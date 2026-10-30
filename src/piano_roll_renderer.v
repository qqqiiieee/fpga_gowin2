// Fixed 640x480 piano/roll overlay. TWO registered pixel stages, matching the
// compact character-ROM/font pipeline; covered and rgb have identical latency.
// x=35..604: 19 white keys, 30px each; 13 black keys, 18px at white boundaries.
// y=144..319 roll, 320..323 hit line, 324..399 keyboard (black ends at y369).
// MIDI48..79 = C3..G5. piano_keys is PHYSICAL HELD state, never voice busy/pads.
// 120BPM timing is supplied by the source: 64 ticks/beat, 1 pixel/tick downward.
// Tick0..127 is count-in. ONE combinational score lookup per raster row:
// future_tick = roll_tick + max(320-y,0), beat = future_tick>>6.
// The shared helper INCLUDES count-in in beat_index (beats0/1 are invalid).
// valid spans both beats of a two-beat note; onset only marks its first beat.
// Two pixels are removed at each onset, never at a continuation beat.
// Static x geometry is ONE 1024x18 synchronous block ROM. No division,
// multiplication, per-key dynamic comparators, extra frame buffer or oscillator.
module piano_roll_renderer(
    input pixel_clk,input rst_n,input [9:0] x,y,input de,
    input [31:0] piano_keys,input piano_outside,
    input [11:0] roll_tick,input [1:0] roll_song,input roll_active,roll_done,
    output reg [23:0] rgb,output reg covered
);
    localparam [23:0] PANEL=24'h172338,GRID=24'h22324a,BORDER=24'h34465f,
        WHITE=24'he2e8f0,BLACK=24'h080d16,CYAN=24'h51d6e8,
        GREEN=24'h21c6a8,AMBER=24'hf4bb4f,ALERT=24'hff5964;
    reg [17:0] geometry[0:1023] /* synthesis syn_romstyle = "block_rom" */;
    // Geometry construction is elaboration only. White IDs and key centres
    // are independent of runtime score/held state. Invalid bar index is 32.
    function integer white_note;
        input integer w;
        begin
            case(w)
                0:white_note=0;1:white_note=2;2:white_note=4;3:white_note=5;
                4:white_note=7;5:white_note=9;6:white_note=11;
                7:white_note=12;8:white_note=14;9:white_note=16;10:white_note=17;
                11:white_note=19;12:white_note=21;13:white_note=23;
                14:white_note=24;15:white_note=26;16:white_note=28;
                17:white_note=29;18:white_note=31;default:white_note=0;
            endcase
        end
    endfunction
    integer px,w,k,c,lower_id,upper_id,bar_id,key_edge,black;
    initial begin
        for(px=0;px<1024;px=px+1)begin
            lower_id=0;upper_id=0;bar_id=32;key_edge=0;black=0;
            for(w=0;w<19;w=w+1)begin
                k=white_note(w);c=50+30*w;
                if(px>=35+30*w && px<65+30*w)begin
                    lower_id=k;upper_id=k;key_edge=(px==35+30*w);
                end
                if(px>=c-6 && px<c+6)bar_id=k;
            end
            for(w=1;w<19;w=w+1)begin
                if(white_note(w)-white_note(w-1)==2)begin
                    k=white_note(w)-1;c=35+30*w;
                    if(px>=c-9 && px<c+9)begin upper_id=k;black=1;end
                    if(px>=c-6 && px<c+6)bar_id=k;
                end
            end
            geometry[px]={black[0],key_edge[0],bar_id[5:0],upper_id[4:0],lower_id[4:0]};
        end
    end
    wire [8:0] ahead=y<320 ? 10'd320-y : 9'd0;
    wire [12:0] future_tick={1'b0,roll_tick}+{4'd0,ahead};
    wire [6:0] score_note;
    wire score_valid,score_onset;
    wire [5:0] score_step,score_steps,score_beats;
    piano_roll_score u_score(.song_id(roll_song),.beat_index(future_tick[11:6]),
        .note(score_note),.valid(score_valid),.onset(score_onset),
        .step_index(score_step),.total_steps(score_steps),.total_beats(score_beats));
    // active=0 freezes source time; retain bars while paused. Only done hides
    // the score. Physical held feedback remains independent of active.
    wire target_valid=!roll_done && !future_tick[12] &&
        score_valid && score_note>=48 && score_note<=79;
    reg [17:0] geo0;
    always @(posedge pixel_clk)geo0<=geometry[x];
    reg [31:0] held0;
    reg [4:0] target0;
    reg target_valid0,bar0,beat0,black_row0,keyboard0,line0,inside0,border0;
    reg outside0,done0,playing0;
    always @(posedge pixel_clk or negedge rst_n)begin
        if(!rst_n)begin
            held0<=0;target0<=0;target_valid0<=0;bar0<=0;beat0<=0;
            black_row0<=0;keyboard0<=0;line0<=0;inside0<=0;border0<=0;
            outside0<=0;done0<=0;playing0<=0;
        end else begin
            held0<=piano_keys;target0<=score_note-7'd48;target_valid0<=target_valid;
            bar0<=target_valid && !(score_onset && future_tick[5:0]<2);
            beat0<=future_tick[5:0]==0;
            black_row0<=y<370;keyboard0<=y>=324;line0<=y>=320 && y<324;
            inside0<=de && x>=34 && x<=605 && y>=143 && y<=400;
            border0<=x==34 || x==605 || y==143 || y==400;
            outside0<=piano_outside;done0<=roll_done;playing0<=roll_active;
        end
    end
    wire is_black=black_row0 && geo0[17];
    wire [4:0] key_id=is_black ? geo0[9:5] : geo0[4:0];
    wire pressed=held0[key_id];
    wire cue=playing0 && target_valid0 && key_id==target0;
    reg [23:0] colour;
    always @* begin
        colour=PANEL;
        if(beat0)colour=GRID;
        if(bar0 && !geo0[15] && geo0[14:10]==target0)colour=CYAN;
        if(line0)colour=done0 ? GREEN : AMBER;
        if(keyboard0)begin
            colour=is_black ? BLACK : WHITE;
            if(!is_black && geo0[16])colour=BORDER;
            if(cue)colour=AMBER;
            if(pressed)colour=playing0 && target_valid0 ? (cue ? GREEN : ALERT) : CYAN;
        end
        if(border0)colour=outside0 ? ALERT : BORDER;
    end
    always @(posedge pixel_clk or negedge rst_n)begin
        if(!rst_n)begin rgb<=0;covered<=0;end
        else begin rgb<=inside0 ? colour : 24'd0;covered<=inside0;end
    end
endmodule
