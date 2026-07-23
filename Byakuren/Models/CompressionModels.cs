using System.Text.Json.Serialization;

namespace Byakuren.Models;

public enum CompressionMode
{
    Fast,
    Balanced,
    ExtraQuality
}

public enum UnderCapBehavior
{
    Auto,
    Copy,
    Transcode
}

public enum MetricMode
{
    Off,
    VMAF,
    XPSNR,
    Ensemble,
    Auto
}

public enum TargetUnit
{
    BinaryMiB,
    DecimalMB
}

public enum SampleMode
{
    Fixed,
    SceneAware,
    Auto
}

public enum AudioPriority
{
    Visual,
    Balanced,
    Speech
}

public enum PreprocessMode
{
    Off,
    Auto,
    Mild
}

public enum CropMode
{
    Off,
    Auto
}

public enum VBVMode
{
    Off,
    Streaming
}

public sealed record CompressionRequest
{
    public required string InputPath { get; init; }
    public required long TargetBytes { get; init; }
    public string? OutputPath { get; init; }
    public string? ResultJsonPath { get; init; }
    public TargetUnit TargetUnit { get; init; } = TargetUnit.BinaryMiB;
    public CompressionMode Mode { get; init; } = CompressionMode.Balanced;
    public string VideoCodec { get; init; } = "x264";
    public string EncoderBackend { get; init; } = "auto";
    public string Container { get; init; } = "auto";
    public string CompatibilityMode { get; init; } = "widest";
    public string ContentClassMode { get; init; } = "auto";
    public SampleMode SampleMode { get; init; } = SampleMode.Auto;
    public AudioPriority AudioPriority { get; init; } = AudioPriority.Balanced;
    public PreprocessMode PreprocessMode { get; init; } = PreprocessMode.Auto;
    public CropMode CropMode { get; init; } = CropMode.Auto;
    public VBVMode VBVMode { get; init; } = VBVMode.Off;
    public string OutputBitDepth { get; init; } = "Auto";
    public string HardwareDevice { get; init; } = "auto";
    public UnderCapBehavior UnderCapBehavior { get; init; } = UnderCapBehavior.Auto;
    public MetricMode MetricMode { get; init; } = MetricMode.Auto;
    public bool EnableExperimentalEncoders { get; init; }
    public string? Preset { get; init; }
    public double WorkingTargetRatio { get; init; } = 0.995;
    public int ProbeSampleSeconds { get; init; } = 6;
    public int MetricSampleSeconds { get; init; }
    public int MetricMaxSamples { get; init; }
    public bool EnablePlanLogging { get; init; }
    public string? PlanLogPath { get; init; }
    public bool VerboseCommands { get; init; }
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
    public string ColorRange { get; init; } = "";
    public string ColorPrimaries { get; init; } = "";
    public string ColorSpace { get; init; } = "";
    public string ChromaLocation { get; init; } = "";
    public bool IsHdr { get; init; }
    public string HDRClassification { get; init; } = "SDR";
    public string HDRReason { get; init; } = "";
    public int VideoBitrateKbps { get; init; }
    public int AudioBitrateKbps { get; init; }
    public int AudioChannels { get; init; }
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

public sealed record ModeStrategy(
    int MaxFullEncodes,
    double FillGate,
    int ProbeMaxSamples = 2,
    int PreviewMaxSamples = 0,
    int PreviewTop = 0,
    int Finalists = 1);

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
    public ComplexityAnalysis? ComplexityAnalysis { get; init; }
    public CropAnalysis? CropAnalysis { get; init; }
    public AudioPlan AudioPlan { get; init; } = AudioPlan.Mute;
    public string Preprocess { get; init; } = "none";
    public string GeometryFilter { get; init; } = "";
    public string PreprocessFilter { get; init; } = "";
    public string MetricReferenceFilter { get; init; } = "";
    public double BitsPerPixelPerFrame { get; init; }
    public double HeuristicScore { get; init; }
    public string WidthOrigin { get; init; } = "heuristic";
    public long MuxReserveBytes { get; init; }
    public IReadOnlyList<string> ColorArguments { get; init; } = [];
    public IReadOnlyList<string> PreservedColorMetadata { get; init; } = [];
    public IReadOnlyList<string> OmittedColorMetadata { get; init; } = [];
    public int? MaxrateKbps { get; init; }
    public int? BufsizeKbits { get; init; }
    public IReadOnlyList<SampleWindow> SampleWindows { get; init; } = [];

    [JsonIgnore]
    public string Identity
    {
        get
        {
            return $"{Profile.Backend}|{Width}x{Height}@{Fps:0.###}|{PixelFormat}|" +
                $"{VideoFilter}|{Preset}|{string.Join(':', Profile.PrivateArguments)}";
        }
    }
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
    public double? CAMBI { get; init; }
    public double? WorstCAMBI { get; init; }
    public IReadOnlyList<MetricWindow> Windows { get; init; } = [];
    public string? Error { get; init; }
}

public sealed record MetricWindow(
    int Index,
    double StartSeconds,
    double EndSeconds,
    double? VMAFNeg,
    double? XPSNR,
    double? CAMBI = null);

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

public sealed record CropSample(double OffsetSeconds, int Width, int Height, int X, int Y);

public sealed record CropAnalysis
{
    public bool Applied { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
    public int X { get; init; }
    public int Y { get; init; }
    public string Filter { get; init; } = "";
    public string Summary { get; init; } = "none";
    public double AreaRemovedRatio { get; init; }
    public IReadOnlyList<CropSample> Samples { get; init; } = [];
}

public sealed record SampleWindow(
    double StartSeconds,
    double DurationSeconds,
    string Source,
    double SceneScore = 0,
    double DifficultyScore = 0,
    string Tag = "");

public sealed record ComplexityAnalysis
{
    public string DetailBucket { get; init; } = "Medium";
    public string MotionBucket { get; init; } = "Medium";
    public double DetailKbps { get; init; }
    public double PeakDetailKbps { get; init; }
    public double MotionKbps { get; init; }
    public double MotionRatio { get; init; } = 1;
    public double MotionNormalized { get; init; } = 0.75;
    public double DetailSpread { get; init; }
    public double MotionSpread { get; init; }
    public string SamplingMode { get; init; } = "fixed";
    public IReadOnlyList<SampleWindow> Windows { get; init; } = [];
}

public sealed record AudioPlan(string Mode, int Kbps, string Codec, string Label, int Rank)
{
    public static AudioPlan Mute { get; } = new("mute", 0, "", "mute", 1);
    public string Identity => $"{Mode}|{Kbps}|{Codec}";
}

public sealed record AudioArtifact(string? Path, long PayloadBytes, AudioPlan Plan);

public sealed record PlanPreview(
    CompressionPlan Plan,
    MetricEnsemble Metrics,
    string OutputPath,
    long OutputBytes,
    double RuntimeSeconds);

public sealed record CompressionOutcome(string OutputPath, object ResultContract);
