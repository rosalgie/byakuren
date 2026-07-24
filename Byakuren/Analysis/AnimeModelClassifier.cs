using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using Byakuren.Execution;
using Byakuren.IO;
using Byakuren.Models;
using Microsoft.ML.OnnxRuntime;

namespace Byakuren.Analysis;

public sealed class AnimeModelClassifier(ProcessRunner runner)
{
    public const string ModelId = "deepghs/anime_real_cls:mobilenetv3_v0_dist";
    public const string ModelRevision = "9194b269b78b83476bfefa99e3581f81dfb29407";
    private const string ModelResourceName = "Byakuren.Assets.Models.AnimeReal.model.onnx";
    private const string ModelSha256 =
        "e393dfc6731844cf3c7be44111d481f7cff904a1519997dc24cb2de2439f915b";
    private const int InputSize = 384;
    private const int InputBytes = InputSize * InputSize * 3;
    private const int MaxFrames = 5;

    public async Task<AnimeModelEvidence> AnalyzeAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<ContentSampleEvidence> samples,
        string tempDirectory,
        CancellationToken cancellationToken)
    {
        try
        {
            byte[] modelBytes = LoadModel();
            using SessionOptions options = new()
            {
                GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
                LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR
            };
            using InferenceSession session = new(modelBytes, options);
            IReadOnlyList<ContentSampleEvidence> selected = SelectFrames(samples);
            List<AnimeModelFrameEvidence> frames = [];
            List<string> errors = [];

            foreach (ContentSampleEvidence sample in selected)
            {
                double offsetSeconds = Math.Min(
                    Math.Max(0, media.DurationSeconds - 0.05),
                    sample.StartSeconds + sample.DurationSeconds / 2.0);
                byte[]? rgb = await ExtractFrameAsync(
                    request,
                    media,
                    offsetSeconds,
                    tempDirectory,
                    cancellationToken).ConfigureAwait(false);
                if (rgb is null)
                {
                    errors.Add($"frame extraction failed at {offsetSeconds:0.###}s");
                    continue;
                }

                (double anime, double real) = Run(session, rgb);
                frames.Add(new AnimeModelFrameEvidence(
                    sample.Index,
                    Math.Round(offsetSeconds, 3),
                    Math.Round(anime, 4),
                    Math.Round(real, 4)));
            }

            if (frames.Count == 0)
            {
                return Unavailable(errors.LastOrDefault() ?? "no model frames were available");
            }

            double animeProbability = Median(frames.Select(frame => frame.AnimeProbability));
            double realProbability = Median(frames.Select(frame => frame.RealProbability));
            return new AnimeModelEvidence
            {
                Available = true,
                Model = ModelId,
                Revision = ModelRevision,
                AnimeProbability = Math.Round(animeProbability, 4),
                RealProbability = Math.Round(realProbability, 4),
                Frames = frames,
                Error = errors.Count == 0 ? null : errors[^1]
            };
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return Unavailable(exception.Message);
        }
    }

    private async Task<byte[]?> ExtractFrameAsync(
        CompressionRequest request,
        MediaInfo media,
        double offsetSeconds,
        string tempDirectory,
        CancellationToken cancellationToken)
    {
        string path = Path.Combine(tempDirectory, $"anime-model-{Guid.NewGuid():N}.rgb");
        try
        {
            ProcessResult result = await runner.RunAsync(request.FFmpegPath,
            [
                "-y", "-hide_banner", "-loglevel", "error",
                "-ss", Number(offsetSeconds),
                "-i", media.Path,
                "-frames:v", "1",
                "-vf", $"scale={InputSize}:{InputSize}:flags=bicubic,format=rgb24",
                "-an", "-f", "rawvideo", path
            ], cancellationToken).ConfigureAwait(false);
            if (result.ExitCode != 0 || !File.Exists(path))
                return null;

            byte[] bytes = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
            return bytes.Length == InputBytes ? bytes : null;
        }
        finally
        {
            FileSystemCleanup.DeleteFile(path, runner.ReportWarning);
        }
    }

    private static (double Anime, double Real) Run(InferenceSession session, byte[] rgb)
    {
        float[] inputData = new float[InputBytes];
        int planeSize = InputSize * InputSize;
        for (int pixel = 0; pixel < planeSize; pixel++)
        {
            int source = pixel * 3;
            inputData[pixel] = Normalize(rgb[source]);
            inputData[planeSize + pixel] = Normalize(rgb[source + 1]);
            inputData[planeSize * 2 + pixel] = Normalize(rgb[source + 2]);
        }

        using OrtValue input = OrtValue.CreateTensorValueFromMemory(
            inputData,
            [1, 3, InputSize, InputSize]);
        Dictionary<string, OrtValue> inputs = new()
        {
            [session.InputNames[0]] = input
        };
        using RunOptions runOptions = new();
        using IDisposableReadOnlyCollection<OrtValue> outputs = session.Run(
            runOptions,
            inputs,
            session.OutputNames);
        ReadOnlySpan<float> values = outputs[0].GetTensorDataAsSpan<float>();
        if (values.Length < 2)
            throw new InvalidOperationException("Anime model returned fewer than two scores.");

        double anime = values[0];
        double real = values[1];
        double sum = anime + real;
        if (anime < 0 || real < 0 || sum is < 0.98 or > 1.02)
        {
            double max = Math.Max(anime, real);
            anime = Math.Exp(anime - max);
            real = Math.Exp(real - max);
            sum = anime + real;
        }
        return (anime / sum, real / sum);
    }

    private static IReadOnlyList<ContentSampleEvidence> SelectFrames(
        IReadOnlyList<ContentSampleEvidence> samples)
    {
        ContentSampleEvidence[] candidates = samples
            .Where(sample => sample.IncludedInAggregate)
            .OrderBy(sample => sample.StartSeconds)
            .ToArray();
        if (candidates.Length == 0)
            candidates = samples.OrderBy(sample => sample.StartSeconds).ToArray();
        if (candidates.Length <= MaxFrames)
            return candidates;

        HashSet<int> indices = [];
        for (int index = 0; index < MaxFrames; index++)
        {
            double position = index * (candidates.Length - 1.0) / (MaxFrames - 1.0);
            indices.Add((int)Math.Round(position));
        }
        return indices.Order().Select(index => candidates[index]).ToArray();
    }

    private static byte[] LoadModel()
    {
        using Stream? stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream(ModelResourceName);
        if (stream is null)
            throw new InvalidOperationException("Embedded anime model was not found.");
        using MemoryStream buffer = new();
        stream.CopyTo(buffer);
        byte[] bytes = buffer.ToArray();
        string sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        if (!sha256.Equals(ModelSha256, StringComparison.Ordinal))
            throw new InvalidOperationException("Embedded anime model checksum validation failed.");
        return bytes;
    }

    private static AnimeModelEvidence Unavailable(string error)
    {
        return new AnimeModelEvidence
        {
            Model = ModelId,
            Revision = ModelRevision,
            Error = error
        };
    }

    private static float Normalize(byte value) => value / 127.5f - 1.0f;

    private static double Median(IEnumerable<double> values)
    {
        double[] sorted = values.Order().ToArray();
        int middle = sorted.Length / 2;
        return sorted.Length % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2.0
            : sorted[middle];
    }

    private static string Number(double value)
    {
        return value.ToString("0.###", CultureInfo.InvariantCulture);
    }
}
