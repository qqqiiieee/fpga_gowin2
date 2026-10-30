`timescale 1ns/1ps
// 生产UART比例，经真实MIDI解析器->Hub->inputs->audio_top验证32半音监视。
// 不force内部held；延音仍有gate时松键必须立即熄灭，鼓与其他通道不能冒充琴键。
module tb_piano_held_monitor;
    reg clk=0;always #5 clk=~clk;
    reg rx=1,ui_panic=0,zero_mode=0;
    reg [15:0] test_keys=0;
    tri1 scl,sda;
    wire rst_n,owned;
    wire [31:0] piano_keys;
    wire outside;
    integer checks=0,k;
    instrument_audio_top #(.MIDI_ENABLE(1),.OPTICAL_ENABLE(0),.TOUCH_ENABLE(0),
        .DISPLAY_TOUCH_ONLY(1),.PHASE_RAM(1),.LIVE_ADSR_ENABLE(1),
        .TEST_HOLD_SAMPLES(4),.TEST_MAX_SAMPLES(500000),.TEST_RAMP_DIV(1)) dut(
        .clk(clk),.matrix_rows(),.matrix_cols(4'hf),.adc_scl(scl),.adc_sda(sda),
        .uart_rx(1'b1),.uart_tx(),.hp_bck(),.hp_ws(),.hp_din(),.pa_en(),
        .amp_bck(),.amp_lrc(),.amp_din(),.timbre_led_n(),.monitor_rst_n(rst_n),
        .monitor_test_owned(owned),.touch_miso(1'b0),.midi_rx(rx),.optical_beams(2'b11),
        .ui_test_keys(test_keys),.ui_panic(ui_panic),.ui_strum_mode(1'b0),
        .ui_timbre_set_valid(1'b0),.ui_timbre_set_value(4'd0),.ui_filter_enable(1'b0),
        .ui_zero_mode(zero_mode),.control_page(2'd0),.ui_fx_cycle(1'b0),
        .phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),.phone_query_param(8'd0),
        .monitor_piano_keys32(piano_keys),.monitor_piano_outside(outside));
    // 禁用MIDI时即使所有本地琴键按住，监视支路也必须为0。
    wire [31:0] disabled_keys;
    wire disabled_outside;
    performance_input_hub #(.MIDI_ENABLE(0),.OPTICAL_ENABLE(0)) disabled_hub(
        .clk(clk),.rst_n(rst_n),.sample_tick(1'b0),.allow_performance(1'b1),
        .suppress_controls(1'b0),.remote_active(1'b0),.digital_zero(1'b0),.midi_rx(rx),
        .optical_beams(2'b11),.local_on(1'b0),.local_off(1'b0),.local_note(7'd60),
        .local_velocity(8'd127),.local_timbre(4'd0),.selected_timbre(4'd0),.local_keys(16'hffff),
        .physical_volume(8'd160),.physical_pitch(9'sd0),.pressure_vibrato(8'd0),
        .strum_mode(1'b0),.manual_panic(1'b0),.knob_volume_valid(1'b0),.knob_volume(8'd0),
        .monitor_piano_keys32(disabled_keys),.monitor_piano_outside(disabled_outside));
    task check;
        input condition;
        input [8*110-1:0] message;
        begin
            checks=checks+1;
            if(condition!==1)begin
                $display("PIANO_HELD_MONITOR_FAIL keys=%h outside=%b: %0s",piano_keys,outside,message);
                $fatal(1,"physical MIDI monitor assertion");
            end
        end
    endtask
    task expect_keys;
        input [31:0] mask;
        input range_outside;
        begin
            #1;
            check(piano_keys===mask&&outside===range_outside,"independent physical held expectation");
            check(disabled_keys===0&&disabled_outside===0,"MIDI disabled excludes local keys");
            // 检查三层端口均接通，不能只在最上层复制一个试验位图。
            check(piano_keys===dut.input_hub.monitor_piano_keys32&&
                  piano_keys===dut.input_hub.performance.monitor_piano_keys32,
                  "held alias passes all three input layers");
        end
    endtask
    task serial;
        input [7:0] value;
        integer b;
        begin
            @(negedge clk);rx=0;repeat(864)@(negedge clk);
            for(b=0;b<8;b=b+1)begin rx=value[b];repeat(864)@(negedge clk);end
            rx=1;repeat(864)@(negedge clk);
        end
    endtask
    task msg;
        input [7:0] status,a,b;
        begin serial(status);serial(a);serial(b);repeat(150)@(negedge clk);end
    endtask
    initial begin
        repeat(1800)@(negedge clk);
        check(rst_n&&!owned,"configuration reset and normal input ready");expect_keys(0,0);
        msg(8'h91,41,100);msg(8'h99,41,100);msg(8'h99,53,100);
        expect_keys(0,0);
        msg(8'h90,41,100);expect_keys(32'h00000001,0);
        msg(8'h90,42,100);expect_keys(32'h00000003,0);
        msg(8'h90,53,100);expect_keys(32'h00001003,0);
        msg(8'h90,71,100);msg(8'h90,72,100);expect_keys(32'hc0001003,0);
        msg(8'h90,40,100);expect_keys(32'hc0001003,1);
        msg(8'h90,73,100);msg(8'h80,40,0);expect_keys(32'hc0001003,1);
        msg(8'h80,73,0);expect_keys(32'hc0001003,0);
        msg(8'h90,0,100);msg(8'h90,127,100);expect_keys(32'hc0001003,1);
        msg(8'h90,0,0);msg(8'h80,127,0);expect_keys(32'hc0001003,0);
        msg(8'h90,42,0);expect_keys(32'hc0001001,0);
        msg(8'hb0,123,0);expect_keys(0,0);
        // running status完整32键；所有黑键和两端点都占独立一位。
        serial(8'h90);
        for(k=41;k<=72;k=k+1)begin serial(k);serial(96);end
        expect_keys(32'hffffffff,0);
        msg(8'hb0,64,127);
        serial(8'h80);
        for(k=41;k<=72;k=k+1)begin serial(k);serial(0);end
        repeat(500)@(negedge clk);expect_keys(0,0);
        check(dut.audio.gate!=0,"released sustain still sounds but has no held piano lights");
        msg(8'hb0,64,0);repeat(500)@(negedge clk);
        check(dut.audio.gate==0,"sustain release audio semantics retained");
        msg(8'h90,54,110);expect_keys(32'h00002000,0);
        msg(8'hb0,120,0);expect_keys(0,0);
        msg(8'h90,55,100);expect_keys(32'h00004000,0);
        @(negedge clk);ui_panic=1;repeat(3)@(negedge clk);ui_panic=0;
        expect_keys(0,0);
        msg(8'h80,55,0);msg(8'h90,55,100);expect_keys(32'h00004000,0);
        // 测试取得所有权后沿用原解析器suppress，监视也清空；保持键不自动复活。
        test_keys=16'h5000;repeat(10000)@(negedge clk);test_keys=0;
        check(owned,"32 voice test owns inputs");expect_keys(0,0);
        msg(8'h90,56,100);expect_keys(0,0);
        test_keys=16'h8000;repeat(10000)@(negedge clk);test_keys=0;
        // 沿用生产控制器完整淡出/松键/淡入（每段可达256采样），
        // 退出请求不是立即交还所有权；只等待真实输出，不force状态或缩短音频渐变。
        k=0;
        while(owned && k<200000)begin @(negedge clk);k=k+1;end
        check(!owned,"test ownership released after complete fade sequence");
        expect_keys(0,0);
        msg(8'h80,56,0);msg(8'h90,56,100);expect_keys(32'h00008000,0);
        $display("PIANO_HELD_MONITOR_TEST_PASS checks=%0d full32=1 semitones=1 outside=1 physical_not_sustain=1 drum_isolation=1 panic=1 test_ownership=1",checks);
        $finish;
    end
    initial begin #100000000;$fatal(1,"physical MIDI monitor watchdog");end
endmodule
