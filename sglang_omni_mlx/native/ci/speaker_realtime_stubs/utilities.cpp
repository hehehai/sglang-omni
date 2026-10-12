// SPDX-License-Identifier: Apache-2.0
#include "transcriber.h"

#include <cmath>

namespace qwen3_asr {
nlohmann::ordered_json
SpeakerSegmentsJson(const std::vector<SpeakerSegment> &segments) {
  nlohmann::ordered_json array = nlohmann::ordered_json::array();
  for (const SpeakerSegment &segment : segments) {
    nlohmann::ordered_json json = {{"start", segment.start_seconds},
                                   {"end", segment.end_seconds},
                                   {"speaker", segment.speaker},
                                   {"text", segment.text}};
    for (const auto &[name, value] : {std::pair{"language", &segment.language},
                                      std::pair{"emotion", &segment.emotion},
                                      std::pair{"event", &segment.event}}) {
      if (value->has_value()) {
        json[name] = **value;
      } else {
      }
    }
    array.push_back(std::move(json));
  }
  return array;
}

bool IsUnicodeSpace(uint32_t code_point) {
  return code_point == ' ' || (code_point >= 0x09 && code_point <= 0x0D) ||
         (code_point >= 0x1C && code_point <= 0x1F) || code_point == 0x85 ||
         code_point == 0xA0 || code_point == 0x1680 ||
         (code_point >= 0x2000 && code_point <= 0x200A) ||
         code_point == 0x2028 || code_point == 0x2029 || code_point == 0x202F ||
         code_point == 0x205F || code_point == 0x3000;
}

// Note (Jiaxin Deng): assumes valid UTF-8, the only kind the tokenizer emits.
std::vector<uint32_t> CodePoints(const std::string &text) {
  std::vector<uint32_t> code_points;
  size_t i = 0;
  while (i < text.size()) {
    const auto byte = [&](size_t index) {
      return static_cast<uint8_t>(text[index]);
    };
    const uint8_t lead = byte(i);
    uint32_t code_point = lead;
    size_t byte_count = 1;
    if (lead >= 0xF0 && i + 3 < text.size()) {
      code_point = ((lead & 0x07) << 18) | ((byte(i + 1) & 0x3F) << 12) |
                   ((byte(i + 2) & 0x3F) << 6) | (byte(i + 3) & 0x3F);
      byte_count = 4;
    } else if (lead >= 0xE0 && i + 2 < text.size()) {
      code_point = ((lead & 0x0F) << 12) | ((byte(i + 1) & 0x3F) << 6) |
                   (byte(i + 2) & 0x3F);
      byte_count = 3;
    } else if (lead >= 0xC0 && i + 1 < text.size()) {
      code_point = ((lead & 0x1F) << 6) | (byte(i + 1) & 0x3F);
      byte_count = 2;
    } else {
    }
    code_points.push_back(code_point);
    i += byte_count;
  }
  return code_points;
}

std::string StripUnicodeWhitespace(const std::string &text) {
  const std::vector<uint32_t> code_points = CodePoints(text);
  size_t begin_code_point = 0;
  size_t end_code_point = code_points.size();
  while (begin_code_point < end_code_point &&
         IsUnicodeSpace(code_points[begin_code_point]))
    ++begin_code_point;
  while (end_code_point > begin_code_point &&
         IsUnicodeSpace(code_points[end_code_point - 1]))
    --end_code_point;
  size_t byte_offset = 0;
  size_t begin_byte = 0;
  size_t end_byte = 0;
  for (size_t i = 0; i <= code_points.size(); ++i) {
    if (i == begin_code_point) {
      begin_byte = byte_offset;
    } else {
    }
    if (i == end_code_point) {
      end_byte = byte_offset;
    } else {
    }
    if (i == code_points.size()) {
      break;
    } else {
    }
    const uint8_t lead = static_cast<uint8_t>(text[byte_offset]);
    byte_offset += lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
  }
  return text.substr(begin_byte, end_byte - begin_byte);
}

std::optional<std::string> NormalizeLanguage(const std::string &) {
  throw std::logic_error("Unexpected Qwen language path");
}
std::pair<std::vector<int>, std::string>
Qwen3ASRTranscriber::RetainedPrefix(const std::string &, int) const {
  throw std::logic_error("Unexpected Qwen prefix path");
}
TranscriptionResult
Qwen3ASRTranscriber::Transcribe(const std::vector<float> &,
                                const TranscriptionOptions &,
                                const std::atomic<bool> &) const {
  throw std::logic_error("Unexpected Qwen model path");
}
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
} // namespace qwen3_asr
