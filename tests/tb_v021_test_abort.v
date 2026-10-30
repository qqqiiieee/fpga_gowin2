`timescale 1ns/1ps
// V021定向退出/恢复回归：只驱动公共UI键和实际31250baud 8N1 RX，不force时钟、
// MIDI解析状态、半包、Panic或声音事件。每个音频tick仍严格间隔288个27MHz clk。
// CASE 0/1/2: CC120 / FF / 已武装ActiveSense超时；CASE 3..7: 渐入开始的
// Note/Kick/Snare/闭镲/开镲；CASE 8..12: 渐入中间的相同五类事件。
// 只在本测试实例defparam减少旋律声部；生产RTL的32声部常量完全不改。
// SHORT_VOICES=2是现有IW=$clog2(NUM_VOICES)的最小非零地址宽度配置，避免1声部
// 产生零宽RAM地址。本例证明32请求/门控和真实UART控制交接，不声称验证32谱峰；
// 完整32声部发声/预算由主集成另行覆盖。可用-P覆盖SHORT_VOICES=32复用本bench。
module tb_v021_test_abort;
    parameter CASE=0;
    parameter SHORT_VOICES=2;
    localparam EVENT_KIND=(CASE<3)?0:((CASE-3)%5);
    localparam MID_RAMP=(CASE>=8);
    localparam BIT_CLOCKS=864;
    reg clk=0;always #18.518 clk=~clk;
    reg midi_rx=1;
    reg [15:0] ui_keys=0;
    tri1 scl,sda;
    wire rst,tick,owned,test_mode,hp_bck,amp_bck;
    wire [15:0] pcm;
    wire [31:0] busy,test_gate,test_busy;
    wire [5:0] requested;
    integer clocks_seen=0,ticks_seen=0,last_tick=-1;
    integer uart_sent=0,uart_received=0,panics=0,aborts=0,resume_checks=0;
    integer deliveries=0,pcm_after_delivery=0,test_pcm=0,wait_count;
    integer event_gain=-1,event_clock=-1,resume_clock=-1;
    reg expect_delivery=0,quiet_after_abort=0;
    reg [4:0] edge_events;
    reg [3:0] state_before;
    reg [6:0] event_note;
    reg [7:0] event_velocity;
    reg panic_before;

    instrument_audio_top #(.TOUCH_ENABLE(1),.MIDI_ENABLE(1),.OPTICAL_ENABLE(1),
        .PRESSURE_EXPRESSION_ENABLE(1),.PHASE_RAM(1),.DISPLAY_TOUCH_ONLY(1),
        .LIVE_ADSR_ENABLE(1),.EFFECTS_ENABLE(1),.TEST_HOLD_SAMPLES(4),
        .TEST_MAX_SAMPLES(10000),.TEST_RAMP_DIV(1)) dut(
        .clk(clk),.matrix_rows(),.matrix_cols(4'hf),.adc_scl(scl),.adc_sda(sda),
        .uart_rx(1'b1),.uart_tx(),.hp_bck(hp_bck),.hp_ws(),.hp_din(),.pa_en(),
        .amp_bck(amp_bck),.amp_lrc(),.amp_din(),.timbre_led_n(),
        .monitor_rst_n(rst),.monitor_tick(tick),.monitor_pcm(pcm),.monitor_keys(),
        .monitor_timbre(),.monitor_volume(),.monitor_pitch(),.monitor_busy(busy),
        .monitor_flags(),.monitor_adc(),.monitor_test_owned(owned),.monitor_test_mode(test_mode),
        .monitor_test_gate(test_gate),.monitor_test_busy(test_busy),.monitor_test_requested(requested),
        .monitor_test_sweep(),.monitor_test_index(),.touch_cs_n(),.touch_sclk(),.touch_mosi(),
        .touch_miso(1'b0),.midi_rx(midi_rx),.optical_beams(2'b11),
        .monitor_performance_keys(),.monitor_external_note(),.monitor_external_note_valid(),
        .monitor_expression0(),.monitor_expression1(),.monitor_pressure_calibrated(),
        .ui_test_keys(ui_keys),.ui_panic(1'b0),.ui_strum_mode(1'b0),
        .ui_timbre_set_valid(1'b0),.ui_timbre_set_value(4'd0),.ui_filter_enable(1'b0),
        .ui_zero_mode(1'b0),.control_page(2'd0),.ui_fx_cycle(1'b0),
        .monitor_fx_mode(),.monitor_knob_values());
    defparam dut.audio.NUM_VOICES=SHORT_VOICES;
    // 仅加速已武装FE的失联等待；CLK_HZ/BAUD不改，实际UART每位依然864clk。
    defparam dut.input_hub.performance.midi_input.keyboard.ACTIVE_SENSE_MS=1;

    function [6:0] note_for_event;
        input integer kind;
        begin case(kind)
            0:note_for_event=69;
            1:note_for_event=36;
            2:note_for_event=38;
            3:note_for_event=37;
            default:note_for_event=39;
        endcase end
    endfunction

    // 事件在消费沿之前取样，NBA之后验证声音层确实捕获，不能只统计解析器hit。
    always @(posedge clk) begin
        clocks_seen=clocks_seen+1;
        state_before=dut.test_state;
        edge_events={dut.hat_open_hit,dut.hat_closed_hit,dut.hit1,dut.hit0,dut.note_on};
        panic_before=dut.panic_audio;
        if(rst) begin
            if(tick) begin
                if(last_tick>=0 && clocks_seen-last_tick!=288)
                    $fatal(1,"ABORT tick discontinuity: %0d clocks",clocks_seen-last_tick);
                last_tick=clocks_seen;ticks_seen=ticks_seen+1;
                if(test_mode && pcm!=0)test_pcm=test_pcm+1;
                if(deliveries>0 && pcm!=0)pcm_after_delivery=pcm_after_delivery+1;
            end
            if(dut.input_hub.performance.midi_input.keyboard.receiver.data_valid)
                uart_received=uart_received+1;
            if(panic_before) begin panics=panics+1;quiet_after_abort=1;end
            if(dut.abort_test) begin
                aborts=aborts+1;
                if(!panic_before || !owned || dut.ui_panic)
                    $fatal(1,"ABORT did not originate from actual MIDI panic");
            end
            if(dut.input_hub.performance.m_error || dut.input_hub.performance.m_overflow)
                $fatal(1,"ABORT UART framing/FIFO fault is not an intended test stimulus");
            if(edge_events!=0) begin
                if(!expect_delivery || CASE<3 || edge_events!==(5'b00001<<EVENT_KIND) || deliveries!=0)
                    $fatal(1,"ABORT wrong/duplicate event kind=%b expected=%0d",edge_events,EVENT_KIND);
                if(dut.test_state!=6 || !owned || test_mode || !dut.normal_input_ready ||
                   !dut.audio.accept_normal_input || dut.effective_test_mute || !dut.audio.audio_rst_n)
                    $fatal(1,"ABORT new event swallowed during normal fade-in state=%0d mute=%b",dut.test_state,dut.effective_test_mute);
                event_gain=dut.test_gain;event_clock=clocks_seen;
                if((!MID_RAMP && event_gain>1) || (MID_RAMP && (event_gain<127 || event_gain>130)))
                    $fatal(1,"ABORT UART event missed requested fade window gain=%0d",event_gain);
                event_note=dut.note;
                case(EVENT_KIND)
                    0:event_velocity=dut.velocity;
                    1:event_velocity=dut.velocity0;
                    2:event_velocity=dut.velocity1;
                    3:event_velocity=dut.hat_closed_velocity;
                    4:event_velocity=dut.hat_open_velocity;
                endcase
                if(event_velocity!==8'd203 || (EVENT_KIND==0 && (event_note!=69 || dut.note_source!=1)))
                    $fatal(1,"ABORT MIDI note/source/velocity changed");
                deliveries=deliveries+1;
            end
        end
        #1;
        if(rst) begin
            if((^{pcm,owned,test_mode,tick,hp_bck,amp_bck})===1'bx || dut.overrun)
                $fatal(1,"ABORT unknown output or synth overrun");
            // 两个DAC串行器仍由整机复位控制，panic不得破坏其时钟/帧相位。
            if(dut.audio.u_pt8211.div_count!=={1'b0,dut.external_dac.div_count} ||
               dut.audio.u_pt8211.bit_index!==dut.external_dac.bit_index || hp_bck!==amp_bck)
                $fatal(1,"ABORT DAC clock/frame phase discontinuity");
            if(state_before==5 && dut.test_state==6) begin
                resume_checks=resume_checks+1;resume_clock=clocks_seen;
                if(!dut.normal_input_ready || test_mode || !owned || dut.test_gain!=0 ||
                   dut.effective_test_mute || !dut.panic_test_mute)
                    $fatal(1,"ABORT first fade-in cycle retained effective hard mute");
            end
            if(quiet_after_abort && dut.test_state!=6 && owned && pcm!==0)
                $fatal(1,"ABORT test tone/tail resurrected after MIDI panic");
            if(edge_events!=0) case(EVENT_KIND)
                0:if(dut.audio.gate[0]!==1 || dut.audio.note_bus[6:0]!==7'd69)
                    $fatal(1,"ABORT melody event not allocated");
                1:if(!dut.audio.kick_busy)$fatal(1,"ABORT kick pending/active lost");
                2:if(!dut.audio.snare_busy)$fatal(1,"ABORT snare pending/active lost");
                3:if(!dut.audio.closed_hat_busy)$fatal(1,"ABORT closed hat pending/active lost");
                4:if(!dut.audio.open_hat_busy)$fatal(1,"ABORT open hat pending/active lost");
            endcase
        end
    end

    task clocks;input integer count;begin repeat(count)@(negedge clk);end endtask
    task frames;input integer count;integer n;begin
        for(n=0;n<count;n=n+1)begin @(posedge clk);while(!tick)@(posedge clk);@(negedge clk);end
    end endtask
    task wait_state;input [3:0] expected;input integer limit;begin
        wait_count=0;
        while(dut.test_state!=expected && wait_count<limit)begin clocks(1);wait_count=wait_count+1;end
        if(dut.test_state!=expected)$fatal(1,"ABORT state %0d timeout at %0d",expected,dut.test_state);
    end endtask

    // 完整8N1，起始位、8数据位、停止位全长864clk。最后一字节可在停止位
    // 中心前4clk松开公共UI键，使FIFO/hit在渐入gain=0/1的最早可接收窗口交付。
    // 只是对真实引脚定时，不修改rx_valid/have_first等内部协议状态。
    task midi_byte;input [7:0] value;input release_in_stop;integer b;begin
        @(negedge clk);midi_rx=0;clocks(BIT_CLOCKS);
        for(b=0;b<8;b=b+1)begin midi_rx=value[b];clocks(BIT_CLOCKS);end
        midi_rx=1;
        if(release_in_stop)begin
            clocks(BIT_CLOCKS/2-4);ui_keys=0;clocks(BIT_CLOCKS/2+4);
        end else clocks(BIT_CLOCKS);
        uart_sent=uart_sent+1;
    end endtask
    task message;input [7:0] status,a,b;begin
        midi_byte(status,0);midi_byte(a,0);midi_byte(b,0);clocks(8);
    end endtask

    initial begin
        if(SHORT_VOICES<2 || SHORT_VOICES>32)$fatal(1,"ABORT invalid test voice count");
        @(posedge rst);clocks(8);
        // 真实MCP首轮采样完成前touch_fault=1，不能跳过生产的ghost入口保护。
        wait_count=0;
        while(dut.keypad_ghost && wait_count<20000)begin clocks(1);wait_count=wait_count+1;end
        if(dut.keypad_ghost)$fatal(1,"ABORT initial idle MCP sample never became valid");
        ui_keys=16'h5000;wait_state(1,2000);ui_keys=0;
        wait_state(3,160000);frames(4);
        if(!owned || !test_mode || requested!=32 || test_gate!==32'hffffffff ||
           (test_busy & ((64'b1<<SHORT_VOICES)-1))!=((64'b1<<SHORT_VOICES)-1) || test_pcm==0)
            $fatal(1,"ABORT precondition: live test32 request/gate/PCM missing");
        // S8不是退出/计数命令，仅用于在退出后真实地保持WAIT_RELEASE。
        ui_keys=16'h0080;clocks(4);
        if(CASE==1)midi_byte(8'hff,0);
        else if(CASE==2)begin
            midi_byte(8'hfe,0);
            if(!dut.input_hub.performance.midi_input.keyboard.sense_enabled || panics!=0)
                $fatal(1,"ABORT FE did not arm cleanly");
        end else message(8'hb0,120,0);
        wait_state(4,30000);
        if(panics!=1 || aborts!=1 || !dut.effective_test_mute || pcm!==0)
            $fatal(1,"ABORT actual UART panic did not immediately mute/request exit");
        wait_state(5,80000);frames(2);
        if(test_mode || requested!=0 || test_gate!=0 || !owned || !dut.panic_test_mute || busy!=0)
            $fatal(1,"ABORT test32 did not exit/clear voices at zero gain");

        if(CASE<3)begin
            ui_keys=0;wait_state(6,8);wait_state(0,75000);frames(16);
            if(owned || test_mode || test_gate!=0 || requested!=0 || pcm!==0 || busy!=0 ||
               dut.panic_test_mute || dut.effective_test_mute || panics!=1 || aborts!=1)
                $fatal(1,"ABORT stuck ownership, repeated panic or test tone after return");
        end else begin
            // 实际UART头两字节先送入解析器，未发送velocity前没有事件。
            midi_byte(EVENT_KIND==0?8'h90:8'h99,0);
            midi_byte({1'b0,note_for_event(EVENT_KIND)},0);
            if(!dut.input_hub.performance.midi_input.keyboard.have_first || deliveries!=0 ||
               dut.input_hub.performance.midi_input.keyboard.first_data!=note_for_event(EVENT_KIND))
                $fatal(1,"ABORT genuine UART partial message setup failed");
            expect_delivery=1;
            if(MID_RAMP)begin
                ui_keys=0;wait_state(6,8);
                while(dut.test_gain<100)clocks(1);
                midi_byte(101,0);
            end else midi_byte(101,1);
            clocks(8);
            if(deliveries!=1 || resume_checks!=1 || event_clock<=resume_clock)
                $fatal(1,"ABORT early/mid fade-in event missing");
            frames(96);
            if(pcm_after_delivery<4 || dut.effective_test_mute || dut.panic_test_mute ||
               panics!=1 || aborts!=1 || dut.test_state!=6)
                $fatal(1,"ABORT event captured but did not produce PCM within fade-in");
        end
        if(uart_received!=uart_sent || resume_checks!=1 || ticks_seen<750)
            $fatal(1,"ABORT UART/tick/resume coverage sent=%0d received=%0d ticks=%0d resume=%0d",uart_sent,uart_received,ticks_seen,resume_checks);
        $display("V021_ABORT_TEST_PASS case=%0d control_voices=%0d production_voices=32 uart_bit_clocks=864 audio_tick_clocks=288 bytes=%0d panics=%0d aborts=%0d resume=%0d deliveries=%0d gain=%0d event_delay_clocks=%0d pcm_frames=%0d ticks=%0d clocks=%0d",
            CASE,SHORT_VOICES,uart_received,panics,aborts,resume_checks,deliveries,event_gain,
            event_clock-resume_clock,pcm_after_delivery,ticks_seen,clocks_seen);
        $finish;
    end
    initial begin #50000000;$fatal(1,"V021_ABORT_TEST_FAIL bounded watchdog");end
endmodule
