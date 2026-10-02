// SPDX-License-Identifier: MIT
#pragma once
#include "Store.h"
#include <utility>

namespace neostation::storage {
// Explicitly owned immutable, regenerable CPU data, not a malloc interceptor.
// The cache owner must serialize entry mutation with readers. Leases and
// accepted asynchronous requests may outlive the cache entry. The owning
// session must retain Store and destroy it on a utility thread, not in a draw
// callback: releasing the last Store owner may wait for its worker.
class CacheEntry final {
public:
    explicit CacheEntry(std::unique_ptr<Bytes> input) : local_(std::move(input)) {}
    ~CacheEntry() { retire(); }
    CacheEntry(const CacheEntry&) = delete;
    CacheEntry& operator=(const CacheEntry&) = delete;
    CacheEntry(CacheEntry&&) = delete;
    CacheEntry& operator=(CacheEntry&&) = delete;
    Submission offload(const std::shared_ptr<Store>& store, Heat heat=Heat::cold) {
        if (!store || !local_ || handle_.id) return {Code::invalid, {}, {}};
        auto submission=store->publish(local_,heat);
        if (submission.code==Code::ok) {store_=store;handle_=submission.handle;}
        return submission;
    }
    // Never retain this pointer across offload/retire. Use a Lease after publish.
    const Bytes* local() const noexcept { return local_.get(); }
    Result try_acquire() {
        return store_ ? store_->try_acquire(handle_) : Result{Code::missing,0,{}};
    }
    Submission request(bool prefetch=false) {
        return store_ ? store_->request(handle_,prefetch) : Submission{Code::missing,{},{}};
    }
    void retire() {
        if(store_){(void)store_->discard(handle_);handle_={};store_.reset();}
        local_.reset();
    }
    Handle handle() const noexcept { return handle_; }
private:
    std::unique_ptr<Bytes> local_;
    std::shared_ptr<Store> store_;
    Handle handle_{};
};
} // namespace neostation::storage
