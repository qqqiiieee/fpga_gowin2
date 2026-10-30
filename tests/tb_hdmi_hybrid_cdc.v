`timescale 1ns/1ps
// Coherent V034 mode+status snapshots across unrelated source/pixel clocks.
// Old packet slices are compared to feature-disabled wrappers on EVERY edge.
module tb_hdmi_hybrid_cdc;
    reg clk27=0,rst_n=0;always #11 clk27=~clk27;
    reg [337:0] stimulus=0;
    reg [1:0] mode=0;
    reg frame=0;
    wire [337:0] expected_base={stimulus[337:285],(mode!=0),stimulus[283:0]};
    wire [338:0] expected={mode==2'd2,expected_base};
`define HYBRID_PORTS \
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
    .strum_mode(mode),.knob_values(stimulus[283:252]), \
    .piano_keys(stimulus[337:306]),.piano_outside(stimulus[305]), \
    .roll_tick(stimulus[304:293]),.roll_song(stimulus[292:291]), \
    .roll_active(stimulus[290]),.roll_done(stimulus[289])
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.HYBRID_MODE_ENABLE(1)) dut(`HYBRID_PORTS);
    hdmi_live_display #(.COMPACT_UI(1),.HYBRID_MODE_ENABLE(1)) compact(`HYBRID_PORTS);
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1)) old_piano(`HYBRID_PORTS);
    hdmi_live_display #(.COMPACT_UI(1)) old_compact(`HYBRID_PORTS);
    // Enabling the parameter MUST NOT widen a non-compact historical layout.
    hdmi_live_display #(.UI_ENABLE(1),.HYBRID_MODE_ENABLE(1)) menu(`HYBRID_PORTS);
    hdmi_live_display #(.HYBRID_MODE_ENABLE(1)) legacy(`HYBRID_PORTS);
