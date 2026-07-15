[CmdletBinding()]
param([switch]$IncludeSyntheticMetrics)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "compress.ps1"
$script:Passed = 0
$script:Failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) { throw "$Message (expected='$Expected', actual='$Actual')" }
}

function Invoke-Test([string]$Name, [scriptblock]$Test) {
  try {
    & $Test
    $script:Passed++
    Write-Host "PASS $Name"
  }
  catch {
    $script:Failed++
    Write-Host "FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
  }
}

function New-TestInfo {
  param([int]$Width = 1920, [int]$Height = 1080, [double]$Fps = 60.0, [int]$BitDepth = 8)
  return [PSCustomObject]@{
    Width = $Width; Height = $Height; Fps = $Fps; PlanningWidth = $Width; PlanningHeight = $Height
    CropFilter = ""; CropApplied = $false; CropSummary = "none"
    SampleAspectRatioValue = 1.0; SampleAspectRatio = "1:1"; DisplayAspectRatio = ""; Rotation = 0
    PixelFormat = if ($BitDepth -gt 8) { "yuv420p10le" } else { "yuv420p" }; VideoBitDepth = $BitDepth
    ColorRange = "tv"; ColorPrimaries = "bt709"; ColorTransfer = "bt709"; ColorSpace = "bt709"; ChromaLocation = "left"
    HdrClassification = "SDR"; HasHdrMetadata = $false; HdrReason = "transfer=bt709"
  }
}

function New-MetricSelectionResult([double]$Vmaf, [double]$WorstVmaf, [double]$Xpsnr) {
  $plan = [PSCustomObject]@{
    Mode = "Balanced"; Width = 1280; Height = 720; Fps = 30; VideoKbps = 1000; WidthRatio = 1.0
    Preset = "medium"; PreviewRank = 1; AudioPlan = [PSCustomObject]@{ Rank = 5; Mode = "aac"; Kbps = 96 }
    CodecProfile = [PSCustomObject]@{ VideoCodec = "x264"; Container = "mp4" }
    PreprocessLabel = "none"; CropApplied = $false; VFilter = ""; GeometryVFilter = ""; EncodeVFilter = ""
    OutputPixelFormat = "yuv420p"; VbvMode = "Off"
    MetricModeUsed = "ensemble"; PrimaryMetricMode = "vmaf"; MetricScore = $Vmaf; WorstMetricScore = $WorstVmaf
    MetricConfidence = 0.9; XpsnrScore = $Xpsnr
  }
  return [PSCustomObject]@{
    Success = $true; Ratio = 0.99; Plan = $plan; MetricModeUsed = "ensemble"; PrimaryMetricMode = "vmaf"
    MetricScore = $Vmaf; WorstMetricScore = $WorstVmaf; MetricConfidence = 0.9; XpsnrScore = $Xpsnr
  }
}

