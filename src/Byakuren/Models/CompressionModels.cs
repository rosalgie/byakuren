using System.Text.Json.Serialization;

namespace Byakuren.Models;

public enum CompressionMode { Fast, Balanced, ExtraQuality }
public enum UnderCapBehavior { Auto, Copy, Transcode }
public enum MetricMode { Off, VMAF, XPSNR, Ensemble, Auto }

public sealed record CompressionRequest
{
    public required string InputPath { get; init; }
    public required long TargetBytes { get; init; }
    public string? OutputPath { get; init; }
    public string? ResultJsonPath { get; init; }
    public CompressionMode Mode { get; init; } = CompressionMode.Balanced;
    public string VideoCodec { get; init; } = "x264";
    public string EncoderBackend { get; init; } = "auto";
    public string Container { get; init; } = "auto";
    public string CompatibilityMode { get; init; } = "widest";
    public string ContentClassMode { get; init; } = "auto";
    public string HardwareDevice { get; init; } = "auto";
    public UnderCapBehavior UnderCapBehavior { get; init; } = UnderCapBehavior.Auto;
    public MetricMode MetricMode { get; init; } = MetricMode.Auto;
    public bool EnableExperimentalEncoders { get; init; }
    public string? Preset { get; init; }
    public double WorkingTargetRatio { get; init; } = 0.995;
    public string FFmpegPath { get; init; } = "ffmpeg";
    public string FFprobePath { get; init; } = "ffprobe";
}

public sealed record MediaInfo
{
    public required string Path { get; init; }
    public required long InputBytes { get; init; }
    public required double DurationSeconds { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public required double Fps { get; init; }
    public required string VideoCodec { get; init; }
    public required string PixelFormat { get; init; }
    public required int BitDepth { get; init; }
    public required string FormatName { get; init; }
    public string AudioCodec { get; init; } = "";
    public bool HasAudio { get; init; }
    public int Rotation { get; init; }
    public double SampleAspectRatio { get; init; } = 1.0;
    public string ColorTransfer { get; init; } = "";
    public bool IsHdr { get; init; }
    public int VideoBitrateKbps { get; init; }
}

public sealed record CanonicalCanvas(int Width, int Height, double Fps, int BitDepth, string PixelFormat)
{
    public const string EvaluatorVersion = "canonical-v1";
}

public sealed record EncoderProfile
{
    public required string VideoCodec { get; init; }
    public required string Backend { get; init; }
    public required string Encoder { get; init; }
    public required string Container { get; init; }
    public required string Extension { get; init; }
    public required string AudioCodec { get; init; }
    public required string AudioEncoder { get; init; }
    public required string RateControlAdapter { get; init; }
    public required string PresetKind { get; init; }
    public int RequiredPasses { get; init; } = 2;
    public bool IsHardware { get; init; }
    public IReadOnlyList<string> PrivateArguments { get; init; } = [];
}

public sealed record ResolvedPolicy(
    EncoderProfile Profile,
    string CodecReason,
    string ContainerReason,
    string CompatibilityMode);

public sealed record CapabilityProbeResult
{
    public required bool Success { get; init; }
    public required string Backend { get; init; }
    public required string Encoder { get; init; }
    public required string RateControlAdapter { get; init; }
    public required string PixelFormat { get; init; }
    public required string Container { get; init; }
    public required string Device { get; init; }
    public required string Driver { get; init; }
    public required string FFmpegBuild { get; init; }
    public required string Os { get; init; }
    public string Error { get; init; } = "";
}

public sealed record ModeStrategy(int MaxFullEncodes, double FillGate);

public sealed record CompressionPlan
{
    public required EncoderProfile Profile { get; init; }
    public required CompressionMode Mode { get; init; }
    public required long HardCapBytes { get; init; }
    public required long WorkingTargetBytes { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public required double Fps { get; init; }
    public required int VideoKbps { get; init; }
    public required int AudioKbps { get; init; }
    public required string Preset { get; init; }
    public required string PixelFormat { get; init; }
    public required string VideoFilter { get; init; }
    public required CanonicalCanvas CanonicalCanvas { get; init; }
    public string ContentClass { get; init; } = "general";
    public ContentAnalysis? ContentAnalysis { get; init; }

    [JsonIgnore]
    public string Identity => $"{Profile.Backend}|{Width}x{Height}@{Fps:0.###}|{PixelFormat}|{VideoFilter}|{Preset}";
}

public sealed record CorrectionPoint(
    int Attempt,
    int VideoKbps,
    long VideoPayloadBytes,
    long AudioPayloadBytes,
    long MuxOverheadBytes,
    long TotalBytes);

public sealed record EncodeAttempt
{
    public required int Attempt { get; init; }
    public required CompressionPlan Plan { get; init; }
    public required long SizeBytes { get; init; }
    public required long VideoPayloadBytes { get; init; }
    public required long AudioPayloadBytes { get; init; }
    public required long MuxOverheadBytes { get; init; }
    public required string? OutputPath { get; init; }
    public bool UnderCap => OutputPath is not null;
    public double FillRatio => SizeBytes / (double)Plan.HardCapBytes;
}

public sealed record MetricEnsemble
{
    public bool Available { get; init; }
    public string Mode { get; init; } = "off";
    public double? PrimaryScore { get; init; }
    public double? WorstWindowScore { get; init; }
    public double? VMAFNeg { get; init; }
    public double? WorstVMAFNeg { get; init; }
    public double? StandardVMAF { get; init; }
    public double? XPSNR { get; init; }
    public double? WorstXPSNR { get; init; }
    public IReadOnlyList<MetricWindow> Windows { get; init; } = [];
    public string? Error { get; init; }
}

public sealed record MetricWindow(
    int Index,
    double StartSeconds,
    double EndSeconds,
    double? VMAFNeg,
    double? XPSNR);

public sealed record ContentFeatures
{
    public const string ClassifierVersion = "direct-core-v1";
    public bool Available { get; init; }
    public double? EdgeDensity { get; init; }
    public double? FlatAreaRatio { get; init; }
    public double? Entropy { get; init; }
    public double? SceneCut { get; init; }
    public double? TemporalDifference { get; init; }
    public double? Noise { get; init; }
    public double? SourceCompression { get; init; }
    public double? UIPersistence { get; init; }
    public string? Error { get; init; }
}

public sealed record ContentAnalysis(string ContentClass, ContentFeatures Features);

public sealed record CompressionOutcome(string OutputPath, object ResultContract);
