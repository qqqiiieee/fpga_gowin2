`timescale 1ns/1ps
module tb_piano_roll_cdc;
    reg clk27=0,rst_n=0;always #11 clk27=~clk27;
    reg [337:0] stimulus=0;reg frame=0;
`define ROLL_SOURCE_PORTS \
    .clk27(clk27),.rst_n(rst_n),.sample_tick(1'b0),.pcm(16'd0),.peak(16'd0), \
    .keys(stimulus[241:230]),.timbre(stimulus[229:226]),.note(stimulus[225:219]), \
    .note_valid(stimulus[218]),.frequency_bcd(stimulus[217:202]), \
    .volume_percent(stimulus[201:194]),.level_dbfs(stimulus[193:186]), \
    .peak_percent(stimulus[185:178]),.pitch(stimulus[177:169]),.voices(stimulus[168:163]), \
    .pressure0(stimulus[162:155]),.pressure1(stimulus[154:147]),.flags(stimulus[146:139]), \
    .guide_active(stimulus[138]),.guide_done(stimulus[137]),.cue_mask(stimulus[136:125]), \
    .next_mask(stimulus[124:113]),.wrong_mask(stimulus[112:101]), \
    .guide_step(stimulus[100:95]),.guide_total(stimulus[94:89]), \
    .beat_progress(stimulus[88:81]),.target_beats(stimulus[80:79]),.clip(stimulus[78]), \
    .test_active(stimulus[77]),.test_requested(stimulus[76:71]), \
    .test_busy(stimulus[70:39]),.test_gate(stimulus[38:7]), \
    .test_sweep(stimulus[6]),.test_index(stimulus[5:1]),.test_overrun(stimulus[0]), \
    .ui_page(stimulus[251:250]),.ui_cursor(stimulus[249:248]), \
    .ui_song(stimulus[247:246]),.ui_controls(stimulus[245:242]), \
    .control_page(stimulus[288:287]),.fx_mode(stimulus[286:285]), \
    .strum_mode(stimulus[284]),.knob_values(stimulus[283:252]), \
    .piano_keys(stimulus[337:306]),.piano_outside(stimulus[305]), \
    .roll_tick(stimulus[304:293]),.roll_song(stimulus[292:291]), \
    .roll_active(stimulus[290]),.roll_done(stimulus[289])
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1)) dut(`ROLL_SOURCE_PORTS);
    hdmi_live_display #(.COMPACT_UI(1)) compact(`ROLL_SOURCE_PORTS);
    hdmi_live_display #(.UI_ENABLE(1)) menu(`ROLL_SOURCE_PORTS);
    hdmi_live_display legacy(`ROLL_SOURCE_PORTS);
`undef ROLL_SOURCE_PORTS
    reg [337:0] history[0:4095];integer history_count=1;
    initial history[0]=0;
    always @(posedge clk27)begin
        if(stimulus!==history[history_count-1])begin
            if(history_count>=4096)$fatal(1,"History capacity");
            history[history_count]=stimulus;history_count=history_count+1;
        end
    end
    reg [337:0] previous=0;
    reg sampled_frame;integer cdc_checks=0,frames=0,h,found,i,k;
    always @(posedge dut.pixel_clk)begin
        sampled_frame=frame;#1;
        if(dut.video_rst_n && compact.video_rst_n && menu.video_rst_n && legacy.video_rst_n)begin
            cdc_checks=cdc_checks+1;
            if(dut.source_status!==stimulus)$fatal(1,"338-bit source packet offsets");
            if(compact.source_status!==stimulus[288:0] || menu.source_status!==stimulus[251:0] || legacy.source_status!==stimulus[241:0])
                $fatal(1,"Disabled source layouts changed");
            if(!sampled_frame && dut.display_status!==previous)$fatal(1,"Mid-frame packet tear");
            if(compact.display_status!==dut.display_status[288:0] || menu.display_status!==dut.display_status[251:0] || legacy.display_status!==dut.display_status[241:0])
                $fatal(1,"Disabled packet frame/latency changed");
            if({dut.d_piano_keys,dut.d_piano_outside,dut.d_roll_tick,dut.d_roll_song,dut.d_roll_active,dut.d_roll_done}!==dut.display_status[337:289])
                $fatal(1,"Piano metadata decode");
            if({dut.compact_ui.u_dashboard.piano_keys,dut.compact_ui.u_dashboard.piano_outside,
                dut.compact_ui.u_dashboard.roll_tick,dut.compact_ui.u_dashboard.roll_song,
                dut.compact_ui.u_dashboard.roll_active,dut.compact_ui.u_dashboard.roll_done}!==dut.display_status[337:289])
                $fatal(1,"Piano renderer ports tear");
            if(compact.d_piano_keys!==0 || compact.d_roll_active!==0 || menu.d_roll_tick!==0 || legacy.d_piano_outside!==0)
                $fatal(1,"Disabled metadata not constant");
            if(sampled_frame)begin
                found=0;frames=frames+1;
                for(h=0;h<history_count;h=h+1)if(dut.display_status===history[h])found=1;
                if(!found)$fatal(1,"Packet never existed at source");
            end
        end else if(dut.display_status!==0)$fatal(1,"Async reset packet");
        previous=dut.display_status;
    end
    task settle;begin repeat(20)@(posedge dut.pixel_clk);#2;end endtask
    task commit;
        begin @(negedge dut.pixel_clk);frame=1;@(negedge dut.pixel_clk);frame=0;settle;end
    endtask
    task verify;
        begin commit;commit;if(dut.display_status!==stimulus)$fatal(1,"Stable packet not delivered");end
    endtask
    task reset_link;
        begin
            @(negedge clk27);rst_n=0;frame=0;#2;
            if(dut.display_status!==0 || dut.rgb_pipe!==0 || dut.de_pipe!==0)$fatal(1,"Async wrapper reset");
            #70;@(negedge clk27);rst_n=1;wait(dut.video_rst_n);settle;
        end
    endtask
    reg [9:0] input_x=0,input_y=0;reg input_de=0,input_hs=1,input_vs=1;
    reg [26:0] expected0=0,expected1=0,expected2=0;
    integer tokens=0,pixel_checks=0;
    task token;
        input [9:0] xx,yy;input dd,hh,vv;input [23:0] colour;
        begin
            @(negedge dut.pixel_clk);input_x=xx;input_y=yy;input_de=dd;input_hs=hh;input_vs=vv;
            @(posedge dut.pixel_clk);#2;
            if(tokens>=3)begin
                pixel_checks=pixel_checks+1;
                if({dut.de_pipe,dut.hs_pipe,dut.vs_pipe,dut.rgb_pipe}!==expected2)
                    $fatal(1,"RGB/DE/HS/VS four-stage alignment token%0d actual%07h expected%07h",tokens,{dut.de_pipe,dut.hs_pipe,dut.vs_pipe,dut.rgb_pipe},expected2);
            end
            expected2=expected1;expected1=expected0;expected0={dd,hh,vv,colour};tokens=tokens+1;
        end
    endtask
    reg [31:0] prng=32'hfa746301;
    initial begin
        force dut.frame_tick=frame;force compact.frame_tick=frame;
        force menu.frame_tick=frame;force legacy.frame_tick=frame;
        if(dut.STATUS_WIDTH!=338 || compact.STATUS_WIDTH!=289 || menu.STATUS_WIDTH!=252 || legacy.STATUS_WIDTH!=242)
            $fatal(1,"Packet widths");
        reset_link;verify;
        for(i=0;i<338;i=i+1)begin
            @(negedge clk27);stimulus=338'd1<<i;verify;
            @(negedge clk27);stimulus=~(338'd1<<i);verify;
        end
        fork
            begin
                for(k=0;k<800;k=k+1)begin
                    @(negedge clk27);prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
                    stimulus={stimulus[305:0],prng};
                end
            end
            begin repeat(50)commit;end
        join
        verify;
        @(negedge clk27);stimulus=0;
        stimulus[337:306]=32'h00180000;stimulus[305]=1;
        stimulus[304:293]=128;stimulus[290]=1;verify;
        force dut.x=input_x;force dut.y=input_y;force dut.de=input_de;
        force dut.hsync=input_hs;force dut.vsync=input_vs;
        // Isolated key-centre/border/background tokens, toggled every pixel.
        // Repeated alternating values expose even a one-clock DE/RGB error.
        for(i=0;i<1024;i=i+1)begin
            case(i%8)
                0:token(380,375,1,i[3],i[4],24'h21c6a8);
                1:token(395,350,1,i[3],i[4],24'hff5964);
                2:token(50,375,1,i[3],i[4],24'he2e8f0);
                3:token(65,350,1,i[3],i[4],24'h080d16);
                4:token(34,375,1,i[3],i[4],24'hff5964);
                5:token(50,375,0,i[3],i[4],0);
                6:token(640,375,0,i[3],i[4],0);
                7:token(260,480,0,i[3],i[4],0);
            endcase
        end
        repeat(4)token(0,0,0,1,1,0);
        // Reset during an in-flight transaction, then PLL lock loss.
        @(negedge clk27);stimulus={338{1'b1}};commit;reset_link;verify;
        tokens=0;repeat(5)token(0,0,0,1,1,0);
        force dut.pll_locked=0;force compact.pll_locked=0;force menu.pll_locked=0;force legacy.pll_locked=0;#2;
        if(dut.display_status!==0 || dut.rgb_pipe!==0 || dut.de_pipe!==0)$fatal(1,"PLL loss reset");
        #40;release dut.pll_locked;release compact.pll_locked;release menu.pll_locked;release legacy.pll_locked;
        wait(dut.video_rst_n);settle;verify;
        $display("PIANO_ROLL_CDC_PASS widths338/289/252/242 walking338x2 async800 frames=%0d cdc=%0d pixels=%0d pipeline4",frames,cdc_checks,pixel_checks);
        $finish;
    end
    initial begin #30000000;$fatal(1,"CDC timeout");end
endmodule
