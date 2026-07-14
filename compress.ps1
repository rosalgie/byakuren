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

  [ValidateSet("x264", "x265", "av1", "auto")]
  [string]$VideoCodec = "x264",

  [AllowEmptyString()]
  [string]$Container = "",

  [AllowEmptyString()]
  [string]$OutputFile = "",

  [AllowEmptyString()]
  [string]$Preset = "",

  [double]$SafetyMarginPercent = 0.995,

  [int]$ProbeSampleSeconds = 6,

  [ValidateSet("off", "xpsnr", "vmaf", "auto")]
  [string]$MetricMode = "auto",

  [ValidateSet("fixed", "sceneaware", "auto")]
  [string]$SampleMode = "auto",

  [ValidateSet("off", "auto")]
  [string]$ContentClassMode = "auto",

  [ValidateSet("widest", "modern", "unrestricted")]
  [string]$CompatibilityMode = "widest",

  [ValidateSet("visual", "balanced", "speech")]
  [string]$AudioPriority = "balanced",

  [int]$MetricSampleSeconds = 0,

  [int]$MetricMaxSamples = 0,

  [switch]$EnablePlanLogging,

  [AllowEmptyString()]
  [string]$PlanLogPath = "",

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
    [string]$WorkingDirectory = "",
    [switch]$AllowFailure
  )

  if ($VerboseCommands) {
    $quoted = $Args | ForEach-Object {
      if ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }
    Write-Host ("CMD> {0} {1}" -f $Exe, ($quoted -join ' '))
  }

  if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    & $Exe @Args
  }
  else {
    Push-Location $WorkingDirectory
    try {
      & $Exe @Args
    }
    finally {
      Pop-Location
    }
  }
  $code = $LASTEXITCODE

  if (-not $AllowFailure -and $code -ne 0) {
    throw "$Exe failed with exit code $code."
  }
}

function Invoke-ToolCapture {
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string[]]$Args,
    [string]$WorkingDirectory = "",
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
    $quotedArgs = foreach ($arg in $Args) {
      if ($null -eq $arg -or $arg -eq "") {
        '""'
        continue
      }

      if ($arg -notmatch '[\s"]') {
        $arg
        continue
      }

      $builder = New-Object System.Text.StringBuilder
      [void]$builder.Append('"')
      $backslashCount = 0
      foreach ($character in $arg.ToCharArray()) {
        if ($character -eq '\') {
          $backslashCount++
          continue
        }

        if ($character -eq '"') {
          if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * ($backslashCount * 2)))
            $backslashCount = 0
          }
          [void]$builder.Append('\"')
          continue
        }

        if ($backslashCount -gt 0) {
          [void]$builder.Append(('\' * $backslashCount))
          $backslashCount = 0
        }

        [void]$builder.Append($character)
      }

      if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
      }

      [void]$builder.Append('"')
      $builder.ToString()
    }

    $startInfo = @{
      FilePath = $Exe
      ArgumentList = ($quotedArgs -join ' ')
      NoNewWindow = $true
      Wait = $true
      PassThru = $true
      RedirectStandardOutput = $stdoutPath
      RedirectStandardError = $stderrPath
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
      $startInfo["WorkingDirectory"] = $WorkingDirectory
    }

    $process = Start-Process @startInfo

    $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
    $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }
    $code = [int]$process.ExitCode

    if (-not $AllowFailure -and $code -ne 0) {
      throw "$Exe failed with exit code $code."
    }

    return [PSCustomObject]@{
      ExitCode = [int]$code
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
$script:FfmpegFiltersText = $null
$script:RuntimeCapabilities = $null
$script:PlanLogPathResolved = ""

function Get-NormalizedOptionValue {
  param(
    [AllowEmptyString()][string]$Value,
    [string]$DefaultValue = ""
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $DefaultValue
  }

  return $Value.Trim().ToLowerInvariant()
}

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

function Get-FfmpegFiltersText {
  if ($null -eq $script:FfmpegFiltersText) {
    $script:FfmpegFiltersText = (Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-filters")).Output
  }

  return [string]$script:FfmpegFiltersText
}

function Test-FfmpegEncoderAvailable([string]$Encoder) {
  $pattern = ('(?m)^\s*[A-Z\.]+\s+{0}\s' -f [regex]::Escape($Encoder))
  return ([regex]::IsMatch((Get-FfmpegEncodersText), $pattern))
}

function Test-FfmpegMuxerAvailable([string]$Muxer) {
  $pattern = ('(?m)^\s*E\s+{0}\s' -f [regex]::Escape($Muxer))
  return ([regex]::IsMatch((Get-FfmpegMuxersText), $pattern))
}

function Test-FfmpegFilterAvailable([string]$Filter) {
  $pattern = ('(?m)^\s*[TSC\.\|AVN]+\s+{0}\s' -f [regex]::Escape($Filter))
  return ([regex]::IsMatch((Get-FfmpegFiltersText), $pattern))
}

function Get-RuntimeCapabilities {
  if ($null -ne $script:RuntimeCapabilities) {
    return $script:RuntimeCapabilities
  }

  $x264Available = Test-FfmpegEncoderAvailable -Encoder "libx264"
  $x265Available = Test-FfmpegEncoderAvailable -Encoder "libx265"
  $av1Available = Test-FfmpegEncoderAvailable -Encoder "libsvtav1"
  $mp4Available = Test-FfmpegMuxerAvailable -Muxer "mp4"
  $webmAvailable = Test-FfmpegMuxerAvailable -Muxer "webm"
  $aacAvailable = Test-FfmpegEncoderAvailable -Encoder "aac"
  $opusAvailable = (Test-FfmpegEncoderAvailable -Encoder "libopus") -or (Test-FfmpegEncoderAvailable -Encoder "opus")
  $hasVmaf = Test-FfmpegFilterAvailable -Filter "libvmaf"
  $hasXpsnr = Test-FfmpegFilterAvailable -Filter "xpsnr"
  $hasScdet = Test-FfmpegFilterAvailable -Filter "scdet"

  $capabilities = [PSCustomObject]@{
    HasLibVmaf             = [bool]$hasVmaf
    HasXpsnr               = [bool]$hasXpsnr
    HasScdet               = [bool]$hasScdet
    HasX264                = [bool]$x264Available
    HasX265                = [bool]$x265Available
    HasAv1                 = [bool]$av1Available
    HasMp4Muxer            = [bool]$mp4Available
    HasWebmMuxer           = [bool]$webmAvailable
    HasAac                 = [bool]$aacAvailable
    HasOpus                = [bool]$opusAvailable
    SupportsX264Mp4        = [bool]($x264Available -and $mp4Available -and $aacAvailable)
    SupportsX265Mp4        = [bool]($x265Available -and $mp4Available -and $aacAvailable)
    SupportsAv1Webm        = [bool]($av1Available -and $webmAvailable -and $opusAvailable)
    PreferredMetricMode    = if ($hasVmaf) { "vmaf" } elseif ($hasXpsnr) { "xpsnr" } else { "off" }
    PreferredSamplingMode  = if ($hasScdet) { "sceneaware" } else { "fixed" }
  }

  $script:RuntimeCapabilities = $capabilities
  return $capabilities
}

function Resolve-PolicyProfile {
  param(
    [Parameter(Mandatory = $true)][string]$RequestedVideoCodec,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RequestedContainer,
    [Parameter(Mandatory = $true)][string]$RequestedMetricMode,
    [Parameter(Mandatory = $true)][string]$RequestedSampleMode,
    [Parameter(Mandatory = $true)][string]$RequestedContentClassMode,
    [Parameter(Mandatory = $true)][string]$CompatibilityMode,
    [Parameter(Mandatory = $true)][string]$AudioPriority,
    [Parameter(Mandatory = $true)][string]$Mode,
    [double]$TotalKbps = 0.0
  )

  $caps = Get-RuntimeCapabilities
  $requestedCodec = Get-NormalizedOptionValue -Value $RequestedVideoCodec -DefaultValue "x264"
  $requestedContainerValue = Get-NormalizedOptionValue -Value $RequestedContainer -DefaultValue "auto"
  $requestedMetric = Get-NormalizedOptionValue -Value $RequestedMetricMode -DefaultValue "auto"
  $requestedSample = Get-NormalizedOptionValue -Value $RequestedSampleMode -DefaultValue "auto"
  $requestedContentClass = Get-NormalizedOptionValue -Value $RequestedContentClassMode -DefaultValue "auto"
  $compatibility = Get-NormalizedOptionValue -Value $CompatibilityMode -DefaultValue "widest"

  if ($requestedContainerValue -notin @("auto", "mp4", "webm")) {
    throw "Unsupported container '$RequestedContainer'. Supported containers are mp4, webm, and auto."
  }

  if ($requestedCodec -notin @("x264", "x265", "av1", "auto")) {
    throw "Unsupported video codec '$RequestedVideoCodec'. Supported codecs are x264, x265, av1, and auto."
  }

  $codecPinned = ($requestedCodec -ne "auto")
  $containerPinned = ($requestedContainerValue -ne "auto")
  $metricModeUsed = if ($requestedMetric -eq "auto") { [string]$caps.PreferredMetricMode } else { $requestedMetric }
  $samplingModeUsed = if ($requestedSample -eq "auto") { [string]$caps.PreferredSamplingMode } else { $requestedSample }
  $contentClassModeUsed = if ($requestedContentClass -eq "off") { "off" } else { "auto" }

  if ($Mode -eq "Fast" -and $requestedMetric -eq "auto") {
    $metricModeUsed = "off"
  }

  $selectedCodec = $requestedCodec
  $selectedContainer = $requestedContainerValue
  $codecReason = if ($codecPinned) { "pinned" } else { "" }
  $containerReason = if ($containerPinned) { "pinned" } else { "" }

  if (-not $codecPinned -or -not $containerPinned) {
    $pairs = New-Object System.Collections.Generic.List[object]
    switch ($compatibility) {
      "modern" {
        if ($caps.SupportsAv1Webm) {
          [void]$pairs.Add([PSCustomObject]@{ VideoCodec = "av1"; Container = "webm"; Reason = "modern-primary"; AudioCodec = "opus" })
        }
        if ($caps.SupportsX264Mp4) {
          [void]$pairs.Add([PSCustomObject]@{ VideoCodec = "x264"; Container = "mp4"; Reason = "modern-fallback"; AudioCodec = "aac" })
        }
      }
      "unrestricted" {
        if ($caps.SupportsAv1Webm) {
          [void]$pairs.Add([PSCustomObject]@{
              VideoCodec = "av1"
              Container  = "webm"
              Reason     = if ($Mode -eq "ExtraQuality" -or $TotalKbps -le 1600) { "unrestricted-av1-retention" } else { "unrestricted-av1" }
              AudioCodec = "opus"
            })
        }
        if ($Mode -ne "Fast" -and $caps.SupportsX265Mp4 -and $requestedContainerValue -in @("auto", "mp4")) {
          [void]$pairs.Add([PSCustomObject]@{ VideoCodec = "x265"; Container = "mp4"; Reason = "unrestricted-x265"; AudioCodec = "aac" })
        }
        if ($caps.SupportsX264Mp4) {
          [void]$pairs.Add([PSCustomObject]@{ VideoCodec = "x264"; Container = "mp4"; Reason = "unrestricted-x264-fallback"; AudioCodec = "aac" })
        }
      }
      default {
        if ($caps.SupportsX264Mp4) {
          [void]$pairs.Add([PSCustomObject]@{ VideoCodec = "x264"; Container = "mp4"; Reason = "widest-default"; AudioCodec = "aac" })
        }
        if ($Mode -ne "Fast" -and $caps.SupportsAv1Webm) {
          [void]$pairs.Add([PSCustomObject]@{ VideoCodec = "av1"; Container = "webm"; Reason = "widest-secondary"; AudioCodec = "opus" })
        }
        if ($Mode -ne "Fast" -and $caps.SupportsX265Mp4) {
          [void]$pairs.Add([PSCustomObject]@{ VideoCodec = "x265"; Container = "mp4"; Reason = "widest-tertiary"; AudioCodec = "aac" })
        }
      }
    }

    $selectedPair = $pairs | Where-Object {
      (($requestedCodec -eq "auto") -or $_.VideoCodec -eq $requestedCodec) -and
      (($requestedContainerValue -eq "auto") -or $_.Container -eq $requestedContainerValue)
    } | Select-Object -First 1

    if ($null -eq $selectedPair -and $codecPinned -and $containerPinned) {
      $selectedPair = [PSCustomObject]@{
        VideoCodec = $requestedCodec
        Container  = $requestedContainerValue
        Reason     = "pinned"
        AudioCodec = if ($requestedContainerValue -eq "webm") { "opus" } else { "aac" }
      }
    }

    if ($null -eq $selectedPair) {
      throw "Could not resolve a supported codec/container pair for codec='$RequestedVideoCodec' container='$RequestedContainer'."
    }

    if (-not $codecPinned) {
      $selectedCodec = [string]$selectedPair.VideoCodec
      $codecReason = [string]$selectedPair.Reason
    }

    if (-not $containerPinned) {
      $selectedContainer = [string]$selectedPair.Container
      $containerReason = [string]$selectedPair.Reason
    }
  }

  if ($selectedContainer -eq "auto") {
    $selectedContainer = if ($selectedCodec -eq "av1") { "webm" } else { "mp4" }
    if ([string]::IsNullOrWhiteSpace($containerReason)) {
      $containerReason = "codec-default"
    }
  }

  $defaultAudioCodec = if ($selectedContainer -eq "webm") { "opus" } else { "aac" }

  return [PSCustomObject]@{
    VideoCodec                 = [string]$selectedCodec
    Container                  = [string]$selectedContainer
    DefaultAudioCodec          = [string]$defaultAudioCodec
    MetricModeUsed             = [string]$metricModeUsed
    SamplingModeUsed           = [string]$samplingModeUsed
    ContentClassModeUsed       = [string]$contentClassModeUsed
    CodecPolicyReason          = if ([string]::IsNullOrWhiteSpace($codecReason)) { "codec-default" } else { [string]$codecReason }
    ContainerPolicyReason      = if ([string]::IsNullOrWhiteSpace($containerReason)) { "container-default" } else { [string]$containerReason }
    RequestedVideoCodec        = [string]$requestedCodec
    RequestedContainer         = [string]$requestedContainerValue
    CompatibilityMode          = [string]$compatibility
    AudioPriority              = (Get-NormalizedOptionValue -Value $AudioPriority -DefaultValue "balanced")
    CodecPinned                = [bool]$codecPinned
    ContainerPinned            = [bool]$containerPinned
    CanChangeCodecInSecondStage = [bool](-not $codecPinned)
    CanChangeContainerInSecondStage = [bool](-not $containerPinned)
  }
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
  $normalizedCodec = Get-NormalizedOptionValue -Value $VideoCodec -DefaultValue "x264"
  $normalizedContainer = Get-NormalizedOptionValue -Value $Container -DefaultValue "auto"

  if ($normalizedContainer -eq "auto") {
    switch ($normalizedCodec) {
      "av1"  { return "webm" }
      default { return "mp4" }
    }
  }

  if ($normalizedContainer -notin @("mp4", "webm")) {
    throw "Unsupported container '$Container'. Supported containers are mp4, webm, and auto."
  }

  return $normalizedContainer
}

function Resolve-CodecProfile {
  param(
    [Parameter(Mandatory = $true)][string]$VideoCodec,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Container
  )

  $resolvedContainer = Get-ResolvedContainer -VideoCodec $VideoCodec -Container $Container

  switch ("$(Get-NormalizedOptionValue -Value $VideoCodec)|$resolvedContainer") {
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

  $pixelFormat = [string](Get-ObjectPropertyValue -Object $video -Name "pix_fmt" -DefaultValue "")
  $videoBitDepth = 8
  $rawBitDepthText = [string](Get-ObjectPropertyValue -Object $video -Name "bits_per_raw_sample" -DefaultValue "")
  $parsedBitDepth = 0
  if ([int]::TryParse($rawBitDepthText, [ref]$parsedBitDepth) -and $parsedBitDepth -gt 0) {
    $videoBitDepth = $parsedBitDepth
  }
  elseif ($pixelFormat -match '(?:p0?|gray)(?<depth>9|10|12|14|16)(?:le|be)?$') {
    $videoBitDepth = [int]$matches["depth"]
  }

  [PSCustomObject]@{
    Duration         = [double]::Parse($probe.format.duration, [Globalization.CultureInfo]::InvariantCulture)
    Width            = [int]$video.width
    Height           = [int]$video.height
    Fps              = $srcFps
    VideoCodec       = [string]$video.codec_name
    PixelFormat      = $pixelFormat
    VideoBitDepth    = $videoBitDepth
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

function Build-PreprocessFilterChain {
  param(
    [AllowEmptyString()][string]$PreprocessProfileName
  )

  $profile = Get-NormalizedOptionValue -Value $PreprocessProfileName -DefaultValue "none"
  switch ($profile) {
    "mild-denoise"     { return "hqdn3d=1.2:1.0:3.0:3.0" }
    "temporal-denoise" { return "hqdn3d=1.8:1.4:4.5:4.5" }
    "deband"           { return "deband=1thr=0.02:2thr=0.02:3thr=0.02:4thr=0.02:range=12:blur=1" }
    "screen-sharpen"   { return "unsharp=3:3:0.25:3:3:0.00" }
    "ringing-reduction" { return "hqdn3d=0.8:0.6:2.0:2.0,smartblur=1.0:-0.25" }
    default            { return "" }
  }
}

function Build-Vf {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][double]$TargetFps,
    [switch]$UseDenoise,
    [AllowEmptyString()][string]$PreprocessProfileName = "",
    [string]$ScaleFlags = "lanczos"
  )

  $parts = @()
  $planningWidth = Get-PlanningWidth -Info $Info
  $cropFilter = Get-CropFilterString -Info $Info
  $effectiveProfile = if (-not [string]::IsNullOrWhiteSpace($PreprocessProfileName)) {
    Get-NormalizedOptionValue -Value $PreprocessProfileName -DefaultValue "none"
  }
  elseif ($UseDenoise) {
    "mild-denoise"
  }
  else {
    "none"
  }

  if (-not [string]::IsNullOrWhiteSpace($cropFilter)) {
    $parts += $cropFilter
  }

  if ($TargetFps -gt 0 -and $Info.Fps -gt ($TargetFps + 0.01)) {
    $parts += ("fps={0}" -f $TargetFps)
  }

  if ($TargetWidth -lt $planningWidth) {
    $parts += ("scale={0}:-2:flags={1}" -f $TargetWidth, $ScaleFlags)
  }

  $preprocessFilter = Build-PreprocessFilterChain -PreprocessProfileName $effectiveProfile
  if (-not [string]::IsNullOrWhiteSpace($preprocessFilter)) {
    $parts += $preprocessFilter
  }

  return ($parts -join ",")
}

function Test-ShouldAddDebandPlan {
  param(
    [Parameter(Mandatory = $true)][string]$ContentClass,
    [Parameter(Mandatory = $true)][double]$TotalBudgetKbps,
    [Parameter(Mandatory = $true)][double]$Bpppf
  )

  return ($ContentClass -eq "anime" -and ($TotalBudgetKbps -lt 900 -or $Bpppf -lt 0.045))
}

function Test-ShouldAddSharpenPlan {
  param(
    [Parameter(Mandatory = $true)][string]$ContentClass,
    [Parameter(Mandatory = $true)][double]$TotalBudgetKbps,
    [Parameter(Mandatory = $true)][double]$Bpppf
  )

  return ($ContentClass -eq "screen" -and $TotalBudgetKbps -lt 1500 -and $Bpppf -lt 0.10)
}

function Test-ShouldAddRingingReductionPlan {
  param(
    [Parameter(Mandatory = $true)][string]$ContentClass,
    [Parameter(Mandatory = $true)][double]$TotalBudgetKbps,
    [Parameter(Mandatory = $true)][double]$Bpppf
  )

  return ($ContentClass -in @("anime", "noisy_camera") -and ($TotalBudgetKbps -lt 950 -or $Bpppf -lt 0.040))
}

function Get-PreprocessCandidates {
  param(
    [Parameter(Mandatory = $true)][string]$RequestedProfile,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$ContentClass,
    [Parameter(Mandatory = $true)][double]$TotalBudgetKbps,
    [Parameter(Mandatory = $true)][double]$Bpppf
  )

  $requested = Get-NormalizedOptionValue -Value $RequestedProfile -DefaultValue "auto"
  if ($requested -eq "off") { return @("none") }
  if ($requested -eq "mild") { return @("mild-denoise") }

  $profiles = New-Object System.Collections.Generic.List[string]
  [void]$profiles.Add("none")

  if ($Mode -in @("Balanced", "ExtraQuality")) {
    if ($ContentClass -eq "noisy_camera" -and ($TotalBudgetKbps -lt 1100 -or $Bpppf -lt 0.055)) {
      [void]$profiles.Add("temporal-denoise")
    }
    elseif ($ContentClass -notin @("screen", "anime") -and ($TotalBudgetKbps -lt 700 -or $Bpppf -lt 0.028)) {
      [void]$profiles.Add("mild-denoise")
    }

    if (Test-ShouldAddDebandPlan -ContentClass $ContentClass -TotalBudgetKbps $TotalBudgetKbps -Bpppf $Bpppf) {
      [void]$profiles.Add("deband")
    }
    if (Test-ShouldAddSharpenPlan -ContentClass $ContentClass -TotalBudgetKbps $TotalBudgetKbps -Bpppf $Bpppf) {
      [void]$profiles.Add("screen-sharpen")
    }
    if (Test-ShouldAddRingingReductionPlan -ContentClass $ContentClass -TotalBudgetKbps $TotalBudgetKbps -Bpppf $Bpppf) {
      [void]$profiles.Add("ringing-reduction")
    }
  }

  return @($profiles | Select-Object -Unique)
}

function Get-TargetFpsCandidates($srcFps, $mode, $duration, $totalKbps, $motionBucket, $detailBucket, $CodecProfile = $null, [string]$ContentClass = "general") {
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

  if ($null -ne $CodecProfile) {
    if ($CodecProfile.VideoCodec -eq "x264" -and $totalKbps -lt 950) {
      if ($srcFps -gt 24) { $list.Add(24) }
      if ($srcFps -gt 30) { $list.Add(30) }
    }

    if ($CodecProfile.VideoCodec -eq "av1" -and $mode -eq "ExtraQuality" -and $srcFps -gt 30 -and $totalKbps -ge 550) {
      $list.Insert(0, $roundedSrc)
    }
  }

  if ($ContentClass -eq "screen" -and $srcFps -le 30.5) {
    $list.Insert(0, $roundedSrc)
  }

  return $list | Where-Object { $_ -gt 0 } | Select-Object -Unique
}

function Get-AudioPlanCandidates {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][double]$TotalKbps,
    [Parameter(Mandatory = $true)][double]$Duration,
    [Parameter(Mandatory = $true)][string]$ProbeBucket,
    [string]$AudioPriority = "balanced",
    [string]$ContentClass = "general"
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

  $audioPriorityNormalized = Get-NormalizedOptionValue -Value $AudioPriority -DefaultValue "balanced"
  $contentAudioBias = switch ($ContentClass) {
    "talking_head" { 8 }
    default        { 0 }
  }
  $priorityBias = switch ($audioPriorityNormalized) {
    "speech" { 12 }
    "visual" { -8 }
    default  { 0 }
  }
  $combinedBias = $contentAudioBias + $priorityBias
  if ($combinedBias -ne 0) {
    $baseList = $baseList | ForEach-Object { [int][math]::Max(32, $_ + $combinedBias) } | Select-Object -Unique
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

function New-SampleWindow {
  param(
    [double]$Start,
    [double]$Duration,
    [string]$Source = "fixed",
    [double]$SceneScore = 0.0,
    [double]$DifficultyScore = 0.0,
    [string]$Tag = ""
  )

  $safeDuration = [math]::Max(0.25, [double]$Duration)
  $safeStart = [math]::Max(0.0, [double]$Start)
  return [PSCustomObject]@{
    Start           = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $safeStart)), [Globalization.CultureInfo]::InvariantCulture)
    Duration        = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $safeDuration)), [Globalization.CultureInfo]::InvariantCulture)
    End             = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", ($safeStart + $safeDuration))), [Globalization.CultureInfo]::InvariantCulture)
    Source          = [string]$Source
    SceneScore      = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F4}", $SceneScore)), [Globalization.CultureInfo]::InvariantCulture)
    DifficultyScore = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $DifficultyScore)), [Globalization.CultureInfo]::InvariantCulture)
    Tag             = [string]$Tag
  }
}

