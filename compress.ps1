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

  [ValidateSet("off", "xpsnr", "vmaf", "ensemble", "auto")]
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

  [ValidateSet("Off", "Streaming")]
  [string]$VbvMode = "Off",

  [ValidateSet("Auto", "8", "10")]
  [string]$OutputBitDepth = "Auto",

  [switch]$VerboseCommands,

  [ValidateSet("Auto", "Copy", "Transcode")]
  [string]$UnderCapBehavior = "Auto",

  [ValidateSet("auto", "libx264", "libx265", "svtav1", "aom", "rav1e", "vpx", "vvenc", "vaapi")]
  [string]$EncoderBackend = "auto",

  [switch]$EnableExperimentalEncoders,

  [AllowEmptyString()]
  [string]$HardwareDevice = "auto",

  [AllowEmptyString()]
  [string]$ResultJsonPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$scriptStart = Get-Date
$script:EncoderPixelFormatSupportCache = @{}
$script:VmafNegModelAvailable = $null
$script:RequestedHardCapBytes = $null
$script:AudioCache = @{}
$script:FunctionalProbeCache = @{}
$script:FunctionalProbeCacheLoaded = $false
$script:FunctionalProbeCachePath = ""
$script:HostFingerprint = $null

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

$script:FFmpegEncodersText = $null
$script:FFmpegMuxersText = $null
$script:FFmpegFiltersText = $null
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

