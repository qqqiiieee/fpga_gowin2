`timescale 1ns/1ps
// Human-contract arithmetic oracle; no production constants/packed snapshot
// or private receiver inputs are used as expected data. UART is real 8N1.
package v038_phone_reference;
    function automatic [7:0] live_slot(
        input integer slot,input [31:0] adc,input integer p0,p1,cal,flags,diag,
        input integer vel,bend,modulation,voices,requested,owned,mode,sweep,index
    );
        integer v;
        begin
            v=0;
            case(slot)
                16:v=adc%256;17:v=(adc>>8)%256;
                18:v=(adc>>16)%256;19:v=(adc>>24)%256;
                20:v=p0;21:v=p1;
                22:v=128+((diag&16)!=0?64:0)+((diag&2)!=0?32:0)+
                    ((diag&32)!=0?16:0)+((flags&16)!=0?8:0)+((flags&8)!=0?4:0)+cal;
                23:v=owned*128+mode*64+((diag&64)!=0?32:0)+((diag&512)!=0?16:0)+
                    ((diag&8)!=0?8:0)+((diag&4)!=0?4:0)+((diag&256)!=0?2:0)+((diag&128)!=0?1:0);
                24:v=vel;25:v=(bend+512)%256;26:v=bend<0?1:0;
                27:v=modulation;28:v=voices;29:v=requested;
                30:v=index*8+((flags&128)!=0?4:0)+sweep*2+owned;
                31:v=167;
            endcase
            live_slot=v;
        end
    endfunction
endpackage

// A wire-level UART peer, with an independent bit-center ACK decoder rather
// than reusing the DUT UART receiver for both stimulus and expected response.
module v038_uart_peer #(parameter BC=10)(input clk,rst_n,tx,output reg rx=1);
    reg [7:0] request[0:11],reply[0:8191];
    integer received=0,base=0,frames=0;
    reg [7:0] decoded;
    integer bit_number;
    initial forever begin
        @(negedge tx);
        if(rst_n)begin:decode
            repeat(BC/2)@(negedge clk);
            if(!rst_n)disable decode;
            if(tx!==0)$fatal(1,"ACK start bit");
            for(bit_number=0;bit_number<8;bit_number=bit_number+1)begin
                repeat(BC)@(negedge clk);
                if(!rst_n)disable decode;
                decoded[bit_number]=tx;
            end
            repeat(BC)@(negedge clk);
            if(!rst_n)disable decode;
            if(tx!==1)$fatal(1,"ACK stop bit");
            if(received>=8192)$fatal(1,"Bounded UART reply capacity");
            reply[received]=decoded;received=received+1;
        end
    end
    task byte_send(input [7:0] v);
        integer n;
        begin
            @(negedge clk);rx=0;repeat(BC)@(negedge clk);
            for(n=0;n<8;n=n+1)begin rx=v[n];repeat(BC)@(negedge clk);end
            rx=1;repeat(BC)@(negedge clk);
        end
    endtask
    task make(input [7:0] seq,cmd,index,value);
        integer n;
        begin
            request[0]=8'ha5;request[1]=8'h5a;request[2]=1;request[3]=seq;
            request[4]=cmd;request[5]=index;request[6]=value;
            for(n=7;n<11;n=n+1)request[n]=0;
            fix_xor();
        end
    endtask
    task fix_xor;
        integer n;reg [7:0] sum;
        begin sum=0;for(n=2;n<11;n=n+1)sum=sum^request[n];request[11]=sum;end
    endtask
    task send;
        integer n;
        begin base=received;for(n=0;n<12;n=n+1)byte_send(request[n]);end
    endtask
    task expect_reply(input [7:0] result,value,input check_status,input [31:0] status);
        integer n,age;reg [7:0] sum;
        begin
            age=0;
            while(received<base+12 && age<2500)begin @(negedge clk);age=age+1;end
            if(received!=base+12)$fatal(1,"ACK size/missing %0d/%0d",received,base);
            if(reply[base]!==8'h5a || reply[base+1]!==8'ha5 || reply[base+2]!==1 ||
                reply[base+3]!==request[3] || reply[base+4]!==result ||
                reply[base+5]!==request[5] || reply[base+6]!==value)
                $fatal(1,"ACK seq=%0d cmd=%0d idx=%0d result=%0d/%0d data=%h/%h",
                    request[3],request[4],request[5],reply[base+4],result,reply[base+6],value);
            if(check_status && {reply[base+10],reply[base+9],reply[base+8],reply[base+7]}!==status)
                $fatal(1,"ACK status bytes");
            sum=0;for(n=2;n<11;n=n+1)sum=sum^reply[base+n];
            if(reply[base+11]!==sum)$fatal(1,"ACK XOR");
            frames=frames+1;repeat(20)@(negedge clk);
        end
    endtask
    task expect_silence;
        begin repeat(1500)@(negedge clk);if(received!=base)$fatal(1,"Bad frame ACKed");end
    endtask
endmodule

module tb_v038_phone_telemetry;
    import v038_phone_reference::*;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0;wire rx,tx,set_valid,panic,get_valid;wire [7:0] param,value,sensor_value;
    reg [31:0] adc=32'h7abc0123;
    reg [7:0] p0=73,p1=201,flags=8'h98,velocity=91;
    reg [1:0] calibrated=1;reg [13:0] diagnostic=14'h02b6;
    reg signed [8:0] bend=-137;reg [6:0] modulation=69;
    reg [5:0] voices=13,requested=32;reg owned=1,mode=0,sweep=1;reg [4:0] index=27;
    reg [7:0] data[0:15],cache[16:30];
    wire [7:0] read_value=param>=16 ? sensor_value : data[param[3:0]];
    wire capture=get_valid && param==16;
    phone_control_link #(.CLK_HZ(1000000),.BAUD(100000),.TIMEOUT_CYCLES(250),.TELEMETRY_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.set_valid(set_valid),.panic(panic),
        .param(param),.value(value),.read_value(read_value),.status_flags(8'h19),
        .current_timbre(8'd1),.current_fx(8'd2),.current_volume(8'd180),.get_valid(get_valid));
    phone_telemetry_snapshot snapshot(.clk(clk),.rst_n(rst_n),.capture(capture),.index(param),
        .adc_raw(adc),.pressure0(p0),.pressure1(p1),.calibrated(calibrated),.flags(flags),
        .external_diagnostic(diagnostic),.midi_velocity(velocity),.midi_bend(bend),
        .midi_modulation(modulation),.voices(voices),.test_requested(requested),
        .test_owned(owned),.test_mode(mode),.test_sweep(sweep),.test_index(index),.value(sensor_value));
    v038_uart_peer peer(.clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx));
    // Explicit legacy GET31 rejection, beyond the unchanged old bench's GET16.
    wire legacy_rx,legacy_tx,legacy_get,legacy_set,legacy_panic;
    wire [7:0] legacy_param,legacy_value;
    phone_control_link #(.CLK_HZ(1000000),.BAUD(100000),.TIMEOUT_CYCLES(250)) legacy(
        .clk(clk),.rst_n(rst_n),.rx(legacy_rx),.tx(legacy_tx),.set_valid(legacy_set),
        .panic(legacy_panic),.param(legacy_param),.value(legacy_value),
        .read_value(8'h3c),.status_flags(8'h19),.current_timbre(8'd1),
        .current_fx(8'd2),.current_volume(8'd180),.get_valid(legacy_get));
    v038_uart_peer legacy_peer(.clk(clk),.rst_n(rst_n),.rx(legacy_rx),.tx(legacy_tx));
    integer legacy_gets=0;
    always @(posedge clk)if(rst_n)begin
        if(legacy_get)legacy_gets=legacy_gets+1;
        if(legacy_set || legacy_panic)$fatal(1,"Legacy rejected telemetry action");
    end
    integer gets=0,sets=0,panics=0,captures=0,slot_checks=0,i,k,seq=0;
    reg last_get=0,last_set=0,last_panic=0;
    reg moving=0;
    always @(negedge clk)if(moving)begin
        adc=adc+32'h01010307;p0=p0+17;p1=p1-29;flags=flags+13;
        calibrated=calibrated+1;diagnostic=diagnostic+17;velocity=velocity+19;
        bend=bend+37;modulation=modulation+11;voices=voices+3;requested=requested+5;
        owned=~owned;mode=~mode;sweep=~sweep;index=index+7;
    end
    always @(posedge clk)begin
        if(!rst_n)begin
            for(integer j=16;j<=30;j=j+1)cache[j]=0;
            last_get=0;last_set=0;last_panic=0;
        end else begin
            if(get_valid && last_get)$fatal(1,"get_valid wider than one clock");
            if(set_valid && last_set)$fatal(1,"set_valid wider than one clock");
            if(panic && last_panic)$fatal(1,"panic wider than one clock");
            last_get=get_valid;last_set=set_valid;last_panic=panic;
            if(get_valid)gets=gets+1;
            if(set_valid)begin sets=sets+1;data[param[3:0]]=value;end
            if(panic)panics=panics+1;
            if(capture)begin
                captures=captures+1;
                for(integer j=16;j<=30;j=j+1)cache[j]=live_slot(j,adc,p0,p1,calibrated,
                    flags,diagnostic,velocity,$signed(bend),modulation,voices,requested,owned,mode,sweep,index);
            end
        end
    end
    task expect_actions(input integer g,s,p,c);
        begin if(gets!=g || sets!=s || panics!=p || captures!=c)
            $fatal(1,"Unexpected commit counts get=%0d/%0d set=%0d/%0d panic=%0d/%0d cap=%0d/%0d",
                gets,g,sets,s,panics,p,captures,c);end
    endtask
    task transact(input [7:0] cmd,idx,val,result);
        integer g,s,p,c;reg [7:0] expected;
        begin
            g=gets+((cmd==0 && result==0)?1:0);
            s=sets+((cmd==1 && result==0)?1:0);
            p=panics+((cmd==2 && result==0)?1:0);
            c=captures+((cmd==0 && result==0 && idx==16)?1:0);
            peer.make(seq,cmd,idx,val);seq=(seq+1)%256;peer.send();
            if(idx==31)expected=8'ha7;
            else if(idx>=16 && idx<=30)expected=cache[idx];
            else if(idx<16)expected=data[idx];else expected=0;
            peer.expect_reply(result,expected,1,32'hb4020119);
            expect_actions(g,s,p,c);slot_checks=slot_checks+1;
        end
    endtask
    task invalid_packet(input [7:0] result);
        integer g,s,p,c;reg [7:0] expected;
        begin
            g=gets;s=sets;p=panics;c=captures;peer.send();
            expected=peer.request[5]==16 ? cache[16] : data[peer.request[5]%16];
            peer.expect_reply(result,expected,1,32'hb4020119);expect_actions(g,s,p,c);
        end
    endtask
    task retry_snapshot(input [7:0] same_seq,original_low);
        integer g,s,p,c;
        begin
            g=gets;s=sets;p=panics;c=captures;
            peer.make(same_seq,0,16,0);peer.send();
            peer.expect_reply(0,original_low,1,32'hb4020119);
            expect_actions(g,s,p,c);
        end
    endtask
    task reset_link;
        begin
            moving=0;rst_n=0;repeat(5)@(negedge clk);rst_n=1;
            repeat(20)@(negedge clk);
        end
    endtask
    integer old_gets,old_sets,old_panics,old_captures;
    reg [7:0] first_snapshot[16:30];
    initial begin
        for(i=0;i<16;i=i+1)data[i]=i+64;
        data[0]=180;data[1]=1;reset_link();
        // Capability and all later slots before first capture must not capture.
        transact(0,31,0,0);for(i=17;i<=30;i=i+1)transact(0,i,0,0);
        if(captures!=0 || cache[22]!=0)$fatal(1,"GET31/ordinary slot created snapshot");
        // Never pulse before validated byte11. Change ADC immediately before
        // checksum: first GET16 ACK must use this NEW low byte after settle.
        old_gets=gets;old_captures=captures;peer.make(255,0,16,0);peer.base=peer.received;
        for(i=0;i<11;i=i+1)peer.byte_send(peer.request[i]);
        repeat(50)@(negedge clk);
        if(gets!=old_gets || captures!=old_captures || peer.received!=peer.base || sensor_value!==0)
            $fatal(1,"Early GET commit or nonzero pre-capture slot16");
        adc=32'hdeadc45e;peer.byte_send(peer.request[11]);
        peer.expect_reply(0,8'h5e,1,32'hb4020119);expect_actions(old_gets+1,sets,panics,old_captures+1);
        // Retry the SAME successful GET16 after ALL telemetry inputs change.
        // The original low byte and every later byte must still be snapshot A.
        for(i=16;i<=30;i=i+1)first_snapshot[i]=cache[i];
        adc=32'h1122a6b7;p0=109;p1=18;flags=0;diagnostic=0;calibrated=2;
        velocity=22;bend=255;modulation=111;voices=2;requested=4;owned=0;mode=1;sweep=0;index=3;
        retry_snapshot(255,8'h5e);
        // Invalid requests/packets must NOT invalidate this retry marker.
        transact(0,16,1,3);retry_snapshot(255,8'h5e);
        transact(1,16,55,2);retry_snapshot(255,8'h5e);
        transact(3,16,0,1);retry_snapshot(255,8'h5e);
        peer.make(19,0,16,0);peer.request[2]=2;peer.fix_xor();invalid_packet(4);
        retry_snapshot(255,8'h5e);
        peer.make(20,0,16,0);peer.request[8]=1;peer.fix_xor();invalid_packet(4);
        retry_snapshot(255,8'h5e);
        old_gets=gets;old_captures=captures;
        peer.make(21,0,16,0);peer.request[11]=peer.request[11]^1;peer.send();peer.expect_silence();
        if(gets!=old_gets || captures!=old_captures)$fatal(1,"Bad XOR disturbed snapshot retry marker");
        retry_snapshot(255,8'h5e);
        for(i=17;i<=30;i=i+1)begin
            transact(0,i,0,0);
            if(cache[i]!==first_snapshot[i])$fatal(1,"Retry split snapshot low/high bytes");
        end
        seq=0;transact(0,16,0,0);
        if(cache[16]!==8'hb7 || cache[17]!==8'ha6 || cache[24]!==22)$fatal(1,"New SEQ did not capture snapshot B");
        for(i=17;i<=30;i=i+1)transact(0,i,0,0);
        // Valid capability request at255 clears marker; seq wraps to0, which
        // must start a new capture despite matching the earlier capture SEQ.
        adc=32'h55667788;seq=255;transact(0,31,0,0);transact(0,16,0,0);
        if(cache[16]!==8'h88)$fatal(1,"SEQ wrap/other valid GET did not refresh");
        retry_snapshot(0,8'h88);
        // Successful SET and Panic also break adjacency; no permanent dedup.
        adc=32'hcafebace;transact(1,13,1,0);seq=0;transact(0,16,0,0);
        if(cache[16]!==8'hce)$fatal(1,"Valid SET did not clear snapshot marker");
        adc=32'h0badf00d;transact(2,0,0,0);seq=0;transact(0,16,0,0);
        if(cache[16]!==8'h0d)$fatal(1,"Valid Panic did not clear snapshot marker");
        // Every source changes on every clock: later bytes stay one coherent
        // snapshot; GET31 is a capability query and never refreshes the cache.
        moving=1;seq=0;
        for(i=17;i<=30;i=i+1)transact(0,i,0,0);
        transact(0,31,0,0);for(i=17;i<=30;i=i+1)transact(0,i,0,0);
        transact(0,16,0,0);for(i=17;i<=30;i=i+1)transact(0,i,0,0);moving=0;
        // All named sensor/beam flag bits, including unused source bits that
        // must not leak into the wire format; calibration bits are independent.
        diagnostic=0;flags=0;calibrated=0;owned=0;mode=0;sweep=0;index=0;
        for(k=0;k<14;k=k+1)begin
            diagnostic=1<<k;transact(0,16,0,0);transact(0,22,0,0);transact(0,23,0,0);
        end
        diagnostic=0;
        for(k=0;k<8;k=k+1)begin flags=1<<k;transact(0,16,0,0);transact(0,22,0,0);transact(0,30,0,0);end
        flags=0;
        for(k=0;k<4;k=k+1)begin calibrated=k;transact(0,16,0,0);transact(0,22,0,0);end
        // Signed9 bend boundaries, full independent pressure bytes, and counts.
        for(k=0;k<4;k=k+1)begin
            case(k)0:bend=-256;1:bend=-1;2:bend=0;3:bend=255;endcase
            adc=(k%2)?32'h8000ffff:32'hffff8000;p0=k*73;p1=255-k*53;
            velocity=k*85;modulation=(k%2)?127:0;voices=(k%2)?63:0;requested=(k%2)?32:1;
            owned=k%2;mode=(k/2)%2;sweep=(k+1)%2;index=(k%2)?31:0;
            transact(0,16,0,0);for(i=17;i<=30;i=i+1)transact(0,i,0,0);
        end
        // Exhaust read-only SET15..31 and unknown >31; no accidental GET pulse.
        for(i=15;i<=31;i=i+1)transact(1,i,8'ha5,2);
        transact(0,32,0,2);transact(0,127,0,2);transact(0,255,0,2);transact(1,255,1,2);
        transact(0,16,1,3);transact(3,16,0,1);transact(2,1,0,3);
        peer.make(1,0,16,0);peer.request[2]=2;peer.fix_xor();invalid_packet(4);
        peer.make(2,0,16,0);peer.request[9]=1;peer.fix_xor();invalid_packet(4);
        old_gets=gets;old_sets=sets;old_panics=panics;old_captures=captures;
        peer.make(3,0,16,0);peer.request[0]=8'ha4;peer.send();peer.expect_silence();
        expect_actions(old_gets,old_sets,old_panics,old_captures);
        peer.make(3,0,16,0);peer.request[11]=peer.request[11]^1;peer.send();peer.expect_silence();
        expect_actions(old_gets,old_sets,old_panics,old_captures);
        // Wrong stop bit on final checksum byte is not an input-byte stub.
        peer.make(4,0,16,0);peer.base=peer.received;
        for(i=0;i<11;i=i+1)peer.byte_send(peer.request[i]);
        @(negedge clk);peer.rx=0;repeat(10)@(negedge clk);
        // Send the eight checksum bits and an invalid low stop bit explicitly.
        for(i=0;i<8;i=i+1)begin peer.rx=peer.request[11][i];repeat(10)@(negedge clk);end
        peer.rx=0;repeat(10)@(negedge clk);peer.rx=1;repeat(30)@(negedge clk);
        peer.expect_silence();expect_actions(old_gets,old_sets,old_panics,old_captures);
        // Timeout, noise, reset mid-packet and sequence wrap recover normally.
        peer.byte_send(8'ha5);peer.byte_send(8'h5a);peer.byte_send(1);repeat(300)@(negedge clk);
        peer.byte_send(0);peer.byte_send(8'ha5);seq=255;transact(0,31,0,0);transact(0,31,0,0);
        for(i=0;i<15;i=i+1)begin
            case(i)1,13,14:k=1;2:k=2;3,12:k=3;default:k=211;endcase
            transact(1,i,k,0);transact(0,i,0,0);
        end
        transact(2,0,0,0);
        peer.make(17,0,16,0);for(i=0;i<6;i=i+1)peer.byte_send(peer.request[i]);reset_link();
        transact(0,31,0,0);for(i=17;i<=30;i=i+1)transact(0,i,0,0);
        if(cache[22]!=0)$fatal(1,"Reset snapshot validity");
        adc=32'h1234abcd;transact(0,16,0,0);for(i=17;i<=30;i=i+1)transact(0,i,0,0);
        legacy_peer.make(255,0,31,0);legacy_peer.send();legacy_peer.expect_reply(2,8'h3c,1,32'hb4020119);
        legacy_peer.make(0,0,16,0);legacy_peer.send();legacy_peer.expect_reply(2,8'h3c,1,32'hb4020119);
        if(legacy_gets!=0)$fatal(1,"Default0 accepted telemetry GET16/31");
        legacy_peer.make(1,1,31,0);legacy_peer.send();legacy_peer.expect_reply(2,8'h3c,1,32'hb4020119);
        legacy_peer.make(2,0,15,0);legacy_peer.send();legacy_peer.expect_reply(0,8'h3c,1,32'hb4020119);
        legacy_peer.make(3,0,15,1);legacy_peer.send();legacy_peer.expect_reply(3,8'h3c,1,32'hb4020119);
        if(legacy_gets!=1)$fatal(1,"Legacy get_valid validation");
        $display("V038_PHONE_TELEMETRY_PASS replies=%0d slots=%0d get=%0d captures=%0d sets=%0d panic=%0d independent_uart=1",
            peer.frames,slot_checks,gets,captures,sets,panics);$finish;
    end
    initial begin #20000000;$fatal(1,"Bounded V038 unit timeout");end
endmodule

`ifdef V038_TOP
`include "tests/hdmi_display_stub.vh"
// Real production top, phone parser, capture connection and audio/MIDI paths.
// Only existing HDMI boundary stub is used. No force of telemetry/input nets.
module tb_v038_phone_top;
    import v038_phone_reference::*;
    reg clk=0;always #5 clk=~clk;
    wire phone_rx,phone_tx;reg midi_rx=1;tri1 scl,sda;
    top #(.BUTTON_DEBOUNCE_CYCLES(4)) dut(.clk(clk),.ui_buttons_n(4'hf),
        .phone_uart_rx(phone_rx),.phone_uart_tx(phone_tx),.uart_rx(1'b1),.uart_tx(),
        .midi_rx(midi_rx),.optical_beams(2'b11),.adc_scl(scl),.adc_sda(sda),
        .hp_bck(),.hp_ws(),.hp_din(),.pa_en(),.amp_bck(),.amp_lrc(),.amp_din(),
        .timbre_led_n(),.tmds_clk_p(),.tmds_clk_n(),.tmds_data_p(),.tmds_data_n());
    // Accelerate only phone UART timing; real MIDI remains864clocks/bit.
    defparam dut.u_phone.CLK_HZ=1000000;
    defparam dut.u_phone.BAUD=100000;
    v038_uart_peer peer(.clk(clk),.rst_n(dut.rst_n),.rx(phone_rx),.tx(phone_tx));
    reg [7:0] cache[16:30];integer captures=0,gets=0,sets=0,seq=0,i,first_seq,previous_gets;
    reg [7:0] first_low;
    always @(posedge clk)begin
        if(!dut.rst_n)begin for(integer j=16;j<=30;j=j+1)cache[j]=0;end
        else begin
            if(dut.phone_get)gets=gets+1;
            if(dut.phone_set)sets=sets+1;
            if(dut.phone_get && dut.phone_param==16)begin
                captures=captures+1;
                for(integer j=16;j<=30;j=j+1)cache[j]=live_slot(j,dut.adc_values[31:0],
                    dut.expression0,dut.expression1,dut.pressure_calibrated,dut.flags,
                    dut.external_diagnostic,dut.midi_velocity,$signed(dut.midi_bend),
                    dut.midi_modulation,dut.voices,dut.test_requested,dut.test_owned,
                    dut.test_mode,dut.test_sweep,dut.test_index);
            end
            if(dut.sample_tick && (^dut.pcm)===1'bx)$fatal(1,"Real top PCM X");
        end
    end
    task transact(input [7:0] cmd,idx,val,result,ordinary_expected);
        integer g,c,s;reg [7:0] expected;
        begin
            g=gets+((cmd==0 && result==0)?1:0);
            c=captures+((cmd==0 && idx==16 && result==0)?1:0);
            s=sets+((cmd==1 && result==0)?1:0);
            peer.make(seq,cmd,idx,val);seq=(seq+1)%256;peer.send();
            expected=ordinary_expected;
            if(idx==31)expected=8'ha7;
            else if(idx>=16 && idx<=30)expected=cache[idx];
            peer.expect_reply(result,expected,0,0);
            if(gets!=g || captures!=c || sets!=s)$fatal(1,"Real top action/capture wiring");
        end
    endtask
    task midi_byte(input [7:0] v);
        integer b;
        begin
            @(negedge clk);midi_rx=0;repeat(864)@(negedge clk);
            for(b=0;b<8;b=b+1)begin midi_rx=v[b];repeat(864)@(negedge clk);end
            midi_rx=1;repeat(864)@(negedge clk);
        end
    endtask
    task midi(input [7:0] status,a,b);
        begin midi_byte(status);midi_byte(a);midi_byte(b);repeat(400)@(negedge clk);end
    endtask
    initial begin
        wait(dut.rst_n);repeat(500)@(negedge clk);
        transact(0,31,0,0,0);transact(0,22,0,0,0);
        if(captures!=0)$fatal(1,"Real top capGET captured");
        midi(8'h90,60,100);midi(8'he0,0,0);midi(8'hb0,1,64);
        first_seq=seq;transact(0,16,0,0,0);first_low=cache[16];
        if(cache[24]!=100 || cache[25]!=0 || cache[26]!=1 || cache[27]!=64)
            $fatal(1,"Real MIDI-to-telemetry field wiring");
        midi(8'h90,67,87);midi(8'he0,127,127);midi(8'hb0,1,113);
        previous_gets=gets;peer.make(first_seq,0,16,0);peer.send();peer.expect_reply(0,first_low,0,0);
        if(captures!=1 || gets!=previous_gets || cache[24]!=100)$fatal(1,"Real top GET16 retry recaptured MIDI B");
        for(i=17;i<=30;i=i+1)transact(0,i,0,0,0);
        if(captures!=1 || cache[24]!=100)$fatal(1,"Top cache refreshed without GET16");
        transact(0,16,0,0,0);
        if(cache[24]!=87 || cache[25]!=255 || cache[26]!=0 || cache[27]!=113)
            $fatal(1,"Top latest snapshot refresh");
        for(i=17;i<=30;i=i+1)transact(0,i,0,0,0);
        transact(1,16,255,2,0);transact(1,31,255,2,0);transact(0,31,0,0,0);
        transact(1,13,0,0,0);transact(0,13,0,0,0);
        if(captures!=2)$fatal(1,"Read-only or capability refreshed top snapshot");
        $display("V038_PHONE_TOP_PASS replies=%0d captures=%0d real_midi=1 real_audio=1 hdmi_boundary_stub=1",peer.frames,captures);
        $finish;
    end
    initial begin #15000000;$fatal(1,"Bounded real top timeout");end
endmodule
`endif
