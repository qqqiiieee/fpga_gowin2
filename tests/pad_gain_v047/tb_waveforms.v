`timescale 1ns/1ps
module tb_waveforms;
 // Audio state advances only on fs_tick. Short idle spacing accelerates the long
 // envelope run; runner also compares 2,048 frames at the actual 288-clock period.
 parameter integer PERIOD=8;
 reg clk=0,rst_n=0,fs_tick=0,tick=0,clear=0;
 always #5 clk=~clk;
 reg [3:0] hits=0;
 reg [7:0] velocity=0,balance=128;
 reg [15:0] melody=0;
 wire [15:0] k,s,c,o;
 wire [3:0] busy;
 drum_voice kick(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(clear),
   .hit(hits[0]),.velocity(velocity),.sample(k),.busy(busy[0]));
 snare_voice snare(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(clear),
   .hit(hits[1]),.velocity(velocity),.sample(s),.busy(busy[1]));
 hat_voice #(.OPEN(0)) ch(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(clear),
   .hit(hits[2]),.velocity(velocity),.sample(c),.busy(busy[2]));
 hat_voice #(.OPEN(1)) oh(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(clear),
   .hit(hits[3]),.velocity(velocity),.sample(o),.busy(busy[3]));
 wire [15:0] y[0:5],old_y[0:5];
 genvar g;
 generate for(g=0;g<6;g=g+1)begin:lanes
  performance_mixer dut(.clk(clk),.rst_n(rst_n),.tick(tick),.balance(balance),
   .melody(g==5?melody:16'd0),.kick(g==0||g>=4?k:16'd0),
   .snare(g==1||g>=4?s:16'd0),.closed_hat(g==2||g>=4?c:16'd0),
   .open_hat(g==3||g>=4?o:16'd0),.sample(y[g]));
  performance_mixer_before old(.clk(clk),.rst_n(rst_n),.tick(tick),.balance(balance),
   .melody(g==5?melody:16'd0),.kick(g==0||g>=4?k:16'd0),
   .snare(g==1||g>=4?s:16'd0),.closed_hat(g==2||g>=4?c:16'd0),
   .open_hat(g==3||g>=4?o:16'd0),.sample(old_y[g]));
 end endgenerate
 integer peak_in[0:5],peak_new[0:5],peak_old[0:5],minimum[0:5],maximum[0:5],clipped[0:5];
 reg [63:0] energy_new[0:5],energy_old[0:5];
 integer v,b,i,j,t,frames=60400,quick=0,scenario=0,input_pcm,value,old_value,total,expected,checks=0,weight,square;
 integer f,raw;
 time last_tick_time=0;
 function integer sat(input integer x);
  sat=x>32767?32767:(x< -32768?-32768:x);
 endfunction
 function integer abs(input integer x);abs=x<0?-x:x;endfunction
 task advance;
  begin
   @(negedge clk);fs_tick=1;
   if(last_tick_time!=0 && $time-last_tick_time!=PERIOD*10)$fatal(1,"sample cadence mismatch");
   last_tick_time=$time;
   @(negedge clk);fs_tick=0;hits=0;tick=1;
   @(negedge clk);tick=0;
   repeat(PERIOD-3)@(negedge clk);
  end
 endtask
 initial begin
  if($value$plusargs("frames=%d",frames))begin end
  if($value$plusargs("quick=%d",quick))begin end
  f=$fopen("wave_metrics.csv","w");raw=$fopen("wave_trace.csv","w");
  $fdisplay(f,"scenario,velocity,balance,lane,samples,upstream_peak,old_peak,new_peak,new_min,new_max,old_energy,new_energy,clips");
  $fdisplay(raw,"frame,kick,snare,closed_hat,open_hat,old_mix,new_mix");
  for(scenario=0;scenario<(quick?1:2);scenario=scenario+1)
  for(v=0;v<(quick?1:6);v=v+1)
  for(b=0;b<(quick?1:2);b=b+1)begin
   // Second scenario staggers hits and retriggers active tails at two velocities.
   if(scenario==1 && v!=5)begin end else begin
   @(negedge clk);rst_n=0;hits=0;tick=0;fs_tick=0;melody=0;balance=b==0?128:255;last_tick_time=0;
   repeat(2)@(negedge clk);rst_n=1;
   repeat(128)advance;
   case(v)0:velocity=0;1:velocity=2;2:velocity=64;3:velocity=129;4:velocity=192;5:velocity=255;endcase
   if(quick)velocity=255;
   for(j=0;j<6;j=j+1)begin
    peak_in[j]=0;peak_new[j]=0;peak_old[j]=0;minimum[j]=0;maximum[j]=0;
    energy_new[j]=0;energy_old[j]=0;clipped[j]=0;
   end
   for(i=0;i<frames;i=i+1)begin
    hits=0;
    if(scenario==0 && i==0)hits=15;
    if(scenario==1)begin
     if(i==0)hits=1;if(i==37)hits=2;if(i==73)hits=4;if(i==109)hits=8;
     if(i==1024)begin hits=15;velocity=64;end
     if(i==2048)begin hits=15;velocity=255;end
    end
    melody=i%1024<512?32767:16'h8000;
    advance;
    total=$signed(k)+$signed(s)+$signed(c)+$signed(o);
    if(abs($signed(k))>8159||abs($signed(s))>8158||abs($signed(c))>8159||abs($signed(o))>8159)
     $fatal(1,"upstream exceeds proven bound");
    for(j=0;j<6;j=j+1)begin
     case(j)0:input_pcm=$signed(k);1:input_pcm=$signed(s);2:input_pcm=$signed(c);
      3:input_pcm=$signed(o);default:input_pcm=total;endcase
     weight=balance;
     expected=sat(((input_pcm>>>1)*weight+(j==5?$signed(melody)*(256-weight):0))>>>8);
     value=$signed(y[j]);old_value=$signed(old_y[j]);
     if(value!==expected)$fatal(1,"wave mismatch frame=%d lane=%d got=%d expected=%d",i,j,value,expected);
     if(j<5 && balance==128 && value!=2*old_value && value!=2*old_value+1)
      $fatal(1,"gain/rounding changed");
     if(j<5 && ((input_pcm>0&&value<0)||(input_pcm<0&&value>0)))$fatal(1,"sign reversal");
     if(abs(input_pcm)>peak_in[j])peak_in[j]=abs(input_pcm);
     if(abs(value)>peak_new[j])peak_new[j]=abs(value);
     if(abs(old_value)>peak_old[j])peak_old[j]=abs(old_value);
     if(value<minimum[j])minimum[j]=value;if(value>maximum[j])maximum[j]=value;
     square=value*value;energy_new[j]=energy_new[j]+square;
     square=old_value*old_value;energy_old[j]=energy_old[j]+square;
     if(value==32767||value== -32768)clipped[j]=clipped[j]+1;
     checks=checks+1;
    end
    if((quick || (scenario==0&&v==5&&b==0)))
     $fdisplay(raw,"%0d,%0d,%0d,%0d,%0d,%0d,%0d",i,$signed(k),$signed(s),$signed(c),$signed(o),$signed(old_y[4]),$signed(y[4]));
   end
   if(frames>60000 && busy!==0)$fatal(1,"voices did not finish");
   for(j=0;j<6;j=j+1)begin
    if(clipped[j]!=0)$fatal(1,"real voice/melody clipped");
    if(scenario==0&&velocity==0&&j<5&&peak_new[j]!=0)$fatal(1,"zero velocity audible");
    $fdisplay(f,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",scenario,velocity,balance,j,frames,
     peak_in[j],peak_old[j],peak_new[j],minimum[j],maximum[j],energy_old[j],energy_new[j],clipped[j]);
   end
   end
  end
  $fclose(f);$fclose(raw);
  $display("WAVEFORMS_PASS checks=%0d period=%0d frames=%0d",checks,PERIOD,frames);$finish;
 end
endmodule
