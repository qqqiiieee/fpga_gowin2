# Run from the already licensed IDE, with instrument_handoff.gprj open.
# The GUI caches its source list; explicitly add the two V047 modules.
add_file -type verilog {D:/Gowin_project/instrument_phone_extensions_20261031/src/guide_chord_modes.v}
add_file -type verilog {D:/Gowin_project/instrument_phone_extensions_20261031/src/guide_chord_events.v}
set_option -top_module top
set_option -use_sspi_as_gpio 1
set_option -place_option 0
set_option -route_option 0
run all
