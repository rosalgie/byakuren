using Byakuren.Execution;
using Byakuren.Models;
using Byakuren.Probe;

namespace Byakuren.Encoding;

public sealed record AudioArtifact(string? Path, long PayloadBytes, int Kbps);

public sealed class FFmpegEncoder(ProcessRunner runner, FFmpegProbe probe)
{
    private readonly Dictionary<string, string> _passLogs = new(StringComparer.Ordinal);

    public async Task<AudioArtifact> EncodeAudioAsync(
        CompressionRequest request,
        MediaInfo media,
        EncoderProfile profile,
        string tempDirectory,
        int audioKbps,
        CancellationToken cancellationToken)
    {
        if (!media.HasAudio || audioKbps <= 0) return new AudioArtifact(null, 0, 0);
        string extension = profile.AudioCodec == "opus" ? ".opus" : ".m4a";
        string path = Path.Combine(tempDirectory, "audio" + extension);
        await runner.RunCheckedAsync(request.FFmpegPath,
        [
            "-y", "-i", media.Path, "-map", "0:a:0", "-vn", "-c:a", profile.AudioEncoder,
            "-b:a", $"{audioKbps}k", path
        ], cancellationToken).ConfigureAwait(false);
        long payload = await probe.GetPacketPayloadBytesAsync(request.FFprobePath, path, "a:0", cancellationToken).ConfigureAwait(false);
        if (payload <= 0) payload = new FileInfo(path).Length;
        return new AudioArtifact(path, payload, audioKbps);
    }

    public async Task<EncodeAttempt> EncodeAttemptAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        AudioArtifact audio,
        string tempDirectory,
        int attempt,
        string hardwareDevice,
        CancellationToken cancellationToken)
    {
        string videoPath = Path.Combine(tempDirectory, $"video-{attempt}.mkv");
        string candidatePath = Path.Combine(tempDirectory, $"candidate-{attempt}{plan.Profile.Extension}");
        IReadOnlyList<string> common = BuildVideoArguments(plan, hardwareDevice);

        if (plan.Mode != CompressionMode.Fast && plan.Profile.RequiredPasses >= 2)
        {
            if (!_passLogs.TryGetValue(plan.Identity, out string? passLog))
            {
                passLog = Path.Combine(tempDirectory, $"pass-{_passLogs.Count}");
                _passLogs[plan.Identity] = passLog;
                await runner.RunCheckedAsync(request.FFmpegPath,
                [
                    "-y", "-i", media.Path, .. common, "-pass", "1", "-passlogfile", passLog,
                    "-an", "-f", "null", "-"
                ], cancellationToken).ConfigureAwait(false);
            }
            await runner.RunCheckedAsync(request.FFmpegPath,
            [
                "-y", "-i", media.Path, .. common, "-pass", "2", "-passlogfile", passLog,
                "-an", videoPath
            ], cancellationToken).ConfigureAwait(false);
        }
        else
        {
            await runner.RunCheckedAsync(request.FFmpegPath,
            [
                "-y", "-i", media.Path, .. common, "-an", videoPath
            ], cancellationToken).ConfigureAwait(false);
        }

        long videoPayload = await probe.GetPacketPayloadBytesAsync(request.FFprobePath, videoPath, "v:0", cancellationToken).ConfigureAwait(false);
        if (videoPayload <= 0) videoPayload = new FileInfo(videoPath).Length;
        List<string> mux = new List<string> { "-y", "-i", videoPath };
        if (audio.Path is not null)
            mux.AddRange(["-i", audio.Path, "-map", "0:v:0", "-map", "1:a:0"]);
        else
            mux.AddRange(["-map", "0:v:0"]);
        mux.AddRange(["-c", "copy"]);
        if (plan.Profile.Container == "mp4") mux.AddRange(["-movflags", "+faststart"]);
        mux.Add(candidatePath);
        await runner.RunCheckedAsync(request.FFmpegPath, mux, cancellationToken).ConfigureAwait(false);

        long size = new FileInfo(candidatePath).Length;
        long overhead = Math.Max(0, size - videoPayload - audio.PayloadBytes);
        try { File.Delete(videoPath); } catch { }
        string? eligiblePath = candidatePath;
        if (size > plan.HardCapBytes)
        {
            File.Delete(candidatePath);
            eligiblePath = null;
        }

        return new EncodeAttempt
        {
            Attempt = attempt,
            Plan = plan,
            SizeBytes = size,
            VideoPayloadBytes = videoPayload,
            AudioPayloadBytes = audio.PayloadBytes,
            MuxOverheadBytes = overhead,
            OutputPath = eligiblePath
        };
    }

    private static IReadOnlyList<string> BuildVideoArguments(CompressionPlan plan, string hardwareDevice)
    {
        List<string> arguments = new List<string>();
        if (plan.Profile.IsHardware) arguments.AddRange(["-vaapi_device", hardwareDevice]);
        if (!string.IsNullOrWhiteSpace(plan.VideoFilter)) arguments.AddRange(["-vf", plan.VideoFilter]);
        arguments.AddRange(["-c:v", plan.Profile.Encoder]);
        arguments.AddRange(CapabilityProbe.PresetArguments(plan.Profile, plan.Preset));
        if (!plan.Profile.IsHardware) arguments.AddRange(["-pix_fmt", plan.PixelFormat]);
        arguments.AddRange(["-b:v", $"{plan.VideoKbps}k"]);
        arguments.AddRange(plan.Profile.PrivateArguments);
        return arguments;
    }
}
