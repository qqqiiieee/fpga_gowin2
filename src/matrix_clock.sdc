# 27MHz源域与PLL生成时钟；层级名称与HDMI模块实例绑定。
# toggle握手只对首级同步器放宽；多位held_status保持期间仍要求39ns整包最大延迟。
# hold例外适用于异步整包路径，不等于把整个显示域设成false path。
# reset_sync首级异步CLEAR例外保留，各域同步释放由RTL实现；改层级须核对实际命中。
create_clock -name clk27 -period 37.037037 [get_ports {clk}]
create_generated_clock -name serial126 -source [get_ports {clk}] -multiply_by 14 -divide_by 3 [get_pins {u_display/u_clocks/u_pll/CLKOUT}]
create_generated_clock -name pixel25_2 -source [get_pins {u_display/u_clocks/u_pll/CLKOUT}] -divide_by 5 [get_pins {u_display/u_clocks/u_div/CLKOUT}]
set_false_path -to [get_cells {*u_status/req_meta*}]
set_false_path -to [get_cells {*u_status/ack_meta*}]
set_false_path -to [get_cells {*u_scope/req_meta*}]
set_false_path -to [get_cells {*u_scope/ack_meta*}]
set_max_delay 39.0 -from [get_cells {*u_status/held_status*}] -to [get_cells {*u_status/pending_status*}]
set_false_path -hold -from [get_cells {*u_status/held_status*}] -to [get_cells {*u_status/pending_status*}]
set_max_delay 39.0 -from [get_cells {*u_scope/capture_gain*}] -to [get_cells {*u_scope/scope_gain*}]
set_false_path -hold -from [get_cells {*u_scope/capture_gain*}] -to [get_cells {*u_scope/scope_gain*}]
set_false_path -to [get_pins {*reset_sync*/CLEAR}]
# V036 visual banks cross only single-bit request/ack toggles. The first
# metastability stage is asynchronous; its second stage remains timed.
# Source/pixel_ready are the only registers receiving the common async reset;
# all functional control registers use their own domain's synchronized release.
# Do not false-path either entire clock domain or the dual-clock RAM data ports.
set_false_path -to [get_cells {*visualization.buffers/fft_req_meta*}]
set_false_path -to [get_cells {*visualization.buffers/xy_req_meta*}]
set_false_path -to [get_cells {*visualization.buffers/fft_ack_meta*}]
set_false_path -to [get_cells {*visualization.buffers/xy_ack_meta*}]
set_false_path -to [get_pins {*visualization.buffers/source_ready*/CLEAR}]
set_false_path -to [get_pins {*visualization.buffers/pixel_ready*/CLEAR}]

# V041 custom-score bundled-data handshake: request/ack first stages alone
# are asynchronous. Their synchronizer second/third stages remain timed.
# held_config stays constant until pixel frame-commit is acknowledged; capture
# occurs after three pixel synchronizer clocks, so bound the entire bus to 39ns.
# This is a DATA maximum, not a false path over the display/audio clock domains.
set_false_path -to [get_cells {*custom_score.req_meta*}]
set_false_path -to [get_cells {*custom_score.ack_meta*}]
set_false_path -to [get_cells {extension_state/ack_meta*}]
set_max_delay 39.0 -from [get_cells {*custom_score.held_config*}] -to [get_cells {*custom_score.pending_config*}]
set_false_path -hold -from [get_cells {*custom_score.held_config*}] -to [get_cells {*custom_score.pending_config*}]
