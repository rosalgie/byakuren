using System.Globalization;
using System.Text.Json;
using Byakuren.Execution;
using Byakuren.Models;

namespace Byakuren.Probe;

public sealed class FFmpegProbe(ProcessRunner runner)
{
    public async Task<MediaInfo> ProbeMediaAsync(
        CompressionRequest request,
        CancellationToken cancellationToken)
    {
        string path = Path.GetFullPath(request.InputPath);
        ProcessResult result = await runner.RunCheckedAsync(request.FFprobePath,
        [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path
        ], cancellationToken).ConfigureAwait(false);

        using JsonDocument document = JsonDocument.Parse(result.StandardOutput);
        JsonElement root = document.RootElement;
        JsonElement[] streams = root.GetProperty("streams").EnumerateArray().ToArray();
        JsonElement video = streams.FirstOrDefault(x => String(x, "codec_type") == "video");
        if (video.ValueKind == JsonValueKind.Undefined)
            throw new InvalidOperationException("Input contains no video stream.");
        JsonElement audio = streams.FirstOrDefault(x => String(x, "codec_type") == "audio");
        JsonElement format = root.GetProperty("format");
        string pixelFormat = String(video, "pix_fmt");
        string transfer = String(video, "color_transfer");
        double duration = Double(format, "duration", Double(video, "duration", 0));
        if (duration <= 0)
            throw new InvalidOperationException("Could not determine a positive input duration.");

        int rotation = 0;
        if (video.TryGetProperty("tags", out JsonElement tags))
            rotation = Integer(tags, "rotate", 0);
        if (video.TryGetProperty("side_data_list", out JsonElement sideData))
        {
            foreach (JsonElement item in sideData.EnumerateArray())
            {
                if (item.TryGetProperty("rotation", out JsonElement value) && value.TryGetInt32(out int parsed))
                    rotation = parsed;
            }
        }

        rotation = NormalizeRotation(rotation);
        int bitDepth = Integer(video, "bits_per_raw_sample", 0);
        if (bitDepth <= 0)
        {
            bitDepth = 8;
            if (pixelFormat.Contains("12", StringComparison.Ordinal))
                bitDepth = 12;
            else if (pixelFormat.Contains("10", StringComparison.Ordinal))
                bitDepth = 10;
        }

        double sar = ParseRatio(String(video, "sample_aspect_ratio"), 1.0);
        bool hasHdrSideData = HasHDRSideData(video);
        bool hdr = transfer is "smpte2084" or "arib-std-b67" || hasHdrSideData;
        string hdrClassification = transfer switch
        {
            "smpte2084" => "HDR10/PQ",
            "arib-std-b67" => "HLG",
            _ when hasHdrSideData => "HDR",
            _ => "SDR"
        };

        string hdrReason;
        if (transfer is "smpte2084" or "arib-std-b67")
            hdrReason = $"color transfer is {transfer}";
        else if (hasHdrSideData)
            hdrReason = "HDR mastering side data is present";
        else
            hdrReason = "no HDR transfer or mastering side data";

        bool hasAudio = audio.ValueKind != JsonValueKind.Undefined;
        string audioCodec = "";
        int audioBitrateKbps = 0;
        int audioChannels = 0;
        if (hasAudio)
        {
            audioCodec = String(audio, "codec_name");
            audioBitrateKbps = (int)Math.Round(Double(audio, "bit_rate", 0) / 1000.0);
            audioChannels = Integer(audio, "channels", 0);
        }

        int videoBitrateKbps = (int)Math.Round(Double(video, "bit_rate", 0) / 1000.0);

        return new MediaInfo
        {
            Path = path,
            InputBytes = new FileInfo(path).Length,
            DurationSeconds = duration,
            Width = Integer(video, "width", 0),
            Height = Integer(video, "height", 0),
            Fps = ParseRatio(
                String(video, "avg_frame_rate"),
                ParseRatio(String(video, "r_frame_rate"), 30)),
            VideoCodec = String(video, "codec_name"),
            PixelFormat = pixelFormat,
            BitDepth = bitDepth,
            FormatName = String(format, "format_name"),
            HasAudio = hasAudio,
            AudioCodec = audioCodec,
            Rotation = rotation,
            SampleAspectRatio = sar,
            ColorTransfer = transfer,
            ColorRange = String(video, "color_range"),
            ColorPrimaries = String(video, "color_primaries"),
            ColorSpace = String(video, "color_space"),
            ChromaLocation = String(video, "chroma_location"),
            IsHdr = hdr,
            HDRClassification = hdrClassification,
            HDRReason = hdrReason,
            VideoBitrateKbps = videoBitrateKbps,
            AudioBitrateKbps = audioBitrateKbps,
            AudioChannels = audioChannels
        };
    }

