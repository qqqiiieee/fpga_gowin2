`timescale 1ns/1ps
// 两音色生产语义的独立回归。旧bench不改预期，继续覆盖默认TIMBRE_COUNT=16。
// 本bench显式设2，独立维护0/1期望，不从DUT内部next_timbre复制答案。
// 同时走实体无源矩阵与虚拟扫描；所有刺激在下降沿，断言在NBA更新后观察。
module tb_timbre2_keypad;
    reg clk=0,rst_n=0,suppress=0,virtual_enable=0;
    always #5 clk=~clk;
    reg [15:0] pressed=0,virtual_keys=0;
    wire [3:0] rows,selected;
    reg [3:0] cols;
    wire [15:0] keys;
    wire ghost,note_on,note_off;
    wire [6:0] note;
    wire [7:0] velocity;
    wire [3:0] event_timbre;
    matrix_keypad #(.ROW_CYCLES(12),.DEBOUNCE_FRAMES(3),
        .PERFORMANCE_MODE(1),.TWO_BUTTON_SELECT(1),.TIMBRE_COUNT(2)) dut(
        .clk(clk),.rst_n(rst_n),.suppress_select(suppress),.rows(rows),.cols(cols),
        .virtual_enable(virtual_enable),.virtual_keys(virtual_keys),.velocity(8'd173),
        .note_on(note_on),.note_off(note_off),.note(note),.vel_out(velocity),
        .timbre_out(event_timbre),.key_state(keys),.ghost_active(ghost),.selected_timbre(selected));

    // 实体开关图做连通传播，可产生真实矩形鬼键；不是直接塞给DUT的消抖状态。
    reg [3:0] reached_rows,reached_cols;
    integer pass,r,c;
    always @(*) begin
        reached_rows=0;reached_cols=0;
        for(r=0;r<4;r=r+1)if(rows[r]===1'b0)reached_rows[r]=1;
        for(pass=0;pass<8;pass=pass+1)
            for(r=0;r<4;r=r+1)for(c=0;c<4;c=c+1)
                if(pressed[r*4+c])begin
                    if(reached_rows[r])reached_cols[c]=1;
                    if(reached_cols[c])reached_rows[r]=1;
                end
        cols=~reached_cols;
    end

    integer checks=0,ons=0,offs=0,probe_seen=0,same_edge_seen=0;
    integer cycles_checked=0,selection_changes=0;
    reg probe=0,probe_off=0;
    reg [3:0] probe_expected=0,before_edge;
    always @(posedge clk)begin
        before_edge=selected;
        #1;
        if(!rst_n)begin ons=0;offs=0;end
        else begin
            cycles_checked=cycles_checked+1;
            if(selected!==0 && selected!==1)$fatal(1,"TIMBRE2 range selected=%0d",selected);
            if(selected!==before_edge)selection_changes=selection_changes+1;
            if(note_on && note_off)$fatal(1,"TIMBRE2 simultaneous note events");
            if(note_on || note_off)begin
                if(event_timbre!==0 && event_timbre!==1)$fatal(1,"TIMBRE2 event range");
                if(note>79 || velocity!==173)$fatal(1,"TIMBRE2 control emitted note or wrong velocity");
            end
            if(note_on)ons=ons+1;
            if(note_off)offs=offs+1;
            if(probe && (probe_off?note_off:note_on))begin
                if(note!==60 || event_timbre!==probe_expected)
                    $fatal(1,"TIMBRE2 same-edge note=%0d timbre=%0d expected=%0d",note,event_timbre,probe_expected);
                probe_seen=probe_seen+1;
                if(selected!==before_edge)same_edge_seen=same_edge_seen+1;
            end
        end
    end
    task cycles;
        input integer n;
        begin repeat(n)@(negedge clk);#2;end
    endtask
    task choice;
        input [3:0] expected;
        begin
            checks=checks+1;
            if(selected!==expected)$fatal(1,"TIMBRE2 source=%0d keys=%h selected=%0d expected=%0d",
                virtual_enable,keys,selected,expected);
        end
    endtask
    task reset_case;
        input source;
        begin
            @(negedge clk);rst_n=0;pressed=0;virtual_keys=0;suppress=0;
            virtual_enable=source;probe=0;probe_off=0;probe_seen=0;same_edge_seen=0;
            cycles(4);rst_n=1;cycles(260);choice(0);
        end
    endtask
    task drive;
        input [15:0] mask;
        begin
            // 完整帧起点对齐使选择键松开与S1音符边沿在同帧消抖，实际检查事件旁路。
            @(negedge clk);
            while(!(dut.row_index==0 && dut.row_timer==0))@(negedge clk);
            pressed=mask;virtual_keys=mask;cycles(240);
            checks=checks+1;
            if(keys!==mask || ghost)$fatal(1,"TIMBRE2 scan keys=%h expected=%h ghost=%b",keys,mask,ghost);
        end
    endtask
    integer source,i,j,release_order,initial_choice,mask,k,expected_choice;
    integer chord_cases=0,wrap_releases=0,changes_before;
    initial begin
        for(source=0;source<2;source=source+1)begin
            reset_case(source);expected_choice=0;
            // S13、S14各32次，覆盖两方向0->1、1->0；长按不得自动重复。
            for(i=0;i<64;i=i+1)begin
                drive(i<32?16'h1000:16'h2000);choice(expected_choice);
                cycles(400);choice(expected_choice);
                drive(0);expected_choice=expected_choice^1;choice(expected_choice);
                wrap_releases=wrap_releases+1;
            end
            drive(16'h4000);drive(0);choice(0);
            drive(16'h8000);drive(0);choice(0);
            if(ons!=0 || offs!=0)$fatal(1,"TIMBRE2 selector/menu key emitted musical event");

            // 六种二键组合，枚举两个到达顺序、两个松开顺序及两种当前音色。
            // 先到的单键必须被后来的组合取消，不能在组合拆开后补切音色。
            for(initial_choice=0;initial_choice<2;initial_choice=initial_choice+1)
                for(i=0;i<4;i=i+1)for(j=0;j<4;j=j+1)if(i!=j)
                    for(release_order=0;release_order<2;release_order=release_order+1)begin
                        reset_case(source);
                        if(initial_choice)begin drive(16'h2000);drive(0);end
                        changes_before=selection_changes;
                        drive(16'h1000<<i);choice(initial_choice);
                        drive((16'h1000<<i)|(16'h1000<<j));choice(initial_choice);
                        drive(16'h1000<<(release_order?i:j));choice(initial_choice);
                        drive(0);choice(initial_choice);
                        if(selection_changes!=changes_before)$fatal(1,"TIMBRE2 chord changed selection transiently");
                        chord_cases=chord_cases+1;
                    end
            // 所有11个多键掩码，含三键/四键；同拍到达和同拍松开也不得误切。
            for(mask=1;mask<16;mask=mask+1)if((mask&(mask-1))!=0)begin
                reset_case(source);changes_before=selection_changes;
                drive(mask<<12);drive(0);choice(0);
                if(selection_changes!=changes_before)$fatal(1,"TIMBRE2 multi-control mask changed selection");
                chord_cases=chord_cases+1;
            end

            // 上层屏蔽期间完成的选择不能在解除屏蔽后重放；重新按松仍正常工作。
            reset_case(source);suppress=1;drive(16'h2000);drive(0);choice(0);
            suppress=0;cycles(300);choice(0);
            drive(16'h1000);drive(0);choice(1);

            // 来源切换产生的“松开”不能提交旧候选，且之后新手势可以正常选择。
            reset_case(source);drive(16'h1000);
            @(negedge clk);virtual_enable=!source;pressed=0;virtual_keys=0;cycles(300);choice(0);
            drive(16'h2000);drive(0);choice(1);

            // 候选遇到鬼键必须取消，旧普通音符保持，待全松后允许重新选择。
            reset_case(source);drive(16'h1001);
            @(negedge clk);pressed=16'h3001;virtual_keys=16'h3003;cycles(240);
            if(!ghost || keys!==16'h1001)$fatal(1,"TIMBRE2 ghost precondition not reached");
            drive(16'h1001);drive(16'h0001);choice(0);drive(0);
            if(ons!=1 || offs!=1)$fatal(1,"TIMBRE2 ghost/source guard lost normal note release");
            drive(16'h2000);drive(0);choice(1);

            // 选择松开与演奏键按下/松开同拍时，事件应带新ID；屏蔽时带原ID。
            for(k=0;k<2;k=k+1)begin
                reset_case(source);drive(16'h2000);suppress=k;
                probe=1;probe_expected=k?0:1;drive(1);probe=0;
                if(probe_seen!=1 || same_edge_seen!=(k?0:1))$fatal(1,"TIMBRE2 note-on bypass missing");
                choice(k?0:1);drive(0);
                reset_case(source);drive(16'h2001);suppress=k;
                probe=1;probe_off=1;probe_expected=k?0:1;drive(0);probe=0;
                if(probe_seen!=1 || same_edge_seen!=(k?0:1))$fatal(1,"TIMBRE2 note-off bypass missing");
                choice(k?0:1);
            end
        end
        $display("TIMBRE2_KEYPAD_TEST_PASS checks=%0d cycles=%0d wrap_releases=%0d chord_cases=%0d same_edge_cases=8",
            checks,cycles_checked,wrap_releases,chord_cases);
        $finish;
    end
    initial begin #10000000;$fatal(1,"TIMBRE2 keypad timeout");end
endmodule
