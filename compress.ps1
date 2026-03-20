[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputFile,

  [Parameter(Mandatory = $true, ParameterSetName = "ByMB")]
  [int]$TargetMB,

  [Parameter(Mandatory = $true, ParameterSetName = "ByBytes")]
  [long]$TargetBytes,

  [ValidateSet("BinaryMiB", "DecimalMB")]
  [string]$TargetUnit = "BinaryMiB",

  [ValidateSet("Fast", "Balanced", "ExtraQuality")]
  [string]$Mode = "Balanced",

  [string]$OutputFile = "",

  [string]$Preset = "",

  [double]$SafetyMarginPercent = 0.995,

  [int]$ProbeSampleSeconds = 6,

  [int]$MaxProbeSamples = 3,

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

function Get-X264PresetRank($preset) {
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

function Get-AspectHeight($srcWidth, $srcHeight, $targetWidth) {
  $raw = [double]$targetWidth * [double]$srcHeight / [double]$srcWidth
  $even = [int]([math]::Round($raw / 2.0) * 2)
  if ($even -lt 2) { $even = 2 }
  return $even
}

function Get-ResolutionCandidates($srcWidth) {
  $all = @(3840, 2560, 1920, 1600, 1440, 1280, 960, 854, 768, 640, 480, 426, 360, 320)
  return $all | Where-Object { $_ -le $srcWidth } | Select-Object -Unique
}

function Get-Bpppf($videoKbps, $width, $height, $fps) {
  if ($width -le 0 -or $height -le 0 -or $fps -le 0 -or $videoKbps -le 0) { return 0.0 }
  return (($videoKbps * 1000.0) / ([double]$width * [double]$height * [double]$fps))
}

function Build-Vf($srcWidth, $targetWidth, $srcFps, $targetFps) {
  $parts = @()

  if ($targetFps -gt 0 -and $srcFps -gt ($targetFps + 0.01)) {
    $parts += ("fps={0}" -f $targetFps)
  }

  if ($targetWidth -lt $srcWidth) {
    $parts += ("scale={0}:-2:flags=lanczos" -f $targetWidth)
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

  if ($Info.AudioCodec -eq "aac" -and $Info.AudioBitrateKbps) {
    foreach ($kbps in $baseList) {
      if ($Info.AudioBitrateKbps -le $kbps) {
        $estimatedBytes = [long][math]::Floor(($Info.AudioBitrateKbps * 1000.0 / 8.0) * $Duration)
        $plans.Add([PSCustomObject]@{
            Mode           = "copy"
            Kbps           = $null
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
        Mode           = "aac"
        Kbps           = $kbps
        Label          = ("AAC {0}k" -f $kbps)
        EstimatedBytes = $estimatedBytes
        Rank           = $rank
      })
    $rank--
  }

  if ($Mode -eq "Fast" -or $TotalKbps -lt 175) {
    $plans.Add([PSCustomObject]@{
        Mode           = "mute"
        Kbps           = $null
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
  $fractions = switch ($maxSamples) {
    1 { @(0.50) }
    2 { @(0.30, 0.70) }
    default { @(0.18, 0.50, 0.82) }
  }

  $count = [math]::Min($fractions.Count, $maxSamples)
  $offsets = foreach ($f in $fractions[0..($count - 1)]) {
    [math]::Round($usableEnd * $f, 3)
  }

  return $offsets | Select-Object -Unique
}

function Invoke-CrfProbeSeries {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
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

  foreach ($offset in $Offsets) {
    $idx++
    $outPath = Join-Path $TempDir ("probe_{0}_{1}.mp4" -f $Name, $idx)

    $vf = @()
    if ($ProbeFps -gt 0 -and $Info.Fps -gt ($ProbeFps + 0.01)) { $vf += ("fps={0}" -f $ProbeFps) }
    if ($ProbeWidth -lt $Info.Width) { $vf += ("scale={0}:-2:flags=bicubic" -f $ProbeWidth) }
    $vfArg = ($vf -join ",")

    $args = @("-y", "-ss", "$offset", "-t", "$SampleSeconds", "-i", $InputPath)
    if (-not [string]::IsNullOrWhiteSpace($vfArg)) { $args += @("-vf", $vfArg) }
    $args += @(
      "-an",
      "-c:v", "libx264",
      "-preset", $ProbePreset,
      "-crf", "$ProbeCrf",
      "-movflags", "+faststart",
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
    [int]$MaxSamples = 3
  )

  $detailProbeWidth = if ($Info.Width -ge 1280) { 480 } elseif ($Info.Width -ge 854) { 426 } else { [math]::Min($Info.Width, 360) }
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

function Get-WidthPlanCandidates {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][int]$TargetFps,
    [Parameter(Mandatory = $true)][int]$VideoKbps,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $widths = Get-ResolutionCandidates -srcWidth $Info.Width | Sort-Object -Descending
  $targetBpppf = Get-ReferenceBpppfForComplexity -bucket $Probe.DetailBucket -mode $Mode
  $targetPixels = [double]$VideoKbps * 1000.0 / ([double]$TargetFps * $targetBpppf)
  $expectedWidth = [int][math]::Round([math]::Sqrt($targetPixels * ([double]$Info.Width / [double]$Info.Height)))
  $expectedWidth = [int][math]::Max(320, [math]::Min($Info.Width, $expectedWidth))
  $scored = New-Object System.Collections.Generic.List[object]

  foreach ($w in $widths) {
    $h = Get-AspectHeight -srcWidth $Info.Width -srcHeight $Info.Height -targetWidth $w
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
        NearTarget    = ($widthRatio -ge 0.82 -and $widthRatio -le 1.18)
      })
  }

  $keepers = @()
  $bestNearTarget = $scored | Where-Object { $_.NearTarget } | Sort-Object Score -Descending | Select-Object -First 1

  if ($bestNearTarget) {
    $keepers += $bestNearTarget

    $justBelow = $scored | Where-Object { $_.Width -lt $bestNearTarget.Width } | Sort-Object Width -Descending | Select-Object -First 1
    if ($justBelow) { $keepers += $justBelow }

    $justAbove = $scored | Where-Object { $_.Width -gt $bestNearTarget.Width } | Sort-Object Width | Select-Object -First 1
    if ($justAbove) { $keepers += $justAbove }
  }
  else {
    $keepers += ($scored | Sort-Object Score -Descending | Select-Object -First 3)
  }

  if ($Mode -eq "ExtraQuality") {
    $keepers += ($scored | Sort-Object Score -Descending | Select-Object -First 6)
  }
  elseif ($Mode -eq "Balanced") {
    $keepers += ($scored | Sort-Object Score -Descending | Select-Object -First 5)
  }
  else {
    $keepers += ($scored | Sort-Object Score -Descending | Select-Object -First 2)
  }

  return $keepers | Sort-Object Width -Descending -Unique
}

function Get-MuxReserveBytes($targetBytes, $mode) {
  switch ($mode) {
    "Fast"         { return [long][math]::Floor($targetBytes * 0.012) }
    "Balanced"     { return [long][math]::Floor($targetBytes * 0.006) }
    "ExtraQuality" { return [long][math]::Floor($targetBytes * 0.005) }
  }
}

function New-EncodePlan {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height,
    [Parameter(Mandatory = $true)][int]$Fps,
    [Parameter(Mandatory = $true)]$AudioPlan
  )

  $muxReserve = Get-MuxReserveBytes -targetBytes $TargetBytes -mode $Mode
  $usableVideoBytes = $TargetBytes - $AudioPlan.EstimatedBytes - $muxReserve
  if ($usableVideoBytes -lt 25000) { return $null }

  $videoKbps = [int][math]::Floor((($usableVideoBytes * 8.0) / $Info.Duration) / 1000.0)
  if ($videoKbps -lt 40) { return $null }

  $vf = Build-Vf -srcWidth $Info.Width -targetWidth $Width -srcFps $Info.Fps -targetFps $Fps
  $bpppf = Get-Bpppf -videoKbps $videoKbps -width $Width -height $Height -fps $Fps
  $totalBudgetKbps = (($TargetBytes * 8.0) / $Info.Duration) / 1000.0
  $targetBpppf = Get-ReferenceBpppfForComplexity -bucket $Probe.DetailBucket -mode $Mode
  $targetPixels = [double]$videoKbps * 1000.0 / ([double]$Fps * $targetBpppf)
  $expectedWidth = [int][math]::Round([math]::Sqrt($targetPixels * ([double]$Info.Width / [double]$Info.Height)))
  $expectedWidth = [int][math]::Max(320, [math]::Min($Info.Width, $expectedWidth))
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
    AudioPlan   = $AudioPlan
    TargetBytes = $TargetBytes
    Preset      = $Preset
    Mode        = $Mode
    Bpppf       = $bpppf
    TargetBpppf = $targetBpppf
    ExpectedWidth = $expectedWidth
    WidthRatio    = $widthRatio
    DetailBucket = $Probe.DetailBucket
    MotionBucket = $Probe.MotionBucket
    Score       = $score
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

function Invoke-EncodePassOne {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$PassLogPath
  )

  $videoRate = ("{0}k" -f $Plan.VideoKbps)
  $bufSize = ("{0}k" -f ([int][math]::Max($Plan.VideoKbps * 2, 100)))
  $maxRate = $videoRate

  $commonVideo = @("-c:v", "libx264", "-preset", $Plan.Preset, "-b:v", $videoRate, "-maxrate", $maxRate, "-bufsize", $bufSize)
  if (-not [string]::IsNullOrWhiteSpace($Plan.VFilter)) { $commonVideo = @("-vf", $Plan.VFilter) + $commonVideo }

  $pass1 = @("-y", "-i", $InputPath) + $commonVideo + @("-pass", "1", "-passlogfile", $PassLogPath, "-an", "-f", "mp4", "NUL")
  [void](Invoke-Tool -Exe "ffmpeg" -Args $pass1)
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
  $videoRate = ("{0}k" -f $Plan.VideoKbps)
  $bufSize = ("{0}k" -f ([int][math]::Max($Plan.VideoKbps * 2, 100)))
  $maxRate = $videoRate

  $commonVideo = @("-c:v", "libx264", "-preset", $Plan.Preset, "-b:v", $videoRate, "-maxrate", $maxRate, "-bufsize", $bufSize)
  if (-not [string]::IsNullOrWhiteSpace($Plan.VFilter)) { $commonVideo = @("-vf", $Plan.VFilter) + $commonVideo }

  if ($TwoPass) {
    if ($ownsPassLog) {
      Invoke-EncodePassOne -InputPath $InputPath -Plan $Plan -PassLogPath $passlog
    }

    $pass2 = @("-y", "-i", $InputPath) + $commonVideo + @("-pass", "2", "-passlogfile", $passlog, "-movflags", "+faststart")

    switch ($Plan.AudioPlan.Mode) {
      "copy" { $pass2 += @("-c:a", "copy") }
      "aac"  { $pass2 += @("-c:a", "aac", "-b:a", ("{0}k" -f $Plan.AudioPlan.Kbps)) }
      "mute" { $pass2 += "-an" }
      default { throw "Unknown audio mode: $($Plan.AudioPlan.Mode)" }
    }

    $pass2 += $OutputPath
    [void](Invoke-Tool -Exe "ffmpeg" -Args $pass2)
  }
  else {
    $args = @("-y", "-i", $InputPath) + $commonVideo + @("-movflags", "+faststart")

    switch ($Plan.AudioPlan.Mode) {
      "copy" { $args += @("-c:a", "copy") }
      "aac"  { $args += @("-c:a", "aac", "-b:a", ("{0}k" -f $Plan.AudioPlan.Kbps)) }
      "mute" { $args += "-an" }
      default { throw "Unknown audio mode: $($Plan.AudioPlan.Mode)" }
    }

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
  switch ($mode) {
    "Fast" {
      return [PSCustomObject]@{
        Enabled       = $false
        SampleSeconds = 0
        MaxSamples    = 0
        PreviewPreset = ""
        Finalists     = 0
      }
    }

    "Balanced" {
      return [PSCustomObject]@{
        Enabled       = $true
        SampleSeconds = if ($duration -le 45) { 4 } else { 5 }
        MaxSamples    = 2
        PreviewPreset = "veryfast"
        Finalists     = 3
      }
    }

    "ExtraQuality" {
      return [PSCustomObject]@{
        Enabled       = $true
        SampleSeconds = 6
        MaxSamples    = 3
        PreviewPreset = "fast"
        Finalists     = 5
      }
    }
  }
}

function Get-PlanKey($Plan) {
  $audioKey = switch ($Plan.AudioPlan.Mode) {
    "aac"  { "aac:$($Plan.AudioPlan.Kbps)" }
    "copy" { "copy" }
    "mute" { "mute" }
    default { [string]$Plan.AudioPlan.Mode }
  }

  return ("{0}x{1}@{2}|v={3}|a={4}|p={5}" -f $Plan.Width, $Plan.Height, $Plan.Fps, $Plan.VideoKbps, $audioKey, $Plan.Preset)
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
      if (Test-IsBetterResult -Candidate $result -Current $ordered[$i]) {
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
  switch ($mode) {
    "Fast"         { return 0.985 }
    "Balanced"     { return 0.995 }
    "ExtraQuality" { return 0.998 }
  }
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

function Get-PlanPreviewResult {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$PreviewPreset,
    [Parameter(Mandatory = $true)][int]$SampleSeconds,
    [Parameter(Mandatory = $true)][int]$MaxSamples
  )

  $offsets = Get-SampleOffsets -duration $Info.Duration -sampleLength $SampleSeconds -maxSamples $MaxSamples
  if (-not $offsets -or $offsets.Count -eq 0) {
    return $null
  }

  $segmentBytes = New-Object System.Collections.Generic.List[double]
  $idx = 0
  $videoRate = ("{0}k" -f $Plan.VideoKbps)
  $bufSize = ("{0}k" -f ([int][math]::Max($Plan.VideoKbps * 2, 100)))

  foreach ($offset in $offsets) {
    $idx++
    $outPath = Join-Path $TempDir ("preview_{0}_{1}_{2}_{3}.mp4" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $idx)
    $args = @("-y", "-ss", "$offset", "-t", "$SampleSeconds", "-i", $InputPath)

    if (-not [string]::IsNullOrWhiteSpace($Plan.VFilter)) {
      $args += @("-vf", $Plan.VFilter)
    }

    $args += @(
      "-an",
      "-c:v", "libx264",
      "-preset", $PreviewPreset,
      "-b:v", $videoRate,
      "-maxrate", $videoRate,
      "-bufsize", $bufSize,
      $outPath
    )

    [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
    $segmentBytes.Add([double](Get-Item $outPath).Length)
    Remove-Item $outPath -Force -ErrorAction SilentlyContinue
  }

  $avgSegmentBytes = ($segmentBytes | Measure-Object -Average).Average
  $predictedVideoBytes = [double]$avgSegmentBytes * ([double]$Info.Duration / [double]$SampleSeconds)
  $predictedTotalBytes = [long][math]::Floor($predictedVideoBytes + [double]$Plan.AudioPlan.EstimatedBytes + [double](Get-MuxReserveBytes -targetBytes $Plan.TargetBytes -mode $Plan.Mode))
  $predictedRatio = $predictedTotalBytes / [double]$Plan.TargetBytes

  return [PSCustomObject]@{
    Success   = ($predictedTotalBytes -gt 0)
    SizeBytes = $predictedTotalBytes
    Path      = $null
    Plan      = $Plan.PSObject.Copy()
    Ratio     = $predictedRatio
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

  $strategy = Get-PreviewStrategyForMode -mode $Mode -duration $Info.Duration
  $candidatePlans = @($Plans)

  if (-not $strategy.Enabled -or $candidatePlans.Count -le $strategy.Finalists) {
    return $candidatePlans
  }

  $previewResults = New-Object System.Collections.Generic.List[object]
  $previewed = 0
  foreach ($plan in $candidatePlans) {
    $previewed++
    Write-Host ("Previewing plan {0}/{1}: {2}x{3} @{4}fps | v={5}k | a={6} | preview preset={7}" -f $previewed, $candidatePlans.Count, $plan.Width, $plan.Height, $plan.Fps, $plan.VideoKbps, $plan.AudioPlan.Label, $strategy.PreviewPreset)
    $preview = Get-PlanPreviewResult `
      -Info $Info `
      -InputPath $InputPath `
      -TempDir $TempDir `
      -Plan $plan `
      -PreviewPreset $strategy.PreviewPreset `
      -SampleSeconds $strategy.SampleSeconds `
      -MaxSamples $strategy.MaxSamples

    if ($preview -and $preview.Success) {
      [void]$previewResults.Add($preview)
    }
  }

  if ($previewResults.Count -eq 0) {
    return $candidatePlans
  }

  $topPreview = Get-TopResultsByPreference -Results $previewResults -Count $strategy.Finalists
  $selectedPlans = New-Object System.Collections.Generic.List[object]
  $seenKeys = New-Object System.Collections.Generic.HashSet[string]

  foreach ($seedPlan in ($candidatePlans | Select-Object -First 1)) {
    $seedKey = Get-PlanKey -Plan $seedPlan
    if ($seenKeys.Add($seedKey)) {
      [void]$selectedPlans.Add($seedPlan)
    }
  }

  foreach ($preview in $topPreview) {
    $key = Get-PlanKey -Plan $preview.Plan
    if ($seenKeys.Add($key)) {
      [void]$selectedPlans.Add($preview.Plan)
    }
  }

  $selectedSummary = $selectedPlans | ForEach-Object {
    "{0}x{1}@{2}" -f $_.Width, $_.Height, $_.Fps
  }
  Write-Host ("Finalists:        {0}" -f ($selectedSummary -join ", "))

  return @($selectedPlans.ToArray())
}

function Try-PlanWithAdjustments {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)]$AllAudioPlans
  )

  $twoPass = ($Plan.Mode -ne "Fast")
  $tries = switch ($Plan.Mode) {
    "Fast"         { 2 }
    "Balanced"     { 5 }
    "ExtraQuality" { 7 }
  }

  $workingPlan = $Plan.PSObject.Copy()
  $bestUnder = $null
  $lowerBound = $null
  $upperBound = $null
  $seenRates = New-Object System.Collections.Generic.HashSet[int]
  $closeEnoughRatio = Get-CloseEnoughRatioForMode -mode $workingPlan.Mode
  $sharedPassLog = $null

  try {
    if ($twoPass) {
      $sharedPassLog = Join-Path $TempDir ("ffpass_shared_{0}" -f ([guid]::NewGuid().ToString("N")))
      Invoke-EncodePassOne -InputPath $InputPath -Plan $workingPlan -PassLogPath $sharedPassLog
    }

    for ($i = 1; $i -le $tries; $i++) {
      if (-not $seenRates.Add([int]$workingPlan.VideoKbps)) {
        break
      }

      $tempOut = Join-Path $TempDir ("candidate_{0}_{1}_{2}_{3}.mp4" -f $workingPlan.Width, $workingPlan.Fps, $workingPlan.VideoKbps, $i)
      $size = Encode-Plan -InputPath $InputPath -OutputPath $tempOut -Plan $workingPlan -TempDir $TempDir -TwoPass $twoPass -PassLogPath $sharedPassLog

      $ratio = $size / [double]$workingPlan.TargetBytes
      Write-Host ("Plan try {0}: {1}x{2} @{3}fps | v={4}k | a={5} | size={6} bytes ({7:P1})" -f $i, $workingPlan.Width, $workingPlan.Height, $workingPlan.Fps, $workingPlan.VideoKbps, $workingPlan.AudioPlan.Label, $size, $ratio)

      if ($size -le $workingPlan.TargetBytes) {
        $candidate = [PSCustomObject]@{
          Success   = $true
          SizeBytes = $size
          Path      = $tempOut
          Plan      = $workingPlan.PSObject.Copy()
          Ratio     = $ratio
        }

        if (Test-IsBetterPlanAttempt -Candidate $candidate -Current $bestUnder) {
          if ($bestUnder -and $bestUnder.Path -and (Test-Path $bestUnder.Path)) {
            Remove-Item $bestUnder.Path -Force -ErrorAction SilentlyContinue
          }
          $bestUnder = $candidate
        }
        else {
          Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
        }

        if (($null -eq $lowerBound) -or ($size -gt $lowerBound.SizeBytes)) {
          $lowerBound = [PSCustomObject]@{
            VideoKbps = [int]$workingPlan.VideoKbps
            SizeBytes = [long]$size
          }
        }

        $isCloseEnough = ($ratio -ge $closeEnoughRatio)

        $isBracketTight = ($lowerBound -and $upperBound -and (([int]$upperBound.VideoKbps - [int]$lowerBound.VideoKbps) -le 8))

        if ($isCloseEnough -or $isBracketTight) {
          break
        }
      }
      else {
        if ($tempOut -and (Test-Path $tempOut)) {
          Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
        }

        if (($null -eq $upperBound) -or ($size -lt $upperBound.SizeBytes)) {
          $upperBound = [PSCustomObject]@{
            VideoKbps = [int]$workingPlan.VideoKbps
            SizeBytes = [long]$size
          }
        }
      }

      if ($i -ge $tries) { break }

      $newRate = Get-NextVideoKbpsGuess `
        -Mode $workingPlan.Mode `
        -TargetBytes $workingPlan.TargetBytes `
        -CurrentVideoKbps $workingPlan.VideoKbps `
        -CurrentSizeBytes $size `
        -LowerBound $lowerBound `
        -UpperBound $upperBound

      if ($newRate -lt 35 -or $newRate -eq $workingPlan.VideoKbps) {
        break
      }

      if ($lowerBound -and $newRate -le [int]$lowerBound.VideoKbps) {
        $newRate = [int]$lowerBound.VideoKbps + 1
      }
      if ($upperBound -and $newRate -ge [int]$upperBound.VideoKbps) {
        $newRate = [int]$upperBound.VideoKbps - 1
      }

      if ($newRate -lt 35 -or $seenRates.Contains($newRate)) {
        break
      }

      $workingPlan.VideoKbps = $newRate
    }
  }
  finally {
    if ($sharedPassLog) {
      Remove-PassLogFiles -PassLogPath $sharedPassLog
    }
  }

  if ($bestUnder) {
    return $bestUnder
  }

  return [PSCustomObject]@{
    Success   = $false
    SizeBytes = 0
    Path      = $null
    Plan      = $workingPlan
    Ratio     = 0.0
  }
}

function Get-PresetCandidatesForPlan {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$BasePreset,
    [Parameter(Mandatory = $true)][bool]$PresetWasExplicit,
    [Parameter(Mandatory = $true)][int]$PlanIndex
  )

  if ($PresetWasExplicit) {
    return @($BasePreset)
  }

  switch ($Mode) {
    "ExtraQuality" {
      $candidates = @()

      if ($PlanIndex -le 2 -and (Get-X264PresetRank $BasePreset) -lt (Get-X264PresetRank "slower")) {
        $candidates += "slower"
      }

      $candidates += $BasePreset
      return $candidates | Select-Object -Unique
    }

    default {
      return @($BasePreset)
    }
  }
}

function Get-PlanList {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Preset
  )

  $totalKbps = (($TargetBytes * 8.0) / $Info.Duration) / 1000.0
  $fpsCandidates = Get-TargetFpsCandidates -srcFps $Info.Fps -mode $Mode -duration $Info.Duration -totalKbps $totalKbps -motionBucket $Probe.MotionBucket -detailBucket $Probe.DetailBucket
  $audioCandidates = Get-AudioPlanCandidates -Info $Info -Mode $Mode -TotalKbps $totalKbps -Duration $Info.Duration -ProbeBucket $Probe.DetailBucket

  $plans = New-Object System.Collections.Generic.List[object]

  foreach ($fps in $fpsCandidates) {
    $seedAudio = $audioCandidates | Select-Object -First 1
    $usableVideoKbps = [int][math]::Floor(((($TargetBytes - $seedAudio.EstimatedBytes - (Get-MuxReserveBytes -targetBytes $TargetBytes -mode $Mode)) * 8.0) / $Info.Duration) / 1000.0)
    if ($usableVideoKbps -lt 40) { continue }

    $widthCandidates = Get-WidthPlanCandidates -Info $Info -Probe $Probe -TargetFps $fps -VideoKbps $usableVideoKbps -Mode $Mode

    foreach ($w in $widthCandidates) {
      foreach ($a in $audioCandidates) {
        $plan = New-EncodePlan `
          -Info $Info `
          -Probe $Probe `
          -Mode $Mode `
          -TargetBytes $TargetBytes `
          -Preset $Preset `
          -Width $w.Width `
          -Height $w.Height `
          -Fps $fps `
          -AudioPlan $a

        if ($null -ne $plan) {
          $plans.Add($plan)
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

function Get-PlanPreferenceTuple {
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
        [int]$plan.Score,
        [int]$plan.Fps,
        $widthFitScore,
        $fillScore,
        [int]$audioRank,
        [int]$plan.VideoKbps
      )
    }

    "Balanced" {
      return @(
        [int]$plan.Score,
        $fillScore,
        [int]$audioRank,
        [int]$plan.Fps,
        $widthFitScore,
        [int]$plan.VideoKbps
      )
    }

    "ExtraQuality" {
      $presetRank = Get-X264PresetRank -preset $plan.Preset
      return @(
        [int]$plan.Score,
        [int]$presetRank,
        $fillScore,
        [int]$audioRank,
        [int]$plan.Fps,
        $widthFitScore,
        [int]$plan.VideoKbps
      )
    }
  }
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

function Get-BestResult {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][bool]$PresetWasExplicit
  )

  $planBundle = Get-PlanList -Info $Info -Probe $Probe -TargetBytes $TargetBytes -Mode $Mode -Preset $Preset
  $plans = $planBundle.Plans
  $audioCandidates = $planBundle.AudioCandidates

  if (-not $plans -or $plans.Count -eq 0) {
    throw "No viable encode plans were generated."
  }

  $maxPlans = switch ($Mode) {
    "Fast"         { 2 }
    "Balanced"     { 6 }
    "ExtraQuality" { 10 }
  }

  $candidatePlans = @($plans | Select-Object -First $maxPlans)
  $finalists = Get-PlanFinalists -Info $Info -Plans $candidatePlans -InputPath $InputPath -TempDir $TempDir -Mode $Mode

  $bestUnder = $null
  $tested = 0

  foreach ($plan in $finalists) {
    $tested++
    $presetCandidates = Get-PresetCandidatesForPlan -Mode $Mode -BasePreset $Preset -PresetWasExplicit $PresetWasExplicit -PlanIndex $tested

    foreach ($presetCandidate in $presetCandidates) {
      $planForPreset = $plan.PSObject.Copy()
      $planForPreset.Preset = $presetCandidate

      Write-Host ("Testing plan {0}/{1}: {2}x{3} @{4}fps | v={5}k | a={6} | detail={7} | motion={8} | bpppf={9:N4} | preset={10}" -f $tested, $finalists.Count, $planForPreset.Width, $planForPreset.Height, $planForPreset.Fps, $planForPreset.VideoKbps, $planForPreset.AudioPlan.Label, $planForPreset.DetailBucket, $planForPreset.MotionBucket, $planForPreset.Bpppf, $planForPreset.Preset)

      $result = Try-PlanWithAdjustments -InputPath $InputPath -Plan $planForPreset -TempDir $TempDir -AllAudioPlans $audioCandidates

      if ($result.Success) {
        if ($null -eq $bestUnder) {
          $bestUnder = $result
        }
        else {
          if (Test-IsBetterResult -Candidate $result -Current $bestUnder) {
            if ($bestUnder.Path -and (Test-Path $bestUnder.Path)) {
              Remove-Item $bestUnder.Path -Force -ErrorAction SilentlyContinue
            }
            $bestUnder = $result
          }
          else {
            if ($result.Path -and (Test-Path $result.Path)) {
              Remove-Item $result.Path -Force -ErrorAction SilentlyContinue
            }
          }
        }
      }
    }
  }

  return $bestUnder
}

Require-Tool "ffmpeg"
Require-Tool "ffprobe"

if (-not (Test-Path $InputFile)) {
  throw "Input file not found: $InputFile"
}

$inputFull = (Resolve-Path $InputFile).Path
$info = Get-ProbeInfo -path $inputFull

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
  $dir = Split-Path $inputFull -Parent
  $base = [System.IO.Path]::GetFileNameWithoutExtension($inputFull)
  if ($PSCmdlet.ParameterSetName -eq "ByBytes") {
    $OutputFile = Join-Path $dir ("{0}_{1}bytes.mp4" -f $base, $TargetBytes)
  }
  else {
    $OutputFile = Join-Path $dir ("{0}_{1}mb.mp4" -f $base, $TargetMB)
  }
}

$presetWasExplicit = -not [string]::IsNullOrWhiteSpace($Preset)
if ([string]::IsNullOrWhiteSpace($Preset)) {
  $Preset = Get-DefaultPresetForMode -mode $Mode
}

$targetRequestBytes = if ($PSCmdlet.ParameterSetName -eq "ByBytes") {
  [double]$TargetBytes
}
else {
  switch ($TargetUnit) {
    "BinaryMiB" { [double]($TargetMB * 1MB) }
    "DecimalMB" { [double]($TargetMB * 1000 * 1000) }
  }
}
$usableTargetBytes = [long][math]::Floor($targetRequestBytes * $SafetyMarginPercent)
$totalKbps = (($usableTargetBytes * 8.0) / $info.Duration) / 1000.0

Write-Host "Input:            $inputFull"
Write-Host "Duration:         $([math]::Round($info.Duration, 2)) s"
Write-Host "Source:           $($info.Width)x$($info.Height) @ $([math]::Round($info.Fps, 3)) fps"
Write-Host "Video codec:      $($info.VideoCodec)"
Write-Host "Video bitrate:    $(if ($info.VideoBitrateKbps) { "$($info.VideoBitrateKbps) kbps" } else { 'unknown' })"
Write-Host "Audio codec:      $(if ($info.HasAudio) { $info.AudioCodec } else { 'none' })"
Write-Host "Audio bitrate:    $(if ($info.AudioBitrateKbps) { "$($info.AudioBitrateKbps) kbps" } else { 'unknown' })"
if ($PSCmdlet.ParameterSetName -eq "ByBytes") {
  Write-Host "Target size:      $TargetBytes bytes"
}
else {
  Write-Host "Target size:      $TargetMB $TargetUnit"
}
Write-Host "Usable bytes:     $usableTargetBytes"
Write-Host "Total budget:     $([math]::Round($totalKbps)) kbps"
Write-Host "Mode:             $Mode"
Write-Host "Preset:           $Preset"
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
    -MaxSamples $MaxProbeSamples

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
  Write-Host ""

  $winner = Get-BestResult `
    -Info $info `
    -Probe $probe `
    -InputPath $inputFull `
    -TempDir $tempDir `
    -TargetBytes $usableTargetBytes `
    -Mode $Mode `
    -Preset $Preset `
    -PresetWasExplicit $presetWasExplicit

  if (-not $winner -or -not $winner.Success) {
    throw "Could not get under target size with the current probe + bitrate-targeting plan."
  }

  Copy-Item $winner.Path $OutputFile -Force

  Write-Host ""
  Write-Host "Done."
  Write-Host "Output file:      $OutputFile"
  Write-Host "Final size:       $($winner.SizeBytes) bytes ($([math]::Round($winner.SizeBytes / 1MB, 3)) MiB)"
  Write-Host "Chosen width:     $($winner.Plan.Width)"
  Write-Host "Chosen height:    $($winner.Plan.Height)"
  Write-Host "Chosen fps:       $($winner.Plan.Fps)"
  Write-Host "Video bitrate:    $($winner.Plan.VideoKbps) kbps"
  Write-Host "Chosen audio:     $($winner.Plan.AudioPlan.Label)"
  Write-Host "Detail bucket:    $($winner.Plan.DetailBucket)"
  Write-Host "Motion bucket:    $($winner.Plan.MotionBucket)"
  Write-Host "Predicted bpppf:  $('{0:N4}' -f $winner.Plan.Bpppf)"
  Write-Host "Video filter:     $(if ([string]::IsNullOrWhiteSpace($winner.Plan.VFilter)) { '(none)' } else { $winner.Plan.VFilter })"
}
finally {
  if (Test-Path $tempDir) {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  $elapsed = (Get-Date) - $scriptStart
  Write-Host ""
  Write-Host ("Execution time:   {0:hh\:mm\:ss\.fff}" -f $elapsed)
}
