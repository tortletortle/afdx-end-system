# Continue3: isolate all verification outputs under this directory.
# Invoke from any directory; source RTL and baseline project files are read-only.
$ErrorActionPreference = 'Stop'
$root = 'C:/Workspace/diansai'
$out = "$root/out/arena-debug/continue3"
Set-Location $root
$qsf = [IO.File]::ReadAllLines("$root/elinx/prj/quartus/AFDX_top.qsf", [Text.Encoding]::UTF8)
$sources = @()
foreach ($line in $qsf) {
  if ($line -match '^set_global_assignment -name VERILOG_FILE "C:/Workspace/diansai/(rtl/[^"]+\.v)"') {
    $sources += $Matches[1]
  }
}
if ($sources.Count -ne 24) { throw "Expected 24 explicit RTL files; found $($sources.Count)" }
New-Item -ItemType Directory -Force -Path "$out/raw", "$out/project", "$out/sim/tb", "$out/sim/vec", "$out/sim/out", "$out/work" | Out-Null
$digests = @()
foreach ($relative in $sources) {
  $dest = "$out/$relative"
  New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
  Copy-Item -LiteralPath "$root/$relative" -Destination $dest -Force
  $srcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath "$root/$relative").Hash
  $dstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash
  if ($srcHash -ne $dstHash) { throw "Source snapshot mismatch: $relative" }
  $digests += "$srcHash  $relative"
}
foreach ($name in @('AFDX_top.qpf','AFDX_top.qsf')) {
  Copy-Item -LiteralPath "$root/elinx/prj/quartus/$name" -Destination "$out/project/$name" -Force
}
foreach ($name in @('compile.tcl','run_one.tcl')) {
  Copy-Item -LiteralPath "$root/sim/$name" -Destination "$out/sim/$name" -Force
}
foreach ($name in @('tb_t01_reset_regs.v','tb_t11_top_port.v')) {
  Copy-Item -LiteralPath "$root/sim/tb/$name" -Destination "$out/sim/tb/$name" -Force
}
Copy-Item -LiteralPath "$root/sim/vec/t08a_frames.hex" -Destination "$out/sim/vec/t08a_frames.hex" -Force
[IO.File]::WriteAllLines("$out/sources.txt", [string[]]$sources, [Text.Encoding]::ASCII)
[IO.File]::WriteAllLines("$out/SOURCE_SHA256.txt", [string[]]$digests, [Text.Encoding]::ASCII)
$lintTop = @('--lint-only','-Wall','-Wno-fatal','-Wno-WIDTH','--top-module','AFDX_top','--Mdir','work/lint_top') + $sources
$lintReset = @('--lint-only','--timing','-Wall','-Wno-fatal','-Wno-WIDTH','--top-module','tb_reset_copy','--Mdir','work/lint_reset', 'rtl/common/rst_sync.v','sim/tb/tb_reset_copy.v')
[IO.File]::WriteAllLines("$out/lint_top.f", [string[]]$lintTop, [Text.Encoding]::ASCII)
[IO.File]::WriteAllLines("$out/lint_reset.f", [string[]]$lintReset, [Text.Encoding]::ASCII)
"Prepared isolated verification snapshot: 24 RTL, 2 TB, 1 vector, Quartus project. Output: $out" |
  Set-Content -LiteralPath "$out/raw/prepare.log" -Encoding ASCII
Get-Content -LiteralPath "$out/raw/prepare.log"
