`timescale 1ns/1ps
module tb_boundaries;
 reg clk=0,rst_n=0,tick=0;
 always #5 clk=~clk;
 reg [15:0] melody=0,kick=0,snare=0,closed_hat=0,open_hat=0;
 reg [7:0] balance=128;
 wire [15:0] sample,old_sample;
 performance_mixer dut(.*);
 performance_mixer_before old(.sample(old_sample),.*);
 integer smooth=128,checks=0,pos_clip=0,neg_clip=0,melody_checks=0;
 integer b,m,c,j,s,seed=47047,hold_value;
 function integer sat(input integer x);
  sat=x>32767?32767:(x< -32768?-32768:x);
 endfunction
 task frame(input integer mv,kv,sv,cv,ov,bv);
  integer sum,d,expected,old_expected,previous,new_value;
  begin
   @(negedge clk);
   melody=mv;kick=kv;snare=sv;closed_hat=cv;open_hat=ov;balance=bv;tick=1;
   previous=$signed(sample);
   if(smooth<bv)smooth=smooth+1;else if(smooth>bv)smooth=smooth-1;
   sum=kv+sv+cv+ov;d=sum>>>1;
   new_value=(mv*(256-smooth)+d*smooth)>>>8;
   expected=sat(new_value);
   old_expected=sat((mv*(256-smooth)+(sum>>>2)*smooth)>>>8);
   @(posedge clk);#1;
   if($signed(dut.drums_sum)!==sum || $signed(dut.drums_q)!==d)
    $fatal(1,"sum/sign mismatch sum=%d d=%d",sum,d);
   if(dut.balance_smooth!==smooth[7:0])$fatal(1,"balance slew changed");
   if($signed(sample)!==previous)$fatal(1,"early sample at capture");
   @(negedge clk);tick=0;
   repeat(2)begin @(posedge clk);#1;
    if($signed(sample)!==previous)$fatal(1,"pipeline latency changed");
   end
   @(posedge clk);#1;
   if($signed(sample)!==expected || $signed(old_sample)!==old_expected)
    $fatal(1,"arithmetic case=%d sum=%d melody=%d balance=%d got=%d expected=%d old=%d old_expected=%d",
           checks,sum,mv,smooth,$signed(sample),expected,$signed(old_sample),old_expected);
   checks=checks+1;
   if(new_value>32767)pos_clip=pos_clip+1;
   if(new_value< -32768)neg_clip=neg_clip+1;
   if(kv==0&&sv==0&&cv==0&&ov==0)begin
    if(sample!==old_sample)$fatal(1,"melody changed");
    melody_checks=melody_checks+1;
   end
  end
 endtask
 task settle(input integer bv);
  begin repeat(256)frame(0,0,0,0,0,bv);end
 endtask
 initial begin
  repeat(2)@(negedge clk);rst_n=1;
  // Every melody code at six balances, including full-gain 0 and near-drum-only 255.
  for(b=0;b<6;b=b+1)begin
   case(b)0:s=0;1:s=1;2:s=64;3:s=128;4:s=192;5:s=255;endcase
   settle(s);
   for(m=-32768;m<=32767;m=m+1)frame(m,0,0,0,0,s);
  end
  // Every balance, all sixteen sign corners, and both melody rails / silence.
  for(b=0;b<256;b=b+1)begin
   frame(0,0,0,0,0,b);
   if(smooth!=b)settle(b);
   for(c=0;c<16;c=c+1)for(m=0;m<3;m=m+1)
    frame(m==0?0:(m==1?32767:-32768),c&1?32767:-32768,
          c&2?32767:-32768,c&4?32767:-32768,c&8?32767:-32768,b);
  end
  // Odd signed sums exercise arithmetic rounding, cancellation and small negatives.
  settle(128);
  for(c=-9;c<=9;c=c+1)begin
   frame(0,c,0,0,0,128);frame(0,0,c,0,0,128);
   frame(0,0,0,c,0,128);frame(0,0,0,0,c,128);
   frame(0,32767,-32768,c,0,128);
  end
  for(j=0;j<10000;j=j+1)
   frame(($random(seed)&65535)-32768,($random(seed)&65535)-32768,
         ($random(seed)&65535)-32768,($random(seed)&65535)-32768,
         ($random(seed)&65535)-32768,$random(seed)&255);
  hold_value=$signed(sample);
  repeat(20)begin @(negedge clk);melody=~melody;kick=~kick;balance=~balance;
   @(posedge clk);#1;if($signed(sample)!==hold_value)$fatal(1,"output changed without tick");end
  // Asynchronous reset aborts an in-flight frame and restores default balance.
  @(negedge clk);tick=1;
  @(posedge clk);#1;rst_n=0;#1;
  if(sample!==0 || dut.valid!==0 || dut.balance_smooth!==128)$fatal(1,"reset failed");
  if(pos_clip==0||neg_clip==0)$fatal(1,"missing saturation coverage");
  $display("BOUNDARIES_PASS checks=%0d melody_checks=%0d positive_clips=%0d negative_clips=%0d",
           checks,melody_checks,pos_clip,neg_clip);
  $finish;
 end
endmodule
