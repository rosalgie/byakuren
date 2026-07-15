using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Byakuren.Models;
using Byakuren.Planner;

namespace Byakuren.Results;

public sealed class ResultContract
{
    public const string SchemaVersion = "byakuren.compress.result.v1";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public async Task<object> BuildAsync(
        DateTimeOffset started,
        string action,
        CompressionRequest request,
        MediaInfo media,
        ResolvedPolicy policy,
        CapabilityProbeResult? capability,
        CompressionPlan? plan,
        EncodeAttempt? attempt,
        IReadOnlyList<CorrectionPoint> corrections,
        MetricEnsemble metrics,
        string outputPath,
        CancellationToken cancellationToken)
    {
        FileInfo output = new FileInfo(outputPath);
        double fill = output.Length / (double)request.TargetBytes;
        ModeStrategy strategy = CompressionPlanner.Strategy(request.Mode);
        CanonicalCanvas canvas = plan?.CanonicalCanvas ?? new CompressionPlanner().GetCanonicalCanvas(media);
        List<string> warnings = new List<string>();
        if (action == "encode" && fill < strategy.FillGate)
            warnings.Add($"final fill {fill:P2} is below the {strategy.FillGate:P2} mode gate");
        if (action == "encode" && attempt is not null && attempt.MuxOverheadBytes > Math.Max(4096, plan?.MuxReserveBytes ?? 0))
            warnings.Add($"mux overhead used {attempt.MuxOverheadBytes} bytes, above the reserved {plan?.MuxReserveBytes ?? 0} bytes; short-file/container overhead may limit fill");
        string hash = await Sha256Async(outputPath, cancellationToken).ConfigureAwait(false);
        DateTimeOffset completed = DateTimeOffset.UtcNow;
        string hostText = $"{RuntimeInformation.OSDescription}|{RuntimeInformation.OSArchitecture}|{Environment.ProcessorCount}|{capability?.Driver}|{capability?.FFmpegBuild}";

        return new
        {
            SchemaVersion,
            Status = "succeeded",
            Action = action,
            StartedUtc = started,
            CompletedUtc = completed,
            ElapsedMilliseconds = (long)(completed - started).TotalMilliseconds,
            Request = new
            {
                InputPath = media.Path,
                OutputPath = output.FullName,
                HardCapBytes = request.TargetBytes,
                WorkingTargetBytes = plan?.WorkingTargetBytes ?? (long)Math.Floor(request.TargetBytes * request.WorkingTargetRatio),
                Mode = request.Mode.ToString(),
                TargetUnit = request.TargetUnit.ToString(),
                RequestedVideoCodec = request.VideoCodec,
                RequestedEncoderBackend = request.EncoderBackend,
                RequestedContainer = request.Container,
                CompatibilityMode = request.CompatibilityMode,
                ContentClassMode = request.ContentClassMode,
                SampleMode = request.SampleMode.ToString(),
                AudioPriority = request.AudioPriority.ToString(),
                PreprocessMode = request.PreprocessMode.ToString(),
                CropMode = request.CropMode.ToString(),
                VBVMode = request.VBVMode.ToString(),
                request.OutputBitDepth,
                request.ProbeSampleSeconds,
                request.MetricSampleSeconds,
                request.MetricMaxSamples,
                UnderCapBehavior = request.UnderCapBehavior.ToString(),
                MetricMode = request.MetricMode.ToString(),
                HardwareDevice = request.HardwareDevice,
                ExperimentalEncoders = request.EnableExperimentalEncoders
            },
            Policy = new
            {
                VideoCodec = policy.Profile.VideoCodec,
                EncoderBackend = policy.Profile.Backend,
                policy.Profile.Container,
                AudioCodec = policy.Profile.AudioCodec,
                CodecReason = policy.CodecReason,
                ContainerReason = policy.ContainerReason,
                policy.CompatibilityMode
            },
            Host = new
            {
                Id = HashText(hostText)[..16],
                MachineName = Environment.MachineName,
                Os = RuntimeInformation.OSDescription,
                Kernel = Environment.OSVersion.VersionString,
                OsArchitecture = RuntimeInformation.OSArchitecture.ToString(),
                ProcessArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
                Cpu = Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER") ?? RuntimeInformation.ProcessArchitecture.ToString(),
                Gpu = capability?.Backend == "vaapi" ? capability.Device : "",
                Driver = capability?.Driver ?? "",
                FFmpegBuild = capability?.FFmpegBuild ?? "not-required",
                HardwareDevice = capability?.Device ?? request.HardwareDevice
            },
            CapabilityProbe = capability ?? new
            {
                Success = (bool?)null,
                Backend = policy.Profile.Backend,
                SkippedReason = "under-cap passthrough"
            } as object,
            Source = new
            {
                Bytes = media.InputBytes,
                media.DurationSeconds,
                media.Width,
                media.Height,
                media.Fps,
                media.VideoCodec,
                media.PixelFormat,
                media.BitDepth,
                media.AudioCodec,
                media.AudioBitrateKbps,
                media.AudioChannels,
                media.Rotation,
                media.SampleAspectRatio,
                media.ColorRange,
                media.ColorPrimaries,
                media.ColorTransfer,
                media.ColorSpace,
                media.ChromaLocation,
                media.HDRClassification,
                media.HDRReason
            },
            Evaluator = new
            {
                Version = CanonicalCanvas.EvaluatorVersion,
                MetricMode = metrics.Mode,
                PrimaryMetric = metrics.VMAFNeg.HasValue ? "vmaf-neg" : metrics.XPSNR.HasValue ? "xpsnr" : "",
                CanonicalCanvas = new { canvas.Width, canvas.Height, canvas.Fps, canvas.PixelFormat, canvas.BitDepth },
                VMAFModel = "vmaf-neg-primary+vmaf-standard-supplemental",
                XPSNRGuard = true
            },
            Encoder = new
            {
                Backend = policy.Profile.Backend,
                Name = policy.Profile.Encoder,
                Codec = policy.Profile.VideoCodec,
                policy.Profile.Container,
                AudioProfile = $"{policy.Profile.Container}-{policy.Profile.AudioCodec}",
                policy.Profile.RateControlAdapter,
                Preset = plan?.Preset ?? "copy",
                PixelFormat = plan?.PixelFormat ?? media.PixelFormat,
                Arguments = plan is null ? Array.Empty<string>() : BuildEncoderArguments(plan)
            },
            Plan = plan,
            PayloadBytes = new
            {
                Video = attempt?.VideoPayloadBytes,
                Audio = attempt?.AudioPayloadBytes,
                MuxOverhead = attempt?.MuxOverheadBytes,
                Total = output.Length
            },
            SizeSearch = new
            {
                HardCapBytes = request.TargetBytes,
                WorkingTargetBytes = plan?.WorkingTargetBytes ?? (long)Math.Floor(request.TargetBytes * request.WorkingTargetRatio),
                FillRatio = fill,
                FillGate = action == "encode" ? strategy.FillGate : (double?)null,
                FullEncodes = corrections.Count,
                CorrectionHistory = corrections
            },
            Metrics = new
            {
                metrics.Available,
                metrics.Mode,
                metrics.PrimaryScore,
                metrics.WorstWindowScore,
                metrics.VMAFNeg,
                metrics.WorstVMAFNeg,
                metrics.StandardVMAF,
                metrics.XPSNR,
                metrics.WorstXPSNR,
                metrics.CAMBI,
                metrics.WorstCAMBI,
                metrics.Error,
                metrics.Windows
            },
            Output = new
            {
                Path = output.FullName,
                Bytes = output.Length,
                FillRatio = fill,
                Sha256 = hash,
                DecodeVerified = capability?.Success ?? true
            },
            Warnings = warnings
        };
    }

