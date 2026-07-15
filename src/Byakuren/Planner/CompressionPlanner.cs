using System.Globalization;
using Byakuren.Analysis;
using Byakuren.Metrics;
using Byakuren.Models;

namespace Byakuren.Planner;

public sealed class CompressionPlanner
{
    private static readonly int[] WidthLadder = [3840, 3200, 2560, 1920, 1600, 1440, 1280, 1152, 960, 854, 768, 640, 576, 480, 426, 384, 320, 256];

    public static ModeStrategy Strategy(CompressionMode mode) => mode switch
    {
        CompressionMode.Fast => new(2, 0.97, 1, 0, 0, 1),
        CompressionMode.Balanced => new(2, 0.99, 3, 1, 2, 2),
        CompressionMode.ExtraQuality => new(5, 0.995, 3, 3, 8, 3),
        _ => throw new ArgumentOutOfRangeException(nameof(mode))
    };

    public CanonicalCanvas GetCanonicalCanvas(MediaInfo media, CropAnalysis? crop = null)
    {
        (int displayWidth, int displayHeight) = DisplayGeometry(media, crop);
        double scale = Math.Min(1.0, Math.Min(1920.0 / displayWidth, 1920.0 / displayHeight));
        int width = EvenFloor(displayWidth * scale);
        int height = EvenFloor(displayHeight * scale);
        int bitDepth = Math.Min(10, Math.Max(8, media.BitDepth));
        return new CanonicalCanvas(width, height, Math.Min(60, media.Fps), bitDepth, bitDepth == 10 ? "yuv420p10le" : "yuv420p");
    }

    public IReadOnlyList<AudioPlan> CreateAudioPlans(
        CompressionRequest request,
        MediaInfo media,
        EncoderProfile profile,
        ComplexityAnalysis complexity,
        string contentClass)
    {
        if (!media.HasAudio) return [AudioPlan.Mute];
        double totalKbps = request.TargetBytes * 8.0 / media.DurationSeconds / 1000.0;
        int[] baseRates = totalKbps switch
        {
            < 220 => [48, 40, 32],
            < 300 => [64, 56, 48, 40],
            < 420 => [72, 64, 56, 48],
            < 650 => [80, 72, 64, 56],
            < 950 => [96, 80, 72, 64],
            _ => [128, 96, 80, 64]
        };
        int priorityBias = (request.AudioPriority, contentClass) switch
        {
            (AudioPriority.Speech, _) => 12,
            (AudioPriority.Visual, _) => -8,
            (_, "talking_head") => 8,
            _ => 0
        };
        int complexityBias = complexity.DetailBucket switch { "VeryLow" => 8, "High" or "VeryHigh" => -8, _ => 0 };
        int bias = priorityBias + complexityBias;
        int channelFloor = media.AudioChannels >= 6 ? 128 : media.AudioChannels > 2 ? 96 : 32;
        int[] rates = baseRates.Select(rate => Math.Max(channelFloor, rate + bias)).Distinct().ToArray();
        int retain = request.Mode switch { CompressionMode.Fast => 2, CompressionMode.Balanced => 2, _ => 3 };
        List<AudioPlan> plans = [];
        int rank = 100;
        if (media.AudioCodec.Equals(profile.AudioCodec, StringComparison.OrdinalIgnoreCase) && media.AudioBitrateKbps > 0 && rates.Any(rate => media.AudioBitrateKbps <= rate))
            plans.Add(new AudioPlan("copy", media.AudioBitrateKbps, media.AudioCodec, $"copy original audio ({media.AudioBitrateKbps}k)", rank + 1));
        foreach (int rate in rates.Take(retain))
            plans.Add(new AudioPlan("encode", rate, profile.AudioCodec, $"{profile.AudioCodec} {rate}k", rank--));
        if (request.Mode == CompressionMode.Fast || totalKbps < 175) plans.Add(AudioPlan.Mute);
        return plans.DistinctBy(plan => plan.Identity).ToArray();
    }

