using System.Globalization;
using System.Text.Json;
using Byakuren.Execution;
using Byakuren.Models;

namespace Byakuren.Probe;

public sealed class FFmpegProbe(ProcessRunner runner)
{
    public async Task<MediaInfo> ProbeMediaAsync(CompressionRequest request, CancellationToken cancellationToken)
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
        if (duration <= 0) throw new InvalidOperationException("Could not determine a positive input duration.");

        int rotation = 0;
        if (video.TryGetProperty("tags", out JsonElement tags))
            rotation = Integer(tags, "rotate", 0);
        if (video.TryGetProperty("side_data_list", out JsonElement sideData))
        {
            foreach (JsonElement item in sideData.EnumerateArray())
                if (item.TryGetProperty("rotation", out JsonElement value) && value.TryGetInt32(out int parsed)) rotation = parsed;
        }

        int bitDepth = Integer(video, "bits_per_raw_sample", 0);
        if (bitDepth <= 0)
            bitDepth = pixelFormat.Contains("12", StringComparison.Ordinal) ? 12 : pixelFormat.Contains("10", StringComparison.Ordinal) ? 10 : 8;
        double sar = ParseRatio(String(video, "sample_aspect_ratio"), 1.0);
        bool hdr = transfer is "smpte2084" or "arib-std-b67";
        int videoBitrateKbps = (int)Math.Round(Double(video, "bit_rate", 0) / 1000.0);

        return new MediaInfo
        {
            Path = path,
            InputBytes = new FileInfo(path).Length,
            DurationSeconds = duration,
            Width = Integer(video, "width", 0),
            Height = Integer(video, "height", 0),
            Fps = ParseRatio(String(video, "avg_frame_rate"), ParseRatio(String(video, "r_frame_rate"), 30)),
            VideoCodec = String(video, "codec_name"),
            PixelFormat = pixelFormat,
            BitDepth = bitDepth,
            FormatName = String(format, "format_name"),
            HasAudio = audio.ValueKind != JsonValueKind.Undefined,
            AudioCodec = audio.ValueKind == JsonValueKind.Undefined ? "" : String(audio, "codec_name"),
            Rotation = rotation,
            SampleAspectRatio = sar,
            ColorTransfer = transfer,
            IsHdr = hdr,
            VideoBitrateKbps = videoBitrateKbps
        };
    }

    public async Task<long> GetPacketPayloadBytesAsync(string ffprobePath, string path, string stream, CancellationToken cancellationToken)
    {
        ProcessResult result = await runner.RunAsync(ffprobePath,
        [
            "-v", "error", "-select_streams", stream, "-show_entries", "packet=size", "-of", "csv=p=0", path
        ], cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0) return 0;
        long total = 0;
        foreach (string line in result.StandardOutput.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
            if (long.TryParse(line.Trim().TrimEnd(','), NumberStyles.Integer, CultureInfo.InvariantCulture, out long value) && value > 0) total += value;
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
        return result.ExitCode == 0 && result.CombinedOutput.Split(['\r', '\n']).Any(x => x.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains(filter));
    }

    private static string String(JsonElement element, string name) =>
        element.ValueKind != JsonValueKind.Undefined && element.TryGetProperty(name, out JsonElement value) ? value.ToString() : "";

    private static int Integer(JsonElement element, string name, int fallback) =>
        int.TryParse(String(element, name), NumberStyles.Integer, CultureInfo.InvariantCulture, out int value) ? value : fallback;

    private static double Double(JsonElement element, string name, double fallback) =>
        double.TryParse(String(element, name), NumberStyles.Float, CultureInfo.InvariantCulture, out double value) ? value : fallback;

    private static double ParseRatio(string value, double fallback)
    {
        if (string.IsNullOrWhiteSpace(value) || value is "0/0" or "N/A") return fallback;
        string[] parts = value.Split(['/', ':']);
        if (parts.Length == 2 && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double numerator)
            && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double denominator) && Math.Abs(denominator) > 1e-9)
            return numerator / denominator;
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed) ? parsed : fallback;
    }
}
