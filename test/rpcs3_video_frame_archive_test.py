#!/usr/bin/env python3
"""Execute the exact VDEC producer with real FFmpeg frames and a decoded H264 fixture."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

root=Path(__file__).resolve().parents[1]
source=Path(sys.argv[1]).resolve()
compiler=shlex.split(os.environ.get('CXX','c++'))
if sdk:=os.environ.get('HOST_MACOS_SDK'):compiler+=['-isysroot',sdk]
env=dict(os.environ);env.pop('SDKROOT',None)
cflags=shlex.split(os.environ['FFMPEG_TEST_CFLAGS']) if 'FFMPEG_TEST_CFLAGS' in os.environ else shlex.split(subprocess.check_output(['pkg-config','--cflags','libavcodec','libavutil','libswscale'],text=True))
libs=shlex.split(os.environ['FFMPEG_TEST_LIBS']) if 'FFMPEG_TEST_LIBS' in os.environ else shlex.split(subprocess.check_output(['pkg-config','--libs','libavcodec','libavutil','libswscale'],text=True))
text=(source/'rpcs3/Emu/Cell/Modules/cellVdec.cpp').read_text()
start=text.index('\tvoid archive_cold_pixels_locked()')
method=text[start:text.index('\n#endif',start)]
assert method.endswith('\n\t}')
assert 'av_frame_is_writable(picture.avf.get()) == 1' in method
assert method.index('!picture.cold_pixels.offload_copy')<method.index('av_buffer_unref')
assert 'hw_frames_ctx' in method and 'nb_extended_buf' in method
assert 'frame_queue_has_room(out_queue.size(), picture_consumers, out_max)' in text
get_picture=text[text.index('error_code cellVdecGetPictureExt('):text.index('error_code cellVdecGetPicture(')]
assert get_picture.index('frame.cold_pixels.restore')<get_picture.index('conversion_lock')
assert 'vdec->out_queue.push_front(std::move(frame));' in get_picture
assert 'pixel_data, pixel_stride, out_f, w, h, 1' in get_picture
for name in ('FrameClient.h','VideoBuffer.h','SourceClient.cpp'):
    assert (source/'rpcs3/ios/NeoSwapStorage'/name).read_bytes()==(root/'native/neoswap-storage'/name).read_bytes(),name
with tempfile.TemporaryDirectory(prefix='vdec-ffmpeg-proof-') as temp:
    out=Path(temp);(out/'vdec-method.inc').write_text(method+'\n');exe=out/'test';video=out/'fixture.h264'
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=1280x720:rate=30',
                    '-frames:v','60','-c:v','libx264','-threads','1','-bf','2','-g','30','-pix_fmt','yuv420p','-f','h264',str(video)],check=True,env=env,timeout=60)
    subprocess.run([*compiler,'-std=c++20','-O1','-g','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',
                    '-I',str(out),'-I',str(source/'rpcs3'),*cflags,
                    str(root/'test/native/rpcs3_video_frame_archive_test.cpp'),str(source/'rpcs3/ios/NeoSwapStorage/SourceClient.cpp'),
                    *libs,'-o',str(exe)],check=True,env=env)
    # Compile the real producer consumer with RPCS3's exception mode too.
    subprocess.run([*compiler,'-std=c++20','-Wall','-Wextra','-Werror','-fno-exceptions',
                    '-I',str(out),'-I',str(source/'rpcs3'),*cflags,'-fsyntax-only',
                    str(root/'test/native/rpcs3_video_frame_archive_test.cpp')],check=True,env=env)
    subprocess.run([str(exe),str(video)],check=True,env=env,timeout=60)