function Get-SampleWindowKey {
  param(
    [Parameter(Mandatory = $true)]$Window
  )

  return ("{0:F3}|{1:F3}" -f [double]$Window.Start, [double]$Window.Duration)
}

function Get-FixedSampleWindows {
  param(
    [Parameter(Mandatory = $true)][double]$Duration,
    [Parameter(Mandatory = $true)][int]$SampleLength,
    [Parameter(Mandatory = $true)][int]$MaxSamples
  )

  $offsets = Get-SampleOffsets -duration $Duration -sampleLength $SampleLength -maxSamples $MaxSamples
  $windows = New-Object System.Collections.Generic.List[object]
  foreach ($offset in @($offsets)) {
    $tag = if ($offset -le 0.1) {
      "early"
    }
    elseif ($offset -ge [math]::Max(0.0, $Duration - ($SampleLength * 1.4))) {
      "late"
    }
    else {
      "representative"
    }

    [void]$windows.Add((New-SampleWindow -Start $offset -Duration $SampleLength -Source "fixed" -Tag $tag))
  }

  return @($windows.ToArray())
}

function Get-SceneMetadataCandidates {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][int]$SampleLength
  )

  $vfArg = "fps=6,scale=320:-2:flags=bicubic,scdet=threshold=10,metadata=print:file=-"
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-i", $InputPath, "-vf", $vfArg, "-an", "-f", "null", "NUL") -AllowFailure
  if ($capture.ExitCode -ne 0) { return @() }

  $candidates = New-Object System.Collections.Generic.List[object]
  $currentPts = $null
  foreach ($line in ($capture.Output -split "`r?`n")) {
    if ($line -match 'pts_time:(?<pts>-?\d+(?:\.\d+)?)') {
      $currentPts = [double]::Parse($matches["pts"], [Globalization.CultureInfo]::InvariantCulture)
      continue
    }

    if ($null -ne $currentPts -and $line -match 'lavfi\.scd\.score=(?<score>-?\d+(?:\.\d+)?)') {
      $score = [double]::Parse($matches["score"], [Globalization.CultureInfo]::InvariantCulture)
      if ($score -ge 0.10) {
        $windowStart = [math]::Max(0.0, [math]::Min([double]$currentPts - ($SampleLength / 2.0), [math]::Max(0.0, $Info.Duration - $SampleLength - 0.1)))
        [void]$candidates.Add((New-SampleWindow -Start $windowStart -Duration $SampleLength -Source "scdet" -SceneScore $score -Tag "scene"))
      }
      $currentPts = $null
    }
  }

  return @($candidates | Sort-Object -Property @{ Expression = { $_.SceneScore }; Descending = $true }, @{ Expression = { $_.Start }; Descending = $false })
}

function Get-SelectSceneCandidates {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][int]$SampleLength
  )

  $vfArg = "fps=6,scale=320:-2:flags=bicubic,select='gt(scene,0.12)',showinfo"
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-i", $InputPath, "-vf", $vfArg, "-an", "-f", "null", "NUL") -AllowFailure
  if ($capture.ExitCode -ne 0) { return @() }

  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($line in ($capture.Output -split "`r?`n")) {
    if ($line -match 'pts_time:(?<pts>-?\d+(?:\.\d+)?)') {
      $pts = [double]::Parse($matches["pts"], [Globalization.CultureInfo]::InvariantCulture)
      $windowStart = [math]::Max(0.0, [math]::Min([double]$pts - ($SampleLength / 2.0), [math]::Max(0.0, $Info.Duration - $SampleLength - 0.1)))
      [void]$candidates.Add((New-SampleWindow -Start $windowStart -Duration $SampleLength -Source "select-scene" -SceneScore 0.12 -Tag "scene"))
    }
  }

  return @($candidates | Sort-Object Start -Unique)
}

