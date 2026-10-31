`timescale 1ns/1ps
// Public ready distinguishes an available silent word from an address/config
// bubble. Test both RAM stores together, with arbitrary switch/commit timing.
module tb_ready_switch;
    reg clk=0;always #5 clk=~clk;
    reg rst=0,sample=0,start=0,we=0;
    reg [1:0] song=0;
    reg [8:0] wa=0;
    reg [31:0] wd=0,cfg=0;
    wire ready,valid,done;
    wire [6:0] note;
    wire [11:0] tick,nextcue;
    integer bank,q,n,checks=0;
    piano_roll_guide #(.BEAT_SAMPLES(64),.CUSTOM_SCORE_ENABLE(1),.SONG_LIBRARY_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst),.sample_tick(sample),.pause(1'b0),.song_id(song),
        .ui_start(start),.ui_restart(1'b0),.ui_toggle(1'b0),.roll_tick(tick),.done(done),
        .score_ready(ready),.expected_note(note),.expected_valid(valid),.next_mask(nextcue),
        .custom_write_clk(clk),.custom_write_en(we),.custom_write_addr(wa),
        .custom_write_data(wd),.custom_config(cfg));
    task check;
        input ok;input [8*100-1:0] message;
        begin checks=checks+1;if(ok!==1)$fatal(1,"ready switch: %0s",message);end
    endtask
    task cycle;begin @(negedge clk);@(posedge clk);#1;end endtask
    task select_song;
        input [1:0] id;
        begin
            @(negedge clk);song=id;start=1;
            @(posedge clk);#1;
            // Custom RAM prefetches even while a builtin is selected. Entering
            // custom at the same quarter/bank can legitimately be ready now.
            if(id!=3)check(!ready&&!valid&&nextcue==0,"new builtin song masks previous tag");
            else check(!valid && (!ready || nextcue==1),"prefetched custom count-in is coherent");
            @(negedge clk);start=0;cycle;
            check(ready&&!valid,"count-in word ready although no note");
        end
    endtask
    initial begin
        #1;rst=0;cycle;check(!ready,"reset invalidates read tag");
        rst=1;cycle;check(ready&&!valid,"builtin count-in is ready");
        // Custom banks: pitched first event in q8/9, explicit silent q10;
        // precomputed next is C4/D4 during count-in and zero afterwards.
        for(bank=0;bank<2;bank=bank+1)for(q=0;q<256;q=q+1)begin
            @(negedge clk);we=1;wa=bank*256+q;
            wd=(q<8)?((1<<23)|((60+2*bank)<<16)):
               ((q<10)?((96<<24)|(1<<13)|((q==8)?(1<<14):0)|60+2*bank):0);
            @(posedge clk);#1;
        end
        @(negedge clk);we=0;cfg={1'b0,1'b1,6'd2,6'd3,18'd23437};
        repeat(3)cycle;
        select_song(3);check(nextcue==1,"custom count-in first note preview");
        @(negedge clk);sample=1;
        for(n=0;n<46874;n=n+1)begin @(posedge clk);#1;@(negedge clk);end
        sample=0;
        check(tick==128&&!ready&&!valid,"custom quarter transition masks old data");
        @(posedge clk);#1;check(ready&&valid&&note==60,"custom note settles next clock");
        // Even with unchanged tick, bank/metadata replacement invalidates ready
        // immediately, before latch/one-clock synchronous read catch up.
        @(negedge clk);cfg[31]=1;#1;check(!ready&&!valid,"pending config is not ready");
        @(posedge clk);#1;check(tick==0&&!ready&&!valid,"commit resets and masks old bank");
        cycle;check(ready&&!valid&&nextcue==2,"new bank count-in settles");
        select_song(1);check(nextcue==0,"low F3 is valid next pitch with zero legacy pad mask");
        select_song(2);
        @(negedge clk);cfg[30]=0;cycle;
        @(negedge clk);song=3;start=1;cycle;
        @(negedge clk);start=0;cycle;
        check(!ready&&!valid&&done,"invalid custom config never reports ready");
        select_song(0);check(nextcue==1,"return from empty custom to builtin");
        $display("BUILTIN_READY_SWITCH_PASS checks=%0d reset_song_bank_invalid=1",checks);
        $finish;
    end
endmodule