function Get-FFmpegEncodersText {
  if ($null -eq $script:FFmpegEncodersText) {
    $script:FFmpegEncodersText = (Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-encoders")).Output
  }

  return [string]$script:FFmpegEncodersText
}

function Get-FFmpegMuxersText {
  if ($null -eq $script:FFmpegMuxersText) {
    $script:FFmpegMuxersText = (Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-muxers")).Output
  }

  return [string]$script:FFmpegMuxersText
}

function Get-FFmpegFiltersText {
  if ($null -eq $script:FFmpegFiltersText) {
    $script:FFmpegFiltersText = (Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-filters")).Output
  }

  return [string]$script:FFmpegFiltersText
}

function Test-FFmpegEncoderAvailable([string]$Encoder) {
  $pattern = ('(?m)^\s*[A-Z\.]+\s+{0}\s' -f [regex]::Escape($Encoder))
  return ([regex]::IsMatch((Get-FFmpegEncodersText), $pattern))
}

function Test-FFmpegMuxerAvailable([string]$Muxer) {
  $pattern = ('(?m)^\s*E\s+{0}\s' -f [regex]::Escape($Muxer))
  return ([regex]::IsMatch((Get-FFmpegMuxersText), $pattern))
}

function Test-FFmpegFilterAvailable([string]$Filter) {
  $pattern = ('(?m)^\s*[TSC\.\|AVN]+\s+{0}\s' -f [regex]::Escape($Filter))
  return ([regex]::IsMatch((Get-FFmpegFiltersText), $pattern))
}

function Get-RuntimeCapabilities {
  if ($null -ne $script:RuntimeCapabilities) {
    return $script:RuntimeCapabilities
  }

  $x264Available = Test-FFmpegEncoderAvailable -Encoder "libx264"
  $x265Available = Test-FFmpegEncoderAvailable -Encoder "libx265"
  $av1Available = Test-FFmpegEncoderAvailable -Encoder "libsvtav1"
  $mp4Available = Test-FFmpegMuxerAvailable -Muxer "mp4"
  $webmAvailable = Test-FFmpegMuxerAvailable -Muxer "webm"
  $aacAvailable = Test-FFmpegEncoderAvailable -Encoder "aac"
  $opusAvailable = (Test-FFmpegEncoderAvailable -Encoder "libopus") -or (Test-FFmpegEncoderAvailable -Encoder "opus")
  $hasVmaf = Test-FFmpegFilterAvailable -Filter "libvmaf"
  $hasXpsnr = Test-FFmpegFilterAvailable -Filter "xpsnr"
  $hasScdet = Test-FFmpegFilterAvailable -Filter "scdet"

  $x264Probe = if ($x264Available -and $mp4Available -and $aacAvailable) { Invoke-EncoderFunctionalProbe -CodecProfile (Resolve-CodecProfile -VideoCodec "x264" -Container "mp4" -EncoderBackend "libx264") } else { $null }
  $x265Probe = if ($x265Available -and $mp4Available -and $aacAvailable) { Invoke-EncoderFunctionalProbe -CodecProfile (Resolve-CodecProfile -VideoCodec "x265" -Container "mp4" -EncoderBackend "libx265") } else { $null }
  $av1Probe = if ($av1Available -and $webmAvailable -and $opusAvailable) { Invoke-EncoderFunctionalProbe -CodecProfile (Resolve-CodecProfile -VideoCodec "av1" -Container "webm" -EncoderBackend "svtav1") } else { $null }

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
    X264FunctionalProbe    = $x264Probe
    X265FunctionalProbe    = $x265Probe
    Av1FunctionalProbe     = $av1Probe
    SupportsX264Mp4        = [bool]($x264Probe -and $x264Probe.Success)
    SupportsX265Mp4        = [bool]($x265Probe -and $x265Probe.Success)
    SupportsAv1Webm        = [bool]($av1Probe -and $av1Probe.Success)
    PreferredMetricMode    = if ($hasVmaf -and $hasXpsnr) { "ensemble" } elseif ($hasVmaf) { "vmaf" } elseif ($hasXpsnr) { "xpsnr" } else { "off" }
    PreferredSamplingMode  = if ($hasScdet) { "sceneaware" } else { "fixed" }
  }

  $script:RuntimeCapabilities = $capabilities
  return $capabilities
}

function Get-CodecForEncoderBackend {
  param(
    [Parameter(Mandatory = $true)][string]$Backend,
    [string]$RequestedVideoCodec = "auto"
  )

  switch (Get-NormalizedOptionValue -Value $Backend -DefaultValue "auto") {
    "libx264" { return "x264" }
    "libx265" { return "x265" }
    "svtav1"  { return "av1" }
    "aom"     { return "av1" }
    "rav1e"   { return "av1" }
    "vpx"     { return "vp9" }
    "vvenc"   { return "vvc" }
    "vaapi"   {
      $codec = Get-NormalizedOptionValue -Value $RequestedVideoCodec -DefaultValue "auto"
      if ($codec -notin @("x264", "x265", "av1")) {
        throw "The VAAPI backend requires -VideoCodec x264, x265, or av1."
      }
      return $codec
    }
    default { return (Get-NormalizedOptionValue -Value $RequestedVideoCodec -DefaultValue "auto") }
  }
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
    [string]$RequestedEncoderBackend = "auto",
    [bool]$RequestedVideoCodecWasExplicit = $false,
    [switch]$EnableExperimental,
    [double]$TotalKbps = 0.0
  )

  $caps = Get-RuntimeCapabilities
  $requestedCodec = Get-NormalizedOptionValue -Value $RequestedVideoCodec -DefaultValue "x264"
  $requestedBackend = Get-NormalizedOptionValue -Value $RequestedEncoderBackend -DefaultValue "auto"
  if ($requestedBackend -ne "auto") {
    if ($requestedBackend -in @("aom", "rav1e", "vpx", "vvenc") -and -not $EnableExperimental) {
      throw "Encoder backend '$requestedBackend' is experimental. Add -EnableExperimentalEncoders to select it explicitly."
    }
    if ($requestedBackend -eq "vvenc") {
      throw "VVenC is a raw-video lab backend and is not available for delivery output."
    }
    if ($requestedBackend -eq "vaapi") {
      throw "VAAPI is implemented by the cross-platform C# worker, not by this PowerShell reference frontend."
    }
    $backendCodec = Get-CodecForEncoderBackend -Backend $requestedBackend -RequestedVideoCodec $requestedCodec
    if ($RequestedVideoCodecWasExplicit -and $requestedCodec -ne "auto" -and $requestedCodec -ne $backendCodec) {
      throw "Encoder backend '$requestedBackend' does not implement requested codec '$requestedCodec'."
    }
    $requestedCodec = $backendCodec
  }
  $requestedContainerValue = Get-NormalizedOptionValue -Value $RequestedContainer -DefaultValue "auto"
  $requestedMetric = Get-NormalizedOptionValue -Value $RequestedMetricMode -DefaultValue "auto"
  $requestedSample = Get-NormalizedOptionValue -Value $RequestedSampleMode -DefaultValue "auto"
  $requestedContentClass = Get-NormalizedOptionValue -Value $RequestedContentClassMode -DefaultValue "auto"
  $compatibility = Get-NormalizedOptionValue -Value $CompatibilityMode -DefaultValue "widest"

  if ($requestedContainerValue -notin @("auto", "mp4", "webm")) {
    throw "Unsupported container '$RequestedContainer'. Supported containers are mp4, webm, and auto."
  }

  if ($requestedCodec -notin @("x264", "x265", "av1", "vp9", "auto")) {
    throw "Unsupported video codec '$RequestedVideoCodec'. Supported codecs are x264, x265, av1, and auto; VP9 is selected through the experimental vpx backend."
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

  # A pinned codec is an explicit compatibility decision. Resolve its default
  # container directly instead of filtering it through automatic policy
  # candidates, which intentionally omit slower codecs in Fast mode.
  if ($codecPinned -and -not $containerPinned) {
    $selectedContainer = Get-ResolvedContainer -VideoCodec $selectedCodec -Container "auto"
    $containerReason = "codec-default"
  }
  elseif (-not $codecPinned -or -not $containerPinned) {
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
    $selectedContainer = if ($selectedCodec -in @("av1", "vp9")) { "webm" } else { "mp4" }
    if ([string]::IsNullOrWhiteSpace($containerReason)) {
      $containerReason = "codec-default"
    }
  }

  $defaultAudioCodec = if ($selectedContainer -eq "webm") { "opus" } else { "aac" }

  return [PSCustomObject]@{
    VideoCodec                 = [string]$selectedCodec
    EncoderBackend             = if ($requestedBackend -ne "auto") { [string]$requestedBackend } else { switch ($selectedCodec) { "x264" { "libx264" } "x265" { "libx265" } "av1" { "svtav1" } "vp9" { "vpx" } } }
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

function Get-ExperimentalSpeedForPreset {
  param(
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][ValidateSet("aom", "vpx", "rav1e")][string]$Backend
  )

  $rank = Get-CodecPresetRank -preset $Preset
  if ($rank -le 0) { throw "Unsupported preset '$Preset' for backend '$Backend'." }
  switch ($Backend) {
    "rav1e" { return [int][math]::Max(0, [math]::Min(10, 11 - $rank)) }
    default { return [int][math]::Max(0, [math]::Min(8, 9 - $rank)) }
  }
}

function Get-CodecEfficiencyMultiplier([string]$VideoCodec) {
  switch ($VideoCodec) {
    "x264" { return 1.00 }
    "x265" { return 0.82 }
    "av1"  { return 0.72 }
    "vp9"  { return 0.84 }
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
    "vp9" {
      switch ($Mode) {
        "Fast"         { return 38.0 }
        "Balanced"     { return 34.0 }
        "ExtraQuality" { return 31.0 }
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
      "vp9"  { return "webm" }
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
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Container,
    [string]$EncoderBackend = "auto"
  )

  $resolvedContainer = Get-ResolvedContainer -VideoCodec $VideoCodec -Container $Container
  $backend = Get-NormalizedOptionValue -Value $EncoderBackend -DefaultValue "auto"
  if ($backend -eq "auto") {
    $backend = switch (Get-NormalizedOptionValue -Value $VideoCodec) {
      "x264" { "libx264" }
      "x265" { "libx265" }
      "av1"  { "svtav1" }
      "vp9"  { "vpx" }
      default { "" }
    }
  }

  switch ("$backend|$(Get-NormalizedOptionValue -Value $VideoCodec)|$resolvedContainer") {
    "libx264|x264|mp4" {
      return [PSCustomObject]@{
        VideoCodec           = "x264"
        EncoderBackend       = "libx264"
        VideoEncoder         = "libx264"
        CodecFamily          = "h264"
        Container            = "mp4"
        ContainerAudioProfile = "mp4-aac"
        Extension            = ".mp4"
        DefaultAudioCodec    = "aac"
        DefaultAudioEncoder  = "aac"
        CopyableAudioCodecs  = @("aac")
        PresetKind           = "x264"
        RateControlAdapter   = "ffmpeg-two-pass-vbr"
        RequiredPasses       = 2
        PrivateEncoderArgs   = @()
        PreviewSpeedOverride = [PSCustomObject]@{ Kind = "preset"; Value = "veryfast"; Label = "veryfast" }
        FinalizeArgs         = @("-c", "copy", "-movflags", "+faststart")
      }
    }
    "libx265|x265|mp4" {
      return [PSCustomObject]@{
        VideoCodec           = "x265"
        EncoderBackend       = "libx265"
        VideoEncoder         = "libx265"
        CodecFamily          = "hevc"
        Container            = "mp4"
        ContainerAudioProfile = "mp4-aac"
        Extension            = ".mp4"
        DefaultAudioCodec    = "aac"
        DefaultAudioEncoder  = "aac"
        CopyableAudioCodecs  = @("aac")
        PresetKind           = "x265"
        RateControlAdapter   = "ffmpeg-two-pass-vbr"
        RequiredPasses       = 2
        PrivateEncoderArgs   = @()
        PreviewSpeedOverride = [PSCustomObject]@{ Kind = "preset"; Value = "fast"; Label = "fast" }
        FinalizeArgs         = @("-c", "copy", "-movflags", "+faststart")
      }
    }
    "svtav1|av1|webm" {
      return [PSCustomObject]@{
        VideoCodec           = "av1"
        EncoderBackend       = "svtav1"
        VideoEncoder         = "libsvtav1"
        CodecFamily          = "av1"
        Container            = "webm"
        ContainerAudioProfile = "webm-opus"
        Extension            = ".webm"
        DefaultAudioCodec    = "opus"
        DefaultAudioEncoder  = if (Test-FFmpegEncoderAvailable -Encoder "libopus") { "libopus" } else { "opus" }
        CopyableAudioCodecs  = @("opus")
        PresetKind           = "svtav1"
        RateControlAdapter   = "ffmpeg-two-pass-vbr"
        RequiredPasses       = 2
        PrivateEncoderArgs   = @()
        PreviewSpeedOverride = [PSCustomObject]@{ Kind = "preset"; Value = 12; Label = "preset=12" }
        FinalizeArgs         = @("-c", "copy")
      }
    }
    "aom|av1|webm" {
      return [PSCustomObject]@{
        VideoCodec = "av1"; EncoderBackend = "aom"; VideoEncoder = "libaom-av1"; CodecFamily = "av1"
        Container = "webm"; ContainerAudioProfile = "webm-opus"; Extension = ".webm"
        DefaultAudioCodec = "opus"; DefaultAudioEncoder = if (Test-FFmpegEncoderAvailable -Encoder "libopus") { "libopus" } else { "opus" }
        CopyableAudioCodecs = @("opus"); PresetKind = "aom"; RateControlAdapter = "ffmpeg-two-pass-vbr"
        RequiredPasses = 2; PrivateEncoderArgs = @(); PreviewSpeedOverride = [PSCustomObject]@{ Kind = "cpu-used"; Value = 8; Label = "cpu-used=8" }
        FinalizeArgs = @("-c", "copy")
      }
    }
    "rav1e|av1|webm" {
      return [PSCustomObject]@{
        VideoCodec = "av1"; EncoderBackend = "rav1e"; VideoEncoder = "librav1e"; CodecFamily = "av1"
        Container = "webm"; ContainerAudioProfile = "webm-opus"; Extension = ".webm"
        DefaultAudioCodec = "opus"; DefaultAudioEncoder = if (Test-FFmpegEncoderAvailable -Encoder "libopus") { "libopus" } else { "opus" }
        CopyableAudioCodecs = @("opus"); PresetKind = "rav1e"; RateControlAdapter = "one-pass-vbr-lab"
        RequiredPasses = 1; PrivateEncoderArgs = @(); PreviewSpeedOverride = [PSCustomObject]@{ Kind = "speed"; Value = 10; Label = "speed=10" }
        FinalizeArgs = @("-c", "copy")
      }
    }
    "vpx|vp9|webm" {
      return [PSCustomObject]@{
        VideoCodec = "vp9"; EncoderBackend = "vpx"; VideoEncoder = "libvpx-vp9"; CodecFamily = "vp9"
        Container = "webm"; ContainerAudioProfile = "webm-opus"; Extension = ".webm"
        DefaultAudioCodec = "opus"; DefaultAudioEncoder = if (Test-FFmpegEncoderAvailable -Encoder "libopus") { "libopus" } else { "opus" }
        CopyableAudioCodecs = @("opus"); PresetKind = "vpx"; RateControlAdapter = "ffmpeg-two-pass-vbr"
        RequiredPasses = 2; PrivateEncoderArgs = @(); PreviewSpeedOverride = [PSCustomObject]@{ Kind = "cpu-used"; Value = 8; Label = "cpu-used=8" }
        FinalizeArgs = @("-c", "copy")
      }
    }
    "svtav1|av1|mp4" {
      throw "AV1 output is restricted to WebM in Phase 1. Use -Container webm."
    }
    default {
      throw "Unsupported encoder/codec/container combination: $backend + $VideoCodec + $resolvedContainer"
    }
  }
}

function Get-OutputExtension([string]$Path) {
  return [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Get-EncoderParameterFamilies {
  param(
    [Parameter(Mandatory = $true)][string]$Backend,
    [string]$ContentClass = "general"
  )

  switch (Get-NormalizedOptionValue -Value $Backend) {
    "libx264" { return @(
        [PSCustomObject]@{ Name = "encoder-defaults"; Args = @(); Automatic = $false },
        [PSCustomObject]@{ Name = "current-adaptive"; Args = @("content-adaptive-x264-params"); Automatic = $true }
      ) }
    "libx265" { return @(
        [PSCustomObject]@{ Name = "encoder-defaults"; Args = @(); Automatic = $true },
        [PSCustomObject]@{ Name = "aq-psy-low"; Args = @("-x265-params", "aq-mode=3:psy-rd=1.0"); Automatic = $false },
        [PSCustomObject]@{ Name = "aq-psy-high"; Args = @("-x265-params", "aq-mode=3:psy-rd=2.0"); Automatic = $false }
      ) }
    "svtav1" { return @(
        [PSCustomObject]@{ Name = "encoder-defaults"; Args = @(); Automatic = $true },
        [PSCustomObject]@{ Name = "visual-variance"; Args = @("-svtav1-params", "tune=0:enable-variance-boost=1"); Automatic = $false },
        [PSCustomObject]@{ Name = "gated-grain"; Args = @("lab-grain-synthesis"); Automatic = $false }
      ) }
    "aom" { return @(
        [PSCustomObject]@{ Name = "encoder-defaults"; Args = @(); Automatic = $false },
        [PSCustomObject]@{ Name = "variance-ssim"; Args = @("-aq-mode", "1", "-tune", "ssim"); Automatic = $false },
        [PSCustomObject]@{ Name = "complexity-psnr"; Args = @("-aq-mode", "2", "-tune", "psnr"); Automatic = $false }
      ) }
    "vpx" {
      $families = @(
        [PSCustomObject]@{ Name = "encoder-defaults"; Args = @(); Automatic = $false },
        [PSCustomObject]@{ Name = "aq-altref-rowmt"; Args = @("-aq-mode", "1", "-auto-alt-ref", "1", "-row-mt", "1"); Automatic = $false }
      )
      if ($ContentClass -eq "screen") {
        $families += [PSCustomObject]@{ Name = "screen-content"; Args = @("-tune-content", "screen", "-row-mt", "1"); Automatic = $false }
      }
      return $families
    }
    "rav1e" { return @([PSCustomObject]@{ Name = "lab-defaults"; Args = @(); Automatic = $false }) }
    "vvenc" { return @([PSCustomObject]@{ Name = "raw-two-pass-vbr"; Args = @("-passlogfile", "<path>"); Automatic = $false }) }
    default { return @() }
  }
}

function Get-FFmpegBuildFingerprint {
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-version") -AllowFailure
  $firstLine = @($capture.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
  if ($firstLine.Count -eq 0) { return "ffmpeg-unavailable" }
  return [string]$firstLine[0]
}

function Initialize-FunctionalProbeCache {
  if ($script:FunctionalProbeCacheLoaded) { return }
  $script:FunctionalProbeCacheLoaded = $true
  $cacheRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if ([string]::IsNullOrWhiteSpace($cacheRoot)) { return }
  $script:FunctionalProbeCachePath = Join-Path (Join-Path $cacheRoot "Byakuren") "encoder-capabilities-v1.json"
  if (-not (Test-Path -LiteralPath $script:FunctionalProbeCachePath)) { return }
  try {
    $stored = Get-Content -LiteralPath $script:FunctionalProbeCachePath -Raw | ConvertFrom-Json
    foreach ($property in @($stored.PSObject.Properties)) {
      $script:FunctionalProbeCache[$property.Name] = $property.Value
    }
  }
  catch {
    $script:FunctionalProbeCache = @{}
  }
}

function Save-FunctionalProbeCache {
  if ([string]::IsNullOrWhiteSpace([string]$script:FunctionalProbeCachePath)) { return }
  try {
    $directory = Split-Path $script:FunctionalProbeCachePath -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = $script:FunctionalProbeCachePath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    $script:FunctionalProbeCache | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $script:FunctionalProbeCachePath -Force
  }
  catch {
    # A cache write failure must never make an otherwise functional encoder fail.
  }
}

function Invoke-EncoderFunctionalProbe {
  param(
    [Parameter(Mandatory = $true)]$CodecProfile,
    [string]$Device = "auto"
  )

  $build = Get-FFmpegBuildFingerprint
  $os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
  $driver = if ($CodecProfile.EncoderBackend -eq "vaapi") { "hardware" } else { "software" }
  $key = "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}" -f $build, $os, $driver, $Device, $CodecProfile.EncoderBackend, $CodecProfile.RateControlAdapter, $CodecProfile.Container, "yuv420p"
  Initialize-FunctionalProbeCache
  if ($script:FunctionalProbeCache.ContainsKey($key)) {
    return $script:FunctionalProbeCache[$key]
  }

  $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("compress_encoder_probe_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temp | Out-Null
  $output = Join-Path $temp ("probe" + $CodecProfile.Extension)
  $passlog = Join-Path $temp "pass"
  $success = $false
  $errorText = ""
  try {
    $plan = [PSCustomObject]@{
      CodecProfile = $CodecProfile; Preset = "medium"; Mode = "Balanced"; VideoKbps = 200
      EncodeVFilter = ""; VFilter = ""; OutputPixelFormat = "yuv420p"; ColorMetadataArgs = @()
      VbvMode = "Off"; VideoPrivateArgs = ""
    }
    $common = @(Get-CommonVideoEncodeArgs -Plan $plan)
    $inputArgs = @("-y", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=0.4")
    if ([int]$CodecProfile.RequiredPasses -ge 2) {
      $first = Invoke-ToolCapture -Exe "ffmpeg" -Args ($inputArgs + $common + @("-pass", "1", "-passlogfile", $passlog, "-an", "-f", "null", "NUL")) -AllowFailure
      if ($first.ExitCode -ne 0) { $errorText = $first.StdErr; throw "pass-one" }
      $second = Invoke-ToolCapture -Exe "ffmpeg" -Args ($inputArgs + $common + @("-pass", "2", "-passlogfile", $passlog, "-an", $output)) -AllowFailure
      if ($second.ExitCode -ne 0) { $errorText = $second.StdErr; throw "pass-two" }
    }
    else {
      $encoded = Invoke-ToolCapture -Exe "ffmpeg" -Args ($inputArgs + $common + @("-an", $output)) -AllowFailure
      if ($encoded.ExitCode -ne 0) { $errorText = $encoded.StdErr; throw "encode" }
    }

    $decoded = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-v", "error", "-i", $output, "-f", "null", "NUL") -AllowFailure
    if ($decoded.ExitCode -ne 0) { $errorText = $decoded.StdErr; throw "decode" }
    $success = $true
  }
  catch {
    if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = $_.Exception.Message }
  }
  finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }

  $probe = [PSCustomObject]@{
    Success = [bool]$success
    Backend = [string]$CodecProfile.EncoderBackend
    Encoder = [string]$CodecProfile.VideoEncoder
    RateControlAdapter = [string]$CodecProfile.RateControlAdapter
    PixelFormat = "yuv420p"
    Container = [string]$CodecProfile.Container
    Device = [string]$Device
    Driver = [string]$driver
    FFmpegBuild = [string]$build
    Os = [string]$os
    Error = if ($success) { "" } else { [string]($errorText -replace '\s+', ' ').Trim() }
  }
  $script:FunctionalProbeCache[$key] = $probe
  Save-FunctionalProbeCache
  return $probe
}

function Invoke-VvencLabFunctionalProbe {
  $build = Get-FFmpegBuildFingerprint
  $os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
  $key = "{0}|{1}|software|raw-lab|vvenc|vvenc-two-pass-vbr|vvc|yuv420p10le" -f $build, $os
  Initialize-FunctionalProbeCache
  if ($script:FunctionalProbeCache.ContainsKey($key)) { return $script:FunctionalProbeCache[$key] }

  $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("compress_vvenc_probe_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temp | Out-Null
  $output = Join-Path $temp "probe.266"
  $passlog = Join-Path $temp "pass"
  $success = $false
  $errorText = ""
  try {
    $inputArgs = @("-y", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=0.4", "-vf", "format=yuv420p10le", "-c:v", "libvvenc", "-b:v", "200k", "-preset", "fast")
    $first = Invoke-ToolCapture -Exe "ffmpeg" -Args ($inputArgs + @("-pass", "1", "-passlogfile", $passlog, "-an", "-f", "null", "NUL")) -AllowFailure
    if ($first.ExitCode -ne 0) { $errorText = $first.StdErr; throw "pass-one" }
    $second = Invoke-ToolCapture -Exe "ffmpeg" -Args ($inputArgs + @("-pass", "2", "-passlogfile", $passlog, "-an", "-f", "vvc", $output)) -AllowFailure
    if ($second.ExitCode -ne 0) { $errorText = $second.StdErr; throw "pass-two" }
    $decoded = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-v", "error", "-i", $output, "-f", "null", "NUL") -AllowFailure
    if ($decoded.ExitCode -ne 0) { $errorText = $decoded.StdErr; throw "decode" }
    $success = $true
  }
  catch {
    if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = $_.Exception.Message }
  }
  finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }

  $probe = [PSCustomObject]@{
    Success = [bool]$success; Backend = "vvenc"; Encoder = "libvvenc"; RateControlAdapter = "vvenc-two-pass-vbr"
    PixelFormat = "yuv420p10le"; Container = "raw-vvc"; Device = "none"; Driver = "software"
    FFmpegBuild = [string]$build; Os = [string]$os; DeliveryEligible = $false
    Error = if ($success) { "" } else { [string]($errorText -replace '\s+', ' ').Trim() }
  }
  $script:FunctionalProbeCache[$key] = $probe
  Save-FunctionalProbeCache
  return $probe
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

  $probe = Invoke-EncoderFunctionalProbe -CodecProfile $CodecProfile -Device $HardwareDevice
  $CodecProfile | Add-Member -NotePropertyName FunctionalProbe -NotePropertyValue $probe -Force
  if (-not $probe.Success) {
    throw "Encoder backend '$($CodecProfile.EncoderBackend)' failed its functional encode/decode probe: $($probe.Error)"
  }

  if (-not (Test-FFmpegEncoderAvailable -Encoder $CodecProfile.DefaultAudioEncoder)) {
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

function Test-InputMatchesCodecProfile {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$CodecProfile
  )

  $sourceVideoCodec = (Get-NormalizedOptionValue -Value ([string]$Info.VideoCodec) -DefaultValue "")
  $videoMatches = switch ($CodecProfile.VideoCodec) {
    "x264" { $sourceVideoCodec -eq "h264" }
    "x265" { $sourceVideoCodec -in @("hevc", "h265") }
    "av1"  { $sourceVideoCodec -eq "av1" }
    "vp9"  { $sourceVideoCodec -eq "vp9" }
    default { $false }
  }
  if (-not $videoMatches) { return $false }

  $sourceExtension = Get-OutputExtension -Path $InputPath
  $sourceFormat = (Get-NormalizedOptionValue -Value ([string](Get-ObjectPropertyValue -Object $Info -Name "FormatName" -DefaultValue "")) -DefaultValue "")
  $containerMatches = switch ($CodecProfile.Container) {
    "mp4" { $sourceExtension -in @(".mp4", ".m4v") -and $sourceFormat -match '(^|,)mov|mp4' }
    "webm" { $sourceExtension -eq ".webm" -and $sourceFormat -match '(^|,)matroska|webm' }
    default { $false }
  }
  if (-not $containerMatches) { return $false }

  if (-not [bool]$Info.HasAudio) { return $true }
  $sourceAudioCodec = Get-NormalizedOptionValue -Value ([string]$Info.AudioCodec) -DefaultValue ""
  return ($sourceAudioCodec -in @($CodecProfile.CopyableAudioCodecs))
}

function Test-UnderCapPassthroughEligible {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)][long]$HardCapBytes,
    [ValidateSet("Auto", "Copy", "Transcode")][string]$Behavior = "Auto"
  )

  if ($Behavior -eq "Transcode") { return $false }
  $inputBytesValue = Get-ObjectPropertyValue -Object $Info -Name "InputBytes" -DefaultValue $null
  $inputBytes = if ($null -ne $inputBytesValue) { [long]$inputBytesValue } else { [long](Get-Item -LiteralPath $InputPath).Length }
  if ($inputBytes -gt $HardCapBytes) { return $false }
  if ($VbvMode -ne "Off" -or $OutputBitDepth -ne "Auto" -or $PreprocessProfile -eq "Mild") { return $false }
  return (Test-InputMatchesCodecProfile -Info $Info -InputPath $InputPath -CodecProfile $CodecProfile)
}

function Invoke-UnderCapPassthrough {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][long]$HardCapBytes
  )

  $inputResolved = (Resolve-Path -LiteralPath $InputPath).Path
  $outputFull = [System.IO.Path]::GetFullPath($OutputPath)
  if (-not [string]::Equals($inputResolved, $outputFull, [StringComparison]::OrdinalIgnoreCase)) {
    $outputDirectory = Split-Path $outputFull -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
      New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    [System.IO.File]::Copy($inputResolved, $outputFull, $true)
  }

  $size = Assert-FinalOutputWithinCap -Path $outputFull -HardCapBytes $HardCapBytes
  return [PSCustomObject]@{
    Action = "copy"
    OutputPath = $outputFull
    SizeBytes = [long]$size
    Ratio = ([double]$size / [double]$HardCapBytes)
  }
}

function Convert-RationalToDouble {
  param(
    [AllowEmptyString()][string]$Value,
    [double]$DefaultValue = 0.0
  )

  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @("0/0", "0:0", "N/A")) {
    return $DefaultValue
  }

  $parts = $Value -split '[/\:]'
  if ($parts.Count -eq 2) {
    $numerator = 0.0
    $denominator = 0.0
    if (
      [double]::TryParse($parts[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numerator) -and
      [double]::TryParse($parts[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$denominator) -and
      [math]::Abs($denominator) -gt 0.0000001
    ) {
      return ($numerator / $denominator)
    }
  }

  $parsed = 0.0
  if ([double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    return $parsed
  }

  return $DefaultValue
}

function Get-NormalizedRotation {
  param($VideoStream)

  $rotation = 0
  $tags = Get-ObjectPropertyValue -Object $VideoStream -Name "tags" -DefaultValue $null
  if ($tags) {
    $rawTag = [string](Get-ObjectPropertyValue -Object $tags -Name "rotate" -DefaultValue "")
    $tagRotation = 0
    if ([int]::TryParse($rawTag, [ref]$tagRotation)) {
      $rotation = $tagRotation
    }
  }

  foreach ($sideData in @((Get-ObjectPropertyValue -Object $VideoStream -Name "side_data_list" -DefaultValue @()))) {
    $rawSideRotation = [string](Get-ObjectPropertyValue -Object $sideData -Name "rotation" -DefaultValue "")
    $sideRotation = 0
    if ([int]::TryParse($rawSideRotation, [ref]$sideRotation)) {
      $rotation = $sideRotation
      break
    }
  }

  $rotation = (($rotation % 360) + 360) % 360
  if ($rotation -ge 315 -or $rotation -lt 45) { return 0 }
  if ($rotation -lt 135) { return 90 }
  if ($rotation -lt 225) { return 180 }
  return 270
}

function Get-HdrClassification {
  param($VideoStream)

  $transfer = ([string](Get-ObjectPropertyValue -Object $VideoStream -Name "color_transfer" -DefaultValue "")).ToLowerInvariant()
  if ($transfer -in @("smpte2084", "pq")) {
    return [PSCustomObject]@{ Classification = "PQ"; HasHdrMetadata = $true; Reason = "transfer=$transfer" }
  }
  if ($transfer -in @("arib-std-b67", "hlg")) {
    return [PSCustomObject]@{ Classification = "HLG"; HasHdrMetadata = $true; Reason = "transfer=$transfer" }
  }

  $hdrSideData = @((Get-ObjectPropertyValue -Object $VideoStream -Name "side_data_list" -DefaultValue @())) |
    Where-Object {
      ([string](Get-ObjectPropertyValue -Object $_ -Name "side_data_type" -DefaultValue "")) -match '(?i)mastering display|content light'
    } |
    Select-Object -First 1

  if ($hdrSideData) {
    return [PSCustomObject]@{ Classification = "unknown"; HasHdrMetadata = $true; Reason = [string](Get-ObjectPropertyValue -Object $hdrSideData -Name "side_data_type" -DefaultValue "HDR side data") }
  }

  $knownSdrTransfers = @("bt709", "smpte170m", "gamma22", "gamma28", "iec61966-2-1", "bt2020-10", "bt2020-12", "linear", "log", "log_sqrt")
  if ($transfer -in $knownSdrTransfers) {
    return [PSCustomObject]@{ Classification = "SDR"; HasHdrMetadata = $false; Reason = "transfer=$transfer" }
  }

  return [PSCustomObject]@{ Classification = "unknown"; HasHdrMetadata = $false; Reason = if ($transfer) { "unclassified transfer=$transfer" } else { "transfer metadata absent" } }
}

function Assert-SdrInputSupported {
  param([Parameter(Mandatory = $true)]$Info)

  if ($Info.HdrClassification -in @("PQ", "HLG") -or $Info.HasHdrMetadata) {
    throw "HDR input was detected ($($Info.HdrClassification); $($Info.HdrReason)). HDR transcoding and tone mapping are not implemented, so no encode was started. Convert to a validated SDR master first."
  }
}

function Get-ProbeInfo($path) {
  $json = & ffprobe -v error -print_format json -show_format -show_streams "$path"
  if (-not $json) { throw "ffprobe failed for: $path" }

  $probe = $json | ConvertFrom-Json
  $video = $probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
  $audio = $probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

  if (-not $video) { throw "No video stream found." }

  $srcFps = Convert-RationalToDouble -Value ([string](Get-ObjectPropertyValue -Object $video -Name "avg_frame_rate" -DefaultValue ""))

  $videoBitrate = $null
  $rawVideoBitrate = Get-ObjectPropertyValue -Object $video -Name "bit_rate" -DefaultValue $null
  if ($null -ne $rawVideoBitrate) {
    $videoBitrate = [int][math]::Round(([double]$rawVideoBitrate) / 1000.0)
  }

  $audioBitrate = $null
  $rawAudioBitrate = if ($audio) { Get-ObjectPropertyValue -Object $audio -Name "bit_rate" -DefaultValue $null } else { $null }
  if ($audio -and $null -ne $rawAudioBitrate) {
    $audioBitrate = [int][math]::Round(([double]$rawAudioBitrate) / 1000.0)
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

  $codedWidth = [int]$video.width
  $codedHeight = [int]$video.height
  $rotation = Get-NormalizedRotation -VideoStream $video
  $displayWidth = if ($rotation -in @(90, 270)) { $codedHeight } else { $codedWidth }
  $displayHeight = if ($rotation -in @(90, 270)) { $codedWidth } else { $codedHeight }
  $sampleAspectRatio = [string](Get-ObjectPropertyValue -Object $video -Name "sample_aspect_ratio" -DefaultValue "1:1")
  $sampleAspectRatioValue = Convert-RationalToDouble -Value $sampleAspectRatio -DefaultValue 1.0
  if ($sampleAspectRatioValue -le 0.0) { $sampleAspectRatioValue = 1.0 }
  $hdr = Get-HdrClassification -VideoStream $video

  [PSCustomObject]@{
    InputBytes       = [long](Get-Item -LiteralPath $path).Length
    FormatName       = [string](Get-ObjectPropertyValue -Object $probe.format -Name "format_name" -DefaultValue "")
    Duration         = [double]::Parse($probe.format.duration, [Globalization.CultureInfo]::InvariantCulture)
    Width            = [int]$displayWidth
    Height           = [int]$displayHeight
    CodedWidth       = [int]$codedWidth
    CodedHeight      = [int]$codedHeight
    Fps              = $srcFps
    VideoCodec       = [string]$video.codec_name
    PixelFormat      = $pixelFormat
    VideoBitDepth    = $videoBitDepth
    ColorRange       = [string](Get-ObjectPropertyValue -Object $video -Name "color_range" -DefaultValue "")
    ColorPrimaries   = [string](Get-ObjectPropertyValue -Object $video -Name "color_primaries" -DefaultValue "")
    ColorTransfer    = [string](Get-ObjectPropertyValue -Object $video -Name "color_transfer" -DefaultValue "")
    ColorSpace       = [string](Get-ObjectPropertyValue -Object $video -Name "color_space" -DefaultValue "")
    ChromaLocation   = [string](Get-ObjectPropertyValue -Object $video -Name "chroma_location" -DefaultValue "")
    SampleAspectRatio = $sampleAspectRatio
    SampleAspectRatioValue = [double]$sampleAspectRatioValue
    DisplayAspectRatio = [string](Get-ObjectPropertyValue -Object $video -Name "display_aspect_ratio" -DefaultValue "")
    Rotation         = [int]$rotation
    HdrClassification = [string]$hdr.Classification
    HasHdrMetadata   = [bool]$hdr.HasHdrMetadata
    HdrReason        = [string]$hdr.Reason
    VideoBitrateKbps = $videoBitrate
    HasAudio         = [bool]$audio
    AudioCodec       = if ($audio) { [string]$audio.codec_name } else { "" }
    AudioBitrateKbps = $audioBitrate
    AudioChannels    = if ($audio -and $null -ne (Get-ObjectPropertyValue -Object $audio -Name "channels" -DefaultValue $null)) { [int](Get-ObjectPropertyValue -Object $audio -Name "channels" -DefaultValue 0) } else { 0 }
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
        CloseEnoughRatio             = 0.970
        EarlyAcceptRatio             = 0.970
        BadUnderfillRatio            = 0.970
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
        MaxFullEncodes               = 3
        MaxSecondStageActions        = 2
        AllowChallenger              = $true
        AllowNeighborFallback        = $true
        AllowPresetExploration       = $false
        NearTieDelta                 = 0.03
        ChallengerConfidenceThreshold = 0.80
        CloseEnoughRatio             = 0.990
        EarlyAcceptRatio             = 0.990
        BadUnderfillRatio            = 0.990
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
        MaxFullEncodes               = 5
        MaxSecondStageActions        = 4
        AllowChallenger              = $true
        AllowNeighborFallback        = $true
        AllowPresetExploration       = $true
        NearTieDelta                 = 0.02
        ChallengerConfidenceThreshold = 0.88
        CloseEnoughRatio             = 0.995
        EarlyAcceptRatio             = 0.995
        BadUnderfillRatio            = 0.995
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

function Get-DisplaySampleAspectRatio {
  param([Parameter(Mandatory = $true)]$Info)

  $sar = [double](Get-ObjectPropertyValue -Object $Info -Name "SampleAspectRatioValue" -DefaultValue 1.0)
  if ($sar -le 0.0) { $sar = 1.0 }
  $rotation = [int](Get-ObjectPropertyValue -Object $Info -Name "Rotation" -DefaultValue 0)
  if ($rotation -in @(90, 270) -and $sar -gt 0.0) {
    return (1.0 / $sar)
  }
  return $sar
}

function Build-GeometryFilterChain {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][double]$TargetFps,
    [string]$ScaleFlags = "lanczos"
  )

  $parts = @()
  $planningWidth = Get-PlanningWidth -Info $Info
  $cropFilter = Get-CropFilterString -Info $Info

  if (-not [string]::IsNullOrWhiteSpace($cropFilter)) {
    $parts += $cropFilter
  }

  # FFmpeg autorotates before user filters. Normalize non-square samples before
  # planning scale so encoded and metric-reference geometry are identical.
  $sar = Get-DisplaySampleAspectRatio -Info $Info
  if ([math]::Abs($sar - 1.0) -gt 0.0001) {
    $sarText = $sar.ToString("0.########", [Globalization.CultureInfo]::InvariantCulture)
    $parts += ("scale=trunc(iw*{0}/2)*2:ih:flags={1}" -f $sarText, $ScaleFlags)
  }
  $parts += "setsar=1"

  if ($TargetFps -gt 0 -and $Info.Fps -gt ($TargetFps + 0.01)) {
    $parts += ("fps={0}" -f $TargetFps)
  }

  if ($TargetWidth -lt $planningWidth) {
    $parts += ("scale={0}:-2:flags={1}" -f $TargetWidth, $ScaleFlags)
  }

  return ($parts -join ",")
}

function Build-EncodeFilterChain {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][double]$TargetFps,
    [AllowEmptyString()][string]$PreprocessProfileName = "",
    [string]$ScaleFlags = "lanczos"
  )

  $parts = @()
  $geometry = Build-GeometryFilterChain -Info $Info -TargetWidth $TargetWidth -TargetFps $TargetFps -ScaleFlags $ScaleFlags
  if (-not [string]::IsNullOrWhiteSpace($geometry)) {
    $parts += $geometry
  }

  $preprocessFilter = Build-PreprocessFilterChain -PreprocessProfileName $PreprocessProfileName
  if (-not [string]::IsNullOrWhiteSpace($preprocessFilter)) {
    $parts += $preprocessFilter
  }

  return ($parts -join ",")
}

function Get-CanonicalMetricProfile {
  param([Parameter(Mandatory = $true)]$Info)

  $sourceWidth = [int](Get-PlanningWidth -Info $Info)
  $sourceHeight = [int](Get-PlanningHeight -Info $Info)
  if ($sourceWidth -lt 2 -or $sourceHeight -lt 2) {
    throw "Cannot build a canonical metric profile for invalid source geometry ${sourceWidth}x${sourceHeight}."
  }

  $scale = [math]::Min(1.0, [math]::Min(1920.0 / [double]$sourceWidth, 1920.0 / [double]$sourceHeight))
  $canvasWidth = [int]([math]::Floor(([double]$sourceWidth * $scale) / 2.0) * 2)
  $canvasHeight = [int]([math]::Floor(([double]$sourceHeight * $scale) / 2.0) * 2)
  $canvasWidth = [int][math]::Max(2, [math]::Min($sourceWidth, $canvasWidth))
  $canvasHeight = [int][math]::Max(2, [math]::Min($sourceHeight, $canvasHeight))

  $sourceFps = [double](Get-ObjectPropertyValue -Object $Info -Name "Fps" -DefaultValue 30.0)
  if ($sourceFps -le 0.0) { $sourceFps = 30.0 }
  $metricFps = [math]::Min(60.0, $sourceFps)
  $sourceBitDepth = [int](Get-ObjectPropertyValue -Object $Info -Name "VideoBitDepth" -DefaultValue 8)
  $metricBitDepth = if ($sourceBitDepth -gt 8) { 10 } else { 8 }

  return [PSCustomObject]@{
    EvaluatorVersion = "canonical-v1"
    Width            = $canvasWidth
    Height           = $canvasHeight
    Fps              = [double]$metricFps
    BitDepth         = $metricBitDepth
    PixelFormat      = if ($metricBitDepth -eq 10) { "yuv420p10le" } else { "yuv420p" }
    SourceWidth      = $sourceWidth
    SourceHeight     = $sourceHeight
  }
}

function Build-MetricReferenceFilterChain {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [int]$TargetWidth = 0,
    [double]$TargetFps = 0,
    [string]$ScaleFlags = "lanczos"
  )

  # TargetWidth and TargetFps remain accepted for call-site compatibility, but
  # metric geometry is derived only from the source so every candidate is
  # evaluated on one common display canvas and timeline.
  $profile = Get-CanonicalMetricProfile -Info $Info
  $parts = @()
  $cropFilter = Get-CropFilterString -Info $Info
  if (-not [string]::IsNullOrWhiteSpace($cropFilter)) {
    $parts += $cropFilter
  }

  $sar = Get-DisplaySampleAspectRatio -Info $Info
  if ([math]::Abs($sar - 1.0) -gt 0.0001) {
    $sarText = $sar.ToString("0.########", [Globalization.CultureInfo]::InvariantCulture)
    $parts += ("scale=trunc(iw*{0}/2)*2:ih:flags={1}" -f $sarText, $ScaleFlags)
  }
  $parts += "setsar=1"

  # Run both sides through an explicit scaler, even at 1:1, so colorspace and
  # chroma-siting behavior are identical between reference and distortion.
  $parts += ("scale={0}:{1}:flags={2}" -f $profile.Width, $profile.Height, $ScaleFlags)
  $fpsText = $profile.Fps.ToString("0.########", [Globalization.CultureInfo]::InvariantCulture)
  $parts += ("fps={0}:round=near" -f $fpsText)
  return ($parts -join ",")
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

  $effectiveProfile = if (-not [string]::IsNullOrWhiteSpace($PreprocessProfileName)) {
    Get-NormalizedOptionValue -Value $PreprocessProfileName -DefaultValue "none"
  }
  elseif ($UseDenoise) {
    "mild-denoise"
  }
  else {
    "none"
  }

  return (Build-EncodeFilterChain -Info $Info -TargetWidth $TargetWidth -TargetFps $TargetFps -PreprocessProfileName $effectiveProfile -ScaleFlags $ScaleFlags)
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

  if ($mode -eq "ExtraQuality") {
    $list.Insert(0, $roundedSrc)
    $nextLowerFps = if ($srcFps -gt 50.0) { 30 } elseif ($srcFps -gt 30.5) { 30 } elseif ($srcFps -gt 24.5) { 24 } elseif ($srcFps -gt 20.5) { 20 } else { 15 }
    if ($nextLowerFps) { $list.Add([int]$nextLowerFps) }
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
  $pixelPlanningWidth = if ($cropApplied) { [int]$CropResult.Width } else { [int]$Info.Width }
  $planningHeight = if ($cropApplied) { [int]$CropResult.Height } else { [int]$Info.Height }
  $displaySar = Get-DisplaySampleAspectRatio -Info $Info
  $planningWidth = [int]([math]::Round(([double]$pixelPlanningWidth * $displaySar) / 2.0) * 2)
  if ($planningWidth -lt 2) { $planningWidth = 2 }
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

function Get-MetadataAverage {
  param(
    [AllowEmptyString()][string]$Text,
    [Parameter(Mandatory = $true)][string]$Key
  )

  $values = New-Object System.Collections.Generic.List[double]
  $pattern = '(?m)^' + [regex]::Escape($Key) + '=(?<value>-?\d+(?:\.\d+)?)\s*$'
  foreach ($match in [regex]::Matches([string]$Text, $pattern)) {
    [void]$values.Add([double]::Parse($match.Groups["value"].Value, [Globalization.CultureInfo]::InvariantCulture))
  }
  if ($values.Count -eq 0) { return $null }
  return [double](($values | Measure-Object -Average).Average)
}

function Invoke-ContentFeatureProbe {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$SampleWindows
  )

  $entropyValues = New-Object System.Collections.Generic.List[double]
  $temporalValues = New-Object System.Collections.Generic.List[double]
  $noiseValues = New-Object System.Collections.Generic.List[double]
  $edgeValues = New-Object System.Collections.Generic.List[double]
  $flatValues = New-Object System.Collections.Generic.List[double]

  foreach ($window in @($SampleWindows | Select-Object -First 2)) {
    $start = [double](Get-ObjectPropertyValue -Object $window -Name "Start" -DefaultValue 0.0)
    $duration = [double][math]::Min(1.5, (Get-ObjectPropertyValue -Object $window -Name "Duration" -DefaultValue 1.5))
    $common = @("-hide_banner", "-loglevel", "error", "-ss", "$start", "-t", "$duration", "-i", $InputPath, "-an")
    $base = Invoke-ToolCapture -Exe "ffmpeg" -Args ($common + @("-vf", "scale=320:-2:flags=area,format=gray,entropy,signalstats=stat=tout,metadata=print:file=-", "-f", "null", "NUL")) -AllowFailure
    if ($base.ExitCode -eq 0) {
      $entropy = Get-MetadataAverage -Text $base.StdOut -Key "lavfi.entropy.normalized_entropy.normal.Y"
      $temporal = Get-MetadataAverage -Text $base.StdOut -Key "lavfi.signalstats.YDIF"
      $noise = Get-MetadataAverage -Text $base.StdOut -Key "lavfi.signalstats.TOUT"
      if ($null -ne $entropy) { [void]$entropyValues.Add([double]$entropy) }
      if ($null -ne $temporal) { [void]$temporalValues.Add([double]$temporal / 255.0) }
      if ($null -ne $noise) { [void]$noiseValues.Add([double]$noise) }
    }

    $edge = Invoke-ToolCapture -Exe "ffmpeg" -Args ($common + @("-filter_complex", "scale=320:-2:flags=area,edgedetect=low=0.08:high=0.20,format=gray,split[edge][flat];[edge]signalstats,metadata=print:file=-[measured];[flat]blackframe=amount=0:threshold=16,metadata=print:file=-[flatness]", "-map", "[measured]", "-map", "[flatness]", "-f", "null", "NUL")) -AllowFailure
    if ($edge.ExitCode -eq 0) {
      $edgeAverage = Get-MetadataAverage -Text $edge.StdOut -Key "lavfi.signalstats.YAVG"
      $flatAverage = Get-MetadataAverage -Text $edge.StdOut -Key "lavfi.blackframe.pblack"
      if ($null -ne $edgeAverage) { [void]$edgeValues.Add([double]$edgeAverage / 255.0) }
      if ($null -ne $flatAverage) { [void]$flatValues.Add([double]$flatAverage / 100.0) }
    }
  }

  return [PSCustomObject]@{
    Entropy = if ($entropyValues.Count -gt 0) { [double](($entropyValues | Measure-Object -Average).Average) } else { $null }
    TemporalDifference = if ($temporalValues.Count -gt 0) { [double](($temporalValues | Measure-Object -Average).Average) } else { $null }
    Noise = if ($noiseValues.Count -gt 0) { [double](($noiseValues | Measure-Object -Average).Average) } else { $null }
    EdgeDensity = if ($edgeValues.Count -gt 0) { [double](($edgeValues | Measure-Object -Average).Average) } else { $null }
    FlatAreaRatio = if ($flatValues.Count -gt 0) { [double](($flatValues | Measure-Object -Average).Average) } else { $null }
  }
}

function Get-ContentClassFeatures {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$SampleWindows,
    [AllowEmptyString()][string]$InputPath = ""
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

  $measured = if (-not [string]::IsNullOrWhiteSpace($InputPath) -and (Test-Path -LiteralPath $InputPath)) {
    Invoke-ContentFeatureProbe -InputPath $InputPath -SampleWindows $SampleWindows
  }
  else { $null }
  $fallbackEdge = [math]::Max(0.0, [math]::Min(1.0, ($peakish - 110.0) / 360.0))
  $fallbackEntropy = [math]::Max(0.0, [math]::Min(1.0, ($avg - 40.0) / 400.0))
  $edgeDensity = if ($measured -and $null -ne $measured.EdgeDensity) { [double]$measured.EdgeDensity } else { $fallbackEdge }
  $entropy = if ($measured -and $null -ne $measured.Entropy) { [double]$measured.Entropy } else { $fallbackEntropy }
  $flatAreaRatio = if ($measured -and $null -ne $measured.FlatAreaRatio) { [double]$measured.FlatAreaRatio } else { [math]::Max(0.0, [math]::Min(1.0, 1.0 - $entropy)) }
  $temporalDifference = if ($measured -and $null -ne $measured.TemporalDifference) { [double]$measured.TemporalDifference } else { [math]::Min(1.0, $motionNormalized / 2.0) }
  $noise = if ($measured -and $null -ne $measured.Noise) { [double]$measured.Noise } else { [math]::Max(0.0, [math]::Min(1.0, ($detailSpread * 2.1) + ($motionSpread * 1.4))) }
  $sourceBpppf = if ($Info.VideoBitrateKbps -and $Info.Width -gt 0 -and $Info.Height -gt 0 -and $Info.Fps -gt 0) { ([double]$Info.VideoBitrateKbps * 1000.0) / ([double]$Info.Width * [double]$Info.Height * [double]$Info.Fps) } else { 0.0 }
  $sourceCompression = if ($sourceBpppf -gt 0.0) { [math]::Max(0.0, [math]::Min(1.0, 1.0 - ($sourceBpppf / 0.12))) } else { 0.5 }
  $uiPersistence = [math]::Max(0.0, [math]::Min(1.0, ((1.0 - [math]::Min(1.0, $temporalDifference * 4.0)) * 0.60) + ($edgeDensity * 0.40)))

  return [PSCustomObject]@{
    MotionNormalized   = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $motionNormalized)), [Globalization.CultureInfo]::InvariantCulture)
    MotionSpread       = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $motionSpread)), [Globalization.CultureInfo]::InvariantCulture)
    DetailSpread       = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $detailSpread)), [Globalization.CultureInfo]::InvariantCulture)
    ClassifierVersion  = "direct-core-v1"
    EdgeDensity        = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $edgeDensity)), [Globalization.CultureInfo]::InvariantCulture)
    Entropy            = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $entropy)), [Globalization.CultureInfo]::InvariantCulture)
    FlatAreaRatio      = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $flatAreaRatio)), [Globalization.CultureInfo]::InvariantCulture)
    TemporalDifference = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $temporalDifference)), [Globalization.CultureInfo]::InvariantCulture)
    Noise              = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $noise)), [Globalization.CultureInfo]::InvariantCulture)
    SourceCompression  = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $sourceCompression)), [Globalization.CultureInfo]::InvariantCulture)
    UiPersistence      = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $uiPersistence)), [Globalization.CultureInfo]::InvariantCulture)
    SceneAverage       = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $sceneAverage)), [Globalization.CultureInfo]::InvariantCulture)
    SourceFps          = [double]$Info.Fps
    SourceBitrateKbps  = [int](Get-ObjectPropertyValue -Object $Info -Name "VideoBitrateKbps" -DefaultValue 0)
  }
}

