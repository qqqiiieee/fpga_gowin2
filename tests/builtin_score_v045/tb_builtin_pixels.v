`timescale 1ns/1ps
module tb_builtin_pixels;
    reg clk=0;always #5 clk=~clk;
    reg rst=0,de=0,active=1,done=0,outside=0;
    reg [9:0] x=0,y=0;
    reg [11:0] tick=0;
    reg [1:0] song=0;
    reg [31:0] held=0;
    wire [23:0] rgb;wire covered;
    piano_roll_renderer #(.SONG_LIBRARY_ENABLE(1)) dut(
        .pixel_clk(clk),.rst_n(rst),.x(x),.y(y),.de(de),
        .piano_keys(held),.piano_outside(outside),.roll_tick(tick),.roll_song(song),
        .roll_active(active),.roll_done(done),.rgb(rgb),.covered(covered),
        .custom_write_clk(clk),.custom_write_en(1'b0),.custom_write_addr(9'd0),
        .custom_write_data(32'd0),.custom_config(32'd0),.frame_tick(1'b0),.roll_custom_bank(1'b0));
    reg [31:0] words[0:1023];
    localparam [23:0] PANEL=24'h172338,GRID=24'h22324a,BORDER=24'h34465f,
        WHITE=24'he2e8f0,BLACK=24'h080d16,CYAN=24'h51d6e8,
        GREEN=24'h21c6a8,AMBER=24'hf4bb4f,ALERT=24'hff5964;
    integer lane[0:799],white_map[0:799],black_map[0:799];
    reg sharp_map[0:799];
    integer gx,gn,gc,s,q,o,yy,i,future,checks=0,rows=0;
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
    // Independent pitch-class arithmetic rather than reading DUT geometry.
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
    function [24:0] pixel_oracle;
        input integer xx,yy;
        integer ft,keyid;
        reg [31:0] word;
        reg valid,sharp,cue,bar;
        reg [23:0] colour;
        begin
            pixel_oracle=0;
            ft=tick+((yy<320)?320-yy:0);
            word=(ft<4096)?words[song*256+ft/16]:0;
            valid=!done && song<3 && ft>=128 && ft<(song==0?3200:2176) && word[13];
            bar=valid && !(word[14] && ft%16<2);
            if(de && xx>=34 && xx<=605 && yy>=143 && yy<=400)begin
                colour=(ft%64==0)?GRID:PANEL;
                if(bar && lane[xx]==word[6:0]-41)colour=CYAN;
                if(yy>=320 && yy<324)colour=done?GREEN:AMBER;
                if(yy>=324)begin
                    sharp=yy<370 && sharp_map[xx];
                    keyid=sharp?black_map[xx]:white_map[xx];
                    colour=sharp?BLACK:WHITE;
                    if(!sharp && (xx-35)%30==0)colour=BORDER;
                    cue=active&&valid&&keyid==word[6:0]-41;
                    if(cue)colour=AMBER;
                    if(held[keyid])colour=(active&&valid)?(cue?GREEN:ALERT):CYAN;
                end
                if(xx==34 || xx==605 || yy==143 || yy==400)colour=outside?ALERT:BORDER;
                pixel_oracle={1'b1,colour};
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
                @(negedge clk);x=xx%800;y=row;de=xx<640;
                want=pixel_oracle(xx%800,row);
                @(posedge clk);#1;
                if(xx>0)begin
                    checks=checks+1;
                    if({covered,rgb}!==prior)$fatal(1,
                        "song=%0d tick=%0d xy=%0d,%0d expected=%07h got=%07h",
                        song,tick,xx-1,row,prior,{covered,rgb});
                end
                prior=want;
            end
            rows=rows+1;
        end
    endtask
    initial begin
        $readmemh("tests/builtin_score_v045/oracle.hex",words);
        repeat(3)@(negedge clk);rst=1;
        // Every song/quarter at offsets 0,1,2,15. This catches onset gaps at
        // half-beat starts, continuous dotted/half notes, rests, repeated MIDI,
        // count-in, final silence and padded addresses with x0..33 prefetch.
        for(s=0;s<3;s=s+1)begin
            song=s;
            for(q=0;q<256;q=q+1)for(o=0;o<4;o=o+1)begin
                future=q*16+((o==3)?15:o);
                if(future>0)begin tick=future-1;raster_row(319);end
            end
        end
        // Complete vertical extent incl border/hit-line, last black-key row,
        // first white-only row and external pixels. Near 4095 must never wrap
        // back into song0's first note even if the physical ROM address wraps.
        for(s=0;s<3;s=s+1)begin
            song=s;
            for(i=0;i<3;i=i+1)begin
                tick=(i==0)?0:((i==1)?128:4090);
                for(yy=142;yy<=401;yy=yy+1)raster_row(yy);
            end
        end
        // All 32 physical held bits across the white/black boundary and both
        // horizontal edges. New melodies reach MIDI41 and 72 without shifts.
        song=2;tick=128;
        for(i=0;i<34;i=i+1)begin
            held=(i<32)?(32'd1<<i):((i==32)?32'hffffffff:32'ha55aa55a);
            raster_row(350);raster_row(369);raster_row(370);raster_row(399);
        end
        held=0;active=0;raster_row(200);raster_row(350);
        active=1;done=1;raster_row(200);raster_row(321);raster_row(350);done=0;
        outside=1;raster_row(143);raster_row(400);outside=0;
        song=3;raster_row(200);raster_row(350);
        // Discontinuous in-panel song change: one bubble, never old song under
        // new address. At tick130 song0 has C4 lane380; song1 has F3 lane260.
        song=0;tick=130;x=380;y=319;de=1;repeat(4)@(negedge clk);
        song=1;
        @(posedge clk);#1;
        @(posedge clk);#1;
        if(rgb!==PANEL)$fatal(1,"stale song shown on discontinuous raster jump");
        @(negedge clk);x=260;
        repeat(2)begin @(posedge clk);#1;end
        if(rgb!==CYAN)$fatal(1,"new song not visible after tag settles");
        @(negedge clk);rst=0;#1;
        if(covered!==0 || rgb!==0)$fatal(1,"async reset pixel outputs");
        $display("BUILTIN_PIXELS_PASS checks=%0d rows=%0d pipeline=2 keys=32 midi=41..72 boundaries=1",checks,rows);
        $finish;
    end
    initial begin #100000000;$fatal(1,"pixel watchdog");end
endmodule
