`timescale 1ns/1ps
// External serial stimulus, two independently compiled RTL implementations.
// Expected events are protocol examples, not a bitmap next-state model.
module tb_midi_bitmap_diff;
    parameter integer CLK_HZ=250000;
    localparam integer ACTIVE_SENSE_MS=20;
    localparam integer BIT_CYCLES=(CLK_HZ+15625)/31250;
    localparam integer IDLE_CYCLES=BIT_CYCLES*10;
    localparam integer SENSE_CYCLES=(CLK_HZ/1000)*ACTIVE_SENSE_MS;
    reg clk=0, rst_n=0, rx=1, suppress=0, event_ready=1;
    always #(500000000.0/CLK_HZ) clk=~clk;
    reg mapping_enable=0, mapping_bank=0, mapping_commit=0, mapping_wr_en=0;
    reg [7:0] mapping_wr_addr=0;
    reg [6:0] mapping_wr_data=0;
    reg [27:0] mapping_pad_notes={7'd39,7'd37,7'd38,7'd36};
    reg [27:0] mapping_cc_numbers={7'd74,7'd71,7'd91,7'd93};
    reg [511:0] phase="startup";
    integer cycles=0, mode=0, cases=0, seed=1;
    reg [31:0] rng;
    `include "interface_derived.vh"

    integer events=0, checked=0, panics=0, receipts=0, ccs=0, kicks=0, snares=0, hats=0;
    integer total_events=0, total_panics=0, total_receipts=0, stall_checks=0;
    integer cover_suppress_pop_on=0, cover_suppress_pop_off=0;
    integer cover_suppress_key_on=0, cover_suppress_key_off=0;
    integer cover_suppress_panic_oldheld=0, cover_scan_retrigger=0;
    integer cover_full_pop_push=0, cover_scan_stall=0, cover_scan_direct=0;
    reg [127:0] gates=0;
    reg log_on[0:4095];
    reg [6:0] log_note[0:4095];
    reg [7:0] log_velocity[0:4095];
    reg stalled=0, old_suppress=0;
    reg [15:0] stalled_value=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>1) compare_outputs("pre-edge");
        if(!rst_n) begin
            events=0; checked=0; panics=0; receipts=0; ccs=0;
            kicks=0; snares=0; hats=0; gates=0; stalled=0; old_suppress=0;
        end else begin
            if(stalled && !b_panic && suppress==old_suppress) begin
                if(!b_event_valid || {b_event_on,b_event_note,b_event_velocity}!==stalled_value)
                    $fatal(1,"STALL_FAIL phase=%0s cycle=%0d",phase,cycles);
                stall_checks=stall_checks+1;
            end
            stalled=b_event_valid && !event_ready && !b_panic && !(suppress && !old_suppress);
            old_suppress=suppress;
            stalled_value={b_event_on,b_event_note,b_event_velocity};
            if(b_event_valid && event_ready) begin
                if(events>=4096) $fatal(1,"scoreboard capacity");
                log_on[events]=b_event_on;log_note[events]=b_event_note;log_velocity[events]=b_event_velocity;
                events=events+1;total_events=total_events+1;
                if(b_event_on)gates[b_event_note]=1;else gates[b_event_note]=0;
            end
            if(b_panic)begin panics=panics+1;total_panics=total_panics+1;gates=0;end
            if(b_receipt_note_on)begin receipts=receipts+1;total_receipts=total_receipts+1;end
            if(b_cc_valid)ccs=ccs+1;
            if(b_hit0)kicks=kicks+1;
            if(b_hit1)snares=snares+1;
            if(b_hat_closed_hit || b_hat_open_hit)hats=hats+1;
            // READ-ONLY coverage witnesses. They neither drive stimulus nor compute
            // expected outputs. This prevents a passing test that missed a collision.
            if(b.entering_suppress && b.pop_event && b_event_on)cover_suppress_pop_on=cover_suppress_pop_on+1;
            if(b.entering_suppress && b.pop_event && b_event_off)cover_suppress_pop_off=cover_suppress_pop_off+1;
            if(b.entering_suppress && b.key_on)cover_suppress_key_on=cover_suppress_key_on+1;
            if(b.entering_suppress && b.key_off)cover_suppress_key_off=cover_suppress_key_off+1;
            if(suppress && b.panic_request && b_held_notes!=0)cover_suppress_panic_oldheld=cover_suppress_panic_oldheld+1;
            if(b.scan_active && b.key_on && b.release_notes[b.first_data])cover_scan_retrigger=cover_scan_retrigger+1;
            if(b.fifo_count==16 && b.pop_event && b.direct_event)cover_full_pop_push=cover_full_pop_push+1;
            if(b.scan_active && b.release_notes[b.scan_note] && !b.fifo_room)cover_scan_stall=cover_scan_stall+1;
            if(b.scan_active && b.direct_event)cover_scan_direct=cover_scan_direct+1;
        end
        #1;
        compare_outputs("post-NBA");
        track_changes;
    end

    task tick; input integer n; begin repeat(n) @(negedge clk); end endtask
    task check; input condition; input [511:0] message; begin
        if(condition!==1'b1)$fatal(1,"ASSERT_FAIL phase=%0s cycle=%0d message=%0s",phase,cycles,message);
    end endtask
    task pass_case; begin cases=cases+1;$display("CASE_PASS mode=%0d phase=%0s cycle=%0d",mode,phase,cycles);end endtask
    task serial; input [7:0] value; input integer good_stop; integer bit_index; begin
        rx=0; tick(BIT_CYCLES);
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin rx=value[bit_index];tick(BIT_CYCLES);end
        rx=(good_stop!=0);tick(BIT_CYCLES);
    end endtask
    // At 8 clocks/bit the two synchronizers move valid to the last stop-bit
    // clock. Two idle clocks let synchronous observers consume registered outputs.
    // Every transmitted bit still lasts exactly BIT_CYCLES (31250 baud).
    task tx; input [7:0] value; begin serial(value,1);tick(2); end endtask
    task msg; input [7:0] status; input [6:0] a,value; begin tx(status);tx({1'b0,a});tx({1'b0,value}); end endtask
    task expect_event; input integer on_value,note_value,velocity_value; integer timeout; begin
        timeout=0;
        while(events<=checked && timeout<2048)begin tick(1);timeout=timeout+1;end
        check(events>checked,"missing event");
        if(log_on[checked]!==on_value[0] || log_note[checked]!==note_value[6:0] || log_velocity[checked]!==velocity_value[7:0])
            $fatal(1,"EVENT_FAIL phase=%0s index=%0d got=%0d,%0d,%0d want=%0d,%0d,%0d",phase,checked,
                log_on[checked],log_note[checked],log_velocity[checked],on_value,note_value,velocity_value);
        checked=checked+1;
    end endtask
    task quiet; begin tick(400);check(events==checked,"unexpected extra event");end endtask
    task commit_map; input integer enable_value,bank_value; integer timeout,old_panics; begin
        mapping_enable=enable_value;mapping_bank=bank_value;
        timeout=0;
        while(!b_mapping_commit_ready && timeout<IDLE_CYCLES*3)begin tick(1);timeout=timeout+1;end
        check(b_mapping_commit_ready,"mapping ready timeout (original 31250 idle formula)");
        old_panics=panics;mapping_commit=1;tick(1);
        check(b_mapping_commit_ack,"mapping registered ack");
        tick(4);mapping_commit=0;tick(3);
        check(panics==old_panics+1,"one mapping commit panic despite held request");
    end endtask
    task reset_mode; begin
        @(negedge clk);rst_n=0;rx=1;suppress=0;event_ready=1;
        mapping_commit=0;mapping_wr_en=0;mapping_enable=0;mapping_bank=0;
        mapping_pad_notes={7'd39,7'd37,7'd38,7'd36};mapping_cc_numbers={7'd74,7'd71,7'd91,7'd93};
        tick(8);rst_n=1;tick(BIT_CYCLES*2);
        // A genuine disabled commit also exercises ready/ack and panic boundaries.
        commit_map(mode!=0,0);
    end endtask
    task release_all; begin event_ready=1;msg(8'hb0,120,0);tick(400);end endtask
    function [31:0] random_next;input [31:0] value;reg[31:0] x;begin
        x=value^(value<<13);x=x^(x>>17);x=x^(x<<5);random_next=x;
    end endfunction

    integer i,j,p0,e0,r0,c0,k0,s0,h0,old_cover;
    initial begin
        if(!$value$plusargs("SEED=%d",seed))seed=1;
        rng=seed; if(rng==0)rng=1;
        $display("CONFIG clk_hz=%0d bit_cycles=%0d idle_cycles=%0d sense_cycles=%0d seed=%0d outputs=33",CLK_HZ,BIT_CYCLES,IDLE_CYCLES,SENSE_CYCLES,seed);
        check(BIT_CYCLES>=8 && CLK_HZ==BIT_CYCLES*31250 && IDLE_CYCLES==10*BIT_CYCLES,"legal scaled UART and mapping timeout");
        for(mode=0;mode<2;mode=mode+1)begin
            phase="all128_duplicate_on_off_velocity0";reset_mode;
            tx(8'h90);
            for(i=0;i<128;i=i+1)begin tx(i);tx(100);expect_event(1,i,201);end
            check(b_held_notes=={128{1'b1}} && gates=={128{1'b1}},"all128 held/delivered");
            msg(8'h90,0,127);expect_event(1,0,255);
            msg(8'h90,127,64);expect_event(1,127,129);
            msg(8'h90,60,1);expect_event(1,60,2);
            msg(8'h90,0,0);expect_event(0,0,0);
            msg(8'h80,0,0); // duplicate Off emits nothing
            tx(8'h80);
            for(i=1;i<128;i=i+1)begin tx(i);tx(0);expect_event(0,i,0);end
            quiet;check(b_held_notes==0 && gates==0 && receipts==131,"duplicate/rawreceipt counts");pass_case;

            phase="sustain_all128_deferred_off_retrigger";reset_mode;
            msg(8'hb0,64,127);tx(8'h90);
            for(i=0;i<128;i=i+1)begin tx(i);tx(100);expect_event(1,i,201);end
            tx(8'h80);
            for(i=0;i<128;i=i+1)begin tx(i);tx(0);end
            check(b_held_notes==0 && gates=={128{1'b1}} && events==128,"sustain delays all Offs");
            msg(8'h80,127,0); // repeated pending Off remains pending
            msg(8'h90,127,127);expect_event(1,127,255);
            msg(8'hb0,64,0);
            for(i=0;i<127;i=i+1)expect_event(0,i,0);
            quiet;check(gates==(128'b1<<127) && b_held_notes==(128'b1<<127),"sustain retrigger survives release");
            msg(8'h80,127,0);expect_event(0,127,0);quiet;pass_case;

            phase="scan_backlog_retrigger_cancel_and_queued_off_order";reset_mode;
            msg(8'h90,127,100);expect_event(1,127,201);
            for(i=0;i<20;i=i+1)begin msg(8'h90,i,100);expect_event(1,i,201);end
            event_ready=0;msg(8'hb0,64,127);msg(8'h80,127,0);
            for(i=0;i<20;i=i+1)msg(8'h80,i,0);
            msg(8'hb0,64,0);tick(500);p0=panics;
            tx(8'h90);tx(127);
            fork
                begin tx(127);end
                begin tick(9*BIT_CYCLES+BIT_CYCLES/2-2);event_ready=1;tick(12);event_ready=0;end
            join
            check(!b_overflow && panics==p0 && b_held_notes[127],"retrigger during paused scan");
            event_ready=1;
            // Synchronous mapping may interleave the new On with the last low
            // scan Off. Check each Off once, ascending, and the On exactly once;
            // baseline/current still must match cycle for cycle without latitude.
            j=0;e0=0;
            while(j<20 || e0==0)begin
                i=0;while(events<=checked && i<2048)begin tick(1);i=i+1;end
                check(events>checked,"missing retrigger/scan event");
                if(log_on[checked])begin
                    check(e0==0,"duplicate retrigger On");expect_event(1,127,255);e0=e0+1;
                end else begin expect_event(0,j,0);j=j+1;end
            end
            quiet;check(gates[127],"no later stale Off");
            msg(8'h80,127,0);expect_event(0,127,0);
            event_ready=0;msg(8'h90,127,100);msg(8'h80,127,0);msg(8'h90,127,127);
            event_ready=1;expect_event(1,127,201);expect_event(0,127,0);expect_event(1,127,255);
            quiet;check(gates[127],"queued Off precedes retrigger On");pass_case;

            phase="cc123_full_release_backpressure_controls";reset_mode;
            tx(8'h90);for(i=0;i<128;i=i+1)begin tx(i);tx(100);expect_event(1,i,201);end
            event_ready=0;p0=panics;msg(8'hb0,123,0);tick(1000);
            msg(8'hb0,7,64);msg(8'hb0,1,77);
            check(!b_overflow && panics==p0 && b_held_notes==0 && b_volume==129 && b_modulation==77,"scan backlog continues CC parsing");
            event_ready=1;for(i=0;i<128;i=i+1)expect_event(0,i,0);
            quiet;check(gates==0,"CC123 all released");pass_case;

            phase="suppress_same_edge_pop_on_and_rearm";reset_mode;
            event_ready=0;msg(8'h90,0,100);msg(8'h90,127,100);
            check(b_event_valid && b_event_on && b_event_note==0,"queued On at suppress edge");
            p0=panics;suppress=1;event_ready=1;tick(500);
            expect_event(1,0,201);expect_event(0,0,0);quiet;
            check(gates==0 && b_held_notes==0 && panics==p0,"suppress exact same-edge On release");
            msg(8'h90,60,100);msg(8'h80,0,0);suppress=0;tick(2);r0=receipts;
            msg(8'h90,127,100);msg(8'h90,60,100);quiet;
            check(receipts==r0 && b_held_notes==0,"blocked raw keys do not rearm on duplicate On");
            msg(8'h80,127,0);msg(8'h90,127,100);expect_event(1,127,201);
            msg(8'h80,60,0);msg(8'h90,60,100);expect_event(1,60,201);quiet;pass_case;

            phase="suppress_same_edge_pop_off";reset_mode;
            msg(8'h90,60,100);expect_event(1,60,201);
            event_ready=0;msg(8'h80,60,0);
            check(b_event_valid && b_event_off && b_event_note==60,"queued Off at suppress edge");
            suppress=1;event_ready=1;expect_event(0,60,0);quiet;
            check(gates==0 && events==2,"same-edge Off excluded from suppress release bitmap");pass_case;

            phase="suppress_same_edge_key_on_key_off";reset_mode;
            msg(8'h90,60,100);expect_event(1,60,201);
            tx(8'h90);tx(61);
            fork
                begin tx(100);end
                // Stop sampled after two sync stages + UART IDLE detection;
                // drive on the negedge BEFORE keyboard consumes the valid byte.
                begin tick(9*BIT_CYCLES+BIT_CYCLES/2+3);suppress=1;end
            join
            expect_event(0,60,0);quiet;check(b_held_notes==0,"coincident key On blocked");
            suppress=0;tick(2);msg(8'h90,61,100);quiet;
            msg(8'h80,61,0);msg(8'h90,61,100);expect_event(1,61,201);
            tx(8'h80);tx(61);
            fork
                begin tx(0);end
                begin tick(9*BIT_CYCLES+BIT_CYCLES/2+3);suppress=1;end
            join
            expect_event(0,61,0);quiet;suppress=0;tick(2);
            msg(8'h90,61,100);expect_event(1,61,201);quiet;pass_case;

            phase="suppress_panic_oldheld_priority";reset_mode;
            msg(8'h90,60,100);expect_event(1,60,201);
            msg(8'h90,61,100);expect_event(1,61,201);
            msg(8'hb0,64,127);msg(8'h80,61,0); // held60 + pending61
            p0=panics;tx(8'hb0);tx(120);
            fork
                begin tx(0);end
                begin tick(9*BIT_CYCLES+BIT_CYCLES/2+3);suppress=1;end
            join
            quiet;check(panics==p0+1 && gates==0 && b_held_notes==0,"panic overrides suppress scan");
            suppress=0;tick(2);r0=receipts;
            msg(8'h90,60,100);quiet;check(receipts==r0,"panic retains old held raw key blocked");
            msg(8'h90,61,100);expect_event(1,61,201); // pending-only key is not old held
            msg(8'h80,60,0);msg(8'h90,60,100);expect_event(1,60,201);quiet;pass_case;

            phase="fifo_full_pop_push_same_edge";reset_mode;event_ready=0;
            for(i=0;i<16;i=i+1)msg(8'h90,i,100);
            check(!b_overflow && b_event_valid,"FIFO16 holds before simultaneous pop/push");
            tx(8'h90);tx(16);old_cover=cover_full_pop_push;
            fork
                begin tx(100);end
                begin tick(9*BIT_CYCLES+BIT_CYCLES/2+3);event_ready=1;tick(1);event_ready=0;end
            join
            check(cover_full_pop_push==old_cover+1 && !b_overflow,"full FIFO accepts same-edge pop/push");
            event_ready=1;for(i=0;i<17;i=i+1)expect_event(1,i,201);quiet;pass_case;

            phase="fifo_overflow_off_and_on_then_recovery";reset_mode;event_ready=0;
            for(i=0;i<16;i=i+1)msg(8'h90,i,100);
            p0=panics;msg(8'h80,0,0);
            check(b_overflow && panics==p0+1 && !b_event_valid && b_held_notes==0,"17th Off overflow panics");
            tx(101);tx(100);event_ready=1;quiet;
            msg(8'h90,127,127);expect_event(1,127,255);msg(8'h80,127,0);expect_event(0,127,0);
            check(b_overflow && !b_framing_error,"overflow sticky after recovery");quiet;
            reset_mode;event_ready=0;for(i=0;i<16;i=i+1)msg(8'h90,i,100);
            r0=receipts;p0=panics;msg(8'h90,16,100);
            check(receipts==r0 && panics==p0+1 && b_overflow,"overflow On suppresses rawreceipt");pass_case;

            phase="cc120_preempts_full_fifo_and_cancels_cc";reset_mode;event_ready=0;
            for(i=0;i<16;i=i+1)msg(8'h90,i,100);
            p0=panics;c0=ccs;msg(8'hb0,120,0);
            check(panics==p0+1 && !b_overflow && !b_event_valid && b_held_notes==0 && ccs==c0,"CC120 full queue priority and no fake CC");
            event_ready=1;quiet;pass_case;

            phase="control_pad_bend_running_status_sysex_filter";reset_mode;
            tx(8'hc0);tx(1);check(b_timbre_select,"program select");
            msg(8'hb0,7,64);check(b_volume==129,"volume");msg(8'hb0,1,77);check(b_modulation==77,"modulation");
            msg(8'he0,0,0);check($signed(b_bend)==-256,"negative bend");
            msg(8'he0,127,127);check($signed(b_bend)==255,"positive bend");
            msg(8'he0,0,64);check($signed(b_bend)==0,"bend center");
            for(i=0;i<4;i=i+1)begin
                case(i)0:j=93;1:j=91;2:j=71;3:j=74;endcase
                msg(8'hb0,j,i+10);check(b_cc_number==j && b_cc_value==i+10,"canonical CC routing");
            end
            for(i=36;i<40;i=i+1)msg(8'h99,i,100);
            check(kicks==1 && snares==1 && hats==2,"four default Pads");
            msg(8'h99,36,0);check(kicks==1,"drum velocity0 ignored");
            tx(8'h90);tx(0);tx(8'hf8);tx(100);expect_event(1,0,201);
            tx(127);tx(8'hfa);tx(64);expect_event(1,127,129);
            r0=receipts;msg(8'h91,62,100);msg(8'h89,60,0);
            tx(8'hf0);tx(60);tx(100);tx(8'hf8);tx(8'hf7);tx(62);tx(100);
            tx(8'hf2);tx(1);tx(2);tx(63);tx(100);quiet;
            check(receipts==r0,"other channel/SysEx/common data do not create notes");
            suppress=1;tick(400);expect_event(0,0,0);expect_event(0,127,0);
            c0=ccs;k0=kicks;s0=snares;h0=hats;
            msg(8'hb0,93,20);msg(8'h99,36,100);msg(8'h99,38,100);msg(8'h99,37,100);msg(8'h99,39,100);
            quiet;check(ccs==c0 && kicks==k0 && snares==s0 && hats==h0,"suppress CC and all Pads");pass_case;

            phase="active_sensing_refresh_timeout_transport_reset";reset_mode;
            msg(8'h90,60,100);expect_event(1,60,201);p0=panics;
            tick(SENSE_CYCLES+50);check(panics==p0 && b_held_notes[60],"sensing opt-in");
            tx(8'hfe);tick(SENSE_CYCLES/2);tx(8'hf8);tick(SENSE_CYCLES*3/4);
            check(panics==p0,"valid realtime refreshes sensing");tick(SENSE_CYCLES/2);
            check(panics==p0+1 && gates==0 && b_held_notes==0,"sensing loss panic once");
            tick(SENSE_CYCLES+50);check(panics==p0+1,"sensing disarms after panic");
            tx(61);tx(100);quiet;msg(8'h90,61,100);expect_event(1,61,201);
            tx(8'hfc);check(panics==p0+2 && gates==0,"transport stop");
            tx(62);tx(100);expect_event(1,62,201);tx(8'hff);check(panics==p0+3,"system reset");
            tx(63);tx(100);quiet;check(gates==0,"FF clears parser running status");pass_case;

            phase="bad_stop_break_recovery";reset_mode;
            msg(8'h90,60,100);expect_event(1,60,201);p0=panics;
            tx(8'h90);tx(61);serial(100,0);rx=1;tick(BIT_CYCLES*3);
            check(b_framing_error && panics==p0+1 && gates==0 && b_held_notes==0,"bad stop panic");
            tx(100);tx(100);quiet;msg(8'h90,62,100);expect_event(1,62,201);
            rx=0;tick(BIT_CYCLES*35);check(panics==p0+2,"long break only one error");
            rx=1;tick(BIT_CYCLES*3);tx(62);tx(100);quiet;
            msg(8'h90,63,100);expect_event(1,63,201);msg(8'h80,63,0);expect_event(0,63,0);
            check(b_framing_error && !b_overflow,"framing error sticky");quiet;pass_case;

            phase="seeded_mixed_uart_backpressure_suppress";reset_mode;
            for(i=0;i<256;i=i+1)begin
                rng=random_next(rng);
                if((rng & 7)==0)event_ready=!event_ready;
                if((rng & 31)==1)suppress=!suppress;
                case((rng>>8)&15)
                    0,1,2,3:msg(8'h90,(rng>>16)&127,(rng>>24)&127);
                    4,5:msg(8'h80,(rng>>16)&127,0);
                    6:msg(8'hb0,64,rng[0]?127:0);
                    7:msg(8'hb0,123,0);
                    8:msg(8'hb0,120,0);
                    9:msg(8'he0,(rng>>16)&127,(rng>>24)&127);
                    10:msg(8'h99,36+((rng>>16)&3),(rng>>24)&127);
                    11:msg(8'hb0,7,(rng>>24)&127);
                    12:begin tx(8'hc0);tx(rng[0]);end
                    13:begin tx(8'hf8);tick(rng&127);end
                    14:begin tx(8'hf0);tx((rng>>16)&127);tx(8'hf7);end
                    15:msg(8'h90,(rng>>16)&127,0);
                endcase
            end
            suppress=0;release_all;check(gates==0 && b_held_notes==0 && !b_event_valid,"random cleanup panic");pass_case;
        end

        phase="shifted_mapping_raw_receipt_held_suppress_release";mode=0;reset_mode;
        // Write only inactive bank1 through actual handshakes. Main two phases use
        // reset identity bank0; this extra case catches raw-vs-mapped bookkeeping.
        for(i=0;i<128;i=i+1)begin
            mapping_wr_addr=128+i;mapping_wr_data=(i+12)&127;mapping_wr_en=1;
            #1;check(b_mapping_wr_ready,"inactive mapping bank writable");tick(1);
        end
        mapping_wr_en=0;commit_map(1,1);
        event_ready=0;msg(8'h90,127,100);
        check(b_held_notes[127] && !b_held_notes[11] && receipts==1 && b_event_note==11,"raw held/receipt with mapped event");
        suppress=1;event_ready=1;expect_event(1,11,201);expect_event(0,11,0);quiet;
        check(gates==0,"suppress release maps raw note exactly once");
        suppress=0;msg(8'h90,127,100);quiet;msg(8'h80,127,0);msg(8'h90,127,100);expect_event(1,11,201);
        msg(8'hb0,64,127);msg(8'h80,127,0);msg(8'hb0,64,0);expect_event(0,11,0);quiet;
        commit_map(0,0);msg(8'h90,127,100);expect_event(1,127,201);quiet;pass_case;

        check(cover_suppress_pop_on>=3 && cover_suppress_pop_off>=2,"suppress pop collision coverage");
        check(cover_suppress_key_on>=2 && cover_suppress_key_off>=2,"suppress direct-byte collision coverage");
        check(cover_suppress_panic_oldheld>=2,"panic/suppress oldheld collision coverage");
        check(cover_scan_retrigger>=2 && cover_full_pop_push>=2 && cover_scan_stall>100 && cover_scan_direct>=2,"scan/FIFO collision coverage");
        print_changes;
        $display("BITMAP_DIFF_PASS cycles=%0d comparisons=%0d cases=%0d events=%0d receipts=%0d panics=%0d stall_checks=%0d suppress_pop_on=%0d suppress_pop_off=%0d suppress_key_on=%0d suppress_key_off=%0d suppress_panic_oldheld=%0d scan_retrigger=%0d full_pop_push=%0d scan_stall=%0d scan_direct=%0d seed=%0d",
            cycles,comparisons,cases,total_events,total_receipts,total_panics,stall_checks,
            cover_suppress_pop_on,cover_suppress_pop_off,cover_suppress_key_on,cover_suppress_key_off,
            cover_suppress_panic_oldheld,cover_scan_retrigger,cover_full_pop_push,cover_scan_stall,cover_scan_direct,seed);
        $finish;
    end
    initial begin #6000000000;$fatal(1,"global watchdog phase=%0s cycle=%0d",phase,cycles);end
endmodule
