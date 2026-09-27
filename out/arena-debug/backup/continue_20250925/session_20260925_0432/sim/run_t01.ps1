# =====================================================================
# run_t01.ps1 - T01 smoke one-click run (auto-locate vsim + license)
# Usage: in sim/ dir:
#   powershell -ExecutionPolicy Bypass -File .\run_t01.ps1
# Notes:
#   - Questasim Starter license: SALT_LICENSE_SERVER (set by installer at
#     user level). Persistent shells (e.g. MCP bridge) started before the
#     install do not inherit it - this script restores it from the user
#     profile automatically.
#   - vsim batch entry: -c -do "source run_t01.tcl" (tcl ends with quit -f)
# =====================================================================
$cands = @(
  "C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe",
  "C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe",
  "C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"
)
$vsim = $null
foreach ($c in $cands) { if (Test-Path $c) { $vsim = $c; break } }
if (-not $vsim) {
  $f = Get-ChildItem "C:\altera_pro" -Recurse -Filter "vsim.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { $vsim = $f.FullName }
}
if (-not $vsim) {
  Write-Output "ERROR: vsim.exe not found (Questasim not installed or non-default location)"
  exit 1
}
# --- license env (Starter embedded license, file-based SALT keyring) ---
$licUser = [Environment]::GetEnvironmentVariable('SALT_LICENSE_SERVER','User')
if (-not $env:SALT_LICENSE_SERVER -and $licUser) {
  $env:SALT_LICENSE_SERVER = $licUser
  Write-Output ("LICENSE-RESTORE: " + $licUser)
}
if (-not $env:SALT_LICENSE_SERVER) {
  Write-Output "ERROR: SALT_LICENSE_SERVER not set (license component missing?)"
  exit 1
}
Write-Output ("vsim: " + $vsim)
# sanity: version check must pass before the full run
$v = & $vsim -version 2>&1
Write-Output ("vsim -version => " + ($v | Select-Object -First 1 -Skip 0))
if ($LASTEXITCODE -ne 0) {
  Write-Output "ERROR: vsim -version failed (license?), exit=$LASTEXITCODE"
  exit 1
}
Push-Location $PSScriptRoot
try {
  if (-not (Test-Path out)) { New-Item -ItemType Directory -Path out | Out-Null }
  $clog = "out/run_t01_console.txt"
  Remove-Item $clog -Force -ErrorAction SilentlyContinue
  $sw = [Diagnostics.Stopwatch]::StartNew()
  cmd /c "`"$vsim`" -c -do `"source run_t01.tcl`" > $clog 2>&1"
  $rc = $LASTEXITCODE
  Write-Output ("vsim exit=" + $rc + " wall_s=" + [math]::Round($sw.Elapsed.TotalSeconds,1))
  Write-Output ("console log: " + (Resolve-Path $clog))
  Get-Content $clog -Encoding UTF8 | Write-Output
} finally { Pop-Location }
exit $rc
