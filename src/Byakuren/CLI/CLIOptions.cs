using Byakuren.Models;

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
            if (key is "help" or "h" or "enableexperimentalencoders")
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
        CompressionMode mode = ParseEnum<CompressionMode>(Get(values, "mode") ?? "Balanced");
        UnderCapBehavior underCap = ParseEnum<UnderCapBehavior>(Get(values, "undercapbehavior", "under-cap-behavior") ?? "Auto");
        MetricMode metric = ParseEnum<MetricMode>(Get(values, "metricmode", "metric-mode") ?? "Auto");

        return new CompressionRequest
        {
            InputPath = input,
            TargetBytes = targetBytes,
            OutputPath = Get(values, "output", "outputfile"),
            ResultJsonPath = Get(values, "resultjson", "resultjsonpath"),
            Mode = mode,
            VideoCodec = Get(values, "videocodec", "video-codec") ?? "x264",
            EncoderBackend = Get(values, "encoderbackend", "encoder-backend") ?? "auto",
            Container = Get(values, "container") ?? "auto",
            CompatibilityMode = Get(values, "compatibilitymode", "compatibility-mode") ?? "widest",
            ContentClassMode = Get(values, "contentclassmode", "content-class-mode") ?? "auto",
            HardwareDevice = Get(values, "hardwaredevice", "hardware-device") ?? "auto",
            UnderCapBehavior = underCap,
            MetricMode = metric,
            EnableExperimentalEncoders = values.ContainsKey("enableexperimentalencoders"),
            Preset = Get(values, "preset"),
            WorkingTargetRatio = ParseDouble(Get(values, "workingtargetratio", "working-target-ratio"), 0.995),
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
          --mode Fast|Balanced|ExtraQuality
          --video-codec x264|x265|av1|auto
          --encoder-backend auto|libx264|libx265|svtav1|aom|rav1e|vpx|vvenc|vaapi
          --container auto|mp4|webm
          --compatibility-mode widest|modern|unrestricted
          --content-class-mode auto|off
          --under-cap-behavior Auto|Copy|Transcode
          --metric-mode Off|VMAF|XPSNR|Ensemble|Auto
          --hardware-device <path|auto>
          --enable-experimental-encoders
          --result-json <path>

        Single-dash aliases such as -InputFile and -TargetBytes are also accepted.
        """;

    private static long ParseTargetBytes(Dictionary<string, string?> values)
    {
        string? bytes = Get(values, "targetbytes", "target-bytes");
        string? mebibytes = Get(values, "targetmb", "target-mb");
        if (bytes is not null && mebibytes is not null) throw new ArgumentException("Specify target bytes or target MB, not both.");
        if (bytes is not null && long.TryParse(bytes, out long parsedBytes) && parsedBytes > 0) return parsedBytes;
        if (mebibytes is not null && long.TryParse(mebibytes, out long parsedMb) && parsedMb > 0) return checked(parsedMb * 1024 * 1024);
        throw new ArgumentException("A positive --target-bytes or --target-mb value is required.");
    }

    private static T ParseEnum<T>(string value) where T : struct, Enum =>
        Enum.TryParse(value, ignoreCase: true, out T parsed) ? parsed : throw new ArgumentException($"Unsupported {typeof(T).Name} value '{value}'.");

    private static double ParseDouble(string? value, double fallback) =>
        value is null ? fallback : double.TryParse(value, out double parsed) ? parsed : throw new ArgumentException($"Invalid numeric value '{value}'.");

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
