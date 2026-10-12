`timescale 1ns/1ps
module tb_video_timing;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 wire [9:0] x,y;wire de,hs,vs,fs;
 video_timing dut(clk,rst_n,x,y,de,hs,vs,fs);
 integer n,h,v,active,hs_low,vs_low,starts;
 initial begin
  #12;rst_n=1;active=0;hs_low=0;vs_low=0;starts=0;
  for(n=0;n<840000;n=n+1)begin
   @(negedge clk);h=(n+1)%800;v=((n+1)/800)%525;
   if(x!==h || y!==v)$fatal(1,"Raster counter mismatch n=%0d x=%0d y=%0d",n,x,y);
   if(de!==(h<640 && v<480))$fatal(1,"Active area mismatch");
   if(hs!==!(h>=656 && h<752) || vs!==!(v>=490 && v<492))$fatal(1,"Sync mismatch");
   if(fs!==(h==0 && v==0))$fatal(1,"Frame pulse mismatch");
   if(de)active=active+1;if(!hs)hs_low=hs_low+1;if(!vs)vs_low=vs_low+1;if(fs)starts=starts+1;
  end
  if(active!=614400 || hs_low!=100800 || vs_low!=3200 || starts!=2)$fatal(1,"Frame totals wrong");
  rst_n=0;#1;if(x!==0 || y!==0)$fatal(1,"Reset failure");
  $display("VIDEO_TIMING_TEST_PASS two frames 800x525, active640x480, HS96, VS2");$finish;
 end
 initial begin #9000000;$fatal(1,"timeout");end
endmodule
