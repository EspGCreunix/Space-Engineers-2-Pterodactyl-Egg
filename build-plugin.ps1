param(
  [string]$Game2 = 'C:\Program Files (x86)\Steam\steamapps\common\SpaceEngineers2\Game2',
  [string]$PulsarModern = ''
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'Y51_SE2Online\Y51_SE2Online.csproj'
$generator = Join-Path $PSScriptRoot 'Y51_SE2Online\Pulsar\VRage.Library.Generator.dll'
if (-not (Test-Path (Join-Path $Game2 'SpaceEngineers2.dll'))) { throw "Game2 not found: $Game2" }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Install/authorize a .NET SDK before building.' }
$props = @("/p:SE2Bin=$Game2")
if ($PulsarModern) { $props += "/p:PulsarModern=$PulsarModern" }
dotnet build $project -c Release @props
if ($LASTEXITCODE -ne 0) { throw 'Y51 compilation failed; review the first compiler errors above.' }
$built = Join-Path (Split-Path $project) 'bin\Release\Y51_SE2Online.dll'
if (-not (Test-Path $built)) { throw "Build output missing: $built" }
Copy-Item $built (Join-Path (Split-Path $project) 'plugin.dll') -Force
Write-Host "Build output staged: $(Join-Path (Split-Path $project) 'plugin.dll')"
