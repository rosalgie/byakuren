using System.Diagnostics;
using System.Text.Json;
using Byakuren.Analysis;
using Byakuren.CLI;
using Byakuren.Execution;
using Byakuren.Models;
using Byakuren.Planner;
using Byakuren.Policy;
using Byakuren.Worker;

namespace Byakuren.Tests;

public static class Program
{
    private static int _passed;
    private static int _failed;

    public static async Task<int> Main(string[] arguments)
    {
        string repositoryRoot = FindRepositoryRoot();
        string goldenPath = Path.Combine(repositoryRoot, "tests", "golden", "parity-v1.json");
        using JsonDocument golden = JsonDocument.Parse(File.ReadAllText(goldenPath));

        Run("golden policy parity", () => TestPolicyCases(golden.RootElement));
        Run("automatic policies retain ordered functional fallbacks", TestAutomaticPolicyFallbacks);
        Run("golden canonical canvas parity", () => TestCanvasCases(golden.RootElement));
        Run("golden mode strategy parity", () => TestModeCases(golden.RootElement));
        Run("payload correction targets the working budget once", TestPayloadCorrection);
        Run("frozen direct evidence recognizes gameplay and screen content", TestContentClassifier);
        Run("process execution never invokes a shell", TestProcessStartInfo);
        Run("CLI accepts PowerShell-compatible option names", TestCliAliases);
        Run("result schema uses byakuren identity", () => Equal("byakuren.compress.result.v1", golden.RootElement.GetProperty("schemaVersion").GetString(), "schema"));

        if (arguments.Contains("--media", StringComparer.OrdinalIgnoreCase))
            await RunMediaTestsAsync().ConfigureAwait(false);

        Console.WriteLine($"Tests: {_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }

    private static void TestPolicyCases(JsonElement root)
    {
        CompressionPolicy policy = new();
        foreach (JsonElement testCase in root.GetProperty("policyCases").EnumerateArray())
        {
            CompressionRequest request = new()
            {
                InputPath = "input.mp4",
                TargetBytes = 1_000_000,
                VideoCodec = Text(testCase, "videoCodec"),
                EncoderBackend = Text(testCase, "encoderBackend"),
                Container = Text(testCase, "container"),
                CompatibilityMode = Text(testCase, "compatibility"),
                EnableExperimentalEncoders = testCase.GetProperty("experimental").GetBoolean(),
                Mode = CompressionMode.Fast
            };
            ResolvedPolicy resolved = policy.Resolve(request);
            string name = Text(testCase, "name");
            Equal(Text(testCase, "expectedCodec"), resolved.Profile.VideoCodec, name + " codec");
            Equal(Text(testCase, "expectedBackend"), resolved.Profile.Backend, name + " backend");
            Equal(Text(testCase, "expectedContainer"), resolved.Profile.Container, name + " container");
        }
    }

    private static void TestCanvasCases(JsonElement root)
    {
        CompressionPlanner planner = new();
        foreach (JsonElement testCase in root.GetProperty("canvasCases").EnumerateArray())
        {
            MediaInfo media = new()
            {
                Path = "input",
                InputBytes = 1,
                DurationSeconds = 1,
                Width = Number(testCase, "width"),
                Height = Number(testCase, "height"),
                Fps = Decimal(testCase, "fps"),
                VideoCodec = "h264",
                PixelFormat = "yuv420p",
                BitDepth = Number(testCase, "bitDepth"),
                FormatName = "mp4",
                SampleAspectRatio = Decimal(testCase, "sar"),
                Rotation = Number(testCase, "rotation")
            };
            CanonicalCanvas canvas = planner.GetCanonicalCanvas(media);
            string name = Text(testCase, "name");
            Equal(Number(testCase, "expectedWidth"), canvas.Width, name + " width");
            Equal(Number(testCase, "expectedHeight"), canvas.Height, name + " height");
            Near(Decimal(testCase, "expectedFps"), canvas.Fps, 0.0001, name + " fps");
            Equal(Text(testCase, "expectedPixelFormat"), canvas.PixelFormat, name + " format");
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

    private static void TestModeCases(JsonElement root)
    {
        foreach (JsonElement testCase in root.GetProperty("modeCases").EnumerateArray())
        {
            CompressionMode mode = Enum.Parse<CompressionMode>(Text(testCase, "mode"));
            ModeStrategy strategy = CompressionPlanner.Strategy(mode);
            Equal(Number(testCase, "maxFullEncodes"), strategy.MaxFullEncodes, mode + " encodes");
            Near(Decimal(testCase, "fillGate"), strategy.FillGate, 1e-9, mode + " fill");
        }
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

        Equal(662, corrected, "corrected bitrate");
    }

    private static void TestCliAliases()
    {
        CompressionRequest request = CLIOptions.Parse(["-InputFile", "input.mp4", "-TargetBytes", "123456", "-Mode", "Fast", "-ResultJsonPath", "result.json"]);
        Equal("input.mp4", request.InputPath, "input");
        Equal(123456L, request.TargetBytes, "bytes");
        Equal(CompressionMode.Fast, request.Mode, "mode");
        Equal("result.json", request.ResultJsonPath, "result path");
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

    private static string FindRepositoryRoot()
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "compress.ps1"))) return directory.FullName;
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException("Could not locate repository root.");
    }

    private static void Run(string name, Action test)
    {
        try { test(); _passed++; Console.WriteLine($"PASS {name}"); }
        catch (Exception exception) { _failed++; Console.WriteLine($"FAIL {name} - {exception.Message}"); }
    }

    private static string Text(JsonElement element, string name) => element.GetProperty(name).GetString()!;
    private static int Number(JsonElement element, string name) => element.GetProperty(name).GetInt32();
    private static double Decimal(JsonElement element, string name) => element.GetProperty(name).GetDouble();
    private static void Equal<T>(T expected, T actual, string name) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{name}: expected '{expected}', actual '{actual}'"); }
    private static void Near(double expected, double actual, double tolerance, string name) { if (Math.Abs(expected - actual) > tolerance) throw new InvalidOperationException($"{name}: expected '{expected}', actual '{actual}'"); }
}
