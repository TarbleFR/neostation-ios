// SPDX-License-Identifier: MIT
// Executes the exact extracted producer method with real FFmpeg buffers.
#include "ios/NeoSwapStorage/FrameClient.h"
#include "ios/NeoSwapStorage/VideoBuffer.h"
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libswscale/swscale.h>
}
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <vector>
using u8=uint8_t;using u32=uint32_t;using u64=uint64_t;using usz=size_t;
using namespace neostation::source_client;
static_assert(!frame_requires_restore_slot(false, false));
static_assert(!frame_requires_restore_slot(false, true));
static_assert(!frame_requires_restore_slot(true, false));
static_assert(frame_requires_restore_slot(true, true));
#define CHECK(v) do {if(!(v)){std::cerr<<"FAIL "<<__LINE__<<": " #v "\n";std::abort();}}while(0)
u64 clock_us=1'000'000,freed_bytes=0,freed_buffers=0;
#ifdef NEOSWAP_CLOCK_DECLARATION_PROBE
#ifdef NEOSWAP_CLOCK_HEADER_INCLUDED
#include "vdec-clock-declaration.inc"
#endif
#else
u64 get_system_time(){return clock_us;}
#endif
struct logger {template<class... T>void notice(const char*,T...) {}} cellVdec;
struct frame_dtor{void operator()(AVFrame* p)const{av_frame_free(&p);}};
struct vdec_frame {
    std::unique_ptr<AVFrame,frame_dtor> avf;
    ColdFrame cold_pixels;u64 queued_at_us=0;
    AVFrame* operator->()const{return avf.get();}
};
struct vdec_context {
    std::deque<vdec_frame> out_queue;
    u64 next_pixel_archive_us=0,pixel_frames_archived=0,pixel_payload_archived=0;
    bool pixel_mapping_allocator=true; // manual test frames have a known non-pooling owner
    #include "vdec-method.inc"
};
std::map<u64,std::string> records;u64 next_id=0,refusal_at=0,admissions=0;
u64 session(){return 77;}
int admit(u64 e,u32 d,const char* p,u64 n,u64* id){
    *id=0;CHECK(e==77&&d==3&&n<=NEOSWAP_SOURCE_MAX_BYTES);
    if(++admissions==refusal_at)return NS_SOURCE_BUSY;
    *id=++next_id;records[*id]=std::string(p,n);return NS_SOURCE_OK;
}
int read(u64 e,u64 id,char* p,u64 n,int* error){
    *error=0;CHECK(e==77);auto it=records.find(id);
    if(it==records.end())return NS_SOURCE_MISSING;
    CHECK(it->second.size()==n);std::copy(it->second.begin(),it->second.end(),p);return NS_SOURCE_OK;
}
void discard(u64,u64 id){CHECK(records.erase(id)==1);}
void released(u64,u64){CHECK(false);}
const NeoSwapSourceAPI api{sizeof(api),NEOSWAP_SOURCE_ABI,session,admit,read,discard,released};
void free_pixels(void* opaque,u8* data){freed_bytes+=reinterpret_cast<uintptr_t>(opaque);++freed_buffers;av_free(data);}
vdec_frame make_frame(int w,int h,bool negative=false){
    vdec_frame f;f.avf.reset(av_frame_alloc());CHECK(f.avf);
    f->width=w;f->height=h;f->format=AV_PIX_FMT_YUV420P;f->pts=12345;f->pict_type=AV_PICTURE_TYPE_B;
    f->colorspace=AVCOL_SPC_BT709;f->color_range=AVCOL_RANGE_MPEG;f->crop_left=2;
    const int bytes=av_image_get_buffer_size(AV_PIX_FMT_YUV420P,w,h,128);CHECK(bytes>0);
    auto* pixels=static_cast<u8*>(av_malloc(bytes+64));CHECK(pixels);
    f->buf[0]=av_buffer_create(pixels,bytes+64,free_pixels,reinterpret_cast<void*>(static_cast<uintptr_t>(bytes+64)),0);
    CHECK(f->buf[0]&&av_image_fill_arrays(f->data,f->linesize,pixels,AV_PIX_FMT_YUV420P,w,h,128)==bytes);
    for(int p=0;p<3;++p){const int rows=p?(h+1)/2:h,cols=p?(w+1)/2:w;
        for(int y=0;y<rows;++y)for(int x=0;x<cols;++x)f->data[p][y*f->linesize[p]+x]=static_cast<u8>((x*3+y*7+p*33)%256);
        if(negative){f->data[p]+=(rows-1)*f->linesize[p];f->linesize[p]=-f->linesize[p];}
    }
    CHECK(av_frame_is_writable(f.avf.get())==1);return f;
}
std::string packed(const AVFrame* f){
    const auto format=static_cast<AVPixelFormat>(f->format);
    const int bytes=av_image_get_buffer_size(format,f->width,f->height,1);CHECK(bytes>0);
    std::string out(bytes,'\0');CHECK(av_image_copy_to_buffer(reinterpret_cast<u8*>(out.data()),bytes,f->data,f->linesize,format,f->width,f->height,1)==bytes);return out;
}
std::string convert(const u8* const* data,const int* stride,int w,int h,AVPixelFormat input,AVPixelFormat output){
    SwsContext* sws=sws_getContext(w,h,input,w,h,output,SWS_POINT,nullptr,nullptr,nullptr);CHECK(sws);
    const int bytes=av_image_get_buffer_size(output,w,h,1);CHECK(bytes>0);
    std::string out(bytes,'\0');u8* planes[4]{};int lines[4]{};
    CHECK(av_image_fill_arrays(planes,lines,reinterpret_cast<const u8*>(out.data()),output,w,h,1)==bytes);
    CHECK(sws_scale(sws,data,stride,0,h,planes,lines)==h);sws_freeContext(sws);return out;
}
void queue_cycle(){
    vdec_context c;std::vector<std::string> expected,expected_rgb;
    for(unsigned i=0;i<60;++i){auto f=make_frame(641,361,i%2);expected.push_back(packed(f.avf.get()));
        expected_rgb.push_back(convert(f->data,f->linesize,641,361,AV_PIX_FMT_YUV420P,AV_PIX_FMT_RGBA));c.out_queue.push_back(std::move(f));}
    std::unique_ptr<AVFrame,frame_dtor> shared(av_frame_clone(c.out_queue.front().avf.get()));CHECK(shared);
    const auto before=freed_buffers;
    for(unsigned i=0;i<60;++i){c.archive_cold_pixels_locked();clock_us+=1'000'000;}
    CHECK(!c.out_queue[0].cold_pixels.archived()&&c.out_queue[0]->buf[0]); // decoder reference retained
    CHECK(c.pixel_frames_archived==51&&freed_buffers==before+51);
    for(unsigned i=52;i<60;++i)CHECK(c.out_queue[i]->buf[0]&&!c.out_queue[i].cold_pixels.archived());
    for(unsigned i=1;i<52;++i){auto& f=c.out_queue[i];CHECK(!f->buf[0]&&!f->data[0]);
        CHECK(f->width==641&&f->height==361&&f->pts==12345&&f->pict_type==AV_PICTURE_TYPE_B&&f->crop_left==2);
        CHECK(f->colorspace==AVCOL_SPC_BT709&&f->color_range==AVCOL_RANGE_MPEG);
        std::string restored;int error=0;CHECK(f.cold_pixels.restore(restored,error)==NS_SOURCE_OK&&restored==expected[i]);
        u8* planes[4]{};int strides[4]{};CHECK(av_image_fill_arrays(planes,strides,reinterpret_cast<const u8*>(restored.data()),AV_PIX_FMT_YUV420P,641,361,1)==static_cast<int>(restored.size()));
        // Both packed stride layouts and RGB conversion preserve exact pixel output.
        const u8* input[4]={planes[0],planes[1],planes[2],nullptr};
        CHECK(convert(input,strides,641,361,AV_PIX_FMT_YUV420P,AV_PIX_FMT_RGBA)==expected_rgb[i]);
    }
    shared.reset();c.archive_cold_pixels_locked();CHECK(c.out_queue[0].cold_pixels.archived());
}
void refusal(){
    vdec_context c;for(unsigned i=0;i<24;++i)c.out_queue.push_back(make_frame(1920,1080));
    auto& f=c.out_queue.front();auto* buffer=f->buf[0];const auto original=packed(f.avf.get());const auto before=freed_buffers;
    refusal_at=admissions+2;c.archive_cold_pixels_locked();
    CHECK(f->buf[0]==buffer&&!f.cold_pixels.archived()&&packed(f.avf.get())==original&&freed_buffers==before);
    refusal_at=0;clock_us+=1'000'000;c.archive_cold_pixels_locked();CHECK(f.cold_pixels.archived()&&freed_buffers==before+1);
}
std::vector<std::string> decode(const char* path,bool mapped,const std::vector<std::string>& baseline={},int threads=1){
    std::ifstream input(path,std::ios::binary);std::vector<u8> data((std::istreambuf_iterator<char>(input)),{});CHECK(!data.empty());
    data.resize(data.size()+AV_INPUT_BUFFER_PADDING_SIZE,0);
    auto* parser=av_parser_init(AV_CODEC_ID_H264);CHECK(parser);
    auto* decoder=avcodec_find_decoder(AV_CODEC_ID_H264);CHECK(decoder);
    auto* ctx=avcodec_alloc_context3(decoder);CHECK(ctx);ctx->thread_count=threads;
    if(mapped)ctx->get_buffer2=allocate_video_mapping;
    CHECK(avcodec_open2(ctx,decoder,nullptr)==0);
    AVPacket* packet=av_packet_alloc();CHECK(packet);vdec_context c;c.pixel_mapping_allocator=mapped;
    std::vector<std::string> expected;unsigned eligible=0;
    auto drain=[&]{for(;;){vdec_frame f;f.avf.reset(av_frame_alloc());CHECK(f.avf);
        const int result=avcodec_receive_frame(ctx,f.avf.get());if(result==AVERROR(EAGAIN)||result==AVERROR_EOF)break;CHECK(result==0);
        if(av_frame_is_writable(f.avf.get())==1)++eligible;
        expected.push_back(packed(f.avf.get()));c.out_queue.push_back(std::move(f));}};
    u8* cursor=data.data();int remaining=static_cast<int>(data.size()-AV_INPUT_BUFFER_PADDING_SIZE);
    while(remaining){const int used=av_parser_parse2(parser,ctx,&packet->data,&packet->size,cursor,remaining,AV_NOPTS_VALUE,AV_NOPTS_VALUE,0);CHECK(used>=0);
        cursor+=used;remaining-=used;if(packet->size){CHECK(avcodec_send_packet(ctx,packet)==0);drain();}else CHECK(used>0);}
    CHECK(av_parser_parse2(parser,ctx,&packet->data,&packet->size,nullptr,0,AV_NOPTS_VALUE,AV_NOPTS_VALUE,0)>=0);
    if(packet->size){CHECK(avcodec_send_packet(ctx,packet)==0);drain();}
    CHECK(avcodec_send_packet(ctx,nullptr)==0);drain();
    CHECK(c.out_queue.size()==60);unsigned cold_exclusive=0;
    for(auto& f:c.out_queue)if(av_frame_is_writable(f.avf.get())==1)++cold_exclusive;
    CHECK(cold_exclusive>0);const auto before=c.pixel_frames_archived;
    if(mapped)CHECK(expected==baseline);
    const auto mapped_before=video_mapped_bytes.load(),unmapped_before=video_unmapped_bytes.load();
    for(unsigned i=0;i<60;++i){clock_us+=1'000'000;c.archive_cold_pixels_locked();}
    if(mapped)CHECK(c.pixel_frames_archived>before);
    else CHECK(c.pixel_frames_archived==0); // pooled defaults must NOT inflate archived/released counters
    if(mapped){CHECK(mapped_before>0&&video_mapped_bytes.load()<mapped_before);
        CHECK(video_unmapped_bytes.load()>unmapped_before&&video_unmap_failures.load()==0);
        std::cout<<"ownedMappingsBefore="<<mapped_before<<" ownedMappingsAfter="<<video_mapped_bytes.load()<<" unmappedDuringArchive="<<video_unmapped_bytes.load()-unmapped_before<<"\n";}
    unsigned index=0;for(auto& f:c.out_queue){if(f.cold_pixels.archived()){
        std::string restored;int error=0;CHECK(f.cold_pixels.restore(restored,error)==NS_SOURCE_OK&&restored==expected[index]);}++index;}
    std::cout<<"decodedFrames="<<c.out_queue.size()<<" immediatelyExclusive="<<eligible<<" queueExclusive="<<cold_exclusive<<" archivedDecodedFrames="<<c.pixel_frames_archived<<"\n";
    av_packet_free(&packet);av_parser_close(parser);avcodec_free_context(&ctx);
    return expected;
}
int main(int argc,char** argv){CHECK(argc==2&&install(&api)==NS_SOURCE_OK);queue_cycle();CHECK(records.empty());refusal();CHECK(records.empty());
    const auto baseline=decode(argv[1],false);CHECK(records.empty());decode(argv[1],true,baseline);
    decode(argv[1],true,baseline,4); // FFmpeg frame workers use the same thread-safe ownership boundary
    CHECK(records.empty()&&video_mapped_bytes.load()==0&&video_unmap_failures.load()==0);
    std::cout<<"PASS exact VDEC producer, actual munmap, pooled-versus-owned H264 identity, reference exclusion, negative strides, preserved metadata and transactional refusals; no RPCS3/iPhone gameplay claim\n";
}