function Score-SampleWindowDifficulty {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)]$Window
  )

  $proxyLength = [int][math]::Max(1, [math]::Min(2, [math]::Round([double]$Window.Duration / 2.0)))
  $probeWidth = if ((Get-PlanningWidth -Info $Info) -ge 854) { 320 } else { [int][math]::Min((Get-PlanningWidth -Info $Info), 240) }
  $probeFps = if ($Info.Fps -gt 24.5) { 18 } else { [int][math]::Max(12, [math]::Round($Info.Fps)) }
  $proxyPath = Join-Path $TempDir ("difficulty_{0}.mp4" -f ([guid]::NewGuid().ToString("N")))
  $vfArg = Build-Vf -Info $Info -TargetWidth $probeWidth -TargetFps $probeFps -ScaleFlags "bicubic"

  try {
    $args = @("-y", "-ss", "$($Window.Start)", "-t", "$proxyLength", "-i", $InputPath)
    if (-not [string]::IsNullOrWhiteSpace($vfArg)) { $args += @("-vf", $vfArg) }
    $args += @("-an", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "30", $proxyPath)
    [void](Invoke-Tool -Exe "ffmpeg" -Args $args)

    if (-not (Test-Path $proxyPath)) {
      return 0.0
    }

    $bytes = (Get-Item $proxyPath).Length
    return (($bytes * 8.0) / [double][math]::Max(1, $proxyLength)) / 1000.0
  }
  catch {
    return 0.0
  }
  finally {
    Remove-Item $proxyPath -Force -ErrorAction SilentlyContinue
  }
}

function Merge-SampleWindows {
  param(
    [Parameter(Mandatory = $true)]$Windows,
    [Parameter(Mandatory = $true)][double]$Duration,
    [Parameter(Mandatory = $true)][int]$SampleLength,
    [Parameter(Mandatory = $true)][int]$MaxSamples
  )

  $all = @($Windows | Where-Object { $null -ne $_ })
  if ($all.Count -eq 0) { return @() }

  $deduped = New-Object System.Collections.Generic.List[object]
  foreach ($window in @($all | Sort-Object Start)) {
    $existing = $deduped | Where-Object {
      [math]::Abs([double]$_.Start - [double]$window.Start) -lt ([double]$SampleLength * 0.60)
    } | Select-Object -First 1

    if ($null -eq $existing) {
      [void]$deduped.Add($window)
      continue
    }

    $existingCombined = ([double]$existing.SceneScore * 150.0) + [double]$existing.DifficultyScore
    $windowCombined = ([double]$window.SceneScore * 150.0) + [double]$window.DifficultyScore
    if ($windowCombined -gt $existingCombined) {
      [void]$deduped.Remove($existing)
      [void]$deduped.Add($window)
    }
  }

  $midpoint = [double][math]::Max(0.0, ($Duration - $SampleLength) / 2.0)
  $selected = New-Object System.Collections.Generic.List[object]
  $seen = New-Object System.Collections.Generic.HashSet[string]

  foreach ($candidate in @(
      ($deduped | Sort-Object Start | Select-Object -First 1),
      ($deduped | Sort-Object Start -Descending | Select-Object -First 1),
      ($deduped | Sort-Object { [math]::Abs([double]$_.Start - $midpoint) } | Select-Object -First 1),
      ($deduped | Sort-Object -Property @{ Expression = { $_.SceneScore }; Descending = $true }, @{ Expression = { $_.Start }; Descending = $false } | Select-Object -First 1),
      ($deduped | Sort-Object -Property @{ Expression = { $_.DifficultyScore }; Descending = $true }, @{ Expression = { $_.SceneScore }; Descending = $true } | Select-Object -First 1)
    )) {
    if ($null -eq $candidate) { continue }
    $key = Get-SampleWindowKey -Window $candidate
    if ($seen.Add($key)) {
      [void]$selected.Add($candidate)
    }
  }

  foreach ($candidate in @($deduped | Sort-Object -Property @{ Expression = { ([double]$_.DifficultyScore * 1.0) + ([double]$_.SceneScore * 150.0) }; Descending = $true }, @{ Expression = { $_.Start }; Descending = $false })) {
    if ($selected.Count -ge $MaxSamples) { break }
    $key = Get-SampleWindowKey -Window $candidate
    if ($seen.Add($key)) {
      [void]$selected.Add($candidate)
    }
  }

  return @($selected.ToArray() | Sort-Object Start | Select-Object -First $MaxSamples)
}

function Get-SceneAwareSampleWindows {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$SampleLength,
    [Parameter(Mandatory = $true)][int]$MaxSamples
  )

  $caps = Get-RuntimeCapabilities
  $fixedWindows = @(Get-FixedSampleWindows -Duration $Info.Duration -SampleLength $SampleLength -MaxSamples ([math]::Max($MaxSamples, 3)))
  $sceneCandidates = if ($caps.HasScdet) {
    @(Get-SceneMetadataCandidates -Info $Info -InputPath $InputPath -SampleLength $SampleLength)
  }
  else {
    @()
  }

  if (@($sceneCandidates).Count -eq 0) {
    $sceneCandidates = @(Get-SelectSceneCandidates -Info $Info -InputPath $InputPath -SampleLength $SampleLength)
  }

  $difficultyCandidates = @($sceneCandidates + $fixedWindows | Select-Object -First ([math]::Max($MaxSamples * 2, 6)))
  $scored = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in $difficultyCandidates) {
    if ($null -eq $candidate) { continue }
    $candidateCopy = $candidate.PSObject.Copy()
    $difficulty = Score-SampleWindowDifficulty -Info $Info -InputPath $InputPath -TempDir $TempDir -Window $candidateCopy
    $candidateCopy | Add-Member -NotePropertyName DifficultyScore -NotePropertyValue ([double]$difficulty) -Force
    [void]$scored.Add($candidateCopy)
  }

  $merged = Merge-SampleWindows -Windows @($scored.ToArray()) -Duration $Info.Duration -SampleLength $SampleLength -MaxSamples $MaxSamples
  if (@($merged).Count -gt 0) {
    return [PSCustomObject]@{
      ModeUsed   = "sceneaware"
      Windows    = @($merged)
      Candidates = @($scored.ToArray())
    }
  }

  return [PSCustomObject]@{
    ModeUsed   = "fixed"
    Windows    = @($fixedWindows | Select-Object -First $MaxSamples)
    Candidates = @($fixedWindows)
  }
}

function Get-SampleWindows {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$SampleLength,
    [Parameter(Mandatory = $true)][int]$MaxSamples,
    [Parameter(Mandatory = $true)][string]$SampleMode
  )

  $resolvedMode = Get-NormalizedOptionValue -Value $SampleMode -DefaultValue "auto"
  $caps = Get-RuntimeCapabilities
  if ($resolvedMode -eq "auto") {
    $resolvedMode = [string]$caps.PreferredSamplingMode
  }

  if ($resolvedMode -eq "sceneaware") {
    $sceneAware = Get-SceneAwareSampleWindows -Info $Info -InputPath $InputPath -TempDir $TempDir -SampleLength $SampleLength -MaxSamples $MaxSamples
    $sceneAwareWindows = @((Get-ObjectPropertyValue -Object $sceneAware -Name "Windows" -DefaultValue @()))
    if ($sceneAwareWindows.Count -gt 0) {
      return $sceneAware
    }
  }

  $fixedWindows = @(Get-FixedSampleWindows -Duration $Info.Duration -SampleLength $SampleLength -MaxSamples $MaxSamples)
  return [PSCustomObject]@{
    ModeUsed   = "fixed"
    Windows    = @($fixedWindows)
    Candidates = @($fixedWindows)
  }
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
    # A normalized threshold keeps the 24/255 black cutoff equivalent for 8-,
    # 10-, and 12-bit sources.
    "-vf", "cropdetect=limit=0.0941176:round=2:reset=0",
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

function Get-CropSampleOffsets {
  param(
    [Parameter(Mandatory = $true)][double]$Duration,
    [Parameter(Mandatory = $true)][int]$SampleLength,
    [Parameter(Mandatory = $true)][int]$MaxSamples
  )

  if ($Duration -le ($SampleLength + 0.1)) {
    return @(0.0)
  }

  # Crop is applied to the whole encode, so include the beginning and end rather
  # than assuming that mid-video samples represent intros, credits, or overlays.
  $usableEnd = [math]::Max(0.0, $Duration - $SampleLength - 0.05)
  $fractions = @(
    switch ($MaxSamples) {
      1 { 0.50 }
      2 { 0.00; 1.00 }
      3 { 0.00; 0.50; 1.00 }
      4 { 0.00; 0.33; 0.67; 1.00 }
      default { 0.00; 0.25; 0.50; 0.75; 1.00 }
    }
  )

  $count = [math]::Min($fractions.Length, $MaxSamples)
  $offsets = foreach ($fraction in @($fractions[0..($count - 1)])) {
    [math]::Round($usableEnd * $fraction, 3)
  }
  return @($offsets | Select-Object -Unique)
}

function Test-CropBorderPairBalanced {
  param(
    [Parameter(Mandatory = $true)][int]$FirstBorder,
    [Parameter(Mandatory = $true)][int]$SecondBorder
  )

  if ($FirstBorder -eq 0 -and $SecondBorder -eq 0) {
    return $true
  }

  # Automatic cropping should only remove conventional paired bars. A lone dark
  # edge is much more likely to be picture composition, a title bar, or UI.
  if ($FirstBorder -le 0 -or $SecondBorder -le 0) {
    return $false
  }

  $largestBorder = [int][math]::Max($FirstBorder, $SecondBorder)
  $allowedDifference = [int][math]::Max(4, [math]::Ceiling($largestBorder * 0.10))
  return ([math]::Abs($FirstBorder - $SecondBorder) -le $allowedDifference)
}

function Test-CropBorderRegionsBlank {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][double]$Offset,
    [Parameter(Mandatory = $true)][int]$SampleSeconds,
    [Parameter(Mandatory = $true)][int]$BitDepth,
    [Parameter(Mandatory = $true)][object[]]$Regions
  )

  $validRegions = @($Regions | Where-Object { $_.Width -gt 0 -and $_.Height -gt 0 })
  if ($validRegions.Count -eq 0) {
    return $true
  }

  $offsetText = [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $Offset)
  $filterParts = New-Object System.Collections.Generic.List[string]
  $inputLabels = @()
  if ($validRegions.Count -eq 1) {
    $inputLabels = @("[0:v]")
  }
  else {
    $inputLabels = @(for ($index = 0; $index -lt $validRegions.Count; $index++) { "[border${index}in]" })
    [void]$filterParts.Add(("[0:v]split={0}{1}" -f $validRegions.Count, ($inputLabels -join "")))
  }

  for ($index = 0; $index -lt $validRegions.Count; $index++) {
    $region = $validRegions[$index]
    $outputLabel = "[border${index}out]"
    [void]$filterParts.Add(("{0}crop={1}:{2}:{3}:{4},fps=8,signalstats,metadata=print{5}" -f $inputLabels[$index], $region.Width, $region.Height, $region.X, $region.Y, $outputLabel))
  }

  $filter = $filterParts -join ";"
  $args = @(
    "-hide_banner",
    "-loglevel", "info",
    "-ss", $offsetText,
    "-t", "$SampleSeconds",
    "-i", $InputPath,
    "-filter_complex", $filter
  )
  for ($index = 0; $index -lt $validRegions.Count; $index++) {
    $args += @("-map", "[border${index}out]", "-an", "-f", "null", "NUL")
  }

  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args $args -AllowFailure
  if ($capture.ExitCode -ne 0) {
    return $false
  }

  $values = @{}
  foreach ($key in @("YMIN", "YMAX", "UMIN", "UMAX", "VMIN", "VMAX")) {
    $matches = [regex]::Matches($capture.Output, ("lavfi\.signalstats\.{0}=(?<value>[0-9.]+)" -f $key))
    if ($matches.Count -eq 0) {
      return $false
    }
    $values[$key] = @($matches | ForEach-Object {
        [double]::Parse($_.Groups["value"].Value, [Globalization.CultureInfo]::InvariantCulture)
      })
  }

  $sampleScale = [math]::Pow(2.0, [math]::Max(0, $BitDepth - 8))
  $yMinimum = [double](($values["YMIN"] | Measure-Object -Minimum).Minimum)
  $yMaximum = [double](($values["YMAX"] | Measure-Object -Maximum).Maximum)
  $uMinimum = [double](($values["UMIN"] | Measure-Object -Minimum).Minimum)
  $uMaximum = [double](($values["UMAX"] | Measure-Object -Maximum).Maximum)
  $vMinimum = [double](($values["VMIN"] | Measure-Object -Minimum).Minimum)
  $vMaximum = [double](($values["VMAX"] | Measure-Object -Maximum).Maximum)

  # Encoded black padding can contain a little quantization noise. These limits
  # allow that noise but reject text, icons, gradients, colored pixels, and other
  # low-luma picture detail that cropdetect alone can misclassify as black.
  $maximumBlankLuma = 40.0 * $sampleScale
  $maximumLumaRange = 24.0 * $sampleScale
  $minimumNeutralChroma = 96.0 * $sampleScale
  $maximumNeutralChroma = 160.0 * $sampleScale
  $maximumChromaRange = 32.0 * $sampleScale

  return (
    $yMaximum -le $maximumBlankLuma -and
    ($yMaximum - $yMinimum) -le $maximumLumaRange -and
    $uMinimum -ge $minimumNeutralChroma -and
    $uMaximum -le $maximumNeutralChroma -and
    ($uMaximum - $uMinimum) -le $maximumChromaRange -and
    $vMinimum -ge $minimumNeutralChroma -and
    $vMaximum -le $maximumNeutralChroma -and
    ($vMaximum - $vMinimum) -le $maximumChromaRange
  )
}

