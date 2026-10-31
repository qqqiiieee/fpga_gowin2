V047 MIDI bitmap cycle-exact differential regression

Scope
  This folder owns its scripts, benches, snapshots and reports. The preserved
  midi_keyboard_before.v is NEVER edited. The runner checks its pinned SHA256.
  The CE/SOP candidate was explicitly authorized later; its only production
  write is src/midi_keyboard.v, reproducibly generated from the preserved RTL by
  apply_ce_sop_candidate.py. Do not rerun that transformer over newer development.

Frozen CE/SOP candidate
  0a51924531c4c981398d5ab98182a31da8c668ccdf5ec8311b73cf604de22969
Preserved baseline
  08c12d1f527fdb8d2e74dd57df86b8e744931176d47f398d069ae6be84a2a58d

Run from the project root (offline; Icarus only)
  python tests/midi_bitmap_v047/run_diff.py --expected-sha 0a51924531c4c981398d5ab98182a31da8c668ccdf5ec8311b73cf604de22969 --seeds 1,203047 --clock-hz 250000
  Additional deterministic random seeds are comma separated; default 1,203047,104729.
  The runner refuses a frozen-source SHA mismatch and fails if any snapshotted
  source or test input changes during the run. Each run compiles immutable copies.
  Two seeds run in parallel, each with a900-second wall limit and a live log.
  A timeout or intentionally stopped earlier1MHz run is never treated as a pass.

Comparator controls
  python tests/midi_bitmap_v047/run_diff.py --baseline-selfcheck --seeds 1
  python tests/midi_bitmap_v047/run_diff.py --mutation receipt --seeds 1
  python tests/midi_bitmap_v047/run_diff.py --mutation held --seeds 1
  Mutation checks change ONLY generated copies; success means DIFF_FAIL is caught.

What is compared
  All 33 declared outputs, with no valid-field masking, before each active clock
  edge and after nonblocking assignments. Case inequality detects X/Z differences;
  independent X rejection prevents two unknown outputs from falsely passing.
  Public ready/suppress/mapping signals and real UART 8N1 frames drive both copies.
  Baseline internal signals are READ ONLY collision-coverage witnesses, never
  stimulus feedback or an expected-state model. No force/release or UART stubs.

Coverage
  MAPPING_ENABLE=1 throughout; runtime disabled and identity-enabled stages each
  run all 128 raw pitches, duplicate On/Off, velocity-zero Off, sustained release,
  scan retrigger, CC123, CC120, full FIFO, overflow/recovery, controls and four Pads,
  bend, running status, realtime/SysEx/common/filtering, sensing and bad stop/break.
  Exact suppress+pop On, suppress+pop Off, suppress+key On/Off, and suppress+panic
  OLD-held collisions are required by counters. Full FIFO+direct push+pop is also
  required. One shifted-bank case verifies raw held/receipt and suppress release.
  A public-event scoreboard checks observable release/retrigger semantics, and
  stalled FIFO event fields must remain stable outside explicit cancel boundaries.

Timing and limitations
  Default250kHz clock,8 clocks/bit at31250 baud; the UART half-bit timer is4,
  TIMER_BITS=3, and two synchronizer stages still fit the stop-bit sample. Two
  idle clocks between bytes permit registered consumers to observe the last
  stop-bit-clock result; the UART bit rate and every test case are unchanged.
  Original mapping timeout formula is unchanged:
  ((250000+15625)/31250)*10 =80 clocks. Active Sensing uses20ms/5000 clocks.
  --clock-hz 1000000 retains32 clocks/bit and320 idle clocks but simulates slower.
  This does not certify production 27MHz/350ms timing, resource fit, routing,
  physical UART/electrical behavior, or hardware audio. No Gowin build or flashing
  is performed by these scripts. Parent task owns synthesis and any later release.

Result locations
  final_latest.json and REPORT.txt: most recent frozen final comparison.
  results/<UTC timestamp>/: exact source snapshots, derived module/interface,
  compile log, simulation log, per-case counters, tool hashes, input hashes.
  selfcheck_latest.json / mutation_latest.json: controls, not a production pass.
  Earlier failed selfcheck logs are retained. The first selfcheck exposed an
  over-strict expected event order with synchronous mapping: a high retrigger On
  can precede the final low-pitch scan Off. The scoreboard now permits that
  interleaving while requiring each Off once in pitch order, exactly one On,
  no stale high-pitch Off, AND strict baseline/current cycle equivalence.
