# Build the Windows diagnostic without installing or running it.
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64',
    [string]$BuildDirectory = (Join-Path $PSScriptRoot 'build')
)
$ErrorActionPreference = 'Stop'
# --- Toolchain validation and build ---

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Build on Windows 10/11 with Visual Studio C++ Build Tools, Windows SDK and CMake.'
}
$cmake = (Get-Command cmake -ErrorAction Stop).Source
& $cmake -S $PSScriptRoot -B $BuildDirectory -A $Architecture
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed ($LASTEXITCODE)." }
& $cmake --build $BuildDirectory --config $Configuration
if ($LASTEXITCODE -ne 0) { throw "CMake build failed ($LASTEXITCODE)." }
Write-Output "Built diagnostic source; nothing installed or started: $BuildDirectory\$Configuration\CRDWindowProbe.exe"