function Test-CropBordersBlank {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][double[]]$Offsets,
    [Parameter(Mandatory = $true)][int]$SampleSeconds,
    [Parameter(Mandatory = $true)][int]$CropWidth,
    [Parameter(Mandatory = $true)][int]$CropHeight,
    [Parameter(Mandatory = $true)][int]$CropX,
    [Parameter(Mandatory = $true)][int]$CropY
  )

  $rightRemoved = [int]($Info.Width - ($CropX + $CropWidth))
  $bottomRemoved = [int]($Info.Height - ($CropY + $CropHeight))
  $regions = New-Object System.Collections.Generic.List[object]

  if ($CropX -gt 0) {
    [void]$regions.Add([PSCustomObject]@{ Width = $CropX; Height = [int]$Info.Height; X = 0; Y = 0 })
  }
  if ($rightRemoved -gt 0) {
    [void]$regions.Add([PSCustomObject]@{ Width = $rightRemoved; Height = [int]$Info.Height; X = [int]($Info.Width - $rightRemoved); Y = 0 })
  }
  if ($CropY -gt 0) {
    [void]$regions.Add([PSCustomObject]@{ Width = [int]$Info.Width; Height = $CropY; X = 0; Y = 0 })
  }
  if ($bottomRemoved -gt 0) {
    [void]$regions.Add([PSCustomObject]@{ Width = [int]$Info.Width; Height = $bottomRemoved; X = 0; Y = [int]($Info.Height - $bottomRemoved) })
  }

  $bitDepth = [int](Get-ObjectPropertyValue -Object $Info -Name "VideoBitDepth" -DefaultValue 8)

  foreach ($offset in $Offsets) {
    $isBlank = Test-CropBorderRegionsBlank `
      -InputPath $InputPath `
      -Offset $offset `
      -SampleSeconds $SampleSeconds `
      -BitDepth $bitDepth `
      -Regions $regions.ToArray()
    if (-not $isBlank) {
      return $false
    }
  }

  return $true
}

function Invoke-CropDetect {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$CropMode,
    [int]$SampleSeconds = 2,
    [int]$MaxSamples = 5
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

  $offsets = Get-CropSampleOffsets -Duration $Info.Duration -SampleLength $SampleSeconds -MaxSamples $MaxSamples
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

  # Use the union of detected picture rectangles. Averaging can trim pixels that
  # even one sample identified as picture content.
  $cropX = [int](($samples | Measure-Object -Property X -Minimum).Minimum)
  $cropY = [int](($samples | Measure-Object -Property Y -Minimum).Minimum)
  $cropRight = [int](($samples | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum)
  $cropBottom = [int](($samples | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum)
  $cropX = [int][math]::Max(0, $cropX)
  $cropY = [int][math]::Max(0, $cropY)
  $cropRight = [int][math]::Min($Info.Width, $cropRight)
  $cropBottom = [int][math]::Min($Info.Height, $cropBottom)
  $cropWidth = [int][math]::Max(2, $cropRight - $cropX)
  $cropHeight = [int][math]::Max(2, $cropBottom - $cropY)

  $rightRemoved = [int][math]::Max(0, $Info.Width - ($cropWidth + $cropX))
  $bottomRemoved = [int][math]::Max(0, $Info.Height - ($cropHeight + $cropY))
  $maxBorderRemoved = (@($cropX, $cropY, $rightRemoved, $bottomRemoved) | Measure-Object -Maximum).Maximum
  $removedAreaRatio = 1.0 - (([double]$cropWidth * [double]$cropHeight) / ([double]$Info.Width * [double]$Info.Height))

  # Cropping is an optimization, so marginal savings are not worth any risk of
  # deleting edge detail. Both tests must pass before more expensive validation.
  if ($removedAreaRatio -lt 0.04 -or $maxBorderRemoved -lt 8) {
    $defaultResult.Summary = "insignificant"
    $defaultResult.Samples = $samples.ToArray()
    return $defaultResult
  }

  $horizontalPairBalanced = Test-CropBorderPairBalanced -FirstBorder $cropX -SecondBorder $rightRemoved
  $verticalPairBalanced = Test-CropBorderPairBalanced -FirstBorder $cropY -SecondBorder $bottomRemoved
  if (-not $horizontalPairBalanced -or -not $verticalPairBalanced) {
    $defaultResult.Summary = "asymmetric"
    $defaultResult.Samples = $samples.ToArray()
    return $defaultResult
  }

  $bordersBlank = Test-CropBordersBlank `
    -Info $Info `
    -InputPath $InputPath `
    -Offsets @($offsets) `
    -SampleSeconds $SampleSeconds `
    -CropWidth $cropWidth `
    -CropHeight $cropHeight `
    -CropX $cropX `
    -CropY $cropY
  if (-not $bordersBlank) {
    $defaultResult.Summary = "border-content"
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
    [Parameter(Mandatory = $true)]$SampleWindows,
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

  foreach ($window in @($SampleWindows)) {
    $idx++
    $outPath = Join-Path $TempDir ("probe_{0}_{1}.mp4" -f $Name, $idx)
    $vfArg = Build-Vf -Info $Info -TargetWidth $ProbeWidth -TargetFps $ProbeFps -ScaleFlags "bicubic"
    $offset = [double](Get-ObjectPropertyValue -Object $window -Name "Start" -DefaultValue 0.0)
    $sampleDuration = [double](Get-ObjectPropertyValue -Object $window -Name "Duration" -DefaultValue $SampleSeconds)

    $args = @("-y", "-ss", "$offset", "-t", "$sampleDuration", "-i", $InputPath)
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
    $kbps = (($bytes * 8.0) / [double][math]::Max(1.0, $sampleDuration)) / 1000.0
    $results.Add([PSCustomObject]@{
        Offset          = $offset
        Bytes           = $bytes
        Kbps            = $kbps
        Duration        = $sampleDuration
        SampleWindow    = $window
        SceneScore      = [double](Get-ObjectPropertyValue -Object $window -Name "SceneScore" -DefaultValue 0.0)
        DifficultyScore = [double](Get-ObjectPropertyValue -Object $window -Name "DifficultyScore" -DefaultValue 0.0)
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

function Get-ContentClassFeatures {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$SampleWindows
  )

  $motionNormalized = [double](Get-ObjectPropertyValue -Object $Probe -Name "MotionNormalized" -DefaultValue 0.75)
  $motionSpread = [double](Get-ObjectPropertyValue -Object $Probe -Name "MotionSpreadRatio" -DefaultValue 0.0)
  $detailSpread = [double](Get-ObjectPropertyValue -Object $Probe -Name "DetailSpreadRatio" -DefaultValue 0.0)
  $peakish = [double](Get-ObjectPropertyValue -Object $Probe -Name "PeakishKbps" -DefaultValue 0.0)
  $avg = [double](Get-ObjectPropertyValue -Object $Probe -Name "AvgKbps" -DefaultValue 0.0)
  $sceneAverage = if (@($SampleWindows).Count -gt 0) {
    [double]((@($SampleWindows) | Measure-Object -Property SceneScore -Average).Average)
  }
  else {
    0.0
  }

  $edgeDensityProxy = [math]::Max(0.0, [math]::Min(1.0, ($peakish - 110.0) / 360.0))
  $flatAreaRatio = [math]::Max(0.0, [math]::Min(1.0, 1.0 - (($avg - 70.0) / 360.0)))
  $uiPersistenceProxy = [math]::Max(0.0, [math]::Min(1.0, ((1.0 - [math]::Min(1.0, $motionNormalized)) * 0.60) + ($edgeDensityProxy * 0.35) - ($detailSpread * 0.25)))
  $noiseProxy = [math]::Max(0.0, [math]::Min(1.0, ($detailSpread * 2.1) + ($motionSpread * 1.4) + ($(if ($Info.VideoBitrateKbps -and $Info.VideoBitrateKbps -ge 3500) { 0.10 } else { 0.0 }))))

  return [PSCustomObject]@{
    MotionNormalized   = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $motionNormalized)), [Globalization.CultureInfo]::InvariantCulture)
    MotionSpread       = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $motionSpread)), [Globalization.CultureInfo]::InvariantCulture)
    DetailSpread       = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $detailSpread)), [Globalization.CultureInfo]::InvariantCulture)
    EdgeDensityProxy   = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $edgeDensityProxy)), [Globalization.CultureInfo]::InvariantCulture)
    FlatAreaRatio      = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $flatAreaRatio)), [Globalization.CultureInfo]::InvariantCulture)
    UiPersistenceProxy = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $uiPersistenceProxy)), [Globalization.CultureInfo]::InvariantCulture)
    NoiseProxy         = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $noiseProxy)), [Globalization.CultureInfo]::InvariantCulture)
    SceneAverage       = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $sceneAverage)), [Globalization.CultureInfo]::InvariantCulture)
    SourceFps          = [double]$Info.Fps
    SourceBitrateKbps  = [int](Get-ObjectPropertyValue -Object $Info -Name "VideoBitrateKbps" -DefaultValue 0)
  }
}

function Invoke-ContentClassifier {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$Features
  )

  if (
    [double]$Features.UiPersistenceProxy -ge 0.62 -and
    [double]$Features.EdgeDensityProxy -ge 0.45 -and
    [double]$Features.MotionNormalized -le 0.90
  ) {
    return "screen"
  }

  if (
    [double]$Features.NoiseProxy -ge 0.58 -and
    [double]$Features.MotionNormalized -ge 0.78
  ) {
    return "noisy_camera"
  }

  if (
    [double]$Info.Fps -ge 50.0 -and
    (Get-ContentBucketRank -bucket $Probe.MotionBucket) -ge (Get-ContentBucketRank -bucket "Medium") -and
    [double]$Features.EdgeDensityProxy -ge 0.40
  ) {
    return "gameplay"
  }

  if (
    [double]$Features.FlatAreaRatio -ge 0.48 -and
    [double]$Features.EdgeDensityProxy -ge 0.34 -and
    [double]$Features.NoiseProxy -le 0.42 -and
    [double]$Features.MotionSpread -le 0.30
  ) {
    return "anime"
  }

  if (
    [double]$Features.MotionNormalized -le 0.82 -and
    (Get-ContentBucketRank -bucket $Probe.DetailBucket) -le (Get-ContentBucketRank -bucket "Medium") -and
    $Info.HasAudio
  ) {
    return "talking_head"
  }

  return "general"
}

function Get-ContentClassPolicy {
  param(
    [Parameter(Mandatory = $true)][string]$ContentClass
  )

  switch ($ContentClass) {
    "screen" {
      return [PSCustomObject]@{
        PreferResolutionRetentionBoost = 0.12
        AudioBiasKbps                  = 0
        AllowDeband                    = $false
        AllowTemporalDenoise           = $false
        AllowScreenSharpen             = $true
        AllowRingingReduction          = $false
      }
    }
    "anime" {
      return [PSCustomObject]@{
        PreferResolutionRetentionBoost = 0.08
        AudioBiasKbps                  = 0
        AllowDeband                    = $true
        AllowTemporalDenoise           = $false
        AllowScreenSharpen             = $false
        AllowRingingReduction          = $true
      }
    }
    "talking_head" {
      return [PSCustomObject]@{
        PreferResolutionRetentionBoost = -0.04
        AudioBiasKbps                  = 8
        AllowDeband                    = $false
        AllowTemporalDenoise           = $false
        AllowScreenSharpen             = $false
        AllowRingingReduction          = $false
      }
    }
    "gameplay" {
      return [PSCustomObject]@{
        PreferResolutionRetentionBoost = 0.10
        AudioBiasKbps                  = 0
        AllowDeband                    = $false
        AllowTemporalDenoise           = $false
        AllowScreenSharpen             = $false
        AllowRingingReduction          = $false
      }
    }
    "noisy_camera" {
      return [PSCustomObject]@{
        PreferResolutionRetentionBoost = -0.06
        AudioBiasKbps                  = 0
        AllowDeband                    = $false
        AllowTemporalDenoise           = $true
        AllowScreenSharpen             = $false
        AllowRingingReduction          = $true
      }
    }
    default {
      return [PSCustomObject]@{
        PreferResolutionRetentionBoost = 0.0
        AudioBiasKbps                  = 0
        AllowDeband                    = $false
        AllowTemporalDenoise           = $false
        AllowScreenSharpen             = $false
        AllowRingingReduction          = $false
      }
    }
  }
}

function Invoke-ComplexityProbe {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Mode,
    [int]$SampleSeconds = 6,
    [int]$MaxSamples = 0,
    [string]$SampleMode = "auto",
    [string]$ContentClassMode = "auto"
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

  $sampleBundle = Get-SampleWindows -Info $Info -InputPath $InputPath -TempDir $TempDir -SampleLength $SampleSeconds -MaxSamples $MaxSamples -SampleMode $SampleMode
  $sampleWindows = @($sampleBundle.Windows)
  if ($sampleWindows.Count -eq 0) {
    throw "Complexity probe could not resolve sample windows."
  }

  $detailProbe = Invoke-CrfProbeSeries `
    -Info $Info `
    -InputPath $InputPath `
    -TempDir $TempDir `
    -Mode $Mode `
    -SampleWindows $sampleWindows `
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
      -SampleWindows $sampleWindows `
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

  $probeShell = [PSCustomObject]@{
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
    SamplingModeUsed  = [string]$sampleBundle.ModeUsed
    SampleWindows     = @($sampleWindows)
  }

  $contentFeatures = $null
  $contentClass = "general"
  if ((Get-NormalizedOptionValue -Value $ContentClassMode -DefaultValue "auto") -ne "off") {
    $contentFeatures = Get-ContentClassFeatures -Info $Info -Probe $probeShell -SampleWindows $sampleWindows
    $contentClass = Invoke-ContentClassifier -Info $Info -Probe $probeShell -Features $contentFeatures
  }

  return [PSCustomObject]@{
    ProbeWidth        = $probeShell.ProbeWidth
    ProbeFps          = $probeShell.ProbeFps
    ProbeCrf          = $probeShell.ProbeCrf
    AvgKbps           = $probeShell.AvgKbps
    PeakishKbps       = $probeShell.PeakishKbps
    Bucket            = $overallBucket
    DetailProbe       = $detailProbe
    MotionProbe       = $motionProbe
    DetailBucket      = $detailBucket
    MotionBucket      = $motionBucket
    MotionRatio       = $probeShell.MotionRatio
    MotionNormalized  = $probeShell.MotionNormalized
    DetailSpreadRatio = $probeShell.DetailSpreadRatio
    MotionSpreadRatio = $probeShell.MotionSpreadRatio
    ProbeSamplesUsed  = $probeShell.ProbeSamplesUsed
    Samples           = $probeShell.Samples
    SamplingModeUsed  = $probeShell.SamplingModeUsed
    SampleWindows     = $probeShell.SampleWindows
    ContentClass      = [string]$contentClass
    ContentClassFeatures = $contentFeatures
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
    [Parameter(Mandatory = $true)][string]$Mode,
    $CodecProfile = $null
  )

  $planningWidth = Get-PlanningWidth -Info $Info
  $planningHeight = Get-PlanningHeight -Info $Info
  $resolutionProfile = Get-ResolutionPlanningProfile -Info $Info -Probe $Probe -Mode $Mode
  $contentPolicy = Get-ContentClassPolicy -ContentClass ([string](Get-ObjectPropertyValue -Object $Probe -Name "ContentClass" -DefaultValue "general"))
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
    $codecRetentionBoost = 0.0
    if ($null -ne $CodecProfile) {
      switch ($CodecProfile.VideoCodec) {
        "av1"  { $codecRetentionBoost = [math]::Max(0.0, ($widthRatio - 0.92) * 180.0) }
        "x264" { $codecRetentionBoost = [math]::Min(0.0, ($widthRatio - 0.98) * 120.0) }
      }
    }
    $contentRetentionBoost = [double](Get-ObjectPropertyValue -Object $contentPolicy -Name "PreferResolutionRetentionBoost" -DefaultValue 0.0) * 220.0
    $score = 1000.0 - $distancePenalty - $overshootPenalty - $undershootPenalty - $bpppfPenalty + $codecRetentionBoost + $contentRetentionBoost

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

function Get-MuxReserveBytes($targetBytes, $mode, [string]$Container = "mp4", [string]$VideoCodec = "x264", [string]$AudioMode = "", [double]$ObservedBias = 1.0) {
  $baseRatio = switch ($mode) {
    "Fast"         { 0.012 }
    "Balanced"     { 0.006 }
    "ExtraQuality" { 0.005 }
  }

  $containerRatio = switch ((Get-NormalizedOptionValue -Value $Container -DefaultValue "mp4")) {
    "webm" { 0.0038 }
    default { 0.0058 }
  }
  $codecRatio = switch ((Get-NormalizedOptionValue -Value $VideoCodec -DefaultValue "x264")) {
    "av1"  { 0.0038 }
    "x265" { 0.0046 }
    default { 0.0052 }
  }
  $audioRatio = switch ((Get-NormalizedOptionValue -Value $AudioMode -DefaultValue "")) {
    "copy" { 0.0018 }
    "mute" { 0.0012 }
    default { 0.0015 }
  }

  $biasExtra = [math]::Max(0.0, [double]$ObservedBias - 1.0) * 0.003
  $ratio = [math]::Max($baseRatio, $containerRatio + $codecRatio + $audioRatio + $biasExtra)
  return [long][math]::Floor($targetBytes * $ratio)
}

function Get-AutoX264Params($mode, $totalBudgetKbps, [string]$ContentClass = "general") {
  if ($ContentClass -eq "screen") {
    return "aq-mode=2:aq-strength=0.70:deblock=0,0"
  }

  if ($ContentClass -eq "noisy_camera") {
    return "aq-mode=3:aq-strength=0.90:deblock=-1,-1"
  }

  if ($mode -in @("Balanced", "ExtraQuality") -and $totalBudgetKbps -lt 1200) {
    return "aq-mode=3:aq-strength=0.85:deblock=-1,-1"
  }

  return ""
}

function Get-PlanBaseScore {
  param(
    [Parameter(Mandatory = $true)][double]$HeuristicScore
  )

  return [double]$HeuristicScore
}

function Get-PlanLearnedAdjustment {
  param(
    [Parameter(Mandatory = $true)]$Plan
  )

  $modelPath = Join-Path $PSScriptRoot "compress.plan-model.json"
  if (-not (Test-Path $modelPath)) {
    return 0.0
  }

  try {
    $model = Get-Content -Path $modelPath -Raw | ConvertFrom-Json
    return [double](Get-ObjectPropertyValue -Object $model -Name "defaultAdjustment" -DefaultValue 0.0)
  }
  catch {
    return 0.0
  }
}

function Get-PlanFinalScore {
  param(
    [Parameter(Mandatory = $true)][double]$BaseScore,
    [double]$LearnedAdjustment = 0.0,
    [double]$MetricInfluence = 0.0
  )

  return ([double]$BaseScore + [double]$LearnedAdjustment + [double]$MetricInfluence)
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
    $PolicyProfile = $null,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height,
    [Parameter(Mandatory = $true)][int]$Fps,
    [Parameter(Mandatory = $true)]$AudioPlan,
    [string]$WidthOrigin = "unknown",
    [AllowEmptyString()][string]$PreprocessProfileName = "",
    [double]$ObservedMuxBias = 1.0,
    [switch]$CalibratedFromPreview,
    [switch]$UseDenoise
  )

  $preprocessLabel = if (-not [string]::IsNullOrWhiteSpace($PreprocessProfileName)) {
    Get-NormalizedOptionValue -Value $PreprocessProfileName -DefaultValue "none"
  }
  elseif ($UseDenoise) {
    "mild-denoise"
  }
  else {
    "none"
  }

  $muxReserve = Get-MuxReserveBytes -targetBytes $TargetBytes -mode $Mode -Container $CodecProfile.Container -VideoCodec $CodecProfile.VideoCodec -AudioMode $AudioPlan.Mode -ObservedBias $ObservedMuxBias
  $usableVideoBytes = $TargetBytes - $AudioPlan.EstimatedBytes - $muxReserve
  if ($usableVideoBytes -lt 25000) { return $null }

  $videoKbps = [int][math]::Floor((($usableVideoBytes * 8.0) / $Info.Duration) / 1000.0)
  if ($videoKbps -lt 40) { return $null }

  $vf = Build-Vf -Info $Info -TargetWidth $Width -TargetFps $Fps -UseDenoise:$UseDenoise -PreprocessProfileName $preprocessLabel
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
  $contentPolicy = Get-ContentClassPolicy -ContentClass ([string](Get-ObjectPropertyValue -Object $Probe -Name "ContentClass" -DefaultValue "general"))
  $contentWidthBoost = [int](([double](Get-ObjectPropertyValue -Object $contentPolicy -Name "PreferResolutionRetentionBoost" -DefaultValue 0.0)) * 4000.0 * [math]::Max(0.5, $widthRatio))
  $bpppfDeficitPenalty = if ($bpppf -lt $targetBpppf) { [int](($targetBpppf - $bpppf) * 200000) } else { 0 }
  $videoPrivateArgs = if ($CodecProfile.VideoCodec -eq "x264") { Get-AutoX264Params -mode $Mode -totalBudgetKbps $totalBudgetKbps -ContentClass ([string](Get-ObjectPropertyValue -Object $Probe -Name "ContentClass" -DefaultValue "general")) } else { "" }
  $crf = Get-RateControlSeedCrf -VideoCodec $CodecProfile.VideoCodec -Mode $Mode
  $fpsTier = Get-FpsTier -SourceFps $Info.Fps -TargetFps $Fps
  $widthTier = Get-WidthTier -WidthRatio $widthRatio
  $audioTier = Get-AudioTier -AudioPlan $AudioPlan

  $score = switch ($Mode) {
    "Fast" {
      40000 + ($Fps * 220) + ($AudioPlan.Rank * 2) + ([int]($bpppf * 40000)) - ($widthFitPenalty * 2) - ($overshootPenalty * 2)
    }
    "Balanced" {
      50000 + ($Fps * 8) + ($AudioPlan.Rank * 6) + ([int]($bpppf * 70000)) + $highFpsRetentionBoost + $contentWidthBoost - $bpppfDeficitPenalty - $widthFitPenalty - $overshootPenalty
    }
    "ExtraQuality" {
      56000 + ($Fps * 16) + ($AudioPlan.Rank * 8) + ([int]($bpppf * 90000)) + [int]($contentWidthBoost * 1.2) - [int]($widthFitPenalty * 0.8) - [int]($overshootPenalty * 0.8)
    }
  }
  $baseScore = Get-PlanBaseScore -HeuristicScore $score
  $learnedAdjustment = Get-PlanLearnedAdjustment -Plan ([PSCustomObject]@{ ContentClass = $Probe.ContentClass; VideoCodec = $CodecProfile.VideoCodec; Container = $CodecProfile.Container; PreprocessLabel = $preprocessLabel })
  $finalScore = Get-PlanFinalScore -BaseScore $baseScore -LearnedAdjustment $learnedAdjustment -MetricInfluence 0.0

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
    Score       = $finalScore
    BaseScore   = $baseScore
    FinalScore  = $finalScore
    TotalBudgetKbps = $totalBudgetKbps
    WidthOrigin = $WidthOrigin
    FpsTier     = $fpsTier
    WidthTier   = $widthTier
    AudioTier   = $audioTier
    PreprocessTier = $preprocessLabel
    ArchetypeKey = ("{0}|{1}|{2}|{3}" -f $fpsTier, $widthTier, $audioTier, $preprocessLabel)
    PredictedTotalBytes = [long]$TargetBytes
    PredictedFillRatio  = 1.0
    ReserveBytes = [long]$muxReserve
    ResolutionBiasLabel = $resolutionProfile.BiasLabel
    PreprocessLabel = $preprocessLabel
    UseDenoise = [bool]$UseDenoise
    CropApplied = [bool](Get-ObjectPropertyValue -Object $Info -Name "CropApplied" -DefaultValue $false)
    CropSummary = Get-CropSummary -Info $Info
    VideoPrivateArgs = $videoPrivateArgs
    ContentClass = [string](Get-ObjectPropertyValue -Object $Probe -Name "ContentClass" -DefaultValue "general")
    MetricModeUsed = if ($PolicyProfile) { [string](Get-ObjectPropertyValue -Object $PolicyProfile -Name "MetricModeUsed" -DefaultValue "off") } else { "off" }
    MetricScore = $null
    MetricConfidence = 0.0
    SamplingModeUsed = [string](Get-ObjectPropertyValue -Object $Probe -Name "SamplingModeUsed" -DefaultValue "fixed")
    SampleWindows = @((Get-ObjectPropertyValue -Object $Probe -Name "SampleWindows" -DefaultValue @()))
    CodecPolicyReason = if ($PolicyProfile) { [string](Get-ObjectPropertyValue -Object $PolicyProfile -Name "CodecPolicyReason" -DefaultValue "explicit") } else { "explicit" }
    ContainerPolicyReason = if ($PolicyProfile) { [string](Get-ObjectPropertyValue -Object $PolicyProfile -Name "ContainerPolicyReason" -DefaultValue "explicit") } else { "explicit" }
    CanChangeCodecInSecondStage = if ($PolicyProfile) { [bool](Get-ObjectPropertyValue -Object $PolicyProfile -Name "CanChangeCodecInSecondStage" -DefaultValue $false) } else { $false }
    CanChangeContainerInSecondStage = if ($PolicyProfile) { [bool](Get-ObjectPropertyValue -Object $PolicyProfile -Name "CanChangeContainerInSecondStage" -DefaultValue $false) } else { $false }
    CalibratedFromPreview = [bool]$CalibratedFromPreview
    LearnedScoreAdjustment = [double]$learnedAdjustment
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

function Get-PreviewSampleWindows {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][int]$SampleSeconds,
    [Parameter(Mandatory = $true)][int]$MaxSamples
  )

  $seedWindows = @((Get-ObjectPropertyValue -Object $Plan -Name "SampleWindows" -DefaultValue @()))
  $windows = New-Object System.Collections.Generic.List[object]
  foreach ($window in $seedWindows) {
    if ($windows.Count -ge $MaxSamples) { break }
    [void]$windows.Add((New-SampleWindow `
        -Start ([double](Get-ObjectPropertyValue -Object $window -Name "Start" -DefaultValue 0.0)) `
        -Duration $SampleSeconds `
        -Source ([string](Get-ObjectPropertyValue -Object $window -Name "Source" -DefaultValue "fixed")) `
        -SceneScore ([double](Get-ObjectPropertyValue -Object $window -Name "SceneScore" -DefaultValue 0.0)) `
        -DifficultyScore ([double](Get-ObjectPropertyValue -Object $window -Name "DifficultyScore" -DefaultValue 0.0)) `
        -Tag ([string](Get-ObjectPropertyValue -Object $window -Name "Tag" -DefaultValue ""))))
  }

  if ($windows.Count -lt $MaxSamples) {
    foreach ($window in @(Get-FixedSampleWindows -Duration $Info.Duration -SampleLength $SampleSeconds -MaxSamples $MaxSamples)) {
      if ($windows.Count -ge $MaxSamples) { break }
      $exists = $windows | Where-Object { [math]::Abs([double]$_.Start - [double]$window.Start) -lt ([double]$SampleSeconds * 0.60) } | Select-Object -First 1
      if ($null -eq $exists) {
        [void]$windows.Add($window)
      }
    }
  }

  return @(Merge-SampleWindows -Windows @($windows.ToArray()) -Duration $Info.Duration -SampleLength $SampleSeconds -MaxSamples $MaxSamples)
}

