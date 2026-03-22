[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputFile,

  [Nullable[int]]$TargetMB = $null,

  [Nullable[long]]$TargetBytes = $null,

  [ValidateSet("BinaryMiB", "DecimalMB")]
  [string]$TargetUnit = "BinaryMiB",

  [ValidateSet("Fast", "Balanced", "ExtraQuality")]
  [string]$Mode = "Balanced",

  [ValidateSet("x264", "x265", "av1")]
  [string]$VideoCodec = "x264",

  [AllowEmptyString()]
  [string]$Container = "",

  [AllowEmptyString()]
  [string]$OutputFile = "",

  [AllowEmptyString()]
  [string]$Preset = "",

  [double]$SafetyMarginPercent = 0.995,

  [int]$ProbeSampleSeconds = 6,

  [ValidateSet("Off", "Auto", "Mild")]
  [string]$PreprocessProfile = "Auto",

  [ValidateSet("Off", "Auto")]
  [string]$CropMode = "Auto",

  [switch]$VerboseCommands
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$scriptStart = Get-Date

function Require-Tool($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required tool '$name' was not found in PATH."
  }
}

function Invoke-Tool {
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string[]]$Args,
    [switch]$AllowFailure
  )

  if ($VerboseCommands) {
    $quoted = $Args | ForEach-Object {
      if ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }
    Write-Host ("CMD> {0} {1}" -f $Exe, ($quoted -join ' '))
  }

  & $Exe @Args
  $code = $LASTEXITCODE

  if (-not $AllowFailure -and $code -ne 0) {
    throw "$Exe failed with exit code $code."
  }
}

function Invoke-ToolCapture {
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string[]]$Args,
    [switch]$AllowFailure
  )

  if ($VerboseCommands) {
    $quoted = $Args | ForEach-Object {
      if ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }
    Write-Host ("CMD> {0} {1}" -f $Exe, ($quoted -join ' '))
  }

  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()

  try {
    $process = Start-Process -FilePath $Exe -ArgumentList $Args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
    $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }

    if (-not $AllowFailure -and $process.ExitCode -ne 0) {
      throw "$Exe failed with exit code $($process.ExitCode)."
    }

    return [PSCustomObject]@{
      ExitCode = [int]$process.ExitCode
      StdOut   = $stdout
      StdErr   = $stderr
      Output   = ($stdout + $stderr)
    }
  }
  finally {
    Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

$script:FfmpegEncodersText = $null
$script:FfmpegMuxersText = $null

function Get-FfmpegEncodersText {
  if ($null -eq $script:FfmpegEncodersText) {
    $script:FfmpegEncodersText = (Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-encoders")).Output
  }

  return [string]$script:FfmpegEncodersText
}

function Get-FfmpegMuxersText {
  if ($null -eq $script:FfmpegMuxersText) {
    $script:FfmpegMuxersText = (Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-muxers")).Output
  }

  return [string]$script:FfmpegMuxersText
}

function Test-FfmpegEncoderAvailable([string]$Encoder) {
  $pattern = ('(?m)^\s*[A-Z\.]+\s+{0}\s' -f [regex]::Escape($Encoder))
  return ([regex]::IsMatch((Get-FfmpegEncodersText), $pattern))
}

function Test-FfmpegMuxerAvailable([string]$Muxer) {
  $pattern = ('(?m)^\s*E\s+{0}\s' -f [regex]::Escape($Muxer))
  return ([regex]::IsMatch((Get-FfmpegMuxersText), $pattern))
}

function Get-CodecPresetRank($preset) {
  switch ($preset) {
    "ultrafast" { return 1 }
    "superfast" { return 2 }
    "veryfast"  { return 3 }
    "faster"    { return 4 }
    "fast"      { return 5 }
    "medium"    { return 6 }
    "slow"      { return 7 }
    "slower"    { return 8 }
    "veryslow"  { return 9 }
    "placebo"   { return 10 }
    default     { return 0 }
  }
}

function Get-SvtAv1PresetForPreset([string]$Preset) {
  switch ($Preset) {
    "ultrafast" { return 12 }
    "superfast" { return 11 }
    "veryfast"  { return 10 }
    "faster"    { return 9 }
    "fast"      { return 8 }
    "medium"    { return 6 }
    "slow"      { return 4 }
    "slower"    { return 3 }
    "veryslow"  { return 2 }
    "placebo"   { return 0 }
    default {
      throw "Unsupported preset '$Preset' for SVT-AV1. Use one of: ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow, placebo."
    }
  }
}

function Get-CodecEfficiencyMultiplier([string]$VideoCodec) {
  switch ($VideoCodec) {
    "x264" { return 1.00 }
    "x265" { return 0.82 }
    "av1"  { return 0.72 }
    default { return 1.00 }
  }
}

function Get-RateControlSeedCrf([string]$VideoCodec, [string]$Mode) {
  switch ($VideoCodec) {
    "x264" {
      switch ($Mode) {
        "Fast"         { return 32.0 }
        "Balanced"     { return 30.0 }
        "ExtraQuality" { return 28.0 }
      }
    }
    "x265" {
      switch ($Mode) {
        "Fast"         { return 34.0 }
        "Balanced"     { return 32.0 }
        "ExtraQuality" { return 30.0 }
      }
    }
    "av1" {
      switch ($Mode) {
        "Fast"         { return 40.0 }
        "Balanced"     { return 36.0 }
        "ExtraQuality" { return 32.0 }
      }
    }
  }
}

function Get-AudioCodecLabel([string]$AudioCodec) {
  switch ($AudioCodec) {
    "aac"  { return "AAC" }
    "opus" { return "Opus" }
    default { return $AudioCodec.ToUpperInvariant() }
  }
}

function Get-ResolvedContainer([string]$VideoCodec, [AllowEmptyString()][string]$Container) {
  if ([string]::IsNullOrWhiteSpace($Container)) {
    switch ($VideoCodec) {
      "av1"  { return "webm" }
      default { return "mp4" }
    }
  }

  $normalized = $Container.Trim().ToLowerInvariant()
  if ($normalized -notin @("mp4", "webm")) {
    throw "Unsupported container '$Container'. Supported containers are mp4 and webm."
  }

  return $normalized
}

function Resolve-CodecProfile {
  param(
    [Parameter(Mandatory = $true)][string]$VideoCodec,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Container
  )

  $resolvedContainer = Get-ResolvedContainer -VideoCodec $VideoCodec -Container $Container

  switch ("$VideoCodec|$resolvedContainer") {
    "x264|mp4" {
      return [PSCustomObject]@{
        VideoCodec           = "x264"
        VideoEncoder         = "libx264"
        Container            = "mp4"
        Extension            = ".mp4"
        DefaultAudioCodec    = "aac"
        DefaultAudioEncoder  = "aac"
        CopyableAudioCodecs  = @("aac")
        PresetKind           = "x264"
        PreviewSpeedOverride = [PSCustomObject]@{ Kind = "preset"; Value = "veryfast"; Label = "veryfast" }
        FinalizeArgs         = @("-c", "copy", "-movflags", "+faststart")
      }
    }
    "x265|mp4" {
      return [PSCustomObject]@{
        VideoCodec           = "x265"
        VideoEncoder         = "libx265"
        Container            = "mp4"
        Extension            = ".mp4"
        DefaultAudioCodec    = "aac"
        DefaultAudioEncoder  = "aac"
        CopyableAudioCodecs  = @("aac")
        PresetKind           = "x265"
        PreviewSpeedOverride = [PSCustomObject]@{ Kind = "preset"; Value = "fast"; Label = "fast" }
        FinalizeArgs         = @("-c", "copy", "-movflags", "+faststart")
      }
    }
    "av1|webm" {
      return [PSCustomObject]@{
        VideoCodec           = "av1"
        VideoEncoder         = "libsvtav1"
        Container            = "webm"
        Extension            = ".webm"
        DefaultAudioCodec    = "opus"
        DefaultAudioEncoder  = if (Test-FfmpegEncoderAvailable -Encoder "libopus") { "libopus" } else { "opus" }
        CopyableAudioCodecs  = @("opus")
        PresetKind           = "svtav1"
        PreviewSpeedOverride = [PSCustomObject]@{ Kind = "preset"; Value = 12; Label = "preset=12" }
        FinalizeArgs         = @("-c", "copy")
      }
    }
    "av1|mp4" {
      throw "AV1 output is restricted to WebM in Phase 1. Use -Container webm."
    }
    default {
      throw "Unsupported codec/container combination: $VideoCodec + $resolvedContainer"
    }
  }
}

function Get-OutputExtension([string]$Path) {
  return [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Test-HasExplicitTarget {
  return ($null -ne $TargetMB -or $null -ne $TargetBytes)
}

function Assert-TargetArguments {
  if ($null -ne $TargetMB -and $null -ne $TargetBytes) {
    throw "Specify only one of -TargetMB or -TargetBytes."
  }

  if ($null -ne $TargetMB -and [int]$TargetMB -le 0) {
    throw "-TargetMB must be greater than zero."
  }

  if ($null -ne $TargetBytes -and [long]$TargetBytes -le 0) {
    throw "-TargetBytes must be greater than zero."
  }

  if (-not (Test-HasExplicitTarget)) {
    throw "Specify -TargetMB or -TargetBytes."
  }
}

function Assert-CodecProfileSupport {
  param(
    [Parameter(Mandatory = $true)]$CodecProfile
  )

  if (-not (Test-FfmpegEncoderAvailable -Encoder $CodecProfile.VideoEncoder)) {
    throw "FFmpeg does not support encoder '$($CodecProfile.VideoEncoder)' in the current build."
  }

  if (-not (Test-FfmpegMuxerAvailable -Muxer $CodecProfile.Container)) {
    throw "FFmpeg does not support muxer '$($CodecProfile.Container)' in the current build."
  }

  if (-not (Test-FfmpegEncoderAvailable -Encoder $CodecProfile.DefaultAudioEncoder)) {
    throw "FFmpeg does not support audio encoder '$($CodecProfile.DefaultAudioEncoder)' in the current build."
  }
}

function Get-RequestedTargetBytes {
  if ($null -ne $TargetBytes) {
    return [double]$TargetBytes
  }

  if ($null -ne $TargetMB) {
    switch ($TargetUnit) {
      "BinaryMiB" { return [double]([int]$TargetMB * 1MB) }
      "DecimalMB" { return [double]([int]$TargetMB * 1000 * 1000) }
    }
  }

  return $null
}

function Get-TargetLabel {
  if ($null -ne $TargetBytes) {
    return ("{0}bytes" -f [long]$TargetBytes)
  }

  if ($null -ne $TargetMB) {
    return ("{0}mb" -f [int]$TargetMB)
  }

  return ""
}

function Get-DefaultOutputPath {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$CodecProfile
  )

  $dir = Split-Path $InputPath -Parent
  $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
  $targetLabel = Get-TargetLabel

  if ($CodecProfile.VideoCodec -eq "x264" -and $CodecProfile.Container -eq "mp4" -and (Test-HasExplicitTarget)) {
    return (Join-Path $dir ("{0}_{1}{2}" -f $base, $targetLabel, $CodecProfile.Extension))
  }

  $parts = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($targetLabel)) {
    [void]$parts.Add($targetLabel)
  }
  [void]$parts.Add($CodecProfile.VideoCodec)
  [void]$parts.Add($Mode.ToLowerInvariant())

  return (Join-Path $dir ("{0}_{1}{2}" -f $base, ($parts -join "_"), $CodecProfile.Extension))
}

function Assert-OutputFileMatchesProfile {
  param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)]$CodecProfile
  )

  $extension = Get-OutputExtension -Path $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($extension) -and $extension -ne $CodecProfile.Extension) {
    throw "Output extension '$extension' does not match resolved container '$($CodecProfile.Container)' which requires '$($CodecProfile.Extension)'."
  }
}

function Get-ProbeInfo($path) {
  $json = & ffprobe -v error -print_format json -show_format -show_streams "$path"
  if (-not $json) { throw "ffprobe failed for: $path" }

  $probe = $json | ConvertFrom-Json
  $video = $probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
  $audio = $probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

  if (-not $video) { throw "No video stream found." }

  $srcFps = 0.0
  if ($video.avg_frame_rate -and $video.avg_frame_rate -ne "0/0") {
    $parts = $video.avg_frame_rate -split "/"
    if ($parts.Count -eq 2 -and [double]$parts[1] -ne 0) {
      $srcFps = [double]$parts[0] / [double]$parts[1]
    }
  }

  $videoBitrate = $null
  if ($video.bit_rate) {
    $videoBitrate = [int][math]::Round(([double]$video.bit_rate) / 1000.0)
  }

  $audioBitrate = $null
  if ($audio -and $audio.bit_rate) {
    $audioBitrate = [int][math]::Round(([double]$audio.bit_rate) / 1000.0)
  }

  [PSCustomObject]@{
    Duration         = [double]::Parse($probe.format.duration, [Globalization.CultureInfo]::InvariantCulture)
    Width            = [int]$video.width
    Height           = [int]$video.height
    Fps              = $srcFps
    VideoCodec       = [string]$video.codec_name
    VideoBitrateKbps = $videoBitrate
    HasAudio         = [bool]$audio
    AudioCodec       = if ($audio) { [string]$audio.codec_name } else { "" }
    AudioBitrateKbps = $audioBitrate
    AudioChannels    = if ($audio -and $audio.channels) { [int]$audio.channels } else { 0 }
  }
}

function Get-DefaultPresetForMode($mode) {
  switch ($mode) {
    "Fast"         { return "superfast" }
    "Balanced"     { return "medium" }
    "ExtraQuality" { return "slow" }
  }
}

function Get-ModeStrategy {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [double]$Duration = 0
  )

  switch ($Mode) {
    "Fast" {
      return [PSCustomObject]@{
        Mode                         = "Fast"
        ProbeMaxSamples              = 2
        ProbeEarlyStopSpreadThreshold = 0.14
        PreviewMode                  = "none"
        PreviewSampleSeconds         = 0
        PreviewMaxSamples            = 0
        PreviewTop                   = 0
        Finalists                    = 1
        ShortlistArchetypes          = 3
        MaxFullEncodes               = 2
        MaxSecondStageActions        = 1
        AllowChallenger              = $false
        AllowNeighborFallback        = $false
        AllowPresetExploration       = $false
        NearTieDelta                 = 0.04
        ChallengerConfidenceThreshold = 0.72
        CloseEnoughRatio             = 0.985
        EarlyAcceptRatio             = 0.985
        BadUnderfillRatio            = 0.955
      }
    }

    "Balanced" {
      return [PSCustomObject]@{
        Mode                         = "Balanced"
        ProbeMaxSamples              = 3
        ProbeEarlyStopSpreadThreshold = 0.09
        PreviewMode                  = "tiebreak"
        PreviewSampleSeconds         = if ($Duration -le 60) { 3 } else { 4 }
        PreviewMaxSamples            = 1
        PreviewTop                   = 2
        Finalists                    = 2
        ShortlistArchetypes          = 5
        MaxFullEncodes               = 2
        MaxSecondStageActions        = 1
        AllowChallenger              = $true
        AllowNeighborFallback        = $true
        AllowPresetExploration       = $false
        NearTieDelta                 = 0.03
        ChallengerConfidenceThreshold = 0.80
        CloseEnoughRatio             = 0.992
        EarlyAcceptRatio             = 0.992
        BadUnderfillRatio            = 0.980
      }
    }

    "ExtraQuality" {
      return [PSCustomObject]@{
        Mode                         = "ExtraQuality"
        ProbeMaxSamples              = 4
        ProbeEarlyStopSpreadThreshold = $null
        PreviewMode                  = "broad"
        PreviewSampleSeconds         = if ($Duration -le 60) { 4 } else { 5 }
        PreviewMaxSamples            = 3
        PreviewTop                   = 5
        Finalists                    = 3
        ShortlistArchetypes          = 9
        MaxFullEncodes               = 4
        MaxSecondStageActions        = 3
        AllowChallenger              = $true
        AllowNeighborFallback        = $true
        AllowPresetExploration       = $true
        NearTieDelta                 = 0.02
        ChallengerConfidenceThreshold = 0.88
        CloseEnoughRatio             = 0.994
        EarlyAcceptRatio             = 0.998
        BadUnderfillRatio            = 0.992
      }
    }
  }
}

function Get-SpreadRatio {
  param(
    [Parameter(Mandatory = $true)]$Values
  )

  $list = @($Values | Where-Object { $null -ne $_ })
  if ($list.Count -lt 2) { return 0.0 }

  $sampleMin = ($list | Measure-Object -Minimum).Minimum
  $sampleMax = ($list | Measure-Object -Maximum).Maximum
  $sampleAvg = ($list | Measure-Object -Average).Average
  return ([double]$sampleMax - [double]$sampleMin) / [double][math]::Max(1.0, $sampleAvg)
}

function Get-FpsTier {
  param(
    [Parameter(Mandatory = $true)][double]$SourceFps,
    [Parameter(Mandatory = $true)][int]$TargetFps
  )

  $roundedSource = [int][math]::Round($SourceFps)
  if ([math]::Abs($TargetFps - $roundedSource) -le 1) { return "source" }
  if ($TargetFps -le 24) { return "24_or_lower" }
  if ($TargetFps -le 30) { return "30" }
  return "source"
}

function Get-WidthTier {
  param(
    [Parameter(Mandatory = $true)][double]$WidthRatio
  )

  if ($WidthRatio -gt 1.05) { return "aggressive" }
  if ($WidthRatio -lt 0.95) { return "safe" }
  return "near"
}

function Get-AudioTier {
  param(
    [Parameter(Mandatory = $true)]$AudioPlan
  )

  switch ($AudioPlan.Mode) {
    "copy" { return "copy" }
    "mute" { return "mute" }
    default {
      $kbps = [int](Get-ObjectPropertyValue -Object $AudioPlan -Name "Kbps" -DefaultValue 0)
      if ($kbps -ge 128) { return "high" }
      if ($kbps -ge 80) { return "mid" }
      return "low"
    }
  }
}

