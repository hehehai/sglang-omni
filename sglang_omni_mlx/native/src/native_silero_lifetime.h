// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <memory>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>

namespace omni_native {

struct SileroLifetime {
  std::shared_mutex call_mutex;
  bool is_destroyed = false;
};

// Note (OpenAI): lookup retains storage before waiting on the destruction gate.
template <typename Handle> class SileroHandles {
public:
  static Handle *Insert(std::shared_ptr<Handle> handle) {
    std::lock_guard lock(mutex);
    auto *pointer = handle.get();
    handles.emplace(pointer, std::move(handle));
    return pointer;
  }

  static std::shared_ptr<Handle> Find(Handle *pointer) {
    std::lock_guard lock(mutex);
    const auto found = handles.find(pointer);
    return found == handles.end() ? nullptr : found->second;
  }

  static void Remove(Handle *pointer) {
    std::lock_guard lock(mutex);
    handles.erase(pointer);
  }

private:
  inline static std::mutex mutex;
  inline static std::unordered_map<Handle *, std::shared_ptr<Handle>> handles;
};

template <typename Handle> class SileroCall {
public:
  explicit SileroCall(Handle *pointer)
      : handle(SileroHandles<Handle>::Find(pointer)) {
    if (handle) {
      lock = std::shared_lock(handle->call_mutex);
    } else {
    }
  }

  explicit operator bool() const { return handle && !handle->is_destroyed; }

private:
  std::shared_ptr<Handle> handle;
  std::shared_lock<std::shared_mutex> lock;
};

} // namespace omni_native
