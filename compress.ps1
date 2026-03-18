[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputFile,

  [Parameter(Mandatory = $true)]
  [int]$TargetMB,

  [ValidateSet("Fast", "Balanced", "ExtraQuality")]
  [string]$Mode = "Balanced",

  [string]$OutputFile = "",

  [string]$Preset = "",

  [double]$SafetyMarginPercent = 0.985,

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
    "Fast"         { return "veryfast" }
    "Balanced"     { return "medium" }
    "ExtraQuality" { return "medium" }
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

function Get-TargetFpsCandidates($srcFps, $mode, $duration, $totalKbps, $probeBucket) {
  $roundedSrc = [int][math]::Max(1, [math]::Round($srcFps))
  $list = New-Object System.Collections.Generic.List[int]

  switch ($mode) {
    "Fast" {
      if ($srcFps -gt 50) {
        $list.Add(30)
        if ($totalKbps -lt 500) { $list.Add(24) }
      }
      elseif ($srcFps -gt 30.5) {
        $list.Add(30)
        if ($totalKbps -lt 450) { $list.Add(24) }
      }
      else {
        $list.Add($roundedSrc)
        if ($roundedSrc -gt 24 -and $totalKbps -lt 650) { $list.Add(24) }
      }
    }

    "Balanced" {
      if ($srcFps -gt 50) {
        if (
          (($probeBucket -in @("VeryLow", "Low")) -and $totalKbps -ge 650) -or
          (($probeBucket -eq "Medium") -and $duration -le 90 -and $totalKbps -ge 1600)
        ) {
          $list.Add($roundedSrc)
        }
        $list.Add(30)
        if ($totalKbps -lt 330) { $list.Add(24) }
      }
      elseif ($srcFps -gt 30.5) {
        if (($probeBucket -in @("VeryLow", "Low")) -and $duration -le 90 -and $totalKbps -ge 1200) {
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
        if ($totalKbps -ge 2200) { $list.Add($roundedSrc) }
        $list.Add(30)
        if ($totalKbps -lt 420) { $list.Add(24) }
      }
      elseif ($srcFps -gt 30.5) {
        if ($totalKbps -ge 1500) { $list.Add($roundedSrc) }
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

function Invoke-ComplexityProbe {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Mode,
    [int]$SampleSeconds = 6,
    [int]$MaxSamples = 3
  )

  $probeWidth = if ($Info.Width -ge 1280) { 480 } elseif ($Info.Width -ge 854) { 426 } else { [math]::Min($Info.Width, 360) }
  $probeFps = if ($Info.Fps -gt 30.5) { 24 } else { [int][math]::Max(12, [math]::Round($Info.Fps)) }

  $probeCrf = switch ($Mode) {
    "Fast"         { 32 }
    "Balanced"     { 30 }
    "ExtraQuality" { 28 }
  }

  $probePreset = switch ($Mode) {
    "Fast"         { "ultrafast" }
    "Balanced"     { "veryfast" }
    "ExtraQuality" { "veryfast" }
  }

  $offsets = Get-SampleOffsets -duration $Info.Duration -sampleLength $SampleSeconds -maxSamples $MaxSamples
  $results = New-Object System.Collections.Generic.List[object]
  $idx = 0

  foreach ($offset in $offsets) {
    $idx++
    $outPath = Join-Path $TempDir ("probe_{0}.mp4" -f $idx)

    $vf = @()
    if ($probeFps -gt 0 -and $Info.Fps -gt ($probeFps + 0.01)) { $vf += ("fps={0}" -f $probeFps) }
    if ($probeWidth -lt $Info.Width) { $vf += ("scale={0}:-2:flags=bicubic" -f $probeWidth) }
    $vfArg = ($vf -join ",")

    $args = @("-y", "-ss", "$offset", "-t", "$SampleSeconds", "-i", $InputPath)
    if (-not [string]::IsNullOrWhiteSpace($vfArg)) { $args += @("-vf", $vfArg) }
    $args += @(
      "-an",
      "-c:v", "libx264",
      "-preset", $probePreset,
      "-crf", "$probeCrf",
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

  $bucket = if ($p95ish -lt 120) {
    "VeryLow"
  }
  elseif ($p95ish -lt 190) {
    "Low"
  }
  elseif ($p95ish -lt 300) {
    "Medium"
  }
  elseif ($p95ish -lt 430) {
    "High"
  }
  else {
    "VeryHigh"
  }

  return [PSCustomObject]@{
    ProbeWidth  = $probeWidth
    ProbeFps    = $probeFps
    ProbeCrf    = $probeCrf
    AvgKbps     = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $avgKbps)), [Globalization.CultureInfo]::InvariantCulture)
    PeakishKbps = [double]::Parse(([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $p95ish)), [Globalization.CultureInfo]::InvariantCulture)
    Bucket      = $bucket
    Samples     = $results
  }
}

function Get-MinBpppfForComplexity($bucket, $mode) {
  $base = switch ($bucket) {
    "VeryLow"  { 0.014 }
    "Low"      { 0.018 }
    "Medium"   { 0.024 }
    "High"     { 0.032 }
    "VeryHigh" { 0.042 }
    default    { 0.024 }
  }

  switch ($mode) {
    "Fast"         { return ($base + 0.004) }
    "Balanced"     { return $base }
    "ExtraQuality" { return ($base - 0.002) }
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
  $minBpppf = Get-MinBpppfForComplexity -bucket $Probe.Bucket -mode $Mode
  $scored = New-Object System.Collections.Generic.List[object]

  foreach ($w in $widths) {
    $h = Get-AspectHeight -srcWidth $Info.Width -srcHeight $Info.Height -targetWidth $w
    $bpppf = Get-Bpppf -videoKbps $VideoKbps -width $w -height $h -fps $TargetFps

    $fitPenalty = if ($bpppf -ge $minBpppf) { 0 } else { ($minBpppf - $bpppf) * 1000.0 }
    $score = ($w / 100.0) - $fitPenalty

    $scored.Add([PSCustomObject]@{
        Width      = $w
        Height     = $h
        Bpppf      = $bpppf
        Score      = $score
        MeetsFloor = ($bpppf -ge $minBpppf)
      })
  }

  $keepers = @()
  $bestMeeting = $scored | Where-Object { $_.MeetsFloor } | Sort-Object Width -Descending | Select-Object -First 1

  if ($bestMeeting) {
    $keepers += $bestMeeting

    $justBelow = $scored | Where-Object { $_.Width -lt $bestMeeting.Width } | Sort-Object Width -Descending | Select-Object -First 1
    if ($justBelow) { $keepers += $justBelow }

    $justAbove = $scored | Where-Object { $_.Width -gt $bestMeeting.Width } | Sort-Object Width | Select-Object -First 1
    if ($justAbove) { $keepers += $justAbove }
  }
  else {
    $keepers += ($scored | Sort-Object Score -Descending | Select-Object -First 2)
  }

  if ($Mode -eq "ExtraQuality") {
    $keepers += ($scored | Sort-Object Score -Descending | Select-Object -First 4)
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
    "Fast"         { return [long][math]::Floor($targetBytes * 0.018) }
    "Balanced"     { return [long][math]::Floor($targetBytes * 0.015) }
    "ExtraQuality" { return [long][math]::Floor($targetBytes * 0.012) }
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
  $highFpsRetentionBoost = 0
  if (
    $Mode -eq "Balanced" -and
    $Info.Fps -gt 50 -and
    $Fps -gt 30 -and
    $Info.Duration -le 90 -and
    $Probe.Bucket -in @("VeryLow", "Low", "Medium") -and
    $totalBudgetKbps -ge 900
  ) {
    $highFpsRetentionBoost = $Fps * 300
  }

  $score = switch ($Mode) {
    "Fast" {
      ($Width * 1000) + ($Fps * 35) + ($AudioPlan.Rank * 2)
    }
    "Balanced" {
      ($Width * 25) + ($Fps * 10) + ($AudioPlan.Rank * 6) + ([int]($bpppf * 50000)) + $highFpsRetentionBoost
    }
    "ExtraQuality" {
      ($Width * 300) + ($Fps * 100) + ($AudioPlan.Rank * 6) + ([int]($bpppf * 12000))
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
    ProbeBucket = $Probe.Bucket
    Score       = $score
  }
}

function Encode-Plan {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][bool]$TwoPass
  )

  $passlog = Join-Path $TempDir ("ffpass_{0}" -f ([guid]::NewGuid().ToString("N")))
  $videoRate = ("{0}k" -f $Plan.VideoKbps)
  $bufSize = ("{0}k" -f ([int][math]::Max($Plan.VideoKbps * 2, 100)))
  $maxRate = $videoRate

  $commonVideo = @("-c:v", "libx264", "-preset", $Plan.Preset, "-b:v", $videoRate, "-maxrate", $maxRate, "-bufsize", $bufSize)
  if (-not [string]::IsNullOrWhiteSpace($Plan.VFilter)) { $commonVideo = @("-vf", $Plan.VFilter) + $commonVideo }

  if ($TwoPass) {
    $pass1 = @("-y", "-i", $InputPath) + $commonVideo + @("-pass", "1", "-passlogfile", $passlog, "-an", "-f", "mp4", "NUL")
    [void](Invoke-Tool -Exe "ffmpeg" -Args $pass1)

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
  Get-ChildItem -Path ($passlog + "*") -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  return $size
}

function Get-NextHigherAudioPlan {
  param(
    [Parameter(Mandatory = $true)]$CurrentPlan,
    [Parameter(Mandatory = $true)]$AllAudioPlans
  )

  if ($CurrentPlan.Mode -ne "aac") { return $null }

  $higher = $AllAudioPlans |
    Where-Object { $_.Mode -eq "aac" -and $_.Kbps -gt $CurrentPlan.Kbps } |
    Sort-Object Kbps |
    Select-Object -First 1

  return $higher
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
    "Balanced"     { 3 }
    "ExtraQuality" { 4 }
  }

  $workingPlan = $Plan.PSObject.Copy()

  for ($i = 1; $i -le $tries; $i++) {
    $tempOut = Join-Path $TempDir ("candidate_{0}_{1}_{2}_{3}.mp4" -f $workingPlan.Width, $workingPlan.Fps, $workingPlan.VideoKbps, $i)
    $size = Encode-Plan -InputPath $InputPath -OutputPath $tempOut -Plan $workingPlan -TempDir $TempDir -TwoPass $twoPass

    $ratio = $size / [double]$workingPlan.TargetBytes
    Write-Host ("Plan try {0}: {1}x{2} @{3}fps | v={4}k | a={5} | size={6} bytes ({7:P1})" -f $i, $workingPlan.Width, $workingPlan.Height, $workingPlan.Fps, $workingPlan.VideoKbps, $workingPlan.AudioPlan.Label, $size, $ratio)

    if ($size -le $workingPlan.TargetBytes) {
      $canRefill = ($i -lt $tries) -and ($workingPlan.Mode -ne "Fast") -and ($ratio -lt 0.96)

      if ($canRefill) {
        $refilled = $false

        if ($workingPlan.ProbeBucket -in @("VeryLow", "Low")) {
          $higherAudio = Get-NextHigherAudioPlan -CurrentPlan $workingPlan.AudioPlan -AllAudioPlans $AllAudioPlans
          if ($higherAudio) {
            $currentAudioKbps = if ($workingPlan.AudioPlan.Kbps) { [int]$workingPlan.AudioPlan.Kbps } else { 0 }
            $audioDelta = [int]$higherAudio.Kbps - $currentAudioKbps

            if ($audioDelta -gt 0 -and ($workingPlan.VideoKbps - $audioDelta) -ge 80) {
              Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
              $workingPlan.AudioPlan = $higherAudio
              $workingPlan.VideoKbps = [int]($workingPlan.VideoKbps - $audioDelta)
              $refilled = $true
            }
          }
        }

        if (-not $refilled) {
          $bumpFactor = switch ($workingPlan.Mode) {
            "Balanced"     { 1.08 }
            "ExtraQuality" { 1.10 }
            default        { 1.00 }
          }

          $bumped = [int][math]::Floor($workingPlan.VideoKbps * $bumpFactor)
          if ($bumped -gt $workingPlan.VideoKbps) {
            Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
            $workingPlan.VideoKbps = $bumped
            $refilled = $true
          }
        }

        if ($refilled) {
          continue
        }
      }

      return [PSCustomObject]@{
        Success   = $true
        SizeBytes = $size
        Path      = $tempOut
        Plan      = $workingPlan
        Ratio     = $ratio
      }
    }

    Remove-Item $tempOut -Force -ErrorAction SilentlyContinue

    $shrinkFactor = if ($ratio -gt 1.25) { 0.86 } elseif ($ratio -gt 1.10) { 0.91 } else { 0.96 }
    $newRate = [int][math]::Floor($workingPlan.VideoKbps * $shrinkFactor)

    if ($newRate -ge $workingPlan.VideoKbps -or $newRate -lt 35) {
      break
    }

    $workingPlan.VideoKbps = $newRate
  }

  return [PSCustomObject]@{
    Success   = $false
    SizeBytes = 0
    Path      = $null
    Plan      = $workingPlan
    Ratio     = 0.0
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
  $fpsCandidates = Get-TargetFpsCandidates -srcFps $Info.Fps -mode $Mode -duration $Info.Duration -totalKbps $totalKbps -probeBucket $Probe.Bucket
  $audioCandidates = Get-AudioPlanCandidates -Info $Info -Mode $Mode -TotalKbps $totalKbps -Duration $Info.Duration -ProbeBucket $Probe.Bucket

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

  switch ($plan.Mode) {
    "Fast" {
      return @(
        [int]$plan.Width,
        [int]$plan.Fps,
        [int]$audioRank,
        [double]$Result.Ratio
      )
    }

    "Balanced" {
      return @(
        [int]$plan.Score,
        [int]$plan.Width,
        [int]$plan.Fps,
        [int]$audioRank,
        [int](1000 - [math]::Abs([math]::Round((1.0 - $Result.Ratio) * 1000)))
      )
    }

    "ExtraQuality" {
      return @(
        [int]$plan.Width,
        [int]$plan.Fps,
        [int]$audioRank,
        [double]([math]::Round($Result.Ratio * 1000))
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
    [Parameter(Mandatory = $true)][string]$Preset
  )

  $planBundle = Get-PlanList -Info $Info -Probe $Probe -TargetBytes $TargetBytes -Mode $Mode -Preset $Preset
  $plans = $planBundle.Plans
  $audioCandidates = $planBundle.AudioCandidates

  if (-not $plans -or $plans.Count -eq 0) {
    throw "No viable encode plans were generated."
  }

  $maxPlans = switch ($Mode) {
    "Fast"         { 3 }
    "Balanced"     { 6 }
    "ExtraQuality" { 7 }
  }

  $bestUnder = $null
  $tested = 0

  foreach ($plan in ($plans | Select-Object -First $maxPlans)) {
    $tested++
    Write-Host ("Testing plan {0}/{1}: {2}x{3} @{4}fps | v={5}k | a={6} | probe={7} | bpppf={8:N4}" -f $tested, $maxPlans, $plan.Width, $plan.Height, $plan.Fps, $plan.VideoKbps, $plan.AudioPlan.Label, $plan.ProbeBucket, $plan.Bpppf)

    $result = Try-PlanWithAdjustments -InputPath $InputPath -Plan $plan -TempDir $TempDir -AllAudioPlans $audioCandidates

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

      if ($Mode -eq "Fast") {
        break
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
  $OutputFile = Join-Path $dir ("{0}_{1}mb.mp4" -f $base, $TargetMB)
}

if ([string]::IsNullOrWhiteSpace($Preset)) {
  $Preset = Get-DefaultPresetForMode -mode $Mode
}

$targetBytes = [long][math]::Floor($TargetMB * 1000 * 1000 * $SafetyMarginPercent)
$totalKbps = (($targetBytes * 8.0) / $info.Duration) / 1000.0

Write-Host "Input:            $inputFull"
Write-Host "Duration:         $([math]::Round($info.Duration, 2)) s"
Write-Host "Source:           $($info.Width)x$($info.Height) @ $([math]::Round($info.Fps, 3)) fps"
Write-Host "Video codec:      $($info.VideoCodec)"
Write-Host "Video bitrate:    $(if ($info.VideoBitrateKbps) { "$($info.VideoBitrateKbps) kbps" } else { 'unknown' })"
Write-Host "Audio codec:      $(if ($info.HasAudio) { $info.AudioCodec } else { 'none' })"
Write-Host "Audio bitrate:    $(if ($info.AudioBitrateKbps) { "$($info.AudioBitrateKbps) kbps" } else { 'unknown' })"
Write-Host "Target size:      $TargetMB MB"
Write-Host "Usable bytes:     $targetBytes"
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

  Write-Host "Probe width/fps:  $($probe.ProbeWidth)p @ $($probe.ProbeFps) fps"
  Write-Host "Probe CRF:        $($probe.ProbeCrf)"
  Write-Host "Probe avg kbps:   $($probe.AvgKbps)"
  Write-Host "Probe peak-ish:   $($probe.PeakishKbps)"
  Write-Host "Complexity:       $($probe.Bucket)"
  Write-Host ""

  $winner = Get-BestResult `
    -Info $info `
    -Probe $probe `
    -InputPath $inputFull `
    -TempDir $tempDir `
    -TargetBytes $targetBytes `
    -Mode $Mode `
    -Preset $Preset

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
  Write-Host "Probe bucket:     $($winner.Plan.ProbeBucket)"
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