function Get-ContentClassifierThresholds {
  # Frozen before Holdout evaluation. Values use the direct 320-pixel Core-v1 probe scale.
  return [PSCustomObject]@{
    Version                    = "direct-core-v1"
    CalibrationSet             = "core"
    Frozen                     = $true
    ScreenMaxTemporal          = 0.030
    ScreenMinNoise             = 0.012
    ScreenMinEdge              = 0.025
    ScreenStaticMaxTemporal    = 0.012
    ScreenStaticMinFlatArea    = 0.940
    ScreenStaticMaxEntropy     = 0.650
    NoisyCameraMinNoise        = 0.015
    NoisyCameraMinTemporal     = 0.035
    GameplayMinFps             = 50.0
    GameplayMinEdge            = 0.045
    GameplayMaxFlatArea        = 0.910
    GameplayMinUiPersistence   = 0.45
    AnimeMinFlatArea           = 0.86
    AnimeMinEdge               = 0.025
    AnimeMaxNoise              = 0.012
    TalkingHeadMaxTemporal     = 0.012
    TalkingHeadMaxNoise        = 0.010
  }
}

function Invoke-ContentClassifier {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)]$Features
  )

  $thresholds = Get-ContentClassifierThresholds

  if (
    (
      [double]$Features.TemporalDifference -le $thresholds.ScreenMaxTemporal -and
      [double]$Features.Noise -ge $thresholds.ScreenMinNoise -and
      [double]$Features.EdgeDensity -ge $thresholds.ScreenMinEdge
    ) -or (
      [double]$Features.TemporalDifference -le $thresholds.ScreenStaticMaxTemporal -and
      [double]$Features.FlatAreaRatio -ge $thresholds.ScreenStaticMinFlatArea -and
      [double]$Features.Entropy -le $thresholds.ScreenStaticMaxEntropy
    )
  ) {
    return "screen"
  }

  if (
    [double]$Features.Noise -ge $thresholds.NoisyCameraMinNoise -and
    [double]$Features.TemporalDifference -ge $thresholds.NoisyCameraMinTemporal
  ) {
    return "noisy_camera"
  }

  if (
    [double]$Info.Fps -ge $thresholds.GameplayMinFps -and
    [double]$Features.EdgeDensity -ge $thresholds.GameplayMinEdge -and
    [double]$Features.FlatAreaRatio -le $thresholds.GameplayMaxFlatArea -and
    [double]$Features.UiPersistence -ge $thresholds.GameplayMinUiPersistence
  ) {
    return "gameplay"
  }

  if (
    [double]$Features.FlatAreaRatio -ge $thresholds.AnimeMinFlatArea -and
    [double]$Features.EdgeDensity -ge $thresholds.AnimeMinEdge -and
    [double]$Features.Noise -le $thresholds.AnimeMaxNoise -and
    [double]$Features.MotionSpread -le 0.30
  ) {
    return "anime"
  }

  if (
    [double]$Features.TemporalDifference -le $thresholds.TalkingHeadMaxTemporal -and
    [double]$Features.Noise -le $thresholds.TalkingHeadMaxNoise -and
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
    $contentFeatures = Get-ContentClassFeatures -Info $Info -Probe $probeShell -SampleWindows $sampleWindows -InputPath $InputPath
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

  if ($Mode -eq "ExtraQuality") {
    $sourceWidth = [int]([math]::Floor($planningWidth / 2.0) * 2)
    $widthOrigins[$sourceWidth] = Get-CombinedWidthOrigin -existingOrigin $widthOrigins[$sourceWidth] -newOrigin "source-sentinel"
    $nextLowerWidth = $ladderWidths | Where-Object { $_ -lt $sourceWidth } | Sort-Object -Descending | Select-Object -First 1
    if ($nextLowerWidth) {
      $widthOrigins[[int]$nextLowerWidth] = Get-CombinedWidthOrigin -existingOrigin $widthOrigins[[int]$nextLowerWidth] -newOrigin "lower-sentinel"
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
  $sourceSentinel = $ordered | Where-Object { $_.Origin -match "source-sentinel" } | Select-Object -First 1
  $lowerSentinel = $ordered | Where-Object { $_.Origin -match "lower-sentinel" } | Select-Object -First 1
  $selected = New-Object System.Collections.Generic.List[object]
  $seenWidths = New-Object System.Collections.Generic.HashSet[int]

  foreach ($candidate in @($sourceSentinel, $lowerSentinel, $bestLocal, $bestLadder) + @($ordered | Select-Object -First $topCount)) {
    if ($null -eq $candidate) { continue }
    if ($seenWidths.Add([int]$candidate.Width)) {
      [void]$selected.Add($candidate)
    }
  }

  return @($selected | Sort-Object Width -Descending)
}

function Get-MuxReserveBytes($targetBytes, $mode, [string]$Container = "mp4", [string]$VideoCodec = "x264", [string]$AudioMode = "", [double]$ObservedBias = 1.0) {
  $baseRatio = switch ($mode) {
    "Fast"         { 0.0060 }
    "Balanced"     { 0.0040 }
    "ExtraQuality" { 0.0030 }
  }

  $containerRatio = switch ((Get-NormalizedOptionValue -Value $Container -DefaultValue "mp4")) {
    "webm" { 0.0025 }
    default { 0.0038 }
  }
  $audioRatio = switch ((Get-NormalizedOptionValue -Value $AudioMode -DefaultValue "")) {
    "mute" { 0.0002 }
    default { 0.0007 }
  }

  $biasExtra = [math]::Max(0.0, [double]$ObservedBias - 1.0) * 0.002
  $ratio = [math]::Max($baseRatio, $containerRatio + $audioRatio + $biasExtra)
  return [long][math]::Max(4096, [math]::Floor($targetBytes * $ratio))
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

function Test-EncoderPixelFormatSupported {
  param(
    [Parameter(Mandatory = $true)][string]$Encoder,
    [Parameter(Mandatory = $true)][string]$PixelFormat
  )

  $cacheKey = ("{0}|{1}" -f $Encoder.ToLowerInvariant(), $PixelFormat.ToLowerInvariant())
  if ($script:EncoderPixelFormatSupportCache.ContainsKey($cacheKey)) {
    return [bool]$script:EncoderPixelFormatSupportCache[$cacheKey]
  }

  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args @("-hide_banner", "-h", ("encoder={0}" -f $Encoder)) -AllowFailure
  $formatLine = [regex]::Match($capture.Output, '(?im)^\s*Supported pixel formats:\s*(?<formats>[^\r\n]+)')
  $supported = ($capture.ExitCode -eq 0 -and $formatLine.Success -and (($formatLine.Groups["formats"].Value -split '\s+') -contains $PixelFormat))
  $script:EncoderPixelFormatSupportCache[$cacheKey] = [bool]$supported
  return [bool]$supported
}

function Get-OutputPixelFormat {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)][string]$Compatibility,
    [Parameter(Mandatory = $true)][string]$RequestedBitDepth
  )

  $requested = Get-NormalizedOptionValue -Value $RequestedBitDepth -DefaultValue "auto"
  $codec = [string]$CodecProfile.VideoCodec
  $pixelFormat = "yuv420p"

  if ($requested -eq "10") {
    if ($codec -eq "x264" -and $Compatibility -eq "widest") {
      throw "-OutputBitDepth 10 is incompatible with x264 in -CompatibilityMode widest. Use x265/AV1 or explicitly select a less restrictive compatibility mode."
    }
    $pixelFormat = "yuv420p10le"
  }
  elseif ($requested -eq "auto" -and [int]$Info.VideoBitDepth -gt 8 -and $codec -in @("x265", "av1", "vp9")) {
    $pixelFormat = "yuv420p10le"
  }

  if (-not (Test-EncoderPixelFormatSupported -Encoder $CodecProfile.VideoEncoder -PixelFormat $pixelFormat)) {
    throw "Encoder '$($CodecProfile.VideoEncoder)' does not support the required output pixel format '$pixelFormat' (source=$($Info.PixelFormat), requested bit depth=$RequestedBitDepth)."
  }

  return $pixelFormat
}

