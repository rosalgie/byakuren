using System.ComponentModel;
using System.Globalization;
using Byakuren.Analysis;
using Byakuren.Encoding;
using Byakuren.Execution;
using Byakuren.IO;
using Byakuren.Metrics;
using Byakuren.Models;
using Byakuren.Planner;
using Byakuren.Policy;
using Byakuren.Probe;
using Byakuren.Results;

namespace Byakuren.Worker;

public sealed class CompressionWorker
{
    private const double AdaptiveXpsnrConfidenceMargin = 0.25;

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

        _runner.WarningObserver = progress is null ? null : progress.Report;

        if (request.Verbose)
        {
            _runner.CommandObserver = command => progress?.Report(command);
            _runner.OutputObserver = output => progress?.Report(output);
        }

        try
        {
            PlanLogger planLogger = new(request);
            MediaInfo media = await _probe
                .ProbeMediaAsync(request, cancellationToken)
                .ConfigureAwait(false);

            await planLogger
                .WriteAsync("source-probed", media, cancellationToken)
                .ConfigureAwait(false);

            if (media.IsHdr)
                throw new NotSupportedException(
                    "HDR input is unsupported at this time " +
                    $"({media.HDRClassification}: {media.HDRReason}).");

            IReadOnlyList<ResolvedPolicy> policyCandidates = FilterByOutputExtension(
                _policy.ResolveCandidates(request),
                request.OutputPath);

            ResolvedPolicy? copyPolicy = null;
            if (media.InputBytes <= request.TargetBytes)
            {
                copyPolicy = policyCandidates.FirstOrDefault(
                    candidate => InputMatches(media, candidate.Profile));
            }
            if (request.UnderCapBehavior == UnderCapBehavior.Copy && copyPolicy is null)
            {
                throw new InvalidOperationException(
                    "Copy behavior requires an under-cap input matching the requested " +
                    "codec, audio, and container policy.");
            }

            if (copyPolicy is not null && request.UnderCapBehavior != UnderCapBehavior.Transcode)
            {
                return await CopyInputAsync(
                    started,
                    request,
                    media,
                    copyPolicy,
                    progress,
                    cancellationToken).ConfigureAwait(false);
            }

            IReadOnlyList<ViablePolicy> viablePolicies = await ProbePoliciesAsync(
                request,
                policyCandidates,
                planLogger,
                cancellationToken).ConfigureAwait(false);

            string tempDirectory = Path.Combine(
                Path.GetTempPath(),
                $"byakuren-job-{Guid.NewGuid():N}");
            Directory.CreateDirectory(tempDirectory);
            try
            {
                return await CompressAsync(
                    started,
                    request,
                    media,
                    viablePolicies,
                    tempDirectory,
                    progress,
                    planLogger,
                    cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                FileSystemCleanup.DeleteDirectory(
                    tempDirectory,
                    recursive: true,
                    _runner.ReportWarning);
            }
        }
        finally
        {
            _runner.CommandObserver = null;
            _runner.OutputObserver = null;
            _runner.WarningObserver = null;
        }
    }

    private async Task<CompressionOutcome> CopyInputAsync(
        DateTimeOffset started,
        CompressionRequest request,
        MediaInfo media,
        ResolvedPolicy copyPolicy,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        string outputPath = ResolveOutputPath(request, copyPolicy.Profile);
        progress?.Report("Input is under cap and matches policy; copying without transcoding.");
        CopyExact(media.Path, outputPath);

        object result = await _results.BuildAsync(
            started,
            "copy",
            request,
            media,
            copyPolicy,
            capability: null,
            plan: null,
            attempt: null,
            corrections: [],
            metrics: new MetricEnsemble(),
            outputPath,
            cancellationToken).ConfigureAwait(false);

        if (!string.IsNullOrWhiteSpace(request.ResultJsonPath))
        {
            await _results
                .WriteAsync(result, request.ResultJsonPath, cancellationToken)
                .ConfigureAwait(false);
        }

        return new CompressionOutcome(outputPath, result);
    }

    private async Task<IReadOnlyList<ViablePolicy>> ProbePoliciesAsync(
        CompressionRequest request,
        IReadOnlyList<ResolvedPolicy> policyCandidates,
        PlanLogger planLogger,
        CancellationToken cancellationToken)
    {
        List<ViablePolicy> viablePolicies = [];
        List<string> capabilityErrors = [];

        foreach (ResolvedPolicy candidate in policyCandidates)
        {
            bool codecSupportsTenBit = candidate.Profile.VideoCodec is "x265" or "av1" or "vp9";
            bool supportsRequestedBitDepth = request.OutputBitDepth != "10" ||
                !candidate.Profile.IsHardware && codecSupportsTenBit;

            if (!supportsRequestedBitDepth)
            {
                capabilityErrors.Add(
                    $"{candidate.Profile.Backend}: requested 10-bit output is unsupported " +
                    "by this delivery profile");
                continue;
            }

            CapabilityProbeResult capability = await _capabilityProbe
                .ProbeAsync(request, candidate.Profile, cancellationToken)
                .ConfigureAwait(false);

            await planLogger
                .WriteAsync("capability-probed", capability, cancellationToken)
                .ConfigureAwait(false);

            if (!capability.Success)
            {
                capabilityErrors.Add($"{candidate.Profile.Backend}: {capability.Error}");
                continue;
            }

            viablePolicies.Add(new ViablePolicy(candidate, capability));
            if (request.Mode == CompressionMode.Fast)
            {
                break;
            }
        }

        if (viablePolicies.Count == 0)
        {
            throw new InvalidOperationException(
                "No eligible encoder backend passed its functional probe: " +
                string.Join(" | ", capabilityErrors));
        }

        return viablePolicies;
    }

