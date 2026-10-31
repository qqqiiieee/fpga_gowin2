# V046 WAV view helper

Run `python tests/wav_view_v046/run_tests.py` from the project root. Results are
written to `tests/wav_view_v046/results.json`; native x64/x86 logs and outputs
stay in this test directory. No serial, network, FPGA or ESP32 build is used.

Fixed interfaces in `namespace v046`:

```cpp
bool wavSamples(size_t fileSize, uint32_t& samples);
template<class FileLike>
bool readWavRange(FileLike& f, uint32_t samples, size_t offset,
                  uint8_t* out, size_t n);
```

The backing file is exactly 44 placeholder bytes plus PCM16LE mono at 15625 Hz.
The helper reuses `v041::wavHeader`, returns a virtual correct 44-byte WAV header,
and reads PCM at its unchanged physical offset. It never allocates, writes or
closes the file. PCM reads change its cursor; the caller must own/serialize it.
It accepts zero samples structurally and rejects more than 468750 samples.
`wavSamples` leaves its output unchanged on failure. Size alone does not establish
EOF/CRC validity; the caller must validate persistent metadata before exposing it.

`readWavRange` requires the exact file size for the supplied sample count.
Zero-length requests are valid through EOF (including a null output pointer).
Nonempty requests require an output buffer of at least `n` bytes. Invalid ranges,
size mismatches, seek failures and short reads return false. Output may be partial
after an I/O error and must be discarded. Header-only requests do not seek/read.
There is no 512-byte policy here; the USB parser retains that protocol limit.

Tests exhaust all subranges around the header for small files, compare against
independent reference WAV bytes, cover legacy correct headers and placeholder
headers, invalid sizes/counts, size_t overflow, I/O failures, and full 3s/30s
outputs in 512/1024-byte chunks on both 32-bit and 64-bit hosts. These tests do
not establish on-device LittleFS behavior or HTTP/USB integration correctness.