function Get-ColorMetadataPolicy {
  param([Parameter(Mandatory = $true)]$Info)

  Assert-SdrInputSupported -Info $Info
  $args = New-Object System.Collections.Generic.List[string]
  $preserved = New-Object System.Collections.Generic.List[string]
  $omitted = New-Object System.Collections.Generic.List[string]

  $values = @(
    @{ Name = "range"; Value = ([string]$Info.ColorRange).ToLowerInvariant(); Option = "-color_range"; Valid = @("tv", "pc") },
    @{ Name = "primaries"; Value = ([string]$Info.ColorPrimaries).ToLowerInvariant(); Option = "-color_primaries"; Valid = @("bt709", "bt470m", "bt470bg", "smpte170m", "smpte240m", "film", "bt2020", "smpte428", "smpte431", "smpte432", "jedec-p22") },
    @{ Name = "transfer"; Value = ([string]$Info.ColorTransfer).ToLowerInvariant(); Option = "-color_trc"; Valid = @("bt709", "gamma22", "gamma28", "smpte170m", "smpte240m", "linear", "log", "log_sqrt", "iec61966-2-1", "bt2020-10", "bt2020-12") },
    @{ Name = "matrix"; Value = ([string]$Info.ColorSpace).ToLowerInvariant(); Option = "-colorspace"; Valid = @("rgb", "bt709", "fcc", "bt470bg", "smpte170m", "smpte240m", "ycgco", "bt2020nc", "bt2020c") },
    @{ Name = "chroma_location"; Value = ([string]$Info.ChromaLocation).ToLowerInvariant(); Option = "-chroma_sample_location"; Valid = @("left", "center", "topleft", "top", "bottomleft", "bottom") }
  )

  foreach ($entry in $values) {
    if ([string]::IsNullOrWhiteSpace($entry.Value) -or $entry.Value -in @("unknown", "unspecified", "reserved")) {
      [void]$omitted.Add(("{0}=unspecified" -f $entry.Name))
      continue
    }
    if ($entry.Value -notin $entry.Valid) {
      [void]$omitted.Add(("{0}={1} (unsupported)" -f $entry.Name, $entry.Value))
      continue
    }
    [void]$args.Add([string]$entry.Option)
    [void]$args.Add([string]$entry.Value)
    [void]$preserved.Add(("{0}={1}" -f $entry.Name, $entry.Value))
  }

  return [PSCustomObject]@{
    Args      = @($args.ToArray())
    Preserved = @($preserved.ToArray())
    Omitted   = @($omitted.ToArray())
    Status    = if ($omitted.Count -eq 0) { "preserved" } elseif ($preserved.Count -gt 0) { "partial" } else { "unspecified" }
  }
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

  $geometryVf = Build-GeometryFilterChain -Info $Info -TargetWidth $Width -TargetFps $Fps
  $preprocessVf = Build-PreprocessFilterChain -PreprocessProfileName $preprocessLabel
  $encodeVf = Build-EncodeFilterChain -Info $Info -TargetWidth $Width -TargetFps $Fps -PreprocessProfileName $preprocessLabel
  $metricReferenceVf = Build-MetricReferenceFilterChain -Info $Info -TargetWidth $Width -TargetFps $Fps
  $metricProfile = Get-CanonicalMetricProfile -Info $Info
  $outputPixelFormat = Get-OutputPixelFormat -Info $Info -CodecProfile $CodecProfile -Compatibility $CompatibilityMode -RequestedBitDepth $OutputBitDepth
  $colorPolicy = Get-ColorMetadataPolicy -Info $Info
  $hardCapBytes = if ($null -ne $script:RequestedHardCapBytes) { [long]$script:RequestedHardCapBytes } else { [long]$TargetBytes }
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
    VFilter     = $encodeVf
    GeometryVFilter = $geometryVf
    PreprocessVFilter = $preprocessVf
    EncodeVFilter = $encodeVf
    MetricReferenceVFilter = $metricReferenceVf
    EvaluatorVersion = [string]$metricProfile.EvaluatorVersion
    MetricCanvasWidth = [int]$metricProfile.Width
    MetricCanvasHeight = [int]$metricProfile.Height
    MetricFps = [double]$metricProfile.Fps
    MetricPixelFormat = [string]$metricProfile.PixelFormat
    MetricBitDepth = [int]$metricProfile.BitDepth
    VideoKbps   = $videoKbps
    EffectiveVideoKbps = $effectiveVideoKbps
    Crf         = $crf
    AudioPlan   = $AudioPlan
    AudioCodec  = [string](Get-ObjectPropertyValue -Object $AudioPlan -Name "Codec" -DefaultValue $CodecProfile.DefaultAudioCodec)
    TargetBytes = $TargetBytes
    WorkingTargetBytes = $TargetBytes
    HardCapBytes = $hardCapBytes
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
    PredictedFillRatio  = ([double]$TargetBytes / [double]$hardCapBytes)
    ReserveBytes = [long]$muxReserve
    AudioPayloadBytes = [long](Get-ObjectPropertyValue -Object $AudioPlan -Name "EstimatedBytes" -DefaultValue 0)
    VideoPayloadBytes = 0L
    MuxOverheadBytes = 0L
    CorrectionHistory = @()
    ResolutionBiasLabel = $resolutionProfile.BiasLabel
    PreprocessLabel = $preprocessLabel
    UseDenoise = [bool]$UseDenoise
    CropApplied = [bool](Get-ObjectPropertyValue -Object $Info -Name "CropApplied" -DefaultValue $false)
    CropSummary = Get-CropSummary -Info $Info
    VideoPrivateArgs = $videoPrivateArgs
    OutputPixelFormat = $outputPixelFormat
    OutputBitDepth = if ($outputPixelFormat -eq "yuv420p10le") { 10 } else { 8 }
    SourcePixelFormat = [string]$Info.PixelFormat
    SourceBitDepth = [int]$Info.VideoBitDepth
    SourceColorRange = [string]$Info.ColorRange
    SourceColorPrimaries = [string]$Info.ColorPrimaries
    SourceColorTransfer = [string]$Info.ColorTransfer
    SourceColorSpace = [string]$Info.ColorSpace
    SourceChromaLocation = [string]$Info.ChromaLocation
    SourceSampleAspectRatio = [string]$Info.SampleAspectRatio
    SourceDisplayAspectRatio = [string]$Info.DisplayAspectRatio
    SourceRotation = [int]$Info.Rotation
    HdrClassification = [string]$Info.HdrClassification
    ColorMetadataArgs = @($colorPolicy.Args)
    ColorMetadataStatus = [string]$colorPolicy.Status
    ColorMetadataPreserved = @($colorPolicy.Preserved)
    ColorMetadataOmitted = @($colorPolicy.Omitted)
    VbvMode = $VbvMode
    VbvPeakMultiplier = if ($VbvMode -eq "Streaming" -and $CodecProfile.VideoCodec -ne "av1") { 1.5 } else { $null }
    VbvBufferSeconds = if ($VbvMode -eq "Streaming" -and $CodecProfile.VideoCodec -ne "av1") { 2.0 } else { $null }
    MaxrateKbps = if ($VbvMode -eq "Streaming" -and $CodecProfile.VideoCodec -ne "av1") { [int][math]::Ceiling($videoKbps * 1.5) } else { $null }
    BufsizeKbits = if ($VbvMode -eq "Streaming" -and $CodecProfile.VideoCodec -ne "av1") { [int][math]::Ceiling($videoKbps * 1.5 * 2.0) } else { $null }
    ContentClass = [string](Get-ObjectPropertyValue -Object $Probe -Name "ContentClass" -DefaultValue "general")
    MetricModeUsed = if ($PolicyProfile) { [string](Get-ObjectPropertyValue -Object $PolicyProfile -Name "MetricModeUsed" -DefaultValue "off") } else { "off" }
    PrimaryMetricMode = "off"
    MetricScore = $null
    WorstMetricScore = $null
    MetricConfidence = 0.0
    VmafNegScore = $null
    WorstVmafNegScore = $null
    StandardVmafScore = $null
    XpsnrScore = $null
    WorstXpsnrScore = $null
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

function Get-StreamPayloadBytes {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateSet("v:0", "a:0")][string]$Stream
  )

  $capture = Invoke-ToolCapture -Exe "ffprobe" -Args @(
    "-v", "error", "-select_streams", $Stream,
    "-show_entries", "packet=size", "-of", "csv=p=0", $Path
  ) -AllowFailure
  if ($capture.ExitCode -ne 0) { return 0L }

  [long]$total = 0
  foreach ($line in ($capture.StdOut -split "`r?`n")) {
    $valueText = $line.Trim().TrimEnd(',')
    [long]$value = 0
    if ([long]::TryParse($valueText, [ref]$value) -and $value -gt 0) {
      $total += $value
    }
  }
  return $total
}

function Get-CachedAudioEntry {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  $identity = Get-AudioPlanIdentity -AudioPlan $Plan.AudioPlan
  if ($script:AudioCache.ContainsKey($identity)) {
    return $script:AudioCache[$identity]
  }

  if ($Plan.AudioPlan.Mode -eq "mute") {
    $entry = [PSCustomObject]@{
      Identity = $identity; Path = $null; PayloadBytes = 0L; FileBytes = 0L
      Mode = "mute"; Kbps = 0; EncodeCount = 0
    }
    $script:AudioCache[$identity] = $entry
    return $entry
  }

  $extension = if ($Plan.AudioPlan.Mode -eq "opus") { ".opus" } else { ".m4a" }
  $audioPath = Join-Path $TempDir ("audio_{0}{1}" -f ([guid]::NewGuid().ToString("N")), $extension)
  $args = @("-y", "-i", $InputPath, "-map", "0:a:0", "-vn")
  switch ($Plan.AudioPlan.Mode) {
    "copy" { $args += @("-c:a", "copy") }
    "aac"  { $args += @("-c:a", "aac", "-b:a", ("{0}k" -f $Plan.AudioPlan.Kbps)) }
    "opus" { $args += @("-c:a", $Plan.CodecProfile.DefaultAudioEncoder, "-b:a", ("{0}k" -f $Plan.AudioPlan.Kbps)) }
    default { throw "Unknown audio mode: $($Plan.AudioPlan.Mode)" }
  }
  $args += $audioPath
  [void](Invoke-Tool -Exe "ffmpeg" -Args $args)

  $payloadBytes = Get-StreamPayloadBytes -Path $audioPath -Stream "a:0"
  if ($payloadBytes -le 0) {
    $payloadBytes = [long](Get-Item -LiteralPath $audioPath).Length
  }
  $entry = [PSCustomObject]@{
    Identity = $identity
    Path = $audioPath
    PayloadBytes = [long]$payloadBytes
    FileBytes = [long](Get-Item -LiteralPath $audioPath).Length
    Mode = [string]$Plan.AudioPlan.Mode
    Kbps = [int](Get-ObjectPropertyValue -Object $Plan.AudioPlan -Name "Kbps" -DefaultValue 0)
    EncodeCount = 1
  }
  $script:AudioCache[$identity] = $entry
  Write-PlanLogRecord -RecordType "audio_cache" -Data $entry
  return $entry
}

function Apply-ActualAudioBudgetToPlan {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$AudioEntry
  )

  if ([bool](Get-ObjectPropertyValue -Object $Plan -Name "AudioBudgetActual" -DefaultValue $false)) {
    return $Plan
  }

  $planCopy = $Plan.PSObject.Copy()
  $estimatedAudioBytes = [long](Get-ObjectPropertyValue -Object $Plan.AudioPlan -Name "EstimatedBytes" -DefaultValue 0)
  $actualAudioBytes = [long]$AudioEntry.PayloadBytes
  $duration = [double](Get-ObjectPropertyValue -Object $Plan -Name "DurationSeconds" -DefaultValue 0.0)
  if ($duration -gt 0.0) {
    $bitrateDelta = (($estimatedAudioBytes - $actualAudioBytes) * 8.0 / $duration) / 1000.0
    $planCopy.VideoKbps = [int][math]::Max(35, [math]::Floor([double]$Plan.VideoKbps + $bitrateDelta))
  }

  $audioPlanCopy = $Plan.AudioPlan.PSObject.Copy()
  $audioPlanCopy.EstimatedBytes = $actualAudioBytes
  $planCopy.AudioPlan = $audioPlanCopy
  $planCopy | Add-Member -NotePropertyName AudioBudgetActual -NotePropertyValue $true -Force
  $planCopy | Add-Member -NotePropertyName AudioPayloadBytes -NotePropertyValue $actualAudioBytes -Force
  $planCopy | Add-Member -NotePropertyName AudioIdentity -NotePropertyValue ([string]$AudioEntry.Identity) -Force
  return $planCopy
}

function Get-CodecPresetArgs {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [ValidateSet("FinalEncode", "SizeEstimate", "QualityMetric")]
    [string]$Purpose = "FinalEncode"
  )

  $useSpeedOverride = ($Purpose -eq "SizeEstimate")
  switch ($Plan.CodecProfile.PresetKind) {
    "svtav1" {
      $presetValue = if ($useSpeedOverride) {
        [int]$Plan.CodecProfile.PreviewSpeedOverride.Value
      }
      else {
        Get-SvtAv1PresetForPreset -Preset $Plan.Preset
      }

      return @("-preset", "$presetValue")
    }

    "aom" {
      $speed = if ($useSpeedOverride) { [int]$Plan.CodecProfile.PreviewSpeedOverride.Value } else { Get-ExperimentalSpeedForPreset -Preset $Plan.Preset -Backend "aom" }
      return @("-cpu-used", "$speed")
    }

    "vpx" {
      $speed = if ($useSpeedOverride) { [int]$Plan.CodecProfile.PreviewSpeedOverride.Value } else { Get-ExperimentalSpeedForPreset -Preset $Plan.Preset -Backend "vpx" }
      return @("-deadline", "good", "-cpu-used", "$speed")
    }

    "rav1e" {
      $speed = if ($useSpeedOverride) { [int]$Plan.CodecProfile.PreviewSpeedOverride.Value } else { Get-ExperimentalSpeedForPreset -Preset $Plan.Preset -Backend "rav1e" }
      return @("-speed", "$speed")
    }

    default {
      $presetValue = if ($useSpeedOverride) { [string]$Plan.CodecProfile.PreviewSpeedOverride.Value } else { [string]$Plan.Preset }
      return @("-preset", $presetValue)
    }
  }
}

function Get-VbvPolicy {
  param([Parameter(Mandatory = $true)]$Plan)

  $mode = [string](Get-ObjectPropertyValue -Object $Plan -Name "VbvMode" -DefaultValue "Off")
  if ($Plan.CodecProfile.VideoCodec -eq "av1" -or $mode -eq "Off") {
    return [PSCustomObject]@{
      Mode = $mode
      Args = @()
      MaxrateKbps = $null
      BufsizeKbits = $null
      PeakMultiplier = $null
      BufferSeconds = $null
    }
  }

  $peakMultiplier = 1.5
  $bufferSeconds = 2.0
  $maxrateKbps = [int][math]::Ceiling([double]$Plan.VideoKbps * $peakMultiplier)
  $bufsizeKbits = [int][math]::Ceiling([double]$maxrateKbps * $bufferSeconds)
  return [PSCustomObject]@{
    Mode = "Streaming"
    Args = @("-maxrate", ("{0}k" -f $maxrateKbps), "-bufsize", ("{0}k" -f $bufsizeKbits))
    MaxrateKbps = $maxrateKbps
    BufsizeKbits = $bufsizeKbits
    PeakMultiplier = $peakMultiplier
    BufferSeconds = $bufferSeconds
  }
}

function Get-CommonVideoEncodeArgs {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [ValidateSet("FinalEncode", "SizeEstimate", "QualityMetric")]
    [string]$Purpose = "FinalEncode"
  )

  $args = @()

  $encodeFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
  if (-not [string]::IsNullOrWhiteSpace($encodeFilter)) {
    $args += @("-vf", $encodeFilter)
  }

  $args += @("-c:v", $Plan.CodecProfile.VideoEncoder)
  $args += Get-CodecPresetArgs -Plan $Plan -Purpose $Purpose
  $args += @("-pix_fmt", ([string](Get-ObjectPropertyValue -Object $Plan -Name "OutputPixelFormat" -DefaultValue "yuv420p")))
  $args += @((Get-ObjectPropertyValue -Object $Plan -Name "ColorMetadataArgs" -DefaultValue @()))

  $videoRate = ("{0}k" -f $Plan.VideoKbps)
  $args += @("-b:v", $videoRate)
  $vbvPolicy = Get-VbvPolicy -Plan $Plan
  $args += @($vbvPolicy.Args)

  if ($Plan.CodecProfile.VideoCodec -eq "x264" -and -not [string]::IsNullOrWhiteSpace($Plan.VideoPrivateArgs)) {
    $args += @("-x264-params", $Plan.VideoPrivateArgs)
  }
  $args += @((Get-ObjectPropertyValue -Object $Plan.CodecProfile -Name "PrivateEncoderArgs" -DefaultValue @()))

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

  $outputDirectory = Split-Path $OutputPath -Parent
  if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
  }
  [System.IO.File]::Copy((Resolve-Path -LiteralPath $InputPath).Path, [System.IO.Path]::GetFullPath($OutputPath), $true)
  return (Get-Item -LiteralPath $OutputPath).Length
}

function Assert-FinalOutputWithinCap {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][long]$HardCapBytes
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Final output is missing: $Path"
  }
  $size = [long](Get-Item -LiteralPath $Path).Length
  if ($size -gt $HardCapBytes) {
    throw "Final muxed output is $size bytes, exceeding the requested hard cap of $HardCapBytes bytes."
  }
  return $size
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
  $audioEntry = Get-CachedAudioEntry -InputPath $InputPath -Plan $Plan -TempDir $TempDir
  $videoPath = Join-Path $TempDir ("video_{0}.mkv" -f ([guid]::NewGuid().ToString("N")))

  try {
    if ($TwoPass) {
      if ($ownsPassLog) {
        Invoke-EncodePassOne -InputPath $InputPath -Plan $Plan -PassLogPath $passlog
      }

      $pass2 = @("-y", "-i", $InputPath) + $commonVideo + @("-pass", "2", "-passlogfile", $passlog, "-an", $videoPath)
      [void](Invoke-Tool -Exe "ffmpeg" -Args $pass2)
    }
    else {
      $args = @("-y", "-i", $InputPath) + $commonVideo + @("-an", $videoPath)
      [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
    }

    $videoPayloadBytes = Get-StreamPayloadBytes -Path $videoPath -Stream "v:0"
    if ($videoPayloadBytes -le 0) {
      $videoPayloadBytes = [long](Get-Item -LiteralPath $videoPath).Length
    }

    $muxArgs = @("-y", "-i", $videoPath)
    if ($audioEntry.Path) {
      $muxArgs += @("-i", [string]$audioEntry.Path, "-map", "0:v:0", "-map", "1:a:0")
    }
    else {
      $muxArgs += @("-map", "0:v:0")
    }
    $muxArgs += @($Plan.CodecProfile.FinalizeArgs)
    $muxArgs += $OutputPath
    [void](Invoke-Tool -Exe "ffmpeg" -Args $muxArgs)

    $size = [long](Get-Item -LiteralPath $OutputPath).Length
    $audioPayloadBytes = [long]$audioEntry.PayloadBytes
    $muxOverheadBytes = [long][math]::Max(0, $size - $videoPayloadBytes - $audioPayloadBytes)
    return [PSCustomObject]@{
      SizeBytes = $size
      VideoPayloadBytes = [long]$videoPayloadBytes
      AudioPayloadBytes = $audioPayloadBytes
      MuxOverheadBytes = $muxOverheadBytes
      AudioIdentity = [string]$audioEntry.Identity
    }
  }
  finally {
    Remove-Item -LiteralPath $videoPath -Force -ErrorAction SilentlyContinue
    if ($ownsPassLog) {
      Remove-PassLogFiles -PassLogPath $passlog
    }
  }
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
    "ensemble" { return [int][math]::Round($metricScore * 10.0) }
    "xpsnr" { return [int][math]::Round($metricScore * 20.0) }
    default { return 0 }
  }
}

function Test-VmafNegModelAvailable {
  if ($null -ne $script:VmafNegModelAvailable) {
    return [bool]$script:VmafNegModelAvailable
  }

  if (-not (Test-FFmpegFilterAvailable -Filter "libvmaf")) {
    $script:VmafNegModelAvailable = $false
    return $false
  }

  $lavfi = "[0:v][1:v]libvmaf=model=version=vmaf_v0.6.1neg:n_threads=1:n_subsample=1"
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args @(
    "-hide_banner", "-f", "lavfi", "-i", "color=size=16x16:duration=0.05",
    "-f", "lavfi", "-i", "color=size=16x16:duration=0.05",
    "-lavfi", $lavfi, "-an", "-f", "null", "NUL"
  ) -AllowFailure
  $script:VmafNegModelAvailable = ($capture.ExitCode -eq 0)
  return [bool]$script:VmafNegModelAvailable
}

function Get-MetricReferenceFilter {
  param([Parameter(Mandatory = $true)]$Plan)

  $geometry = [string](Get-ObjectPropertyValue -Object $Plan -Name "MetricReferenceVFilter" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "GeometryVFilter" -DefaultValue ""))
  $pixelFormat = [string](Get-ObjectPropertyValue -Object $Plan -Name "MetricPixelFormat" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "OutputPixelFormat" -DefaultValue "yuv420p"))
  $parts = @()
  if (-not [string]::IsNullOrWhiteSpace($geometry)) { $parts += $geometry }
  $parts += ("format={0}" -f $pixelFormat)
  $parts += "settb=AVTB"
  $parts += "setpts=PTS-STARTPTS"
  return ($parts -join ",")
}

function Get-MetricDistortedFilter {
  param([Parameter(Mandatory = $true)]$Plan)

  $pixelFormat = [string](Get-ObjectPropertyValue -Object $Plan -Name "MetricPixelFormat" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "OutputPixelFormat" -DefaultValue "yuv420p"))
  $canvasWidth = [int](Get-ObjectPropertyValue -Object $Plan -Name "MetricCanvasWidth" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "Width" -DefaultValue 0))
  $canvasHeight = [int](Get-ObjectPropertyValue -Object $Plan -Name "MetricCanvasHeight" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "Height" -DefaultValue 0))
  $metricFps = [double](Get-ObjectPropertyValue -Object $Plan -Name "MetricFps" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "Fps" -DefaultValue 30.0))
  $parts = @("setsar=1")
  if ($canvasWidth -gt 0 -and $canvasHeight -gt 0) {
    $parts += ("scale={0}:{1}:flags=lanczos" -f $canvasWidth, $canvasHeight)
  }
  if ($metricFps -gt 0.0) {
    $fpsText = $metricFps.ToString("0.########", [Globalization.CultureInfo]::InvariantCulture)
    $parts += ("fps={0}:round=near" -f $fpsText)
  }
  $parts += ("format={0}" -f $pixelFormat)
  $parts += "settb=AVTB"
  $parts += "setpts=PTS-STARTPTS"
  return ($parts -join ",")
}

function Get-DistortedMetricInputArgs {
  param(
    [Parameter(Mandatory = $true)][string]$PreviewPath,
    [Parameter(Mandatory = $true)]$Window,
    [double]$DistortedOffset = 0.0
  )

  if ($DistortedOffset -gt 0.0001) {
    return @("-ss", "$DistortedOffset", "-t", "$($Window.Duration)", "-i", $PreviewPath)
  }
  return @("-t", "$($Window.Duration)", "-i", $PreviewPath)
}

