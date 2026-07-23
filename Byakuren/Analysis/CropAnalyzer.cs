using System.Globalization;
using System.Text.RegularExpressions;
using Byakuren.Execution;
using Byakuren.Models;

namespace Byakuren.Analysis;

public sealed class CropAnalyzer(ProcessRunner runner)
{
    public async Task<CropAnalysis> AnalyzeAsync(
        CompressionRequest request,
        MediaInfo media,
        CancellationToken cancellationToken)
    {
        string fallbackSummary = request.CropMode == CropMode.Off ? "disabled" : "none";
        CropAnalysis fallback = new()
        {
            Width = media.Width,
            Height = media.Height,
            Summary = fallbackSummary
        };

        if (request.CropMode == CropMode.Off)
            return fallback;

        int frameWidth = media.Rotation is 90 or 270 ? media.Height : media.Width;
        int frameHeight = media.Rotation is 90 or 270 ? media.Width : media.Height;

        IReadOnlyList<double> offsets = Offsets(media.DurationSeconds, 2, 5);
        List<CropSample> samples = [];

        foreach (double offset in offsets)
        {
            CropSample? sample = await DetectSampleAsync(
                request,
                media,
                offset,
                cancellationToken).ConfigureAwait(false);

            if (sample is null)
                return fallback with { Summary = "detection-failed", Samples = samples };
            samples.Add(sample);
        }

        if (samples.Count == 0)
            return fallback;
        bool unstable = Spread(samples.Select(sample => sample.Width)) > 4 ||
            Spread(samples.Select(sample => sample.Height)) > 4 ||
            Spread(samples.Select(sample => sample.X)) > 4 ||
            Spread(samples.Select(sample => sample.Y)) > 4;

        if (unstable)
            return fallback with { Summary = "unstable", Samples = samples };

        int x = Math.Max(0, samples.Min(sample => sample.X));
        int y = Math.Max(0, samples.Min(sample => sample.Y));
        int right = Math.Min(frameWidth, samples.Max(sample => sample.X + sample.Width));
        int bottom = Math.Min(frameHeight, samples.Max(sample => sample.Y + sample.Height));
        int width = Even(Math.Max(2, right - x));
        int height = Even(Math.Max(2, bottom - y));
        int rightRemoved = Math.Max(0, frameWidth - x - width);
        int bottomRemoved = Math.Max(0, frameHeight - y - height);
        double areaRemoved = 1 - width * (double)height / (frameWidth * (double)frameHeight);
        int maxBorder = new[] { x, y, rightRemoved, bottomRemoved }.Max();
        if (areaRemoved < 0.04 || maxBorder < 8)
            return fallback with { Summary = "insignificant", Samples = samples, AreaRemovedRatio = areaRemoved };
        int pairToleranceX = Math.Max(4, (int)Math.Round(Math.Max(x, rightRemoved) * 0.10));
        int pairToleranceY = Math.Max(4, (int)Math.Round(Math.Max(y, bottomRemoved) * 0.10));
        if (Math.Abs(x - rightRemoved) > pairToleranceX || Math.Abs(y - bottomRemoved) > pairToleranceY)
            return fallback with { Summary = "unbalanced", Samples = samples, AreaRemovedRatio = areaRemoved };
        bool bordersBlank = await BordersBlankAsync(
            request,
            media,
            offsets,
            frameWidth,
            frameHeight,
            x,
            y,
            width,
            height,
            cancellationToken).ConfigureAwait(false);

        if (!bordersBlank)
            return fallback with { Summary = "border-content", Samples = samples, AreaRemovedRatio = areaRemoved };

        return new CropAnalysis
        {
            Applied = true,
            Width = width,
            Height = height,
            X = x,
            Y = y,
            Filter = $"crop={width}:{height}:{x}:{y}",
            Summary = $"{width}x{height}+{x}+{y}",
            AreaRemovedRatio = areaRemoved,
            Samples = samples
        };
    }