function Get-X264PresetRank($preset) {
  return (Get-CodecPresetRank -preset $preset)
}

function Get-AspectHeight($srcWidth, $srcHeight, $targetWidth) {
  $raw = [double]$targetWidth * [double]$srcHeight / [double]$srcWidth
  $even = [int]([math]::Round($raw / 2.0) * 2)
  if ($even -lt 2) { $even = 2 }
  return $even
}

function Get-ObjectPropertyValue {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    $DefaultValue = $null
  )

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $DefaultValue }
  return $property.Value
}

function Get-PlanningWidth($Info) {
  return [int](Get-ObjectPropertyValue -Object $Info -Name "PlanningWidth" -DefaultValue $Info.Width)
}

function Get-PlanningHeight($Info) {
  return [int](Get-ObjectPropertyValue -Object $Info -Name "PlanningHeight" -DefaultValue $Info.Height)
}

function Get-CropFilterString($Info) {
  return [string](Get-ObjectPropertyValue -Object $Info -Name "CropFilter" -DefaultValue "")
}

function Get-CropSummary($Info) {
  return [string](Get-ObjectPropertyValue -Object $Info -Name "CropSummary" -DefaultValue "none")
}

function Get-ExpectedWidth($srcWidth, $srcHeight, $videoKbps, $targetFps, $targetBpppf) {
  if ($srcWidth -le 0 -or $srcHeight -le 0 -or $videoKbps -le 0 -or $targetFps -le 0 -or $targetBpppf -le 0) {
    return [int][math]::Max(320, $srcWidth)
  }

  $targetPixels = [double]$videoKbps * 1000.0 / ([double]$targetFps * $targetBpppf)
  $expectedWidth = [int][math]::Round([math]::Sqrt($targetPixels * ([double]$srcWidth / [double]$srcHeight)))
  return [int][math]::Max(320, [math]::Min($srcWidth, $expectedWidth))
}

function Get-SnappedWidth($width, $maxWidth) {
  if ($maxWidth -le 0) { return 0 }

  $rounded = [int]([math]::Round($width / 32.0) * 32)
  $maxSnapped = [int]([math]::Floor($maxWidth / 32.0) * 32)

  if ($maxSnapped -lt 320) {
    $maxSnapped = [int]([math]::Floor($maxWidth / 2.0) * 2)
  }

  return [int][math]::Max([math]::Min(320, $maxSnapped), [math]::Min($maxSnapped, $rounded))
}

function Get-CombinedWidthOrigin($existingOrigin, $newOrigin) {
  $parts = @()

  foreach ($origin in @($existingOrigin, $newOrigin)) {
    if ([string]::IsNullOrWhiteSpace($origin)) { continue }
    foreach ($part in ($origin -split '\+')) {
      if (-not [string]::IsNullOrWhiteSpace($part) -and $part -notin $parts) {
        $parts += $part
      }
    }
  }

  return ($parts -join "+")
}

function Get-ResolutionCandidates($srcWidth) {
  $all = @(3840, 2560, 1920, 1600, 1440, 1280, 960, 854, 768, 640, 480, 426, 360, 320)
  return $all | Where-Object { $_ -le $srcWidth } | Select-Object -Unique
}

function Get-Bpppf($videoKbps, $width, $height, $fps) {
  if ($width -le 0 -or $height -le 0 -or $fps -le 0 -or $videoKbps -le 0) { return 0.0 }
  return (($videoKbps * 1000.0) / ([double]$width * [double]$height * [double]$fps))
}

function Build-Vf {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][double]$TargetFps,
    [switch]$UseDenoise,
    [string]$ScaleFlags = "lanczos"
  )

  $parts = @()
  $planningWidth = Get-PlanningWidth -Info $Info
  $cropFilter = Get-CropFilterString -Info $Info

  if (-not [string]::IsNullOrWhiteSpace($cropFilter)) {
    $parts += $cropFilter
  }

  if ($TargetFps -gt 0 -and $Info.Fps -gt ($TargetFps + 0.01)) {
    $parts += ("fps={0}" -f $TargetFps)
  }

  if ($TargetWidth -lt $planningWidth) {
    $parts += ("scale={0}:-2:flags={1}" -f $TargetWidth, $ScaleFlags)
  }

  if ($UseDenoise) {
    $parts += "hqdn3d=1.2:1.0:3.0:3.0"
  }

  return ($parts -join ",")
}

function Get-TargetFpsCandidates($srcFps, $mode, $duration, $totalKbps, $motionBucket, $detailBucket) {
  $roundedSrc = [int][math]::Max(1, [math]::Round($srcFps))
  $list = New-Object System.Collections.Generic.List[int]
  $motionVeryLow = ($motionBucket -eq "VeryLow")
  $motionLowish = ($motionBucket -in @("VeryLow", "Low"))
  $detailLowish = ($detailBucket -in @("VeryLow", "Low"))

  switch ($mode) {
    "Fast" {
      if ($srcFps -gt 50) {
        if ($motionVeryLow) {
          $list.Add(30)
          if ($detailLowish -and $duration -le 45 -and $totalKbps -ge 1500) {
            $list.Add($roundedSrc)
          }
          if ($totalKbps -lt 500) { $list.Add(24) }
        }
        else {
          $list.Add($roundedSrc)
          if ($totalKbps -lt 900) { $list.Add(30) }
          if ($totalKbps -lt 500) { $list.Add(24) }
        }
      }
      elseif ($srcFps -gt 30.5) {
        if ($motionVeryLow -and $totalKbps -lt 700) {
          $list.Add(30)
          if ($totalKbps -lt 450) { $list.Add(24) }
        }
        else {
          $list.Add($roundedSrc)
          if ($totalKbps -lt 650) { $list.Add(30) }
          if ($totalKbps -lt 450) { $list.Add(24) }
        }
      }
      else {
        $list.Add($roundedSrc)
        if ($roundedSrc -gt 24 -and $totalKbps -lt 650) { $list.Add(24) }
      }
    }

    "Balanced" {
      if ($srcFps -gt 50) {
        if (-not $motionVeryLow -or $totalKbps -ge 1250 -or ($detailLowish -and $duration -le 45 -and $totalKbps -ge 950)) {
          $list.Add($roundedSrc)
        }
        $list.Add(30)
        if ($totalKbps -lt 330) { $list.Add(24) }
      }
      elseif ($srcFps -gt 30.5) {
        if (-not $motionVeryLow -or ($duration -le 90 -and $totalKbps -ge 900)) {
          $list.Add($roundedSrc)
        }
        $list.Add(30)
        if ($totalKbps -lt 300) { $list.Add(24) }
      }
      else {
        $list.Add($roundedSrc)
        if ($roundedSrc -gt 24 -and $totalKbps -lt 700) { $list.Add(24) }
      }
    }

    "ExtraQuality" {
      if ($srcFps -gt 50) {
        if (-not $motionLowish -or $totalKbps -ge 1100) { $list.Add($roundedSrc) }
        $list.Add(30)
        if ($totalKbps -lt 420) { $list.Add(24) }
      }
      elseif ($srcFps -gt 30.5) {
        if (-not $motionVeryLow -or $totalKbps -ge 850) { $list.Add($roundedSrc) }
        $list.Add(30)
        if ($totalKbps -lt 360) { $list.Add(24) }
      }
      else {
        $list.Add($roundedSrc)
        if ($roundedSrc -gt 24 -and $totalKbps -lt 650) { $list.Add(24) }
      }
    }
  }

  return $list | Select-Object -Unique
}

function Get-AudioPlanCandidates {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][double]$TotalKbps,
    [Parameter(Mandatory = $true)][double]$Duration,
    [Parameter(Mandatory = $true)][string]$ProbeBucket
  )

  $plans = New-Object System.Collections.Generic.List[object]

  if (-not $Info.HasAudio) {
    $plans.Add([PSCustomObject]@{
        Mode           = "mute"
        Kbps           = $null
        Label          = "no audio"
        EstimatedBytes = 0L
        Rank           = 100
      })
    return $plans
  }

  $channels = [math]::Max(1, $Info.AudioChannels)
  $isStereo = ($channels -le 2)

  $baseList = switch ($Mode) {
    "Fast" {
      if ($TotalKbps -lt 220)      { @(48, 40) }
      elseif ($TotalKbps -lt 300)  { @(56, 48, 40) }
      elseif ($TotalKbps -lt 420)  { @(64, 56, 48) }
      elseif ($TotalKbps -lt 650)  { @(80, 64, 56) }
      else                         { @(96, 80, 64) }
    }

    "Balanced" {
      switch ($ProbeBucket) {
        "VeryLow" {
          if ($TotalKbps -lt 220)      { @(56, 48, 40) }
          elseif ($TotalKbps -lt 300)  { @(72, 64, 56, 48) }
          elseif ($TotalKbps -lt 420)  { @(80, 72, 64, 56) }
          elseif ($TotalKbps -lt 650)  { @(96, 80, 72, 64) }
          else                         { @(128, 96, 80, 72) }
        }
        "Low" {
          if ($TotalKbps -lt 220)      { @(56, 48, 40) }
          elseif ($TotalKbps -lt 300)  { @(72, 64, 56, 48) }
          elseif ($TotalKbps -lt 420)  { @(80, 72, 64, 56) }
          elseif ($TotalKbps -lt 650)  { @(80, 72, 64, 56) }
          else                         { @(96, 80, 72, 64) }
        }
        "Medium" {
          if ($TotalKbps -lt 220)      { @(48, 40) }
          elseif ($TotalKbps -lt 300)  { @(64, 56, 48) }
          elseif ($TotalKbps -lt 420)  { @(72, 64, 56, 48) }
          elseif ($TotalKbps -lt 650)  { @(80, 64, 56, 48) }
          else                         { @(96, 80, 64) }
        }
        default {
          if ($TotalKbps -lt 220)      { @(48, 40) }
          elseif ($TotalKbps -lt 300)  { @(56, 48, 40) }
          elseif ($TotalKbps -lt 420)  { @(64, 56, 48) }
          elseif ($TotalKbps -lt 650)  { @(72, 64, 56, 48) }
          else                         { @(80, 64, 56) }
        }
      }
    }

    "ExtraQuality" {
      switch ($ProbeBucket) {
        "VeryLow" {
          if ($TotalKbps -lt 220)      { @(56, 48, 40) }
          elseif ($TotalKbps -lt 300)  { @(72, 64, 56, 48) }
          elseif ($TotalKbps -lt 420)  { @(80, 72, 64, 56) }
          elseif ($TotalKbps -lt 650)  { @(96, 80, 72, 64) }
          else                         { @(128, 96, 80, 72) }
        }
        "Low" {
          if ($TotalKbps -lt 220)      { @(56, 48, 40) }
          elseif ($TotalKbps -lt 300)  { @(72, 64, 56, 48) }
          elseif ($TotalKbps -lt 420)  { @(80, 72, 64, 56) }
          elseif ($TotalKbps -lt 650)  { @(96, 80, 72, 64) }
          else                         { @(128, 96, 80, 72) }
        }
        default {
          if ($TotalKbps -lt 220)      { @(48, 40) }
          elseif ($TotalKbps -lt 300)  { @(64, 56, 48) }
          elseif ($TotalKbps -lt 420)  { @(72, 64, 56, 48) }
          elseif ($TotalKbps -lt 650)  { @(80, 72, 64, 56) }
          else                         { @(128, 96, 80, 64) }
        }
      }
    }
  }

  if (-not $isStereo) {
    $baseList = $baseList | ForEach-Object { [math]::Max($_, 96) } | Select-Object -Unique
  }

  if ($Mode -eq "Balanced" -and $isStereo -and $Duration -le 90 -and $TotalKbps -ge 950) {
    $baseList = @(128) + $baseList
  }

  if ($channels -ge 6) {
    $baseList = $baseList | ForEach-Object { [math]::Max($_, 128) } | Select-Object -Unique
  }

  $rank = 100

  if ($Info.AudioCodec -in $CodecProfile.CopyableAudioCodecs -and $Info.AudioBitrateKbps) {
    foreach ($kbps in $baseList) {
      if ($Info.AudioBitrateKbps -le $kbps) {
        $estimatedBytes = [long][math]::Floor(($Info.AudioBitrateKbps * 1000.0 / 8.0) * $Duration)
        $plans.Add([PSCustomObject]@{
            Mode           = "copy"
            Kbps           = $null
            Codec          = $Info.AudioCodec
            Label          = ("copy original audio ({0}k)" -f $Info.AudioBitrateKbps)
            EstimatedBytes = $estimatedBytes
            Rank           = $rank
          })
        break
      }
    }
  }

  foreach ($kbps in $baseList) {
    $estimatedBytes = [long][math]::Floor(($kbps * 1000.0 / 8.0) * $Duration)
    $plans.Add([PSCustomObject]@{
        Mode           = $CodecProfile.DefaultAudioCodec
        Kbps           = $kbps
        Codec          = $CodecProfile.DefaultAudioCodec
        Label          = ("{0} {1}k" -f (Get-AudioCodecLabel -AudioCodec $CodecProfile.DefaultAudioCodec), $kbps)
        EstimatedBytes = $estimatedBytes
        Rank           = $rank
      })
    $rank--
  }

  if ($Mode -eq "Fast" -or $TotalKbps -lt 175) {
    $plans.Add([PSCustomObject]@{
        Mode           = "mute"
        Kbps           = $null
        Codec          = ""
        Label          = "mute"
        EstimatedBytes = 0L
        Rank           = 1
      })
  }

  return $plans | Select-Object -Unique
}

function Get-SampleOffsets($duration, $sampleLength, $maxSamples) {
  if ($duration -le ($sampleLength + 2)) {
    return @(0.0)
  }

  $usableEnd = [math]::Max(0.0, $duration - $sampleLength - 0.5)
  $fractions = @(
    switch ($maxSamples) {
      1 { 0.50 }
      2 { 0.30; 0.70 }
      3 { 0.18; 0.50; 0.82 }
      4 { 0.12; 0.37; 0.63; 0.88 }
      default { 0.18; 0.50; 0.82 }
    }
  )

  $count = [math]::Min($fractions.Length, $maxSamples)
  $offsets = foreach ($f in @($fractions[0..($count - 1)])) {
    [math]::Round($usableEnd * $f, 3)
  }

  return @($offsets | Select-Object -Unique)
}

function Set-InfoPlanningContext {
  param(
    [Parameter(Mandatory = $true)]$Info,
    $CropResult
  )

  $cropApplied = [bool](Get-ObjectPropertyValue -Object $CropResult -Name "Applied" -DefaultValue $false)
  $planningWidth = if ($cropApplied) { [int]$CropResult.Width } else { [int]$Info.Width }
  $planningHeight = if ($cropApplied) { [int]$CropResult.Height } else { [int]$Info.Height }
  $cropFilter = if ($cropApplied) { [string]$CropResult.Filter } else { "" }
  $cropSummary = if ($cropApplied) {
    ("{0}x{1}+{2}+{3} ({4:P1} removed)" -f $CropResult.Width, $CropResult.Height, $CropResult.X, $CropResult.Y, $CropResult.AreaRemovedRatio)
  }
  else {
    [string](Get-ObjectPropertyValue -Object $CropResult -Name "Summary" -DefaultValue "none")
  }

  $Info | Add-Member -NotePropertyName PlanningWidth -NotePropertyValue $planningWidth -Force
  $Info | Add-Member -NotePropertyName PlanningHeight -NotePropertyValue $planningHeight -Force
  $Info | Add-Member -NotePropertyName CropApplied -NotePropertyValue $cropApplied -Force
  $Info | Add-Member -NotePropertyName CropFilter -NotePropertyValue $cropFilter -Force
  $Info | Add-Member -NotePropertyName CropSummary -NotePropertyValue $cropSummary -Force
  $Info | Add-Member -NotePropertyName CropAreaRemovedRatio -NotePropertyValue ([double](Get-ObjectPropertyValue -Object $CropResult -Name "AreaRemovedRatio" -DefaultValue 0.0)) -Force
  $Info | Add-Member -NotePropertyName CropSamples -NotePropertyValue @((Get-ObjectPropertyValue -Object $CropResult -Name "Samples" -DefaultValue @())) -Force

  return $Info
}

function Invoke-CropDetectSample {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][double]$Offset,
    [Parameter(Mandatory = $true)][int]$SampleSeconds
  )

  $args = @(
    "-hide_banner",
    "-ss", "$Offset",
    "-t", "$SampleSeconds",
    "-i", $InputPath,
    "-vf", "cropdetect=limit=24:round=2:reset=0",
    "-an",
    "-f", "null",
    "NUL"
  )

  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args $args -AllowFailure
  if ($capture.ExitCode -ne 0) { return $null }

  $matches = [regex]::Matches($capture.Output, 'crop=(?<w>\d+):(?<h>\d+):(?<x>-?\d+):(?<y>-?\d+)')
  if ($matches.Count -eq 0) { return $null }

  $match = $matches[$matches.Count - 1]
  return [PSCustomObject]@{
    Offset = $Offset
    Width  = [int]$match.Groups["w"].Value
    Height = [int]$match.Groups["h"].Value
    X      = [int]$match.Groups["x"].Value
    Y      = [int]$match.Groups["y"].Value
  }
}

