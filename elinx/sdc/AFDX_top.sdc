# =====================================================================
# AFDX_top.sdc - Quartus/TimeQuest timing constraints (MISSION-CONTINUE2)
#
# This file MUST stay in sync with elinx/sdc/AFDX_top.edc (the eLinx-side
# copy).  Both encode design book 11.2: a single 125 MHz system clock.
#
# Deliberate boundary: there is NO set_input_delay / set_output_delay here.
# The design book lists nominal 3.2 ns IO delays only as a commented
# *example*, not as a measured board budget, and no pinout or board exists.
# Inventing IO delays to manufacture a PASS is forbidden.  Consequently every
# conclusion drawn from this file covers REGISTER-TO-REGISTER INTERNAL PATHS
# ONLY; all IO ports are reported as unconstrained and that is expected.
#
# If this file is absent, Quartus silently falls back to a default 1 ns
# (1 GHz) clock and every slack number becomes meaningless - that failure
# mode actually occurred once in this project; see out/arena-debug/continue2/
# sta/default_1ns_no_sdc/ for the discarded reports.
# =====================================================================

# NOTE on syntax divergence from the .edc: Quartus TimeQuest does NOT accept the
# Synopsys form "set_clock_uncertainty <value> <object>" (it rejects the file and
# then falls back to a default 1 ns clock).  It requires -from/-to plus an explicit
# -setup/-hold.  "set_clock_transition" is a Synopsys DC command with no Quartus
# TimeQuest equivalent, so it is intentionally not replicated here; the 0.30 ns
# transition stays in the .edc for the eLinx flow only.

create_clock -name clk -period 8.000 [get_ports clk]

set_clock_uncertainty -setup -from [get_clocks clk] -to [get_clocks clk] 0.45
set_clock_uncertainty -hold  -from [get_clocks clk] -to [get_clocks clk] 0.45

# PPS is an asynchronous 1 Hz pulse captured by a synchroniser inside the
# design; it is not a timed interface.
set_false_path -from [get_ports pps_in]
