param(
    [Parameter(Mandatory = $true)][string]$Checkout,
    [Parameter(Mandatory = $true)][string]$SourceRepository,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$Commit,
    [Parameter(Mandatory = $true)][string]$FlutterSdk,
    [Parameter(Mandatory = $true)][string]$DevEcoStudio,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$checkoutRoot = (Resolve-Path -LiteralPath $Checkout).Path
$sourceRoot = (Resolve-Path -LiteralPath $SourceRepository).Path
if ($checkoutRoot -eq $sourceRoot) {
    throw 'HarmonyOS requires a separate checkout from the standard Flutter build.'
}
foreach ($path in @(
    (Join-Path $checkoutRoot '.git'),
    (Join-Path $FlutterSdk 'bin/flutter.bat'),
    (Join-Path $DevEcoStudio 'sdk/default/openharmony')
)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing build prerequisite: $path" }
}

# Preserve local source changes and generated native libraries in the OH checkout.
$changes = & git -C $checkoutRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the HarmonyOS checkout.' }
if ($changes) { throw 'The HarmonyOS checkout has tracked changes; refusing to overwrite them.' }
& git -C $checkoutRoot fetch --no-tags $sourceRoot $Commit
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the requested build commit.' }
& git -C $checkoutRoot merge --ff-only --no-edit $Commit
if ($LASTEXITCODE -ne 0) { throw 'The HarmonyOS checkout cannot fast-forward to the requested commit.' }
$actualCommit = & git -C $checkoutRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $Commit) {
    throw 'The HarmonyOS checkout does not match the requested build commit.'
}

$versionLine = Select-String -LiteralPath (Join-Path $checkoutRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)\s*$'
if ($versionLine.Count -ne 1) { throw 'Expected one application version in pubspec.yaml.' }
$appVersion = $versionLine.Matches[0].Groups[1].Value
if ($appVersion -notmatch '^([^+]+)\+(\d+)$') { throw "Invalid application version: $appVersion" }
$versionName = $Matches[1]
$versionCode = [int]$Matches[2]

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.hap') {
    throw 'The output directory already contains HAP files; use an empty directory.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$nativeLibraries = @(
    'libapp.so', 'libflutter.so', 'libc++_shared.so', 'libflutter_7zip.so',
    'liblodepng_flutter.so', 'libonnxruntime.so', 'libpdfium.so',
    'libqjs.so', 'librhttp.so', 'libsqlite3.so', 'libzip_flutter.so'
)
$targets = @(
    @{ Platform = 'ohos-arm64'; Abi = 'arm64-v8a'; Name = 'arm64' },
    @{ Platform = 'ohos-x64'; Abi = 'x86_64'; Name = 'x64-emulator' }
)
$buildScript = Join-Path $checkoutRoot 'tool/build_ohos.ps1'
$sources = Join-Path $checkoutRoot '.dart_tool/ohos/sources'
$builtHap = Join-Path $checkoutRoot 'build/ohos/hap/entry-default-unsigned.hap'
foreach ($target in $targets) {
    # Each ABI overwrites the same generated filename. Never reuse an older HAP.
    if (Test-Path -LiteralPath $builtHap) { Remove-Item -LiteralPath $builtHap -Force }
    & $buildScript -FlutterSdk $FlutterSdk -DevEcoStudio $DevEcoStudio `
        -Target lib/main.dart -TargetPlatform $target.Platform -BuildMode release `
        -OnnxSource (Join-Path $sources 'onnxruntime') `
        -EigenSource (Join-Path $sources 'eigen') `
        -WebViewSource (Join-Path $sources 'inappwebview')
    if ($LASTEXITCODE -ne 0) { throw "HarmonyOS build failed for $($target.Platform)." }
    if (-not (Test-Path -LiteralPath $builtHap) -or (Get-Item -LiteralPath $builtHap).Length -eq 0) {
        throw "Missing HarmonyOS package for $($target.Platform)."
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($builtHap)
    try {
        $manifestEntry = $archive.GetEntry('module.json')
        if ($null -eq $manifestEntry) { throw 'The HAP has no module.json.' }
        $reader = [IO.StreamReader]::new($manifestEntry.Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        $app = $manifest.app
        if ($app.versionName -ne $versionName -or $app.versionCode -ne $versionCode) {
            throw "Packaged version does not match $appVersion."
        }
        if ($app.bundleName -ne 'com.github.kyosee.venera' -or
            $app.debug -ne $false -or $app.buildMode -ne 'release') {
            throw 'Expected the VeneraX release application in the HAP.'
        }
        $abis = @($archive.Entries.FullName | ForEach-Object {
            if ($_ -match '^libs/([^/]+)/[^/]+\.so$') { $Matches[1] }
        } | Sort-Object -Unique)
        if ($abis.Count -ne 1 -or $abis[0] -ne $target.Abi) {
            throw "Unexpected packaged ABI: $($abis -join ', '); expected $($target.Abi)."
        }
        foreach ($library in $nativeLibraries) {
            $entry = $archive.GetEntry("libs/$($target.Abi)/$library")
            if ($null -eq $entry -or $entry.Length -eq 0) {
                throw "Missing native library: $library ($($target.Abi))."
            }
        }
    } finally {
        $archive.Dispose()
    }
    $filename = "VeneraX-$appVersion-harmonyos-$($target.Name)-unsigned.hap"
    Copy-Item -LiteralPath $builtHap -Destination (Join-Path $OutputDirectory $filename)
    Write-Host "Verified $filename (release, $($target.Abi))."
}
