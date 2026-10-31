V045 builtin BRAM / guide / renderer integration
================================================
Scope
  Production edits are restricted to src/piano_roll_guide.v,
  src/piano_roll_renderer.v, new src/piano_builtin_score_ram.v and
  src/piano_builtin_score.hex. The only generator added is
  scripts/generate_builtin_score_bram_v045.py. All tests/logs/caches live here.
  No top/menu/phone, project file, constraints, release or hardware changes.

Parent integration
  Set SONG_LIBRARY_ENABLE=1 on BOTH guide and renderer (through the display
  wrappers owned by the parent). Default 0 retains the exact old three songs.
  Add src/piano_builtin_score_ram.v and src/piano_builtin_score.hex to the
  parent's source/asset handling. Preserve src/piano_song_rom_v045.vh, which
  supplies ONLY the small metadata functions called by the new RAM wrapper.
  Run elaboration/synthesis with project-root include/readmemh paths, or copy
  the same src/ structure into its build directory. No project file is edited.
  Connect guide.score_ready to guide-mode score_ready; do not tie it high for
  enabled built-ins. Low means RAM/config bubble, not a silent musical rest.
  A preloaded custom word can already be ready when switching to custom; ready
  reports address validity, not a compulsory one-clock blank on every command.
  Existing pause/active/restart and custom-bank handshake remain authoritative.

Data format and resource structure
  Logical ROM is 1024 x 32, address {song[1:0], quarter[7:0]}.
  One quarter is 1/4 BEAT = 16 roll ticks, not a quarter note.
  It is instantiated once at source clock and once at pixel clock. No reset
  loops, async ROM read, added write port or cross-domain builtin data bus.
  [31:24] velocity (96 if pitched); [23] next_valid; [22:16] next MIDI;
  [15] duration > one beat; [14] first quarter of pitched event;
  [13] pitched valid; [12:7] step (including rests); [6:0] MIDI or zero.
  All fields match the reference song_v045_word/custom word bit positions.
  All 256 addresses per song are initialized, including count-in and tail.
  Bank 3 is zero and reserved for the separate uploaded custom-score RAM.
  Precomputed next fields skip rests and preview the first note in count-in.
  There is no second word/event/slot/next-note combinational query in V045.
  The old guide's two piano_roll_score instances and renderer's one instance
  exist only in SONG_LIBRARY_ENABLE=0 generate branches. Enabled test builds
  intentionally omit that old module from compilation to prove elimination.
  The full reference include defines event functions too, but these functions
  are never called by production RTL; they create no active score decoder.

Library and timebase
  ID0: 小星星 / Twinkle, retained 42 events, 50 beats incl count-in, 120 BPM,
       46875 samples/beat at 93750Hz, final tick3200.
  ID1: 灯阶练习曲 / Lantern Steps, original 48 events incl 4 rests,
       34 beats incl count-in, 112 BPM, 50223 samples/beat, final tick2176.
  ID2: 溪桥练习曲 / River Bridges, original 48 events incl 6 rests,
       34 beats incl count-in, 100 BPM, 56250 samples/beat, final tick2176.
  112 BPM is the reference's nearest integer period: 50223 samples/beat.
  Fractional tick remainder is retained; there is no per-beat truncation drift.
  Any BEAT_SAMPLES !=46875 preserves its parameter timebase for ALL built-ins,
  including <=0 clamping to1 and multi-tick advancement for values <64.
  Custom scores always retain custom_config's tempo.
  Eighth / quarter / dotted-quarter / half notes occupy 32 / 64 / 96 / 128
  ticks respectively. Rests consume their full scheduled time and step.
  beat_progress for enabled V045 is phase in CURRENT quarter (0..240), as for
  uploaded custom scores. target_beats is a coarse 1-or-2-beat hint; neither
  port claims to represent exact dotted/eighth duration or whole-note progress.
  Exact duration is represented by the contiguous quarter words/step IDs.
  Legacy twelve-pad cue masks do not cover every physical pitch; parent demo
  and practice must use expected_note/expected_valid/score_ready and the
  unchanged 32-key MIDI41..72 layout, not treat zero pad mask as a rest.

RAM latency and renderer
  Source score_ready checks read_valid and the complete song+quarter tag;
  custom additionally checks valid config and pending config changes.
  On quarter changes old source note/valid/cues are suppressed for one clk.
  Timer advancement itself is not stalled by this output; parent practice
  can pause while unready. Normal source has 288 clocks per audio sample.
  Pixel RAM follows the existing custom approach: prefetch each raster row
  during x=0..33. First panel border x34/key x35 has settled data. A sudden
  in-panel time/song jump blanks stale data. RGB and covered remain aligned
  through the original TWO pixel stages; no additional display latency.
  Onset gap uses low FOUR future_tick bits for both custom and V045 so eighth
  notes/repeated MIDI pitches remain separated; continuation quarters have
  no added gap. Full 13-bit time/end guards prevent truncated-address wraps.
  MIDI range, all key geometry, held-key feedback and panel borders are intact.