    private async Task<CompressionOutcome> CompressAsync(
        DateTimeOffset started,
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<ViablePolicy> viablePolicies,
        string tempDirectory,
        IProgress<string>? progress,
        PlanLogger planLogger,
        CancellationToken cancellationToken)
    {
        ModeStrategy strategy = CompressionPlanner.Strategy(request.Mode);
        AnalysisResults analysis = await AnalyzeAsync(
            request,
            media,
            tempDirectory,
            strategy,
            progress,
            planLogger,
            cancellationToken).ConfigureAwait(false);

        CandidateSet candidates = await CreateCandidatesAsync(
            request,
            media,
            viablePolicies,
            analysis,
            tempDirectory,
            planLogger,
            cancellationToken).ConfigureAwait(false);

        PreviewEvaluation previewEvaluation = await PreviewCandidatesAsync(
            request,
            media,
            candidates.Plans,
            viablePolicies,
            tempDirectory,
            strategy,
            progress,
            planLogger,
            cancellationToken).ConfigureAwait(false);
        IReadOnlyList<PlanPreview> previews = previewEvaluation.Previews;

        CompressionPlan selectedPlan = SelectPlan(candidates.Plans, previews);
        List<CompressionPlan> encodeOrder = BuildEncodeOrder(
            selectedPlan,
            candidates.Plans,
            previews);

        object selectionLog = new
        {
            Selected = selectedPlan,
            AdaptiveMetric = previewEvaluation.Decision,
            Previews = previews.Select(preview => new
            {
                preview.Plan.Identity,
                preview.Metrics,
                preview.OutputBytes,
                preview.RuntimeSeconds
            })
        };

        await planLogger
            .WriteAsync("plan-selected", selectionLog, cancellationToken)
            .ConfigureAwait(false);

        EncodingResult encoding = await EncodeAsync(
            request,
            media,
            viablePolicies,
            candidates.AudioArtifacts,
            encodeOrder,
            tempDirectory,
            strategy,
            progress,
            planLogger,
            cancellationToken).ConfigureAwait(false);

        return await FinalizeAsync(
            started,
            request,
            media,
            viablePolicies,
            encoding,
            tempDirectory,
            previewEvaluation.FinalMetricMode,
            planLogger,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<AnalysisResults> AnalyzeAsync(
        CompressionRequest request,
        MediaInfo media,
        string tempDirectory,
        ModeStrategy strategy,
        IProgress<string>? progress,
        PlanLogger planLogger,
        CancellationToken cancellationToken)
    {
        CropAnalysis crop = await _cropAnalyzer
            .AnalyzeAsync(request, media, cancellationToken)
            .ConfigureAwait(false);
        progress?.Report($"Crop analysis: {crop.Summary}");

        IReadOnlyList<SampleWindow> sampleWindows = await _sampleWindowPlanner
            .CreateAsync(
                request,
                media,
                tempDirectory,
                request.ProbeSampleSeconds,
                strategy.ProbeMaxSamples,
                cancellationToken)
            .ConfigureAwait(false);

        ComplexityAnalysis complexity = await _complexityAnalyzer
            .AnalyzeAsync(request, media, sampleWindows, tempDirectory, cancellationToken)
            .ConfigureAwait(false);

        string requestedContentClass = ContentClassSelection.Normalize(request.ContentClassMode);
        ContentAnalysis? content = null;
        if (requestedContentClass != ContentClassSelection.Off)
        {
            content = await _contentAnalyzer
                .AnalyzeAsync(request, media, sampleWindows, cancellationToken)
                .ConfigureAwait(false);
            if (ContentClassSelection.IsExplicit(requestedContentClass))
            {
                content = content with
                {
                    ContentClass = requestedContentClass,
                    Source = ContentAnalysis.ManualSource
                };
            }
        }

        if (content is not null)
        {
            string traits = content.Traits.Count == 0
                ? ""
                : $" [{string.Join(", ", content.Traits)}]";
            string margin = content.Source == ContentAnalysis.ManualSource
                ? ""
                : $", margin {content.HeuristicConfidenceMargin:0.000}";
            progress?.Report(
                $"Content classification: {content.ContentClass}{traits} " +
                $"({content.Source}{margin})");
        }

        progress?.Report(
            $"Complexity: detail {complexity.DetailBucket}, motion {complexity.MotionBucket}, " +
            $"sampling {complexity.SamplingMode}");

        AnalysisResults analysis = new(crop, sampleWindows, complexity, content);
        object analysisLog = new
        {
            Crop = crop,
            Samples = sampleWindows,
            Complexity = complexity,
            Content = content
        };
        await planLogger
            .WriteAsync("analysis-complete", analysisLog, cancellationToken)
            .ConfigureAwait(false);

        return analysis;
    }

    private async Task<CandidateSet> CreateCandidatesAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<ViablePolicy> viablePolicies,
        AnalysisResults analysis,
        string tempDirectory,
        PlanLogger planLogger,
        CancellationToken cancellationToken)
    {
        Dictionary<string, AudioArtifact> audioArtifacts = new(StringComparer.Ordinal);
        List<CompressionPlan> candidates = [];

        foreach (ViablePolicy viablePolicy in viablePolicies)
        {
            EncoderProfile profile = viablePolicy.Policy.Profile;
            string contentClass = analysis.Content?.ContentClass ?? "general";
            IReadOnlyList<AudioPlan> audioPlans = _planner.CreateAudioPlans(
                request,
                media,
                profile,
                analysis.Complexity,
                contentClass);

            foreach (AudioPlan audioPlan in audioPlans)
            {
                string audioKey = $"{profile.AudioEncoder}|{audioPlan.Identity}";
                if (!audioArtifacts.TryGetValue(audioKey, out AudioArtifact? artifact))
                {
                    artifact = await _encoder.EncodeAudioAsync(
                        request,
                        media,
                        profile,
                        tempDirectory,
                        audioPlan,
                        cancellationToken).ConfigureAwait(false);

                    audioArtifacts[audioKey] = artifact;
                    await planLogger
                        .WriteAsync("audio-cached", artifact with { Path = null }, cancellationToken)
                        .ConfigureAwait(false);
                }

                IReadOnlyList<CompressionPlan> plans = _planner.CreateCandidatePlans(
                    request,
                    media,
                    profile,
                    artifact,
                    analysis.Content,
                    analysis.Complexity,
                    analysis.Crop,
                    analysis.SampleWindows);

                candidates.AddRange(plans);
            }
        }

        if (candidates.Count == 0)
            throw new InvalidOperationException("Planning produced no eligible compression plans.");

        await planLogger
            .WriteAsync("candidates-created", candidates, cancellationToken)
            .ConfigureAwait(false);

        return new CandidateSet(candidates, audioArtifacts);
    }

    private async Task<EncodingResult> EncodeAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<ViablePolicy> viablePolicies,
        IReadOnlyDictionary<string, AudioArtifact> audioArtifacts,
        IReadOnlyList<CompressionPlan> encodeOrder,
        string tempDirectory,
        ModeStrategy strategy,
        IProgress<string>? progress,
        PlanLogger planLogger,
        CancellationToken cancellationToken)
    {
        List<CorrectionPoint> corrections = [];
        EncodeAttempt? best = null;
        int currentIndex = 0;
        int attemptsOnCurrentPlan = 0;
        CompressionPlan currentPlan = encodeOrder[0];

        Dictionary<string, int> priority = encodeOrder
            .Select((plan, index) => (Key: PlanKey(plan), Index: index))
            .DistinctBy(item => item.Key)
            .ToDictionary(item => item.Key, item => item.Index, StringComparer.Ordinal);

        Dictionary<string, List<CorrectionPoint>> correctionHistory = new(StringComparer.Ordinal);
        Dictionary<string, EncodeAttempt> lastAttempts = new(StringComparer.Ordinal);

        for (int attemptNumber = 1; attemptNumber <= strategy.MaxFullEncodes; attemptNumber++)
        {
            attemptsOnCurrentPlan++;

            CapabilityProbeResult capability = CapabilityFor(currentPlan, viablePolicies);
            string audioKey =
                $"{currentPlan.Profile.AudioEncoder}|{currentPlan.AudioPlan.Identity}";
            AudioArtifact audio = audioArtifacts[audioKey];
            IReadOnlyList<AudioArtifact> fallbackAudio = audioArtifacts
                .Where(pair => pair.Key.StartsWith(
                    currentPlan.Profile.AudioEncoder + "|",
                    StringComparison.Ordinal))
                .Select(pair => pair.Value)
                .ToArray();

            progress?.Report(
                $"Encode {attemptNumber}/{strategy.MaxFullEncodes}: " +
                $"{currentPlan.Width}x{currentPlan.Height}@{currentPlan.Fps:0.###}, " +
                $"{currentPlan.VideoKbps} kbps, {currentPlan.Profile.Backend}, " +
                currentPlan.AudioPlan.Label);

            EncodeAttempt attempt = await _encoder.EncodeAttemptAsync(
                request,
                media,
                currentPlan,
                audio,
                fallbackAudio,
                tempDirectory,
                attemptNumber,
                capability.Device,
                cancellationToken).ConfigureAwait(false);

            currentPlan = attempt.Plan;
            CorrectionPoint correctionPoint = new(
                attemptNumber,
                attempt.Plan.VideoKbps,
                attempt.VideoPayloadBytes,
                attempt.AudioPayloadBytes,
                attempt.MuxOverheadBytes,
                attempt.SizeBytes);
            corrections.Add(correctionPoint);

            string currentKey = PlanKey(currentPlan);
            if (!correctionHistory.TryGetValue(currentKey, out List<CorrectionPoint>? planHistory))
            {
                planHistory = [];
                correctionHistory[currentKey] = planHistory;
            }

            planHistory.Add(correctionPoint);
            lastAttempts[currentKey] = attempt;

            object attemptLog = new
            {
                attempt.Attempt,
                attempt.SizeBytes,
                attempt.VideoPayloadBytes,
                attempt.AudioPayloadBytes,
                attempt.MuxOverheadBytes,
                attempt.UnderCap,
                Plan = currentPlan
            };

            await planLogger
                .WriteAsync("encode-attempt", attemptLog, cancellationToken)
                .ConfigureAwait(false);

            best = KeepBetterAttempt(attempt, best, priority);

            bool targetReached = best is not null &&
                best.Plan.Identity == currentPlan.Identity &&
                best.FillRatio >= strategy.FillGate;

            if (targetReached || attemptNumber == strategy.MaxFullEncodes)
            {
                break;
            }

            bool finalExtraQualityAttempt = request.Mode == CompressionMode.ExtraQuality &&
                attemptNumber == strategy.MaxFullEncodes - 1 &&
                best is not null;

            if (finalExtraQualityAttempt)
            {
                currentPlan = best!.Plan;
                string bestKey = PlanKey(currentPlan);
                EncodeAttempt reference = lastAttempts[bestKey];
                int correctedBitrate = _planner.CorrectBitrate(
                    currentPlan,
                    reference,
                    correctionHistory[bestKey]);

                if (correctedBitrate != currentPlan.VideoKbps)
                {
                    currentPlan = WithBitrate(currentPlan, correctedBitrate);
                    continue;
                }
            }

            bool hasAnotherFinalist = currentIndex + 1 <
                Math.Min(strategy.Finalists, encodeOrder.Count);
            bool useStructuralFinalist = request.Mode == CompressionMode.ExtraQuality &&
                attemptsOnCurrentPlan >= 2 &&
                hasAnotherFinalist;

            if (useStructuralFinalist)
            {
                currentIndex++;
                currentPlan = encodeOrder[currentIndex];
                attemptsOnCurrentPlan = 0;
                continue;
            }

            int nextBitrate = _planner.CorrectBitrate(currentPlan, attempt, planHistory);
            if (nextBitrate == currentPlan.VideoKbps)
            {
                break;
            }

            currentPlan = WithBitrate(currentPlan, nextBitrate);
        }

        if (best?.OutputPath is null)
        {
            throw new InvalidOperationException("No encode attempt satisfied the hard byte cap.");
        }

        return new EncodingResult(best, corrections);
    }