function Get-ResolvedMetricSampling {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][int]$PreviewSampleSeconds
  )

  $defaultMaxSamples = switch ($Plan.Mode) {
    "Balanced"     { 2 }
    "ExtraQuality" { 3 }
    default        { 1 }
  }

  return [PSCustomObject]@{
    SampleSeconds = if ($MetricSampleSeconds -gt 0) { [int]$MetricSampleSeconds } else { [int]$PreviewSampleSeconds }
    MaxSamples    = if ($MetricMaxSamples -gt 0) { [int]$MetricMaxSamples } else { [int]$defaultMaxSamples }
  }
}

function Get-NormalizedMetricPreferenceScore {
  param(
    [Parameter(Mandatory = $true)]$Result
  )

  $metricMode = Get-NormalizedOptionValue -Value (Get-ObjectPropertyValue -Object $Result -Name "MetricModeUsed" -DefaultValue (Get-ObjectPropertyValue -Object $Result.Plan -Name "MetricModeUsed" -DefaultValue "off")) -DefaultValue "off"
  $metricScore = [double](Get-ObjectPropertyValue -Object $Result -Name "MetricScore" -DefaultValue 0.0)
  switch ($metricMode) {
    "vmaf"  { return [int][math]::Round($metricScore * 10.0) }
    "xpsnr" { return [int][math]::Round($metricScore * 20.0) }
    default { return 0 }
  }
}

