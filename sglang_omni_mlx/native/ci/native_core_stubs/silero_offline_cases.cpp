// SPDX-License-Identifier: Apache-2.0
#include "silero_cases.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace omni_test {
namespace {

void InvalidDirectories() {
  for (const char *directory : {static_cast<const char *>(nullptr), "",
                                "missing-private-model-directory", __FILE__}) {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_silero_create(directory, &error) == nullptr);
    CheckSileroError(error);
  }
  assert(omni_silero_create(nullptr, nullptr) == nullptr);
  assert(SileroState().load_count == 0);
}

void InvalidOfflineInputs() {
  auto model = CreateSileroModel();
  const float sample = 0.75f;
  struct InvalidInput {
    OmniSileroHandle *model;
    const float *samples;
    size_t sample_count;
    const OmniSileroSettings *settings;
    bool has_result;
  };
  for (const auto &input : std::vector<InvalidInput>{
           {nullptr, &sample, 1, &SILERO_SETTINGS, true},
           {model.get(), nullptr, 1, &SILERO_SETTINGS, true},
           {model.get(), &sample, 0, &SILERO_SETTINGS, true},
           {model.get(), &sample, OMNI_SILERO_MAX_OFFLINE_SAMPLES + 1,
            &SILERO_SETTINGS, true},
           {model.get(), &sample, std::numeric_limits<size_t>::max(),
            &SILERO_SETTINGS, true},
           {model.get(), &sample, 1, nullptr, true},
           {model.get(), &sample, 1, &SILERO_SETTINGS, false}}) {
    auto request = CreateSileroRequest();
    OmniSileroResult result{reinterpret_cast<OmniSileroTimestamp *>(1), 9};
    char *error = reinterpret_cast<char *>(1);
    assert(omni_silero_speech_timestamps(
               input.model, request.get(), input.samples, input.sample_count,
               input.settings, input.has_result ? &result : nullptr,
               &error) == 0);
    CheckSileroError(error);
    if (input.has_result) {
      CheckSileroCleared(result);
    } else {
    }
    assert(omni_silero_speech_timestamps(model.get(), request.get(), &sample, 1,
                                         &SILERO_SETTINGS, &result,
                                         &error) == 0);
    CheckSileroCleared(result);
    CheckSileroError(error);
  }
  OmniSileroResult result{};
  assert(omni_silero_speech_timestamps(model.get(), nullptr, &sample, 1,
                                       &SILERO_SETTINGS, &result,
                                       nullptr) == 0);
  for (float nonfinite : {NAN, INFINITY, -INFINITY}) {
    for (size_t position : {size_t{0}, size_t{511}, size_t{512}}) {
      std::vector<float> samples(513, 0.75f);
      samples[position] = nonfinite;
      auto request = CreateSileroRequest();
      char *error = nullptr;
      assert(omni_silero_speech_timestamps(
                 model.get(), request.get(), samples.data(), samples.size(),
                 &SILERO_SETTINGS, &result, &error) == 0);
      CheckSileroCleared(result);
      CheckSileroError(error);
    }
  }
  assert(SileroState().frames.empty());
  CheckSileroOfflineSuccess(model.get());
}

void InvalidOfflineSettings() {
  auto model = CreateSileroModel();
  const float sample = 0.75f;
  std::vector<OmniSileroSettings> invalid_settings;
  for (float threshold : {-0.01f, 1.01f, NAN, INFINITY, -INFINITY}) {
    auto settings = SILERO_SETTINGS;
    settings.threshold = threshold;
    invalid_settings.push_back(settings);
  }
  for (int milliseconds : {-1, OMNI_SILERO_MAX_OPTION_MILLISECONDS + 1,
                           std::numeric_limits<int32_t>::max()}) {
    invalid_settings.push_back({0.5f, milliseconds, 0, 0});
    invalid_settings.push_back({0.5f, 0, milliseconds, 0});
    invalid_settings.push_back({0.5f, 0, 0, milliseconds});
  }
  for (const auto &settings : invalid_settings) {
    auto request = CreateSileroRequest();
    OmniSileroResult result{reinterpret_cast<OmniSileroTimestamp *>(1), 9};
    char *error = nullptr;
    assert(omni_silero_speech_timestamps(model.get(), request.get(), &sample, 1,
                                         &settings, &result, &error) == 0);
    CheckSileroCleared(result);
    CheckSileroError(error);
  }
  assert(SileroState().frames.empty());
  for (float threshold : {0.0f, 1.0f}) {
    for (int milliseconds : {0, OMNI_SILERO_MAX_OPTION_MILLISECONDS}) {
      const OmniSileroSettings settings{threshold, milliseconds, milliseconds,
                                        milliseconds};
      auto request = CreateSileroRequest();
      OmniSileroResult result{};
      char *error = reinterpret_cast<char *>(1);
      assert(omni_silero_speech_timestamps(model.get(), request.get(), &sample,
                                           1, &settings, &result, &error) == 1);
      assert(error == nullptr);
      omni_silero_result_free(&result);
    }
  }
}

