// SPDX-License-Identifier: MIT
#pragma once
#include "FrameClient.h"
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
inline constinit std::atomic<uint64_t> video_mapped_bytes{0},video_mapped_peak{0},video_unmapped_bytes{0};
inline constinit std::atomic<uint64_t> video_unmap_failures{0};
inline void retire_video_mapping(void* opaque,uint8_t* pixels) noexcept {
    const auto bytes=reinterpret_cast<uintptr_t>(opaque);
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
    auto* mapping=static_cast<uint8_t*>(::mmap(nullptr,span,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0));
    if(mapping==MAP_FAILED)return AVERROR(errno);
    auto* buffer=av_buffer_create(mapping,span,retire_video_mapping,reinterpret_cast<void*>(span),0);
    if(!buffer){(void)::munmap(mapping,span);return AVERROR(ENOMEM);}
    const auto live=video_mapped_bytes.fetch_add(span)+span;auto peak=video_mapped_peak.load();
    while(peak<live && !video_mapped_peak.compare_exchange_weak(peak,live)){}
    frame->buf[0]=buffer;
    for(unsigned p=0;p<4;++p){frame->linesize[p]=strides[p];frame->data[p]=sizes[p]?mapping+offsets[p]:nullptr;}
    frame->extended_data=frame->data;return 0;
}
}
