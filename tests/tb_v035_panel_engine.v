`timescale 1ns/1ps
// Exercise the public external command interface and exact original safety path.
// Two default-parameter instances additionally compare driven garbage vs omitted
// external inputs, proving legacy compatibility while their legacy keys operate.
module tb_v035_panel_engine;
    localparam integer HOLD=5, IDLE=257, HALF=3, DIV=2;
    reg clk=0,rst_n=0,tick=0,ghost=0,source=0;
    always #5 clk=~clk;
    reg [15:0] keys=0;
    reg enter=0,exit_test=0,count_valid=0,sweep_start=0;
    reg [5:0] count=0;
    wire owned,mode,sweep,clear,ready;
    wire [31:0] gates;
    wire [5:0] requested;
    wire [4:0] index;
    wire [8:0] gain;
    wire [3:0] state;
    wire [60:0] default_open,default_driven;
    oscillator_test_control #(.HOLD_SAMPLES(HOLD),.MAX_SAMPLES(IDLE),
        .SWEEP_HALF_SAMPLES(HALF),.RAMP_DIV(DIV),.EXTERNAL_UI_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.keys(keys),.ghost(ghost),
        .remote_active(source),.owned(owned),.test_mode(mode),.gate_mask(gates),
        .requested_count(requested),.sweep_active(sweep),.sweep_index(index),
        .master_gain(gain),.clear_audio(clear),.state_debug(state),
        .normal_input_ready(ready),.external_enter(enter),.external_exit(exit_test),
        .external_count_valid(count_valid),.external_count(count),
        .external_sweep_start(sweep_start));
    // Compare every public output, including legacy input-readiness ownership.
    wire lo_owned,lo_mode,lo_sweep,lo_clear,lo_ready;
    wire ld_owned,ld_mode,ld_sweep,ld_clear,ld_ready;
    wire [31:0] lo_gates,ld_gates;
    wire [5:0] lo_count,ld_count;
    wire [4:0] lo_index,ld_index;
    wire [8:0] lo_gain,ld_gain;
    wire [3:0] lo_state,ld_state;
    assign default_open={lo_owned,lo_mode,lo_gates,lo_count,lo_sweep,lo_index,
                         lo_gain,lo_clear,lo_state,lo_ready};
    assign default_driven={ld_owned,ld_mode,ld_gates,ld_count,ld_sweep,ld_index,
                           ld_gain,ld_clear,ld_state,ld_ready};
    oscillator_test_control #(.HOLD_SAMPLES(HOLD),.MAX_SAMPLES(IDLE),
        .SWEEP_HALF_SAMPLES(HALF),.RAMP_DIV(DIV)) legacy_unconnected(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.keys(keys),.ghost(ghost),
        .remote_active(source),.owned(lo_owned),.test_mode(lo_mode),.gate_mask(lo_gates),
        .requested_count(lo_count),.sweep_active(lo_sweep),.sweep_index(lo_index),
        .master_gain(lo_gain),.clear_audio(lo_clear),.state_debug(lo_state),.normal_input_ready(lo_ready));
    oscillator_test_control #(.HOLD_SAMPLES(HOLD),.MAX_SAMPLES(IDLE),
        .SWEEP_HALF_SAMPLES(HALF),.RAMP_DIV(DIV)) legacy_driven(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.keys(keys),.ghost(ghost),
        .remote_active(source),.owned(ld_owned),.test_mode(ld_mode),.gate_mask(ld_gates),
        .requested_count(ld_count),.sweep_active(ld_sweep),.sweep_index(ld_index),
        .master_gain(ld_gain),.clear_audio(ld_clear),.state_debug(ld_state),
        .normal_input_ready(ld_ready),.external_enter(enter),.external_exit(exit_test),
        .external_count_valid(count_valid),.external_count(count),.external_sweep_start(sweep_start));
    integer checks=0,clears=0,observations=0,legacy_active_observations=0;
    reg last_clear=0,last_mode=0,monitor_valid=0;
    reg [8:0] last_gain=256;
    task check(input condition,input [1023:0] message);
        begin checks=checks+1;if(condition!==1'b1)
            $fatal(1,"%0s state=%0d gain=%0d req=%0d gates=%h",message,state,gain,requested,gates);end
    endtask
    always @(posedge clk)begin
        #1;
        if(!rst_n)begin
            last_clear=0;last_mode=0;last_gain=256;monitor_valid=0;clears=0;
        end else begin
            observations=observations+1;
            if(default_open!==default_driven)$fatal(1,"default-disabled behavior changed with unused inputs");
            if(lo_state==3)legacy_active_observations=legacy_active_observations+1;
            check((^{owned,mode,gates,requested,sweep,index,gain,clear,state,ready,default_open})!==1'bx,
                  "all outputs known, including unconnected default inputs");
            check(gain<=256 && requested<=32 && state<=6,"bounded outputs");
            check(owned==(state!=0) && ready==(state==0 || state==6),"ownership/input readiness encoding");
            check(!(last_clear&&clear),"clear one clock wide");
            if(clear)begin clears=clears+1;check(gain==0 && (state==2 || state==5),"clear at zero boundary");end
            if(monitor_valid)begin
                if(mode!=last_mode)check(clear,"mode changes only on clear");
                if(gain!=last_gain)begin
                    check(tick,"gain advances only at sample tick");
                    check(gain+1==last_gain || gain==last_gain+1,"gain changes by one");
                end
            end
            if(state==0)check(!mode&&!sweep&&gates==0&&requested==0&&gain==256,"normal safe state");
            if(state==5)check(!mode&&!sweep&&gates==0&&requested==0&&gain==0,"wait-release safe state");
            last_clear=clear;last_mode=mode;last_gain=gain;monitor_valid=1;
        end
    end
    task clocks(input integer n);
        repeat(n)begin @(posedge clk);#2;end
    endtask
    task sample;
        begin
            @(negedge clk);tick=1;@(posedge clk);#2;
            @(negedge clk);tick=0;#2;
        end
    endtask
    task samples(input integer n);
        begin integer m;for(m=0;m<n;m=m+1)sample;end
    endtask
    task key_level(input [15:0] value,input bad);
        begin @(negedge clk);keys=value;ghost=bad;clocks(1);end
    endtask
    task external_command(input en,input ex,input cv,input [5:0] value,input sw);
        begin
            @(negedge clk);enter=en;exit_test=ex;count_valid=cv;count=value;sweep_start=sw;
            clocks(1);@(negedge clk);enter=0;exit_test=0;count_valid=0;sweep_start=0;#2;
        end
    endtask
    task reset_all;
        begin
            @(negedge clk);rst_n=0;tick=0;keys=0;ghost=0;source=0;
            enter=0;exit_test=0;count_valid=0;count=0;sweep_start=0;
            clocks(4);@(negedge clk);rst_n=1;clocks(2);
        end
    endtask
    task finish_ramp(input [3:0] from_state,input [3:0] to_state,input integer direction);
        integer start_gain,steps,m,d,expected;
        begin
            check(state==from_state,"ramp starts in expected phase");
            start_gain=gain;steps=direction>0?256-start_gain:start_gain;
            if(steps==0)begin clocks(1);check(state==to_state,"zero gain cancellation");end
            else for(m=0;m<steps;m=m+1)for(d=1;d<=DIV;d=d+1)begin
                sample;expected=start_gain+direction*m+(d==DIV?direction:0);
                check(gain==expected,"exact gain divider/step");
                check(state==((m==steps-1 && d==DIV)?to_state:from_state),"exact ramp phase boundary");
            end
        end
    endtask
    task enter_active;
        begin
            external_command(1,0,0,0,0);
            check(state==1 && gain==256 && !mode && !lo_owned,"external entry needs no old chord/tick");
            finish_ramp(1,2,-1);
            check(mode&&clear&&gates==32'hffffffff&&requested==32&&clears==1,"default32 at zero-clear entry");
            finish_ramp(2,3,1);clocks(2);
        end
    endtask
    task recover;
        begin
            check(state==5,"recovery starts at WAIT_RELEASE");
            key_level(0,0);check(state==6,"release restores normal input");
            finish_ramp(6,0,1);check(!owned && clears>=1,"ownership returned after full fade");
        end
    endtask
    function [5:0] value_for(input integer number);
        case(number)0:value_for=1;1:value_for=4;2:value_for=8;3:value_for=16;default:value_for=32;endcase
    endfunction
    function [31:0] prefix(input [5:0] number);
        prefix=32'hffffffff>>(32-number);
    endfunction
    integer i,j;
    reg [31:0] old_gates;
    initial begin
        reset_all;
        external_command(0,1,1,1,1);check(state==0&&!owned,"controls ignored in NORMAL");
        external_command(1,1,0,0,0);check(state==0,"simultaneous exit vetoes entry");
        @(negedge clk);keys=16'h8000;enter=1;clocks(1);
        check(state==0,"legacy exit edge vetoes simultaneous external entry");
        @(negedge clk);enter=0;keys=0;clocks(2);
        external_command(1,0,0,0,0);clocks(23);
        check(state==1&&gain==256&&!mode,"entry acquired but ramp waits sample ticks");
        external_command(0,0,1,1,1);finish_ramp(1,2,-1);
        check(requested==32 && gates==32'hffffffff,"preparation commands are not queued");
        external_command(0,0,1,4,1);key_level(16'h0001,0);
        finish_ramp(2,3,1);
        external_command(0,0,1,4,0);check(requested==32,"unarmed ACTIVE ignores external count");
        key_level(0,1);key_level(16'h0001,0);
        external_command(0,0,1,8,1);check(requested==32&&!sweep,"ghost release cannot arm controls");
        key_level(0,0);
        for(i=0;i<5;i=i+1)begin
            external_command(0,0,1,value_for(i),0);
            check(requested==value_for(i)&&gates==prefix(value_for(i))&&!sweep,"valid external count/mask");
        end
        for(i=0;i<64;i=i+1)if(i!=1 && i!=4 && i!=8 && i!=16 && i!=32)begin
            external_command(0,0,1,i,0);
            check(requested==32&&gates==32'hffffffff&&!sweep,"invalid six-bit count ignored");
        end
        external_command(1,0,0,0,0);check(state==3 && gain==256,"ACTIVE cannot re-enter");
        external_command(0,0,0,0,1);
        for(i=0;i<32;i=i+1)begin
            check(sweep&&index==i&&gates==(32'hffffffff^(32'h1<<i))&&requested==32,"OFF each independent gate");
            for(j=1;j<HALF;j=j+1)begin sample;check(sweep&&gates==(32'hffffffff^(32'h1<<i)),"full OFF half");end
            sample;check(sweep&&index==i&&gates==32'hffffffff,"ON boundary");
            for(j=1;j<HALF;j=j+1)begin sample;check(sweep&&index==i&&gates==32'hffffffff,"full ON half");end
            sample;
        end
        check(!sweep&&index==31&&gates==32'hffffffff,"sweep finishes once without wrapping");
        external_command(0,0,0,0,1);samples(2);external_command(0,0,1,8,0);
        check(!sweep&&requested==8&&gates==255,"count cancels sweep");
        external_command(0,0,1,32,0);check(!sweep&&gates==32'hffffffff,"full32 cancels sweep");
        external_command(0,0,1,4,1);check(!sweep&&requested==4&&gates==15,"count wins simultaneous sweep");
        key_level(16'h0040,0);old_gates=gates;
        external_command(0,1,1,1,1);
        check(state==4&&gain==256&&gates==old_gates&&!sweep,"exit priority preserves frozen gates");
        sample;external_command(0,1,0,0,0);sample;
        check(gain==255,"repeated exit does not reset ramp divider");
        finish_ramp(4,5,-1);check(clears==2,"entry/exit clear exactly once each");
        clocks(10);check(state==5,"legacy held key still blocks recovery");recover;

        // Abort immediately before entering TEST_IN at the last fade tick.
        reset_all;external_command(1,0,0,0,0);samples(256*DIV-1);
        check(state==1&&gain==1&&!mode,"pre-entry final boundary");
        @(negedge clk);exit_test=1;tick=1;@(posedge clk);#2;
        check(state==4&&gain==1&&!mode&&!clear,"exit outranks test selection at zero boundary");
        @(negedge clk);exit_test=0;tick=0;keys=16'h0040;
        finish_ramp(4,5,-1);check(clears==1&&!mode,"aborted preparation never selected test");recover;
        // Abort exactly at zero TEST_IN; separate clear pulses must not merge.
        reset_all;external_command(1,0,0,0,0);finish_ramp(1,2,-1);
        external_command(0,1,0,0,0);check(state==4&&gain==0&&!clear,"zero-test-in abort starts safe exit");
        key_level(16'h0040,0);check(state==5&&!mode&&clears==2,"zero abort clears on separate clock");
        recover;
        // New external exit also cancels the NORMAL_IN ramp (same as S16).
        reset_all;enter_active;key_level(16'h0040,0);external_command(0,1,0,0,0);
        finish_ramp(4,5,-1);key_level(0,0);samples(19*DIV);
        check(state==6&&gain==19,"partial normal restoration");
        key_level(16'h0040,0);external_command(0,1,0,0,0);
        check(state==4&&gain==19,"external exit cancels restoration");finish_ramp(4,5,-1);recover;
        // Source handoff cannot bypass the original bounded exit path.
        for(i=0;i<2;i=i+1)begin
            reset_all;@(negedge clk);source=i!=0;enter_active;
            key_level(16'h0040,0);@(negedge clk);source=i==0;clocks(1);
            check(state==4,"source change exits externally entered test");
            finish_ramp(4,5,-1);recover;
        end
        reset_all;external_command(1,0,0,0,0);samples(7*DIV);
        key_level(16'h0040,0);@(negedge clk);source=1;clocks(1);
        check(state==4&&gain==249&&!mode,"source change aborts external preparation");
        finish_ramp(4,5,-1);recover;
        // Invalid external values must not refresh the exact sample-clock timeout.
        reset_all;enter_active;key_level(16'h0040,0);samples(IDLE-1);clocks(50);
        external_command(0,0,1,3,0);check(state==3,"invalid command is not early timeout");
        sample;check(state==4,"invalid command cannot keep test alive");finish_ramp(4,5,-1);recover;
        // A legitimate count at the deadline wins, then sweep itself cannot keep alive.
        reset_all;enter_active;samples(IDLE-1);
        @(negedge clk);tick=1;count_valid=1;count=1;@(posedge clk);#2;
        check(state==3&&requested==1,"valid external count wins timeout deadline");
        @(negedge clk);tick=0;count_valid=0;
        external_command(0,0,0,0,1);key_level(16'h0040,0);samples(IDLE-1);
        check(state==3&&!sweep,"automatic sweep cannot alter timeout");sample;
        check(state==4,"sweep completion is not keepalive");finish_ramp(4,5,-1);recover;
        // Both legacy default instances must still complete the original entry path.
        reset_all;key_level(16'h5000,0);samples(HOLD-1);
        check(!owned&&!lo_owned,"legacy entry still requires full hold");sample;
        check(state==1&&lo_owned&&ld_owned,"legacy hold threshold preserved");
        finish_ramp(1,2,-1);finish_ramp(2,3,1);key_level(0,0);key_level(16'h0004,0);
        check(requested==8&&lo_count==8&&ld_count==8,"legacy count path preserved");
        key_level(0,0);key_level(16'h8000,0);finish_ramp(4,5,-1);recover;
        check(legacy_active_observations>0,"default equivalence covered ACTIVE, not only NORMAL");
        $display("V035_PANEL_ENGINE_PASS checks=%0d observed=%0d legacy_active=%0d safety_fades=1 invalid_counts=1 timeout=1 legacy_default=1",
                 checks,observations,legacy_active_observations);
        $finish;
    end
    initial begin #10000000;$fatal(1,"panel engine watchdog");end
endmodule
