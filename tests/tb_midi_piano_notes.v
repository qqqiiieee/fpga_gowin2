`timescale 1ns/1ps
// Read-only pitch audit. Drive the production 27 MHz / 31250 baud UART,
// production MIDI hub and production audio/phase RAM; never force DUT state.
module tb_piano_note_table;
    reg [6:0] note;
    wire [23:0] increment;
    integer n;
    note_table dut(.note(note), .phase_inc(increment));
    initial begin
        // A real transition to MIDI 0 avoids the initial-zero @* simulator trap.
        note=127; #1;
        for(n=0;n<128;n=n+1) begin
            note=n; #1;
            if((^increment)===1'bx) $fatal(1,"UNKNOWN_TABLE note=%0d",n);
            $display("PIANO_TABLE note=%0d increment=%0d",n,increment);
        end
        $display("PIANO_NOTE_TABLE_TEST_PASS count=128"); $finish;
    end
endmodule

module tb_midi_piano_notes;
    reg clk=0;
    always #18.518518519 clk=~clk;
    reg rst_n=0,rx=1;
    reg [3:0] selected_timbre=0;
    wire tick,note_on,note_off,panic_audio,overrun;
    wire [6:0] note;
    wire [7:0] velocity,volume;
    wire [3:0] timbre;
    wire [1:0] source;
    wire signed [8:0] pitch,monitor_pitch;
    wire [11:0] performance_keys;
    wire [31:0] busy;
    wire [15:0] pcm;
    performance_input_hub #(.MIDI_ENABLE(1),.OPTICAL_ENABLE(0),.CONTROL_BANK_ENABLE(1)) hub(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.allow_performance(1'b1),
        .suppress_controls(1'b0),.remote_active(1'b0),.digital_zero(1'b0),.midi_rx(rx),
        .optical_beams(2'b11),.local_on(1'b0),.local_off(1'b0),.local_note(7'd0),
        .local_velocity(8'd0),.local_timbre(4'd0),.selected_timbre(selected_timbre),
        .local_keys(16'd0),.physical_volume(8'd255),.physical_pitch(9'sd0),
        .note_on(note_on),.note_off(note_off),.note(note),.velocity(velocity),
        .timbre(timbre),.event_source(source),.volume(volume),.pitch(pitch),
        .panic_audio(panic_audio),.performance_keys(performance_keys),.pressure_vibrato(8'd0),
        .strum_mode(1'b0),.manual_panic(1'b0),.knob_volume_valid(1'b0),.knob_volume(8'd0));
    instrument_audio #(.NUM_VOICES(32),.REDUCED_TIMBRES(1),.SOURCE_TAG_ENABLE(1),
        .PHASE_RAM(1),.CONTROL_BANK_ENABLE(1),.LIVE_ADSR_ENABLE(1)) audio(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),
        .velocity(velocity),.timbre(timbre),.slider_volume(volume),.slider_pitch(pitch),
        .hit0(1'b0),.hit1(1'b0),.velocity0(8'd0),.velocity1(8'd0),
        .digital_zero_test(1'b0),.filter_enable(1'b0),.test_owned(1'b0),
        .test_mode(1'b0),.test_clear(panic_audio),.normal_input_ready(1'b1),
        .test_gate_mask(32'd0),.test_master_gain(9'd256),.overrun(overrun),
        .monitor_tick(tick),.monitor_pcm(pcm),.monitor_pitch(monitor_pitch),.monitor_busy(busy),
        .event_source(source),.pressure_brightness(8'd255),.pressure_brightness_ready(1'b0),
        .attack_ctrl(8'd0),.decay_ctrl(8'd0),.sustain_ctrl(8'd255),.release_ctrl(8'd0),
        .damping(8'd0),.mix_balance(8'd0),.hat_closed_hit(1'b0),.hat_open_hit(1'b0),
        .hat_closed_velocity(8'd0),.hat_open_velocity(8'd0),.fx_mode(2'd0),
        .fx_amount(8'd0),.fx_time(8'd0),.fx_feedback(8'd0),.fx_mod(8'd0));

    reg [23:0] expected_increment[0:127];
    integer expected_note[0:255],expected_velocity[0:255],expected_on[0:255];
    integer expected_count=0,seen_count=0,decoder_count=0,on_count=0,off_count=0;
    integer clocks=0,last_tick=-1,ticks=0,nonzero=0,phase_checks=0,pcm_files=0;
    integer event_index;
    // Observe BEFORE the handshake edge, exactly when the allocator consumes it.
    always @(posedge clk) begin
        clocks=clocks+1;
        if(!rst_n) last_tick=-1;
        else begin
            if(panic_audio || overrun || hub.m_error || hub.m_overflow)
                $fatal(1,"UNEXPECTED_UART_AUDIO_FAULT");
            if(tick) begin
                if(last_tick>=0 && clocks-last_tick!=288) $fatal(1,"BAD_SAMPLE_PERIOD");
                last_tick=clocks;ticks=ticks+1;
                if((^pcm)===1'bx) $fatal(1,"UNKNOWN_PCM");
                if(pcm!=0) nonzero=nonzero+1;
            end
            if(hub.m_valid && hub.m_ready) begin
                event_index=decoder_count;
                if(event_index>=expected_count) $fatal(1,"UNEXPECTED_DECODER_EVENT");
                if(hub.m_note!==expected_note[event_index] ||
                   hub.m_velocity!==expected_velocity[event_index] ||
                   hub.m_on!==expected_on[event_index] || hub.m_off===hub.m_on)
                    $fatal(1,"DECODER_NOTE_MISMATCH event=%0d got=%0d/%0d/%0d expected=%0d/%0d/%0d",
                        event_index,hub.m_note,hub.m_on,hub.m_velocity,
                        expected_note[event_index],expected_on[event_index],expected_velocity[event_index]);
                decoder_count=decoder_count+1;
            end
            if(note_on || note_off) begin
                event_index=seen_count;
                if(event_index>=expected_count) $fatal(1,"UNEXPECTED_AUDIO_EVENT");
                if(note!==expected_note[event_index] || velocity!==expected_velocity[event_index] ||
                   note_on!==expected_on[event_index] || note_off===note_on || source!==2'd1 ||
                   timbre!==selected_timbre || pitch!==0 || monitor_pitch!==0)
                    $fatal(1,"AUDIO_EVENT_MISMATCH event=%0d note=%0d velocity=%0d",event_index,note,velocity);
                $display("PIANO_EVENT index=%0d on=%0d note=%0d velocity=%0d timbre=%0d",event_index,note_on,note,velocity,timbre);
                seen_count=seen_count+1;
                if(note_on)on_count=on_count+1;else off_count=off_count+1;
            end
        end
    end
    task cycles;input integer count;begin repeat(count)@(negedge clk);end endtask
    task frames;input integer count;integer f;begin
        for(f=0;f<count;f=f+1)begin @(posedge tick);@(negedge clk);end
    end endtask
    task uart_byte;input [7:0] value;integer b;begin
        @(negedge clk);rx=0;cycles(864);
        for(b=0;b<8;b=b+1)begin rx=value[b];cycles(864);end
        rx=1;cycles(864);
    end endtask
    task expect_event;input integer n,v,is_on;begin
        expected_note[expected_count]=n;expected_velocity[expected_count]=v;
        expected_on[expected_count]=is_on;expected_count=expected_count+1;
    end endtask
    function integer expanded;input integer v;begin expanded=2*v+(v/64);end endfunction
    task message;input [7:0] status,a,b;begin
        uart_byte(status);uart_byte(a);uart_byte(b);cycles(300);
    end endtask
    task note_message;input integer n,v,is_on,use_status;begin
        expect_event(n,expanded(v),is_on && v!=0);
        if(use_status)uart_byte(is_on?8'h90:8'h80);
        uart_byte(n);uart_byte(v);cycles(300);
        if(seen_count!=expected_count || decoder_count!=expected_count)
            $fatal(1,"MISSING_EVENT expected=%0d decoder=%0d audio=%0d",expected_count,decoder_count,seen_count);
    end endtask
    function integer legacy_note;input integer i;begin case(i)
        0:legacy_note=60;1:legacy_note=62;2:legacy_note=64;3:legacy_note=65;
        4:legacy_note=67;5:legacy_note=69;6:legacy_note=71;7:legacy_note=72;
        8:legacy_note=74;9:legacy_note=76;10:legacy_note=77;11:legacy_note=79;
    endcase end endfunction
    reg [127:0] expected_held=0;
    task check_held_and_legacy;
        integer j;reg [11:0] mask;
        begin
            mask=0;for(j=0;j<12;j=j+1)mask[j]=expected_held[legacy_note(j)];
            if(hub.held!==expected_held) $fatal(1,"HELD_NOTES_MISMATCH got=%h expected=%h",hub.held,expected_held);
            if(performance_keys!==mask) $fatal(1,"LEGACY_DISPLAY_MISMATCH got=%h expected=%h",performance_keys,mask);
        end
    endtask
    integer found_slot,found_count;
    task find_note;input integer n;integer s;begin
        found_slot=-1;found_count=0;
        for(s=0;s<32;s=s+1)if(audio.gate[s] && audio.u_alloc.notes[s]==n)begin
            found_slot=s;found_count=found_count+1;
        end
        if(found_count!=1)$fatal(1,"VOICE_NOTE_MISMATCH note=%0d count=%0d",n,found_count);
        if(audio.u_alloc.sources[found_slot]!==2'd1 ||
           audio.u_alloc.timbres[found_slot]!==selected_timbre[0]) $fatal(1,"VOICE_SOURCE_TIMBRE");
    end endtask
    reg [23:0] phase_before[0:12];
    integer chord_slots[0:12],velocities[0:12];
    reg [23:0] delta;
    task check_chord_pitch;
        integer i;
        begin
            frames(32);
            // Same frame position, all 32 voices finished; read actual accumulator RAM.
            cycles(270);
            for(i=0;i<13;i=i+1)begin
                find_note(60+i);chord_slots[i]=found_slot;
                if(audio.u_alloc.velocities[found_slot]!==expanded(velocities[i]))$fatal(1,"VOICE_VELOCITY");
                phase_before[i]=audio.synth.phase_ram.ram[found_slot];
            end
            frames(32);cycles(270);
            for(i=0;i<13;i=i+1)begin
                delta=audio.synth.phase_ram.ram[chord_slots[i]]-phase_before[i];
                if(delta!==((expected_increment[60+i]*32)&24'hffffff))
                    $fatal(1,"DDS_NOTE_MISMATCH note=%0d delta=%0d expected_inc=%0d",60+i,delta,expected_increment[60+i]);
                if(i>0 && expected_increment[60+i]<=expected_increment[59+i])$fatal(1,"BAD_ORACLE");
                phase_checks=phase_checks+1;
                $display("PIANO_DDS note=%0d timbre=%0d velocity=%0d delta=%0d frames=32 increment=%0d",
                    60+i,selected_timbre,expanded(velocities[i]),delta,expected_increment[60+i]);
            end
            if(audio.gate!==32'h00001fff)$fatal(1,"CHORD_COLLAPSED gate=%h",audio.gate);
        end
    endtask
    task reset_case;begin
        rst_n=0;rx=1;cycles(10);rst_n=1;expected_held=0;cycles(400);
        if(audio.gate!==0 || hub.held!==0)$fatal(1,"RESET_NOT_EMPTY");
    end endtask
    integer capture_file,sample_i;
    task capture_solo;input integer n;reg [255:0] filename;
        begin
            reset_case;note_message(n,100,1,1);expected_held[n]=1;
            check_held_and_legacy;find_note(n);frames(256);
            filename="";$sformat(filename,"pcm_t%0d_n%0d.txt",selected_timbre,n);
            capture_file=$fopen(filename,"w");if(capture_file==0)$fatal(1,"PCM_OPEN_FAILED");
            for(sample_i=0;sample_i<4096;sample_i=sample_i+1)begin
                @(posedge clk);while(!tick)@(posedge clk);
                $fdisplay(capture_file,"%0d",$signed(pcm));@(negedge clk);
            end
            $fclose(capture_file);pcm_files=pcm_files+1;
            note_message(n,0,0,1);expected_held=0;check_held_and_legacy;
            frames(128);if(audio.gate!==0 || busy!==0)$fatal(1,"SOLO_RELEASE_STUCK");
            $display("PIANO_PCM_CAPTURE note=%0d timbre=%0d samples=4096",n,selected_timbre);
        end
    endtask
    integer t,n,base_seen;
    initial begin
        $readmemh("piano_expected.hex",expected_increment);
        velocities[0]=1;velocities[1]=2;velocities[2]=31;velocities[3]=32;
        velocities[4]=63;velocities[5]=64;velocities[6]=65;velocities[7]=80;
        velocities[8]=96;velocities[9]=110;velocities[10]=120;velocities[11]=126;velocities[12]=127;
        for(t=0;t<2;t=t+1)begin
            selected_timbre=t;reset_case;
            // C4..C5, including every black key, with running-status data pairs.
            for(n=60;n<=72;n=n+1)begin
                note_message(n,velocities[n-60],1,n==60);
                expected_held[n]=1;check_held_and_legacy;find_note(n);
            end
            base_seen=seen_count;check_chord_pitch;check_held_and_legacy;
            if(seen_count!=base_seen)$fatal(1,"HELD_NOTE_RETRIGGERED");
            // Release alternate keys using true Note Off and Note On velocity 0.
            for(n=60;n<=72;n=n+1)begin
                if(n%2==0)note_message(n,17,0,1);else note_message(n,0,1,1);
                expected_held[n]=0;check_held_and_legacy;
                if((audio.gate & (32'b1<<(n-60)))!=0)$fatal(1,"RELEASE_GATE_STUCK note=%0d",n);
            end
            frames(128);if(audio.gate!==0 || busy!==0)$fatal(1,"CHORD_RELEASE_STUCK");
            // Black C# still sounds with sustain even though physical held clears.
            note_message(61,64,1,1);expected_held[61]=1;check_held_and_legacy;
            message(8'hb0,64,127);base_seen=seen_count;
            message(8'h80,61,0);expected_held[61]=0;check_held_and_legacy;
            find_note(61);frames(32);
            if(seen_count!=base_seen)$fatal(1,"SUSTAIN_RELEASED_TOO_EARLY");
            expect_event(61,0,0);message(8'hb0,64,0);
            if(seen_count!=expected_count)$fatal(1,"PEDAL_UP_LOST_RELEASE");
            frames(128);if(audio.gate!==0 || busy!==0)$fatal(1,"PEDAL_RELEASE_STUCK");
            // MIDI 0 is a valid note, not an off sentinel; 127 must not clamp.
            note_message(0,1,1,1);expected_held[0]=1;check_held_and_legacy;find_note(0);
            note_message(127,127,1,0);expected_held[127]=1;check_held_and_legacy;find_note(127);
            note_message(0,0,0,1);expected_held[0]=0;check_held_and_legacy;
            note_message(127,0,0,0);expected_held[127]=0;check_held_and_legacy;
            frames(128);if(audio.gate!==0 || busy!==0)$fatal(1,"BOUNDARY_RELEASE_STUCK");
            $display("PIANO_CASE_PASS timbre=%0d chromatic=13 held=1 velocity=1 release=1 sustain=1 boundaries=1 legacy_display_only=1",t);
        end
        selected_timbre=0;
        capture_solo(60);capture_solo(61);capture_solo(62);
        if(on_count!=off_count || seen_count!=expected_count || decoder_count!=expected_count ||
           phase_checks!=26 || pcm_files!=3 || nonzero<1000)$fatal(1,"COVERAGE_INCOMPLETE");
        $display("MIDI_PIANO_NOTES_TEST_PASS events=%0d ons=%0d offs=%0d phase_checks=%0d pcm_files=%0d nonzero=%0d ticks=%0d",
            seen_count,on_count,off_count,phase_checks,pcm_files,nonzero,ticks);$finish;
    end
    initial begin #1000000000;$fatal(1,"PIANO_WATCHDOG");end
endmodule