    public IReadOnlyList<CompressionPlan> CreateCandidatePlans(
        CompressionRequest request,
        MediaInfo media,
        EncoderProfile profile,
        AudioArtifact audio,
        ContentAnalysis? contentAnalysis,
        ComplexityAnalysis complexity,
        CropAnalysis crop,
        IReadOnlyList<SampleWindow> sampleWindows)
    {
        long workingBytes = (long)Math.Floor(request.TargetBytes * request.WorkingTargetRatio);
        long muxReserve = MuxReserveBytes(request.TargetBytes, request.Mode, profile.Container, audio.Plan.Mode);
        long videoBytes = Math.Max(25_000, workingBytes - audio.PayloadBytes - muxReserve);
        int videoKbps = Math.Max(35, (int)Math.Floor(videoBytes * 8.0 / media.DurationSeconds / 1000.0));
        double totalKbps = request.TargetBytes * 8.0 / media.DurationSeconds / 1000.0;
        string contentClass = contentAnalysis?.ContentClass ?? "general";
        (int sourceWidth, int sourceHeight) = DisplayGeometry(media, crop);
        double aspect = sourceWidth / (double)sourceHeight;
        CanonicalCanvas canvas = GetCanonicalCanvas(media, crop);
        IReadOnlyList<double> fpsCandidates = TargetFpsCandidates(request.Mode, media.Fps, media.DurationSeconds, totalKbps, complexity, profile);
        List<CompressionPlan> plans = [];

        foreach (EncoderProfile tunedProfile in TuningProfiles(profile, request.Mode, contentClass, totalKbps))
        {
            foreach (double fps in fpsCandidates)
            {
                IReadOnlyList<(int Width, string Origin, double Score)> widths = WidthCandidates(request.Mode, sourceWidth, sourceHeight, fps, videoKbps, complexity, tunedProfile);
                foreach ((int width, string origin, double widthScore) in widths)
                {
                    int height = EvenFloor(width / aspect);
                    double bpppf = videoKbps * 1000.0 / Math.Max(1, width * (double)height * fps);
                    foreach ((string preprocess, string preprocessFilter) in PreprocessCandidates(request.PreprocessMode, request.Mode, contentClass, totalKbps, bpppf))
                    {
                        string pixelFormat = PixelFormat(request.OutputBitDepth, media, tunedProfile);
                        string geometryFilter = GeometryFilter(media, crop, width, height, fps);
                        string videoFilter = JoinFilters(crop.Filter, preprocessFilter, geometryFilter, tunedProfile.IsHardware ? "format=nv12,hwupload" : "");
                        (IReadOnlyList<string> colorArguments, IReadOnlyList<string> preserved, IReadOnlyList<string> omitted) = ColorMetadata(media);
                        int? maxrate = request.VBVMode == VBVMode.Streaming && tunedProfile.VideoCodec != "av1" ? Math.Max(35, (int)Math.Ceiling(videoKbps * 1.5)) : null;
                        int? bufsize = maxrate.HasValue ? maxrate.Value * 2 : null;
                        double fpsRetention = Math.Min(1, fps / Math.Max(1, Math.Min(60, media.Fps)));
                        bool lowMotion = complexity.MotionBucket is "VeryLow" or "Low";
                        double fpsWeight = request.Mode == CompressionMode.Fast || !lowMotion ? 80 : 8;
                        double gameplayMotionBonus = contentClass == "gameplay" && !lowMotion && fpsRetention > 0.99 ? 10 : 0;
                        double spatialQuality = Math.Min(100, bpppf * 1000);
                        double heuristic = widthScore + fpsRetention * fpsWeight + spatialQuality + gameplayMotionBonus + audio.Plan.Rank * 0.35 + TuningBonus(tunedProfile, profile);
                        plans.Add(new CompressionPlan
                        {
                            Profile = tunedProfile,
                            Mode = request.Mode,
                            HardCapBytes = request.TargetBytes,
                            WorkingTargetBytes = workingBytes,
                            Width = width,
                            Height = height,
                            Fps = fps,
                            VideoKbps = videoKbps,
                            AudioKbps = audio.Plan.Kbps,
                            AudioPlan = audio.Plan,
                            Preset = request.Preset ?? DefaultPreset(request.Mode, tunedProfile),
                            PixelFormat = pixelFormat,
                            VideoFilter = videoFilter,
                            GeometryFilter = geometryFilter,
                            PreprocessFilter = preprocessFilter,
                            Preprocess = preprocess,
                            CanonicalCanvas = canvas,
                            MetricReferenceFilter = MetricReferenceFilter(media, crop, canvas),
                            ContentClass = contentClass,
                            ContentAnalysis = contentAnalysis,
                            ComplexityAnalysis = complexity,
                            CropAnalysis = crop,
                            BitsPerPixelPerFrame = bpppf,
                            HeuristicScore = heuristic,
                            WidthOrigin = origin,
                            MuxReserveBytes = muxReserve,
                            ColorArguments = colorArguments,
                            PreservedColorMetadata = preserved,
                            OmittedColorMetadata = omitted,
                            MaxrateKbps = maxrate,
                            BufsizeKbits = bufsize,
                            SampleWindows = sampleWindows
                        });
                    }
                }
            }
        }

        int candidateLimit = request.Mode switch { CompressionMode.Fast => 1, CompressionMode.Balanced => 12, _ => 24 };
        IEnumerable<CompressionPlan> ordered = plans.OrderByDescending(plan => plan.HeuristicScore);
        if (request.Mode == CompressionMode.ExtraQuality)
        {
            CompressionPlan? sourceSentinel = plans.Where(plan => plan.WidthOrigin.Contains("source-sentinel", StringComparison.Ordinal)).OrderByDescending(plan => plan.HeuristicScore).FirstOrDefault();
            CompressionPlan? lowerSentinel = plans.Where(plan => plan.WidthOrigin.Contains("lower-sentinel", StringComparison.Ordinal)).OrderByDescending(plan => plan.HeuristicScore).FirstOrDefault();
            double sourceFps = Math.Min(60, media.Fps);
            CompressionPlan? sourceFpsSentinel = plans.Where(plan => Math.Abs(plan.Fps - sourceFps) < 0.1).OrderByDescending(plan => plan.HeuristicScore).FirstOrDefault();
            CompressionPlan? lowerFpsSentinel = plans.Where(plan => plan.Fps < sourceFps - 0.1).OrderByDescending(plan => plan.Fps).ThenByDescending(plan => plan.HeuristicScore).FirstOrDefault();
            ordered = new[] { sourceSentinel, lowerSentinel, sourceFpsSentinel, lowerFpsSentinel }.Where(plan => plan is not null).Cast<CompressionPlan>().Concat(ordered);
        }
        return ordered.DistinctBy(plan => plan.Identity + "|" + plan.AudioPlan.Identity).Take(candidateLimit).ToArray();
    }

