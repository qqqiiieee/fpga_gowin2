set project_root [file dirname [file normalize [info script]]]
cd $project_root
open_project [file join $project_root instrument_handoff.gprj]
set_option -top_module top
# N9 is an SSPI dual-purpose pin; use as GPIO after configuration.
set_option -use_sspi_as_gpio 1
# Per-lane reset release FFs reduce RESET fanout; use default PnR algorithms.
set_option -place_option 0
set_option -route_option 0
run all
exit
