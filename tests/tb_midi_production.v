`timescale 1ns/1ps
// 整模块使用真实27MHz、864拍/位串口，Active Sensing仍为默认350ms。
// 此 bench 与快速全功能 bench 分开，防止只验证缩放参数而漏掉生产节拍。
module tb_midi_production;
    midi_test_driver #(.CLK_HZ(27000000)) d();
    integer i,start_cycle,first_off_cycle,last_off_cycle,old_panics;
    initial begin
        d.reset;
        d.serial(8'h90,-8,1); d.serial(0,8,1); d.serial(127,-8,1);
        d.expect_event(1,0,255);
        d.serial(127,8,1); d.serial(64,-8,1); d.expect_event(1,127,129);
        d.msg(8'hb0,64,127);
        d.msg(8'h80,0,0); d.msg(8'h80,127,0);
        if (d.held!=0 || !d.gates[0] || !d.gates[127]) $fatal(1,"MIDI production sustain");
        d.msg(8'hb0,64,0); d.expect_event(0,0,0); d.expect_event(0,127,0);
        d.msg(8'h99,36,127); d.msg(8'h99,38,64);
        if (d.kicks!=1 || d.snares!=1) $fatal(1,"MIDI production drums");
        d.msg(8'he0,0,0); if ($signed(d.bend)!=-256) $fatal(1,"MIDI production signed bend");
        d.msg(8'h90,60,100); d.expect_event(1,60,201);
        d.tick(d.SENSE_CYCLES+10);
        if (d.panics || !d.held[60]) $fatal(1,"MIDI production long hold before FE");
        d.tx(8'hfe);
        // tx 返回在停止位结束；从 FE 的中心采样到此处约半位，故提前1000拍
        // 检查尚未触发，之后越过350ms阈值应只触发一次。
        d.tick(d.SENSE_CYCLES-1000);
        if (d.panics!=0) $fatal(1,"MIDI production early active sense timeout");
        d.tick(2000);
        if (d.panics!=1 || d.gates!=0 || d.held!=0) $fatal(1,"MIDI production 350ms loss panic");
        d.msg(8'h90,61,100); d.expect_event(1,61,201);
        d.msg(8'h80,61,0); d.expect_event(0,61,0);
        d.quiet;
        $display("MIDI_CASE_PASS production_27mhz_31250_and_350ms_active_sense");
        $display("MIDI_PRODUCTION_TEST_PASS");
        $finish;
    end
    initial begin #1000000000; $fatal(1,"MIDI production watchdog"); end
endmodule
