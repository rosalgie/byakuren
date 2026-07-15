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

Invoke-Test "backend policy keeps experimental encoders explicit" {
  $script:RuntimeCapabilities = [PSCustomObject]@{
    PreferredMetricMode = "off"; PreferredSamplingMode = "fixed"
    SupportsX264Mp4 = $true; SupportsX265Mp4 = $true; SupportsAv1Webm = $true
  }
  $common = @{
    RequestedContainer = "auto"; RequestedMetricMode = "off"; RequestedSampleMode = "fixed"
    RequestedContentClassMode = "off"; CompatibilityMode = "widest"; AudioPriority = "balanced"; Mode = "Fast"
  }
  $blocked = $false
  try { Resolve-PolicyProfile -RequestedVideoCodec auto -RequestedEncoderBackend aom @common | Out-Null }
  catch { $blocked = $true }
  Assert-True $blocked "Experimental aom backend was accepted without its gate"

  $aom = Resolve-PolicyProfile -RequestedVideoCodec auto -RequestedEncoderBackend aom -EnableExperimental @common
  Assert-Equal $aom.VideoCodec "av1" "aom did not resolve AV1"
  Assert-Equal $aom.EncoderBackend "aom" "aom backend identity was lost"
  Assert-Equal $aom.Container "webm" "aom did not resolve WebM"
}

Invoke-Test "widest automatic policy remains x264 only" {
  $script:RuntimeCapabilities = [PSCustomObject]@{
    PreferredMetricMode = "off"; PreferredSamplingMode = "fixed"
    SupportsX264Mp4 = $true; SupportsX265Mp4 = $true; SupportsAv1Webm = $true
  }
  $profile = Resolve-PolicyProfile -RequestedVideoCodec auto -RequestedContainer auto -RequestedMetricMode off -RequestedSampleMode fixed -RequestedContentClassMode off -CompatibilityMode widest -AudioPriority balanced -Mode ExtraQuality
  Assert-Equal $profile.VideoCodec "x264" "Widest policy selected a compatibility-gated codec"
  Assert-Equal $profile.EncoderBackend "libx264" "Widest policy selected a non-production backend"
}

Invoke-Test "codec profiles separate backend and rate-control adapters" {
  $aom = Resolve-CodecProfile -VideoCodec av1 -Container webm -EncoderBackend aom
  $vpx = Resolve-CodecProfile -VideoCodec vp9 -Container webm -EncoderBackend vpx
  $rav1e = Resolve-CodecProfile -VideoCodec av1 -Container webm -EncoderBackend rav1e
  Assert-Equal $aom.VideoEncoder "libaom-av1" "aom encoder mapping is wrong"
  Assert-Equal $aom.RateControlAdapter "ffmpeg-two-pass-vbr" "aom did not require exact two-pass VBR"
  Assert-Equal $vpx.ContainerAudioProfile "webm-opus" "VP9 delivery profile is wrong"
  Assert-Equal $rav1e.RequiredPasses 1 "rav1e was incorrectly advertised as two-pass"
}

Invoke-Test "PowerShell matches shared byakuren golden contracts" {
  $golden = Get-Content -LiteralPath (Join-Path $PSScriptRoot "golden\parity-v1.json") -Raw | ConvertFrom-Json
  $script:RuntimeCapabilities = [PSCustomObject]@{
    PreferredMetricMode = "off"; PreferredSamplingMode = "fixed"
    SupportsX264Mp4 = $true; SupportsX265Mp4 = $true; SupportsAv1Webm = $true
  }
  foreach ($case in @($golden.policyCases)) {
    $resolved = Resolve-PolicyProfile `
      -RequestedVideoCodec $case.videoCodec `
      -RequestedContainer $case.container `
      -RequestedMetricMode off `
      -RequestedSampleMode fixed `
      -RequestedContentClassMode off `
      -CompatibilityMode $case.compatibility `
      -AudioPriority balanced `
      -Mode Fast `
      -RequestedEncoderBackend $case.encoderBackend `
      -EnableExperimental:([bool]$case.experimental)
    Assert-Equal $resolved.VideoCodec $case.expectedCodec "$($case.name) codec mismatch"
    Assert-Equal $resolved.EncoderBackend $case.expectedBackend "$($case.name) backend mismatch"
    Assert-Equal $resolved.Container $case.expectedContainer "$($case.name) container mismatch"
  }
  foreach ($case in @($golden.canvasCases)) {
    $info = New-TestInfo -Width $case.width -Height $case.height -Fps $case.fps -BitDepth $case.bitDepth
    $info.SampleAspectRatioValue = [double]$case.sar
    $info.Rotation = [int]$case.rotation
    if ([math]::Abs([int]$case.rotation) % 180 -eq 90) {
      $info.PlanningWidth = [int]$case.height
      $info.PlanningHeight = [int]$case.width
    }
    $canvas = Get-CanonicalMetricProfile -Info $info
    Assert-Equal $canvas.Width $case.expectedWidth "$($case.name) canvas width mismatch"
    Assert-Equal $canvas.Height $case.expectedHeight "$($case.name) canvas height mismatch"
    Assert-True ([math]::Abs([double]$canvas.Fps - [double]$case.expectedFps) -lt 0.0001) "$($case.name) canvas FPS mismatch"
    Assert-Equal $canvas.PixelFormat $case.expectedPixelFormat "$($case.name) canvas format mismatch"
  }
  foreach ($case in @($golden.modeCases)) {
    $strategy = Get-ModeStrategy -Mode $case.mode
    Assert-Equal $strategy.MaxFullEncodes $case.maxFullEncodes "$($case.mode) encode limit mismatch"
    Assert-True ([math]::Abs([double]$strategy.EarlyAcceptRatio - [double]$case.fillGate) -lt 0.0000001) "$($case.mode) fill gate mismatch"
  }
  Assert-Equal $golden.schemaVersion "byakuren.compress.result.v1" "Shared result schema mismatch"
}

