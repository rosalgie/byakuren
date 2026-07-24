using System.Globalization;
using Byakuren.Analysis;
using Byakuren.Metrics;
using Byakuren.Models;

namespace Byakuren.Planner;

public sealed class CompressionPlanner
{
    private static readonly int[] WidthLadder =
    [
        3840, 3200, 2560, 1920, 1600, 1440, 1280, 1152, 960,
        854, 768, 640, 576, 480, 426, 384, 320, 256
    ];

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
        string pixelFormat = bitDepth == 10 ? "yuv420p10le" : "yuv420p";
        return new CanonicalCanvas(
            width,
            height,
            Math.Min(60, media.Fps),
            bitDepth,
            pixelFormat);
    }

    public IReadOnlyList<AudioPlan> CreateAudioPlans(
        CompressionRequest request,
        MediaInfo media,
        EncoderProfile profile,
        ComplexityAnalysis complexity,
        string contentClass)
    {
        if (!media.HasAudio)
            return [AudioPlan.Mute];
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
            (AudioPriority.Balanced, "gameplay") => 16,
            (_, "talking_head") => 8,
            _ => 0
        };
        int complexityBias = complexity.DetailBucket switch
        {
            "VeryLow" => 8,
            "High" or "VeryHigh" => -8,
            _ => 0
        };
        int bias = priorityBias + complexityBias;

        int channelFloor = 32;
        if (media.AudioChannels >= 6)
            channelFloor = 128;
        else if (media.AudioChannels > 2)
            channelFloor = 96;

        int[] rates = baseRates.Select(rate => Math.Max(channelFloor, rate + bias)).Distinct().ToArray();
        int retain = request.Mode switch
        {
            CompressionMode.Fast => 2,
            CompressionMode.Balanced => 2,
            _ => 3
        };
        List<AudioPlan> plans = [];
        int rank = 100;

        int copyCeiling = rates.Max();
        if (contentClass == "gameplay")
        {
            copyCeiling = totalKbps switch
            {
                < 300 => 64,
                < 420 => 72,
                < 650 => 96,
                < 950 => 128,
                _ => 160
            };
        }

        bool canCopyAudio = media.AudioCodec.Equals(
                profile.AudioCodec,
                StringComparison.OrdinalIgnoreCase) &&
            media.AudioBitrateKbps > 0 &&
            media.AudioBitrateKbps <= copyCeiling;
        if (canCopyAudio)
        {
            plans.Add(new AudioPlan(
                "copy",
                media.AudioBitrateKbps,
                media.AudioCodec,
                $"copy original audio ({media.AudioBitrateKbps}k)",
                rank + 1));
        }

        foreach (int rate in rates.Take(retain))
            plans.Add(new AudioPlan("encode", rate, profile.AudioCodec, $"{profile.AudioCodec} {rate}k", rank--));
        if (request.Mode == CompressionMode.Fast || totalKbps < 175)
            plans.Add(AudioPlan.Mute);
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
        IReadOnlyList<double> fpsCandidates = TargetFpsCandidates(
            request.Mode,
            media.Fps,
            media.DurationSeconds,
            totalKbps,
            contentClass,
            complexity,
            profile);
        List<CompressionPlan> plans = [];

        foreach (EncoderProfile tunedProfile in TuningProfiles(
                     profile,
                     request.Mode,
                     contentClass,
                     totalKbps,
                     contentAnalysis))
        {
            foreach (double fps in fpsCandidates)
            {
                IReadOnlyList<(int Width, string Origin, double Score)> widths = WidthCandidates(
                    request.Mode,
                    sourceWidth,
                    sourceHeight,
                    fps,
                    videoKbps,
                    complexity,
                    tunedProfile);
                foreach ((int width, string origin, double widthScore) in widths)
                {
                    int height = EvenFloor(width / aspect);
                    double bpppf = videoKbps * 1000.0 / Math.Max(1, width * (double)height * fps);
                    IReadOnlyList<(string Name, string Filter)> preprocessCandidates =
                        PreprocessCandidates(
                            request.PreprocessMode,
                            request.Mode,
                            contentClass,
                            totalKbps,
                            bpppf,
                            contentAnalysis);
                    foreach ((string preprocess, string preprocessFilter) in preprocessCandidates)
                    {
                        string pixelFormat = PixelFormat(request.OutputBitDepth, media, tunedProfile);
                        string geometryFilter = GeometryFilter(media, crop, width, height, fps);
                        string hardwareFilter = tunedProfile.IsHardware ? "format=nv12,hwupload" : "";
                        string videoFilter = JoinFilters(
                            crop.Filter,
                            preprocessFilter,
                            geometryFilter,
                            hardwareFilter);
                        (IReadOnlyList<string> colorArguments,
                            IReadOnlyList<string> preserved,
                            IReadOnlyList<string> omitted) = ColorMetadata(media);

                        int? maxrate = null;
                        if (request.VBVMode == VBVMode.Streaming && tunedProfile.VideoCodec != "av1")
                            maxrate = Math.Max(35, (int)Math.Ceiling(videoKbps * 1.5));

                        int? bufsize = maxrate.HasValue ? maxrate.Value * 2 : null;
                        double fpsRetention = Math.Min(1, fps / Math.Max(1, Math.Min(60, media.Fps)));
                        bool lowMotion = complexity.MotionBucket is "VeryLow" or "Low";

                        bool prioritizeFrameRate = request.Mode == CompressionMode.Fast ||
                            !lowMotion ||
                            contentClass == "gameplay";
                        double fpsWeight = prioritizeFrameRate ? 80 : 8;
                        double gameplayMotionBonus = contentClass == "gameplay" && fpsRetention > 0.99 ? 10 : 0;
                        double spatialQuality = SpatialQualityScore(
                            request.Mode,
                            complexity.DetailBucket,
                            tunedProfile.VideoCodec,
                            bpppf);
                        double audioWeight = contentClass == "gameplay" ? 0.75 : 0.35;
                        double heuristic = widthScore +
                            fpsRetention * fpsWeight +
                            spatialQuality +
                            gameplayMotionBonus +
                            audio.Plan.Rank * audioWeight +
                            TuningBonus(tunedProfile, profile);
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

        int candidateLimit = request.Mode switch
        {
            CompressionMode.Fast => 1,
            CompressionMode.Balanced => 12,
            _ => 24
        };
        IEnumerable<CompressionPlan> ordered = plans.OrderByDescending(plan => plan.HeuristicScore);
        if (request.Mode == CompressionMode.ExtraQuality)
        {
            CompressionPlan? sourceSentinel = plans
                .Where(plan => plan.WidthOrigin.Contains(
                    "source-sentinel",
                    StringComparison.Ordinal))
                .OrderByDescending(plan => plan.HeuristicScore)
                .FirstOrDefault();
            CompressionPlan? lowerSentinel = plans
                .Where(plan => plan.WidthOrigin.Contains(
                    "lower-sentinel",
                    StringComparison.Ordinal))
                .OrderByDescending(plan => plan.HeuristicScore)
                .FirstOrDefault();
            double sourceFps = Math.Min(60, media.Fps);
            CompressionPlan? sourceFpsSentinel = plans
                .Where(plan => Math.Abs(plan.Fps - sourceFps) < 0.1)
                .OrderByDescending(plan => plan.HeuristicScore)
                .FirstOrDefault();
            CompressionPlan? lowerFpsSentinel = plans
                .Where(plan => plan.Fps < sourceFps - 0.1)
                .OrderByDescending(plan => plan.Fps)
                .ThenByDescending(plan => plan.HeuristicScore)
                .FirstOrDefault();
            ordered = new[]
                {
                    sourceSentinel,
                    lowerSentinel,
                    sourceFpsSentinel,
                    lowerFpsSentinel
                }
                .Where(plan => plan is not null)
                .Cast<CompressionPlan>()
                .Concat(ordered);
        }

        return ordered
            .DistinctBy(plan => plan.Identity + "|" + plan.AudioPlan.Identity)
            .Take(candidateLimit)
            .ToArray();
    }

    public IReadOnlyList<CompressionPlan> CreatePreviewShortlist(IReadOnlyList<CompressionPlan> candidates, int limit)
    {
        if (limit <= 0 || candidates.Count == 0)
            return [];
        CompressionPlan[] ordered = candidates.OrderByDescending(plan => plan.HeuristicScore).ToArray();
        List<CompressionPlan> selected = [ordered[0]];
        HashSet<string> identities = new(StringComparer.Ordinal) { ordered[0].Identity };

        if (limit > 1 && IsSpatiallyAtRisk(ordered[0]))
        {
            long primaryPixels = (long)ordered[0].Width * ordered[0].Height;
            CompressionPlan? spatialSafety = ordered
                .Where(candidate => !identities.Contains(candidate.Identity))
                .Where(candidate => candidate.Profile.Backend == ordered[0].Profile.Backend)
                .Where(candidate => Math.Abs(candidate.Fps - ordered[0].Fps) < 0.1)
                .Where(candidate => (long)candidate.Width * candidate.Height <= primaryPixels * 0.75)
                .OrderByDescending(candidate => candidate.HeuristicScore)
                .FirstOrDefault();
            if (spatialSafety is not null)
            {
                selected.Add(spatialSafety);
                identities.Add(spatialSafety.Identity);
            }
        }

        if (selected.Count == 1 && limit > 1)
        {
            CompressionPlan? meaningfulChallenger = ordered
                .Where(candidate => !identities.Contains(candidate.Identity))
                .Where(candidate => IsMeaningfullyDifferent(candidate, ordered[0]))
                .OrderByDescending(candidate => candidate.HeuristicScore)
                .FirstOrDefault();
            if (meaningfulChallenger is not null)
            {
                selected.Add(meaningfulChallenger);
                identities.Add(meaningfulChallenger.Identity);
            }
        }

        while (selected.Count < limit)
        {
            CompressionPlan? next = ordered
                .Where(candidate => !identities.Contains(candidate.Identity))
                .OrderByDescending(candidate => StructuralNovelty(candidate, selected))
                .ThenByDescending(candidate => candidate.HeuristicScore)
                .FirstOrDefault();
            if (next is null)
                break;
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
        ModeStrategy strategy = Strategy(request.Mode);
        IReadOnlyList<SampleWindow> windows = SampleWindowPlanner.FixedWindows(
            media.DurationSeconds,
            request.ProbeSampleSeconds,
            strategy.ProbeMaxSamples);
        ComplexityAnalysis complexity = new() { Windows = windows };
        CropAnalysis crop = new() { Width = media.Width, Height = media.Height };

        AudioPlan audioPlan = AudioPlan.Mute;
        if (media.HasAudio)
        {
            int audioKbps = request.Mode == CompressionMode.Fast ? 80 : 96;
            audioPlan = new AudioPlan(
                "encode",
                audioKbps,
                profile.AudioCodec,
                "default",
                100);
        }

        AudioArtifact audio = new(null, audioPayloadBytes, audioPlan);
        return CreateCandidatePlans(
            request,
            media,
            profile,
            audio,
            contentAnalysis,
            complexity,
            crop,
            windows).First();
    }

    public int CorrectBitrate(CompressionPlan plan, EncodeAttempt current, IReadOnlyList<CorrectionPoint> history)
    {
        long correctionTargetBytes = plan.WorkingTargetBytes;
        if (plan.Mode == CompressionMode.Fast)
        {
            correctionTargetBytes = Math.Min(
                plan.WorkingTargetBytes,
                (long)Math.Floor(plan.HardCapBytes * 0.992));
        }

        long targetPayload = Math.Max(
            25_000,
            correctionTargetBytes - current.AudioPayloadBytes - current.MuxOverheadBytes);
        CorrectionPoint? lower = history
            .Where(point => point.VideoPayloadBytes <= targetPayload)
            .OrderByDescending(point => point.VideoPayloadBytes)
            .FirstOrDefault();
        CorrectionPoint? upper = history
            .Where(point => point.VideoPayloadBytes >= targetPayload)
            .OrderBy(point => point.VideoPayloadBytes)
            .FirstOrDefault();

        bool canInterpolate = lower is not null &&
            upper is not null &&
            upper.VideoKbps != lower.VideoKbps &&
            upper.VideoPayloadBytes != lower.VideoPayloadBytes;
        double guess;
        if (canInterpolate)
        {
            guess = lower!.VideoKbps +
                (targetPayload - lower.VideoPayloadBytes) /
                (double)(upper!.VideoPayloadBytes - lower.VideoPayloadBytes) *
                (upper.VideoKbps - lower.VideoKbps);
        }
        else
        {
            guess = plan.VideoKbps * targetPayload /
                (double)Math.Max(1, current.VideoPayloadBytes);
        }

        double minimum = Math.Max(35, plan.VideoKbps * 0.35);
        double maximum = Math.Max(minimum, plan.VideoKbps * 1.35);
        int minStep = plan.Mode switch
        {
            CompressionMode.Fast => 12,
            CompressionMode.Balanced => 8,
            _ => 5
        };
        int next = (int)Math.Round(Math.Clamp(guess, minimum, maximum));
        if (next == plan.VideoKbps)
        {
            if (current.VideoPayloadBytes < targetPayload)
                next += minStep;
            else
                next -= minStep;
        }

        return Math.Max(35, next);
    }

    private static IReadOnlyList<double> TargetFpsCandidates(
        CompressionMode mode,
        double sourceFps,
        double durationSeconds,
        double totalKbps,
        string contentClass,
        ComplexityAnalysis complexity,
        EncoderProfile profile)
    {
        int source = Math.Max(1, (int)Math.Round(Math.Min(60, sourceFps)));
        List<double> candidates = [];
        bool veryLowMotion = complexity.MotionBucket == "VeryLow";
        bool lowMotion = complexity.MotionBucket is "VeryLow" or "Low";
        bool lowDetail = complexity.DetailBucket is "VeryLow" or "Low";
        if (contentClass == "gameplay" && sourceFps > 50)
        {
            if (totalKbps >= 900)
                return [source];
            if (totalKbps >= 650)
                return [source, 30];
            return totalKbps < 330 ? [30, 24] : [30];
        }
        if (mode == CompressionMode.Fast)
        {
            if (sourceFps > 50)
            {
                if (veryLowMotion)
                {
                    candidates.Add(30);
                    if (lowDetail && durationSeconds <= 45 && totalKbps >= 1500)
                        candidates.Add(source);
                    if (totalKbps < 500)
                        candidates.Add(24);
                }
                else
                {
                    candidates.Add(source);
                    if (totalKbps < 900)
                        candidates.Add(30);
                    if (totalKbps < 500)
                        candidates.Add(24);
                }
            }
            else if (sourceFps > 30.5)
            {
                if (veryLowMotion && totalKbps < 700)
                {
                    candidates.Add(30);
                    if (totalKbps < 450)
                        candidates.Add(24);
                }
                else
                {
                    candidates.Add(source);
                    if (totalKbps < 650)
                        candidates.Add(30);
                    if (totalKbps < 450)
                        candidates.Add(24);
                }
            }
            else
            {
                candidates.Add(source);
                if (source > 24 && totalKbps < 650)
                    candidates.Add(24);
            }
        }
        else if (mode == CompressionMode.Balanced)
        {
            if (sourceFps > 50)
            {
                bool retainSourceFps = !veryLowMotion ||
                    totalKbps >= 1250 ||
                    lowDetail && durationSeconds <= 45 && totalKbps >= 950;
                if (retainSourceFps)
                    candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 330)
                    candidates.Add(24);
            }
            else if (sourceFps > 30.5)
            {
                if (!veryLowMotion || durationSeconds <= 90 && totalKbps >= 900)
                    candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 300)
                    candidates.Add(24);
            }
            else
            {
                candidates.Add(source);
                if (source > 24 && totalKbps < 700)
                    candidates.Add(24);
            }
        }
        else
        {
            if (sourceFps > 50)
            {
                if (!lowMotion || totalKbps >= 1100)
                    candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 420)
                    candidates.Add(24);
            }
            else if (sourceFps > 30.5)
            {
                if (!veryLowMotion || totalKbps >= 850)
                    candidates.Add(source);
                candidates.Add(30);
                if (totalKbps < 360)
                    candidates.Add(24);
            }
            else
            {
                candidates.Add(source);
                if (source > 24 && totalKbps < 650)
                    candidates.Add(24);
            }
            if (profile.VideoCodec == "av1" && totalKbps >= 550)
                candidates.Insert(0, source);
            candidates.Insert(0, source);

            double lowFpsCandidate;
            if (sourceFps > 30.5)
                lowFpsCandidate = 30;
            else if (sourceFps > 24.5)
                lowFpsCandidate = 24;
            else if (sourceFps > 20.5)
                lowFpsCandidate = 20;
            else
                lowFpsCandidate = 15;

            candidates.Add(lowFpsCandidate);
        }

        return candidates
            .Where(fps => fps > 0 && fps <= source + 0.5)
            .Distinct()
            .ToArray();
    }

    private static int StructuralNovelty(CompressionPlan candidate, IReadOnlyList<CompressionPlan> selected)
    {
        int score = 0;
        if (selected.All(plan => plan.Profile.Backend != candidate.Profile.Backend))
            score += 100;
        if (selected.All(plan => Math.Abs(plan.Fps - candidate.Fps) > 0.1))
            score += 80;
        if (selected.All(plan => plan.Width != candidate.Width || plan.Height != candidate.Height))
            score += 60;
        if (selected.All(plan => plan.Preprocess != candidate.Preprocess))
            score += 40;
        if (selected.All(plan => !plan.Profile.PrivateArguments.SequenceEqual(candidate.Profile.PrivateArguments)))
            score += 20;
        return score;
    }

    private static bool IsMeaningfullyDifferent(CompressionPlan candidate, CompressionPlan primary)
    {
        if (candidate.Profile.Backend != primary.Profile.Backend)
            return true;
        if (Math.Abs(candidate.Fps - primary.Fps) > 0.1)
            return true;
        long candidatePixels = (long)candidate.Width * candidate.Height;
        long primaryPixels = (long)primary.Width * primary.Height;
        double areaRatio = candidatePixels / (double)Math.Max(1, primaryPixels);
        return areaRatio <= 0.80 ||
            areaRatio >= 1.25 ||
            candidate.Preprocess != primary.Preprocess ||
            !candidate.Profile.PrivateArguments.SequenceEqual(primary.Profile.PrivateArguments);
    }

    private static double SpatialQualityScore(CompressionMode mode, string detailBucket, string codec, double bpppf)
    {
        // Bits per pixel have diminishing value beyond a codec- and content-aware soft knee.
        double target = SpatialDensityTarget(mode, detailBucket, codec);
        if (bpppf <= target)
            return bpppf * 1000;
        double surplusRatio = bpppf / target - 1;
        return target * 1000 + 30 * (1 - Math.Exp(-surplusRatio));
    }

    private static bool IsSpatiallyAtRisk(CompressionPlan plan)
    {
        string detailBucket = plan.ComplexityAnalysis?.DetailBucket ?? "Medium";
        double target = SpatialDensityTarget(plan.Mode, detailBucket, plan.Profile.VideoCodec);
        return plan.BitsPerPixelPerFrame < target * 0.90;
    }

    private static double SpatialDensityTarget(CompressionMode mode, string detailBucket, string codec)
    {
        double detailTarget = detailBucket switch
        {
            "VeryLow" => 0.070,
            "Low" => 0.090,
            "High" => 0.140,
            "VeryHigh" => 0.160,
            _ => 0.115
        };
        double modeFactor = mode switch
        {
            CompressionMode.Fast => 1.10,
            CompressionMode.ExtraQuality => 0.90,
            _ => 1.0
        };
        double codecFactor = codec switch
        {
            "av1" => 0.82,
            "x265" or "vp9" => 0.90,
            _ => 1.0
        };
        return detailTarget * modeFactor * codecFactor;
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
        double expected = Math.Min(
            sourceWidth,
            Math.Sqrt(videoKbps * 1000.0 * aspect / Math.Max(1, fps * targetBpppf)));
        Dictionary<int, string> origins = new();
        int[] ladder = WidthLadder
            .Where(width => width <= sourceWidth)
            .DefaultIfEmpty(EvenFloor(sourceWidth))
            .ToArray();
        foreach (int width in ladder.OrderBy(width => Math.Abs(width - expected)).Take(3))
            origins[width] = "ladder";
        foreach (double factor in new[] { 0.85, 0.92, 1.0, 1.08, 1.15 })
        {
            int width = EvenFloor(Math.Clamp(expected * factor, 2, sourceWidth));
            if (origins.TryGetValue(width, out string? origin))
                origins[width] = origin + "+local";
            else
                origins[width] = "local";
        }
        if (mode == CompressionMode.ExtraQuality)
        {
            int source = EvenFloor(sourceWidth);
            if (origins.TryGetValue(source, out string? origin))
                origins[source] = origin + "+source-sentinel";
            else
                origins[source] = "source-sentinel";

            int lower = ladder.Where(width => width < source).DefaultIfEmpty(source).Max();
            if (origins.TryGetValue(lower, out string? lowerOrigin))
                origins[lower] = lowerOrigin + "+lower-sentinel";
            else
                origins[lower] = "lower-sentinel";
        }

        return origins
            .Select(pair =>
            {
                double ratio = pair.Key / Math.Max(2.0, expected);
                double distancePenalty = Math.Abs(Math.Log(ratio)) * 140;
                double overshootPenalty = ratio > 1 ? (ratio - 1) * 120 : 0;
                double score = 200 -
                    distancePenalty -
                    overshootPenalty +
                    pair.Key / (double)sourceWidth * 20;
                return (pair.Key, pair.Value, score);
            })
            .OrderByDescending(candidate => candidate.score)
            .Select(candidate => (candidate.Key, candidate.Value, candidate.score))
            .ToArray();
    }

    private static double TargetBpppf(CompressionMode mode, string bucket, string codec)
    {
        double baseValue;
        if (mode == CompressionMode.Fast)
        {
            baseValue = bucket switch
            {
                "VeryLow" => 0.010,
                "Low" => 0.0125,
                "High" => 0.020,
                "VeryHigh" => 0.024,
                _ => 0.016
            };
        }
        else
        {
            baseValue = bucket switch
            {
                "VeryLow" => 0.0185,
                "Low" => 0.0155,
                "High" => 0.0095,
                "VeryHigh" => 0.008,
                _ => 0.0115
            };
        }

        if (mode == CompressionMode.ExtraQuality)
            baseValue += 0.0008;

        return codec switch
        {
            "av1" => baseValue * 0.88,
            "x265" or "vp9" => baseValue * 0.93,
            _ => baseValue
        };
    }

    private static IReadOnlyList<(string Name, string Filter)> PreprocessCandidates(
        PreprocessMode requested,
        CompressionMode mode,
        string contentClass,
        double totalKbps,
        double bpppf,
        ContentAnalysis? contentAnalysis)
    {
        if (requested == PreprocessMode.Off)
            return [("none", "")];
        if (requested == PreprocessMode.Mild)
            return [("mild-denoise", "hqdn3d=1.2:1.0:3.0:3.0")];
        List<(string, string)> candidates = [("none", "")];
        if (mode == CompressionMode.Fast)
            return candidates;
        bool grainOrNoise = HasTrait(contentAnalysis, "grain_or_noise") ||
            contentClass == "noisy_camera";
        bool flatColor = HasTrait(contentAnalysis, "flat_color") ||
            contentClass == "anime";
        bool screenDetail = contentClass == "screen" ||
            (HasTrait(contentAnalysis, "persistent_ui") &&
             HasTrait(contentAnalysis, "text_heavy"));
        if (grainOrNoise && (totalKbps < 1100 || bpppf < 0.055))
            candidates.Add(("temporal-denoise", "hqdn3d=1.8:1.4:4.5:4.5"));
        else if (!screenDetail && !flatColor && contentClass != "gameplay" &&
            (totalKbps < 700 || bpppf < 0.028))
            candidates.Add(("mild-denoise", "hqdn3d=1.2:1.0:3.0:3.0"));
        if (flatColor && (totalKbps < 950 || bpppf < 0.040))
        {
            candidates.Add((
                "deband",
                "deband=1thr=0.02:2thr=0.02:3thr=0.02:" +
                "4thr=0.02:range=12:blur=1"));
        }
        if (screenDetail && totalKbps >= 350)
            candidates.Add(("screen-sharpen", "unsharp=3:3:0.25:3:3:0.00"));
        if ((flatColor || grainOrNoise) && totalKbps < 700)
            candidates.Add(("ringing-reduction", "hqdn3d=0.8:0.6:2.0:2.0,smartblur=1.0:-0.25"));
        return candidates;
    }

    private static IReadOnlyList<EncoderProfile> TuningProfiles(
        EncoderProfile profile,
        CompressionMode mode,
        string contentClass,
        double totalKbps,
        ContentAnalysis? contentAnalysis)
    {
        List<EncoderProfile> profiles = [profile];
        if (mode == CompressionMode.Fast || profile.IsHardware)
            return profiles;
        bool screenDetail = contentClass == "screen" ||
            (HasTrait(contentAnalysis, "persistent_ui") &&
             HasTrait(contentAnalysis, "text_heavy"));
        bool grainOrNoise = HasTrait(contentAnalysis, "grain_or_noise") ||
            contentClass == "noisy_camera";
        switch (profile.Backend)
        {
            case "libx264":
                string x264Parameters = (screenDetail, grainOrNoise, totalKbps) switch
                {
                    (true, _, _) => "aq-mode=2:aq-strength=0.70:deblock=0,0",
                    (_, true, _) => "aq-mode=3:aq-strength=0.90:deblock=-1,-1",
                    (_, _, < 1200) => "aq-mode=3:aq-strength=0.85:deblock=-1,-1",
                    _ => ""
                };
                if (!string.IsNullOrWhiteSpace(x264Parameters))
                    profiles.Add(profile with { PrivateArguments = ["-x264-params", x264Parameters] });
                break;
            case "libx265":
                profiles.Add(profile with
                {
                    PrivateArguments =
                    [
                        "-x265-params",
                        "aq-mode=3:aq-strength=0.8:psy-rd=1.5"
                    ]
                });
                if (mode == CompressionMode.ExtraQuality)
                {
                    profiles.Add(profile with
                    {
                        PrivateArguments =
                        [
                            "-x265-params",
                            "aq-mode=3:aq-strength=1.0:psy-rd=2.0:psy-rdoq=1.0"
                        ]
                    });
                }
                break;
            case "svtav1":
                profiles.Add(profile with { PrivateArguments = ["-svtav1-params", "tune=0:enable-variance-boost=1"] });
                if (mode == CompressionMode.ExtraQuality && grainOrNoise)
                {
                    profiles.Add(profile with
                    {
                        PrivateArguments =
                        [
                            "-svtav1-params",
                            "tune=0:enable-variance-boost=1:" +
                            "film-grain=8:film-grain-denoise=0"
                        ]
                    });
                }
                break;
            case "aom":
                profiles.Add(profile with { PrivateArguments = ["-aq-mode", "1", "-tune", "ssim"] });
                break;
            case "vpx":
                profiles.Add(profile with
                {
                    PrivateArguments =
                    [
                        "-aq-mode", "1",
                        "-auto-alt-ref", "1",
                        "-lag-in-frames", "25",
                        "-row-mt", "1"
                    ]
                });
                if (screenDetail)
                    profiles.Add(profile with { PrivateArguments = ["-aq-mode", "1", "-tune-content", "screen", "-row-mt", "1"] });
                break;
        }
        return profiles;
    }

    private static bool HasTrait(ContentAnalysis? analysis, string trait)
    {
        return analysis?.Traits.Contains(trait, StringComparer.Ordinal) == true;
    }

    private static string PixelFormat(string requested, MediaInfo media, EncoderProfile profile)
    {
        bool supportsTenBit = !profile.IsHardware && profile.VideoCodec is "x265" or "av1" or "vp9";

        int requestedDepth;
        if (requested.Equals("10", StringComparison.Ordinal))
            requestedDepth = 10;
        else if (requested.Equals("8", StringComparison.Ordinal))
            requestedDepth = 8;
        else if (media.BitDepth > 8)
            requestedDepth = 10;
        else
            requestedDepth = 8;

        if (requestedDepth == 10 && requested.Equals("10", StringComparison.Ordinal) && !supportsTenBit)
            throw new ArgumentException($"Backend '{profile.Backend}' does not support the requested 10-bit delivery profile.");

        if (requestedDepth == 10 && supportsTenBit)
            return "yuv420p10le";

        return "yuv420p";
    }

    private static (
        IReadOnlyList<string> Arguments,
        IReadOnlyList<string> Preserved,
        IReadOnlyList<string> Omitted) ColorMetadata(MediaInfo media)
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

    private static void AddColor(
        string label,
        string value,
        string argument,
        List<string> arguments,
        List<string> preserved,
        List<string> omitted)
    {
        bool unknown = string.IsNullOrWhiteSpace(value) ||
            value.Equals("unknown", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("unspecified", StringComparison.OrdinalIgnoreCase);
        if (unknown)
        {
            omitted.Add(label);
            return;
        }
        arguments.AddRange([argument, value]);
        preserved.Add($"{label}={value}");
    }

    private static string GeometryFilter(
        MediaInfo media,
        CropAnalysis crop,
        int width,
        int height,
        double fps)
    {
        string formattedFps = fps.ToString("0.########", CultureInfo.InvariantCulture);
        return $"setsar=1,scale={width}:{height}:flags=lanczos," +
            $"fps={formattedFps}:round=near";
    }

    private static string MetricReferenceFilter(MediaInfo media, CropAnalysis crop, CanonicalCanvas canvas) =>
        JoinFilters(crop.Filter, MetricEvaluator.ReferenceFilter(canvas));

    private static string JoinFilters(params string[] filters)
    {
        return string.Join(
            ',',
            filters.Where(filter => !string.IsNullOrWhiteSpace(filter)));
    }

    private static double TuningBonus(EncoderProfile tuned, EncoderProfile original)
    {
        return tuned.PrivateArguments.Count > original.PrivateArguments.Count ? 0.25 : 0;
    }

    private static (int Width, int Height) DisplayGeometry(MediaInfo media, CropAnalysis? crop)
    {
        int codedWidth = crop?.Applied == true ? crop.Width : media.Width;
        int codedHeight = crop?.Applied == true ? crop.Height : media.Height;
        int width = EvenFloor(codedWidth * Math.Max(0.01, media.SampleAspectRatio));
        int height = EvenFloor(codedHeight);
        if (crop?.Applied != true && media.Rotation is 90 or 270)
            (width, height) = (height, width);
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
        double modeRatio = mode switch
        {
            CompressionMode.Fast => 0.0060,
            CompressionMode.Balanced => 0.0040,
            _ => 0.0030
        };
        double containerRatio = container == "webm" ? 0.0025 : 0.0038;
        double audioRatio = audioMode == "mute" ? 0.0002 : 0.0007;
        return Math.Max(
            4096,
            (long)Math.Ceiling(
                targetBytes * Math.Max(modeRatio, containerRatio + audioRatio)));
    }

    private static int EvenFloor(double value) => Math.Max(2, (int)Math.Floor(value / 2) * 2);
}
