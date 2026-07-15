using Byakuren.Analysis;
using Byakuren.Encoding;
using Byakuren.Execution;
using Byakuren.Metrics;
using Byakuren.Models;
using Byakuren.Planner;
using Byakuren.Policy;
using Byakuren.Probe;
using Byakuren.Results;

namespace Byakuren.Worker;

public sealed class CompressionWorker
{
    private readonly ProcessRunner _runner;
    private readonly CompressionPolicy _policy;
    private readonly CompressionPlanner _planner;
    private readonly FFmpegProbe _probe;
    private readonly CapabilityProbe _capabilityProbe;
    private readonly FFmpegEncoder _encoder;
    private readonly MetricEvaluator _metrics;
    private readonly ContentAnalyzer _contentAnalyzer;
    private readonly SampleWindowPlanner _sampleWindowPlanner;
    private readonly ComplexityAnalyzer _complexityAnalyzer;
    private readonly CropAnalyzer _cropAnalyzer;
    private readonly ResultContract _results;

    public CompressionWorker()
    {
        _runner = new ProcessRunner();
        _policy = new CompressionPolicy();
        _planner = new CompressionPlanner();
        _probe = new FFmpegProbe(_runner);
        _capabilityProbe = new CapabilityProbe(_runner, _probe);
        _encoder = new FFmpegEncoder(_runner, _probe);
        _metrics = new MetricEvaluator(_runner, _probe);
        _contentAnalyzer = new ContentAnalyzer(_runner);
        _sampleWindowPlanner = new SampleWindowPlanner(_runner);
        _complexityAnalyzer = new ComplexityAnalyzer(_runner);
        _cropAnalyzer = new CropAnalyzer(_runner);
        _results = new ResultContract();
    }

    public async Task<CompressionOutcome> RunAsync(
        CompressionRequest request,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        DateTimeOffset started = DateTimeOffset.UtcNow;
        Validate(request);
        if (request.VerboseCommands) _runner.CommandObserver = command => progress?.Report(command);
        PlanLogger planLogger = new(request);
        MediaInfo media = await _probe.ProbeMediaAsync(request, cancellationToken).ConfigureAwait(false);
        await planLogger.WriteAsync("source-probed", media, cancellationToken).ConfigureAwait(false);
        if (media.IsHdr) throw new NotSupportedException($"HDR input is rejected until an explicit color-management policy is selected ({media.HDRClassification}: {media.HDRReason}).");
        IReadOnlyList<ResolvedPolicy> policyCandidates = FilterByOutputExtension(_policy.ResolveCandidates(request), request.OutputPath);
        ResolvedPolicy? copyPolicy = media.InputBytes <= request.TargetBytes
            ? policyCandidates.FirstOrDefault(candidate => InputMatches(media, candidate.Profile))
            : null;
        if (request.UnderCapBehavior == UnderCapBehavior.Copy && copyPolicy is null)
            throw new InvalidOperationException("Copy behavior requires an under-cap input matching the requested codec, audio, and container policy.");

        if (copyPolicy is not null && request.UnderCapBehavior != UnderCapBehavior.Transcode)
        {
            string copyOutputPath = ResolveOutputPath(request, copyPolicy.Profile);
            progress?.Report("Input is under cap and matches policy; copying without transcoding.");
            CopyExact(media.Path, copyOutputPath);
            object copyResult = await _results.BuildAsync(started, "copy", request, media, copyPolicy, null, null, null, [], new MetricEnsemble(), copyOutputPath, cancellationToken).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(request.ResultJsonPath))
                await _results.WriteAsync(copyResult, request.ResultJsonPath, cancellationToken).ConfigureAwait(false);
            return new CompressionOutcome(copyOutputPath, copyResult);
        }

