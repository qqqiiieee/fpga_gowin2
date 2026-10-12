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
