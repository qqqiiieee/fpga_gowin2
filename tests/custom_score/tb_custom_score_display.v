`timescale 1ns/1ps
// Actual wrapper->dashboard->renderer chain with source guide. No top/audio
// or real controller is replaced. The small BEGIN model below documents and
// checks the required external two-flop ACK ownership rule.
module tb_custom_score_display;
    reg clk=0;always #11 clk=~clk;
    reg rst_n=0,frame=0,we=0,start=0;
    reg [8:0] wa=0;reg [31:0] wd=0,cfg=0;
    reg [1:0] page=0;
    reg [1:0] cursor=0;
    wire [11:0] tick;wire [1:0] song;wire active,done,ack;
    piano_roll_guide #(.CUSTOM_SCORE_ENABLE(1)) guide(.clk(clk),.rst_n(rst_n),
        .sample_tick(1'b0),.pause(page!=0),.song_id(2'd3),.ui_start(start),
        .ui_toggle(1'b0),.ui_restart(1'b0),.roll_tick(tick),.roll_song(song),
        .active(active),.done(done),.custom_write_clk(clk),.custom_write_en(we),
        .custom_write_addr(wa),.custom_write_data(wd),.custom_config(cfg));
`define LIVE_PORTS \
    .clk27(clk),.rst_n(rst_n),.sample_tick(1'b0),.pcm(16'd0),.peak(16'd0), \
    .keys(12'd0),.timbre(4'd0),.note(7'd60),.note_valid(1'b1), \
    .frequency_bcd(16'h0262),.volume_percent(8'd73),.level_dbfs(-8'sd18), \
    .peak_percent(8'd86),.pitch(9'd0),.voices(6'd0),.pressure0(8'd12), \
    .pressure1(8'd34),.flags(8'h24),.guide_active(active),.guide_done(done), \
    .cue_mask(12'd0),.next_mask(12'd0),.wrong_mask(12'd0),.guide_step(6'd0), \
    .guide_total(6'd5),.beat_progress(8'd0),.target_beats(2'd0),.clip(1'b0), \
    .test_active(1'b0),.test_requested(6'd0),.test_busy(32'd0),.test_gate(32'd0), \
    .test_sweep(1'b0),.test_index(5'd0),.test_overrun(1'b0), \
    .ui_page(page),.ui_cursor(cursor),.ui_song(2'd3),.ui_controls(4'd0), \
    .control_page(2'd2),.fx_mode(2'd1),.strum_mode(2'd2),.knob_values(32'hc0806040), \
    .piano_keys(32'd0),.piano_outside(1'b0),.roll_tick(tick),.roll_song(song), \
    .roll_active(active),.roll_done(done),.expression_adc(32'h12345678), \
    .expression_calibrated(2'b10),.midi_velocity(8'd91),.midi_bend(-9'sd137), \
    .midi_modulation(7'd69),.visual_voice0(16'd0),.visual_voice1(16'd0)
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.CUSTOM_SCORE_ENABLE(1),
        .HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1),.VISUALIZATION_ENABLE(1)) dut(
        `LIVE_PORTS,.custom_write_clk(clk),.custom_write_en(we),.custom_write_addr(wa),
        .custom_write_data(wd),.custom_config(cfg),.custom_bank_ack(ack));
    hdmi_live_display #(.PIANO_ROLL_ENABLE(1),.HYBRID_MODE_ENABLE(1),
        .EXPRESSION_UI_ENABLE(1),.VISUALIZATION_ENABLE(1)) legacy(`LIVE_PORTS);
