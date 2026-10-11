// SPDX-License-Identifier: Apache-2.0
#include "native_sortformer_worker.h"

#include <cstdio>

using omni_native::ClearSortformerError;
using omni_native::SetError;
using omni_native::SortformerCommand;
using omni_native::SortformerOperation;

OmniSortformerHandle *omni_sortformer_create(const char *model_directory,
                                             char **error_message) {
  ClearSortformerError(error_message);
  try {
    if (model_directory == nullptr || model_directory[0] == '\0' ||
        !std::filesystem::is_directory(model_directory)) {
      SetError(error_message, "Invalid model directory.");
      return nullptr;
    } else {
      auto handle = std::make_unique<OmniSortformerHandle>();
      handle->worker =
          std::make_shared<omni_native::SortformerWorker>(model_directory);
      return handle.release();
    }
  } catch (...) {
    SetError(error_message, "Sortformer initialization failed.");
    return nullptr;
  }
}

void omni_sortformer_cancel(OmniSortformerHandle *handle) {
  if (handle != nullptr) {
    handle->worker->is_cancelled.store(true);
  } else {
  }
}

void omni_sortformer_destroy(OmniSortformerHandle *handle) {
  try {
    if (handle != nullptr) {
      const auto worker = handle->worker;
      worker->is_cancelled.store(true);
      {
        std::lock_guard<std::mutex> lock(worker->command_mutex);
        SortformerCommand command{.operation = SortformerOperation::DrainAll};
        worker->Execute(command);
      }
      delete handle;
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore Sortformer shutdown failed; model retained.\n",
               stderr);
  }
}
