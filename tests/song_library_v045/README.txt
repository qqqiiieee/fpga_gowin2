V045 built-in song library sidecar / integration handoff
=======================================================
Scope and status
  Root AGENTS.md was read. This is development input only, NOT a firmware release.
  All created/edited files belong to tests/song_library_v045, the new script
  scripts/generate_song_library_v045.py, or src/piano_song_rom_v045.vh.
  Existing production .v, project files, constraints, ESP sources, release folders
  and hardware were not edited or operated by this sidecar.
  No FPGA synthesis, PnR, firmware compilation, programming, or publication ran.
  Parent owns integration and concurrent ESP recording fixes.

Library
  ID 0: Twinkle Twinkle Little Star / 小星星（保留原版）
        42 events = 42 notes; MIDI60..69; 120 BPM; 46875 samples/beat.
        48 melody beats + 2 count-in = 50 beats; end_tick=3200.
        All 42 old pitches and durations retained. Phrase ends 6/13/20/27/34/41
        last two beats; other events last one beat. No new external arrangement.
  ID 1: Lantern Steps / 灯阶练习曲（原创）
        48 events = 44 notes + 4 rests; MIDI48..72; F major; 112 BPM.
        50223 samples/beat; 32 melody beats + 2 count-in = 34; end_tick=2176.
        Eight 4/4 bars, arpeggios/register changes and repeated C4 articulation.
  ID 2: River Bridges / 溪桥练习曲（原创）
        48 events = 42 notes + 6 rests; MIDI41..70; D minor; 100 BPM.
        56250 samples/beat; 32 melody beats + 2 count-in = 34; end_tick=2176.
        Eight 4/4 bars, F2 excursion, Bb/C-sharp and low/high register leaps.
  Both added melodies were composed for this task; no downloaded score,
  contemporary song or claimed third-party license was used.
  Both have eighth, quarter, dotted-quarter notes and explicit rests.
  ID 3 is reserved for existing custom scores. EVERY new function returns
  empty data for ID 3; do not silently map it to built-in song 0.

Source of truth and commands (run from project root)
  tests/song_library_v045/source.json is the editable, machine-readable source.
  events_note_duration_quarters holds ordered [MIDI,duration] pairs; 0 means rest.
  Source count, total duration, IDs, BPM and physical range are validated.
  tests/song_library_v045/library.json is the generated expanded form with
  explicit step, note/rest, start, duration, tick and count/BPM metadata.
  Each quarter here is ONE QUARTER OF A BEAT, not a quarter note:
     eighth note=2 quarters=32 ticks; quarter note=4 quarters=64 ticks;
     dotted quarter=6 quarters=96 ticks; half note=8 quarters=128 ticks.
  source.start is melody-relative; absolute_start_quarter/start_tick include
  the fixed two-beat count-in. Every rest consumes one event/step.
  The source schema is an internal library schema, not the phone upload schema;
  the current uploader represents rests as gaps and rejects note=0 events.

  Generate and run built-in Python validation/negative tests:
    python scripts/generate_song_library_v045.py
  Verify deterministic outputs, then run isolated native Verilog simulation:
    python scripts/generate_song_library_v045.py --check --simulate
  Optional simulator directory:
    ... --iverilog-bin D:/path/to/iverilog/bin
  --check does not rewrite source/include/library. It does refresh validation.json;
  --simulate additionally writes only tests/song_library_v045/simulation/.
  No dependencies beyond Python standard library and optional Icarus Verilog.

