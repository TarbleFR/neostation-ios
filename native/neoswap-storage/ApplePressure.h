// SPDX-License-Identifier: MIT
#pragma once
#include "Store.h"
#ifdef __APPLE__
#include <dispatch/dispatch.h>
namespace neostation::storage {
// Destroy BEFORE Store on a setup/utility thread, never from its event callback.
class ApplePressure final {
public:
    explicit ApplePressure(Store& store);
    ~ApplePressure();
    ApplePressure(const ApplePressure&)=delete;
    ApplePressure& operator=(const ApplePressure&)=delete;
    bool active() const noexcept {return source_ != nullptr;}
private:
    Store& store_; dispatch_source_t source_=nullptr;
    dispatch_semaphore_t cancelled_=nullptr;
    static void event(void*);
    static void cancelled(void*);
};
}
#endif