function Invoke-VmafMetric {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$PreviewPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Window,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [double]$DistortedOffset = 0.0
  )

  $logName = ("vmaf_{0}.json" -f ([guid]::NewGuid().ToString("N")))
  $refFilter = Get-MetricReferenceFilter -Plan $Plan
  $distortedFilter = Get-MetricDistortedFilter -Plan $Plan
  if (-not (Test-VmafNegModelAvailable)) {
    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "vmaf"
        Reason = "vmaf-neg-unavailable"
        Window = $Window
        PreviewPath = $PreviewPath
        ReferenceFilter = $refFilter
        EncodeFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
      })
    return $null
  }
  # NEG is the primary encoder-comparison model. The standard model is emitted
  # alongside it as supplemental evidence from the exact same decoded frames.
  $modelOption = ":model='version=vmaf_v0.6.1neg\:name=vmaf_neg|version=vmaf_v0.6.1\:name=vmaf_standard'"
  $threadCount = if ($Plan.Mode -eq "ExtraQuality") { 4 } else { 2 }
  $subsample = if ($Plan.Mode -eq "ExtraQuality") { 1 } else { 2 }
  $lavfi = "[1:v]{0}[main];[0:v]{1}[ref];[main][ref]libvmaf=log_fmt=json:log_path={2}:n_threads={3}:n_subsample={4}{5}" -f $distortedFilter, $refFilter, $logName, $threadCount, $subsample, $modelOption
  $inputArgs = @("-hide_banner", "-ss", "$($Window.Start)", "-t", "$($Window.Duration)", "-i", $InputPath)
  $inputArgs += Get-DistortedMetricInputArgs -PreviewPath $PreviewPath -Window $Window -DistortedOffset $DistortedOffset
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args ($inputArgs + @("-lavfi", $lavfi, "-an", "-f", "null", "NUL")) -WorkingDirectory $TempDir -AllowFailure
  if ($capture.ExitCode -ne 0) {
    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "vmaf"
        ExitCode   = [int]$capture.ExitCode
        Output     = $capture.Output
        Window     = $Window
        PreviewPath = $PreviewPath
        ReferenceFilter = $refFilter
        DistortedFilter = $distortedFilter
        EncodeFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
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
        ReferenceFilter = $refFilter
        DistortedFilter = $distortedFilter
        EncodeFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
      })
    return $null
  }

  try {
    $json = Get-Content -Path $logPath -Raw | ConvertFrom-Json
    $pooled = Get-ObjectPropertyValue -Object $json -Name "pooled_metrics" -DefaultValue $null
    $negMetric = Get-ObjectPropertyValue -Object $pooled -Name "vmaf_neg" -DefaultValue (Get-ObjectPropertyValue -Object $pooled -Name "vmaf" -DefaultValue $null)
    $standardMetric = Get-ObjectPropertyValue -Object $pooled -Name "vmaf_standard" -DefaultValue $null
    $scoreValue = Get-ObjectPropertyValue -Object $negMetric -Name "mean" -DefaultValue $null
    if ($null -eq $scoreValue) {
      Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
          MetricMode = "vmaf"
          Reason = "missing-vmaf-neg-score"
          Window = $Window
          PreviewPath = $PreviewPath
        })
      return $null
    }
    $score = [double]$scoreValue
    $standardScore = Get-ObjectPropertyValue -Object $standardMetric -Name "mean" -DefaultValue $null
    return [PSCustomObject]@{
      Mode              = "vmaf"
      Score             = [double]$score
      VmafNegScore      = [double]$score
      StandardVmafScore = if ($null -ne $standardScore) { [double]$standardScore } else { $null }
      Model             = "vmaf_v0.6.1neg"
      SupplementalModel = "vmaf_v0.6.1"
      Window            = $Window
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
    [Parameter(Mandatory = $true)][string]$TempDir,
    [double]$DistortedOffset = 0.0
  )

  $statsName = ("xpsnr_{0}.log" -f ([guid]::NewGuid().ToString("N")))
  $refFilter = Get-MetricReferenceFilter -Plan $Plan
  $distortedFilter = Get-MetricDistortedFilter -Plan $Plan
  $lavfi = "[0:v]{0}[ref];[1:v]{1}[test];[ref][test]xpsnr=stats_file={2}" -f $refFilter, $distortedFilter, $statsName
  $inputArgs = @("-hide_banner", "-ss", "$($Window.Start)", "-t", "$($Window.Duration)", "-i", $InputPath)
  $inputArgs += Get-DistortedMetricInputArgs -PreviewPath $PreviewPath -Window $Window -DistortedOffset $DistortedOffset
  $capture = Invoke-ToolCapture -Exe "ffmpeg" -Args ($inputArgs + @("-lavfi", $lavfi, "-an", "-f", "null", "NUL")) -WorkingDirectory $TempDir -AllowFailure
  if ($capture.ExitCode -ne 0) {
    Write-PlanLogRecord -RecordType "metric_failure" -Data ([PSCustomObject]@{
        MetricMode = "xpsnr"
        ExitCode   = [int]$capture.ExitCode
        Output     = $capture.Output
        Window     = $Window
        PreviewPath = $PreviewPath
        ReferenceFilter = $refFilter
        DistortedFilter = $distortedFilter
        EncodeFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
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
        ReferenceFilter = $refFilter
        DistortedFilter = $distortedFilter
        EncodeFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
      })
    return $null
  }

  try {
    $frameScores = New-Object System.Collections.Generic.List[double]
    foreach ($line in (Get-Content -Path $statsPath)) {
      $matches = [regex]::Matches($line, '(?i)(?:^|\s)(?:xpsnr[_\s]+)?(?<plane>[yuv]|average|min)\s*[:=]\s*(?<value>-?\d+(?:\.\d+)?)')
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
        WorstFrameScore = [double](($frameScores | Measure-Object -Minimum).Minimum)
        Window = $Window
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
          WorstFrameScore = [double]$score
          Window = $Window
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
        ReferenceFilter = $refFilter
        DistortedFilter = $distortedFilter
        EncodeFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
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
      WorstMetricScore = $null
      MetricConfidence = 0.0
      SegmentScores = @()
    }
  }

  $scores = New-Object System.Collections.Generic.List[object]
  foreach ($segment in @($PreviewSegments)) {
    if (-not (Test-Path $segment.Path)) { continue }
    $distortedOffset = [double](Get-ObjectPropertyValue -Object $segment -Name "DistortedOffset" -DefaultValue 0.0)
    $vmafResult = if ($metricMode -in @("vmaf", "ensemble")) {
      Invoke-VmafMetric -InputPath $InputPath -PreviewPath $segment.Path -Plan $Plan -Window $segment.Window -TempDir $TempDir -DistortedOffset $distortedOffset
    }
    else { $null }
    $xpsnrResult = if ($metricMode -in @("xpsnr", "ensemble")) {
      Invoke-XpsnrMetric -InputPath $InputPath -PreviewPath $segment.Path -Plan $Plan -Window $segment.Window -TempDir $TempDir -DistortedOffset $distortedOffset
    }
    else { $null }

    if ($vmafResult -or $xpsnrResult) {
      [void]$scores.Add([PSCustomObject]@{
          Mode = $metricMode
          Score = if ($vmafResult) { [double]$vmafResult.Score } else { [double]$xpsnrResult.Score }
          PrimaryMetricMode = if ($vmafResult) { "vmaf" } else { "xpsnr" }
          VmafNegScore = if ($vmafResult) { [double]$vmafResult.VmafNegScore } else { $null }
          StandardVmafScore = if ($vmafResult) { Get-ObjectPropertyValue -Object $vmafResult -Name "StandardVmafScore" -DefaultValue $null } else { $null }
          XpsnrScore = if ($xpsnrResult) { [double]$xpsnrResult.Score } else { $null }
          XpsnrWorstFrameScore = if ($xpsnrResult) { Get-ObjectPropertyValue -Object $xpsnrResult -Name "WorstFrameScore" -DefaultValue $null } else { $null }
          Window = $segment.Window
        })
    }
  }

  if ($scores.Count -eq 0) {
    return [PSCustomObject]@{
      MetricModeUsed = [string]$metricMode
      MetricScore = $null
      WorstMetricScore = $null
      MetricConfidence = 0.0
      SegmentScores = @()
    }
  }

  $vmafScores = @($scores | Where-Object { $null -ne $_.VmafNegScore })
  $xpsnrScores = @($scores | Where-Object { $null -ne $_.XpsnrScore })
  if ($vmafScores.Count -gt 0) {
    $primaryScores = @($vmafScores)
  }
  else {
    $primaryScores = @($xpsnrScores)
  }
  $primaryMode = if ($vmafScores.Count -gt 0) { "vmaf" } else { "xpsnr" }
  $score = [double](($primaryScores | Measure-Object -Property Score -Average).Average)
  $confidence = if ($primaryScores.Count -ge 3) { 0.95 } elseif ($primaryScores.Count -eq 2) { 0.88 } else { 0.75 }
  return [PSCustomObject]@{
    MetricModeUsed   = [string]$metricMode
    PrimaryMetricMode = $primaryMode
    MetricScore      = [double]$score
    WorstMetricScore = [double](($primaryScores | Measure-Object -Property Score -Minimum).Minimum)
    MetricConfidence = [double]$confidence
    VmafNegScore = if ($vmafScores.Count -gt 0) { [double](($vmafScores | Measure-Object -Property VmafNegScore -Average).Average) } else { $null }
    WorstVmafNegScore = if ($vmafScores.Count -gt 0) { [double](($vmafScores | Measure-Object -Property VmafNegScore -Minimum).Minimum) } else { $null }
    StandardVmafScore = if (@($vmafScores | Where-Object { $null -ne $_.StandardVmafScore }).Count -gt 0) { [double](($vmafScores | Where-Object { $null -ne $_.StandardVmafScore } | Measure-Object -Property StandardVmafScore -Average).Average) } else { $null }
    XpsnrScore = if ($xpsnrScores.Count -gt 0) { [double](($xpsnrScores | Measure-Object -Property XpsnrScore -Average).Average) } else { $null }
    WorstXpsnrScore = if ($xpsnrScores.Count -gt 0) { [double](($xpsnrScores | Measure-Object -Property XpsnrScore -Minimum).Minimum) } else { $null }
    SegmentScores    = @($scores.ToArray())
  }
}

function Get-MetricScoreBundle {
  param(
    [Parameter(Mandatory = $true)]$MetricResult
  )

  return [PSCustomObject]@{
    MetricModeUsed   = [string](Get-ObjectPropertyValue -Object $MetricResult -Name "MetricModeUsed" -DefaultValue "off")
    PrimaryMetricMode = [string](Get-ObjectPropertyValue -Object $MetricResult -Name "PrimaryMetricMode" -DefaultValue (Get-ObjectPropertyValue -Object $MetricResult -Name "MetricModeUsed" -DefaultValue "off"))
    MetricScore      = (Get-ObjectPropertyValue -Object $MetricResult -Name "MetricScore" -DefaultValue $null)
    WorstMetricScore = (Get-ObjectPropertyValue -Object $MetricResult -Name "WorstMetricScore" -DefaultValue $null)
    MetricConfidence = [double](Get-ObjectPropertyValue -Object $MetricResult -Name "MetricConfidence" -DefaultValue 0.0)
    VmafNegScore     = (Get-ObjectPropertyValue -Object $MetricResult -Name "VmafNegScore" -DefaultValue $null)
    WorstVmafNegScore = (Get-ObjectPropertyValue -Object $MetricResult -Name "WorstVmafNegScore" -DefaultValue $null)
    StandardVmafScore = (Get-ObjectPropertyValue -Object $MetricResult -Name "StandardVmafScore" -DefaultValue $null)
    XpsnrScore       = (Get-ObjectPropertyValue -Object $MetricResult -Name "XpsnrScore" -DefaultValue $null)
    WorstXpsnrScore  = (Get-ObjectPropertyValue -Object $MetricResult -Name "WorstXpsnrScore" -DefaultValue $null)
    MetricSortScore  = if ($null -ne (Get-ObjectPropertyValue -Object $MetricResult -Name "MetricScore" -DefaultValue $null)) {
      switch ((Get-NormalizedOptionValue -Value (Get-ObjectPropertyValue -Object $MetricResult -Name "MetricModeUsed" -DefaultValue "off") -DefaultValue "off")) {
        "vmaf"  { [int][math]::Round([double]$MetricResult.MetricScore * 10.0) }
        "ensemble" { [int][math]::Round([double]$MetricResult.MetricScore * 10.0) }
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
  $previewCopy | Add-Member -NotePropertyName PrimaryMetricMode -NotePropertyValue ([string]$MetricBundle.PrimaryMetricMode) -Force
  $previewCopy | Add-Member -NotePropertyName MetricScore -NotePropertyValue $MetricBundle.MetricScore -Force
  $previewCopy | Add-Member -NotePropertyName WorstMetricScore -NotePropertyValue $MetricBundle.WorstMetricScore -Force
  $previewCopy | Add-Member -NotePropertyName MetricConfidence -NotePropertyValue ([double]$MetricBundle.MetricConfidence) -Force
  $previewCopy | Add-Member -NotePropertyName MetricSortScore -NotePropertyValue ([int]$MetricBundle.MetricSortScore) -Force
  $previewCopy | Add-Member -NotePropertyName MetricSegmentScores -NotePropertyValue @($MetricBundle.SegmentScores) -Force
  foreach ($metricProperty in @("VmafNegScore", "WorstVmafNegScore", "StandardVmafScore", "XpsnrScore", "WorstXpsnrScore")) {
    $previewCopy | Add-Member -NotePropertyName $metricProperty -NotePropertyValue (Get-ObjectPropertyValue -Object $MetricBundle -Name $metricProperty -DefaultValue $null) -Force
  }
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

  $geometry = [string](Get-ObjectPropertyValue -Object $Plan -Name "GeometryVFilter" -DefaultValue "")
  $encode = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
  $pixFmt = [string](Get-ObjectPropertyValue -Object $Plan -Name "OutputPixelFormat" -DefaultValue "yuv420p")
  $vbv = [string](Get-ObjectPropertyValue -Object $Plan -Name "VbvMode" -DefaultValue "Off")
  $backend = [string](Get-ObjectPropertyValue -Object $Plan.CodecProfile -Name "EncoderBackend" -DefaultValue $Plan.CodecProfile.VideoCodec)
  return ("{0}x{1}@{2}|v={3}|a={4}|p={5}|pp={6}|crop={7}|codec={8}|backend={9}|container={10}|pix={11}|vbv={12}|g={13}|ef={14}" -f $Plan.Width, $Plan.Height, $Plan.Fps, $Plan.VideoKbps, $audioKey, $Plan.Preset, $Plan.PreprocessLabel, [int]$Plan.CropApplied, $Plan.CodecProfile.VideoCodec, $backend, $Plan.CodecProfile.Container, $pixFmt, $vbv, $geometry, $encode)
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

  $vbvPolicy = Get-VbvPolicy -Plan $Plan

  return [PSCustomObject]@{
    Width                 = [int]$Plan.Width
    Height                = [int]$Plan.Height
    Fps                   = [int]$Plan.Fps
    VideoKbps             = [int]$Plan.VideoKbps
    PlanningTargetBytes   = [long](Get-ObjectPropertyValue -Object $Plan -Name "TargetBytes" -DefaultValue 0)
    WorkingTargetBytes    = [long](Get-ObjectPropertyValue -Object $Plan -Name "WorkingTargetBytes" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "TargetBytes" -DefaultValue 0))
    HardCapBytes          = [long](Get-ObjectPropertyValue -Object $Plan -Name "HardCapBytes" -DefaultValue $Plan.TargetBytes)
    AudioMode             = [string]$Plan.AudioPlan.Mode
    AudioKbps             = [int](Get-ObjectPropertyValue -Object $Plan.AudioPlan -Name "Kbps" -DefaultValue 0)
    Codec                 = [string]$Plan.CodecProfile.VideoCodec
    EncoderBackend        = [string](Get-ObjectPropertyValue -Object $Plan.CodecProfile -Name "EncoderBackend" -DefaultValue $Plan.CodecProfile.VideoCodec)
    Container             = [string]$Plan.CodecProfile.Container
    Preset                = [string]$Plan.Preset
    PreprocessLabel       = [string]$Plan.PreprocessLabel
    ContentClass          = [string](Get-ObjectPropertyValue -Object $Plan -Name "ContentClass" -DefaultValue "general")
    SamplingModeUsed      = [string](Get-ObjectPropertyValue -Object $Plan -Name "SamplingModeUsed" -DefaultValue "fixed")
    MetricModeUsed        = [string](Get-ObjectPropertyValue -Object $Plan -Name "MetricModeUsed" -DefaultValue "off")
    PrimaryMetricMode     = [string](Get-ObjectPropertyValue -Object $Plan -Name "PrimaryMetricMode" -DefaultValue "off")
    MetricScore           = (Get-ObjectPropertyValue -Object $Plan -Name "MetricScore" -DefaultValue $null)
    WorstMetricScore      = (Get-ObjectPropertyValue -Object $Plan -Name "WorstMetricScore" -DefaultValue $null)
    MetricConfidence      = [double](Get-ObjectPropertyValue -Object $Plan -Name "MetricConfidence" -DefaultValue 0.0)
    VmafNegScore          = (Get-ObjectPropertyValue -Object $Plan -Name "VmafNegScore" -DefaultValue $null)
    WorstVmafNegScore     = (Get-ObjectPropertyValue -Object $Plan -Name "WorstVmafNegScore" -DefaultValue $null)
    StandardVmafScore     = (Get-ObjectPropertyValue -Object $Plan -Name "StandardVmafScore" -DefaultValue $null)
    XpsnrScore            = (Get-ObjectPropertyValue -Object $Plan -Name "XpsnrScore" -DefaultValue $null)
    WorstXpsnrScore       = (Get-ObjectPropertyValue -Object $Plan -Name "WorstXpsnrScore" -DefaultValue $null)
    PreviewRank           = [int](Get-ObjectPropertyValue -Object $Plan -Name "PreviewRank" -DefaultValue 0)
    PreviewRatio          = (Get-ObjectPropertyValue -Object $Plan -Name "PreviewRatio" -DefaultValue $null)
    GeometryVFilter       = [string](Get-ObjectPropertyValue -Object $Plan -Name "GeometryVFilter" -DefaultValue "")
    PreprocessVFilter     = [string](Get-ObjectPropertyValue -Object $Plan -Name "PreprocessVFilter" -DefaultValue "")
    EncodeVFilter         = [string](Get-ObjectPropertyValue -Object $Plan -Name "EncodeVFilter" -DefaultValue $Plan.VFilter)
    MetricReferenceVFilter = [string](Get-ObjectPropertyValue -Object $Plan -Name "MetricReferenceVFilter" -DefaultValue "")
    EvaluatorVersion       = [string](Get-ObjectPropertyValue -Object $Plan -Name "EvaluatorVersion" -DefaultValue "")
    MetricCanvasWidth      = [int](Get-ObjectPropertyValue -Object $Plan -Name "MetricCanvasWidth" -DefaultValue 0)
    MetricCanvasHeight     = [int](Get-ObjectPropertyValue -Object $Plan -Name "MetricCanvasHeight" -DefaultValue 0)
    MetricFps              = [double](Get-ObjectPropertyValue -Object $Plan -Name "MetricFps" -DefaultValue 0.0)
    MetricPixelFormat      = [string](Get-ObjectPropertyValue -Object $Plan -Name "MetricPixelFormat" -DefaultValue "")
    OutputPixelFormat     = [string](Get-ObjectPropertyValue -Object $Plan -Name "OutputPixelFormat" -DefaultValue "yuv420p")
    OutputBitDepth        = [int](Get-ObjectPropertyValue -Object $Plan -Name "OutputBitDepth" -DefaultValue 8)
    SourcePixelFormat     = [string](Get-ObjectPropertyValue -Object $Plan -Name "SourcePixelFormat" -DefaultValue "")
    SourceBitDepth        = [int](Get-ObjectPropertyValue -Object $Plan -Name "SourceBitDepth" -DefaultValue 8)
    ColorMetadataStatus   = [string](Get-ObjectPropertyValue -Object $Plan -Name "ColorMetadataStatus" -DefaultValue "unspecified")
    ColorMetadataPreserved = @((Get-ObjectPropertyValue -Object $Plan -Name "ColorMetadataPreserved" -DefaultValue @()))
    ColorMetadataOmitted  = @((Get-ObjectPropertyValue -Object $Plan -Name "ColorMetadataOmitted" -DefaultValue @()))
    VbvMode               = [string](Get-ObjectPropertyValue -Object $Plan -Name "VbvMode" -DefaultValue "Off")
    MaxrateKbps           = $vbvPolicy.MaxrateKbps
    BufsizeKbits          = $vbvPolicy.BufsizeKbits
    VbvPeakMultiplier     = $vbvPolicy.PeakMultiplier
    VbvBufferSeconds      = $vbvPolicy.BufferSeconds
    ReserveBytes          = [long](Get-ObjectPropertyValue -Object $Plan -Name "ReserveBytes" -DefaultValue 0)
    VideoPayloadBytes     = [long](Get-ObjectPropertyValue -Object $Plan -Name "VideoPayloadBytes" -DefaultValue 0)
    AudioPayloadBytes     = [long](Get-ObjectPropertyValue -Object $Plan -Name "AudioPayloadBytes" -DefaultValue 0)
    MuxOverheadBytes      = [long](Get-ObjectPropertyValue -Object $Plan -Name "MuxOverheadBytes" -DefaultValue 0)
    CorrectionHistory     = @((Get-ObjectPropertyValue -Object $Plan -Name "CorrectionHistory" -DefaultValue @()))
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
    VideoPayloadBytes = [long](Get-ObjectPropertyValue -Object $Result -Name "VideoPayloadBytes" -DefaultValue 0)
    AudioPayloadBytes = [long](Get-ObjectPropertyValue -Object $Result -Name "AudioPayloadBytes" -DefaultValue 0)
    MuxOverheadBytes = [long](Get-ObjectPropertyValue -Object $Result -Name "MuxOverheadBytes" -DefaultValue 0)
    CorrectionHistory = @((Get-ObjectPropertyValue -Object $Result -Name "CorrectionHistory" -DefaultValue @()))
    SearchStats    = (Get-ObjectPropertyValue -Object $Result -Name "SearchStats" -DefaultValue $null)
    Plan           = Get-PlanFeatureVector -Plan $Result.Plan
  }
}

function Get-HostFingerprint {
  if ($null -ne $script:HostFingerprint) { return $script:HostFingerprint }

  $cpu = [string]$env:PROCESSOR_IDENTIFIER
  $gpu = ""
  $driver = ""
  if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    try {
      $processor = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
      if ($processor -and $processor.Name) { $cpu = [string]$processor.Name.Trim() }
      $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
      $gpu = (@($controllers | ForEach-Object { [string]$_.Name }) -join "; ")
      $driver = (@($controllers | ForEach-Object { [string]$_.DriverVersion }) -join "; ")
    }
    catch {
      # The portable runtime fields below remain sufficient when CIM is absent.
    }
  }

  $identityText = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f [System.Runtime.InteropServices.RuntimeInformation]::OSDescription, [Environment]::OSVersion.VersionString, [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture, $cpu, $gpu, $driver, (Get-FFmpegBuildFingerprint)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $idBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identityText))
    $hostId = ([BitConverter]::ToString($idBytes)).Replace("-", "").Substring(0, 16).ToLowerInvariant()
  }
  finally { $sha.Dispose() }

  $script:HostFingerprint = [PSCustomObject]@{
    Id = $hostId
    MachineName = [Environment]::MachineName
    Os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    Kernel = [Environment]::OSVersion.VersionString
    OsArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    ProcessArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    Cpu = $cpu
    Gpu = $gpu
    Driver = $driver
    FFmpegBuild = Get-FFmpegBuildFingerprint
    HardwareDevice = $HardwareDevice
  }
  return $script:HostFingerprint
}

