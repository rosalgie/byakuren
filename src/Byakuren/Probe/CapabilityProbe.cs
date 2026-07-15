using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Byakuren.Execution;
using Byakuren.Models;

namespace Byakuren.Probe;

public sealed class CapabilityProbe(ProcessRunner runner, FFmpegProbe ffmpegProbe)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public async Task<CapabilityProbeResult> ProbeAsync(
        CompressionRequest request,
        EncoderProfile profile,
        CancellationToken cancellationToken)
    {
        string build = await ffmpegProbe.GetFFmpegBuildAsync(request.FFmpegPath, cancellationToken).ConfigureAwait(false);
        string device = profile.IsHardware ? ResolveHardwareDevice(request.HardwareDevice) : "none";
        string driver = profile.IsHardware ? await GetDriverFingerprintAsync(device, cancellationToken).ConfigureAwait(false) : "software";
        string pixelFormat = profile.IsHardware
            ? "nv12"
            : request.OutputBitDepth == "10" && profile.VideoCodec is "x265" or "av1" or "vp9" ? "yuv420p10le" : "yuv420p";
        string keyMaterial = $"probe-v2|{build}|{RuntimeInformation.OSDescription}|{driver}|{device}|{profile.Backend}|{profile.Encoder}|{profile.AudioEncoder}|{profile.RateControlAdapter}|{profile.Container}|{pixelFormat}";
        string key = Hash(keyMaterial);
        Dictionary<string, CapabilityProbeResult> cache = await LoadCacheAsync(cancellationToken).ConfigureAwait(false);
        if (cache.TryGetValue(key, out CapabilityProbeResult? cached)) return cached;

        string temp = Path.Combine(Path.GetTempPath(), $"byakuren-capability-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temp);
        string videoOutput = Path.Combine(temp, "video" + profile.Extension);
        string audioExtension = profile.AudioCodec == "opus" ? ".opus" : ".m4a";
        string audioOutput = Path.Combine(temp, "audio" + audioExtension);
        string deliveryOutput = Path.Combine(temp, "delivery" + profile.Extension);
        string passLog = Path.Combine(temp, "pass");
        bool success = false;
        string error = "";
        try
        {
            List<string> baseArguments = ["-y"];
            if (profile.IsHardware) baseArguments.AddRange(["-vaapi_device", device]);
            baseArguments.AddRange(["-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=0.4"]);
            if (profile.IsHardware) baseArguments.AddRange(["-vf", "format=nv12,hwupload"]);
            else baseArguments.AddRange(["-pix_fmt", pixelFormat]);
            baseArguments.AddRange(["-c:v", profile.Encoder, "-b:v", "200k"]);
            baseArguments.AddRange(PresetArguments(profile, "medium", preview: true));

            if (profile.RequiredPasses >= 2)
            {
                ProcessResult first = await runner.RunAsync(request.FFmpegPath,
                    [.. baseArguments, "-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "-"], cancellationToken).ConfigureAwait(false);
                if (first.ExitCode != 0) throw new InvalidOperationException(first.StandardError);
                ProcessResult second = await runner.RunAsync(request.FFmpegPath,
                    [.. baseArguments, "-pass", "2", "-passlogfile", passLog, "-an", videoOutput], cancellationToken).ConfigureAwait(false);
                if (second.ExitCode != 0) throw new InvalidOperationException(second.StandardError);
            }
            else
            {
                ProcessResult encoded = await runner.RunAsync(request.FFmpegPath, [.. baseArguments, "-an", videoOutput], cancellationToken).ConfigureAwait(false);
                if (encoded.ExitCode != 0) throw new InvalidOperationException(encoded.StandardError);
            }

            ProcessResult encodedAudio = await runner.RunAsync(request.FFmpegPath,
            [
                "-y", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=0.4",
                "-c:a", profile.AudioEncoder, "-b:a", "64k", audioOutput
            ], cancellationToken).ConfigureAwait(false);
            if (encodedAudio.ExitCode != 0) throw new InvalidOperationException(encodedAudio.StandardError);

            List<string> muxArguments =
                ["-y", "-i", videoOutput, "-i", audioOutput, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy"];
            if (profile.Container == "mp4") muxArguments.AddRange(["-movflags", "+faststart"]);
            muxArguments.Add(deliveryOutput);
            ProcessResult muxed = await runner.RunAsync(request.FFmpegPath, muxArguments, cancellationToken).ConfigureAwait(false);
            if (muxed.ExitCode != 0) throw new InvalidOperationException(muxed.StandardError);

            ProcessResult decoded = await runner.RunAsync(request.FFmpegPath, ["-v", "error", "-i", deliveryOutput, "-f", "null", "-"], cancellationToken).ConfigureAwait(false);
            if (decoded.ExitCode != 0) throw new InvalidOperationException(decoded.StandardError);
            success = true;
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            error = LastUsefulLine(exception.Message);
        }
        finally
        {
            try { Directory.Delete(temp, recursive: true); } catch { }
        }

        CapabilityProbeResult result = new()
        {
            Success = success,
            Backend = profile.Backend,
            Encoder = profile.Encoder,
            RateControlAdapter = profile.RateControlAdapter,
            PixelFormat = pixelFormat,
            Container = profile.Container,
            Device = device,
            Driver = driver,
            FFmpegBuild = build,
            Os = RuntimeInformation.OSDescription,
            Error = error
        };
        cache[key] = result;
        await SaveCacheAsync(cache, cancellationToken).ConfigureAwait(false);
        return result;
    }

    public static IReadOnlyList<string> PresetArguments(EncoderProfile profile, string preset, bool preview = false)
    {
        int rank = preset.ToLowerInvariant() switch
        {
            "ultrafast" => 1,
            "superfast" => 2,
            "veryfast" => 3,
            "faster" => 4,
            "fast" => 5,
            "medium" => 6,
            "slow" => 7,
            "slower" => 8,
            "veryslow" => 9,
            "placebo" => 10,
            _ => throw new ArgumentException($"Unsupported preset '{preset}'.")
        };
        return profile.PresetKind switch
        {
            "svtav1" => ["-preset", preview ? "12" : Math.Clamp(12 - rank, 0, 12).ToString()],
            "aom" => ["-cpu-used", preview ? "8" : Math.Clamp(9 - rank, 0, 8).ToString()],
            "vpx" => ["-deadline", "good", "-cpu-used", preview ? "8" : Math.Clamp(9 - rank, 0, 8).ToString()],
            "rav1e" => ["-speed", preview ? "10" : Math.Clamp(11 - rank, 0, 10).ToString()],
            "vaapi" => [],
            _ => ["-preset", preset]
        };
    }

    private async Task<string> GetDriverFingerprintAsync(string device, CancellationToken cancellationToken)
    {
        try
        {
            ProcessResult result = await runner.RunAsync("vainfo", ["--display", "drm", "--device", device], cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0) return Hash(result.CombinedOutput);
        }
        catch { }
        return File.Exists(device) ? $"device:{new FileInfo(device).Length}:{File.GetLastWriteTimeUtc(device):O}" : "device-unavailable";
    }

    private static string ResolveHardwareDevice(string requested)
    {
        if (!string.Equals(requested, "auto", StringComparison.OrdinalIgnoreCase)) return requested;
        if (OperatingSystem.IsWindows()) throw new InvalidOperationException("Automatic VAAPI device discovery is unavailable on this operating system; provide an explicit device on a supported host.");
        const string dri = "/dev/dri";
        string? candidate = Directory.Exists(dri)
            ? Directory.EnumerateFiles(dri, "renderD*").OrderBy(x => x, StringComparer.Ordinal).FirstOrDefault()
            : null;
        return candidate ?? throw new InvalidOperationException("No VAAPI render device was discovered; provide --hardware-device explicitly.");
    }

    private static string CachePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Byakuren", "encoder-capabilities-v2.json");

    private static async Task<Dictionary<string, CapabilityProbeResult>> LoadCacheAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (!File.Exists(CachePath)) return new();
            await using FileStream stream = File.OpenRead(CachePath);
            return await JsonSerializer.DeserializeAsync<Dictionary<string, CapabilityProbeResult>>(stream, JsonOptions, cancellationToken).ConfigureAwait(false) ?? new();
        }
        catch { return new(); }
    }

    private static async Task SaveCacheAsync(Dictionary<string, CapabilityProbeResult> cache, CancellationToken cancellationToken)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CachePath)!);
            string temporary = CachePath + $".{Guid.NewGuid():N}.tmp";
            await using (FileStream stream = File.Create(temporary))
                await JsonSerializer.SerializeAsync(stream, cache, JsonOptions, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, CachePath, overwrite: true);
        }
        catch { }
    }

    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    private static string LastUsefulLine(string value) => value.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? "functional probe failed";
}
