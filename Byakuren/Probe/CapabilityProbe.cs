using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Byakuren.Execution;
using Byakuren.IO;
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
        string build = await ffmpegProbe
            .GetFFmpegBuildAsync(request.FFmpegPath, cancellationToken)
            .ConfigureAwait(false);
        string device = profile.IsHardware ? ResolveHardwareDevice(request.HardwareDevice) : "none";

        string driver = "software";
        if (profile.IsHardware)
        {
            driver = await GetDriverFingerprintAsync(device, cancellationToken)
                .ConfigureAwait(false);
        }

        string pixelFormat = "yuv420p";
        if (profile.IsHardware)
            pixelFormat = "nv12";
        else if (request.OutputBitDepth == "10" && profile.VideoCodec is "x265" or "av1" or "vp9")
            pixelFormat = "yuv420p10le";

        string keyMaterial = $"probe-v2|{build}|{RuntimeInformation.OSDescription}|" +
            $"{driver}|{device}|{profile.Backend}|{profile.Encoder}|" +
            $"{profile.AudioEncoder}|{profile.RateControlAdapter}|" +
            $"{profile.Container}|{pixelFormat}";
        string key = Hash(keyMaterial);
        Dictionary<string, CapabilityProbeResult> cache = await LoadCacheAsync(cancellationToken).ConfigureAwait(false);
        if (cache.TryGetValue(key, out CapabilityProbeResult? cached))
            return cached;

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
            if (profile.IsHardware)
                baseArguments.AddRange(["-vaapi_device", device]);
            baseArguments.AddRange(["-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=0.4"]);
            if (profile.IsHardware)
                baseArguments.AddRange(["-vf", "format=nv12,hwupload"]);
            else
                baseArguments.AddRange(["-pix_fmt", pixelFormat]);
            baseArguments.AddRange(["-c:v", profile.Encoder, "-b:v", "200k"]);
            baseArguments.AddRange(PresetArguments(profile, "medium", preview: true));

            if (profile.RequiredPasses >= 2)
            {
                ProcessResult first = await runner.RunAsync(
                    request.FFmpegPath,
                    [.. baseArguments, "-pass", "1", "-passlogfile", passLog, "-an", "-f", "null", "-"],
                    cancellationToken).ConfigureAwait(false);
                if (first.ExitCode != 0)
                    throw new InvalidOperationException(first.StandardError);

                ProcessResult second = await runner.RunAsync(
                    request.FFmpegPath,
                    [.. baseArguments, "-pass", "2", "-passlogfile", passLog, "-an", videoOutput],
                    cancellationToken).ConfigureAwait(false);
                if (second.ExitCode != 0)
                    throw new InvalidOperationException(second.StandardError);
            }
            else
            {
                ProcessResult encoded = await runner.RunAsync(
                    request.FFmpegPath,
                    [.. baseArguments, "-an", videoOutput],
                    cancellationToken).ConfigureAwait(false);
                if (encoded.ExitCode != 0)
                    throw new InvalidOperationException(encoded.StandardError);
            }

            ProcessResult encodedAudio = await runner.RunAsync(request.FFmpegPath,
            [
                "-y", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=0.4",
                "-c:a", profile.AudioEncoder, "-b:a", "64k", audioOutput
            ], cancellationToken).ConfigureAwait(false);
            if (encodedAudio.ExitCode != 0)
                throw new InvalidOperationException(encodedAudio.StandardError);

            List<string> muxArguments =
                ["-y", "-i", videoOutput, "-i", audioOutput, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy"];
            if (profile.Container == "mp4")
                muxArguments.AddRange(["-movflags", "+faststart"]);
            muxArguments.Add(deliveryOutput);
            ProcessResult muxed = await runner.RunAsync(
                request.FFmpegPath,
                muxArguments,
                cancellationToken).ConfigureAwait(false);
            if (muxed.ExitCode != 0)
                throw new InvalidOperationException(muxed.StandardError);

            ProcessResult decoded = await runner.RunAsync(
                request.FFmpegPath,
                ["-v", "error", "-i", deliveryOutput, "-f", "null", "-"],
                cancellationToken).ConfigureAwait(false);
            if (decoded.ExitCode != 0)
                throw new InvalidOperationException(decoded.StandardError);
            success = true;
        }
        catch (Exception exception) when (IsRecoverableProbeFailure(exception))
        {
            error = LastUsefulLine(exception.Message);
        }
        finally
        {
            FileSystemCleanup.DeleteDirectory(temp, recursive: true, runner.ReportWarning);
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
            "svtav1" =>
            [
                "-preset",
                preview ? "12" : Math.Clamp(12 - rank, 0, 12).ToString()
            ],
            "aom" =>
            [
                "-cpu-used",
                preview ? "8" : Math.Clamp(9 - rank, 0, 8).ToString()
            ],
            "vpx" =>
            [
                "-deadline", "good", "-cpu-used",
                preview ? "8" : Math.Clamp(9 - rank, 0, 8).ToString()
            ],
            "rav1e" =>
            [
                "-speed",
                preview ? "10" : Math.Clamp(11 - rank, 0, 10).ToString()
            ],
            "vaapi" => [],
            _ => ["-preset", preset]
        };
    }

    private async Task<string> GetDriverFingerprintAsync(string device, CancellationToken cancellationToken)
    {
        try
        {
            ProcessResult result = await runner.RunAsync(
                "vainfo",
                ["--display", "drm", "--device", device],
                cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0)
                return Hash(result.CombinedOutput);

            runner.ReportWarning(
                $"Could not query the driver for device '{device}'; using a device-file fingerprint instead.",
                new InvalidOperationException(LastUsefulLine(result.StandardError)));
        }
        catch (Exception exception) when (IsRecoverableProbeFailure(exception))
        {
            runner.ReportWarning(
                $"Could not query the driver for device '{device}'; using a device-file fingerprint instead.",
                exception);
        }

        if (!File.Exists(device))
            return "device-unavailable";

        try
        {
            return $"device:{new FileInfo(device).Length}:{File.GetLastWriteTimeUtc(device):O}";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            runner.ReportWarning(
                $"Could not read metadata for device '{device}'; capability caching will use a fallback key.",
                exception);
            return "device-metadata-unavailable";
        }
    }

    private static string ResolveHardwareDevice(string requested)
    {
        if (!string.Equals(requested, "auto", StringComparison.OrdinalIgnoreCase))
            return requested;
        if (OperatingSystem.IsWindows())
            throw new InvalidOperationException(
                "Automatic VAAPI device discovery is unavailable on this operating system; " +
                "provide an explicit device on a supported host.");
        const string dri = "/dev/dri";
        string? candidate = null;
        if (Directory.Exists(dri))
        {
            candidate = Directory
                .EnumerateFiles(dri, "renderD*")
                .OrderBy(path => path, StringComparer.Ordinal)
                .FirstOrDefault();
        }

        if (candidate is null)
        {
            throw new InvalidOperationException(
                "No VAAPI render device was discovered; provide --hardware-device explicitly.");
        }

        return candidate;
    }

    private static string CachePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Byakuren", "encoder-capabilities-v2.json");

    private async Task<Dictionary<string, CapabilityProbeResult>> LoadCacheAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (!File.Exists(CachePath))
                return new();
            await using FileStream stream = File.OpenRead(CachePath);
            Dictionary<string, CapabilityProbeResult>? cache = await JsonSerializer
                .DeserializeAsync<Dictionary<string, CapabilityProbeResult>>(
                    stream,
                    JsonOptions,
                    cancellationToken)
                .ConfigureAwait(false);

            return cache ?? new();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or JsonException)
        {
            runner.ReportWarning($"Could not read capability cache '{CachePath}'; probing again.", exception);
            return new();
        }
    }

    private async Task SaveCacheAsync(Dictionary<string, CapabilityProbeResult> cache, CancellationToken cancellationToken)
    {
        string temporary = CachePath + $".{Guid.NewGuid():N}.tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CachePath)!);
            await using (FileStream stream = File.Create(temporary))
                await JsonSerializer.SerializeAsync(stream, cache, JsonOptions, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, CachePath, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            runner.ReportWarning($"Could not update capability cache '{CachePath}'.", exception);
        }
        finally
        {
            FileSystemCleanup.DeleteFile(temporary, runner.ReportWarning);
        }
    }

    private static string Hash(string value)
    {
        byte[] bytes = System.Text.Encoding.UTF8.GetBytes(value);
        byte[] hash = SHA256.HashData(bytes);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string LastUsefulLine(string value)
    {
        return value
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .LastOrDefault()
            ?.Trim() ?? "functional probe failed";
    }

    private static bool IsRecoverableProbeFailure(Exception exception) =>
        exception is Win32Exception or
            IOException or
            UnauthorizedAccessException or
            InvalidOperationException or
            NotSupportedException;
}