function New-CompressorResultObject {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("copy", "encode")][string]$Action,
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$CodecProfile,
    [Parameter(Mandatory = $true)]$PolicyProfile,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][long]$HardCapBytes,
    [Parameter(Mandatory = $true)][long]$WorkingTargetBytes,
    $Winner = $null
  )

  $outputFull = (Resolve-Path -LiteralPath $OutputPath).Path
  $outputBytes = [long](Get-Item -LiteralPath $outputFull).Length
  $canonical = Get-CanonicalMetricProfile -Info $Info
  $plan = if ($Winner) { $Winner.Plan } else { $null }
  $fillGate = if ($Action -eq "encode") { [double](Get-ModeStrategy -Mode $Mode -Duration $Info.Duration).EarlyAcceptRatio } else { $null }
  $fillRatio = [double]$outputBytes / [double]$HardCapBytes
  $warnings = New-Object System.Collections.Generic.List[string]
  if ($Action -eq "encode" -and $fillRatio -lt $fillGate) {
    [void]$warnings.Add(("final fill {0:P2} is below the {1:P2} mode gate" -f $fillRatio, $fillGate))
  }

  $probe = Get-ObjectPropertyValue -Object $CodecProfile -Name "FunctionalProbe" -DefaultValue $null
  $metricScore = if ($plan) { Get-ObjectPropertyValue -Object $plan -Name "MetricScore" -DefaultValue $null } else { $null }
  $encoderArguments = if ($plan) { @(Get-CommonVideoEncodeArgs -Plan $plan) } else { @() }
  $searchStats = if ($Winner) { Get-ObjectPropertyValue -Object $Winner -Name "SearchStats" -DefaultValue $null } else { $null }

  return [PSCustomObject]@{
    SchemaVersion = "byakuren.compress.result.v1"
    Status = "succeeded"
    Action = $Action
    StartedUtc = $scriptStart.ToUniversalTime().ToString("o")
    CompletedUtc = (Get-Date).ToUniversalTime().ToString("o")
    ElapsedMilliseconds = [long]((Get-Date) - $scriptStart).TotalMilliseconds
    Request = [PSCustomObject]@{
      InputPath = $InputPath; OutputPath = $outputFull; HardCapBytes = $HardCapBytes; WorkingTargetBytes = $WorkingTargetBytes
      Mode = $Mode; RequestedVideoCodec = $VideoCodec; RequestedEncoderBackend = $EncoderBackend
      RequestedContainer = if ([string]::IsNullOrWhiteSpace($Container)) { "auto" } else { $Container }
      CompatibilityMode = $CompatibilityMode; UnderCapBehavior = $UnderCapBehavior; MetricMode = $MetricMode
      SampleMode = $SampleMode; HardwareDevice = $HardwareDevice; ExperimentalEncoders = [bool]$EnableExperimentalEncoders
    }
    Policy = [PSCustomObject]@{
      VideoCodec = [string]$PolicyProfile.VideoCodec; EncoderBackend = [string]$PolicyProfile.EncoderBackend
      Container = [string]$PolicyProfile.Container; AudioCodec = [string]$PolicyProfile.DefaultAudioCodec
      CodecReason = [string]$PolicyProfile.CodecPolicyReason; ContainerReason = [string]$PolicyProfile.ContainerPolicyReason
      CompatibilityMode = [string]$PolicyProfile.CompatibilityMode
    }
    Host = Get-HostFingerprint
    CapabilityProbe = if ($probe) { $probe } else { [PSCustomObject]@{ Success = $null; Backend = $CodecProfile.EncoderBackend; SkippedReason = "under-cap passthrough" } }
    Source = [PSCustomObject]@{
      Bytes = [long]$Info.InputBytes; DurationSeconds = [double]$Info.Duration; Width = [int]$Info.Width; Height = [int]$Info.Height
      Fps = [double]$Info.Fps; VideoCodec = [string]$Info.VideoCodec; PixelFormat = [string]$Info.PixelFormat
      BitDepth = [int]$Info.VideoBitDepth; AudioCodec = [string]$Info.AudioCodec; Rotation = [int]$Info.Rotation
      SampleAspectRatio = [string]$Info.SampleAspectRatio; HdrClassification = [string]$Info.HdrClassification
    }
    Evaluator = [PSCustomObject]@{
      Version = [string]$canonical.EvaluatorVersion; MetricMode = if ($plan) { [string](Get-ObjectPropertyValue -Object $plan -Name "MetricModeUsed" -DefaultValue "off") } else { "off" }
      PrimaryMetric = if ($plan) { [string](Get-ObjectPropertyValue -Object $plan -Name "PrimaryMetricMode" -DefaultValue "") } else { "" }
      CanonicalCanvas = [PSCustomObject]@{ Width = [int]$canonical.Width; Height = [int]$canonical.Height; Fps = [double]$canonical.Fps; PixelFormat = [string]$canonical.PixelFormat; BitDepth = [int]$canonical.BitDepth }
      VMAFModel = "vmaf-neg-primary+vmaf-standard-supplemental"; XPSNRGuard = $true
    }
    Encoder = [PSCustomObject]@{
      Backend = [string]$CodecProfile.EncoderBackend; Name = [string]$CodecProfile.VideoEncoder; Codec = [string]$CodecProfile.VideoCodec
      Container = [string]$CodecProfile.Container; AudioProfile = [string]$CodecProfile.ContainerAudioProfile
      RateControlAdapter = [string]$CodecProfile.RateControlAdapter; Preset = if ($plan) { [string]$plan.Preset } else { "copy" }
      PixelFormat = if ($plan) { [string]$plan.OutputPixelFormat } else { [string]$Info.PixelFormat }; Arguments = @($encoderArguments)
      ParameterFamilies = @(Get-EncoderParameterFamilies -Backend $CodecProfile.EncoderBackend -ContentClass $(if ($plan) { [string]$plan.ContentClass } else { "general" }))
    }
    Plan = if ($plan) { Get-PlanFeatureVector -Plan $plan } else { $null }
    PayloadBytes = [PSCustomObject]@{
      Video = if ($Winner) { [long]$Winner.VideoPayloadBytes } else { $null }
      Audio = if ($Winner) { [long]$Winner.AudioPayloadBytes } else { $null }
      MuxOverhead = if ($Winner) { [long]$Winner.MuxOverheadBytes } else { $null }
      Total = $outputBytes
    }
    SizeSearch = [PSCustomObject]@{
      HardCapBytes = $HardCapBytes; WorkingTargetBytes = $WorkingTargetBytes; FillRatio = $fillRatio; FillGate = $fillGate
      FullEncodes = if ($searchStats) { [int]$searchStats.FullEncodesRun } else { 0 }
      CorrectionHistory = if ($Winner) { @($Winner.CorrectionHistory) } else { @() }
    }
    Metrics = [PSCustomObject]@{
      Available = ($null -ne $metricScore); PrimaryScore = $metricScore
      WorstWindowScore = if ($plan) { Get-ObjectPropertyValue -Object $plan -Name "WorstMetricScore" -DefaultValue $null } else { $null }
      VMAFNeg = if ($plan) { Get-ObjectPropertyValue -Object $plan -Name "VmafNegScore" -DefaultValue $null } else { $null }
      WorstVMAFNeg = if ($plan) { Get-ObjectPropertyValue -Object $plan -Name "WorstVmafNegScore" -DefaultValue $null } else { $null }
      StandardVMAF = if ($plan) { Get-ObjectPropertyValue -Object $plan -Name "StandardVmafScore" -DefaultValue $null } else { $null }
      XPSNR = if ($plan) { Get-ObjectPropertyValue -Object $plan -Name "XpsnrScore" -DefaultValue $null } else { $null }
      WorstXPSNR = if ($plan) { Get-ObjectPropertyValue -Object $plan -Name "WorstXpsnrScore" -DefaultValue $null } else { $null }
      Windows = if ($Winner) { @((Get-ObjectPropertyValue -Object $Winner -Name "MetricSegmentScores" -DefaultValue @())) } else { @() }
    }
    Output = [PSCustomObject]@{
      Path = $outputFull; Bytes = $outputBytes; FillRatio = $fillRatio; Sha256 = (Get-FileHash -LiteralPath $outputFull -Algorithm SHA256).Hash.ToLowerInvariant()
      DecodeVerified = if ($probe) { [bool]$probe.Success } else { $true }
    }
    Warnings = @($warnings.ToArray())
  }
}

function Write-CompressorResultJson {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $directory = Split-Path $fullPath -Parent
  if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $temporary = $fullPath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
  try {
    $Result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $fullPath -Force
  }
  finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
  return $fullPath
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
    [long]$TargetVideoPayloadBytes = 0,
    [long]$CurrentVideoPayloadBytes = 0,
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

    $lowerBytes = [double](Get-ObjectPropertyValue -Object $LowerBound -Name "PayloadBytes" -DefaultValue $LowerBound.SizeBytes)
    $upperBytes = [double](Get-ObjectPropertyValue -Object $UpperBound -Name "PayloadBytes" -DefaultValue $UpperBound.SizeBytes)
    $effectiveTargetBytes = if ($TargetVideoPayloadBytes -gt 0) { [double]$TargetVideoPayloadBytes } else { [double]$TargetBytes }
    $spanBytes = $upperBytes - $lowerBytes
    if ($spanBytes -gt 1.0) {
      $guess = [double]$LowerBound.VideoKbps + (($effectiveTargetBytes - $lowerBytes) / $spanBytes) * ([double]$UpperBound.VideoKbps - [double]$LowerBound.VideoKbps)
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

  $effectiveCurrentBytes = if ($CurrentVideoPayloadBytes -gt 0) { [double]$CurrentVideoPayloadBytes } else { [double]$CurrentSizeBytes }
  $effectiveTargetBytes = if ($TargetVideoPayloadBytes -gt 0) { [double]$TargetVideoPayloadBytes } else { [double]$TargetBytes }
  if ($effectiveCurrentBytes -lt $effectiveTargetBytes) {
    $desiredFillBytes = switch ($Mode) {
      "Fast"         { [math]::Floor($TargetBytes * 0.992) }
      "Balanced"     { [math]::Floor($TargetBytes * 0.9985) }
      "ExtraQuality" { [math]::Floor($TargetBytes * 0.9990) }
    }
    $desiredFillBytes = if ($TargetVideoPayloadBytes -gt 0) { [double]$TargetVideoPayloadBytes } else { [double]$desiredFillBytes }
    $factor = [double]$desiredFillBytes / [double][math]::Max(1, $effectiveCurrentBytes)
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
    $desiredShrinkBytes = if ($TargetVideoPayloadBytes -gt 0) { [double]$TargetVideoPayloadBytes } else { [double]$desiredShrinkBytes }
    $factor = [double]$desiredShrinkBytes / [double][math]::Max(1, $effectiveCurrentBytes)
    $factor = switch ($Mode) {
      "Fast"         { [math]::Max(0.35, [math]::Min(0.99, $factor)) }
      "Balanced"     { [math]::Max(0.60, [math]::Min(0.985, $factor)) }
      "ExtraQuality" { [math]::Max(0.70, [math]::Min(0.988, $factor)) }
    }
  }

  $nextGuess = [int][math]::Floor($CurrentVideoKbps * $factor)
  if ($nextGuess -eq $CurrentVideoKbps) {
    if ($effectiveCurrentBytes -lt $effectiveTargetBytes) {
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
  $sizeEstimateVideo = Get-CommonVideoEncodeArgs -Plan $Plan -Purpose "SizeEstimate"

  foreach ($window in $sampleWindows) {
    $idx++
    $offset = [double](Get-ObjectPropertyValue -Object $window -Name "Start" -DefaultValue 0.0)
    $windowDuration = [double](Get-ObjectPropertyValue -Object $window -Name "Duration" -DefaultValue $SampleSeconds)
    $outPath = Join-Path $TempDir ("preview_{0}_{1}_{2}_{3}{4}" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $idx, $Plan.OutputExtension)
    $args = @("-y", "-ss", "$offset", "-t", "$windowDuration", "-i", $InputPath)
    $args += @("-an") + $sizeEstimateVideo + @($outPath)

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
  $metricMode = Get-NormalizedOptionValue -Value (Get-ObjectPropertyValue -Object $Plan -Name "MetricModeUsed" -DefaultValue "off") -DefaultValue "off"
  if ($metricMode -ne "off") {
    $qualityMetricVideo = Get-CommonVideoEncodeArgs -Plan $Plan -Purpose "QualityMetric"
    $metricWindows = @(Get-PreviewSampleWindows -Info $Info -Plan $Plan -SampleSeconds $metricSampling.SampleSeconds -MaxSamples $metricSampling.MaxSamples)
    $metricIdx = 0
    foreach ($window in $metricWindows) {
      $metricIdx++
      $offset = [double](Get-ObjectPropertyValue -Object $window -Name "Start" -DefaultValue 0.0)
      $windowDuration = [double](Get-ObjectPropertyValue -Object $window -Name "Duration" -DefaultValue $metricSampling.SampleSeconds)
      $outPath = Join-Path $TempDir ("metricpreview_{0}_{1}_{2}_{3}{4}" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $metricIdx, $Plan.OutputExtension)
      $args = @("-y", "-ss", "$offset", "-t", "$windowDuration", "-i", $InputPath)
      $args += @("-an") + $qualityMetricVideo + @($outPath)
      [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
      [void]$metricSegments.Add([PSCustomObject]@{
          Path  = $outPath
          Bytes = [double](Get-Item $outPath).Length
          Window = $window
        })
    }
  }

  $metricResult = Invoke-PreviewMetric -InputPath $InputPath -PreviewSegments @($metricSegments.ToArray()) -Plan $Plan -TempDir $TempDir
  $metricBundle = Get-MetricScoreBundle -MetricResult $metricResult
  $predictedTotalBytes = [long][math]::Floor($predictedVideoBytes + [double]$Plan.AudioPlan.EstimatedBytes + [double](Get-MuxReserveBytes -targetBytes $Plan.TargetBytes -mode $Plan.Mode -Container $Plan.CodecProfile.Container -VideoCodec $Plan.CodecProfile.VideoCodec -AudioMode $Plan.AudioPlan.Mode))
  $hardCapBytes = [long](Get-ObjectPropertyValue -Object $Plan -Name "HardCapBytes" -DefaultValue $Plan.TargetBytes)
  $predictedRatio = $predictedTotalBytes / [double]$hardCapBytes

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
    SizeEstimatePreset = ((Get-CodecPresetArgs -Plan $Plan -Purpose "SizeEstimate") -join " ")
    QualityMetricPreset = if ($metricMode -ne "off") { ((Get-CodecPresetArgs -Plan $Plan -Purpose "QualityMetric") -join " ") } else { "off" }
    QualityMetricPixelFormat = [string](Get-ObjectPropertyValue -Object $Plan -Name "OutputPixelFormat" -DefaultValue "yuv420p")
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
                $selectedPlan | Add-Member -NotePropertyName WorstMetricScore -NotePropertyValue (Get-ObjectPropertyValue -Object $preview -Name "WorstMetricScore" -DefaultValue $null) -Force
                $selectedPlan | Add-Member -NotePropertyName MetricConfidence -NotePropertyValue ([double](Get-ObjectPropertyValue -Object $preview -Name "MetricConfidence" -DefaultValue 0.0)) -Force
                foreach ($metricProperty in @("PrimaryMetricMode", "VmafNegScore", "WorstVmafNegScore", "StandardVmafScore", "XpsnrScore", "WorstXpsnrScore")) {
                  $selectedPlan | Add-Member -NotePropertyName $metricProperty -NotePropertyValue (Get-ObjectPropertyValue -Object $preview -Name $metricProperty -DefaultValue $null) -Force
                }
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
          $selectedPlan | Add-Member -NotePropertyName WorstMetricScore -NotePropertyValue (Get-ObjectPropertyValue -Object $preview -Name "WorstMetricScore" -DefaultValue $null) -Force
          $selectedPlan | Add-Member -NotePropertyName MetricConfidence -NotePropertyValue ([double](Get-ObjectPropertyValue -Object $preview -Name "MetricConfidence" -DefaultValue 0.0)) -Force
          foreach ($metricProperty in @("PrimaryMetricMode", "VmafNegScore", "WorstVmafNegScore", "StandardVmafScore", "XpsnrScore", "WorstXpsnrScore")) {
            $selectedPlan | Add-Member -NotePropertyName $metricProperty -NotePropertyValue (Get-ObjectPropertyValue -Object $preview -Name $metricProperty -DefaultValue $null) -Force
          }
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

  return ("{0}|{1}|{2}" -f $AudioPlan.Mode, (Get-ObjectPropertyValue -Object $AudioPlan -Name "Codec" -DefaultValue ""), (Get-ObjectPropertyValue -Object $AudioPlan -Name "Kbps" -DefaultValue ""))
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

function Get-FinalMetricWindows {
  param([Parameter(Mandatory = $true)]$Plan)

  $sampleSeconds = if ($MetricSampleSeconds -gt 0) { [int]$MetricSampleSeconds } else { 4 }
  $maxSamples = if ($MetricMaxSamples -gt 0) {
    [int]$MetricMaxSamples
  }
  elseif ($Plan.Mode -eq "ExtraQuality") {
    3
  }
  else {
    2
  }

  $duration = [double](Get-ObjectPropertyValue -Object $Plan -Name "DurationSeconds" -DefaultValue 0.0)
  $windows = New-Object System.Collections.Generic.List[object]
  foreach ($seed in @((Get-ObjectPropertyValue -Object $Plan -Name "SampleWindows" -DefaultValue @()))) {
    if ($windows.Count -ge $maxSamples) { break }
    $start = [double](Get-ObjectPropertyValue -Object $seed -Name "Start" -DefaultValue 0.0)
    $available = [math]::Max(0.0, $duration - $start)
    if ($available -le 0.05) { continue }
    [void]$windows.Add([PSCustomObject]@{
        Start = $start
        Duration = [double][math]::Min($sampleSeconds, $available)
        Source = [string](Get-ObjectPropertyValue -Object $seed -Name "Source" -DefaultValue "final")
        Tag = [string](Get-ObjectPropertyValue -Object $seed -Name "Tag" -DefaultValue "")
      })
  }

  if ($windows.Count -eq 0 -and $duration -gt 0.05) {
    foreach ($window in @(Get-FixedSampleWindows -Duration $duration -SampleLength $sampleSeconds -MaxSamples $maxSamples)) {
      [void]$windows.Add($window)
    }
  }

  return @($windows.ToArray())
}

function Invoke-FinalOutputMetric {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  $segments = New-Object System.Collections.Generic.List[object]
  foreach ($window in @(Get-FinalMetricWindows -Plan $Plan)) {
    [void]$segments.Add([PSCustomObject]@{
        Path = $OutputPath
        Window = $window
        DistortedOffset = [double]$window.Start
      })
  }
  return (Invoke-PreviewMetric -InputPath $InputPath -PreviewSegments @($segments.ToArray()) -Plan $Plan -TempDir $TempDir)
}

function Invoke-PlanAttempt {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][int]$Attempt,
    [string]$PassLogPath = ""
  )

  $audioEntry = Get-CachedAudioEntry -InputPath $InputPath -Plan $Plan -TempDir $TempDir
  $Plan = Apply-ActualAudioBudgetToPlan -Plan $Plan -AudioEntry $audioEntry
  $tempOut = Get-PlanAttemptOutputPath -Plan $Plan -TempDir $TempDir -Attempt $Attempt
  $twoPass = ($Plan.Mode -ne "Fast")
  $encodeResult = Encode-Plan -InputPath $InputPath -OutputPath $tempOut -Plan $Plan -TempDir $TempDir -TwoPass $twoPass -PassLogPath $PassLogPath
  $size = [long]$encodeResult.SizeBytes
  $hardCapBytes = [long](Get-ObjectPropertyValue -Object $Plan -Name "HardCapBytes" -DefaultValue $Plan.TargetBytes)
  $ratio = $size / [double]$hardCapBytes
  $predictedTotalBytes = [long](Get-ObjectPropertyValue -Object $Plan -Name "PredictedTotalBytes" -DefaultValue $Plan.TargetBytes)
  $predictionBias = if ($predictedTotalBytes -gt 0) { [double]$size / [double]$predictedTotalBytes } else { $ratio }
  $metricResult = $null
  if ($size -le $hardCapBytes -and (Get-NormalizedOptionValue -Value ([string](Get-ObjectPropertyValue -Object $Plan -Name "MetricModeUsed" -DefaultValue "off")) -DefaultValue "off") -ne "off") {
    $metricResult = Invoke-FinalOutputMetric -InputPath $InputPath -OutputPath $tempOut -Plan $Plan -TempDir $TempDir
  }

  $resultPlan = $Plan.PSObject.Copy()
  $correctionHistory = @((Get-ObjectPropertyValue -Object $Plan -Name "CorrectionHistory" -DefaultValue @()))
  $correctionHistory += [PSCustomObject]@{
    Attempt = [int]$Attempt
    VideoKbps = [int]$Plan.VideoKbps
    VideoPayloadBytes = [long]$encodeResult.VideoPayloadBytes
    AudioPayloadBytes = [long]$encodeResult.AudioPayloadBytes
    MuxOverheadBytes = [long]$encodeResult.MuxOverheadBytes
    TotalBytes = [long]$size
  }
  $resultPlan | Add-Member -NotePropertyName CorrectionHistory -NotePropertyValue @($correctionHistory) -Force
  $resultPlan | Add-Member -NotePropertyName VideoPayloadBytes -NotePropertyValue ([long]$encodeResult.VideoPayloadBytes) -Force
  $resultPlan | Add-Member -NotePropertyName AudioPayloadBytes -NotePropertyValue ([long]$encodeResult.AudioPayloadBytes) -Force
  $resultPlan | Add-Member -NotePropertyName MuxOverheadBytes -NotePropertyValue ([long]$encodeResult.MuxOverheadBytes) -Force
  if ($metricResult) {
    $resultPlan | Add-Member -NotePropertyName MetricModeUsed -NotePropertyValue ([string]$metricResult.MetricModeUsed) -Force
    $resultPlan | Add-Member -NotePropertyName PrimaryMetricMode -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $metricResult -Name "PrimaryMetricMode" -DefaultValue $metricResult.MetricModeUsed)) -Force
    $resultPlan | Add-Member -NotePropertyName MetricScore -NotePropertyValue (Get-ObjectPropertyValue -Object $metricResult -Name "MetricScore" -DefaultValue $null) -Force
    $resultPlan | Add-Member -NotePropertyName WorstMetricScore -NotePropertyValue (Get-ObjectPropertyValue -Object $metricResult -Name "WorstMetricScore" -DefaultValue $null) -Force
    $resultPlan | Add-Member -NotePropertyName MetricConfidence -NotePropertyValue ([double](Get-ObjectPropertyValue -Object $metricResult -Name "MetricConfidence" -DefaultValue 0.0)) -Force
    foreach ($metricProperty in @("VmafNegScore", "WorstVmafNegScore", "StandardVmafScore", "XpsnrScore", "WorstXpsnrScore")) {
      $resultPlan | Add-Member -NotePropertyName $metricProperty -NotePropertyValue (Get-ObjectPropertyValue -Object $metricResult -Name $metricProperty -DefaultValue $null) -Force
    }
  }
  $metricSegmentScores = if ($metricResult) { @((Get-ObjectPropertyValue -Object $metricResult -Name "SegmentScores" -DefaultValue @())) } else { @() }

  Write-Host ("Plan try {0}: {1}x{2} @{3}fps | v={4}k | a={5} | size={6} bytes ({7:P1})" -f $Attempt, $Plan.Width, $Plan.Height, $Plan.Fps, $Plan.VideoKbps, $Plan.AudioPlan.Label, $size, $ratio)

  if ($size -gt $hardCapBytes) {
    if ($tempOut -and (Test-Path $tempOut)) {
      Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
    }
  }

  $attemptResult = [PSCustomObject]@{
    Success        = ($size -le $hardCapBytes)
    SizeBytes      = [long]$size
    Path           = if ($size -le $hardCapBytes) { $tempOut } else { $null }
    Plan           = $resultPlan
    Ratio          = [double]$ratio
    Attempt        = [int]$Attempt
    PredictionBias = [double]$predictionBias
    MetricModeUsed = [string](Get-ObjectPropertyValue -Object $resultPlan -Name "MetricModeUsed" -DefaultValue "off")
    MetricScore = (Get-ObjectPropertyValue -Object $resultPlan -Name "MetricScore" -DefaultValue $null)
    WorstMetricScore = (Get-ObjectPropertyValue -Object $resultPlan -Name "WorstMetricScore" -DefaultValue $null)
    MetricConfidence = [double](Get-ObjectPropertyValue -Object $resultPlan -Name "MetricConfidence" -DefaultValue 0.0)
    MetricSegmentScores = @($metricSegmentScores)
    VideoPayloadBytes = [long]$encodeResult.VideoPayloadBytes
    AudioPayloadBytes = [long]$encodeResult.AudioPayloadBytes
    MuxOverheadBytes = [long]$encodeResult.MuxOverheadBytes
    CorrectionHistory = @($correctionHistory)
  }
  Write-PlanLogRecord -RecordType "plan_attempt" -Data (Get-OutcomeRecord -Result $attemptResult)
  return $attemptResult
}

function Get-RetryPlanFromResult {
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)]$Result
  )

  $workingTargetBytes = [long](Get-ObjectPropertyValue -Object $Plan -Name "TargetBytes" -DefaultValue 0)
  $hardCapBytes = [long](Get-ObjectPropertyValue -Object $Plan -Name "HardCapBytes" -DefaultValue $workingTargetBytes)
  $audioPayloadBytes = [long](Get-ObjectPropertyValue -Object $Result -Name "AudioPayloadBytes" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "AudioPayloadBytes" -DefaultValue 0))
  $muxOverheadBytes = [long](Get-ObjectPropertyValue -Object $Result -Name "MuxOverheadBytes" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "ReserveBytes" -DefaultValue 0))
  $correctionTotalBytes = $workingTargetBytes
  if ($Result.Success -and $Plan.Mode -eq "ExtraQuality") {
    # A secant bracket is available for the final micro-fill, so use a narrow
    # hard-cap guard instead of stopping just below the 99.5% promotion gate.
    $correctionTotalBytes = [long][math]::Max($workingTargetBytes, [math]::Floor($hardCapBytes * 0.997))
  }
  elseif ($Result.Success -and $Plan.Mode -eq "Balanced") {
    # Leave a small, mode-derived margin for bitrate quantization and mux drift
    # without encoding assumptions about a particular backend or machine.
    $fillGate = [double](Get-ModeStrategy -Mode "Balanced").EarlyAcceptRatio
    $portableTargetRatio = [math]::Min(([double]$workingTargetBytes / [double]$hardCapBytes), $fillGate + 0.001)
    $correctionTotalBytes = [long][math]::Floor($hardCapBytes * $portableTargetRatio)
  }
  $targetVideoPayloadBytes = [long][math]::Max(25000, $correctionTotalBytes - $audioPayloadBytes - $muxOverheadBytes)
  if ([long]$Result.SizeBytes -gt $hardCapBytes) {
    $overshootSafety = switch ($Plan.Mode) {
      "Fast" {
        # Derive a conservative single-pass guard from the observed miss. This
        # keeps the correction portable across encoders, hosts, and drivers.
        $overshootFraction = [math]::Max(0.0, ([double]$Result.SizeBytes / [double]$hardCapBytes) - 1.0)
        if ($overshootFraction -le 0.02) { 0.995 }
        elseif ($overshootFraction -le 0.10) { [math]::Max(0.94, 1.0 - $overshootFraction) }
        else { 0.97 }
      }
      "Balanced" { 0.97 }
      default { 0.985 }
    }
    $targetVideoPayloadBytes = [long][math]::Max(25000, [math]::Floor($targetVideoPayloadBytes * $overshootSafety))
  }
  $currentVideoPayloadBytes = [long](Get-ObjectPropertyValue -Object $Result -Name "VideoPayloadBytes" -DefaultValue 0)

  $points = @((Get-ObjectPropertyValue -Object $Result -Name "CorrectionHistory" -DefaultValue (Get-ObjectPropertyValue -Object $Plan -Name "CorrectionHistory" -DefaultValue @())) | ForEach-Object {
      [PSCustomObject]@{
        VideoKbps = [int]$_.VideoKbps
        PayloadBytes = [long]$_.VideoPayloadBytes
        SizeBytes = [long]$_.TotalBytes
      }
    })
  $lowerBound = $points | Where-Object { $_.PayloadBytes -le $targetVideoPayloadBytes } | Sort-Object PayloadBytes -Descending | Select-Object -First 1
  $upperBound = $points | Where-Object { $_.PayloadBytes -ge $targetVideoPayloadBytes } | Sort-Object PayloadBytes | Select-Object -First 1
  if ($lowerBound -and $upperBound -and $lowerBound.VideoKbps -eq $upperBound.VideoKbps) {
    if ($currentVideoPayloadBytes -le $targetVideoPayloadBytes) { $upperBound = $null } else { $lowerBound = $null }
  }

  $newRate = Get-NextVideoKbpsGuess `
    -Mode $Plan.Mode `
    -TargetBytes $workingTargetBytes `
    -CurrentVideoKbps $Plan.VideoKbps `
    -CurrentSizeBytes $Result.SizeBytes `
    -TargetVideoPayloadBytes $targetVideoPayloadBytes `
    -CurrentVideoPayloadBytes $currentVideoPayloadBytes `
    -LowerBound $lowerBound `
    -UpperBound $upperBound

  if ($newRate -lt 35 -or $newRate -eq $Plan.VideoKbps) {
    return $null
  }

  $retryPlan = Apply-SizeCalibrationToPlan -Plan $Plan -Calibration (Get-ObservedSizeCalibration -ReferenceResult $Result)
  $retryPlan.VideoKbps = [int]$newRate
  $retryPlan | Add-Member -NotePropertyName PredictedTotalBytes -NotePropertyValue $workingTargetBytes -Force
  $retryPlan | Add-Member -NotePropertyName PredictedFillRatio -NotePropertyValue ([double]$Result.Ratio) -Force
  $retryPlan | Add-Member -NotePropertyName CorrectionTargetVideoBytes -NotePropertyValue $targetVideoPayloadBytes -Force
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
  $candidateHardCap = [long](Get-ObjectPropertyValue -Object $CandidatePlan -Name "HardCapBytes" -DefaultValue $CandidatePlan.TargetBytes)
  $desiredBytes = [math]::Floor($candidateHardCap * $strategy.CloseEnoughRatio)
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
  $planCopy | Add-Member -NotePropertyName PredictedTotalBytes -NotePropertyValue ([long][math]::Floor($candidateHardCap * $ReferenceResult.PredictionBias)) -Force
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

  return (Get-QualityPreferenceTuple -Result $Result -EligibilityKind "Final")
}

