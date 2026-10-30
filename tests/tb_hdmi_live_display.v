`timescale 1ns/1ps
// Independent raw coordinate / 3-stage sync and RGB reference.
module tb_hdmi_live_display;

    localparam [23:0] BG=24'h0b101c,PANEL=24'h172338,BORDER=24'h34465f,
        GRID=24'h22324a,TEXT=24'he2e8f0,MUTED=24'h91a4be,CYAN=24'h51d6e8,
        GREEN=24'h21c6a8,AMBER=24'hf4bb4f,ALERT=24'hff5964;
    // 512 codes x 16 rows. Code bit 8 and row bit 3 must both survive.
    // This test ROM is separate storage; no hierarchical DUT glyph call/read.
    reg [7:0] reference_rom [0:8191];
    integer rom_i;
    initial begin
        $readmemh("src/ui_font.hex",reference_rom);
        #0.01;
        for(rom_i=0;rom_i<8192;rom_i=rom_i+1)
            if((^reference_rom[rom_i])===1'bx)$fatal(1,"Reference ROM missing row %0d",rom_i);
    end
    function [287:0] reference_ascii;
        input [287:0] base;
        input integer start;
        input [255:0] text;
        input integer chars;
        integer ci;
        begin
            reference_ascii=base;
            for(ci=0;ci<chars;ci=ci+1)
                reference_ascii[287-(start+ci)*9 -: 9]=(text >> ((chars-1-ci)*8)) & 9'h0ff;
        end
    endfunction
    function [287:0] reference_number;
        input [287:0] base;
        input integer start,chars,value;
        integer ci,divisor;
        begin
            reference_number=base;divisor=1;
            for(ci=1;ci<chars;ci=ci+1)divisor=divisor*10;
            for(ci=0;ci<chars;ci=ci+1)begin
                reference_number[287-(start+ci)*9 -: 9]=48+(value/divisor)%10;
                divisor=divisor/10;
            end
        end
    endfunction
    function reference_lit;
        input [287:0] label;
        input integer xx,yy;
        reg [8:0] code;
        reg [7:0] bits;
        begin
            code=label[287-(xx/8)*9 -: 9];
            bits=reference_rom[code*16+yy];
            reference_lit=bits[7-(xx%8)];
        end
    endfunction
    function integer reference_y;
        input integer sample,gain;
        integer displacement;
        begin
            displacement=(sample*(1<<gain))>>>9;
            if(displacement>60)displacement=60;
            if(displacement< -60)displacement=-60;
            reference_y=212-displacement;
        end
    endfunction
    function [23:0] reference_scope;
        input integer px,py,previous,current,gain,valid;
        integer y0,y1,lo,hi;
        begin
            reference_scope=BG;
            if(px>=31 && px<=544 && py>=143 && py<=280)begin
                reference_scope=BORDER;
                if(px>=32 && px<=543 && py>=144 && py<=279)begin
                    reference_scope=PANEL;
                    if((px-32)%64==0 || py==176 || py==248)reference_scope=GRID;
                    if(py==212)reference_scope=BORDER;
                    y0=reference_y(previous,gain);y1=reference_y(current,gain);
                    lo=y0<y1?y0:y1;hi=y0>y1?y0:y1;
                    if(valid && py>=lo && py<=hi)reference_scope=CYAN;
                end
            end
        end
    endfunction
    localparam [287:0] ZH_BLANK=288'h100804020100804020100804020100804020100804020100804020100804020100804020; // 
    localparam [287:0] ZH_TITLE=288'h402050483422150c87442244020100804020100804020100804020100804020100804020; // 多音色乐器
    localparam [287:0] ZH_GUIDE=288'h4924d28954a2552c974c2644020100804020100804020100804020100804020100804020; // 小星星跟弹
    localparam [287:0] ZH_FREE=288'h4522d188d4723d2091100804020100804020100804020100804020100804020100804020; // 自由演奏
    localparam [287:0] ZH_DONE_TITLE=288'h4d26d389d4f27d40a1100804020100804020100804020100804020100804020100804020; // 练习完成
    localparam [287:0] ZH_DONE=288'h4f27d40a1100804020100804020100804020100804020100804020100804020100804020; // 完成
    localparam [287:0] ZH_WAIT=288'h7a3d5ecf7100804020100804020100804020100804020100804020100804020100804020; // 等待
    localparam [287:0] ZH_HOLD=288'h783c5e4f3100804020100804020100804020100804020100804020100804020100804020; // 保持
    localparam [287:0] ZH_WRONG=288'h763b5dcef100804020100804020100804020100804020100804020100804020100804020; // 错误
    localparam [287:0] ZH_CURRENT=288'h5128d48a5100b45a2d168806030180c0907a100804020100804020100804020100804020; // 当前 ---- 0000Hz
    localparam [287:0] ZH_VOLUME=288'h4120d4ca7100c06030128804020100804020100804020100804020100804020100804020; // 音量 000%
    localparam [287:0] ZH_RMS_NEG=288'h29134a620168c06030321088c53100804020100804020100804020100804020100804020; // RMS -000dBFS
    localparam [287:0] ZH_RMS_POS=288'h29134a620158c06030321088c53100804020100804020100804020100804020100804020; // RMS +000dBFS
    localparam [287:0] ZH_PEAK=288'h542a554ab100c06030128804020100804020100804020100804020100804020100804020; // 峰值 000%
    localparam [287:0] ZH_VOICES=288'h562b55caf100c06020100804020100804020100804020100804020100804020100804020; // 声部 00
    localparam [287:0] ZH_PAD0=288'h582c46220180c06020100804020100804020100804020100804020100804020100804020; // 鼓1 000
    localparam [287:0] ZH_PAD1=288'h582c46420180c06020100804020100804020100804020100804020100804020100804020; // 鼓2 000
    localparam [287:0] ZH_PITCH_NEG=288'h592cd68b5100b46030180804020100804020100804020100804020100804020100804020; // 移调 -000
    localparam [287:0] ZH_PITCH_POS=288'h592cd68b5100ac6030180804020100804020100804020100804020100804020100804020; // 移调 +000
    localparam [287:0] ZH_LOWEST=288'h5d2ed78bd5f2fd80c16130d88c56331d90c94120d6cb7100804020100804020100804020; // 最低按住键的设定音符
    localparam [287:0] ZH_CLOCK=288'h231cc4039198dc6a30241e84020100804020100804020100804020100804020100804020; // Fs 93750Hz
    localparam [287:0] ZH_PCM=288'h2810c9aca65b319a203c0c8bc30180804020100804020100804020100804020100804020; // PCM波形 x2^00
    localparam [287:0] ZH_FLAGS=288'h6733da0d1100804020100804020100804020100804020100804020100804020100804020; // 状态
    localparam [287:0] ZH_KEYS=288'h6130dcce71014c622d298c46420100804020100804020100804020100804020100804020; // 键盘 S1-S12
    localparam [287:0] ZH_STEP=288'hdb6de8d47100c0602f180c04020100804020100804020100804020100804020100804020; // 进度 00/00
    localparam [287:0] ZH_BEATS=288'h743a5d4eb100c04020100804020100804020100804020100804020100804020100804020; // 节拍 0
    localparam [287:0] ZH_PLAY=288'h5128d48a5100b45a207c3e5f4fb7e3f4402d168804020100804020100804020100804020; // 当前 -- 下一个 --
    localparam [287:0] ZH_HINT=288'h7f3fe01018140c410482c1a0f0884882150b763b5dcef100804020100804020100804020; // 黄提示 绿正确 红错误
    localparam [287:0] ZH_NEXT_HINT=288'h86435148b462351c8f48244410e87c4222f87cbe9f6fc7e8804020100804020100804020; // 青自由演奏 角标下一个
    localparam [287:0] ZH_SHORTCUT_GUIDE=288'h298c4662b298c46c204b25d3099100804020100804020100804020100804020100804020; // S13+S16 跟弹
    localparam [287:0] ZH_SHORTCUT_RESTART=288'h298c4662b298c468208944e2915100804020100804020100804020100804020100804020; // S13+S14 重开
    localparam [287:0] ZH_FOOT1=288'h8b45e3119101489a53101908446298805e202810c9a20100804020100804020100804020; // 数字 RMS dBFS / PCM
    localparam [287:0] ZH_FOOT2=288'h5f2fd84c3dc6e594cb663368543ab55f65b3da6d44020100804020100804020100804020; // 按键与波形实时监测
    localparam [287:0] ZH_TEST_TITLE=288'h198ca7139904864523100804020100804020100804020100804020100804020100804020; // 32路验证
    localparam [287:0] ZH_TEST_SUBTITLE=288'hba5d6ed77d46a755ab442244020100804020100804020100804020100804020100804020; // 独立振荡器
    localparam [287:0] ZH_REQUESTED=288'h974be6131100c06020100804020100804020100804020100804020100804020100804020; // 请求 00
    localparam [287:0] ZH_ACTIVE=288'h994ce6935100c06020100804020100804020100804020100804020100804020100804020; // 活跃 00
    localparam [287:0] ZH_FIXED=288'h9d4ed90c9d66b75daf100804020100804020100804020100804020100804020100804020; // 固定输出
    localparam [287:0] ZH_SWEEP=288'h9b4de7139904864523100804020100804020100804020100804020100804020100804020; // 逐路验证
    localparam [287:0] ZH_FIXED_VOLUME=288'h9d4ed90c94120d4ca7100804020100804020100804020100804020100804020100804020; // 固定音量
    localparam [287:0] ZH_FREQ_CONFIG=288'h9e4f63d1f5c2e67d3fa050554ab100804020100804020100804020100804020100804020; // 频率为配置值
    localparam [287:0] ZH_INDEX=288'hae576bd5f100c06020100804020100804020100804020100804020100804020100804020; // 索引 00
    localparam [287:0] ZH_SET=288'h6331d90c9100c0603018120f420100804020100804020100804020100804020100804020; // 设定 0000Hz
    localparam [287:0] ZH_SCHED_OK=288'h5a2d68d478341e954b100804020100804020100804020100804020100804020100804020; // 调度正常
    localparam [287:0] ZH_SCHED_BAD=288'h5a2d68d47a4526954b100804020100804020100804020100804020100804020100804020; // 调度异常
    localparam [287:0] ZH_SCHED=288'h5a2d68d47100804020100804020100804020100804020100804020100804020100804020; // 调度
    localparam [287:0] ZH_ERROR=288'ha4526954b100804020100804020100804020100804020100804020100804020100804020; // 异常
    localparam [287:0] ZH_FFT=288'hb45a6d56b101188c54b75bee171100804020100804020100804020100804020100804020; // 电脑 FFT检查
    localparam [287:0] ZH_TEST_EXIT=288'h298c46db0d8ebb5e20100804020100804020100804020100804020100804020100804020; // S16退出
    function [287:0] reference_timbre_label;
        input integer index;
        begin
            case(index)
                0: reference_timbre_label=288'h4120d0885100c060208341ef179100804020100804020100804020100804020100804020; // 音色 00 正弦
                1: reference_timbre_label=288'h4120d0885100c06220bd5eef97dbf5ff0181100804020100804020100804020100804020; // 音色 01 柔和长笛
                2: reference_timbre_label=288'h4120d0885100c06420c160f0985100804020100804020100804020100804020100804020; // 音色 02 木管
                3: reference_timbre_label=288'h4120d0885100c06620c361d0483c4627158b100804020100804020100804020100804020; // 音色 03 暖音风琴
                4: reference_timbre_label=288'h4120d0885100c06820c66371d8fc26144020100804020100804020100804020100804020; // 音色 04 空心管
                5: reference_timbre_label=288'h4120d0885100c06a20bd5eef97dc86470985100804020100804020100804020100804020; // 音色 05 柔和铜管
                6: reference_timbre_label=288'h4120d0885100c06c20c160f158b100804020100804020100804020100804020100804020; // 音色 06 木琴
                7: reference_timbre_label=288'h4120d0885100c06e20c964ef179100804020100804020100804020100804020100804020; // 音色 07 拨弦
                8: reference_timbre_label=288'h4120d0885100c07020bd5eef97dbc5e50c87100804020100804020100804020100804020; // 音色 08 柔和弦乐
                9: reference_timbre_label=288'h4120d0885100c07220ca6572d97100804020100804020100804020100804020100804020; // 音色 09 簧片
                10: reference_timbre_label=288'h4120d0885100c46020cc667359bc4627158b100804020100804020100804020100804020; // 音色 10 明亮风琴
                11: reference_timbre_label=288'h4120d0885100c46220ce67558ad100804020100804020100804020100804020100804020; // 音色 11 钟声
                12: reference_timbre_label=288'h4120d0885100c46420cf67f158b100804020100804020100804020100804020100804020; // 音色 12 口琴
                13: reference_timbre_label=288'h4120d0885100c46620d068745a3502844020100804020100804020100804020100804020; // 音色 13 厚合成
                14: reference_timbre_label=288'h4120d0885100c46820d26974da7100804020100804020100804020100804020100804020; // 音色 14 金属
                15: reference_timbre_label=288'h4120d0885100c46a20cc667359bd168d40a1100804020100804020100804020100804020; // 音色 15 明亮合成
                default:reference_timbre_label=288'h100804020100804020100804020100804020100804020100804020100804020100804020;
            endcase
        end
    endfunction
    function [287:0] reference_flag_label;
        input integer index;
        begin
            case(index)
                0: reference_flag_label=288'h6934d94cb100804020100804020100804020100804020100804020100804020100804020; // 削波
                1: reference_flag_label=288'h6a35584c3100804020100804020100804020100804020100804020100804020100804020; // 鬼键
                2: reference_flag_label=288'h209108620100804020100804020100804020100804020100804020100804020100804020; // ADC
                3: reference_flag_label=288'h6b35db0d9100804020100804020100804020100804020100804020100804020100804020; // 过期
                4: reference_flag_label=288'h6d36db8dd100804020100804020100804020100804020100804020100804020100804020; // 故障
                5: reference_flag_label=288'h6f37d94cb100804020100804020100804020100804020100804020100804020100804020; // 滤波
                6: reference_flag_label=288'h70385c4e3100804020100804020100804020100804020100804020100804020100804020; // 远控
                7: reference_flag_label=288'h723950483100804020100804020100804020100804020100804020100804020100804020; // 静音
                default:reference_flag_label=288'h100804020100804020100804020100804020100804020100804020100804020100804020;
            endcase
        end
    endfunction

    reg clk=0,rst_n=0;always #18.518519 clk=~clk;
    // Accelerated sample source, real scope RAM/capture/CDC still exercised.
    reg tick=0;reg [3:0] sample_count=0;reg [15:0] pcm=0;
    always @(posedge clk)begin
        if(!rst_n)begin tick<=0;sample_count<=0;pcm<=0;end
        else begin tick<=sample_count==6;sample_count<=sample_count==7?0:sample_count+1'b1;
            if(sample_count==6)pcm<=pcm+16'd1300;end
    end
    reg [11:0] keys=12'h020;reg [3:0] timbre=7;reg [6:0] note=69;reg nv=1;
    reg [15:0] frequency=16'h0440;reg [7:0] vol=80,pk=45;
    reg signed [7:0] level=-12;reg signed [8:0] pitch=-10;
    reg [5:0] voices=4,step=2,total=42;reg [7:0] p0=25,p1=150,flags=8'h24,progress=60;
    reg active=1,done=0,clip=0;reg [11:0] cue=1,next=16,wrong=32;reg [1:0] beats=1;
    wire cp,cn,locked,fs;wire [2:0] dp,dn;
    hdmi_live_display dut(clk,rst_n,tick,pcm,16'd15000,keys,timbre,note,nv,frequency,
        vol,level,pk,pitch,voices,p0,p1,flags,active,done,cue,next,wrong,step,total,
        progress,beats,clip,cp,cn,dp,dn,locked,fs,1'b0,6'd0,32'd0,32'd0,1'b0,5'd0,1'b0);
    GSR GSR(.GSRI(1'b1));
    reg [241:0] expected,previous;
    reg drive=0,monitor=0;
    reg [9:0] input_x=0,input_y=0;
    reg input_de=0,input_hs=1,input_vs=1;
    reg [9:0] ref_x=0,ref_y=0;
    reg [9:0] coords_x [0:2],coords_y [0:2];
    reg de_ref [0:2],hs_ref [0:2],vs_ref [0:2];
    reg [23:0] rgb_ref [0:2];
    reg raw_de,raw_hs,raw_vs;
    integer s,checks=0,de_edges=0,hs_edges=0,vs_edges=0,reset_checks=0,n,px,py;
    reg previous_de=0,previous_hs=1,previous_vs=1;
    function [23:0] wrapper_reference;
        input integer px,py,visible;
        begin
            // Selected rectangles have no waveform or status dependency.
            wrapper_reference=BG;
            if(px>=32 && px<288 && py>=16 && py<32 && reference_lit(ZH_TITLE,px-32,py-16))
                wrapper_reference=CYAN;
            if(!visible || px>=640 || py>=480)wrapper_reference=0;
        end
    endfunction
    // Independent input coordinates and 3-stage queues. No expected value is
    // obtained from draw_*, font_*, renderer RGB, rgb_pipe or other DUT stages.
    always @(posedge dut.pixel_clk or negedge dut.video_rst_n)begin
        if(!dut.video_rst_n)begin
            ref_x=0;ref_y=0;
            for(s=0;s<3;s=s+1)begin
                coords_x[s]=0;coords_y[s]=0;de_ref[s]=0;hs_ref[s]=1;vs_ref[s]=1;rgb_ref[s]=0;
            end
            #1;
            if(dut.rgb_pipe!==0 || dut.de_pipe!==0 || dut.hs_pipe!==1 || dut.vs_pipe!==1 ||
               dut.font_de!==0 || dut.font_hs!==1 || dut.font_vs!==1 ||
               dut.draw_x!==0 || dut.draw_y!==0 || dut.draw_de!==0 ||
               {dut.r,dut.g,dut.b}!==0)$fatal(1,"Wrapper reset left a pending token");
            reset_checks=reset_checks+1;
        end else if(monitor)begin
            for(s=2;s>0;s=s-1)begin
                coords_x[s]=coords_x[s-1];coords_y[s]=coords_y[s-1];
                de_ref[s]=de_ref[s-1];hs_ref[s]=hs_ref[s-1];vs_ref[s]=vs_ref[s-1];
                rgb_ref[s]=rgb_ref[s-1];
            end
            if(drive)begin
                coords_x[0]=input_x;coords_y[0]=input_y;
                raw_de=input_de;raw_hs=input_hs;raw_vs=input_vs;
            end else begin
                if(dut.x!==ref_x || dut.y!==ref_y)$fatal(1,"Raw timing counter disagrees with independent raster");
                coords_x[0]=ref_x;coords_y[0]=ref_y;
                raw_de=ref_x<640 && ref_y<480;
                raw_hs=!(ref_x>=656 && ref_x<752);raw_vs=!(ref_y>=490 && ref_y<492);
                if(dut.de!==raw_de || dut.hsync!==raw_hs || dut.vsync!==raw_vs)
                    $fatal(1,"Raw timing sync disagrees with raster");
                if(ref_x==799)begin ref_x=0;ref_y=ref_y==524?0:ref_y+1'b1;end
                else ref_x=ref_x+1'b1;
            end
            de_ref[0]=raw_de;hs_ref[0]=raw_hs;vs_ref[0]=raw_vs;
            rgb_ref[0]=wrapper_reference(coords_x[0],coords_y[0],raw_de);
            if(raw_de!=previous_de)de_edges=de_edges+1;
            if(raw_hs!=previous_hs)hs_edges=hs_edges+1;
            if(raw_vs!=previous_vs)vs_edges=vs_edges+1;
            previous_de=raw_de;previous_hs=raw_hs;previous_vs=raw_vs;
            #1;checks=checks+1;
            if(dut.draw_x!==coords_x[0] || dut.draw_y!==coords_y[0] || dut.draw_de!==de_ref[0] ||
               dut.draw_hs!==hs_ref[0] || dut.draw_vs!==vs_ref[0])$fatal(1,"Draw stage != raw coordinate token");
            if(dut.font_de!==de_ref[1] || dut.font_hs!==hs_ref[1] || dut.font_vs!==vs_ref[1])
                $fatal(1,"Font sync != independent stage 2");
            if(dut.de_pipe!==de_ref[2] || dut.hs_pipe!==hs_ref[2] || dut.vs_pipe!==vs_ref[2])
                $fatal(1,"Output sync != independent stage 3");
            if(dut.rgb_pipe!==rgb_ref[2])$fatal(1,"Output RGB != 3-stage oracle at %0d/%0d expected=%h got=%h",
                coords_x[2],coords_y[2],rgb_ref[2],dut.rgb_pipe);
            if((^{cp,cn,dp,dn})===1'bx || cn!==!cp || dn!==~dp)$fatal(1,"Differential TMDS invalid");
        end
    end
    task snapshot;
        begin expected={keys,timbre,note,nv,frequency,vol,level,pk,pitch,voices,p0,p1,
            flags,active,done,cue,next,wrong,step,total,progress,beats,clip,78'd0};end
    endtask
    task commit;
        begin
            @(negedge dut.pixel_clk);force dut.frame_tick=1;
            @(posedge dut.pixel_clk);#2;force dut.frame_tick=0;
            repeat(24)@(posedge dut.pixel_clk);#2;
        end
    endtask
    task scope_commit;
        begin
            commit;
            // Wait for real sample-bank acknowledgement; not a fabricated valid.
            wait(dut.u_scope.request==dut.u_scope.ack_sync);
            repeat(4)@(posedge dut.pixel_clk);commit;
            if(!dut.scope_valid)$fatal(1,"Real PCM scope never committed");
        end
    endtask
    task token;
        input integer tx,ty,td,th,tv;
        begin
            @(negedge dut.pixel_clk);input_x=tx;input_y=ty;input_de=td;input_hs=th;input_vs=tv;
            @(posedge dut.pixel_clk);#2;
        end
    endtask
    initial begin
        force dut.frame_tick=0;
        #200;rst_n=1;wait(locked);wait(dut.video_rst_n);
        // Natural raster for 3 lines: covers DE/HS transitions without forced timing.
        monitor=1;repeat(2400)@(negedge dut.pixel_clk);monitor=0;
        snapshot;commit;commit;
        if(dut.display_status!==expected)$fatal(1,"242-bit live status packing/CDC failed");
        scope_commit;previous=dut.display_status;
        // Explicit raw-token sequence covers font rows/halves, end of line/frame,
        // sync changes and arbitrary DE blanks independently from renderer stages.
        @(negedge dut.pixel_clk);drive=1;
        force dut.x=input_x;force dut.y=input_y;force dut.de=input_de;
        force dut.hsync=input_hs;force dut.vsync=input_vs;
        // Prime queues from three blank tokens; no stale natural-raster expectations.
        for(s=0;s<3;s=s+1)begin
            coords_x[s]=0;coords_y[s]=0;de_ref[s]=0;hs_ref[s]=1;vs_ref[s]=1;rgb_ref[s]=0;
        end
        repeat(4)@(negedge dut.pixel_clk);monitor=1;
        for(py=16;py<33;py=py+1)for(px=24;px<296;px=px+1)token(px,py,1,1,1);
        for(n=0;n<128;n=n+1)begin
            token(639,31,1,1,1);token(640,31,0,1,1);token(656,31,0,0,1);
            token(751,31,0,0,1);token(752,31,0,1,1);token(799,31,0,1,1);
            token(0,32,1,1,1);token(0,490,0,1,0);token(0,492,0,1,1);
            token(32+n%80,16+n%16,n%2,n%3!=0,n%5!=0);
        end
        token(32,16,1,1,1);token(40,24,1,0,0);token(47,31,0,1,1);
        keys=12'h801;timbre=15;note=60;frequency=16'h0262;vol=30;level=-30;
        cue=16;next=8;wrong=1;step=6;beats=2;clip=1;flags=2;
        for(n=0;n<1000;n=n+1)begin
            token(32+n%80,16+n%16,n%2,1,1);
            if(dut.display_status!==previous)$fatal(1,"Status tears within frame");
        end
        snapshot;commit;commit;
        if(dut.display_status!==expected || !dut.alert_flags[7])$fatal(1,"New live snapshot/clipping failed");
        // Reset while all three stages contain mixed visible/blank sync tokens.
        token(32,16,1,0,0);token(40,24,0,1,0);
        rst_n=0;#100;rst_n=1;wait(locked);wait(dut.video_rst_n);
        token(47,31,1,1,1);token(48,32,0,0,0);token(0,480,1,1,1);
        snapshot;commit;commit;scope_commit;
        if(dut.display_status!==expected)$fatal(1,"Reset/relock lost coherent live status");
        repeat(4)token(0,0,0,1,1);
        if(de_edges<100 || hs_edges<100 || vs_edges<100 || reset_checks<2)
            $fatal(1,"Incomplete sync/reset coverage");
        monitor=0;release dut.x;release dut.y;release dut.de;release dut.hsync;release dut.vsync;
        release dut.frame_tick;
        $display("HDMI_LIVE_DISPLAY_TEST_PASS checks=%0d DE=%0d HS=%0d VS=%0d resets=%0d",
            checks,de_edges,hs_edges,vs_edges,reset_checks);$finish;
    end
    initial begin #20000000;$fatal(1,"HDMI wrapper timeout");end
endmodule