Invoke-Test "encoder tuning families remain benchmark-only" {
  $vp9 = @(Get-EncoderParameterFamilies -Backend vpx -ContentClass screen)
  Assert-True ("screen-content" -in @($vp9.Name)) "VP9 screen-content candidate is missing"
  Assert-True (-not ($vp9 | Where-Object Automatic)) "Experimental VP9 tuning was promoted without a full gate"
  $x265 = @(Get-EncoderParameterFamilies -Backend libx265)
  Assert-True ("aq-psy-low" -in @($x265.Name)) "x265 AQ/psy experiment family is missing"
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

Invoke-Test "under-cap policy copies only compatible inputs" {
  $info = New-TestInfo
  $info | Add-Member -NotePropertyName InputBytes -NotePropertyValue 90000 -Force
  $info | Add-Member -NotePropertyName FormatName -NotePropertyValue "mov,mp4,m4a,3gp,3g2,mj2" -Force
  $info | Add-Member -NotePropertyName VideoCodec -NotePropertyValue "h264" -Force
  $info | Add-Member -NotePropertyName HasAudio -NotePropertyValue $true -Force
  $info | Add-Member -NotePropertyName AudioCodec -NotePropertyValue "aac" -Force
  $profile = [PSCustomObject]@{ VideoCodec = "x264"; Container = "mp4"; CopyableAudioCodecs = @("aac") }
  Assert-True (Test-UnderCapPassthroughEligible -Info $info -InputPath "compatible.mp4" -CodecProfile $profile -HardCapBytes 100000 -Behavior Auto) "Compatible under-cap input did not pass"
  Assert-True (-not (Test-UnderCapPassthroughEligible -Info $info -InputPath "compatible.mp4" -CodecProfile $profile -HardCapBytes 100000 -Behavior Transcode)) "Transcode policy unexpectedly copied"
  $info.VideoCodec = "hevc"
  Assert-True (-not (Test-UnderCapPassthroughEligible -Info $info -InputPath "compatible.mp4" -CodecProfile $profile -HardCapBytes 100000 -Behavior Auto)) "Mismatched codec unexpectedly copied"
}

Invoke-Test "under-cap passthrough preserves bytes exactly" {
  $temp = Join-Path $env:TEMP ("compress_copy_test_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temp | Out-Null
  try {
    $input = Join-Path $temp "input.mp4"
    $output = Join-Path $temp "output.mp4"
    [IO.File]::WriteAllBytes($input, (New-Object byte[] 1234))
    $result = Invoke-UnderCapPassthrough -InputPath $input -OutputPath $output -HardCapBytes 2000
    Assert-Equal $result.SizeBytes 1234 "Passthrough size changed"
    Assert-Equal (Get-FileHash $input).Hash (Get-FileHash $output).Hash "Passthrough bytes changed"
  }
  finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test "versioned copy result preserves unavailable metrics" {
  $temp = Join-Path $env:TEMP ("compress_result_test_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temp | Out-Null
  try {
    $input = Join-Path $temp "input.mp4"
    $output = Join-Path $temp "output.mp4"
    $jsonPath = Join-Path $temp "result.json"
    [IO.File]::WriteAllBytes($input, (New-Object byte[] 64))
    [IO.File]::Copy($input, $output)
    $info = New-TestInfo
    foreach ($entry in @{
        InputBytes = 64L; Duration = 1.0; VideoCodec = "h264"; AudioCodec = "aac"; HasAudio = $true
      }.GetEnumerator()) {
      $info | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
    }
    $profile = Resolve-CodecProfile -VideoCodec x264 -Container mp4 -EncoderBackend libx264
    $policy = [PSCustomObject]@{
      VideoCodec = "x264"; EncoderBackend = "libx264"; Container = "mp4"; DefaultAudioCodec = "aac"
      CodecPolicyReason = "pinned"; ContainerPolicyReason = "codec-default"; CompatibilityMode = "widest"
    }
    $result = New-CompressorResultObject -Action copy -Info $info -CodecProfile $profile -PolicyProfile $policy -InputPath $input -OutputPath $output -HardCapBytes 100 -WorkingTargetBytes 99
    Assert-Equal $result.SchemaVersion "byakuren.compress.result.v1" "Unexpected result schema"
    Assert-Equal $result.Metrics.Available $false "Copy result advertised metric evidence"
    Assert-Equal $result.Metrics.PrimaryScore $null "Unavailable metric became zero-valued"
    Assert-Equal $result.CapabilityProbe.SkippedReason "under-cap passthrough" "Copy probe disposition is missing"
    Write-CompressorResultJson -Result $result -Path $jsonPath | Out-Null
    $roundTrip = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    Assert-Equal $roundTrip.Output.Bytes 64 "Result JSON output size changed"
    Assert-Equal $roundTrip.Output.Sha256 (Get-FileHash $output).Hash.ToLowerInvariant() "Result JSON output hash changed"
  }
  finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test "payload correction ignores unrelated mux size" {
  $guess = Get-NextVideoKbpsGuess -Mode Balanced -TargetBytes 1000000 -CurrentVideoKbps 800 -CurrentSizeBytes 930000 -TargetVideoPayloadBytes 850000 -CurrentVideoPayloadBytes 680000
  Assert-True ($guess -gt 800) "Underfilled video payload did not increase bitrate"
  $shrink = Get-NextVideoKbpsGuess -Mode Balanced -TargetBytes 1000000 -CurrentVideoKbps 800 -CurrentSizeBytes 930000 -TargetVideoPayloadBytes 650000 -CurrentVideoPayloadBytes 680000
  Assert-True ($shrink -lt 800) "Oversized video payload did not reduce bitrate"
}

Invoke-Test "ExtraQuality keeps source and next-lower sentinels" {
  $fps = @(Get-TargetFpsCandidates -srcFps 60 -mode ExtraQuality -duration 120 -totalKbps 400 -motionBucket VeryLow -detailBucket Medium)
  Assert-True (60 -in $fps) "Source FPS sentinel was omitted"
  Assert-True (30 -in $fps) "Next-lower FPS sentinel was omitted"

  $info = New-TestInfo -Width 1920 -Height 1080 -Fps 60
  $info | Add-Member -NotePropertyName VideoBitrateKbps -NotePropertyValue 4000 -Force
  $probe = [PSCustomObject]@{
    DetailBucket = "Medium"; MotionNormalized = 1.0; ContentClass = "general"
    DetailProbe = [PSCustomObject]@{ AvgKbps = 100.0; PeakishKbps = 120.0 }
  }
  $widths = @(Get-WidthPlanCandidates -Info $info -Probe $probe -TargetFps 30 -VideoKbps 700 -Mode ExtraQuality)
  Assert-True (1920 -in @($widths.Width)) "Source resolution sentinel was omitted"
  Assert-True (1600 -in @($widths.Width)) "Next-lower resolution sentinel was omitted"
}

Invoke-Test "direct classifier thresholds are frozen before Holdout" {
  $thresholds = Get-ContentClassifierThresholds
  Assert-Equal $thresholds.Version "direct-core-v1" "Unexpected classifier version"
  Assert-Equal $thresholds.CalibrationSet "core" "Classifier was not calibrated on Core"
  Assert-True $thresholds.Frozen "Classifier thresholds are not frozen"
}

Invoke-Test "Core-shaped direct evidence recognizes gaming and screen content" {
  $probe = [PSCustomObject]@{ MotionBucket = "Medium"; DetailBucket = "Medium" }
  $gamingInfo = [PSCustomObject]@{ Fps = 60.0; HasAudio = $false }
  $gaming = [PSCustomObject]@{
    UiPersistence = 0.52; EdgeDensity = 0.050; Entropy = 0.84; FlatAreaRatio = 0.864
    TemporalDifference = 0.053; Noise = 0.006; MotionSpread = 0.20
  }
  Assert-Equal (Invoke-ContentClassifier -Info $gamingInfo -Probe $probe -Features $gaming) "gameplay" "S015-shaped direct evidence was not classified as gameplay"

  $screenInfo = [PSCustomObject]@{ Fps = 30.0; HasAudio = $false }
  $screen = [PSCustomObject]@{
    UiPersistence = 0.62; EdgeDensity = 0.044; Entropy = 0.79; FlatAreaRatio = 0.898
    TemporalDifference = 0.007; Noise = 0.025; MotionSpread = 0.10
  }
  Assert-Equal (Invoke-ContentClassifier -Info $screenInfo -Probe $probe -Features $screen) "screen" "S018-shaped direct evidence was not classified as screen content"
}

if ($IncludeSyntheticMetrics) {
  Invoke-Test "experimental delivery backends pass functional probes" {
    foreach ($profile in @(
        (Resolve-CodecProfile -VideoCodec av1 -Container webm -EncoderBackend aom),
        (Resolve-CodecProfile -VideoCodec vp9 -Container webm -EncoderBackend vpx)
      )) {
      $probe = Invoke-EncoderFunctionalProbe -CodecProfile $profile
      Assert-True $probe.Success "Backend $($profile.EncoderBackend) failed its encode/decode rate-control probe"
      Assert-Equal $probe.RateControlAdapter "ffmpeg-two-pass-vbr" "Functional probe used the wrong rate-control adapter"
    }
  }

  Invoke-Test "VVenC probe remains raw-video lab only" {
    $probe = Invoke-VvencLabFunctionalProbe
    Assert-True $probe.Success "VVenC raw two-pass encode/decode probe failed"
    Assert-Equal $probe.Container "raw-vvc" "VVenC probe was assigned a delivery container"
    Assert-True (-not $probe.DeliveryEligible) "VVenC was marked eligible for website delivery"
  }

  Invoke-Test "direct content probe measures independent feature families" {
    $temp = Join-Path $env:TEMP ("compress_content_probe_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
      $source = Join-Path $temp "source.mkv"
      & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=320x180:rate=30:duration=1" -c:v ffv1 -pix_fmt yuv420p $source
      $features = Invoke-ContentFeatureProbe -InputPath $source -SampleWindows @([PSCustomObject]@{ Start = 0.0; Duration = 0.9 })
      Assert-True ($null -ne $features.EdgeDensity -and $features.EdgeDensity -gt 0) "Edge evidence was unavailable"
      Assert-True ($null -ne $features.FlatAreaRatio -and $features.FlatAreaRatio -gt 0) "Flat-area evidence was unavailable"
      Assert-True ($null -ne $features.Entropy -and $features.Entropy -gt 0) "Entropy evidence was unavailable"
      Assert-True ($null -ne $features.TemporalDifference -and $features.TemporalDifference -gt 0) "Temporal evidence was unavailable"
      Assert-True ($null -ne $features.Noise) "Noise evidence was unavailable"
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
  }

  Invoke-Test "canonical metrics expose temporal and spatial loss" {
    if (-not (Test-FFmpegFilterAvailable -Filter "libvmaf") -or -not (Test-VmafNegModelAvailable)) {
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

  Invoke-Test "audio identities are encoded once and cached" {
    $temp = Join-Path $env:TEMP ("compress_audio_cache_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
      $source = Join-Path $temp "source.mp4"
      & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=size=64x64:rate=10:duration=1" -f lavfi -i "sine=frequency=440:duration=1" -c:v libx264 -c:a aac -shortest $source
      $script:AudioCache = @{}
      $plan = [PSCustomObject]@{
        AudioPlan = [PSCustomObject]@{ Mode = "aac"; Codec = "aac"; Kbps = 64; EstimatedBytes = 8000 }
        CodecProfile = [PSCustomObject]@{ DefaultAudioEncoder = "aac" }
      }
      $first = Get-CachedAudioEntry -InputPath $source -Plan $plan -TempDir $temp
      $second = Get-CachedAudioEntry -InputPath $source -Plan $plan -TempDir $temp
      Assert-Equal $first.Path $second.Path "Audio cache returned a different artifact"
      Assert-Equal $script:AudioCache.Count 1 "Audio identity was encoded more than once"
      Assert-True ($first.PayloadBytes -gt 0) "Cached audio payload was not measured"
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

Write-Host ""
Write-Host "Tests: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
