using System.Globalization;
using System.Text.RegularExpressions;
using Byakuren.Execution;
using Byakuren.Models;

namespace Byakuren.Analysis;

public sealed class ContentAnalyzer(ProcessRunner runner)
{
    public const double DarkLuminanceThreshold = 0.18;
    private readonly AnimeModelClassifier _animeModelClassifier = new(runner);

    public async Task<ContentAnalysis> AnalyzeAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<SampleWindow> representativeWindows,
        string tempDirectory,
        CancellationToken cancellationToken)
    {
        List<ContentSampleEvidence> samples = [];
        List<string> errors = [];
        IReadOnlyList<SampleWindow> contentWindows = SampleWindowPlanner.ContentWindows(
            media.DurationSeconds,
            representativeWindows);

        int sampleIndex = 0;
        foreach (SampleWindow window in contentWindows)
        {
            double startSeconds = window.StartSeconds;
            double durationSeconds = Math.Min(
                window.DurationSeconds,
                media.DurationSeconds - startSeconds);
            if (durationSeconds <= 0)
                continue;
            List<string> sampleErrors = [];
            double? luminance = null;
            double? entropy = null;
            double? temporalDifference = null;
            double? temporalOutlierRatio = null;
            double? edgeDensity = null;
            double? flatAreaRatio = null;
            double? sceneCut = null;
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
                luminance = MetadataAverage(baseProbe.CombinedOutput, "lavfi.signalstats.YAVG");
                if (luminance.HasValue)
                    luminance /= 255.0;

                entropy = MetadataAverage(
                    baseProbe.CombinedOutput,
                    "lavfi.entropy.normalized_entropy.normal.Y");

                temporalDifference = MetadataAverage(
                    baseProbe.CombinedOutput,
                    "lavfi.signalstats.YDIF");
                if (temporalDifference.HasValue)
                    temporalDifference /= 255.0;

                temporalOutlierRatio = MetadataAverage(
                    baseProbe.CombinedOutput,
                    "lavfi.signalstats.TOUT");
            }
            else
                sampleErrors.Add(baseProbe.StandardError);

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
                edgeDensity = MetadataAverage(shapeProbe.CombinedOutput, "lavfi.signalstats.YAVG");
                flatAreaRatio = MetadataAverage(shapeProbe.CombinedOutput, "lavfi.blackframe.pblack");
                if (edgeDensity.HasValue)
                    edgeDensity /= 255.0;

                if (flatAreaRatio.HasValue)
                    flatAreaRatio /= 100.0;
            }
            else
                sampleErrors.Add(shapeProbe.StandardError);

            ProcessResult sceneProbe = await runner.RunAsync(request.FFmpegPath,
            [
                .. commonArguments,
                "-vf", "scale=320:-2:flags=area,scdet=t=10,metadata=print:file=-",
                "-f", "null", "-"
            ], cancellationToken).ConfigureAwait(false);
            if (sceneProbe.ExitCode == 0)
            {
                sceneCut = (MetadataAverage(
                    sceneProbe.CombinedOutput,
                    "lavfi.scd.score") ?? 0) / 100.0;
            }
            else
                sampleErrors.Add(sceneProbe.StandardError);

            errors.AddRange(sampleErrors);
            double? uiPersistence = UIPersistence(edgeDensity, temporalDifference);
            ContentFeatures sampleFeatures = new()
            {
                Available = edgeDensity.HasValue && flatAreaRatio.HasValue &&
                    entropy.HasValue && temporalDifference.HasValue &&
                    temporalOutlierRatio.HasValue && sceneCut.HasValue,
                LuminanceMean = Rounded(luminance),
                EdgeDensity = Rounded(edgeDensity),
                FlatAreaRatio = Rounded(flatAreaRatio),
                Entropy = Rounded(entropy),
                SceneCut = Rounded(sceneCut),
                TemporalDifference = Rounded(temporalDifference),
                TemporalOutlierRatio = Rounded(temporalOutlierRatio),
                SourceCompression = Rounded(SourceCompression(media)),
                UIPersistence = Rounded(uiPersistence),
                Error = sampleErrors.Count == 0 ? null : LastUsefulError(sampleErrors)
            };
            string? exclusionReason = SampleExclusionReason(sampleFeatures, window.Tag);
            IReadOnlyList<ContentClassScore> sampleScores = ScoreClasses(media, sampleFeatures);
            IReadOnlyList<ContentTraitScore> sampleTraits = ScoreTraits(sampleFeatures);
            samples.Add(new ContentSampleEvidence(
                sampleIndex++,
                Math.Round(startSeconds, 3),
                Math.Round(durationSeconds, 3),
                window.Source,
                window.Tag,
                exclusionReason is null,
                exclusionReason,
                sampleFeatures,
                sampleScores,
                sampleTraits));
        }

        ContentSampleEvidence[] includedSamples = samples
            .Where(sample => sample.IncludedInAggregate)
            .ToArray();
        if (includedSamples.Length == 0)
        {
            samples = samples
                .Select(sample => sample.Features.Available
                    ? sample with { IncludedInAggregate = true, ExclusionReason = null }
                    : sample)
                .ToList();
            includedSamples = samples
                .Where(sample => sample.IncludedInAggregate)
                .ToArray();
        }

        double? aggregateEdgeDensity = Aggregate(
            includedSamples,
            features => features.EdgeDensity);
        double? aggregateTemporalDifference = Aggregate(
            includedSamples,
            features => features.TemporalDifference);
        double? sourceCompression = SourceCompression(media);
        double? aggregateUiPersistence = UIPersistence(
            aggregateEdgeDensity,
            aggregateTemporalDifference);

        ContentFeatures features = new()
        {
            Available = includedSamples.Length > 0,
            LuminanceMean = Rounded(Aggregate(
                includedSamples,
                sampleFeatures => sampleFeatures.LuminanceMean)),
            EdgeDensity = Rounded(aggregateEdgeDensity),
            FlatAreaRatio = Rounded(Aggregate(
                includedSamples,
                sampleFeatures => sampleFeatures.FlatAreaRatio)),
            Entropy = Rounded(Aggregate(
                includedSamples,
                sampleFeatures => sampleFeatures.Entropy)),
            SceneCut = Rounded(Aggregate(
                includedSamples,
                sampleFeatures => sampleFeatures.SceneCut,
                0.75)),
            TemporalDifference = Rounded(aggregateTemporalDifference),
            TemporalOutlierRatio = Rounded(Aggregate(
                includedSamples,
                sampleFeatures => sampleFeatures.TemporalOutlierRatio)),
            SourceCompression = Rounded(sourceCompression),
            UIPersistence = Rounded(aggregateUiPersistence),
            Error = errors.Count == 0 ? null : LastUsefulError(errors)
        };
        IReadOnlyList<ContentClassScore> scores = ScoreClasses(media, features);
        IReadOnlyList<ContentTraitScore> traitScores = ScoreTraits(features);
        AnimeModelEvidence animeModel = await _animeModelClassifier
            .AnalyzeAsync(
                request,
                media,
                samples,
                tempDirectory,
                cancellationToken)
            .ConfigureAwait(false);
        ContentFusionResult fusion = ContentScoreFusion.Fuse(scores, samples, animeModel);
        return new ContentAnalysis(fusion.ContentClass, features)
        {
            Traits = ClassifyTraits(traitScores),
            Samples = samples,
            HeuristicScores = scores,
            HeuristicConfidenceMargin = ScoreMargin(scores),
            TraitScores = traitScores,
            AnimeModel = animeModel,
            Scores = fusion.Scores,
            Confidence = fusion.Confidence,
            ConfidenceMargin = fusion.ConfidenceMargin,
            ConfidenceLevel = fusion.ConfidenceLevel,
            Alternatives = fusion.Alternatives,
            DecisionReason = fusion.DecisionReason,
            Source = ContentAnalysis.HybridSource
        };
    }

    public static IReadOnlyList<ContentTraitScore> ScoreTraits(ContentFeatures features)
    {
        if (!features.Available)
            return [];

        List<ContentTraitScore> scores =
        [
            WeightedTrait("dark",
                ("low-luminance", 1.00, Falling(features.LuminanceMean, 0.08, 0.28))),
            WeightedTrait("flat_color",
                ("large-flat-regions", 0.80, Rising(features.FlatAreaRatio, 0.78, 0.96)),
                ("bounded-entropy", 0.20, Falling(features.Entropy, 0.50, 0.82))),
            WeightedTrait("line_art",
                ("defined-edges", 0.55, Rising(features.EdgeDensity, 0.018, 0.060)),
                ("flat-backgrounds", 0.30, Rising(features.FlatAreaRatio, 0.72, 0.94)),
                ("clean-temporal-signal", 0.15, Falling(features.TemporalOutlierRatio, 0.010, 0.030))),
            WeightedTrait("persistent_ui",
                ("persistent-layout", 0.45, Rising(features.UIPersistence, 0.48, 0.72)),
                ("defined-edges", 0.25, Rising(features.EdgeDensity, 0.025, 0.065)),
                ("limited-motion", 0.20, Falling(features.TemporalDifference, 0.008, 0.040)),
                ("stable-scenes", 0.10, Falling(features.SceneCut, 0.010, 0.060))),
            WeightedTrait("text_heavy",
                ("dense-edges", 0.35, Rising(features.EdgeDensity, 0.030, 0.075)),
                ("very-flat-regions", 0.25, Rising(features.FlatAreaRatio, 0.92, 0.985)),
                ("low-entropy-layout", 0.25, Falling(features.Entropy, 0.35, 0.68)),
                ("static-layout", 0.15, Falling(features.TemporalDifference, 0.006, 0.025))),
            WeightedTrait("grain_or_noise",
                ("temporal-outliers", 0.45, Rising(features.TemporalOutlierRatio, 0.008, 0.035)),
                ("texture-entropy", 0.25, Rising(features.Entropy, 0.45, 0.82)),
                ("temporal-variation", 0.20, Rising(features.TemporalDifference, 0.012, 0.060)),
                ("non-flat-surface", 0.10, Falling(features.FlatAreaRatio, 0.75, 0.95))),
            WeightedTrait("high_motion",
                ("temporal-difference", 0.70, Rising(features.TemporalDifference, 0.015, 0.060)),
                ("scene-change", 0.30, Rising(features.SceneCut, 0.010, 0.070))),
            WeightedTrait("high_scene_change",
                ("scene-change", 0.70, Rising(features.SceneCut, 0.010, 0.070)),
                ("temporal-difference", 0.30, Rising(features.TemporalDifference, 0.020, 0.070))),
            WeightedTrait("compressed_source",
                ("source-bpppf", 0.75, Rising(features.SourceCompression, 0.35, 0.85)),
                ("texture-entropy", 0.25, Rising(features.Entropy, 0.45, 0.82)))
        ];

        return scores
            .OrderByDescending(score => score.Score)
            .ThenBy(score => score.Trait, StringComparer.Ordinal)
            .ToArray();
    }

    public static IReadOnlyList<ContentClassScore> ScoreClasses(
        MediaInfo media,
        ContentFeatures features)
    {
        if (!features.Available)
        {
            return
            [
                new ContentClassScore("general", 1, ["features-unavailable"])
            ];
        }

        double staticScreenPattern = AverageSignals(
            Rising(features.FlatAreaRatio, 0.95, 0.985),
            Falling(features.Entropy, 0.35, 0.62),
            Falling(features.TemporalDifference, 0.004, 0.015));
        double motionScreenPattern = AverageSignals(
            Rising(features.TemporalOutlierRatio, 0.010, 0.028),
            Rising(features.EdgeDensity, 0.022, 0.060),
            Falling(features.TemporalDifference, 0.012, 0.045));
        double screenSpecificPattern = Math.Max(staticScreenPattern, motionScreenPattern);

        List<ContentClassScore> scores =
        [
            WeightedScore("gameplay",
                ("high-frame-rate", 0.30, Rising(media.Fps, 45, 60)),
                ("persistent-ui", 0.20, Rising(features.UIPersistence, 0.48, 0.70)),
                ("strong-edges", 0.18, Rising(features.EdgeDensity, 0.025, 0.065)),
                ("active-motion", 0.14, Rising(features.TemporalDifference, 0.003, 0.030)),
                ("stable-scenes", 0.08, Falling(features.SceneCut, 0.010, 0.060)),
                ("audio-present", 0.10, media.HasAudio ? 1 : 0)),
            WeightedScore("screen",
                ("screen-specific-pattern", 0.30, screenSpecificPattern),
                ("persistent-layout", 0.22, Rising(features.UIPersistence, 0.48, 0.72)),
                ("defined-edges", 0.18, Rising(features.EdgeDensity, 0.022, 0.060)),
                ("limited-motion", 0.15, Falling(features.TemporalDifference, 0.008, 0.040)),
                ("stable-scenes", 0.15, Falling(features.SceneCut, 0.010, 0.060))),
            WeightedScore("noisy_camera",
                ("temporal-outliers", 0.32, Rising(features.TemporalOutlierRatio, 0.010, 0.040)),
                ("camera-motion", 0.28, Rising(features.TemporalDifference, 0.020, 0.080)),
                ("texture-entropy", 0.15, Rising(features.Entropy, 0.45, 0.80)),
                ("non-flat-surface", 0.15, Falling(features.FlatAreaRatio, 0.75, 0.95)),
                ("scene-variation", 0.10, Rising(features.SceneCut, 0.005, 0.050))),
            WeightedScore("anime",
                ("flat-color-regions", 0.26, Rising(features.FlatAreaRatio, 0.82, 0.95)),
                ("line-art-edges", 0.18, Rising(features.EdgeDensity, 0.018, 0.055)),
                ("clean-temporal-signal", 0.18, Falling(features.TemporalOutlierRatio, 0.008, 0.025)),
                ("stable-drawing", 0.10, Falling(features.TemporalDifference, 0.004, 0.025)),
                ("bounded-entropy", 0.10, Centered(features.Entropy, 0.48, 0.30)),
                ("not-static-layout", 0.18, 1 - staticScreenPattern)),
            WeightedScore("talking_head",
                ("audio-present", 0.25, media.HasAudio ? 1 : 0),
                ("limited-motion", 0.27, Falling(features.TemporalDifference, 0.006, 0.030)),
                ("clean-temporal-signal", 0.18, Falling(features.TemporalOutlierRatio, 0.008, 0.025)),
                ("natural-surface", 0.18, Falling(features.FlatAreaRatio, 0.80, 0.96)),
                ("moderate-edges", 0.12, Centered(features.EdgeDensity, 0.035, 0.030))),
            WeightedScore("general", 0.22,
                ("natural-surface", 0.22, Falling(features.FlatAreaRatio, 0.80, 0.97)),
                ("texture-entropy", 0.18, Rising(features.Entropy, 0.35, 0.75)),
                ("visible-motion", 0.16, Rising(features.TemporalDifference, 0.010, 0.060)),
                ("non-persistent-layout", 0.12, Falling(features.UIPersistence, 0.40, 0.75)),
                ("conventional-frame-rate", 0.10, Falling(media.Fps, 45, 60)))
        ];

        return scores
            .OrderByDescending(score => score.Score)
            .ThenBy(score => score.ContentClass, StringComparer.Ordinal)
            .ToArray();
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

    private static double? Aggregate(
        IReadOnlyList<ContentSampleEvidence> samples,
        Func<ContentFeatures, double?> selector,
        double percentile = 0.5)
    {
        double[] values = samples
            .Select(sample => selector(sample.Features))
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .Order()
            .ToArray();
        if (values.Length == 0)
            return null;
        double position = Math.Clamp(percentile, 0, 1) * (values.Length - 1);
        int lower = (int)Math.Floor(position);
        int upper = (int)Math.Ceiling(position);
        if (lower == upper)
            return values[lower];
        double fraction = position - lower;
        return values[lower] + (values[upper] - values[lower]) * fraction;
    }

    private static ContentClassScore WeightedScore(
        string contentClass,
        params (string Name, double Weight, double Signal)[] components)
    {
        return WeightedScore(contentClass, 0, components);
    }

    private static ContentClassScore WeightedScore(
        string contentClass,
        double bias,
        params (string Name, double Weight, double Signal)[] components)
    {
        double score = bias + components.Sum(component =>
            component.Weight * Math.Clamp(component.Signal, 0, 1));
        string[] evidence = components
            .Where(component => component.Signal >= 0.55)
            .OrderByDescending(component => component.Weight * component.Signal)
            .Select(component => component.Name)
            .ToArray();
        return new ContentClassScore(contentClass, Math.Round(Math.Clamp(score, 0, 1), 3), evidence);
    }

    private static ContentTraitScore WeightedTrait(
        string trait,
        params (string Name, double Weight, double Signal)[] components)
    {
        double score = components.Sum(component =>
            component.Weight * Math.Clamp(component.Signal, 0, 1));
        string[] evidence = components
            .Where(component => component.Signal >= 0.55)
            .OrderByDescending(component => component.Weight * component.Signal)
            .Select(component => component.Name)
            .ToArray();
        return new ContentTraitScore(trait, Math.Round(Math.Clamp(score, 0, 1), 3), evidence);
    }

    private static IReadOnlyList<string> ClassifyTraits(
        IReadOnlyList<ContentTraitScore> scores)
    {
        return scores
            .Where(score => score.Score >= 0.65)
            .Select(score => score.Trait)
            .Order(StringComparer.Ordinal)
            .ToArray();
    }

    private static double ScoreMargin(IReadOnlyList<ContentClassScore> scores)
    {
        return scores.Count < 2 ? scores.FirstOrDefault()?.Score ?? 0 : Math.Round(
            scores[0].Score - scores[1].Score,
            3);
    }

    private static double Rising(double? value, double low, double high)
    {
        if (!value.HasValue)
            return 0;
        return Math.Clamp((value.Value - low) / Math.Max(0.000001, high - low), 0, 1);
    }

    private static double Falling(double? value, double low, double high)
    {
        if (!value.HasValue)
            return 0;
        return 1 - Rising(value, low, high);
    }

    private static double Centered(double? value, double center, double radius)
    {
        if (!value.HasValue)
            return 0;
        return Math.Clamp(1 - Math.Abs(value.Value - center) / Math.Max(0.000001, radius), 0, 1);
    }

    private static double AverageSignals(params double[] values)
    {
        return values.Length == 0 ? 0 : values.Average();
    }

    private static double? Rounded(double? value) => value.HasValue ? Math.Round(value.Value, 3) : null;
    private static double? UIPersistence(double? edgeDensity, double? temporalDifference)
    {
        if (!edgeDensity.HasValue || !temporalDifference.HasValue)
            return null;
        return Math.Clamp(
            (1.0 - Math.Min(1.0, temporalDifference.Value * 4.0)) * 0.60 +
            edgeDensity.Value * 0.40,
            0.0,
            1.0);
    }
    private static string? SampleExclusionReason(ContentFeatures features, string tag)
    {
        if (!features.Available)
            return "probe-unavailable";
        bool lowInformation = AtMost(features.Entropy, 0.30);
        if (lowInformation && AtMost(features.LuminanceMean, 0.04))
            return "black-or-fade";
        if (lowInformation && AtLeast(features.LuminanceMean, 0.96))
            return "white-or-fade";
        if (AtLeast(features.SceneCut, 0.08))
            return "transition-heavy";
        bool endingWindow = tag.Contains("ending", StringComparison.Ordinal);
        if (endingWindow &&
            AtMost(features.TemporalDifference, 0.004) &&
            AtLeast(features.EdgeDensity, 0.045))
        {
            return "static-ending-card";
        }
        return null;
    }
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
