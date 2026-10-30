`timescale 1ns/1ps
// 快速回归仍从串口引脚进入：1MHz / 31250，32拍/位，不绕过 UART。
module tb_midi_keyboard;
    midi_test_driver d();
    integer i,j,k,base,old_count,old_panics,pc,vc,bc;
    reg [127:0] mask;
    initial begin
        d.reset;
        // running status 中间插入 F8/F9/FA/FB/FD/FE；半包也必须保持。
        d.tx(8'h90); d.tx(60); d.tx(8'hf8); d.tx(100); d.expect_event(1,60,201);
        d.tx(61); d.tx(8'hf9); d.tx(8'hfa); d.tx(8'hfb); d.tx(8'hfd); d.tx(110);
        d.expect_event(1,61,221);
        d.tx(60); d.tx(8'hfe); d.tx(0); d.expect_event(0,60,0);
        d.tx(61); d.tx(0); d.expect_event(0,61,0);
        if (d.held!=0 || d.gates!=0 || d.panics!=0) $fatal(1,"MIDI running status/zero off");
        d.quiet;
        $display("MIDI_CASE_PASS running_status_realtime_zero_off");

        d.reset;
        // 全 128 键同时保持，证明未在此裁剪成 32/有限键域。
        d.tx(8'h90);
        for (i=0;i<128;i=i+1) begin
            d.tx(i); d.tx(127); d.expect_event(1,i,255);
        end
        if (d.held!=={128{1'b1}} || d.gates!=={128{1'b1}}) $fatal(1,"MIDI full key domain/polyphony");
        d.tx(8'h80);
        for (i=0;i<128;i=i+1) begin
            d.tx(i); d.tx(64); d.expect_event(0,i,129);
        end
        if (d.held!=0 || d.gates!=0 || d.overflow) $fatal(1,"MIDI full key release");
        // 计数包含每个正确 UART 字节，8 位自然回绕：514 mod256=2。
        if (d.received!=2) $fatal(1,"MIDI received count wrap got=%0d",d.received);
        d.quiet;
        $display("MIDI_CASE_PASS full_128_keys_more_than_32_and_counter_wrap");

        d.reset;
        d.msg(8'h90,60,90); d.expect_event(1,60,181);
        d.msg(8'hb0,64,127);
        d.msg(8'h80,60,0); d.msg(8'h80,60,0); // 重复 off 不得删掉延音记录。
        if (d.held[60] || !d.gates[60]) $fatal(1,"MIDI physical held vs sustain");
        d.quiet;
        d.msg(8'h90,60,100); d.expect_event(1,60,201);
        d.msg(8'hb0,64,0); d.quiet; // 重触发之后松踏板，不得出现旧 off。
        if (!d.held[60] || !d.gates[60]) $fatal(1,"MIDI sustain retrigger killed new note");
        d.msg(8'h80,60,0); d.expect_event(0,60,0);
        // 升序释放，输入故意按不同顺序。
        d.msg(8'hb0,64,64);
        d.msg(8'h90,127,127); d.expect_event(1,127,255);
        d.msg(8'h90,0,1); d.expect_event(1,0,2);
        d.msg(8'h90,64,64); d.expect_event(1,64,129);
        d.msg(8'h80,127,0); d.msg(8'h80,0,0); d.msg(8'h80,64,0);
        if (d.held!=0) $fatal(1,"MIDI held includes released sustained note");
        d.msg(8'hb0,64,63);
        d.expect_event(0,0,0); d.expect_event(0,64,0); d.expect_event(0,127,0);
        // CC123 必须覆盖 held + 已松延音，并取消踏板。
        d.msg(8'hb0,64,127);
        d.msg(8'h90,10,50); d.expect_event(1,10,100);
        d.msg(8'h90,100,50); d.expect_event(1,100,100);
        d.msg(8'h80,10,0); d.msg(8'hb0,123,0);
        d.expect_event(0,10,0); d.expect_event(0,100,0);
        d.msg(8'h90,10,50); d.expect_event(1,10,100);
        d.msg(8'h80,10,0); d.expect_event(0,10,0);
        if (d.held!=0 || d.gates!=0) $fatal(1,"MIDI CC123 cleanup");
        d.quiet;
        $display("MIDI_CASE_PASS sustain_retrigger_duplicate_off_ordered_release_cc123");

        d.reset;
        // PC 只有 0/1 有效；单数据消息运行状态必须正确。
        d.tx(8'hc0); d.tx(1);
        if (!d.timbre || d.programs!=1) $fatal(1,"MIDI PC1");
        d.tx(9); if (!d.timbre || d.programs!=1) $fatal(1,"MIDI ignored PC");
        d.tx(0); if (d.timbre || d.programs!=2) $fatal(1,"MIDI PC0");
        d.msg(8'hb0,7,0); if (d.volume!=0 || d.volumes!=1) $fatal(1,"MIDI CC7 zero");
        d.msg(8'hb0,7,64); if (d.volume!=129 || d.volumes!=2) $fatal(1,"MIDI CC7 middle");
        d.msg(8'hb0,7,127); if (d.volume!=255 || d.volumes!=3) $fatal(1,"MIDI CC7 max");
        d.msg(8'hb0,1,93); if (d.modulation!=93) $fatal(1,"MIDI modulation");
        d.msg(8'he0,0,0); if ($signed(d.bend)!=-256) $fatal(1,"MIDI bend min");
        d.msg(8'he0,0,64); if ($signed(d.bend)!=0) $fatal(1,"MIDI bend center");
        d.msg(8'he0,127,127); if ($signed(d.bend)!=255) $fatal(1,"MIDI bend max");
        d.msg(8'he0,127,63); if ($signed(d.bend)!=-1 || d.bends!=4) $fatal(1,"MIDI bend signed floor");
        pc=d.programs; vc=d.volumes; bc=d.bends;
        // 其余 14 通道逐个验证，不得产生主键或控制输出。
        for (i=1;i<16;i=i+1) begin
            if (i!=9) begin
                d.msg(8'h90+i,60,100); d.msg(8'h80+i,60,0);
            end
            d.msg(8'hb0+i,7,20); d.msg(8'hb0+i,64,127);
            d.msg(8'hb0+i,120,0); d.msg(8'hb0+i,123,0);
            d.tx(8'hc0+i); d.tx(1); d.msg(8'he0+i,0,0);
        end
        if (d.programs!=pc || d.volumes!=vc || d.bends!=bc || d.modulation!=93 || d.panics)
            $fatal(1,"MIDI channel control filtering");
        d.msg(8'h99,36,127); d.msg(8'h99,35,64);
        d.msg(8'h99,38,100); d.msg(8'h99,40,1);
        d.msg(8'h99,37,100); d.msg(8'h99,36,0); d.msg(8'h89,38,100);
        if (d.kicks!=2 || d.snares!=2 || d.last_kick!=129 || d.last_snare!=2 || d.held!=0)
            $fatal(1,"MIDI drums mapping/zero/off filter");
        d.quiet;
        $display("MIDI_CASE_PASS program_volume_bend_modulation_channels_drums");

        d.reset;
        // SysEx 内插实时字节；F1/F2/F3 的载荷不能变成通道数据。
        d.tx(8'h90); d.tx(60); d.tx(8'hf0); d.tx(1); d.tx(60); d.tx(127);
        d.tx(8'hf8); d.tx(8'hf7); d.tx(60); d.tx(100); d.quiet;
        for (i=1;i<=7;i=i+1) begin
            d.tx(8'h90); d.tx(60); d.tx(8'hf0+i);
            if (i==1 || i==3) begin d.tx(60); d.tx(8'hf8); end
            if (i==2) begin d.tx(60); d.tx(8'hfa); d.tx(100); end
            d.tx(60); d.tx(100); d.quiet;
        end
        // 新状态中止旧半包，通道压感/复音压感也必须消费正确字节数。
        d.tx(8'h90); d.tx(60); d.tx(8'hd0); d.tx(70); d.tx(71);
        d.msg(8'ha0,60,100); d.msg(8'h91,60,100); d.quiet;
        d.msg(8'h90,62,100); d.expect_event(1,62,201);
        // 非法 SysEx 中断以新的显式状态重新同步，而非沿用 SysEx 前的半包。
        d.tx(8'hf0); d.tx(1); d.msg(8'h80,62,0); d.expect_event(0,62,0);
        d.quiet;
        $display("MIDI_CASE_PASS sysex_system_common_fragment_resynchronization");

        d.reset;
        d.msg(8'h90,60,100); d.expect_event(1,60,201);
        // 无 FE 时，长按超过默认 350ms 不得清音。
        d.tick(d.SENSE_CYCLES+100);
        if (d.panics!=0 || !d.held[60] || !d.gates[60]) $fatal(1,"MIDI optional sense armed too soon");
        d.tx(8'hfe); old_panics=d.panics;
        // 任意合法流量都续期，不只 FE。跨过原来的超时点仍不得 panic。
        d.tick(d.SENSE_CYCLES/2); d.tx(8'hf8);
        d.tick(d.SENSE_CYCLES/2);
        if (d.panics!=old_panics) $fatal(1,"MIDI sense traffic refresh");
        d.tick(d.SENSE_CYCLES/2+100);
        if (d.panics!=old_panics+1 || d.held!=0 || d.gates!=0) $fatal(1,"MIDI sense timeout panic");
        d.tick(d.SENSE_CYCLES+100);
        if (d.panics!=old_panics+1) $fatal(1,"MIDI repeated unarmed sense panic");
        d.msg(8'h90,61,100); d.expect_event(1,61,201);
        d.tx(8'h90); d.tx(62); d.tx(8'hfc);
        if (d.panics!=old_panics+2 || d.gates!=0) $fatal(1,"MIDI FC global panic");
        d.tx(100); d.expect_event(1,62,201); // FC 为实时字节，半包不破坏。
        d.tx(8'hff); if (d.gates!=0 || d.held!=0) $fatal(1,"MIDI FF global reset");
        d.tx(63); d.tx(100); d.quiet; // FF 后必须重新给状态。
        d.msg(8'h90,63,100); d.expect_event(1,63,201);
        d.msg(8'hb0,120,0);
        if (d.gates!=0 || d.held!=0 || d.volume!=255 || d.bend!=0 || d.modulation!=0 || d.timbre!=0)
            $fatal(1,"MIDI CC120 panic/reset state");
        d.quiet;
        $display("MIDI_CASE_PASS active_sense_opt_in_refresh_loss_fc_ff_cc120");

        d.reset;
        d.msg(8'h90,60,100); d.expect_event(1,60,201);
        d.msg(8'h90,61,100); d.expect_event(1,61,201);
        d.msg(8'hb0,64,127); d.msg(8'h80,61,0);
        // 未交付的 on 和 off 都要在 suppress 边界正确处理。
        d.ready=0; d.msg(8'h80,60,0); d.msg(8'h90,62,100);
        d.suppress=1; d.tick(3); d.ready=1;
        d.expect_event(0,60,0); d.expect_event(0,61,0);
        d.msg(8'h90,63,100); d.msg(8'h99,36,100); d.msg(8'h99,38,100);
        d.msg(8'h80,60,0); d.msg(8'h80,63,0);
        if (d.held!=0 || d.gates!=0 || d.kicks!=0 || d.snares!=0 || d.panics!=0)
            $fatal(1,"MIDI suppress generated audio/global panic");
        d.suppress=0; d.tick(3);
        d.msg(8'h90,62,100); d.quiet; // 期间按下未松，不接受重复 on。
        d.msg(8'h80,62,0); d.msg(8'h90,62,100); d.expect_event(1,62,201);
        d.msg(8'h80,62,0); d.expect_event(0,62,0);
        d.quiet;
        $display("MIDI_CASE_PASS suppress_release_no_replay_release_to_rearm");

        d.reset;
        d.msg(8'h90,60,100); d.expect_event(1,60,201);
        d.ready=0;
        d.msg(8'h80,60,0); // off 被反压，必须保持，后续 CC 仍解析。
        d.msg(8'hb0,7,64); d.msg(8'hb0,1,77);
        if (!d.valid || !d.off_event || d.note!=60 || d.volume!=129 || d.modulation!=77 || d.overflow)
            $fatal(1,"MIDI stalled off/control progress");
        for (i=0;i<7;i=i+1) begin d.msg(8'h90,i,100); d.msg(8'h80,i,0); end
        d.ready=1; d.expect_event(0,60,0);
        for (i=0;i<7;i=i+1) begin d.expect_event(1,i,201); d.expect_event(0,i,0); end
        if (d.gates!=0 || d.overflow || d.stall_checks<100) $fatal(1,"MIDI backpressure loss/stability");
        d.quiet;
        // 紧急控制不得排在已满事件队列后等待：ready永久不读时CC120仍立即执行。
        d.ready=0;
        for (i=0;i<16;i=i+1) d.msg(8'h90,i,100);
        d.msg(8'hb0,120,0);
        if (d.overflow || d.panics!=1 || d.valid || d.held!=0)
            $fatal(1,"MIDI emergency control blocked by full FIFO");
        d.ready=1; d.quiet;
        d.reset;
        // 真正填满16项，继续解析新事件必须 panic，且能恢复不永久僵住。
        d.ready=0;
        for (i=0;i<16;i=i+1) d.msg(8'h90,i,100);
        if (d.overflow || d.panics!=0 || !d.valid) $fatal(1,"MIDI FIFO capacity premature overflow");
        d.msg(8'h80,0,0); // 第17项故意是off：无处保存时必须panic，不能静默丢松键。
        if (!d.overflow || d.panics!=1 || d.held!=0 || d.valid || d.gates!=0)
            $fatal(1,"MIDI FIFO full panic/recovery");
        d.tx(101); d.tx(100); // 溢出后旧 running status 已失效。
        d.ready=1; d.quiet;
        d.msg(8'h90,127,127); d.expect_event(1,127,255);
        d.msg(8'h80,127,0); d.expect_event(0,127,0);
        if (!d.overflow || d.framing_error) $fatal(1,"MIDI overflow not sticky");
        d.quiet;
        $display("MIDI_CASE_PASS backpressure_off_stability_fifo_full_panic_recovery");

        d.reset;
        d.msg(8'h90,60,100); d.expect_event(1,60,201);
        d.tx(8'h90); d.tx(61); d.serial(100,0,0);
        d.rx=1; d.tick(d.BIT_CYCLES*3);
        if (!d.framing_error || d.panics!=1 || d.gates!=0 || d.held!=0)
            $fatal(1,"MIDI framing error panic");
        d.tx(100); d.tx(100); d.quiet;
        d.msg(8'h90,62,100); d.expect_event(1,62,201);
        d.rx=0; d.tick(d.BIT_CYCLES*35);
        if (d.panics!=2) $fatal(1,"MIDI break should report once");
        d.rx=1; d.tick(d.BIT_CYCLES*3);
        d.tx(62); d.tx(100); d.quiet;
        d.msg(8'h90,63,100); d.expect_event(1,63,201);
        d.msg(8'h80,63,0); d.expect_event(0,63,0);
        if (!d.framing_error || d.overflow) $fatal(1,"MIDI error sticky/recovered");
        d.quiet;
        $display("MIDI_CASE_PASS bad_stop_break_fragment_no_ghost_recovery");
        $display("MIDI_KEYBOARD_TEST_PASS");
        $finish;
    end
    initial begin #3000000000; $fatal(1,"MIDI keyboard watchdog"); end
endmodule
