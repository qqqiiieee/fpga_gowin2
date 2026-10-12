// 四页界面控制，全部在27MHz源时钟域；sample_tick仅作为93750Hz计数使能。
// S15单键松开换页；S16在曲库/帮助页选项，在诊断页回演奏页。
// 默认长按阈值 75000 个 sample_tick = 0.8s；确认仍须松开，不连发。
// 所有组合键、鬼键和验证所有权都取消单键候选，避免旧快捷键误翻页。
// S13/S14由matrix_keypad负责前/后音色，本模块不改变音频或虚拟键协议。
module instrument_ui_control #(parameter HOLD_SAMPLES=75000)(
    input clk,input rst_n,input sample_tick,input [15:0] keys,
    input ghost,input test_owned,input remote_active,
    output reg [1:0] page,output reg [1:0] cursor,output reg [1:0] song_id,
    output reg song_start,output reg song_toggle,output reg song_restart
);
    localparam LIVE=2'd0,LIBRARY=2'd1,HELP=2'd2,DIAGNOSTIC=2'd3;
    reg [1:0] pending;
    reg cancelled,wait_release,remote_previous;
    // 计数宽度随参数改变，避免长按阈值超过 131071 时计数溢出。
    // 参数为 0/负数时归一为 1，保证比较和 $clog2 结果均有效。
    localparam HOLD_LIMIT = HOLD_SAMPLES < 1 ? 1 : HOLD_SAMPLES;
    localparam HOLD_WIDTH = HOLD_LIMIT < 2 ? 1 : $clog2(HOLD_LIMIT);
    reg [HOLD_WIDTH-1:0] held_samples;
    reg long_press;
    wire is_page=keys==16'h4000;
    wire is_next=keys==16'h8000;
    wire clean_release=(keys==0) && !ghost;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            page<=LIVE;cursor<=0;song_id<=0;
            song_start<=0;song_toggle<=0;song_restart<=0;
            pending<=0;cancelled<=0;wait_release<=1;remote_previous<=0;
            held_samples<=0;long_press<=0;
        end else begin
            song_start<=0;song_toggle<=0;song_restart<=0;
            remote_previous<=remote_active;
            if(test_owned || remote_previous!=remote_active) begin
                // 退出测试或切换实体/远程来源必须先全部松开。
                pending<=0;cancelled<=0;wait_release<=1;held_samples<=0;long_press<=0;
                if(test_owned)page<=LIVE;
            end else if(wait_release) begin
                if(clean_release)wait_release<=0;
            end else if(clean_release) begin
                if(!cancelled && pending==1) begin
                    page<=page+2'd1;
                    cursor<=page==LIVE ? song_id : 2'd0;
                end else if(!cancelled && pending==2) begin
                    if(page==LIVE) begin
                        if(long_press)song_restart<=1;else song_toggle<=1;
                    end else if(page==LIBRARY && long_press) begin
                        song_id<=cursor;song_start<=1;page<=LIVE;
                    end else if(page==DIAGNOSTIC)begin
                        // 本页没有列表；S16 提供可见的退出操作，短按长按均可。
                        page<=LIVE;cursor<=0;
                    end else if(long_press)cursor<=0;
                    else cursor<=cursor==2 ? 2'd0 : cursor+2'd1;
                end
                pending<=0;cancelled<=0;held_samples<=0;long_press<=0;
            end else if(ghost || (!is_page && !is_next)) begin
                cancelled<=1;
            end else if(pending==0 && !cancelled) begin
                pending<=is_page ? 2'd1 : 2'd2;held_samples<=0;long_press<=0;
            end else if((pending==1 && !is_page) || (pending==2 && !is_next)) begin
                cancelled<=1;
            end else if(pending==2 && sample_tick && !long_press) begin
                if(held_samples>=HOLD_LIMIT-1)long_press<=1;
                else held_samples<=held_samples+1'b1;
            end
        end
    end
endmodule
