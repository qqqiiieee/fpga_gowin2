`timescale 1ns/1ps
// 独立像素预期来自assets/menu_layout.json的最终文本/颜色与独立字体读取。
// 不调用DUT字符函数、不读取DUT内部ROM；连续送像素，逐拍检查两级延迟。
module tb_compact_dashboard;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [9:0] x=0,y=0;reg de=0;
    reg [1:0] ui_page,ui_cursor,ui_song,control_page,fx_mode;
    reg strum_mode;reg [31:0] knob_values;
    reg [11:0] keys;reg [3:0] ui_controls,timbre;reg [6:0] note;reg note_valid;
    reg [15:0] frequency_bcd;reg [7:0] volume_percent,peak_percent,flags;
    reg signed [7:0] level_dbfs;reg [5:0] voices,guide_step,guide_total;
    reg [11:0] cue_mask,next_mask,wrong_mask;
    reg signed [15:0] wave_current,wave_previous;
    reg [3:0] scope_gain;reg wave_valid,test_active;
    reg [5:0] test_requested;reg [31:0] test_busy,test_gate;
    reg test_sweep,test_overrun;reg [4:0] test_index;
    wire [7:0] red,green,blue;
    hdmi_compact_dashboard dut(
        .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de),.keys(keys),.timbre(timbre),
        .note(note),.note_valid(note_valid),.frequency_bcd(frequency_bcd),
        .volume_percent(volume_percent),.level_dbfs(level_dbfs),.peak_percent(peak_percent),
        .voices(voices),.flags(flags),.cue_mask(cue_mask),.next_mask(next_mask),.wrong_mask(wrong_mask),
        .guide_step(guide_step),.guide_total(guide_total),.wave_current(wave_current),.wave_previous(wave_previous),
        .scope_gain(scope_gain),.wave_valid(wave_valid),.test_active(test_active),.test_requested(test_requested),
        .test_busy(test_busy),.test_gate(test_gate),.test_sweep(test_sweep),.test_index(test_index),.test_overrun(test_overrun),
        .ui_page(ui_page),.ui_cursor(ui_cursor),.ui_song(ui_song),.ui_controls(ui_controls),
        .control_page(control_page),.fx_mode(fx_mode),.strum_mode(strum_mode),.knob_values(knob_values),
        .red(red),.green(green),.blue(blue));
    integer scene=0,fd,count,read_count,checks=0,have_previous=0;
    reg [46:0] vector;
    reg [23:0] previous_expected;
    reg [9:0] previous_x,previous_y;
    string filename;
    task token;
        input [46:0] v;
        begin
            @(negedge clk);x=v[46:37];y=v[36:27];de=v[26];
            @(posedge clk);#2;
            if(have_previous)begin
                checks=checks+1;
                if({red,green,blue}!==previous_expected)
                    $fatal(1,"scene%0d pixel(%0d,%0d) expected=%06h actual=%06h",scene,previous_x,previous_y,previous_expected,{red,green,blue});
            end
            previous_expected=v[23:0];previous_x=v[46:37];previous_y=v[36:27];have_previous=1;
        end
    endtask
    initial begin
        if(!$value$plusargs("SCENE=%d",scene))scene=0;
        filename=$sformatf("scene_%0d.cfg",scene);fd=$fopen(filename,"r");
        if(fd==0)$fatal(1,"Missing scene config");
        read_count=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
            ui_page,ui_cursor,ui_song,control_page,fx_mode,strum_mode,knob_values,
            keys,ui_controls,timbre,note,note_valid,frequency_bcd,volume_percent,level_dbfs,peak_percent,
            voices,flags,cue_mask,next_mask,wrong_mask,guide_step,guide_total,wave_current,wave_previous,
            scope_gain,wave_valid,test_active,test_requested,test_busy,test_gate,test_sweep,test_index,test_overrun);
        $fclose(fd);if(read_count!=34)$fatal(1,"Malformed scene config");
        repeat(3)@(posedge clk);@(negedge clk);rst_n=1;
        filename=$sformatf("scene_%0d.vec",scene);fd=$fopen(filename,"r");
        if(fd==0)$fatal(1,"Missing independent oracle");
        count=0;
        while(!$feof(fd))begin
            read_count=$fscanf(fd,"%h\n",vector);
            if(read_count==1)begin
                token(vector);count=count+1;
                if(count==13579)begin
                    rst_n=0;#1;
                    if({red,green,blue}!==0)$fatal(1,"Reset retained visible pixels");
                    @(negedge clk);rst_n=1;have_previous=0;
                end
            end else if(!$feof(fd))$fatal(1,"Malformed oracle vector");
        end
        $fclose(fd);token(0);token(0);
        if(count<300000)$fatal(1,"Incomplete full-frame coverage");
        $display("COMPACT_DASHBOARD_TEST_PASS scene=%0d pixels=%0d reset latency window font colors",scene,checks);$finish;
    end
    initial begin #20000000;$fatal(1,"Compact renderer timeout");end
endmodule

// 显示封装集成：只替换PLL/TMDS物理边界，使用真实CDC、光栅和波形RAM。
// 行走位/异步更改检查289位整包；逐像素检查RGB与DE/HS/VS共同延迟四拍。
module tb_compact_display_link;
    reg clk27=0,rst_n=0;always #11 clk27=~clk27;
    reg [288:0] stimulus=0;
    reg frame=0;
    hdmi_live_display #(.COMPACT_UI(1)) dut(
        .clk27(clk27),.rst_n(rst_n),.sample_tick(1'b0),.pcm(16'd0),.peak(16'd0),
        .keys(stimulus[241:230]),.timbre(stimulus[229:226]),.note(stimulus[225:219]),
        .note_valid(stimulus[218]),.frequency_bcd(stimulus[217:202]),
        .volume_percent(stimulus[201:194]),.level_dbfs(stimulus[193:186]),
        .peak_percent(stimulus[185:178]),.pitch(stimulus[177:169]),.voices(stimulus[168:163]),
        .pressure0(stimulus[162:155]),.pressure1(stimulus[154:147]),.flags(stimulus[146:139]),
        .guide_active(stimulus[138]),.guide_done(stimulus[137]),.cue_mask(stimulus[136:125]),
        .next_mask(stimulus[124:113]),.wrong_mask(stimulus[112:101]),
        .guide_step(stimulus[100:95]),.guide_total(stimulus[94:89]),
        .beat_progress(stimulus[88:81]),.target_beats(stimulus[80:79]),.clip(stimulus[78]),
        .test_active(stimulus[77]),.test_requested(stimulus[76:71]),
        .test_busy(stimulus[70:39]),.test_gate(stimulus[38:7]),.test_sweep(stimulus[6]),
        .test_index(stimulus[5:1]),.test_overrun(stimulus[0]),
        .ui_page(stimulus[251:250]),.ui_cursor(stimulus[249:248]),.ui_song(stimulus[247:246]),.ui_controls(stimulus[245:242]),
        .control_page(stimulus[288:287]),.fx_mode(stimulus[286:285]),.strum_mode(stimulus[284]),.knob_values(stimulus[283:252]));
    reg [288:0] history[0:4095];integer history_count=1;
    initial history[0]=0;
    always @(posedge clk27)begin
        if(stimulus!==history[history_count-1])begin history[history_count]=stimulus;history_count=history_count+1;end
    end
    reg [288:0] previous=0;
    reg sampled_frame;
    integer frames=0,h,found,cdc_checks=0;
    always @(posedge dut.pixel_clk)begin
        sampled_frame=frame;#1;
        if(dut.video_rst_n)begin
            cdc_checks=cdc_checks+1;
            if(dut.source_status!==stimulus)$fatal(1,"289-bit source packing");
            if(!sampled_frame && dut.display_status!==previous)$fatal(1,"Torn compact frame");
            if({dut.d_control_page,dut.d_fx_mode,dut.d_strum_mode,dut.d_knob_values}!==dut.display_status[288:252])
                $fatal(1,"Compact metadata decode");
            if({dut.compact_ui.u_dashboard.control_page,dut.compact_ui.u_dashboard.fx_mode,
                dut.compact_ui.u_dashboard.strum_mode,dut.compact_ui.u_dashboard.knob_values}!==dut.display_status[288:252])
                $fatal(1,"Compact renderer CDC ports");
            if(sampled_frame)begin
                frames=frames+1;found=0;
                for(h=0;h<history_count;h=h+1)if(dut.display_status===history[h])found=1;
                if(!found)$fatal(1,"Compact word never existed at source");
            end
        end else if(dut.display_status!==0)$fatal(1,"Reset retains packet");
        previous=dut.display_status;
    end
    task settle;begin repeat(20)@(posedge dut.pixel_clk);#2;end endtask
    task commit;
        begin @(negedge dut.pixel_clk);frame=1;@(negedge dut.pixel_clk);frame=0;settle;end
    endtask
    task verify;
        begin commit;commit;if(dut.display_status!==stimulus)$fatal(1,"Compact coherent snapshot failed");end
    endtask
    task reset_link;
        begin
            @(negedge clk27);rst_n=0;frame=0;#3;
            if(dut.display_status!==0 || dut.de_pipe!==0 || dut.rgb_pipe!==0)$fatal(1,"Wrapper reset");
            #70;@(negedge clk27);rst_n=1;wait(dut.video_rst_n);settle;
        end
    endtask
    reg [9:0] input_x=0,input_y=0;
    reg input_de=0,input_hs=1,input_vs=1;
    reg [26:0] expected0=0,expected1=0,expected2=0;
    integer tokens=0,pixel_checks=0;
    reg [46:0] vector;
    task token;
        input [46:0] v;
        begin
            @(negedge dut.pixel_clk);input_x=v[46:37];input_y=v[36:27];input_de=v[26];input_hs=v[25];input_vs=v[24];
            @(posedge dut.pixel_clk);#2;
            if(tokens>=3)begin
                pixel_checks=pixel_checks+1;
                if({dut.de_pipe,dut.hs_pipe,dut.vs_pipe,dut.rgb_pipe}!==expected2)
                    $fatal(1,"Four-cycle RGB/sync misaligned token%0d got=%07h expected=%07h",tokens,{dut.de_pipe,dut.hs_pipe,dut.vs_pipe,dut.rgb_pipe},expected2);
            end
            expected2=expected1;expected1=expected0;expected0=v[26:0];tokens=tokens+1;
        end
    endtask
    integer i,k,fd,read_count;
    reg [288:0] fixed_word[0:0];
    reg [31:0] prng=32'h6dc2913f;
    initial begin
        force dut.frame_tick=frame;
        if(dut.STATUS_WIDTH!=289)$fatal(1,"COMPACT must imply UI metadata");
        reset_link;verify;
        for(i=0;i<289;i=i+1)begin
            @(negedge clk27);stimulus=289'd1<<i;verify;
            @(negedge clk27);stimulus=~(289'd1<<i);verify;
        end
        fork
            begin
                for(k=0;k<500;k=k+1)begin
                    @(negedge clk27);
                    prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
                    stimulus={stimulus[256:0],prng};
                end
            end
            begin repeat(32)commit;end
        join
        verify;
        $readmemh("link_status.hex",fixed_word);
        @(negedge clk27);stimulus=fixed_word[0];verify;
        force dut.x=input_x;force dut.y=input_y;force dut.de=input_de;
        force dut.hsync=input_hs;force dut.vsync=input_vs;
        fd=$fopen("link.vec","r");if(fd==0)$fatal(1,"Missing link oracle");
        while(!$feof(fd))begin
            read_count=$fscanf(fd,"%h\n",vector);
            if(read_count==1)token(vector);else if(!$feof(fd))$fatal(1,"Malformed link oracle");
        end
        $fclose(fd);repeat(4)token(0);
        if(pixel_checks<30000)$fatal(1,"Link oracle coverage");
        // PLL loss discards both new fields and in-flight raster validity.
        force dut.pll_locked=1'b0;#2;
        if(dut.display_status!==0 || dut.rgb_pipe!==0 || dut.de_pipe!==0)$fatal(1,"Lock loss state");
        #40;release dut.pll_locked;wait(dut.video_rst_n);settle;verify;
        tokens=0;repeat(5)token(0);
        release dut.x;release dut.y;release dut.de;release dut.hsync;release dut.vsync;release dut.frame_tick;
        $display("COMPACT_DISPLAY_LINK_TEST_PASS width=289 walking_bits=289x2 async_packets=500 frames=%0d cdc=%0d pixels=%0d latency=4",frames,cdc_checks,pixel_checks);$finish;
    end
    initial begin #20000000;$fatal(1,"Compact link timeout");end
endmodule

// 仅用于测试的时钟/发送器边界模型，不代表硬件PLL或TMDS物理验证。
module hdmi_clocks(input clk27,input rst_n,output serial_clk,output reg pixel_clk=0,output reg locked=0);
    always #7 pixel_clk=~pixel_clk;
    assign serial_clk=clk27;
    reg [2:0] lock_count=0;
    always @(posedge clk27 or negedge rst_n)begin
        if(!rst_n)begin locked<=0;lock_count<=0;end
        else if(lock_count==3)locked<=1;
        else lock_count<=lock_count+1'b1;
    end
endmodule
module hdmi_tx(input pixel_clk,input serial_clk,input rst_n,input [7:0] red,green,blue,
    input de,hsync,vsync,output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n);
    // 时钟通道的可见频率是像素时钟；这里仅做互补端口占位，避免让旧bench
    // 在异步serial/source边沿采样到连续赋值的delta-cycle竞争，不模拟串行器。
    assign tmds_clk_p=pixel_clk;assign tmds_clk_n=~pixel_clk;
    assign tmds_data_p=0;assign tmds_data_n=3'b111;
endmodule
// 历史封装bench声明厂商GSR，但本文件的PLL/TMDS行为模型不使用全局复位原语。
// 仅满足该bench的无输出占位实例；实际复位仍由rst_n和真实wrapper逐项验证。
module GSR(input GSRI);
endmodule
