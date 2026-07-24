using System.CommandLine;
using Byakuren.Models;

namespace Byakuren.CLI;

public sealed class CLIOptions
{
    private readonly Option<string?> _input = new("--input", "-i", "-InputFile")
    {
        Description = "Input media path"
    };

    private readonly Option<long?> _targetBytes = new("--target-bytes", "-TargetBytes")
    {
        Description = "Absolute output size cap in bytes"
    };

    private readonly Option<double?> _targetMegabytes = new("--target-mb", "-t", "-TargetMB")
    {
        Description = "Output size cap in MiB, or MB when --target-unit is DecimalMB"
    };

    private readonly Option<string?> _output = new("--output", "-o", "-OutputFile")
    {
        Description = "Output media path"
    };

    private readonly Option<string?> _resultJson = new("--result-json", "-ResultJsonPath")
    {
        Description = "Path for the JSON result contract"
    };

    private readonly Option<TargetUnit?> _targetUnit = new("--target-unit", "-TargetUnit")
    {
        Description = "Unit used by --target-mb: BinaryMiB or DecimalMB"
    };

    private readonly Option<CompressionMode?> _mode = new("--mode", "-Mode")
    {
        Description = "Compression strategy: Fast, Balanced, or ExtraQuality"
    };

    private readonly Option<string?> _videoCodec = new("--video-codec", "-VideoCodec")
    {
        Description = "Video codec: x264, x265, av1, vp9, or auto"
    };

    private readonly Option<string?> _encoderBackend = new("--encoder-backend", "-EncoderBackend")
    {
        Description = "Encoder backend, such as libx264, libx265, svtav1, or auto"
    };

    private readonly Option<string?> _container = new("--container", "-Container")
    {
        Description = "Output container: mp4, webm, or auto"
    };

    private readonly Option<string?> _compatibilityMode = new("--compatibility-mode", "-CompatibilityMode")
    {
        Description = "Compatibility policy: widest, modern, or unrestricted"
    };

    private readonly Option<string?> _contentClassMode = new("--content-class-mode", "-ContentClassMode")
    {
        Description = "Legacy content classification mode: auto or off"
    };

    private readonly Option<string?> _contentClass = new("--content-class", "-ContentClass")
    {
        Description =
            "Content class: auto, general, screen, gameplay, anime, noisy_camera, talking_head, or off"
    };

    private readonly Option<SampleMode?> _sampleMode = new("--sample-mode", "-SampleMode")
    {
        Description = "Sampling strategy: Fixed, SceneAware, or Auto"
    };

    private readonly Option<AudioPriority?> _audioPriority = new("--audio-priority", "-AudioPriority")
    {
        Description = "Audio allocation priority: Visual, Balanced, or Speech"
    };

    private readonly Option<PreprocessMode?> _preprocessMode = new(
        "--preprocess-profile",
        "--preprocess-mode",
        "-PreprocessProfile")
    {
        Description = "Preprocessing policy: Off, Auto, or Mild"
    };

    private readonly Option<CropMode?> _cropMode = new("--crop-mode", "-CropMode")
    {
        Description = "Automatic border cropping: Off or Auto"
    };

    private readonly Option<VBVMode?> _vbvMode = new("--vbv-mode", "-VBVMode")
    {
        Description = "VBV rate-control policy: Off or Streaming"
    };

    private readonly Option<string?> _outputBitDepth = new("--output-bit-depth", "-OutputBitDepth")
    {
        Description = "Output bit depth: Auto, 8, or 10"
    };

    private readonly Option<string?> _hardwareDevice = new("--hardware-device", "-HardwareDevice")
    {
        Description = "Hardware encoder device path, or auto"
    };

    private readonly Option<UnderCapBehavior?> _underCapBehavior = new(
        "--under-cap-behavior",
        "-UnderCapBehavior")
    {
        Description = "Behavior for an input already under the cap: Auto, Copy, or Transcode"
    };

    private readonly Option<MetricMode?> _metricMode = new("--metric-mode", "-MetricMode")
    {
        Description = "Quality metric: Off, VMAF, XPSNR, Ensemble, or Auto"
    };

    private readonly Option<bool> _enableExperimentalEncoders = new(
        "--enable-experimental-encoders",
        "-EnableExperimentalEncoders")
    {
        Description = "Allow experimental encoder backends"
    };

    private readonly Option<string?> _preset = new("--preset", "-Preset")
    {
        Description = "Encoder-specific preset"
    };

    private readonly Option<double?> _workingTargetRatio = new(
        "--working-target-ratio",
        "-WorkingTargetRatio")
    {
        Description = "Fraction of the hard cap used while planning, from 0 to 1"
    };

    private readonly Option<double?> _safetyMarginPercent = new(
        "--safety-margin-percent",
        "-SafetyMarginPercent")
    {
        Description = "Legacy safety margin expressed as a ratio or percent"
    };

    private readonly Option<int?> _probeSampleSeconds = new(
        "--probe-sample-seconds",
        "-ProbeSampleSeconds")
    {
        Description = "Length of each analysis sample in seconds"
    };

