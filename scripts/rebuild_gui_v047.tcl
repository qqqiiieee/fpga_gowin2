# Portable native Gowin Tcl entry. Run with `source {path/to/this/file}` in
# an already licensed IDE. No download/programming commands are issued.
set project_root [file normalize [file join [file dirname [info script]] ..]]
cd $project_root
open_project [file join $project_root instrument_handoff.gprj]
set_option -top_module top
# ADS SCL uses N9; this dual-purpose pin must remain GPIO after configuration.
set_option -use_sspi_as_gpio 1
set_option -place_option 0
set_option -route_option 0
run all