    private async Task<CropSample?> DetectSampleAsync(
        CompressionRequest request,
        MediaInfo media,
        double offset,
        CancellationToken cancellationToken)
    {
        ProcessResult result = await runner.RunAsync(request.FFmpegPath,
        [
            "-hide_banner", "-loglevel", "info", "-ss", Number(offset), "-t", "2", "-i", media.Path,
            "-vf", "cropdetect=limit=0.0941176:round=2:reset=0", "-an", "-f", "null", "-"
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
            return null;
        MatchCollection matches = Regex.Matches(
            result.CombinedOutput,
            @"crop=(?<w>\d+):(?<h>\d+):(?<x>\d+):(?<y>\d+)");
        if (matches.Count == 0)
            return null;
        Match match = matches[^1];
        return new CropSample(offset,
            int.Parse(match.Groups["w"].Value, CultureInfo.InvariantCulture),
            int.Parse(match.Groups["h"].Value, CultureInfo.InvariantCulture),
            int.Parse(match.Groups["x"].Value, CultureInfo.InvariantCulture),
            int.Parse(match.Groups["y"].Value, CultureInfo.InvariantCulture));
    }

    private async Task<bool> BordersBlankAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<double> offsets,
        int frameWidth,
        int frameHeight,
        int x,
        int y,
        int width,
        int height,
        CancellationToken cancellationToken)
    {
        List<(int Width, int Height, int X, int Y)> regions = [];
        int right = frameWidth - x - width;
        int bottom = frameHeight - y - height;
        if (x > 0)
            regions.Add((x, frameHeight, 0, 0));
        if (right > 0)
            regions.Add((right, frameHeight, frameWidth - right, 0));
        if (y > 0)
            regions.Add((frameWidth, y, 0, 0));
        if (bottom > 0)
            regions.Add((frameWidth, bottom, 0, frameHeight - bottom));
        if (regions.Count == 0)
            return false;

        foreach (double offset in offsets)
        {
            foreach ((int regionWidth, int regionHeight, int regionX, int regionY) in regions)
            {
                if (regionWidth < 2 || regionHeight < 2)
                    continue;
                string filter =
                    $"crop={regionWidth}:{regionHeight}:{regionX}:{regionY}," +
                    "fps=4,signalstats,metadata=print:file=-";
                ProcessResult result = await runner.RunAsync(request.FFmpegPath,
                [
                    "-hide_banner", "-loglevel", "info", "-ss", Number(offset), "-t", "1", "-i", media.Path,
                    "-vf", filter, "-an", "-f", "null", "-"
                ], cancellationToken).ConfigureAwait(false);
                if (result.ExitCode != 0)
                    return false;
                IReadOnlyList<double> yMaxValues = Values(result.CombinedOutput, "lavfi.signalstats.YMAX");
                IReadOnlyList<double> yMinValues = Values(result.CombinedOutput, "lavfi.signalstats.YMIN");
                IReadOnlyList<double> uMaxValues = Values(result.CombinedOutput, "lavfi.signalstats.UMAX");
                IReadOnlyList<double> uMinValues = Values(result.CombinedOutput, "lavfi.signalstats.UMIN");
                IReadOnlyList<double> vMaxValues = Values(result.CombinedOutput, "lavfi.signalstats.VMAX");
                IReadOnlyList<double> vMinValues = Values(result.CombinedOutput, "lavfi.signalstats.VMIN");
                bool missingSignalData = yMaxValues.Count == 0 ||
                    yMinValues.Count == 0 ||
                    uMaxValues.Count == 0 ||
                    uMinValues.Count == 0 ||
                    vMaxValues.Count == 0 ||
                    vMinValues.Count == 0;
                if (missingSignalData)
                    return false;

                double scale = Math.Pow(2, Math.Max(0, media.BitDepth - 8));
                if (yMaxValues.Max() > 40 * scale || yMaxValues.Max() - yMinValues.Min() > 24 * scale)
                    return false;

                bool chromaUOutsideBlankRange = uMinValues.Min() < 96 * scale ||
                    uMaxValues.Max() > 160 * scale ||
                    uMaxValues.Max() - uMinValues.Min() > 32 * scale;
                if (chromaUOutsideBlankRange)
                    return false;

                bool chromaVOutsideBlankRange = vMinValues.Min() < 96 * scale ||
                    vMaxValues.Max() > 160 * scale ||
                    vMaxValues.Max() - vMinValues.Min() > 32 * scale;
                if (chromaVOutsideBlankRange)
                    return false;
            }
        }
        return true;
    }

    private static IReadOnlyList<double> Values(string output, string key)
    {
        return Regex.Matches(output, Regex.Escape(key) + @"=(?<value>\d+(?:\.\d+)?)")
            .Select(match => double.Parse(
                match.Groups["value"].Value,
                CultureInfo.InvariantCulture))
            .ToArray();
    }

    private static IReadOnlyList<double> Offsets(
        double duration,
        int sampleSeconds,
        int maxSamples)
    {
        return SampleWindowPlanner.FixedWindows(duration, sampleSeconds, maxSamples)
            .Select(window => window.StartSeconds)
            .ToArray();
    }

    private static int Spread(IEnumerable<int> values) => values.Max() - values.Min();
    private static int Even(int value) => Math.Max(2, value / 2 * 2);
    private static string Number(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
}
