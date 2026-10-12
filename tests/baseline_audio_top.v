// Tang Primer 20K 顶层：端口、上电复位及三层连接，不在这里实现状态机。
// 输入层：键盘/ADS1115/UART；声音层：32复音/双鼓/滤波/耳机；状态层：LED/组合键。
// clk=27MHz H11。VIRTUAL_ADC_CYCLES 是虚拟 ADC 节奏，不是音频采样率。
module baseline_audio_top #(parameter LOWPASS_ENABLE=1,parameter VIRTUAL_ADC_CYCLES=63390)(
    input clk,output [3:0] matrix_rows,input [3:0] matrix_cols,
    inout adc_scl,inout adc_sda,input uart_rx,output uart_tx,
    output hp_bck,output hp_ws,output hp_din,output pa_en,
    output amp_bck,output amp_lrc,output amp_din,output [3:0] timbre_led_n);
    // 配置后先保持复位 256 个主时钟，待状态确定后才允许工作。
    reg [7:0] por_cnt=0;reg rst_n=0;
    always @(posedge clk) begin
        if(por_cnt!=255) por_cnt<=por_cnt+1'b1;
        rst_n<=(por_cnt==255);
    end
    wire note_on,note_off,hit0,hit1;
    wire [6:0] note;
    wire [7:0] velocity,velocity0,velocity1,slider_volume;
    wire [3:0] timbre,selected_timbre;wire [15:0] key_state;
    wire signed [8:0] slider_pitch;
    wire keypad_ghost,digital_zero_test,adc_fault,adc_stale,filter_enable,overrun;
    instrument_inputs #(.VIRTUAL_ADC_CYCLES(VIRTUAL_ADC_CYCLES)) input_hub(
        .clk(clk),.rst_n(rst_n),.matrix_rows(matrix_rows),.matrix_cols(matrix_cols),
        .adc_scl(adc_scl),.adc_sda(adc_sda),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .synth_overrun(overrun),.suppress_controls(1'b0),.note_on(note_on),.note_off(note_off),.note(note),
        .velocity(velocity),.timbre(timbre),.key_state(key_state),
        .selected_timbre(selected_timbre),.keypad_ghost(keypad_ghost),
        .slider_volume(slider_volume),.slider_pitch(slider_pitch),
        .hit0(hit0),.hit1(hit1),.velocity0(velocity0),.velocity1(velocity1),
        .digital_zero_test(digital_zero_test),.adc_fault(adc_fault),.adc_stale(adc_stale));
    baseline_instrument_audio #(.LOWPASS_ENABLE(LOWPASS_ENABLE),.NUM_VOICES(32)) audio(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),
        .velocity(velocity),.timbre(timbre),.slider_volume(slider_volume),.slider_pitch(slider_pitch),
        .hit0(hit0),.hit1(hit1),.velocity0(velocity0),.velocity1(velocity1),
        .digital_zero_test(digital_zero_test),.filter_enable(filter_enable),
        .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.overrun(overrun));
    instrument_status status(.clk(clk),.rst_n(rst_n),.key_state(key_state),.keypad_ghost(keypad_ghost),
        .selected_timbre(selected_timbre),.note_on(note_on),.hit0(hit0),.hit1(hit1),
        .digital_zero_test(digital_zero_test),.adc_fault(adc_fault),.adc_stale(adc_stale),
        .filter_enable(filter_enable),.timbre_led_n(timbre_led_n));
    // PA_EN 属于板载耳机模拟级，必须为 1；和外部数字功放使能不同。
    assign pa_en=1'b1;
    // 保留旧接线的三个功放端口并明确驱动0，避免已连接的时钟线浮空。
    // 本工程仍只使用耳机输出，这里没有 I2S 发声逻辑。
    assign amp_bck=1'b0;assign amp_lrc=1'b0;assign amp_din=1'b0;
endmodule
