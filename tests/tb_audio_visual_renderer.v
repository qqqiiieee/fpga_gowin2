`timescale 1ns/1ps
module tb_audio_visual_renderer;
    reg pixel_clk=0;always #5 pixel_clk=~pixel_clk;
    reg rst_n=0,de=0,enabled=0,compact=0,fft_valid=0,xy_valid=0;
    reg [9:0] x=0,y=0;
    reg [7:0] fft_q;reg xy_q;
    wire [7:0] fft_addr;wire [13:0] xy_addr;
    wire [23:0] rgb;wire covered;
    audio_visual_renderer dut(.pixel_clk(pixel_clk),.rst_n(rst_n),.x(x),.y(y),
        .de(de),.enabled(enabled),.compact(compact),.fft_level(fft_q),
        .xy_dot(xy_q),.fft_valid(fft_valid),.xy_valid(xy_valid),
        .fft_read_addr(fft_addr),.xy_read_addr(xy_addr),.rgb(rgb),.covered(covered));
    function [7:0] spectrum;
        input integer address;
        begin spectrum=(address*73+19)%256;end
    endfunction
    function bitmap;
        input integer address;
        integer px,py;
        begin
            px=address%128;py=address/128;
            bitmap=((3*px+5*py)%29==0) || (px==17 && py==93) ||
                (px==0 && py==127) || (px==127 && py==0);
        end
    endfunction
    // Real single-clock synchronous read latency, not combinational test data.
    always @(posedge pixel_clk)begin fft_q<=spectrum(fft_addr);xy_q<=bitmap(xy_addr);end

    // Independent integer-coordinate oracle: literal rectangles, division,
    // modulo and literal palette; no hierarchy or RTL-extracted expectations.
    integer expected_faddr,expected_xaddr;
    reg [23:0] next_rgb,previous_rgb=0;
    reg next_covered,previous_covered=0;
    integer top,bottom,left,right,xtop,xbottom,lx,ly,level;
    reg inf,inx,bf,bx,border;
    integer checks=0,dots=0,bars=0,uncovered=0;
    always @(posedge pixel_clk)begin
        if(!rst_n)begin
            previous_rgb=0;previous_covered=0;
            #1;if(rgb!==0 || covered!==0)$fatal(1,"Renderer reset output");
        end else begin
            expected_faddr=0;expected_xaddr=0;next_rgb=0;next_covered=0;
            top=compact ? 144 : 80;bottom=compact ? 271 : 335;
            left=compact ? 384 : 320;right=compact ? 511 : 575;
            xtop=compact ? 148 : 80;xbottom=compact ? 275 : 335;
            inf=x>=32 && x<=287 && y>=top && y<=bottom;
            inx=x>=left && x<=right && y>=xtop && y<=xbottom;
            bf=x>=31 && x<=288 && y>=(compact ? 144 : 79) && y<=bottom+1;
            bx=x>=left-1 && x<=right+1 && y>=xtop-1 && y<=xbottom+1;
            if(de && enabled && x<640 && y<480)begin
                if(inf)expected_faddr=x-32;
                if(inx)expected_xaddr=((y-xtop)/(compact ? 1 : 2))*128+
                    (x-left)/(compact ? 1 : 2);
                if(bf || bx)begin
                    next_covered=1;next_rgb=24'h0b101c;
                    border=(bf && (!inf || (compact && y==144))) || (bx && !inx);
                    lx=(x-left)/(compact ? 1 : 2);ly=(y-xtop)/(compact ? 1 : 2);
                    level=spectrum(x-32);if(compact)level=level/2;
                    if(border)next_rgb=24'h34465f;
                    else if(inx && xy_valid && bitmap(expected_xaddr))begin
                        next_rgb=24'h51d6e8;dots=dots+1;
                    end else if(inf && fft_valid && bottom-y<level)begin
                        next_rgb=24'h21c6a8;bars=bars+1;
                    end else if(inx && (lx==64 || ly==64))next_rgb=24'h34465f;
                    else if((inx && (lx%32==0 || ly%32==0)) ||
                        (inf && ((x-32)%32==0 || (y-top)%(compact ? 32 : 64)==0)))
                        next_rgb=24'h22324a;
                end
            end
            if(fft_addr!==expected_faddr[7:0] || xy_addr!==expected_xaddr[13:0])
                $fatal(1,"Address c=%0d x=%0d y=%0d: fft %0d/%0d xy %0d/%0d",
                    compact,x,y,fft_addr,expected_faddr,xy_addr,expected_xaddr);
            #1;
            if(rgb!==previous_rgb || covered!==previous_covered)
                $fatal(1,"Two-stage pixel %0d expected %h/%b got %h/%b current=%0d,%0d",
                    checks,previous_rgb,previous_covered,rgb,covered,x,y);
            previous_rgb=next_rgb;previous_covered=next_covered;checks=checks+1;
            if(!next_covered)uncovered=uncovered+1;
        end
    end
    integer mode,row,col,scene,i,box,left_edge,right_edge,top_edge,bottom_edge,stride;
    initial begin
        repeat(3)@(negedge pixel_clk);rst_n=1;
        // Exhaust every pixel in each valid plot and its surrounding outside
        // rim. Invalid plots use a stride2 grid. Do not spend simulation cycles
        // rastering the same empty background a million times.
        for(scene=0;scene<4;scene=scene+1)begin
            mode=scene%2;stride=scene<2 ? 1 : 2;
            for(box=0;box<2;box=box+1)begin
                left_edge=box==0 ? 30 : (mode ? 382 : 318);
                right_edge=box==0 ? 289 : (mode ? 513 : 577);
                top_edge=box==0 ? (mode ? 143 : 78) : (mode ? 146 : 78);
                bottom_edge=box==0 ? (mode ? 273 : 337) : (mode ? 277 : 337);
                for(row=top_edge;row<=bottom_edge;row=row+stride)begin
                    for(col=left_edge;col<=right_edge;col=col+stride)begin
                        @(negedge pixel_clk);
                        x=col;y=row;compact=mode;enabled=1;de=1;
                        fft_valid=scene<2;xy_valid=scene<2;
                    end
                end
            end
        end
        // Background, footer y432/464, off-screen and independent valid bits.
        for(mode=0;mode<2;mode=mode+1)begin
            for(row=0;row<512;row=row+16)begin
                for(col=0;col<672;col=col+16)begin
                    @(negedge pixel_clk);x=col;y=row;compact=mode;
                    de=1;enabled=1;fft_valid=1;xy_valid=0;
                end
            end
        end
        // Adjacent unrelated pixels/modes/valid bits test actual latency,
        // independent validity, input blanking and enable alignment.
        for(i=0;i<5000;i=i+1)begin
            @(negedge pixel_clk);
            x=(i*131+49)%1024;y=(i*47+87)%1024;
            compact=i%2;enabled=(i%7!=0);de=(i%5!=0);
            fft_valid=(i%3!=0);xy_valid=(i%4!=0);
        end
        @(negedge pixel_clk);x=418;y=241;compact=0;enabled=1;de=1;xy_valid=1;
        repeat(3)@(negedge pixel_clk);
        #2;rst_n=0;#1;
        if(rgb!==0 || covered!==0)$fatal(1,"Async reset mid active pixel");
        repeat(2)@(negedge pixel_clk);rst_n=1;enabled=0;de=0;
        repeat(4)@(negedge pixel_clk);
        if(checks<230000 || dots<100 || bars<100 || uncovered<100)
            $fatal(1,"Coverage incomplete %0d %0d %0d %0d",checks,dots,bars,uncovered);
        $display("AUDIO_VISUAL_RENDERER_PASS checks=%0d dots=%0d bars=%0d uncovered=%0d",
            checks,dots,bars,uncovered);$finish;
    end
    initial begin #20000000;$fatal(1,"Renderer timeout");end
endmodule
