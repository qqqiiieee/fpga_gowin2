set project_root [file dirname [file normalize [info script]]]
cd $project_root
open_project [file join $project_root instrument_handoff.gprj]
set_option -top_module top
run all
exit
