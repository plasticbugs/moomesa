# ==============================================================================
# Cowboys of Moo Mesa on the Pocket: timing constraints beyond the BSP's
# sys_constr.sdc. The 96 MHz system clock, its 8 MHz video pair and the
# shifted SDRAM clock all come from core_pll and are timed as one related
# group; the two 74.25 MHz inputs and the audio PLL are asynchronous to it.
# The PLL's fifth output drives nothing in core_top, so no clock of its own
# reaches the netlist and it is not named here -- naming it only bought an
# ignored-filter warning that hid the ones that mattered.
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# SDRAM: the chip is clocked by the phase-shifted PLL output (core_pll's
# outclk_3).  The shift divides the budget between two checks that pull
# opposite ways: the data the chip returns is captured by an I/O-cell register
# on the core clock, and the address and command the core drives are captured
# by the chip.  On the captured data, setup gets 2T - shift and hold gets
# T - shift, so a nanosecond off the shift is a nanosecond onto setup and a
# nanosecond off hold.
#
# THE SHIFT IS PER-DESIGN.  5.859 ns is where Master of Weapon's fit balanced
# (setup slack = 6.241 - shift at slow 85C, hold slack = shift - 5.519 at fast
# 0C); the board is the same for every core but the fit is not.  If the worst
# path in a build is dram_dq[*] -> sdram_ctrl|dq_in[*], measure both slacks at
# two shift values, solve for where they meet, and round to a multiple of
# 130.2 ps, the step the 960 MHz VCO can make.  projects/report_worst.tcl
# writes the reports to read: worst_paths*.txt for setup, worst_hold_fast.txt
# for hold.  METHODOLOGY.md section 5.20.
create_generated_clock -name dram_clk -source \
    [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {dram_clk}]
set_input_delay -max -clock dram_clk 7.0 [get_ports {dram_dq[*]}]
set_input_delay -min -clock dram_clk 2.5 [get_ports {dram_dq[*]}]
set SDRAM_OUT [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -max -clock dram_clk  1.5 $SDRAM_OUT
set_output_delay -min -clock dram_clk -0.8 $SDRAM_OUT
set_multicycle_path -setup 2 -from [get_clocks {dram_clk}] -to [get_registers {*|sdram_ctrl:*|dq_in[*]}]
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# The pixel hand-over to the 8 MHz video clock. The dot enable's phase is
# pinned to clk_vid (core_top.sv's pix_sync into clk_enables.sv), so the
# colour and sync registers are launched a fixed number of system clocks
# before the clk_vid edge that samples them, and the setup check starts from
# that launch edge. The toggle the other way (vt -> vt_s) is a plain
# flop-to-flop path, checked as it stands.
set VID_OUT [get_registers {ic|vr_q[*] ic|vg_q[*] ic|vb_q[*] ic|vhs_q ic|vvs_q ic|vde_q}]
set_multicycle_path -setup 3 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT
set_multicycle_path -hold  2 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT

# SRAM: registered pins held for whole system cycles, a read sampled several
# cycles after the address (target/pocket/sram_port.sv), so the pins are not
# timed against a clock.
set_false_path -to   [get_ports {sram_*}]
set_false_path -from [get_ports {sram_dq[*]}]

# The PSRAMs are unused on this board; the BSP still brings their pins out.
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]

# ------------------------------------------------------------------------------
# The 68000.  fx68k changes state only on enPhi1 or enPhi2, which
# rtl/clk_enables.sv raises three system clocks apart (a 16 MHz CPU in a
# 96 MHz domain: div % 6 == 0 and == 3), so every path that both starts and
# ends inside fx68k has three clocks.  The filter is fx68k's own registers
# only; its bus inputs (iEdb, DTACKn, VPAn, IPL) come from moomesa_core's
# registers and are single-cycle paths into it, checked as they stand.
set M68K [get_keepers {*|fx68k:u_68k|*}]
set_multicycle_path -setup 3 -from $M68K -to $M68K
set_multicycle_path -hold  2 -from $M68K -to $M68K

# ------------------------------------------------------------------------------
# The YM2151 (jt51).  Every register in jt51's operator pipeline (jt51_pg and
# the blocks after it) loads only on cen_p1, the 2 MHz enable, every 48 system
# clocks.  What feeds them is either that pipeline (changing on cen_p1) or
# jt51's register file, which changes on the clock after a write strobe --
# and moomesa_core hands jt51 its writes only on the clock after a 2 MHz
# enable (rtl/moomesa_core.sv, "YM2151").  So every path into these registers
# has 47 clocks; 24 is claimed.  Paths from outside jt51 (the strobe, the data
# latch) end in the register file, not here, and stay single-cycle.
set JT51_PIPE [get_keepers {*|jt51:u_ym|jt51_pg:u_pg|*}]
set_multicycle_path -setup 24 -from [get_keepers {*|jt51:u_ym|*}] -to $JT51_PIPE
set_multicycle_path -hold  23 -from [get_keepers {*|jt51:u_ym|*}] -to $JT51_PIPE

# ------------------------------------------------------------------------------
# The Z80 (tv80_core, through rtl/z80_cen.sv).  Every clocked block in
# tv80_core and tv80_reg loads only on ClkEn (= cen, bus requests being tied
# off) or cen itself, and cen is cen_z80, every 12 system clocks
# (rtl/clk_enables.sv: div % 12 == 1).  So every path that starts and ends in
# tv80_core has 12 clocks.  Its inputs from outside (wait_n, int_n, the data
# bus) come from moomesa_core's registers and are not in this filter.
set Z80 [get_keepers {*|z80_cen:u_z80|tv80_core:u_core|*}]
set_multicycle_path -setup 12 -from $Z80 -to $Z80
set_multicycle_path -hold  11 -from $Z80 -to $Z80

# ------------------------------------------------------------------------------
# Multicycle exceptions for other clock-enabled blocks go here.  Before adding
# any, read METHODOLOGY.md sections 5.11 and 5.20:
#
#   * write down why EVERYTHING the filter matches qualifies, and register
#     every input at the edge of the relaxed region;
#   * a register Quartus merges into a block RAM's output no longer exists by
#     name, the filter matches nothing, and the line is ignored with a warning
#     -- CI fails the build on that (Check every constraint was applied);
#   * a block RAM read closes on one clock.  Leave it alone.
#
# The shape the sibling cores use, proven on hardware, for a CPU that steps on
# clock enables four or more system clocks apart:
#
#   set M68K [get_keepers {*|fx68k:*|*}]
#   set_multicycle_path -setup 4 -from $M68K -to $M68K
#   set_multicycle_path -hold  3 -from $M68K -to $M68K
# ------------------------------------------------------------------------------