function Get-PreviewEligibilityClass {
  param([Parameter(Mandatory = $true)]$Result)

  $ratio = [double](Get-ObjectPropertyValue -Object $Result -Name "Ratio" -DefaultValue 0.0)
  if ($ratio -gt 1.0) {
    return [PSCustomObject]@{ Name = "OverCap"; Rank = 0; Ratio = $ratio }
  }
  if ($ratio -ge 0.96) {
    return [PSCustomObject]@{ Name = "Eligible"; Rank = 2; Ratio = $ratio }
  }
  return [PSCustomObject]@{ Name = "Underfilled"; Rank = 1; Ratio = $ratio }
}

function Get-FinalEligibilityClass {
  param([Parameter(Mandatory = $true)]$Result)

  $ratio = [double](Get-ObjectPropertyValue -Object $Result -Name "Ratio" -DefaultValue 0.0)
  $success = [bool](Get-ObjectPropertyValue -Object $Result -Name "Success" -DefaultValue $false)
  if (-not $success -or $ratio -gt 1.0) {
    return [PSCustomObject]@{ Name = "OverCap"; Rank = 0; Ratio = $ratio }
  }
  if ($ratio -ge 0.96) {
    return [PSCustomObject]@{ Name = "Eligible"; Rank = 2; Ratio = $ratio }
  }
  return [PSCustomObject]@{ Name = "Underfilled"; Rank = 1; Ratio = $ratio }
}

function Get-MetricNoiseBand {
  param([AllowEmptyString()][string]$MetricMode)

  switch ((Get-NormalizedOptionValue -Value $MetricMode -DefaultValue "off")) {
    "vmaf"  { return 0.50 }
    "ensemble" { return 0.50 }
    "xpsnr" { return 0.25 }
    default { return [double]::PositiveInfinity }
  }
}

function Get-MetricMaterialityThreshold {
  param([AllowEmptyString()][string]$MetricMode)

  switch ((Get-NormalizedOptionValue -Value $MetricMode -DefaultValue "off")) {
    "vmaf"  { return 1.00 }
    "ensemble" { return 1.00 }
    "xpsnr" { return 0.50 }
    default { return [double]::PositiveInfinity }
  }
}

function Get-MetricQualitySummary {
  param([Parameter(Mandatory = $true)]$Result)

  $plan = $Result.Plan
  $mode = Get-NormalizedOptionValue -Value ([string](Get-ObjectPropertyValue -Object $Result -Name "MetricModeUsed" -DefaultValue (Get-ObjectPropertyValue -Object $plan -Name "MetricModeUsed" -DefaultValue "off"))) -DefaultValue "off"
  $primaryMode = Get-NormalizedOptionValue -Value ([string](Get-ObjectPropertyValue -Object $Result -Name "PrimaryMetricMode" -DefaultValue (Get-ObjectPropertyValue -Object $plan -Name "PrimaryMetricMode" -DefaultValue $mode))) -DefaultValue $mode
  $mean = Get-ObjectPropertyValue -Object $Result -Name "MetricScore" -DefaultValue (Get-ObjectPropertyValue -Object $plan -Name "MetricScore" -DefaultValue $null)
  $worst = Get-ObjectPropertyValue -Object $Result -Name "WorstMetricScore" -DefaultValue (Get-ObjectPropertyValue -Object $plan -Name "WorstMetricScore" -DefaultValue $mean)
  $confidence = [double](Get-ObjectPropertyValue -Object $Result -Name "MetricConfidence" -DefaultValue (Get-ObjectPropertyValue -Object $plan -Name "MetricConfidence" -DefaultValue 0.0))
  $xpsnr = Get-ObjectPropertyValue -Object $Result -Name "XpsnrScore" -DefaultValue (Get-ObjectPropertyValue -Object $plan -Name "XpsnrScore" -DefaultValue $null)
  $available = ($mode -in @("vmaf", "xpsnr", "ensemble") -and $primaryMode -in @("vmaf", "xpsnr") -and $null -ne $mean)
  if (-not $available) {
    return [PSCustomObject]@{ Available = $false; Mode = $mode; PrimaryMode = $primaryMode; Mean = $null; Worst = $null; Composite = $null; Confidence = 0.0; NoiseBand = [double]::PositiveInfinity; Xpsnr = $null }
  }

  $meanValue = [double]$mean
  $worstValue = if ($null -ne $worst) { [double]$worst } else { $meanValue }
  $tailPenalty = [math]::Max(0.0, $meanValue - $worstValue) * 0.35
  return [PSCustomObject]@{
    Available = $true
    Mode = $mode
    PrimaryMode = $primaryMode
    Mean = $meanValue
    Worst = $worstValue
    Composite = ($meanValue - $tailPenalty)
    Confidence = $confidence
    NoiseBand = Get-MetricNoiseBand -MetricMode $mode
    Xpsnr = if ($null -ne $xpsnr) { [double]$xpsnr } else { $null }
  }
}

function Get-QualityPreferenceTuple {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [ValidateSet("Preview", "Final")][string]$EligibilityKind = "Final"
  )

  $plan = $Result.Plan
  $eligibility = if ($EligibilityKind -eq "Preview") { Get-PreviewEligibilityClass -Result $Result } else { Get-FinalEligibilityClass -Result $Result }
  $quality = Get-MetricQualitySummary -Result $Result
  $audioRank = if ($plan.AudioPlan -and $plan.AudioPlan.Rank) { [int]$plan.AudioPlan.Rank } else { 0 }
  $fillScore = [int](1000 - [math]::Min(999, [math]::Round([math]::Abs(1.0 - $Result.Ratio) * 1000)))
  $widthFitScore = [int](1000 - [math]::Min(999, [math]::Round([math]::Abs([math]::Log([math]::Max(0.001, $plan.WidthRatio))) * 1000)))
  $previewRank = [int](Get-ObjectPropertyValue -Object $plan -Name "PreviewRank" -DefaultValue 1)
  $previewRankScore = [int](1000 - [math]::Min(999, (($previewRank - 1) * 100)))
  $metricScale = if ($quality.Mode -eq "xpsnr") { 20.0 } else { 10.0 }
  $metricScore = if ($quality.Available) { [int][math]::Round([double]$quality.Composite * $metricScale) } else { 0 }
  $worstMetricScore = if ($quality.Available) { [int][math]::Round([double]$quality.Worst * $metricScale) } else { 0 }
  $metricConfidence = [int][math]::Round([double]$quality.Confidence * 1000.0)

  switch ($plan.Mode) {
    "Fast" {
      return @(
        [int]$eligibility.Rank,
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
        [int]$eligibility.Rank,
        [int][bool]$quality.Available,
        $metricConfidence,
        $metricScore,
        $worstMetricScore,
        [int]$audioRank,
        $fillScore,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps,
        $previewRankScore
      )
    }

    "ExtraQuality" {
      $presetRank = Get-X264PresetRank -preset $plan.Preset
      return @(
        [int]$eligibility.Rank,
        [int][bool]$quality.Available,
        $metricConfidence,
        $metricScore,
        $worstMetricScore,
        [int]$audioRank,
        $fillScore,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps,
        [int]$presetRank,
        $previewRankScore
      )
    }
  }
}

function Get-PreviewPreferenceTuple {
  param(
    [Parameter(Mandatory = $true)]$Result
  )

  return (Get-QualityPreferenceTuple -Result $Result -EligibilityKind "Preview")
}

function Test-UnderfillQualityOverride {
  param(
    [Parameter(Mandatory = $true)]$Underfilled,
    [Parameter(Mandatory = $true)]$Eligible
  )

  $underQuality = Get-MetricQualitySummary -Result $Underfilled
  $eligibleQuality = Get-MetricQualitySummary -Result $Eligible
  if (-not $underQuality.Available -or -not $eligibleQuality.Available -or $underQuality.Mode -ne $eligibleQuality.Mode) {
    return $false
  }
  $underRatio = [double](Get-ObjectPropertyValue -Object $Underfilled -Name "Ratio" -DefaultValue 0.0)
  $underfillScale = if ($underQuality.Mode -eq "vmaf") { 10.0 } else { 5.0 }
  $extraUnderfillPenalty = [math]::Max(0.0, 0.96 - $underRatio) * $underfillScale
  $requiredAdvantage = (Get-MetricMaterialityThreshold -MetricMode $underQuality.Mode) + $extraUnderfillPenalty
  return (([double]$underQuality.Composite - [double]$eligibleQuality.Composite) -ge $requiredAdvantage)
}