    public async Task WriteAsync(object result, string path, CancellationToken cancellationToken)
    {
        string fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        string temporary = fullPath + $".{Guid.NewGuid():N}.tmp";
        await using (FileStream stream = File.Create(temporary))
            await JsonSerializer.SerializeAsync(stream, result, JsonOptions, cancellationToken).ConfigureAwait(false);
        File.Move(temporary, fullPath, overwrite: true);
    }

    private static async Task<string> Sha256Async(string path, CancellationToken cancellationToken)
    {
        await using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false)).ToLowerInvariant();
    }

    private static string HashText(string value) => Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private static IReadOnlyList<string> BuildEncoderArguments(CompressionPlan plan)
    {
        List<string> arguments = ["-vf", plan.VideoFilter, "-c:v", plan.Profile.Encoder, "-pix_fmt", plan.PixelFormat, "-b:v", $"{plan.VideoKbps}k"];
        if (plan.MaxrateKbps.HasValue) arguments.AddRange(["-maxrate", $"{plan.MaxrateKbps.Value}k"]);
        if (plan.BufsizeKbits.HasValue) arguments.AddRange(["-bufsize", $"{plan.BufsizeKbits.Value}k"]);
        arguments.AddRange(plan.ColorArguments);
        arguments.AddRange(plan.Profile.PrivateArguments);
        return arguments;
    }
}
