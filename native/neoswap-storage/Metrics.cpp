// SPDX-License-Identifier: MIT
#include "Store.h"
#ifdef __APPLE__
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#else
#include <cstdio>
#include <unistd.h>
#endif
namespace neostation::storage {
ProcessMetrics sample_process() noexcept {
    ProcessMetrics out{};
#ifdef __APPLE__
    task_vm_info_data_t info{};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    if(::task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS){
        out.resident_bytes=info.resident_size;out.resident_valid=true;
        if(count>=TASK_VM_INFO_REV1_COUNT){out.footprint_bytes=info.phys_footprint;out.footprint_valid=true;}
        out.compressed_accounted_bytes=info.compressed;out.compressed_valid=true;
    }
#if TARGET_OS_IPHONE
    out.process_available_bytes=os_proc_available_memory();out.process_available_valid=true;
#endif
#else
    if(auto* f=std::fopen("/proc/self/statm","r")){
        unsigned long pages=0,resident=0;
        if(std::fscanf(f,"%lu %lu",&pages,&resident)==2){out.resident_bytes=resident*uint64_t(::sysconf(_SC_PAGESIZE));out.resident_valid=true;}
        std::fclose(f);
    }
#endif
    return out;
}
}
