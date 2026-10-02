// SPDX-License-Identifier: MIT
#include "ApplePressure.h"
#ifdef __APPLE__
namespace neostation::storage {
ApplePressure::ApplePressure(Store& store):store_(store){
    cancelled_=dispatch_semaphore_create(0);if(!cancelled_)return;
    source_=dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,0,
        DISPATCH_MEMORYPRESSURE_NORMAL|DISPATCH_MEMORYPRESSURE_WARN|DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    if(!source_){dispatch_release(cancelled_);cancelled_=nullptr;return;}
    dispatch_set_context(source_,this);
    dispatch_source_set_event_handler_f(source_,&ApplePressure::event);
    dispatch_source_set_cancel_handler_f(source_,&ApplePressure::cancelled);
    dispatch_resume(source_);
}
void ApplePressure::event(void* ptr){auto& self=*static_cast<ApplePressure*>(ptr);const auto flags=dispatch_source_get_data(self.source_);
    self.store_.set_pressure(flags&DISPATCH_MEMORYPRESSURE_CRITICAL?Pressure::critical:
        flags&DISPATCH_MEMORYPRESSURE_WARN?Pressure::warning:Pressure::normal);
}
void ApplePressure::cancelled(void* ptr){dispatch_semaphore_signal(static_cast<ApplePressure*>(ptr)->cancelled_);}
ApplePressure::~ApplePressure(){
    if(source_){dispatch_source_cancel(source_);dispatch_semaphore_wait(cancelled_,DISPATCH_TIME_FOREVER);dispatch_release(source_);}
    if(cancelled_)dispatch_release(cancelled_);
}
}
#endif