function Invoke-CropDetect {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$CropMode,
    [int]$SampleSeconds = 3,
    [int]$MaxSamples = 3
  )

  $defaultResult = [PSCustomObject]@{
    Applied          = $false
    Width            = [int]$Info.Width
    Height           = [int]$Info.Height
    X                = 0
    Y                = 0
    Filter           = ""
    Summary          = if ($CropMode -eq "Off") { "disabled" } else { "none" }
    Samples          = @()
    AreaRemovedRatio = 0.0
  }

  if ($CropMode -eq "Off") {
    return $defaultResult
  }

  $offsets = Get-SampleOffsets -duration $Info.Duration -sampleLength $SampleSeconds -maxSamples $MaxSamples
  $samples = New-Object System.Collections.Generic.List[object]

  foreach ($offset in $offsets) {
    $sample = Invoke-CropDetectSample -Info $Info -InputPath $InputPath -Offset $offset -SampleSeconds $SampleSeconds
    if ($null -eq $sample) {
      return $defaultResult
    }
    [void]$samples.Add($sample)
  }

  if ($samples.Count -eq 0) {
    return $defaultResult
  }

  $widthSpread = (($samples | Measure-Object -Property Width -Maximum).Maximum) - (($samples | Measure-Object -Property Width -Minimum).Minimum)
  $heightSpread = (($samples | Measure-Object -Property Height -Maximum).Maximum) - (($samples | Measure-Object -Property Height -Minimum).Minimum)
  $xSpread = (($samples | Measure-Object -Property X -Maximum).Maximum) - (($samples | Measure-Object -Property X -Minimum).Minimum)
  $ySpread = (($samples | Measure-Object -Property Y -Maximum).Maximum) - (($samples | Measure-Object -Property Y -Minimum).Minimum)

  if ($widthSpread -gt 4 -or $heightSpread -gt 4 -or $xSpread -gt 4 -or $ySpread -gt 4) {
    $defaultResult.Summary = "unstable"
    $defaultResult.Samples = $samples.ToArray()
    return $defaultResult
  }

  $cropWidth = [int][math]::Round(($samples | Measure-Object -Property Width -Average).Average / 2.0) * 2
  $cropHeight = [int][math]::Round(($samples | Measure-Object -Property Height -Average).Average / 2.0) * 2
  $cropX = [int][math]::Round(($samples | Measure-Object -Property X -Average).Average / 2.0) * 2
  $cropY = [int][math]::Round(($samples | Measure-Object -Property Y -Average).Average / 2.0) * 2
  $cropWidth = [int][math]::Min($Info.Width, [math]::Max(2, $cropWidth))
  $cropHeight = [int][math]::Min($Info.Height, [math]::Max(2, $cropHeight))
  $cropX = [int][math]::Max(0, $cropX)
  $cropY = [int][math]::Max(0, $cropY)

  $rightRemoved = [int][math]::Max(0, $Info.Width - ($cropWidth + $cropX))
  $bottomRemoved = [int][math]::Max(0, $Info.Height - ($cropHeight + $cropY))
  $maxBorderRemoved = (@($cropX, $cropY, $rightRemoved, $bottomRemoved) | Measure-Object -Maximum).Maximum
  $removedAreaRatio = 1.0 - (([double]$cropWidth * [double]$cropHeight) / ([double]$Info.Width * [double]$Info.Height))

  if ($removedAreaRatio -lt 0.04 -and $maxBorderRemoved -lt 6) {
    $defaultResult.Summary = "none"
    $defaultResult.Samples = $samples.ToArray()
    return $defaultResult
  }

  return [PSCustomObject]@{
    Applied          = $true
    Width            = $cropWidth
    Height           = $cropHeight
    X                = $cropX
    Y                = $cropY
    Filter           = ("crop={0}:{1}:{2}:{3}" -f $cropWidth, $cropHeight, $cropX, $cropY)
    Summary          = ("{0}x{1}+{2}+{3}" -f $cropWidth, $cropHeight, $cropX, $cropY)
    Samples          = $samples.ToArray()
    AreaRemovedRatio = $removedAreaRatio
  }
}

function Invoke-CrfProbeSeries {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][double[]]$Offsets,
    [Parameter(Mandatory = $true)][int]$SampleSeconds,
    [Parameter(Mandatory = $true)][int]$ProbeWidth,
    [Parameter(Mandatory = $true)][int]$ProbeFps,
    [Parameter(Mandatory = $true)][int]$ProbeCrf,
    [Parameter(Mandatory = $true)][string]$ProbePreset,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $results = New-Object System.Collections.Generic.List[object]
  $idx = 0
  $strategy = Get-ModeStrategy -Mode $Mode -Duration $Info.Duration

  foreach ($offset in $Offsets) {
    $idx++
    $outPath = Join-Path $TempDir ("probe_{0}_{1}.mp4" -f $Name, $idx)
    $vfArg = Build-Vf -Info $Info -TargetWidth $ProbeWidth -TargetFps $ProbeFps -ScaleFlags "bicubic"

    $args = @("-y", "-ss", "$offset", "-t", "$SampleSeconds", "-i", $InputPath)
    if (-not [string]::IsNullOrWhiteSpace($vfArg)) { $args += @("-vf", $vfArg) }
    $args += @(
      "-an",
      "-c:v", "libx264",
      "-preset", $ProbePreset,
      "-crf", "$ProbeCrf",
      $outPath
    )

    [void](Invoke-Tool -Exe "ffmpeg" -Args $args)

    $bytes = (Get-Item $outPath).Length
    $kbps = (($bytes * 8.0) / $SampleSeconds) / 1000.0
    $results.Add([PSCustomObject]@{
        Offset = $offset
        Bytes  = $bytes
        Kbps   = $kbps
      })

    if ($results.Count -ge 2 -and $null -ne $strategy.ProbeEarlyStopSpreadThreshold) {
      $spreadRatio = Get-SpreadRatio -Values ($results | ForEach-Object { $_.Kbps })
      if ($spreadRatio -le [double]$strategy.ProbeEarlyStopSpreadThreshold) {
        Remove-Item $outPath -Force -ErrorAction SilentlyContinue
        break
      }
    }

    Remove-Item $outPath -Force -ErrorAction SilentlyContinue
  }

  if ($results.Count -eq 0) {
    throw "Complexity probe produced no samples."
  }

  $avgKbps = ($results | Measure-Object -Property Kbps -Average).Average
  $maxKbps = ($results | Measure-Object -Property Kbps -Maximum).Maximum
  $p95ish = ($avgKbps * 0.65) + ($maxKbps * 0.35)

  return [PSCustomObject]@{
    Name         = $Name
    ProbeWidth   = $ProbeWidth
    ProbeFps     = $ProbeFps
    ProbeCrf     = $ProbeCrf
    ProbePreset  = $ProbePreset
    AvgKbps      = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $avgKbps)), [Globalization.CultureInfo]::InvariantCulture)
    PeakishKbps  = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $p95ish)), [Globalization.CultureInfo]::InvariantCulture)
    BitsPerFrame = if ($ProbeFps -gt 0) {
      [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F2}", (($avgKbps * 1000.0) / $ProbeFps))), [Globalization.CultureInfo]::InvariantCulture)
    }
    else {
      0.0
    }
    Samples      = $results
  }
}

function Get-ContentBucketRank($bucket) {
  switch ($bucket) {
    "VeryLow"  { return 1 }
    "Low"      { return 2 }
    "Medium"   { return 3 }
    "High"     { return 4 }
    "VeryHigh" { return 5 }
    default    { return 0 }
  }
}

function Get-DetailBucket {
  param(
    [Parameter(Mandatory = $true)][double]$PeakishKbps
  )

  $bucket = if ($PeakishKbps -lt 120) {
    "VeryLow"
  }
  elseif ($PeakishKbps -lt 190) {
    "Low"
  }
  elseif ($PeakishKbps -lt 300) {
    "Medium"
  }
  elseif ($PeakishKbps -lt 430) {
    "High"
  }
  else {
    "VeryHigh"
  }

  return $bucket
}

function Get-MotionBucket {
  param(
    [Parameter(Mandatory = $true)][double]$MotionRatio,
    [Parameter(Mandatory = $true)][double]$NormalizedMotion,
    [Parameter(Mandatory = $true)][double]$SourceFps,
    [Parameter(Mandatory = $true)][string]$FallbackBucket
  )

  if ($SourceFps -le 30.5) {
    return $FallbackBucket
  }

  $bucket = if ($SourceFps -gt 50) {
    if ($MotionRatio -lt 1.10) {
      "VeryLow"
    }
    elseif ($MotionRatio -lt 1.22) {
      "Low"
    }
    elseif ($MotionRatio -lt 1.40) {
      "Medium"
    }
    elseif ($MotionRatio -lt 1.62) {
      "High"
    }
    else {
      "VeryHigh"
    }
  }
  else {
    if ($MotionRatio -lt 1.04) {
      "VeryLow"
    }
    elseif ($MotionRatio -lt 1.12) {
      "Low"
    }
    elseif ($MotionRatio -lt 1.22) {
      "Medium"
    }
    elseif ($MotionRatio -lt 1.35) {
      "High"
    }
    else {
      "VeryHigh"
    }
  }

  if ($NormalizedMotion -lt 0.46 -and $bucket -notin @("VeryLow", "Low")) {
    return "VeryLow"
  }

  return $bucket
}

function Invoke-ComplexityProbe {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Mode,
    [int]$SampleSeconds = 6,
    [int]$MaxSamples = 0
  )

  $strategy = Get-ModeStrategy -Mode $Mode -Duration $Info.Duration
  if ($MaxSamples -le 0) {
    $MaxSamples = [int]$strategy.ProbeMaxSamples
  }

  $planningWidth = Get-PlanningWidth -Info $Info
  $detailProbeWidth = if ($planningWidth -ge 1280) { 480 } elseif ($planningWidth -ge 854) { 426 } else { [math]::Min($planningWidth, 360) }
  $detailProbeFps = if ($Info.Fps -gt 30.5) { 24 } else { [int][math]::Max(12, [math]::Round($Info.Fps)) }

  $probeCrf = switch ($Mode) {
    "Fast"         { 32 }
    "Balanced"     { 30 }
    "ExtraQuality" { 28 }
  }

  $probePreset = switch ($Mode) {
    "Fast"         { "superfast" }
    "Balanced"     { "veryfast" }
    "ExtraQuality" { "fast" }
  }

  $offsets = Get-SampleOffsets -duration $Info.Duration -sampleLength $SampleSeconds -maxSamples $MaxSamples

  $detailProbe = Invoke-CrfProbeSeries `
    -Info $Info `
    -InputPath $InputPath `
    -TempDir $TempDir `
    -Mode $Mode `
    -Offsets $offsets `
    -SampleSeconds $SampleSeconds `
    -ProbeWidth $detailProbeWidth `
    -ProbeFps $detailProbeFps `
    -ProbeCrf $probeCrf `
    -ProbePreset $probePreset `
    -Name "detail"

  $detailBucket = Get-DetailBucket -PeakishKbps $detailProbe.PeakishKbps

  $motionProbe = $null
  $motionNormalized = 0.0
  $motionRatio = 1.0

  if ($Info.Fps -gt ($detailProbeFps + 0.5)) {
    $motionProbeFps = [int][math]::Min(60, [math]::Round($Info.Fps))
    $motionProbe = Invoke-CrfProbeSeries `
      -Info $Info `
      -InputPath $InputPath `
      -TempDir $TempDir `
      -Mode $Mode `
      -Offsets $offsets `
      -SampleSeconds $SampleSeconds `
      -ProbeWidth $detailProbeWidth `
      -ProbeFps $motionProbeFps `
      -ProbeCrf $probeCrf `
      -ProbePreset $probePreset `
      -Name "motion"

    $motionRatio = $motionProbe.AvgKbps / [math]::Max(1.0, $detailProbe.AvgKbps)
    $fpsRatio = [double]$motionProbeFps / [double][math]::Max(1, $detailProbeFps)
    $motionNormalized = $motionRatio / [math]::Max(1.0, $fpsRatio)
  }
  else {
    $motionProbe = $detailProbe
    $motionNormalized = 0.75
  }

  $motionBucket = Get-MotionBucket -MotionRatio $motionRatio -NormalizedMotion $motionNormalized -SourceFps $Info.Fps -FallbackBucket $detailBucket
  $overallBucket = if ((Get-ContentBucketRank -bucket $motionBucket) -gt (Get-ContentBucketRank -bucket $detailBucket)) {
    $motionBucket
  }
  else {
    $detailBucket
  }

  return [PSCustomObject]@{
    ProbeWidth        = $detailProbe.ProbeWidth
    ProbeFps          = $detailProbe.ProbeFps
    ProbeCrf          = $detailProbe.ProbeCrf
    AvgKbps           = $detailProbe.AvgKbps
    PeakishKbps       = $detailProbe.PeakishKbps
    Bucket            = $overallBucket
    DetailProbe       = $detailProbe
    MotionProbe       = $motionProbe
    DetailBucket      = $detailBucket
    MotionBucket      = $motionBucket
    MotionRatio       = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $motionRatio)), [Globalization.CultureInfo]::InvariantCulture)
    MotionNormalized  = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $motionNormalized)), [Globalization.CultureInfo]::InvariantCulture)
    DetailSpreadRatio = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", (Get-SpreadRatio -Values ($detailProbe.Samples | ForEach-Object { $_.Kbps })))), [Globalization.CultureInfo]::InvariantCulture)
    MotionSpreadRatio = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", (Get-SpreadRatio -Values ($motionProbe.Samples | ForEach-Object { $_.Kbps })))), [Globalization.CultureInfo]::InvariantCulture)
    ProbeSamplesUsed  = [int]$detailProbe.Samples.Count
    Samples           = $detailProbe.Samples
  }
}

function Get-ReferenceBpppfForComplexity($bucket, $mode) {
  if ($mode -eq "Fast") {
    $fastBase = switch ($bucket) {
        "VeryLow"  { 0.0100 }
        "Low"      { 0.0125 }
        "Medium"   { 0.0160 }
        "High"     { 0.0200 }
        "VeryHigh" { 0.0240 }
        default    { 0.0160 }
      }
    return $fastBase
  }

  $base = switch ($bucket) {
    "VeryLow"  { 0.0185 }
    "Low"      { 0.0155 }
    "Medium"   { 0.0115 }
    "High"     { 0.0095 }
    "VeryHigh" { 0.0080 }
    default    { 0.0115 }
  }

  switch ($mode) {
    "Balanced"     { return $base }
    "ExtraQuality" { return ($base + 0.0008) }
  }
}

function Get-SourceToProbeComplexityRatio {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe
  )

  $sourceVideoKbps = [double](Get-ObjectPropertyValue -Object $Info -Name "VideoBitrateKbps" -DefaultValue 0)
  $probeAvgKbps = [double](Get-ObjectPropertyValue -Object $Probe.DetailProbe -Name "AvgKbps" -DefaultValue 0.0)

  if ($sourceVideoKbps -le 0 -or $probeAvgKbps -le 0.0) {
    return 0.0
  }

  return ($sourceVideoKbps / $probeAvgKbps)
}

function Get-ResolutionPlanningProfile {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $baseTargetBpppf = Get-ReferenceBpppfForComplexity -bucket $Probe.DetailBucket -mode $Mode
  $planningWidth = Get-PlanningWidth -Info $Info
  $sourceToProbeRatio = Get-SourceToProbeComplexityRatio -Info $Info -Probe $Probe
  $detailPeakishKbps = [double](Get-ObjectPropertyValue -Object $Probe.DetailProbe -Name "PeakishKbps" -DefaultValue 0.0)

  # Preserve more spatial detail on extremely compressible, edge-sensitive 60 fps captures.
  $preferResolutionRetention = (
    $Mode -ne "Fast" -and
    $planningWidth -ge 960 -and
    $Info.Fps -gt 50 -and
    $Probe.DetailBucket -eq "VeryLow" -and
    $detailPeakishKbps -le 70.0 -and
    $Probe.MotionNormalized -le 0.55 -and
    (
      $sourceToProbeRatio -ge 80.0 -or
      (
        [double](Get-ObjectPropertyValue -Object $Info -Name "VideoBitrateKbps" -DefaultValue 0) -ge 6000.0 -and
        $detailPeakishKbps -le 55.0
      )
    )
  )

  $retentionFactor = if ($preferResolutionRetention) {
    switch ($Mode) {
      "Balanced"     { 0.42 }
      "ExtraQuality" { 0.38 }
      default        { 1.0 }
    }
  }
  else {
    1.0
  }

  $targetBpppf = $baseTargetBpppf * $retentionFactor

  return [PSCustomObject]@{
    BaseTargetBpppf           = [double]$baseTargetBpppf
    TargetBpppf               = [double]$targetBpppf
    PreferResolutionRetention = [bool]$preferResolutionRetention
    RetentionFactor           = [double]$retentionFactor
    SourceToProbeRatio        = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $sourceToProbeRatio)), [Globalization.CultureInfo]::InvariantCulture)
    BiasLabel                 = if ($preferResolutionRetention) { "retain-resolution" } else { "standard" }
  }
}

