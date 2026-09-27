# Fail closed if TimeQuest silently substitutes the default 1 ns clock.
# Validate the generated report, not merely the SDC_FILE assignment in QSF.
proc check_sdc_8ns {report_path} {
  set f [open $report_path r]
  set content [read $f]
  close $f
  if {![regexp {;[[:space:]]*create_clock[[:space:]]*;[[:space:]]*clk[[:space:]]*;[[:space:]]*8\.000[[:space:]]*;} $content]} {
    error "SDC_GUARD_FAILED: expected actual clk create_clock period 8.000 ns in $report_path"
  }
  return 1
}
