// SPDX-License-Identifier: MIT
#pragma once
#include "FrameClient.h"
// The Core tree places this header under ios/NeoSwapStorage/ next to the
// borrowed NeoSwap allocator client. Without it (host-side copies, isolated
// tests) frames keep their ordinary anonymous mappings.
#if __has_include("../NeoSwapClient.h")
#include "../NeoSwapClient.h"
#define NEOSWAP_VIDEO_FRAME_LOANS 1
#else
#define NEOSWAP_VIDEO_FRAME_LOANS 0
#endif
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
}
#include <algorithm>
#include <cerrno>
#include <climits>
#include <sys/mman.h>
#include <unistd.h>

namespace neostation::source_client {
// The default FFmpeg pool retains freed pixels. Opt-in software VDEC frames
// instead own anonymous mappings, released by FFmpeg's LAST reference. This
// changes no codec, threading, timestamps, guest output or hardware frames.
// When the host NeoSwap allocator admits video-frame loans (kind 4), the
// mapping is borrowed from relay pages outside the host footprint instead;
// a refusal keeps the anonymous mapping. The borrowed interval is returned
// through the same last-reference callback. Loaned bytes are counted apart.
inline constinit std::atomic<uint64_t> video_mapped_bytes{0},video_mapped_peak{0},video_unmapped_bytes{0};
inline constinit std::atomic<uint64_t> video_unmap_failures{0};
inline constinit std::atomic<uint64_t> video_loaned_bytes{0},video_loaned_peak{0},video_loan_returned_bytes{0};
inline constinit std::atomic<uint64_t> video_loan_release_failures{0};
inline constexpr uintptr_t video_loan_tag=1; // spans are page multiples; bit 0 marks a NeoSwap loan
inline void retire_video_mapping(void* opaque,uint8_t* pixels) noexcept {
    const auto tagged=reinterpret_cast<uintptr_t>(opaque);
    const auto bytes=tagged&~video_loan_tag;
    if(tagged&video_loan_tag){
#if NEOSWAP_VIDEO_FRAME_LOANS
        const int result=neostation::swap::release(pixels);
        if(result==NEOSWAP_OK){video_loaned_bytes.fetch_sub(bytes);video_loan_returned_bytes.fetch_add(bytes);return;}
        if(result!=NEOSWAP_NOT_OWNED){video_loan_release_failures.fetch_add(1);return;} // broker retains the mapping
#endif
        video_loan_release_failures.fetch_add(1); // never munmap a loan the broker did not disown
        return;
    }
    if(::munmap(pixels,bytes)==0){video_mapped_bytes.fetch_sub(bytes);video_unmapped_bytes.fetch_add(bytes);}
    else video_unmap_failures.fetch_add(1);
}
inline bool video_mapping_format(const AVCodecContext* ctx,const AVFrame* frame) noexcept {
    if(!ctx->codec || !(ctx->codec->capabilities&AV_CODEC_CAP_DR1) || ctx->hw_frames_ctx || frame->hw_frames_ctx ||
       (frame->format!=AV_PIX_FMT_YUV420P && frame->format!=AV_PIX_FMT_YUVJ420P))return false;
    const int bytes=av_image_get_buffer_size(static_cast<AVPixelFormat>(frame->format),frame->width,frame->height,1);
    return bytes>=4096 && static_cast<uint64_t>(bytes)<=frame_max_bytes;
}
inline int allocate_video_mapping(AVCodecContext* ctx,AVFrame* frame,int flags) noexcept {
    if(!video_mapping_format(ctx,frame))return avcodec_default_get_buffer2(ctx,frame,flags);
    for(auto* p:frame->data)if(p)return AVERROR(EINVAL);
    int width=frame->width,height=frame->height,alignment[AV_NUM_DATA_POINTERS]{};
    avcodec_align_dimensions2(ctx,&width,&height,alignment);
    if(width<=0 || height<=0)return AVERROR(EINVAL);
    int strides[4]{};bool aligned=false;
    for(unsigned attempt=0;attempt<32;++attempt){
        const int result=av_image_fill_linesizes(strides,static_cast<AVPixelFormat>(frame->format),width);
        if(result<0)return result;
        aligned=true;for(unsigned p=0;p<4;++p)
            if(strides[p] && (alignment[p]<=0 || strides[p]%alignment[p]))aligned=false;
        if(aligned)break;
        const auto increment=static_cast<unsigned>(width)&(~static_cast<unsigned>(width)+1);
        if(!increment || increment>static_cast<unsigned>(INT_MAX-width))return AVERROR(EINVAL);
        width+=static_cast<int>(increment);
    }
    if(!aligned)return AVERROR(EINVAL);
    ptrdiff_t pitch[4]={strides[0],strides[1],strides[2],strides[3]};size_t sizes[4]{};
    const int result=av_image_fill_plane_sizes(sizes,static_cast<AVPixelFormat>(frame->format),height,pitch);
    if(result<0)return result;
    const long page_size=::sysconf(_SC_PAGESIZE);if(page_size<=0)return AVERROR(EINVAL);
    const auto page=static_cast<size_t>(page_size);size_t offsets[4]{},span=0;
    for(unsigned p=0;p<4;++p)if(sizes[p]){
        // Page-aligned planes cover all codec SIMD alignment requirements.
        // Include overread/padding without assuming that visible bytes are allocation bytes.
        if(alignment[p]>page_size || sizes[p]>(8ULL<<20)-page-64)return AVERROR(EINVAL);
        offsets[p]=span;const auto charge=(sizes[p]+64+page-1)/page*page;
        if(charge>(8ULL<<20)-span)return AVERROR(EINVAL);
        span+=charge;
    }
    if(!span)return AVERROR(EINVAL);
    uint8_t* mapping=nullptr;bool loaned=false;
#if NEOSWAP_VIDEO_FRAME_LOANS
    // Page-aligned relay loan; the host refuses (no file, no wait) when the
    // budget does not admit video frames, and the anonymous mapping is used.
    if(auto* loan=neostation::swap::try_allocate_kind(NEOSWAP_RPCS3,NEOSWAP_VIDEO_FRAME,span,page)){
        mapping=static_cast<uint8_t*>(loan);loaned=true;
    }
#endif
    if(!mapping){
        mapping=static_cast<uint8_t*>(::mmap(nullptr,span,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0));
        if(mapping==MAP_FAILED)return AVERROR(errno);
    }
    const uintptr_t opaque=static_cast<uintptr_t>(span)|(loaned?video_loan_tag:0);
    auto* buffer=av_buffer_create(mapping,span,retire_video_mapping,reinterpret_cast<void*>(opaque),0);
    if(!buffer){
#if NEOSWAP_VIDEO_FRAME_LOANS
        if(loaned){if(neostation::swap::release(mapping)!=NEOSWAP_OK)video_loan_release_failures.fetch_add(1);}
        else
#endif
        (void)::munmap(mapping,span);
        return AVERROR(ENOMEM);
    }
    if(loaned){
        const auto live=video_loaned_bytes.fetch_add(span)+span;auto peak=video_loaned_peak.load();
        while(peak<live && !video_loaned_peak.compare_exchange_weak(peak,live)){}
    } else {
        const auto live=video_mapped_bytes.fetch_add(span)+span;auto peak=video_mapped_peak.load();
        while(peak<live && !video_mapped_peak.compare_exchange_weak(peak,live)){}
    }
    frame->buf[0]=buffer;
    for(unsigned p=0;p<4;++p){frame->linesize[p]=strides[p];frame->data[p]=sizes[p]?mapping+offsets[p]:nullptr;}
    frame->extended_data=frame->data;return 0;
}
}
