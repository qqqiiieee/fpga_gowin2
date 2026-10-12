`timescale 1ns/1ps
// keypad_tests.py derives this include from the actual CST and fixed physical
// wiring (R1=T11, R2=M14, R3=T12, R4=J14). No logical row swap in the model.
`include "keypad_cst_map.vh"
module tb_keypad_physical_map;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, suppress=0, virtual_enable=0;
    reg [15:0] physical_pressed=0, virtual_keys=0;
    wire [3:0] rows, two_rows, release_rows, legacy_rows, press_rows;
    reg [3:0] cols;
    wire plain_on, plain_off, two_on, two_off, release_on, release_off;
    wire legacy_on, legacy_off, press_on, press_off;
    wire [6:0] plain_note, two_note, release_note, legacy_note, press_note;
    wire [7:0] plain_vel, two_vel, release_vel;
    wire [3:0] plain_timbre, two_timbre, release_timbre;
    wire [3:0] chosen, release_chosen, legacy_chosen, press_chosen;
    wire [3:0] legacy_timbre, press_timbre;
    wire [15:0] plain_state, two_state, release_state;
    wire ghost, two_ghost, release_ghost;

    // Omitted mode parameters exercise the complete original 16-note default.
    matrix_keypad #(.ROW_CYCLES(10), .DEBOUNCE_FRAMES(3)) plain(
        .clk(clk), .rst_n(rst_n), .suppress_select(suppress), .rows(rows), .cols(cols),
        .virtual_enable(virtual_enable), .virtual_keys(virtual_keys), .velocity(8'd173),
        .note_on(plain_on), .note_off(plain_off), .note(plain_note), .vel_out(plain_vel),
        .timbre_out(plain_timbre), .key_state(plain_state), .ghost_active(ghost));
    // SELECT_ON_RELEASE is deliberately omitted: TWO_BUTTON_SELECT must enforce release.
    matrix_keypad #(.ROW_CYCLES(10), .DEBOUNCE_FRAMES(3),
        .PERFORMANCE_MODE(1), .TWO_BUTTON_SELECT(1)) two(
        .clk(clk), .rst_n(rst_n), .suppress_select(suppress), .rows(two_rows), .cols(cols),
        .virtual_enable(virtual_enable), .virtual_keys(virtual_keys), .velocity(8'd173),
        .note_on(two_on), .note_off(two_off), .note(two_note), .vel_out(two_vel),
        .timbre_out(two_timbre), .key_state(two_state), .ghost_active(two_ghost),
        .selected_timbre(chosen));
    matrix_keypad #(.ROW_CYCLES(10), .DEBOUNCE_FRAMES(3),
        .PERFORMANCE_MODE(1), .SELECT_ON_RELEASE(1), .TWO_BUTTON_SELECT(1)) released(
        .clk(clk), .rst_n(rst_n), .suppress_select(suppress), .rows(release_rows), .cols(cols),
        .virtual_enable(virtual_enable), .virtual_keys(virtual_keys), .velocity(8'd173),
        .note_on(release_on), .note_off(release_off), .note(release_note), .vel_out(release_vel),
        .timbre_out(release_timbre), .key_state(release_state), .ghost_active(release_ghost),
        .selected_timbre(release_chosen));
    // Default TWO_BUTTON_SELECT remains omitted in both historical modes.
    matrix_keypad #(.ROW_CYCLES(10), .DEBOUNCE_FRAMES(3),
        .PERFORMANCE_MODE(1), .SELECT_ON_RELEASE(1)) legacy_release(
        .clk(clk), .rst_n(rst_n), .suppress_select(suppress), .rows(legacy_rows), .cols(cols),
        .virtual_enable(virtual_enable), .virtual_keys(virtual_keys), .velocity(8'd173),
        .note_on(legacy_on), .note_off(legacy_off), .note(legacy_note),
        .timbre_out(legacy_timbre), .selected_timbre(legacy_chosen));
    matrix_keypad #(.ROW_CYCLES(10), .DEBOUNCE_FRAMES(3), .PERFORMANCE_MODE(1)) legacy_press(
        .clk(clk), .rst_n(rst_n), .suppress_select(suppress), .rows(press_rows), .cols(cols),
        .virtual_enable(virtual_enable), .virtual_keys(virtual_keys), .velocity(8'd173),
        .note_on(press_on), .note_off(press_off), .note(press_note),
        .timbre_out(press_timbre), .selected_timbre(press_chosen));

    // Fixed physical wires route through CST-derived logical indices, including
    // columns. Flood-fill the passive switch network, allowing real ghost paths.
    function integer physical_row_logical;
        input integer row;
        begin case(row)
            0:physical_row_logical=`CST_PHYSICAL_R1;
            1:physical_row_logical=`CST_PHYSICAL_R2;
            2:physical_row_logical=`CST_PHYSICAL_R3;
            default:physical_row_logical=`CST_PHYSICAL_R4;
        endcase end
    endfunction
    function integer physical_col_logical;
        input integer col;
        begin case(col)
            0:physical_col_logical=`CST_PHYSICAL_C1;
            1:physical_col_logical=`CST_PHYSICAL_C2;
            2:physical_col_logical=`CST_PHYSICAL_C3;
            default:physical_col_logical=`CST_PHYSICAL_C4;
        endcase end
    endfunction
    reg [3:0] reached_rows, reached_cols;
    integer pass, r, c;
    always @(*) begin
        reached_rows=0; reached_cols=0;
        for(r=0;r<4;r=r+1)
            if(rows[physical_row_logical(r)]===1'b0) reached_rows[r]=1;
        for(pass=0;pass<8;pass=pass+1)
            for(r=0;r<4;r=r+1)
                for(c=0;c<4;c=c+1)
                    if(physical_pressed[r*4+c]) begin
                        if(reached_rows[r]) reached_cols[c]=1;
                        if(reached_cols[c]) reached_rows[r]=1;
                    end
        cols=4'hf;
        for(c=0;c<4;c=c+1) cols[physical_col_logical(c)]=!reached_cols[c];
    end

    function integer midi;
        input integer key;
        begin case(key)
            0:midi=60; 1:midi=62; 2:midi=64; 3:midi=65;
            4:midi=67; 5:midi=69; 6:midi=71; 7:midi=72;
            8:midi=74; 9:midi=76; 10:midi=77; 11:midi=79;
            12:midi=81; 13:midi=83; 14:midi=84; 15:midi=86;
        endcase end
    endfunction
    function integer note_key;
        input integer pitch;
        integer n;
        begin
            note_key=-1;
            for(n=0;n<16;n=n+1) if(midi(n)==pitch) note_key=n;
        end
    endfunction
    integer on_count[0:15], off_count[0:15], two_on_count[0:15], two_off_count[0:15];
    integer expected_on[0:15], expected_off[0:15];
    integer monitor_key, m;
    reg probe=0, probe_off=0, probe_press=0;
    reg [3:0] probe_two_timbre=0, probe_legacy_timbre=0, probe_press_timbre=0;
    reg [3:0] choice_before_edge;
    integer probe_seen=0, same_edge_seen=0;
    always @(posedge clk) begin
        choice_before_edge=chosen;
        #1;
        if(!rst_n) begin
            for(m=0;m<16;m=m+1) begin
                on_count[m]=0; off_count[m]=0; two_on_count[m]=0; two_off_count[m]=0;
            end
        end else begin
            if(rows!==two_rows || rows!==release_rows || rows!==legacy_rows || rows!==press_rows)
                $fatal(1,"scan drivers differ across parameter modes");
            if(two_state!==release_state || two_ghost!==release_ghost ||
               two_on!==release_on || two_off!==release_off || two_note!==release_note ||
               two_vel!==release_vel || two_timbre!==release_timbre || chosen!==release_chosen)
                $fatal(1,"TWO_BUTTON_SELECT depends on SELECT_ON_RELEASE");
            if(plain_on && plain_off || two_on && two_off) $fatal(1,"on/off pulses collided");
            if(plain_on || plain_off) begin
                monitor_key=note_key(plain_note);
                if(monitor_key<0) $fatal(1,"unexpected ordinary note %0d",plain_note);
                if(plain_vel!==173 || plain_timbre!==monitor_key)
                    $fatal(1,"ordinary event velocity/key timbre mismatch");
                if(plain_on) on_count[monitor_key]=on_count[monitor_key]+1;
                if(plain_off) off_count[monitor_key]=off_count[monitor_key]+1;
            end
            if(two_on || two_off) begin
                monitor_key=note_key(two_note);
                if(monitor_key<0 || monitor_key>=12) $fatal(1,"control emitted pitch event");
                if(two_vel!==173) $fatal(1,"performance velocity mismatch");
                if(two_on) two_on_count[monitor_key]=two_on_count[monitor_key]+1;
                if(two_off) two_off_count[monitor_key]=two_off_count[monitor_key]+1;
            end
            if(probe && (probe_off?two_off:two_on)) begin
                if(two_note!==60 || two_timbre!==probe_two_timbre)
                    $fatal(1,"two-button bypass got %0d expected %0d",two_timbre,probe_two_timbre);
                if(!(probe_off?legacy_off:legacy_on) || legacy_note!==60 ||
                   legacy_timbre!==probe_legacy_timbre)
                    $fatal(1,"legacy release bypass got %0d expected %0d",legacy_timbre,probe_legacy_timbre);
                if(probe_press && (!(probe_off?press_off:press_on) || press_note!==60 ||
                   press_timbre!==probe_press_timbre))
                    $fatal(1,"legacy press bypass got %0d expected %0d",press_timbre,probe_press_timbre);
                probe_seen=probe_seen+1;
                if(choice_before_edge!==chosen) same_edge_seen=same_edge_seen+1;
            end
        end
    end

    task cycles;
        input integer n;
        integer j;
        begin for(j=0;j<n;j=j+1) @(negedge clk); end
    endtask
    task frame_start;
        begin
            @(negedge clk);
            while(!(plain.row_index==0 && plain.row_timer==0)) @(negedge clk);
        end
    endtask
    reg [15:0] expected_state=0;
    task check_state_events;
        input [15:0] target;
        integer key;
        begin
            for(key=0;key<16;key=key+1) begin
                if(target[key] && !expected_state[key]) expected_on[key]=expected_on[key]+1;
                if(!target[key] && expected_state[key]) expected_off[key]=expected_off[key]+1;
                if(on_count[key]!=expected_on[key] || off_count[key]!=expected_off[key])
                    $fatal(1,"S%0d event counts on=%0d/%0d off=%0d/%0d",key+1,
                        on_count[key],expected_on[key],off_count[key],expected_off[key]);
                if(key<12 && (two_on_count[key]!=expected_on[key] || two_off_count[key]!=expected_off[key]))
                    $fatal(1,"S%0d performance event mismatch",key+1);
            end
            if(plain_state!==target || two_state!==target)
                $fatal(1,"physical/virtual state got %h/%h expected %h",plain_state,two_state,target);
            expected_state=target;
        end
    endtask
    task drive;
        input [15:0] mask, target;
        begin
            frame_start;
            if(virtual_enable) virtual_keys=mask; else physical_pressed=mask;
            cycles(320);
            check_state_events(target);
        end
    endtask
    task reset_all;
        integer key;
        begin
            rst_n=0; physical_pressed=0; virtual_keys=0; virtual_enable=0; suppress=0;
            probe=0; probe_press=0; probe_off=0; probe_seen=0; same_edge_seen=0;
            expected_state=0;
            for(key=0;key<16;key=key+1) begin expected_on[key]=0; expected_off[key]=0; end
            cycles(5); rst_n=1; cycles(320);
            check_state_events(0);
            if(chosen!==0 || legacy_chosen!==0 || press_chosen!==0) $fatal(1,"reset timbre");
        end
    endtask
    task choice;
        input [3:0] expected;
        begin if(chosen!==expected) $fatal(1,"choice %0d expected %0d",chosen,expected); end
    endtask
    task select_tap;
        input [15:0] mask;
        input [3:0] expected;
        reg [3:0] before_choice;
        begin
            before_choice=chosen;
            drive(mask,mask); choice(before_choice);
            cycles(700); check_state_events(mask); choice(before_choice);
            drive(0,0); choice(expected);
            cycles(360); check_state_events(0); choice(expected);
        end
    endtask

    integer i,j,k,ra,rb,ca,cb,corner,pair_count=0,ghost_count=0;
    reg [15:0] mask, rectangle;
    reg [3:0] before_choice;
    initial begin
        reset_all;
        for(i=0;i<16;i=i+1) begin
            mask=16'h0001<<i;
            drive(mask,mask); cycles(400); check_state_events(mask); drive(0,0);
            $display("PASS physical S%0d -> bit%0d MIDI%0d press/release",i+1,i,midi(i));
        end
        $display("PASS all 16 CST-connected physical keys, including S5-S12");
        reset_all;
        virtual_enable=1;
        // An unrelated physically held S9 must be ignored in virtual mode.
        physical_pressed=16'h0100;
        for(i=0;i<16;i=i+1) begin mask=16'h0001<<i; drive(mask,mask); drive(0,0); end
        $display("PASS virtual bit0..15 unchanged and physical input overridden");
        reset_all;
        for(i=0;i<16;i=i+1) for(j=i+1;j<16;j=j+1) begin
            mask=(16'h0001<<i)|(16'h0001<<j);
            drive(mask,mask); drive(16'h0001<<j,16'h0001<<j); drive(0,0);
            pair_count=pair_count+1;
        end
        $display("PASS %0d physical two-key pairs and independent releases",pair_count);
        reset_all;
        // Every 2x2 rectangle, each possible missing physical corner. The model
        // electrically closes the fourth corner; no new notes may escape.
        for(ra=0;ra<4;ra=ra+1) for(rb=ra+1;rb<4;rb=rb+1)
            for(ca=0;ca<4;ca=ca+1) for(cb=ca+1;cb<4;cb=cb+1) begin
                rectangle=(16'h1<<(ra*4+ca))|(16'h1<<(ra*4+cb))|
                          (16'h1<<(rb*4+ca))|(16'h1<<(rb*4+cb));
                for(corner=0;corner<16;corner=corner+1) if(rectangle[corner]) begin
                    drive(rectangle & ~(16'h1<<corner),0);
                    if(!ghost || !two_ghost) $fatal(1,"real rectangle not detected %h",rectangle);
                    choice(0); drive(0,0); choice(0); ghost_count=ghost_count+1;
                end
            end
        $display("PASS %0d real three-corner ghost cases and recovery",ghost_count);
        drive(1,1); drive(16'h0131,1);
        if(!ghost) $fatal(1,"held note ghost missing");
        drive(16'h0130,0);
        if(!ghost) $fatal(1,"release while ghost lost test ambiguity");
        drive(0,0); drive(16'h0020,16'h0020); drive(0,0);
        $display("PASS confirmed key survives ghost and releases while ghost is active");
        reset_all;
        // Contact shorter than three frames never reaches confirmed key_state.
        frame_start; physical_pressed=16'h0010; cycles(55); physical_pressed=0;
        cycles(320); check_state_events(0);
        frame_start; physical_pressed=16'h1000; cycles(55); physical_pressed=0;
        cycles(320); check_state_events(0); choice(0);
        drive(16'h0010,16'h0010);
        frame_start; physical_pressed=0; cycles(55); physical_pressed=16'h0010;
        cycles(320); check_state_events(16'h0010); drive(0,0);
        $display("PASS press/release bounce and selector bounce rejected");
        reset_all;
        for(i=1;i<=16;i=i+1) select_tap(16'h2000,i%16);
        for(i=1;i<=16;i=i+1) select_tap(16'h1000,(16-i)%16);
        $display("PASS S14 forward/S13 backward all 16 timbres and both wrap directions");
        before_choice=chosen;
        select_tap(16'h4000,before_choice); select_tap(16'h8000,before_choice);
        for(i=1;i<16;i=i+1) if((i & (i-1))!=0) begin
            mask=i<<12; drive(mask,mask); choice(before_choice);
            // Every still-held single key must preserve cancellation.
            for(j=0;j<4;j=j+1) if(i & (1<<j)) begin
                drive(mask,mask); drive(16'h1000<<j,16'h1000<<j); choice(before_choice);
                drive(0,0); choice(before_choice); drive(mask,mask);
            end
            drive(0,0); choice(before_choice);
        end
        // All ordered selector/menu pairs arriving and departing separately.
        for(i=0;i<4;i=i+1) for(j=0;j<4;j=j+1) if(i!=j) begin
            drive(16'h1000<<i,16'h1000<<i); choice(before_choice);
            mask=(16'h1000<<i)|(16'h1000<<j); drive(mask,mask); choice(before_choice);
            drive(16'h1000<<j,16'h1000<<j); choice(before_choice);
            drive(0,0); choice(before_choice);
        end
        drive(16'h1000,16'h1000); drive(16'h2000,16'h2000); drive(0,0); choice(before_choice);
        select_tap(16'h2000,1);
        $display("PASS S15/S16, all multi-control subsets, staggered chords, direct replacement");
        reset_all;
        drive(16'h6000,16'h6000); drive(16'h6002,16'h6000);
        if(!ghost) $fatal(1,"selector/menu ghost missing");
        drive(16'h6000,16'h6000); drive(16'h2000,16'h2000); drive(0,0); choice(0);
        select_tap(16'h1000,15);
        $display("PASS ghost does not resurrect a canceled selector chord");
        reset_all;
        drive(1,1); drive(16'h2001,16'h2001); choice(0);
        drive(1,1); choice(1); drive(0,0);
        $display("PASS selector release keeps held note without retrigger");
        reset_all;
        suppress=1; drive(16'h2000,16'h2000); drive(0,0); choice(0);
        suppress=0; cycles(500); check_state_events(0); choice(0);
        suppress=1; drive(16'h1000,16'h1000); suppress=0; drive(0,0); choice(15);
        $display("PASS suppress freezes selection, retains scan/release tracking, no deferred replay");

        // Align changes to a complete scan so the note edge and selector release
        // debounce together. Inspect actual emitted events and same-edge output
        // change, rather than merely checking the eventual selected register.
        for(k=0;k<2;k=k+1) begin
            reset_all;
            drive(16'h2000,16'h2000);
            suppress=k; probe=1; probe_two_timbre=k?0:1; probe_legacy_timbre=k?0:4;
            drive(1,1); probe=0;
            if(probe_seen!=1 || (!k && same_edge_seen!=1)) $fatal(1,"same-edge note-on bypass not exercised");
            choice(k?0:1); drive(0,0);
            suppress=0; cycles(400); choice(k?0:1);
            reset_all;
            drive(16'h2001,16'h2001);
            suppress=k; probe=1; probe_off=1; probe_two_timbre=k?0:1; probe_legacy_timbre=k?0:4;
            drive(0,0); probe=0;
            if(probe_seen!=1 || (!k && same_edge_seen!=1)) $fatal(1,"same-edge note-off bypass not exercised");
            choice(k?0:1);
        end
        $display("PASS same-edge note on/off release bypass and suppressed real timbre (two/legacy)");
        for(k=0;k<2;k=k+1) begin
            reset_all; suppress=k; probe=1; probe_press=1;
            probe_two_timbre=0; probe_legacy_timbre=0; probe_press_timbre=k?0:4;
            drive(16'h2001,16'h2001); probe=0;
            if(probe_seen!=1 || press_chosen!==(k?4'd0:4'd4)) $fatal(1,"legacy same-edge press bypass missing");
            drive(0,0);
        end
        $display("PASS legacy press-mode same-edge bypass and suppress protection");
        $display("KEYPAD_PHYSICAL_MAP_TEST_PASS physical16 virtual16 pairs120 ghosts144 selectors32 bypass6");
        $finish;
    end
    initial begin #10000000; $fatal(1,"keypad physical test timeout"); end
endmodule
