using Byakuren.Models;
using System.Globalization;

namespace Byakuren.CLI;

public static class CLIOptions
{
    public static CompressionRequest Parse(string[] arguments)
    {
        Dictionary<string, string?> values = new(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < arguments.Length; index++)
        {
            string token = arguments[index];
            if (!token.StartsWith('-')) throw new ArgumentException($"Unexpected argument '{token}'.");
            string key = NormalizeKey(token);
            if (key is "help" or "h" or "enableexperimentalencoders" or "enableplanlogging" or "verbosecommands")
            {
                values[key] = "true";
                continue;
            }
            if (++index >= arguments.Length) throw new ArgumentException($"Missing value for '{token}'.");
            values[key] = arguments[index];
        }

        if (values.ContainsKey("help") || values.ContainsKey("h")) throw new HelpRequestedException();
        string input = Required(values, "input", "inputfile");
        long targetBytes = ParseTargetBytes(values);
        TargetUnit targetUnit = ParseEnum<TargetUnit>(Get(values, "targetunit") ?? "BinaryMiB");
        CompressionMode mode = ParseEnum<CompressionMode>(Get(values, "mode") ?? "Balanced");
        UnderCapBehavior underCap = ParseEnum<UnderCapBehavior>(Get(values, "undercapbehavior", "under-cap-behavior") ?? "Auto");
        MetricMode metric = ParseEnum<MetricMode>(Get(values, "metricmode", "metric-mode") ?? "Auto");
        SampleMode sampleMode = ParseEnum<SampleMode>(Get(values, "samplemode") ?? "Auto");
        AudioPriority audioPriority = ParseEnum<AudioPriority>(Get(values, "audiopriority") ?? "Balanced");
        PreprocessMode preprocessMode = ParseEnum<PreprocessMode>(Get(values, "preprocessprofile", "preprocessmode") ?? "Auto");
        CropMode cropMode = ParseEnum<CropMode>(Get(values, "cropmode") ?? "Auto");
        VBVMode vbvMode = ParseEnum<VBVMode>(Get(values, "vbvmode") ?? "Off");
        string outputBitDepth = Get(values, "outputbitdepth") ?? "Auto";
        if (outputBitDepth is not ("8" or "10") && !outputBitDepth.Equals("auto", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Output bit depth must be Auto, 8, or 10.");

        double workingTargetRatio = ParseWorkingTargetRatio(values);

        return new CompressionRequest
        {
            InputPath = input,
            TargetBytes = targetBytes,
            OutputPath = Get(values, "output", "outputfile"),
            ResultJsonPath = Get(values, "resultjson", "resultjsonpath"),
            TargetUnit = targetUnit,
            Mode = mode,
            VideoCodec = Get(values, "videocodec", "video-codec") ?? "x264",
            EncoderBackend = Get(values, "encoderbackend", "encoder-backend") ?? "auto",
            Container = Get(values, "container") ?? "auto",
            CompatibilityMode = Get(values, "compatibilitymode", "compatibility-mode") ?? "widest",
            ContentClassMode = Get(values, "contentclassmode", "content-class-mode") ?? "auto",
            SampleMode = sampleMode,
            AudioPriority = audioPriority,
            PreprocessMode = preprocessMode,
            CropMode = cropMode,
            VBVMode = vbvMode,
            OutputBitDepth = outputBitDepth,
            HardwareDevice = Get(values, "hardwaredevice", "hardware-device") ?? "auto",
            UnderCapBehavior = underCap,
            MetricMode = metric,
            EnableExperimentalEncoders = values.ContainsKey("enableexperimentalencoders"),
            Preset = Get(values, "preset"),
            WorkingTargetRatio = workingTargetRatio,
            ProbeSampleSeconds = ParseInt(Get(values, "probesampleseconds"), 6, 1),
            MetricSampleSeconds = ParseInt(Get(values, "metricsampleseconds"), 0, 0),
            MetricMaxSamples = ParseInt(Get(values, "metricmaxsamples"), 0, 0),
            EnablePlanLogging = values.ContainsKey("enableplanlogging"),
            PlanLogPath = Get(values, "planlogpath"),
            VerboseCommands = values.ContainsKey("verbosecommands"),
            FFmpegPath = Get(values, "ffmpeg") ?? "ffmpeg",
            FFprobePath = Get(values, "ffprobe") ?? "ffprobe"
        };
    }

    public static string HelpText => """
        byakuren - exact-size video compressor worker

        Required:
          --input <path>                  Input media path
          --target-bytes <bytes>          Absolute hard cap
            or --target-mb <MiB>

        Common options:
          --output <path>                 Output path
          --target-unit BinaryMiB|DecimalMB
          --mode Fast|Balanced|ExtraQuality
          --video-codec x264|x265|av1|auto
          --encoder-backend auto|libx264|libx265|svtav1|aom|rav1e|vpx|vvenc|vaapi
          --container auto|mp4|webm
          --compatibility-mode widest|modern|unrestricted
          --content-class-mode auto|off
          --under-cap-behavior Auto|Copy|Transcode
          --metric-mode Off|VMAF|XPSNR|Ensemble|Auto
          --sample-mode Fixed|SceneAware|Auto
          --audio-priority Visual|Balanced|Speech
          --preprocess-profile Off|Auto|Mild
          --crop-mode Off|Auto
          --vbv-mode Off|Streaming
          --output-bit-depth Auto|8|10
          --preset <encoder preset>
          --probe-sample-seconds <seconds>
          --metric-sample-seconds <seconds>
          --metric-max-samples <count>
          --working-target-ratio <0..1>
          --safety-margin-percent <ratio|percent>
          --hardware-device <path|auto>
          --enable-experimental-encoders
          --enable-plan-logging
          --plan-log-path <path>
          --verbose-commands
          --result-json <path>
          --ffmpeg <path>
          --ffprobe <path>

        Single-dash aliases such as -InputFile and -TargetBytes are also accepted.
        """;

    private static long ParseTargetBytes(Dictionary<string, string?> values)
    {
        string? bytes = Get(values, "targetbytes", "target-bytes");
        string? mebibytes = Get(values, "targetmb", "target-mb");
        if (bytes is not null && mebibytes is not null) throw new ArgumentException("Specify target bytes or target MB, not both.");
        if (bytes is not null && long.TryParse(bytes, out long parsedBytes) && parsedBytes > 0) return parsedBytes;
        TargetUnit unit = ParseEnum<TargetUnit>(Get(values, "targetunit") ?? "BinaryMiB");
        if (mebibytes is not null && double.TryParse(mebibytes, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsedMb) && parsedMb > 0)
        {
            double multiplier = unit == TargetUnit.BinaryMiB ? 1024.0 * 1024.0 : 1_000_000.0;
            return checked((long)Math.Floor(parsedMb * multiplier));
        }
        throw new ArgumentException("A positive --target-bytes or --target-mb value is required.");
    }

    private static double ParseWorkingTargetRatio(Dictionary<string, string?> values)
    {
        string? ratio = Get(values, "workingtargetratio", "working-target-ratio");
        string? margin = Get(values, "safetymarginpercent");
        if (ratio is not null && margin is not null)
            throw new ArgumentException("Specify working target ratio or safety margin percent, not both.");
        if (margin is null) return ParseDouble(ratio, 0.995);
        double legacyRatioOrPercent = ParseDouble(margin, 0.995);
        if (legacyRatioOrPercent is > 0 and <= 1) return legacyRatioOrPercent;
        if (legacyRatioOrPercent is > 1 and < 100) return 1 - legacyRatioOrPercent / 100;
        throw new ArgumentOutOfRangeException("safety-margin-percent");
    }

    private static T ParseEnum<T>(string value) where T : struct, Enum =>
        Enum.TryParse(value, ignoreCase: true, out T parsed) ? parsed : throw new ArgumentException($"Unsupported {typeof(T).Name} value '{value}'.");

    private static double ParseDouble(string? value, double fallback) =>
        value is null ? fallback : double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed) ? parsed : throw new ArgumentException($"Invalid numeric value '{value}'.");

    private static int ParseInt(string? value, int fallback, int minimum) =>
        value is null ? fallback : int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int parsed) && parsed >= minimum
            ? parsed
            : throw new ArgumentException($"Invalid integer value '{value}'.");

    private static string Required(Dictionary<string, string?> values, params string[] keys) =>
        Get(values, keys) ?? throw new ArgumentException($"Missing required option --{keys[0]}.");

    private static string? Get(Dictionary<string, string?> values, params string[] keys)
    {
        foreach (string key in keys)
            if (values.TryGetValue(NormalizeKey(key), out string? value)) return value;
        return null;
    }

    private static string NormalizeKey(string value) => value.TrimStart('-').Replace("_", "", StringComparison.Ordinal).Replace("-", "", StringComparison.Ordinal).ToLowerInvariant();
}

public sealed class HelpRequestedException : Exception;
