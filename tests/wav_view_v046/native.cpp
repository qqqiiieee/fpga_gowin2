#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>
#include "../../esp32_phone/wav_view.h"

static unsigned checks = 0;
#define CHECK(x) do { ++checks; if (!(x)) { \
    std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; \
} } while (0)

// Deliberately offers no write/close API. Header bytes on disk are not consulted.
struct FileMock {
    std::vector<uint8_t> bytes;
    size_t declaredSize, pos = 0, seeks = 0, reads = 0, lastSeek = 0;
    bool seekFails = false, shortRead = false;
    explicit FileMock(const std::vector<uint8_t>& b) : bytes(b), declaredSize(b.size()) {}
    size_t size() const { return declaredSize; }
    bool seek(size_t at) {
        ++seeks; lastSeek = at;
        if (seekFails || at > bytes.size()) return false;
        pos = at; return true;
    }
    size_t read(uint8_t* out, size_t n) {
        ++reads;
        size_t take = (std::min)(n, bytes.size() - pos);
        if (shortRead && take) --take;
        if (take) std::memcpy(out, bytes.data() + pos, take);
        pos += take; return take;
    }
};

// Independent reference bytes, not v041::wavHeader or the helper under test.
static std::vector<uint8_t> reference(uint32_t samples) {
    const uint8_t header[44] = {
        'R','I','F','F',0,0,0,0,'W','A','V','E','f','m','t',' ',
        16,0,0,0,1,0,1,0,0x09,0x3d,0,0,0x12,0x7a,0,0,
        2,0,16,0,'d','a','t','a',0,0,0,0
    };
    std::vector<uint8_t> bytes(size_t(samples) * 2 + 44);
    std::memcpy(bytes.data(), header, 44);
    for (unsigned i = 0; i < 4; ++i) {
        bytes[4 + i] = uint8_t((36u + 2u * samples) >> (8 * i));
        bytes[40 + i] = uint8_t((2u * samples) >> (8 * i));
    }
    for (size_t i = 44; i < bytes.size(); ++i) bytes[i] = uint8_t((i * 73u + 19u) & 255u);
    return bytes;
}

int main() {
    uint32_t samples = 123;
    for (size_t size = 0; size < 44; ++size) {
        CHECK(!v046::wavSamples(size, samples)); CHECK(samples == 123);
    }
    CHECK(v046::wavSamples(44, samples) && samples == 0);
    CHECK(v046::wavSamples(46, samples) && samples == 1);
    CHECK(v046::wavSamples(937544, samples) && samples == 468750);
    samples = 123;
    for (size_t size : {size_t(45), size_t(47), size_t(937543), size_t(937545),
                        size_t(937546), size_t(UINT32_MAX - 1u), size_t(UINT32_MAX),
                        (std::numeric_limits<size_t>::max)()}) {
        CHECK(!v046::wavSamples(size, samples)); CHECK(samples == 123);
    }
    if (sizeof(size_t) > 4) {
        CHECK(!v046::wavSamples(size_t(uint64_t(UINT32_MAX) + 1u), samples));
        CHECK(!v046::wavSamples(size_t(uint64_t(UINT32_MAX) + 44u), samples));
    }

    // Every possible valid subrange of a small WAV, with guard bytes around out.
    // Run for both a zero-length placeholder header and a real legacy WAV header.
    for (uint32_t count : {0u, 1u, 2u, 8u, 31u}) {
        const auto expected = reference(count);
        for (bool legacy : {false, true}) {
            auto disk = expected;
            if (!legacy) {
                const auto placeholder = reference(0);
                std::copy(placeholder.begin(), placeholder.end(), disk.begin());
            }
            FileMock f(disk);
            for (size_t offset = 0; offset <= expected.size(); ++offset) {
                for (size_t n = 0; n <= expected.size() - offset; ++n) {
                    std::vector<uint8_t> out(n + 2, 0xa7);
                    const size_t oldSeeks = f.seeks, oldReads = f.reads;
                    CHECK(v046::readWavRange(f, count, offset, out.data() + 1, n));
                    CHECK(out.front() == 0xa7 && out.back() == 0xa7);
                    CHECK(std::equal(out.begin() + 1, out.end() - 1, expected.begin() + offset));
                    if (!n || offset + n <= 44) {
                        CHECK(f.seeks == oldSeeks && f.reads == oldReads);
                    } else {
                        CHECK(f.seeks == oldSeeks + 1 && f.reads == oldReads + 1);
                        CHECK(f.lastSeek == (std::max)(offset, size_t(44)));
                    }
                }
            }
            CHECK(f.bytes == disk);
            CHECK(v046::readWavRange(f, count, expected.size(), nullptr, 0));
            uint8_t out[64] = {};
            CHECK(!v046::readWavRange(f, count, expected.size(), out, 1));
            CHECK(!v046::readWavRange(f, count, expected.size() + 1, out, 0));
            CHECK(!v046::readWavRange(f, count, 0, nullptr, 1));
            CHECK(!v046::readWavRange(f, count, (std::numeric_limits<size_t>::max)(), out, 2));
            CHECK(!v046::readWavRange(f, count, 43, out, (std::numeric_limits<size_t>::max)()));
            CHECK(!v046::readWavRange(f, count + 1, 0, out, 44));
            CHECK(!v046::readWavRange(f, UINT32_MAX, 0, out, 44));
        }
    }

    FileMock f(reference(8));
    uint8_t out[64] = {};
    f.seekFails = true;
    CHECK(v046::readWavRange(f, 8, 0, out, 44));
    CHECK(!v046::readWavRange(f, 8, 43, out, 2) && f.reads == 0);
    CHECK(!v046::readWavRange(f, 8, 44, out, 1) && f.reads == 0);
    f.seekFails = false; f.shortRead = true;
    CHECK(!v046::readWavRange(f, 8, 40, out, 8));
    CHECK(!v046::readWavRange(f, 8, 44, out, 16));
    f.shortRead = false;
    for (size_t badSize : {size_t(0), size_t(43), size_t(45), size_t(58), size_t(62),
                           size_t(937546), (std::numeric_limits<size_t>::max)()}) {
        f.declaredSize = badSize;
        const size_t seeks = f.seeks, reads = f.reads;
        CHECK(!v046::readWavRange(f, 8, 0, out, 44));
        CHECK(f.seeks == seeks && f.reads == reads);
    }

    // Full 3s and 30s output, with USB-sized and HTTP-sized chunks; no extra file.
    for (uint32_t count : {46875u, 468750u}) {
        const auto expected = reference(count);
        auto disk = expected;
        std::fill(disk.begin(), disk.begin() + 44, uint8_t(0xcc));
        FileMock big(disk);
        for (size_t chunk : {size_t(512), size_t(1024)}) {
            std::vector<uint8_t> downloaded(expected.size());
            for (size_t offset = 0; offset < expected.size(); offset += chunk) {
                const size_t n = (std::min)(chunk, expected.size() - offset);
                CHECK(v046::readWavRange(big, count, offset, downloaded.data() + offset, n));
            }
            CHECK(downloaded == expected);
        }
        CHECK(big.bytes == disk);
    }
    std::printf("WAV_VIEW_V046_PASS checks=%u size_t_bits=%u boundary=1 legacy=1 overflow=1 io_errors=1 full_30s=1\n",
                checks, unsigned(sizeof(size_t) * 8));
    return 0;
}
