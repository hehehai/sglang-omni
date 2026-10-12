// SPDX-License-Identifier: Apache-2.0
#include "native_batch_worker.h"

#include <new>
#include <stdexcept>

OmniBatchStatus omni_batch_create(OmniBatchModelKind model_kind,
                                  const char *model_directory,
                                  OmniBatchHandle **handle) {
  if (handle == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
    *handle = nullptr;
  }
  try {
    OmniBatchOptions options{};
    if (omni_batch_options_default(model_kind, &options) != OMNI_BATCH_OK ||
        model_directory == nullptr || model_directory[0] == '\0' ||
        !omni_native::BatchStringFits(model_directory,
                                      OMNI_BATCH_MAX_PROMPT_BYTES) ||
        !std::filesystem::is_directory(model_directory)) {
      return OMNI_BATCH_INVALID;
    } else {
      auto created = std::make_unique<OmniBatchHandle>();
      created->worker = std::make_shared<omni_native::BatchWorker>(
          model_kind, std::filesystem::path(model_directory));
      if (created->worker->load_status != OMNI_BATCH_OK) {
        return created->worker->load_status;
      } else {
        *handle = created.release();
        return OMNI_BATCH_OK;
      }
    }
  } catch (const std::bad_alloc &) {
    return OMNI_BATCH_OUT_OF_MEMORY;
  } catch (...) {
    return OMNI_BATCH_FAILED;
  }
}

void omni_batch_cancel(OmniBatchHandle *handle) {
  if (handle != nullptr) {
    handle->worker->is_cancelled.store(true);
    handle->worker->request_is_cancelled.store(true);
  } else {
  }
}

OmniBatchStatus omni_batch_destroy_checked(OmniBatchHandle *handle) {
  if (handle == nullptr) {
    return OMNI_BATCH_OK;
  } else {
  }
  try {
    {
      std::lock_guard lock(handle->worker->lease_mutex);
      if (handle->worker->has_request_lease) {
        return OMNI_BATCH_BUSY;
      } else {
        handle->worker->is_cancelled.store(true);
        handle->worker->Shutdown();
      }
    }
    delete handle;
    return OMNI_BATCH_OK;
  } catch (...) {
    return OMNI_BATCH_FAILED;
  }
}

OmniBatchStatus omni_batch_request_create(OmniBatchHandle *handle,
                                          OmniBatchRequest **request) {
  if (request == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
    *request = nullptr;
  }
  if (handle == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
  }
  try {
    std::lock_guard lock(handle->worker->lease_mutex);
    if (handle->worker->is_cancelled.load()) {
      return OMNI_BATCH_CANCELLED;
    } else if (handle->worker->has_request_lease) {
      return OMNI_BATCH_BUSY;
    } else {
      auto created = std::make_unique<OmniBatchRequest>();
      created->worker = handle->worker;
      handle->worker->request_is_cancelled.store(false);
      if (handle->worker->is_cancelled.load()) {
        return OMNI_BATCH_CANCELLED;
      } else {
        handle->worker->has_request_lease = true;
        *request = created.release();
        return OMNI_BATCH_OK;
      }
    }
  } catch (const std::bad_alloc &) {
    return OMNI_BATCH_OUT_OF_MEMORY;
  } catch (...) {
    return OMNI_BATCH_FAILED;
  }
}

void omni_batch_request_cancel(OmniBatchRequest *request) {
  if (request != nullptr) {
    request->worker->request_is_cancelled.store(true);
  } else {
  }
}

OmniBatchStatus omni_batch_request_drain(OmniBatchRequest *request) {
  if (request == nullptr) {
    return OMNI_BATCH_OK;
  } else {
  }
  try {
    omni_batch_request_cancel(request);
    std::lock_guard lock(request->command_mutex);
    request->is_used = true;
    return OMNI_BATCH_OK;
  } catch (...) {
    return OMNI_BATCH_FAILED;
  }
}

OmniBatchStatus omni_batch_request_destroy_checked(OmniBatchRequest *request) {
  const auto status = omni_batch_request_drain(request);
  if (status != OMNI_BATCH_OK || request == nullptr) {
    return status;
  } else {
  }
  try {
    {
      std::lock_guard lock(request->worker->lease_mutex);
      request->worker->has_request_lease = false;
    }
    delete request;
    return OMNI_BATCH_OK;
  } catch (...) {
    return OMNI_BATCH_FAILED;
  }
}

OmniBatchStatus omni_batch_transcribe(OmniBatchRequest *request,
                                      const float *samples, size_t sample_count,
                                      const OmniBatchOptions *options,
                                      OmniBatchResult *result) {
  if (result != nullptr) {
    *result = {};
  } else {
  }
  if (request == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
  }
  try {
    std::unique_lock lock(request->command_mutex, std::try_to_lock);
    if (!lock.owns_lock()) {
      return OMNI_BATCH_BUSY;
    } else if (request->is_used) {
      return OMNI_BATCH_INVALID;
    } else {
      request->is_used = true;
    }
    if (request->worker->request_is_cancelled.load()) {
      return OMNI_BATCH_CANCELLED;
    } else if (result == nullptr) {
      return OMNI_BATCH_INVALID;
    } else {
      const auto status = omni_native::ValidateBatchInput(
          request->worker->model_kind, samples, sample_count, options);
      if (status != OMNI_BATCH_OK) {
        return status;
      } else {
        omni_native::BatchCommand command{
            std::vector<float>(samples, samples + sample_count), *options,
            request->worker->request_is_cancelled, result};
        request->worker->Execute(command);
        return command.status;
      }
    }
  } catch (const std::bad_alloc &) {
    return OMNI_BATCH_OUT_OF_MEMORY;
  } catch (const std::invalid_argument &) {
    return OMNI_BATCH_INVALID;
  } catch (...) {
    return OMNI_BATCH_FAILED;
  }
}
