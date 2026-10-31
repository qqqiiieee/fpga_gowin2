V045 guide-mode sidecar handoff
=============================

Scope
  New files only, under D:/Gowin_project/instrument_phone_extensions_20261031:
    src/guide_play_modes.v
    tests/guide_modes_v045/{run_tests.py,tb_*.v,README.txt,latest_report.json,results/...}
  Existing RTL, project manifests, constraints, recording code and firmware were
  not edited. This is a source/test handoff, not a released firmware version;
  no UserCode, Gowin build, synthesis/P&R, release directory or burn was made.

Behavior / ports
  mode 0: fixed BPM; practice_hold=0, demo_gate/retrigger=0.
  mode 1: demo; no timeline hold; one-hot MIDI 41..72 gates, fixed velocity 192,
          one clk retrigger per new note identity, including adjacent same notes.
  mode 2: practice; freeze at each new valid note until a fresh matching NoteOn.
          Accepted note duration, long-note continuations and rests run normally.
          Wrong notes and earlier events are not queued. No automatic synthesis.
  mode 3: safe fixed-BPM fallback (no hold or demo output).

  clk/rst_n: same 27 MHz guide domain, asynchronous active-low reset.
  running: active && !done. False clears all accepted/pending context.
  suspended: page/menu/test ownership pause. Keeps a previously accepted practice
             note's status but discards NoteOn and immediately disables demo.
  restart: one clk (or held during reconfiguration); clears context even if the
           new score starts on the same step and pitch. Mode changes also clear.
  score_ready: 1 for stable score data, 0 only for a synchronous RAM read bubble.
               Tie to 1 for built-ins. A bubble freezes practice without erasing
               acceptance, and preserves the current demo gate without retrigger.
  expected_valid: stable score says this is a note; false with ready=1 is a rest.
  expected_note[6:0]: absolute MIDI pitch; no pitch-class/octave aliasing.
  step_index[5:0]: unique identity per successive note; stable across long notes.
                  Repeated pitch after a rest must still use a new step ID.
  midi_note_on/midi_note: actual fresh, same-domain, nonzero-velocity MELODY
                         NoteOn at receipt, with pitch aligned in that cycle.
  practice_hold: OR into the GUIDE pause only. Combinational step comparison
                 freezes before the first subsequent sample can advance.
  demo_gate[31:0]: bit k represents MIDI (41+k); invalid/outside pitches silent.
  demo_retrigger[31:0]: single clk per note, one-hot like demo_gate.
  demo_velocity[7:0]: constant 192; parameter DEMO_VELOCITY can replace it.

  A NoteOn at entry/change/restart, while suspended/unready, or still asserted
  across a boundary is ignored. A low observation arms the next pulse. No held
  bitmap exists here, so pre-held keys and sustain cannot satisfy a new step.
  Acceptance survives an external ownership pause; running=0 instead clears it.
  Demo resumes the remaining current note with a new attack after suspension.
  Demo gates disappear immediately on mode exit, restart, pause, reset or end.