function Compare-QualityResults {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$Current,
    [ValidateSet("Preview", "Final")][string]$EligibilityKind
  )

  $candidatePlan = $Candidate.Plan
  if ($candidatePlan.Mode -eq "Fast") {
    $candidateTuple = Get-QualityPreferenceTuple -Result $Candidate -EligibilityKind $EligibilityKind
    $currentTuple = Get-QualityPreferenceTuple -Result $Current -EligibilityKind $EligibilityKind
    for ($i = 0; $i -lt $candidateTuple.Count; $i++) {
      if ($candidateTuple[$i] -gt $currentTuple[$i]) { return [PSCustomObject]@{ Better = $true; DecidedBy = "fast_tuple_$i"; CandidateTuple = $candidateTuple; CurrentTuple = $currentTuple } }
      if ($candidateTuple[$i] -lt $currentTuple[$i]) { return [PSCustomObject]@{ Better = $false; DecidedBy = "fast_tuple_$i"; CandidateTuple = $candidateTuple; CurrentTuple = $currentTuple } }
    }
    return [PSCustomObject]@{ Better = $false; DecidedBy = "stable_tie"; CandidateTuple = $candidateTuple; CurrentTuple = $currentTuple }
  }

  $candidateEligibility = if ($EligibilityKind -eq "Preview") { Get-PreviewEligibilityClass -Result $Candidate } else { Get-FinalEligibilityClass -Result $Candidate }
  $currentEligibility = if ($EligibilityKind -eq "Preview") { Get-PreviewEligibilityClass -Result $Current } else { Get-FinalEligibilityClass -Result $Current }

  if ($candidateEligibility.Name -eq "OverCap" -and $currentEligibility.Name -ne "OverCap") {
    return [PSCustomObject]@{ Better = $false; DecidedBy = "eligibility"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
  }
  if ($currentEligibility.Name -eq "OverCap" -and $candidateEligibility.Name -ne "OverCap") {
    return [PSCustomObject]@{ Better = $true; DecidedBy = "eligibility"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
  }
  if ($candidateEligibility.Name -ne $currentEligibility.Name) {
    if ($candidateEligibility.Name -eq "Underfilled" -and $currentEligibility.Name -eq "Eligible") {
      $override = Test-UnderfillQualityOverride -Underfilled $Candidate -Eligible $Current
      return [PSCustomObject]@{ Better = [bool]$override; DecidedBy = if ($override) { "underfill_material_quality" } else { "eligibility" }; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
    }
    if ($candidateEligibility.Name -eq "Eligible" -and $currentEligibility.Name -eq "Underfilled") {
      $keepUnderfilled = Test-UnderfillQualityOverride -Underfilled $Current -Eligible $Candidate
      return [PSCustomObject]@{ Better = (-not $keepUnderfilled); DecidedBy = if ($keepUnderfilled) { "underfill_material_quality" } else { "eligibility" }; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
    }
  }

  $candidateQuality = Get-MetricQualitySummary -Result $Candidate
  $currentQuality = Get-MetricQualitySummary -Result $Current
  if ($candidateQuality.Available -ne $currentQuality.Available) {
    return [PSCustomObject]@{ Better = [bool]$candidateQuality.Available; DecidedBy = "metric_availability"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
  }

  if ($candidateQuality.Available -and $candidateQuality.Mode -eq $currentQuality.Mode) {
    $confidenceDelta = [double]$candidateQuality.Confidence - [double]$currentQuality.Confidence
    if ([math]::Abs($confidenceDelta) -ge 0.10) {
      return [PSCustomObject]@{ Better = ($confidenceDelta -gt 0); DecidedBy = "metric_confidence"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
    }

    if ($null -ne $candidateQuality.Xpsnr -and $null -ne $currentQuality.Xpsnr) {
      $xpsnrDelta = [double]$candidateQuality.Xpsnr - [double]$currentQuality.Xpsnr
      if ($xpsnrDelta -le -0.50) {
        return [PSCustomObject]@{ Better = $false; DecidedBy = "xpsnr_regression_guard"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
      }
    }

    $meanDelta = [double]$candidateQuality.Mean - [double]$currentQuality.Mean
    if ([math]::Abs($meanDelta) -gt [double]$candidateQuality.NoiseBand) {
      return [PSCustomObject]@{ Better = ($meanDelta -gt 0); DecidedBy = "perceptual_quality"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
    }

    $worstDelta = [double]$candidateQuality.Worst - [double]$currentQuality.Worst
    if ([math]::Abs($worstDelta) -gt [double]$candidateQuality.NoiseBand) {
      return [PSCustomObject]@{ Better = ($worstDelta -gt 0); DecidedBy = "worst_window_quality"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
    }

    if ($null -ne $candidateQuality.Xpsnr -and $null -ne $currentQuality.Xpsnr) {
      $xpsnrDelta = [double]$candidateQuality.Xpsnr - [double]$currentQuality.Xpsnr
      if ([math]::Abs($xpsnrDelta) -gt 0.25) {
        return [PSCustomObject]@{ Better = ($xpsnrDelta -gt 0); DecidedBy = "xpsnr_quality"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
      }
    }
  }

  $candidateAudio = [int](Get-ObjectPropertyValue -Object $Candidate.Plan.AudioPlan -Name "Rank" -DefaultValue 0)
  $currentAudio = [int](Get-ObjectPropertyValue -Object $Current.Plan.AudioPlan -Name "Rank" -DefaultValue 0)
  if ($candidateAudio -ne $currentAudio) {
    return [PSCustomObject]@{ Better = ($candidateAudio -gt $currentAudio); DecidedBy = "audio_rank"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
  }

  $candidateFill = [math]::Abs(1.0 - [double]$Candidate.Ratio)
  $currentFill = [math]::Abs(1.0 - [double]$Current.Ratio)
  if ([math]::Abs($candidateFill - $currentFill) -gt 0.000001) {
    return [PSCustomObject]@{ Better = ($candidateFill -lt $currentFill); DecidedBy = "fill_within_quality_neighborhood"; CandidateTuple = (Get-QualityPreferenceTuple $Candidate $EligibilityKind); CurrentTuple = (Get-QualityPreferenceTuple $Current $EligibilityKind) }
  }

  $candidateTuple = Get-QualityPreferenceTuple -Result $Candidate -EligibilityKind $EligibilityKind
  $currentTuple = Get-QualityPreferenceTuple -Result $Current -EligibilityKind $EligibilityKind
  for ($i = 7; $i -lt $candidateTuple.Count; $i++) {
    if ($candidateTuple[$i] -gt $currentTuple[$i]) { return [PSCustomObject]@{ Better = $true; DecidedBy = "late_tiebreak_$i"; CandidateTuple = $candidateTuple; CurrentTuple = $currentTuple } }
    if ($candidateTuple[$i] -lt $currentTuple[$i]) { return [PSCustomObject]@{ Better = $false; DecidedBy = "late_tiebreak_$i"; CandidateTuple = $candidateTuple; CurrentTuple = $currentTuple } }
  }
  return [PSCustomObject]@{ Better = $false; DecidedBy = "stable_tie"; CandidateTuple = $candidateTuple; CurrentTuple = $currentTuple }
}

function Test-IsBetterPreviewResult {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$Current
  )

  $comparison = Compare-QualityResults -Candidate $Candidate -Current $Current -EligibilityKind "Preview"
  Write-PlanLogRecord -RecordType "selection_comparison" -Data ([PSCustomObject]@{ Kind = "preview"; DecidedBy = $comparison.DecidedBy; CandidateTuple = $comparison.CandidateTuple; CurrentTuple = $comparison.CurrentTuple; CandidatePlanKey = (Get-PlanKey -Plan $Candidate.Plan); CurrentPlanKey = (Get-PlanKey -Plan $Current.Plan) })
  return [bool]$comparison.Better
}

function Test-IsBetterResult {
  param(
    [Parameter(Mandatory = $true)]$Candidate,
    [Parameter(Mandatory = $true)]$Current
  )

  $comparison = Compare-QualityResults -Candidate $Candidate -Current $Current -EligibilityKind "Final"
  Write-PlanLogRecord -RecordType "selection_comparison" -Data ([PSCustomObject]@{ Kind = "final"; DecidedBy = $comparison.DecidedBy; CandidateTuple = $comparison.CandidateTuple; CurrentTuple = $comparison.CurrentTuple; CandidatePlanKey = (Get-PlanKey -Plan $Candidate.Plan); CurrentPlanKey = (Get-PlanKey -Plan $Current.Plan) })
  return [bool]$comparison.Better
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
    $stats.SecondEncodeReason = "bitrate refinement"
    $secondResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $primaryResult.Plan -CurrentResult $primaryResult -TempDir $TempDir -Attempt 2

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
    $lastSizeResult = $primaryResult

    if ($primaryResult.Ratio -gt 1.0 -or $primaryResult.Ratio -lt $strategy.BadUnderfillRatio) {
      $stats.SecondEncodeReason = "bitrate refinement"
      $retryResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $primaryResult.Plan -CurrentResult $primaryResult -TempDir $TempDir -Attempt 2 -PassLogPath $sharedPassLog
      if ($retryResult) {
        $stats.FullEncodesRun++
        $lastSizeResult = $retryResult
        $bestUnder = Update-BestResult -Current $bestUnder -Candidate $retryResult
      }
    }

    # Do not spend the last Balanced encode on a structural alternative while
    # the selected plan still misses the 99% fill gate.
    if ($stats.FullEncodesRun -lt $strategy.MaxFullEncodes -and (($bestUnder -and $bestUnder.Ratio -lt $strategy.EarlyAcceptRatio) -or -not $bestUnder)) {
      $stats.SecondEncodeReason = "bitrate refinement"
      $sizeReference = if ($bestUnder) { $bestUnder } else { $lastSizeResult }
      $fillResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $sizeReference.Plan -CurrentResult $sizeReference -TempDir $TempDir -Attempt ($stats.FullEncodesRun + 1) -PassLogPath $sharedPassLog
      if ($fillResult) {
        $stats.FullEncodesRun++
        $bestUnder = Update-BestResult -Current $bestUnder -Candidate $fillResult
      }
      return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
    }

    if ($challenger -and $stats.FullEncodesRun -lt $strategy.MaxFullEncodes -and $stats.PreviewsRun -eq 0) {
      $stats.SecondEncodeReason = "challenger"
      Write-Host ("Second-stage:    challenger -> {0}x{1} @{2}fps | v={3}k | a={4} | pp={5}" -f $challenger.Width, $challenger.Height, $challenger.Fps, $challenger.VideoKbps, $challenger.AudioPlan.Label, $challenger.PreprocessLabel)
      $challengerResult = Invoke-PlanAttempt -InputPath $InputPath -Plan $challenger -TempDir $TempDir -Attempt ($stats.FullEncodesRun + 1)
      $stats.FullEncodesRun++
      $bestUnder = Update-BestResult -Current $bestUnder -Candidate $challengerResult

      if ($bestUnder -and $bestUnder.Ratio -lt $strategy.EarlyAcceptRatio -and $stats.FullEncodesRun -lt $strategy.MaxFullEncodes) {
        $stats.SecondEncodeReason = "challenger fill"
        $fillResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $bestUnder.Plan -CurrentResult $bestUnder -TempDir $TempDir -Attempt ($stats.FullEncodesRun + 1)
        if ($fillResult) {
          $stats.FullEncodesRun++
          $bestUnder = Update-BestResult -Current $bestUnder -Candidate $fillResult
        }
      }
    }

    return (Set-SearchStatsOnResult -Result $bestUnder -Stats $stats)
  }
  finally {
    if ($sharedPassLog) { Remove-PassLogFiles -PassLogPath $sharedPassLog }
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
  $attempt = 0
  $lastSizeResult = $null

  foreach ($plan in @($Plans | Select-Object -First 2)) {
    if ($attempt -ge $strategy.MaxFullEncodes) { break }
    $attempt++
    Write-Host ("Testing finalist: {0}x{1} @{2}fps | codec={3} | v={4}k | a={5} | detail={6} | motion={7} | bpppf={8:N4} | preset={9} | width={10} | pp={11} | crop={12}" -f $plan.Width, $plan.Height, $plan.Fps, $plan.CodecProfile.VideoCodec, $plan.VideoKbps, $plan.AudioPlan.Label, $plan.DetailBucket, $plan.MotionBucket, $plan.Bpppf, $plan.Preset, $plan.WidthOrigin, $plan.PreprocessLabel, $plan.CropSummary)
    $result = Invoke-PlanAttempt -InputPath $InputPath -Plan $plan -TempDir $TempDir -Attempt $attempt
    $stats.FullEncodesRun++
    $stats.PredictionBias = [double]$result.PredictionBias
    $bestUnder = Update-BestResult -Current $bestUnder -Candidate $result
    $lastSizeResult = $result

    # Correct this exact plan before moving to a structural competitor. This is
    # required even when every result so far is over cap and bestUnder is null.
    if ($attempt -lt $strategy.MaxFullEncodes -and ($result.Ratio -gt 1.0 -or $result.Ratio -lt $strategy.EarlyAcceptRatio)) {
      $attempt++
      $stats.SecondEncodeReason = "bitrate refinement"
      $retryResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $result.Plan -CurrentResult $result -TempDir $TempDir -Attempt $attempt
      if ($retryResult) {
        $stats.FullEncodesRun++
        $lastSizeResult = $retryResult
        $bestUnder = Update-BestResult -Current $bestUnder -Candidate $retryResult
      }
    }
  }

  $sizeReference = if ($bestUnder) { $bestUnder } else { $lastSizeResult }
  while ($attempt -lt $strategy.MaxFullEncodes -and $sizeReference -and ($null -eq $bestUnder -or $bestUnder.Ratio -lt $strategy.EarlyAcceptRatio)) {
    $attempt++
    $stats.SecondEncodeReason = "micro-fill"
    $retryResult = Try-PlanBitrateRefinement -InputPath $InputPath -Plan $sizeReference.Plan -CurrentResult $sizeReference -TempDir $TempDir -Attempt $attempt
    if (-not $retryResult) { break }
    $stats.FullEncodesRun++
    $sizeReference = $retryResult
    $bestUnder = Update-BestResult -Current $bestUnder -Candidate $retryResult
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

  $archetypes = @(Get-PlanArchetypes -Plans $plans -Info $Info -Probe $Probe -TargetBytes $TargetBytes -Mode $Mode)
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

if ($env:COMPRESS_INTERNAL_TEST_MODE -eq "1") {
  return
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
Assert-SdrInputSupported -Info $info
$targetRequestBytes = Get-RequestedTargetBytes
$script:RequestedHardCapBytes = [long]$targetRequestBytes
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
  -RequestedEncoderBackend $EncoderBackend `
  -RequestedVideoCodecWasExplicit:$($PSBoundParameters.ContainsKey("VideoCodec")) `
  -EnableExperimental:$EnableExperimentalEncoders `
  -TotalKbps $totalKbps

$codecProfile = Resolve-CodecProfile -VideoCodec $policyProfile.VideoCodec -Container $policyProfile.Container -EncoderBackend $policyProfile.EncoderBackend
if ($codecProfile.EncoderBackend -eq "rav1e" -and $Mode -ne "Fast") {
  throw "The installed rav1e FFmpeg wrapper does not expose the required two-pass interface. Use -Mode Fast for lab-only rav1e runs."
}

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
  $OutputFile = Get-DefaultOutputPath -InputPath $inputFull -CodecProfile $codecProfile
}

Assert-OutputFileMatchesProfile -OutputPath $OutputFile -CodecProfile $codecProfile

$underCapEligible = Test-UnderCapPassthroughEligible `
  -Info $info `
  -InputPath $inputFull `
  -CodecProfile $codecProfile `
  -HardCapBytes ([long]$targetRequestBytes) `
  -Behavior $UnderCapBehavior
if ($UnderCapBehavior -eq "Copy" -and -not $underCapEligible) {
  if ([long]$info.InputBytes -gt [long]$targetRequestBytes) {
    throw "-UnderCapBehavior Copy cannot satisfy the hard cap because the input is $($info.InputBytes) bytes and the cap is $([long]$targetRequestBytes) bytes."
  }
  throw "-UnderCapBehavior Copy requires the input codec, audio, and container to match the requested output policy."
}
if ($underCapEligible) {
  $copyResult = Invoke-UnderCapPassthrough -InputPath $inputFull -OutputPath $OutputFile -HardCapBytes ([long]$targetRequestBytes)
  if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
    $resultObject = New-CompressorResultObject -Action copy -Info $info -CodecProfile $codecProfile -PolicyProfile $policyProfile -InputPath $inputFull -OutputPath $OutputFile -HardCapBytes ([long]$targetRequestBytes) -WorkingTargetBytes $usableTargetBytes
    $writtenResultPath = Write-CompressorResultJson -Result $resultObject -Path $ResultJsonPath
    Write-Host "Result JSON:      $writtenResultPath"
  }
  Write-Host "Input is already under the hard cap and matches the requested codec/container policy."
  Write-Host "Output file:      $($copyResult.OutputPath)"
  Write-Host "Final size:       $($copyResult.SizeBytes) bytes"
  Write-Host "Action:           copied without transcoding"
  return
}

Assert-CodecProfileSupport -CodecProfile $codecProfile

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
    VbvMode              = $VbvMode
    OutputBitDepth       = $OutputBitDepth
    UnderCapBehavior     = $UnderCapBehavior
    EncoderBackend      = $codecProfile.EncoderBackend
    HardwareDevice      = $HardwareDevice
    ExperimentalEncoders = [bool]$EnableExperimentalEncoders
    ResultJsonPath        = $ResultJsonPath
    SourceTechnicalMetadata = $info
  })

Write-Host "Input:            $inputFull"
Write-Host "Duration:         $([math]::Round($info.Duration, 2)) s"
Write-Host "Source:           $($info.Width)x$($info.Height) @ $([math]::Round($info.Fps, 3)) fps"
Write-Host "Planning frame:   $(Get-PlanningWidth -Info $info)x$(Get-PlanningHeight -Info $info)"
Write-Host "Source codec:     $($info.VideoCodec)"
Write-Host "Source pixel fmt: $($info.PixelFormat) ($($info.VideoBitDepth)-bit)"
Write-Host "Source color:     range=$($info.ColorRange), primaries=$($info.ColorPrimaries), transfer=$($info.ColorTransfer), matrix=$($info.ColorSpace)"
Write-Host "Source geometry:  SAR=$($info.SampleAspectRatio), DAR=$($info.DisplayAspectRatio), rotation=$($info.Rotation)"
Write-Host "HDR policy:       $($info.HdrClassification) ($($info.HdrReason))"
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
Write-Host "VBV mode:         $VbvMode"
Write-Host "Output bit depth: $OutputBitDepth"
Write-Host "Under-cap action: $UnderCapBehavior"
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
  try {
    $winner.SizeBytes = Assert-FinalOutputWithinCap -Path $OutputFile -HardCapBytes ([long]$targetRequestBytes)
    $winner.Ratio = [double]$winner.SizeBytes / [double]$targetRequestBytes
  }
  catch {
    Remove-Item -LiteralPath $OutputFile -Force -ErrorAction SilentlyContinue
    throw
  }
  Write-PlanLogRecord -RecordType "final_output" -Data (Get-OutcomeRecord -Result $winner)
  $fillGate = [double](Get-ModeStrategy -Mode $Mode -Duration $info.Duration).EarlyAcceptRatio
  if ($winner.Ratio -lt $fillGate -and ($info.Duration -lt 10.0 -or $winner.MuxOverheadBytes -gt ($targetRequestBytes * 0.01))) {
    Write-Host ("Short-file overhead note: final fill {0:P1} is below the {1:P1} mode gate; mux overhead was {2} bytes." -f $winner.Ratio, $fillGate, $winner.MuxOverheadBytes)
    Write-PlanLogRecord -RecordType "short_file_overhead" -Data ([PSCustomObject]@{
        DurationSeconds = [double]$info.Duration
        FillRatio = [double]$winner.Ratio
        FillGate = $fillGate
        VideoPayloadBytes = [long]$winner.VideoPayloadBytes
        AudioPayloadBytes = [long]$winner.AudioPayloadBytes
        MuxOverheadBytes = [long]$winner.MuxOverheadBytes
      })
  }

  Write-Host ""
  Write-Host "Done."
  Write-Host "Output file:      $OutputFile"
  Write-Host "Final size:       $($winner.SizeBytes) bytes ($([math]::Round($winner.SizeBytes / 1MB, 3)) MiB)"
  Write-Host "Chosen width:     $($winner.Plan.Width)"
  Write-Host "Chosen height:    $($winner.Plan.Height)"
  Write-Host "Chosen fps:       $($winner.Plan.Fps)"
  Write-Host "Chosen codec:     $($winner.Plan.CodecProfile.VideoCodec)"
  Write-Host "Encoder backend:  $($winner.Plan.CodecProfile.EncoderBackend)"
  Write-Host "Container:        $($winner.Plan.CodecProfile.Container)"
  Write-Host "Video bitrate:    $($winner.Plan.VideoKbps) kbps"
  Write-Host "Video payload:    $($winner.VideoPayloadBytes) bytes"
  Write-Host "Audio payload:    $($winner.AudioPayloadBytes) bytes"
  Write-Host "Mux overhead:     $($winner.MuxOverheadBytes) bytes"
  Write-Host "Chosen CRF:       $($winner.Plan.Crf)"
  Write-Host "Chosen audio:     $($winner.Plan.AudioPlan.Label)"
  Write-Host "Chosen preset:    $($winner.Plan.Preset)"
  Write-Host "Pixel format:     $($winner.Plan.OutputPixelFormat)"
  Write-Host "VBV mode:         $($winner.Plan.VbvMode)"
  Write-Host "VBV max/buffer:   $(if ($winner.Plan.VbvMode -eq 'Streaming') { "$($winner.Plan.MaxrateKbps)k / $($winner.Plan.BufsizeKbits)k" } else { '(off)' })"
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
  Write-Host "Geometry filter:  $(if ([string]::IsNullOrWhiteSpace($winner.Plan.GeometryVFilter)) { '(none)' } else { $winner.Plan.GeometryVFilter })"
  Write-Host "Preprocess filt:  $(if ([string]::IsNullOrWhiteSpace($winner.Plan.PreprocessVFilter)) { '(none)' } else { $winner.Plan.PreprocessVFilter })"
  Write-Host "Encode filter:    $(if ([string]::IsNullOrWhiteSpace($winner.Plan.EncodeVFilter)) { '(none)' } else { $winner.Plan.EncodeVFilter })"
  Write-Host "Metric ref filt:  $(if ([string]::IsNullOrWhiteSpace($winner.Plan.MetricReferenceVFilter)) { '(none)' } else { $winner.Plan.MetricReferenceVFilter })"
  if ($winner.SearchStats) {
    Write-Host "Probe samples:    $($winner.SearchStats.ProbeSamplesUsed)"
    Write-Host "Previews run:     $($winner.SearchStats.PreviewsRun)"
    Write-Host "Full encodes:     $($winner.SearchStats.FullEncodesRun)"
    Write-Host "Second-stage:     $(if ([string]::IsNullOrWhiteSpace($winner.SearchStats.SecondEncodeReason)) { '(none)' } else { $winner.SearchStats.SecondEncodeReason })"
    Write-Host "Prediction bias:  $('{0:N3}' -f $winner.SearchStats.PredictionBias)"
  }
  if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
    $resultObject = New-CompressorResultObject -Action encode -Info $info -CodecProfile $codecProfile -PolicyProfile $policyProfile -InputPath $inputFull -OutputPath $OutputFile -HardCapBytes ([long]$targetRequestBytes) -WorkingTargetBytes $usableTargetBytes -Winner $winner
    $writtenResultPath = Write-CompressorResultJson -Result $resultObject -Path $ResultJsonPath
    Write-Host "Result JSON:      $writtenResultPath"
    Write-PlanLogRecord -RecordType "result_contract" -Data $resultObject
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
