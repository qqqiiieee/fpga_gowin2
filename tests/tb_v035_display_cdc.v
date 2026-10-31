`timescale 1ns/1ps
// Real wrapper + real bundled CDC. Only PLL/TMDS are simulation boundaries.
module tb_v035_display_cdc;
    reg clk27=0,rst_n=0;always #11 clk27=~clk27;
    reg [337:0] stimulus=0;
    reg [57:0] expression=0;
    reg [1:0] mode=0;
    reg frame=0;
    wire [337:0] base={stimulus[337:285],(mode!=0),stimulus[283:0]};
    wire [338:0] hybrid={mode==2'd2,base};
    wire [396:0] expected={expression,hybrid};
`define V035_PORTS \
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
    .roll_active(stimulus[290]),.roll_done(stimulus[289]), \
    .expression_adc(expression[57:26]),.expression_calibrated(expression[25:24]), \
    .midi_velocity(expression[23:16]),.midi_bend(expression[15:7]),.midi_modulation(expression[6:0])
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1)) dut(`V035_PORTS);
    hdmi_live_display #(.COMPACT_UI(1),.HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1)) compact_new(`V035_PORTS);
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.EXPRESSION_UI_ENABLE(1)) piano_new(`V035_PORTS);
    hdmi_live_display #(.COMPACT_UI(1),.EXPRESSION_UI_ENABLE(1)) compact_plain(`V035_PORTS);
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.HYBRID_MODE_ENABLE(1)) old_hybrid(`V035_PORTS);
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1)) old_piano(`V035_PORTS);
    hdmi_live_display #(.COMPACT_UI(1),.HYBRID_MODE_ENABLE(1)) old_compact_hybrid(`V035_PORTS);
    hdmi_live_display #(.COMPACT_UI(1)) old_compact(`V035_PORTS);
    // Expression must NOT widen a legacy renderer even if both new flags are1.
    hdmi_live_display #(.UI_ENABLE(1),.HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1)) menu(`V035_PORTS);
    hdmi_live_display #(.HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1)) legacy(`V035_PORTS);
