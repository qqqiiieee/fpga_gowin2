`timescale 1ns/1ps
// Realistic asynchronous clocks and complete 800-clock raster rows. The oracle
// computes lane geometry arithmetically; it never reads the DUT geometry ROM.
module tb_custom_score_pixels;
    parameter PIXEL_PHASE=0;
    reg source_clk=0,pixel_clk=0;
    always #18.518 source_clk=~source_clk;
    initial begin #(PIXEL_PHASE);forever #19.841 pixel_clk=~pixel_clk;end
    reg rst_n=0,we=0,frame=0,de=0,active=1,done=0,outside=0,tag=0;
    reg [8:0] wa=0;reg [31:0] wd=0,cfg=0,held=0;
    reg [9:0] x=0,y=0;reg [11:0] tick=0;reg [1:0] song=3;
    wire [23:0] rgb;wire covered,ack;
    piano_roll_renderer #(.CUSTOM_SCORE_ENABLE(1)) dut(
        .pixel_clk(pixel_clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
        .piano_keys(held),.piano_outside(outside),.roll_tick(tick),
        .roll_song(song),.roll_active(active),.roll_done(done),.rgb(rgb),.covered(covered),
        .custom_write_clk(source_clk),.custom_write_en(we),.custom_write_addr(wa),
        .custom_write_data(wd),.custom_config(cfg),.frame_tick(frame),
        .roll_custom_bank(tag),.custom_bank_ack(ack));
    `include "tests/custom_score/score_fixture.vh"
    localparam [23:0] PANEL=24'h172338,GRID=24'h22324a,BORDER=24'h34465f,
        WHITE=24'he2e8f0,BLACK=24'h080d16,CYAN=24'h51d6e8,
        GREEN=24'h21c6a8,AMBER=24'hf4bb4f,ALERT=24'hff5964;
    integer checks=0,rows=0,flips=0,q,i,j,yy,b=0,fut,noteid,whiteid,k,boundary;
    reg [31:0] prevcfg=0;reg prevack=0,sampled_frame;
    always @(posedge pixel_clk)begin
        sampled_frame=frame;#0.5;
        if(rst_n && !sampled_frame &&
            (dut.pixel_custom_config!==prevcfg || ack!==prevack))
            $fatal(1,"configuration/ACK changed within frame");
        prevcfg=dut.pixel_custom_config;prevack=ack;
    end
    task upload;
        input integer bank;
        begin
            for(q=0;q<256;q=q+1)begin
                @(negedge source_clk);we=1;wa=bank*256+q;wd=fixture_word(bank,q);
                @(posedge source_clk);#1;
            end
            @(negedge source_clk);we=0;
        end
    endtask
    task frame_pulse;
        begin @(negedge pixel_clk);frame=1;@(negedge pixel_clk);frame=0;end
    endtask
    task publish;
        input integer bank;
        begin
            @(negedge source_clk);cfg=fixture_config(bank,46875);
            repeat(30)@(negedge pixel_clk);
            if(dut.pixel_custom_config[31]!==b[0])$fatal(1,"early config application");
            frame_pulse;repeat(4)@(negedge pixel_clk);
            if(dut.pixel_custom_config!==cfg || ack!==bank[0])$fatal(1,"frame commit/ack");
            b=bank;tag=bank;flips=flips+1;
            repeat(6)@(negedge source_clk);
        end
    endtask
    function integer white_offset;
        input integer w;
        begin
            case((w+3)%7)
                0:white_offset=0;1:white_offset=2;2:white_offset=4;
                3:white_offset=5;4:white_offset=7;5:white_offset=9;default:white_offset=11;
            endcase
            white_offset=white_offset+12*((w+3)/7)-5;
        end
    endfunction
    // Test-side precomputed geometry avoids millions of repeated oracle loops.
    // Construction uses chromatic pitch arithmetic independently of DUT ROM.
    integer lane[0:799],white_map[0:799],black_map[0:799];
    reg sharp_map[0:799];
    integer gx,gn,gc;
    initial begin
        for(gx=0;gx<800;gx=gx+1)begin
            lane[gx]=-1;white_map[gx]=0;black_map[gx]=0;sharp_map[gx]=0;
            if(gx>=35 && gx<605)white_map[gx]=white_offset((gx-35)/30);
            for(gn=0;gn<19;gn=gn+1)begin
                gc=50+30*gn;
                if(gx>=gc-6 && gx<gc+6)lane[gx]=white_offset(gn);
                if(gn>0 && white_offset(gn)-white_offset(gn-1)==2)begin
                    gc=35+30*gn;
                    if(gx>=gc-6 && gx<gc+6)lane[gx]=white_offset(gn)-1;
                    if(gx>=gc-9 && gx<gc+9)begin
                        sharp_map[gx]=1;black_map[gx]=white_offset(gn)-1;
                    end
                end
            end
        end
    end
    function [24:0] oracle;
        input integer xx,yy;
        integer future,whitekey,keyid,n,barid,centre,boundary;
        reg [31:0] word;
        reg valid,sharp,cue,bar;
        reg [23:0] colour;
        begin
            oracle=0;
            future=tick+((yy<320)?320-yy:0);
            word=fixture_word(b,future/16);
            valid=cfg[30] && tag==b && future>=128 && future<320 &&
                  !done && word[13] && !future[12];
            bar=valid && !(word[14] && future%16<2);
            if(de && xx>=34 && xx<=605 && yy>=143 && yy<=400)begin
                colour=(future%64==0)?GRID:PANEL;
                barid=lane[xx];
                if(bar && barid==word[6:0]-41)colour=CYAN;
                if(yy>=320 && yy<324)colour=done?GREEN:AMBER;
                if(yy>=324)begin
                    sharp=yy<370 && sharp_map[xx];
                    keyid=sharp ? black_map[xx] : white_map[xx];
                    colour=sharp?BLACK:WHITE;
                    if(!sharp && (xx-35)%30==0)colour=BORDER;
                    cue=active&&valid&&keyid==word[6:0]-41;
                    if(cue)colour=AMBER;
                    if(held[keyid])colour=(active&&valid)?(cue?GREEN:ALERT):CYAN;
                end
                if(xx==34 || xx==605 || yy==143 || yy==400)colour=outside?ALERT:BORDER;
                oracle={1'b1,colour};
            end
        end
    endfunction
    reg [24:0] prior,want;
    task raster_row;
        input integer row;
        integer xx;
        begin
            prior=0;
            for(xx=0;xx<=800;xx=xx+1)begin
                @(negedge pixel_clk);x=xx%800;y=row;de=xx<640;
                want=oracle(xx%800,row);
                @(posedge pixel_clk);#1;
                if(xx>0)begin
                    checks=checks+1;
                    if({covered,rgb}!==prior)$fatal(1,
                        "pixel phase=%0d bank=%0d tick=%0d (%0d,%0d) expected=%07h got=%07h",
                        PIXEL_PHASE,b,tick,xx-1,row,prior,{covered,rgb});
                end
                prior=want;
            end
            rows=rows+1;
        end
    endtask
    initial begin
        repeat(5)@(negedge source_clk);rst_n=1;
        repeat(10)@(negedge pixel_clk);
        // Invalid config must hide unknown BRAM contents.
        raster_row(190);
        upload(0);upload(1);publish(0);
        for(i=0;i<10;i=i+1)begin
            case(i)
                0:tick=0;1:tick=64;2:tick=128;3:tick=144;4:tick=176;
                5:tick=192;6:tick=256;7:tick=288;8:tick=319;9:tick=4090;
            endcase
            // Every roll row: onset low4, rests, continuation, overflow;
            // first panel pixel included after x=0..33 prefetch every row.
            for(yy=143;yy<=324;yy=yy+1)raster_row(yy);
        end
        tick=128;held=32'h00180000;
        raster_row(350);raster_row(369);raster_row(370);raster_row(375);
        active=0;raster_row(200);raster_row(375); // frozen bars and held feedback
        active=1;done=1;raster_row(200);raster_row(321);raster_row(375);done=0;
        outside=1;raster_row(143);raster_row(400);outside=0;
        upload(1);raster_row(300); // inactive writes cannot disturb bank0
        publish(1);tag=0;raster_row(300); // old-time tag masks the new bank
        tag=1;raster_row(300);raster_row(375);
        // Apply attempts at 13 relative phases around arrival of the CDC
        // request. A too-early frame leaves the ENTIRE old config unchanged.
        for(j=0;j<13;j=j+1)begin
            @(negedge source_clk);cfg=fixture_config(1-b,23437+j*1001);
            repeat(j)@(negedge pixel_clk);frame_pulse;
            repeat(20)@(negedge pixel_clk);frame_pulse;
            repeat(5)@(negedge pixel_clk);
            if(dut.pixel_custom_config!==cfg || ack!==cfg[31])$fatal(1,"phase commit failed j=%0d",j);
            b=cfg[31];tag=b;flips=flips+1;
            repeat(8)@(negedge source_clk);
        end
        // Reset an in-flight config transaction and reconstruct from the
        // still-held source config. BRAM contents survive the reset.
        @(negedge source_clk);cfg=fixture_config(1-b,93750);
        repeat(2)@(negedge pixel_clk);rst_n=0;
        repeat(5)@(negedge source_clk);rst_n=1;b=0;
        repeat(30)@(negedge pixel_clk);frame_pulse;repeat(4)@(negedge pixel_clk);
        if(dut.pixel_custom_config!==cfg || ack!==cfg[31])$fatal(1,"CDC reset recovery");
        $display("CUSTOM_PIXELS_PASS phase_ns=%0d pixels=%0d rows=%0d commits=%0d renderer_stages=2 prefetch_blank_pixels=34",PIXEL_PHASE,checks,rows,flips);
        $finish;
    end
    initial begin #200000000;$fatal(1,"pixel watchdog");end
endmodule
