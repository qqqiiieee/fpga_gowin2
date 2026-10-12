`timescale 1ns/1ps
// The real wrapper, renderer, timing, wave RAM and bundled CDC are compiled.
// Clock and TMDS boundaries below are test-only models, with no vendor/hardware
// dependencies. No claim about PLL/TMDS serialization or physical HDMI.
module tb_menu_cdc;
    reg clk27=0,rst_n=0;always #11 clk27=~clk27;
    reg [251:0] stimulus=0;
    reg frame=0;
    // Contract offsets are specified independently, not copied from DUT pack.
`define MENU_SOURCE_PORTS \
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
    .ui_song(stimulus[247:246]),.ui_controls(stimulus[245:242])
    hdmi_live_display #(.UI_ENABLE(1)) dut(`MENU_SOURCE_PORTS);
    hdmi_live_display legacy(`MENU_SOURCE_PORTS);
`undef MENU_SOURCE_PORTS
    reg [251:0] history[0:4095];integer history_count=1;
    initial history[0]=0;
    always @(posedge clk27)begin
        if(stimulus!==history[history_count-1])begin
            if(history_count>=4096)$fatal(1,"History capacity exceeded");
            history[history_count]=stimulus;history_count=history_count+1;
        end
    end
    reg [251:0] previous=0;
    reg sampled_frame;
    integer frames=0,checks=0,h,i,k,found;
    // Observe output after NBA. A frame may only contain one complete source
    // word ever presented, and every lower-field decode must match its offsets.
    always @(posedge dut.pixel_clk)begin
        sampled_frame=frame;
        #1;
        if(dut.video_rst_n && legacy.video_rst_n)begin
            checks=checks+1;
            if(!sampled_frame && dut.display_status!==previous)$fatal(1,"252-bit packet tears within frame");
            if(legacy.display_status!==dut.display_status[241:0])$fatal(1,"Legacy 242 bits diverge from menu low bits");
            if(dut.source_status!==stimulus)$fatal(1,"Source packing differs from explicit 252-bit offsets");
            if(legacy.source_status!==stimulus[241:0])$fatal(1,"Legacy source layout differs");
            if({dut.d_ui_page,dut.d_ui_cursor,dut.d_ui_song,dut.d_ui_controls}!==dut.display_status[251:242])
                $fatal(1,"High 10 UI bits decoded incorrectly");
            if({legacy.d_ui_page,legacy.d_ui_cursor,legacy.d_ui_song,legacy.d_ui_controls}!==10'd0)
                $fatal(1,"Default UI_ENABLE=0 metadata not disabled");
            if({dut.d_keys,dut.d_timbre,dut.d_note,dut.d_note_valid,dut.d_frequency,
                dut.d_volume,dut.d_level,dut.d_peak,dut.d_pitch,dut.d_voices,
                dut.d_pressure0,dut.d_pressure1,dut.d_flags,dut.d_active,dut.d_done,
                dut.d_cue,dut.d_next,dut.d_wrong,dut.d_step,dut.d_total,dut.d_progress,
                dut.d_beats,dut.d_clip,dut.d_test_active,dut.d_test_requested,
                dut.d_test_busy,dut.d_test_gate,dut.d_test_sweep,dut.d_test_index,dut.d_test_overrun}
                 !==dut.display_status[241:0])$fatal(1,"Old fields unpack incorrectly");
            if({dut.u_dashboard.ui_page,dut.u_dashboard.ui_cursor,dut.u_dashboard.ui_song,
                dut.u_dashboard.ui_controls}!==dut.display_status[251:242])$fatal(1,"UI renderer ports tear");
            if(dut.u_dashboard.flags!==(dut.display_status[146:139] | (dut.display_status[78] ? 8'h80 : 8'h00)))
                $fatal(1,"Physical clip flag OR lost");
            if(sampled_frame)begin
                frames=frames+1;found=0;
                for(h=0;h<history_count;h=h+1)if(dut.display_status===history[h])found=1;
                if(!found)$fatal(1,"Frame is not a coherent source word: %063h",dut.display_status);
            end
        end else begin
            if(dut.display_status!==0 || legacy.display_status!==0)$fatal(1,"Reset did not discard packet");
        end
        previous=dut.display_status;
    end
    task settle;
        begin repeat(20)@(posedge dut.pixel_clk);#2;end
    endtask
    task commit;
        begin
            @(negedge dut.pixel_clk);frame=1;
            @(posedge dut.pixel_clk);#2;
            @(negedge dut.pixel_clk);frame=0;settle;
        end
    endtask
    task verify;
        input [251:0] expected;
        begin
            // First boundary requests; second applies completed coherent data.
            commit;commit;
            if(dut.display_status!==expected || legacy.display_status!==expected[241:0])
                $fatal(1,"Stable snapshot expected=%063h actual=%063h",expected,dut.display_status);
        end
    endtask
    task reset_both;
        begin
            @(negedge clk27);rst_n=0;frame=0;#3;
            if(dut.display_status!==0 || legacy.display_status!==0)$fatal(1,"Asynchronous reset failed");
            #70;@(negedge clk27);rst_n=1;
            wait(dut.pll_locked && legacy.pll_locked);
            wait(dut.video_rst_n && legacy.video_rst_n);settle;
        end
    endtask
    reg [251:0] word;
    reg [31:0] prng=32'h6dc2913f;
    task random_word;
        integer n;
        begin
            for(n=0;n<252;n=n+1)begin
                prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};word[n]=prng[0];
            end
        end
    endtask
    initial begin
        force dut.frame_tick=frame;force legacy.frame_tick=frame;
        if(dut.STATUS_WIDTH!=252 || legacy.STATUS_WIDTH!=242)$fatal(1,"Wrong status widths");
        reset_both;verify(0);
        // Every wire, not just UI metadata: catches bit order and truncation.
        for(i=0;i<252;i=i+1)begin
            @(negedge clk27);stimulus=252'd1<<i;
            verify(stimulus);
            @(negedge clk27);stimulus=~(252'd1<<i);verify(stimulus);
        end
        // Hold a nontrivial page while rapidly changing all source fields.
        fork
            begin
                for(k=0;k<800;k=k+1)begin @(negedge clk27);random_word;stimulus=word;end
            end
            begin repeat(50)commit;end
        join
        settle;verify(stimulus);
        // Enter test, clear gate while release busy persists, then exit.
        @(negedge clk27);stimulus=0;stimulus[251:242]={2'd3,2'd2,2'd1,4'ha};
        stimulus[241:230]=12'h340;stimulus[168:163]=32;
        stimulus[77]=1;stimulus[76:71]=32;stimulus[70:39]=32'hffffffff;stimulus[38:7]=32'hffffffff;
        verify(stimulus);
        @(negedge clk27);stimulus[76:71]=0;stimulus[38:7]=0;stimulus[70:39]=32'h80000000;stimulus[168:163]=1;
        verify(stimulus);
        if(!dut.u_dashboard.test_active || dut.u_dashboard.test_gate!==0 || dut.u_dashboard.test_busy!==32'h80000000)
            $fatal(1,"Exit handover lost test ownership or release tail");
        @(negedge clk27);stimulus[70:39]=0;stimulus[168:163]=0;verify(stimulus);
        @(negedge clk27);stimulus[77]=0;verify(stimulus);
        // Mid-handshake reset discards pending old packets, including UI/test.
        @(negedge clk27);stimulus={252{1'b1}};commit;
        @(negedge clk27);stimulus=0;stimulus[251:242]={2'd2,2'd1,2'd2,4'h5};reset_both;verify(stimulus);
        // PLL lock loss drives wrapper resets even with external reset high.
        force dut.pll_locked=1'b0;force legacy.pll_locked=1'b0;#3;
        if(dut.display_status!==0 || legacy.display_status!==0)$fatal(1,"Lock loss retained stale metadata");
        #40;release dut.pll_locked;release legacy.pll_locked;
        wait(dut.video_rst_n && legacy.video_rst_n);settle;verify(stimulus);
        release dut.frame_tick;release legacy.frame_tick;
        $display("MENU_CDC_TEST_PASS widths=252/242 frames=%0d checks=%0d walking_bits=252x2 async_packets=800 reset_test_entry_exit_lockloss",frames,checks);$finish;
    end
    initial begin #10000000;$fatal(1,"Menu CDC timeout");end
endmodule

module hdmi_clocks(input clk27,input rst_n,output serial_clk,output reg pixel_clk=0,output reg locked=0);
    always #7 pixel_clk=~pixel_clk;
    assign serial_clk=clk27;
    reg [2:0] lock_count=0;
    always @(posedge clk27 or negedge rst_n)begin
        if(!rst_n)begin locked<=0;lock_count<=0;end
        else if(lock_count==3)locked<=1;
        else lock_count<=lock_count+1;
    end
endmodule
module hdmi_tx(input pixel_clk,input serial_clk,input rst_n,input [7:0] red,green,blue,
    input de,hsync,vsync,output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n);
    assign tmds_clk_p=serial_clk;assign tmds_clk_n=~serial_clk;
    assign tmds_data_p=0;assign tmds_data_n=3'b111;
endmodule
