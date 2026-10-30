`timescale 1ns/1ps
// 批量释放、长背压、同音重触发与非默认通道的独立端到端覆盖。
module tb_midi_release;
    midi_test_driver #(.MIDI_CHANNEL(2),.DRUM_CHANNEL(4),.ACTIVE_SENSE_MS(0)) d();
    integer i,j,start_at,end_at,last_note,base;
    initial begin
        d.reset;
        d.msg(8'h90,60,100); d.msg(8'h99,36,100); d.quiet;
        if (d.kicks || d.held!=0) $fatal(1,"MIDI parameter channel filtering");
        d.msg(8'h94,36,100);
        if (d.kicks!=1) $fatal(1,"MIDI parameter drum channel");
        d.tx(8'hfe); d.tick(400000);
        if (d.panics) $fatal(1,"MIDI disabled active sensing");
        d.msg(8'hb2,64,127); d.tx(8'h92);
        for(i=0;i<128;i=i+1) begin d.tx(i); d.tx(127); d.expect_event(1,i,255); end
        d.tx(8'h82);
        for(i=0;i<128;i=i+1) begin d.tx(i); d.tx(0); end
        if (d.held!=0) $fatal(1,"MIDI full sustain physical state");
        // 最后一个数据字节单独发，外部观察首末 off 握手间的时钟数。
        d.tx(8'hb2); d.tx(64); d.tx(0);
        d.expect_event(0,0,0);
        // 使用公开事件日志计数：串行返回前的半停止位已有16拍，故部分释放
        // 已发生；独立观察器会给出完整128项的首末握手跨度。
        for(i=1;i<128;i=i+1) d.expect_event(0,i,0);
        if (release_last-release_first!=127 || d.gates!=0 || d.overflow)
            $fatal(1,"MIDI full release must scan one note per cycle span=%0d",release_last-release_first);
        d.quiet;
        $display("MIDI_CASE_PASS release_128_scan_128_cycles_parameter_channels_sense_disabled");

        d.reset;
        // 128条批量off可存于位图；即使16项FIFO满也不应误报丢失。
        d.tx(8'h92);
        for(i=0;i<128;i=i+1) begin d.tx(i); d.tx(100); d.expect_event(1,i,201); end
        d.ready=0; d.msg(8'hb2,123,0); d.tick(5000);
        if (d.overflow || d.panics || d.held!=0) $fatal(1,"MIDI scan backlog misreported as overflow");
        d.msg(8'hb2,7,64);
        if (d.volume!=129 || d.overflow) $fatal(1,"MIDI parser stuck behind release scan");
        d.ready=1;
        for(i=0;i<128;i=i+1) d.expect_event(0,i,0);
        if (d.gates!=0) $fatal(1,"MIDI bulk off lost under backpressure");
        d.quiet;
        $display("MIDI_CASE_PASS release_bitmap_backpressure_no_off_loss_controls_progress");

        d.reset;
        d.msg(8'h92,127,100); d.expect_event(1,127,201);
        // 填充off扫描前16个位置，故127的旧off尚未入FIFO。
        for(i=0;i<20;i=i+1) begin d.msg(8'h92,i,100); d.expect_event(1,i,201); end
        d.ready=0; d.msg(8'hb2,64,127);
        d.msg(8'h82,127,0);
        for(i=0;i<20;i=i+1) d.msg(8'h82,i,0);
        d.msg(8'hb2,64,0); d.tick(500);
        // 在新on最后一字节的停止位中心附近短暂开放ready；扫描只推进少量
        // 低音位置，127的off仍在位图，新的127 on应取消它。只定时驱动公开
        // rx/ready，不观察或force内部UART；开放12拍容纳两级同步/采样延迟。
        d.tx(8'h92); d.tx(127);
        fork
            begin d.tx(127); end
            begin
                d.tick(9*d.BIT_CYCLES+d.BIT_CYCLES/2-2);
                d.ready=1; d.tick(12); d.ready=0;
            end
        join
        if (d.overflow || d.panics || !d.held[127]) $fatal(1,"MIDI pending release retrigger overflow");
        d.ready=1;
        for(i=0;i<20;i=i+1) d.expect_event(0,i,0);
        d.expect_event(1,127,255); d.quiet;
        if (!d.gates[127]) $fatal(1,"MIDI pending stale off killed retrigger");
        d.msg(8'h82,127,0); d.expect_event(0,127,0);
        // 已入FIFO的旧off不能撤销，但应严格排在后来同音on之前。
        d.ready=0;
        d.msg(8'h92,127,100); d.msg(8'h82,127,0); d.msg(8'h92,127,127);
        d.ready=1;
        d.expect_event(1,127,201); d.expect_event(0,127,0); d.expect_event(1,127,255);
        if (!d.gates[127]) $fatal(1,"MIDI stale queued off killed retrigger");
        d.msg(8'h82,127,0); d.expect_event(0,127,0);
        d.quiet;
        $display("MIDI_CASE_PASS pending_off_cancellation_and_queued_off_before_retrigger_order");
        $display("MIDI_RELEASE_TEST_PASS");
        $finish;
    end
    integer local_cycle=0,release_first=-1,release_last=-1;
    always @(posedge d.clk) begin
        local_cycle=local_cycle+1;
        if (d.valid && d.ready && d.off_event) begin
            if (release_first<0) release_first=local_cycle;
            release_last=local_cycle;
        end
    end
    initial begin #3000000000; $fatal(1,"MIDI release watchdog"); end
endmodule
