using Byakuren.Execution;
using Byakuren.Models;
using Byakuren.Probe;

namespace Byakuren.Encoding;

public sealed class FFmpegEncoder(ProcessRunner runner, FFmpegProbe probe)
{
    private readonly Dictionary<string, string> _passLogs = new(StringComparer.Ordinal);

    public async Task<AudioArtifact> EncodeAudioAsync(
        CompressionRequest request,
        MediaInfo media,
        EncoderProfile profile,
        string tempDirectory,
        AudioPlan audioPlan,
        CancellationToken cancellationToken)
    {
        if (!media.HasAudio || audioPlan.Mode == "mute" || audioPlan.Kbps <= 0) return new AudioArtifact(null, 0, AudioPlan.Mute);
        if (audioPlan.Mode == "copy")
        {
            string copyExtension = profile.AudioCodec == "opus" ? ".opus" : ".m4a";
            string copyPath = Path.Combine(tempDirectory, $"audio-copy-{Sanitize(audioPlan.Identity)}{copyExtension}");
            await runner.RunCheckedAsync(request.FFmpegPath,
            [
                "-y", "-i", media.Path, "-map", "0:a:0", "-vn", "-c:a", "copy", copyPath
            ], cancellationToken).ConfigureAwait(false);
            long copyPayload = await probe.GetPacketPayloadBytesAsync(request.FFprobePath, copyPath, "a:0", cancellationToken).ConfigureAwait(false);
            return new AudioArtifact(copyPath, copyPayload > 0 ? copyPayload : new FileInfo(copyPath).Length, audioPlan);
        }
        string extension = profile.AudioCodec == "opus" ? ".opus" : ".m4a";
        string path = Path.Combine(tempDirectory, $"audio-{Sanitize(audioPlan.Identity)}{extension}");
        await runner.RunCheckedAsync(request.FFmpegPath,
        [
            "-y", "-i", media.Path, "-map", "0:a:0", "-vn", "-c:a", profile.AudioEncoder,
            "-b:a", $"{audioPlan.Kbps}k", path
        ], cancellationToken).ConfigureAwait(false);
        long payload = await probe.GetPacketPayloadBytesAsync(request.FFprobePath, path, "a:0", cancellationToken).ConfigureAwait(false);
        if (payload <= 0) payload = new FileInfo(path).Length;
        return new AudioArtifact(path, payload, audioPlan);
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

    public async Task<string> EncodePreviewAsync(
        CompressionRequest request,
        MediaInfo media,
        CompressionPlan plan,
        SampleWindow window,
        string tempDirectory,
        string hardwareDevice,
        CancellationToken cancellationToken)
    {
        string path = Path.Combine(tempDirectory, $"preview-{Guid.NewGuid():N}.mkv");
        IReadOnlyList<string> videoArguments = BuildVideoArguments(plan, hardwareDevice);
        await runner.RunCheckedAsync(request.FFmpegPath,
        [
            "-y", "-ss", Number(window.StartSeconds), "-t", Number(window.DurationSeconds), "-i", media.Path,
            .. videoArguments, "-an", path
        ], cancellationToken).ConfigureAwait(false);
        return path;
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
        if (plan.MaxrateKbps.HasValue) arguments.AddRange(["-maxrate", $"{plan.MaxrateKbps.Value}k"]);
        if (plan.BufsizeKbits.HasValue) arguments.AddRange(["-bufsize", $"{plan.BufsizeKbits.Value}k"]);
        arguments.AddRange(plan.ColorArguments);
        arguments.AddRange(plan.Profile.PrivateArguments);
        return arguments;
    }

    private static string Sanitize(string value) => string.Concat(value.Select(character => char.IsLetterOrDigit(character) ? character : '_'));
    private static string Number(double value) => value.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
}
