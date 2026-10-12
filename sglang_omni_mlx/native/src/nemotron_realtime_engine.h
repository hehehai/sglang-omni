// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "nemotron_transcriber.h"
#include "speaker_realtime_event.h"
#include "worker.h"

namespace nemotron {

class NemotronRealtimeEngine
    : public std::enable_shared_from_this<NemotronRealtimeEngine> {
public:
  using EventSink =
      std::function<void(const qwen3_asr::SpeakerRealtimeEvent &)>;

  NemotronRealtimeEngine(
      qwen3_asr::TranscriptionWorker &worker,
      const NemotronTranscriber &transcriber, EventSink event_sink,
      qwen3_asr::CancelFlag cancel = qwen3_asr::NewCancelFlag());
  ~NemotronRealtimeEngine();

  // Commands are caller-serialized; only Close may overlap or reenter a sink.
  void UpdateSettings(std::optional<std::string> language,
                      std::optional<double> chunk_milliseconds);
  void Append(std::vector<float> samples);
  void Commit();
  void Finish();
  // Cancellation and sink barrier, not a worker/model drain.
  void Close();

private:
  // Called with mutex_ held and no other stream job in flight.
  void SubmitDecode(bool final);
  void CompleteDecode(std::optional<qwen3_asr::TranscriptionResult> result,
                      std::exception_ptr error, bool final);
  void Emit(const qwen3_asr::SpeakerRealtimeEvent &event);
  void ReportDecodeFailure(std::exception_ptr error) noexcept;

  // These references must survive both engine destruction and queued jobs.
  qwen3_asr::TranscriptionWorker &worker_;
  const NemotronTranscriber &transcriber_;
  const EventSink event_sink_;
  const qwen3_asr::CancelFlag cancel_;
  std::recursive_mutex send_mutex_;
  std::mutex mutex_;
  std::condition_variable decode_done_;
  NemotronOptions options_;
  std::shared_ptr<NemotronStream> stream_;
  std::vector<float> pending_samples_;
  int64_t received_samples_ = 0;
  bool decoding_ = false;
  bool finished_ = false;
  bool completed_ = false;
  bool failed_ = false;
  std::string shown_text_;
  qwen3_asr::TranscriptionResult final_result_;
};

} // namespace nemotron
