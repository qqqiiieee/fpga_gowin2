`timescale 1ns/1ps
// 只经公开接口驱动，检查软接管方向、切页同沿事件、外部音量仲裁及显示字节序。
module tb_midi_control_bank;
    reg clk=0, rst_n=0, cc_valid=0, ui_fx_cycle=0;
    reg [6:0] cc_number=0, cc_value=0;
    reg [1:0] control_page=0;
    reg [7:0] current_master_volume=180;
    wire [7:0] master_volume, mix_balance, brightness_base;
    wire [7:0] attack_ctrl, decay_ctrl, sustain_ctrl, release_ctrl;
    wire [7:0] fx_amount, fx_time, fx_feedback, fx_mod;
    wire [1:0] fx_mode;
    wire master_volume_valid;
    wire [31:0] knob_values;
    integer volume_events=0, before_events, i;
    reg echo_volume=1;
    reg [89:0] saved;
    wire [89:0] parameters_now = {master_volume,mix_balance,brightness_base,
        attack_ctrl,decay_ctrl,sustain_ctrl,release_ctrl,fx_mode,
        fx_amount,fx_time,fx_feedback,fx_mod};
    always #5 clk=~clk;
    midi_control_bank dut (
        .clk(clk),.rst_n(rst_n),.cc_valid(cc_valid),.cc_number(cc_number),.cc_value(cc_value),
        .control_page(control_page),.ui_fx_cycle(ui_fx_cycle),
        .current_master_volume(current_master_volume),.master_volume(master_volume),
        .master_volume_valid(master_volume_valid),.mix_balance(mix_balance),
        .brightness_base(brightness_base),.attack_ctrl(attack_ctrl),.decay_ctrl(decay_ctrl),
        .sustain_ctrl(sustain_ctrl),.release_ctrl(release_ctrl),.fx_mode(fx_mode),
        .fx_amount(fx_amount),.fx_time(fx_time),.fx_feedback(fx_feedback),.fx_mod(fx_mod),
        .knob_values(knob_values)
    );
    // 模拟原音量仲裁器：一拍后回送请求，防止把自身确认误判为外部抢占。
    always @(posedge clk) begin
        if (!rst_n) volume_events=0;
        else if (master_volume_valid) begin
            volume_events=volume_events+1;
            if (echo_volume) current_master_volume<=master_volume;
        end
    end
    task tick; input integer n; begin repeat(n) @(negedge clk); end endtask
    task send_cc;
        input [6:0] number, value;
        begin
            @(negedge clk); cc_number=number; cc_value=value; cc_valid=1;
            @(negedge clk); cc_valid=0; tick(3);
            if (master_volume_valid) $fatal(1,"master valid did not clear after event");
        end
    endtask
    task page;
        input [1:0] value;
        begin @(negedge clk); control_page=value; tick(3); end
    endtask
    initial begin
        tick(3); rst_n=1; tick(4);
        if (master_volume!=180 || volume_events || fx_mode!=0 || mix_balance!=128 ||
            brightness_base!=64 || attack_ctrl!=32 || decay_ctrl!=96 ||
            sustain_ctrl!=192 || release_ctrl!=128 || fx_amount!=64 ||
            fx_time!=96 || fx_feedback!=80 || fx_mod!=48 || knob_values!==32'h404080b4)
            $fatal(1,"audible defaults / page0 byte order");
        saved=parameters_now;
        send_cc(7,0); send_cc(1,127); send_cc(64,127); send_cc(120,0);
        send_cc(123,0); send_cc(92,127);
        if (parameters_now!==saved || volume_events) $fatal(1,"CC7/unknown CC stole controls");
        $display("CONTROL_CASE_PASS defaults_brightness_headroom_cc7_ignored");

        send_cc(93,0);
        if (master_volume!=180 || volume_events) $fatal(1,"first distant volume jumped");
        send_cc(93,100); // 0 -> 201跨过真实目标180。
        if (master_volume!=201 || current_master_volume!=201 || volume_events!=1)
            $fatal(1,"upward crossing / master request pulse");
        send_cc(93,127);
        if (master_volume!=255 || volume_events!=2) $fatal(1,"self echo lost pickup");
        send_cc(93,0);
        if (master_volume!=0 || volume_events!=3) $fatal(1,"picked knob failed full range");
        tick(20);
        if (volume_events!=3) $fatal(1,"volume valid repeated without CC");
        $display("CONTROL_CASE_PASS master_cross_follow_echo_single_pulse");

        @(negedge clk); current_master_volume=90; tick(3);
        if (knob_values[7:0]!=90) $fatal(1,"master display not external target");
        send_cc(93,0); send_cc(93,10);
        if (volume_events!=3) $fatal(1,"external master move failed to disarm pickup");
        send_cc(93,60);
        if (master_volume!=120 || volume_events!=4) $fatal(1,"external master reacquire crossing");
        // 与外部改音量同沿的CC不得使用旧位置历史跨越新目标。
        @(negedge clk); current_master_volume=60; cc_number=93; cc_value=0; cc_valid=1;
        @(negedge clk); cc_valid=0; tick(3);
        if (volume_events!=4) $fatal(1,"stale history crossed moving master target");
        send_cc(93,40);
        if (master_volume!=80 || volume_events!=5) $fatal(1,"new master history not recorded");
        // 128不是7->8位扩展可到达的码，129必须能匹配；负向一格同理。
        @(negedge clk); current_master_volume=128; tick(3); send_cc(93,64);
        if (master_volume!=129 || volume_events!=6) $fatal(1,"unreachable target +1 tolerance");
        @(negedge clk); current_master_volume=63; tick(3); send_cc(93,31);
        if (master_volume!=62 || volume_events!=7) $fatal(1,"target -1 tolerance");
        $display("CONTROL_CASE_PASS external_master_retarget_same_edge_quantization");

        send_cc(91,120); send_cc(91,80);
        if (mix_balance!=128) $fatal(1,"balance distant values jumped");
        send_cc(91,60);
        if (mix_balance!=120) $fatal(1,"downward crossing failed");
        send_cc(91,0);
        send_cc(71,32); send_cc(71,64);
        send_cc(74,32); send_cc(74,127);
        if (mix_balance!=0 || brightness_base!=129 || fx_amount!=255 ||
            knob_values!==32'hff81003e) $fatal(1,"page0 stock CC mapping / byte order");
        $display("CONTROL_CASE_PASS downward_cross_page0_four_knobs");

        // 切页不改变任何参数；同沿第一条远端CC也不能继承上页的已接管标志。
        saved=parameters_now; before_events=volume_events;
        @(negedge clk); control_page=1; cc_valid=1; cc_number=93; cc_value=127;
        @(negedge clk); cc_valid=0; tick(3);
        if (parameters_now!==saved || knob_values!==32'h80c06020)
            $fatal(1,"page change / same edge CC jump");
        send_cc(93,80);
        if (attack_ctrl!=32) $fatal(1,"page1 premature pickup");
        send_cc(93,0); send_cc(93,8);
        send_cc(91,0); send_cc(91,60); send_cc(91,40);
        send_cc(71,127); send_cc(71,80);
        send_cc(74,48); send_cc(74,70);
        if (attack_ctrl!=16 || decay_ctrl!=80 || sustain_ctrl!=161 || release_ctrl!=141 ||
            knob_values!==32'h8da15010 || volume_events!=before_events)
            $fatal(1,"page1 ADSR mapping / isolated master");
        $display("CONTROL_CASE_PASS page1_soft_takeover_adsr_same_edge");

        saved=parameters_now; page(2);
        if (parameters_now!==saved || knob_values!==32'hff305060)
            $fatal(1,"page2 target display / page-only mutation");
        send_cc(93,0); send_cc(91,0); send_cc(71,0); send_cc(74,0);
        if (parameters_now!==saved) $fatal(1,"page2 first distant values jumped");
        send_cc(93,48); send_cc(91,40); send_cc(71,24); send_cc(74,127);
        send_cc(93,127); send_cc(91,127); send_cc(71,127); send_cc(74,10);
        if (fx_time!=255 || fx_feedback!=255 || fx_mod!=255 || fx_amount!=20 ||
            knob_values!==32'h14ffffff || attack_ctrl!=16 || release_ctrl!=141)
            $fatal(1,"page2 FX mapping / ADSR isolation");
        page(0);
        send_cc(74,127);
        if (fx_amount!=20) $fatal(1,"shared wet knob inherited pickup across page");
        send_cc(74,0);
        if (fx_amount!=0) $fatal(1,"shared wet value not picked up on return page");
        $display("CONTROL_CASE_PASS page2_four_knobs_shared_wet_page_return");

        // page3可预测地显示page0，但仍按一次切页重新接管。
        page(3); saved=parameters_now; send_cc(91,127);
        if (parameters_now!==saved || knob_values!==32'h0081003e)
            $fatal(1,"reserved page3 fallback / no stale pickup");
        for (i=1;i<=8;i=i+1) begin
            @(negedge clk); ui_fx_cycle=1;
            @(negedge clk); ui_fx_cycle=0; tick(2);
            if (fx_mode!==(i%4)) $fatal(1,"FX cycle bypass/delay/chorus/reverb");
        end
        saved=parameters_now; cc_number=93; cc_value=127; tick(5);
        if (parameters_now!==saved) $fatal(1,"CC payload changed without valid");
        @(negedge clk); rst_n=0; tick(2); rst_n=1; tick(3);
        if (fx_mode!=0 || master_volume_valid || attack_ctrl!=32 || fx_amount!=64)
            $fatal(1,"reset failed to restore defaults");
        $display("CONTROL_CASE_PASS reserved_page_fx_cycle_valid_gating_reset");
        // 集成默认物理音量为160：不能错误地围绕本模块请求寄存器180接管。
        @(negedge clk); rst_n=0; control_page=0; current_master_volume=160;
        tick(2); rst_n=1; tick(3);
        if (knob_values[7:0]!=160 || master_volume_valid) $fatal(1,"physical default160 target");
        send_cc(93,0); send_cc(93,80); // 扩展161，与实际目标160仅差1码。
        if (volume_events!=1 || master_volume!=161 || current_master_volume!=161)
            $fatal(1,"K1 did not use final arbiter volume160 for pickup");
        $display("CONTROL_CASE_PASS final_arbiter_physical_volume160_pickup");
        $display("MIDI_CONTROL_BANK_TEST_PASS"); $finish;
    end
    initial begin #1000000; $fatal(1,"control bank watchdog"); end
endmodule
