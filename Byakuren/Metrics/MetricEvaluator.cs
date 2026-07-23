using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Byakuren.Analysis;
using Byakuren.Execution;
using Byakuren.IO;
using Byakuren.Models;
using Byakuren.Planner;
using Byakuren.Probe;

namespace Byakuren.Metrics;

public sealed class MetricEvaluator(ProcessRunner runner, FFmpegProbe probe)
{
    private readonly Dictionary<string, MotionRegion?> motionRegionCache = new(StringComparer.Ordinal);

    public static string ReferenceFilter(CanonicalCanvas canvas)
    {
        return $"setsar=1,scale={canvas.Width}:{canvas.Height}:flags=lanczos," +
            $"fps={Number(canvas.Fps)}:round=near,format={canvas.PixelFormat}";
    }

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
        return await EvaluateWindowsAsync(
            request,
            media,
            plan,
            outputPath,
            tempDirectory,
            windows,
            distortedIsPreview: false,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<MetricEnsemble> EvaluatePreviewAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        SampleWindow window,
        CancellationToken cancellationToken)
    {
        return await EvaluateWindowsAsync(
            request,
            media,
            plan,
            outputPath,
            tempDirectory,
            [window],
            distortedIsPreview: true,
            cancellationToken).ConfigureAwait(false);
    }

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
        if (mode == MetricMode.Off)
            return new MetricEnsemble { Mode = "off" };
        bool collectCAMBI = !distortedIsPreview &&
            (plan.ContentClass is "anime" or "noisy_camera" || plan.Preprocess == "deband");
        List<MetricWindow> metricWindows = [];
        List<double> standardScores = [];
        List<string> errors = [];

        int index = 0;
        foreach (SampleWindow window in windows)
        {
            WindowEvaluation evaluation = await EvaluateWindowAsync(
                request,
                media,
                plan,
                outputPath,
                tempDirectory,
                window,
                index,
                mode,
                collectCAMBI,
                distortedIsPreview,
                cancellationToken).ConfigureAwait(false);

            metricWindows.Add(evaluation.Window);
            errors.AddRange(evaluation.Errors);
            if (evaluation.StandardVmaf.HasValue)
                standardScores.Add(evaluation.StandardVmaf.Value);

            index++;
        }

        double? meanVMAFNeg = Average(metricWindows.Select(window => window.VMAFNeg));
        double? meanXPSNR = Average(metricWindows.Select(window => window.XPSNR));
        double? meanCAMBI = Average(metricWindows.Select(window => window.CAMBI));
        double? primary = meanVMAFNeg ?? meanXPSNR;
        double? worstWindowScore = Minimum(metricWindows.Select(window => window.XPSNR));
        if (meanVMAFNeg.HasValue)
            worstWindowScore = Minimum(metricWindows.Select(window => window.VMAFNeg));

        double? standardVmaf = null;
        if (standardScores.Count > 0)
            standardVmaf = standardScores.Average();

        string? error = null;
        if (!primary.HasValue)
            error = LastUsefulError(errors);