function Invoke-VmafMetric {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$PreviewPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Window,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  $logName = ("vmaf_{0}.json" -f ([guid]::NewGuid().ToString("N")))
  $refFilter = if ([string]::IsNullOrWhiteSpace($Plan.VFilter)) {
    "settb=AVTB,setpts=PTS-STARTPTS"
  }
  else {
    "{0},settb=AVTB,setpts=PTS-STARTPTS" -f $Plan.VFilter
  }
  $threadCount = if ($Plan.Mode -eq "ExtraQuality") { 4 } else { 2 }
  $subsample = if ($Plan.Mode -eq "ExtraQuality") { 1 } else { 2 }
  $lavfi = "[1:v]settb=AVTB,setpts=PTS-STARTPTS[main];[0:v]{0}[ref];[main][ref]libvmaf=log_fmt=json:log_path={1}:n_threads={2}:n_subsample={3}" -f $refFilter, $logName, $threadCount, $subsample
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-ss", "$($Window.Start)", "-t", "$($Window.Duration)", "-i", $InputPath, "-i", $PreviewPath, "-lavfi", $lavfi, "-an", "-f", "null", "NUL") -WorkingDirectory $TempDir -AllowFailure
  if ($capture.ExitCode -ne 0) {
    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "vmaf"
        ExitCode   = [int]$capture.ExitCode
        Output     = $capture.Output
        Window     = $Window
        PreviewPath = $PreviewPath
      })
    return $null
  }

  $logPath = Join-Path $TempDir $logName
  if (-not (Test-Path $logPath)) {
    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "vmaf"
        ExitCode   = [int]$capture.ExitCode
        Output     = $capture.Output
        Window     = $Window
        PreviewPath = $PreviewPath
        Reason     = "missing-log"
      })
    return $null
  }

  try {
    $json = Get-Content -Path $logPath -Raw | ConvertFrom-Json
    $score = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $json -Name "pooled_metrics" -DefaultValue $null) -Name "vmaf" -DefaultValue $null) -Name "mean" -DefaultValue 0.0)
    return [PSCustomObject]@{
      Mode  = "vmaf"
      Score = [double]$score
    }
  }
  finally {
    Remove-Item $logPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-XpsnrMetric {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$PreviewPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Window,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  $statsName = ("xpsnr_{0}.log" -f ([guid]::NewGuid().ToString("N")))
  $refFilter = if ([string]::IsNullOrWhiteSpace($Plan.VFilter)) {
    "settb=AVTB,setpts=PTS-STARTPTS"
  }
  else {
    "{0},settb=AVTB,setpts=PTS-STARTPTS" -f $Plan.VFilter
  }
  $lavfi = "[0:v]{0}[ref];[1:v]settb=AVTB,setpts=PTS-STARTPTS[test];[ref][test]xpsnr=stats_file={1}" -f $refFilter, $statsName
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-ss", "$($Window.Start)", "-t", "$($Window.Duration)", "-i", $InputPath, "-i", $PreviewPath, "-lavfi", $lavfi, "-an", "-f", "null", "NUL") -WorkingDirectory $TempDir -AllowFailure
  if ($capture.ExitCode -ne 0) {
    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "xpsnr"
        ExitCode   = [int]$capture.ExitCode
        Output     = $capture.Output
        Window     = $Window
        PreviewPath = $PreviewPath
      })
    return $null
  }

  $statsPath = Join-Path $TempDir $statsName
  if (-not (Test-Path $statsPath)) {
    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "xpsnr"
        ExitCode   = [int]$capture.ExitCode
        Output     = $capture.Output
        Window     = $Window
        PreviewPath = $PreviewPath
        Reason     = "missing-log"
      })
    return $null
  }

  try {
    $frameScores = New-Object System.Collections.Generic.List[double]
    foreach ($line in (Get-Content -Path $statsPath)) {
      $matches = [regex]::Matches($line, '(?i)(?:^|\s)(?:xpsnr_)?(?<plane>[yuv]|average|min)[:=](?<value>-?\d+(?:\.\d+)?)')
      if ($matches.Count -eq 0) { continue }
      $values = New-Object System.Collections.Generic.List[double]
      foreach ($match in $matches) {
        $plane = $match.Groups["plane"].Value.ToLowerInvariant()
        $value = [double]::Parse($match.Groups["value"].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($plane -in @("y", "u", "v")) {
          [void]$values.Add($value)
        }
      }
      if ($values.Count -gt 0) {
        [void]$frameScores.Add(([double](($values | Measure-Object -Minimum).Minimum)))
      }
      else {
        $fallback = [regex]::Match($line, '(?i)(?:average|min)[:=](?<value>-?\d+(?:\.\d+)?)')
        if ($fallback.Success) {
          [void]$frameScores.Add(([double]::Parse($fallback.Groups["value"].Value, [Globalization.CultureInfo]::InvariantCulture)))
        }
      }
    }

    if ($frameScores.Count -gt 0) {
      return [PSCustomObject]@{
        Mode  = "xpsnr"
        Score = [double](($frameScores | Measure-Object -Average).Average)
      }
    }

    $summaryMatches = [regex]::Matches($capture.Output, '(?i)(?<plane>y|u|v|minimum)\s*:\s*(?<value>-?\d+(?:\.\d+)?)')
    if ($summaryMatches.Count -gt 0) {
      $planeScores = @{}
      foreach ($match in $summaryMatches) {
        $plane = $match.Groups["plane"].Value.ToLowerInvariant()
        $value = [double]::Parse($match.Groups["value"].Value, [Globalization.CultureInfo]::InvariantCulture)
        $planeScores[$plane] = $value
      }

      $score = if ($planeScores.ContainsKey("minimum")) {
        [double]$planeScores["minimum"]
      }
      elseif (($planeScores.Keys | Where-Object { $_ -in @("y", "u", "v") }).Count -gt 0) {
        [double](($planeScores.GetEnumerator() | Where-Object { $_.Key -in @("y", "u", "v") } | ForEach-Object { $_.Value } | Measure-Object -Minimum).Minimum)
      }
      else {
        $null
      }

      if ($null -ne $score) {
        return [PSCustomObject]@{
          Mode  = "xpsnr"
          Score = [double]$score
        }
      }
    }

    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "xpsnr"
        ExitCode   = [int]$capture.ExitCode
        Output     = $capture.Output
        Window     = $Window
        PreviewPath = $PreviewPath
        Reason     = "no-frame-scores"
      })
    return $null
  }
  finally {
    Remove-Item $statsPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-PreviewMetric {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$PreviewSegments,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  $metricMode = Get-NormalizedOptionValue -Value (Get-ObjectPropertyValue -Object $Plan -Name "MetricModeUsed" -DefaultValue "off") -DefaultValue "off"
  if ($metricMode -eq "off") {
    return [PSCustomObject]@{
      MetricModeUsed = "off"
      MetricScore = $null
      MetricConfidence = 0.0
      SegmentScores = @()
    }
  }

  $scores = New-Object System.Collections.Generic.List[object]
  foreach ($segment in @($PreviewSegments)) {
    if (-not (Test-Path $segment.Path)) { continue }
    $metricResult = switch ($metricMode) {
      "vmaf"  { Invoke-VmafMetric -InputPath $InputPath -PreviewPath $segment.Path -Plan $Plan -Window $segment.Window -TempDir $TempDir }
      "xpsnr" { Invoke-XpsnrMetric -InputPath $InputPath -PreviewPath $segment.Path -Plan $Plan -Window $segment.Window -TempDir $TempDir }
    }

    if ($metricResult) {
      [void]$scores.Add($metricResult)
    }
  }

  if ($scores.Count -eq 0) {
    return [PSCustomObject]@{
      MetricModeUsed = [string]$metricMode
      MetricScore = $null
      MetricConfidence = 0.0
      SegmentScores = @()
    }
  }

  $score = [double](($scores | Measure-Object -Property Score -Average).Average)
  $confidence = if ($scores.Count -ge 3) { 0.95 } elseif ($scores.Count -eq 2) { 0.88 } else { 0.75 }
  return [PSCustomObject]@{
    MetricModeUsed   = [string]$metricMode
    MetricScore      = [double]$score
    MetricConfidence = [double]$confidence
    SegmentScores    = @($scores.ToArray())
  }
}

function Get-MetricScoreBundle {
  param(
    [Parameter(Mandatory = $true)]$MetricResult
  )

  return [PSCustomObject]@{
    MetricModeUsed   = [string](Get-ObjectPropertyValue -Object $MetricResult -Name "MetricModeUsed" -DefaultValue "off")
    MetricScore      = (Get-ObjectPropertyValue -Object $MetricResult -Name "MetricScore" -DefaultValue $null)
    MetricConfidence = [double](Get-ObjectPropertyValue -Object $MetricResult -Name "MetricConfidence" -DefaultValue 0.0)
    MetricSortScore  = if ($null -ne (Get-ObjectPropertyValue -Object $MetricResult -Name "MetricScore" -DefaultValue $null)) {
      switch ((Get-NormalizedOptionValue -Value (Get-ObjectPropertyValue -Object $MetricResult -Name "MetricModeUsed" -DefaultValue "off") -DefaultValue "off")) {
        "vmaf"  { [int][math]::Round([double]$MetricResult.MetricScore * 10.0) }
        "xpsnr" { [int][math]::Round([double]$MetricResult.MetricScore * 20.0) }
        default { 0 }
      }
    }
    else {
      0
    }
    SegmentScores    = @((Get-ObjectPropertyValue -Object $MetricResult -Name "SegmentScores" -DefaultValue @()))
  }
}

function Merge-PreviewAndMetricScore {
  param(
    [Parameter(Mandatory = $true)]$Preview,
    [Parameter(Mandatory = $true)]$MetricBundle
  )

  $previewCopy = $Preview.PSObject.Copy()
  $previewCopy | Add-Member -NotePropertyName MetricModeUsed -NotePropertyValue ([string]$MetricBundle.MetricModeUsed) -Force
  $previewCopy | Add-Member -NotePropertyName MetricScore -NotePropertyValue $MetricBundle.MetricScore -Force
  $previewCopy | Add-Member -NotePropertyName MetricConfidence -NotePropertyValue ([double]$MetricBundle.MetricConfidence) -Force
  $previewCopy | Add-Member -NotePropertyName MetricSortScore -NotePropertyValue ([int]$MetricBundle.MetricSortScore) -Force
  $previewCopy | Add-Member -NotePropertyName MetricSegmentScores -NotePropertyValue @($MetricBundle.SegmentScores) -Force
  return $previewCopy
}

function Get-PreviewSeedVideoKbps {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Preview
  )

  $predictedVideoBytes = [double]$Preview.VideoBytes
  $targetVideoBytes = [double]$Plan.TargetBytes - [double]$Plan.AudioPlan.EstimatedBytes - [double](Get-MuxReserveBytes -targetBytes $Plan.TargetBytes -mode $Plan.Mode -Container $Plan.CodecProfile.Container -VideoCodec $Plan.CodecProfile.VideoCodec -AudioMode $Plan.AudioPlan.Mode)
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

  return ("{0}x{1}@{2}|v={3}|a={4}|p={5}|pp={6}|crop={7}|codec={8}|container={9}" -f $Plan.Width, $Plan.Height, $Plan.Fps, $Plan.VideoKbps, $audioKey, $Plan.Preset, $Plan.PreprocessLabel, [int]$Plan.CropApplied, $Plan.CodecProfile.VideoCodec, $Plan.CodecProfile.Container)
}

function Write-PlanLogRecord {
  param(
    [Parameter(Mandatory = $true)][string]$RecordType,
    [Parameter(Mandatory = $true)]$Data
  )

  if (-not $EnablePlanLogging -or [string]::IsNullOrWhiteSpace($script:PlanLogPathResolved)) {
    return
  }

  $record = [PSCustomObject]@{
    Timestamp  = (Get-Date).ToString("o")
    RecordType = $RecordType
    Data       = $Data
  }

  $json = $record | ConvertTo-Json -Depth 8 -Compress
  Add-Content -Path $script:PlanLogPathResolved -Value $json
}

function Get-PlanFeatureVector {
  param(
    [Parameter(Mandatory = $true)]$Plan
  )

  return [PSCustomObject]@{
    Width                 = [int]$Plan.Width
    Height                = [int]$Plan.Height
    Fps                   = [int]$Plan.Fps
    VideoKbps             = [int]$Plan.VideoKbps
    AudioMode             = [string]$Plan.AudioPlan.Mode
    AudioKbps             = [int](Get-ObjectPropertyValue -Object $Plan.AudioPlan -Name "Kbps" -DefaultValue 0)
    Codec                 = [string]$Plan.CodecProfile.VideoCodec
    Container             = [string]$Plan.CodecProfile.Container
    Preset                = [string]$Plan.Preset
    PreprocessLabel       = [string]$Plan.PreprocessLabel
    ContentClass          = [string](Get-ObjectPropertyValue -Object $Plan -Name "ContentClass" -DefaultValue "general")
    SamplingModeUsed      = [string](Get-ObjectPropertyValue -Object $Plan -Name "SamplingModeUsed" -DefaultValue "fixed")
    MetricModeUsed        = [string](Get-ObjectPropertyValue -Object $Plan -Name "MetricModeUsed" -DefaultValue "off")
    MetricScore           = (Get-ObjectPropertyValue -Object $Plan -Name "MetricScore" -DefaultValue $null)
    MetricConfidence      = [double](Get-ObjectPropertyValue -Object $Plan -Name "MetricConfidence" -DefaultValue 0.0)
    ReserveBytes          = [long](Get-ObjectPropertyValue -Object $Plan -Name "ReserveBytes" -DefaultValue 0)
    CodecPolicyReason     = [string](Get-ObjectPropertyValue -Object $Plan -Name "CodecPolicyReason" -DefaultValue "")
    ContainerPolicyReason = [string](Get-ObjectPropertyValue -Object $Plan -Name "ContainerPolicyReason" -DefaultValue "")
    BaseScore             = [double](Get-ObjectPropertyValue -Object $Plan -Name "BaseScore" -DefaultValue 0.0)
    FinalScore            = [double](Get-ObjectPropertyValue -Object $Plan -Name "FinalScore" -DefaultValue $Plan.Score)
    LearnedScoreAdjustment = [double](Get-ObjectPropertyValue -Object $Plan -Name "LearnedScoreAdjustment" -DefaultValue 0.0)
    SampleWindows         = @((Get-ObjectPropertyValue -Object $Plan -Name "SampleWindows" -DefaultValue @()) | ForEach-Object {
        [PSCustomObject]@{
          Start      = [double](Get-ObjectPropertyValue -Object $_ -Name "Start" -DefaultValue 0.0)
          Duration   = [double](Get-ObjectPropertyValue -Object $_ -Name "Duration" -DefaultValue 0.0)
          Source     = [string](Get-ObjectPropertyValue -Object $_ -Name "Source" -DefaultValue "")
          SceneScore = [double](Get-ObjectPropertyValue -Object $_ -Name "SceneScore" -DefaultValue 0.0)
        }
      })
  }
}