`undef V035_PORTS
    reg [396:0] history[0:4095];integer history_count=1;
    initial history[0]=0;
    always @(posedge clk27)begin
        if(expected!==history[history_count-1])begin
            if(history_count>=4096)$fatal(1,"History capacity");
            history[history_count]=expected;history_count=history_count+1;
        end
    end
    reg [396:0] previous=0;
    reg sampled_frame;integer cdc_checks=0,frames=0,h,found,i,k,seen_modes=0;
    reg [1:0] expected_mode;
    always @(posedge dut.pixel_clk)begin
        sampled_frame=frame;#1;
        if(dut.video_rst_n && compact_new.video_rst_n && menu.video_rst_n && legacy.video_rst_n)begin
            cdc_checks=cdc_checks+1;
            if(dut.source_status!==expected)$fatal(1,"397-bit source layout");
            if(compact_new.source_status!=={expression,hybrid[338],base[288:0]} ||
               piano_new.source_status!=={expression,base} ||
               compact_plain.source_status!=={expression,base[288:0]})$fatal(1,"Optional feature packet layouts");
            if(old_hybrid.source_status!==hybrid || old_piano.source_status!==base ||
               old_compact_hybrid.source_status!=={hybrid[338],base[288:0]} ||
               old_compact.source_status!==base[288:0] || menu.source_status!==stimulus[251:0] ||
               legacy.source_status!==stimulus[241:0])$fatal(1,"Historical source field slices");
            if(!sampled_frame && dut.display_status!==previous)$fatal(1,"Mid-frame397-bit tear");
            if(old_hybrid.display_status!==dut.display_status[338:0] ||
               old_piano.display_status!==dut.display_status[337:0] ||
               old_compact_hybrid.display_status!=={dut.display_status[338],dut.display_status[288:0]} ||
               old_compact.display_status!==dut.display_status[288:0] ||
               menu.display_status!==dut.display_status[251:0] || legacy.display_status!==dut.display_status[241:0])
                $fatal(1,"Old layouts/CDC latency moved");
            if(compact_new.display_status!=={dut.display_status[396:338],dut.display_status[288:0]} ||
               piano_new.display_status!=={dut.display_status[396:339],dut.display_status[337:0]} ||
               compact_plain.display_status!=={dut.display_status[396:339],dut.display_status[288:0]})
                $fatal(1,"Feature combinations incoherent");
            if({dut.d_expression_adc,dut.d_expression_calibrated,dut.d_midi_velocity,
                dut.d_midi_bend,dut.d_midi_modulation}!==dut.display_status[396:339])
                $fatal(1,"Expression decode offsets");
            if({dut.compact_ui.u_dashboard.expression_adc,dut.compact_ui.u_dashboard.expression_calibrated,
                dut.compact_ui.u_dashboard.midi_velocity,dut.compact_ui.u_dashboard.midi_bend,
                dut.compact_ui.u_dashboard.midi_modulation}!==dut.display_status[396:339])
                $fatal(1,"Renderer expression ports");
            if({dut.compact_ui.u_dashboard.pressure0,dut.compact_ui.u_dashboard.pressure1}!==dut.display_status[162:147])
                $fatal(1,"Independent legacy FSR levels moved");
            expected_mode=dut.display_status[338] ? 2'd2 : {1'b0,dut.display_status[284]};
            if(dut.d_strum_mode!==expected_mode || compact_new.d_strum_mode!==expected_mode)
                $fatal(1,"Hybrid flag read from expression MSB instead of old top bit");
            if(old_hybrid.d_expression_adc!==0 || old_hybrid.d_expression_calibrated!==0 ||
               old_hybrid.d_midi_velocity!==0 || old_hybrid.d_midi_bend!==0 || old_hybrid.d_midi_modulation!==0)
                $fatal(1,"Disabled expression feature not zero");
            if(sampled_frame)begin
                found=0;frames=frames+1;seen_modes=seen_modes|(1<<expected_mode);
                for(h=0;h<history_count;h=h+1)if(dut.display_status===history[h])found=1;
                if(!found)$fatal(1,"397-bit snapshot never existed at source");
            end
        end else if(dut.display_status!==0)$fatal(1,"Async reset packet");
        previous=dut.display_status;
    end
    task settle;begin repeat(20)@(posedge dut.pixel_clk);#2;end endtask
    task commit;
        begin @(negedge dut.pixel_clk);frame=1;@(negedge dut.pixel_clk);frame=0;settle;end
    endtask
    task verify;
        begin commit;commit;if(dut.display_status!==expected)$fatal(1,"Stable397-bit packet not delivered");end
    endtask
    task reset_link;
        begin
            @(negedge clk27);rst_n=0;frame=0;#2;
            if(dut.display_status!==0 || dut.rgb_pipe!==0 || dut.de_pipe!==0)$fatal(1,"Async wrapper reset");
            #70;@(negedge clk27);rst_n=1;wait(dut.video_rst_n);settle;
        end
    endtask
    reg [31:0] prng=32'h3500ab19;
    initial begin
        force dut.frame_tick=frame;force compact_new.frame_tick=frame;
        force piano_new.frame_tick=frame;force compact_plain.frame_tick=frame;
        force old_hybrid.frame_tick=frame;force old_piano.frame_tick=frame;
        force old_compact_hybrid.frame_tick=frame;force old_compact.frame_tick=frame;
        force menu.frame_tick=frame;force legacy.frame_tick=frame;
        if(dut.STATUS_WIDTH!=397 || compact_new.STATUS_WIDTH!=348 || piano_new.STATUS_WIDTH!=396 ||
           compact_plain.STATUS_WIDTH!=347 || old_hybrid.STATUS_WIDTH!=339 || old_piano.STATUS_WIDTH!=338 ||
           old_compact_hybrid.STATUS_WIDTH!=290 || old_compact.STATUS_WIDTH!=289 ||
           menu.STATUS_WIDTH!=252 || legacy.STATUS_WIDTH!=242)$fatal(1,"Feature widths");
        reset_link;verify;
        for(i=0;i<396;i=i+1)begin
            @(negedge clk27);{expression,stimulus}=396'd1<<i;mode=i%3;verify;
            @(negedge clk27);{expression,stimulus}=~(396'd1<<i);mode=(i+1)%3;verify;
        end
        fork
            begin
                for(k=0;k<800;k=k+1)begin
                    @(negedge clk27);prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
                    {expression,stimulus}={stimulus[337:0],expression};
                    stimulus={stimulus[305:0],prng};mode=k%3;
                end
            end
            begin repeat(50)commit;end
        join
        verify;
        @(negedge clk27);expression={32'hdead0123,2'b01,8'd127,-9'sd256,7'd93};mode=2;verify;
        @(negedge clk27);expression={32'h0000ffff,2'b10,8'd1,9'sd255,7'd0};mode=0;verify;
        @(negedge clk27);expression={58{1'b1}};mode=1;commit;reset_link;verify;
        if(seen_modes!=7)$fatal(1,"Missing three-mode frame coverage");
        $display("V035_DISPLAY_CDC_PASS widths397/348/396/347/339/338/290/289/252/242 walking396x2 async800 frames=%0d checks=%0d",frames,cdc_checks);
        $finish;
    end
    initial begin #30000000;$fatal(1,"V035 display CDC timeout");end
endmodule
