using System.Globalization;
using System.Text.RegularExpressions;
using Byakuren.Execution;
using Byakuren.Models;

namespace Byakuren.Analysis;

public sealed class SampleWindowPlanner(ProcessRunner runner)
{
    public async Task<IReadOnlyList<SampleWindow>> CreateAsync(
        CompressionRequest request,
        MediaInfo media,
        string tempDirectory,
        int sampleSeconds,
        int maxSamples,
        CancellationToken cancellationToken)
    {
        int safeSampleSeconds = Math.Max(1, sampleSeconds);
        int safeMaxSamples = Math.Max(1, maxSamples);
        List<SampleWindow> candidates = FixedWindows(media.DurationSeconds, safeSampleSeconds, safeMaxSamples).ToList();
        if (request.SampleMode != SampleMode.Fixed && media.DurationSeconds > safeSampleSeconds + 2)
        {
            IReadOnlyList<SampleWindow> sceneWindows = await SceneWindowsAsync(request, media, safeSampleSeconds, cancellationToken).ConfigureAwait(false);
            candidates.AddRange(sceneWindows.Take(safeMaxSamples * 2));
        }

        List<SampleWindow> distinct = Deduplicate(candidates, safeSampleSeconds);
        List<SampleWindow> scored = [];
        foreach (SampleWindow candidate in distinct.Take(safeMaxSamples * 3))
        {
            double difficulty = await ScoreDifficultyAsync(request, media, tempDirectory, candidate, cancellationToken).ConfigureAwait(false);
            scored.Add(candidate with { DifficultyScore = difficulty });
        }

        return SelectRepresentative(scored, media.DurationSeconds, safeSampleSeconds, safeMaxSamples);
    }

    public static IReadOnlyList<SampleWindow> FixedWindows(double durationSeconds, int sampleSeconds, int maxSamples)
    {
        double sampleLength = Math.Min(sampleSeconds, Math.Max(0.25, durationSeconds));
        if (durationSeconds <= sampleLength + 2) return [new SampleWindow(0, sampleLength, "fixed", Tag: "whole")];
        double[] fractions = maxSamples switch
        {
            1 => [0.50],
            2 => [0.30, 0.70],
            3 => [0.18, 0.50, 0.82],
            4 => [0.12, 0.37, 0.63, 0.88],
            _ => [0.08, 0.28, 0.50, 0.72, 0.92]
        };
        double usableEnd = Math.Max(0, durationSeconds - sampleLength - 0.5);
        return fractions.Take(maxSamples)
            .Select(fraction => Math.Round(usableEnd * fraction, 3))
            .Distinct()
            .Select(start => new SampleWindow(start, sampleLength, "fixed", Tag: start < 0.1 ? "early" : start > durationSeconds - sampleLength * 1.4 ? "late" : "representative"))
            .ToArray();
    }