function Get-WidthPlanCandidates {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][int]$TargetFps,
    [Parameter(Mandatory = $true)][int]$VideoKbps,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $planningWidth = Get-PlanningWidth -Info $Info
  $planningHeight = Get-PlanningHeight -Info $Info
  $resolutionProfile = Get-ResolutionPlanningProfile -Info $Info -Probe $Probe -Mode $Mode
  $targetBpppf = $resolutionProfile.TargetBpppf
  $expectedWidth = Get-ExpectedWidth -srcWidth $planningWidth -srcHeight $planningHeight -videoKbps $VideoKbps -targetFps $TargetFps -targetBpppf $targetBpppf
  $ladderWidths = Get-ResolutionCandidates -srcWidth $planningWidth | Sort-Object -Descending
  $closestLadder = $ladderWidths | Sort-Object { [math]::Abs($_ - $expectedWidth) } | Select-Object -First 1
  $justBelow = $ladderWidths | Where-Object { $_ -lt $expectedWidth } | Sort-Object -Descending | Select-Object -First 1
  $justAbove = $ladderWidths | Where-Object { $_ -gt $expectedWidth } | Sort-Object | Select-Object -First 1
  $localFactors = @(0.85, 0.92, 1.00, 1.08, 1.15)
  $widthOrigins = @{}
  $scored = New-Object System.Collections.Generic.List[object]

  foreach ($width in @($closestLadder, $justBelow, $justAbove) | Where-Object { $null -ne $_ } | Select-Object -Unique) {
    $widthOrigins[[int]$width] = Get-CombinedWidthOrigin -existingOrigin $widthOrigins[[int]$width] -newOrigin "ladder"
  }

  foreach ($factor in $localFactors) {
    $width = Get-SnappedWidth -width ($expectedWidth * $factor) -maxWidth $planningWidth
    if ($width -gt 0) {
      $widthOrigins[[int]$width] = Get-CombinedWidthOrigin -existingOrigin $widthOrigins[[int]$width] -newOrigin "local"
    }
  }

  foreach ($width in ($widthOrigins.Keys | Sort-Object {[int]$_} -Descending)) {
    $w = [int]$width
    $h = Get-AspectHeight -srcWidth $planningWidth -srcHeight $planningHeight -targetWidth $w
    $bpppf = Get-Bpppf -videoKbps $VideoKbps -width $w -height $h -fps $TargetFps
    $widthRatio = [double]$w / [double]$expectedWidth
    $distancePenalty = [math]::Abs([math]::Log($widthRatio)) * 140.0
    $overshootPenalty = if ($widthRatio -gt 1.0) { ($widthRatio - 1.0) * 120.0 } else { 0.0 }
    $undershootPenalty = if ($widthRatio -lt 0.80) { (0.80 - $widthRatio) * 30.0 } else { 0.0 }
    $bpppfPenalty = if ($bpppf -lt $targetBpppf) { ($targetBpppf - $bpppf) * 5000.0 } else { 0.0 }
    $score = 1000.0 - $distancePenalty - $overshootPenalty - $undershootPenalty - $bpppfPenalty

    $scored.Add([PSCustomObject]@{
        Width         = $w
        Height        = $h
        Bpppf         = $bpppf
        Score         = $score
        TargetBpppf   = $targetBpppf
        ExpectedWidth = $expectedWidth
        WidthRatio    = $widthRatio
        Origin        = [string]$widthOrigins[$w]
        NearTarget    = ($widthRatio -ge 0.82 -and $widthRatio -le 1.18)
      })
  }

  $topCount = switch ($Mode) {
    "Fast"         { 3 }
    "Balanced"     { 6 }
    "ExtraQuality" { 8 }
  }
  $ordered = $scored | Sort-Object Score -Descending
  $bestLocal = $ordered | Where-Object { $_.Origin -match "local" } | Select-Object -First 1
  $bestLadder = $ordered | Where-Object { $_.Origin -match "ladder" } | Select-Object -First 1
  $selected = New-Object System.Collections.Generic.List[object]
  $seenWidths = New-Object System.Collections.Generic.HashSet[int]

  foreach ($candidate in @($bestLocal, $bestLadder) + @($ordered | Select-Object -First $topCount)) {
    if ($null -eq $candidate) { continue }
    if ($seenWidths.Add([int]$candidate.Width)) {
      [void]$selected.Add($candidate)
    }
  }

  return @($selected | Sort-Object Width -Descending)
}

function Get-MuxReserveBytes($targetBytes, $mode) {
  switch ($mode) {
    "Fast"         { return [long][math]::Floor($targetBytes * 0.012) }
    "Balanced"     { return [long][math]::Floor($targetBytes * 0.006) }
    "ExtraQuality" { return [long][math]::Floor($targetBytes * 0.005) }
  }
}

function Get-AutoX264Params($mode, $totalBudgetKbps) {
  if ($mode -in @("Balanced", "ExtraQuality") -and $totalBudgetKbps -lt 1200) {
    return "aq-mode=3:aq-strength=0.85:deblock=-1,-1"
  }

  return ""
}

function Test-ShouldAddDenoisePlan($mode, $detailBucket, $totalBudgetKbps, $bpppf, $profile) {
  if ($profile -eq "Off" -or $mode -notin @("Balanced", "ExtraQuality")) { return $false }
  if ((Get-ContentBucketRank -bucket $detailBucket) -lt (Get-ContentBucketRank -bucket "Medium")) { return $false }
  if ($profile -eq "Mild") { return $true }
  return ($totalBudgetKbps -lt 500 -or $bpppf -lt 0.02)
}

function New-EncodePlan {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height,
    [Parameter(Mandatory = $true)][int]$Fps,
    [Parameter(Mandatory = $true)]$AudioPlan,
    [string]$WidthOrigin = "unknown",
    [switch]$UseDenoise
  )

  $muxReserve = Get-MuxReserveBytes -targetBytes $TargetBytes -mode $Mode
  $usableVideoBytes = $TargetBytes - $AudioPlan.EstimatedBytes - $muxReserve
  if ($usableVideoBytes -lt 25000) { return $null }

  $videoKbps = [int][math]::Floor((($usableVideoBytes * 8.0) / $Info.Duration) / 1000.0)
  if ($videoKbps -lt 40) { return $null }

  $vf = Build-Vf -Info $Info -TargetWidth $Width -TargetFps $Fps -UseDenoise:$UseDenoise
  $codecEfficiency = Get-CodecEfficiencyMultiplier -VideoCodec $CodecProfile.VideoCodec
  $effectiveVideoKbps = [double]$videoKbps / [double][math]::Max(0.001, $codecEfficiency)
  $bpppf = Get-Bpppf -videoKbps $effectiveVideoKbps -width $Width -height $Height -fps $Fps
  $totalBudgetKbps = (($TargetBytes * 8.0) / $Info.Duration) / 1000.0
  $resolutionProfile = Get-ResolutionPlanningProfile -Info $Info -Probe $Probe -Mode $Mode
  $targetBpppf = $resolutionProfile.TargetBpppf
  $planningWidth = Get-PlanningWidth -Info $Info
  $planningHeight = Get-PlanningHeight -Info $Info
  $expectedWidth = Get-ExpectedWidth -srcWidth $planningWidth -srcHeight $planningHeight -videoKbps $effectiveVideoKbps -targetFps $Fps -targetBpppf $targetBpppf
  $widthRatio = [double]$Width / [double]$expectedWidth
  $widthFitPenalty = [int]([math]::Abs([math]::Log($widthRatio)) * 5000.0)
  $overshootPenalty = if ($widthRatio -gt 1.0) { [int](($widthRatio - 1.0) * 4500.0) } else { 0 }
  $highFpsRetentionBoost = 0
  if (
    $Mode -eq "Balanced" -and
    $Info.Fps -gt 50 -and
    $Fps -gt 30 -and
    $Info.Duration -le 90 -and
    $Probe.MotionBucket -notin @("VeryLow", "Low") -and
    $totalBudgetKbps -ge 900
  ) {
    $highFpsRetentionBoost = $Fps * 300
  }
  $bpppfDeficitPenalty = if ($bpppf -lt $targetBpppf) { [int](($targetBpppf - $bpppf) * 200000) } else { 0 }
  $videoPrivateArgs = if ($CodecProfile.VideoCodec -eq "x264") { Get-AutoX264Params -mode $Mode -totalBudgetKbps $totalBudgetKbps } else { "" }
  $preprocessLabel = if ($UseDenoise) { "mild-denoise" } else { "none" }
  $crf = Get-RateControlSeedCrf -VideoCodec $CodecProfile.VideoCodec -Mode $Mode
  $fpsTier = Get-FpsTier -SourceFps $Info.Fps -TargetFps $Fps
  $widthTier = Get-WidthTier -WidthRatio $widthRatio
  $audioTier = Get-AudioTier -AudioPlan $AudioPlan

  $score = switch ($Mode) {
    "Fast" {
      40000 + ($Fps * 220) + ($AudioPlan.Rank * 2) + ([int]($bpppf * 40000)) - ($widthFitPenalty * 2) - ($overshootPenalty * 2)
    }
    "Balanced" {
      50000 + ($Fps * 8) + ($AudioPlan.Rank * 6) + ([int]($bpppf * 70000)) + $highFpsRetentionBoost - $bpppfDeficitPenalty - $widthFitPenalty - $overshootPenalty
    }
    "ExtraQuality" {
      56000 + ($Fps * 16) + ($AudioPlan.Rank * 8) + ([int]($bpppf * 90000)) - [int]($widthFitPenalty * 0.8) - [int]($overshootPenalty * 0.8)
    }
  }

  return [PSCustomObject]@{
    Width       = $Width
    Height      = $Height
    Fps         = $Fps
    VFilter     = $vf
    VideoKbps   = $videoKbps
    EffectiveVideoKbps = $effectiveVideoKbps
    Crf         = $crf
    AudioPlan   = $AudioPlan
    AudioCodec  = if ($AudioPlan.Codec) { $AudioPlan.Codec } else { $CodecProfile.DefaultAudioCodec }
    TargetBytes = $TargetBytes
    Preset      = $Preset
    Mode        = $Mode
    CodecProfile = $CodecProfile
    OutputExtension = $CodecProfile.Extension
    Bpppf       = $bpppf
    TargetBpppf = $targetBpppf
    ExpectedWidth = $expectedWidth
    WidthRatio    = $widthRatio
    DetailBucket = $Probe.DetailBucket
    MotionBucket = $Probe.MotionBucket
    DurationSeconds = $Info.Duration
    Score       = $score
    TotalBudgetKbps = $totalBudgetKbps
    WidthOrigin = $WidthOrigin
    FpsTier     = $fpsTier
    WidthTier   = $widthTier
    AudioTier   = $audioTier
    PreprocessTier = $preprocessLabel
    ArchetypeKey = ("{0}|{1}|{2}|{3}" -f $fpsTier, $widthTier, $audioTier, $preprocessLabel)
    PredictedTotalBytes = [long]$TargetBytes
    PredictedFillRatio  = 1.0
    ResolutionBiasLabel = $resolutionProfile.BiasLabel
    PreprocessLabel = $preprocessLabel
    UseDenoise = [bool]$UseDenoise
    CropApplied = [bool](Get-ObjectPropertyValue -Object $Info -Name "CropApplied" -DefaultValue $false)
    CropSummary = Get-CropSummary -Info $Info
    VideoPrivateArgs = $videoPrivateArgs
  }
}

function Remove-PassLogFiles {
  param(
    [Parameter(Mandatory = $true)][string]$PassLogPath
  )

  if (-not [string]::IsNullOrWhiteSpace($PassLogPath)) {
    Get-ChildItem -Path ($PassLogPath + "*") -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

function Get-AudioEncodeArgs {
  param(
    [Parameter(Mandatory = $true)]$Plan
  )

  switch ($Plan.AudioPlan.Mode) {
    "copy" { return @("-c:a", "copy") }
    "aac"  { return @("-c:a", "aac", "-b:a", ("{0}k" -f $Plan.AudioPlan.Kbps)) }
    "opus" { return @("-c:a", $Plan.CodecProfile.DefaultAudioEncoder, "-b:a", ("{0}k" -f $Plan.AudioPlan.Kbps)) }
    "mute" { return @("-an") }
    default { throw "Unknown audio mode: $($Plan.AudioPlan.Mode)" }
  }
}

function Get-CodecPresetArgs {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [switch]$Preview
  )

  switch ($Plan.CodecProfile.PresetKind) {
    "svtav1" {
      $presetValue = if ($Preview) {
        [int]$Plan.CodecProfile.PreviewSpeedOverride.Value
      }
      else {
        Get-SvtAv1PresetForPreset -Preset $Plan.Preset
      }

      return @("-preset", "$presetValue")
    }

    default {
      $presetValue = if ($Preview) { [string]$Plan.CodecProfile.PreviewSpeedOverride.Value } else { [string]$Plan.Preset }
      return @("-preset", $presetValue)
    }
  }
}

function Get-CommonVideoEncodeArgs {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [switch]$Preview
  )

  $args = @()

  if (-not [string]::IsNullOrWhiteSpace($Plan.VFilter)) {
    $args += @("-vf", $Plan.VFilter)
  }

  $args += @("-c:v", $Plan.CodecProfile.VideoEncoder)
  $args += Get-CodecPresetArgs -Plan $Plan -Preview:$Preview
  $args += @("-pix_fmt", "yuv420p")

  $videoRate = ("{0}k" -f $Plan.VideoKbps)
  $bufSize = ("{0}k" -f ([int][math]::Max($Plan.VideoKbps * 2, 100)))

  if ($Plan.CodecProfile.VideoCodec -eq "av1") {
    $args += @("-b:v", $videoRate)
  }
  else {
    $args += @("-b:v", $videoRate, "-maxrate", $videoRate, "-bufsize", $bufSize)
  }

  if ($Plan.CodecProfile.VideoCodec -eq "x264" -and -not [string]::IsNullOrWhiteSpace($Plan.VideoPrivateArgs)) {
    $args += @("-x264-params", $Plan.VideoPrivateArgs)
  }

  return $args
}

function Invoke-EncodePassOne {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$PassLogPath
  )

  $commonVideo = Get-CommonVideoEncodeArgs -Plan $Plan
  $pass1 = @("-y", "-i", $InputPath) + $commonVideo + @("-pass", "1", "-passlogfile", $PassLogPath, "-an", "-f", "null", "NUL")
  [void](Invoke-Tool -Exe "ffmpeg" -Args $pass1)
}

function Finalize-OutputFile {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)]$CodecProfile
  )

  $args = @("-y", "-i", $InputPath) + $CodecProfile.FinalizeArgs + @($OutputPath)
  [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
  return (Get-Item $OutputPath).Length
}

function Encode-Plan {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][bool]$TwoPass,
    [string]$PassLogPath = ""
  )

  $passlog = if ([string]::IsNullOrWhiteSpace($PassLogPath)) {
    Join-Path $TempDir ("ffpass_{0}" -f ([guid]::NewGuid().ToString("N")))
  }
  else {
    $PassLogPath
  }
  $ownsPassLog = [string]::IsNullOrWhiteSpace($PassLogPath)
  $commonVideo = Get-CommonVideoEncodeArgs -Plan $Plan

  if ($TwoPass) {
    if ($ownsPassLog) {
      Invoke-EncodePassOne -InputPath $InputPath -Plan $Plan -PassLogPath $passlog
    }

    $pass2 = @("-y", "-i", $InputPath) + $commonVideo + @("-pass", "2", "-passlogfile", $passlog)
    $pass2 += Get-AudioEncodeArgs -Plan $Plan
    $pass2 += $OutputPath
    [void](Invoke-Tool -Exe "ffmpeg" -Args $pass2)
  }
  else {
    $args = @("-y", "-i", $InputPath) + $commonVideo
    $args += Get-AudioEncodeArgs -Plan $Plan
    $args += $OutputPath
    [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
  }

  $size = (Get-Item $OutputPath).Length
  if ($ownsPassLog) {
    Remove-PassLogFiles -PassLogPath $passlog
  }
  return $size
}

function Test-IsBetterPlanAttempt {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    $Current
  )

  if ($null -eq $Current) { return $true }

  if ($Candidate.SizeBytes -gt $Current.SizeBytes) { return $true }
  if ($Candidate.SizeBytes -lt $Current.SizeBytes) { return $false }

  $candAudioRank = if ($Candidate.Plan.AudioPlan -and $Candidate.Plan.AudioPlan.Rank) { [int]$Candidate.Plan.AudioPlan.Rank } else { 0 }
  $currAudioRank = if ($Current.Plan.AudioPlan -and $Current.Plan.AudioPlan.Rank) { [int]$Current.Plan.AudioPlan.Rank } else { 0 }

  if ($candAudioRank -gt $currAudioRank) { return $true }
  if ($candAudioRank -lt $currAudioRank) { return $false }

  return ($Candidate.Plan.VideoKbps -gt $Current.Plan.VideoKbps)
}

function Get-PreviewStrategyForMode($mode, $duration) {
  $strategy = Get-ModeStrategy -Mode $mode -Duration $duration
  return [PSCustomObject]@{
    Enabled       = ($strategy.PreviewMode -ne "none")
    Mode          = $strategy.PreviewMode
    SampleSeconds = [int]$strategy.PreviewSampleSeconds
    MaxSamples    = [int]$strategy.PreviewMaxSamples
    PreviewTop    = [int](Get-ObjectPropertyValue -Object $strategy -Name "PreviewTop" -DefaultValue $strategy.Finalists)
    PreviewPreset = "auto"
    Finalists     = [int]$strategy.Finalists
  }
}

function Get-PreviewSeedVideoKbps {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Preview
  )

  $predictedVideoBytes = [double]$Preview.VideoBytes
  $targetVideoBytes = [double]$Plan.TargetBytes - [double]$Plan.AudioPlan.EstimatedBytes - [double](Get-MuxReserveBytes -targetBytes $Plan.TargetBytes -mode $Plan.Mode)
  if ($predictedVideoBytes -le 1.0 -or $targetVideoBytes -le 1.0) {
    return [int]$Plan.VideoKbps
  }

  $factor = $targetVideoBytes / $predictedVideoBytes
  $bounds = switch ($Plan.Mode) {
    "Balanced"     { @{ Min = 0.90; Max = 1.12 } }
    "ExtraQuality" { @{ Min = 0.88; Max = 1.15 } }
    default        { @{ Min = 0.94; Max = 1.08 } }
  }
  $factor = [math]::Max($bounds.Min, [math]::Min($bounds.Max, $factor))
  $seedRate = [int][math]::Round([int]$Plan.VideoKbps * $factor)
  if ([math]::Abs($seedRate - [int]$Plan.VideoKbps) -lt 8) {
    return [int]$Plan.VideoKbps
  }

  return [int][math]::Max(35, $seedRate)
}

function Get-PlanKey($Plan) {
  $audioKey = switch ($Plan.AudioPlan.Mode) {
    "aac"  { "aac:$($Plan.AudioPlan.Kbps)" }
    "opus" { "opus:$($Plan.AudioPlan.Kbps)" }
    "copy" { "copy" }
    "mute" { "mute" }
    default { [string]$Plan.AudioPlan.Mode }
  }

  return ("{0}x{1}@{2}|v={3}|a={4}|p={5}|pp={6}|crop={7}|codec={8}" -f $Plan.Width, $Plan.Height, $Plan.Fps, $Plan.VideoKbps, $audioKey, $Plan.Preset, $Plan.PreprocessLabel, [int]$Plan.CropApplied, $Plan.CodecProfile.VideoCodec)
}

