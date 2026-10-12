// 输入层：把实体/虚拟键盘、ADS1115、滑杆和压力转成演奏事件，不生成 PCM。
// A0/A1 是压力，A2 是音量，A3 是音高；ADC 数据是码值，不是电压或 kg。
// clk=27MHz，rst_n 异步低有效。默认实体输入，完整 UART 命令才开启虚拟输入。
// 无外部音频 clock enable；键盘按扫描帧更新，控制由完整 adc_valid 事件推进，
// 失联年龄、模式检测和 UART 仍每 clk 工作，不能把 ADC 采样率当音频帧率。
// VIRTUAL_ADC_CYCLES 默认63390个 clk/结果，范围1..65536以匹配16位 timer。
// note_on/off 和 hit0/1 是单 clk 事件；note 为7位音符号，velocity 为0..255，
// timbre/selected_timbre 为0..15。key_state bit0..15对应S1..S16，1表示按下。
// slider_volume 为0..255，slider_pitch 为9位有符号码（本映射输出-128..127）。
// digital_zero_test 是持续零PCM请求；adc_fault 为当前源故障，adc_stale 为
// 距任一有效源样本已过0.5秒，不是四通道逐一的新鲜度保证。
// monitor_ready 为 pads_ready && sliders_ready，不代表压力模块已完成校准；
// monitor_adc 四个16位码从低位起是A0/A1/A2/A3，monitor_remote 表示选中虚拟源。
// suppress_controls 交由相关子模块屏蔽选择/诊断操作，不停止扫描或 ADC 采集。
module instrument_inputs #(parameter VIRTUAL_ADC_CYCLES=63390)(
    input clk,input rst_n,
    output [3:0] matrix_rows,input [3:0] matrix_cols,
    inout adc_scl,inout adc_sda,input uart_rx,output uart_tx,
    input synth_overrun,input suppress_controls,
    output note_on,output note_off,output [6:0] note,
    output [7:0] velocity,output [3:0] timbre,
    output [15:0] key_state,output [3:0] selected_timbre,output keypad_ghost,
    output [7:0] slider_volume,output signed [8:0] slider_pitch,
    output hit0,output hit1,output [7:0] velocity0,output [7:0] velocity1,
    output digital_zero_test,output adc_fault,output adc_stale,
    output monitor_ready,output monitor_remote,output [63:0] monitor_adc
);
    localparam ADC_STALE_CYCLES=13500000; // 0.5s 没有完整 ADC 结果视为失联。
    wire remote_active,remote_zero,remote_park,physical_zero_test;
    wire [15:0] remote_keys;
    wire [7:0] remote_velocity;
    wire [63:0] remote_adc;
    wire hw_adc_valid,hw_adc_fault;
    wire [1:0] hw_adc_channel;
    wire [15:0] hw_adc_data;
    wire adc_valid,sliders_ready,pads_ready;
    wire [1:0] adc_channel;
    wire [15:0] adc_data;
    reg [63:0] physical_adc;
    reg remote_previous;
    reg [1:0] pad_seen;
    reg [23:0] adc_age;
    reg [15:0] virtual_timer;
    reg [2:0] virtual_step;
    reg virtual_valid;
    reg [1:0] virtual_channel;
    reg [15:0] virtual_data;

    // 模式改变时只初始化滑杆/压力状态，避免把实体基线带入虚拟测试。
    // 合成器不复位；松键及尾音仍由正常音符事件和包络处理。
    always @(posedge clk or negedge rst_n)
        if(!rst_n) remote_previous<=0;else remote_previous<=remote_active;
    wire mode_changed=(remote_previous!=remote_active);
    wire controls_rst_n=rst_n && !mode_changed;
    assign digital_zero_test=physical_zero_test || (remote_active && remote_zero);

    // ACK 可回显最近的实体 ADC 缓存。失联/暂停时缓存可能过期，必须同时看
    // 故障标志，不能仅凭缓存数值证明传感器正在更新或手指真的在动。
    always @(posedge clk or negedge rst_n)
        if(!rst_n) physical_adc<=0;
        else if(hw_adc_valid) physical_adc[hw_adc_channel*16 +: 16]<=hw_adc_data;

    // 虚拟 ADC 沿用健康实体的 0,1,2,0,1,3 优先序，压力更新快于滑杆。
    // 每63390 clk发布一结果；六步序列中各压力通道间隔三步，名义约7.043ms。
    // 这是虚拟发布间隔，不证明实体 I2C 每次转换的实测时长。
    // 这里只模拟数字采样节奏，不模拟模拟电路、总线噪声或硬件故障。
    function [1:0] scheduled_channel;
        input [2:0] step;
        begin case(step)
            0,3:scheduled_channel=0;1,4:scheduled_channel=1;
            2:scheduled_channel=2;default:scheduled_channel=3;
        endcase end
    endfunction
    // 命令原子提交的四路码按固定序列分次发布，避免一次clk把四路都冒充新样本。
    // 来源切换清计数/序列；valid 仅为一次发布事件，数据在下一次事件前保持。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            virtual_timer<=0;virtual_step<=0;virtual_valid<=0;
            virtual_channel<=0;virtual_data<=0;
        end else begin
            virtual_valid<=0;
            if(!remote_active || mode_changed) begin virtual_timer<=0;virtual_step<=0;end
            else if(virtual_timer==VIRTUAL_ADC_CYCLES-1) begin
                virtual_timer<=0;virtual_valid<=1;
                virtual_channel<=scheduled_channel(virtual_step);
                virtual_data<=remote_adc[scheduled_channel(virtual_step)*16 +: 16];
                virtual_step<=(virtual_step==5)?0:virtual_step+1'b1;
            end else virtual_timer<=virtual_timer+1'b1;
        end
    end

    // ACK flags 高位：bit7 合成超时，bit6 鬼键，bit5 滑杆就绪，
    // bit4 当前数据过期，bit3 实体 ADC 故障；低三位由 UART 模块填入。
    wire [7:0] remote_status={synth_overrun,keypad_ghost,sliders_ready,adc_stale,hw_adc_fault,3'b000};
    remote_debug_link link(.clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .physical_keys(key_state),.physical_adc(physical_adc),.status_flags(remote_status),
        .remote_active(remote_active),.zero_mode(remote_zero),.park_i2c(remote_park),
        .virtual_keys(remote_keys),.velocity(remote_velocity),.virtual_adc(remote_adc),
        .accepted(),.last_seq());

    // S15+S16 持续按住进入零 PCM 参考；鬼键不能触发。UART 也可直接请求。
    headphone_mute_guard mute_guard(.clk(clk),.rst_n(rst_n),.key_state(suppress_controls?16'd0:key_state),
        .ghost(keypad_ghost),.mute_active(physical_zero_test));
    ads1115_reader #(.PRESSURE_PRIORITY(1)) adc(
        .clk(clk),.rst_n(rst_n && !digital_zero_test && !(remote_active && remote_park)),
        .scl(adc_scl),.sda(adc_sda),.sample_valid(hw_adc_valid),
        .sample_channel(hw_adc_channel),.sample_data(hw_adc_data),.fault(hw_adc_fault));
    assign adc_valid=remote_active?virtual_valid:hw_adc_valid;
    assign adc_fault=remote_active?1'b0:hw_adc_fault;
    assign adc_channel=remote_active?virtual_channel:hw_adc_channel;
    assign adc_data=remote_active?virtual_data:hw_adc_data;
    assign adc_stale=(adc_age>=ADC_STALE_CYCLES);

    // 两个压力通道都至少收到一个有效样本才允许开始校准。
    // 按键通路不依赖 ready，ADC 出错也不阻塞键盘发声。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin pad_seen<=0;adc_age<=ADC_STALE_CYCLES;end
        else begin
            if(adc_valid) adc_age<=0;
            else if(adc_age<ADC_STALE_CYCLES) adc_age<=adc_age+1'b1;
            if(mode_changed || adc_fault || digital_zero_test || adc_stale) pad_seen<=0;
            else if(adc_valid && adc_channel<2) pad_seen[adc_channel]<=1;
        end
    end
    assign pads_ready=(&pad_seen) && !adc_fault && !adc_stale && !digital_zero_test;
    slider_controls sliders(.clk(clk),.rst_n(controls_rst_n),.adc_valid(adc_valid),
        .adc_channel(adc_channel),.adc_data(adc_data),.volume(slider_volume),
        .pitch(slider_pitch),.ready(sliders_ready));
    pressure_adaptive pads(.clk(clk),.rst_n(controls_rst_n),.ready(pads_ready),
        .adc_valid(adc_valid),.adc_channel(adc_channel),.adc_data(adc_data),
        .hit0(hit0),.hit1(hit1),.velocity0(velocity0),.velocity1(velocity1),
        .calibrated(),.armed_status());

    // S1..S12 是音高；S13/S14 前/后音色，S15/S16 留给界面，共16种音色。
    // 松开才确认选择，给诊断组合留出识别时间，避免误改音色。
    matrix_keypad #(.DEBOUNCE_FRAMES(3),.PERFORMANCE_MODE(1),.SELECT_ON_RELEASE(1),.TWO_BUTTON_SELECT(1)) u_keypad(
        .suppress_select(suppress_controls),.clk(clk),.rst_n(rst_n),.rows(matrix_rows),.cols(matrix_cols),
        .virtual_enable(remote_active),.virtual_keys(remote_keys),
        .velocity(remote_active?remote_velocity:8'd160),
        .note_on(note_on),.note_off(note_off),.note(note),.vel_out(velocity),
        .timbre_out(timbre),.key_state(key_state),.ghost_active(keypad_ghost),
        .selected_timbre(selected_timbre));
// HDMI旁路只读这些状态，不改变输入处理。
    assign monitor_ready=pads_ready && sliders_ready;
    assign monitor_remote=remote_active;
    assign monitor_adc=remote_active?remote_adc:physical_adc;
endmodule