    private async Task<CompressionOutcome> FinalizeAsync(
        DateTimeOffset started,
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<ViablePolicy> viablePolicies,
        EncodingResult encoding,
        string tempDirectory,
        MetricMode finalMetricMode,
        PlanLogger planLogger,
        CancellationToken cancellationToken)
    {
        CompressionPlan finalPlan = encoding.Best.Plan;
        ViablePolicy viablePolicy = viablePolicies.First(
            item => item.Policy.Profile.Backend == finalPlan.Profile.Backend);
        ResolvedPolicy finalPolicy = viablePolicy.Policy with { Profile = finalPlan.Profile };
        string outputPath = ResolveOutputPath(request, finalPlan.Profile);

        CopyExact(encoding.Best.OutputPath!, outputPath);
        if (new FileInfo(outputPath).Length > request.TargetBytes)
        {
            FileSystemCleanup.DeleteFile(outputPath, _runner.ReportWarning);
            throw new InvalidOperationException("Final mux exceeded the requested hard byte cap.");
        }

        await VerifyOutputAsync(request, outputPath, cancellationToken).ConfigureAwait(false);

        MetricEnsemble metrics = await _metrics.EvaluateAsync(
            request with { MetricMode = finalMetricMode },
            media,
            finalPlan,
            outputPath,
            tempDirectory,
            cancellationToken).ConfigureAwait(false);

        object result = await _results.BuildAsync(
            started,
            "encode",
            request,
            media,
            finalPolicy,
            viablePolicy.Capability,
            finalPlan,
            encoding.Best,
            encoding.Corrections,
            metrics,
            outputPath,
            cancellationToken).ConfigureAwait(false);

        if (!string.IsNullOrWhiteSpace(request.ResultJsonPath))
        {
            await _results
                .WriteAsync(result, request.ResultJsonPath, cancellationToken)
                .ConfigureAwait(false);
        }

        object completionLog = new
        {
            OutputPath = outputPath,
            Bytes = new FileInfo(outputPath).Length,
            Metrics = metrics
        };

        await planLogger
            .WriteAsync("completed", completionLog, cancellationToken)
            .ConfigureAwait(false);

        return new CompressionOutcome(outputPath, result);
    }

