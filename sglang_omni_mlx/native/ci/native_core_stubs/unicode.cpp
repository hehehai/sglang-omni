// SPDX-License-Identifier: Apache-2.0
// Test-only Unicode/audio stand-ins for the actual realtime engine.
#include "audio.h"
#include "transcriber.h"

#include <algorithm>
#include <cmath>

namespace qwen3_asr {

bool PeakIsSilent(const float *samples, size_t sample_count,
                  float peak_threshold) {
  for (size_t i = 0; i < sample_count; ++i) {
    if (std::fabs(samples[i]) >= peak_threshold) {
      return false;
    } else {
    }
  }
  return true;
}

bool IsUnicodeSpace(uint32_t code_point) {
  return code_point == ' ' || (code_point >= 0x09 && code_point <= 0x0D) ||
         (code_point >= 0x1C && code_point <= 0x1F) || code_point == 0x85 ||
         code_point == 0xA0 || code_point == 0x1680 ||
         (code_point >= 0x2000 && code_point <= 0x200A) ||
         code_point == 0x2028 || code_point == 0x2029 || code_point == 0x202F ||
         code_point == 0x205F || code_point == 0x3000;
}

std::vector<uint32_t> CodePoints(const std::string &text) {
  std::vector<uint32_t> code_points;
  for (size_t i = 0; i < text.size();) {
    const uint8_t lead = static_cast<uint8_t>(text[i]);
    const size_t byte_count = lead >= 0xF0   ? 4
                              : lead >= 0xE0 ? 3
                              : lead >= 0xC0 ? 2
                                             : 1;
    uint32_t code_point =
        lead & (byte_count == 1 ? 0x7F : (0x7F >> byte_count));
    for (size_t j = 1; j < byte_count; ++j) {
      code_point =
          (code_point << 6) | (static_cast<uint8_t>(text.at(i + j)) & 0x3F);
    }
    code_points.push_back(code_point);
    i += byte_count;
  }
  return code_points;
}

std::string StripUnicodeWhitespace(const std::string &text) {
  size_t begin_byte = text.size();
  size_t end_byte = 0;
  size_t byte_offset = 0;
  for (const uint32_t code_point : CodePoints(text)) {
    const size_t byte_count = code_point > 0xFFFF  ? 4
                              : code_point > 0x7FF ? 3
                              : code_point > 0x7F  ? 2
                                                   : 1;
    if (!IsUnicodeSpace(code_point)) {
      begin_byte = std::min(begin_byte, byte_offset);
      end_byte = byte_offset + byte_count;
    } else {
    }
    byte_offset += byte_count;
  }
  return begin_byte < end_byte ? text.substr(begin_byte, end_byte - begin_byte)
                               : "";
}

} // namespace qwen3_asr
