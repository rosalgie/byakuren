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
    private readonly CompressionPolicy _policy;
    private readonly CompressionPlanner _planner;
    private readonly FFmpegProbe _probe;
    private readonly CapabilityProbe _capabilityProbe;
    private readonly FFmpegEncoder _encoder;
    private readonly MetricEvaluator _metrics;
    private readonly ContentAnalyzer _contentAnalyzer;
    private readonly ResultContract _results;

    public CompressionWorker()
    {
        ProcessRunner runner = new ProcessRunner();
        _policy = new CompressionPolicy();
        _planner = new CompressionPlanner();
        _probe = new FFmpegProbe(runner);
        _capabilityProbe = new CapabilityProbe(runner, _probe);
        _encoder = new FFmpegEncoder(runner, _probe);
        _metrics = new MetricEvaluator(runner, _probe);
        _contentAnalyzer = new ContentAnalyzer(runner);
        _results = new ResultContract();
    }

    public async Task<CompressionOutcome> RunAsync(
        CompressionRequest request,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        DateTimeOffset started = DateTimeOffset.UtcNow;
        Validate(request);
        MediaInfo media = await _probe.ProbeMediaAsync(request, cancellationToken).ConfigureAwait(false);
        if (media.IsHdr) throw new NotSupportedException("HDR input is rejected until an explicit color-management policy is selected.");
        IReadOnlyList<ResolvedPolicy> policyCandidates = FilterByOutputExtension(_policy.ResolveCandidates(request), request.OutputPath);
        ResolvedPolicy? copyPolicy = media.InputBytes <= request.TargetBytes
            ? policyCandidates.FirstOrDefault(candidate => InputMatches(media, candidate.Profile))
            : null;
        bool canCopy = copyPolicy is not null;
        if (request.UnderCapBehavior == UnderCapBehavior.Copy && !canCopy)
            throw new InvalidOperationException("Copy behavior requires an under-cap input matching the requested codec, audio, and container policy.");

        if (canCopy && request.UnderCapBehavior != UnderCapBehavior.Transcode)
        {
            ResolvedPolicy copySelectedPolicy = copyPolicy!;
            string copyOutputPath = ResolveOutputPath(request, copySelectedPolicy.Profile);
            progress?.Report("Input is under cap and matches policy; copying without transcoding.");
            CopyExact(media.Path, copyOutputPath);
            object result = await _results.BuildAsync(started, "copy", request, media, copySelectedPolicy, null, null, null, [], new MetricEnsemble(), copyOutputPath, cancellationToken).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(request.ResultJsonPath))
                await _results.WriteAsync(result, request.ResultJsonPath, cancellationToken).ConfigureAwait(false);
            return new CompressionOutcome(copyOutputPath, result);
        }

        ResolvedPolicy? selectedPolicy = null;
        CapabilityProbeResult? selectedCapability = null;
        List<string> capabilityErrors = new List<string>();
        foreach (ResolvedPolicy candidate in policyCandidates)
        {
            CapabilityProbeResult candidateCapability = await _capabilityProbe.ProbeAsync(request, candidate.Profile, cancellationToken).ConfigureAwait(false);
            if (candidateCapability.Success)
            {
                selectedPolicy = candidate;
                selectedCapability = candidateCapability;
                break;
            }
            capabilityErrors.Add($"{candidate.Profile.Backend}: {candidateCapability.Error}");
        }
        if (selectedPolicy is null || selectedCapability is null)
            throw new InvalidOperationException("No eligible encoder backend passed its functional probe: " + string.Join(" | ", capabilityErrors));
        ResolvedPolicy policy = selectedPolicy;
        CapabilityProbeResult capability = selectedCapability;
        string outputPath = ResolveOutputPath(request, policy.Profile);

        string tempDirectory = Path.Combine(Path.GetTempPath(), $"byakuren-job-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDirectory);
        try
        {
            int audioKbps = media.HasAudio ? request.Mode == CompressionMode.Fast ? 80 : 96 : 0;
            ContentAnalysis? contentAnalysis = request.ContentClassMode.Equals("off", StringComparison.OrdinalIgnoreCase)
                ? null
                : await _contentAnalyzer.AnalyzeAsync(request, media, cancellationToken).ConfigureAwait(false);
            if (contentAnalysis is not null)
                progress?.Report($"Content classification: {contentAnalysis.ContentClass} ({ContentFeatures.ClassifierVersion})");
            AudioArtifact audio = await _encoder.EncodeAudioAsync(request, media, policy.Profile, tempDirectory, audioKbps, cancellationToken).ConfigureAwait(false);
            CompressionPlan plan = _planner.CreateInitialPlan(request, media, policy.Profile, audio.PayloadBytes, contentAnalysis);
            ModeStrategy strategy = CompressionPlanner.Strategy(request.Mode);
            List<CorrectionPoint> corrections = new List<CorrectionPoint>();
            EncodeAttempt? best = null;

            for (int attemptNumber = 1; attemptNumber <= strategy.MaxFullEncodes; attemptNumber++)
            {
                progress?.Report($"Encode {attemptNumber}/{strategy.MaxFullEncodes}: {plan.Width}x{plan.Height}@{plan.Fps:0.###}, {plan.VideoKbps} kbps, {plan.Profile.Backend}");
                EncodeAttempt attempt = await _encoder.EncodeAttemptAsync(request, media, plan, audio, tempDirectory, attemptNumber, capability.Device, cancellationToken).ConfigureAwait(false);
                corrections.Add(new CorrectionPoint(attemptNumber, plan.VideoKbps, attempt.VideoPayloadBytes, attempt.AudioPayloadBytes, attempt.MuxOverheadBytes, attempt.SizeBytes));
                if (attempt.UnderCap && (best is null || attempt.SizeBytes > best.SizeBytes))
                {
                    if (best?.OutputPath is not null) TryDelete(best.OutputPath);
                    best = attempt;
                }
                else if (attempt.OutputPath is not null && !ReferenceEquals(best, attempt)) TryDelete(attempt.OutputPath);

                if (best is not null && best.FillRatio >= strategy.FillGate) break;
                if (attemptNumber == strategy.MaxFullEncodes) break;
                int corrected = _planner.CorrectBitrate(plan, attempt, corrections);
                if (corrected == plan.VideoKbps) break;
                plan = plan with { VideoKbps = corrected };
            }

            if (best?.OutputPath is null) throw new InvalidOperationException("No encode attempt satisfied the hard byte cap.");
            CopyExact(best.OutputPath, outputPath);
            if (new FileInfo(outputPath).Length > request.TargetBytes)
            {
                TryDelete(outputPath);
                throw new InvalidOperationException("Final mux exceeded the requested hard byte cap.");
            }

            MetricEnsemble metricResult = await _metrics.EvaluateAsync(request, media, best.Plan, outputPath, tempDirectory, cancellationToken).ConfigureAwait(false);
            object result = await _results.BuildAsync(started, "encode", request, media, policy, capability, best.Plan, best, corrections, metricResult, outputPath, cancellationToken).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(request.ResultJsonPath))
                await _results.WriteAsync(result, request.ResultJsonPath, cancellationToken).ConfigureAwait(false);
            return new CompressionOutcome(outputPath, result);
        }
        finally
        {
            try { Directory.Delete(tempDirectory, recursive: true); } catch { }
        }
    }

    private static void Validate(CompressionRequest request)
    {
        if (!File.Exists(request.InputPath)) throw new FileNotFoundException("Input file was not found.", request.InputPath);
        if (request.TargetBytes <= 0) throw new ArgumentOutOfRangeException(nameof(request.TargetBytes));
        if (request.WorkingTargetRatio is <= 0 or > 1) throw new ArgumentOutOfRangeException(nameof(request.WorkingTargetRatio));
        if (!request.ContentClassMode.Equals("auto", StringComparison.OrdinalIgnoreCase) &&
            !request.ContentClassMode.Equals("off", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Content class mode must be 'auto' or 'off'.", nameof(request.ContentClassMode));
    }

    private static string ResolveOutputPath(CompressionRequest request, EncoderProfile profile)
    {
        string? output = request.OutputPath;
        if (string.IsNullOrWhiteSpace(output))
        {
            string input = Path.GetFullPath(request.InputPath);
            output = Path.Combine(Path.GetDirectoryName(input)!, $"{Path.GetFileNameWithoutExtension(input)}_{request.TargetBytes}_{profile.Backend}{profile.Extension}");
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
            "mp4" => media.FormatName.Split(',').Any(x => x is "mov" or "mp4"),
            "webm" => media.FormatName.Split(',').Any(x => x is "matroska" or "webm"),
            _ => false
        };
        bool audioMatches = !media.HasAudio || media.AudioCodec == profile.AudioCodec;
        return videoMatches && containerMatches && audioMatches;
    }

    private static IReadOnlyList<ResolvedPolicy> FilterByOutputExtension(
        IReadOnlyList<ResolvedPolicy> policies,
        string? outputPath)
    {
        if (string.IsNullOrWhiteSpace(outputPath)) return policies;
        string extension = Path.GetExtension(outputPath);
        ResolvedPolicy[] matching = policies
            .Where(policy => extension.Equals(policy.Profile.Extension, StringComparison.OrdinalIgnoreCase))
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

    private static void TryDelete(string path) { try { File.Delete(path); } catch { } }
}