function Get-TopResultsByPreference {
  param(
    [Parameter(Mandatory = $true)]$Results,
    [Parameter(Mandatory = $true)][int]$Count
  )

  $ordered = New-Object System.Collections.ArrayList

  foreach ($result in $Results) {
    $inserted = $false

    for ($i = 0; $i -lt $ordered.Count; $i++) {
      if (Test-IsBetterPreviewResult -Candidate $result -Current $ordered[$i]) {
        [void]$ordered.Insert($i, $result)
        $inserted = $true
        break
      }
    }

    if (-not $inserted) {
      [void]$ordered.Add($result)
    }

    while ($ordered.Count -gt $Count) {
      $ordered.RemoveAt($ordered.Count - 1)
    }
  }

  return @($ordered)
}

function Get-CloseEnoughRatioForMode($mode) {
  return [double](Get-ModeStrategy -Mode $mode).CloseEnoughRatio
}

function Get-EarlyAcceptRatioForMode($mode) {
  return [double](Get-ModeStrategy -Mode $mode).EarlyAcceptRatio
}

function Set-PlanPreviewMetadata {
  param(
    [Parameter(Mandatory = $true)]$Plans
  )

  $rankedPlans = New-Object System.Collections.Generic.List[object]
  $rank = 0

  foreach ($plan in @($Plans)) {
    $rank++
    $planCopy = $plan.PSObject.Copy()
    $planCopy | Add-Member -NotePropertyName PreviewRank -NotePropertyValue $rank -Force
    [void]$rankedPlans.Add($planCopy)
  }

  return @($rankedPlans.ToArray())
}

function Get-NextVideoKbpsGuess {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][int]$CurrentVideoKbps,
    [Parameter(Mandatory = $true)][long]$CurrentSizeBytes,
    $LowerBound,
    $UpperBound
  )

  $minRate = 35
  $minStep = switch ($Mode) {
    "Fast"         { 12 }
    "Balanced"     { 8 }
    "ExtraQuality" { 5 }
  }

  if ($LowerBound -and $UpperBound) {
    $gap = [int]$UpperBound.VideoKbps - [int]$LowerBound.VideoKbps
    if ($gap -le $minStep) { return 0 }

    $spanBytes = [double]$UpperBound.SizeBytes - [double]$LowerBound.SizeBytes
    if ($spanBytes -gt 1.0) {
      $guess = [double]$LowerBound.VideoKbps + (([double]$TargetBytes - [double]$LowerBound.SizeBytes) / $spanBytes) * ([double]$UpperBound.VideoKbps - [double]$LowerBound.VideoKbps)
    }
    else {
      $guess = ([double]$LowerBound.VideoKbps + [double]$UpperBound.VideoKbps) / 2.0
    }

    $next = [int][math]::Round($guess)
    $next = [int][math]::Max([int]$LowerBound.VideoKbps + $minStep, [math]::Min([int]$UpperBound.VideoKbps - $minStep, $next))

    if ($next -eq $CurrentVideoKbps) {
      $next = [int][math]::Floor(([double]$LowerBound.VideoKbps + [double]$UpperBound.VideoKbps) / 2.0)
    }

    return [int][math]::Max($minRate, $next)
  }

  if ($CurrentSizeBytes -lt $TargetBytes) {
    $desiredFillBytes = switch ($Mode) {
      "Fast"         { [math]::Floor($TargetBytes * 0.992) }
      "Balanced"     { [math]::Floor($TargetBytes * 0.9985) }
      "ExtraQuality" { [math]::Floor($TargetBytes * 0.9990) }
    }
    $factor = [double]$desiredFillBytes / [double][math]::Max(1, $CurrentSizeBytes)
    $factor = switch ($Mode) {
      "Fast"         { [math]::Max(1.01, [math]::Min(1.08, $factor)) }
      "Balanced"     { [math]::Max(1.01, [math]::Min(1.12, $factor)) }
      "ExtraQuality" { [math]::Max(1.01, [math]::Min(1.10, $factor)) }
    }
  }
  else {
    $desiredShrinkBytes = switch ($Mode) {
      "Fast"         { [math]::Floor($TargetBytes * 0.992) }
      "Balanced"     { [math]::Floor($TargetBytes * 0.9975) }
      "ExtraQuality" { [math]::Floor($TargetBytes * 0.9985) }
    }
    $factor = [double]$desiredShrinkBytes / [double][math]::Max(1, $CurrentSizeBytes)
    $factor = switch ($Mode) {
      "Fast"         { [math]::Max(0.80, [math]::Min(0.99, $factor)) }
      "Balanced"     { [math]::Max(0.85, [math]::Min(0.985, $factor)) }
      "ExtraQuality" { [math]::Max(0.88, [math]::Min(0.988, $factor)) }
    }
  }

  $nextGuess = [int][math]::Floor($CurrentVideoKbps * $factor)
  if ($nextGuess -eq $CurrentVideoKbps) {
    if ($CurrentSizeBytes -lt $TargetBytes) {
      $nextGuess++
    }
    else {
      $nextGuess--
    }
  }

  return [int][math]::Max($minRate, $nextGuess)
}

function Get-PlanAttemptOutputPath {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$Attempt
  )

  $presetKey = ($Plan.Preset -replace '[^A-Za-z0-9]+', '_')
  $preprocessKey = ($Plan.PreprocessLabel -replace '[^A-Za-z0-9]+', '_')
  return Join-Path $TempDir ("candidate_{0}_{1}_{2}_{3}_{4}_{5}{6}" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $presetKey, $preprocessKey, $Attempt, $Plan.OutputExtension)
}

function Get-PlanPreviewResult {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][int]$SampleSeconds,
    [Parameter(Mandatory = $true)][int]$MaxSamples
  )

  $offsets = @(
    Get-SampleOffsets -duration $Info.Duration -sampleLength $SampleSeconds -maxSamples $MaxSamples
  )
  if (-not $offsets -or $offsets.Length -eq 0) {
    return $null
  }

  $strategy = Get-ModeStrategy -Mode $Plan.Mode -Duration $Info.Duration
  $segmentBytes = @()
  $idx = 0
  $commonVideo = Get-CommonVideoEncodeArgs -Plan $Plan -Preview

  foreach ($offset in $offsets) {
    $idx++
    $outPath = Join-Path $TempDir ("preview_{0}_{1}_{2}_{3}{4}" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $idx, $Plan.OutputExtension)
    $args = @("-y", "-ss", "$offset", "-t", "$SampleSeconds", "-i", $InputPath)
    $args += @("-an") + $commonVideo + @($outPath)

    [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
    $segmentBytes += [double](Get-Item $outPath).Length
    Remove-Item $outPath -Force -ErrorAction SilentlyContinue
  }

  if ($segmentBytes.Length -eq 0) {
    return $null
  }

  $avgSegmentBytes = ($segmentBytes | Measure-Object -Average).Average
  $maxSegmentBytes = ($segmentBytes | Measure-Object -Maximum).Maximum
  $weightedSegmentBytes = if ($strategy.Mode -eq "ExtraQuality") {
    [double]$avgSegmentBytes + (([double]$maxSegmentBytes - [double]$avgSegmentBytes) * 0.35)
  }
  else {
    [double]$avgSegmentBytes
  }
  $predictedVideoBytes = [double]$weightedSegmentBytes * ([double]$Info.Duration / [double]$SampleSeconds)
  $predictedTotalBytes = [long][math]::Floor($predictedVideoBytes + [double]$Plan.AudioPlan.EstimatedBytes + [double](Get-MuxReserveBytes -targetBytes $Plan.TargetBytes -mode $Plan.Mode))
  $predictedRatio = $predictedTotalBytes / [double]$Plan.TargetBytes

  return [PSCustomObject]@{
    Success    = ($predictedTotalBytes -gt 0)
    SizeBytes  = $predictedTotalBytes
    VideoBytes = [long][math]::Floor($predictedVideoBytes)
    MeanSegmentBytes = [long][math]::Floor($avgSegmentBytes)
    MaxSegmentBytes  = [long][math]::Floor($maxSegmentBytes)
    SampleCount = [int]$segmentBytes.Length
    Path       = $null
    Plan       = $Plan.PSObject.Copy()
    Ratio      = $predictedRatio
  }
}

function Get-PlanFinalists {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $modeStrategy = Get-ModeStrategy -Mode $Mode -Duration $Info.Duration
  $strategy = Get-PreviewStrategyForMode -mode $Mode -duration $Info.Duration
  $candidatePlans = @($Plans)
  $previewResults = New-Object System.Collections.Generic.List[object]
  $previewsRun = 0

  switch ($Mode) {
    "Fast" {
      $primary = @($candidatePlans | Select-Object -First 1)[0]
      $backup = Get-MeaningfulAlternativePlan -Primary $primary -Plans $candidatePlans
      $selectedPlans = @($primary) + @($backup | Where-Object { $null -ne $_ })
      $ranked = @(Set-PlanPreviewMetadata -Plans $selectedPlans)
      return [PSCustomObject]@{
        Plans       = $ranked
        PreviewsRun = 0
      }
    }

    "Balanced" {
      $primary = @($candidatePlans | Select-Object -First 1)[0]
      $selectedPlans = New-Object System.Collections.Generic.List[object]
      [void]$selectedPlans.Add($primary)

      $shouldChallenge = (
        [double](Get-ObjectPropertyValue -Object $primary -Name "Confidence" -DefaultValue 1.0) -lt [double]$modeStrategy.ChallengerConfidenceThreshold -or
        @((Get-ObjectPropertyValue -Object $primary -Name "RiskFlags" -DefaultValue @())).Count -ge 2
      )

      if ($shouldChallenge) {
        $challenger = Get-MeaningfulAlternativePlan -Primary $primary -Plans $candidatePlans
        if ($challenger) {
          [void]$selectedPlans.Add($challenger)

          $scoreGap = Get-RelativeScoreGap -PrimaryScore $primary.Score -SecondaryScore $challenger.Score
          if ($scoreGap -le [double]$modeStrategy.NearTieDelta) {
            foreach ($plan in @($primary, $challenger)) {
              $previewsRun++
              Write-Host ("Previewing plan {0}/2: {1}x{2} @{3}fps | v={4}k | a={5} | width={6} | pp={7}" -f $previewsRun, $plan.Width, $plan.Height, $plan.Fps, $plan.VideoKbps, $plan.AudioPlan.Label, $plan.WidthOrigin, $plan.PreprocessLabel)
              $preview = Get-PlanPreviewResult `
                -Info $Info `
                -InputPath $InputPath `
                -TempDir $TempDir `
                -Plan $plan `
                -SampleSeconds $strategy.SampleSeconds `
                -MaxSamples $strategy.MaxSamples

              if ($preview -and $preview.Success) {
                [void]$previewResults.Add($preview)
              }
            }

            if ($previewResults.Count -gt 0) {
              $topPreview = Get-TopResultsByPreference -Results $previewResults -Count $selectedPlans.Count
              $previewSelected = New-Object System.Collections.Generic.List[object]
              $previewRank = 0
              foreach ($preview in $topPreview) {
                $previewRank++
                $selectedPlan = $preview.Plan.PSObject.Copy()
                $selectedPlan | Add-Member -NotePropertyName PreviewRank -NotePropertyValue $previewRank -Force
                $selectedPlan | Add-Member -NotePropertyName PreviewRatio -NotePropertyValue ([double]$preview.Ratio) -Force
                $selectedPlan | Add-Member -NotePropertyName PredictedTotalBytes -NotePropertyValue ([long]$preview.SizeBytes) -Force
                $selectedPlan | Add-Member -NotePropertyName PredictedFillRatio -NotePropertyValue ([double]$preview.Ratio) -Force
                [void]$previewSelected.Add($selectedPlan)
              }

              return [PSCustomObject]@{
                Plans       = @($previewSelected.ToArray())
                PreviewsRun = $previewsRun
              }
            }
          }
        }
      }

      return [PSCustomObject]@{
        Plans       = @(Set-PlanPreviewMetadata -Plans @($selectedPlans.ToArray()))
        PreviewsRun = $previewsRun
      }
    }

    default {
      $previewCandidates = @($candidatePlans | Select-Object -First $strategy.PreviewTop)
      foreach ($plan in $previewCandidates) {
        $previewsRun++
        Write-Host ("Previewing plan {0}/{1}: {2}x{3} @{4}fps | v={5}k | a={6} | width={7} | pp={8}" -f $previewsRun, $previewCandidates.Count, $plan.Width, $plan.Height, $plan.Fps, $plan.VideoKbps, $plan.AudioPlan.Label, $plan.WidthOrigin, $plan.PreprocessLabel)
        $preview = Get-PlanPreviewResult `
          -Info $Info `
          -InputPath $InputPath `
          -TempDir $TempDir `
          -Plan $plan `
          -SampleSeconds $strategy.SampleSeconds `
          -MaxSamples $strategy.MaxSamples

        if ($preview -and $preview.Success) {
          [void]$previewResults.Add($preview)
        }
      }

      if ($previewResults.Count -eq 0) {
        return [PSCustomObject]@{
          Plans       = @(Set-PlanPreviewMetadata -Plans @($candidatePlans | Select-Object -First $strategy.Finalists))
          PreviewsRun = $previewsRun
        }
      }

      $topPreview = Get-TopResultsByPreference -Results $previewResults -Count $strategy.Finalists
      $selectedPlans = New-Object System.Collections.Generic.List[object]
      $seenKeys = New-Object System.Collections.Generic.HashSet[string]
      $previewRank = 0

      foreach ($preview in $topPreview) {
        $key = Get-PlanKey -Plan $preview.Plan
        if ($seenKeys.Add($key)) {
          $previewRank++
          $selectedPlan = $preview.Plan.PSObject.Copy()
          $selectedPlan.VideoKbps = Get-PreviewSeedVideoKbps -Plan $selectedPlan -Preview $preview
          $selectedPlan | Add-Member -NotePropertyName PreviewRank -NotePropertyValue $previewRank -Force
          $selectedPlan | Add-Member -NotePropertyName PreviewRatio -NotePropertyValue ([double]$preview.Ratio) -Force
          $selectedPlan | Add-Member -NotePropertyName PredictedTotalBytes -NotePropertyValue ([long]$preview.SizeBytes) -Force
          $selectedPlan | Add-Member -NotePropertyName PredictedFillRatio -NotePropertyValue ([double]$preview.Ratio) -Force
          [void]$selectedPlans.Add($selectedPlan)
        }
      }

      $selectedSummary = $selectedPlans | ForEach-Object {
        "{0}x{1}@{2} ({3}, {4})" -f $_.Width, $_.Height, $_.Fps, $_.WidthOrigin, $_.PreprocessLabel
      }
      Write-Host ("Finalists:        {0}" -f ($selectedSummary -join ", "))

      return [PSCustomObject]@{
        Plans       = @($selectedPlans.ToArray())
        PreviewsRun = $previewsRun
      }
    }
  }
}

function Get-AudioPlanIdentity {
  param(
    [Parameter(Mandatory = $true)]$AudioPlan
  )

  return ("{0}|{1}|{2}" -f $AudioPlan.Mode, (Get-ObjectPropertyValue -Object $AudioPlan -Name "Kbps" -DefaultValue ""), $AudioPlan.EstimatedBytes)
}

function Initialize-PlanPassLog {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  if ($Plan.Mode -eq "Fast") { return $null }

  $passLogPath = Join-Path $TempDir ("ffpass_shared_{0}" -f ([guid]::NewGuid().ToString("N")))
  Invoke-EncodePassOne -InputPath $InputPath -Plan $Plan -PassLogPath $passLogPath
  return $passLogPath
}

function Invoke-PlanAttempt {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$Attempt,
    [string]$PassLogPath = ""
  )

  $tempOut = Get-PlanAttemptOutputPath -Plan $Plan -TempDir $TempDir -Attempt $Attempt
  $twoPass = ($Plan.Mode -ne "Fast")
  $size = Encode-Plan -InputPath $InputPath -OutputPath $tempOut -Plan $Plan -TempDir $TempDir -TwoPass $twoPass -PassLogPath $PassLogPath
  $ratio = $size / [double]$Plan.TargetBytes
  $predictedTotalBytes = [long](Get-ObjectPropertyValue -Object $Plan -Name "PredictedTotalBytes" -DefaultValue $Plan.TargetBytes)
  $predictionBias = if ($predictedTotalBytes -gt 0) { [double]$size / [double]$predictedTotalBytes } else { $ratio }

  Write-Host ("Plan try {0}: {1}x{2} @{3}fps | v={4}k | a={5} | size={6} bytes ({7:P1})" -f $Attempt, $Plan.Width, $Plan.Height, $Plan.Fps, $Plan.VideoKbps, $Plan.AudioPlan.Label, $size, $ratio)

  if ($size -gt $Plan.TargetBytes) {
    if ($tempOut -and (Test-Path $tempOut)) {
      Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
    }
  }

  return [PSCustomObject]@{
    Success        = ($size -le $Plan.TargetBytes)
    SizeBytes      = [long]$size
    Path           = if ($size -le $Plan.TargetBytes) { $tempOut } else { $null }
    Plan           = $Plan.PSObject.Copy()
    Ratio          = [double]$ratio
    Attempt        = [int]$Attempt
    PredictionBias = [double]$predictionBias
  }
}

function Get-RetryPlanFromResult {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Result
  )

  $lowerBound = $null
  $upperBound = $null
  if ($Result.Success) {
    $lowerBound = [PSCustomObject]@{
      VideoKbps = [int]$Plan.VideoKbps
      SizeBytes = [long]$Result.SizeBytes
    }
  }
  else {
    $upperBound = [PSCustomObject]@{
      VideoKbps = [int]$Plan.VideoKbps
      SizeBytes = [long]$Result.SizeBytes
    }
  }

  $newRate = Get-NextVideoKbpsGuess `
    -Mode $Plan.Mode `
    -TargetBytes $Plan.TargetBytes `
    -CurrentVideoKbps $Plan.VideoKbps `
    -CurrentSizeBytes $Result.SizeBytes `
    -LowerBound $lowerBound `
    -UpperBound $upperBound

  if ($newRate -lt 35 -or $newRate -eq $Plan.VideoKbps) {
    return $null
  }

  $retryPlan = $Plan.PSObject.Copy()
  $retryPlan.VideoKbps = [int]$newRate
  $retryPlan | Add-Member -NotePropertyName PredictedTotalBytes -NotePropertyValue ([long][math]::Floor($Plan.TargetBytes * $Result.PredictionBias)) -Force
  $retryPlan | Add-Member -NotePropertyName PredictedFillRatio -NotePropertyValue ([double]$Result.Ratio) -Force
  return $retryPlan
}

