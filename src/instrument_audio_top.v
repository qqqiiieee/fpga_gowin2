// Tang Primer 20K 顶层：端口、上电复位及三层连接，不在这里实现状态机。
// 输入层：键盘/ADS1115/UART；声音层：32复音/双鼓/滤波/耳机；状态层：LED/组合键。
// clk=27MHz H11。VIRTUAL_ADC_CYCLES 是虚拟 ADC 节奏，不是音频采样率。
// 无外部复位口；寄存器初值和 por_cnt 产生配置后低有效复位，再按 clk 同步释放。
// monitor_rst_n 是此源域复位；monitor_tick 为93750Hz整帧装载使能，不是新时钟。
// matrix_rows 为逐行0/Z，matrix_cols低有效需上拉；ADC为开漏I2C，UART为8N1。
// hp_bck/ws/din 是 PT8211 右对齐串行口；pa_en 固定1，amp_* 三口固定0。
// monitor_pcm 为16位二补码装载字；keys bit0..15为S1..S16，timbre为0..15，
// volume为0..255控制码，pitch为9位有符号弯音码；busy每位对应声部0..31。
// monitor_adc低到高四个16位原始码为A0/A1压力、A2音量、A3弯音，不是kg。
// monitor_flags bit7..0依次为overrun/ghost/input_ready/adc_stale/adc_fault/
// filter_enable/remote_active/digital_zero；ready 不表示完成传感器物理标定。
// test_gate/busy每位对应测试声部；requested为请求数0/1/4/8/16/32，index为0..31。
// 测试owned与test_mode为持续状态，监视口没有额外valid，不由HDMI消费来反控音频。
// LOWPASS_ENABLE 默认1，按布尔开关使用；VIRTUAL_ADC_CYCLES 默认63390，
// 须在1..65536内匹配虚拟计数器。TEST_* 默认187500/5625000/46875/8，
// 单位为采样数，范围/非正值处理继承 oscillator_test_control。
module instrument_audio_top #(parameter LOWPASS_ENABLE=1,parameter VIRTUAL_ADC_CYCLES=63390,
    parameter TEST_HOLD_SAMPLES=187500,parameter TEST_MAX_SAMPLES=5625000,
    parameter TEST_SWEEP_HALF_SAMPLES=46875,parameter TEST_RAMP_DIV=8)(
    input clk,output [3:0] matrix_rows,input [3:0] matrix_cols,
    inout adc_scl,inout adc_sda,input uart_rx,output uart_tx,
    output hp_bck,output hp_ws,output hp_din,output pa_en,
    output amp_bck,output amp_lrc,output amp_din,output [3:0] timbre_led_n,
    output monitor_rst_n,output monitor_tick,output [15:0] monitor_pcm,
    output [15:0] monitor_keys,output [3:0] monitor_timbre,output [7:0] monitor_volume,
    output signed [8:0] monitor_pitch,output [31:0] monitor_busy,
    output [7:0] monitor_flags,output [63:0] monitor_adc,
    output monitor_test_owned,output monitor_test_mode,
    output [31:0] monitor_test_gate,output [31:0] monitor_test_busy,
    output [5:0] monitor_test_requested,output monitor_test_sweep,
    output [4:0] monitor_test_index);
    // 配置后先保持复位 256 个主时钟，待状态确定后才允许工作。
    reg [7:0] por_cnt=0;reg rst_n=0;
    always @(posedge clk) begin
        if(por_cnt!=255) por_cnt<=por_cnt+1'b1;
        rst_n<=(por_cnt==255);
    end
    wire note_on,note_off,hit0,hit1;
    wire input_ready,input_remote;
    wire [6:0] note;
    wire [7:0] velocity,velocity0,velocity1,slider_volume;
    wire [3:0] timbre,selected_timbre;wire [15:0] key_state;
    wire signed [8:0] slider_pitch;
    wire keypad_ghost,digital_zero_test,adc_fault,adc_stale,filter_enable,overrun;
    wire test_owned,test_mode,test_clear,test_sweep;
    wire [31:0] test_gate;
    wire [5:0] test_requested;
    wire [4:0] test_index;
    wire [8:0] test_gain;
    wire [3:0] test_state;
    wire normal_input_ready;
    // 本地长按/串口虚拟键都使用同一已消抖key_state，避免矩阵鬼键绕过。
    // 默认计数按93750Hz；参数只为仿真加速提供覆盖，不改变板上时钟。
    oscillator_test_control #(.HOLD_SAMPLES(TEST_HOLD_SAMPLES),.MAX_SAMPLES(TEST_MAX_SAMPLES),
        .SWEEP_HALF_SAMPLES(TEST_SWEEP_HALF_SAMPLES),.RAMP_DIV(TEST_RAMP_DIV)) test_control(
        .clk(clk),.rst_n(rst_n),.sample_tick(monitor_tick),.keys(key_state),
        .ghost(keypad_ghost),.remote_active(input_remote),.owned(test_owned),
        .test_mode(test_mode),.gate_mask(test_gate),.requested_count(test_requested),
        .sweep_active(test_sweep),.sweep_index(test_index),.master_gain(test_gain),
        .clear_audio(test_clear),.state_debug(test_state),.normal_input_ready(normal_input_ready));
    instrument_inputs #(.VIRTUAL_ADC_CYCLES(VIRTUAL_ADC_CYCLES)) input_hub(
        .clk(clk),.rst_n(rst_n),.matrix_rows(matrix_rows),.matrix_cols(matrix_cols),
        .adc_scl(adc_scl),.adc_sda(adc_sda),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .synth_overrun(overrun),.suppress_controls(test_owned),
        .note_on(note_on),.note_off(note_off),.note(note),
        .velocity(velocity),.timbre(timbre),.key_state(key_state),
        .selected_timbre(selected_timbre),.keypad_ghost(keypad_ghost),
        .slider_volume(slider_volume),.slider_pitch(slider_pitch),
        .hit0(hit0),.hit1(hit1),.velocity0(velocity0),.velocity1(velocity1),
        .digital_zero_test(digital_zero_test),.adc_fault(adc_fault),.adc_stale(adc_stale),
        .monitor_ready(input_ready),.monitor_remote(input_remote),.monitor_adc(monitor_adc));
    instrument_audio #(.LOWPASS_ENABLE(LOWPASS_ENABLE),.NUM_VOICES(32),.TRANSITION_INPUT_ENABLE(1)) audio(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),
        .velocity(velocity),.timbre(timbre),.slider_volume(slider_volume),.slider_pitch(slider_pitch),
        .hit0(hit0),.hit1(hit1),.velocity0(velocity0),.velocity1(velocity1),
        .digital_zero_test(digital_zero_test),.filter_enable(filter_enable),
        .test_owned(test_owned),.test_mode(test_mode),.test_clear(test_clear),
        .normal_input_ready(normal_input_ready),
        .test_gate_mask(test_gate),.test_master_gain(test_gain),
        .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.overrun(overrun),
        .monitor_tick(monitor_tick),.monitor_pcm(monitor_pcm),
        .monitor_pitch(monitor_pitch),.monitor_busy(monitor_busy),.monitor_test_busy(monitor_test_busy));
    wire [3:0] normal_led_n;
    instrument_status status(.clk(clk),.rst_n(rst_n),
        .key_state(test_owned?16'd0:key_state),.keypad_ghost(keypad_ghost),
        .selected_timbre(selected_timbre),.note_on(note_on),.hit0(hit0),.hit1(hit1),
        .digital_zero_test(digital_zero_test),.adc_fault(adc_fault),.adc_stale(adc_stale),
        .filter_enable(filter_enable),.timbre_led_n(normal_led_n));
    // 测试时两组LED交替提示；合成超时优先全灯闪。普通模式沿用原状态灯。
    reg [24:0] test_led_counter;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)test_led_counter<=0;else test_led_counter<=test_led_counter+1'b1;
    assign timbre_led_n=test_owned?
        (overrun?{4{test_led_counter[22]}}:(test_led_counter[22]?4'b1010:4'b0101)):normal_led_n;
    // 当前板载耳机模拟级 PA_EN 固定为1；不是外部功放的使能请求。
    assign pa_en=1'b1;
    // 保留旧接线的三个功放端口并明确驱动0，避免已连接的时钟线浮空。
    // 本工程仍只使用耳机输出，这里没有 I2S 发声逻辑。
    assign amp_bck=1'b0;assign amp_lrc=1'b0;assign amp_din=1'b0;
// 只读状态出口；原来的音频、串口和实体接线保持不变。
    assign monitor_rst_n=rst_n;
    assign monitor_keys=key_state;
    assign monitor_timbre=selected_timbre;
    assign monitor_volume=slider_volume;
    assign monitor_flags={overrun,keypad_ghost,input_ready,adc_stale,
                          adc_fault,filter_enable,input_remote,digital_zero_test};
    assign monitor_test_owned=test_owned;
    assign monitor_test_mode=test_mode;
    assign monitor_test_gate=test_gate;
    assign monitor_test_requested=test_requested;
    assign monitor_test_sweep=test_sweep;
    assign monitor_test_index=test_index;
endmodule