Integration recommendations (NOT applied)
  1. src/top.v falling_guide.u_roll currently leaves expected_note/expected_valid
     unconnected. Connect those plus guide_step and guide_active/guide_done.
     Existing external pause is test_owned || ui_page!=0 || menu_key_pause.

       external_pause = test_owned || ui_page!=0 || menu_key_pause;
       modes.suspended = external_pause;
       modes.running = guide_active && !guide_done;
       u_roll.pause = external_pause || practice_hold;

     NEVER feed practice_hold back into modes.suspended: it would reject the key
     needed to release the hold. Keep sample_tick running; use guide.pause so
     fractional_phase, roll_tick and beat_pulse retain the existing semantics.

  2. Feed restart from ui_start/ui_restart and any accepted song/score replacement
     (including custom config/bank commit). The sidecar detects mode changes,
     but does not itself restart the guide. If a mode switch should replay from
     count-in, restart the guide and sidecar together in the parent controller.

  3. src/piano_roll_guide.v has INTERNAL is_custom/custom_word_ready. For future
     integration expose a public ready = !is_custom || custom_word_ready port.
     Do not treat expected_valid=0 as equivalent to RAM-ready, and do not use
     production hierarchical references. The custom bench uses hierarchy only
     to exercise the existing unmodified implementation.

     Its score_onset/builtin_onset are whole-quarter/whole-beat levels, not
     single-clk pulses. No onset port is needed here because step_index separates
     repeated notes. A one-cycle ready gap does not change the saved identity.

  4. src/midi_keyboard.v supplies a queued event_valid/event_ready stream.
     src/performance_input_hub.v arbitrates that stream with other sources.
     Neither a sustained bitmap nor a late audio/FIFO delivery establishes when
     a key was physically played. Do not wire their pending NoteOn directly into
     practice: a delayed event could otherwise be attributed to a later step.

     Add a READ-ONLY receipt observation at the existing parser when integrating;
     reuse key_on/direct_event, map_first (or the chosen score pitch convention),
     and the parser's suppress/blocked/panic/error cancellation rules. key_on
     already excludes velocity-zero NoteOn and non-melody channels. Export pulse
     and matching pitch together through the existing hierarchy, before the
     audio FIFO/arbiter. No additional UART is needed. If any new pipeline can
     cross step/restart/pause boundaries, carry receipt step/epoch metadata and
     discard mismatches before this module; pulse+pitch alone cannot determine
     arbitrary upstream age. The module itself never stores a pending NoteOn.

     Tests prove prior/extra/spanning/paused events are discarded at THIS port;
     they do not claim to validate a not-yet-implemented production receipt tap.

  5. src/instrument_audio.v and src/wavetable_synth.v use voice-SLOT gates.
     demo_gate is PITCH-indexed and cannot be ORed directly into those buses.
     Use a parent-owned route/adapter that supplies corresponding note/velocity
     data and a distinct demo owner. If using the allocator's note event input,
     sequence old-note Off and new-note On without losing either (they can have
     different pitches); adjacent equal notes still require explicit retrigger.
     A pitch-indexed destination can consume the masks directly.

     wavetable_synth captures retrigger every clk into pending_triggers; a
     sample_tick-only consumer could miss these pulses. Do not rely on a short
     gate gap to retrigger same-pitch notes. Flush any downstream queued demo
     events on suspension/mode exit/restart/end so they cannot start late.
     Gate=0 initiates normal release. Hard-zero PCM/ADSR/FX tail handling remains
     an audio ownership decision; no audible-silence claim is made by this RTL.

Resources
  20 explicit state bits: mode 2, saved step 6, saved pitch 7, five flags.
  Combinational comparisons/32 pitch decodes only; no extra UART, RAM, FIFO,
  divider, timer or per-key state. This is RTL accounting, NOT mapped resource
  utilization or timing closure; no FPGA compile was requested or performed.

Reproduce
  From the project root:
    python tests/guide_modes_v045/run_tests.py
  Optional --tool-dir selects an existing Icarus bin directory.
  Default reuses the existing local Icarus installation; no software download.
  Runs three simulations concurrently, with per-command 60-second timeout.
  All inputs are snapshotted and SHA-256 recorded before simulation. Each run
  has a unique UTC timestamp below this test directory; latest_report.json
  points to its results and records concurrent input changes, if observed.

Validation completed 2026-10-31 (simulation only)
  9/9 cases PASS:
    unit: 358 assertions; all 32 demo pitches, out-of-range pitch silence,
      wrong/stale/pre-held/held-across-boundary events, rest, RAM bubble,
      same-note repetition, accepted/waiting pause, mode switch, restart,
      stop/start, invalid mode, async reset and end.
    real piano_roll_guide: modes 0/1/2 at beat lengths 64 and 67 samples.
      Every sample checked against floor(accepted_samples*64/BEAT_SAMPLES).
      42 notes finish at 3200 roll ticks, including full two-beat durations.
      Demo emitted exactly 42 retriggers; fixed/practice emitted zero.
    real custom-score RAM: modes 1/2, SPB=23437, two-quarter C4, repeated C4,
      quarter rest, multi-quarter C5, 16 RAM read bubbles, natural end.
      Demo emitted 3 retriggers; practice accepted exactly 3 fresh NoteOns.
  Source hashes unchanged during this run. Icarus -Wall reports inherited
  timescale warnings for existing production files without their own timescale;
  no port-width/elaboration errors. Logs and exact source snapshots retained.

  FPGA compilation: NOT RUN. Integration: NOT APPLIED. Hardware/burn: NOT RUN.
