using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Byakuren.Analysis;
using Byakuren.Execution;
using Byakuren.Models;
using Byakuren.Planner;
using Byakuren.Probe;

namespace Byakuren.Metrics;

public sealed class MetricEvaluator(ProcessRunner runner, FFmpegProbe probe)
{
    public static string ReferenceFilter(CanonicalCanvas canvas) =>
        $"setsar=1,scale={canvas.Width}:{canvas.Height}:flags=lanczos,fps={Number(canvas.Fps)}:round=near,format={canvas.PixelFormat}";

    public static string DistortedFilter(CanonicalCanvas canvas) => ReferenceFilter(canvas);

    public async Task<MetricEnsemble> EvaluateAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        CancellationToken cancellationToken)
    {
        IReadOnlyList<SampleWindow> windows = ResolveWindows(request, media, plan);
        return await EvaluateWindowsAsync(request, media, plan, outputPath, tempDirectory, windows, distortedIsPreview: false, cancellationToken).ConfigureAwait(false);
    }

    public async Task<MetricEnsemble> EvaluatePreviewAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        SampleWindow window,
        CancellationToken cancellationToken) =>
        await EvaluateWindowsAsync(request, media, plan, outputPath, tempDirectory, [window], distortedIsPreview: true, cancellationToken).ConfigureAwait(false);

    private async Task<MetricEnsemble> EvaluateWindowsAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        IReadOnlyList<SampleWindow> windows,
        bool distortedIsPreview,
        CancellationToken cancellationToken)
    {
        MetricMode mode = await ResolveModeAsync(request, cancellationToken).ConfigureAwait(false);
        if (mode == MetricMode.Off) return new MetricEnsemble { Mode = "off" };
        bool collectCAMBI = plan.ContentClass is "anime" or "noisy_camera" || plan.Preprocess == "deband";
        List<MetricWindow> metricWindows = [];
        List<double> standardScores = [];
        List<string> errors = [];

        int index = 0;
        foreach (SampleWindow window in windows)
        {
            double duration = Math.Min(window.DurationSeconds, Math.Max(0.25, media.DurationSeconds - window.StartSeconds));
            double? vmafNeg = null;
            double? standardVMAF = null;
            double? xpsnr = null;
            double? cambi = null;
            if (mode is MetricMode.VMAF or MetricMode.Ensemble)
            {
                (vmafNeg, standardVMAF, string? error) = await RunVMAFAsync(request, media, plan, outputPath, tempDirectory, window.StartSeconds, distortedIsPreview ? 0 : window.StartSeconds, duration, index, distortedIsPreview, cancellationToken).ConfigureAwait(false);
                if (standardVMAF.HasValue) standardScores.Add(standardVMAF.Value);
                if (!string.IsNullOrWhiteSpace(error)) errors.Add(error);
                if (collectCAMBI)
                {
                    (cambi, string? cambiError) = await RunCAMBIAsync(request, media, plan, outputPath, tempDirectory, window.StartSeconds, distortedIsPreview ? 0 : window.StartSeconds, duration, index, distortedIsPreview, cancellationToken).ConfigureAwait(false);
                    if (!string.IsNullOrWhiteSpace(cambiError)) errors.Add(cambiError);
                }
            }
            if (mode is MetricMode.XPSNR or MetricMode.Ensemble)
            {
                (xpsnr, string? error) = await RunXPSNRAsync(request, media, plan, outputPath, window.StartSeconds, distortedIsPreview ? 0 : window.StartSeconds, duration, distortedIsPreview, cancellationToken).ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(error)) errors.Add(error);
            }
            metricWindows.Add(new MetricWindow(index++, window.StartSeconds, window.StartSeconds + duration, vmafNeg, xpsnr, cambi));
        }

        double? meanVMAFNeg = Average(metricWindows.Select(window => window.VMAFNeg));
        double? meanXPSNR = Average(metricWindows.Select(window => window.XPSNR));
        double? meanCAMBI = Average(metricWindows.Select(window => window.CAMBI));
        double? primary = meanVMAFNeg ?? meanXPSNR;
        return new MetricEnsemble
        {
            Available = primary.HasValue,
            Mode = mode.ToString().ToLowerInvariant(),
            PrimaryScore = primary,
            WorstWindowScore = meanVMAFNeg.HasValue ? Minimum(metricWindows.Select(window => window.VMAFNeg)) : Minimum(metricWindows.Select(window => window.XPSNR)),
            VMAFNeg = meanVMAFNeg,
            WorstVMAFNeg = Minimum(metricWindows.Select(window => window.VMAFNeg)),
            StandardVMAF = standardScores.Count == 0 ? null : standardScores.Average(),
            XPSNR = meanXPSNR,
            WorstXPSNR = Minimum(metricWindows.Select(window => window.XPSNR)),
            CAMBI = meanCAMBI,
            WorstCAMBI = Maximum(metricWindows.Select(window => window.CAMBI)),
            Windows = metricWindows,
            Error = primary.HasValue ? null : LastUsefulError(errors)
        };
    }

    private async Task<(double? VMAFNeg, double? StandardVMAF, string? Error)> RunVMAFAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        double referenceStart,
        double distortedStart,
        double duration,
        int index,
        bool selectionTimeline,
        CancellationToken cancellationToken)
    {
        string logPath = Path.Combine(tempDirectory, $"vmaf-{Guid.NewGuid():N}-{index}.json");
        (string referenceFilter, string distortedFilter) = MetricFilters(plan, selectionTimeline);
        string filter = $"[0:v]{referenceFilter},setpts=PTS-STARTPTS[ref];[1:v]{distortedFilter},setpts=PTS-STARTPTS[dist];" +
                        $"[dist][ref]libvmaf=log_fmt=json:log_path='{EscapeFilterPath(logPath)}':model='version=vmaf_v0.6.1neg\\:name=vmaf_neg|version=vmaf_v0.6.1\\:name=vmaf'";
        ProcessResult result = await runner.RunAsync(request.FFmpegPath,
        [
            "-v", "error", "-ss", Number(referenceStart), "-t", Number(duration), "-i", media.Path,
            "-ss", Number(distortedStart), "-t", Number(duration), "-i", outputPath,
            "-filter_complex", filter, "-f", "null", "-"
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0 || !File.Exists(logPath)) return (null, null, result.StandardError);
        try
        {
            using JsonDocument document = JsonDocument.Parse(await File.ReadAllTextAsync(logPath, cancellationToken).ConfigureAwait(false));
            JsonElement pooled = document.RootElement.GetProperty("pooled_metrics");
            double? standard = Mean(pooled, "vmaf");
            return (Mean(pooled, "vmaf_neg") ?? standard, standard, null);
        }
        catch (Exception exception) { return (null, null, exception.Message); }
        finally { TryDelete(logPath); }
    }

    private async Task<(double? Score, string? Error)> RunXPSNRAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        double referenceStart,
        double distortedStart,
        double duration,
        bool selectionTimeline,
        CancellationToken cancellationToken)
    {
        (string referenceFilter, string distortedFilter) = MetricFilters(plan, selectionTimeline);
        string filter = $"[0:v]{referenceFilter},setpts=PTS-STARTPTS[ref];[1:v]{distortedFilter},setpts=PTS-STARTPTS[dist];[dist][ref]xpsnr=stats_file=-";
        ProcessResult result = await runner.RunAsync(request.FFmpegPath,
        [
            "-v", "info", "-ss", Number(referenceStart), "-t", Number(duration), "-i", media.Path,
            "-ss", Number(distortedStart), "-t", Number(duration), "-i", outputPath,
            "-filter_complex", filter, "-f", "null", "-"
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0) return (null, result.StandardError);
        MatchCollection matches = Regex.Matches(result.CombinedOutput, @"XPSNR y:\s*(?<score>\d+(?:\.\d+)?)", RegexOptions.IgnoreCase);
        return matches.Count == 0
            ? (null, "XPSNR produced no frame scores.")
            : (matches.Select(match => double.Parse(match.Groups["score"].Value, CultureInfo.InvariantCulture)).Average(), null);
    }

    private async Task<(double? Score, string? Error)> RunCAMBIAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        double referenceStart,
        double distortedStart,
        double duration,
        int index,
        bool selectionTimeline,
        CancellationToken cancellationToken)
    {
        string logPath = Path.Combine(tempDirectory, $"cambi-{Guid.NewGuid():N}-{index}.json");
        (string referenceFilter, string distortedFilter) = MetricFilters(plan, selectionTimeline);
        string filter = $"[0:v]{referenceFilter},setpts=PTS-STARTPTS[ref];[1:v]{distortedFilter},setpts=PTS-STARTPTS[dist];" +
                        $"[dist][ref]libvmaf=log_fmt=json:log_path='{EscapeFilterPath(logPath)}':feature='name=cambi'";
        ProcessResult result = await runner.RunAsync(request.FFmpegPath,
        [
            "-v", "error", "-ss", Number(referenceStart), "-t", Number(duration), "-i", media.Path,
            "-ss", Number(distortedStart), "-t", Number(duration), "-i", outputPath,
            "-filter_complex", filter, "-f", "null", "-"
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0 || !File.Exists(logPath)) return (null, result.StandardError);
        try
        {
            using JsonDocument document = JsonDocument.Parse(await File.ReadAllTextAsync(logPath, cancellationToken).ConfigureAwait(false));
            return (Mean(document.RootElement.GetProperty("pooled_metrics"), "cambi"), null);
        }
        catch (Exception exception) { return (null, exception.Message); }
        finally { TryDelete(logPath); }
    }

    private async Task<MetricMode> ResolveModeAsync(CompressionRequest request, CancellationToken cancellationToken)
    {
        if (request.MetricMode != MetricMode.Auto) return request.MetricMode;
        if (request.Mode == CompressionMode.Fast) return MetricMode.Off;
        bool vmaf = await probe.HasFilterAsync(request.FFmpegPath, "libvmaf", cancellationToken).ConfigureAwait(false);
        bool xpsnr = await probe.HasFilterAsync(request.FFmpegPath, "xpsnr", cancellationToken).ConfigureAwait(false);
        return vmaf && xpsnr ? MetricMode.Ensemble : vmaf ? MetricMode.VMAF : xpsnr ? MetricMode.XPSNR : MetricMode.Off;
    }

    private static IReadOnlyList<SampleWindow> ResolveWindows(CompressionRequest request, MediaInfo media, CompressionPlan plan)
    {
        int maxSamples = request.MetricMaxSamples > 0 ? request.MetricMaxSamples : Math.Max(1, CompressionPlanner.Strategy(request.Mode).PreviewMaxSamples);
        int sampleSeconds = request.MetricSampleSeconds > 0 ? request.MetricSampleSeconds : Math.Min(4, request.ProbeSampleSeconds);
        IReadOnlyList<SampleWindow> source = plan.SampleWindows.Count > 0 ? plan.SampleWindows : SampleWindowPlanner.FixedWindows(media.DurationSeconds, sampleSeconds, maxSamples);
        return source.Take(maxSamples).Select(window => window with { DurationSeconds = Math.Min(window.DurationSeconds, sampleSeconds) }).ToArray();
    }

    private static (string Reference, string Distorted) MetricFilters(CompressionPlan plan, bool selectionTimeline)
    {
        if (!selectionTimeline)
        {
            string canonicalReference = string.IsNullOrWhiteSpace(plan.MetricReferenceFilter)
                ? ReferenceFilter(plan.CanonicalCanvas)
                : plan.MetricReferenceFilter;
            return (canonicalReference, DistortedFilter(plan.CanonicalCanvas));
        }

        // Candidate selection measures spatial damage at the candidate cadence.
        // Final reporting still uses the canonical source timeline above.
        CanonicalCanvas selectionCanvas = plan.CanonicalCanvas with
        {
            Fps = Math.Min(plan.CanonicalCanvas.Fps, plan.Fps)
        };
        string crop = plan.CropAnalysis?.Filter ?? "";
        string selectionReference = string.Join(',', new[] { crop, ReferenceFilter(selectionCanvas) }.Where(filter => !string.IsNullOrWhiteSpace(filter)));
        return (selectionReference, DistortedFilter(selectionCanvas));
    }

    private static double? Mean(JsonElement pooled, string name) =>
        pooled.TryGetProperty(name, out JsonElement metric) && metric.TryGetProperty("mean", out JsonElement mean) && mean.TryGetDouble(out double value) ? value : null;
    private static double? Average(IEnumerable<double?> values) { double[] available = values.Where(value => value.HasValue).Select(value => value!.Value).ToArray(); return available.Length == 0 ? null : available.Average(); }
    private static double? Minimum(IEnumerable<double?> values) { double[] available = values.Where(value => value.HasValue).Select(value => value!.Value).ToArray(); return available.Length == 0 ? null : available.Min(); }
    private static double? Maximum(IEnumerable<double?> values) { double[] available = values.Where(value => value.HasValue).Select(value => value!.Value).ToArray(); return available.Length == 0 ? null : available.Max(); }
    private static string Number(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
    private static string EscapeFilterPath(string value) => value.Replace("\\", "/").Replace(":", "\\:").Replace("'", "\\'");
    private static string? LastUsefulError(IEnumerable<string> errors) => errors.SelectMany(error => error.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)).LastOrDefault()?.Trim();
    private static void TryDelete(string path) { try { File.Delete(path); } catch { } }
}
