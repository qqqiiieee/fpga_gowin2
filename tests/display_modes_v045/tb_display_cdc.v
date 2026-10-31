`timescale 1ns/1ps
module tb_display_cdc;
    reg clk27=0,rst_n=0,frame=0;always #11 clk27=~clk27;
    reg [337:0] stimulus=0;
    reg [57:0] expression=0;
    reg [1:0] strum=0,mode=0;
    reg waiting=0;
    reg [31:0] cfg=0;
    reg bank=0;
    wire [337:0] base={stimulus[337:285],(strum!=0),stimulus[283:0]};
    wire [400:0] expected={mode,waiting,bank,expression,(strum==2'd2),base};
    always @(posedge clk27 or negedge dut.source_reset_sync[2])
        if(!dut.source_reset_sync[2])bank<=0;else bank<=cfg[31];
`define PORTS \
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
    .strum_mode(strum),.knob_values(stimulus[283:252]), \
    .piano_keys(stimulus[337:306]),.piano_outside(stimulus[305]), \
    .roll_tick(stimulus[304:293]),.roll_song(stimulus[292:291]), \
    .roll_active(stimulus[290]),.roll_done(stimulus[289]), \
    .expression_adc(expression[57:26]),.expression_calibrated(expression[25:24]), \
    .midi_velocity(expression[23:16]),.midi_bend(expression[15:7]),.midi_modulation(expression[6:0]), \
    .custom_write_clk(clk27),.custom_write_en(1'b0),.custom_write_addr(9'd0), \
    .custom_write_data(32'd0),.custom_config(cfg),.guide_mode(mode),.practice_wait(waiting)
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1),
        .CUSTOM_SCORE_ENABLE(1),.SONG_LIBRARY_ENABLE(1)) dut(`PORTS);
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1),
        .CUSTOM_SCORE_ENABLE(1)) old(`PORTS);
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1),
        .SONG_LIBRARY_ENABLE(1)) no_custom(`PORTS);
    hdmi_live_display #(.COMPACT_UI(1),.SONG_LIBRARY_ENABLE(1)) compact(`PORTS);
    hdmi_live_display #(.SONG_LIBRARY_ENABLE(1)) legacy(`PORTS);
`undef PORTS
    reg [400:0] history[0:8191];integer used=1;
    initial history[0]=0;
    always @(posedge clk27)if(dut.source_reset_sync[2] && expected!==history[used-1])begin
        history[used]=expected;used=used+1;if(used>=8192)$fatal(1,"History full");
    end
    reg [400:0] previous=0;
    reg sampled_frame;integer checks=0,frames=0,found,h,seen=0,i,k;
    always @(posedge dut.pixel_clk)begin
        sampled_frame=frame;#1;
        if(dut.video_rst_n && old.video_rst_n && compact.video_rst_n && legacy.video_rst_n)begin
            checks=checks+1;
            if(dut.source_status!==expected)$fatal(1,"401bit source layout");
            if(old.source_status!==expected[397:0] || no_custom.source_status!=={mode,waiting,expected[396:0]} ||
                compact.source_status!=={mode,waiting,base[288:0]} || legacy.source_status!==stimulus[241:0])
                $fatal(1,"Optional source layout");
            if(!sampled_frame && dut.display_status!==previous)$fatal(1,"Mid-frame status tear");
            if(old.display_status!==dut.display_status[397:0] ||
                no_custom.display_status!=={dut.display_status[400:398],dut.display_status[396:0]} ||
                compact.display_status!=={dut.display_status[400:398],dut.display_status[288:0]} ||
                legacy.display_status!==dut.display_status[241:0])$fatal(1,"Old bits or handshake timing moved");
            if({dut.d_guide_mode,dut.d_practice_wait}!==dut.display_status[400:398] ||
                {dut.compact_ui.u_dashboard.guide_mode,dut.compact_ui.u_dashboard.practice_wait}!==dut.display_status[400:398])
                $fatal(1,"Dashboard bypassed coherent CDC");
            if(dut.d_roll_custom_bank!==dut.display_status[397])$fatal(1,"Bank tag offset moved");
            if(old.d_guide_mode!==0 || old.d_practice_wait!==0 || legacy.d_guide_mode!==0 || legacy.d_practice_wait!==0)
                $fatal(1,"Disabled inputs leaked");
            if(sampled_frame)begin
                frames=frames+1;seen=seen|(1<<dut.d_guide_mode);found=0;
                for(h=0;h<used;h=h+1)if(history[h]===dut.display_status)found=1;
                if(!found)$fatal(1,"Displayed packet never existed at source");
            end
        end else if(dut.display_status!==0)$fatal(1,"Async reset failed");
        previous=dut.display_status;
    end
    task settle;begin repeat(25)@(negedge dut.pixel_clk);end endtask
    task commit;begin @(negedge dut.pixel_clk);frame=1;@(negedge dut.pixel_clk);frame=0;settle;end endtask
    task verify;begin commit;commit;if(dut.display_status!==expected)$fatal(1,"Stable packet not delivered");end endtask
    task reset_link;begin
        @(negedge clk27);rst_n=0;frame=0;#2;
        if(dut.display_status!==0 || dut.rgb_pipe!==0 || dut.de_pipe!==0)$fatal(1,"Reset pipeline");
        #70;@(negedge clk27);rst_n=1;wait(dut.video_rst_n);settle;
    end endtask
    reg [31:0] prng=32'h4500ab19;
    initial begin
        force dut.frame_tick=frame;force old.frame_tick=frame;force no_custom.frame_tick=frame;
        force compact.frame_tick=frame;force legacy.frame_tick=frame;
        if(dut.STATUS_WIDTH!=401 || old.STATUS_WIDTH!=398 || no_custom.STATUS_WIDTH!=400 ||
            compact.STATUS_WIDTH!=292 || legacy.STATUS_WIDTH!=242)$fatal(1,"Widths");
        if(dut.compact_ui.u_dashboard.piano_panel.u_piano.SONG_LIBRARY_ENABLE!=1 ||
            old.compact_ui.u_dashboard.piano_panel.u_piano.SONG_LIBRARY_ENABLE!=0)$fatal(1,"Renderer parameter");
        reset_link;verify;
        for(i=0;i<400;i=i+1)begin
            @(negedge clk27);{mode,waiting,cfg[31],expression,stimulus}=400'd1<<i;strum=i%3;verify;
            @(negedge clk27);{mode,waiting,cfg[31],expression,stimulus}=~(400'd1<<i);strum=(i+1)%3;verify;
        end
        fork
            begin for(k=0;k<1000;k=k+1)begin
                @(negedge clk27);prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
                stimulus={stimulus[305:0],prng};expression={expression[25:0],prng};
                mode=k%3;waiting=k%2;strum=(k+1)%3;cfg[31]=prng[5];
            end end
            begin repeat(80)commit;end
        join
        verify;
        for(i=0;i<3;i=i+1)begin @(negedge clk27);mode=i;waiting=1;verify;end
        reset_link;verify;
        if((seen&7)!=7)$fatal(1,"Mode coverage");
        $display("V045_CDC_PASS widths=401/398/400/292/242 walk400x2 async1000 frames=%0d checks=%0d",frames,checks);
        $finish;
    end
    initial begin #30000000;$fatal(1,"CDC timeout");end
endmodule