void OfflineSettingsMapping() {
  auto model = CreateSileroModel();
  struct SettingsCase {
    OmniSileroSettings settings;
    std::vector<OmniSileroTimestamp> expected;
  };
  const std::vector<float> samples(1536, 0.75f);
  for (const auto &input :
       std::vector<SettingsCase>{{{0.9f, 0, 0, 0}, {}},
                                 {{0.5f, 33, 0, 0}, {}},
                                 {{0.5f, 0, 32, 0}, {{512, 1536}}},
                                 {{0.5f, 0, 0, 30}, {{32, 1504}}}}) {
    auto request = CreateSileroRequest();
    SileroState().scripted_probabilities = {0.0f, 0.8f, 0.0f};
    OmniSileroResult result{};
    assert(omni_silero_speech_timestamps(
               model.get(), request.get(), samples.data(), samples.size(),
               &input.settings, &result, nullptr) == 1);
    assert(result.timestamp_count == input.expected.size());
    for (size_t i = 0; i < input.expected.size(); ++i) {
      assert(result.timestamps[i].start_sample ==
             input.expected[i].start_sample);
      assert(result.timestamps[i].end_sample == input.expected[i].end_sample);
    }
    omni_silero_result_free(&result);
  }
}

void OfflinePaddingAndOwnership() {
  auto model = CreateSileroModel();
  auto &backend = SileroState();
  for (size_t sample_count : {size_t{1}, size_t{511}, size_t{512}, size_t{513},
                              size_t{OMNI_SILERO_MAX_OFFLINE_SAMPLES}}) {
    backend.frames.clear();
    CheckSileroOfflineSuccess(model.get(), sample_count);
    const size_t frame_count = (sample_count + 511) / 512;
    assert(backend.frames.size() == frame_count);
    for (size_t i = 0; i < frame_count * 512; ++i) {
      assert(backend.frames[i / 512][i % 512] ==
             (i < sample_count ? 0.75f : 0.0f));
    }
    assert(backend.live_array_count == 1);
  }
  OmniSileroResult first{};
  OmniSileroResult second{};
  const float sample = 0.75f;
  for (auto *result : {&first, &second}) {
    auto request = CreateSileroRequest();
    assert(omni_silero_speech_timestamps(model.get(), request.get(), &sample, 1,
                                         &SILERO_SETTINGS, result,
                                         nullptr) == 1);
  }
  assert(first.timestamps != second.timestamps);
  first.timestamps[0].end_sample = 999;
  assert(second.timestamps[0].end_sample == 1);
  backend.scripted_probabilities = {0.0f};
  auto request = CreateSileroRequest();
  OmniSileroResult silent{};
  assert(omni_silero_speech_timestamps(model.get(), request.get(), &sample, 1,
                                       &SILERO_SETTINGS, &silent,
                                       nullptr) == 1);
  CheckSileroCleared(silent);
  model.reset();
  assert(second.timestamps[0].end_sample == 1);
  omni_silero_result_free(&first);
  omni_silero_result_free(&second);
  omni_silero_result_free(&silent);
  omni_silero_result_free(nullptr);
}

void OfflineSingleUse() {
  auto model = CreateSileroModel();
  const float sample = 0.75f;
  for (bool cancelled : {false, true}) {
    auto request = CreateSileroRequest();
    if (cancelled) {
      omni_silero_request_cancel(request.get());
      omni_silero_request_cancel(request.get());
    } else {
    }
    OmniSileroResult result{};
    char *error = nullptr;
    const int status =
        omni_silero_speech_timestamps(model.get(), request.get(), &sample, 1,
                                      &SILERO_SETTINGS, &result, &error);
    assert(status == (cancelled ? 0 : 1));
    if (cancelled) {
      CheckSileroCleared(result);
      CheckSileroError(error);
    } else {
      assert(error == nullptr);
      omni_silero_result_free(&result);
    }
    const auto frame_count = SileroState().frames.size();
    assert(omni_silero_speech_timestamps(model.get(), request.get(), &sample, 1,
                                         &SILERO_SETTINGS, &result,
                                         &error) == 0);
    CheckSileroError(error);
    CheckSileroCleared(result);
    assert(SileroState().frames.size() == frame_count);
    CheckSileroOfflineSuccess(model.get());
  }
  omni_silero_request_cancel(nullptr);
  omni_silero_request_destroy(nullptr);
  omni_silero_cancel(nullptr);
  omni_silero_destroy(nullptr);
}

} // namespace

void RunSileroOfflineCase(const std::string &test) {
  if (test == "silero_offline_directories") {
    InvalidDirectories();
  } else if (test == "silero_offline_inputs") {
    InvalidOfflineInputs();
  } else if (test == "silero_offline_settings") {
    InvalidOfflineSettings();
  } else if (test == "silero_offline_settings_mapping") {
    OfflineSettingsMapping();
  } else if (test == "silero_offline_padding_ownership") {
    OfflinePaddingAndOwnership();
  } else if (test == "silero_offline_single_use") {
    OfflineSingleUse();
  } else {
    assert(false && "Unknown Silero offline test");
  }
}

} // namespace omni_test