    private EncodeAttempt? KeepBetterAttempt(
        EncodeAttempt attempt,
        EncodeAttempt? best,
        IReadOnlyDictionary<string, int> priority)
    {
        if (attempt.UnderCap && BetterAttempt(attempt, best, priority))
        {
            if (best?.OutputPath is not null)
            {
                FileSystemCleanup.DeleteFile(best.OutputPath, _runner.ReportWarning);
            }

            return attempt;
        }

        if (attempt.OutputPath is not null && !ReferenceEquals(best, attempt))
        {
            FileSystemCleanup.DeleteFile(attempt.OutputPath, _runner.ReportWarning);
        }

        return best;
    }

    private static CompressionPlan WithBitrate(CompressionPlan plan, int videoKbps)
    {
        int? maxrateKbps = null;
        if (plan.MaxrateKbps.HasValue)
        {
            maxrateKbps = Math.Max(35, (int)Math.Ceiling(videoKbps * 1.5));
        }

        int? bufsizeKbits = null;
        if (plan.BufsizeKbits.HasValue)
        {
            bufsizeKbits = Math.Max(70, (int)Math.Ceiling(videoKbps * 3.0));
        }

        return plan with
        {
            VideoKbps = videoKbps,
            MaxrateKbps = maxrateKbps,
            BufsizeKbits = bufsizeKbits
        };
    }

