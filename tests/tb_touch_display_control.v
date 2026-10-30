`timescale 1ns/1ps
// The real legacy test controller is connected, including its full gain ramps.
// Note isolation belongs to the parent's top/input integration regression.
module tb_touch_display_control;
    parameter integer TEST_HOLD=4;
    localparam integer LIMIT=TEST_HOLD<1 ? 1 : TEST_HOLD;
    reg clk=0,rst_n=0,sample_tick=0,ghost=0;
    reg [15:0] keys=0;
    always #5 clk=~clk;
    wire [1:0] page,cursor,song_id,control_page;
    wire song_start,song_toggle,song_restart,key_pause,panic_pulse,strum_mode,fx_cycle;
    wire timbre_set_valid,filter_enable,zero_mode;
    wire [3:0] timbre_set_value;
    wire [15:0] test_keys;
    wire owned,test_mode,sweep;
    wire [31:0] gates;
    wire [5:0] requested;
    wire [3:0] state;
    reg force_owned=0;
    touch_display_control #(.HOLD_SAMPLES(TEST_HOLD)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.keys(keys),.ghost(ghost),
        .test_owned(owned || force_owned),.page(page),.cursor(cursor),.song_id(song_id),
        .song_start(song_start),.song_toggle(song_toggle),.song_restart(song_restart),
        .key_pause(key_pause),.test_keys(test_keys),.panic_pulse(panic_pulse),.strum_mode(strum_mode),
        .control_page(control_page),.fx_cycle(fx_cycle),.timbre_set_valid(timbre_set_valid),
        .timbre_set_value(timbre_set_value),.filter_enable(filter_enable),.zero_mode(zero_mode));
    oscillator_test_control #(.HOLD_SAMPLES(8),.MAX_SAMPLES(4000),.SWEEP_HALF_SAMPLES(4),.RAMP_DIV(1)) legacy(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .keys((panic_pulse && owned) ? 16'h8000 : test_keys),.ghost(ghost),.remote_active(1'b0),
        .owned(owned),.test_mode(test_mode),.gate_mask(gates),.requested_count(requested),
        .sweep_active(sweep),.state_debug(state));
    wire [5:0] pulses={song_start,song_toggle,song_restart,panic_pulse,fx_cycle,timbre_set_valid};
    reg [5:0] previous_pulses=0;
    integer checks=0,events=0,i,n,panic_events=0,saved_panic_count;
    reg [18:0] saved;
    wire [18:0] ui_state={page,cursor,song_id,control_page,strum_mode,filter_enable,zero_mode,timbre_set_value,4'd0};
    always @(posedge clk)begin
        #1;
        if(rst_n)begin
            checks=checks+1;
            if((pulses & previous_pulses)!=0)$fatal(1,"Pulse lasted longer than one clk");
            if((owned || force_owned) && (pulses & 6'b111011)!=0)$fatal(1,"Diagnostic ownership leaked UI command");
            if(pulses!=0)events=events+1;
            if(panic_pulse)panic_events=panic_events+1;
            previous_pulses=pulses;
        end else previous_pulses=0;
    end
    task step;
        input [15:0] k;input g,t;
        begin @(negedge clk);keys=k;ghost=g;sample_tick=t;@(posedge clk);#2;end
    endtask
    task reset;
        begin
            @(negedge clk);rst_n=0;keys=0;ghost=0;force_owned=0;sample_tick=0;
            repeat(3)@(posedge clk);
            @(negedge clk);rst_n=1;step(0,0,0);step(0,0,0);
            if(page!=0 || cursor!=0 || control_page!=0 || strum_mode || !filter_enable || zero_mode || test_keys!=0)
                $fatal(1,"Reset defaults");
        end
    endtask
    task click;
        input integer key;
        input [5:0] expected;
        begin
            step(16'd1<<(key-1),0,0);
            if(key!=13 && pulses!=0)$fatal(1,"Key %0d committed before release",key);
            repeat(5)begin step(16'd1<<(key-1),0,0);if(pulses!=0)$fatal(1,"Held key repeats");end
            step(0,0,0);
            if(pulses!==expected)$fatal(1,"S%0d release got=%b expected=%b",key,pulses,expected);
            step(0,0,0);if(pulses!=0)$fatal(1,"Idle repeated release command");
        end
    endtask
    task wait_state;
        input [3:0] target;
        begin
            n=0;
            while(state!=target && n<1400)begin step(keys,0,1);n=n+1;end
            if(state!=target)$fatal(1,"Legacy state stuck actual=%d expected=%d",state,target);
        end
    endtask
    initial begin
        reset;
        click(1,0);if(cursor!=2)$fatal(1,"Previous wrap");
        click(2,0);if(cursor!=0)$fatal(1,"Next wrap");
        click(2,0);click(3,0);if(control_page!=1)$fatal(1,"ADSR selection");
        click(4,0);if(control_page!=0)$fatal(1,"Parameter back");
        click(5,0);if(page!=3)$fatal(1,"Previous page wrap");
        click(6,0);if(page!=0)$fatal(1,"Next page wrap");
        click(6,0);click(2,0);click(3,6'b100000);
        if(page!=0 || song_id!=1)$fatal(1,"Song selection/start");
        click(6,0);if(cursor!=1)$fatal(1,"Library remembers selected song");
        click(4,0);if(page!=0)$fatal(1,"Library back");
        click(7,6'b010000);click(8,6'b001000);
        click(9,6'b000001);if(timbre_set_value!=0)$fatal(1,"Flute ID");
        click(10,6'b000001);if(timbre_set_value!=1)$fatal(1,"Pluck ID");
        click(11,0);if(!strum_mode)$fatal(1,"Strum toggle");
        click(11,0);if(strum_mode)$fatal(1,"Keyboard toggle");
        click(12,6'b000010);
        step(16'h1000,0,0);if(!panic_pulse)$fatal(1,"Panic is not immediate");
        repeat(20)begin step(16'h1000,0,1);if(panic_pulse)$fatal(1,"Panic repeated");end
        step(0,0,0);if(pulses!=0)$fatal(1,"Panic repeated on release");
        // Short touch counts zero sample enables, so even HOLD=1 has a short case.
        click(14,0);if(filter_enable || zero_mode)$fatal(1,"Short filter toggle");
        for(i=0;i<LIMIT-1;i=i+1)step(16'h2000,0,1);
        if(LIMIT>1)begin step(0,0,0);if(!filter_enable || zero_mode)$fatal(1,"Below long threshold");end
        for(i=0;i<LIMIT;i=i+1)step(16'h2000,0,1);
        if(zero_mode)$fatal(1,"Zero committed while held");
        repeat(9)step(16'h2000,0,1);
        step(0,0,0);if(!zero_mode || (LIMIT>1 && !filter_enable))$fatal(1,"Long zero/filter overlap");
        step(0,0,0);
        click(15,0); // no sample enables: only maps the entry level, no UI side effect.
        click(6,0);click(16,0);if(page!=0)$fatal(1,"S16 back");

        // Every key is tested under ghost and under a multi-key gesture. No UI
        // commands may be fabricated when ghost clears while the key stays held.
        for(i=0;i<16;i=i+1)begin
            saved=ui_state;
            step(16'd1<<i,1,1);if(pulses!=0 || test_keys!=0)$fatal(1,"Ghost key action");
            step(16'd1<<i,0,1);step(0,0,0);
            if(ui_state!==saved || pulses!=0)$fatal(1,"Ghost recovery forged action S%0d",i+1);
            step(0,0,0);
            step(16'hffff,0,1);step(16'd1<<i,0,1);step(0,0,0);
            if(ui_state!==saved || pulses!=0)$fatal(1,"Chord degraded into action S%0d",i+1);
            step(0,0,0);
        end
        step(16'h0002,0,0);step(16'h0004,0,0);step(0,0,0);
        if(cursor!=0 || song_start)$fatal(1,"Key substitution committed");
        step(0,0,0);

        // Force ownership over ALL 16 keys to verify persistent state and pulses.
        force_owned=1;step(0,0,0);saved=ui_state;
        for(i=0;i<16;i=i+1)begin
            step(16'd1<<i,0,0);
            if(i==12 && !panic_pulse)$fatal(1,"Owned panic must fire immediately");
            if(i==12)begin
                repeat(12)begin step(16'h1000,0,1);if(panic_pulse)$fatal(1,"Owned panic repeated");end
            end
            if(test_keys!==((i<6 || i==15)?(16'd1<<i):16'd0))$fatal(1,"Owned routing S%0d",i+1);
            step(0,0,0);
            if(ui_state!==saved || pulses!=0)$fatal(1,"Owned UI state pollution");
        end
        step(16'h0002,1,0);step(16'h0002,0,0);
        if(test_keys!=0)$fatal(1,"Owned ghost recovery created test command");
        step(0,0,0);step(16'h0002,0,0);force_owned=0;
        step(16'h0002,0,0);step(0,0,0);step(0,0,0);
        if(ui_state!==saved)$fatal(1,"Ownership exit committed stale key");
        reset;

        // Real entry mapping, two gain ramps, all six test commands, S16 exit,
        // then a fresh normal command: no deadlock or stale release action.
        step(16'h4000,0,0);if(test_keys!==16'h5000)$fatal(1,"Entry mapping");
        repeat(7)step(16'h4000,0,1);
        if(owned)$fatal(1,"Entry before eight sample enables");
        step(16'h4000,0,1);step(16'h4000,0,0);
        if(!owned || test_keys!=0)$fatal(1,"Entry did not acquire/release chord");
        step(0,0,1);wait_state(3);step(0,0,1);saved=ui_state;
        for(i=0;i<6;i=i+1)begin
            step(16'd1<<i,0,0);step(16'd1<<i,0,0);
            case(i)
                0:if(requested!=1)$fatal(1,"Test1");
                1:if(requested!=4)$fatal(1,"Test4");
                2:if(requested!=8)$fatal(1,"Test8");
                3:if(requested!=16)$fatal(1,"Test16");
                4:if(requested!=32)$fatal(1,"Test32");
                5:if(!sweep)$fatal(1,"Sweep");
            endcase
            step(0,0,1);step(0,0,1);
            if(ui_state!==saved)$fatal(1,"Test changed UI");
        end
        step(16'h8000,0,1);step(16'h8000,0,1);wait_state(5);
        repeat(10)step(16'h8000,0,1);
        if(!owned)$fatal(1,"Returned before clean release");
        step(0,0,1);wait_state(0);step(0,0,1);step(0,0,1);
        click(6,0);if(page!=1)$fatal(1,"UI locked after diagnostic exit");
        // Exit can also interrupt entry fade without waiting for ACTIVE.
        reset;step(16'h4000,0,0);repeat(8)step(16'h4000,0,1);
        step(0,0,1);step(16'h8000,0,1);step(16'h8000,0,1);wait_state(5);
        step(0,0,1);wait_state(0);step(0,0,1);step(0,0,1);
        click(7,6'b010000);
        // Model the parent's private S16 override on safety panic, in ACTIVE.
        reset;step(16'h4000,0,0);repeat(8)step(16'h4000,0,1);
        step(0,0,1);wait_state(3);step(0,0,1);
        step(16'h1000,0,0);if(!panic_pulse)$fatal(1,"ACTIVE panic suppressed");
        step(16'h1000,0,1);if(panic_pulse)$fatal(1,"ACTIVE panic wider than one clk");
        saved_panic_count=panic_events;
        wait_state(5);wait_state(0); // 保持S13，跨过整个所有权下降沿也不能重复发Panic。
        repeat(10)begin step(16'h1000,0,1);if(panic_pulse)$fatal(1,"Exit ownership repeated panic");end
        if(panic_events!=saved_panic_count)$fatal(1,"Ownership change retriggered held panic");
        step(0,0,1);step(0,0,1);
        click(7,6'b010000);
        // 在刚进入的淡出阶段，也必须能立即Panic并提前退出。
        reset;step(16'h4000,0,0);repeat(8)step(16'h4000,0,1);step(0,0,1);
        step(16'h1000,0,0);if(!owned || !panic_pulse)$fatal(1,"Entry fade panic suppressed");
        step(16'h1000,0,1);wait_state(0);step(0,0,1);step(0,0,1);
        click(7,6'b010000);
        $display("TOUCH_DISPLAY_CONTROL_TEST_PASS hold=%0d checks=%0d events=%0d all16 ghost hold test_entry_exit",TEST_HOLD,checks,events);
        $finish;
    end
    initial begin #100000000;$fatal(1,"Touch display timeout");end
endmodule