function Try-PlanBitrateRefinement {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$CurrentResult,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$Attempt,
    [string]$PassLogPath = ""
  )

  $retryPlan = Get-RetryPlanFromResult -Plan $Plan -Result $CurrentResult
  if ($null -eq $retryPlan) { return $null }

  Write-Host ("Second-stage:    bitrate refinement -> {0}k" -f $retryPlan.VideoKbps)
  return Invoke-PlanAttempt -InputPath $InputPath -Plan $retryPlan -TempDir $TempDir -Attempt $Attempt -PassLogPath $PassLogPath
}

function Get-AdjacentAudioPlans {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans
  )

  $audioIdentity = Get-AudioPlanIdentity -AudioPlan $Plan.AudioPlan
  $matching = @(
    $Plans |
      Where-Object {
        $_.Width -eq $Plan.Width -and
        $_.Fps -eq $Plan.Fps -and
        $_.PreprocessTier -eq $Plan.PreprocessTier
      } |
      Sort-Object -Property @{ Expression = { $_.AudioPlan.EstimatedBytes }; Descending = $true }, @{ Expression = { $_.AudioPlan.Rank }; Descending = $true }
  )

  if ($matching.Count -lt 2) { return @() }
  $currentIndex = -1
  for ($i = 0; $i -lt $matching.Count; $i++) {
    if ((Get-AudioPlanIdentity -AudioPlan $matching[$i].AudioPlan) -eq $audioIdentity) {
      $currentIndex = $i
      break
    }
  }

  if ($currentIndex -lt 0) { return @() }

  $neighbors = New-Object System.Collections.Generic.List[object]
  if ($currentIndex -gt 0) { [void]$neighbors.Add($matching[$currentIndex - 1]) }
  if ($currentIndex -lt ($matching.Count - 1)) { [void]$neighbors.Add($matching[$currentIndex + 1]) }
  return @($neighbors.ToArray())
}

function Get-AdjacentWidthPlans {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans
  )

  $audioIdentity = Get-AudioPlanIdentity -AudioPlan $Plan.AudioPlan
  $matching = @(
    $Plans |
      Where-Object {
        $_.Fps -eq $Plan.Fps -and
        (Get-AudioPlanIdentity -AudioPlan $_.AudioPlan) -eq $audioIdentity -and
        $_.PreprocessTier -eq $Plan.PreprocessTier
      } |
      Sort-Object -Property @{ Expression = { $_.Width }; Descending = $true }, @{ Expression = { $_.Score }; Descending = $true }
  )

  if ($matching.Count -lt 2) { return @() }
  $currentIndex = -1
  for ($i = 0; $i -lt $matching.Count; $i++) {
    if ($matching[$i].Width -eq $Plan.Width) {
      $currentIndex = $i
      break
    }
  }

  if ($currentIndex -lt 0) { return @() }

  $neighbors = New-Object System.Collections.Generic.List[object]
  if ($currentIndex -gt 0) { [void]$neighbors.Add($matching[$currentIndex - 1]) }
  if ($currentIndex -lt ($matching.Count - 1)) { [void]$neighbors.Add($matching[$currentIndex + 1]) }
  return @($neighbors.ToArray())
}

function Get-DenoiseTogglePlan {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans
  )

  $audioIdentity = Get-AudioPlanIdentity -AudioPlan $Plan.AudioPlan
  return @(
    $Plans |
      Where-Object {
        $_.Width -eq $Plan.Width -and
        $_.Fps -eq $Plan.Fps -and
        (Get-AudioPlanIdentity -AudioPlan $_.AudioPlan) -eq $audioIdentity -and
        $_.UseDenoise -ne $Plan.UseDenoise
      } |
      Select-Object -First 1
  )
}

function Test-IsSaferFallbackPlan {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$ReferencePlan
  )

  return (
    $Candidate.Width -lt $ReferencePlan.Width -or
    $Candidate.AudioPlan.EstimatedBytes -lt $ReferencePlan.AudioPlan.EstimatedBytes -or
    ($Candidate.UseDenoise -and -not $ReferencePlan.UseDenoise)
  )
}

function Test-IsMoreAggressiveFallbackPlan {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$ReferencePlan
  )

  return (
    $Candidate.Width -gt $ReferencePlan.Width -or
    $Candidate.AudioPlan.EstimatedBytes -gt $ReferencePlan.AudioPlan.EstimatedBytes -or
    (-not $Candidate.UseDenoise -and $ReferencePlan.UseDenoise)
  )
}

function Get-CalibratedFallbackPlan {
  param(
    [Parameter(Mandatory = $true)]$CandidatePlan,
    [Parameter(Mandatory = $true)]$ReferenceResult
  )

  $strategy = Get-ModeStrategy -Mode $CandidatePlan.Mode -Duration $CandidatePlan.DurationSeconds
  $desiredBytes = [math]::Floor($CandidatePlan.TargetBytes * $strategy.CloseEnoughRatio)
  $factor = [double]$desiredBytes / [double][math]::Max(1, $ReferenceResult.SizeBytes)

  if ($ReferenceResult.Ratio -le 1.0) {
    $factor = switch ($CandidatePlan.Mode) {
      "Fast"         { [math]::Max(1.01, [math]::Min(1.08, $factor)) }
      "Balanced"     { [math]::Max(1.01, [math]::Min(1.12, $factor)) }
      default        { [math]::Max(1.01, [math]::Min(1.10, $factor)) }
    }
  }
  else {
    $factor = switch ($CandidatePlan.Mode) {
      "Fast"         { [math]::Max(0.80, [math]::Min(0.99, $factor)) }
      "Balanced"     { [math]::Max(0.85, [math]::Min(0.985, $factor)) }
      default        { [math]::Max(0.88, [math]::Min(0.988, $factor)) }
    }
  }

  $planCopy = $CandidatePlan.PSObject.Copy()
  $planCopy.VideoKbps = [int][math]::Max(35, [math]::Floor($CandidatePlan.VideoKbps * $factor))
  $planCopy | Add-Member -NotePropertyName PredictedTotalBytes -NotePropertyValue ([long][math]::Floor($CandidatePlan.TargetBytes * $ReferenceResult.PredictionBias)) -Force
  $planCopy | Add-Member -NotePropertyName PredictedFillRatio -NotePropertyValue ([double]$ReferenceResult.Ratio) -Force
  return $planCopy
}

function Get-SecondStageCandidateScore {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$ReferenceResult
  )

  $score = [double]$Candidate.Score + ([double](Get-ObjectPropertyValue -Object $Candidate -Name "Confidence" -DefaultValue 0.75) * 1000.0)
  if ($ReferenceResult.Ratio -gt 1.0) {
    if (Test-IsSaferFallbackPlan -Candidate $Candidate -ReferencePlan $ReferenceResult.Plan) { $score += 1200.0 }
  }
  elseif ($ReferenceResult.Ratio -lt (Get-ModeStrategy -Mode $Candidate.Mode -Duration $Candidate.DurationSeconds).BadUnderfillRatio) {
    if (Test-IsMoreAggressiveFallbackPlan -Candidate $Candidate -ReferencePlan $ReferenceResult.Plan) { $score += 1200.0 }
  }
  else {
    $score -= 500.0
  }

  return $score
}

function Expand-PlanNeighborhood {
  param(
    [Parameter(Mandatory = $true)]$ReferenceResult,
    [Parameter(Mandatory = $true)]$AllPlans,
    [bool]$PresetWasExplicit = $false
  )

  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in @(Get-AdjacentAudioPlans -Plan $ReferenceResult.Plan -Plans $AllPlans)) {
    if ($candidate) { [void]$candidates.Add($candidate) }
  }
  foreach ($candidate in @(Get-AdjacentWidthPlans -Plan $ReferenceResult.Plan -Plans $AllPlans)) {
    if ($candidate) { [void]$candidates.Add($candidate) }
  }
  foreach ($candidate in @(Get-DenoiseTogglePlan -Plan $ReferenceResult.Plan -Plans $AllPlans)) {
    if ($candidate) { [void]$candidates.Add($candidate) }
  }

  if (-not $PresetWasExplicit -and $ReferenceResult.Plan.Mode -eq "ExtraQuality") {
    $presetVariant = Get-PresetVariantPlan -Plan $ReferenceResult.Plan
    if ($presetVariant) {
      [void]$candidates.Add($presetVariant)
    }
  }

  $seenKeys = New-Object System.Collections.Generic.HashSet[string]
  $scored = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in $candidates) {
    if ($null -eq $candidate) { continue }
    $calibrated = Get-CalibratedFallbackPlan -CandidatePlan $candidate -ReferenceResult $ReferenceResult
    $key = Get-PlanKey -Plan $calibrated
    if (-not $seenKeys.Add($key)) { continue }

    $scored.Add([PSCustomObject]@{
        Plan  = $calibrated
        Score = (Get-SecondStageCandidateScore -Candidate $calibrated -ReferenceResult $ReferenceResult)
      })
  }

  return @($scored | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Plan.Score }; Descending = $true } | ForEach-Object { $_.Plan })
}

function Try-PlanSingleFallback {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$ReferenceResult,
    [Parameter(Mandatory = $true)]$AllPlans,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$Attempt,
    [bool]$PresetWasExplicit = $false
  )

  $candidates = Expand-PlanNeighborhood -ReferenceResult $ReferenceResult -AllPlans $AllPlans -PresetWasExplicit:$PresetWasExplicit
  $chosen = @($candidates | Select-Object -First 1)[0]
  if ($null -eq $chosen) { return $null }

  Write-Host ("Second-stage:    fallback -> {0}x{1} @{2}fps | v={3}k | a={4} | pp={5}" -f $chosen.Width, $chosen.Height, $chosen.Fps, $chosen.VideoKbps, $chosen.AudioPlan.Label, $chosen.PreprocessLabel)
  return Invoke-PlanAttempt -InputPath $InputPath -Plan $chosen -TempDir $TempDir -Attempt $Attempt
}

function Get-PresetVariantPlan {
  param(
    [Parameter(Mandatory = $true)]$Plan
  )

  $strategy = Get-ModeStrategy -Mode $Plan.Mode -Duration $Plan.DurationSeconds
  if (-not $strategy.AllowPresetExploration) { return $null }

  $currentRank = Get-X264PresetRank -preset $Plan.Preset
  if ($currentRank -lt (Get-X264PresetRank "slow")) {
    $variantPreset = "slow"
  }
  elseif ($currentRank -gt (Get-X264PresetRank "medium")) {
    $variantPreset = "medium"
  }
  else {
    return $null
  }

  $planCopy = $Plan.PSObject.Copy()
  $planCopy.Preset = $variantPreset
  return $planCopy
}

function Get-PlanList {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][string]$PreprocessProfile
  )

  $totalKbps = (($TargetBytes * 8.0) / $Info.Duration) / 1000.0
  $fpsCandidates = Get-TargetFpsCandidates -srcFps $Info.Fps -mode $Mode -duration $Info.Duration -totalKbps $totalKbps -motionBucket $Probe.MotionBucket -detailBucket $Probe.DetailBucket
  $audioCandidates = Get-AudioPlanCandidates -Info $Info -CodecProfile $CodecProfile -Mode $Mode -TotalKbps $totalKbps -Duration $Info.Duration -ProbeBucket $Probe.DetailBucket

  $plans = New-Object System.Collections.Generic.List[object]

  foreach ($fps in $fpsCandidates) {
    $seedAudios = New-Object System.Collections.Generic.List[object]
    $seedAudioKeys = New-Object System.Collections.Generic.HashSet[string]
    $highestAudio = $audioCandidates | Sort-Object -Property @{ Expression = { $_.EstimatedBytes }; Descending = $true }, @{ Expression = { $_.Rank }; Descending = $true } | Select-Object -First 1
    $lowestAudio = $audioCandidates | Sort-Object -Property @{ Expression = { $_.EstimatedBytes }; Descending = $false }, @{ Expression = { $_.Rank }; Descending = $true } | Select-Object -First 1

    foreach ($audioSeed in @($highestAudio, $lowestAudio)) {
      if ($null -eq $audioSeed) { continue }
      $seedKey = "{0}|{1}|{2}" -f $audioSeed.Mode, $audioSeed.Kbps, $audioSeed.EstimatedBytes
      if ($seedAudioKeys.Add($seedKey)) {
        [void]$seedAudios.Add($audioSeed)
      }
    }

    $widthByValue = @{}
    foreach ($seedAudio in $seedAudios) {
      $usableVideoKbps = [int][math]::Floor(((($TargetBytes - $seedAudio.EstimatedBytes - (Get-MuxReserveBytes -targetBytes $TargetBytes -mode $Mode)) * 8.0) / $Info.Duration) / 1000.0)
      if ($usableVideoKbps -lt 40) { continue }

      $widthCandidates = Get-WidthPlanCandidates -Info $Info -Probe $Probe -TargetFps $fps -VideoKbps $usableVideoKbps -Mode $Mode
      foreach ($widthCandidate in $widthCandidates) {
        $existing = $widthByValue[[int]$widthCandidate.Width]
        if ($null -eq $existing) {
          $widthByValue[[int]$widthCandidate.Width] = $widthCandidate
          continue
        }

        $widthCandidate.Origin = Get-CombinedWidthOrigin -existingOrigin $existing.Origin -newOrigin $widthCandidate.Origin
        if ($widthCandidate.Score -gt $existing.Score) {
          $widthByValue[[int]$widthCandidate.Width] = $widthCandidate
        }
        else {
          $existing.Origin = Get-CombinedWidthOrigin -existingOrigin $existing.Origin -newOrigin $widthCandidate.Origin
        }
      }
    }

    $widthCandidates = @($widthByValue.Values | Sort-Object Width -Descending)

    foreach ($w in $widthCandidates) {
      foreach ($a in $audioCandidates) {
        $basePlan = New-EncodePlan `
          -Info $Info `
          -Probe $Probe `
          -CodecProfile $CodecProfile `
          -Mode $Mode `
          -TargetBytes $TargetBytes `
          -Preset $Preset `
          -Width $w.Width `
          -Height $w.Height `
          -Fps $fps `
          -AudioPlan $a `
          -WidthOrigin $w.Origin

        if ($null -ne $basePlan -and $PreprocessProfile -ne "Mild") {
          $plans.Add($basePlan)
        }

        $shouldAddDenoise = if ($null -ne $basePlan) {
          Test-ShouldAddDenoisePlan -mode $Mode -detailBucket $Probe.DetailBucket -totalBudgetKbps $basePlan.TotalBudgetKbps -bpppf $basePlan.Bpppf -profile $PreprocessProfile
        }
        else {
          $false
        }

        if ($shouldAddDenoise) {
          $denoisePlan = New-EncodePlan `
            -Info $Info `
            -Probe $Probe `
            -CodecProfile $CodecProfile `
            -Mode $Mode `
            -TargetBytes $TargetBytes `
            -Preset $Preset `
            -Width $w.Width `
            -Height $w.Height `
            -Fps $fps `
            -AudioPlan $a `
            -WidthOrigin $w.Origin `
            -UseDenoise

          if ($null -ne $denoisePlan) {
            $plans.Add($denoisePlan)
          }
        }
        elseif ($null -ne $basePlan -and $PreprocessProfile -eq "Mild") {
          $plans.Add($basePlan)
        }
      }
    }
  }

  return [PSCustomObject]@{
    Plans = ($plans | Sort-Object -Property `
      @{ Expression = { $_.Score }; Descending = $true }, `
      @{ Expression = { $_.AudioPlan.Rank }; Descending = $true } `
      -Unique)
    AudioCandidates = $audioCandidates
  }
}

function Get-RelativeScoreGap {
  param(
    [double]$PrimaryScore,
    [double]$SecondaryScore
  )

  if ($PrimaryScore -eq 0.0) { return 1.0 }
  return ([double]$PrimaryScore - [double]$SecondaryScore) / [double][math]::Max(1.0, [math]::Abs($PrimaryScore))
}

function Get-CropPotentialAreaRemovedRatio {
  param(
    [Parameter(Mandatory = $true)]$Info
  )

  $samples = @((Get-ObjectPropertyValue -Object $Info -Name "CropSamples" -DefaultValue @()))
  if (-not $samples -or $samples.Count -eq 0) {
    return [double](Get-ObjectPropertyValue -Object $Info -Name "CropAreaRemovedRatio" -DefaultValue 0.0)
  }

  $avgWidth = ($samples | Measure-Object -Property Width -Average).Average
  $avgHeight = ($samples | Measure-Object -Property Height -Average).Average
  if ($avgWidth -le 0 -or $avgHeight -le 0) { return 0.0 }

  return 1.0 - (([double]$avgWidth * [double]$avgHeight) / ([double]$Info.Width * [double]$Info.Height))
}

function Get-CropConfidenceClass {
  param(
    [Parameter(Mandatory = $true)]$Info
  )

  $cropSummary = [string](Get-ObjectPropertyValue -Object $Info -Name "CropSummary" -DefaultValue "none")
  $samples = @((Get-ObjectPropertyValue -Object $Info -Name "CropSamples" -DefaultValue @()))
  $spread = 0.0
  if ($samples.Count -ge 2) {
    $spread = [math]::Max(
      (Get-SpreadRatio -Values ($samples | ForEach-Object { $_.Width })),
      (Get-SpreadRatio -Values ($samples | ForEach-Object { $_.Height }))
    )
  }

  if ($cropSummary -eq "unstable") { return "Medium" }
  if ([bool](Get-ObjectPropertyValue -Object $Info -Name "CropApplied" -DefaultValue $false)) {
    if ($spread -le 0.02) { return "High" }
    return "Medium"
  }

  return "Low"
}