`undef LIVE_PORTS
    `include "tests/custom_score/score_fixture.vh"
    reg ack_meta=0,ack_sync=0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)begin ack_meta<=0;ack_sync<=0;end
        else begin ack_meta<=ack;ack_sync<=ack_meta;end
    wire begin_allowed=ack_sync==cfg[31];
    integer i,q,b=0,checks=0,commits=0;
    reg [9:0] xx=0,yy=190;reg dd=0;
    reg [26:0] queue0,queue1,queue2,want;
    reg [23:0] colour;
    reg [7:0] font[0:8191];
    task settle;begin repeat(30)@(negedge dut.pixel_clk);end endtask
    task frame_pulse;
        begin @(negedge dut.pixel_clk);frame=1;@(negedge dut.pixel_clk);frame=0;settle;end
    endtask
    task menu_glyph;
        input integer origin_x,origin_y;
        input [7:0] character;
        input [23:0] ink;
        integer dx,dy;
        reg [23:0] expected;
        begin
            for(dy=0;dy<16;dy=dy+1)for(dx=0;dx<8;dx=dx+1)begin
                @(negedge dut.pixel_clk);xx=origin_x+dx;yy=origin_y+dy;dd=1;
                // Four wrapper stages including geometry/font ROMs.
                repeat(4)begin @(posedge dut.pixel_clk);#2;end
                expected=font[character*16+dy][7-dx] ? ink : 24'h0b101c;
                checks=checks+1;
                if(dut.rgb_pipe!==expected)$fatal(1,"menu glyph char=%0d (%0d,%0d) expected=%06h got=%06h",character,xx,yy,expected,dut.rgb_pipe);
            end
        end
    endtask
    task upload;
        input integer bank;
        begin
            for(q=0;q<256;q=q+1)begin
                @(negedge clk);we=1;wa=bank*256+q;wd=fixture_word(bank,q);
            end
            @(negedge clk);we=0;
        end
    endtask
    task publish;
        input integer bank;
        begin
            @(negedge clk);cfg=fixture_config(bank,46875);
            repeat(4)@(negedge clk);
            if(!begin_allowed && ack_sync!==b[0])$fatal(1,"ACK synchronizer model");
            if(bank!=b && begin_allowed)$fatal(1,"BEGIN allowed before pixel acknowledgement");
            settle;
            if(ack!==b[0])$fatal(1,"ACK advanced without a frame");
            frame_pulse;frame_pulse;frame_pulse;
            if(!begin_allowed || ack!==bank[0])$fatal(1,"ACK did not propagate through wrapper");
            if(dut.d_roll_custom_bank!==bank[0] || dut.d_roll_tick!==0 || dut.d_roll_song!==3)
                $fatal(1,"timeline bank tag/guide restart not coherent");
            if(dut.d_expression_adc!==32'h12345678 || dut.d_midi_bend!==-9'sd137 || dut.d_strum_mode!==2)
                $fatal(1,"existing expression/hybrid bit offsets moved");
            b=bank;commits=commits+1;
        end
    endtask
    task row;
        input integer row_y;
        integer n,position;
        begin
            for(n=0;n<804;n=n+1)begin
                @(negedge dut.pixel_clk);position=n%800;xx=position;yy=row_y;dd=position<640;
                colour=0;
                if(dd)begin
                    colour=24'h0b101c;
                    if(position>=34&&position<=605)begin
                        colour=24'h172338;
                        if(position==34||position==605)colour=24'h34465f;
                        else if(position>=(b?404:374)&&position<(b?416:386))colour=24'h51d6e8;
                    end
                end
                want={dd,1'b1,1'b1,colour};
                @(posedge dut.pixel_clk);#2;
                if(n>=3 && page==0)begin
                    checks=checks+1;
                    if({dut.de_pipe,dut.hs_pipe,dut.vs_pipe,dut.rgb_pipe}!==queue2)
                        $fatal(1,"four-clock custom wrapper alignment x=%0d expected=%07h got=%07h",position-3,queue2,{dut.de_pipe,dut.hs_pipe,dut.vs_pipe,dut.rgb_pipe});
                end
                if(n>=3 && page!=0)begin
                    checks=checks+1;
                    if(dut.rgb_pipe!==legacy.rgb_pipe || dut.visual_fft_addr!==legacy.visual_fft_addr ||
                        dut.visual_xy_addr!==legacy.visual_xy_addr)$fatal(1,"library/FFT/XY branch changed");
                end
                queue2=queue1;queue1=queue0;queue0=want;
            end
        end
    endtask
    initial begin
        $readmemh("src/ui_font.hex",font);
        force dut.frame_tick=frame;force legacy.frame_tick=frame;
        force dut.x=xx;force dut.y=yy;force dut.de=dd;
        force legacy.x=xx;force legacy.y=yy;force legacy.de=dd;
        force dut.hsync=1'b1;force dut.vsync=1'b1;
        force legacy.hsync=1'b1;force legacy.vsync=1'b1;
        #2;repeat(4)@(negedge clk);rst_n=1;wait(dut.video_rst_n);settle;
        if(dut.STATUS_WIDTH!=398 || legacy.STATUS_WIDTH!=397)$fatal(1,"conditional packet width");
        @(negedge clk);start=1;@(negedge clk);start=0;
        upload(0);upload(1);publish(0);row(190);
        @(negedge clk);page=1;cursor=3;frame_pulse;frame_pulse;frame_pulse;
        if(dut.compact_ui.u_dashboard.selected_song!==21)$fatal(1,"song3 incorrectly labelled Twinkle");
        menu_glyph(360,48,"4",24'he2e8f0); // selected SONG4
        menu_glyph(32,176,"S",24'hf4bb4f);
        menu_glyph(40,176,"O",24'hf4bb4f);
        menu_glyph(48,176,"N",24'hf4bb4f);
        menu_glyph(56,176,"G",24'hf4bb4f);
        menu_glyph(72,176,"4",24'hf4bb4f);
        menu_glyph(128,176," ",24'hf4bb4f); // no STEP counters in list
        // ACK must work with piano overlay hidden on the library page.
        publish(1);
        @(negedge clk);page=2;frame_pulse;frame_pulse;frame_pulse;row(190);row(350);
        @(negedge clk);page=0;frame_pulse;frame_pulse;frame_pulse;row(190);
        if(tick!==0)$fatal(1,"sample-disabled page switch advanced guide");
        $display("CUSTOM_DISPLAY_PASS pixels=%0d commits=%0d wrapper_stages=4 packet_bits=398 ack_route=renderer_dashboard_live fft_xy_preserved=1",checks,commits);
        $finish;
    end
    initial begin #10000000;$fatal(1,"display watchdog");end
endmodule
