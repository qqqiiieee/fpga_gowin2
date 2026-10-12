// 状态与诊断控制层。27MHz 主时钟；LED 低电平点亮。
// 把 LED、滤波组合键和计时移出顶层，避免显示逻辑混入声音数据通路。
// rst_n 异步低有效，复位 filter_enable=1；无 clock enable/模块参数，计时每 clk。
// key_state bit0..15 对应S1..S16，1为按下；selected_timbre 为0..15的音色编号。
// note_on/hit0/hit1 是 clk 域触发事件，只用于短时点灯，不代表持续有声。
// digital_zero_test/adc_fault/adc_stale 是持续状态；输出 filter_enable 也为持续开关。
// 无valid输出；LED组合反映优先状态，正常时逐位取反显示4位音色编号。
// 隐含状态为组合键 armed 与计时器；启动/触发门槛固定按27MHz定义。
module instrument_status(
    input clk,input rst_n,input [15:0] key_state,input keypad_ghost,
    input [3:0] selected_timbre,input note_on,input hit0,input hit1,
    input digital_zero_test,input adc_fault,input adc_stale,
    output reg filter_enable,output [3:0] timbre_led_n
);
    reg filter_combo_armed;
    wire filter_combo=(key_state==16'h6000) && !keypad_ghost;
    // S14+S15 只翻转一次低通状态，两键都松开后才重新武装。
    // 按住不重复切换，鬼键不能切换，保持原滤波 A/B 操作方式。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin filter_enable<=1;filter_combo_armed<=1;end
        else begin
            if((key_state & 16'h6000)==0 && !keypad_ghost) filter_combo_armed<=1;
            if(filter_combo && filter_combo_armed) begin
                filter_enable<=!filter_enable;filter_combo_armed<=0;
            end
        end
    end
    reg [23:0] startup_count,status_count;
    reg [21:0] note_led_timer;
    // 开机 0.5s 闪烁；任意旋律/鼓触发后全亮 80ms，便于观察输入响应。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin startup_count<=0;note_led_timer<=0;end
        else begin
            if(startup_count<13500000) startup_count<=startup_count+1'b1;
            if(note_on || hit0 || hit1) note_led_timer<=2160000;
            else if(note_led_timer!=0) note_led_timer<=note_led_timer-1'b1;
        end
    end
    always @(posedge clk or negedge rst_n)
        if(!rst_n) status_count<=0;else status_count<=status_count+1'b1;
    // 优先级：启动 > 零参考 > ADC 故障 > 触发 > 音色编号。
    // ADC 异常时 LED3/LED4 交替，不代表键盘或音频合成停止工作。
    assign timbre_led_n=(startup_count<13500000)?{4{startup_count[21]}}:
        (digital_zero_test?4'b0000:((adc_fault || adc_stale)?
        {1'b1,status_count[22],!status_count[22],1'b1}:
        ((note_led_timer!=0)?4'b0000:~selected_timbre)));
endmodule
