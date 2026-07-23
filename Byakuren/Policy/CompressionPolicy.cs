using Byakuren.Models;

namespace Byakuren.Policy;

public sealed class CompressionPolicy
{
    public IReadOnlyList<ResolvedPolicy> ResolveCandidates(CompressionRequest request)
    {
        string requestedCodec = Normalize(request.VideoCodec, "x264");
        string requestedBackend = Normalize(request.EncoderBackend, "auto");
        if (requestedCodec != "auto" || requestedBackend != "auto")
            return [Resolve(request)];

        string compatibility = Normalize(request.CompatibilityMode, "widest");
        IReadOnlyList<(string Codec, string Backend)> candidates = compatibility switch
        {
            "widest" => [("x264", "libx264")],
            "modern" when request.EnableExperimentalEncoders =>
            [
                ("av1", "svtav1"),
                ("vp9", "vpx"),
                ("x264", "libx264")
            ],
            "modern" => [("av1", "svtav1"), ("x264", "libx264")],
            "unrestricted" when request.EnableExperimentalEncoders =>
            [
                ("x264", "libx264"),
                ("x265", "libx265"),
                ("av1", "svtav1"),
                ("vp9", "vpx")
            ],
            "unrestricted" =>
            [
                ("x264", "libx264"),
                ("x265", "libx265"),
                ("av1", "svtav1")
            ],
            _ => throw new ArgumentException($"Unsupported compatibility mode '{request.CompatibilityMode}'.")
        };

        List<ResolvedPolicy> resolved = [];
        foreach ((string codec, string backend) in candidates)
        {
            try
            {
                CompressionRequest candidateRequest = request with { VideoCodec = codec, EncoderBackend = backend };
                ResolvedPolicy candidate = Resolve(candidateRequest);
                resolved.Add(candidate with { CodecReason = $"{compatibility}-policy" });
            }
            catch (ArgumentException) when (!request.Container.Equals("auto", StringComparison.OrdinalIgnoreCase))
            {
                // An explicit container narrows the otherwise eligible automatic codec set.
            }
        }
        if (resolved.Count == 0)
            throw new ArgumentException($"No automatic codec candidate supports container '{request.Container}'.");
        return resolved;
    }

    public ResolvedPolicy Resolve(CompressionRequest request)
    {
        string requestedCodec = Normalize(request.VideoCodec, "x264");
        string backend = Normalize(request.EncoderBackend, "auto");
        string compatibility = Normalize(request.CompatibilityMode, "widest");
        string container = Normalize(request.Container, "auto");
        string codecReason = requestedCodec == "auto" ? $"{compatibility}-policy" : "pinned";

        if (backend != "auto")
        {
            if (backend is "aom" or "rav1e" or "vpx" or "vvenc" && !request.EnableExperimentalEncoders)
                throw new ArgumentException(
                    $"Encoder backend '{backend}' is experimental; explicitly enable " +
                    "experimental encoders to use it.");
            if (backend == "vvenc")
                throw new ArgumentException("VVenC is a raw-video lab backend and is not eligible for delivery output.");

            string backendCodec = BackendCodec(backend, requestedCodec);
            if (requestedCodec != "auto" && !CodecAliasesMatch(requestedCodec, backendCodec))
                throw new ArgumentException($"Encoder backend '{backend}' does not implement codec '{requestedCodec}'.");
            requestedCodec = backendCodec;
            codecReason = "backend-pinned";
        }
        else if (requestedCodec == "auto")
        {
            requestedCodec = compatibility switch
            {
                "widest" => "x264",
                "modern" => "av1",
                "unrestricted" => "av1",
                _ => throw new ArgumentException($"Unsupported compatibility mode '{request.CompatibilityMode}'.")
            };
        }

        if (backend == "auto")
            backend = DefaultBackend(requestedCodec);

        if (container == "auto")
            container = DefaultContainer(requestedCodec);

        string expectedContainer = DefaultContainer(requestedCodec);
        if (container != expectedContainer)
            throw new ArgumentException(
                $"Codec '{requestedCodec}' with backend '{backend}' requires the " +
                $"'{expectedContainer}' delivery container.");

        EncoderProfile profile = CreateProfile(requestedCodec, backend, container);
        if (profile.IsHardware && request.Mode != CompressionMode.Fast)
            throw new ArgumentException("Hardware backends are explicit throughput options and are supported only in Fast mode.");
        if (backend == "rav1e" && request.Mode != CompressionMode.Fast)
            throw new ArgumentException("The FFmpeg rav1e wrapper exposes only the one-pass lab adapter; use Fast mode.");

        string containerReason = "pinned";
        if (request.Container.Equals("auto", StringComparison.OrdinalIgnoreCase))
            containerReason = "codec-default";

        return new ResolvedPolicy(profile, codecReason, containerReason, compatibility);
    }

