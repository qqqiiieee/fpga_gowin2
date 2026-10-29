# Tang Primer 20K instrument — cloud working contract

Read README.md and docs/V020_架构与AI交接.txt first. This checkout starts from V020,
not the older V015 on the repository's historical main branch. Keep Chinese
comments detailed around protocols, timing, fixed point arithmetic and resets.

- FPGA: GW2A-18C / GW2A-LV18PG256C8/I7. Top: src/top.v. Pin authority:
  src/multi_tone.cst. Preserve pins and the corrected matrix R2=M14 / R3=T12.
- Preserve 32 shared independent melody voices, two timbres, four Chinese HDMI
  pages and the 32-frequency verification mode. Resource/timing margin is small.
- Current audio: onboard PT8211 → 3.5mm. amp_* is intentionally zero;
  MAX98357 standard I2S and ESP32 bridge are not implemented.
- ADS A0: FSR brightness; A1: vibrato depth; A2: volume; A3: base pitch.
  FSRs do not create notes/drums. MIDI channel 10 drums remain supported.
- MIDI RX T8, 31250 8N1; melody CH1. Optics P8/P9, two SEN0503 pairs.
  GVS touch is analog MCP3208 CH0, not a TTP229 or ordinary R/C matrix.
- Keep earlier source files under tests/fixtures only when they are differential
  regression oracles. Do not upload other release folders or conversations.
- Cloud: `bash cloud/setup.sh`, then
  `.venv/bin/python cloud/run_checks.py --suite full`.
  Run relevant tests after changes; full in this command covers MIDI, optical,
  touch, standalone pressure and FSR/audio integration, not every historical test.
- Additional portable legacy regressions use scripts/run_iverilog_tests.py;
  inspect --list / --help and run groups appropriate to a change. HDMI primitive
  simulation and Gowin synthesis require the proper vendor tools/models.
- Keep failed assertions. Do not hide errors, replace tests with empty checks,
  or silently remove frozen-source guards. Update a guard only with a reviewed
  behavior change and a new expectation that still detects regressions.
- Cloud reports are digital simulation, not FPGA resource/timing signoff or
  physical audio/sensor verification. No COM ports, JTAG, microphone or USB board
  exist here. Never attempt local-device access, GUI programming or WinMM capture.
- No Gowin executable/license is included. Never claim a new .fs was built until
  an actual licensed Gowin run and timing report exist. Retain V020 fs as a
  reference; do not rename it as a new firmware version.
- Keep each future firmware release in its own dated version folder with changes,
  source, firmware identity and verification status; avoid desktop scattering.
- Do not merge to main, force push, change repo visibility, or add paid services
  unless the user's current request authorizes that action. Work on a task branch.