        return new MetricEnsemble
        {
            Available = primary.HasValue,
            Mode = mode.ToString().ToLowerInvariant(),
            PrimaryScore = primary,
            WorstWindowScore = worstWindowScore,
            VMAFNeg = meanVMAFNeg,
            WorstVMAFNeg = Minimum(metricWindows.Select(window => window.VMAFNeg)),
            StandardVMAF = standardVmaf,
            XPSNR = meanXPSNR,
            WorstXPSNR = Minimum(metricWindows.Select(window => window.XPSNR)),
            CAMBI = meanCAMBI,
            WorstCAMBI = Maximum(metricWindows.Select(window => window.CAMBI)),
            Windows = metricWindows,
            Error = error
        };
    }

    private async Task<WindowEvaluation> EvaluateWindowAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        string outputPath,
        string tempDirectory,
        SampleWindow window,
        int index,
        MetricMode mode,
        bool collectCambi,
        bool distortedIsPreview,
        CancellationToken cancellationToken)
    {
        double duration = Math.Min(
            window.DurationSeconds,
            Math.Max(0.25, media.DurationSeconds - window.StartSeconds));
        double distortedStart = distortedIsPreview ? 0 : window.StartSeconds;

        MotionRegion? motionRegion = null;
        if (distortedIsPreview)
        {
            motionRegion = await ResolveMotionRegionAsync(
                request,
                media,
                plan,
                window.StartSeconds,
                duration,
                cancellationToken).ConfigureAwait(false);
        }

        double? vmafNeg = null;
        double? standardVmaf = null;
        double? xpsnr = null;
        double? cambi = null;
        List<string> errors = [];

        if (mode is MetricMode.VMAF or MetricMode.Ensemble)
        {
            (vmafNeg, standardVmaf, string? error) = await RunVMAFAsync(
                request,
                media,
                plan,
                outputPath,
                tempDirectory,
                window.StartSeconds,
                distortedStart,
                duration,
                index,
                distortedIsPreview,
                cancellationToken).ConfigureAwait(false);

            if (!string.IsNullOrWhiteSpace(error))
                errors.Add(error);

            if (motionRegion is not null)
            {
                (double? regionVmafNeg, double? regionStandardVmaf, string? regionError) =
                    await RunVMAFAsync(
                        request,
                        media,
                        plan,
                        outputPath,
                        tempDirectory,
                        window.StartSeconds,
                        distortedStart,
                        duration,
                        index + 1000,
                        distortedIsPreview,
                        cancellationToken,
                        motionRegion).ConfigureAwait(false);

                vmafNeg = Blend(vmafNeg, regionVmafNeg);
                standardVmaf = Blend(standardVmaf, regionStandardVmaf);
                if (!string.IsNullOrWhiteSpace(regionError) && !vmafNeg.HasValue)
                    errors.Add(regionError);
            }

            if (collectCambi)
            {
                (cambi, string? cambiError) = await RunCAMBIAsync(
                    request,
                    media,
                    plan,
                    outputPath,
                    tempDirectory,
                    window.StartSeconds,
                    distortedStart,
                    duration,
                    index,
                    distortedIsPreview,
                    cancellationToken).ConfigureAwait(false);

                if (!string.IsNullOrWhiteSpace(cambiError))
                    errors.Add(cambiError);
            }
        }

        if (mode is MetricMode.XPSNR or MetricMode.Ensemble)
        {
            (xpsnr, string? error) = await RunXPSNRAsync(
                request,
                media,
                plan,
                outputPath,
                window.StartSeconds,
                distortedStart,
                duration,
                distortedIsPreview,
                cancellationToken).ConfigureAwait(false);

            if (!string.IsNullOrWhiteSpace(error))
                errors.Add(error);

            if (motionRegion is not null)
            {
                (double? regionXpsnr, string? regionError) = await RunXPSNRAsync(
                    request,
                    media,
                    plan,
                    outputPath,
                    window.StartSeconds,
                    distortedStart,
                    duration,
                    distortedIsPreview,
                    cancellationToken,
                    motionRegion).ConfigureAwait(false);

                xpsnr = Blend(xpsnr, regionXpsnr);
                if (!string.IsNullOrWhiteSpace(regionError) && !xpsnr.HasValue)
                    errors.Add(regionError);
            }
        }

        MetricWindow metricWindow = new(
            index,
            window.StartSeconds,
            window.StartSeconds + duration,
            vmafNeg,
            xpsnr,
            cambi);

        return new WindowEvaluation(metricWindow, standardVmaf, errors);
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
        CancellationToken cancellationToken,
        MotionRegion? motionRegion = null)
    {
        string logPath = Path.Combine(tempDirectory, $"vmaf-{Guid.NewGuid():N}-{index}.json");
        (string referenceFilter, string distortedFilter) = MetricFilters(plan, selectionTimeline, motionRegion);
        string filter =
            $"[0:v]{referenceFilter},setpts=PTS-STARTPTS[ref];" +
            $"[1:v]{distortedFilter},setpts=PTS-STARTPTS[dist];" +
            $"[dist][ref]libvmaf=log_fmt=json:log_path='{EscapeFilterPath(logPath)}':" +
            "model='version=vmaf_v0.6.1neg\\:name=vmaf_neg|" +
            "version=vmaf_v0.6.1\\:name=vmaf'";
        try
        {
            ProcessResult result = await runner.RunAsync(request.FFmpegPath,
            [
                "-v", "error", "-ss", Number(referenceStart), "-t", Number(duration), "-i", media.Path,
                "-ss", Number(distortedStart), "-t", Number(duration), "-i", outputPath,
                "-filter_complex", filter, "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (result.ExitCode != 0 || !File.Exists(logPath))
                return (null, null, result.StandardError);
            try
            {
                string json = await File
                    .ReadAllTextAsync(logPath, cancellationToken)
                    .ConfigureAwait(false);
                using JsonDocument document = JsonDocument.Parse(json);
                JsonElement pooled = document.RootElement.GetProperty("pooled_metrics");
                double? standard = Mean(pooled, "vmaf");
                return (Mean(pooled, "vmaf_neg") ?? standard, standard, null);
            }
            catch (Exception exception) when (
                exception is IOException or
                    UnauthorizedAccessException or
                    JsonException or
                    KeyNotFoundException or
                    InvalidOperationException)
            {
                return (null, null, exception.Message);
            }
        }
        finally
        {
            FileSystemCleanup.DeleteFile(logPath, runner.ReportWarning);
        }
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
        CancellationToken cancellationToken,
        MotionRegion? motionRegion = null)
    {
        (string referenceFilter, string distortedFilter) = MetricFilters(plan, selectionTimeline, motionRegion);
        string filter =
            $"[0:v]{referenceFilter},setpts=PTS-STARTPTS[ref];" +
            $"[1:v]{distortedFilter},setpts=PTS-STARTPTS[dist];" +
            "[dist][ref]xpsnr=stats_file=-";
        ProcessResult result = await runner.RunAsync(request.FFmpegPath,
        [
            "-v", "info", "-ss", Number(referenceStart), "-t", Number(duration), "-i", media.Path,
            "-ss", Number(distortedStart), "-t", Number(duration), "-i", outputPath,
            "-filter_complex", filter, "-f", "null", "-"
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
            return (null, result.StandardError);
        MatchCollection matches = Regex.Matches(
            result.CombinedOutput,
            @"XPSNR y:\s*(?<score>\d+(?:\.\d+)?)",
            RegexOptions.IgnoreCase);
        if (matches.Count == 0)
            return (null, "XPSNR produced no frame scores.");

        double average = matches
            .Select(match => double.Parse(
                match.Groups["score"].Value,
                CultureInfo.InvariantCulture))
            .Average();
        return (average, null);
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
        string filter =
            $"[0:v]{referenceFilter},setpts=PTS-STARTPTS[ref];" +
            $"[1:v]{distortedFilter},setpts=PTS-STARTPTS[dist];" +
            $"[dist][ref]libvmaf=log_fmt=json:log_path='{EscapeFilterPath(logPath)}':" +
            "feature='name=cambi'";
        try
        {
            ProcessResult result = await runner.RunAsync(request.FFmpegPath,
            [
                "-v", "error", "-ss", Number(referenceStart), "-t", Number(duration), "-i", media.Path,
                "-ss", Number(distortedStart), "-t", Number(duration), "-i", outputPath,
                "-filter_complex", filter, "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (result.ExitCode != 0 || !File.Exists(logPath))
                return (null, result.StandardError);
            try
            {
                string json = await File
                    .ReadAllTextAsync(logPath, cancellationToken)
                    .ConfigureAwait(false);
                using JsonDocument document = JsonDocument.Parse(json);
                JsonElement pooledMetrics = document.RootElement.GetProperty("pooled_metrics");
                return (Mean(pooledMetrics, "cambi"), null);
            }
            catch (Exception exception) when (
                exception is IOException or
                    UnauthorizedAccessException or
                    JsonException or
                    KeyNotFoundException or
                    InvalidOperationException)
            {
                return (null, exception.Message);
            }
        }
        finally
        {
            FileSystemCleanup.DeleteFile(logPath, runner.ReportWarning);
        }
    }

    private async Task<MetricMode> ResolveModeAsync(CompressionRequest request, CancellationToken cancellationToken)
    {
        if (request.MetricMode != MetricMode.Auto)
            return request.MetricMode;
        if (request.Mode == CompressionMode.Fast)
            return MetricMode.Off;
        bool vmaf = await probe
            .HasFilterAsync(request.FFmpegPath, "libvmaf", cancellationToken)
            .ConfigureAwait(false);
        bool xpsnr = await probe
            .HasFilterAsync(request.FFmpegPath, "xpsnr", cancellationToken)
            .ConfigureAwait(false);

        if (vmaf && xpsnr)
            return MetricMode.Ensemble;
        if (vmaf)
            return MetricMode.VMAF;
        if (xpsnr)
            return MetricMode.XPSNR;

        return MetricMode.Off;
    }

    private static IReadOnlyList<SampleWindow> ResolveWindows(CompressionRequest request, MediaInfo media, CompressionPlan plan)
    {
        int maxSamples = request.MetricMaxSamples;
        if (maxSamples <= 0)
        {
            ModeStrategy strategy = CompressionPlanner.Strategy(request.Mode);
            maxSamples = Math.Max(1, strategy.PreviewMaxSamples);
        }

        int sampleSeconds = request.MetricSampleSeconds;
        if (sampleSeconds <= 0)
            sampleSeconds = Math.Min(4, request.ProbeSampleSeconds);

        IReadOnlyList<SampleWindow> source = plan.SampleWindows;
        if (source.Count == 0)
        {
            source = SampleWindowPlanner.FixedWindows(
                media.DurationSeconds,
                sampleSeconds,
                maxSamples);
        }

        return source
            .Take(maxSamples)
            .Select(window => window with
            {
                DurationSeconds = Math.Min(window.DurationSeconds, sampleSeconds)
            })
            .ToArray();
    }

    private async Task<MotionRegion?> ResolveMotionRegionAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        double startSeconds,
        double durationSeconds,
        CancellationToken cancellationToken)
    {
        string crop = plan.CropAnalysis?.Filter ?? "";
        string key = $"{media.Path}|{startSeconds:0.###}|{durationSeconds:0.###}|{crop}";
        if (motionRegionCache.TryGetValue(key, out MotionRegion? cached))
            return cached;

        MotionRegion? best = null;
        double probeDuration = Math.Min(2, durationSeconds);
        for (int row = 0; row < 3; row++)
        {
            for (int column = 0; column < 3; column++)
            {
                string tile = $"scale=384:216:flags=bilinear,fps=8," +
                    $"crop=128:72:{column * 128}:{row * 72}," +
                    "signalstats,metadata=print:file=-";
                string filter = string.Join(
                    ',',
                    new[] { crop, tile }.Where(value => !string.IsNullOrWhiteSpace(value)));
                ProcessResult result = await runner.RunAsync(request.FFmpegPath,
                [
                    "-v", "error", "-ss", Number(startSeconds), "-t", Number(probeDuration), "-i", media.Path,
                    "-vf", filter, "-an", "-sn", "-dn", "-f", "null", "-"
                ], cancellationToken).ConfigureAwait(false);
                if (result.ExitCode != 0)
                    continue;
                double[] differences = Regex.Matches(
                        result.CombinedOutput,
                        @"lavfi\.signalstats\.YDIF=(?<value>\d+(?:\.\d+)?)",
                        RegexOptions.IgnoreCase)
                    .Select(match => double.Parse(
                        match.Groups["value"].Value,
                        CultureInfo.InvariantCulture))
                    .OrderBy(value => value)
                    .ToArray();
                if (differences.Length == 0)
                    continue;
                // Favor recurring or peak motion without letting a single noisy frame choose the tile.
                int upperQuartile = Math.Clamp(
                    (int)Math.Floor(differences.Length * 0.75),
                    0,
                    differences.Length - 1);
                double score = differences[upperQuartile..].Average();
                if (best is null || score > best.Score)
                    best = new MotionRegion(row, column, score);
            }
        }

        motionRegionCache[key] = best;
        return best;
    }

    private static (string Reference, string Distorted) MetricFilters(
        CompressionPlan plan,
        bool selectionTimeline,
        MotionRegion? motionRegion = null)
    {
        (string reference, string distorted) filters;
        if (!selectionTimeline)
        {
            string canonicalReference = plan.MetricReferenceFilter;
            if (string.IsNullOrWhiteSpace(canonicalReference))
                canonicalReference = ReferenceFilter(plan.CanonicalCanvas);

            filters = (canonicalReference, DistortedFilter(plan.CanonicalCanvas));
        }
        else
        {
            // Candidate selection measures spatial damage at the candidate cadence.
            // Final reporting still uses the canonical source timeline above.
            CanonicalCanvas selectionCanvas = plan.CanonicalCanvas with
            {
                Fps = Math.Min(plan.CanonicalCanvas.Fps, plan.Fps)
            };
            string crop = plan.CropAnalysis?.Filter ?? "";
            string selectionReference = string.Join(
                ',',
                new[] { crop, ReferenceFilter(selectionCanvas) }
                    .Where(filter => !string.IsNullOrWhiteSpace(filter)));
            filters = (selectionReference, DistortedFilter(selectionCanvas));
        }

        if (motionRegion is null)
            return filters;
        int tileWidth = Math.Max(2, plan.CanonicalCanvas.Width / 3 / 2 * 2);
        int tileHeight = Math.Max(2, plan.CanonicalCanvas.Height / 3 / 2 * 2);
        int x = Math.Min(plan.CanonicalCanvas.Width - tileWidth, motionRegion.Column * tileWidth);
        int y = Math.Min(plan.CanonicalCanvas.Height - tileHeight, motionRegion.Row * tileHeight);
        string regionCrop = $"crop={tileWidth}:{tileHeight}:{x}:{y}";
        return ($"{filters.reference},{regionCrop}", $"{filters.distorted},{regionCrop}");
    }

    private static double? Mean(JsonElement pooled, string name)
    {
        if (pooled.TryGetProperty(name, out JsonElement metric) &&
            metric.TryGetProperty("mean", out JsonElement mean) &&
            mean.TryGetDouble(out double value))
        {
            return value;
        }

        return null;
    }

    private static double? Average(IEnumerable<double?> values)
    {
        double[] available = values
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .ToArray();

        if (available.Length == 0)
            return null;

        return available.Average();
    }

    private static double? Minimum(IEnumerable<double?> values)
    {
        double[] available = values
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .ToArray();

        if (available.Length == 0)
            return null;

        return available.Min();
    }

    private static double? Maximum(IEnumerable<double?> values)
    {
        double[] available = values
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .ToArray();

        if (available.Length == 0)
            return null;

        return available.Max();
    }

    // Motion evidence influences preview selection only; final reporting remains whole-frame and canonical.
    private static double? Blend(double? wholeFrame, double? motionRegion)
    {
        if (wholeFrame.HasValue && motionRegion.HasValue)
            return wholeFrame.Value * 0.65 + motionRegion.Value * 0.35;

        return wholeFrame ?? motionRegion;
    }

    private static string Number(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
    private static string EscapeFilterPath(string value) => value.Replace("\\", "/").Replace(":", "\\:").Replace("'", "\\'");
    private static string? LastUsefulError(IEnumerable<string> errors)
    {
        return errors
            .SelectMany(error => error.Split(
                ['\r', '\n'],
                StringSplitOptions.RemoveEmptyEntries))
            .LastOrDefault()
            ?.Trim();
    }

    private sealed record WindowEvaluation(
        MetricWindow Window,
        double? StandardVmaf,
        IReadOnlyList<string> Errors);

    private sealed record MotionRegion(int Row, int Column, double Score);
}
