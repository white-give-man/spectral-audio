param([string]$BuildDirectory='build-windows')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Push-Location $root
try {
    & (Join-Path $PSScriptRoot 'check_scripts.ps1')
    cmake -S . -B $BuildDirectory -A x64
    if($LASTEXITCODE){throw 'CMake configuration failed. Install Visual Studio C++ Build Tools and Windows 11 SDK.'}
    cmake --build $BuildDirectory --config Release
    if($LASTEXITCODE){throw 'Windows build failed.'}
    Push-Location $BuildDirectory
    try {ctest -C Release --output-on-failure;if($LASTEXITCODE){throw 'Windows tests failed.'}}finally{Pop-Location}
    Write-Output ('Build and tests passed. Package with: python tools/package.py --binaries "'+(Join-Path $BuildDirectory 'Release')+'"')
} finally {Pop-Location}
