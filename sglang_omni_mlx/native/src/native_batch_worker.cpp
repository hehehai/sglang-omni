// SPDX-License-Identifier: Apache-2.0
#include "native_batch_worker.h"

#include <new>
#include <stdexcept>
#include <variant>

#include "cohere_transcriber.h"
#include "moss_transcriber.h"
#include "nemotron_transcriber.h"
#include "parakeet_transcriber.h"
#include "sensevoice_transcriber.h"
#include "whisper_transcriber.h"

namespace omni_native {
namespace {

using BatchModel =
    std::variant<std::monostate, std::unique_ptr<whisper::WhisperTranscriber>,
                 std::unique_ptr<cohere_transcribe::CohereTranscriber>,
                 std::unique_ptr<moss::MossTranscriber>,
                 std::unique_ptr<nemotron::NemotronTranscriber>,
                 std::unique_ptr<parakeet::ParakeetTranscriber>,
                 std::unique_ptr<sensevoice::SenseVoiceTranscriber>>;

qwen3_asr::TranscriptionResult TranscribeBatch(BatchModel &model,
                                               const BatchCommand &command) {
  const auto &family = command.options.family;
  switch (command.options.model_kind) {
  case OMNI_BATCH_WHISPER: {
    whisper::WhisperOptions options;
    if (family.whisper.language != nullptr) {
      options.language = family.whisper.language;
    } else {
    }
    options.max_new_tokens = family.whisper.maximum_token_count;
    options.temperature = family.whisper.temperature;
    return std::get<1>(model)->Transcribe(command.samples, options,
                                          command.is_cancelled);
  }
  case OMNI_BATCH_COHERE: {
    cohere_transcribe::CohereOptions options;
    if (family.cohere.language != nullptr) {
      options.language = family.cohere.language;
    } else {
    }
    options.use_punctuation = family.cohere.use_punctuation != 0;
    options.max_new_tokens = family.cohere.maximum_token_count;
    options.temperature = family.cohere.temperature;
    options.chunk_duration_seconds = family.cohere.chunk_duration_seconds;
    options.min_chunk_duration_seconds =
        family.cohere.minimum_chunk_duration_seconds;
    return std::get<2>(model)->Transcribe(command.samples, options,
                                          command.is_cancelled);
  }
  case OMNI_BATCH_MOSS: {
    moss::MossOptions options;
    if (family.moss.prompt != nullptr) {
      options.prompt = family.moss.prompt;
    } else {
    }
    if (family.moss.maximum_token_count >= 0) {
      options.max_new_tokens = family.moss.maximum_token_count;
    } else {
    }
    options.stop_at_end_of_text = family.moss.stop_at_end_of_text != 0;
    options.stop_on_token_loop = family.moss.stop_on_token_loop != 0;
    return std::get<3>(model)->Transcribe(command.samples, options,
                                          command.is_cancelled);
  }
  case OMNI_BATCH_NEMOTRON: {
    nemotron::NemotronOptions options;
    if (family.nemotron.language != nullptr) {
      options.language = family.nemotron.language;
    } else {
    }
    if (family.nemotron.chunk_frame_count != 0) {
      options.chunk_frames = family.nemotron.chunk_frame_count;
    } else {
    }
    return std::get<4>(model)->Transcribe(command.samples, options,
                                          command.is_cancelled);
  }
  case OMNI_BATCH_PARAKEET: {
    parakeet::ParakeetOptions options;
    options.chunk_duration_seconds = family.parakeet.chunk_duration_seconds;
    return std::get<5>(model)->Transcribe(command.samples, options,
                                          command.is_cancelled);
  }
  case OMNI_BATCH_SENSEVOICE: {
    sensevoice::SenseVoiceOptions options;
    if (family.sensevoice.language != nullptr) {
      options.language = family.sensevoice.language;
    } else {
    }
    options.use_itn = family.sensevoice.use_inverse_text_normalization != 0;
    return std::get<6>(model)->Transcribe(command.samples, options,
                                          command.is_cancelled);
  }
  default:
    throw std::invalid_argument("Invalid batch model kind.");
  }
}

} // namespace

BatchWorker::BatchWorker(OmniBatchModelKind kind,
                         const std::filesystem::path &model_directory)
    : model_kind(kind),
      worker_thread([this, model_directory] { Run(model_directory); }) {
  try {
    std::unique_lock lock(worker_mutex);
    worker_condition.wait(lock, [this] { return is_ready; });
  } catch (...) {
    Shutdown();
    throw;
  }
}

BatchWorker::~BatchWorker() {
  if (worker_thread.joinable()) {
    Shutdown();
  } else {
  }
}

void BatchWorker::Shutdown() {
  if (worker_thread.get_id() == std::this_thread::get_id()) {
    throw std::logic_error("Cannot join batch worker from itself.");
  } else {
    {
      std::lock_guard lock(worker_mutex);
      is_stopping = true;
    }
    worker_condition.notify_all();
    if (worker_thread.joinable()) {
      worker_thread.join();
    } else {
    }
  }
}

void BatchWorker::Execute(BatchCommand &command) {
  std::unique_lock lock(worker_mutex);
  if (is_stopping || queued_command != nullptr) {
    command.status = OMNI_BATCH_BUSY;
  } else {
    queued_command = &command;
    worker_condition.notify_all();
    worker_condition.wait(lock, [this] { return queued_command == nullptr; });
  }
}

void BatchWorker::Run(const std::filesystem::path &model_directory) noexcept {
  BatchModel model;
  OmniBatchStatus status = OMNI_BATCH_OK;
  try {
    switch (model_kind) {
    case OMNI_BATCH_WHISPER:
      model.emplace<1>(
          std::make_unique<whisper::WhisperTranscriber>(model_directory));
      break;
    case OMNI_BATCH_COHERE:
      model.emplace<2>(std::make_unique<cohere_transcribe::CohereTranscriber>(
          model_directory));
      break;
    case OMNI_BATCH_MOSS:
      model.emplace<3>(
          std::make_unique<moss::MossTranscriber>(model_directory));
      break;
    case OMNI_BATCH_NEMOTRON:
      model.emplace<4>(
          std::make_unique<nemotron::NemotronTranscriber>(model_directory));
      break;
    case OMNI_BATCH_PARAKEET:
      model.emplace<5>(
          std::make_unique<parakeet::ParakeetTranscriber>(model_directory));
      break;
    case OMNI_BATCH_SENSEVOICE:
      model.emplace<6>(
          std::make_unique<sensevoice::SenseVoiceTranscriber>(model_directory));
      break;
    default:
      status = OMNI_BATCH_INVALID;
      break;
    }
  } catch (const std::bad_alloc &) {
    status = OMNI_BATCH_OUT_OF_MEMORY;
  } catch (...) {
    status = OMNI_BATCH_FAILED;
  }
  std::unique_lock lock(worker_mutex);
  load_status = status;
  is_ready = true;
  worker_condition.notify_all();
  while (status == OMNI_BATCH_OK) {
    worker_condition.wait(
        lock, [this] { return is_stopping || queued_command != nullptr; });
    if (queued_command != nullptr) {
      BatchCommand &command = *queued_command;
      lock.unlock();
      try {
        if (command.is_cancelled.load()) {
          command.status = OMNI_BATCH_CANCELLED;
        } else {
          const auto transcription = TranscribeBatch(model, command);
          if (command.is_cancelled.load()) {
            command.status = OMNI_BATCH_CANCELLED;
          } else {
            command.status = CopyBatchResult(transcription, command.result);
          }
        }
      } catch (const qwen3_asr::TranscriptionCancelled &) {
        command.status = OMNI_BATCH_CANCELLED;
      } catch (const std::bad_alloc &) {
        command.status = OMNI_BATCH_OUT_OF_MEMORY;
      } catch (...) {
        command.status = OMNI_BATCH_FAILED;
      }
      lock.lock();
      queued_command = nullptr;
      worker_condition.notify_all();
    } else if (is_stopping) {
      break;
    } else {
    }
  }
}

} // namespace omni_native
