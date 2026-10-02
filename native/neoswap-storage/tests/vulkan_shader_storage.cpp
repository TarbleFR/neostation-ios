// SPDX-License-Identifier: MIT
// Real MoltenVK module/pipeline/dispatch after checked disk restoration.
// Synthetic SPIR-V, not a full RPCS3 renderer or God of War III benchmark.
#include "ShaderCache.h"
#include "Client.h"
#include <vulkan/vulkan.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <thread>
#include <vector>
using namespace neostation::storage;
using namespace neostation::storage_client;
static ShaderCache* cache;
static uint64_t epoch=1;
uint64_t session(){return epoch;}
int acquire(uint64_t s,const uint8_t* k,NeoSwapStorageView* out){
    *out={};if(s!=epoch)return NS_STORAGE_DISABLED;ShaderKey key;std::memcpy(key.data(),k,key.size());
    auto r=cache->acquire(key);if(r.code!=Code::ok)return NS_STORAGE_MISS;
    auto lease=new neostation::storage::Lease(std::move(r.lease));*out={reinterpret_cast<const uint32_t*>(lease->data()),lease->size(),lease};return NS_STORAGE_OK;
}
int publish(uint64_t s,const uint8_t* k,const uint32_t* data,uint64_t n){
    if(s!=epoch)return NS_STORAGE_DISABLED;ShaderKey key;std::memcpy(key.data(),k,key.size());return cache->publish(key,data,n)==Code::ok?NS_STORAGE_OK:NS_STORAGE_BUSY;
}
void release(NeoSwapStorageView* out){delete static_cast<neostation::storage::Lease*>(out->lease);*out={};}
void prefetch(uint64_t,const uint8_t* k){ShaderKey key;std::memcpy(key.data(),k,key.size());cache->prefetch(key);}
void invalidate(uint64_t,const uint8_t* k){ShaderKey key;std::memcpy(key.data(),k,key.size());cache->invalidate(key);}
void event(uint64_t,uint32_t kind,uint64_t bytes){cache->event(kind,bytes);}
static const NeoSwapStorageAPI api{sizeof(api),1,session,acquire,publish,release,prefetch,invalidate,event};
void require(bool b,const char* msg){if(!b)throw std::runtime_error(msg);}
void wait(Submission s){require(s.code==Code::ok,"job admission");require(s.completion.wait_for(std::chrono::seconds(10))==std::future_status::ready,"job timeout");require(s.completion.get().code==Code::ok,"job failure");}
std::vector<uint32_t> binary(){
    std::vector<uint32_t> out{0x07230203,0x00010000,0,5,0,
        0x00020011,1,0x0003000e,0,1,0x0005000f,5,4,0x6e69616d,0,
        0x00060010,4,17,1,1,1,0x00020013,1,0x00030021,2,1,
        0x00050036,1,4,0,2,0x000200f8,3};
    out.insert(out.end(),5000,0x00010000);
    out.push_back(0x000100fd);out.push_back(0x00010038);return out;
}
int main(int argc,char** argv){try {
    require(argc==2,"private cache path required");std::filesystem::create_directories(argv[1]);
    Config config;config.ram_bytes=2*1024*1024;config.warm_bytes=0;config.disk_bytes=8*1024*1024;config.compression=false;config.max_write_bytes_per_second=0;
    ShaderCache owner(argv[1],epoch,config);cache=&owner;require(install(&api)==0,"client ABI");
    uint32_t count=0;require(vkEnumerateInstanceExtensionProperties(nullptr,&count,nullptr)==VK_SUCCESS,"instance extensions");
    std::vector<VkExtensionProperties> ie(count);require(vkEnumerateInstanceExtensionProperties(nullptr,&count,ie.data())==VK_SUCCESS,"extension list");
    bool portability=std::any_of(ie.begin(),ie.end(),[](const auto& p){return !std::strcmp(p.extensionName,VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);});
    const char* extension=VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    VkApplicationInfo app{};app.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO;app.apiVersion=VK_API_VERSION_1_2;
    VkInstanceCreateInfo ii{};ii.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;ii.pApplicationInfo=&app;
    if(portability){ii.enabledExtensionCount=1;ii.ppEnabledExtensionNames=&extension;ii.flags=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;}
    VkInstance instance=nullptr;require(vkCreateInstance(&ii,nullptr,&instance)==VK_SUCCESS,"real Vulkan instance");
    require(vkEnumeratePhysicalDevices(instance,&count,nullptr)==VK_SUCCESS&&count,"physical GPU");
    std::vector<VkPhysicalDevice> physical(count);require(vkEnumeratePhysicalDevices(instance,&count,physical.data())==VK_SUCCESS,"GPU list");
    auto gpu=physical.front();VkPhysicalDeviceProperties properties{};vkGetPhysicalDeviceProperties(gpu,&properties);
    require(properties.deviceType!=VK_PHYSICAL_DEVICE_TYPE_CPU,"real non-CPU GPU required");
    vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,nullptr);std::vector<VkQueueFamilyProperties> families(count);vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,families.data());
    uint32_t family=UINT32_MAX;for(uint32_t i=0;i<count;++i)if(families[i].queueCount&&(families[i].queueFlags&VK_QUEUE_COMPUTE_BIT)){family=i;break;}
    require(family!=UINT32_MAX,"compute queue");
    require(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,nullptr)==VK_SUCCESS,"device extensions");
    std::vector<VkExtensionProperties> de(count);require(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,de.data())==VK_SUCCESS,"device extension list");
    bool subset=std::any_of(de.begin(),de.end(),[](const auto& p){return !std::strcmp(p.extensionName,"VK_KHR_portability_subset");});
    const char* ds="VK_KHR_portability_subset";float priority=1;
    VkDeviceQueueCreateInfo qi{};qi.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;qi.queueFamilyIndex=family;qi.queueCount=1;qi.pQueuePriorities=&priority;
    VkDeviceCreateInfo di{};di.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;di.queueCreateInfoCount=1;di.pQueueCreateInfos=&qi;if(subset){di.enabledExtensionCount=1;di.ppEnabledExtensionNames=&ds;}
    VkDevice device=nullptr;require(vkCreateDevice(gpu,&di,nullptr,&device)==VK_SUCCESS,"Vulkan device");
    std::vector<uint32_t> original;unsigned compiles=0;VkShaderModule module=nullptr;
    auto t=ticket();t.key[0]=61;
    auto build=[&](auto& v){++compiles;v=binary();return true;};
    auto create=[&](const uint32_t* p,size_t n){
        VkShaderModuleCreateInfo mi{};mi.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;mi.pCode=p;mi.codeSize=n;
        return vkCreateShaderModule(device,&mi,nullptr,&module)==VK_SUCCESS?ModuleResult::ok:ModuleResult::fatal;
    };
    for(unsigned attempt=0;attempt<100;++attempt){
        require(compile(t,original,build,create)==CompileResult::ok&&module,"source module creation");
        if(original.empty())break;
        vkDestroyShaderModule(device,module,nullptr);module=nullptr;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    require(module&&original.empty(),"eventual nonblocking cache admission");
    const unsigned sourceBuildsBeforeRestore=compiles;
    vkDestroyShaderModule(device,module,nullptr);module=nullptr;
    wait(owner.test_store().barrier());wait(owner.test_store().trim());require(owner.snapshot().store.disk_only_logical_bytes>0,"real disk-only eviction");
    prefetch(epoch,t.key.data());
    for(unsigned i=0;i<2000&&owner.snapshot().store.disk_hits==0;++i){std::this_thread::sleep_for(std::chrono::milliseconds(1));}
    require(owner.snapshot().store.disk_hits>0,"restoration from actual file");
    require(compile(t,original,build,create)==CompileResult::ok&&module&&compiles==sourceBuildsBeforeRestore,"restored bytecode consumed without rebuilding");
    owner.maintain();wait(owner.test_store().trim());
    require(owner.snapshot().store.raw_ram_bytes==0,"release cache mappings before pipeline creation");
    VkPipelineLayoutCreateInfo li{};li.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    VkPipelineLayout layout=nullptr;require(vkCreatePipelineLayout(device,&li,nullptr,&layout)==VK_SUCCESS,"pipeline layout");
    VkComputePipelineCreateInfo ci{};ci.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;ci.layout=layout;ci.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=module;ci.stage.pName="main";
    VkPipeline pipeline=nullptr;require(vkCreateComputePipelines(device,nullptr,1,&ci,nullptr,&pipeline)==VK_SUCCESS,"pipeline from restored module after CPU release");
    VkCommandPoolCreateInfo pi{};pi.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;pi.queueFamilyIndex=family;
    VkCommandPool pool=nullptr;require(vkCreateCommandPool(device,&pi,nullptr,&pool)==VK_SUCCESS,"command pool");
    VkCommandBufferAllocateInfo ai{};ai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;ai.commandPool=pool;ai.commandBufferCount=1;ai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    VkCommandBuffer command=nullptr;require(vkAllocateCommandBuffers(device,&ai,&command)==VK_SUCCESS,"commands");
    VkCommandBufferBeginInfo bi{};bi.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;require(vkBeginCommandBuffer(command,&bi)==VK_SUCCESS,"begin");
    vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);vkCmdDispatch(command,1,1,1);require(vkEndCommandBuffer(command)==VK_SUCCESS,"end");
    VkFenceCreateInfo fi{};fi.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;VkFence fence=nullptr;require(vkCreateFence(device,&fi,nullptr,&fence)==VK_SUCCESS,"fence");
    VkQueue queue=nullptr;vkGetDeviceQueue(device,family,0,&queue);VkSubmitInfo si{};si.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;si.commandBufferCount=1;si.pCommandBuffers=&command;
    require(vkQueueSubmit(queue,1,&si,fence)==VK_SUCCESS,"submit");require(vkWaitForFences(device,1,&fence,VK_TRUE,10'000'000'000ULL)==VK_SUCCESS,"compute completed");
    const auto stat=owner.snapshot();
    vkDestroyFence(device,fence,nullptr);vkDestroyCommandPool(device,pool,nullptr);vkDestroyPipeline(device,pipeline,nullptr);vkDestroyPipelineLayout(device,layout,nullptr);vkDestroyShaderModule(device,module,nullptr);vkDestroyDevice(device,nullptr);vkDestroyInstance(instance,nullptr);
    std::cout<<"{\"passed\":true,\"realVulkanModule\":true,\"realComputeDispatchCompleted\":true,\"cpuBytesReleasedBeforePipeline\":true,\"sourceBuilds\":"<<compiles<<",\"sourceBuildsBeforeRestore\":"<<sourceBuildsBeforeRestore<<",\"diskReadBytes\":"<<stat.store.bytes_read<<",\"diskWriteBytes\":"<<stat.store.bytes_written<<",\"cacheHits\":"<<stat.hits<<",\"physicalIPhoneValidated\":false,\"realRPCS3GameplayValidated\":false}\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
