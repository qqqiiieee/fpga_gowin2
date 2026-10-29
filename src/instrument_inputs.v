// 输入层：把实体/虚拟键盘、ADS1115、滑杆和压力转成演奏事件，不生成 PCM。
// A0/A1 是压力，A2 是音量，A3 是音高；ADC 数据是码值，不是电压或 kg。
// clk=27MHz，rst_n 异步低有效。默认实体输入，完整 UART 命令才开启虚拟输入。
// 无外部音频 clock enable；键盘按扫描帧更新，控制由完整 adc_valid 事件推进，
// 失联年龄、模式检测和 UART 仍每 clk 工作，不能把 ADC 采样率当音频帧率。
// VIRTUAL_ADC_CYCLES 默认63390个 clk/结果，范围1..65536以匹配16位 timer。
// note_on/off 和 hit0/1 是单 clk 事件；V020生产hit0/1仅来自MIDI pads，FSR不触发鼓。
// pressure_brightness/vibrato是0..255连续表情，calibrated两位对应A0/A1的基线就绪。
// PRESSURE_EXPRESSION_ENABLE默认0供历史独立调用，根top显式1；note为7位，velocity为0..255，
// timbre/selected_timbre 保留4位总线，生产仅0/1：柔和长笛/拨弦。
// key_state bit0..15对应S1..S16，1表示按下；总线宽度不表示音色数量。
// slider_volume 为0..255，slider_pitch 为9位有符号码（本映射输出-128..127）。
// digital_zero_test 是持续零PCM请求；adc_fault 为当前源故障，adc_stale 为
// 距任一有效源样本已过0.5秒，不是四通道逐一的新鲜度保证。
// monitor_ready 为 pads_ready && sliders_ready，不代表压力模块已完成校准；
// 表情使用前还要看pressure_calibrated；屏幕“明亮/VIB”显示平滑后的level而非力/质量。
// monitor_adc 四个16位码从低位起是A0/A1/A2/A3，monitor_remote 表示选中虚拟源。
// suppress_controls 交由相关子模块屏蔽选择/诊断操作，不停止扫描或 ADC 采集。
module instrument_inputs #(parameter VIRTUAL_ADC_CYCLES=63390,parameter TOUCH_ENABLE=0,
    parameter PRESSURE_EXPRESSION_ENABLE=0,
    parameter MIDI_ENABLE=0,parameter OPTICAL_ENABLE=0,parameter MIDI_CHANNEL=0)(
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
    output monitor_ready,output monitor_remote,output [63:0] monitor_adc,
    output touch_cs_n,output touch_sclk,output touch_mosi,input touch_miso,
    input midi_rx,input [1:0] optical_beams,input sample_tick,input allow_performance,
    output [1:0] note_source,output panic_audio,output [11:0] performance_keys,
    output [6:0] external_note,output external_note_valid,
    output [7:0] pressure_brightness,output [7:0] pressure_vibrato,
    output [1:0] pressure_calibrated
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
    wire local_on,local_off,local_hit0,local_hit1;
    wire legacy_hit0,legacy_hit1;
    wire [7:0] legacy_velocity0,legacy_velocity1;
    wire [6:0] local_note;
    wire [7:0] local_velocity,physical_volume,local_velocity0,local_velocity1;
    wire [3:0] local_timbre;
    wire signed [8:0] physical_pitch;
    wire midi_hit0,midi_hit1;
    wire [7:0] midi_velocity0,midi_velocity1;
    wire program_valid;wire [3:0] program_timbre;
    wire [13:0] external_diagnostic;

    // G/V/S触摸板只有一路模拟编码：经MCP3208 CH0读取，不冒充数字矩阵列。
    // 单键触摸负责演奏，原矩阵可选保留菜单组合键；ADC的采集不依赖ADS1115。
    wire [15:0] touch_keys;
    wire [11:0] touch_raw;
    wire touch_valid,touch_fault,touch_sample_valid;
    wire [11:0] touch_sample;
    wire cal_write;
    wire [3:0] cal_index;
    wire [11:0] cal_value;
    reg [15:0] touch_sequence;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)touch_sequence<=0;
        else if(touch_sample_valid)touch_sequence<=touch_sequence+1'b1;
    wire [63:0] touch_diagnostic={touch_sequence,external_diagnostic,touch_fault,touch_valid,touch_keys,4'd0,touch_raw};
    generate if(TOUCH_ENABLE) begin:touch_input
        mcp3208_reader #(.POLL_CYCLES(5400)) reader(.clk(clk),.rst_n(rst_n),.channel(3'd0),
            .cs_n(touch_cs_n),.sclk(touch_sclk),.mosi(touch_mosi),.miso(touch_miso),
            .sample_valid(touch_sample_valid),.sample_data(touch_sample),.sample_channel());
        analog_touch_keypad decode(.clk(clk),.rst_n(rst_n),
            .sample_valid(touch_sample_valid),.sample_data(touch_sample),
            .cal_write(cal_write),.cal_index(cal_index),.cal_value(cal_value),
            .keys(touch_keys),.raw_value(touch_raw),.valid(touch_valid),.fault(touch_fault));
    end else begin:no_touch_input
        assign touch_cs_n=1'b1;assign touch_sclk=1'b0;assign touch_mosi=1'b0;
        assign touch_keys=0;assign touch_raw=0;assign touch_valid=0;assign touch_fault=0;
        assign touch_sample_valid=0;assign touch_sample=0;
    end endgenerate

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
    remote_debug_link #(.DIAG_ENABLE(TOUCH_ENABLE || MIDI_ENABLE || OPTICAL_ENABLE),
        .CALIB_ENABLE(TOUCH_ENABLE)) link(.clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .physical_keys(key_state),.physical_adc(physical_adc),.status_flags(remote_status),
        .remote_active(remote_active),.zero_mode(remote_zero),.park_i2c(remote_park),
        .virtual_keys(remote_keys),.velocity(remote_velocity),.virtual_adc(remote_adc),
        .accepted(),.last_seq(),.diagnostic_data(touch_diagnostic),
        .cal_write(cal_write),.cal_index(cal_index),.cal_value(cal_value));

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
        .adc_channel(adc_channel),.adc_data(adc_data),.volume(physical_volume),
        .pitch(physical_pitch),.ready(sliders_ready));
    // V020生产将FSR改为连续表情：A0开合音色，A1揉弦深度；不再生成鼓击。
    // 默认参数0兼容旧独立模块测试；只有生产顶层明确选1。
    // 旧命名pads只服务默认兼容分支；生产参数1时输出无人使用，综合整体裁掉。
    pressure_adaptive pads(.clk(clk),.rst_n(controls_rst_n),.ready(pads_ready && !PRESSURE_EXPRESSION_ENABLE),
        .adc_valid(adc_valid),.adc_channel(adc_channel),.adc_data(adc_data),
        .hit0(legacy_hit0),.hit1(legacy_hit1),.velocity0(legacy_velocity0),.velocity1(legacy_velocity1),
        .calibrated(),.armed_status());
    generate if(PRESSURE_EXPRESSION_ENABLE) begin:expression_input
      pressure_expression expression(.clk(clk),.rst_n(controls_rst_n),.ready(pads_ready),
        .adc_valid(adc_valid),.adc_channel(adc_channel),.adc_data(adc_data),
        .level0(pressure_brightness),.level1(pressure_vibrato),.calibrated(pressure_calibrated));
      assign local_hit0=1'b0;assign local_hit1=1'b0;
      assign local_velocity0=8'd0;assign local_velocity1=8'd0;
    end else begin:legacy_pressure_drums
      assign pressure_brightness=8'd0;assign pressure_vibrato=8'd0;assign pressure_calibrated=2'b00;
      assign local_hit0=legacy_hit0;assign local_hit1=legacy_hit1;
      assign local_velocity0=legacy_velocity0;assign local_velocity1=legacy_velocity1;
    end endgenerate

    // S1..S12 是音高；S13/S14 前/后音色，S15/S16 留给界面，恰好两种音色。
    // 新ID0=柔和长笛（旧ID1），新ID1=拨弦（旧ID7）；音频bank映射由音频层负责。
    // 松开才确认选择，给诊断组合留出识别时间，避免误改音色。
    // 触摸前端3次稳定采样后，还经过1ms矩阵帧消抖；缩短旧4ms扫描帧的等待。
    // 未启用触摸的独立旧调用仍保持原27000clk/行，不改变历史参数语义。
    matrix_keypad #(.ROW_CYCLES(TOUCH_ENABLE?6750:27000),
        .DEBOUNCE_FRAMES(3),.PERFORMANCE_MODE(1),.SELECT_ON_RELEASE(1),
        .TWO_BUTTON_SELECT(1),.TIMBRE_COUNT(2),.EXTERNAL_KEYS_ENABLE(TOUCH_ENABLE),
        .EXTERNAL_TIMBRE_ENABLE(MIDI_ENABLE)) u_keypad(
        .suppress_select(suppress_controls),.clk(clk),.rst_n(rst_n),.rows(matrix_rows),.cols(matrix_cols),
        .virtual_enable(remote_active),.virtual_keys(remote_keys),
        .velocity(remote_active?remote_velocity:8'd160),
        .note_on(local_on),.note_off(local_off),.note(local_note),.vel_out(local_velocity),
        .timbre_out(local_timbre),.key_state(key_state),.ghost_active(keypad_ghost),
        .selected_timbre(selected_timbre),.external_keys(touch_keys),
        .timbre_set_valid(program_valid),.timbre_set_value(program_timbre));
    performance_input_hub #(.MIDI_ENABLE(MIDI_ENABLE),.OPTICAL_ENABLE(OPTICAL_ENABLE),
        .PRESSURE_EXPRESSION_ENABLE(PRESSURE_EXPRESSION_ENABLE),
        .MIDI_CHANNEL(MIDI_CHANNEL)) performance(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.allow_performance(allow_performance),
        .suppress_controls(suppress_controls),.remote_active(remote_active),.digital_zero(digital_zero_test),
        .midi_rx(midi_rx),.optical_beams(optical_beams),
        .local_on(local_on),.local_off(local_off),.local_note(local_note),.local_velocity(local_velocity),
        .local_timbre(local_timbre),.selected_timbre(selected_timbre),.local_keys(key_state),
        .physical_volume(physical_volume),.physical_pitch(physical_pitch),
        .pressure_vibrato(pressure_vibrato),
        .note_on(note_on),.note_off(note_off),.note(note),.velocity(velocity),.timbre(timbre),
        .event_source(note_source),.volume(slider_volume),.pitch(slider_pitch),
        .program_valid(program_valid),.program_timbre(program_timbre),
        .midi_hit0(midi_hit0),.midi_hit1(midi_hit1),.midi_drum_velocity0(midi_velocity0),
        .midi_drum_velocity1(midi_velocity1),.panic_audio(panic_audio),
        .performance_keys(performance_keys),.primary_note(external_note),.primary_valid(external_note_valid),
        .diagnostic_status(external_diagnostic));
    assign hit0=local_hit0 || midi_hit0;
    assign hit1=local_hit1 || midi_hit1;
    // 同一鼓同拍双输入取较大力度；两路鼓仍各只有一个独立鼓声部。
    assign velocity0=midi_hit0 && (!local_hit0 || midi_velocity0>local_velocity0)?midi_velocity0:local_velocity0;
    assign velocity1=midi_hit1 && (!local_hit1 || midi_velocity1>local_velocity1)?midi_velocity1:local_velocity1;
// HDMI旁路只读这些状态，不改变输入处理。
    assign monitor_ready=pads_ready && sliders_ready;
    assign monitor_remote=remote_active;
    assign monitor_adc=remote_active?remote_adc:physical_adc;
endmodule
