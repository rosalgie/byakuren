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
    $defaultResult.Samples = @($samples)
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
  $maxBorderRemoved = ($cropX, $cropY, $rightRemoved, $bottomRemoved | Measure-Object -Maximum).Maximum
  $removedAreaRatio = 1.0 - (([double]$cropWidth * [double]$cropHeight) / ([double]$Info.Width * [double]$Info.Height))

  if ($removedAreaRatio -lt 0.04 -and $maxBorderRemoved -lt 6) {
    $defaultResult.Summary = "none"
    $defaultResult.Samples = @($samples)
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
    Samples          = @($samples)
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

    if ($results.Count -ge 2 -and $Mode -in @("Fast", "Balanced")) {
      $sampleMin = ($results | Measure-Object -Property Kbps -Minimum).Minimum
      $sampleMax = ($results | Measure-Object -Property Kbps -Maximum).Maximum
      $sampleAvg = ($results | Measure-Object -Property Kbps -Average).Average
      $spreadRatio = ([double]$sampleMax - [double]$sampleMin) / [double][math]::Max(1.0, $sampleAvg)
      $spreadThreshold = switch ($Mode) {
        "Fast"     { 0.14 }
        "Balanced" { 0.09 }
      }

      if ($spreadRatio -le $spreadThreshold) {
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
    [int]$MaxSamples = 3
  )

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

  $planningWidth = Get-PlanningWidth -Info $Info
  $planningHeight = Get-PlanningHeight -Info $Info
  $targetBpppf = Get-ReferenceBpppfForComplexity -bucket $Probe.DetailBucket -mode $Mode
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
  $bpppf = Get-Bpppf -videoKbps $videoKbps -width $Width -height $Height -fps $Fps
  $totalBudgetKbps = (($TargetBytes * 8.0) / $Info.Duration) / 1000.0
  $targetBpppf = Get-ReferenceBpppfForComplexity -bucket $Probe.DetailBucket -mode $Mode
  $planningWidth = Get-PlanningWidth -Info $Info
  $planningHeight = Get-PlanningHeight -Info $Info
  $expectedWidth = Get-ExpectedWidth -srcWidth $planningWidth -srcHeight $planningHeight -videoKbps $videoKbps -targetFps $Fps -targetBpppf $targetBpppf
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
  $x264Params = Get-AutoX264Params -mode $Mode -totalBudgetKbps $totalBudgetKbps
  $preprocessLabel = if ($UseDenoise) { "mild-denoise" } else { "none" }

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
    TotalBudgetKbps = $totalBudgetKbps
    WidthOrigin = $WidthOrigin
    PreprocessLabel = $preprocessLabel
    UseDenoise = [bool]$UseDenoise
    CropApplied = [bool](Get-ObjectPropertyValue -Object $Info -Name "CropApplied" -DefaultValue $false)
    CropSummary = Get-CropSummary -Info $Info
    X264Params = $x264Params
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

function Get-CommonVideoEncodeArgs {
  param(
    [Parameter(Mandatory = $true)]$Plan
  )

  $videoRate = ("{0}k" -f $Plan.VideoKbps)
  $bufSize = ("{0}k" -f ([int][math]::Max($Plan.VideoKbps * 2, 100)))
  $args = @()

  if (-not [string]::IsNullOrWhiteSpace($Plan.VFilter)) {
    $args += @("-vf", $Plan.VFilter)
  }

  $args += @("-c:v", "libx264", "-preset", $Plan.Preset, "-b:v", $videoRate, "-maxrate", $videoRate, "-bufsize", $bufSize)

  if (-not [string]::IsNullOrWhiteSpace($Plan.X264Params)) {
    $args += @("-x264-params", $Plan.X264Params)
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
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $args = @("-y", "-i", $InputPath, "-c", "copy", "-movflags", "+faststart", $OutputPath)
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
    $args = @("-y", "-i", $InputPath) + $commonVideo

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
        Finalists     = if ($duration -ge 60) { 2 } else { 3 }
      }
    }

    "ExtraQuality" {
      return [PSCustomObject]@{
        Enabled       = $true
        SampleSeconds = 6
        MaxSamples    = 3
        PreviewPreset = "fast"
        Finalists     = if ($duration -ge 180) { 4 } else { 5 }
      }
    }
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
    "copy" { "copy" }
    "mute" { "mute" }
    default { [string]$Plan.AudioPlan.Mode }
  }

  return ("{0}x{1}@{2}|v={3}|a={4}|p={5}|pp={6}|crop={7}" -f $Plan.Width, $Plan.Height, $Plan.Fps, $Plan.VideoKbps, $audioKey, $Plan.Preset, $Plan.PreprocessLabel, [int]$Plan.CropApplied)
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
  switch ($mode) {
    "Fast"         { return 0.985 }
    "Balanced"     { return 0.994 }
    "ExtraQuality" { return 0.998 }
  }
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
  $commonVideo = Get-CommonVideoEncodeArgs -Plan $Plan

  foreach ($offset in $offsets) {
    $idx++
    $outPath = Join-Path $TempDir ("preview_{0}_{1}_{2}_{3}.mp4" -f $Plan.Width, $Plan.Fps, $Plan.VideoKbps, $idx)
    $args = @("-y", "-ss", "$offset", "-t", "$SampleSeconds", "-i", $InputPath)

    $previewVideo = @()
    $skipNextPreset = $false
    for ($i = 0; $i -lt $commonVideo.Count; $i++) {
      if ($skipNextPreset) {
        $skipNextPreset = $false
        continue
      }

      if ($commonVideo[$i] -eq "-preset" -and ($i + 1) -lt $commonVideo.Count) {
        $previewVideo += @("-preset", $PreviewPreset)
        $skipNextPreset = $true
        continue
      }

      $previewVideo += $commonVideo[$i]
    }

    $args += @("-an") + $previewVideo + @($outPath)

    [void](Invoke-Tool -Exe "ffmpeg" -Args $args)
    $segmentBytes.Add([double](Get-Item $outPath).Length)
    Remove-Item $outPath -Force -ErrorAction SilentlyContinue
  }

  $avgSegmentBytes = ($segmentBytes | Measure-Object -Average).Average
  $predictedVideoBytes = [double]$avgSegmentBytes * ([double]$Info.Duration / [double]$SampleSeconds)
  $predictedTotalBytes = [long][math]::Floor($predictedVideoBytes + [double]$Plan.AudioPlan.EstimatedBytes + [double](Get-MuxReserveBytes -targetBytes $Plan.TargetBytes -mode $Plan.Mode))
  $predictedRatio = $predictedTotalBytes / [double]$Plan.TargetBytes

  return [PSCustomObject]@{
    Success    = ($predictedTotalBytes -gt 0)
    SizeBytes  = $predictedTotalBytes
    VideoBytes = [long][math]::Floor($predictedVideoBytes)
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

  $strategy = Get-PreviewStrategyForMode -mode $Mode -duration $Info.Duration
  $candidatePlans = @($Plans)

  if (-not $strategy.Enabled -or $candidatePlans.Count -le $strategy.Finalists) {
    return @(Set-PlanPreviewMetadata -Plans $candidatePlans)
  }

  $previewResults = New-Object System.Collections.Generic.List[object]
  $previewed = 0
  foreach ($plan in $candidatePlans) {
    $previewed++
    Write-Host ("Previewing plan {0}/{1}: {2}x{3} @{4}fps | v={5}k | a={6} | width={7} | pp={8} | preview preset={9}" -f $previewed, $candidatePlans.Count, $plan.Width, $plan.Height, $plan.Fps, $plan.VideoKbps, $plan.AudioPlan.Label, $plan.WidthOrigin, $plan.PreprocessLabel, $strategy.PreviewPreset)
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
  $previewRank = 0

  foreach ($preview in $topPreview) {
    $key = Get-PlanKey -Plan $preview.Plan
    if ($seenKeys.Add($key)) {
      $previewRank++
      $selectedPlan = $preview.Plan.PSObject.Copy()
      $selectedPlan.VideoKbps = Get-PreviewSeedVideoKbps -Plan $selectedPlan -Preview $preview
      $selectedPlan | Add-Member -NotePropertyName PreviewRank -NotePropertyValue $previewRank -Force
      $selectedPlan | Add-Member -NotePropertyName PreviewRatio -NotePropertyValue ([double]$preview.Ratio) -Force
      [void]$selectedPlans.Add($selectedPlan)
    }
  }

  $selectedSummary = $selectedPlans | ForEach-Object {
    "{0}x{1}@{2} ({3}, {4})" -f $_.Width, $_.Height, $_.Fps, $_.WidthOrigin, $_.PreprocessLabel
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

      $presetKey = ($workingPlan.Preset -replace '[^A-Za-z0-9]+', '_')
      $preprocessKey = ($workingPlan.PreprocessLabel -replace '[^A-Za-z0-9]+', '_')
      $tempOut = Join-Path $TempDir ("candidate_{0}_{1}_{2}_{3}_{4}_{5}.mp4" -f $workingPlan.Width, $workingPlan.Fps, $workingPlan.VideoKbps, $presetKey, $preprocessKey, $i)
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
    "Balanced" {
      $candidates = @()

      if ($PlanIndex -le 2 -and (Get-X264PresetRank $BasePreset) -lt (Get-X264PresetRank "slow")) {
        $candidates += "slow"
      }

      $candidates += $BasePreset
      return $candidates | Select-Object -Unique
    }

    "ExtraQuality" {
      $candidates = @()

      if ($PlanIndex -le 3 -and (Get-X264PresetRank $BasePreset) -lt (Get-X264PresetRank "slower")) {
        $candidates += "slower"
      }

      if ($PlanIndex -le 3 -and (Get-X264PresetRank $BasePreset) -lt (Get-X264PresetRank "slow")) {
        $candidates += "slow"
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
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][string]$PreprocessProfile
  )

  $totalKbps = (($TargetBytes * 8.0) / $Info.Duration) / 1000.0
  $fpsCandidates = Get-TargetFpsCandidates -srcFps $Info.Fps -mode $Mode -duration $Info.Duration -totalKbps $totalKbps -motionBucket $Probe.MotionBucket -detailBucket $Probe.DetailBucket
  $audioCandidates = Get-AudioPlanCandidates -Info $Info -Mode $Mode -TotalKbps $totalKbps -Duration $Info.Duration -ProbeBucket $Probe.DetailBucket

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
        [int]$presetRank,
        $previewRankScore,
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps
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
        [int]$presetRank,
        $fillScore,
        [int]$audioRank,
        $widthFitScore,
        [int]$plan.Fps,
        [int]$plan.Width,
        [int]$plan.VideoKbps,
        [int]$plan.Score
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

function Get-BestResult {
  param(
    [Parameter(Mandatory = $true)]$Info,
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][long]$TargetBytes,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][bool]$PresetWasExplicit,
    [Parameter(Mandatory = $true)][string]$PreprocessProfile
  )

  $planBundle = Get-PlanList -Info $Info -Probe $Probe -TargetBytes $TargetBytes -Mode $Mode -Preset $Preset -PreprocessProfile $PreprocessProfile
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

      Write-Host ("Testing plan {0}/{1}: {2}x{3} @{4}fps | v={5}k | a={6} | detail={7} | motion={8} | bpppf={9:N4} | preset={10} | width={11} | pp={12} | crop={13}" -f $tested, $finalists.Count, $planForPreset.Width, $planForPreset.Height, $planForPreset.Fps, $planForPreset.VideoKbps, $planForPreset.AudioPlan.Label, $planForPreset.DetailBucket, $planForPreset.MotionBucket, $planForPreset.Bpppf, $planForPreset.Preset, $planForPreset.WidthOrigin, $planForPreset.PreprocessLabel, $planForPreset.CropSummary)

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
$cropResult = Invoke-CropDetect -Info $info -InputPath $inputFull -CropMode $CropMode
$info = Set-InfoPlanningContext -Info $info -CropResult $cropResult

Write-Host "Input:            $inputFull"
Write-Host "Duration:         $([math]::Round($info.Duration, 2)) s"
Write-Host "Source:           $($info.Width)x$($info.Height) @ $([math]::Round($info.Fps, 3)) fps"
Write-Host "Planning frame:   $(Get-PlanningWidth -Info $info)x$(Get-PlanningHeight -Info $info)"
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
Write-Host "Crop mode:        $CropMode"
Write-Host "Crop detect:      $(Get-CropSummary -Info $info)"
Write-Host "Preprocess:       $PreprocessProfile"
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
    -PresetWasExplicit $presetWasExplicit `
    -PreprocessProfile $PreprocessProfile

  if (-not $winner -or -not $winner.Success) {
    throw "Could not get under target size with the current probe + bitrate-targeting plan."
  }

  $winner.SizeBytes = Finalize-OutputFile -InputPath $winner.Path -OutputPath $OutputFile

  Write-Host ""
  Write-Host "Done."
  Write-Host "Output file:      $OutputFile"
  Write-Host "Final size:       $($winner.SizeBytes) bytes ($([math]::Round($winner.SizeBytes / 1MB, 3)) MiB)"
  Write-Host "Chosen width:     $($winner.Plan.Width)"
  Write-Host "Chosen height:    $($winner.Plan.Height)"
  Write-Host "Chosen fps:       $($winner.Plan.Fps)"
  Write-Host "Video bitrate:    $($winner.Plan.VideoKbps) kbps"
  Write-Host "Chosen audio:     $($winner.Plan.AudioPlan.Label)"
  Write-Host "Chosen preset:    $($winner.Plan.Preset)"
  Write-Host "Width origin:     $($winner.Plan.WidthOrigin)"
  Write-Host "Crop state:       $($winner.Plan.CropSummary)"
  Write-Host "Preprocess:       $($winner.Plan.PreprocessLabel)"
  Write-Host "Detail bucket:    $($winner.Plan.DetailBucket)"
  Write-Host "Motion bucket:    $($winner.Plan.MotionBucket)"
  Write-Host "Predicted bpppf:  $('{0:N4}' -f $winner.Plan.Bpppf)"
  Write-Host "X264 params:      $(if ([string]::IsNullOrWhiteSpace($winner.Plan.X264Params)) { '(default)' } else { $winner.Plan.X264Params })"
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
