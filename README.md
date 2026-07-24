# byakuren

[![.NET](https://img.shields.io/badge/.NET-10.0-512BD4)](https://dotnet.microsoft.com/download/dotnet/10.0)

A command-line video compressor that uses FFmpeg to compress videos perfectly under any file size, while squeezing out the most quality possible

## Features

- **Content-Aware Planning**: Samples motion, detail, scene changes, and content characteristics before encoding
- **Adaptive Encoding**: Chooses resolution, frame rate, bitrate, audio allocation, preprocessing, and crop settings
- **Multiple Codecs**: Supports H.264, H.265, AV1, and VP9 through compatible FFmpeg encoders
- **Quality Modes**: Select `Fast`, `Balanced`, or `ExtraQuality` according to the desired speed and search depth
- **Quality Metrics**: Uses VMAF and XPSNR when they are available in the installed FFmpeg build

## Installation

### Prerequisites

Install the following:

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- [FFmpeg](https://ffmpeg.org/download.html), including `ffmpeg` and `ffprobe`
- [Git](https://git-scm.com/downloads)

Make sure the tools are available in your `PATH`:

```powershell
dotnet --version
ffmpeg -version
ffprobe -version
```

The default H.264 profile requires an FFmpeg build with `libx264` and AAC support. Other profiles require their corresponding encoders, such as `libx265`, `libsvtav1`, `libvpx-vp9`, or `libopus`. Byakuren probes the selected profile before performing the full encode.

### Build and Install Locally

Clone the repository and publish a Release build:

```powershell
git clone https://github.com/rosalgie/byakuren.git
cd byakuren
dotnet publish Byakuren\Byakuren.csproj -c Release -o out\publish
```

Run the published application:

```powershell
.\out\publish\byakuren.exe --help
```

On platforms where the publish output does not include a native launcher, use:

```powershell
dotnet .\out\publish\byakuren.dll --help
```

## Usage

Compress a video to a 25 MiB cap:

```powershell
.\out\publish\byakuren.exe --input .\video.mp4 --target-mb 25
```

Specify the output file and save a JSON result:

```powershell
.\out\publish\byakuren.exe `
    --input .\video.mp4 `
    --target-mb 25 `
    --output .\video-compressed.mp4 `
    --result-json .\video-compressed.json
```

Use an exact byte cap:

```powershell
.\out\publish\byakuren.exe `
    --input .\video.mp4 `
    --target-bytes 26214400 `
    --output .\video-compressed.mp4
```

Use automatic codec selection under the modern compatibility policy:

```powershell
.\out\publish\byakuren.exe `
    --input .\video.mp4 `
    --target-mb 25 `
    --video-codec auto `
    --compatibility-mode modern
```

If `--output` is omitted, Byakuren writes beside the input with a generated name similar to:

```text
video_25mb_libx264_balanced.mp4
```

Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to cancel an active job cleanly.

## Options

### Common Options

| Option | Description | Default |
| --- | --- | --- |
| `-i`, `--input <path>` | Input media path | Required |
| `-t`, `--target-mb <size>` | Output cap in MiB, or MB with `DecimalMB` | Required unless `--target-bytes` is used |
| `--target-bytes <bytes>` | Absolute output cap in bytes | Required unless `--target-mb` is used |
| `-o`, `--output <path>` | Output media path | Generated beside the input |
| `--target-unit <BinaryMiB\|DecimalMB>` | Unit used by `--target-mb` | `BinaryMiB` |
| `--mode <Fast\|Balanced\|ExtraQuality>` | Compression strategy | `Balanced` |
| `--video-codec <x264\|x265\|av1\|vp9\|auto>` | Video codec policy | `x264` |
| `--encoder-backend <name>` | FFmpeg encoder backend | `auto` |
| `--container <mp4\|webm\|auto>` | Output container | `auto` |
| `--result-json <path>` | Write the result contract as JSON | Disabled |
| `-v`, `--verbose [0\|1\|2]` | Shows output of commands being run by byakuren | Disabled |

Run the built-in help to view every option:

```powershell
.\out\publish\byakuren.exe --help
```

### Encoding Profiles

| Codec | Backend | FFmpeg video encoder | Container | Audio |
| --- | --- | --- | --- | --- |
| H.264 | `libx264` | `libx264` | MP4 | AAC |
| H.265 | `libx265` | `libx265` | MP4 | AAC |
| AV1 | `svtav1` | `libsvtav1` | WebM | Opus |
| AV1 | `aom` | `libaom-av1` | WebM | Opus |
| AV1 | `rav1e` | `librav1e` | WebM | Opus |
| VP9 | `vpx` | `libvpx-vp9` | WebM | Opus |
| H.264, H.265, or AV1 | `vaapi` | Codec-specific VAAPI encoder | MP4 or WebM | AAC or Opus |

The `aom`, `rav1e`, and `vpx` backends require `--enable-experimental-encoders`. Hardware VAAPI profiles are explicit throughput options available only in `Fast` mode and require a supported host and device.

### Advanced Controls

- `--compatibility-mode <widest|modern|unrestricted>` controls automatic codec selection.
- `--sample-mode <Fixed|SceneAware|Auto>` controls how analysis windows are selected.
- `--audio-priority <Visual|Balanced|Speech>` changes how the size budget is divided.
- `--preprocess-profile <Off|Auto|Mild>` controls preprocessing.
- `--crop-mode <Off|Auto>` controls automatic border removal.
- `--vbv-mode <Off|Streaming>` enables streaming-oriented VBV constraints.
- `--output-bit-depth <Auto|8|10>` selects output bit depth where supported.
- `--under-cap-behavior <Auto|Copy|Transcode>` controls already-small inputs.
- `--metric-mode <Off|VMAF|XPSNR|Ensemble|Auto>` controls quality evaluation.
- `--working-target-ratio <ratio>` reserves space beneath the hard cap; the default is `0.995`.
- `--enable-plan-logging` writes detailed planning events as JSON Lines.
- `--ffmpeg <path>` and `--ffprobe <path>` select custom executable locations.