        List<(ResolvedPolicy Policy, CapabilityProbeResult Capability)> viablePolicies = [];
        List<string> capabilityErrors = [];
        foreach (ResolvedPolicy candidate in policyCandidates)
        {
            if (request.OutputBitDepth == "10" && (candidate.Profile.IsHardware || candidate.Profile.VideoCodec is not ("x265" or "av1" or "vp9")))
            {
                capabilityErrors.Add($"{candidate.Profile.Backend}: requested 10-bit output is unsupported by this delivery profile");
                continue;
            }
            CapabilityProbeResult capability = await _capabilityProbe.ProbeAsync(request, candidate.Profile, cancellationToken).ConfigureAwait(false);
            await planLogger.WriteAsync("capability-probed", capability, cancellationToken).ConfigureAwait(false);
            if (capability.Success)
            {
                viablePolicies.Add((candidate, capability));
                if (request.Mode == CompressionMode.Fast) break;
            }
            else capabilityErrors.Add($"{candidate.Profile.Backend}: {capability.Error}");
        }
        if (viablePolicies.Count == 0)
            throw new InvalidOperationException("No eligible encoder backend passed its functional probe: " + string.Join(" | ", capabilityErrors));

        string tempDirectory = Path.Combine(Path.GetTempPath(), $"byakuren-job-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDirectory);
        try
        {
            ModeStrategy strategy = CompressionPlanner.Strategy(request.Mode);
            CropAnalysis crop = await _cropAnalyzer.AnalyzeAsync(request, media, cancellationToken).ConfigureAwait(false);
            progress?.Report($"Crop analysis: {crop.Summary}");
            IReadOnlyList<SampleWindow> sampleWindows = await _sampleWindowPlanner.CreateAsync(
                request, media, tempDirectory, request.ProbeSampleSeconds, strategy.ProbeMaxSamples, cancellationToken).ConfigureAwait(false);
            ComplexityAnalysis complexity = await _complexityAnalyzer.AnalyzeAsync(request, media, sampleWindows, tempDirectory, cancellationToken).ConfigureAwait(false);
            ContentAnalysis? contentAnalysis = request.ContentClassMode.Equals("off", StringComparison.OrdinalIgnoreCase)
                ? null
                : await _contentAnalyzer.AnalyzeAsync(request, media, cancellationToken).ConfigureAwait(false);
            if (contentAnalysis is not null)
                progress?.Report($"Content classification: {contentAnalysis.ContentClass} ({ContentFeatures.ClassifierVersion})");
            progress?.Report($"Complexity: detail {complexity.DetailBucket}, motion {complexity.MotionBucket}, sampling {complexity.SamplingMode}");
            await planLogger.WriteAsync("analysis-complete", new { Crop = crop, Samples = sampleWindows, Complexity = complexity, Content = contentAnalysis }, cancellationToken).ConfigureAwait(false);

            Dictionary<string, AudioArtifact> audioArtifacts = new(StringComparer.Ordinal);
            List<CompressionPlan> allCandidates = [];
            foreach ((ResolvedPolicy policy, _) in viablePolicies)
            {
                IReadOnlyList<AudioPlan> audioPlans = _planner.CreateAudioPlans(request, media, policy.Profile, complexity, contentAnalysis?.ContentClass ?? "general");
                foreach (AudioPlan audioPlan in audioPlans)
                {
                    string audioKey = $"{policy.Profile.AudioEncoder}|{audioPlan.Identity}";
                    if (!audioArtifacts.TryGetValue(audioKey, out AudioArtifact? artifact))
                    {
                        artifact = await _encoder.EncodeAudioAsync(request, media, policy.Profile, tempDirectory, audioPlan, cancellationToken).ConfigureAwait(false);
                        audioArtifacts[audioKey] = artifact;
                        await planLogger.WriteAsync("audio-cached", artifact with { Path = null }, cancellationToken).ConfigureAwait(false);
                    }
                    IReadOnlyList<CompressionPlan> plans = _planner.CreateCandidatePlans(request, media, policy.Profile, artifact, contentAnalysis, complexity, crop, sampleWindows);
                    allCandidates.AddRange(plans);
                }
            }
            if (allCandidates.Count == 0) throw new InvalidOperationException("Planning produced no eligible compression plans.");
            await planLogger.WriteAsync("candidates-created", allCandidates, cancellationToken).ConfigureAwait(false);

            IReadOnlyList<PlanPreview> previews = await PreviewCandidatesAsync(request, media, allCandidates, viablePolicies, tempDirectory, strategy, progress, planLogger, cancellationToken).ConfigureAwait(false);
            CompressionPlan selectedPlan = SelectPlan(allCandidates, previews);
            List<CompressionPlan> encodeOrder = BuildEncodeOrder(selectedPlan, allCandidates, previews);
            await planLogger.WriteAsync("plan-selected", new { Selected = selectedPlan, Previews = previews.Select(preview => new { preview.Plan.Identity, preview.Metrics, preview.OutputBytes, preview.RuntimeSeconds }) }, cancellationToken).ConfigureAwait(false);

            List<CorrectionPoint> corrections = [];
            EncodeAttempt? best = null;
            int currentIndex = 0;
            int attemptsOnCurrentPlan = 0;
            CompressionPlan currentPlan = encodeOrder[0];
            Dictionary<string, int> priority = encodeOrder.Select((plan, index) => (Key: PlanKey(plan), Index: index)).DistinctBy(item => item.Key).ToDictionary(item => item.Key, item => item.Index, StringComparer.Ordinal);
            Dictionary<string, List<CorrectionPoint>> correctionHistory = new(StringComparer.Ordinal);
            Dictionary<string, EncodeAttempt> lastAttempts = new(StringComparer.Ordinal);

            for (int attemptNumber = 1; attemptNumber <= strategy.MaxFullEncodes; attemptNumber++)
            {
                attemptsOnCurrentPlan++;
                CapabilityProbeResult capability = CapabilityFor(currentPlan, viablePolicies);
                AudioArtifact audio = AudioFor(currentPlan, audioArtifacts);
                IReadOnlyList<AudioArtifact> fallbackAudio = audioArtifacts
                    .Where(pair => pair.Key.StartsWith(currentPlan.Profile.AudioEncoder + "|", StringComparison.Ordinal))
                    .Select(pair => pair.Value)
                    .ToArray();
                progress?.Report($"Encode {attemptNumber}/{strategy.MaxFullEncodes}: {currentPlan.Width}x{currentPlan.Height}@{currentPlan.Fps:0.###}, {currentPlan.VideoKbps} kbps, {currentPlan.Profile.Backend}, {currentPlan.AudioPlan.Label}");
                EncodeAttempt attempt = await _encoder.EncodeAttemptAsync(request, media, currentPlan, audio, fallbackAudio, tempDirectory, attemptNumber, capability.Device, cancellationToken).ConfigureAwait(false);
                currentPlan = attempt.Plan;
                CorrectionPoint correctionPoint = new(attemptNumber, currentPlan.VideoKbps, attempt.VideoPayloadBytes, attempt.AudioPayloadBytes, attempt.MuxOverheadBytes, attempt.SizeBytes);
                corrections.Add(correctionPoint);
                string currentKey = PlanKey(currentPlan);
                if (!correctionHistory.TryGetValue(currentKey, out List<CorrectionPoint>? planHistory))
                {
                    planHistory = [];
                    correctionHistory[currentKey] = planHistory;
                }
                planHistory.Add(correctionPoint);
                lastAttempts[currentKey] = attempt;
                await planLogger.WriteAsync("encode-attempt", new { attempt.Attempt, attempt.SizeBytes, attempt.VideoPayloadBytes, attempt.AudioPayloadBytes, attempt.MuxOverheadBytes, attempt.UnderCap, Plan = currentPlan }, cancellationToken).ConfigureAwait(false);
                if (attempt.UnderCap && BetterAttempt(attempt, best, priority))
                {
                    if (best?.OutputPath is not null) TryDelete(best.OutputPath);
                    best = attempt;
                }
                else if (attempt.OutputPath is not null && !ReferenceEquals(best, attempt)) TryDelete(attempt.OutputPath);

                if (best is not null && best.Plan.Identity == currentPlan.Identity && best.FillRatio >= strategy.FillGate) break;
                if (attemptNumber == strategy.MaxFullEncodes) break;

                if (request.Mode == CompressionMode.ExtraQuality && attemptNumber == strategy.MaxFullEncodes - 1 && best is not null)
                {
                    currentPlan = best.Plan;
                    string bestKey = PlanKey(currentPlan);
                    EncodeAttempt reference = lastAttempts[bestKey];
                    int corrected = _planner.CorrectBitrate(currentPlan, reference, correctionHistory[bestKey]);
                    if (corrected != currentPlan.VideoKbps)
                    {
                        currentPlan = currentPlan with
                        {
                            VideoKbps = corrected,
                            MaxrateKbps = currentPlan.MaxrateKbps.HasValue ? Math.Max(35, (int)Math.Ceiling(corrected * 1.5)) : null,
                            BufsizeKbits = currentPlan.BufsizeKbits.HasValue ? Math.Max(70, (int)Math.Ceiling(corrected * 3.0)) : null
                        };
                        continue;
                    }
                }

                bool useStructuralFinalist = request.Mode == CompressionMode.ExtraQuality && attemptsOnCurrentPlan >= 2 && currentIndex + 1 < Math.Min(strategy.Finalists, encodeOrder.Count);
                if (useStructuralFinalist)
                {
                    currentIndex++;
                    currentPlan = encodeOrder[currentIndex];
                    attemptsOnCurrentPlan = 0;
                    continue;
                }

                int nextBitrate = _planner.CorrectBitrate(currentPlan, attempt, correctionHistory[currentKey]);
                if (nextBitrate == currentPlan.VideoKbps) break;
                currentPlan = currentPlan with
                {
                    VideoKbps = nextBitrate,
                    MaxrateKbps = currentPlan.MaxrateKbps.HasValue ? Math.Max(35, (int)Math.Ceiling(nextBitrate * 1.5)) : null,
                    BufsizeKbits = currentPlan.BufsizeKbits.HasValue ? Math.Max(70, (int)Math.Ceiling(nextBitrate * 3.0)) : null
                };
            }

            if (best?.OutputPath is null) throw new InvalidOperationException("No encode attempt satisfied the hard byte cap.");
            CompressionPlan finalPlan = best.Plan;
            ResolvedPolicy finalPolicy = viablePolicies.First(item => item.Policy.Profile.Backend == finalPlan.Profile.Backend).Policy with { Profile = finalPlan.Profile };
            CapabilityProbeResult finalCapability = CapabilityFor(finalPlan, viablePolicies);
            string outputPath = ResolveOutputPath(request, finalPlan.Profile);
            CopyExact(best.OutputPath, outputPath);
            if (new FileInfo(outputPath).Length > request.TargetBytes)
            {
                TryDelete(outputPath);
                throw new InvalidOperationException("Final mux exceeded the requested hard byte cap.");
            }
            try
            {
                await _runner.RunCheckedAsync(request.FFmpegPath, ["-v", "error", "-i", outputPath, "-f", "null", "-"], cancellationToken).ConfigureAwait(false);
            }
            catch
            {
                TryDelete(outputPath);
                throw;
            }

            MetricEnsemble metricResult = await _metrics.EvaluateAsync(request, media, finalPlan, outputPath, tempDirectory, cancellationToken).ConfigureAwait(false);
            object result = await _results.BuildAsync(started, "encode", request, media, finalPolicy, finalCapability, finalPlan, best, corrections, metricResult, outputPath, cancellationToken).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(request.ResultJsonPath))
                await _results.WriteAsync(result, request.ResultJsonPath, cancellationToken).ConfigureAwait(false);
            await planLogger.WriteAsync("completed", new { OutputPath = outputPath, Bytes = new FileInfo(outputPath).Length, Metrics = metricResult }, cancellationToken).ConfigureAwait(false);
            return new CompressionOutcome(outputPath, result);
        }
        finally
        {
            try { Directory.Delete(tempDirectory, recursive: true); } catch { }
            _runner.CommandObserver = null;
        }
    }

    private async Task<IReadOnlyList<PlanPreview>> PreviewCandidatesAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<CompressionPlan> candidates,
        IReadOnlyList<(ResolvedPolicy Policy, CapabilityProbeResult Capability)> viablePolicies,
        string tempDirectory,
        ModeStrategy strategy,
        IProgress<string>? progress,
        PlanLogger logger,
        CancellationToken cancellationToken)
    {
        if (strategy.PreviewTop <= 0 || request.MetricMode == MetricMode.Off) return [];
        bool metricAvailable = request.MetricMode != MetricMode.Auto ||
            await _probe.HasFilterAsync(request.FFmpegPath, "libvmaf", cancellationToken).ConfigureAwait(false) ||
            await _probe.HasFilterAsync(request.FFmpegPath, "xpsnr", cancellationToken).ConfigureAwait(false);
        if (!metricAvailable) return [];

        IReadOnlyList<CompressionPlan> previewPlans = _planner.CreatePreviewShortlist(candidates, strategy.PreviewTop);

        List<PlanPreview> previews = [];
        int previewNumber = 0;
        foreach (CompressionPlan plan in previewPlans.Take(strategy.PreviewTop))
        {
            previewNumber++;
            progress?.Report($"Preview {previewNumber}/{Math.Min(strategy.PreviewTop, previewPlans.Count)}: {plan.Profile.Backend} {plan.Width}x{plan.Height}@{plan.Fps:0.###} {plan.Preprocess}");
            DateTimeOffset started = DateTimeOffset.UtcNow;
            List<MetricEnsemble> windowMetrics = [];
            long bytes = 0;
            string lastPath = "";
            try
            {
                CapabilityProbeResult capability = CapabilityFor(plan, viablePolicies);
                IReadOnlyList<SampleWindow> windows = plan.SampleWindows.OrderByDescending(window => window.DifficultyScore + window.SceneScore * 150).Take(strategy.PreviewMaxSamples).ToArray();
                if (windows.Count == 0) windows = [new SampleWindow(0, Math.Min(4, media.DurationSeconds), "fallback")];
                foreach (SampleWindow window in windows)
                {
                    string path = await _encoder.EncodePreviewAsync(request, media, plan, window, tempDirectory, capability.Device, cancellationToken).ConfigureAwait(false);
                    lastPath = path;
                    bytes += new FileInfo(path).Length;
                    windowMetrics.Add(await _metrics.EvaluatePreviewAsync(request, media, plan, path, tempDirectory, window, cancellationToken).ConfigureAwait(false));
                    TryDelete(path);
                }
                MetricEnsemble merged = MergeMetrics(windowMetrics);
                PlanPreview preview = new(plan, merged, lastPath, bytes, (DateTimeOffset.UtcNow - started).TotalSeconds);
                previews.Add(preview);
                await logger.WriteAsync("preview-complete", new { Plan = plan, Metrics = merged, Bytes = bytes, preview.RuntimeSeconds }, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                await logger.WriteAsync("preview-failed", new { Plan = plan, Error = exception.Message }, cancellationToken).ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(lastPath)) TryDelete(lastPath);
            }
        }
        return previews;
    }

    private static CompressionPlan SelectPlan(IReadOnlyList<CompressionPlan> candidates, IReadOnlyList<PlanPreview> previews)
    {
        PlanPreview[] available = previews.Where(preview => preview.Metrics.Available).ToArray();
        if (available.Length == 0) return candidates.OrderByDescending(plan => plan.HeuristicScore).First();
        double bestPrimary = available.Max(preview => preview.Metrics.PrimaryScore ?? double.MinValue);
        PlanPreview[] materialContenders = available.Where(preview => (preview.Metrics.PrimaryScore ?? double.MinValue) >= bestPrimary - 0.25).ToArray();
        double? bestXPSNR = materialContenders.Where(preview => preview.Metrics.XPSNR.HasValue).Select(preview => preview.Metrics.XPSNR).Max();
        if (bestXPSNR.HasValue)
            materialContenders = materialContenders.Where(preview => preview.Metrics.XPSNR.HasValue && preview.Metrics.XPSNR.Value >= bestXPSNR.Value - 0.5).ToArray();
        return materialContenders
            .OrderByDescending(preview => preview.Metrics.PrimaryScore)
            .ThenByDescending(preview => preview.Metrics.WorstWindowScore)
            .ThenByDescending(preview => preview.Plan.AudioPlan.Rank)
            .ThenByDescending(preview => preview.Plan.HeuristicScore)
            .First().Plan;
    }

    private static List<CompressionPlan> BuildEncodeOrder(CompressionPlan selected, IReadOnlyList<CompressionPlan> candidates, IReadOnlyList<PlanPreview> previews)
    {
        List<CompressionPlan> order = [selected];
        foreach (CompressionPlan plan in previews.Where(preview => preview.Metrics.Available).OrderByDescending(preview => preview.Metrics.PrimaryScore).Select(preview => preview.Plan))
            if (order.All(existing => existing.Identity != plan.Identity || existing.AudioPlan.Identity != plan.AudioPlan.Identity)) order.Add(plan);
        foreach (CompressionPlan plan in candidates
            .Where(plan => plan.Profile.Backend == selected.Profile.Backend)
            .OrderBy(plan => Math.Abs(plan.Width - selected.Width) + Math.Abs(plan.Fps - selected.Fps) * 20)
            .ThenByDescending(plan => plan.HeuristicScore))
            if (order.All(existing => existing.Identity != plan.Identity || existing.AudioPlan.Identity != plan.AudioPlan.Identity)) order.Add(plan);
        return order;
    }

    private static MetricEnsemble MergeMetrics(IReadOnlyList<MetricEnsemble> metrics)
    {
        MetricEnsemble[] available = metrics.Where(metric => metric.Available).ToArray();
        if (available.Length == 0) return new MetricEnsemble { Mode = metrics.FirstOrDefault()?.Mode ?? "off", Error = metrics.Select(metric => metric.Error).LastOrDefault(error => !string.IsNullOrWhiteSpace(error)) };
        List<MetricWindow> windows = available.SelectMany(metric => metric.Windows).Select((window, index) => window with { Index = index }).ToList();
        double? vmaf = Average(available.Select(metric => metric.VMAFNeg));
        double? xpsnr = Average(available.Select(metric => metric.XPSNR));
        return new MetricEnsemble
        {
            Available = true,
            Mode = available[0].Mode,
            PrimaryScore = vmaf ?? xpsnr,
            WorstWindowScore = vmaf.HasValue ? Minimum(available.Select(metric => metric.WorstVMAFNeg)) : Minimum(available.Select(metric => metric.WorstXPSNR)),
            VMAFNeg = vmaf,
            WorstVMAFNeg = Minimum(available.Select(metric => metric.WorstVMAFNeg)),
            StandardVMAF = Average(available.Select(metric => metric.StandardVMAF)),
            XPSNR = xpsnr,
            WorstXPSNR = Minimum(available.Select(metric => metric.WorstXPSNR)),
            CAMBI = Average(available.Select(metric => metric.CAMBI)),
            WorstCAMBI = Maximum(available.Select(metric => metric.WorstCAMBI)),
            Windows = windows
        };
    }

    private static AudioArtifact AudioFor(CompressionPlan plan, IReadOnlyDictionary<string, AudioArtifact> artifacts) =>
        artifacts[$"{plan.Profile.AudioEncoder}|{plan.AudioPlan.Identity}"];
    private static CapabilityProbeResult CapabilityFor(CompressionPlan plan, IReadOnlyList<(ResolvedPolicy Policy, CapabilityProbeResult Capability)> policies) =>
        policies.First(item => item.Policy.Profile.Backend == plan.Profile.Backend).Capability;
    private static bool BetterAttempt(EncodeAttempt attempt, EncodeAttempt? best, IReadOnlyDictionary<string, int> priority) =>
        best is null || priority[PlanKey(attempt.Plan)] < priority[PlanKey(best.Plan)] || priority[PlanKey(attempt.Plan)] == priority[PlanKey(best.Plan)] && attempt.SizeBytes > best.SizeBytes;
    private static string PlanKey(CompressionPlan plan) => plan.Identity + "|" + plan.AudioPlan.Identity;
    private static double? Average(IEnumerable<double?> values) { double[] available = values.Where(value => value.HasValue).Select(value => value!.Value).ToArray(); return available.Length == 0 ? null : available.Average(); }
    private static double? Minimum(IEnumerable<double?> values) { double[] available = values.Where(value => value.HasValue).Select(value => value!.Value).ToArray(); return available.Length == 0 ? null : available.Min(); }
    private static double? Maximum(IEnumerable<double?> values) { double[] available = values.Where(value => value.HasValue).Select(value => value!.Value).ToArray(); return available.Length == 0 ? null : available.Max(); }

    private static void Validate(CompressionRequest request)
    {
        if (!File.Exists(request.InputPath)) throw new FileNotFoundException("Input file was not found.", request.InputPath);
        if (request.TargetBytes <= 0) throw new ArgumentOutOfRangeException(nameof(request.TargetBytes));
        if (request.WorkingTargetRatio is <= 0 or > 1) throw new ArgumentOutOfRangeException(nameof(request.WorkingTargetRatio));
        if (request.ProbeSampleSeconds <= 0) throw new ArgumentOutOfRangeException(nameof(request.ProbeSampleSeconds));
        if (!request.ContentClassMode.Equals("auto", StringComparison.OrdinalIgnoreCase) && !request.ContentClassMode.Equals("off", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Content class mode must be 'auto' or 'off'.", nameof(request.ContentClassMode));
    }

    private static string ResolveOutputPath(CompressionRequest request, EncoderProfile profile)
    {
        string? output = request.OutputPath;
        if (string.IsNullOrWhiteSpace(output))
        {
            string input = Path.GetFullPath(request.InputPath);
            string mode = request.Mode.ToString().ToLowerInvariant();
            output = Path.Combine(Path.GetDirectoryName(input)!, $"{Path.GetFileNameWithoutExtension(input)}_{request.TargetBytes}_{profile.Backend}_{mode}{profile.Extension}");
        }
        output = Path.GetFullPath(output);
        if (!Path.GetExtension(output).Equals(profile.Extension, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException($"Output extension must be '{profile.Extension}' for the resolved {profile.Container} profile.");
        return output;
    }

    private static bool InputMatches(MediaInfo media, EncoderProfile profile)
    {
        bool videoMatches = profile.VideoCodec switch
        {
            "x264" => media.VideoCodec == "h264",
            "x265" => media.VideoCodec is "hevc" or "h265",
            "av1" => media.VideoCodec == "av1",
            "vp9" => media.VideoCodec == "vp9",
            _ => false
        };
        bool containerMatches = profile.Container switch
        {
            "mp4" => media.FormatName.Split(',').Any(format => format is "mov" or "mp4"),
            "webm" => media.FormatName.Split(',').Any(format => format is "matroska" or "webm"),
            _ => false
        };
        bool audioMatches = !media.HasAudio || media.AudioCodec == profile.AudioCodec;
        return videoMatches && containerMatches && audioMatches;
    }

    private static IReadOnlyList<ResolvedPolicy> FilterByOutputExtension(IReadOnlyList<ResolvedPolicy> policies, string? outputPath)
    {
        if (string.IsNullOrWhiteSpace(outputPath)) return policies;
        string extension = Path.GetExtension(outputPath);
        ResolvedPolicy[] matching = policies.Where(policy => extension.Equals(policy.Profile.Extension, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (matching.Length == 0) throw new ArgumentException($"No eligible codec policy produces output extension '{extension}'.");
        return matching;
    }

    private static void CopyExact(string source, string destination)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        if (!Path.GetFullPath(source).Equals(Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase)) File.Copy(source, destination, overwrite: true);
    }

    private static void TryDelete(string path) { try { File.Delete(path); } catch { } }
}