    private readonly Option<int?> _metricSampleSeconds = new(
        "--metric-sample-seconds",
        "-MetricSampleSeconds")
    {
        Description = "Length of each metric sample in seconds"
    };

    private readonly Option<int?> _metricMaxSamples = new("--metric-max-samples", "-MetricMaxSamples")
    {
        Description = "Maximum number of metric samples"
    };

    private readonly Option<bool> _enablePlanLogging = new(
        "--enable-plan-logging",
        "-EnablePlanLogging")
    {
        Description = "Write detailed planning events to a log"
    };

    private readonly Option<string?> _planLogPath = new("--plan-log-path", "-PlanLogPath")
    {
        Description = "Path for the planning event log"
    };

    private readonly Option<bool> _verbose = new("--verbose", "-v")
    {
        Description = "Print external commands and stream their output"
    };

    private readonly Option<string?> _ffmpeg = new("--ffmpeg", "-FFmpeg")
    {
        Description = "Path to the ffmpeg executable"
    };

    private readonly Option<string?> _ffprobe = new("--ffprobe", "-FFprobe")
    {
        Description = "Path to the ffprobe executable"
    };

    public RootCommand CreateRootCommand(
        Func<CompressionRequest, CancellationToken, Task<int>> runCompression)
    {
        RootCommand command = new("Compress a video to an exact output-size cap.");
        AddOptions(command);

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            try
            {
                CompressionRequest request = CreateRequest(parseResult);
                return await runCompression(request, cancellationToken).ConfigureAwait(false);
            }
            catch (ArgumentException exception)
            {
                Console.Error.WriteLine(exception.Message);
                return 1;
            }
        });

        return command;
    }

    private void AddOptions(RootCommand command)
    {
        command.Options.Add(_input);
        command.Options.Add(_targetBytes);
        command.Options.Add(_targetMegabytes);
        command.Options.Add(_output);
        command.Options.Add(_resultJson);
        command.Options.Add(_targetUnit);
        command.Options.Add(_mode);
        command.Options.Add(_videoCodec);
        command.Options.Add(_encoderBackend);
        command.Options.Add(_container);
        command.Options.Add(_compatibilityMode);
        command.Options.Add(_contentClass);
        command.Options.Add(_contentClassMode);
        command.Options.Add(_sampleMode);
        command.Options.Add(_audioPriority);
        command.Options.Add(_preprocessMode);
        command.Options.Add(_cropMode);
        command.Options.Add(_vbvMode);
        command.Options.Add(_outputBitDepth);
        command.Options.Add(_hardwareDevice);
        command.Options.Add(_underCapBehavior);
        command.Options.Add(_metricMode);
        command.Options.Add(_enableExperimentalEncoders);
        command.Options.Add(_preset);
        command.Options.Add(_workingTargetRatio);
        command.Options.Add(_safetyMarginPercent);
        command.Options.Add(_probeSampleSeconds);
        command.Options.Add(_metricSampleSeconds);
        command.Options.Add(_metricMaxSamples);
        command.Options.Add(_enablePlanLogging);
        command.Options.Add(_planLogPath);
        command.Options.Add(_verbose);
        command.Options.Add(_ffmpeg);
        command.Options.Add(_ffprobe);
    }

    private CompressionRequest CreateRequest(ParseResult parseResult)
    {
        string? inputPath = parseResult.GetValue(_input);
        if (string.IsNullOrWhiteSpace(inputPath))
            throw new ArgumentException("Missing required option --input.");

        TargetUnit targetUnit = parseResult.GetValue(_targetUnit) ?? TargetUnit.BinaryMiB;
        long targetBytes = GetTargetBytes(parseResult, targetUnit);
        string outputBitDepth = parseResult.GetValue(_outputBitDepth) ?? "Auto";

        bool automaticBitDepth = outputBitDepth.Equals(
            "auto",
            StringComparison.OrdinalIgnoreCase);
        if (!automaticBitDepth && outputBitDepth is not ("8" or "10"))
            throw new ArgumentException("Output bit depth must be Auto, 8, or 10.");

        return new CompressionRequest
        {
            InputPath = inputPath,
            TargetBytes = targetBytes,
            OutputPath = parseResult.GetValue(_output),
            ResultJsonPath = parseResult.GetValue(_resultJson),
            TargetUnit = targetUnit,
            Mode = parseResult.GetValue(_mode) ?? CompressionMode.Balanced,
            VideoCodec = parseResult.GetValue(_videoCodec) ?? "x264",
            EncoderBackend = parseResult.GetValue(_encoderBackend) ?? "auto",
            Container = parseResult.GetValue(_container) ?? "auto",
            CompatibilityMode = parseResult.GetValue(_compatibilityMode) ?? "widest",
            ContentClassMode = GetContentClass(parseResult),
            SampleMode = parseResult.GetValue(_sampleMode) ?? SampleMode.Auto,
            AudioPriority = parseResult.GetValue(_audioPriority) ?? AudioPriority.Balanced,
            PreprocessMode = parseResult.GetValue(_preprocessMode) ?? PreprocessMode.Auto,
            CropMode = parseResult.GetValue(_cropMode) ?? CropMode.Auto,
            VBVMode = parseResult.GetValue(_vbvMode) ?? VBVMode.Off,
            OutputBitDepth = outputBitDepth,
            HardwareDevice = parseResult.GetValue(_hardwareDevice) ?? "auto",
            UnderCapBehavior = parseResult.GetValue(_underCapBehavior) ?? UnderCapBehavior.Auto,
            MetricMode = parseResult.GetValue(_metricMode) ?? MetricMode.Auto,
            EnableExperimentalEncoders = parseResult.GetValue(_enableExperimentalEncoders),
            Preset = parseResult.GetValue(_preset),
            WorkingTargetRatio = GetWorkingTargetRatio(parseResult),
            ProbeSampleSeconds = GetNonNegativeValue(parseResult.GetValue(_probeSampleSeconds), 6, 1, "--probe-sample-seconds"),
            MetricSampleSeconds = GetNonNegativeValue(parseResult.GetValue(_metricSampleSeconds), 0, 0, "--metric-sample-seconds"),
            MetricMaxSamples = GetNonNegativeValue(parseResult.GetValue(_metricMaxSamples), 0, 0, "--metric-max-samples"),
            EnablePlanLogging = parseResult.GetValue(_enablePlanLogging),
            PlanLogPath = parseResult.GetValue(_planLogPath),
            Verbose = parseResult.GetValue(_verbose),
            FFmpegPath = parseResult.GetValue(_ffmpeg) ?? "ffmpeg",
            FFprobePath = parseResult.GetValue(_ffprobe) ?? "ffprobe"
        };
    }

    private long GetTargetBytes(ParseResult parseResult, TargetUnit targetUnit)
    {
        long? bytes = parseResult.GetValue(_targetBytes);
        double? megabytes = parseResult.GetValue(_targetMegabytes);

        if (bytes.HasValue && megabytes.HasValue)
        {
            throw new ArgumentException("Specify either --target-bytes or --target-mb, not both.");
        }

        if (bytes.HasValue)
        {
            if (bytes.Value <= 0)
            {
                throw new ArgumentOutOfRangeException(
                    "--target-bytes",
                    "Target bytes must be greater than zero.");
            }

            return bytes.Value;
        }

        if (!megabytes.HasValue || megabytes.Value <= 0)
        {
            throw new ArgumentException("A positive --target-bytes or --target-mb value is required.");
        }

        double multiplier;
        if (targetUnit == TargetUnit.BinaryMiB)
        {
            multiplier = 1024.0 * 1024.0;
        }
        else
        {
            multiplier = 1_000_000.0;
        }

        try
        {
            return checked((long)Math.Floor(megabytes.Value * multiplier));
        }
        catch (OverflowException)
        {
            throw new ArgumentOutOfRangeException(
                "--target-mb",
                megabytes.Value,
                "Target size is too large.");
        }
    }

    private double GetWorkingTargetRatio(ParseResult parseResult)
    {
        double? ratio = parseResult.GetValue(_workingTargetRatio);
        double? margin = parseResult.GetValue(_safetyMarginPercent);

        if (ratio.HasValue && margin.HasValue)
        {
            throw new ArgumentException(
                "Specify either --working-target-ratio or --safety-margin-percent, not both.");
        }

        if (ratio.HasValue)
        {
            return ratio.Value;
        }

        if (!margin.HasValue)
        {
            return 0.995;
        }

        if (margin.Value is > 0 and <= 1)
        {
            return margin.Value;
        }

        if (margin.Value is > 1 and < 100)
        {
            return 1 - margin.Value / 100;
        }

        throw new ArgumentOutOfRangeException(
            "--safety-margin-percent",
            "Safety margin must be a ratio from 0 to 1 or a percent below 100.");
    }

    private string GetContentClass(ParseResult parseResult)
    {
        string? contentClass = parseResult.GetValue(_contentClass);
        string? legacyMode = parseResult.GetValue(_contentClassMode);
        if (contentClass is not null && legacyMode is not null)
        {
            throw new ArgumentException(
                "Specify either --content-class or --content-class-mode, not both.");
        }

        if (legacyMode is not null)
        {
            string normalizedLegacyMode = ContentClassSelection.Normalize(legacyMode);
            if (normalizedLegacyMode is not (
                ContentClassSelection.Auto or ContentClassSelection.Off))
            {
                throw new ArgumentException(
                    "Legacy --content-class-mode accepts only auto or off.");
            }

            return normalizedLegacyMode;
        }

        return ContentClassSelection.Normalize(contentClass);
    }

    private static int GetNonNegativeValue(
        int? value,
        int defaultValue,
        int minimum,
        string optionName)
    {
        if (!value.HasValue)
        {
            return defaultValue;
        }

        if (value.Value < minimum)
        {
            throw new ArgumentOutOfRangeException(
                optionName,
                $"Value must be at least {minimum}.");
        }

        return value.Value;
    }

}
