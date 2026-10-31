#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "v041_core.h"

// A read-only WAV view over 44 placeholder bytes followed by PCM16LE mono.
// FileLike provides size(), bool seek(size_t), and size_t read(uint8_t*,size_t).
// This view checks structure, not persistent CRC/EOF validity; callers own that.
namespace v046 {

inline bool wavSamples(size_t fileSize, uint32_t& samples) {
    if (fileSize < 44) return false;
    const uint64_t pcmBytes = uint64_t(fileSize) - 44;
    if ((pcmBytes & 1u) || pcmBytes > uint64_t(UINT32_MAX) - 36u ||
        pcmBytes / 2u > 468750u) return false;
    samples = uint32_t(pcmBytes / 2u);
    return true;
}

// n==0 succeeds at offsets through EOF, including with out==nullptr.
// For n>0, out must point to n writable bytes. No truncation or padding on error.
// A failed seek/read may leave partial output; callers must discard it on false.
// PCM reads change the file cursor. The file is never written or closed here.
template<class FileLike>
inline bool readWavRange(FileLike& f, uint32_t samples, size_t offset,
                         uint8_t* out, size_t n) {
    const size_t fileSize = f.size();
    uint32_t storedSamples = 0;
    if (!wavSamples(fileSize, storedSamples) || storedSamples != samples ||
        offset > fileSize || n > fileSize - offset || (n && !out)) return false;
    if (!n) return true;

    if (offset < 44) {
        uint8_t header[44];
        v041::wavHeader(header, samples);
        const size_t headerBytes = n < 44 - offset ? n : 44 - offset;
        memcpy(out, header + offset, headerBytes);
        offset += headerBytes;
        out += headerBytes;
        n -= headerBytes;
    }
    if (!n) return true;
    return f.seek(offset) && f.read(out, n) == n;
}

} // namespace v046