Invoke-Test "PowerShell parser accepts compressor" {
  $tokens = $null; $errors = $null
  [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
  Assert-Equal $errors.Count 0 "PowerShell parser errors were found"
}

$env:COMPRESS_INTERNAL_TEST_MODE = "1"
try { . $scriptPath -InputFile "test-only" -TargetBytes 100000 }
finally { Remove-Item Env:COMPRESS_INTERNAL_TEST_MODE -ErrorAction SilentlyContinue }

Invoke-Test "pinned codecs resolve their default container in Fast mode" {
  $script:RuntimeCapabilities = [PSCustomObject]@{
    PreferredMetricMode = "off"; PreferredSamplingMode = "fixed"
    SupportsX264Mp4 = $true; SupportsX265Mp4 = $true; SupportsAv1Webm = $true
  }
  $common = @{
    RequestedMetricMode = "off"; RequestedSampleMode = "fixed"; RequestedContentClassMode = "off"
    CompatibilityMode = "widest"; AudioPriority = "balanced"; Mode = "Fast"
  }
  $x265 = Resolve-PolicyProfile -RequestedVideoCodec x265 -RequestedContainer auto @common
  $av1 = Resolve-PolicyProfile -RequestedVideoCodec av1 -RequestedContainer auto @common
  Assert-Equal $x265.Container "mp4" "Pinned x265 did not resolve MP4"
  Assert-Equal $av1.Container "webm" "Pinned AV1 did not resolve WebM"
  Assert-Equal $x265.ContainerPolicyReason "codec-default" "x265 resolution reason was not recorded"
}

Invoke-Test "canonical metric geometry is source-derived and plan-invariant" {
  $info = New-TestInfo -Width 3840 -Height 2160 -Fps 120
  $profile = Get-CanonicalMetricProfile -Info $info
  Assert-Equal $profile.Width 1920 "Canonical width was not bounded"
  Assert-Equal $profile.Height 1080 "Canonical height did not preserve display geometry"
  Assert-Equal $profile.Fps 60 "Canonical FPS was not capped at 60"
  $first = Build-MetricReferenceFilterChain -Info $info -TargetWidth 1920 -TargetFps 60
  $second = Build-MetricReferenceFilterChain -Info $info -TargetWidth 640 -TargetFps 24
  Assert-Equal $first $second "Candidate geometry contaminated the reference metric filter"
}

Invoke-Test "canonical metrics do not upscale the reference and retain ten-bit comparison" {
  $profile = Get-CanonicalMetricProfile -Info (New-TestInfo -Width 640 -Height 360 -Fps 29.97 -BitDepth 10)
  Assert-Equal $profile.Width 640 "Reference was upscaled"
  Assert-Equal $profile.Height 360 "Reference was upscaled"
  Assert-Equal $profile.PixelFormat "yuv420p10le" "Ten-bit metric format was not retained"
}

Invoke-Test "distortions are restored to the canonical canvas and source timeline" {
  $plan = [PSCustomObject]@{
    Width = 960; Height = 540; Fps = 30
    MetricCanvasWidth = 1920; MetricCanvasHeight = 1080; MetricFps = 60.0; MetricPixelFormat = "yuv420p10le"
    OutputPixelFormat = "yuv420p"
  }
  $filter = Get-MetricDistortedFilter -Plan $plan
  Assert-True ($filter -match 'scale=1920:1080') "Reduced resolution was not restored to the metric canvas"
  Assert-True ($filter -match 'fps=60:round=near') "Reduced FPS was not frame-repeated on the source timeline"
  Assert-True ($filter -match 'format=yuv420p10le') "Distorted output was not converted to the common metric format"
}

Invoke-Test "preprocessing never enters the canonical reference" {
  $info = New-TestInfo
  $reference = Build-MetricReferenceFilterChain -Info $info -TargetWidth 1280 -TargetFps 30
  foreach ($profile in @("mild-denoise", "deband", "screen-sharpen", "ringing-reduction")) {
    $encode = Build-EncodeFilterChain -Info $info -TargetWidth 1280 -TargetFps 30 -PreprocessProfileName $profile
    Assert-True ($encode -ne $reference) "Encode and reference filters unexpectedly match for $profile"
  }
  Assert-True ($reference -notmatch 'hqdn3d|deband|unsharp|smartblur') "Destructive preprocessing contaminated the reference"
}

Invoke-Test "missing metric evidence remains unavailable" {
  $plan = [PSCustomObject]@{ MetricModeUsed = "ensemble" }
  $result = Invoke-PreviewMetric -InputPath "missing" -PreviewSegments @() -Plan $plan -TempDir $env:TEMP
  Assert-Equal $result.MetricScore $null "Metric failure became a zero score"
  Assert-Equal $result.MetricConfidence 0 "Metric failure retained confidence"
}

Invoke-Test "material XPSNR regression guards VMAF selection" {
  $candidate = New-MetricSelectionResult -Vmaf 92 -WorstVmaf 91 -Xpsnr 29.0
  $current = New-MetricSelectionResult -Vmaf 90 -WorstVmaf 89 -Xpsnr 30.0
  Assert-True (-not (Test-IsBetterPreviewResult -Candidate $candidate -Current $current)) "VMAF gain hid a material XPSNR regression"
}

if ($IncludeSyntheticMetrics) {
  Invoke-Test "canonical metrics expose temporal and spatial loss" {
    if (-not (Test-FfmpegFilterAvailable -Filter "libvmaf") -or -not (Test-VmafNegModelAvailable)) {
      Write-Host "SKIP libvmaf NEG is unavailable"
      return
    }

    $temp = Join-Path $env:TEMP ("compress_metric_regression_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
      $source = Join-Path $temp "source.mkv"
      $same = Join-Path $temp "same.mkv"
      $lowFps = Join-Path $temp "low-fps.mkv"
      $lowResolution = Join-Path $temp "low-resolution.mkv"
      & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=60:duration=2" -c:v ffv1 -pix_fmt yuv420p $source
      & ffmpeg -hide_banner -loglevel error -y -i $source -c:v ffv1 -pix_fmt yuv420p $same
      & ffmpeg -hide_banner -loglevel error -y -i $source -vf "fps=30" -c:v ffv1 -pix_fmt yuv420p $lowFps
      & ffmpeg -hide_banner -loglevel error -y -i $source -vf "scale=320:180:flags=lanczos" -c:v ffv1 -pix_fmt yuv420p $lowResolution

      $plan = [PSCustomObject]@{
        MetricReferenceVFilter = "setsar=1,scale=640:360:flags=lanczos,fps=60:round=near"
        MetricPixelFormat = "yuv420p"; MetricCanvasWidth = 640; MetricCanvasHeight = 360; MetricFps = 60.0
        OutputPixelFormat = "yuv420p"; Mode = "Balanced"; PreprocessLabel = "none"; EncodeVFilter = ""; VFilter = ""
      }
      $window = [PSCustomObject]@{ Start = 0.0; Duration = 1.8 }
      $sameScore = (Invoke-VmafMetric -InputPath $source -PreviewPath $same -Plan $plan -Window $window -TempDir $temp).Score
      $fpsScore = (Invoke-VmafMetric -InputPath $source -PreviewPath $lowFps -Plan $plan -Window $window -TempDir $temp).Score
      $resolutionScore = (Invoke-VmafMetric -InputPath $source -PreviewPath $lowResolution -Plan $plan -Window $window -TempDir $temp).Score
      Assert-True ($sameScore -gt $fpsScore) "30 fps loss was hidden on a 60 fps source"
      Assert-True ($sameScore -gt $resolutionScore) "Resolution loss was hidden by per-plan normalization"
    }
    finally {
      Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host ""
Write-Host "Tests: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
