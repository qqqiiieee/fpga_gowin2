# V030 cloud task contract
Read TASK.txt first. The source is the actually compiled/flashed V030, not V020 or main/V015.
Preserve all PMOD constraints: buttons A11/B11/N6/D11, MIDI T8, phone FPGA RX L9 <- ESP32 TX17, FPGA TX N8 -> ESP32 RX16. PMOD1 is unused. UART 115200 8N1 3.3V. Do not alter audio synthesis, I2S, MIDI sound pitch, FSR mapping, button semantics, or ESP32 protocol for a visual fix.
Work entirely in the cloud. Do not access Windows devices or request local compilation while the user is gaming. Cloud has no JTAG/COM/board and no configured licensed Gowin installation. Never label digital simulation as physical testing or invent a new .fs.
Use Icarus and Pillow for real RTL pixel captures. Adapt Windows-specific runner paths to PATH tools only as necessary. Retain meaningful checks; do not weaken assertions just to pass.
Keep detailed Chinese comments for new geometry, MIDI range and pixel latency. Use bounded parallelism. Do not merge main, force-push, upload unrelated files or transcripts, or install paid services.
Deliver code diff, tests/report, actual RTL previews and ESP32 wiring documentation. Preserve V030 reference identity. Release numbering on Windows is assigned when results are retrieved; do not fabricate a Windows release folder or claim flashing.
