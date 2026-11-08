param(
    [string]$SourceRoot,
    [string]$EigenRoot,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$NativeSdk,
    [ValidateSet('x86_64', 'arm64-v8a')][string[]]$Abi = @('x86_64', 'arm64-v8a'),
    [ValidateRange(1, 8)][int]$Jobs = 8
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-PinnedSource([string]$Path, [string]$DefaultPath, [string]$Remote, [string]$Revision) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = $DefaultPath
        if (-not (Test-Path -LiteralPath $Path)) {
            & git init $Path | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Cannot create source checkout: $Path" }
            & git -C $Path remote add origin $Remote | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Cannot configure official source remote: $Remote" }
            & git -C $Path fetch --depth 1 origin $Revision | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Cannot fetch official source: $Remote at $Revision" }
            & git -C $Path checkout --detach FETCH_HEAD | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Cannot check out source: $Revision" }
        }
    }
    $commit = & git -C $Path rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $commit -ne $Revision) {
        throw "Source checkout must be $Remote at $Revision : $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

$SourceRoot = Get-PinnedSource $SourceRoot (Join-Path $projectRoot '.dart_tool/ohos/sources/onnxruntime') `
    'https://github.com/microsoft/onnxruntime.git' 'f217402897f40ebba457e2421bc0a4702771968e'
$EigenRoot = Get-PinnedSource $EigenRoot (Join-Path $projectRoot '.dart_tool/ohos/sources/eigen') `
    'https://gitlab.com/libeigen/eigen.git' '1d8b82b0740839c0de7f1242a3585e3390ff5f33'
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$EigenRoot = (Resolve-Path -LiteralPath $EigenRoot).Path
$NativeSdk = (Resolve-Path -LiteralPath $NativeSdk).Path
$patchPath = Join-Path $PSScriptRoot 'ohos/onnxruntime.patch'

& git -C $EigenRoot diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'The pinned Eigen checkout contains source modifications.' }
foreach ($source in @($SourceRoot, $EigenRoot)) {
    $untracked = & git -C $source ls-files --others --exclude-standard -- . ':(exclude).codegraph' ':(exclude).dependencies'
    if ($LASTEXITCODE -ne 0 -or $untracked) { throw "Unexpected untracked source files in $source : $untracked" }
}

if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'The OHOS ONNX build requires an x64 Windows host.'
}
foreach ($path in @(
    (Join-Path $SourceRoot 'VERSION_NUMBER'),
    (Join-Path $SourceRoot 'cmake/CMakeLists.txt'),
    (Join-Path $EigenRoot 'CMakeLists.txt'),
    (Join-Path $EigenRoot 'Eigen/Core'),
    (Join-Path $NativeSdk 'build-tools/cmake/bin/cmake.exe'),
    (Join-Path $NativeSdk 'build-tools/cmake/bin/ninja.exe'),
    (Join-Path $NativeSdk 'build/cmake/ohos.toolchain.cmake'),
    $patchPath
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required OHOS ONNX build file is missing: $path"
    }
}
if ((Get-Content -LiteralPath (Join-Path $SourceRoot 'VERSION_NUMBER') -Raw).Trim() -ne '1.22.0') {
    throw 'The OHOS ONNX patch requires official ONNX Runtime v1.22.0 source.'
}
# Source acquisition supplies Eigen commit 1d8b82b0740839c0de7f1242a3585e3390ff5f33.
Get-Command git -ErrorAction Stop | Out-Null
$previousErrorAction = $ErrorActionPreference
$previousGitCeiling = $env:GIT_CEILING_DIRECTORIES
try {
    # Archive sources must not discover the parent application repository.
    $env:GIT_CEILING_DIRECTORIES = Split-Path -Parent $SourceRoot
    # A failed check is expected when the patch was already applied.
    $ErrorActionPreference = 'Continue'
    $patchMessages = & git -C $SourceRoot apply --check $patchPath 2>&1
    $patchExitCode = $LASTEXITCODE
    if ($patchExitCode -ne 0) {
        $reverseMessages = & git -C $SourceRoot apply --reverse --check $patchPath 2>&1
        $reverseExitCode = $LASTEXITCODE
    }
    if ($patchExitCode -eq 0) {
        & git -C $SourceRoot apply $patchPath
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply the OHOS ONNX compatibility patch.' }
    } elseif ($reverseExitCode -ne 0) {
        throw "The ONNX source must be unpatched or contain the complete OHOS patch. $($patchMessages -join [Environment]::NewLine) $($reverseMessages -join [Environment]::NewLine)"
    }
} finally {
    $ErrorActionPreference = $previousErrorAction
    if ($null -eq $previousGitCeiling) {
        Remove-Item -LiteralPath Env:GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue
    } else {
        $env:GIT_CEILING_DIRECTORIES = $previousGitCeiling
    }
}

