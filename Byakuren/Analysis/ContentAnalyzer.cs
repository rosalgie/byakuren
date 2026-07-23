using System.Globalization;
using System.Text.RegularExpressions;
using Byakuren.Execution;
using Byakuren.Models;

namespace Byakuren.Analysis;

public sealed class ContentAnalyzer(ProcessRunner runner)
{
    public async Task<ContentAnalysis> AnalyzeAsync(
        CompressionRequest request,
        MediaInfo media,
        CancellationToken cancellationToken)
    {
        List<double> entropyValues = [];
        List<double> temporalValues = [];
        List<double> noiseValues = [];
        List<double> edgeValues = [];
        List<double> flatValues = [];
        List<double> sceneValues = [];
        List<string> errors = [];

        foreach (double startSeconds in SampleStarts(media.DurationSeconds))
        {
            double durationSeconds = Math.Min(1.5, media.DurationSeconds - startSeconds);
            if (durationSeconds <= 0)
                continue;
            string start = startSeconds.ToString("0.###", CultureInfo.InvariantCulture);
            string duration = durationSeconds.ToString("0.###", CultureInfo.InvariantCulture);
            IReadOnlyList<string> commonArguments =
            [
                "-hide_banner", "-loglevel", "error", "-ss", start, "-t", duration,
                "-i", media.Path, "-an"
            ];

            ProcessResult baseProbe = await runner.RunAsync(request.FFmpegPath,
            [
                .. commonArguments,
                "-vf", "scale=320:-2:flags=area,format=gray,entropy,signalstats=stat=tout,metadata=print:file=-",
                "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (baseProbe.ExitCode == 0)
            {
                AddIfAvailable(
                    entropyValues,
                    MetadataAverage(
                        baseProbe.CombinedOutput,
                        "lavfi.entropy.normalized_entropy.normal.Y"));

                double? temporal = MetadataAverage(baseProbe.CombinedOutput, "lavfi.signalstats.YDIF");
                if (temporal.HasValue)
                    temporalValues.Add(temporal.Value / 255.0);

                AddIfAvailable(
                    noiseValues,
                    MetadataAverage(baseProbe.CombinedOutput, "lavfi.signalstats.TOUT"));
            }
            else
                errors.Add(baseProbe.StandardError);

            ProcessResult shapeProbe = await runner.RunAsync(request.FFmpegPath,
            [
                .. commonArguments,
                "-filter_complex",
                "scale=320:-2:flags=area,edgedetect=low=0.08:high=0.20,format=gray," +
                "split[edge][flat];[edge]signalstats,metadata=print:file=-[measured];" +
                "[flat]blackframe=amount=0:threshold=16,metadata=print:file=-[flatness]",
                "-map", "[measured]", "-map", "[flatness]", "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (shapeProbe.ExitCode == 0)
            {
                double? edge = MetadataAverage(shapeProbe.CombinedOutput, "lavfi.signalstats.YAVG");
                double? flat = MetadataAverage(shapeProbe.CombinedOutput, "lavfi.blackframe.pblack");
                if (edge.HasValue)
                    edgeValues.Add(edge.Value / 255.0);

                if (flat.HasValue)
                    flatValues.Add(flat.Value / 100.0);
            }
            else
                errors.Add(shapeProbe.StandardError);

            ProcessResult sceneProbe = await runner.RunAsync(request.FFmpegPath,
            [
                .. commonArguments,
                "-vf", "scale=320:-2:flags=area,scdet=t=10,metadata=print:file=-",
                "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (sceneProbe.ExitCode == 0)
            {
                double? scene = MetadataAverage(sceneProbe.CombinedOutput, "lavfi.scd.score");
                sceneValues.Add((scene ?? 0) / 100.0);
            }
            else
                errors.Add(sceneProbe.StandardError);
        }

        double? edgeDensity = Average(edgeValues);
        double? temporalDifference = Average(temporalValues);
        double? sourceCompression = SourceCompression(media);
        double? uiPersistence = null;
        if (edgeDensity.HasValue && temporalDifference.HasValue)
        {
            uiPersistence = Math.Clamp(
                (1.0 - Math.Min(1.0, temporalDifference.Value * 4.0)) * 0.60 +
                edgeDensity.Value * 0.40,
                0.0,
                1.0);
        }

        ContentFeatures features = new()
        {
            Available = edgeValues.Count > 0 && flatValues.Count > 0 && entropyValues.Count > 0 &&
                        temporalValues.Count > 0 && noiseValues.Count > 0 && sceneValues.Count > 0,
            EdgeDensity = Rounded(edgeDensity),
            FlatAreaRatio = Rounded(Average(flatValues)),
            Entropy = Rounded(Average(entropyValues)),
            SceneCut = Rounded(Average(sceneValues)),
            TemporalDifference = Rounded(temporalDifference),
            Noise = Rounded(Average(noiseValues)),
            SourceCompression = Rounded(sourceCompression),
            UIPersistence = Rounded(uiPersistence),
            Error = errors.Count == 0 ? null : LastUsefulError(errors)
        };
        string contentClass = Classify(media, features);
        return new ContentAnalysis(contentClass, features);
    }

    public static string Classify(MediaInfo media, ContentFeatures features)
    {
        if (!features.Available)
            return "general";

        bool localizedHighFpsGameplay = media.Fps >= 50.0 && media.HasAudio &&
            AtLeast(features.EdgeDensity, 0.018) &&
            AtLeast(features.UIPersistence, 0.58) &&
            AtMost(features.TemporalDifference, 0.020) &&
            AtMost(features.SceneCut, 0.010) &&
            AtMost(features.Noise, 0.018) &&
            (AtLeast(features.TemporalDifference, 0.002) ||
             AtMost(features.FlatAreaRatio, 0.930));
        bool conventionalGameplay = media.Fps >= 50.0 && AtLeast(features.EdgeDensity, 0.045) &&
            AtMost(features.FlatAreaRatio, 0.910) &&
            AtLeast(features.UIPersistence, 0.45);
        if (localizedHighFpsGameplay || conventionalGameplay)
            return "gameplay";

        bool screenMotion = AtMost(features.TemporalDifference, 0.030) &&
            AtLeast(features.Noise, 0.012) &&
            AtLeast(features.EdgeDensity, 0.025);
        bool screenStatic = AtMost(features.TemporalDifference, 0.012) &&
            AtLeast(features.FlatAreaRatio, 0.940) &&
            AtMost(features.Entropy, 0.650);
        if (screenMotion || screenStatic)
            return "screen";

        if (AtLeast(features.Noise, 0.015) && AtLeast(features.TemporalDifference, 0.035))
            return "noisy_camera";

        if (AtLeast(features.FlatAreaRatio, 0.86) && AtLeast(features.EdgeDensity, 0.025) &&
            AtMost(features.Noise, 0.012))
            return "anime";

        if (media.HasAudio && AtMost(features.TemporalDifference, 0.012) && AtMost(features.Noise, 0.010))
            return "talking_head";

        return "general";
    }

    private static IReadOnlyList<double> SampleStarts(double durationSeconds)
    {
        if (durationSeconds <= 2.0)
            return [0.0];
        double middle = Math.Max(0.0, durationSeconds / 2.0 - 0.75);
        return middle < 0.25 ? [0.0] : [0.0, middle];
    }

    private static double? MetadataAverage(string text, string key)
    {
        string pattern = "(?m)^" + Regex.Escape(key) + @"=(?<value>-?\d+(?:\.\d+)?)\s*$";
        MatchCollection matches = Regex.Matches(text, pattern);
        if (matches.Count == 0)
            return null;
        return matches
            .Select(match => double.Parse(
                match.Groups["value"].Value,
                CultureInfo.InvariantCulture))
            .Average();
    }

    private static double? SourceCompression(MediaInfo media)
    {
        if (media.VideoBitrateKbps <= 0 || media.Width <= 0 || media.Height <= 0 || media.Fps <= 0)
            return null;
        double bitsPerPixelPerFrame = media.VideoBitrateKbps * 1000.0 /
            (media.Width * (double)media.Height * media.Fps);
        return Math.Clamp(1.0 - bitsPerPixelPerFrame / 0.12, 0.0, 1.0);
    }

    private static void AddIfAvailable(List<double> values, double? value)
    {
        if (value.HasValue)
            values.Add(value.Value);
    }

    private static double? Average(IReadOnlyList<double> values) => values.Count == 0 ? null : values.Average();
    private static double? Rounded(double? value) => value.HasValue ? Math.Round(value.Value, 3) : null;
    private static bool AtLeast(double? value, double threshold) => value.HasValue && value.Value >= threshold;
    private static bool AtMost(double? value, double threshold) => value.HasValue && value.Value <= threshold;
    private static string? LastUsefulError(IEnumerable<string> errors)
    {
        return errors
            .SelectMany(error => error.Split(
                ['\r', '\n'],
                StringSplitOptions.RemoveEmptyEntries))
            .LastOrDefault()
            ?.Trim();
    }
}
