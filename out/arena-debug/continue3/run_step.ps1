# Run exactly one verification stage; raw stdout/stderr and process rc are retained.
param([ValidateSet('lint_top','lint_reset','compile','reset_tb','t01','t11','t11g','synth','map','sta','sta_guard','guard_selftest')][string]$Stage)
$ErrorActionPreference = 'Stop'
$root = 'C:/Workspace/diansai'
$out = "$root/out/arena-debug/continue3"
$sim = "$out/sim"
$proj = "$out/project"
$raw = "$out/raw"
$quartus = 'C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin'
$exe = ''
$arguments = ''
$workdir = $out
switch ($Stage) {
  lint_top {
    $exe = 'C:/Program Files (x86)/eHiWay/eLinx3.0/verilator/verilator.exe'
    $arguments = '-f lint_top.f'
  }
  lint_reset {
    $exe = 'C:/Program Files (x86)/eHiWay/eLinx3.0/verilator/verilator.exe'
    $arguments = '-f lint_reset.f'
  }
  compile {
    $exe = 'C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe'
    $workdir = $sim
    $src = @(Get-Content -LiteralPath "$out/sources.txt" -Encoding ASCII | ForEach-Object { "../$_" })
    $env:VLOG_SRC = (@($src) + @('tb/tb_reset_copy.v','tb/tb_t01_reset_regs.v','tb/tb_t11_top_port.v')) -join ' '
    $arguments = '-c -do "source compile.tcl"'
  }
  reset_tb {
    $exe = 'C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe'
    $workdir = $sim
    $env:TEST_TB = 'tb_reset_copy'
    $env:VSIM_ACC = '0'
    $arguments = '-c -do "source run_one.tcl"'
  }
  t01 {
    $exe = 'C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe'
    $workdir = $sim
    $env:TEST_TB = 'tb_t01_reset_regs'
    $env:VSIM_ACC = '0'
    $arguments = '-c -do "source run_one.tcl"'
  }
  t11 {
    $exe = 'C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe'
    $workdir = $sim
    $env:TEST_TB = 'tb_t11_top_port'
    $env:VSIM_ACC = '0'
    $arguments = '-c -do "source run_one.tcl"'
  }
  t11g {
    $exe = 'C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe'
    $workdir = $sim
    $env:TEST_TB = 'tb_t11g_top_port'
    $env:VSIM_ACC = '0'
    $arguments = '-c -do "source run_one.tcl"'
  }
  synth {
    $exe = 'C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe'
    $arguments = "-s $root/elinx/prj/AFDX_top_synth.ys -l $raw/synth.elinx.log"
  }
  map {
    $exe = "$quartus/quartus_map.exe"
    $workdir = $proj
    $arguments = 'AFDX_top -c AFDX_top'
  }
  sta {
    $exe = "$quartus/quartus_sta.exe"
    $workdir = $proj
    $arguments = '-t sta_continue3.tcl'
  }
  sta_guard {
    $exe = "$quartus/quartus_sta.exe"
    $workdir = $proj
    $env:DIANSAI_STA_OUT = "$raw/guarded"
    New-Item -ItemType Directory -Force -Path $env:DIANSAI_STA_OUT | Out-Null
    $arguments = "-t $root/elinx/prj/quartus/sta_post_map.tcl"
  }
  guard_selftest {
    $exe = "$quartus/quartus_sh.exe"
    $workdir = $proj
    $arguments = '-t guard_selftest.tcl'
  }
}
if (-not (Test-Path -LiteralPath $exe)) { throw "Executable unavailable for stage $Stage" }
$stdout = "$raw/$Stage.stdout.log"
$stderr = "$raw/$Stage.stderr.log"
$start = Get-Date
$p = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $workdir -NoNewWindow -PassThru `
  -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$null = $p.Handle
$p.WaitForExit()
$rc = $p.ExitCode
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds,1)
[IO.File]::WriteAllText("$raw/$Stage.rc", "$rc`n", [Text.Encoding]::ASCII)
$record = [ordered]@{
  started = $start.ToString('o'); stage = $Stage; cwd = $workdir;
  executable = $exe; arguments = $arguments; process_exit_code = $rc;
  wall_seconds = $elapsed; stdout = $stdout; stderr = $stderr
}
($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath "$out/COMMANDS.jsonl" -Encoding UTF8
Write-Output ("STAGE=$Stage RC=$rc WALL_S=$elapsed STDOUT=$stdout STDERR=$stderr")
if ($rc -ne 0) { exit $rc }
exit 0
