`timescale 1ns/1ps
// 公开端口测试：不force、不窥探picked/history，以后续旋钮行为验证重新接管。
// current_master_volume由测试端模拟外部最终仲裁结果，故意不自动回显手机请求。
module tb_midi_fx_phone;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg cc_valid=0, ui_fx_cycle=0, phone_set_valid=0;
    reg [6:0] cc_number=0, cc_value=0;
    reg [1:0] control_page=0;
    reg [7:0] current_master_volume=160;
    reg [7:0] phone_param=0, phone_value=0, phone_query_param=0;
    wire [7:0] phone_query_value, master_volume, mix_balance, brightness_base;
    wire master_volume_valid;
    wire [7:0] attack_ctrl, decay_ctrl, sustain_ctrl, release_ctrl;
    wire [1:0] fx_mode;
    wire [7:0] fx_amount, fx_time, fx_feedback, fx_mod;
    wire [31:0] knob_values;
    wire [7:0] legacy_time, legacy_feedback, legacy_mod, legacy_wet;
    wire legacy_volume_valid;
    wire [31:0] legacy_knobs;
    wire [89:0] state = {master_volume, mix_balance, brightness_base,
        attack_ctrl, decay_ctrl, sustain_ctrl, release_ctrl, fx_mode,
        fx_amount, fx_mod, fx_feedback, fx_time};
    reg [89:0] saved;
    integer groups=0, checks=0, volume_pulses=0;
    integer page_index, knob, other, value, param_index, mode_index;
    reg [7:0] desired;
    reg [1:0] expected_mode;

    midi_control_bank dut (
        .clk(clk), .rst_n(rst_n), .cc_valid(cc_valid),
        .cc_number(cc_number), .cc_value(cc_value), .control_page(control_page),
        .ui_fx_cycle(ui_fx_cycle), .current_master_volume(current_master_volume),
        .master_volume(master_volume), .master_volume_valid(master_volume_valid),
        .mix_balance(mix_balance), .brightness_base(brightness_base),
        .attack_ctrl(attack_ctrl), .decay_ctrl(decay_ctrl),
        .sustain_ctrl(sustain_ctrl), .release_ctrl(release_ctrl), .fx_mode(fx_mode),
        .fx_amount(fx_amount), .fx_time(fx_time),
        .fx_feedback(fx_feedback), .fx_mod(fx_mod), .knob_values(knob_values),
        .phone_set_valid(phone_set_valid), .phone_param(phone_param),
        .phone_value(phone_value), .phone_query_param(phone_query_param),
        .phone_query_value(phone_query_value)
    );
    // 基线命名端口调用保留：刻意不连接新增手机端口，检查Z不会屏蔽CC处理。
    midi_control_bank legacy_named (
        .clk(clk), .rst_n(rst_n), .cc_valid(cc_valid),
        .cc_number(cc_number), .cc_value(cc_value), .control_page(control_page),
        .ui_fx_cycle(ui_fx_cycle), .current_master_volume(current_master_volume),
        .master_volume(), .master_volume_valid(legacy_volume_valid),
        .mix_balance(), .brightness_base(), .attack_ctrl(), .decay_ctrl(),
        .sustain_ctrl(), .release_ctrl(), .fx_mode(),
        .fx_amount(legacy_wet), .fx_time(legacy_time),
        .fx_feedback(legacy_feedback), .fx_mod(legacy_mod), .knob_values(legacy_knobs)
    );

    // 每个采样沿检查恒定默认、显示顺序、请求有效条件；不把请求视为已生效。
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            checks=checks+1;
            if (mix_balance!==8'd128 || brightness_base!==8'd64)
                $fatal(1,"mix/brightness were changed by FX or phone");
            if (knob_values!=={fx_amount,fx_mod,fx_feedback,fx_time})
                $fatal(1,"knob_values is not the fixed FX target order");
            if (master_volume_valid!==(phone_set_valid && phone_param==0))
                $fatal(1,"volume valid must correspond only to phone SET 0");
            if (legacy_volume_valid!==1'b0)
                $fatal(1,"legacy unconnected phone produced volume request");
            if (master_volume_valid) volume_pulses=volume_pulses+1;
        end
    end

    function [6:0] knob_cc;
        input integer k;
        begin
            case(k)
                0:knob_cc=93; 1:knob_cc=91; 2:knob_cc=71; default:knob_cc=74;
            endcase
        end
    endfunction
    function [7:0] knob_param;
        input integer k;
        begin
            case(k)
                0:knob_param=5; 1:knob_param=6; 2:knob_param=7; default:knob_param=4;
            endcase
        end
    endfunction
    function [7:0] expanded;
        input [6:0] v;
        begin expanded={v,v[6]}; end
    endfunction
    function [7:0] fx_at;
        input integer k;
        begin
            case(k)
                0:fx_at=fx_time; 1:fx_at=fx_feedback; 2:fx_at=fx_mod; default:fx_at=fx_amount;
            endcase
        end
    endfunction
    function [7:0] actual_query;
        input [7:0] p;
        begin
            case(p)
                0:actual_query=current_master_volume;
                3:actual_query={6'd0,fx_mode};
                4:actual_query=fx_amount; 5:actual_query=fx_time;
                6:actual_query=fx_feedback; 7:actual_query=fx_mod;
                8:actual_query=attack_ctrl; 9:actual_query=decay_ctrl;
                10:actual_query=sustain_ctrl; 11:actual_query=release_ctrl;
                default:actual_query=0;
            endcase
        end
    endfunction
    task expect_query;
        input [7:0] p, want;
        begin
            phone_query_param=p; #2; checks=checks+1;
            if (phone_query_value!==want)
                $fatal(1,"GET %0d got %0d expected %0d",p,phone_query_value,want);
        end
    endtask
    task expect_fx;
        input integer k;
        input [7:0] want;
        begin
            checks=checks+1;
            if (fx_at(k)!==want)
                $fatal(1,"K%0d FX got %0d expected %0d page=%0d",k+1,fx_at(k),want,control_page);
            expect_query(knob_param(k),want);
        end
    endtask
    task drive_event;
        input cc_en;
        input [6:0] n, v;
        input set_en;
        input [7:0] p, data;
        input cycle_en;
        input [1:0] page;
        begin
            @(negedge clk);
            cc_valid=cc_en; cc_number=n; cc_value=v;
            phone_set_valid=set_en; phone_param=p; phone_value=data;
            ui_fx_cycle=cycle_en; control_page=page;
            @(posedge clk); #2;
        end
    endtask
    task idle;
        begin
            drive_event(0,0,0,0,0,0,0,control_page);
            if (master_volume_valid!==0) $fatal(1,"volume pulse did not clear");
        end
    endtask
    task send_cc;
        input [6:0] n,v;
        begin drive_event(1,n,v,0,0,0,0,control_page); idle; end
    endtask
    task send_phone;
        input [7:0] p,data;
        begin
            drive_event(0,0,0,1,p,data,0,control_page);
            if (p==0 && (master_volume_valid!==1 || master_volume!==data))
                $fatal(1,"phone volume request missing/wrong");
            idle;
        end
    endtask
    task reset;
        begin
            @(negedge clk); rst_n=0;
            cc_valid=0; phone_set_valid=0; ui_fx_cycle=0; control_page=0;
            current_master_volume=160; phone_query_param=0;
            repeat(2) @(negedge clk);
            rst_n=1; idle;
            if (master_volume!==180 || master_volume_valid!==0 ||
                mix_balance!==128 || brightness_base!==64 ||
                attack_ctrl!==32 || decay_ctrl!==96 || sustain_ctrl!==192 ||
                release_ctrl!==128 || fx_mode!==0 || fx_time!==96 ||
                fx_feedback!==80 || fx_mod!==48 || fx_amount!==64 ||
                knob_values!==32'h40305060)
                $fatal(1,"reset/default state mismatch");
            expect_query(0,160);
        end
    endtask
    task group_pass;
        input [8*100-1:0] label;
        begin groups=groups+1; $display("FX_PHONE_CASE_PASS %0s",label); end
    endtask

    initial begin
        reset;
        for (param_index=0;param_index<256;param_index=param_index+1)
            expect_query(param_index,actual_query(param_index));
        saved=state;
        // 无valid时改变所有负载，查询仍为实际值，不能因为总线值改变就写入。
        @(negedge clk); phone_param=5; phone_value=255; cc_number=93; cc_value=127;
        repeat(3) @(negedge clk);
        if (state!==saved) $fatal(1,"payload without valid changed state");
        group_pass("reset_defaults_all_256_query_ids_valid_gating");

        // 四个页面（含保留page3）均从默认目标就近接管，再逐个扫完128种CC值。
        // 检查非目标旋钮、ADSR、音量以及省略手机端口的旧命名实例。
        for (page_index=0;page_index<4;page_index=page_index+1) begin
            reset;
            drive_event(0,0,0,0,0,0,0,page_index); idle;
            send_cc(93,48); send_cc(91,40); send_cc(71,24); send_cc(74,32);
            for (knob=0;knob<4;knob=knob+1) begin
                for (value=0;value<128;value=value+1) begin
                    saved=state;
                    send_cc(knob_cc(knob),value);
                    expect_fx(knob,expanded(value));
                    for (other=0;other<4;other=other+1)
                        if (other!=knob && fx_at(other)!==saved[other*8+:8]) begin
                            // state低字节顺序time/feedback/mod/wet与旋钮顺序相同。
                            $fatal(1,"CC changed unrelated FX knob=%0d other=%0d",knob,other);
                        end
                    if (attack_ctrl!==32 || decay_ctrl!==96 || sustain_ctrl!==192 ||
                        release_ctrl!==128 || master_volume!==180 || master_volume_valid!==0 || fx_mode!==0)
                        $fatal(1,"fixed FX CC was routed to ADSR/volume/mode");
                    if (legacy_knobs!==knob_values)
                        $fatal(1,"omitting phone ports broke legacy named invocation");
                end
            end
        end
        group_pass("fixed_mapping_four_pages_2048_cc_values_legacy_named_ports_FX_stays_OFF");

        // 未接管的历史跨页面保留；同拍切页也不能清历史/接管。
        reset;
        send_cc(93,0); expect_fx(0,96);
        drive_event(1,93,60,0,0,0,0,1); idle; expect_fx(0,120);
        drive_event(1,93,127,0,0,0,0,2); idle; expect_fx(0,255);
        drive_event(1,93,0,0,0,0,0,3); idle; expect_fx(0,0);
        drive_event(1,93,127,0,0,0,0,0); idle; expect_fx(0,255);
        reset;
        send_cc(91,127); expect_fx(1,80);
        drive_event(0,0,0,0,0,0,0,3); idle;
        send_cc(91,0); expect_fx(1,0);
        group_pass("page_changes_keep_unpicked_crossing_history_and_picked_ownership");

        // 每个旋钮：远处不跳变，向上/向下跨越可接管；手机SET后必须重新接管。
        // 255旧历史跨到新目标100的0样本不能立即生效；同值SET也会重新接管。
        for (knob=0;knob<4;knob=knob+1) begin
            reset; desired=fx_at(knob);
            send_cc(knob_cc(knob),0); expect_fx(knob,desired);
            send_cc(knob_cc(knob),10); expect_fx(knob,desired);
            send_cc(knob_cc(knob),127); expect_fx(knob,255);
            send_phone(knob_param(knob),100);
            send_cc(knob_cc(knob),0); expect_fx(knob,100);
            send_cc(knob_cc(knob),10); expect_fx(knob,100);
            send_cc(knob_cc(knob),70); expect_fx(knob,141);
            send_phone(knob_param(knob),100);
            send_cc(knob_cc(knob),127); expect_fx(knob,100);
            send_cc(knob_cc(knob),100); expect_fx(knob,100);
            send_cc(knob_cc(knob),0); expect_fx(knob,0);
            send_phone(knob_param(knob),0);
            send_cc(knob_cc(knob),127); expect_fx(knob,0);
            send_cc(knob_cc(knob),0); expect_fx(knob,0);
            send_cc(knob_cc(knob),127); expect_fx(knob,255);
        end
        group_pass("all_knobs_soft_pickup_both_crossing_directions_phone_retarget_same_value");

        // +/-1容差（128、63不可精确扩展）与距离2必须拒绝，再允许真正跨越。
        // 穷举四旋钮的所有8位手机目标：第一条近目标CC均应可接管。
        for (knob=0;knob<4;knob=knob+1) begin
            for (value=0;value<256;value=value+1) begin
                send_phone(knob_param(knob),value);
                send_cc(knob_cc(knob),value>>1);
                expect_fx(knob,expanded(value>>1));
            end
            send_phone(knob_param(knob),128); send_cc(knob_cc(knob),64); expect_fx(knob,129);
            send_phone(knob_param(knob),63); send_cc(knob_cc(knob),31); expect_fx(knob,62);
            send_phone(knob_param(knob),100); send_cc(knob_cc(knob),49); expect_fx(knob,100);
            send_phone(knob_param(knob),100); send_cc(knob_cc(knob),51); expect_fx(knob,100);
        end
        group_pass("all_knobs_1024_phone_targets_within_one_tolerance_distance_two_rejected");

        // 同拍手机/CC只让手机拥有目标字段；既清picked也清同拍采样。
        // SET前和同拍分别落在目标两侧；下一CC也不能借任一旧位置假跨越。
        for (knob=0;knob<4;knob=knob+1) begin
            reset;
            send_cc(knob_cc(knob),0); send_cc(knob_cc(knob),127);
            drive_event(1,knob_cc(knob),127,1,knob_param(knob),100,0,2);
            expect_fx(knob,100); idle;
            send_cc(knob_cc(knob),0); expect_fx(knob,100);
            send_cc(knob_cc(knob),60); expect_fx(knob,120);
            drive_event(1,knob_cc(knob),0,1,knob_param(knob),100,0,3);
            idle; send_cc(knob_cc(knob),127); expect_fx(knob,100);
            send_cc(knob_cc(knob),0); expect_fx(knob,0);
            // 同拍CC正好在新目标附近也必须丢掉，不能预先保持picked。
            drive_event(1,knob_cc(knob),50,1,knob_param(knob),100,0,1);
            idle; send_cc(knob_cc(knob),127); expect_fx(knob,100);
        end
        group_pass("same_parameter_phone_wins_discards_old_and_collision_samples_all_knobs");

        // 逐一覆盖12组不同旋钮冲突：目标手机重设不清其它旋钮的接管。
        for (knob=0;knob<4;knob=knob+1) begin
            for (other=0;other<4;other=other+1) if(other!=knob) begin
                reset;
                send_cc(93,48); send_cc(91,40); send_cc(71,24); send_cc(74,32);
                drive_event(1,knob_cc(other),127,1,knob_param(knob),100,0,3);
                idle; expect_fx(knob,100); expect_fx(other,255);
                send_cc(knob_cc(other),0); expect_fx(other,0);
                send_cc(knob_cc(knob),127); expect_fx(knob,100);
            end
        end
        group_pass("different_parameter_same_cycle_updates_12_pairs_other_pickup_preserved");

        // CC7及所有其它非旋钮CC均不触碰控制库；四个page、所有128种CC号。
        reset;
        for (page_index=0;page_index<4;page_index=page_index+1) begin
            drive_event(0,0,0,0,0,0,0,page_index); idle;
            saved=state;
            for (value=0;value<128;value=value+1)
                if (value!=93 && value!=91 && value!=71 && value!=74) begin
                    send_cc(value,127);
                    if (state!==saved) $fatal(1,"non-knob CC %0d was misrouted",value);
                end
            // 外部音量换成滑杆/CC7实际值，不得使四个FX重新等待接管。
            send_cc(93,48);
            @(negedge clk); current_master_volume=page_index*53;
            idle; expect_query(0,page_index*53);
            send_cc(93,127); expect_fx(0,255);
            send_cc(93,48);
        end
        group_pass("CC7_all_non_knob_CCs_ignored_all_pages_external_volume_keeps_FX_pickup");

        // ADSR手机全量程读写，页面/CC不再拥有ADSR；并验证无关CC同拍仍生效。
        reset;
        send_cc(93,48);
        for (param_index=8;param_index<=11;param_index=param_index+1) begin
            for (value=0;value<256;value=value+1) begin
                drive_event(1,93,127,1,param_index,value,0,value%4);
                expect_query(param_index,value); idle; expect_fx(0,255);
            end
        end
        if (attack_ctrl!==255 || decay_ctrl!==255 || sustain_ctrl!==255 || release_ctrl!==255)
            $fatal(1,"ADSR byte range mismatch");
        group_pass("ADSR_1024_phone_writes_queries_unrelated_CC_same_cycle");

        // 手机音量是valid一拍请求；GET0永远看外部实际音量，包括尚未生效、
        // 外部后来改回滑杆，以及有效请求值恰好相同的重复SET。
        reset;
        for (value=0;value<256;value=value+1) begin
            send_phone(0,value); expect_query(0,160);
            if (master_volume!==value) $fatal(1,"volume request byte range");
        end
        if (volume_pulses!=256) $fatal(1,"volume request pulse count %0d",volume_pulses);
        send_phone(0,200); send_phone(0,200); expect_query(0,160);
        @(negedge clk); current_master_volume=200; #1; expect_query(0,200);
        @(negedge clk); current_master_volume=37; #1; expect_query(0,37);
        if (master_volume!==200) $fatal(1,"external actual volume overwrote request register");
        // 连续两拍独立SET允许背靠背valid，各拍都以该拍请求为准。
        drive_event(0,0,0,1,0,0,0,0);
        if(master_volume_valid!==1 || master_volume!==0) $fatal(1,"back-to-back volume first");
        drive_event(0,0,0,1,0,255,0,0);
        if(master_volume_valid!==1 || master_volume!==255) $fatal(1,"back-to-back volume second");
        idle; expect_query(0,37);
        send_cc(93,48);
        drive_event(1,93,127,1,0,77,0,1);
        if(master_volume_valid!==1 || master_volume!==77) $fatal(1,"phone volume/CC conflict");
        idle; expect_fx(0,255); expect_query(0,37);
        saved=state; repeat(10) idle;
        if(state!==saved || master_volume_valid!==0) $fatal(1,"idle repeated volume request");
        group_pass("volume_256_requests_one_cycle_repeat_back_to_back_actual_external_query");

        // OFF/Delay/Chorus/Reverb循环，SET同拍覆盖UI；所有非法8位mode不可截断。
        reset;
        for (value=1;value<=8;value=value+1) begin
            drive_event(0,0,0,0,0,0,1,control_page); idle;
            expect_query(3,value%4);
        end
        for (mode_index=0;mode_index<4;mode_index=mode_index+1) begin
            drive_event(0,0,0,1,3,mode_index,1,control_page); idle;
            expect_query(3,mode_index);
            // 手机改mode不影响FX旋钮接管；无关SET也不能吞掉UI cycle。
            send_cc(93,48);
            drive_event(1,93,127,1,3,mode_index,1,control_page); idle;
            expect_fx(0,255); expect_query(3,mode_index);
            expected_mode=(mode_index+1)%4;
            drive_event(0,0,0,1,8,23,1,control_page); idle;
            expect_query(3,{6'd0,expected_mode}); expect_query(8,23);
        end
        for (value=4;value<256;value=value+1) begin
            send_phone(3,2); saved=state;
            send_phone(3,value);
            if(state!==saved) $fatal(1,"illegal mode %0d changed state",value);
            drive_event(0,0,0,1,3,value,1,control_page); idle;
            expect_query(3,3);
        end
        group_pass("mode_OFF_default_cycle_phone_UI_priority_all_252_invalid_values");

        // 所有不归本库拥有的SET都无效，不清其它旋钮的picked/history。
        reset; send_cc(93,48);
        for (param_index=0;param_index<256;param_index=param_index+1)
            if(param_index!=0 && !(param_index>=3 && param_index<=11)) begin
                saved=state; send_phone(param_index,255);
                if(state!==saved) $fatal(1,"unknown/read-only SET %0d changed state",param_index);
                expect_query(param_index,0);
            end
        drive_event(1,93,127,1,15,255,1,2); idle;
        expect_fx(0,255); expect_query(3,1);
        group_pass("all_unknown_readonly_SET_GET_ignored_CC_UI_not_blocked");

        // Reset与CC/SET/UI同拍：复位优先，已接管、未接管历史和音量valid均清空。
        for(knob=0;knob<4;knob=knob+1) begin
            send_phone(knob_param(knob),100);
            send_cc(knob_cc(knob),0); send_cc(knob_cc(knob),127);
        end
        send_phone(8,255); send_phone(9,0); send_phone(10,0); send_phone(11,255);
        drive_event(1,93,127,1,0,255,1,3);
        if(master_volume_valid!==1) $fatal(1,"reset setup requires pending request");
        @(negedge clk); rst_n=0; #1;
        if(master_volume_valid!==0 || fx_mode!==0 || knob_values!==32'h40305060)
            $fatal(1,"asynchronous reset did not dominate pending event");
        @(posedge clk); #2;
        if(master_volume_valid!==0 || master_volume!==180 || attack_ctrl!==32 ||
            decay_ctrl!==96 || sustain_ctrl!==192 || release_ctrl!==128)
            $fatal(1,"held reset failed");
        @(negedge clk); cc_valid=0; phone_set_valid=0; ui_fx_cycle=0; rst_n=1;
        idle;
        for(knob=0;knob<4;knob=knob+1) begin
            desired=fx_at(knob);
            send_cc(knob_cc(knob),0); expect_fx(knob,desired);
            send_cc(knob_cc(knob),127); expect_fx(knob,255);
        end
        group_pass("reset_dominates_pending_CC_phone_UI_clears_all_pickup_history_and_valid");
        $display("MIDI_FX_PHONE_TEST_PASS groups=%0d checks=%0d",groups,checks);
        $finish;
    end
    initial begin #5000000; $fatal(1,"midi FX phone watchdog"); end
endmodule