    public async Task<long> GetPacketPayloadBytesAsync(
        string ffprobePath,
        string path,
        string stream,
        CancellationToken cancellationToken)
    {
        ProcessResult result = await runner.RunAsync(ffprobePath,
        [
            "-v", "error", "-select_streams", stream, "-show_entries", "packet=size", "-of", "csv=p=0", path
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
            return 0;
        long total = 0;
        foreach (string line in result.StandardOutput.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
            if (long.TryParse(line.Trim().TrimEnd(','), NumberStyles.Integer, CultureInfo.InvariantCulture, out long value) && value > 0)
                total += value;
        return total;
    }

    public async Task<string> GetFFmpegBuildAsync(string ffmpegPath, CancellationToken cancellationToken)
    {
        ProcessResult result = await runner.RunCheckedAsync(ffmpegPath, ["-version"], cancellationToken).ConfigureAwait(false);
        return result.StandardOutput.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "unknown";
    }

    public async Task<bool> HasFilterAsync(string ffmpegPath, string filter, CancellationToken cancellationToken)
    {
        ProcessResult result = await runner.RunAsync(ffmpegPath, ["-hide_banner", "-filters"], cancellationToken).ConfigureAwait(false);
        return result.ExitCode == 0 && result.CombinedOutput
            .Split(['\r', '\n'])
            .Any(line => line
                .Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Contains(filter));
    }

    private static string String(JsonElement element, string name)
    {
        if (element.ValueKind == JsonValueKind.Undefined)
            return "";

        if (element.TryGetProperty(name, out JsonElement value))
            return value.ToString();

        return "";
    }

    private static int Integer(JsonElement element, string name, int fallback)
    {
        bool parsed = int.TryParse(
            String(element, name),
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out int value);

        return parsed ? value : fallback;
    }

    private static double Double(JsonElement element, string name, double fallback)
    {
        bool parsed = double.TryParse(
            String(element, name),
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double value);

        return parsed ? value : fallback;
    }

    private static double ParseRatio(string value, double fallback)
    {
        if (string.IsNullOrWhiteSpace(value) || value is "0/0" or "N/A")
            return fallback;
        string[] parts = value.Split(['/', ':']);
        if (parts.Length == 2 &&
            double.TryParse(
                parts[0],
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out double numerator) &&
            double.TryParse(
                parts[1],
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out double denominator) &&
            Math.Abs(denominator) > 1e-9)
            return numerator / denominator;
        if (double.TryParse(
            value,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out double parsed))
        {
            return parsed;
        }

        return fallback;
    }

    private static int NormalizeRotation(int rotation)
    {
        int normalized = rotation % 360;
        if (normalized < 0)
            normalized += 360;
        return normalized switch
        {
            >= 315 or < 45 => 0,
            < 135 => 90,
            < 225 => 180,
            _ => 270
        };
    }

    private static bool HasHDRSideData(JsonElement video)
    {
        if (!video.TryGetProperty("side_data_list", out JsonElement sideData))
            return false;
        foreach (JsonElement item in sideData.EnumerateArray())
        {
            string sideDataType = String(item, "side_data_type");
            if (sideDataType.Contains("Mastering display metadata", StringComparison.OrdinalIgnoreCase) ||
                sideDataType.Contains("Content light level metadata", StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }
}