    public IReadOnlyList<CompressionPlan> CreatePreviewShortlist(IReadOnlyList<CompressionPlan> candidates, int limit)
    {
        if (limit <= 0 || candidates.Count == 0) return [];
        CompressionPlan[] ordered = candidates.OrderByDescending(plan => plan.HeuristicScore).ToArray();
        List<CompressionPlan> selected = [ordered[0]];
        HashSet<string> identities = new(StringComparer.Ordinal) { ordered[0].Identity };

        while (selected.Count < limit)
        {
            CompressionPlan? next = ordered
                .Where(candidate => !identities.Contains(candidate.Identity))
                .OrderByDescending(candidate => StructuralNovelty(candidate, selected))
                .ThenByDescending(candidate => candidate.HeuristicScore)
                .FirstOrDefault();
            if (next is null) break;
            selected.Add(next);
            identities.Add(next.Identity);
        }

        return selected;
    }

    public CompressionPlan CreateInitialPlan(
        CompressionRequest request,
        MediaInfo media,
        EncoderProfile profile,
        long audioPayloadBytes,
        ContentAnalysis? contentAnalysis = null)
    {
        IReadOnlyList<SampleWindow> windows = SampleWindowPlanner.FixedWindows(media.DurationSeconds, request.ProbeSampleSeconds, Strategy(request.Mode).ProbeMaxSamples);
        ComplexityAnalysis complexity = new() { Windows = windows };
        CropAnalysis crop = new() { Width = media.Width, Height = media.Height };
        AudioPlan audioPlan = media.HasAudio ? new AudioPlan("encode", request.Mode == CompressionMode.Fast ? 80 : 96, profile.AudioCodec, "default", 100) : AudioPlan.Mute;
        AudioArtifact audio = new(null, audioPayloadBytes, audioPlan);
        return CreateCandidatePlans(request, media, profile, audio, contentAnalysis, complexity, crop, windows).First();
    }

