// V047: four-note groups share start/duration. offset0=0 is the root;
// three packed 5-bit positive offsets are strictly ascending (0 = absent).
// Practice requires a FRESH NoteOn for every target after entering this step,
// and all target physical keys held together. Pedal tails do not count.
// RAM bubbles preserve context. External pause drops incomplete attempts.
module guide_chord_modes(
 input clk,rst_n,input [1:0] mode,input running,suspended,restart,score_ready,
 input [6:0] expected_note,input [14:0] expected_offsets,input expected_valid,
 input [5:0] step_index,input midi_note_on,input [6:0] midi_note,
 input [31:0] held_keys,
 output practice_hold,output demo_valid,output [6:0] demo_note,
 output [14:0] demo_offsets,output demo_retrigger
);
 reg [1:0] mode_q;
 reg [5:0] target_step;
 reg [6:0] target_note;
 reg [14:0] target_offsets;
 reg known,accepted,armed,demo_active,trigger_q;
 reg [3:0] seen;
 wire changed=!known || step_index!=target_step || expected_note!=target_note || expected_offsets!=target_offsets;
 wire clear_context=restart || mode!=mode_q || !running;
 wire [3:0] required={|target_offsets[14:10],|target_offsets[9:5],|target_offsets[4:0],1'b1};
 wire [3:0] held,hit;
 genvar i;
 generate for(i=0;i<4;i=i+1)begin:g
  wire [4:0] delta;
  if(i==0)assign delta=0;else assign delta=target_offsets[(i-1)*5+:5];
  wire [6:0] pitch=target_note+{2'b0,delta};
  wire [6:0] key_index=pitch-7'd41;
  assign held[i]=!required[i] || (pitch>=41 && pitch<=72 && held_keys[key_index[4:0]]);
  assign hit[i]=required[i] && midi_note==pitch;
 end endgenerate
 assign practice_hold=rst_n && mode==2 && running &&
     (!score_ready || (expected_valid && (clear_context || changed || !accepted)));
 assign demo_valid=rst_n && mode==1 && running && !suspended && !clear_context && demo_active &&
     (!score_ready || (expected_valid && !changed));
 assign demo_note=target_note;
 assign demo_offsets=target_offsets;
 assign demo_retrigger=demo_valid && trigger_q;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin mode_q<=0;target_step<=0;target_note<=0;target_offsets<=0;
   known<=0;accepted<=0;armed<=0;demo_active<=0;trigger_q<=0;seen<=0;
  end else begin
   mode_q<=mode;trigger_q<=0;
   if(clear_context)begin known<=0;accepted<=0;armed<=0;demo_active<=0;seen<=0;end
   else if(suspended)begin armed<=0;demo_active<=0;if(!accepted)seen<=0;end
   else if(!score_ready)armed<=0;
   else if(!expected_valid)begin armed<=0;demo_active<=0;end
   else begin
    if(changed)begin
     target_step<=step_index;target_note<=expected_note;target_offsets<=expected_offsets;
     known<=1;accepted<=0;armed<=!midi_note_on;seen<=0;
    end else if(mode==2)begin
     // Clear a previously struck member on physical release. Merely tapping
     // each target in turn never completes a chord; restrike missing members.
     seen<=seen & held;
     if(!midi_note_on)armed<=1;
     else begin armed<=0;if(armed)seen<=(seen & held)|hit;end
     if((seen & required)==required && &held)accepted<=1;
    end else armed<=0;
    if(mode==1 && expected_note>=41 && expected_note<=72)begin
     demo_active<=1;if(changed || !demo_active)trigger_q<=1;
    end else demo_active<=0;
   end
  end
endmodule
