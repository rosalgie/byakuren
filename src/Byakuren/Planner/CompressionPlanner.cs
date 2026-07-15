using Byakuren.Models;

namespace Byakuren.Planner;

public sealed class CompressionPlanner
{
    private static readonly int[] WidthLadder = [3840, 3200, 2560, 1920, 1600, 1440, 1280, 1152, 960, 854, 768, 640, 576, 480, 426, 384, 320, 256];

    public static ModeStrategy Strategy(CompressionMode mode) => mode switch
    {
        CompressionMode.Fast => new(2, 0.97),
        CompressionMode.Balanced => new(3, 0.99),
        CompressionMode.ExtraQuality => new(5, 0.995),
        _ => throw new ArgumentOutOfRangeException(nameof(mode))
    };

    public CanonicalCanvas GetCanonicalCanvas(MediaInfo media)
    {
        (int displayWidth, int displayHeight) = DisplayGeometry(media);
        double scale = Math.Min(1.0, Math.Min(1920.0 / displayWidth, 1920.0 / displayHeight));
        int width = EvenFloor(displayWidth * scale);
        int height = EvenFloor(displayHeight * scale);
        int bitDepth = media.BitDepth > 8 ? 10 : 8;
        return new CanonicalCanvas(width, height, Math.Min(60, media.Fps), bitDepth, bitDepth == 10 ? "yuv420p10le" : "yuv420p");
    }

    public CompressionPlan CreateInitialPlan(
        CompressionRequest request,
        MediaInfo media,
        EncoderProfile profile,
        long audioPayloadBytes,
        ContentAnalysis? contentAnalysis = null)
    {
        long workingBytes = (long)Math.Floor(request.TargetBytes * request.WorkingTargetRatio);
        long muxReserve = Math.Max(4096L, (long)Math.Floor(request.TargetBytes * 0.003));
        long videoBytes = Math.Max(25_000, workingBytes - audioPayloadBytes - muxReserve);
        int videoKbps = Math.Max(35, (int)Math.Floor(videoBytes * 8.0 / media.DurationSeconds / 1000.0));
        double totalKbps = request.TargetBytes * 8.0 / media.DurationSeconds / 1000.0;
        double fps = SelectFps(request.Mode, media.Fps, totalKbps);
        (int sourceWidth, int sourceHeight) = DisplayGeometry(media);
        double aspect = sourceWidth / (double)sourceHeight;
        double targetBpppf = request.Mode switch { CompressionMode.Fast => 0.040, CompressionMode.Balanced => 0.050, _ => 0.060 };
        double idealWidth = Math.Sqrt(videoKbps * 1000.0 * aspect / Math.Max(1.0, fps * targetBpppf));
        int width = SelectWidth(sourceWidth, idealWidth);
        int height = EvenFloor(width / aspect);
        string pixelFormat = media.BitDepth > 8 && profile.VideoCodec is "x265" or "av1" or "vp9" ? "yuv420p10le" : "yuv420p";
        string filter = BuildVideoFilter(media, width, height, fps, profile.IsHardware);

        return new CompressionPlan
        {
            Profile = profile,
            Mode = request.Mode,
            HardCapBytes = request.TargetBytes,
            WorkingTargetBytes = workingBytes,
            Width = width,
            Height = height,
            Fps = fps,
            VideoKbps = videoKbps,
            AudioKbps = media.HasAudio ? request.Mode == CompressionMode.Fast ? 80 : 96 : 0,
            Preset = request.Preset ?? DefaultPreset(request.Mode),
            PixelFormat = pixelFormat,
            VideoFilter = filter,
            CanonicalCanvas = GetCanonicalCanvas(media),
            ContentClass = contentAnalysis?.ContentClass ?? "general",
            ContentAnalysis = contentAnalysis
        };
    }

    public int CorrectBitrate(CompressionPlan plan, EncodeAttempt current, IReadOnlyList<CorrectionPoint> history)
    {
        long targetTotal = plan.WorkingTargetBytes;
        long targetPayload = Math.Max(25_000, targetTotal - current.AudioPayloadBytes - current.MuxOverheadBytes);

        CorrectionPoint? lower = history.Where(x => x.VideoPayloadBytes <= targetPayload).OrderByDescending(x => x.VideoPayloadBytes).FirstOrDefault();
        CorrectionPoint? upper = history.Where(x => x.VideoPayloadBytes >= targetPayload).OrderBy(x => x.VideoPayloadBytes).FirstOrDefault();
        double guess;
        if (lower is not null && upper is not null && upper.VideoKbps != lower.VideoKbps && upper.VideoPayloadBytes != lower.VideoPayloadBytes)
        {
            guess = lower.VideoKbps + (targetPayload - lower.VideoPayloadBytes) / (double)(upper.VideoPayloadBytes - lower.VideoPayloadBytes) * (upper.VideoKbps - lower.VideoKbps);
        }
        else
        {
            guess = plan.VideoKbps * targetPayload / (double)Math.Max(1, current.VideoPayloadBytes);
        }

        int minStep = plan.Mode switch { CompressionMode.Fast => 12, CompressionMode.Balanced => 8, _ => 5 };
        int next = Math.Max(35, (int)Math.Round(guess));
        if (next == plan.VideoKbps)
            next += current.VideoPayloadBytes < targetPayload ? minStep : -minStep;
        return Math.Max(35, next);
    }

    private static double SelectFps(CompressionMode mode, double sourceFps, double totalKbps)
    {
        double capped = Math.Min(60, sourceFps);
        if (mode != CompressionMode.Fast && capped > 30 && totalKbps < 1000) return 30;
        return capped;
    }

    private static int SelectWidth(int sourceWidth, double idealWidth)
    {
        int[] candidates = WidthLadder.Where(x => x <= sourceWidth).DefaultIfEmpty(Math.Max(2, EvenFloor(sourceWidth))).ToArray();
        return candidates.OrderBy(x => Math.Abs(x - idealWidth)).First();
    }

    private static (int Width, int Height) DisplayGeometry(MediaInfo media)
    {
        int width = EvenFloor(media.Width * Math.Max(0.01, media.SampleAspectRatio));
        int height = EvenFloor(media.Height);
        if (Math.Abs(media.Rotation) % 180 == 90) (width, height) = (height, width);
        return (Math.Max(2, width), Math.Max(2, height));
    }

    private static string BuildVideoFilter(MediaInfo media, int width, int height, double fps, bool hardware)
    {
        List<string> parts = new List<string> { "setsar=1", $"scale={width}:{height}:flags=lanczos", $"fps={fps:0.########}:round=near" };
        if (hardware) parts.Add("format=nv12,hwupload");
        return string.Join(',', parts);
    }

    private static string DefaultPreset(CompressionMode mode) => mode switch
    {
        CompressionMode.Fast => "superfast",
        CompressionMode.Balanced => "medium",
        _ => "slow"
    };

    private static int EvenFloor(double value) => Math.Max(2, (int)Math.Floor(value / 2) * 2);
}