function Get-OutcomeRecord {
  param(
    [Parameter(Mandatory = $true)]$Result
  )

  return [PSCustomObject]@{
    Success        = [bool]$Result.Success
    SizeBytes      = [long]$Result.SizeBytes
    Ratio          = [double]$Result.Ratio
    Attempt        = [int](Get-ObjectPropertyValue -Object $Result -Name "Attempt" -DefaultValue 0)
    PredictionBias = [double](Get-ObjectPropertyValue -Object $Result -Name "PredictionBias" -DefaultValue 0.0)
    SearchStats    = (Get-ObjectPropertyValue -Object $Result -Name "SearchStats" -DefaultValue $null)
    Plan           = Get-PlanFeatureVector -Plan $Result.Plan
  }
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

  $sampleWindows = @(Get-PreviewSampleWindows -Info $Info -Plan $Plan -SampleSeconds $SampleSeconds -MaxSamples $MaxSamples)
  if (-not $sampleWindows -or $sampleWindows.Length -eq 0) {
    return $null
  }

  $strategy = Get-ModeStrategy -Mode $Plan.Mode -Duration $Info.Duration
  $segmentBytes = @()
  $previewSegments = New-Object System.Collections.Generic.List[object]
  $metricSegments = New-Object System.Collections.Generic.List[object]
  $idx = 0
  $commonVideo = Get-CommonVideoEncodeArgs -Plan $Plan -Preview

  foreach ($window in $sampleWindows) {
    $idx++
    $offset = [double](Get-ObjectPropertyValue -Object $window -Name "Start" -DefaultValue 0.0)
    $windowDuration = [double](Get-ObjectPropertyValue -Object $window -Name "Duration" -DefaultValue $SampleSeconds)
    $outPath = Join-Path $TempDir ("preview_{0}_{1}_{2}_{3}{4}" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $idx, $Plan.OutputExtension)
    $args = @("-y", "-ss", "$offset", "-t", "$windowDuration", "-i", $InputPath)
    $args += @("-an") + $commonVideo + @($outPath)

    [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
    $bytes = [double](Get-Item $outPath).Length
    $segmentBytes += $bytes
    [void]$previewSegments.Add([PSCustomObject]@{
        Path  = $outPath
        Bytes = $bytes
        Window = $window
      })
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
  $metricSampling = Get-ResolvedMetricSampling -Plan $Plan -PreviewSampleSeconds $SampleSeconds
  if (
    (Get-NormalizedOptionValue -Value (Get-ObjectPropertyValue -Object $Plan -Name "MetricModeUsed" -DefaultValue "off") -DefaultValue "off") -ne "off" -and
    ($metricSampling.SampleSeconds -ne $SampleSeconds -or $metricSampling.MaxSamples -ne $sampleWindows.Count)
  ) {
    $metricWindows = @(Get-PreviewSampleWindows -Info $Info -Plan $Plan -SampleSeconds $metricSampling.SampleSeconds -MaxSamples $metricSampling.MaxSamples)
    $metricIdx = 0
    foreach ($window in $metricWindows) {
      $metricIdx++
      $offset = [double](Get-ObjectPropertyValue -Object $window -Name "Start" -DefaultValue 0.0)
      $windowDuration = [double](Get-ObjectPropertyValue -Object $window -Name "Duration" -DefaultValue $metricSampling.SampleSeconds)
      $outPath = Join-Path $TempDir ("metricpreview_{0}_{1}_{2}_{3}{4}" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $metricIdx, $Plan.OutputExtension)
      $args = @("-y", "-ss", "$offset", "-t", "$windowDuration", "-i", $InputPath)
      $args += @("-an") + $commonVideo + @($outPath)
      [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
      [void]$metricSegments.Add([PSCustomObject]@{
          Path  = $outPath
          Bytes = [double](Get-Item $outPath).Length
          Window = $window
        })
    }
  }
  else {
    foreach ($segment in @($previewSegments.ToArray())) {
      [void]$metricSegments.Add($segment)
    }
  }

  $metricResult = Invoke-PreviewMetric -InputPath $InputPath -PreviewSegments @($metricSegments.ToArray()) -Plan $Plan -TempDir $TempDir
  $metricBundle = Get-MetricScoreBundle -MetricResult $metricResult
  $predictedTotalBytes = [long][math]::Floor($predictedVideoBytes + [double]$Plan.AudioPlan.EstimatedBytes + [double](Get-MuxReserveBytes -targetBytes $Plan.TargetBytes -mode $Plan.Mode -Container $Plan.CodecProfile.Container -VideoCodec $Plan.CodecProfile.VideoCodec -AudioMode $Plan.AudioPlan.Mode))
  $predictedRatio = $predictedTotalBytes / [double]$Plan.TargetBytes

  $previewResult = [PSCustomObject]@{
    Success    = ($predictedTotalBytes -gt 0)
    SizeBytes  = $predictedTotalBytes
    VideoBytes = [long][math]::Floor($predictedVideoBytes)
    MeanSegmentBytes = [long][math]::Floor($avgSegmentBytes)
    MaxSegmentBytes  = [long][math]::Floor($maxSegmentBytes)
    SampleCount = [int]$segmentBytes.Length
    Path       = $null
    Plan       = $Plan.PSObject.Copy()
    Ratio      = $predictedRatio
    SamplingModeUsed = [string](Get-ObjectPropertyValue -Object $Plan -Name "SamplingModeUsed" -DefaultValue "fixed")
    SampleWindows = @($sampleWindows)
  }

  foreach ($segment in @($previewSegments.ToArray())) {
    Remove-Item $segment.Path -Force -ErrorAction SilentlyContinue
  }
  foreach ($segment in @($metricSegments.ToArray())) {
    if (-not ($previewSegments | Where-Object { $_.Path -eq $segment.Path })) {
      Remove-Item $segment.Path -Force -ErrorAction SilentlyContinue
    }
  }

  return (Merge-PreviewAndMetricScore -Preview $previewResult -MetricBundle $metricBundle)
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
        PreviewResults = @()
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
                $selectedPlan | Add-Member -NotePropertyName MetricModeUsed -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $preview -Name "MetricModeUsed" -DefaultValue "off")) -Force
                $selectedPlan | Add-Member -NotePropertyName MetricScore -NotePropertyValue (Get-ObjectPropertyValue -Object $preview -Name "MetricScore" -DefaultValue $null) -Force
                $selectedPlan | Add-Member -NotePropertyName MetricConfidence -NotePropertyValue ([double](Get-ObjectPropertyValue -Object $preview -Name "MetricConfidence" -DefaultValue 0.0)) -Force
                [void]$previewSelected.Add($selectedPlan)
              }

              return [PSCustomObject]@{
                Plans       = @($previewSelected.ToArray())
                PreviewsRun = $previewsRun
                PreviewResults = @($previewResults.ToArray())
              }
            }
          }
        }
      }

      return [PSCustomObject]@{
        Plans       = @(Set-PlanPreviewMetadata -Plans @($selectedPlans.ToArray()))
        PreviewsRun = $previewsRun
        PreviewResults = @($previewResults.ToArray())
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
          PreviewResults = @()
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
          $selectedPlan | Add-Member -NotePropertyName MetricModeUsed -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $preview -Name "MetricModeUsed" -DefaultValue "off")) -Force
          $selectedPlan | Add-Member -NotePropertyName MetricScore -NotePropertyValue (Get-ObjectPropertyValue -Object $preview -Name "MetricScore" -DefaultValue $null) -Force
          $selectedPlan | Add-Member -NotePropertyName MetricConfidence -NotePropertyValue ([double](Get-ObjectPropertyValue -Object $preview -Name "MetricConfidence" -DefaultValue 0.0)) -Force
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
        PreviewResults = @($previewResults.ToArray())
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

  $retryPlan = Apply-SizeCalibrationToPlan -Plan $Plan -Calibration (Get-ObservedSizeCalibration -ReferenceResult $Result)
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
        $_.PreprocessLabel -ne $Plan.PreprocessLabel
      } |
      Select-Object -First 1
  )
}

function Get-AdjacentFpsPlans {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Plans
  )

  $audioIdentity = Get-AudioPlanIdentity -AudioPlan $Plan.AudioPlan
  $matching = @(
    $Plans |
      Where-Object {
        $_.Width -eq $Plan.Width -and
        (Get-AudioPlanIdentity -AudioPlan $_.AudioPlan) -eq $audioIdentity -and
        $_.PreprocessTier -eq $Plan.PreprocessTier
      } |
      Sort-Object -Property @{ Expression = { $_.Fps }; Descending = $true }, @{ Expression = { $_.Score }; Descending = $true }
  )

  if ($matching.Count -lt 2) { return @() }
  $currentIndex = -1
  for ($i = 0; $i -lt $matching.Count; $i++) {
    if ($matching[$i].Fps -eq $Plan.Fps) {
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

function Get-AdjacentPreprocessPlans {
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
        $_.PreprocessLabel -ne $Plan.PreprocessLabel
      } |
      Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.PreprocessLabel }; Descending = $false } |
      Select-Object -First 2
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
    ($Candidate.PreprocessLabel -in @("mild-denoise", "temporal-denoise", "ringing-reduction") -and $Candidate.PreprocessLabel -ne $ReferencePlan.PreprocessLabel)
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
    ($Candidate.PreprocessLabel -eq "screen-sharpen" -and $ReferencePlan.PreprocessLabel -ne "screen-sharpen")
  )
}

function Get-ObservedSizeCalibration {
  param(
    [Parameter(Mandatory = $true)]$ReferenceResult
  )

  return [PSCustomObject]@{
    ObservedBias     = [double][math]::Max(0.85, [math]::Min(1.25, [double](Get-ObjectPropertyValue -Object $ReferenceResult -Name "PredictionBias" -DefaultValue 1.0)))
    VideoCodec       = [string]$ReferenceResult.Plan.CodecProfile.VideoCodec
    Container        = [string]$ReferenceResult.Plan.CodecProfile.Container
    AudioMode        = [string]$ReferenceResult.Plan.AudioPlan.Mode
    PreprocessLabel  = [string](Get-ObjectPropertyValue -Object $ReferenceResult.Plan -Name "PreprocessLabel" -DefaultValue "none")
    DurationBucket   = if ($ReferenceResult.Plan.DurationSeconds -le 60) { "short" } elseif ($ReferenceResult.Plan.DurationSeconds -le 300) { "medium" } else { "long" }
  }
}

function Apply-SizeCalibrationToPlan {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Calibration
  )

  $planCopy = $Plan.PSObject.Copy()
  $reserve = Get-MuxReserveBytes -targetBytes $planCopy.TargetBytes -mode $planCopy.Mode -Container $planCopy.CodecProfile.Container -VideoCodec $planCopy.CodecProfile.VideoCodec -AudioMode $planCopy.AudioPlan.Mode -ObservedBias ([double]$Calibration.ObservedBias)
  $planCopy | Add-Member -NotePropertyName ReserveBytes -NotePropertyValue ([long]$reserve) -Force
  $planCopy | Add-Member -NotePropertyName CalibratedFromPreview -NotePropertyValue $true -Force
  return $planCopy
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

  $planCopy = Apply-SizeCalibrationToPlan -Plan $CandidatePlan -Calibration (Get-ObservedSizeCalibration -ReferenceResult $ReferenceResult)
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
  foreach ($candidate in @(Get-AdjacentFpsPlans -Plan $ReferenceResult.Plan -Plans $AllPlans)) {
    if ($candidate) { [void]$candidates.Add($candidate) }
  }
  foreach ($candidate in @(Get-DenoiseTogglePlan -Plan $ReferenceResult.Plan -Plans $AllPlans)) {
    if ($candidate) { [void]$candidates.Add($candidate) }
  }
  foreach ($candidate in @(Get-AdjacentPreprocessPlans -Plan $ReferenceResult.Plan -Plans $AllPlans)) {
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

function Get-CodecAwareFallbackPlan {
  param(
    [Parameter(Mandatory = $true)]$ReferenceResult,
    [Parameter(Mandatory = $true)]$AllPlans
  )

  if (-not [bool](Get-ObjectPropertyValue -Object $ReferenceResult.Plan -Name "CanChangeCodecInSecondStage" -DefaultValue $false)) {
    return $null
  }

  return (
    $AllPlans |
      Where-Object {
        $_.CodecProfile.VideoCodec -ne $ReferenceResult.Plan.CodecProfile.VideoCodec -or
        $_.CodecProfile.Container -ne $ReferenceResult.Plan.CodecProfile.Container
      } |
      Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true } |
      Select-Object -First 1
  )
}

