`timescale 1ns/1ps
module tb_instrument_ui_control;
    localparam HOLD=8;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg sample_tick=0;reg [15:0] keys=0;
    reg ghost=0,test_owned=0,remote_active=0;
    wire [1:0] page,cursor,song_id;wire song_start,song_toggle,song_restart;
    instrument_ui_control #(.HOLD_SAMPLES(HOLD)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.keys(keys),.ghost(ghost),
        .test_owned(test_owned),.remote_active(remote_active),.page(page),.cursor(cursor),
        .song_id(song_id),.song_start(song_start),.song_toggle(song_toggle),.song_restart(song_restart));
    reg default_rst_n=0,default_tick=0;reg [15:0] default_keys=0;
    wire [1:0] default_page,default_cursor,default_song;
    wire default_start,default_toggle,default_restart;
    // Default instance independently measures the production 75,000 sample limit.
    instrument_ui_control default_dut(.clk(clk),.rst_n(default_rst_n),.sample_tick(default_tick),
        .keys(default_keys),.ghost(1'b0),.test_owned(1'b0),.remote_active(1'b0),
        .page(default_page),.cursor(default_cursor),.song_id(default_song),
        .song_start(default_start),.song_toggle(default_toggle),.song_restart(default_restart));
    integer checks=0,a,b,i,p,s;
    task step;
        input [15:0] k;input tick;
        begin @(negedge clk);keys=k;sample_tick=tick;@(posedge clk);#1;end
    endtask
    task expect_state;
        input integer ep,ec,es;
        input [2:0] pulses; // {start,toggle,restart}
        begin
            checks=checks+1;
            if({page,cursor,song_id,song_start,song_toggle,song_restart}!=={ep[1:0],ec[1:0],es[1:0],pulses})
                $fatal(1,"UI check=%0d keys=%04h expected p/c/s=%0d/%0d/%0d pulses=%03b got=%0d/%0d/%0d %b%b%b",checks,keys,ep,ec,es,pulses,page,cursor,song_id,song_start,song_toggle,song_restart);
        end
    endtask
    task reset_ui;
        begin
            @(negedge clk);rst_n=0;keys=0;ghost=0;test_owned=0;remote_active=0;sample_tick=0;
            @(posedge clk);#1;expect_state(0,0,0,0);
            @(negedge clk);rst_n=1;step(0,0);expect_state(0,0,0,0);
        end
    endtask
    task page_click;
        input integer ep,ec,es;
        reg [1:0] old_page,old_cursor,old_song;
        begin
            old_page=page;old_cursor=cursor;old_song=song_id;
            step(16'h4000,1);expect_state(old_page,old_cursor,old_song,0);
            repeat(3)begin step(16'h4000,1);expect_state(old_page,old_cursor,old_song,0);end
            step(0,0);expect_state(ep,ec,es,0);step(0,1);expect_state(ep,ec,es,0);
        end
    endtask
    task next_click;
        input integer ticks,ep,ec,es;input [2:0] pulse;
        reg [1:0] old_page,old_cursor,old_song;
        integer n;
        begin
            old_page=page;old_cursor=cursor;old_song=song_id;
            step(16'h8000,0);expect_state(old_page,old_cursor,old_song,0);
            for(n=0;n<ticks;n=n+1)begin step(16'h8000,1);expect_state(old_page,old_cursor,old_song,0);end
            step(0,0);expect_state(ep,ec,es,pulse);
            step(0,1);expect_state(ep,ec,es,0);
        end
    endtask
    task cancel_mask;
        input [15:0] candidate,bad;
        reg [1:0] ep,ec,es;
        begin
            ep=page;ec=cursor;es=song_id;
            step(candidate,1);step(bad,1);expect_state(ep,ec,es,0);
            // Returning to a singleton must not resurrect the old candidate.
            repeat(HOLD+2)step(candidate,1);
            step(0,1);expect_state(ep,ec,es,0);step(0,0);expect_state(ep,ec,es,0);
        end
    endtask
    initial begin
        reset_ui;
        // Four pages cycle only on release, not while holding S15.
        page_click(1,0,0);page_click(2,0,0);page_click(3,0,0);page_click(0,0,0);
        next_click(HOLD-1,0,0,0,3'b010);next_click(HOLD,0,0,0,3'b001);
        next_click(HOLD+4,0,0,0,3'b001);
        // Source-clock duration cannot count as sample duration.
        step(16'h8000,0);repeat(100)step(16'h8000,0);step(0,0);expect_state(0,0,0,3'b010);step(0,0);
        // Select and start each actual song; selected song seeds library cursor.
        for(s=0;s<3;s=s+1)begin
            reset_ui;page_click(1,0,0);
            for(i=0;i<s;i=i+1)next_click(0,1,i+1,0,0);
            next_click(HOLD,0,s,s,3'b100);page_click(1,s,s);
            next_click(0,1,(s+1)%3,s,0);
        end
        reset_ui;page_click(1,0,0);
        next_click(0,1,1,0,0);next_click(0,1,2,0,0);next_click(0,1,0,0,0);
        page_click(2,0,0);next_click(0,2,1,0,0);next_click(0,2,2,0,0);
        next_click(0,2,0,0,0);next_click(0,2,1,0,0);next_click(HOLD,2,0,0,0);
        page_click(3,0,0);next_click(0,0,0,0,0);
        page_click(1,0,0);page_click(2,0,0);page_click(3,0,0);next_click(HOLD,0,0,0,0);
        // Every 2-key chord (all 120 pairs), both UI candidates.
        for(a=0;a<16;a=a+1)for(b=a+1;b<16;b=b+1)begin
            cancel_mask(16'h4000,(16'b1<<a)|(16'b1<<b));
            cancel_mask(16'h8000,(16'b1<<a)|(16'b1<<b));
        end
        cancel_mask(16'h4000,16'hffff);cancel_mask(16'h8000,16'hffff);
        // Singleton S13/S14 or a note cannot become a UI gesture without release.
        for(i=0;i<14;i=i+1)begin cancel_mask(16'h4000,16'b1<<i);cancel_mask(16'h8000,16'b1<<i);end
        cancel_mask(16'h4000,16'h8000);cancel_mask(16'h8000,16'h4000);
        for(p=0;p<4;p=p+1)begin
            reset_ui;for(i=0;i<p;i=i+1)page_click(i+1,0,0);
            step(16'h8000,0);repeat(HOLD)step(16'h8000,1);
            @(negedge clk);ghost=1;step(0,1);expect_state(p,0,0,0);
            step(16'h8000,1);@(negedge clk);ghost=0;
            step(16'h8000,1);step(0,0);expect_state(p,0,0,0);
            // Re-arm after clean release succeeds once.
            if(p==0)next_click(0,0,0,0,3'b010);
            else if(p==1 || p==2)next_click(0,p,1,0,0);
        end
        // Source switching on press, during hold, and coincident with release.
        for(p=0;p<2;p=p+1)begin
            reset_ui;page_click(1,0,0);
            step(16'h8000,0);repeat(HOLD)step(16'h8000,1);
            // Change source and key on the SAME edge. A separate step here
            // would create an intervening clean-release clock and legitimately
            // arm a fresh gesture, invalidating the cancellation expectation.
            @(negedge clk);remote_active=1;keys=p ? 0 : 16'h8000;sample_tick=1;
            @(posedge clk);#1;expect_state(1,0,0,0);
            repeat(HOLD+2)step(16'h8000,1);step(0,0);expect_state(1,0,0,0);
            next_click(0,1,1,0,0);
            step(16'h4000,0);@(negedge clk);remote_active=0;step(0,0);expect_state(1,1,0,0);
            step(0,0);page_click(2,0,0);
        end
        reset_ui;page_click(1,0,0);next_click(0,1,1,0,0);
        step(16'h8000,1);@(negedge clk);test_owned=1;step(16'h8000,1);expect_state(0,1,0,0);
        repeat(HOLD+4)step(16'h8000,1);
        @(negedge clk);test_owned=0;step(16'h8000,1);step(0,0);expect_state(0,1,0,0);
        next_click(0,0,1,0,3'b010);
        // Reset with key held requires full clean release before arming.
        @(negedge clk);rst_n=0;keys=16'h4000;@(posedge clk);#1;
        @(negedge clk);rst_n=1;step(16'h4000,1);step(0,0);expect_state(0,0,0,0);
        page_click(1,0,0);
        // Production threshold: 74999 -> short, 75000 -> long, 0.8 s at 93750 Hz.
        @(negedge clk);default_rst_n=1;default_keys=0;default_tick=0;
        repeat(2)@(posedge clk);
        for(p=0;p<2;p=p+1)begin
            @(negedge clk);default_keys=16'h8000;default_tick=0;@(posedge clk);#1;
            for(i=0;i<74999+p;i=i+1)begin
                @(negedge clk);default_tick=1;@(posedge clk);#1;
                if(default_start || default_toggle || default_restart)$fatal(1,"Default pulse before release");
            end
            @(negedge clk);default_keys=0;default_tick=0;@(posedge clk);#1;
            if({default_start,default_toggle,default_restart}!== (p ? 3'b001 : 3'b010))
                $fatal(1,"Default 75000 tick threshold incorrect p=%0d",p);
            @(posedge clk);#1;if(default_start || default_toggle || default_restart)$fatal(1,"Default pulse too wide");
        end
        $display("INSTRUMENT_UI_CONTROL_TEST_PASS checks=%0d chords=120x2 exact_default75000 source_switch ghost owned reset",checks);$finish;
    end
    initial begin #10000000;$fatal(1,"UI control timeout");end
endmodule
