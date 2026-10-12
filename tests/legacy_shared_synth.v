// Eight slots per voice, soft/bright morph, four tagged arithmetic stages.
// NUM_VOICES=32 uses 261/288 cycles at 93.75kHz; do not set this engine to 64.
// Every voice retains its own phase, ADSR, envelope divider and previous gate.
module legacy_shared_synth #(parameter NUM_VOICES=32,parameter TABLE_BITS=10,parameter ONE_SHOT=0,
  parameter FILE="fixtures/pressure_wave.hex")(
  input clk,input rst_n,input fs_tick,input diagnostic,
  input [NUM_VOICES-1:0] gate,input [NUM_VOICES-1:0] retrigger,
  input [NUM_VOICES*7-1:0] note_bus,input [NUM_VOICES*8-1:0] vel_bus,
  input [NUM_VOICES*4-1:0] timbre_bus,input signed [8:0] pitch,input [7:0] color,
  output reg [15:0] sample,output reg frame_done,output reg overrun,
  output [NUM_VOICES-1:0] voice_busy);
    localparam IW=$clog2(NUM_VOICES);
    localparam IDLE=0,ATTACK=1,DECAY=2,SUSTAIN=3,RELEASE=4;
    reg [23:0] phases [0:NUM_VOICES-1];
    reg [7:0] envelopes [0:NUM_VOICES-1];
    reg [7:0] subdivisions [0:NUM_VOICES-1];
    reg [2:0] states [0:NUM_VOICES-1];
    reg [6:0] previous_notes [0:NUM_VOICES-1];
    reg [NUM_VOICES-1:0] previous_gates,pending_triggers;
    reg [NUM_VOICES-1:0] gates_frame;
    reg [NUM_VOICES*7-1:0] notes_frame;
    reg [NUM_VOICES*8-1:0] velocities_frame;
    reg [NUM_VOICES*4-1:0] timbres_frame;
    reg signed [8:0] pitch_frame;
    reg [7:0] color_frame;
    reg diag_frame,last_diag,change_frame;
    reg running;
    reg [IW-1:0] voice_index;
    reg [2:0] slot;
    reg [15:0] rom [0:(32*(1<<TABLE_BITS))-1] /* synthesis syn_romstyle="block_rom" */;
    reg [TABLE_BITS+4:0] rom_address;
    reg [TABLE_BITS+3:0] tone_address;
    reg [15:0] rom_q;
    reg signed [15:0] soft_a,soft_b,bright_a,bright_b;
    reg signed [15:0] soft_base,bright_base,soft_interp;
    reg signed [25:0] soft_product,bright_product;
    reg [7:0] frac,env_slot;
    initial $readmemh(FILE,rom);
    always @(posedge clk) rom_q<=rom[rom_address];
    wire [6:0] selected_note=notes_frame[voice_index*7+:7];
    wire [7:0] velocity=velocities_frame[voice_index*8+:8];
    wire [3:0] timbre=timbres_frame[voice_index*4+:4];
    wire selected_gate=gates_frame[voice_index];
    wire [23:0] increment;
    note_table frequency(selected_note,increment);
    wire signed [13:0] bend_base=$signed({1'b0,increment[23:11]});
    wire signed [22:0] bend_delta=bend_base*pitch_frame;
    wire [23:0] bent_increment=increment+{bend_delta[22],bend_delta};
    wire [23:0] diag_increment;
    diagnostic_frequency #(.NUM_VOICES(NUM_VOICES)) diagnostic_table(voice_index,diag_increment);
    wire [23:0] current_phase=change_frame?24'd0:phases[voice_index];
    wire [7:0] current_env=change_frame?8'd0:envelopes[voice_index];
    wire [2:0] current_state=change_frame?IDLE:states[voice_index];
    wire [7:0] sub=subdivisions[voice_index];
    wire [7:0] sustain=(velocity>>1)+(velocity>>2);
    wire [7:0] attack=ONE_SHOT?8'd4:(timbre==0 || timbre==1 || timbre==8)?1:
      ((timbre==6 || timbre==7 || timbre==14)?8:3);
    reg [7:0] env_next;
    reg [2:0] state_next;
    always @(*) begin
      env_next=current_env;state_next=current_state;
      if(diag_frame) begin env_next=128;state_next=SUSTAIN;end
      else if(selected_gate && (change_frame || !previous_gates[voice_index] ||
          selected_note!=previous_notes[voice_index] || pending_triggers[voice_index])) begin
        env_next=0;state_next=ATTACK;
      end else case(current_state)
        IDLE:env_next=0;
        ATTACK:if(!selected_gate) state_next=RELEASE;
          else if({1'b0,current_env}+{1'b0,attack}>={1'b0,velocity}) begin env_next=velocity;state_next=DECAY;end
          else env_next=current_env+attack;
        DECAY:if(ONE_SHOT) begin
            // Finite plucked envelope: 0.17--0.35s at maximum velocity.
            if((timbre[1] && sub[6:0]==127) || (!timbre[1] && sub[5:0]==63)) begin
              if(current_env<=1) begin env_next=0;state_next=IDLE;end
              else env_next=current_env-1'b1;
            end
          end else if(!selected_gate) state_next=RELEASE;
          else if(sub[1:0]==3) begin
            if(current_env<=sustain+1'b1) state_next=SUSTAIN;else env_next=current_env-1'b1;
          end
        SUSTAIN:if(!selected_gate) state_next=RELEASE;
        RELEASE:if(sub[3:0]==15) begin
          if(current_env<=1) begin env_next=0;state_next=IDLE;end else env_next=current_env-1'b1;
        end
        default:begin env_next=0;state_next=IDLE;end
      endcase
    end
    wire [NUM_VOICES-1:0] consumed=(running && slot==0)?({{(NUM_VOICES-1){1'b0}},1'b1}<<voice_index):0;
    always @(posedge clk or negedge rst_n)
      if(!rst_n) pending_triggers<=0;
      else pending_triggers<=(pending_triggers & ~consumed)|retrigger;
    genvar g;
    generate for(g=0;g<NUM_VOICES;g=g+1) begin : busy_flags
      assign voice_busy[g]=(states[g]!=IDLE || envelopes[g]!=0);
    end endgenerate
    reg v0,v1,v2,v3,last0,last1,last2,last3;
    reg signed [15:0] soft0,bright0,soft1,interp2,sample3;
    reg signed [25:0] blend_product1;
    reg [7:0] env0,env1,env2,color0;
    reg signed [27:0] accumulator;
    wire signed [16:0] soft_difference=$signed(soft_b)-$signed(soft_a);
    wire signed [16:0] bright_difference=$signed(bright_b)-$signed(bright_a);
    wire signed [26:0] soft_result=$signed(soft_base)+(soft_product>>>8);
    wire signed [26:0] bright_result=$signed(bright_base)+(bright_product>>>8);
    wire signed [16:0] blend_difference=$signed(bright0)-$signed(soft0);
    wire signed [26:0] blend_result=$signed(soft1)+(blend_product1>>>8);
    wire signed [24:0] amplitude_product=$signed(interp2)*$signed({1'b0,env2});
    wire signed [27:0] final_sum=accumulator+sample3;
    // Diagnostic uses conservative linear gain; normal mode has a gentle knee.
    wire signed [27:0] scaled=diag_frame?(final_sum>>>IW):(final_sum>>>2);
    wire [27:0] magnitude=scaled[27]?-scaled:scaled;
    wire [27:0] compressed=(!diag_frame && magnitude>16000)?
      (28'd16000+((magnitude-16000)>>2)):magnitude;
    wire [15:0] bounded=compressed>32767?16'd32767:compressed[15:0];
    integer i;
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        running<=0;slot<=0;voice_index<=0;sample<=0;frame_done<=0;overrun<=0;
        gates_frame<=0;notes_frame<=0;velocities_frame<=0;timbres_frame<=0;pitch_frame<=0;color_frame<=0;
        previous_gates<=0;diag_frame<=0;last_diag<=0;change_frame<=0;
        rom_address<=0;tone_address<=0;frac<=0;env_slot<=0;accumulator<=0;
        soft_a<=0;soft_b<=0;bright_a<=0;bright_b<=0;
        soft_base<=0;bright_base<=0;soft_interp<=0;soft_product<=0;bright_product<=0;
        v0<=0;v1<=0;v2<=0;v3<=0;last0<=0;last1<=0;last2<=0;last3<=0;
        soft0<=0;bright0<=0;soft1<=0;interp2<=0;blend_product1<=0;env0<=0;env1<=0;env2<=0;color0<=0;sample3<=0;
        for(i=0;i<NUM_VOICES;i=i+1) begin
          phases[i]<=0;envelopes[i]<=0;subdivisions[i]<=0;states[i]<=IDLE;previous_notes[i]<=0;
        end
      end else begin
        frame_done<=0;v0<=0;v1<=v0;v2<=v1;v3<=v2;last1<=last0;last2<=last1;last3<=last2;
        if(v0) begin blend_product1<=blend_difference*$signed({1'b0,color0});soft1<=soft0;env1<=env0;end
        if(v1) begin interp2<=blend_result[15:0];env2<=env1;end
        if(v2) sample3<=amplitude_product>>>8;
        if(v3) begin
          accumulator<=final_sum;
          if(last3) begin sample<=scaled[27]?-bounded:bounded;frame_done<=1;end
        end
        if(fs_tick) begin
          if(running || v0 || v1 || v2 || v3) overrun<=1;
          gates_frame<=gate;notes_frame<=note_bus;velocities_frame<=vel_bus;timbres_frame<=timbre_bus;
          pitch_frame<=pitch;color_frame<=diagnostic?8'd0:color;diag_frame<=diagnostic;change_frame<=diagnostic!=last_diag;last_diag<=diagnostic;
          accumulator<=0;voice_index<=0;slot<=0;running<=1;
        end else if(running) begin
          slot<=slot+1'b1;
          case(slot)
            0:begin
              rom_address<={1'b0,diag_frame?4'd0:timbre,current_phase[23:24-TABLE_BITS]};
              tone_address<={diag_frame?4'd0:timbre,current_phase[23:24-TABLE_BITS]};
              frac<=current_phase[23-TABLE_BITS:16-TABLE_BITS];env_slot<=env_next;
              phases[voice_index]<=current_phase+(diag_frame?diag_increment:bent_increment);
              envelopes[voice_index]<=env_next;states[voice_index]<=state_next;
              subdivisions[voice_index]<=change_frame?0:sub+1'b1;
              previous_gates[voice_index]<=selected_gate;previous_notes[voice_index]<=selected_note;
            end
            1:rom_address<={1'b0,tone_address[TABLE_BITS+3:TABLE_BITS],tone_address[TABLE_BITS-1:0]+1'b1};
            2:begin soft_a<=$signed(rom_q);rom_address<={1'b1,tone_address};end
            3:begin soft_b<=$signed(rom_q);rom_address<={1'b1,tone_address[TABLE_BITS+3:TABLE_BITS],tone_address[TABLE_BITS-1:0]+1'b1};end
            4:begin bright_a<=$signed(rom_q);soft_base<=soft_a;soft_product<=soft_difference*$signed({1'b0,frac});end
            5:begin bright_b<=$signed(rom_q);soft_interp<=soft_result[15:0];end
            6:begin bright_base<=bright_a;bright_product<=bright_difference*$signed({1'b0,frac});end
            7:begin
              soft0<=soft_interp;bright0<=bright_result[15:0];color0<=(ONE_SHOT && !diag_frame)?
                ((velocity<=64)?8'd0:((velocity>=192)?8'd255:((velocity-8'd64)<<1))):color_frame;
              env0<=env_slot;v0<=1;last0<=(voice_index==NUM_VOICES-1);
              if(voice_index==NUM_VOICES-1) running<=0;else voice_index<=voice_index+1'b1;
            end
          endcase
        end
      end
    end
endmodule
