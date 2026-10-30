`timescale 1ns/1ps
// Hub公开接口安全回归：MIDI数据全部经真实UART引脚，不force任何内部信号。
// 两份Hub共享输入，索引1为V021，索引0为默认CONTROL_BANK_ENABLE=0的旧路径。
// 快速配置只把MIDI解析器时钟参数缩为1MHz，仍为31250baud、完整8N1；
// CLK_HZ=27000000时同一组断言使用生产864clk/bit，不修改生产RTL接口。
module tb_v021_hub_safety #(
    parameter integer CLK_HZ=1000000
);
    localparam integer BIT_CYCLES=(CLK_HZ+15625)/31250;
    localparam real HALF_NS=500000000.0/CLK_HZ;
    reg clk=0, rst_n=0, rx=1;
    always #(HALF_NS) clk=~clk;
    reg allow_performance=1, suppress_controls=0, remote_active=0, digital_zero=0;
    reg strum_mode=0, manual_panic=0, knob_volume_valid=0;
    reg [7:0] physical_volume=160, knob_volume=0;
    wire [1:0] cc_valid, panic_audio;
    wire [6:0] cc_number [0:1], cc_value [0:1];
    wire [7:0] volume [0:1];
    // 四位依次为底鼓、军鼓、闭镲、开镲，直接观察Hub公共输出。
    wire [3:0] hits [0:1];
    wire [7:0] pad_velocity [0:1][0:3];
    integer cc_count [0:1];
    integer pad_count [0:1][0:3];
    reg [7:0] last_velocity [0:1][0:3];
    integer md,mp,k,e,i;
    genvar g;
    generate for(g=0;g<2;g=g+1) begin:configurations
        performance_input_hub #(.MIDI_ENABLE(1),.CONTROL_BANK_ENABLE(g)) dut (
            .clk(clk),.rst_n(rst_n),.sample_tick(1'b0),
            .allow_performance(allow_performance),.suppress_controls(suppress_controls),
            .remote_active(remote_active),.digital_zero(digital_zero),.midi_rx(rx),.optical_beams(2'b11),
            .local_on(1'b0),.local_off(1'b0),.local_note(7'd0),.local_velocity(8'd0),
            .local_timbre(4'd0),.selected_timbre(4'd0),.local_keys(16'd0),
            .physical_volume(physical_volume),.physical_pitch(9'sd0),
            .note_on(),.note_off(),.note(),.velocity(),.timbre(),.event_source(),
            .volume(volume[g]),.pitch(),.program_valid(),.program_timbre(),
            .midi_hit0(hits[g][0]),.midi_hit1(hits[g][1]),
            .midi_drum_velocity0(pad_velocity[g][0]),.midi_drum_velocity1(pad_velocity[g][1]),
            .panic_audio(panic_audio[g]),.performance_keys(),.primary_note(),.primary_valid(),
            .diagnostic_status(),.pressure_vibrato(8'd0),.strum_mode(strum_mode),
            .manual_panic(manual_panic),.knob_volume_valid(knob_volume_valid),.knob_volume(knob_volume),
            .cc_valid(cc_valid[g]),.cc_number(cc_number[g]),.cc_value(cc_value[g]),
            .hat_closed_hit(hits[g][2]),.hat_open_hit(hits[g][3]),
            .hat_closed_velocity(pad_velocity[g][2]),.hat_open_velocity(pad_velocity[g][3])
        );
        defparam dut.midi_input.keyboard.CLK_HZ=CLK_HZ;
    end endgenerate

    // 与真实接收端一样在posedge读取有效脉冲，不能把半拍出现后被取消的valid
    // 当作已交付。这里不查看/驱动解析器内部data、valid、FIFO或所有权寄存器。
    always @(posedge clk) begin
        for(md=0;md<2;md=md+1) begin
            if(!rst_n) begin
                cc_count[md]=0;
                for(mp=0;mp<4;mp=mp+1) begin
                    pad_count[md][mp]=0; last_velocity[md][mp]=0;
                end
            end else begin
                if(cc_valid[md]) cc_count[md]=cc_count[md]+1;
                for(mp=0;mp<4;mp=mp+1) begin
                    if(hits[md][mp]) begin
                        pad_count[md][mp]=pad_count[md][mp]+1;
                        last_velocity[md][mp]=pad_velocity[md][mp];
                    end
                    if(!hits[md][mp] && pad_velocity[md][mp]!=0)
                        $fatal(1,"pad velocity leaked without hit cfg=%0d pad=%0d",md,mp);
                end
            end
        end
    end
    task ticks; input integer n; begin repeat(n) @(negedge clk); end endtask
    task reset;
        begin
            @(negedge clk); rst_n=0; rx=1; allow_performance=1; suppress_controls=0;
            remote_active=0; digital_zero=0; strum_mode=0; manual_panic=0;
            knob_volume_valid=0; knob_volume=0; physical_volume=160;
            ticks(6); rst_n=1; ticks(BIT_CYCLES*2);
        end
    endtask
    task tx;
        input [7:0] data;
        integer b;
        begin
            @(negedge clk); rx=0; ticks(BIT_CYCLES);
            for(b=0;b<8;b=b+1) begin rx=data[b]; ticks(BIT_CYCLES); end
            rx=1; ticks(BIT_CYCLES);
        end
    endtask
    task message;
        input [7:0] status;
        input [6:0] a,b;
        begin tx(status);tx({1'b0,a});tx({1'b0,b});ticks(3);end
    endtask
    task set_physical;
        input [7:0] value;
        begin @(negedge clk);physical_volume=value;ticks(3);end
    endtask
    task k1;
        input [7:0] value;
        begin
            @(negedge clk);knob_volume=value;knob_volume_valid=1;
            @(negedge clk);knob_volume_valid=0;ticks(3);
        end
    endtask
    task boundary;
        input integer kind,on_value;
        begin case(kind)
            0: manual_panic=on_value!=0;
            1: digital_zero=on_value!=0;
            2: strum_mode=on_value!=0;
            3: remote_active=on_value!=0;
            4: allow_performance=on_value==0;
            default:$fatal(1,"unknown public boundary");
        endcase end
    endtask
    function [6:0] pad_note;
        input integer index;
        begin case(index)
            0:pad_note=36;1:pad_note=38;2:pad_note=37;default:pad_note=39;
        endcase end
    endfunction
    task stock_pads;
        integer p,d;
        begin
            for(p=0;p<4;p=p+1) begin
                message(8'h99,pad_note(p),100);
                for(d=0;d<2;d=d+1)
                    if(pad_count[d][p]!=1 || last_velocity[d][p]!=201)
                        $fatal(1,"BankA normal map/velocity cfg=%0d pad=%0d",d,p);
            end
        end
    endtask

    // 每种公共边界碰撞：通用CC93、旧CC7及全部四Pad；同时挂起合法K1请求。
    // 等待的是旧参数实例的公共输出，保证UART消息真实到达且正等待接收沿；
    // 然后只驱动公共输入，绝不force内部valid或直接写内部控制状态。
    task collision;
        input integer kind,event_type;
        reg [7:0] status;
        reg [6:0] number;
        integer p;
        begin
            reset;set_physical(163);k1(40);
            if(volume[1]!=40 || volume[0]!=163) $fatal(1,"collision baseline / legacy K1 ignored");
            status=event_type<2?8'hb0:8'h99;
            number=event_type==0?7'd93:(event_type==1?7'd7:pad_note(event_type-2));
            tx(status);tx({1'b0,number});
            fork
                tx(100);
                begin
                    if(event_type<2) wait(cc_valid[0]);
                    else wait(hits[0][event_type-2]);
                    @(negedge clk);
                    boundary(kind,1);knob_volume=200;knob_volume_valid=1;
                    #1;
                    if(cc_valid[1] || hits[1]!=0 || pad_velocity[1][0]!=0 ||
                       pad_velocity[1][1]!=0 || pad_velocity[1][2]!=0 || pad_velocity[1][3]!=0)
                        $fatal(1,"global cancel leaked output boundary=%0d event=%0d",kind,event_type);
                    if(panic_audio[1] !== (kind!=4)) $fatal(1,"public panic boundary mismatch");
                    if(event_type<2 && !cc_valid[0]) $fatal(1,"legacy CC behavior changed");
                    if(event_type>=2 && !hits[0][event_type-2]) $fatal(1,"legacy Pad behavior changed");
                    @(negedge clk);boundary(kind,0);knob_volume_valid=0;
                end
            join
            ticks(5);
            if(cc_count[1]!=0) $fatal(1,"cancelled CC delivered late");
            for(p=0;p<4;p=p+1)
                if(pad_count[1][p]!=0) $fatal(1,"cancelled Pad delivered late");
            // remote接管本来就释放音量所有权；其余边界应保留旧目标40。
            if(volume[1] !== (kind==3?8'd163:8'd40))
                $fatal(1,"cancelled CC7/K1 committed boundary=%0d event=%0d volume=%0d",kind,event_type,volume[1]);
            if(event_type<2 && cc_count[0]!=1) $fatal(1,"legacy in-flight CC was not preserved");
            if(event_type>=2 && pad_count[0][event_type-2]!=1)
                $fatal(1,"legacy in-flight Pad was not preserved");
            if(event_type==1 && volume[0] !== ((kind==0 || kind==2)?8'd201:8'd163))
                $fatal(1,"legacy CC7 arbitration changed");
            // 被取消的K1脉冲不能排队重放，也不能被错误记为已见而拒收后续同值新请求。
            k1(200);
            if(volume[1]!=200) $fatal(1,"fresh K1 after cancellation was lost");
            $display("HUB_CASE_PASS public_boundary=%0d uart_event=%0d pending_K1_cancelled",kind,event_type);
        end
    endtask
    task midi_panic_collision;
        input integer use_reset;
        begin
            reset;set_physical(163);k1(40);
            fork
                begin
                    if(use_reset)tx(8'hff);else message(8'hb0,120,0);
                end
                begin
                    wait(panic_audio[0]);@(negedge clk);knob_volume=200;knob_volume_valid=1;
                    #1;
                    if(!panic_audio[1] || cc_valid[1] || hits[1]!=0)
                        $fatal(1,"real UART panic leaked CC/Pad");
                    @(negedge clk);knob_volume_valid=0;
                end
            join
            ticks(5);
            if(volume[1]!=163 || cc_count[1]!=0) $fatal(1,"MIDI panic failed to cancel pending K1");
            k1(200);if(volume[1]!=200)$fatal(1,"K1 failed after MIDI panic");
            $display("HUB_CASE_PASS real_UART_panic=%0d pending_K1_cancelled",use_reset);
        end
    endtask

    initial begin
        reset;stock_pads;
        message(8'hb0,93,100);
        if(cc_count[1]!=1 || cc_count[0]!=1 || cc_number[1]!=93 || cc_value[1]!=100)
            $fatal(1,"normal generic CC changed");
        $display("HUB_CASE_PASS normal_UART_CC_and_BankA_four_pads");

        reset;set_physical(163);k1(40);
        set_physical(164);
        if(volume[1]!=40 || volume[0]!=164)$fatal(1,"K1 anchor / legacy one-code retake");
        set_physical(166);if(volume[1]!=40)$fatal(1,"K1 under-four-code jitter stole volume");
        set_physical(167);if(volume[1]!=167)$fatal(1,"K1 slow cumulative four-code retake lost");
        k1(40);if(volume[1]!=167)$fatal(1,"same K1 value stole physical ownership");
        k1(41);set_physical(168);if(volume[1]!=41)$fatal(1,"changed K1 did not reset physical anchor");
        $display("HUB_CASE_PASS K1_anchor_jitter_cumulative_retake_duplicate_value");

        reset;set_physical(163);message(8'hb0,7,20);
        if(volume[1]!=40 || volume[0]!=40)$fatal(1,"CC7 ownership acquisition");
        set_physical(164);
        if(volume[1]!=40 || volume[0]!=164)$fatal(1,"CC7 anchor / legacy retake");
        set_physical(166);if(volume[1]!=40)$fatal(1,"CC7 jitter stole volume");
        set_physical(167);if(volume[1]!=167)$fatal(1,"CC7 cumulative retake lost");
        message(8'hb0,7,20);if(volume[1]!=167)$fatal(1,"duplicate CC7 stole volume");
        message(8'hb0,7,21);set_physical(168);
        if(volume[1]!=42 || volume[0]!=168)$fatal(1,"changed CC7 anchor / legacy retake");
        $display("HUB_CASE_PASS UART_CC7_anchor_jitter_duplicate_and_legacy_behavior");

        for(k=0;k<5;k=k+1)
            for(e=0;e<6;e=e+1)collision(k,e);
        midi_panic_collision(0);midi_panic_collision(1);

        // owned正常渐入可同时有suppress_controls=1和allow_performance=1。
        // 只拒收分页CC，不能把新Pad也错误地按整个owned窗口屏蔽。
        reset;suppress_controls=1;stock_pads;
        message(8'hb0,93,100);
        if(cc_count[0]!=0 || cc_count[1]!=0)$fatal(1,"suppressed control CC leaked");
        $display("HUB_CASE_PASS normal_resume_Pads_allowed_while_controls_suppressed");

        // 扫弦模式稳定后只屏蔽主旋律直通；CC与四Pad仍可正常交付。
        reset;@(negedge clk);strum_mode=1;ticks(4);stock_pads;
        message(8'hb0,93,100);
        if(cc_count[1]!=1)$fatal(1,"stable strum mode incorrectly blocked CC/Pad");
        $display("HUB_CASE_PASS stable_strum_mode_keeps_CC_and_Pads");
        $display("V021_HUB_SAFETY_TEST_PASS clk_hz=%0d boundary_pairs=30",CLK_HZ);$finish;
    end
    initial begin #300000000; $fatal(1,"Hub safety watchdog"); end
endmodule
