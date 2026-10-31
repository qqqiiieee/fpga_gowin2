`include "src/piano_layout.vh"
// Fixed 640x480 piano/roll overlay. TWO registered pixel stages, matching the
// compact character-ROM/font pipeline; covered and rgb have identical latency.
// x=35..604: 19 white keys, 30px each; 13 black keys, 18px at white boundaries.
// y=144..319 roll, 320..323 hit line, 324..399 keyboard (black ends at y369).
// Display MIDI41..72 = F2..C5, matching the user-confirmed left edge. piano_keys is PHYSICAL HELD state, never voice busy/pads.
// Tempo is supplied by the source: 64 ticks/beat, 1 pixel/tick downward.
// Tick0..127 is count-in. Legacy mode uses one combinational lookup per row:
// future_tick = roll_tick + max(320-y,0), beat = future_tick>>6.
// The shared helper INCLUDES count-in in beat_index (beats0/1 are invalid).
// valid spans both beats of a two-beat note; onset only marks its first beat.
// Two pixels are removed at each onset, never at a continuation beat.
// Static x geometry is ONE 1024x18 synchronous block ROM. No division,
// multiplication, per-key dynamic comparators, extra frame buffer or oscillator.
module piano_roll_renderer #(parameter CUSTOM_SCORE_ENABLE=0,
    parameter SONG_LIBRARY_ENABLE=0)(
    input pixel_clk,input rst_n,input [9:0] x,y,input de,
    input [31:0] piano_keys,input piano_outside,
    input [11:0] roll_tick,input [1:0] roll_song,input roll_active,roll_done,
    output reg [23:0] rgb,output reg covered,
    input custom_write_clk,input custom_write_en,
    input [8:0] custom_write_addr,input [31:0] custom_write_data,
    input [31:0] custom_config,input frame_tick,
    // Tag from the SAME frame snapshot as roll_tick; suppress an old
    // timeline until its matching bank snapshot arrives after a commit.
    input roll_custom_bank,output custom_bank_ack
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
                0:white_note=0;
                1:white_note=2;
                2:white_note=4;
                3:white_note=6;
                4:white_note=7;
                5:white_note=9;
                6:white_note=11;
                7:white_note=12;
                8:white_note=14;
                9:white_note=16;
                10:white_note=18;
                11:white_note=19;
                12:white_note=21;
                13:white_note=23;
                14:white_note=24;
                15:white_note=26;
                16:white_note=28;
                17:white_note=30;
                18:white_note=31;
                default:white_note=0;
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
    wire [31:0] pixel_custom_config,custom_word;
    wire custom_word_ready;
    generate if(CUSTOM_SCORE_ENABLE)begin:custom_score
        // Bundled-data CDC, NOT 32 independent bit synchronisers. held_config
        // is frozen from request until the destination applies it at a frame
        // boundary and returns applied_toggle. Three pixel clocks of toggle
        // synchronisation give the whole bus settling time before capture.
        // Controller commits alternate banks and forbids BEGIN while its
        // two-flop-synchronised custom_bank_ack != custom_config[31]. This
        // protects the OLD pixel bank throughout pending/blanked frames.
        reg [31:0] held_config;
        reg request_toggle;
        reg applied_toggle;
        (* syn_preserve=1 *) reg ack_meta,ack_sync;
        (* syn_preserve=1 *) reg [1:0] source_reset_sync;
        always @(posedge custom_write_clk or negedge rst_n)
            if(!rst_n)source_reset_sync<=0;
            else source_reset_sync<={source_reset_sync[0],1'b1};
        // rst_n is released in the PIXEL domain. Only the two synchronizer FFs
        // above may see that asynchronous release; all source-domain functional
        // state releases on its own clock. Do not false-path functional resets.
        wire source_rst_n=source_reset_sync[1];
        always @(posedge custom_write_clk or negedge source_rst_n)begin
            if(!source_rst_n)begin held_config<=0;request_toggle<=0;ack_meta<=0;ack_sync<=0;end
            else begin
                ack_meta<=applied_toggle;ack_sync<=ack_meta;
                if(request_toggle==ack_sync && custom_config!=held_config)begin
                    held_config<=custom_config;request_toggle<=!request_toggle;
                end
            end
        end
        (* syn_preserve=1 *) reg req_meta,req_sync,req_settled;
        reg request_seen,pending_valid;
        reg [31:0] pending_config,active_config;
        reg bank_ack;
        always @(posedge pixel_clk or negedge rst_n)begin
            if(!rst_n)begin
                req_meta<=0;req_sync<=0;req_settled<=0;request_seen<=0;
                pending_valid<=0;pending_config<=0;active_config<=0;
                applied_toggle<=0;bank_ack<=0;
            end else begin
                req_meta<=request_toggle;req_sync<=req_meta;req_settled<=req_sync;
                if(req_settled!=request_seen)begin
                    pending_config<=held_config;pending_valid<=1;
                    request_seen<=req_settled;
                end
                if(frame_tick && pending_valid)begin
                    active_config<=pending_config;
                    bank_ack<=pending_config[31];
                    applied_toggle<=request_seen;pending_valid<=0;
                end
            end
        end
        assign pixel_custom_config=active_config;
        assign custom_bank_ack=bank_ack;
        wire [8:0] address={active_config[31],future_tick[11:4]};
        reg [8:0] read_tag;
        reg read_valid;
        custom_score_ram ram(.custom_write_clk(custom_write_clk),
            .custom_write_en(custom_write_en),.custom_write_addr(custom_write_addr),
            .custom_write_data(custom_write_data),.read_clk(pixel_clk),
            .read_addr(address),.read_data(custom_word));
        always @(posedge pixel_clk or negedge rst_n)
            if(!rst_n)begin read_tag<=0;read_valid<=0;end
            else begin read_tag<=address;read_valid<=1;end
        // Score address depends on y/time, never x. Each legal 640x480 raster
        // row prefetches during x=0..33, before the first border at34/key at35.
        // RAM therefore feeds stage0 from the SAME row without a third pixel
        // stage. Tag gating also makes a discontinuous raster jump safe.
        // At a bank flip it blanks one clock, strictly before the x35 panel.
        assign custom_word_ready=read_valid && read_tag==address;
    end else begin:no_custom_score
        assign pixel_custom_config=0;assign custom_word=0;
        assign custom_word_ready=0;assign custom_bank_ack=0;
    end endgenerate
    wire is_custom=CUSTOM_SCORE_ENABLE && roll_song==2'd3;
    wire custom_config_valid=pixel_custom_config[30] &&
        pixel_custom_config[29:24]!=0 && pixel_custom_config[23:18]!=0 &&
        pixel_custom_config[17:0]>=23437 && pixel_custom_config[17:0]<=187500;
    wire custom_in_range=custom_config_valid && custom_word_ready &&
        roll_custom_bank==pixel_custom_config[31] && future_tick>=128 &&
        future_tick<{1'b0,pixel_custom_config[23:18],6'd0};
    wire [6:0] score_note,builtin_note;
    wire score_valid,score_onset,builtin_valid,builtin_onset;
    wire [5:0] score_step,score_steps,score_beats;
    generate if(SONG_LIBRARY_ENABLE)begin:builtin_library
        wire [9:0] address={roll_song,future_tick[11:4]};
        wire [31:0] word_data;
        reg [9:0] read_tag;
        reg read_valid;
        piano_builtin_score_ram ram(.read_clk(pixel_clk),.read_addr(address),
            .read_data(word_data),.total_steps(score_steps),
            .total_beats(score_beats),.beat_samples());
        always @(posedge pixel_clk or negedge rst_n)
            if(!rst_n)begin read_tag<=0;read_valid<=0;end
            else begin read_tag<=address;read_valid<=1;end
        // Like the custom bank, prefetch each row at x=0..33. Tag includes
        // SONG as well as quarter: a frame song change cannot show old notes.
        // No third pixel stage is added. A discontinuous input jump blanks
        // the stale request; normal raster data is ready before the border.
        // Check the FULL 13-bit future time BEFORE using its sliced address:
        // overflow/past-end may physically read ROM but can never draw a bar.
        wire in_range=read_valid && read_tag==address && roll_song!=2'd3 &&
            future_tick>=128 && future_tick<{1'b0,score_beats,6'd0};
        assign builtin_note=word_data[6:0];
        assign builtin_valid=in_range && word_data[13];
        assign builtin_onset=word_data[14];
        assign score_step=word_data[12:7];
    end else begin:legacy_builtin
        piano_roll_score u_score(.song_id(roll_song),.beat_index(future_tick[11:6]),
            .note(builtin_note),.valid(builtin_valid),.onset(builtin_onset),
            .step_index(score_step),.total_steps(score_steps),.total_beats(score_beats));
    end endgenerate
    assign score_note=is_custom ? custom_word[6:0] : builtin_note;
    assign score_valid=is_custom ? (custom_in_range && custom_word[13]) : builtin_valid;
    assign score_onset=is_custom ? custom_word[14] : builtin_onset;
    // active=0 freezes source time; retain bars while paused. Only done hides
    // the score. Physical held feedback remains independent of active.
    wire target_valid=!roll_done && !future_tick[12] &&
        score_valid && score_note>=`PIANO_BASE_NOTE && score_note<=`PIANO_LAST_NOTE;
    reg [17:0] geo0;
    always @(posedge pixel_clk)geo0<=geometry[x];
    reg [31:0] held0;
    reg [4:0] target0;
    reg [14:0] offsets0;
    reg target_valid0,bar0,beat0,black_row0,keyboard0,line0,inside0,border0;
    reg outside0,done0,playing0;
    always @(posedge pixel_clk or negedge rst_n)begin
        if(!rst_n)begin
            offsets0<=0;held0<=0;target0<=0;target_valid0<=0;bar0<=0;beat0<=0;
            black_row0<=0;keyboard0<=0;line0<=0;inside0<=0;border0<=0;
            outside0<=0;done0<=0;playing0<=0;
        end else begin
            offsets0<=is_custom && custom_word[31] ? custom_word[30:16] : 15'd0;
            held0<=piano_keys;target0<=score_note-`PIANO_BASE_NOTE;target_valid0<=target_valid;
            // Custom onset marks ONE quarter, so its two-pixel separation
            // uses low FOUR bits; beat low6 would merge same-note quarters.
            bar0<=target_valid && !(score_onset &&
                ((is_custom || SONG_LIBRARY_ENABLE) ? future_tick[3:0]<2 : future_tick[5:0]<2));
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
    // Common 5-bit subtraction handles all four lane comparisons without
    // extra RAM, framebuffer or per-pitch renderer instances.
    function chord_hit;
      input [4:0] key,root; input [14:0] offsets;
      reg [4:0] delta;
      begin delta=key-root;chord_hit=key==root || (key>root &&
        ((offsets[4:0]!=0 && delta==offsets[4:0]) ||
         (offsets[9:5]!=0 && delta==offsets[9:5]) ||
         (offsets[14:10]!=0 && delta==offsets[14:10])));end
    endfunction
    wire cue=playing0 && target_valid0 && chord_hit(key_id,target0,offsets0);
    reg [23:0] colour;
    always @* begin
        colour=PANEL;
        if(beat0)colour=GRID;
        if(bar0 && !geo0[15] && chord_hit(geo0[14:10],target0,offsets0))colour=CYAN;
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