`undef HYBRID_PORTS
    reg [338:0] history[0:4095];integer history_count=1;
    initial history[0]=0;
    always @(posedge clk27)begin
        if(expected!==history[history_count-1])begin
            if(history_count>=4096)$fatal(1,"History capacity");
            history[history_count]=expected;history_count=history_count+1;
        end
    end
    reg [338:0] previous=0;
    reg sampled_frame;
    reg [1:0] expected_mode;
    integer cdc_checks=0,frames=0,h,found,i,k,seen_modes=0;
    always @(posedge dut.pixel_clk)begin
        sampled_frame=frame;#1;
        if(dut.video_rst_n && compact.video_rst_n && old_piano.video_rst_n &&
            old_compact.video_rst_n && menu.video_rst_n && legacy.video_rst_n)begin
            cdc_checks=cdc_checks+1;
            if(dut.source_status!==expected)$fatal(1,"339-bit source layout");
            if(compact.source_status!=={expected[338],expected_base[288:0]})
                $fatal(1,"290-bit compact source layout");
            if(old_piano.source_status!==expected_base || old_compact.source_status!==expected_base[288:0] ||
                menu.source_status!==stimulus[251:0] || legacy.source_status!==stimulus[241:0])
                $fatal(1,"Historical source layouts changed");
            if(!sampled_frame && dut.display_status!==previous)$fatal(1,"Mid-frame hybrid packet tear");
            if(compact.display_status!=={dut.display_status[338],dut.display_status[288:0]} ||
                old_piano.display_status!==dut.display_status[337:0] ||
                old_compact.display_status!==dut.display_status[288:0] ||
                menu.display_status!==dut.display_status[251:0] ||
                legacy.display_status!==dut.display_status[241:0])
                $fatal(1,"Existing field slices or CDC latency changed");
            expected_mode=dut.display_status[338] ? 2'd2 : {1'b0,dut.display_status[284]};
            if(dut.d_strum_mode!==expected_mode || compact.d_strum_mode!==expected_mode ||
                dut.compact_ui.u_dashboard.strum_mode!==expected_mode ||
                compact.compact_ui.u_dashboard.strum_mode!==expected_mode)
                $fatal(1,"Mode reconstruction or dashboard delivery");
            if(old_piano.d_strum_mode!=={1'b0,dut.display_status[284]} ||
                old_compact.d_strum_mode!=={1'b0,dut.display_status[284]} ||
                menu.d_strum_mode!==0 || legacy.d_strum_mode!==0)
                $fatal(1,"Disabled hybrid decode compatibility");
            if({dut.d_piano_keys,dut.d_piano_outside,dut.d_roll_tick,dut.d_roll_song,
                dut.d_roll_active,dut.d_roll_done}!==dut.display_status[337:289])
                $fatal(1,"Piano field slices moved");
            if(dut.display_status[338] && !dut.display_status[284])
                $fatal(1,"HYBRID flag torn from optical-enabled flag");
            if(sampled_frame)begin
                found=0;frames=frames+1;seen_modes=seen_modes|(1<<expected_mode);
                for(h=0;h<history_count;h=h+1)if(dut.display_status===history[h])found=1;
                if(!found)$fatal(1,"Snapshot never existed at source");
            end
        end else if(dut.display_status!==0)$fatal(1,"Async reset packet");
        previous=dut.display_status;
    end
    task settle;begin repeat(20)@(posedge dut.pixel_clk);#2;end endtask
    task commit;
        begin @(negedge dut.pixel_clk);frame=1;@(negedge dut.pixel_clk);frame=0;settle;end
    endtask
    task verify;
        begin
            commit;commit;
            if(dut.display_status!==expected)$fatal(1,"Stable hybrid snapshot not delivered");
        end
    endtask
    task reset_link;
        begin
            @(negedge clk27);rst_n=0;frame=0;#2;
            if(dut.display_status!==0 || dut.d_strum_mode!==0 || dut.de_pipe!==0)
                $fatal(1,"Async wrapper mode reset");
            #70;@(negedge clk27);rst_n=1;wait(dut.video_rst_n);settle;
        end
    endtask
    reg [31:0] prng=32'hf03481ab;
    initial begin
        force dut.frame_tick=frame;force compact.frame_tick=frame;
        force old_piano.frame_tick=frame;force old_compact.frame_tick=frame;
        force menu.frame_tick=frame;force legacy.frame_tick=frame;
        if(dut.STATUS_WIDTH!=339 || compact.STATUS_WIDTH!=290 || old_piano.STATUS_WIDTH!=338 ||
            old_compact.STATUS_WIDTH!=289 || menu.STATUS_WIDTH!=252 || legacy.STATUS_WIDTH!=242)
            $fatal(1,"Hybrid feature packet widths");
        reset_link;verify;
        // Exercise every original status position with changing modes, then its
        // complement. Bit284 is supplied only by the real two-bit mode port.
        for(i=0;i<338;i=i+1)begin
            @(negedge clk27);stimulus=338'd1<<i;mode=i%3;verify;
            @(negedge clk27);stimulus=~(338'd1<<i);mode=(i+1)%3;verify;
        end
        for(i=0;i<3;i=i+1)begin
            @(negedge clk27);mode=i;stimulus=0;verify;
            if(dut.d_strum_mode!==i)$fatal(1,"All three stable modes");
        end
        fork
            begin
                for(k=0;k<800;k=k+1)begin
                    @(negedge clk27);prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
                    stimulus={stimulus[305:0],prng};mode=k%3;
                end
            end
            begin repeat(50)commit;end
        join
        verify;
        // Discard in-flight mode+status on external reset and PLL loss.
        @(negedge clk27);mode=2;stimulus={338{1'b1}};commit;reset_link;verify;
        force dut.pll_locked=0;force compact.pll_locked=0;
        force old_piano.pll_locked=0;force old_compact.pll_locked=0;
        force menu.pll_locked=0;force legacy.pll_locked=0;#2;
        if(dut.display_status!==0 || dut.d_strum_mode!==0 || dut.rgb_pipe!==0)
            $fatal(1,"PLL loss hybrid reset");
        #40;release dut.pll_locked;release compact.pll_locked;
        release old_piano.pll_locked;release old_compact.pll_locked;
        release menu.pll_locked;release legacy.pll_locked;
        wait(dut.video_rst_n);settle;verify;
        if(seen_modes!=7)$fatal(1,"Missing mode frame coverage");
        $display("HDMI_HYBRID_CDC_PASS widths339/290/338/289/252/242 walking338x2 async800 modes3 frames=%0d cdc=%0d",frames,cdc_checks);
        $finish;
    end
    initial begin #30000000;$fatal(1,"Hybrid CDC timeout");end
endmodule
