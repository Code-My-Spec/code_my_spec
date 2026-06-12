<#
.SYNOPSIS
  Set up the full MSVC + Burrito toolchain environment, then run a mix command.

  Burrito's Windows release needs several tools that are NOT on the global PATH:
    - MSVC build tools (cl/nmake/link) for C NIFs (bcrypt_elixir) -> via vcvars64.bat
    - zig 0.15.2 (exact) to build the Burrito launcher
    - xz to compress the foilz payload
    - 7z (full, NSIS-capable) to unpack the downloaded otp_win64_*.exe ERTS
    - Rust (x86_64-pc-windows-msvc) + cargo for the ortex NIF

  Env vars do not persist between separate shells, so this script loads them
  fresh each run and then execs `mix $Args`.

.EXAMPLE
  pwsh -File scripts/win-build.ps1 -MixEnv prod_cli compile
  pwsh -File scripts/win-build.ps1 -MixEnv prod_cli -BurritoTarget windows release code_my_spec_cli
#>
[CmdletBinding()]
param(
  [string]$MixEnv = "prod_cli",
  [string]$BurritoTarget = "",
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$MixArgs
)

$ErrorActionPreference = "Stop"

$Tools  = "C:\Users\John Davenport\winbuild"
$ZigDir = "$Tools\zig-aarch64-windows-0.15.2"
$XzDir  = "$Tools\xz\bin_x86-64"
$SzDir  = "C:\Users\Public\winbuild\7zip"
$CargoHome  = "C:\Users\Public\winbuild\cargo"
$RustupHome = "C:\Users\Public\winbuild\rustup"

# --- MSVC env (vcvars64) ---
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found at $vcvars" }
cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
  if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:\$($matches[1])" -Value $matches[2] }
}

# --- Burrito toolchain on PATH ---
$env:RUSTUP_HOME = $RustupHome
$env:CARGO_HOME  = $CargoHome
$env:PATH = ($ZigDir, $XzDir, $SzDir, "$CargoHome\bin", $env:PATH) -join ';'

# --- Mix env ---
$env:MIX_ENV = $MixEnv
if ($BurritoTarget -ne "") { $env:BURRITO_TARGET = $BurritoTarget }

# --- Sanity report ---
function Probe($name) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { "  {0,-6} {1}" -f $name, $c.Source } else { "  {0,-6} MISSING" -f $name }
}
Write-Host "== toolchain =="
@('cl','nmake','zig','xz','7z','cargo','rustc','mix') | ForEach-Object { Write-Host (Probe $_) }
Write-Host "  MIX_ENV=$env:MIX_ENV BURRITO_TARGET=$env:BURRITO_TARGET"
Write-Host "== mix $($MixArgs -join ' ') =="

& mix @MixArgs
exit $LASTEXITCODE