Synthesizable function interface (Verilog-2001)
  Include INSIDE each consuming module:
    `include "src/piano_song_rom_v045.vh"
  This matches the project's root include-search convention. Alternatively add
  src to include paths and include "piano_song_rom_v045.vh".
  Deliberately no global `ifndef guard: each module needs its local functions.
  No modules are defined by the include and no extra top-level ports are created.

  song_v045_count(song_id[1:0]) -> [5:0] total events INCLUDING rests
  song_v045_total_beats(song_id) -> [5:0] beats INCLUDING two-beat count-in
  song_v045_bpm(song_id) -> [7:0] BPM (zero for custom/reserved ID3)
  song_v045_beat_samples(song_id) -> [17:0] precomputed 93750Hz sample period
    Formula evaluated in Python: round(93750*60/BPM), never in RTL.

  song_v045_event(song_id, step[5:0]) -> [18:0]
    [18:11] absolute start quarter, including count-in
    [10:7] duration in quarter-beat units
    [6:0] MIDI or 0 for rest
    Invalid step/id -> zero. Rest is distinguished by nonzero duration.
    Exact event start tick = {event_data[18:11],4'b0000}.
    Exact event duration ticks = {event_data[10:7],4'b0000}.

  song_v045_slot(song_id, absolute_quarter[7:0]) -> [7:0]
    [7] active EVENT, including rest (not a note gate)
    [6] first quarter of event (also true for a rest's first quarter)
    [5:0] step, zero in count-in, last step at/after end
    Count-in and at/after end clear [7:6]. Input address is roll_tick[11:4].
    Beat number roll_tick[11:6] is insufficient for the new rhythms.

  song_v045_next_note(song_id, step) -> [6:0]
    Next pitched note AFTER the supplied step, skipping any intervening rests.
    Last/invalid event -> 0. During count-in use event 0's note instead.

  song_v045_word(song_id, absolute_quarter) -> [31:0]
    Convenient composite view, with existing custom-score word BIT POSITIONS:
      [31:24] velocity 96 when valid, else 0 (no audio is generated here)
      [23] next_valid; [22:16] next MIDI (previews first note during count-in)
      [15] pitched duration > one beat, a coarse hint only
      [14] note onset-quarter; [13] valid pitched note
      [12:7] step including rests; [6:0] note, or 0 outside a pitched event
    Unlike uploaded custom words, explicit rests retain their own step number.
    At/after end the last step is retained; valid/onset/next all clear.
    This helper inlines event, slot and next lookups; call it once per consumer.

Required parent integration (production files intentionally left untouched)
  Inspection found three dependencies:
    src/piano_roll_score.v: hard-coded whole-beat ROM for all three old songs.
    src/piano_roll_guide.v: score + next_score instances, whole-beat long_note
      tables, fixed built-in tempo, C4..G5 twelve-pad cue_mask conversion.
    src/piano_roll_renderer.v: a third score instance using future_tick[11:6],
      whole-beat onset gap for built-ins, MIDI41..72 physical renderer.
  Legacy src/song_guide.v separately embeds old melody_mask/long_note tables.
  Replacing only guide note data would leave the rendered roll/legacy hints old.

  1. Source guide: select built-in data for IDs0..2; retain the custom ID3 path
     and its bank/config handshake. Keep latched roll_song (not live song_id).
     Example single-query wiring inside the guide module:
       wire [31:0] builtin_word_v045 = song_v045_word(roll_song,roll_tick[11:4]);
       wire [5:0] builtin_step_v045 = builtin_word_v045[12:7];
       wire [18:0] builtin_event_v045 = song_v045_event(roll_song,builtin_step_v045);
       // expected_note = builtin_word_v045[6:0]
       // expected_valid = active && !done && builtin_word_v045[13]
       // next_note/next_valid = builtin_word_v045[22:16]/[23]
       // total_steps/total_beats = song_v045_count/total_beats(roll_song)
     Remove old long_note and next_beat_index decisions from the built-in path.
     Rests must advance by time and must not require MIDI0 or physical key input.
     Step count includes rests; only word[13] means a played/scored note.

  2. Renderer: use song_v045_word(roll_song,future_tick[11:4]) on the BUILT-IN
     path too. Keep !future_tick[12] guard: never let a 13-bit future tick wrap
     to quarter 0 when sliced down to 8 bits. Keep !roll_done and MIDI bounds.
     For these new word onsets use future_tick[3:0]<2 to cut the onset gap;
     the old built-in future_tick[5:0]<2 misses eighth-note starts.
     Same-note adjacent steps stay distinct. Existing row/pixel pipeline timing
     and custom RAM read-tag/bank acknowledgement remain integration concerns.

  3. Tempo: built-ins now have different BPM. Feed precomputed beat_samples
     into the existing add64/compare/subtract fractional accumulator, retaining
     the remainder to prevent drift. Allocate enough phase bits (18 is enough
     for all supported BPM), and retain existing count-in/pause/restart/end logic.
     Do not merely change the displayed BPM while leaving BEAT_SAMPLES=46875.
     The constants for this library are 46875/50223/56250; small-BEAT_SAMPLES
     accelerated test modes need their own explicit override if retained.

  4. Duration/HUD: target_beats[1:0] cannot express half or dotted beats.
     Keep it documented as the existing coarse one-or-two-beat hint (word[15]), or
     add exact duration_quarters to the new guide mode interface. Do not truncate
     duration 2 quarters to zero beats. The exact 4-bit duration and 12-bit start
     are available from the event ROM for hold training/full-event progress.
     Existing custom-style within-quarter progress {roll_tick[3:0],4'd0} is
     compatible but is NOT whole-event progress. Whole-event progress for a
     dotted quarter requires the correct 96-tick denominator, not long_note.

  5. Physical keyboard: compare held bits for note-41 over all 32 physical keys.
     Current note_mask's twelve C4..G5 diatonic pads cannot represent low notes
     or black keys. Do not transpose these melodies to fit that old mask, and
     do not use a zero legacy cue_mask as evidence of a rest.
     Parent's new guide modes should use exact note and valid for matching.

  6. UI names: update song IDs1/2 wherever old Ode/Frere titles are displayed
     (at least src/hdmi_instrument_dashboard.v's song_label function/comments;
     compact dashboard uses a numeric song ID). Do this in the parent integration,
     including any ESP labels if needed; this sidecar does not change ESP.
     Old regressions asserting 32-event songs1/2 or 38 beats need new expectations.
     The existing piano_roll_score interface can only support the new rhythm if
     widened to quarter/tick resolution or replaced with these functions in BOTH
     domains. An unmodified whole-beat interface is NOT a drop-in replacement.

Resource design and validation boundaries
  Event ROM: 138 entries x 19 bits; timeline uses 8-bit index words, not 32-bit
  per-quarter payloads. Next-note ROM is 7 bits per event and skips rests offline.
  Used-address information including metadata is approximately 7478 bits before
  optimization versus 24576 bits for three dense 256x32 word tables. These are
  DATA SIZE estimates, not measured FPGA LUT/BSRAM usage or timing results.
  Constant combinational cases avoid runtime event scans, variable division,
  inferred score RAM write ports, clocks or additional CDC. A function is inlined
  per call site; synthesis may duplicate logic. Share one query per domain and
  assess resource/timing after parent integration. No synthesis claims are made.

  Native selfchecks cover all 4 IDs x 256 quarter addresses, all 4 x 64 step
  addresses, every metadata record, rest/onset/next-note boundaries, final silence,
  and including the same function file in two modules within one compilation.
  Python builds its reference by a sequential walk of source note/duration pairs;
  it does not parse generated Verilog to make expected answers.
  Negative cases reject out-of-keyboard notes, bad duration/type, count/time width
  overflow, mismatched metadata, duplicate IDs, bad BPM, missing rests, leading
  rest and changed retained song. Expanded metadata is always recomputed.
  validation.json records what actually ran and simulation/*.log contains output.
  Tests exercise this library only, not the parent's new guide modes, timing
  closure, hardware playback, MIDI matching, HDMI visual inspection or ESP fixes.
