`timescale 1ns/1ps
// Only external pins drive the DUT. Production timers are scaled, not forced.
module tb_v035_panel_buttons;
    parameter integer DB=4;
    localparam integer HOLD=64, SETTLE=DB+9;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [3:0] keys_n=15;
    reg guide_done=0, test_owned=0, phone_set=0;
    reg [7:0] phone_param=0, phone_value=0;
    wire [1:0] page,song,cursor;
    wire song_start,song_toggle,song_restart,timbre_cycle,mode_cycle,key_pause;
    wire test_toggle,test_count_cycle,test_sweep_toggle,test_full;
    wire [3:0] down;
    // 0..4 old events; 5..8 new diagnostic events.
    wire [8:0] events={test_full,test_sweep_toggle,test_count_cycle,test_toggle,
                       mode_cycle,timbre_cycle,song_restart,song_toggle,song_start};
    reg [8:0] previous_events=0;
    integer totals[0:8],saved[0:8];
    integer checks=0,i,j,k,age;
    reg [3:0] saved_ui;
    four_button_display_control #(.DEBOUNCE_CYCLES(DB),.LONG_PRESS_CYCLES(HOLD)) dut(
        .clk(clk),.rst_n(rst_n),.keys_n(keys_n),.guide_done(guide_done),
        .test_owned(test_owned),.page(page),.song_id(song),.cursor(cursor),
        .song_start(song_start),.song_toggle(song_toggle),.song_restart(song_restart),
        .key_pause(key_pause),.buttons_down(down),.phone_set_valid(phone_set),
        .phone_param(phone_param),.phone_value(phone_value),
        .timbre_cycle(timbre_cycle),.mode_cycle(mode_cycle),.test_toggle(test_toggle),
        .test_count_cycle(test_count_cycle),.test_sweep_toggle(test_sweep_toggle),
        .test_full(test_full));

    always @(posedge clk) begin : observe
        integer m;
        #1;
        if(!rst_n)begin
            previous_events=0;
            for(m=0;m<9;m=m+1)totals[m]=0;
        end else begin
            if((^{events,page,song,cursor,down,key_pause})===1'bx)
                $fatal(1,"unknown panel output DB=%0d",DB);
            if((events&previous_events)!=0)$fatal(1,"multi-clock event");
            if((events&(events-1))!=0)$fatal(1,"overlapping panel events %b",events);
            if(events!=0 && down!=0)$fatal(1,"event before debounced release");
            if(test_owned && events[4:0]!=0)$fatal(1,"normal command leaks into test");
            if(!test_owned && events[8:6]!=0)$fatal(1,"test controls leak into normal");
            if(cursor!==song || song>2)$fatal(1,"song state not preserved");
            previous_events=events;
            for(m=0;m<9;m=m+1)if(events[m])totals[m]=totals[m]+1;
        end
    end
    task cycles(input integer n);
        repeat(n)begin @(posedge clk);#2;end
    endtask
    task check(input condition,input [1023:0] message);
        begin checks=checks+1;if(condition!==1'b1)
            $fatal(1,"%0s DB=%0d page/song=%0d/%0d",message,DB,page,song);end
    endtask
    task level(input [3:0] mask,input integer n);
        begin @(negedge clk);keys_n=~mask;cycles(n);end
    endtask
    task release_keys;
        level(0,2*SETTLE);
    endtask
    task remember;
        begin saved_ui={page,song};for(k=0;k<9;k=k+1)saved[k]=totals[k];end
    endtask
    task delta(input [8:0] expected,input [1023:0] message);
        begin
            for(k=0;k<9;k=k+1)
                check(totals[k]==saved[k]+(expected[k]?1:0),message);
        end
    endtask
    task unchanged(input [1023:0] message);
        begin delta(0,message);check({page,song}==saved_ui,message);end
    endtask
    task click_event(input integer key,input integer duration,input [8:0] expected);
        begin
            remember;level(1<<key,duration);unchanged("held gesture fires early");
            release_keys;delta(expected,"release event mismatch");
            remember;cycles(SETTLE*2);unchanged("release repeats while idle");
        end
    endtask
    task change_owner(input value);
        begin @(negedge clk);test_owned=value;cycles(2*SETTLE);end
    endtask
    task set_phone(input [7:0] p,input [7:0] v);
        begin
            @(negedge clk);phone_param=p;phone_value=v;phone_set=1;
            cycles(1);@(negedge clk);phone_set=0;cycles(2);
        end
    endtask
    task reset_panel(input [3:0] mask,input owner);
        begin
            @(negedge clk);rst_n=0;keys_n=~mask;test_owned=owner;phone_set=0;
            guide_done=0;cycles(4);@(negedge clk);rst_n=1;cycles(2*SETTLE);
            check({page,song}==0 && key_pause,"reset state");
        end
    endtask
    function [7:0] absolute_param(input integer number);
        case(number)
            0:absolute_param=1;1:absolute_param=2;2:absolute_param=12;
            3:absolute_param=13;default:absolute_param=14;
        endcase
    endfunction
    initial begin
        // Every boot-held key is inert in either ownership domain.
        for(i=0;i<2;i=i+1)for(j=0;j<4;j=j+1)begin
            reset_panel(1<<j,i!=0);remember;cycles(HOLD*3);
            unchanged("boot-held key fires");release_keys;
            unchanged("boot-held key release fires");
        end
        reset_panel(0,0);
        click_event(0,SETTLE,0);check(page==1,"short1 page");
        click_event(1,SETTLE,9'b000000001);check(page==0 && !key_pause,"short2 start");
        click_event(1,SETTLE,9'b000000010);
        guide_done=1;click_event(1,SETTLE,9'b000000001);guide_done=0;
        click_event(2,SETTLE,9'b000000100);check(page==0,"short3 restart");
        click_event(3,SETTLE,0);check(page==1 && song==1 && key_pause,"short4 song");
        click_event(0,HOLD*4,9'b000001000);
        click_event(1,HOLD*4,9'b000010000);
        remember;level(4,HOLD-1);release_keys;
        delta(9'b000000100,"one-clock-below long3 must restart");
        remember;level(4,HOLD);release_keys;
        delta(9'b000100000,"exact long3 enters test without restart");
        click_event(2,HOLD*4,9'b000100000);

        change_owner(1);check(key_pause,"test owns teaching pause");
        for(i=0;i<4;i=i+1)begin
            click_event(i,SETTLE,i==0?9'b001000000:
                (i==1?9'b010000000:(i==2?9'b000100000:9'b100000000)));
        end
        click_event(2,HOLD*4,9'b000100000);
        for(i=0;i<4;i=i+1)if(i!=2)begin
            remember;level(1<<i,HOLD*4);release_keys;
            unchanged("owned long1/2/4 are intentionally ignored");
        end
        // Debounce glitches and long multi-key sequences may never salvage an action.
        for(i=0;i<2;i=i+1)begin
            change_owner(i!=0);
            if(DB>1)for(j=0;j<4;j=j+1)begin
                remember;level(1<<j,DB-1);release_keys;
                unchanged("sub-debounce pulse becomes action");
            end
            for(j=0;j<4;j=j+1)for(age=j+1;age<4;age=age+1)begin
                remember;level((1<<j)|(1<<age),HOLD*2);
                level(1<<j,SETTLE);release_keys;unchanged("chord became single action");
                level(1<<j,HOLD*2);level((1<<j)|(1<<age),SETTLE);
                level(1<<age,SETTLE);release_keys;unchanged("long gesture salvaged after chord");
                level(1<<j,SETTLE);level(1<<age,SETTLE);release_keys;
                unchanged("key substitution action");
            end
        end
        // On BOTH ownership edges, discard pending held and release-boundary gestures.
        for(i=0;i<2;i=i+1)for(j=0;j<4;j=j+1)begin
            reset_panel(0,i!=0);remember;level(1<<j,HOLD*2);
            change_owner(i==0);release_keys;
            unchanged("ownership edge replays held gesture");
            // A new gesture in the new owner works only after full release guard.
            click_event(2,SETTLE,i==0?9'b000100000:9'b000000100);
            remember;level(1<<j,SETTLE);
            @(negedge clk);keys_n=15;age=0;
            while(down!=0 && age<SETTLE*2)begin cycles(1);age=age+1;end
            check(down==0,"debounced release boundary found");
            @(negedge clk);test_owned=i!=0;
            cycles(2*SETTLE);unchanged("ownership edge loses release priority");
        end
        // Absolute phone UI writes outrank all old AND new panel gestures.
        for(i=0;i<2;i=i+1)for(j=0;j<5;j=j+1)begin
            reset_panel(0,i!=0);remember;level(4,HOLD*2);
            set_phone(absolute_param(j),j==2?2:1);
            if(j==2)begin check(page==2,"phone page wins during hold");saved_ui={page,song};end
            release_keys;unchanged("phone SET failed to discard long3");
            remember;level(4,SETTLE);@(negedge clk);keys_n=15;age=0;
            while(down!=0 && age<SETTLE*2)begin cycles(1);age=age+1;end
            check(down==0,"phone collision release boundary");
            set_phone(absolute_param(j),j==2?3:1);
            if(j==2)begin check(page==3,"same-edge phone page wins");saved_ui={page,song};end
            release_keys;unchanged("phone SET loses same-release priority");
        end
        // Non-UI volume SET must leave a legitimate owned count gesture intact.
        reset_panel(0,1);remember;level(1,SETTLE);set_phone(0,200);release_keys;
        delta(9'b001000000,"unrelated phone write consumed count action");
        $display("V035_PANEL_BUTTONS_PASS checks=%0d debounce=%0d release_only=1 ownership_edges=1 phone_priority=1",checks,DB);
        $finish;
    end
    initial begin #4000000;$fatal(1,"panel button watchdog");end
endmodule