    public static EncoderProfile CreateProfile(string codec, string backend, string container)
    {
        const string opus = "libopus";
        return (backend, codec, container) switch
        {
            ("libx264", "x264", "mp4") => Software(
                "x264", "libx264", "libx264", "mp4", ".mp4", "aac", "aac", "x264"),
            ("libx265", "x265", "mp4") => Software(
                "x265", "libx265", "libx265", "mp4", ".mp4", "aac", "aac", "x265"),
            ("svtav1", "av1", "webm") => Software(
                "av1", "svtav1", "libsvtav1", "webm", ".webm", "opus", opus, "svtav1"),
            ("aom", "av1", "webm") => Software(
                "av1", "aom", "libaom-av1", "webm", ".webm", "opus", opus, "aom"),
            ("rav1e", "av1", "webm") => Software(
                "av1", "rav1e", "librav1e", "webm", ".webm", "opus", opus, "rav1e",
                passes: 1,
                adapter: "one-pass-vbr-lab"),
            ("vpx", "vp9", "webm") => Software(
                "vp9", "vpx", "libvpx-vp9", "webm", ".webm", "opus", opus, "vpx"),
            ("vaapi", "x264", "mp4") => Hardware(
                "x264", "h264_vaapi", "mp4", ".mp4", "aac", "aac"),
            ("vaapi", "x265", "mp4") => Hardware(
                "x265", "hevc_vaapi", "mp4", ".mp4", "aac", "aac"),
            ("vaapi", "av1", "webm") => Hardware(
                "av1", "av1_vaapi", "webm", ".webm", "opus", opus),
            _ => throw new ArgumentException($"Unsupported encoder/codec/container combination: {backend} + {codec} + {container}.")
        };
    }

    private static EncoderProfile Software(
        string codec,
        string backend,
        string encoder,
        string container,
        string extension,
        string audioCodec,
        string audioEncoder,
        string presetKind,
        int passes = 2,
        string adapter = "ffmpeg-two-pass-vbr")
    {
        return new EncoderProfile
        {
            VideoCodec = codec,
            Backend = backend,
            Encoder = encoder,
            Container = container,
            Extension = extension,
            AudioCodec = audioCodec,
            AudioEncoder = audioEncoder,
            PresetKind = presetKind,
            RequiredPasses = passes,
            RateControlAdapter = adapter
        };
    }

    private static EncoderProfile Hardware(
        string codec,
        string encoder,
        string container,
        string extension,
        string audioCodec,
        string audioEncoder)
    {
        return new EncoderProfile
        {
            VideoCodec = codec,
            Backend = "vaapi",
            Encoder = encoder,
            Container = container,
            Extension = extension,
            AudioCodec = audioCodec,
            AudioEncoder = audioEncoder,
            PresetKind = "vaapi",
            RequiredPasses = 1,
            RateControlAdapter = "vaapi-one-pass-vbr",
            IsHardware = true
        };
    }

    private static string BackendCodec(string backend, string requestedCodec) => backend switch
    {
        "libx264" => "x264",
        "libx265" => "x265",
        "svtav1" or "aom" or "rav1e" => "av1",
        "vpx" => "vp9",
        "vvenc" => "vvc",
        "vaapi" when requestedCodec is "x264" or "x265" or "av1" => requestedCodec,
        "vaapi" => throw new ArgumentException("VAAPI requires an explicit x264, x265, or av1 codec."),
        _ => throw new ArgumentException($"Unsupported encoder backend '{backend}'.")
    };

    private static string DefaultBackend(string codec) => codec switch
    {
        "x264" => "libx264",
        "x265" => "libx265",
        "av1" => "svtav1",
        "vp9" => "vpx",
        _ => throw new ArgumentException($"Unsupported video codec '{codec}'.")
    };

    private static string DefaultContainer(string codec) => codec is "av1" or "vp9" ? "webm" : "mp4";
    private static bool CodecAliasesMatch(string first, string second)
    {
        return first == second ||
            first == "h264" && second == "x264" ||
            first == "hevc" && second == "x265";
    }

    private static string Normalize(string? value, string fallback)
    {
        if (string.IsNullOrWhiteSpace(value))
            return fallback;

        return value.Trim().ToLowerInvariant();
    }
}