# Compare the worktree with the official Git revision plus only our patch.
# This detects changed source/CMake files even when HEAD is still pinned.
$temporaryIndex = Join-Path $projectRoot ('.dart_tool/ohos/onnx-' + [Guid]::NewGuid().ToString('N') + '.index')
$previousGitIndex = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE', 'Process')
try {
    $env:GIT_INDEX_FILE = $temporaryIndex
    & git -C $SourceRoot read-tree HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the official ONNX source tree.' }
    & git -C $SourceRoot apply --cached $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compare the OHOS ONNX patch with the official revision.' }
    & git -C $SourceRoot diff --quiet --
    if ($LASTEXITCODE -ne 0) { throw 'The ONNX checkout contains changes outside the OHOS compatibility patch.' }
} finally {
    if ($null -eq $previousGitIndex) {
        Remove-Item -LiteralPath Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
    } else {
        $env:GIT_INDEX_FILE = $previousGitIndex
    }
    Remove-Item -LiteralPath $temporaryIndex -ErrorAction SilentlyContinue
}

$libraries = [ordered]@{}
foreach ($targetAbi in $Abi) {
    $buildRoot = Join-Path $projectRoot "build/onnxruntime-ohos/$targetAbi"
    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    $hostPlatformPath = Join-Path $buildRoot 'host-platform.cmake'
    $hostPlatform = @'
# Some Windows hosts omit processor environment variables.
if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows" AND NOT CMAKE_HOST_SYSTEM_PROCESSOR)
  set(CMAKE_HOST_SYSTEM_PROCESSOR "AMD64")
endif()
'@
    [IO.File]::WriteAllText($hostPlatformPath, $hostPlatform, [Text.UTF8Encoding]::new($false))
    $cmake = Join-Path $NativeSdk 'build-tools/cmake/bin/cmake.exe'
    $cmakeArgs = @(
        '-S', (Join-Path $SourceRoot 'cmake'),
        '-B', $buildRoot,
        '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$(Join-Path $NativeSdk 'build-tools/cmake/bin/ninja.exe')",
        "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $NativeSdk 'build/cmake/ohos.toolchain.cmake')",
        "-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=$hostPlatformPath",
        '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_C_FLAGS=-Wno-unused-command-line-argument',
        '-DCMAKE_CXX_FLAGS=-Wno-unused-command-line-argument',
        '-DCMAKE_ASM_FLAGS=-Wno-unused-command-line-argument',
        "-DOHOS_ARCH=$targetAbi",
        '-DOHOS_STL=c++_shared',
        '-DCMAKE_TLS_VERIFY=ON',
        "-DFETCHCONTENT_SOURCE_DIR_EIGEN3=$EigenRoot",
        '-Donnxruntime_BUILD_SHARED_LIB=ON',
        '-Donnxruntime_BUILD_UNIT_TESTS=OFF',
        '-Donnxruntime_ENABLE_CPUINFO=OFF'
    )
    & $cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "ONNX CMake configuration failed for $targetAbi." }
    & $cmake --build $buildRoot --target onnxruntime --parallel $Jobs
    if ($LASTEXITCODE -ne 0) { throw "ONNX build failed for $targetAbi." }
    $library = Join-Path $buildRoot 'libonnxruntime.so.1.22.0'
    if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
        throw "Built ONNX library is missing: $library"
    }
    $libraries[$targetAbi] = $library
}
foreach ($targetAbi in $libraries.Keys) {
    $destination = Join-Path $projectRoot "ohos/entry/libs/$targetAbi"
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath $libraries[$targetAbi] -Destination (Join-Path $destination 'libonnxruntime.so') -Force
    Write-Host "Copied ONNX Runtime to $destination"
}
$notices = Join-Path $projectRoot 'ohos/entry/src/main/resources/rawfile/onnxruntime'
New-Item -ItemType Directory -Path $notices -Force | Out-Null
foreach ($name in @('LICENSE', 'ThirdPartyNotices.txt')) {
    Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination (Join-Path $notices $name) -Force
}
