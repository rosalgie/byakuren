using System.Globalization;
using Byakuren.Execution;
using Byakuren.IO;
using Byakuren.Models;

namespace Byakuren.Analysis;

public sealed class ComplexityAnalyzer(ProcessRunner runner)
{
    public async Task<ComplexityAnalysis> AnalyzeAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<SampleWindow> windows,
        string tempDirectory,
        CancellationToken cancellationToken)
    {
        int probeWidth;
        if (media.Width >= 1280)
            probeWidth = 480;
        else if (media.Width >= 854)
            probeWidth = 426;
        else
            probeWidth = Math.Min(media.Width, 360);

        int detailFps = media.Fps > 30.5 ? 24 : Math.Max(12, (int)Math.Round(media.Fps));
        int motionFps = Math.Min(60, Math.Max(detailFps, (int)Math.Round(media.Fps)));
        int crf = request.Mode switch
        {
            CompressionMode.Fast => 32,
            CompressionMode.Balanced => 30,
            _ => 28
        };
        string preset = request.Mode switch
        {
            CompressionMode.Fast => "superfast",
            CompressionMode.Balanced => "veryfast",
            _ => "fast"
        };

        IReadOnlyList<double> detailValues = await ProbeSeriesAsync(
            request,
            media,
            windows,
            tempDirectory,
            probeWidth,
            detailFps,
            crf,
            preset,
            "detail",
            cancellationToken).ConfigureAwait(false);

        IReadOnlyList<double> motionValues = detailValues;
        if (motionFps > detailFps)
        {
            motionValues = await ProbeSeriesAsync(
                request,
                media,
                windows,
                tempDirectory,
                probeWidth,
                motionFps,
                crf,
                preset,
                "motion",
                cancellationToken).ConfigureAwait(false);
        }

        double detailAverage = Average(detailValues);
        double peakDetail = Percentile(detailValues, 0.80);
        double motionAverage = Average(motionValues);
        double motionRatio = motionAverage / Math.Max(1, detailAverage);
        double fpsRatio = motionFps / (double)Math.Max(1, detailFps);
        double motionNormalized = motionFps > detailFps ? motionRatio / fpsRatio : 0.75;

        return new ComplexityAnalysis
        {
            DetailBucket = DetailBucket(peakDetail),
            MotionBucket = MotionBucket(motionRatio, motionNormalized, media.Fps, DetailBucket(peakDetail)),
            DetailKbps = Math.Round(detailAverage, 2),
            PeakDetailKbps = Math.Round(peakDetail, 2),
            MotionKbps = Math.Round(motionAverage, 2),
            MotionRatio = Math.Round(motionRatio, 3),
            MotionNormalized = Math.Round(motionNormalized, 3),
            DetailSpread = Math.Round(Spread(detailValues), 3),
            MotionSpread = Math.Round(Spread(motionValues), 3),
            SamplingMode = windows.Any(window => window.Source != "fixed") ? "sceneaware" : "fixed",
            Windows = windows
        };
    }

    private async Task<IReadOnlyList<double>> ProbeSeriesAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<SampleWindow> windows,
        string tempDirectory,
        int width,
        int fps,
        int crf,
        string preset,
        string name,
        CancellationToken cancellationToken)
    {
        List<double> values = [];
        int index = 0;
        foreach (SampleWindow window in windows)
        {
            string path = Path.Combine(tempDirectory, $"probe-{name}-{index++}.mp4");
            try
            {
                ProcessResult result = await runner.RunAsync(request.FFmpegPath,
                [
                    "-y", "-ss", Number(window.StartSeconds), "-t", Number(window.DurationSeconds), "-i", media.Path,
                    "-vf", $"setsar=1,scale={width}:-2:flags=bicubic,fps={fps}", "-an",
                    "-c:v", "libx264", "-preset", preset, "-crf", crf.ToString(CultureInfo.InvariantCulture), path
                ], cancellationToken).ConfigureAwait(false);
                if (result.ExitCode == 0 && File.Exists(path))
                {
                    long bytes = new FileInfo(path).Length;
                    values.Add(bytes * 8.0 / Math.Max(0.25, window.DurationSeconds) / 1000.0);
                }
            }
            finally
            {
                FileSystemCleanup.DeleteFile(path, runner.ReportWarning);
            }
        }
        return values;
    }

    private static string DetailBucket(double kbps) => kbps switch
    {
        < 80 => "VeryLow",
        < 160 => "Low",
        < 320 => "Medium",
        < 650 => "High",
        _ => "VeryHigh"
    };

    private static string MotionBucket(
        double ratio,
        double normalized,
        double fps,
        string fallback)
    {
        if (fps <= 30.5)
            return fallback;

        return normalized switch
        {
            < 0.56 => "VeryLow",
            < 0.72 => "Low",
            < 0.92 => "Medium",
            < 1.12 => "High",
            _ when ratio > 1.8 => "VeryHigh",
            _ => "High"
        };
    }

    private static double Average(IReadOnlyList<double> values) => values.Count == 0 ? 0 : values.Average();

    private static double Spread(IReadOnlyList<double> values)
    {
        if (values.Count < 2)
            return 0;

        return (values.Max() - values.Min()) / Math.Max(1, values.Average());
    }

    private static double Percentile(IReadOnlyList<double> values, double percentile)
    {
        if (values.Count == 0)
            return 0;
        double[] sorted = values.OrderBy(value => value).ToArray();
        int index = Math.Clamp((int)Math.Ceiling(sorted.Length * percentile) - 1, 0, sorted.Length - 1);
        return sorted[index];
    }
    private static string Number(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
}
