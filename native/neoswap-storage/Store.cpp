// SPDX-License-Identifier: MIT
#include "Store.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <zlib.h>
#ifdef __APPLE__
#include <compression.h>
#include <pthread.h>
#else
#include <lz4.h>
#endif
namespace neostation::storage {
namespace {
using Clock = std::chrono::steady_clock;
uint64_t us(Clock::time_point t) { return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-t).count(); }
size_t page() { static const size_t p = static_cast<size_t>(::sysconf(_SC_PAGESIZE)); return p; }
size_t aligned(size_t n) { if (!n || n > SIZE_MAX-page()) throw std::invalid_argument("blob size"); return (n+page()-1)/page()*page(); }
uint32_t checksum(const Bytes& b) { return static_cast<uint32_t>(::crc32(0, b.data(), static_cast<uInt>(b.size()))); }
struct Histogram {
    std::array<uint64_t,256> ring{}; size_t count=0, at=0; uint64_t maximum=0;
    void add(uint64_t n) { ring[at++%ring.size()]=n; count=std::min(count+1,ring.size()); maximum=std::max(maximum,n); }
    uint64_t percentile(unsigned p) const { if(!count)return 0; auto a=ring; std::sort(a.begin(),a.begin()+count); return a[((count-1)*p+99)/100]; }
};
std::atomic<uint64_t> next_session{1};
}
Bytes::Bytes(size_t n):size_(n),mapped_(aligned(n)) {
    if(n>8U*1024*1024)throw std::invalid_argument("blob exceeds 8 MiB");
    void* m=::mmap(nullptr,mapped_,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(m==MAP_FAILED)throw std::system_error(errno,std::generic_category(),"mmap CPU blob");
    data_=static_cast<uint8_t*>(m);
}
Bytes::~Bytes(){if(data_)::munmap(data_,mapped_);}
Bytes::Bytes(Bytes&& b) noexcept:data_(std::exchange(b.data_,nullptr)),size_(std::exchange(b.size_,0)),mapped_(std::exchange(b.mapped_,0)){}
Bytes& Bytes::operator=(Bytes&& b) noexcept {if(this!=&b){if(data_)::munmap(data_,mapped_);data_=std::exchange(b.data_,nullptr);size_=std::exchange(b.size_,0);mapped_=std::exchange(b.mapped_,0);}return *this;}
bool Bytes::shrink(size_t n) noexcept {
    if(!n || n>size_)return false;
    const size_t mapped=(n+page()-1)/page()*page();
    if(mapped<mapped_ && ::munmap(data_+mapped,mapped_-mapped))return false;
    size_=n;mapped_=mapped;return true;
}
bool Bytes::seal() noexcept {return ::mprotect(data_,mapped_,PROT_READ)==0;}
const char* codec_name() noexcept {
#ifdef __APPLE__
 return "Apple Compression LZ4_RAW";
#else
 return "liblz4 raw";
#endif
}
struct Store::Impl {
    enum class Kind {read,trim,write,prefetch,barrier};
    struct Entry {
        uint64_t id=0, offset=0, stamp=0, span=0; uint32_t size=0, stored=0, crc=0, codec=0;
        bool disk=false,busy=false,prefetched=false,discarded=false; Heat heat=Heat::cold;
        std::shared_ptr<Bytes> raw,warm;
    };
    struct Header {uint64_t magic=0x31524f5453454eULL,session=0,id=0; uint32_t size=0,stored=0,crc=0,codec=0;};
    static_assert(sizeof(Header)==40);
    struct Job {Kind kind; uint64_t id; Clock::time_point queued=Clock::now();std::promise<Result> done;};
    Config config; int fd=-1; uint64_t session=next_session.fetch_add(1),next_id=1,clock=0,tail=0,loading=0;
    mutable std::mutex mu,tm; std::condition_variable cv; std::thread worker;
    std::unordered_map<uint64_t,Entry> entries;
    struct Extent {uint64_t offset, size;};
    // Reserved once. At most one free interval between each live record and
    // one inflight write, so erasing a record never allocates metadata.
    std::vector<Extent> free_extents;
    std::deque<std::unique_ptr<Job>> queue; bool stopping=false;
    std::atomic<Pressure> pressure{Pressure::normal}; std::atomic<uint64_t> transitions{0};
    std::unique_ptr<Bytes> codec_scratch;
    Stats stats; Histogram reads,writes,queues,restores; Clock::time_point write_after{};
#ifdef NEOSWAP_STORAGE_TESTING
    std::atomic<Fault> fault{Fault::none};
    bool hit(Fault f){auto expected=f;return fault.compare_exchange_strong(expected,Fault::none);}
#endif
    explicit Impl(const std::string& parent,Config c):config(c) {
        if(c.max_blob<65536 || c.max_blob>(8U<<20) || c.ram_bytes<c.max_blob*2ULL || c.ram_bytes>(1ULL<<30) ||
           c.warm_bytes>c.ram_bytes/2 || c.disk_bytes<c.max_blob || c.disk_bytes>(8ULL<<30) ||
           !c.max_queue || c.max_queue>64 || !c.max_entries || c.max_entries>4096)
            throw std::invalid_argument("storage limits");
        if(parent.empty() || parent.front()!='/')throw std::invalid_argument("absolute private directory required");
        std::string path=parent+"/neoswap-storage-XXXXXX";
        fd=::mkstemp(path.data());
        if(fd<0)throw std::system_error(errno,std::generic_category(),"temporary store");
        if(::fchmod(fd,0600) || ::fcntl(fd,F_SETFD,FD_CLOEXEC) || ::unlink(path.c_str())) {
            const int e=errno;::close(fd);fd=-1;::unlink(path.c_str());throw std::system_error(e,std::generic_category(),"private store");
        }
#ifdef __APPLE__
        (void)::fcntl(fd,F_NOCACHE,1);
#endif
        try {
            if(config.compression){
#ifdef __APPLE__
                const size_t scratch=std::max(::compression_encode_scratch_buffer_size(COMPRESSION_LZ4_RAW),::compression_decode_scratch_buffer_size(COMPRESSION_LZ4_RAW));
#else
                const size_t scratch=static_cast<size_t>(::LZ4_sizeofState());
#endif
                if(scratch>(1U<<20))config.compression=false;
                else if(scratch){try {codec_scratch=std::make_unique<Bytes>(scratch);}
                    catch(const std::exception&){config.compression=false;}}
            }
            entries.reserve(c.max_entries);free_extents.reserve(c.max_entries+2);worker=std::thread([this]{run();});}
        catch(...){::close(fd);fd=-1;throw;}
    }
    ~Impl(){
        {std::lock_guard l(mu);stopping=true;for(auto& j:queue)j->done.set_value({Code::stopped,0,{}});queue.clear();}
        cv.notify_all();if(worker.joinable())worker.join();if(fd>=0)::close(fd);
    }
    uint64_t ram() const {uint64_t n=loading;for(auto& [id,e]:entries){(void)id;if(e.raw)n+=e.raw->mapped_size();if(e.warm)n+=e.warm->mapped_size();}return n;}
    uint64_t warm_size() const {uint64_t n=0;for(auto& [id,e]:entries){(void)id;if(e.warm)n+=e.warm->mapped_size();}return n;}
    uint64_t target() const {const auto p=pressure.load();return p==Pressure::critical?0:p==Pressure::warning?config.ram_bytes/2:config.ram_bytes;}
    void peak(){std::lock_guard t(tm);stats.managed_ram_peak=std::max(stats.managed_ram_peak,ram());}
    bool trim_to(uint64_t limit,uint64_t except=0){
        while(ram()>limit){
            Entry* victim=nullptr;
            for(auto& [id,e]:entries){
                if(id==except || e.busy || !e.disk || (!e.raw&&!e.warm) || (e.raw&&e.raw.use_count()!=1))continue;
                if(!victim || (e.heat==Heat::cold&&victim->heat==Heat::hot) ||
                   (e.heat==victim->heat&&e.stamp<victim->stamp))victim=&e;
            }
            if(!victim)return false;
            {std::lock_guard t(tm);stats.evicted_logical_bytes+=victim->size;
             if(victim->prefetched){++stats.prefetch_wasted;victim->prefetched=false;}}
            victim->raw.reset();victim->warm.reset();
        }return true;
    }
    Submission submit(Kind k,uint64_t id){
        if(stopping)return {Code::stopped,{}, {}};
        if(k==Kind::prefetch && queue.size()+1>=config.max_queue){std::lock_guard t(tm);++stats.prefetch_cancelled;return {Code::busy,{}, {}};}
        if(queue.size()>=config.max_queue && k==Kind::read){
            const auto speculative=std::find_if(queue.begin(),queue.end(),[](const auto& j){return j->kind==Kind::prefetch;});
            if(speculative!=queue.end()){(*speculative)->done.set_value({Code::busy,0,{}});queue.erase(speculative);std::lock_guard t(tm);++stats.prefetch_cancelled;}
        }
        if(queue.size()>=config.max_queue){std::lock_guard t(tm);++stats.backpressure;return {Code::busy,{}, {}};}
        auto j=std::make_unique<Job>();j->kind=k;j->id=id;
        Submission out{Code::ok,{session,id},j->done.get_future()};queue.push_back(std::move(j));
        {std::lock_guard t(tm);stats.queue_peak=std::max<uint64_t>(stats.queue_peak,queue.size());}
        cv.notify_one();return out;
    }
    void return_extent(uint64_t offset,uint64_t span){
        if(!span)return;
        auto it=std::lower_bound(free_extents.begin(),free_extents.end(),offset,
            [](const Extent& a,uint64_t b){return a.offset<b;});
        if(it!=free_extents.begin()){
            auto prev=it-1;
            if(prev->offset+prev->size==offset){
                prev->size+=span;
                if(it!=free_extents.end()&&prev->offset+prev->size==it->offset){
                    prev->size+=it->size;free_extents.erase(it);
                }return;
            }
        }
        if(it!=free_extents.end()&&offset+span==it->offset){it->offset=offset;it->size+=span;return;}
        free_extents.insert(it,{offset,span});
    }
    void collect_discarded(){
        for(auto it=entries.begin();it!=entries.end();){
            auto& e=it->second;
            const bool queued=std::any_of(queue.begin(),queue.end(),[&](const auto& j){return j->id==e.id;});
            if(!e.discarded||e.busy||queued||(e.raw&&e.raw.use_count()!=1)){++it;continue;}
            return_extent(e.offset,e.span);it=entries.erase(it);
            std::lock_guard t(tm);++stats.discarded_entries;
        }
    }
    int allocate_extent(uint64_t span,uint64_t& offset){
        {
            std::lock_guard l(mu);
            auto it=std::find_if(free_extents.begin(),free_extents.end(),
                [&](const Extent& e){return e.size>=span;});
            if(it!=free_extents.end()){
                offset=it->offset;it->offset+=span;it->size-=span;
                if(!it->size)free_extents.erase(it);
                std::lock_guard t(tm);++stats.reused_extent_count;return 0;
            }
        }
        // A reused hole is already reserved. Never truncate it: live records
        // can follow it. Only appending needs reservation and a free-space test.
        offset=tail;const int err=reserve(offset,span);if(!err)tail+=span;return err;
    }
    Result error(int err,Code c=Code::io){std::lock_guard t(tm);stats.last_errno=err;if(err==ENOSPC)++stats.quota_refusals;if(c==Code::corrupt)++stats.corruptions;else ++stats.io_errors;return {c,err,{}};}
    int transfer(void* data,size_t n,uint64_t off,bool write){
        bool short_io=false;
#ifdef NEOSWAP_STORAGE_TESTING
        if(hit(write?Fault::write_error:Fault::read_error))return write?ENOSPC:EIO;
        short_io=hit(Fault::short_io);
#endif
        auto* p=static_cast<uint8_t*>(data);
        while(n){size_t part=short_io?std::min(n,size_t(13)):n;
            ssize_t done=write?::pwrite(fd,p,part,static_cast<off_t>(off)): ::pread(fd,p,part,static_cast<off_t>(off));
            if(done<0){if(errno==EINTR)continue;return errno;}if(done==0)return EIO;
            {std::lock_guard t(tm);if(write){stats.bytes_written+=done;++stats.write_calls;}else{stats.bytes_read+=done;++stats.read_calls;}}
            p+=done;off+=static_cast<uint64_t>(done);n-=static_cast<size_t>(done);
        }return 0;
    }
    int reserve(uint64_t off,uint64_t n){
        if(off>config.disk_bytes || n>config.disk_bytes-off)return ENOSPC;
        struct statvfs v{};if(::fstatvfs(fd,&v))return errno;
        const uint64_t free=uint64_t(v.f_bavail)*v.f_frsize;
        if(free<config.free_disk_floor || n>free-config.free_disk_floor)return ENOSPC;
#ifdef __APPLE__
        fstore_t store{};store.fst_flags=F_ALLOCATEALL;store.fst_posmode=F_PEOFPOSMODE;store.fst_length=static_cast<off_t>(n);
        int ret;do{ret=::fcntl(fd,F_PREALLOCATE,&store);}while(ret<0&&errno==EINTR);if(ret<0)return errno;
#else
        int ret;do{ret=::posix_fallocate(fd,static_cast<off_t>(off),static_cast<off_t>(n));}while(ret==EINTR);if(ret)return ret;
#endif
        if(::ftruncate(fd,static_cast<off_t>(off+n)))return errno;return 0;
    }
    Result write(uint64_t id){
        std::shared_ptr<Bytes> raw;{std::lock_guard l(mu);auto it=entries.find(id);if(it==entries.end())return {Code::missing,0,{}};it->second.busy=true;raw=it->second.raw;}
        const auto begin=Clock::now();std::shared_ptr<Bytes> compressed;
        uint32_t codec=0;uint64_t encode_us=0;
        if(config.compression&&pressure.load()==Pressure::normal){
            try {compressed=std::make_shared<Bytes>(raw->size());const auto start=Clock::now();size_t count=0;
#ifdef __APPLE__
            count=::compression_encode_buffer(compressed->data(),compressed->size(),raw->data(),raw->size(),codec_scratch?codec_scratch->data():nullptr,COMPRESSION_LZ4_RAW);
#else
            count=static_cast<size_t>(::LZ4_compress_fast_extState(codec_scratch->data(),reinterpret_cast<const char*>(raw->data()),reinterpret_cast<char*>(compressed->data()),static_cast<int>(raw->size()),static_cast<int>(compressed->size()),1));
#endif
            encode_us=us(start);
            if(count&&count<=raw->size()-raw->size()/8&&encode_us<=config.compression_budget_us&&compressed->shrink(count)&&compressed->seal())codec=1;
            else compressed.reset();
            std::lock_guard t(tm);++stats.compression_attempts;stats.compression_us+=encode_us;stats.worker_scratch_peak=std::max<uint64_t>(stats.worker_scratch_peak,raw->mapped_size()+(codec_scratch?codec_scratch->mapped_size():0));
            if(codec){++stats.compression_accepted;stats.compression_input_bytes+=raw->size();stats.compression_output_bytes+=compressed->size();}
            }catch(const std::bad_alloc&){compressed.reset();codec=0;}
             catch(const std::system_error&){compressed.reset();codec=0;}
        }
        auto payload=codec?compressed:raw;
        Header head{};head.session=session;head.id=id;head.size=static_cast<uint32_t>(raw->size());head.stored=static_cast<uint32_t>(payload->size());head.crc=checksum(*raw);head.codec=codec;
        uint64_t offset=0;const uint64_t span=aligned(sizeof(head)+payload->size());int err=allocate_extent(span,offset);
        const bool reserved=!err;
        if(!err){err=transfer(&head,sizeof(head),offset,true);if(!err)err=transfer(payload->data(),payload->size(),offset+sizeof(head),true);}
        if(!err){
#ifdef NEOSWAP_STORAGE_TESTING
            if(hit(Fault::sync_error))err=EIO;else
#endif
            {int ret;do{ret=::fsync(fd);}while(ret<0&&errno==EINTR);if(ret<0)err=errno;}
        }
        struct stat st{};const bool stat_ok=::fstat(fd,&st)==0;
        {std::lock_guard t(tm);writes.add(us(begin));stats.reserved_file_bytes=tail;if(stat_ok)stats.allocated_file_bytes=uint64_t(st.st_blocks)*512;}
        payload.reset();raw.reset();
        {std::lock_guard l(mu);auto& e=entries.at(id);e.busy=false;
         if(err&&reserved)return_extent(offset,span);
         if(!err){e.disk=true;e.offset=offset;e.span=span;e.stored=head.stored;e.crc=head.crc;e.codec=codec;
            if(compressed&&pressure.load()==Pressure::normal&&e.heat==Heat::cold&&e.raw.use_count()==1&&
               warm_size()+compressed->mapped_size()<=config.warm_bytes){e.raw.reset();e.warm=std::move(compressed);}
         }
         trim_to(target());peak();}
        return err?error(err):Result{};
    }
    Result read(uint64_t id,bool prefetch){
        const auto begin=Clock::now();Header expected{};std::shared_ptr<Bytes> warm;uint64_t offset=0,required=0;
        {std::lock_guard l(mu);auto it=entries.find(id);if(it==entries.end())return {Code::missing,0,{}};auto& e=it->second;
            if(prefetch&&pressure.load()!=Pressure::normal){std::lock_guard t(tm);++stats.prefetch_cancelled;return {Code::pressure,0,{}};}
            if(e.raw){e.stamp=++clock;if(!prefetch){e.heat=Heat::hot;std::lock_guard t(tm);++stats.ram_hits;if(e.prefetched){++stats.prefetch_used;e.prefetched=false;}}return {Code::ok,0,prefetch?Lease{}:Lease{e.raw}};}
            if(!e.disk)return {Code::busy,0,{}};
            required=aligned(e.size);const uint64_t hard=config.ram_bytes+config.max_blob;
            const uint64_t limit=prefetch?config.ram_bytes:hard;
            if(required>limit||(!trim_to(limit-required,id)&&ram()>limit-required)){std::lock_guard t(tm);++stats.quota_refusals;return {Code::quota,0,{}};}
            e.busy=true;loading+=required;warm=e.warm;offset=e.offset;
            expected.session=session;expected.id=e.id;expected.size=e.size;expected.stored=e.stored;expected.crc=e.crc;expected.codec=e.codec;peak();
        }
        std::shared_ptr<Bytes> raw;int err=0;Code code=Code::ok;
        try{
            raw=std::make_shared<Bytes>(expected.size);
            std::shared_ptr<Bytes> encoded=warm;
            const auto io_start=Clock::now();
            if(!warm){
#ifdef NEOSWAP_STORAGE_TESTING
                if(hit(Fault::truncate))::ftruncate(fd,static_cast<off_t>(offset+sizeof(Header)+expected.stored/2));
                if(hit(Fault::corrupt)){uint8_t bad=0xff;(void)::pwrite(fd,&bad,1,static_cast<off_t>(offset));}
#endif
                Header actual{};err=transfer(&actual,sizeof(actual),offset,false);
                if(!err&&std::memcmp(&actual,&expected,sizeof(actual))){err=EILSEQ;code=Code::corrupt;}
                if(!err){if(expected.codec)encoded=std::make_shared<Bytes>(expected.stored);
                    auto dest=expected.codec?encoded:raw;err=transfer(dest->data(),dest->size(),offset+sizeof(Header),false);}
                std::lock_guard t(tm);reads.add(us(io_start));
                if(expected.codec)stats.worker_scratch_peak=std::max<uint64_t>(stats.worker_scratch_peak,aligned(expected.stored)+(codec_scratch?codec_scratch->mapped_size():0));
            }
            if(!err&&expected.codec){const auto dstart=Clock::now();size_t decoded=0;
#ifdef __APPLE__
                decoded=::compression_decode_buffer(raw->data(),raw->size(),encoded->data(),encoded->size(),codec_scratch?codec_scratch->data():nullptr,COMPRESSION_LZ4_RAW);
#else
                const int n=::LZ4_decompress_safe(reinterpret_cast<const char*>(encoded->data()),reinterpret_cast<char*>(raw->data()),static_cast<int>(encoded->size()),static_cast<int>(raw->size()));decoded=n<0?0:static_cast<size_t>(n);
#endif
                if(decoded!=raw->size()){err=EILSEQ;code=Code::corrupt;}
                std::lock_guard t(tm);stats.decompression_us+=us(dstart);
            }
            if(!err&&checksum(*raw)!=expected.crc){err=EILSEQ;code=Code::corrupt;}
            if(!err&&!raw->seal())err=errno;
        }catch(const std::system_error& e){err=e.code().value();}catch(const std::bad_alloc&){err=ENOMEM;}
        const bool was_warm=bool(warm);warm.reset();
        Lease lease;
        {std::lock_guard l(mu);auto& e=entries.at(id);e.busy=false;loading-=required;
            if(!err){e.raw=std::move(raw);e.warm.reset();e.stamp=++clock;e.prefetched=prefetch;if(!prefetch){e.heat=Heat::hot;lease.bytes=e.raw;}
                std::lock_guard t(tm);stats.restored_logical_bytes+=e.size;restores.add(us(begin));
                if(was_warm)++stats.warm_hits;else ++stats.disk_hits;}
            trim_to(target(),prefetch?0:id);peak();
        }
        if(err)return error(err,code==Code::ok?Code::io:code);
        return {Code::ok,0,std::move(lease)};
    }
    void run() noexcept {
#ifdef __APPLE__
        (void)::pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0);
#endif
        uint64_t observed_pressure_events=0;
        for(;;){std::unique_ptr<Job> job;
            {std::unique_lock l(mu);cv.wait_for(l,std::chrono::milliseconds(100),[&]{return stopping||!queue.empty()||transitions.load()!=observed_pressure_events;});if(stopping)break;
                observed_pressure_events=transitions.load();
                collect_discarded();trim_to(target());if(queue.empty())continue;
                auto it=std::min_element(queue.begin(),queue.end(),[](const auto& a,const auto& b){return a->kind<b->kind;});
                if((*it)->kind==Kind::write && Clock::now()<write_after){cv.wait_until(l,write_after);continue;}
                job=std::move(*it);queue.erase(it);
                // Protect the dequeue-to-execution gap from explicit erase.
                if(auto e=entries.find(job->id);e!=entries.end())e->second.busy=true;
                if(job->kind==Kind::write&&config.max_write_bytes_per_second){
                    const auto found=entries.find(job->id);
                    if(found!=entries.end())write_after=Clock::now()+std::chrono::microseconds(
                        (found->second.size*1000000ULL)/config.max_write_bytes_per_second);
                }
            }
            {std::lock_guard t(tm);queues.add(us(job->queued));}
            Result result;
            try{switch(job->kind){case Kind::read:result=read(job->id,false);break;case Kind::prefetch:result=read(job->id,true);break;
                case Kind::write:result=write(job->id);break;case Kind::trim:{std::lock_guard l(mu);trim_to(0);break;}case Kind::barrier:break;}}
            catch(const std::system_error& e){result=error(e.code().value());}
            catch(const std::bad_alloc&){result=error(ENOMEM);}
            catch(...){result=error(EIO);}
            {std::lock_guard l(mu);auto it=entries.find(job->id);if(it!=entries.end())it->second.busy=false;}
            job->done.set_value(std::move(result));
        }
    }
};
Store::Store(const std::string& dir,Config c):p_(std::make_unique<Impl>(dir,c)){}
Store::~Store()=default;
Submission Store::publish(std::unique_ptr<Bytes>& input,Heat heat){
    if(!input||!input->data()||!input->size()||input->size()>p_->config.max_blob)return {Code::invalid,{}, {}};
    std::unique_lock l(p_->mu,std::try_to_lock);if(!l.owns_lock())return {Code::busy,{}, {}};
    if(p_->pressure.load()!=Pressure::normal)return {Code::pressure,{}, {}};
    if(p_->stopping)return {Code::stopped,{}, {}};
    if(p_->entries.size()>=p_->config.max_entries){std::lock_guard t(p_->tm);++p_->stats.quota_refusals;return {Code::quota,{}, {}};}
    if(p_->ram()+input->mapped_size()>p_->config.ram_bytes+p_->config.max_blob || p_->queue.size()>=p_->config.max_queue){std::lock_guard t(p_->tm);++p_->stats.backpressure;return {Code::busy,{}, {}};}
    const uint64_t id=p_->next_id++;
    auto raw=std::make_shared<Bytes>();
    auto [it,ok]=p_->entries.try_emplace(id);(void)ok;
    Submission out;
    try {out=p_->submit(Impl::Kind::write,id);}
    catch(...) {p_->entries.erase(it);throw;}
    if(out.code!=Code::ok){p_->entries.erase(it);return out;}
    if(!input->seal()){
        out.code=Code::io;p_->queue.back()->done.set_value({Code::io,errno,{}});
        p_->queue.pop_back();p_->entries.erase(it);return out;
    }
    *raw=std::move(*input);
    auto& e=it->second;e.raw=std::move(raw);e.id=id;e.size=static_cast<uint32_t>(e.raw->size());
    e.heat=heat;e.stamp=++p_->clock;input.reset();p_->peak();return out;
}
Result Store::try_acquire(Handle h){
    std::unique_lock l(p_->mu,std::try_to_lock);if(!l.owns_lock())return {Code::busy,0,{}};
    if(h.session!=p_->session)return {Code::missing,0,{}};auto it=p_->entries.find(h.id);if(it==p_->entries.end())return {Code::missing,0,{}};
    auto& e=it->second;if(e.discarded)return {Code::missing,0,{}};if(!e.raw)return {Code::busy,0,{}};e.stamp=++p_->clock;e.heat=Heat::hot;
    {std::lock_guard t(p_->tm);++p_->stats.ram_hits;if(e.prefetched){++p_->stats.prefetch_used;e.prefetched=false;}}
    return {Code::ok,0,{e.raw}};
}
Submission Store::request(Handle h,bool speculative){
    std::unique_lock l(p_->mu,std::try_to_lock);if(!l.owns_lock())return {Code::busy,{}, {}};
    if(h.session!=p_->session||!p_->entries.count(h.id)||p_->entries.at(h.id).discarded)return {Code::missing,{}, {}};
    if(speculative){std::lock_guard t(p_->tm);if(p_->pressure.load()!=Pressure::normal||p_->reads.percentile(95)>p_->config.prefetch_latency_limit_us){++p_->stats.prefetch_cancelled;return {Code::pressure,{}, {}};}}
    return p_->submit(speculative?Impl::Kind::prefetch:Impl::Kind::read,h.id);
}
Submission Store::trim(){std::lock_guard l(p_->mu);return p_->submit(Impl::Kind::trim,0);}
Submission Store::barrier(){std::lock_guard l(p_->mu);return p_->submit(Impl::Kind::barrier,0);}
Code Store::erase(Handle h){
    std::lock_guard l(p_->mu);if(h.session!=p_->session)return Code::missing;auto it=p_->entries.find(h.id);if(it==p_->entries.end())return Code::missing;
    auto& e=it->second;if(e.busy||(e.raw&&e.raw.use_count()!=1))return Code::busy;
    for(auto& j:p_->queue)if(j->id==h.id)return Code::busy;
    p_->return_extent(e.offset,e.span);p_->entries.erase(it);return Code::ok;
}
Code Store::discard(Handle h){
    std::lock_guard l(p_->mu);if(h.session!=p_->session)return Code::missing;
    auto it=p_->entries.find(h.id);if(it==p_->entries.end())return Code::missing;
    it->second.discarded=true;p_->cv.notify_one();return Code::ok;
}
void Store::set_pressure(Pressure level) noexcept {if(p_->pressure.exchange(level)!=level)p_->transitions.fetch_add(1);p_->cv.notify_one();}
Stats Store::snapshot() const {
    std::lock_guard l(p_->mu);Stats s;{std::lock_guard t(p_->tm);s=p_->stats;s.read_p50_us=p_->reads.percentile(50);s.read_p95_us=p_->reads.percentile(95);s.read_p99_us=p_->reads.percentile(99);s.read_max_us=p_->reads.maximum;s.write_p95_us=p_->writes.percentile(95);s.queue_p95_us=p_->queues.percentile(95);s.restore_p95_us=p_->restores.percentile(95);}
    for(auto& [id,e]:p_->entries){(void)id;s.logical_bytes+=e.size;if(e.disk)s.stored_payload_bytes+=e.stored;
        if(e.raw){s.raw_ram_bytes+=e.raw->mapped_size();if(e.raw.use_count()>1)s.pinned_raw_bytes+=e.raw->mapped_size();}
        if(e.warm)s.compressed_ram_bytes+=e.warm->mapped_size();if(e.disk&&!e.raw&&!e.warm)s.disk_only_logical_bytes+=e.size;}
    for(const auto& e:p_->free_extents)s.reusable_file_bytes+=e.size;
    s.loading_reserved_bytes=p_->loading;s.pressure=p_->pressure.load();s.pressure_events=p_->transitions.load();return s;
}
#ifdef NEOSWAP_STORAGE_TESTING
void Store::inject(Fault f){p_->fault.store(f);}
#endif
} // namespace neostation::storage