Commands (PowerShell, from D:/Gowin_project/instrument_phone_extensions_20261031)
  python scripts/generate_builtin_score_bram_v045.py
  python scripts/generate_builtin_score_bram_v045.py --check
  python tests/builtin_score_v045/run_tests.py --workers 2 --timeout 600
  python tests/builtin_score_v045/run_tests.py --case ready_switch
  python tests/builtin_score_v045/check_resources.py

Validation
  generation.json checks source/library/reference-include consistency and HEX
  determinism without editing the already completed library owner's files.
  run_tests.py freezes inputs, emits a separate chronological oracle directly
  from source.json raw [pitch,duration] pairs, and checks all 1024 words.
  Icarus Verilog-2001 checks synchronous ROM behavior, metadata, ready tags,
  source pitch/step/rest/next fields, quarter HUD, exact full-song timing,
  112/100 BPM, pauses/restarts/completion and accelerated B=0,1,7,63,64,65,67,1001.
  Default B=46875 tests walk every sample through all three complete songs.
  Pixel test compares 4,443,200 real output pixels: all quarters at offsets
  0/1/2/15, full vertical extent, all32 held bits, black/white boundary,
  reserved song/end/13-bit overflow, pause/done and discontinuous song changes.
  Legacy guide tests cover the same nine beat parameters; a frozen old guide
  and renderer provide cycle-by-cycle builtin compatibility evidence.
  Existing custom tests run from local frozen copies with library ALSO enabled:
  tempos 23437/46875/187500, two asynchronous pixel phases, bank/frame commits.
  Detailed commands, hashes, metrics, failed attempts and pass results are
  retained in results/*/report.json with latest_report.json as the latest run.
  Initial 240-second limits were too short for two full real-tempo cases during
  concurrent workspace testing. Their timeout logs are retained. The runner
  now defaults to600 seconds and supports --reuse-report PATH: only passing
  cases with identical RTL/data/bench hashes and compile options are reused;
  failed/timed-out cases run again. Reused records name their original report.

Optional resource check boundary
  check_resources.py maps an isolated guide+renderer core with custom enabled
  and compares library0/library1 using already available YoWASP/Yosys gw2a.
  It dumps the actual geometry ROM with Icarus and replaces ONLY the frozen
  mapping copy's old nested geometry initializer with an identical readmemh.
  It checks synchronous 1024-deep builtin memories, absence of old decoders,
  absence of runtime div/mod, and records mapped primitive counts.
  This is experimental mapping, NOT vendor CLS packing or whole-device fit,
  timing closure, a firmware build, physical HDMI/audio testing or programming.
  See resource_report.json; no claim of fitting the final 18-CLS margin is made.

Observed isolated mapping (current RTL, custom enabled in both cases)
  library0 -> library1: LUT1..4 sum 750 -> 483; ALU 441 -> 259.
  SPX9 1 -> 4, SDPX9B 2 -> 2: three additional block RAM primitives.
  New builtin guide store maps to two SPX9; pixel store maps to one SPX9
  after unused word bits are optimized. Geometry/custom memories are separate.
  DFF-family sum 332 -> 335. Runtime div/mod cells: 0 in both cases.
  Enabled hierarchy has synchronous 1024x32 builtin memory and no old
  piano_roll_score module. Exact source hashes/netlist paths are in the report.
  These numbers are Yosys primitive counts, not vendor CLS counts or timing.

Final freeze / focused handoff
  Per the final request to stop expanding tests and unblock fulltop compilation,
  two redundant full-period reruns were stopped. No production RTL was changed.
  freeze_report.json and latest_report.json now describe the FINAL scope:
    25 current focused simulation cases PASS;
    2 prior full-period cases PASS, with all relevant RTL/test/data compared.
  The only difference for those prior cases is standalone guide comment lines;
  executable Verilog, bench, metadata, HEX and chronological oracle are identical.
  finalize_focused.py verifies this equivalence and current resource hashes.
  Original failed timeout/stopped-repeat reports remain in their result folders.
  Latest passed=true does not claim that the stopped repeats finished; the
  report lists their status and separately cites earlier complete-period proof.
  Source is frozen; no unresolved RTL assertion failures. Parent may proceed
  with Gowin fulltop synthesis/packing to establish actual CLS fit and timing.