    public int CorrectBitrate(CompressionPlan plan, EncodeAttempt current, IReadOnlyList<CorrectionPoint> history)
    {
        long correctionTargetBytes = plan.Mode == CompressionMode.Fast
            ? Math.Min(plan.WorkingTargetBytes, (long)Math.Floor(plan.HardCapBytes * 0.992))
            : plan.WorkingTargetBytes;
        long targetPayload = Math.Max(25_000, correctionTargetBytes - current.AudioPayloadBytes - current.MuxOverheadBytes);
        CorrectionPoint? lower = history.Where(point => point.VideoPayloadBytes <= targetPayload).OrderByDescending(point => point.VideoPayloadBytes).FirstOrDefault();
        CorrectionPoint? upper = history.Where(point => point.VideoPayloadBytes >= targetPayload).OrderBy(point => point.VideoPayloadBytes).FirstOrDefault();
        double guess = lower is not null && upper is not null && upper.VideoKbps != lower.VideoKbps && upper.VideoPayloadBytes != lower.VideoPayloadBytes
            ? lower.VideoKbps + (targetPayload - lower.VideoPayloadBytes) / (double)(upper.VideoPayloadBytes - lower.VideoPayloadBytes) * (upper.VideoKbps - lower.VideoKbps)
            : plan.VideoKbps * targetPayload / (double)Math.Max(1, current.VideoPayloadBytes);
        double minimum = Math.Max(35, plan.VideoKbps * 0.35);
        double maximum = Math.Max(minimum, plan.VideoKbps * 1.35);
        int minStep = plan.Mode switch { CompressionMode.Fast => 12, CompressionMode.Balanced => 8, _ => 5 };
        int next = (int)Math.Round(Math.Clamp(guess, minimum, maximum));
        if (next == plan.VideoKbps) next += current.VideoPayloadBytes < targetPayload ? minStep : -minStep;
        return Math.Max(35, next);
    }

