# V045 display handoff

This change is confined to the display wrapper/dashboard and their Chinese text
assets. `hdmi_compact_text.v` did not exist: the existing dashboard included
`hdmi_ui_text.vh`. V045 adds `src/hdmi_compact_text.vh` as initialization constants
for the same synchronous character ROM. No new standalone HDL module/project
entry is required.

## Parent integration

Enable `.SONG_LIBRARY_ENABLE(1)` on `hdmi_live_display` and connect the source
clock domain signals `.guide_mode(guide_mode)` and `.practice_wait(practice_wait)`.
Mode values are 0=fixed BPM, 1=automatic play, 2=note-by-note practice. The flag
passes through dashboard to the existing `piano_roll_renderer` parameter.

The inputs are appended to the existing bundled `hdmi_status_cdc` handshake and
reach the dashboard only through the frame snapshot. No independent crossing is
introduced. All old bit positions remain fixed, including the custom bank tag:

| Configuration | Bits | New fields |
|---|---:|---|
| Piano + hybrid + expression + custom + V045 | 401 | mode[400:399], wait[398]; bank remains[397] |
| Piano + hybrid + expression + V045 | 400 | mode[399:398], wait[397] |
| Compact only + V045 | 292 | mode[291:290], wait[289] |
| Noncompact legacy + V045 flag | 242/252 | Flag ignored; old renderer retained |
| Any configuration with flag=0 (default) | unchanged | New inputs ignored and decoded as zero |

## Screen contract

- Built-ins: 小星星 120 BPM, 灯阶练习曲 112 BPM, 溪桥练习曲 100 BPM.
  The latter two are labeled 原创 in the library.
- Modes: 固定BPM / 自动演奏 / 逐音练习. Waiting shows amber 等待按键;
  completion and pause take precedence over a stale wait flag. Modes 0/1 ignore
  the wait bit. Uploaded song 4 retains its existing entry; its tempo displays
  `--- BPM` because its tempo is not part of this display status packet.
- Every normal page: y432 left/right = key1/key2, y464 left/right = key3/key4.
  Key1 short page/long timbre; key2 short start-pause/long KEY-STRUM-HYBRID;
  key3 short restart/long validation; key4 short song/long fixed-auto-practice.
  Library y272 explicitly shows the return from practice to fixed BPM.
- Test ownership retains priority on all four requested pages and shows
  `1路数 2逐路 3退出 4全32`. Test masks, counts, routing and controls are untouched.
- Piano pixels stay y144..399; its small FX row moves to y400..415 to leave room
  for both action rows. Chinese cells are 16x16 and ASCII cells 8x16. The longest
  action row is 31 half-cells (248px) inside the existing 256px text window.
- Production character ROM remains 4096x9 (V036 visualization already selected
  this size), font ROM remains 8192x8. Eight unused glyph pairs are reassigned;
  all 166 legacy-used Chinese glyphs and ASCII retain their codes/pixels. No new
  per-pixel Chinese combinational lookup is introduced. Actual CLS/timing fit is
  not measured: no Gowin compilation/synthesis or hardware programming is run.

## Changed/added implementation files

1. `src/hdmi_live_display.v`
2. `src/hdmi_compact_dashboard.v`
3. `src/hdmi_compact_text.vh` (generated, new)
4. `src/ui_font.hex`
5. `assets/ui_font_map.json`
6. `assets/ui_texts_v045.json` (new)
7. `scripts/generate_v045_display_text.py` (new)

All test code, frozen baselines, logs and previews are in
`tests/display_modes_v045/`. Existing top, guide, piano renderer, score ROM,
ESP code and validation scripts are read-only for this work. The baseline files
were captured before changing the owned display code.

## Reproduce and inspect

Run `python tests/display_modes_v045/run_tests.py` from the project root.
Use `--quick` to omit full frame captures. The script uses the existing local
Icarus installation, freezes HDL/assets into its result directory and never
invokes Gowin. Pillow is required only for PNG/contact-sheet output (an isolated
copy is available in `tests/display_modes_v045/tool_deps`).

`latest_report.json` points to the latest immutable result report and records
source hashes, scenario list, test logs and preview name. The tests include:

- 400-bit walking-1/0 plus 1,000 changing asynchronous source packets, reset,
  frame-boundary-only publication, original field positions, parameter pass-down.
- The original V035 CDC bench, unchanged, for ten historical parameter layouts.
- Literal Unicode pixel expectations independent of DUT row IDs/character ROM,
  with randomized consecutive tokens, glyph pixels, blanking and two-stage
  pixel latency. All four pages and test ownership are covered.
- A feature-disabled RGB miter against the frozen pre-edit dashboard, including
  every visible/blanking pixel of four targeted 800x525 scans (640x480 active).
- Legacy font preservation and existing text/font generation consistency checks.

`--reuse-cdc <previous-result-directory>` may reuse only passed CDC results whose
sources/benches still match exactly; the copied logs and original directory are
recorded. This avoids rerunning the same CDC tests after a pixel-oracle-only fix.

The final handoff was narrowed at the user's request: `run_targeted_pixels.py`
checks 32768 shuffled literal pixels plus explicit blanking in all 18 scenarios,
using the same frozen executable; `finalize_targeted.py` consolidates only actual
PASS logs and four complete previews. Extra full-page scans and the broad pixel
sweep were cancelled, not reported as production failures. The final result is
`targeted_report.json`, linked by `latest_report.json`.
