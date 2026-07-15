using System.Diagnostics;
using System.Text.Json;
using Byakuren.Analysis;
using Byakuren.CLI;
using Byakuren.Encoding;
using Byakuren.Execution;
using Byakuren.Metrics;
using Byakuren.Models;
using Byakuren.Planner;
using Byakuren.Policy;
using Byakuren.Probe;
using Byakuren.Results;
using Byakuren.Worker;

namespace Byakuren.Tests;

public static class Program
{
    private static int _passed;
    private static int _failed;

    public static async Task<int> Main(string[] arguments)
    {
        Run("codec policy resolves expected production profiles", TestPolicyCases);
        Run("automatic policies retain ordered functional fallbacks", TestAutomaticPolicyFallbacks);
        Run("canonical canvas normalizes source geometry", TestCanvasCases);
        Run("mode strategies enforce encode and fill limits", TestModeCases);
        Run("payload correction targets the working budget once", TestPayloadCorrection);
        Run("frozen direct evidence recognizes gameplay and screen content", TestContentClassifier);
        Run("process execution never invokes a shell", TestProcessStartInfo);
        Run("CLI accepts single-dash aliases", TestCLIAliases);
        Run("CLI preserves advanced planning controls", TestCLIAdvancedControls);
        Run("planner retains structural sentinels and reference isolation", TestPlannerCandidates);
        Run("planner balances temporal and spatial candidates", TestTemporalSpatialPlanning);
        Run("audio priorities change payload allocation", TestAudioPriorities);
        Run("result schema uses byakuren identity", () => Equal("byakuren.compress.result.v1", ResultContract.SchemaVersion, "schema"));

        if (arguments.Contains("--media", StringComparer.OrdinalIgnoreCase))
            await RunMediaTestsAsync().ConfigureAwait(false);

        Console.WriteLine($"Tests: {_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }

    private static void TestPolicyCases()
    {
        CompressionPolicy policy = new CompressionPolicy();
        PolicyCase[] cases =
        [
            new PolicyCase("widest-auto", "auto", "auto", "auto", "widest", false, "x264", "libx264", "mp4"),
            new PolicyCase("modern-auto", "auto", "auto", "auto", "modern", false, "av1", "svtav1", "webm"),
            new PolicyCase("pinned-x265", "x265", "auto", "auto", "widest", false, "x265", "libx265", "mp4"),
            new PolicyCase("explicit-aom", "auto", "aom", "auto", "modern", true, "av1", "aom", "webm"),
            new PolicyCase("explicit-vpx", "auto", "vpx", "auto", "modern", true, "vp9", "vpx", "webm")
        ];
        foreach (PolicyCase testCase in cases)
        {
            CompressionRequest request = new()
            {
                InputPath = "input.mp4",
                TargetBytes = 1_000_000,
                VideoCodec = testCase.VideoCodec,
                EncoderBackend = testCase.EncoderBackend,
                Container = testCase.Container,
                CompatibilityMode = testCase.Compatibility,
                EnableExperimentalEncoders = testCase.Experimental,
                Mode = CompressionMode.Fast
            };
            ResolvedPolicy resolved = policy.Resolve(request);
            Equal(testCase.ExpectedCodec, resolved.Profile.VideoCodec, testCase.Name + " codec");
            Equal(testCase.ExpectedBackend, resolved.Profile.Backend, testCase.Name + " backend");
            Equal(testCase.ExpectedContainer, resolved.Profile.Container, testCase.Name + " container");
        }
    }

    private static void TestCanvasCases()
    {
        CompressionPlanner planner = new CompressionPlanner();
        CanvasCase[] cases =
        [
            new CanvasCase("bounded-uhd", 3840, 2160, 120, 8, 1, 0, 1920, 1080, 60, "yuv420p"),
            new CanvasCase("no-upscale-ten-bit", 640, 360, 29.97, 10, 1, 0, 640, 360, 29.97, "yuv420p10le"),
            new CanvasCase("portrait-rotation", 1920, 1080, 60, 8, 1, 90, 1080, 1920, 60, "yuv420p"),
            new CanvasCase("anamorphic-SAR", 720, 480, 24, 8, 4.0 / 3.0, 0, 960, 480, 24, "yuv420p")
        ];
        foreach (CanvasCase testCase in cases)
        {
            MediaInfo media = new()
            {
                Path = "input",
                InputBytes = 1,
                DurationSeconds = 1,
                Width = testCase.Width,
                Height = testCase.Height,
                Fps = testCase.FPS,
                VideoCodec = "h264",
                PixelFormat = "yuv420p",
                BitDepth = testCase.BitDepth,
                FormatName = "mp4",
                SampleAspectRatio = testCase.SampleAspectRatio,
                Rotation = testCase.Rotation
            };
            CanonicalCanvas canvas = planner.GetCanonicalCanvas(media);
            Equal(testCase.ExpectedWidth, canvas.Width, testCase.Name + " width");
            Equal(testCase.ExpectedHeight, canvas.Height, testCase.Name + " height");
            Near(testCase.ExpectedFPS, canvas.Fps, 0.0001, testCase.Name + " fps");
            Equal(testCase.ExpectedPixelFormat, canvas.PixelFormat, testCase.Name + " format");
        }
    }

    private static void TestAutomaticPolicyFallbacks()
    {
        CompressionPolicy policy = new CompressionPolicy();
        CompressionRequest modern = new CompressionRequest
        {
            InputPath = "input.mp4",
            TargetBytes = 1_000_000,
            VideoCodec = "auto",
            EncoderBackend = "auto",
            Container = "auto",
            CompatibilityMode = "modern",
            Mode = CompressionMode.Fast
        };
        string[] modernBackends = policy.ResolveCandidates(modern).Select(candidate => candidate.Profile.Backend).ToArray();
        Equal("svtav1,libx264", string.Join(',', modernBackends), "modern fallback order");

        CompressionRequest experimental = modern with { EnableExperimentalEncoders = true };
        string[] experimentalBackends = policy.ResolveCandidates(experimental).Select(candidate => candidate.Profile.Backend).ToArray();
        Equal("svtav1,vpx,libx264", string.Join(',', experimentalBackends), "experimental fallback order");

        CompressionRequest mp4Only = modern with { Container = "mp4" };
        string[] mp4Backends = policy.ResolveCandidates(mp4Only).Select(candidate => candidate.Profile.Backend).ToArray();
        Equal("libx264", string.Join(',', mp4Backends), "explicit container filter");
    }

    private static void TestModeCases()
    {
        (CompressionMode Mode, int MaxFullEncodes, double FillGate)[] cases =
        [
            (CompressionMode.Fast, 2, 0.97),
            (CompressionMode.Balanced, 2, 0.99),
            (CompressionMode.ExtraQuality, 5, 0.995)
        ];
        foreach ((CompressionMode mode, int maxFullEncodes, double fillGate) in cases)
        {
            ModeStrategy strategy = CompressionPlanner.Strategy(mode);
            Equal(maxFullEncodes, strategy.MaxFullEncodes, mode + " encodes");
            Near(fillGate, strategy.FillGate, 1e-9, mode + " fill");
        }
        ModeStrategy balanced = CompressionPlanner.Strategy(CompressionMode.Balanced);
        Equal(3, balanced.ProbeMaxSamples, "Balanced probe samples");
        Equal(1, balanced.PreviewMaxSamples, "Balanced preview samples");
        Equal(2, balanced.PreviewTop, "Balanced preview plans");
    }

    private static void TestProcessStartInfo()
    {
        ProcessStartInfo startInfo = ProcessRunner.CreateStartInfo("ffmpeg", ["-i", "path with spaces.mp4", "-f", "null", "-"]);
        Equal(false, startInfo.UseShellExecute, "UseShellExecute");
        Equal(true, startInfo.RedirectStandardOutput, "stdout redirect");
        Equal("path with spaces.mp4", startInfo.ArgumentList[1], "argument boundary");
    }

    private static void TestContentClassifier()
    {
        MediaInfo gameplayMedia = TestMedia(60, hasAudio: false);
        ContentFeatures gameplayFeatures = new ContentFeatures
        {
            Available = true,
            UIPersistence = 0.52,
            EdgeDensity = 0.050,
            Entropy = 0.84,
            FlatAreaRatio = 0.864,
            TemporalDifference = 0.053,
            Noise = 0.006,
            SceneCut = 0.04,
            SourceCompression = 0.4
        };
        Equal("gameplay", ContentAnalyzer.Classify(gameplayMedia, gameplayFeatures), "gameplay class");

        MediaInfo screenMedia = TestMedia(30, hasAudio: false);
        ContentFeatures screenFeatures = new ContentFeatures
        {
            Available = true,
            UIPersistence = 0.62,
            EdgeDensity = 0.044,
            Entropy = 0.79,
            FlatAreaRatio = 0.898,
            TemporalDifference = 0.007,
            Noise = 0.025,
            SceneCut = 0.01,
            SourceCompression = 0.5
        };
        Equal("screen", ContentAnalyzer.Classify(screenMedia, screenFeatures), "screen class");
    }

    private static void TestPayloadCorrection()
    {
        EncoderProfile profile = CompressionPolicy.CreateProfile("x264", "libx264", "mp4");
        CompressionPlan plan = new CompressionPlan
        {
            Profile = profile,
            Mode = CompressionMode.Fast,
            HardCapBytes = 300_000,
            WorkingTargetBytes = 298_500,
            Width = 640,
            Height = 360,
            Fps = 60,
            VideoKbps = 703,
            AudioKbps = 80,
            Preset = "superfast",
            PixelFormat = "yuv420p",
            VideoFilter = "scale=640:360",
            CanonicalCanvas = new CanonicalCanvas(640, 360, 60, 8, "yuv420p")
        };
        EncodeAttempt attempt = new EncodeAttempt
        {
            Attempt = 1,
            Plan = plan,
            SizeBytes = 314_691,
            VideoPayloadBytes = 276_850,
            AudioPayloadBytes = 30_526,
            MuxOverheadBytes = 7_315,
            OutputPath = null
        };
        CorrectionPoint point = new CorrectionPoint(1, 703, 276_850, 30_526, 7_315, 314_691);

        int corrected = new CompressionPlanner().CorrectBitrate(plan, attempt, [point]);

        Equal(660, corrected, "corrected bitrate");
    }

    private static void TestCLIAliases()
    {
        CompressionRequest request = CLIOptions.Parse(["-InputFile", "input.mp4", "-TargetBytes", "123456", "-Mode", "Fast", "-ResultJsonPath", "result.json"]);
        Equal("input.mp4", request.InputPath, "input");
        Equal(123456L, request.TargetBytes, "bytes");
        Equal(CompressionMode.Fast, request.Mode, "mode");
        Equal("result.json", request.ResultJsonPath, "result path");
    }

    private static void TestCLIAdvancedControls()
    {
        CompressionRequest request = CLIOptions.Parse([
            "--input", "input.mp4", "--target-mb", "1.5", "--target-unit", "DecimalMB",
            "--sample-mode", "SceneAware", "--audio-priority", "Speech", "--preprocess-profile", "Mild",
            "--crop-mode", "Off", "--vbv-mode", "Streaming", "--output-bit-depth", "10",
            "--safety-margin-percent", "1.25", "--probe-sample-seconds", "7", "--metric-max-samples", "4",
            "--enable-plan-logging", "--verbose-commands"
        ]);
        Equal(1_500_000L, request.TargetBytes, "decimal target");
        Equal(TargetUnit.DecimalMB, request.TargetUnit, "target unit");
        Equal(SampleMode.SceneAware, request.SampleMode, "sample mode");
        Equal(AudioPriority.Speech, request.AudioPriority, "audio priority");
        Equal(PreprocessMode.Mild, request.PreprocessMode, "preprocess mode");
        Equal(CropMode.Off, request.CropMode, "crop mode");
        Equal(VBVMode.Streaming, request.VBVMode, "VBV mode");
        Equal("10", request.OutputBitDepth, "bit depth");
        Near(0.9875, request.WorkingTargetRatio, 1e-9, "working ratio");
        Equal(7, request.ProbeSampleSeconds, "probe seconds");
        Equal(4, request.MetricMaxSamples, "metric samples");
        Equal(true, request.EnablePlanLogging, "plan logging");
        Equal(true, request.VerboseCommands, "verbose commands");
        CompressionRequest legacyMargin = CLIOptions.Parse(["-InputFile", "input.mp4", "-TargetBytes", "1000", "-SafetyMarginPercent", "0.995"]);
        Near(0.995, legacyMargin.WorkingTargetRatio, 1e-9, "legacy safety ratio");
    }

    private static void TestPlannerCandidates()
    {
        CompressionPlanner planner = new CompressionPlanner();
        MediaInfo media = TestMedia(60, hasAudio: true) with
        {
            DurationSeconds = 30,
            AudioCodec = "aac",
            AudioBitrateKbps = 96,
            AudioChannels = 2,
            ColorPrimaries = "bt709",
            ColorTransfer = "bt709",
            ColorSpace = "bt709",
            ChromaLocation = "left"
        };
        CompressionRequest request = new CompressionRequest
        {
            InputPath = "input",
            TargetBytes = 2_000_000,
            Mode = CompressionMode.ExtraQuality,
            VideoCodec = "x265",
            OutputBitDepth = "10",
            VBVMode = VBVMode.Streaming
        };
        EncoderProfile profile = CompressionPolicy.CreateProfile("x265", "libx265", "mp4");
        IReadOnlyList<SampleWindow> windows = [new SampleWindow(2, 6, "fixed")];
        ComplexityAnalysis complexity = new ComplexityAnalysis { DetailBucket = "Low", MotionBucket = "Low", Windows = windows };
        CropAnalysis crop = new CropAnalysis { Applied = true, Width = 1920, Height = 800, X = 0, Y = 140, Filter = "crop=1920:800:0:140" };
        ContentAnalysis content = new ContentAnalysis("anime", new ContentFeatures { Available = true });
        AudioPlan audioPlan = new AudioPlan("encode", 96, "aac", "aac 96k", 100);
        AudioArtifact audio = new AudioArtifact(null, 360_000, audioPlan);

        IReadOnlyList<CompressionPlan> plans = planner.CreateCandidatePlans(request, media, profile, audio, content, complexity, crop, windows);

        Equal(true, plans.Any(plan => plan.WidthOrigin.Contains("source-sentinel", StringComparison.Ordinal)), "source width sentinel");
        Equal(true, plans.Any(plan => plan.WidthOrigin.Contains("lower-sentinel", StringComparison.Ordinal)), "lower width sentinel");
        Equal(true, plans.Any(plan => Math.Abs(plan.Fps - 60) < 0.01), "source FPS sentinel");
        Equal(true, plans.Any(plan => Math.Abs(plan.Fps - 30) < 0.01), "lower FPS sentinel");
        Equal(true, plans.All(plan => plan.PixelFormat == "yuv420p10le"), "10-bit plans");
        Equal(true, plans.All(plan => plan.MaxrateKbps.HasValue && plan.BufsizeKbits.HasValue), "streaming VBV");
        Equal(true, plans.All(plan => plan.ColorArguments.Contains("bt709")), "color metadata");
        Equal(true, plans.All(plan => !plan.MetricReferenceFilter.Contains("deband", StringComparison.Ordinal)), "reference preprocessing isolation");
    }

    private static void TestAudioPriorities()
    {
        CompressionPlanner planner = new CompressionPlanner();
        EncoderProfile profile = CompressionPolicy.CreateProfile("x264", "libx264", "mp4");
        MediaInfo media = TestMedia(30, hasAudio: true) with { DurationSeconds = 30, AudioCodec = "aac", AudioBitrateKbps = 256, AudioChannels = 2 };
        ComplexityAnalysis complexity = new ComplexityAnalysis { DetailBucket = "Medium" };
        CompressionRequest visual = new CompressionRequest { InputPath = "input", TargetBytes = 2_000_000, AudioPriority = AudioPriority.Visual };
        CompressionRequest speech = visual with { AudioPriority = AudioPriority.Speech };
        int visualKbps = planner.CreateAudioPlans(visual, media, profile, complexity, "general").First(plan => plan.Mode == "encode").Kbps;
        int speechKbps = planner.CreateAudioPlans(speech, media, profile, complexity, "general").First(plan => plan.Mode == "encode").Kbps;
        Equal(true, speechKbps > visualKbps, "speech audio allocation");
    }

    private static void TestTemporalSpatialPlanning()
    {
        CompressionPlanner planner = new CompressionPlanner();
        MediaInfo media = TestMedia(60, hasAudio: true) with
        {
            DurationSeconds = 40,
            AudioCodec = "aac",
            AudioBitrateKbps = 96,
            AudioChannels = 2
        };
        EncoderProfile profile = CompressionPolicy.CreateProfile("x264", "libx264", "mp4");
        ComplexityAnalysis complexity = new ComplexityAnalysis
        {
            DetailBucket = "High",
            MotionBucket = "VeryLow",
            Windows = [new SampleWindow(10, 4, "fixed")]
        };
        ContentAnalysis content = new ContentAnalysis("general", new ContentFeatures { Available = true });
        CropAnalysis crop = new CropAnalysis { Width = media.Width, Height = media.Height };
        AudioPlan audioPlan = new AudioPlan("copy", 96, "aac", "copy source audio", 101);
        AudioArtifact audio = new AudioArtifact(null, 480_000, audioPlan);

        CompressionRequest balancedRequest = new CompressionRequest
        {
            InputPath = "input",
            TargetBytes = 8 * 1024 * 1024,
            Mode = CompressionMode.Balanced,
            VideoCodec = "x264"
        };
        IReadOnlyList<CompressionPlan> balancedPlans = planner.CreateCandidatePlans(
            balancedRequest, media, profile, audio, content, complexity, crop, complexity.Windows);
        IReadOnlyList<CompressionPlan> shortlist = planner.CreatePreviewShortlist(balancedPlans, 2);

        Equal(30.0, balancedPlans[0].Fps, "Balanced primary FPS");
        Equal(2, shortlist.Count, "Balanced shortlist size");
        Equal(true, shortlist.Any(plan => Math.Abs(plan.Fps - 30) < 0.1), "Balanced 30 FPS finalist");
        CompressionPlan primary = shortlist[0];
        CompressionPlan challenger = shortlist[1];
        double areaRatio = challenger.Width * (double)challenger.Height / (primary.Width * (double)primary.Height);
        bool meaningfulAllocationChange = Math.Abs(challenger.Fps - primary.Fps) > 0.1 || areaRatio <= 0.80 || areaRatio >= 1.25;
        Equal(true, meaningfulAllocationChange, "Balanced allocation challenger");
        if (Math.Abs(challenger.Fps - primary.Fps) < 0.1 && areaRatio < 1)
            Equal(true, challenger.BitsPerPixelPerFrame > primary.BitsPerPixelPerFrame, "spatial safety density");
        Equal(true, shortlist.Select(plan => plan.Identity).Distinct().Count() == shortlist.Count, "structurally distinct previews");

        CompressionRequest fastRequest = balancedRequest with { Mode = CompressionMode.Fast };
        IReadOnlyList<CompressionPlan> fastPlans = planner.CreateCandidatePlans(
            fastRequest, media, profile, audio, content, complexity, crop, complexity.Windows);
        Equal(30.0, fastPlans[0].Fps, "Fast primary FPS");
    }

    private static async Task RunMediaTestsAsync()
    {
        string tempDirectory = Path.Combine(Path.GetTempPath(), $"byakuren-media-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDirectory);
        try
        {
            ProcessRunner runner = new ProcessRunner();
            string sourcePath = Path.Combine(tempDirectory, "source.mp4");
            await runner.RunCheckedAsync("ffmpeg",
            [
                "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=60:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
                "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", sourcePath
            ], CancellationToken.None).ConfigureAwait(false);

            await RunAsync("media under-cap passthrough is byte-exact", async () =>
            {
                string outputPath = Path.Combine(tempDirectory, "copy.mp4");
                CompressionRequest request = new CompressionRequest
                {
                    InputPath = sourcePath,
                    OutputPath = outputPath,
                    TargetBytes = new FileInfo(sourcePath).Length + 1024,
                    Mode = CompressionMode.Fast,
                    UnderCapBehavior = UnderCapBehavior.Auto,
                    MetricMode = MetricMode.Off
                };
                await new CompressionWorker().RunAsync(request, null, CancellationToken.None).ConfigureAwait(false);
                byte[] sourceBytes = await File.ReadAllBytesAsync(sourcePath).ConfigureAwait(false);
                byte[] outputBytes = await File.ReadAllBytesAsync(outputPath).ConfigureAwait(false);
                Equal(true, sourceBytes.AsSpan().SequenceEqual(outputBytes), "copy bytes");
            }).ConfigureAwait(false);

            await RunAsync("media default output names include mode", async () =>
            {
                CompressionRequest request = new CompressionRequest
                {
                    InputPath = sourcePath,
                    TargetBytes = new FileInfo(sourcePath).Length + 2048,
                    Mode = CompressionMode.Fast,
                    UnderCapBehavior = UnderCapBehavior.Auto,
                    MetricMode = MetricMode.Off
                };
                CompressionOutcome outcome = await new CompressionWorker().RunAsync(request, null, CancellationToken.None).ConfigureAwait(false);
                Equal(true, Path.GetFileNameWithoutExtension(outcome.OutputPath).EndsWith("_libx264_fast", StringComparison.Ordinal), "mode suffix");
            }).ConfigureAwait(false);

            await RunAsync("media previews honor planned bitrate", async () =>
            {
                EncoderProfile profile = CompressionPolicy.CreateProfile("x264", "libx264", "mp4");
                CompressionPlan plan = new CompressionPlan
                {
                    Profile = profile,
                    Mode = CompressionMode.Balanced,
                    HardCapBytes = 300_000,
                    WorkingTargetBytes = 297_000,
                    Width = 640,
                    Height = 360,
                    Fps = 60,
                    VideoKbps = 500,
                    AudioKbps = 0,
                    AudioPlan = AudioPlan.Mute,
                    Preset = "medium",
                    PixelFormat = "yuv420p",
                    VideoFilter = "setsar=1,scale=640:360:flags=lanczos,fps=60:round=near",
                    CanonicalCanvas = new CanonicalCanvas(640, 360, 60, 8, "yuv420p")
                };
                FFmpegProbe probe = new FFmpegProbe(runner);
                MediaInfo sourceMedia = await probe.ProbeMediaAsync(new CompressionRequest { InputPath = sourcePath, TargetBytes = 300_000 }, CancellationToken.None).ConfigureAwait(false);
                FFmpegEncoder encoder = new FFmpegEncoder(runner, probe);
                string preview = await encoder.EncodePreviewAsync(
                    new CompressionRequest { InputPath = sourcePath, TargetBytes = 300_000 },
                    sourceMedia,
                    plan,
                    new SampleWindow(0, 3, "fixed"),
                    tempDirectory,
                    "none",
                    CancellationToken.None).ConfigureAwait(false);
                long payload = await probe.GetPacketPayloadBytesAsync("ffprobe", preview, "v:0", CancellationToken.None).ConfigureAwait(false);
                double actualKbps = payload * 8.0 / 3.0 / 1000.0;
                Equal(true, actualKbps is >= 450 and <= 550, $"preview bitrate {actualKbps:0.0} kbps");
                File.Delete(preview);
            }).ConfigureAwait(false);

            await RunAsync("media preview metrics compare on candidate timeline", async () =>
            {
                if (!await new FFmpegProbe(runner).HasFilterAsync("ffmpeg", "libvmaf", CancellationToken.None).ConfigureAwait(false)) return;
                string lowFpsPath = Path.Combine(tempDirectory, "selection-timeline.mkv");
                await runner.RunCheckedAsync("ffmpeg",
                [
                    "-y", "-i", sourcePath, "-vf", "fps=30", "-an", "-c:v", "ffv1", lowFpsPath
                ], CancellationToken.None).ConfigureAwait(false);
                FFmpegProbe probe = new FFmpegProbe(runner);
                CompressionRequest metricRequest = new CompressionRequest
                {
                    InputPath = sourcePath,
                    TargetBytes = 300_000,
                    Mode = CompressionMode.Balanced,
                    MetricMode = MetricMode.VMAF
                };
                MediaInfo sourceMedia = await probe.ProbeMediaAsync(metricRequest, CancellationToken.None).ConfigureAwait(false);
                CompressionPlan plan = new CompressionPlan
                {
                    Profile = CompressionPolicy.CreateProfile("x264", "libx264", "mp4"),
                    Mode = CompressionMode.Balanced,
                    HardCapBytes = 300_000,
                    WorkingTargetBytes = 297_000,
                    Width = 640,
                    Height = 360,
                    Fps = 30,
                    VideoKbps = 500,
                    AudioKbps = 0,
                    Preset = "medium",
                    PixelFormat = "yuv420p",
                    VideoFilter = "fps=30",
                    CanonicalCanvas = new CanonicalCanvas(640, 360, 60, 8, "yuv420p"),
                    CropAnalysis = new CropAnalysis { Width = 640, Height = 360 }
                };
                MetricEnsemble result = await new MetricEvaluator(runner, probe).EvaluatePreviewAsync(
                    metricRequest, sourceMedia, plan, lowFpsPath, tempDirectory, new SampleWindow(0, 2, "fixed"), CancellationToken.None).ConfigureAwait(false);
                Equal(true, result.VMAFNeg is > 90, $"selection VMAF {result.VMAFNeg:0.0}");
            }).ConfigureAwait(false);

            foreach ((string codec, string extension) in new[] { ("x264", ".mp4"), ("x265", ".mp4"), ("av1", ".webm") })
            {
                await RunAsync($"media Fast {codec} respects cap, fill, and decode", async () =>
                {
                    const long hardCapBytes = 300_000;
                    string outputPath = Path.Combine(tempDirectory, codec + extension);
                    string resultPath = Path.Combine(tempDirectory, codec + ".json");
                    CompressionRequest request = new CompressionRequest
                    {
                        InputPath = sourcePath,
                        OutputPath = outputPath,
                        ResultJsonPath = resultPath,
                        TargetBytes = hardCapBytes,
                        Mode = CompressionMode.Fast,
                        VideoCodec = codec,
                        Container = "auto",
                        UnderCapBehavior = UnderCapBehavior.Transcode,
                        ContentClassMode = "off",
                        MetricMode = MetricMode.Off
                    };
                    await new CompressionWorker().RunAsync(request, null, CancellationToken.None).ConfigureAwait(false);
                    long outputBytes = new FileInfo(outputPath).Length;
                    Equal(true, outputBytes <= hardCapBytes, codec + " hard cap");
                    Equal(true, outputBytes / (double)hardCapBytes >= CompressionPlanner.Strategy(CompressionMode.Fast).FillGate, codec + " fill gate");
                    await runner.RunCheckedAsync("ffmpeg", ["-v", "error", "-i", outputPath, "-f", "null", "-"], CancellationToken.None).ConfigureAwait(false);
                    using JsonDocument result = JsonDocument.Parse(await File.ReadAllTextAsync(resultPath).ConfigureAwait(false));
                    Equal(extension.TrimStart('.'), result.RootElement.GetProperty("Policy").GetProperty("Container").GetString(), codec + " container");
                }).ConfigureAwait(false);
            }

            await RunAsync("media Balanced emits canonical metric windows when available", async () =>
            {
                string outputPath = Path.Combine(tempDirectory, "balanced.mp4");
                string resultPath = Path.Combine(tempDirectory, "balanced.json");
                CompressionRequest request = new CompressionRequest
                {
                    InputPath = sourcePath,
                    OutputPath = outputPath,
                    ResultJsonPath = resultPath,
                    TargetBytes = 300_000,
                    Mode = CompressionMode.Balanced,
                    UnderCapBehavior = UnderCapBehavior.Transcode,
                    ContentClassMode = "off",
                    MetricMode = MetricMode.Auto
                };
                await new CompressionWorker().RunAsync(request, null, CancellationToken.None).ConfigureAwait(false);
                using JsonDocument result = JsonDocument.Parse(await File.ReadAllTextAsync(resultPath).ConfigureAwait(false));
                JsonElement metrics = result.RootElement.GetProperty("Metrics");
                if (metrics.GetProperty("Available").GetBoolean())
                {
                    Equal(true, metrics.GetProperty("WorstWindowScore").ValueKind == JsonValueKind.Number, "worst metric");
                    Equal(true, metrics.GetProperty("Windows").GetArrayLength() > 0, "metric windows");
                }
            }).ConfigureAwait(false);

            await RunAsync("media under-cap explicit conversion still transcodes", async () =>
            {
                string outputPath = Path.Combine(tempDirectory, "under-cap-conversion.mp4");
                string resultPath = Path.Combine(tempDirectory, "under-cap-conversion.json");
                CompressionRequest request = new CompressionRequest
                {
                    InputPath = sourcePath,
                    OutputPath = outputPath,
                    ResultJsonPath = resultPath,
                    TargetBytes = new FileInfo(sourcePath).Length + 100_000,
                    Mode = CompressionMode.Fast,
                    VideoCodec = "x265",
                    UnderCapBehavior = UnderCapBehavior.Auto,
                    ContentClassMode = "off",
                    CropMode = CropMode.Off,
                    MetricMode = MetricMode.Off
                };
                await new CompressionWorker().RunAsync(request, null, CancellationToken.None).ConfigureAwait(false);
                using JsonDocument result = JsonDocument.Parse(await File.ReadAllTextAsync(resultPath).ConfigureAwait(false));
                Equal("encode", result.RootElement.GetProperty("Action").GetString(), "conversion action");
                Equal("libx265", result.RootElement.GetProperty("Policy").GetProperty("EncoderBackend").GetString(), "conversion backend");
                Equal(true, new FileInfo(outputPath).Length <= request.TargetBytes, "conversion cap");
            }).ConfigureAwait(false);

            await RunAsync("media crop detection removes only stable blank borders", async () =>
            {
                string cropSource = Path.Combine(tempDirectory, "crop-source.mp4");
                await runner.RunCheckedAsync("ffmpeg",
                [
                    "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=3",
                    "-vf", "pad=320:240:0:30:black", "-c:v", "libx264", "-preset", "ultrafast", cropSource
                ], CancellationToken.None).ConfigureAwait(false);
                CompressionRequest cropRequest = new CompressionRequest { InputPath = cropSource, TargetBytes = 300_000, CropMode = CropMode.Auto };
                FFmpegProbe probe = new FFmpegProbe(runner);
                MediaInfo cropMedia = await probe.ProbeMediaAsync(cropRequest, CancellationToken.None).ConfigureAwait(false);
                CropAnalysis crop = await new CropAnalyzer(runner).AnalyzeAsync(cropRequest, cropMedia, CancellationToken.None).ConfigureAwait(false);
                Equal(true, crop.Applied, "crop applied");
                Equal(320, crop.Width, "crop width");
                Equal(true, crop.Height is >= 178 and <= 182, "crop height");
                Equal(true, crop.Y is >= 28 and <= 32, "crop Y");
            }).ConfigureAwait(false);

            await RunAsync("media 10-bit SDR remains 10-bit when requested", async () =>
            {
                string tenBitSource = Path.Combine(tempDirectory, "ten-bit-source.mp4");
                string tenBitOutput = Path.Combine(tempDirectory, "ten-bit-output.mp4");
                await runner.RunCheckedAsync("ffmpeg",
                [
                    "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=2",
                    "-vf", "format=yuv420p10le", "-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1", tenBitSource
                ], CancellationToken.None).ConfigureAwait(false);
                CompressionRequest request = new CompressionRequest
                {
                    InputPath = tenBitSource,
                    OutputPath = tenBitOutput,
                    TargetBytes = 220_000,
                    Mode = CompressionMode.Fast,
                    VideoCodec = "x265",
                    OutputBitDepth = "10",
                    UnderCapBehavior = UnderCapBehavior.Transcode,
                    ContentClassMode = "off",
                    CropMode = CropMode.Off,
                    MetricMode = MetricMode.Off
                };
                await new CompressionWorker().RunAsync(request, null, CancellationToken.None).ConfigureAwait(false);
                MediaInfo outputMedia = await new FFmpegProbe(runner).ProbeMediaAsync(request with { InputPath = tenBitOutput }, CancellationToken.None).ConfigureAwait(false);
                Equal(10, outputMedia.BitDepth, "output bit depth");
                Equal(false, outputMedia.IsHdr, "SDR classification");
            }).ConfigureAwait(false);

            await RunAsync("media HDR metadata is rejected before planning", async () =>
            {
                string hdrSource = Path.Combine(tempDirectory, "hdr-source.mp4");
                await runner.RunCheckedAsync("ffmpeg",
                [
                    "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=1",
                    "-vf", "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc", "-c:v", "libx265", "-preset", "ultrafast", hdrSource
                ], CancellationToken.None).ConfigureAwait(false);
                CompressionRequest hdrRequest = new CompressionRequest { InputPath = hdrSource, TargetBytes = 150_000, Mode = CompressionMode.Fast };
                MediaInfo hdrMedia = await new FFmpegProbe(runner).ProbeMediaAsync(hdrRequest, CancellationToken.None).ConfigureAwait(false);
                Equal(true, hdrMedia.IsHdr, "PQ probe classification");
                bool rejected = false;
                try { await new CompressionWorker().RunAsync(hdrRequest, null, CancellationToken.None).ConfigureAwait(false); }
                catch (NotSupportedException) { rejected = true; }
                Equal(true, rejected, "HDR rejected");
            }).ConfigureAwait(false);

            await RunAsync("canonical metrics expose frame-rate and resolution loss", async () =>
            {
                string highPath = Path.Combine(tempDirectory, "metric-high.mp4");
                string lowPath = Path.Combine(tempDirectory, "metric-low.mp4");
                await runner.RunCheckedAsync("ffmpeg", ["-y", "-i", sourcePath, "-an", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18", highPath], CancellationToken.None).ConfigureAwait(false);
                await runner.RunCheckedAsync("ffmpeg", ["-y", "-i", sourcePath, "-vf", "scale=320:180,fps=30", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18", lowPath], CancellationToken.None).ConfigureAwait(false);
                MediaInfo sourceMedia = await new FFmpegProbe(runner).ProbeMediaAsync(new CompressionRequest { InputPath = sourcePath, TargetBytes = 1 }, CancellationToken.None).ConfigureAwait(false);
                CanonicalCanvas canvas = new CompressionPlanner().GetCanonicalCanvas(sourceMedia);
                CompressionPlan metricPlan = new CompressionPlan
                {
                    Profile = CompressionPolicy.CreateProfile("x264", "libx264", "mp4"),
                    Mode = CompressionMode.Balanced,
                    HardCapBytes = 1_000_000,
                    WorkingTargetBytes = 995_000,
                    Width = 640,
                    Height = 360,
                    Fps = 60,
                    VideoKbps = 1_000,
                    AudioKbps = 0,
                    Preset = "medium",
                    PixelFormat = "yuv420p",
                    VideoFilter = "scale=640:360,fps=60",
                    CanonicalCanvas = canvas,
                    MetricReferenceFilter = MetricEvaluator.ReferenceFilter(canvas),
                    SampleWindows = [new SampleWindow(0, 3, "fixed")]
                };
                MetricEvaluator evaluator = new MetricEvaluator(runner, new FFmpegProbe(runner));
                CompressionRequest metricRequest = new CompressionRequest { InputPath = sourcePath, TargetBytes = 1_000_000, Mode = CompressionMode.Balanced, MetricMode = MetricMode.Ensemble, MetricSampleSeconds = 3, MetricMaxSamples = 1 };
                MetricEnsemble high = await evaluator.EvaluateAsync(metricRequest, sourceMedia, metricPlan, highPath, tempDirectory, CancellationToken.None).ConfigureAwait(false);
                MetricEnsemble low = await evaluator.EvaluateAsync(metricRequest, sourceMedia, metricPlan, lowPath, tempDirectory, CancellationToken.None).ConfigureAwait(false);
                Equal(true, high.Available && low.Available, "metrics available");
                Equal(true, high.PrimaryScore > low.PrimaryScore, "canonical loss ordering");
                Equal(canvas.Width, metricPlan.CanonicalCanvas.Width, "common canvas width");
                Equal(canvas.Fps, metricPlan.CanonicalCanvas.Fps, "common canvas FPS");

                CompressionPlan invalidMetricPlan = metricPlan with { MetricReferenceFilter = "definitely_not_a_filter" };
                MetricEnsemble unavailable = await evaluator.EvaluateAsync(metricRequest with { MetricMode = MetricMode.VMAF }, sourceMedia, invalidMetricPlan, highPath, tempDirectory, CancellationToken.None).ConfigureAwait(false);
                Equal(false, unavailable.Available, "failed metric unavailable");
                Equal(null, unavailable.PrimaryScore, "failed metric is not zero");
            }).ConfigureAwait(false);
        }
        finally
        {
            try { Directory.Delete(tempDirectory, recursive: true); } catch { }
        }
    }

    private static async Task RunAsync(string name, Func<Task> test)
    {
        try { await test().ConfigureAwait(false); _passed++; Console.WriteLine($"PASS {name}"); }
        catch (Exception exception) { _failed++; Console.WriteLine($"FAIL {name} - {exception.Message}"); }
    }

    private static MediaInfo TestMedia(double fps, bool hasAudio) => new MediaInfo
    {
        Path = "input",
        InputBytes = 1,
        DurationSeconds = 1,
        Width = 1920,
        Height = 1080,
        Fps = fps,
        VideoCodec = "h264",
        PixelFormat = "yuv420p",
        BitDepth = 8,
        FormatName = "mp4",
        HasAudio = hasAudio
    };

    private static void Run(string name, Action test)
    {
        try { test(); _passed++; Console.WriteLine($"PASS {name}"); }
        catch (Exception exception) { _failed++; Console.WriteLine($"FAIL {name} - {exception.Message}"); }
    }

    private static void Equal<T>(T expected, T actual, string name) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{name}: expected '{expected}', actual '{actual}'"); }
    private static void Near(double expected, double actual, double tolerance, string name) { if (Math.Abs(expected - actual) > tolerance) throw new InvalidOperationException($"{name}: expected '{expected}', actual '{actual}'"); }

    private sealed record PolicyCase(
        string Name,
        string VideoCodec,
        string EncoderBackend,
        string Container,
        string Compatibility,
        bool Experimental,
        string ExpectedCodec,
        string ExpectedBackend,
        string ExpectedContainer);

    private sealed record CanvasCase(
        string Name,
        int Width,
        int Height,
        double FPS,
        int BitDepth,
        double SampleAspectRatio,
        int Rotation,
        int ExpectedWidth,
        int ExpectedHeight,
        double ExpectedFPS,
        string ExpectedPixelFormat);
}