    private async Task<IReadOnlyList<SampleWindow>> SceneWindowsAsync(
        CompressionRequest request,
        MediaInfo media,
        int sampleSeconds,
        CancellationToken cancellationToken)
    {
        ProcessResult result = await runner.RunAsync(request.FFmpegPath,
        [
            "-hide_banner", "-i", media.Path,
            "-vf", "fps=6,scale=320:-2:flags=bicubic,scdet=threshold=10,metadata=print:file=-",
            "-an", "-f", "null", "-"
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0) return [];

        List<SampleWindow> windows = [];
        double? currentPts = null;
        foreach (string line in result.CombinedOutput.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            Match ptsMatch = Regex.Match(line, @"pts_time:(?<pts>-?\d+(?:\.\d+)?)");
            if (ptsMatch.Success)
            {
                currentPts = double.Parse(ptsMatch.Groups["pts"].Value, CultureInfo.InvariantCulture);
                continue;
            }
            Match scoreMatch = Regex.Match(line, @"lavfi\.scd\.score=(?<score>-?\d+(?:\.\d+)?)");
            if (!currentPts.HasValue || !scoreMatch.Success) continue;
            double score = double.Parse(scoreMatch.Groups["score"].Value, CultureInfo.InvariantCulture);
            if (score >= 0.10)
            {
                double latestStart = Math.Max(0, media.DurationSeconds - sampleSeconds - 0.1);
                double start = Math.Clamp(currentPts.Value - sampleSeconds / 2.0, 0, latestStart);
                windows.Add(new SampleWindow(Math.Round(start, 3), Math.Min(sampleSeconds, media.DurationSeconds), "scdet", score, Tag: "scene"));
            }
            currentPts = null;
        }
        return windows.OrderByDescending(window => window.SceneScore).ThenBy(window => window.StartSeconds).ToArray();
    }

    private async Task<double> ScoreDifficultyAsync(
        CompressionRequest request,
        MediaInfo media,
        string tempDirectory,
        SampleWindow window,
        CancellationToken cancellationToken)
    {
        string path = Path.Combine(tempDirectory, $"difficulty-{Guid.NewGuid():N}.mp4");
        double duration = Math.Min(2, window.DurationSeconds);
        int width = media.Width >= 854 ? 320 : Math.Min(media.Width, 240);
        int fps = media.Fps > 24.5 ? 18 : Math.Max(12, (int)Math.Round(media.Fps));
        ProcessResult result = await runner.RunAsync(request.FFmpegPath,
        [
            "-y", "-ss", Number(window.StartSeconds), "-t", Number(duration), "-i", media.Path,
            "-vf", $"setsar=1,scale={width}:-2:flags=bicubic,fps={fps}", "-an",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "30", path
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0 || !File.Exists(path)) return 0;
        long bytes = new FileInfo(path).Length;
        TryDelete(path);
        return Math.Round(bytes * 8.0 / Math.Max(0.25, duration) / 1000.0, 2);
    }

    private static List<SampleWindow> Deduplicate(IEnumerable<SampleWindow> windows, int sampleSeconds)
    {
        List<SampleWindow> distinct = [];
        foreach (SampleWindow candidate in windows.OrderBy(window => window.StartSeconds))
        {
            int existingIndex = distinct.FindIndex(window => Math.Abs(window.StartSeconds - candidate.StartSeconds) < sampleSeconds * 0.60);
            if (existingIndex < 0) distinct.Add(candidate);
            else if (candidate.SceneScore > distinct[existingIndex].SceneScore) distinct[existingIndex] = candidate;
        }
        return distinct;
    }

    private static IReadOnlyList<SampleWindow> SelectRepresentative(
        IReadOnlyList<SampleWindow> candidates,
        double durationSeconds,
        int sampleSeconds,
        int maxSamples)
    {
        if (candidates.Count <= maxSamples) return candidates.OrderBy(window => window.StartSeconds).ToArray();
        List<SampleWindow> selected = [];
        AddUnique(selected, candidates.OrderBy(window => window.StartSeconds).First(), sampleSeconds);
        if (maxSamples > 1) AddUnique(selected, candidates.OrderBy(window => window.StartSeconds).Last(), sampleSeconds);
        if (maxSamples > 2)
        {
            double midpoint = Math.Max(0, (durationSeconds - sampleSeconds) / 2.0);
            AddUnique(selected, candidates.OrderBy(window => Math.Abs(window.StartSeconds - midpoint)).First(), sampleSeconds);
        }
        foreach (SampleWindow candidate in candidates.OrderByDescending(window => window.DifficultyScore + window.SceneScore * 150))
        {
            if (selected.Count >= maxSamples) break;
            AddUnique(selected, candidate, sampleSeconds);
        }
        return selected.OrderBy(window => window.StartSeconds).Take(maxSamples).ToArray();
    }

    private static void AddUnique(List<SampleWindow> selected, SampleWindow candidate, int sampleSeconds)
    {
        if (selected.All(window => Math.Abs(window.StartSeconds - candidate.StartSeconds) >= sampleSeconds * 0.50)) selected.Add(candidate);
    }

    private static string Number(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
    private static void TryDelete(string path) { try { File.Delete(path); } catch { } }
}
