// SPDX-License-Identifier: MIT
#pragma once
#include <memory>
#include <mutex>
#include <utility>
namespace neostation::storage {
// Core callbacks never wait for this control-plane lock. Retired owners are
// returned to the service and destroyed only on its utility queue.
template<class T> class SessionSlot final {
    mutable std::mutex mutex_;
    std::shared_ptr<T> value_;
public:
    std::shared_ptr<T> try_load() const {
        std::unique_lock lock(mutex_, std::try_to_lock);
        return lock.owns_lock() ? value_ : nullptr;
    }
    std::shared_ptr<T> control_load() const {
        std::lock_guard lock(mutex_);return value_;
    }
    std::shared_ptr<T> exchange(std::shared_ptr<T> next) {
        std::lock_guard lock(mutex_);value_.swap(next);return next;
    }
};
}