    private static IReadOnlyList<double> TargetFpsCandidates(
        CompressionMode mode,
        double sourceFps,
        double durationSeconds,
        double totalKbps,
        ComplexityAnalysis complexity,
        EncoderProfile profile)
    {
        int source = Math.Max(1, (int)Math.Round(Math.Min(60, sourceFps)));
        List<double> candidates = [];
        bool veryLowMotion = complexity.MotionBucket == "VeryLow";
        bool lowMotion = complexity.MotionBucket is "VeryLow" or "Low";
        bool lowDetail = complexity.DetailBucket is "VeryLow" or "Low";
        if (mode == CompressionMode.Fast)
        {
            if (sourceFps > 50)
            {
                if (veryLowMotion)
                {
                    candidates.Add(30);
                    if (lowDetail && durationSeconds <= 45 && totalKbps >= 1500) candidates.Add(source);
                    if (totalKbps < 500) candidates.Add(24);
                }
                else
                {
                    candidates.Add(source);
                    if (totalKbps < 900) candidates.Add(30);
                    if (totalKbps < 500) candidates.Add(24);
                }
            }
            else if (sourceFps > 30.5)
            {
                if (veryLowMotion && totalKbps < 700)
                {
                    candidates.Add(30);
                    if (totalKbps < 450) candidates.Add(24);
                }
                else
                {
                    candidates.Add(source);
                    if (totalKbps < 650) candidates.Add(30);
                    if (totalKbps < 450) candidates.Add(24);
                }
            }
            else
            {
                candidates.Add(source);
                if (source > 24 && totalKbps < 650) candidates.Add(24);
            }
        }
        else if (mode == CompressionMode.Balanced)
        {
            if (sourceFps > 50)
            {
                if (!veryLowMotion || totalKbps >= 1250 || lowDetail && durationSeconds <= 45 && totalKbps >= 950) candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 330) candidates.Add(24);
            }
            else if (sourceFps > 30.5)
            {
                if (!veryLowMotion || durationSeconds <= 90 && totalKbps >= 900) candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 300) candidates.Add(24);
            }
            else
            {
                candidates.Add(source);
                if (source > 24 && totalKbps < 700) candidates.Add(24);
            }
        }
        else
        {
            if (sourceFps > 50)
            {
                if (!lowMotion || totalKbps >= 1100) candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 420) candidates.Add(24);
            }
            else if (sourceFps > 30.5)
            {
                if (!veryLowMotion || totalKbps >= 850) candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 360) candidates.Add(24);
            }
            else
            {
                candidates.Add(source);
                if (source > 24 && totalKbps < 650) candidates.Add(24);
            }
            if (profile.VideoCodec == "av1" && totalKbps >= 550) candidates.Insert(0, source);
            candidates.Insert(0, source);
            candidates.Add(sourceFps > 30.5 ? 30 : sourceFps > 24.5 ? 24 : sourceFps > 20.5 ? 20 : 15);
        }
        return candidates.Where(fps => fps > 0 && fps <= source + 0.5).Distinct().ToArray();
    }

    private static int StructuralNovelty(CompressionPlan candidate, IReadOnlyList<CompressionPlan> selected)
    {
        int score = 0;
        if (selected.All(plan => plan.Profile.Backend != candidate.Profile.Backend)) score += 100;
        if (selected.All(plan => Math.Abs(plan.Fps - candidate.Fps) > 0.1)) score += 80;
        if (selected.All(plan => plan.Width != candidate.Width || plan.Height != candidate.Height)) score += 60;
        if (selected.All(plan => plan.Preprocess != candidate.Preprocess)) score += 40;
        if (selected.All(plan => !plan.Profile.PrivateArguments.SequenceEqual(candidate.Profile.PrivateArguments))) score += 20;
        return score;
    }

    private static IReadOnlyList<(int Width, string Origin, double Score)> WidthCandidates(
        CompressionMode mode,
        int sourceWidth,
        int sourceHeight,
        double fps,
        int videoKbps,
        ComplexityAnalysis complexity,
        EncoderProfile profile)
    {
        double aspect = sourceWidth / (double)sourceHeight;
        double targetBpppf = TargetBpppf(mode, complexity.DetailBucket, profile.VideoCodec);
        double expected = Math.Min(sourceWidth, Math.Sqrt(videoKbps * 1000.0 * aspect / Math.Max(1, fps * targetBpppf)));
        Dictionary<int, string> origins = new();
        int[] ladder = WidthLadder.Where(width => width <= sourceWidth).DefaultIfEmpty(EvenFloor(sourceWidth)).ToArray();
        foreach (int width in ladder.OrderBy(width => Math.Abs(width - expected)).Take(3)) origins[width] = "ladder";
        foreach (double factor in new[] { 0.85, 0.92, 1.0, 1.08, 1.15 })
        {
            int width = EvenFloor(Math.Clamp(expected * factor, 2, sourceWidth));
            origins[width] = origins.TryGetValue(width, out string? origin) ? origin + "+local" : "local";
        }
        if (mode == CompressionMode.ExtraQuality)
        {
            int source = EvenFloor(sourceWidth);
            origins[source] = origins.TryGetValue(source, out string? origin) ? origin + "+source-sentinel" : "source-sentinel";
            int lower = ladder.Where(width => width < source).DefaultIfEmpty(source).Max();
            origins[lower] = origins.TryGetValue(lower, out string? lowerOrigin) ? lowerOrigin + "+lower-sentinel" : "lower-sentinel";
        }
        return origins.Select(pair =>
        {
            double ratio = pair.Key / Math.Max(2.0, expected);
            double distancePenalty = Math.Abs(Math.Log(ratio)) * 140;
            double overshootPenalty = ratio > 1 ? (ratio - 1) * 120 : 0;
            double score = 200 - distancePenalty - overshootPenalty + pair.Key / (double)sourceWidth * 20;
            return (pair.Key, pair.Value, score);
        }).OrderByDescending(candidate => candidate.score).Select(candidate => (candidate.Key, candidate.Value, candidate.score)).ToArray();
    }

    private static double TargetBpppf(CompressionMode mode, string bucket, string codec)
    {
        double baseValue = mode == CompressionMode.Fast ? bucket switch { "VeryLow" => 0.010, "Low" => 0.0125, "High" => 0.020, "VeryHigh" => 0.024, _ => 0.016 }
            : bucket switch { "VeryLow" => 0.0185, "Low" => 0.0155, "High" => 0.0095, "VeryHigh" => 0.008, _ => 0.0115 };
        if (mode == CompressionMode.ExtraQuality) baseValue += 0.0008;
        return codec switch { "av1" => baseValue * 0.88, "x265" or "vp9" => baseValue * 0.93, _ => baseValue };
    }

    private static IReadOnlyList<(string Name, string Filter)> PreprocessCandidates(PreprocessMode requested, CompressionMode mode, string contentClass, double totalKbps, double bpppf)
    {
        if (requested == PreprocessMode.Off) return [("none", "")];
        if (requested == PreprocessMode.Mild) return [("mild-denoise", "hqdn3d=1.2:1.0:3.0:3.0")];
        List<(string, string)> candidates = [("none", "")];
        if (mode == CompressionMode.Fast) return candidates;
        if (contentClass == "noisy_camera" && (totalKbps < 1100 || bpppf < 0.055)) candidates.Add(("temporal-denoise", "hqdn3d=1.8:1.4:4.5:4.5"));
        else if (contentClass is not ("screen" or "anime") && (totalKbps < 700 || bpppf < 0.028)) candidates.Add(("mild-denoise", "hqdn3d=1.2:1.0:3.0:3.0"));
        if (contentClass is "anime" or "noisy_camera" && (totalKbps < 950 || bpppf < 0.040)) candidates.Add(("deband", "deband=1thr=0.02:2thr=0.02:3thr=0.02:4thr=0.02:range=12:blur=1"));
        if (contentClass == "screen" && totalKbps >= 350) candidates.Add(("screen-sharpen", "unsharp=3:3:0.25:3:3:0.00"));
        if (contentClass is "anime" or "noisy_camera" && totalKbps < 700) candidates.Add(("ringing-reduction", "hqdn3d=0.8:0.6:2.0:2.0,smartblur=1.0:-0.25"));
        return candidates;
    }

    private static IReadOnlyList<EncoderProfile> TuningProfiles(EncoderProfile profile, CompressionMode mode, string contentClass, double totalKbps)
    {
        List<EncoderProfile> profiles = [profile];
        if (mode == CompressionMode.Fast || profile.IsHardware) return profiles;
        switch (profile.Backend)
        {
            case "libx264":
                string x264Parameters = contentClass switch
                {
                    "screen" => "aq-mode=2:aq-strength=0.70:deblock=0,0",
                    "noisy_camera" => "aq-mode=3:aq-strength=0.90:deblock=-1,-1",
                    _ when totalKbps < 1200 => "aq-mode=3:aq-strength=0.85:deblock=-1,-1",
                    _ => ""
                };
                if (!string.IsNullOrWhiteSpace(x264Parameters)) profiles.Add(profile with { PrivateArguments = ["-x264-params", x264Parameters] });
                break;
            case "libx265":
                profiles.Add(profile with { PrivateArguments = ["-x265-params", "aq-mode=3:aq-strength=0.8:psy-rd=1.5"] });
                if (mode == CompressionMode.ExtraQuality) profiles.Add(profile with { PrivateArguments = ["-x265-params", "aq-mode=3:aq-strength=1.0:psy-rd=2.0:psy-rdoq=1.0"] });
                break;
            case "svtav1":
                profiles.Add(profile with { PrivateArguments = ["-svtav1-params", "tune=0:enable-variance-boost=1"] });
                if (mode == CompressionMode.ExtraQuality && contentClass == "noisy_camera") profiles.Add(profile with { PrivateArguments = ["-svtav1-params", "tune=0:enable-variance-boost=1:film-grain=8:film-grain-denoise=0"] });
                break;
            case "aom":
                profiles.Add(profile with { PrivateArguments = ["-aq-mode", "1", "-tune", "ssim"] });
                break;
            case "vpx":
                profiles.Add(profile with { PrivateArguments = ["-aq-mode", "1", "-auto-alt-ref", "1", "-lag-in-frames", "25", "-row-mt", "1"] });
                if (contentClass == "screen") profiles.Add(profile with { PrivateArguments = ["-aq-mode", "1", "-tune-content", "screen", "-row-mt", "1"] });
                break;
        }
        return profiles;
    }

    private static string PixelFormat(string requested, MediaInfo media, EncoderProfile profile)
    {
        bool supportsTenBit = !profile.IsHardware && profile.VideoCodec is "x265" or "av1" or "vp9";
        int requestedDepth = requested.Equals("10", StringComparison.Ordinal) ? 10 : requested.Equals("8", StringComparison.Ordinal) ? 8 : media.BitDepth > 8 ? 10 : 8;
        if (requestedDepth == 10 && requested.Equals("10", StringComparison.Ordinal) && !supportsTenBit)
            throw new ArgumentException($"Backend '{profile.Backend}' does not support the requested 10-bit delivery profile.");
        return requestedDepth == 10 && supportsTenBit ? "yuv420p10le" : "yuv420p";
    }

    private static (IReadOnlyList<string> Arguments, IReadOnlyList<string> Preserved, IReadOnlyList<string> Omitted) ColorMetadata(MediaInfo media)
    {
        List<string> arguments = [];
        List<string> preserved = [];
        List<string> omitted = [];
        AddColor("range", media.ColorRange, "-color_range", arguments, preserved, omitted);
        AddColor("primaries", media.ColorPrimaries, "-color_primaries", arguments, preserved, omitted);
        AddColor("transfer", media.ColorTransfer, "-color_trc", arguments, preserved, omitted);
        AddColor("space", media.ColorSpace, "-colorspace", arguments, preserved, omitted);
        AddColor("chroma_location", media.ChromaLocation, "-chroma_sample_location", arguments, preserved, omitted);
        return (arguments, preserved, omitted);
    }

    private static void AddColor(string label, string value, string argument, List<string> arguments, List<string> preserved, List<string> omitted)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Equals("unknown", StringComparison.OrdinalIgnoreCase) || value.Equals("unspecified", StringComparison.OrdinalIgnoreCase))
        {
            omitted.Add(label);
            return;
        }
        arguments.AddRange([argument, value]);
        preserved.Add($"{label}={value}");
    }

    private static string GeometryFilter(MediaInfo media, CropAnalysis crop, int width, int height, double fps) =>
        $"setsar=1,scale={width}:{height}:flags=lanczos,fps={fps.ToString("0.########", CultureInfo.InvariantCulture)}:round=near";

    private static string MetricReferenceFilter(MediaInfo media, CropAnalysis crop, CanonicalCanvas canvas) =>
        JoinFilters(crop.Filter, MetricEvaluator.ReferenceFilter(canvas));

    private static string JoinFilters(params string[] filters) => string.Join(',', filters.Where(filter => !string.IsNullOrWhiteSpace(filter)));
    private static double TuningBonus(EncoderProfile tuned, EncoderProfile original) => tuned.PrivateArguments.Count > original.PrivateArguments.Count ? 0.25 : 0;

    private static (int Width, int Height) DisplayGeometry(MediaInfo media, CropAnalysis? crop)
    {
        int codedWidth = crop?.Applied == true ? crop.Width : media.Width;
        int codedHeight = crop?.Applied == true ? crop.Height : media.Height;
        int width = EvenFloor(codedWidth * Math.Max(0.01, media.SampleAspectRatio));
        int height = EvenFloor(codedHeight);
        if (crop?.Applied != true && media.Rotation is 90 or 270) (width, height) = (height, width);
        return (Math.Max(2, width), Math.Max(2, height));
    }

    private static string DefaultPreset(CompressionMode mode, EncoderProfile profile) => mode switch
    {
        CompressionMode.Fast => "superfast",
        CompressionMode.Balanced => "medium",
        _ => "slow"
    };

    private static long MuxReserveBytes(long targetBytes, CompressionMode mode, string container, string audioMode)
    {
        double modeRatio = mode switch { CompressionMode.Fast => 0.0060, CompressionMode.Balanced => 0.0040, _ => 0.0030 };
        double containerRatio = container == "webm" ? 0.0025 : 0.0038;
        double audioRatio = audioMode == "mute" ? 0.0002 : 0.0007;
        return Math.Max(4096, (long)Math.Ceiling(targetBytes * Math.Max(modeRatio, containerRatio + audioRatio)));
    }

    private static int EvenFloor(double value) => Math.Max(2, (int)Math.Floor(value / 2) * 2);
}
