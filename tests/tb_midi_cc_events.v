`timescale 1ns/1ps
// 常规协议测试全部从UART引脚进入；另以27MHz重跑同一组协议断言。
// 只在最后的冲突用例注入一拍rx_error，不伪造UART数据/valid，用来检查
// “完整CC/镲消息恰好遇到高优先级链路故障”的分支优先级。
// Panic同拍不留CC/镲事件，包括CC120；默认控制值valid也不产生虚构CC。
module tb_midi_cc_events #(
    parameter integer CLK_HZ=1000000
);
    midi_test_driver #(.CLK_HZ(CLK_HZ),.ACTIVE_SENSE_MS(20)) d();
    wire cc_valid=d.dut.cc_valid;
    wire [6:0] cc_number=d.dut.cc_number, cc_value=d.dut.cc_value;
    wire closed_hit=d.dut.hat_closed_hit, open_hit=d.dut.hat_open_hit;
    wire [7:0] closed_velocity=d.dut.hat_closed_velocity, open_velocity=d.dut.hat_open_velocity;
    integer cc_count=0, cc_checked=0, closed_hits=0, open_hits=0;
    integer i, base, old_panics, before_closed, before_open;
    reg [6:0] numbers [0:255];
    reg [6:0] values [0:255];
    reg [7:0] last_closed=0, last_open=0;
    reg previous_cc=0, previous_closed=0, previous_open=0;
    always @(posedge d.clk) begin
        if (!d.rst_n) begin
            cc_count=0; cc_checked=0; closed_hits=0; open_hits=0;
            last_closed=0; last_open=0;
            previous_cc=0; previous_closed=0; previous_open=0;
        end else begin
            if (d.panic && (cc_valid || closed_hit || open_hit || d.hit0 || d.hit1))
                $fatal(1,"high priority panic leaked same-cycle CC/pad event");
            if ((cc_valid && previous_cc) || (closed_hit && previous_closed) ||
                (open_hit && previous_open)) $fatal(1,"new MIDI outputs not single clk pulses");
            previous_cc=cc_valid; previous_closed=closed_hit; previous_open=open_hit;
            if (cc_valid) begin
                if (d.suppress || cc_count>=256) $fatal(1,"suppressed / excessive CC event");
                numbers[cc_count]=cc_number; values[cc_count]=cc_value; cc_count=cc_count+1;
            end
            if (closed_hit) begin closed_hits=closed_hits+1; last_closed=closed_velocity; end
            if (open_hit) begin open_hits=open_hits+1; last_open=open_velocity; end
            if ((!closed_hit && closed_velocity!=0) || (!open_hit && open_velocity!=0))
                $fatal(1,"hat velocity not cleared with pulse");
            if ((closed_hit || open_hit) && (d.hit0 || d.hit1)) $fatal(1,"pad triggered two voices");
        end
    end
    task expect_cc;
        input [6:0] number, value;
        begin
            d.tick(3);
            if (cc_count!=cc_checked+1 || numbers[cc_checked]!==number || values[cc_checked]!==value)
                $fatal(1,"CC mismatch got_count=%0d checked=%0d wanted=%0d,%0d got=%0d,%0d",
                    cc_count,cc_checked,number,value,numbers[cc_checked],values[cc_checked]);
            cc_checked=cc_checked+1;
        end
    endtask
    task no_extra_cc;
        begin d.tick(8); if (cc_count!=cc_checked) $fatal(1,"unexpected / synthetic CC event"); end
    endtask
    task error_collision;
        input [7:0] status;
        input [6:0] number, value;
        begin
            d.reset;
            fork
                d.msg(status,number,value);
                begin
                    // UART仍接收真正串行的完整消息，仅在解析消费沿加故障标志。
                    wait (d.dut.complete && d.dut.running_status==status &&
                          d.dut.first_data==number && d.dut.rx_data=={1'b0,value});
                    force d.dut.rx_error=1'b1;
                    @(posedge d.clk); #1; release d.dut.rx_error;
                end
            join
            d.tick(5); no_extra_cc;
            if (d.panics!=1 || !d.framing_error || closed_hits || open_hits || d.kicks || d.snares)
                $fatal(1,"panic collision did not suppress CC/pad status=%h note=%0d",status,number);
        end
    endtask
    initial begin
        d.reset;
        d.tx(8'hb0); d.tx(93); no_extra_cc;
        d.tx(8'hf8); d.tx(10); expect_cc(93,10);
        d.tx(91); d.tx(8'hfa); d.tx(64); expect_cc(91,64);
        d.tx(71); d.tx(127); expect_cc(71,127);
        d.tx(74); d.tx(0); expect_cc(74,0);
        // 观察所有已有CC，不能因为原路径已处理就漏发。
        d.msg(8'hb0,1,99); expect_cc(1,99);
        d.msg(8'hb0,7,64); expect_cc(7,64);
        if (d.volume!=129 || d.modulation!=99) $fatal(1,"legacy CC path changed");
        d.msg(8'hb0,64,127); expect_cc(64,127);
        d.msg(8'hb0,123,0); expect_cc(123,0);
        d.msg(8'hb0,120,0); no_extra_cc;
        if (d.panics!=1 || d.volume!=255 || d.modulation!=0) $fatal(1,"CC120 legacy panic changed");
        no_extra_cc;
        d.tx(93); d.tx(33); expect_cc(93,33); // CC120保留running status。
        // 未专门定义的主通道CC也必须原样输出。
        d.msg(8'hb0,0,127); expect_cc(0,127);
        d.msg(8'hb0,127,1); expect_cc(127,1);
        $display("CC_CASE_PASS running_status_realtime_all_existing_and_arbitrary_cc");

        old_panics=d.panics;
        for (i=1;i<16;i=i+1) begin
            d.msg(8'hb0+i,93,127); d.msg(8'hb0+i,7,0); d.msg(8'hb0+i,120,0);
        end
        if (d.panics!=old_panics || d.volume!=255) $fatal(1,"wrong channel changed old controls");
        no_extra_cc;
        d.tx(8'hb0); d.tx(93); d.tx(8'hc0); d.tx(1); no_extra_cc;
        d.tx(8'hb0); d.tx(91); d.tx(8'hf0); d.tx(91); d.tx(100);
        d.tx(8'hf8); d.tx(8'hf7); d.tx(91); d.tx(100); no_extra_cc;
        d.tx(8'hb0); d.tx(71); d.tx(8'hf2); d.tx(71); d.tx(100);
        d.tx(71); d.tx(100); no_extra_cc;
        d.msg(8'hb0,74,55); expect_cc(74,55);
        $display("CC_CASE_PASS other_channels_half_packets_sysex_system_common");

        d.suppress=1; d.tick(3);
        d.msg(8'hb0,93,100); d.msg(8'hb0,7,20); d.msg(8'hb0,1,22);
        d.msg(8'h99,37,100); d.msg(8'h99,39,100);
        if (d.volume!=40 || d.modulation!=22 || closed_hits || open_hits)
            $fatal(1,"suppression changed legacy controls / leaked hats");
        no_extra_cc;
        d.suppress=0; d.tick(3);
        d.msg(8'hb0,93,100); expect_cc(93,100);
        $display("CC_CASE_PASS suppressed_generic_cc_hats_legacy_defaults_preserved");

        // FC可打断半包但不破坏它；只有尾字节真正到达才产生真实CC。
        old_panics=d.panics;
        d.tx(8'hb0); d.tx(93); d.tx(8'hfc); no_extra_cc;
        if (d.panics!=old_panics+1) $fatal(1,"FC panic missing");
        d.tx(66); expect_cc(93,66);
        d.tx(8'hff); no_extra_cc;
        d.tx(93); d.tx(100); no_extra_cc;
        d.msg(8'hb0,91,64); expect_cc(91,64);
        old_panics=d.panics;
        d.tx(8'hfe); d.tick(d.SENSE_CYCLES+50); no_extra_cc;
        if (d.panics!=old_panics+1) $fatal(1,"disconnect sensing panic missing");
        d.tx(91); d.tx(100); no_extra_cc; // 失联清掉running status。
        d.tx(8'hb0); d.tx(91); d.serial(100,0,0);
        d.rx=1; d.tick(d.BIT_CYCLES*3); no_extra_cc;
        if (!d.framing_error || d.panics!=old_panics+2) $fatal(1,"bad frame not rejected");
        d.msg(8'hb0,71,22); expect_cc(71,22);
        $display("CC_CASE_PASS panic_fc_ff_disconnect_bad_frame_no_synthetic_cc");

        // 即使音符FIFO已满，控制不被反压；第17项松键仍必须安全Panic。
        d.reset; d.ready=0;
        for (i=0;i<16;i=i+1) d.msg(8'h90,i,100);
        d.msg(8'hb0,93,77); expect_cc(93,77);
        if (d.overflow || d.panics) $fatal(1,"CC stalled by full note FIFO");
        d.msg(8'h80,0,0); no_extra_cc;
        if (!d.overflow || d.panics!=1 || d.valid || d.held!=0)
            $fatal(1,"FIFO noteoff panic protection changed");
        d.ready=1;
        d.msg(8'hb0,74,88); expect_cc(74,88);
        d.msg(8'hb0,120,0); no_extra_cc;
        $display("CC_CASE_PASS full_fifo_control_progress_noteoff_protection");

        d.reset;
        d.tx(8'h99);
        d.tx(36); d.tx(127);
        d.tx(37); d.tx(8'hf8); d.tx(64);
        d.tx(38); d.tx(100);
        d.tx(39); d.tx(1);
        if (d.kicks!=1 || closed_hits!=1 || d.snares!=1 || open_hits!=1 ||
            d.last_kick!=255 || last_closed!=129 || d.last_snare!=201 || last_open!=2)
            $fatal(1,"stock Bank A36/37/38/39 four pads mapping");
        d.tx(42); d.tx(127); d.tx(46); d.tx(100);
        d.tx(35); d.tx(1); d.tx(40); d.tx(64);
        if (closed_hits!=2 || open_hits!=2 || last_closed!=255 || last_open!=201 ||
            d.kicks!=2 || d.snares!=2 || d.last_kick!=2 || d.last_snare!=129 || d.held!=0)
            $fatal(1,"GM hats / unchanged kick snare aliases");
        before_closed=closed_hits; before_open=open_hits;
        d.msg(8'h89,37,127); d.msg(8'h89,39,127);
        d.msg(8'h99,37,0); d.msg(8'h99,39,0); d.msg(8'h99,42,0); d.msg(8'h99,46,0);
        d.msg(8'h98,37,100); d.msg(8'h9a,39,100); d.msg(8'h99,41,127);
        d.suppress=1; d.tick(3);
        d.msg(8'h99,37,100); d.msg(8'h99,39,100);
        d.msg(8'h99,42,100); d.msg(8'h99,46,100);
        d.msg(8'hb0,120,0); no_extra_cc; // suppress仍允许原Panic，但不发通用CC。
        if (closed_hits!=before_closed || open_hits!=before_open || d.panics!=1)
            $fatal(1,"hat noteoff/zero/channel/suppress filtering");
        d.suppress=0; d.tick(3);
        d.msg(8'h99,37,1); d.msg(8'h99,39,127);
        if (closed_hits!=before_closed+1 || open_hits!=before_open+1 ||
            last_closed!=2 || last_open!=255) $fatal(1,"hats failed recovery after panic");
        no_extra_cc;
        $display("CC_CASE_PASS stock_pad_gm_alias_velocity_single_pulse_filters");
        error_collision(8'hb0,93,100);
        error_collision(8'h99,37,100);
        error_collision(8'h99,39,100);
        error_collision(8'h99,36,100);
        error_collision(8'h99,38,100);
        $display("CC_CASE_PASS high_priority_panic_same_cycle_cc_all_four_pads");
        $display("MIDI_CC_EVENTS_TEST_PASS clk_hz=%0d",CLK_HZ); $finish;
    end
    initial begin #3000000000; $fatal(1,"CC events watchdog"); end
endmodule