function Test-PlanWidthNearTie {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)][double]$NearTieDelta
  )

  $candidates = @(
    $Plans |
      Where-Object {
        $_.Fps -eq $Plan.Fps -and
        $_.AudioTier -eq $Plan.AudioTier -and
        $_.PreprocessTier -eq $Plan.PreprocessTier
      } |
      Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Width }; Descending = $true }
  )

  if ($candidates.Count -lt 2) { return $false }
  $gap = Get-RelativeScoreGap -PrimaryScore $candidates[0].Score -SecondaryScore $candidates[1].Score
  return ($gap -le $NearTieDelta)
}

function Test-PlanFpsNearTie {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)][double]$NearTieDelta
  )

  $candidates = @(
    $Plans |
      Where-Object {
        $_.WidthTier -eq $Plan.WidthTier -and
        $_.AudioTier -eq $Plan.AudioTier -and
        $_.PreprocessTier -eq $Plan.PreprocessTier
      } |
      Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Fps }; Descending = $true }
  )

  if ($candidates.Count -lt 2) { return $false }
  $gap = Get-RelativeScoreGap -PrimaryScore $candidates[0].Score -SecondaryScore $candidates[1].Score
  return ($gap -le $NearTieDelta)
}

function Test-PlanAudioTradeoffMaterial {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][double]$NearTieDelta
  )

  $candidates = @(
    $Plans |
      Where-Object {
        $_.FpsTier -eq $Plan.FpsTier -and
        $_.WidthTier -eq $Plan.WidthTier -and
        $_.PreprocessTier -eq $Plan.PreprocessTier
      } |
      Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.AudioPlan.Rank }; Descending = $true }
  )

  if ($candidates.Count -lt 2) { return $false }
  $gap = Get-RelativeScoreGap -PrimaryScore $candidates[0].Score -SecondaryScore $candidates[1].Score
  $byteDelta = [math]::Abs([double]$candidates[0].AudioPlan.EstimatedBytes - [double]$candidates[1].AudioPlan.EstimatedBytes)
  return ($gap -le $NearTieDelta -and $byteDelta -ge ($TargetBytes * 0.04))
}

function Test-PlanProbeSpreadHigh {
  param(
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$Strategy
  )

  $maxSpread = [double][math]::Max(
    [double](Get-ObjectPropertyValue -Object $Probe -Name "DetailSpreadRatio" -DefaultValue 0.0),
    [double](Get-ObjectPropertyValue -Object $Probe -Name "MotionSpreadRatio" -DefaultValue 0.0)
  )
  $threshold = if ($null -ne $Strategy.ProbeEarlyStopSpreadThreshold) {
    [double]$Strategy.ProbeEarlyStopSpreadThreshold * 1.8
  }
  else {
    0.20
  }

  return ($maxSpread -ge $threshold)
}

function Add-PlanRiskMetadata {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$Strategy,
    [Parameter(Mandatory = $true)][long]$TargetBytes
  )

  $riskFlags = New-Object System.Collections.Generic.List[string]

  if (Test-PlanWidthNearTie -Plan $Plan -Plans $Plans -NearTieDelta $Strategy.NearTieDelta) {
    [void]$riskFlags.Add("WidthNearTie")
  }
  if (Test-PlanFpsNearTie -Plan $Plan -Plans $Plans -NearTieDelta $Strategy.NearTieDelta) {
    [void]$riskFlags.Add("FpsNearTie")
  }
  if (Test-PlanAudioTradeoffMaterial -Plan $Plan -Plans $Plans -TargetBytes $TargetBytes -NearTieDelta $Strategy.NearTieDelta) {
    [void]$riskFlags.Add("AudioMaterial")
  }

  $cropPotential = Get-CropPotentialAreaRemovedRatio -Info $Info
  $cropConfidence = Get-CropConfidenceClass -Info $Info
  if ($cropConfidence -eq "Medium" -and $cropPotential -ge 0.06) {
    [void]$riskFlags.Add("CropUncertain")
  }
  if (Test-PlanProbeSpreadHigh -Probe $Probe -Strategy $Strategy) {
    [void]$riskFlags.Add("ProbeSpread")
  }

  $confidence = 0.94
  $confidence -= ($riskFlags.Count * 0.10)
  if ($Plan.WidthOrigin -eq "local") { $confidence -= 0.02 }
  $confidence = [math]::Max(0.40, [math]::Min(0.98, $confidence))

  $planCopy = $Plan.PSObject.Copy()
  $planCopy | Add-Member -NotePropertyName RiskFlags -NotePropertyValue @($riskFlags.ToArray()) -Force
  $planCopy | Add-Member -NotePropertyName Confidence -NotePropertyValue ([double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $confidence)), [Globalization.CultureInfo]::InvariantCulture)) -Force
  $planCopy | Add-Member -NotePropertyName CropConfidence -NotePropertyValue $cropConfidence -Force
  $planCopy | Add-Member -NotePropertyName CropPotentialRatio -NotePropertyValue ([double]$cropPotential) -Force
  return $planCopy
}

function Add-UniquePlanSelection {
  param(
    [Parameter(Mandatory = $true)]$Selected,
    [Parameter(Mandatory = $true)]$SeenKeys,
    $Candidate
  )

  if ($null -eq $Candidate) { return }
  $key = Get-PlanKey -Plan $Candidate
  if ($SeenKeys.Add($key)) {
    [void]$Selected.Add($Candidate)
  }
}

function Test-IsMeaningfullyDifferentPlan {
  param(
    [Parameter(Mandatory = $true)]$Left,
    [Parameter(Mandatory = $true)]$Right
  )

  return (
    $Left.Width -ne $Right.Width -or
    $Left.Fps -ne $Right.Fps -or
    $Left.AudioTier -ne $Right.AudioTier -or
    $Left.PreprocessTier -ne $Right.PreprocessTier -or
    $Left.WidthOrigin -ne $Right.WidthOrigin
  )
}

function Get-MeaningfulAlternativePlan {
  param(
    [Parameter(Mandatory = $true)]$Primary,
    [Parameter(Mandatory = $true)]$Plans
  )

  return @($Plans | Where-Object { (Get-PlanKey -Plan $_) -ne (Get-PlanKey -Plan $Primary) -and (Test-IsMeaningfullyDifferentPlan -Left $Primary -Right $_) } | Select-Object -First 1)
}

function Get-PlanArchetypes {
  param(
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $strategy = Get-ModeStrategy -Mode $Mode -Duration $Info.Duration
  $groups = @{}
  foreach ($plan in @($Plans)) {
    $key = [string]$plan.ArchetypeKey
    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = New-Object System.Collections.Generic.List[object]
    }
    [void]$groups[$key].Add($plan)
  }

  $archetypes = New-Object System.Collections.Generic.List[object]
  foreach ($key in ($groups.Keys | Sort-Object)) {
    $best = @($groups[$key] | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.AudioPlan.Rank }; Descending = $true } | Select-Object -First 1)[0]
    if ($null -eq $best) { continue }
    [void]$archetypes.Add((Add-PlanRiskMetadata -Plan $best -Plans $Plans -Info $Info -Probe $Probe -Strategy $strategy -TargetBytes $TargetBytes))
  }

  $ordered = @($archetypes | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { Get-ObjectPropertyValue -Object $_ -Name "Confidence" -DefaultValue 0.75 }; Descending = $true }, @{ Expression = { $_.AudioPlan.Rank }; Descending = $true })
  if ($ordered.Count -le $strategy.ShortlistArchetypes) { return $ordered }

  $selected = New-Object System.Collections.Generic.List[object]
  $seenKeys = New-Object System.Collections.Generic.HashSet[string]
  $primary = $ordered | Select-Object -First 1
  Add-UniquePlanSelection -Selected $selected -SeenKeys $seenKeys -Candidate $primary

  foreach ($property in @("WidthTier", "FpsTier", "AudioTier", "PreprocessTier", "WidthOrigin")) {
    $baseline = Get-ObjectPropertyValue -Object $primary -Name $property -DefaultValue $null
    $candidate = $ordered | Where-Object { (Get-ObjectPropertyValue -Object $_ -Name $property -DefaultValue $null) -ne $baseline } | Select-Object -First 1
    Add-UniquePlanSelection -Selected $selected -SeenKeys $seenKeys -Candidate $candidate
    if ($selected.Count -ge $strategy.ShortlistArchetypes) { break }
  }

  foreach ($candidate in $ordered) {
    if ($selected.Count -ge $strategy.ShortlistArchetypes) { break }
    Add-UniquePlanSelection -Selected $selected -SeenKeys $seenKeys -Candidate $candidate
  }

  return @($selected.ToArray())
}

function Get-PlanPreferenceTuple {
  param(
    [Parameter(Mandatory = $true)]$Result
  )

  $plan = $Result.Plan
  $audioRank = if ($plan.AudioPlan -and $plan.AudioPlan.Rank) { [int]$plan.AudioPlan.Rank } else { 0 }
  $fillScore = [int](1000 - [math]::Min(999, [math]::Round([math]::Abs(1.0 - $Result.Ratio) * 1000)))
  $widthFitScore = [int](1000 - [math]::Min(999, [math]::Round([math]::Abs([math]::Log([math]::Max(0.001, $plan.WidthRatio))) * 1000)))
  $previewRank = [int](Get-ObjectPropertyValue -Object $plan -Name "PreviewRank" -DefaultValue 1)
  $previewRankScore = [int](1000 - [math]::Min(999, (($previewRank - 1) * 100)))

  switch ($plan.Mode) {
    "Fast" {
      return @(
        [int]$plan.Fps,
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Width,
        [int]$plan.VideoKbps
      )
    }

    "Balanced" {
      return @(
        $previewRankScore,
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps
      )
    }

    "ExtraQuality" {
      $presetRank = Get-X264PresetRank -preset $plan.Preset
      return @(
        $previewRankScore,
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps,
        [int]$presetRank
      )
    }
  }
}

function Get-PreviewPreferenceTuple {
  param(
    [Parameter(Mandatory = $true)]$Result
  )

  $plan = $Result.Plan
  $audioRank = if ($plan.AudioPlan -and $plan.AudioPlan.Rank) { [int]$plan.AudioPlan.Rank } else { 0 }
  $fillScore = [int](1000 - [math]::Min(999, [math]::Round([math]::Abs(1.0 - $Result.Ratio) * 1000)))
  $widthFitScore = [int](1000 - [math]::Min(999, [math]::Round([math]::Abs([math]::Log([math]::Max(0.001, $plan.WidthRatio))) * 1000)))

  switch ($plan.Mode) {
    "Fast" {
      return @(
        [int]$plan.Fps,
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Width,
        [int]$plan.VideoKbps
      )
    }

    "Balanced" {
      return @(
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps,
        [int]$plan.Score
      )
    }

    "ExtraQuality" {
      $presetRank = Get-X264PresetRank -preset $plan.Preset
      return @(
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps,
        [int]$plan.Score,
        [int]$presetRank
      )
    }
  }
}

function Test-IsBetterPreviewResult {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$Current
  )

  $candTuple = Get-PreviewPreferenceTuple -Result $Candidate
  $currTuple = Get-PreviewPreferenceTuple -Result $Current

  for ($i = 0; $i -lt $candTuple.Count; $i++) {
    if ($candTuple[$i] -gt $currTuple[$i]) { return $true }
    if ($candTuple[$i] -lt $currTuple[$i]) { return $false }
  }

  return $false
}

function Test-IsBetterResult {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$Current
  )

  $candTuple = Get-PlanPreferenceTuple -Result $Candidate
  $currTuple = Get-PlanPreferenceTuple -Result $Current

  for ($i = 0; $i -lt $candTuple.Count; $i++) {
    if ($candTuple[$i] -gt $currTuple[$i]) { return $true }
    if ($candTuple[$i] -lt $currTuple[$i]) { return $false }
  }

  return $false
}

function Update-BestResult {
  param(
    $Current,
    $Candidate
  )

  if ($null -eq $Candidate -or -not $Candidate.Success) {
    return $Current
  }

  if ($null -eq $Current) {
    return $Candidate
  }

  if (Test-IsBetterResult -Candidate $Candidate -Current $Current) {
    if ($Current.Path -and (Test-Path $Current.Path)) {
      Remove-Item $Current.Path -Force -ErrorAction SilentlyContinue
    }
    return $Candidate
  }

  if ($Candidate.Path -and (Test-Path $Candidate.Path)) {
    Remove-Item $Candidate.Path -Force -ErrorAction SilentlyContinue
  }
  return $Current
}

function Set-SearchStatsOnResult {
  param(
    $Result,
    [Parameter(Mandatory = $true)]$Stats
  )

  if ($null -eq $Result) { return $null }

  $Result | Add-Member -NotePropertyName SearchStats -NotePropertyValue $Stats -Force
  return $Result
}

function Invoke-FastModeSearch {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)]$AllPlans,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$PreviewsRun
  )

  $strategy = Get-ModeStrategy -Mode "Fast"
  $stats = [PSCustomObject]@{
    ProbeSamplesUsed   = 0
    PreviewsRun        = [int]$PreviewsRun
    FullEncodesRun     = 0
    SecondEncodeReason = ""
    PredictionBias     = 0.0
  }

  $primary = @($Plans | Select-Object -First 1)[0]
  $backup = @($Plans | Select-Object -Skip 1 -First 1)[0]

  Write-Host ("Testing primary:  {0}x{1} @{2}fps | codec={3} | v={4}k | a={5} | detail={6} | motion={7} | bpppf={8:N4} | preset={9} | width={10} | pp={11} | crop={12}" -f $primary.Width, $primary.Height, $primary.Fps, $primary.CodecProfile.VideoCodec, $primary.VideoKbps, $primary.AudioPlan.Label, $primary.DetailBucket, $primary.MotionBucket, $primary.Bpppf, $primary.Preset, $primary.WidthOrigin, $primary.PreprocessLabel, $primary.CropSummary)
  $primaryResult = Invoke-PlanAttempt -InputPath $InputPath -Plan $primary -TempDir $TempDir -Attempt 1
  $stats.FullEncodesRun++
  $stats.PredictionBias = [double]$primaryResult.PredictionBias
  $bestUnder = Update-BestResult -Current $null -Candidate $primaryResult

  if ($primaryResult.Success -and $primaryResult.Ratio -ge $strategy.EarlyAcceptRatio) {
    return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
  }

  $secondResult = $null
  if ($stats.FullEncodesRun -lt $strategy.MaxFullEncodes -and ($primaryResult.Ratio -gt 1.0 -or $primaryResult.Ratio -lt $strategy.BadUnderfillRatio)) {
    $useBackup = $false
    if ($backup) {
      if ($primaryResult.Ratio -gt 1.0) {
        $useBackup = Test-IsSaferFallbackPlan -Candidate $backup -ReferencePlan $primary
      }
      else {
        $useBackup = ((Test-IsMoreAggressiveFallbackPlan -Candidate $backup -ReferencePlan $primary) -and $backup.Score -gt $primary.Score)
      }
    }

    if ($useBackup) {
      $stats.SecondEncodeReason = "backup"
      $backupPlan = Get-CalibratedFallbackPlan -CandidatePlan $backup -ReferenceResult $primaryResult
      Write-Host ("Second-stage:    backup -> {0}x{1} @{2}fps | v={3}k | a={4} | pp={5}" -f $backupPlan.Width, $backupPlan.Height, $backupPlan.Fps, $backupPlan.VideoKbps, $backupPlan.AudioPlan.Label, $backupPlan.PreprocessLabel)
      $secondResult = Invoke-PlanAttempt -InputPath $InputPath -Plan $backupPlan -TempDir $TempDir -Attempt 2
    }
    else {
      $stats.SecondEncodeReason = "bitrate refinement"
      $secondResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $primary -CurrentResult $primaryResult -TempDir $TempDir -Attempt 2
    }

    if ($secondResult) {
      $stats.FullEncodesRun++
      $bestUnder = Update-BestResult -Current $bestUnder -Candidate $secondResult
    }
  }

  return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
}