function Get-SearchActionCandidates {
  param(
    [Parameter(Mandatory = $true)]$ReferenceResult,
    [Parameter(Mandatory = $true)]$AllPlans,
    $Challenger
  )

  $options = New-Object System.Collections.Generic.List[object]
  $retryPlan = Get-RetryPlanFromResult -Plan $ReferenceResult.Plan -Result $ReferenceResult
  if ($retryPlan) {
    $retryScore = [double]$ReferenceResult.Plan.Score + 900.0
    if ($ReferenceResult.Ratio -gt 1.0 -and $ReferenceResult.Ratio -lt 1.03) { $retryScore += 300.0 }
    if ($ReferenceResult.Ratio -lt 1.0 -and $ReferenceResult.Ratio -gt 0.96) { $retryScore += 200.0 }
    [void]$options.Add([PSCustomObject]@{ Kind = "retune"; Score = $retryScore; Plan = $retryPlan })
  }

  if ($Challenger) {
    $challengerPlan = Get-CalibratedFallbackPlan -CandidatePlan $Challenger -ReferenceResult $ReferenceResult
    $challengerScore = [double]$challengerPlan.Score + 600.0 + ((1.0 - [double](Get-ObjectPropertyValue -Object $ReferenceResult.Plan -Name "Confidence" -DefaultValue 1.0)) * 1000.0)
    [void]$options.Add([PSCustomObject]@{ Kind = "challenger"; Score = $challengerScore; Plan = $challengerPlan })
  }

  $fallbackPlan = Expand-PlanNeighborhood -ReferenceResult $ReferenceResult -AllPlans $AllPlans | Select-Object -First 1
  if ($fallbackPlan) {
    [void]$options.Add([PSCustomObject]@{ Kind = "fallback"; Score = (Get-SecondStageCandidateScore -Candidate $fallbackPlan -ReferenceResult $ReferenceResult); Plan = $fallbackPlan })
  }

  $codecAware = Get-CodecAwareFallbackPlan -ReferenceResult $ReferenceResult -AllPlans $AllPlans
  if ($codecAware) {
    $codecAwarePlan = Get-CalibratedFallbackPlan -CandidatePlan $codecAware -ReferenceResult $ReferenceResult
    [void]$options.Add([PSCustomObject]@{ Kind = "codec"; Score = (Get-SecondStageCandidateScore -Candidate $codecAwarePlan -ReferenceResult $ReferenceResult) + 200.0; Plan = $codecAwarePlan })
  }

  return @($options.ToArray())
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
  $chosen = $candidates | Select-Object -First 1
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
    $PolicyProfile = $null,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][string]$PreprocessProfile
  )

  $totalKbps = (($TargetBytes * 8.0) / $Info.Duration) / 1000.0
  $contentClass = [string](Get-ObjectPropertyValue -Object $Probe -Name "ContentClass" -DefaultValue "general")
  $audioPriority = if ($PolicyProfile) { [string](Get-ObjectPropertyValue -Object $PolicyProfile -Name "AudioPriority" -DefaultValue "balanced") } else { "balanced" }
  $fpsCandidates = Get-TargetFpsCandidates -srcFps $Info.Fps -mode $Mode -duration $Info.Duration -totalKbps $totalKbps -motionBucket $Probe.MotionBucket -detailBucket $Probe.DetailBucket -CodecProfile $CodecProfile -ContentClass $contentClass
  $audioCandidates = Get-AudioPlanCandidates -Info $Info -CodecProfile $CodecProfile -Mode $Mode -TotalKbps $totalKbps -Duration $Info.Duration -ProbeBucket $Probe.DetailBucket -AudioPriority $audioPriority -ContentClass $contentClass

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
      $usableVideoKbps = [int][math]::Floor(((($TargetBytes - $seedAudio.EstimatedBytes - (Get-MuxReserveBytes -targetBytes $TargetBytes -mode $Mode -Container $CodecProfile.Container -VideoCodec $CodecProfile.VideoCodec -AudioMode $seedAudio.Mode)) * 8.0) / $Info.Duration) / 1000.0)
      if ($usableVideoKbps -lt 40) { continue }

      $widthCandidates = Get-WidthPlanCandidates -Info $Info -Probe $Probe -TargetFps $fps -VideoKbps $usableVideoKbps -Mode $Mode -CodecProfile $CodecProfile
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
        $seedPlan = New-EncodePlan `
          -Info $Info `
          -Probe $Probe `
          -CodecProfile $CodecProfile `
          -PolicyProfile $PolicyProfile `
          -Mode $Mode `
          -TargetBytes $TargetBytes `
          -Preset $Preset `
          -Width $w.Width `
          -Height $w.Height `
          -Fps $fps `
          -AudioPlan $a `
          -WidthOrigin $w.Origin `
          -PreprocessProfileName "none"

        if ($null -eq $seedPlan) {
          continue
        }

        $preprocessCandidates = Get-PreprocessCandidates -RequestedProfile $PreprocessProfile -Mode $Mode -ContentClass $contentClass -TotalBudgetKbps $seedPlan.TotalBudgetKbps -Bpppf $seedPlan.Bpppf
        foreach ($preprocessCandidate in $preprocessCandidates) {
          $normalizedPreprocess = Get-NormalizedOptionValue -Value $preprocessCandidate -DefaultValue "none"
          if ($normalizedPreprocess -eq "none") {
            $plans.Add($seedPlan)
            continue
          }

          $variantPlan = New-EncodePlan `
            -Info $Info `
            -Probe $Probe `
            -CodecProfile $CodecProfile `
            -PolicyProfile $PolicyProfile `
            -Mode $Mode `
            -TargetBytes $TargetBytes `
            -Preset $Preset `
            -Width $w.Width `
            -Height $w.Height `
            -Fps $fps `
            -AudioPlan $a `
            -WidthOrigin $w.Origin `
            -PreprocessProfileName $normalizedPreprocess `
            -UseDenoise:($normalizedPreprocess -in @("mild-denoise", "temporal-denoise"))

          if ($null -ne $variantPlan) {
            $plans.Add($variantPlan)
          }
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
  $metricScore = Get-NormalizedMetricPreferenceScore -Result $Result
  $metricConfidence = [int][math]::Round([double](Get-ObjectPropertyValue -Object $Result -Name "MetricConfidence" -DefaultValue (Get-ObjectPropertyValue -Object $plan -Name "MetricConfidence" -DefaultValue 0.0)) * 1000.0)

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
        $metricScore,
        $metricConfidence,
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
        $metricScore,
        $metricConfidence,
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
  $metricScore = Get-NormalizedMetricPreferenceScore -Result $Result
  $metricConfidence = [int][math]::Round([double](Get-ObjectPropertyValue -Object $Result -Name "MetricConfidence" -DefaultValue 0.0) * 1000.0)

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
        $metricScore,
        $metricConfidence,
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
        $metricScore,
        $metricConfidence,
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
  $backup = $Plans | Select-Object -Skip 1 -First 1

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
  $challenger = $Plans | Select-Object -Skip 1 -First 1
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

    $selectedAction =
      Get-SearchActionCandidates -ReferenceResult $primaryResult -AllPlans $AllPlans -Challenger $challenger |
        Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true } |
        Select-Object -First 1
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
    $thirdFinalist = $Plans | Select-Object -Skip 2 -First 1
    if ($thirdFinalist) { [void]$extraCandidates.Add($thirdFinalist) }

    if ($bestUnder) {
      foreach ($candidate in @(Expand-PlanNeighborhood -ReferenceResult $bestUnder -AllPlans $AllPlans -PresetWasExplicit:$PresetWasExplicit)) {
        if ($candidate) { [void]$extraCandidates.Add($candidate) }
      }
    }

    $selectedExtra =
      $extraCandidates |
        Where-Object { $null -ne $_ -and -not $triedKeys.Contains((Get-PlanKey -Plan $_)) } |
        Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { Get-ObjectPropertyValue -Object $_ -Name "Confidence" -DefaultValue 0.75 }; Descending = $true } |
        Select-Object -First 1

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
    $PolicyProfile = $null,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][bool]$PresetWasExplicit,
    [Parameter(Mandatory = $true)][string]$PreprocessProfile
  )

  $planBundle = Get-PlanList -Info $Info -Probe $Probe -CodecProfile $CodecProfile -PolicyProfile $PolicyProfile -TargetBytes $TargetBytes -Mode $Mode -Preset $Preset -PreprocessProfile $PreprocessProfile
  $plans = @($planBundle.Plans)
  $audioCandidates = @($planBundle.AudioCandidates)

  Write-PlanLogRecord -RecordType "candidate_plans" -Data ([PSCustomObject]@{
      AudioCandidates = @($audioCandidates)
      CandidatePlans  = @($plans | ForEach-Object { Get-PlanFeatureVector -Plan $_ })
    })

  if (-not $plans -or $plans.Count -eq 0 -or $null -eq $plans[0]) {
    throw "No viable encode plans were generated."
  }

  $archetypes = Get-PlanArchetypes -Plans $plans -Info $Info -Probe $Probe -TargetBytes $TargetBytes -Mode $Mode
  if (-not $archetypes -or $archetypes.Count -eq 0) {
    throw "No viable archetypal plans were generated."
  }

  $finalistBundle = Get-PlanFinalists -Info $Info -Plans $archetypes -InputPath $InputPath -TempDir $TempDir -Mode $Mode
  $finalists = @($finalistBundle.Plans)

  Write-PlanLogRecord -RecordType "preview_selection" -Data ([PSCustomObject]@{
      Archetypes      = @($archetypes | ForEach-Object { Get-PlanFeatureVector -Plan $_ })
      PreviewResults  = @($finalistBundle.PreviewResults)
      Finalists       = @($finalists | ForEach-Object { Get-PlanFeatureVector -Plan $_ })
      PreviewsRun     = [int]$finalistBundle.PreviewsRun
    })

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

  if ($result) {
    Write-PlanLogRecord -RecordType "search_result" -Data (Get-OutcomeRecord -Result $result)
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

$info = Get-ProbeInfo -path $inputFull
$targetRequestBytes = Get-RequestedTargetBytes
$hasExplicitTarget = ($null -ne $targetRequestBytes)
$usableTargetBytes = if ($hasExplicitTarget) { [long][math]::Floor($targetRequestBytes * $SafetyMarginPercent) } else { 0L }
$totalKbps = if ($hasExplicitTarget) { (($usableTargetBytes * 8.0) / $info.Duration) / 1000.0 } else { 0.0 }
$runtimeCapabilities = Get-RuntimeCapabilities
$policyProfile = Resolve-PolicyProfile `
  -RequestedVideoCodec $VideoCodec `
  -RequestedContainer $Container `
  -RequestedMetricMode $MetricMode `
  -RequestedSampleMode $SampleMode `
  -RequestedContentClassMode $ContentClassMode `
  -CompatibilityMode $CompatibilityMode `
  -AudioPriority $AudioPriority `
  -Mode $Mode `
  -TotalKbps $totalKbps

$codecProfile = Resolve-CodecProfile -VideoCodec $policyProfile.VideoCodec -Container $policyProfile.Container
Assert-CodecProfileSupport -CodecProfile $codecProfile

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
  $OutputFile = Get-DefaultOutputPath -InputPath $inputFull -CodecProfile $codecProfile
}

Assert-OutputFileMatchesProfile -OutputPath $OutputFile -CodecProfile $codecProfile

$script:PlanLogPathResolved = if ($EnablePlanLogging) {
  if (-not [string]::IsNullOrWhiteSpace($PlanLogPath)) {
    $PlanLogPath
  }
  else {
    $outputDir = Split-Path $OutputFile -Parent
    $outputBase = [System.IO.Path]::GetFileNameWithoutExtension($inputFull)
    Join-Path $outputDir ("{0}_{1}.planlog.jsonl" -f $outputBase, (Get-Date -Format "yyyyMMdd_HHmmss"))
  }
}
else {
  ""
}

if ($EnablePlanLogging -and -not [string]::IsNullOrWhiteSpace($script:PlanLogPathResolved)) {
  $planLogDir = Split-Path $script:PlanLogPathResolved -Parent
  if (-not [string]::IsNullOrWhiteSpace($planLogDir) -and -not (Test-Path $planLogDir)) {
    New-Item -ItemType Directory -Path $planLogDir -Force | Out-Null
  }
}

$cropResult = Invoke-CropDetect -Info $info -InputPath $inputFull -CropMode $CropMode
$info = Set-InfoPlanningContext -Info $info -CropResult $cropResult

Write-PlanLogRecord -RecordType "job_start" -Data ([PSCustomObject]@{
    InputFile            = $inputFull
    OutputFile           = $OutputFile
    RequestedVideoCodec  = $VideoCodec
    RequestedContainer   = if ([string]::IsNullOrWhiteSpace($Container)) { "auto" } else { $Container }
    RuntimeCapabilities  = $runtimeCapabilities
    PolicyProfile        = $policyProfile
    Mode                 = $Mode
    TargetRequestBytes   = $targetRequestBytes
    UsableTargetBytes    = $usableTargetBytes
    MetricSampleSeconds  = $MetricSampleSeconds
    MetricMaxSamples     = $MetricMaxSamples
    CropMode             = $CropMode
    PreprocessProfile    = $PreprocessProfile
  })

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
Write-Host "Policy:           $($policyProfile.CompatibilityMode)"
Write-Host "Output codec:     $($codecProfile.VideoCodec)"
Write-Host "Container:        $($codecProfile.Container)"
Write-Host "Metric mode:      $($policyProfile.MetricModeUsed)"
Write-Host "Sample mode:      $($policyProfile.SamplingModeUsed)"
Write-Host "Content class:    $($policyProfile.ContentClassModeUsed)"
Write-Host "Audio priority:   $($policyProfile.AudioPriority)"
Write-Host "Preset:           $Preset"
Write-Host "Crop mode:        $CropMode"
Write-Host "Crop detect:      $(Get-CropSummary -Info $info)"
Write-Host "Preprocess:       $PreprocessProfile"
Write-Host "Codec reason:     $($policyProfile.CodecPolicyReason)"
Write-Host "Container reason: $($policyProfile.ContainerPolicyReason)"
if ($EnablePlanLogging) {
  Write-Host "Plan log:         $script:PlanLogPathResolved"
}
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
    -SampleSeconds $ProbeSampleSeconds `
    -SampleMode $policyProfile.SamplingModeUsed `
    -ContentClassMode $policyProfile.ContentClassModeUsed
  $resolutionProfile = Get-ResolutionPlanningProfile -Info $info -Probe $probe -Mode $Mode

  Write-PlanLogRecord -RecordType "probe" -Data ([PSCustomObject]@{
      Probe = $probe
      ResolutionProfile = $resolutionProfile
    })

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
  Write-Host "Sampling used:    $($probe.SamplingModeUsed)"
  Write-Host "Content class:    $($probe.ContentClass)"
  Write-Host "Resolution bias:  $($resolutionProfile.BiasLabel) (ratio=$($resolutionProfile.SourceToProbeRatio), bpppf=$('{0:N4}' -f $resolutionProfile.TargetBpppf))"
  Write-Host ""

  $winner = Get-BestResult `
    -Info $info `
    -Probe $probe `
    -CodecProfile $codecProfile `
    -PolicyProfile $policyProfile `
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
  Write-PlanLogRecord -RecordType "final_output" -Data (Get-OutcomeRecord -Result $winner)

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
  Write-Host "Content class:    $($winner.Plan.ContentClass)"
  Write-Host "Metric mode:      $($winner.Plan.MetricModeUsed)"
  Write-Host "Metric score:     $(if ($null -ne $winner.Plan.MetricScore) { $winner.Plan.MetricScore } else { '(none)' })"
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
