using Byakuren.Models;

namespace Byakuren.Analysis;

public sealed record ContentFusionResult(
    string ContentClass,
    IReadOnlyList<ContentClassScore> Scores,
    double Confidence,
    double ConfidenceMargin,
    string ConfidenceLevel,
    IReadOnlyList<string> Alternatives,
    string DecisionReason);

public static class ContentScoreFusion
{
    private const double AlternativeMargin = 0.10;

    public static ContentFusionResult Fuse(
        IReadOnlyList<ContentClassScore> heuristicScores,
        IReadOnlyList<ContentSampleEvidence> samples,
        AnimeModelEvidence animeModel)
    {
        if (heuristicScores.Count == 0)
        {
            ContentClassScore general = new("general", 1, ["classifier-unavailable"]);
            return new ContentFusionResult(
                "general",
                [general],
                0,
                1,
                "low",
                [],
                "classifier-unavailable");
        }

        ContentSampleEvidence[] includedSamples = samples
            .Where(sample => sample.IncludedInAggregate)
            .ToArray();
        bool modelAvailable = animeModel.Available &&
            animeModel.AnimeProbability.HasValue &&
            animeModel.RealProbability.HasValue;
        List<ContentClassScore> fused = [];

        foreach (ContentClassScore heuristic in heuristicScores)
        {
            double sampleSupport = SampleSupport(
                heuristic.ContentClass,
                includedSamples,
                heuristic.Score);
            double score;
            List<string> evidence = heuristic.Evidence.ToList();
            if (modelAvailable)
            {
                double modelSupport = heuristic.ContentClass == ContentClassSelection.Anime
                    ? animeModel.AnimeProbability!.Value
                    : animeModel.RealProbability!.Value;
                score = heuristic.Score * 0.65 +
                    sampleSupport * 0.15 +
                    modelSupport * 0.20;
                if (modelSupport >= 0.70)
                {
                    evidence.Add(heuristic.ContentClass == ContentClassSelection.Anime
                        ? "anime-model-support"
                        : "real-model-support");
                }
            }
            else
            {
                score = heuristic.Score * 0.80 + sampleSupport * 0.20;
                evidence.Add("model-unavailable");
            }

            if (sampleSupport >= 0.65)
                evidence.Add("cross-window-support");
            fused.Add(new ContentClassScore(
                heuristic.ContentClass,
                Math.Round(Math.Clamp(score, 0, 1), 3),
                evidence.Distinct(StringComparer.Ordinal).ToArray()));
        }

        ContentClassScore[] ranked = fused
            .OrderByDescending(score => score.Score)
            .ThenBy(score => score.ContentClass, StringComparer.Ordinal)
            .ToArray();
        double margin = ranked.Length < 2
            ? ranked[0].Score
            : Math.Round(ranked[0].Score - ranked[1].Score, 3);
        double confidence = Math.Round(
            ranked[0].Score *
            (0.55 + 0.45 * Math.Clamp(margin / 0.25, 0, 1)),
            3);
        string confidenceLevel = ConfidenceLevel(confidence, margin);
        List<string> alternatives = ranked
            .Skip(1)
            .Where(score => ranked[0].Score - score.Score <= AlternativeMargin)
            .Take(2)
            .Select(score => score.ContentClass)
            .ToList();
        if (confidenceLevel == "low" && alternatives.Count == 0 && ranked.Length > 1)
            alternatives.Add(ranked[1].ContentClass);
        string decisionReason = modelAvailable
            ? "heuristic+window+anime-model"
            : "heuristic+window:model-unavailable";

        return new ContentFusionResult(
            ranked[0].ContentClass,
            ranked,
            confidence,
            margin,
            confidenceLevel,
            alternatives,
            decisionReason);
    }

    private static double SampleSupport(
        string contentClass,
        IReadOnlyList<ContentSampleEvidence> samples,
        double fallback)
    {
        if (samples.Count == 0)
            return fallback;

        double[] scores = samples
            .Select(sample => sample.HeuristicScores
                .FirstOrDefault(score => score.ContentClass == contentClass)
                ?.Score)
            .Where(score => score.HasValue)
            .Select(score => score!.Value)
            .Order()
            .ToArray();
        if (scores.Length == 0)
            return fallback;

        double median = Median(scores);
        double winnerRate = samples.Count(sample =>
            sample.HeuristicScores.Count > 0 &&
            sample.HeuristicScores[0].ContentClass == contentClass) /
            (double)samples.Count;
        return median * 0.70 + winnerRate * 0.30;
    }

    private static double Median(IReadOnlyList<double> sorted)
    {
        int middle = sorted.Count / 2;
        return sorted.Count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2.0
            : sorted[middle];
    }

    private static string ConfidenceLevel(double confidence, double margin)
    {
        if (confidence >= 0.75 && margin >= 0.12)
            return "high";
        if (confidence >= 0.55 && margin >= 0.06)
            return "medium";
        return "low";
    }
}
