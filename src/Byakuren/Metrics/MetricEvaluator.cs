using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Byakuren.Execution;
using Byakuren.Models;
using Byakuren.Probe;

namespace Byakuren.Metrics;

public sealed class MetricEvaluator(ProcessRunner runner, FFmpegProbe probe)
{
    public static string ReferenceFilter(CanonicalCanvas canvas) =>
        $"setsar=1,scale={canvas.Width}:{canvas.Height}:flags=lanczos,fps={canvas.Fps.ToString("0.########", CultureInfo.InvariantCulture)}:round=near,format={canvas.PixelFormat}";

    public static string DistortedFilter(CanonicalCanvas canvas) => ReferenceFilter(canvas);

    public async Task<MetricEnsemble> EvaluateAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        CancellationToken cancellationToken)
    {
        MetricMode mode = await ResolveModeAsync(request, cancellationToken).ConfigureAwait(false);
        if (mode == MetricMode.Off) return new MetricEnsemble();
        double? vmafNeg = null;
        double? standardVmaf = null;
        double? xpsnr = null;
        List<double> vmafFrameScores = new List<double>();
        List<double> xpsnrFrameScores = new List<double>();
        List<string> errors = new List<string>();
        double sampleDurationSeconds = Math.Min(4, media.DurationSeconds);

        if (mode is MetricMode.VMAF or MetricMode.Ensemble)
        {
            string log = Path.Combine(tempDirectory, "vmaf.json");
            string filter = $"[0:v]{ReferenceFilter(plan.CanonicalCanvas)}[ref];[1:v]{DistortedFilter(plan.CanonicalCanvas)}[dist];" +
                         $"[dist][ref]libvmaf=log_fmt=json:log_path='{EscapeFilterPath(log)}':model='version=vmaf_v0.6.1neg\\:name=vmaf_neg|version=vmaf_v0.6.1\\:name=vmaf'";
            ProcessResult result = await runner.RunAsync(request.FFmpegPath,
            [
                "-v", "error", "-t", sampleDurationSeconds.ToString("0.###", CultureInfo.InvariantCulture),
                "-i", media.Path, "-i", outputPath, "-filter_complex", filter, "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0 && File.Exists(log))
            {
                try
                {
                    using JsonDocument document = JsonDocument.Parse(await File.ReadAllTextAsync(log, cancellationToken).ConfigureAwait(false));
                    JsonElement pooled = document.RootElement.GetProperty("pooled_metrics");
                    vmafNeg = Mean(pooled, "vmaf_neg") ?? Mean(pooled, "vmaf");
                    standardVmaf = Mean(pooled, "vmaf");
                    vmafFrameScores = FrameScores(document.RootElement, "vmaf_neg");
                    if (vmafFrameScores.Count == 0) vmafFrameScores = FrameScores(document.RootElement, "vmaf");
                }
                catch (Exception exception) { errors.Add(exception.Message); }
            }
            else errors.Add(result.StandardError);
        }

        if (mode is MetricMode.XPSNR or MetricMode.Ensemble)
        {
            string filter = $"[0:v]{ReferenceFilter(plan.CanonicalCanvas)}[ref];[1:v]{DistortedFilter(plan.CanonicalCanvas)}[dist];[dist][ref]xpsnr=stats_file=-";
            ProcessResult result = await runner.RunAsync(request.FFmpegPath,
            [
                "-v", "info", "-t", sampleDurationSeconds.ToString("0.###", CultureInfo.InvariantCulture),
                "-i", media.Path, "-i", outputPath, "-filter_complex", filter, "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0)
            {
                MatchCollection matches = Regex.Matches(result.CombinedOutput, @"XPSNR y:\s*(?<score>\d+(?:\.\d+)?)", RegexOptions.IgnoreCase);
                if (matches.Count > 0)
                {
                    xpsnrFrameScores = matches.Select(match => double.Parse(match.Groups["score"].Value, CultureInfo.InvariantCulture)).ToList();
                    xpsnr = xpsnrFrameScores.Average();
                }
            }
            else errors.Add(result.StandardError);
        }

        IReadOnlyList<MetricWindow> windows = BuildWindows(vmafFrameScores, xpsnrFrameScores, plan.CanonicalCanvas.Fps, sampleDurationSeconds);
        double? worstVmafNeg = windows.Where(window => window.VMAFNeg.HasValue).Select(window => window.VMAFNeg).Min();
        double? worstXpsnr = windows.Where(window => window.XPSNR.HasValue).Select(window => window.XPSNR).Min();
        double? primary = vmafNeg ?? xpsnr;
        double? worstPrimary = vmafNeg.HasValue ? worstVmafNeg : worstXpsnr;
        return new MetricEnsemble
        {
            Available = primary.HasValue,
            Mode = mode.ToString().ToLowerInvariant(),
            PrimaryScore = primary,
            WorstWindowScore = worstPrimary,
            VMAFNeg = vmafNeg,
            WorstVMAFNeg = worstVmafNeg,
            StandardVMAF = standardVmaf,
            XPSNR = xpsnr,
            WorstXPSNR = worstXpsnr,
            Windows = windows,
            Error = primary.HasValue ? null : LastUsefulError(errors)
        };
    }

    private async Task<MetricMode> ResolveModeAsync(CompressionRequest request, CancellationToken cancellationToken)
    {
        if (request.MetricMode != MetricMode.Auto) return request.MetricMode;
        if (request.Mode == CompressionMode.Fast) return MetricMode.Off;
        bool vmaf = await probe.HasFilterAsync(request.FFmpegPath, "libvmaf", cancellationToken).ConfigureAwait(false);
        bool xpsnr = await probe.HasFilterAsync(request.FFmpegPath, "xpsnr", cancellationToken).ConfigureAwait(false);
        return vmaf && xpsnr ? MetricMode.Ensemble : vmaf ? MetricMode.VMAF : xpsnr ? MetricMode.XPSNR : MetricMode.Off;
    }

    private static double? Mean(JsonElement pooled, string name) =>
        pooled.TryGetProperty(name, out JsonElement metric) && metric.TryGetProperty("mean", out JsonElement mean) && mean.TryGetDouble(out double value) ? value : null;

    private static List<double> FrameScores(JsonElement root, string name)
    {
        List<double> scores = new List<double>();
        if (!root.TryGetProperty("frames", out JsonElement frames)) return scores;
        foreach (JsonElement frame in frames.EnumerateArray())
        {
            if (!frame.TryGetProperty("metrics", out JsonElement metrics)) continue;
            if (metrics.TryGetProperty(name, out JsonElement metric) && metric.TryGetDouble(out double value)) scores.Add(value);
        }
        return scores;
    }

    private static IReadOnlyList<MetricWindow> BuildWindows(
        IReadOnlyList<double> vmafScores,
        IReadOnlyList<double> xpsnrScores,
        double fps,
        double durationSeconds)
    {
        int framesPerWindow = Math.Max(1, (int)Math.Round(fps));
        int windowCount = Math.Max(
            (int)Math.Ceiling(vmafScores.Count / (double)framesPerWindow),
            (int)Math.Ceiling(xpsnrScores.Count / (double)framesPerWindow));
        List<MetricWindow> windows = new List<MetricWindow>(windowCount);
        for (int index = 0; index < windowCount; index++)
        {
            int startFrame = index * framesPerWindow;
            double startSeconds = startFrame / Math.Max(1.0, fps);
            double endSeconds = Math.Min(durationSeconds, (startFrame + framesPerWindow) / Math.Max(1.0, fps));
            double? vmaf = WindowMean(vmafScores, startFrame, framesPerWindow);
            double? xpsnr = WindowMean(xpsnrScores, startFrame, framesPerWindow);
            windows.Add(new MetricWindow(index, startSeconds, endSeconds, vmaf, xpsnr));
        }
        return windows;
    }

    private static double? WindowMean(IReadOnlyList<double> scores, int start, int count)
    {
        if (start >= scores.Count) return null;
        int end = Math.Min(scores.Count, start + count);
        double total = 0;
        for (int index = start; index < end; index++) total += scores[index];
        return total / (end - start);
    }

    private static string EscapeFilterPath(string value) => value.Replace("\\", "/").Replace(":", "\\:").Replace("'", "\\'");
    private static string? LastUsefulError(IEnumerable<string> errors) => errors.SelectMany(x => x.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)).LastOrDefault()?.Trim();
}