function Invoke-BalancedModeSearch {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)]$AllPlans,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$PreviewsRun
  )

  $strategy = Get-ModeStrategy -Mode "Balanced"
  $stats = [PSCustomObject]@{
    ProbeSamplesUsed   = 0
    PreviewsRun        = [int]$PreviewsRun
    FullEncodesRun     = 0
    SecondEncodeReason = ""
    PredictionBias     = 0.0
  }

  $primary = @($Plans | Select-Object -First 1)[0]
  $challenger = @($Plans | Select-Object -Skip 1 -First 1)[0]
  $sharedPassLog = $null

  try {
    $sharedPassLog = Initialize-PlanPassLog -InputPath $InputPath -Plan $primary -TempDir $TempDir

    Write-Host ("Testing primary:  {0}x{1} @{2}fps | codec={3} | v={4}k | a={5} | detail={6} | motion={7} | bpppf={8:N4} | preset={9} | width={10} | pp={11} | crop={12}" -f $primary.Width, $primary.Height, $primary.Fps, $primary.CodecProfile.VideoCodec, $primary.VideoKbps, $primary.AudioPlan.Label, $primary.DetailBucket, $primary.MotionBucket, $primary.Bpppf, $primary.Preset, $primary.WidthOrigin, $primary.PreprocessLabel, $primary.CropSummary)
    $primaryResult = Invoke-PlanAttempt -InputPath $InputPath -Plan $primary -TempDir $TempDir -Attempt 1 -PassLogPath $sharedPassLog
    $stats.FullEncodesRun++
    $stats.PredictionBias = [double]$primaryResult.PredictionBias
    $bestUnder = Update-BestResult -Current $null -Candidate $primaryResult

    if ($primaryResult.Success -and $primaryResult.Ratio -ge $strategy.EarlyAcceptRatio) {
      return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
    }

    $needsSecondAction = (
      $primaryResult.Ratio -gt 1.0 -or
      $primaryResult.Ratio -lt $strategy.BadUnderfillRatio -or
      ($challenger -and $stats.PreviewsRun -eq 0)
    )

    if (-not $needsSecondAction) {
      return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
    }

    if ($stats.FullEncodesRun -ge $strategy.MaxFullEncodes) {
      return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
    }

    $actionOptions = New-Object System.Collections.Generic.List[object]
    $retryPlan = Get-RetryPlanFromResult -Plan $primary -Result $primaryResult
    if ($retryPlan) {
      $retryScore = [double]$primary.Score + 900.0
      if ($primaryResult.Ratio -gt 1.0 -and $primaryResult.Ratio -lt 1.03) { $retryScore += 300.0 }
      if ($primaryResult.Ratio -lt 1.0 -and $primaryResult.Ratio -gt 0.96) { $retryScore += 200.0 }
      [void]$actionOptions.Add([PSCustomObject]@{ Kind = "retune"; Score = $retryScore; Plan = $retryPlan })
    }

    if ($challenger) {
      $challengerPlan = Get-CalibratedFallbackPlan -CandidatePlan $challenger -ReferenceResult $primaryResult
      $challengerScore = [double]$challengerPlan.Score + 600.0 + ((1.0 - [double](Get-ObjectPropertyValue -Object $primary -Name "Confidence" -DefaultValue 1.0)) * 1000.0)
      [void]$actionOptions.Add([PSCustomObject]@{ Kind = "challenger"; Score = $challengerScore; Plan = $challengerPlan })
    }

    $fallbackPlan = @(Expand-PlanNeighborhood -ReferenceResult $primaryResult -AllPlans $AllPlans | Select-Object -First 1)[0]
    if ($fallbackPlan) {
      $fallbackScore = Get-SecondStageCandidateScore -Candidate $fallbackPlan -ReferenceResult $primaryResult
      [void]$actionOptions.Add([PSCustomObject]@{ Kind = "fallback"; Score = $fallbackScore; Plan = $fallbackPlan })
    }

    $selectedAction = @($actionOptions | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true } | Select-Object -First 1)[0]
    if ($null -eq $selectedAction) {
      return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
    }

    $stats.SecondEncodeReason = $selectedAction.Kind
    switch ($selectedAction.Kind) {
      "retune" {
        Write-Host ("Second-stage:    bitrate refinement -> {0}k" -f $selectedAction.Plan.VideoKbps)
        $secondResult = Invoke-PlanAttempt -InputPath $InputPath -Plan $selectedAction.Plan -TempDir $TempDir -Attempt 2 -PassLogPath $sharedPassLog
      }
      default {
        Write-Host ("Second-stage:    {0} -> {1}x{2} @{3}fps | v={4}k | a={5} | pp={6}" -f $selectedAction.Kind, $selectedAction.Plan.Width, $selectedAction.Plan.Height, $selectedAction.Plan.Fps, $selectedAction.Plan.VideoKbps, $selectedAction.Plan.AudioPlan.Label, $selectedAction.Plan.PreprocessLabel)
        $secondResult = Invoke-PlanAttempt -InputPath $InputPath -Plan $selectedAction.Plan -TempDir $TempDir -Attempt 2
      }
    }

    if ($secondResult) {
      $stats.FullEncodesRun++
      $bestUnder = Update-BestResult -Current $bestUnder -Candidate $secondResult
    }

    return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
  }
  finally {
    if ($sharedPassLog) {
      Remove-PassLogFiles -PassLogPath $sharedPassLog
    }
  }
}

function Invoke-ExtraQualityModeSearch {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plans,
    [Parameter(Mandatory = $true)]$AllPlans,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$PreviewsRun,
    [Parameter(Mandatory = $true)][bool]$PresetWasExplicit
  )

  $strategy = Get-ModeStrategy -Mode "ExtraQuality"
  $stats = [PSCustomObject]@{
    ProbeSamplesUsed   = 0
    PreviewsRun        = [int]$PreviewsRun
    FullEncodesRun     = 0
    SecondEncodeReason = ""
    PredictionBias     = 0.0
  }

  $bestUnder = $null
  $triedKeys = New-Object System.Collections.Generic.HashSet[string]
  $attempt = 0

  foreach ($plan in @($Plans | Select-Object -First 2)) {
    if ($attempt -ge $strategy.MaxFullEncodes) { break }
    $attempt++
    [void]$triedKeys.Add((Get-PlanKey -Plan $plan))
    Write-Host ("Testing finalist: {0}x{1} @{2}fps | codec={3} | v={4}k | a={5} | detail={6} | motion={7} | bpppf={8:N4} | preset={9} | width={10} | pp={11} | crop={12}" -f $plan.Width, $plan.Height, $plan.Fps, $plan.CodecProfile.VideoCodec, $plan.VideoKbps, $plan.AudioPlan.Label, $plan.DetailBucket, $plan.MotionBucket, $plan.Bpppf, $plan.Preset, $plan.WidthOrigin, $plan.PreprocessLabel, $plan.CropSummary)
    $result = Invoke-PlanAttempt -InputPath $InputPath -Plan $plan -TempDir $TempDir -Attempt $attempt
    $stats.FullEncodesRun++
    $stats.PredictionBias = [double]$result.PredictionBias
    $bestUnder = Update-BestResult -Current $bestUnder -Candidate $result

    if ($bestUnder -and $bestUnder.Ratio -ge $strategy.EarlyAcceptRatio -and $attempt -ge 2) {
      return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
    }
  }

  if ($attempt -lt $strategy.MaxFullEncodes) {
    $extraCandidates = New-Object System.Collections.Generic.List[object]
    $thirdFinalist = @($Plans | Select-Object -Skip 2 -First 1)[0]
    if ($thirdFinalist) { [void]$extraCandidates.Add($thirdFinalist) }

    if ($bestUnder) {
      foreach ($candidate in @(Expand-PlanNeighborhood -ReferenceResult $bestUnder -AllPlans $AllPlans -PresetWasExplicit:$PresetWasExplicit)) {
        if ($candidate) { [void]$extraCandidates.Add($candidate) }
      }
    }

    $selectedExtra = @(
      $extraCandidates |
        Where-Object { $null -ne $_ -and -not $triedKeys.Contains((Get-PlanKey -Plan $_)) } |
        Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { Get-ObjectPropertyValue -Object $_ -Name "Confidence" -DefaultValue 0.75 }; Descending = $true } |
        Select-Object -First 1
    )[0]

    if ($selectedExtra) {
      $attempt++
      $stats.SecondEncodeReason = "neighborhood"
      [void]$triedKeys.Add((Get-PlanKey -Plan $selectedExtra))
      Write-Host ("Exploring:       {0}x{1} @{2}fps | v={3}k | a={4} | pp={5} | preset={6}" -f $selectedExtra.Width, $selectedExtra.Height, $selectedExtra.Fps, $selectedExtra.VideoKbps, $selectedExtra.AudioPlan.Label, $selectedExtra.PreprocessLabel, $selectedExtra.Preset)
      $extraResult = Invoke-PlanAttempt -InputPath $InputPath -Plan $selectedExtra -TempDir $TempDir -Attempt $attempt
      $stats.FullEncodesRun++
      $bestUnder = Update-BestResult -Current $bestUnder -Candidate $extraResult
    }
  }

  if ($attempt -lt $strategy.MaxFullEncodes -and $bestUnder -and $bestUnder.Ratio -lt 0.996) {
    $attempt++
    $stats.SecondEncodeReason = "micro-fill"
    $retryResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $bestUnder.Plan -CurrentResult $bestUnder -TempDir $TempDir -Attempt $attempt
    if ($retryResult) {
      $stats.FullEncodesRun++
      $bestUnder = Update-BestResult -Current $bestUnder -Candidate $retryResult
    }
  }

  return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
}

function Get-BestResult {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][bool]$PresetWasExplicit,
    [Parameter(Mandatory = $true)][string]$PreprocessProfile
  )

  $planBundle = Get-PlanList -Info $Info -Probe $Probe -CodecProfile $CodecProfile -TargetBytes $TargetBytes -Mode $Mode -Preset $Preset -PreprocessProfile $PreprocessProfile
  $plans = @($planBundle.Plans)
  $audioCandidates = @($planBundle.AudioCandidates)

  if (-not $plans -or $plans.Count -eq 0 -or $null -eq $plans[0]) {
    throw "No viable encode plans were generated."
  }

  $archetypes = Get-PlanArchetypes -Plans $plans -Info $Info -Probe $Probe -TargetBytes $TargetBytes -Mode $Mode
  if (-not $archetypes -or $archetypes.Count -eq 0) {
    throw "No viable archetypal plans were generated."
  }

  $finalistBundle = Get-PlanFinalists -Info $Info -Plans $archetypes -InputPath $InputPath -TempDir $TempDir -Mode $Mode
  $finalists = @($finalistBundle.Plans)

  if (-not $finalists -or $finalists.Count -eq 0) {
    throw "No executable finalist plans were selected."
  }

  $result = switch ($Mode) {
    "Fast" {
      Invoke-FastModeSearch -InputPath $InputPath -Plans $finalists -AllPlans $plans -TempDir $TempDir -PreviewsRun $finalistBundle.PreviewsRun
    }
    "Balanced" {
      Invoke-BalancedModeSearch -InputPath $InputPath -Plans $finalists -AllPlans $plans -TempDir $TempDir -PreviewsRun $finalistBundle.PreviewsRun
    }
    default {
      Invoke-ExtraQualityModeSearch -InputPath $InputPath -Plans $finalists -AllPlans $plans -TempDir $TempDir -PreviewsRun $finalistBundle.PreviewsRun -PresetWasExplicit:$PresetWasExplicit
    }
  }

  if ($result -and $result.SearchStats) {
    $result.SearchStats.ProbeSamplesUsed = [int](Get-ObjectPropertyValue -Object $Probe -Name "ProbeSamplesUsed" -DefaultValue 0)
  }

  return $result
}

Require-Tool "ffmpeg"
Require-Tool "ffprobe"
Assert-TargetArguments

if (-not (Test-Path $InputFile)) {
  throw "Input file not found: $InputFile"
}

$inputFull = (Resolve-Path $InputFile).Path
$presetWasExplicit = -not [string]::IsNullOrWhiteSpace($Preset)
if ([string]::IsNullOrWhiteSpace($Preset)) {
  $Preset = Get-DefaultPresetForMode -mode $Mode
}

$codecProfile = Resolve-CodecProfile -VideoCodec $VideoCodec -Container $Container
Assert-CodecProfileSupport -CodecProfile $codecProfile

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
  $OutputFile = Get-DefaultOutputPath -InputPath $inputFull -CodecProfile $codecProfile
}

Assert-OutputFileMatchesProfile -OutputPath $OutputFile -CodecProfile $codecProfile

$info = Get-ProbeInfo -path $inputFull
$targetRequestBytes = Get-RequestedTargetBytes
$hasExplicitTarget = ($null -ne $targetRequestBytes)
$usableTargetBytes = if ($hasExplicitTarget) { [long][math]::Floor($targetRequestBytes * $SafetyMarginPercent) } else { 0L }
$totalKbps = if ($hasExplicitTarget) { (($usableTargetBytes * 8.0) / $info.Duration) / 1000.0 } else { 0.0 }
$cropResult = Invoke-CropDetect -Info $info -InputPath $inputFull -CropMode $CropMode
$info = Set-InfoPlanningContext -Info $info -CropResult $cropResult

Write-Host "Input:            $inputFull"
Write-Host "Duration:         $([math]::Round($info.Duration, 2)) s"
Write-Host "Source:           $($info.Width)x$($info.Height) @ $([math]::Round($info.Fps, 3)) fps"
Write-Host "Planning frame:   $(Get-PlanningWidth -Info $info)x$(Get-PlanningHeight -Info $info)"
Write-Host "Source codec:     $($info.VideoCodec)"
Write-Host "Video bitrate:    $(if ($info.VideoBitrateKbps) { "$($info.VideoBitrateKbps) kbps" } else { 'unknown' })"
Write-Host "Audio codec:      $(if ($info.HasAudio) { $info.AudioCodec } else { 'none' })"
Write-Host "Audio bitrate:    $(if ($info.AudioBitrateKbps) { "$($info.AudioBitrateKbps) kbps" } else { 'unknown' })"
if ($null -ne $TargetBytes) {
  Write-Host "Target size:      $TargetBytes bytes"
}
elseif ($null -ne $TargetMB) {
  Write-Host "Target size:      $TargetMB $TargetUnit"
}
else {
  Write-Host "Target size:      (none)"
}
Write-Host "Usable bytes:     $(if ($hasExplicitTarget) { $usableTargetBytes } else { '(n/a)' })"
Write-Host "Total budget:     $(if ($hasExplicitTarget) { '{0} kbps' -f ([math]::Round($totalKbps)) } else { '(n/a)' })"
Write-Host "Mode:             $Mode"
Write-Host "Output codec:     $($codecProfile.VideoCodec)"
Write-Host "Container:        $($codecProfile.Container)"
Write-Host "Preset:           $Preset"
Write-Host "Crop mode:        $CropMode"
Write-Host "Crop detect:      $(Get-CropSummary -Info $info)"
Write-Host "Preprocess:       $PreprocessProfile"
Write-Host "Output file:      $OutputFile"
Write-Host ""

$tempDir = Join-Path $env:TEMP ("compress_probe_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
  $probe = Invoke-ComplexityProbe `
    -Info $info `
    -InputPath $inputFull `
    -TempDir $tempDir `
    -Mode $Mode `
    -SampleSeconds $ProbeSampleSeconds
  $resolutionProfile = Get-ResolutionPlanningProfile -Info $info -Probe $probe -Mode $Mode

  Write-Host "Detail probe:     $($probe.DetailProbe.ProbeWidth)p @ $($probe.DetailProbe.ProbeFps) fps"
  if ($probe.MotionProbe) {
    Write-Host "Motion probe:     $($probe.MotionProbe.ProbeWidth)p @ $($probe.MotionProbe.ProbeFps) fps"
  }
  Write-Host "Probe CRF:        $($probe.ProbeCrf)"
  Write-Host "Detail avg kbps:  $($probe.DetailProbe.AvgKbps)"
  Write-Host "Detail peak-ish:  $($probe.DetailProbe.PeakishKbps)"
  Write-Host "Detail bucket:    $($probe.DetailBucket)"
  Write-Host "Motion ratio:     $($probe.MotionRatio)"
  Write-Host "Motion norm:      $($probe.MotionNormalized)"
  Write-Host "Motion bucket:    $($probe.MotionBucket)"
  Write-Host "Resolution bias:  $($resolutionProfile.BiasLabel) (ratio=$($resolutionProfile.SourceToProbeRatio), bpppf=$('{0:N4}' -f $resolutionProfile.TargetBpppf))"
  Write-Host ""

  $winner = Get-BestResult `
    -Info $info `
    -Probe $probe `
    -CodecProfile $codecProfile `
    -InputPath $inputFull `
    -TempDir $tempDir `
    -TargetBytes $usableTargetBytes `
    -Mode $Mode `
    -Preset $Preset `
    -PresetWasExplicit $presetWasExplicit `
    -PreprocessProfile $PreprocessProfile

  if (-not $winner -or -not $winner.Success) {
    throw "Could not get under target size with the current exact-size plan."
  }

  $winner.SizeBytes = Finalize-OutputFile -InputPath $winner.Path -OutputPath $OutputFile -CodecProfile $codecProfile

  Write-Host ""
  Write-Host "Done."
  Write-Host "Output file:      $OutputFile"
  Write-Host "Final size:       $($winner.SizeBytes) bytes ($([math]::Round($winner.SizeBytes / 1MB, 3)) MiB)"
  Write-Host "Chosen width:     $($winner.Plan.Width)"
  Write-Host "Chosen height:    $($winner.Plan.Height)"
  Write-Host "Chosen fps:       $($winner.Plan.Fps)"
  Write-Host "Chosen codec:     $($winner.Plan.CodecProfile.VideoCodec)"
  Write-Host "Container:        $($winner.Plan.CodecProfile.Container)"
  Write-Host "Video bitrate:    $($winner.Plan.VideoKbps) kbps"
  Write-Host "Chosen CRF:       $($winner.Plan.Crf)"
  Write-Host "Chosen audio:     $($winner.Plan.AudioPlan.Label)"
  Write-Host "Chosen preset:    $($winner.Plan.Preset)"
  Write-Host "Width origin:     $($winner.Plan.WidthOrigin)"
  Write-Host "Crop state:       $($winner.Plan.CropSummary)"
  Write-Host "Preprocess:       $($winner.Plan.PreprocessLabel)"
  Write-Host "Detail bucket:    $($winner.Plan.DetailBucket)"
  Write-Host "Motion bucket:    $($winner.Plan.MotionBucket)"
  Write-Host "Resolution bias:  $($winner.Plan.ResolutionBiasLabel)"
  Write-Host "Predicted bpppf:  $('{0:N4}' -f $winner.Plan.Bpppf)"
  Write-Host "Video args:       $(if ([string]::IsNullOrWhiteSpace($winner.Plan.VideoPrivateArgs)) { '(default)' } else { $winner.Plan.VideoPrivateArgs })"
  Write-Host "Video filter:     $(if ([string]::IsNullOrWhiteSpace($winner.Plan.VFilter)) { '(none)' } else { $winner.Plan.VFilter })"
  if ($winner.SearchStats) {
    Write-Host "Probe samples:    $($winner.SearchStats.ProbeSamplesUsed)"
    Write-Host "Previews run:     $($winner.SearchStats.PreviewsRun)"
    Write-Host "Full encodes:     $($winner.SearchStats.FullEncodesRun)"
    Write-Host "Second-stage:     $(if ([string]::IsNullOrWhiteSpace($winner.SearchStats.SecondEncodeReason)) { '(none)' } else { $winner.SearchStats.SecondEncodeReason })"
    Write-Host "Prediction bias:  $('{0:N3}' -f $winner.SearchStats.PredictionBias)"
  }
}
finally {
  if (Test-Path $tempDir) {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  $elapsed = (Get-Date) - $scriptStart
  Write-Host ""
  Write-Host ("Execution time:   {0:hh\:mm\:ss\.fff}" -f $elapsed)
}