    private async Task VerifyOutputAsync(
        CompressionRequest request,
        string outputPath,
        CancellationToken cancellationToken)
    {
        try
        {
            await _runner.RunCheckedAsync(
                request.FFmpegPath,
                ["-v", "error", "-i", outputPath, "-f", "null", "-"],
                cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            FileSystemCleanup.DeleteFile(outputPath, _runner.ReportWarning);
            throw;
        }
    }

    private async Task<PreviewEvaluation> PreviewCandidatesAsync(
        CompressionRequest request,
        MediaInfo media,
        IReadOnlyList<CompressionPlan> candidates,
        IReadOnlyList<ViablePolicy> viablePolicies,
        string tempDirectory,
        ModeStrategy strategy,
        IProgress<string>? progress,
        PlanLogger logger,
        CancellationToken cancellationToken)
    {
        if (strategy.PreviewTop <= 0 || request.MetricMode == MetricMode.Off)
        {
            return new PreviewEvaluation(
                [],
                request.MetricMode,
                AdaptiveMetricDecision.Disabled("preview-disabled"));
        }

        bool hasVmaf = true;
        bool hasXpsnr = true;
        MetricMode initialMetricMode = request.MetricMode;
        if (request.MetricMode == MetricMode.Auto)
        {
            hasVmaf = await _probe
                .HasFilterAsync(request.FFmpegPath, "libvmaf", cancellationToken)
                .ConfigureAwait(false);
            hasXpsnr = await _probe
                .HasFilterAsync(request.FFmpegPath, "xpsnr", cancellationToken)
                .ConfigureAwait(false);
            initialMetricMode = hasXpsnr
                ? MetricMode.XPSNR
                : hasVmaf
                    ? MetricMode.VMAF
                    : MetricMode.Off;
        }

        if (initialMetricMode == MetricMode.Off)
        {
            return new PreviewEvaluation(
                [],
                MetricMode.Off,
                AdaptiveMetricDecision.Disabled("no-metric-filter"));
        }

        IReadOnlyList<CompressionPlan> previewPlans = _planner.CreatePreviewShortlist(candidates, strategy.PreviewTop);

        List<PreviewWork> work = [];
        int previewNumber = 0;
        foreach (CompressionPlan plan in previewPlans.Take(strategy.PreviewTop))
        {
            previewNumber++;
            int previewCount = Math.Min(strategy.PreviewTop, previewPlans.Count);
            progress?.Report(
                $"Preview {previewNumber}/{previewCount}: {plan.Profile.Backend} " +
                $"{plan.Width}x{plan.Height}@{plan.Fps:0.###} {plan.Preprocess}");
            DateTimeOffset started = DateTimeOffset.UtcNow;
            List<PreviewSample> samples = [];
            long bytes = 0;
            string lastPath = "";
            try
            {
                CapabilityProbeResult capability = CapabilityFor(plan, viablePolicies);
                IReadOnlyList<SampleWindow> windows = plan.SampleWindows
                    .OrderByDescending(
                        window => window.DifficultyScore + window.SceneScore * 150)
                    .Take(strategy.PreviewMaxSamples)
                    .ToArray();
                if (windows.Count == 0)
                {
                    windows =
                    [
                        new SampleWindow(
                            0,
                            Math.Min(4, media.DurationSeconds),
                            "fallback")
                    ];
                }

                foreach (SampleWindow window in windows)
                {
                    string path = await _encoder.EncodePreviewAsync(
                        request,
                        media,
                        plan,
                        window,
                        tempDirectory,
                        capability.Device,
                        cancellationToken).ConfigureAwait(false);
                    lastPath = path;
                    bytes += new FileInfo(path).Length;
                    MetricEnsemble metrics = await _metrics.EvaluatePreviewAsync(
                        request with { MetricMode = initialMetricMode },
                        media,
                        plan,
                        path,
                        tempDirectory,
                        window,
                        cancellationToken).ConfigureAwait(false);
                    samples.Add(new PreviewSample(window, path, metrics));
                }
                work.Add(new PreviewWork(
                    plan,
                    samples,
                    bytes,
                    (DateTimeOffset.UtcNow - started).TotalSeconds));
            }
            catch (Exception exception) when (
                exception is Win32Exception or
                    IOException or
                    UnauthorizedAccessException or
                    InvalidOperationException or
                    NotSupportedException)
            {
                object failureLog = new { Plan = plan, Error = exception.Message };
                await logger
                    .WriteAsync("preview-failed", failureLog, cancellationToken)
                    .ConfigureAwait(false);
                foreach (PreviewSample sample in samples)
                    FileSystemCleanup.DeleteFile(sample.Path, _runner.ReportWarning);
                if (!string.IsNullOrWhiteSpace(lastPath) &&
                    samples.All(sample => !sample.Path.Equals(lastPath, StringComparison.OrdinalIgnoreCase)))
                {
                    FileSystemCleanup.DeleteFile(lastPath, _runner.ReportWarning);
                }
            }
        }

        IReadOnlyList<PlanPreview> initialPreviews = CreatePreviews(work);
        AdaptiveMetricDecision decision = ResolveAdaptiveMetricDecision(
            request,
            hasVmaf,
            hasXpsnr,
            initialPreviews);
        bool evaluateVmafFallback = decision.UseVmafFallback &&
            initialMetricMode == MetricMode.XPSNR &&
            hasVmaf;
        MetricMode finalMetricMode = evaluateVmafFallback
            ? MetricMode.Ensemble
            : initialMetricMode;

        try
        {
            if (evaluateVmafFallback)
            {
                for (int candidateIndex = work.Count - 1; candidateIndex >= 0; candidateIndex--)
                {
                    PreviewWork candidate = work[candidateIndex];
                    DateTimeOffset fallbackStarted = DateTimeOffset.UtcNow;
                    try
                    {
                        foreach (PreviewSample sample in candidate.Samples)
                        {
                            MetricEnsemble vmaf = await _metrics.EvaluatePreviewAsync(
                                request with { MetricMode = MetricMode.VMAF },
                                media,
                                candidate.Plan,
                                sample.Path,
                                tempDirectory,
                                sample.Window,
                                cancellationToken).ConfigureAwait(false);
                            sample.Metrics = CombineMetricModes(vmaf, sample.Metrics);
                        }
                        candidate.RuntimeSeconds +=
                            (DateTimeOffset.UtcNow - fallbackStarted).TotalSeconds;
                    }
                    catch (Exception exception) when (
                        exception is Win32Exception or
                            IOException or
                            UnauthorizedAccessException or
                            InvalidOperationException or
                            NotSupportedException)
                    {
                        object failureLog = new
                        {
                            Plan = candidate.Plan,
                            Stage = "vmaf-fallback",
                            Error = exception.Message
                        };
                        await logger
                            .WriteAsync("preview-failed", failureLog, cancellationToken)
                            .ConfigureAwait(false);
                        foreach (PreviewSample sample in candidate.Samples)
                            FileSystemCleanup.DeleteFile(sample.Path, _runner.ReportWarning);
                        work.RemoveAt(candidateIndex);
                    }
                }
            }

            IReadOnlyList<PlanPreview> previews = CreatePreviews(work);
            if (request.MetricMode == MetricMode.Auto)
            {
                await logger
                    .WriteAsync("adaptive-metric-decision", decision, cancellationToken)
                    .ConfigureAwait(false);
            }

            foreach (PlanPreview preview in previews)
            {
                object previewLog = new
                {
                    Plan = preview.Plan,
                    preview.Metrics,
                    Bytes = preview.OutputBytes,
                    preview.RuntimeSeconds
                };
                await logger
                    .WriteAsync("preview-complete", previewLog, cancellationToken)
                    .ConfigureAwait(false);
            }

            return new PreviewEvaluation(previews, finalMetricMode, decision);
        }
        finally
        {
            foreach (PreviewSample sample in work.SelectMany(candidate => candidate.Samples))
                FileSystemCleanup.DeleteFile(sample.Path, _runner.ReportWarning);
        }
    }

    private static IReadOnlyList<PlanPreview> CreatePreviews(IReadOnlyList<PreviewWork> work)
    {
        return work
            .Select(candidate => new PlanPreview(
                candidate.Plan,
                MergeMetrics(candidate.Samples.Select(sample => sample.Metrics).ToArray()),
                candidate.Samples.LastOrDefault()?.Path ?? "",
                candidate.Bytes,
                candidate.RuntimeSeconds))
            .ToArray();
    }

    private static AdaptiveMetricDecision ResolveAdaptiveMetricDecision(
        CompressionRequest request,
        bool hasVmaf,
        bool hasXpsnr,
        IReadOnlyList<PlanPreview> previews)
    {
        if (request.MetricMode != MetricMode.Auto)
            return AdaptiveMetricDecision.Disabled("explicit-metric-mode");
        if (!hasXpsnr)
            return AdaptiveMetricDecision.Fallback("xpsnr-unavailable");
        if (!hasVmaf)
            return AdaptiveMetricDecision.Fast("vmaf-unavailable");

        PlanPreview[] ranked = previews
            .Where(preview => preview.Metrics.XPSNR.HasValue)
            .OrderByDescending(preview => preview.Metrics.XPSNR)
            .ThenByDescending(preview => preview.Metrics.WorstXPSNR)
            .ThenByDescending(preview => preview.Plan.AudioPlan.Rank)
            .ThenByDescending(preview => preview.Plan.HeuristicScore)
            .ToArray();
        if (ranked.Length == 0)
            return AdaptiveMetricDecision.Fallback("xpsnr-evaluation-failed");

        CompressionPlan winner = ranked[0].Plan;
        double? margin = ranked.Length >= 2
            ? ranked[0].Metrics.XPSNR!.Value - ranked[1].Metrics.XPSNR!.Value
            : null;
        bool sameGeometryAndPreprocess = ranked.Length < 2 ||
            SameGeometryAndPreprocess(winner, ranked[1].Plan);
        double? luminance = winner.ContentAnalysis?.Features.LuminanceMean;
        string contentClass = winner.ContentClass;
        bool flatColor = HasTrait(winner.ContentAnalysis, "flat_color");
        bool dark = HasTrait(winner.ContentAnalysis, "dark");

        AdaptiveMetricDecision Decision(bool fallback, string reason)
        {
            return new AdaptiveMetricDecision(
                Enabled: true,
                UseVmafFallback: fallback,
                Reason: reason,
                ContentClass: contentClass,
                LuminanceMean: luminance,
                XpsnrMargin: margin,
                SameGeometryAndPreprocess: sameGeometryAndPreprocess);
        }

        if (flatColor || winner.Preprocess == "deband")
            return Decision(true, "cambi-sensitive-content");

        bool naturalContent = contentClass is not ("screen" or "gameplay" or "anime");
        if (naturalContent &&
            (dark ||
             luminance.HasValue &&
             luminance.Value <= ContentAnalyzer.DarkLuminanceThreshold))
            return Decision(true, "dark-natural-content");

        if (contentClass is "screen" or "gameplay")
        {
            bool confident = sameGeometryAndPreprocess ||
                margin is >= AdaptiveXpsnrConfidenceMargin;
            return Decision(!confident, confident
                ? "screen-or-gameplay-fast-path"
                : "low-confidence-geometry-change");
        }

        if (contentClass == "general")
        {
            if (!luminance.HasValue)
                return Decision(true, "luminance-unavailable");
            bool confident = margin is >= AdaptiveXpsnrConfidenceMargin;
            return Decision(!confident, confident
                ? "high-confidence-general-content"
                : "low-confidence-general-content");
        }

        return Decision(true, "conservative-content-class");
    }

    private static bool HasTrait(ContentAnalysis? analysis, string trait)
    {
        return analysis?.Traits.Contains(trait, StringComparer.Ordinal) == true;
    }

    private static bool SameGeometryAndPreprocess(CompressionPlan left, CompressionPlan right)
    {
        return left.Width == right.Width &&
            left.Height == right.Height &&
            Math.Abs(left.Fps - right.Fps) < 0.001 &&
            left.Preprocess == right.Preprocess;
    }

    private static MetricEnsemble CombineMetricModes(MetricEnsemble vmaf, MetricEnsemble xpsnr)
    {
        int count = Math.Max(vmaf.Windows.Count, xpsnr.Windows.Count);
        List<MetricWindow> windows = [];
        for (int index = 0; index < count; index++)
        {
            MetricWindow? vmafWindow = index < vmaf.Windows.Count ? vmaf.Windows[index] : null;
            MetricWindow? xpsnrWindow = index < xpsnr.Windows.Count ? xpsnr.Windows[index] : null;
            MetricWindow basis = vmafWindow ?? xpsnrWindow!;
            windows.Add(new MetricWindow(
                index,
                basis.StartSeconds,
                basis.EndSeconds,
                vmafWindow?.VMAFNeg,
                xpsnrWindow?.XPSNR,
                vmafWindow?.CAMBI));
        }

        double? primary = vmaf.VMAFNeg ?? xpsnr.XPSNR;
        string? error = primary.HasValue
            ? null
            : vmaf.Error ?? xpsnr.Error;
        return new MetricEnsemble
        {
            Available = primary.HasValue,
            Mode = "ensemble",
            PrimaryScore = primary,
            WorstWindowScore = vmaf.WorstVMAFNeg ?? xpsnr.WorstXPSNR,
            VMAFNeg = vmaf.VMAFNeg,
            WorstVMAFNeg = vmaf.WorstVMAFNeg,
            StandardVMAF = vmaf.StandardVMAF,
            XPSNR = xpsnr.XPSNR,
            WorstXPSNR = xpsnr.WorstXPSNR,
            CAMBI = vmaf.CAMBI,
            WorstCAMBI = vmaf.WorstCAMBI,
            Windows = windows,
            Error = error
        };
    }

    private static CompressionPlan SelectPlan(IReadOnlyList<CompressionPlan> candidates, IReadOnlyList<PlanPreview> previews)
    {
        PlanPreview[] available = previews.Where(preview => preview.Metrics.Available).ToArray();
        if (available.Length == 0)
            return candidates.OrderByDescending(plan => plan.HeuristicScore).First();
        double bestPrimary = available.Max(preview => preview.Metrics.PrimaryScore ?? double.MinValue);
        PlanPreview[] materialContenders = available
            .Where(preview =>
                (preview.Metrics.PrimaryScore ?? double.MinValue) >= bestPrimary - 0.25)
            .ToArray();
        double? bestXPSNR = materialContenders
            .Where(preview => preview.Metrics.XPSNR.HasValue)
            .Select(preview => preview.Metrics.XPSNR)
            .Max();
        if (bestXPSNR.HasValue)
        {
            materialContenders = materialContenders
                .Where(preview =>
                    preview.Metrics.XPSNR.HasValue &&
                    preview.Metrics.XPSNR.Value >= bestXPSNR.Value - 0.5)
                .ToArray();
        }

        return materialContenders
            .OrderByDescending(preview => preview.Metrics.PrimaryScore)
            .ThenByDescending(preview => preview.Metrics.WorstWindowScore)
            .ThenByDescending(preview => preview.Plan.AudioPlan.Rank)
            .ThenByDescending(preview => preview.Plan.HeuristicScore)
            .First().Plan;
    }

    private static List<CompressionPlan> BuildEncodeOrder(
        CompressionPlan selected,
        IReadOnlyList<CompressionPlan> candidates,
        IReadOnlyList<PlanPreview> previews)
    {
        List<CompressionPlan> order = [selected];
        IEnumerable<CompressionPlan> previewOrder = previews
            .Where(preview => preview.Metrics.Available)
            .OrderByDescending(preview => preview.Metrics.PrimaryScore)
            .Select(preview => preview.Plan);
        foreach (CompressionPlan plan in previewOrder)
        {
            bool alreadyAdded = order.Any(existing =>
                existing.Identity == plan.Identity &&
                existing.AudioPlan.Identity == plan.AudioPlan.Identity);
            if (!alreadyAdded)
                order.Add(plan);
        }

        foreach (CompressionPlan plan in candidates
            .Where(plan => plan.Profile.Backend == selected.Profile.Backend)
            .OrderBy(plan => Math.Abs(plan.Width - selected.Width) + Math.Abs(plan.Fps - selected.Fps) * 20)
            .ThenByDescending(plan => plan.HeuristicScore))
        {
            bool alreadyAdded = order.Any(existing =>
                existing.Identity == plan.Identity &&
                existing.AudioPlan.Identity == plan.AudioPlan.Identity);
            if (!alreadyAdded)
                order.Add(plan);
        }

        return order;
    }

    private static MetricEnsemble MergeMetrics(IReadOnlyList<MetricEnsemble> metrics)
    {
        MetricEnsemble[] available = metrics.Where(metric => metric.Available).ToArray();
        if (available.Length == 0)
        {
            return new MetricEnsemble
            {
                Mode = metrics.FirstOrDefault()?.Mode ?? "off",
                Error = metrics
                    .Select(metric => metric.Error)
                    .LastOrDefault(error => !string.IsNullOrWhiteSpace(error))
            };
        }

        List<MetricWindow> windows = available
            .SelectMany(metric => metric.Windows)
            .Select((window, index) => window with { Index = index })
            .ToList();
        double? vmaf = Average(available.Select(metric => metric.VMAFNeg));
        double? xpsnr = Average(available.Select(metric => metric.XPSNR));

        double? worstWindowScore = Minimum(available.Select(metric => metric.WorstXPSNR));
        if (vmaf.HasValue)
            worstWindowScore = Minimum(available.Select(metric => metric.WorstVMAFNeg));

        return new MetricEnsemble
        {
            Available = true,
            Mode = available[0].Mode,
            PrimaryScore = vmaf ?? xpsnr,
            WorstWindowScore = worstWindowScore,
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

    private static CapabilityProbeResult CapabilityFor(
        CompressionPlan plan,
        IEnumerable<ViablePolicy> policies)
    {
        return policies
            .First(item => item.Policy.Profile.Backend == plan.Profile.Backend)
            .Capability;
    }

    private static bool BetterAttempt(
        EncodeAttempt attempt,
        EncodeAttempt? best,
        IReadOnlyDictionary<string, int> priority)
    {
        if (best is null)
            return true;

        int attemptPriority = priority[PlanKey(attempt.Plan)];
        int bestPriority = priority[PlanKey(best.Plan)];

        if (attemptPriority != bestPriority)
            return attemptPriority < bestPriority;

        return attempt.SizeBytes > best.SizeBytes;
    }

    private static string PlanKey(CompressionPlan plan)
    {
        return plan.Identity + "|" + plan.AudioPlan.Identity;
    }

    private static double? Average(IEnumerable<double?> values)
    {
        double[] available = values
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .ToArray();

        if (available.Length == 0)
            return null;

        return available.Average();
    }

    private static double? Minimum(IEnumerable<double?> values)
    {
        double[] available = values
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .ToArray();

        if (available.Length == 0)
            return null;

        return available.Min();
    }

    private static double? Maximum(IEnumerable<double?> values)
    {
        double[] available = values
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .ToArray();

        if (available.Length == 0)
            return null;

        return available.Max();
    }

    private static void Validate(CompressionRequest request)
    {
        if (!File.Exists(request.InputPath))
            throw new FileNotFoundException("Input file was not found.", request.InputPath);
        if (request.TargetBytes <= 0)
            throw new ArgumentOutOfRangeException(nameof(request.TargetBytes));
        if (request.WorkingTargetRatio is <= 0 or > 1)
            throw new ArgumentOutOfRangeException(nameof(request.WorkingTargetRatio));
        if (request.ProbeSampleSeconds <= 0)
            throw new ArgumentOutOfRangeException(nameof(request.ProbeSampleSeconds));
        _ = ContentClassSelection.Normalize(request.ContentClassMode);
    }

    private static string ResolveOutputPath(CompressionRequest request, EncoderProfile profile)
    {
        string? output = request.OutputPath;
        if (string.IsNullOrWhiteSpace(output))
        {
            string input = Path.GetFullPath(request.InputPath);
            string mode = request.Mode.ToString().ToLowerInvariant();
            double bytesPerMegabyte = request.TargetUnit == TargetUnit.BinaryMiB
                ? 1024.0 * 1024.0
                : 1_000_000.0;
            string targetMegabytes = (request.TargetBytes / bytesPerMegabyte)
                .ToString("0.##", CultureInfo.InvariantCulture);
            string fileName = $"{Path.GetFileNameWithoutExtension(input)}_" +
                $"{targetMegabytes}mb_{profile.Backend}_{mode}{profile.Extension}";
            output = Path.Combine(Path.GetDirectoryName(input)!, fileName);
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
        if (string.IsNullOrWhiteSpace(outputPath))
            return policies;
        string extension = Path.GetExtension(outputPath);
        ResolvedPolicy[] matching = policies
            .Where(policy => extension.Equals(
                policy.Profile.Extension,
                StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (matching.Length == 0)
            throw new ArgumentException($"No eligible codec policy produces output extension '{extension}'.");
        return matching;
    }

    private static void CopyExact(string source, string destination)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        if (!Path.GetFullPath(source).Equals(Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
            File.Copy(source, destination, overwrite: true);
    }

    private sealed record PreviewEvaluation(
        IReadOnlyList<PlanPreview> Previews,
        MetricMode FinalMetricMode,
        AdaptiveMetricDecision Decision);

    private sealed record AdaptiveMetricDecision(
        bool Enabled,
        bool UseVmafFallback,
        string Reason,
        string ContentClass,
        double? LuminanceMean,
        double? XpsnrMargin,
        bool? SameGeometryAndPreprocess)
    {
        public static AdaptiveMetricDecision Disabled(string reason) =>
            new(false, false, reason, "", null, null, null);

        public static AdaptiveMetricDecision Fast(string reason) =>
            new(true, false, reason, "", null, null, null);

        public static AdaptiveMetricDecision Fallback(string reason) =>
            new(true, true, reason, "", null, null, null);
    }

    private sealed class PreviewSample(
        SampleWindow window,
        string path,
        MetricEnsemble metrics)
    {
        public SampleWindow Window { get; } = window;
        public string Path { get; } = path;
        public MetricEnsemble Metrics { get; set; } = metrics;
    }

    private sealed class PreviewWork(
        CompressionPlan plan,
        IReadOnlyList<PreviewSample> samples,
        long bytes,
        double runtimeSeconds)
    {
        public CompressionPlan Plan { get; } = plan;
        public IReadOnlyList<PreviewSample> Samples { get; } = samples;
        public long Bytes { get; } = bytes;
        public double RuntimeSeconds { get; set; } = runtimeSeconds;
    }

    private sealed record ViablePolicy(
        ResolvedPolicy Policy,
        CapabilityProbeResult Capability);

    private sealed record AnalysisResults(
        CropAnalysis Crop,
        IReadOnlyList<SampleWindow> SampleWindows,
        ComplexityAnalysis Complexity,
        ContentAnalysis? Content);

    private sealed record CandidateSet(
        IReadOnlyList<CompressionPlan> Plans,
        IReadOnlyDictionary<string, AudioArtifact> AudioArtifacts);

    private sealed record EncodingResult(
        EncodeAttempt Best,
        IReadOnlyList<CorrectionPoint> Corrections);
}
