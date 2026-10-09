#ifndef GLES_SILENCE_DEPRECATION
#define GLES_SILENCE_DEPRECATION 1
#endif
#ifndef COREVIDEO_SILENCE_GL_DEPRECATION
#define COREVIDEO_SILENCE_GL_DEPRECATION 1
#endif

#import "LibretroGLRenderer.h"

#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

#include <dlfcn.h>

#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif

static NSError *GLError(NSString *detail) {
  return [NSError errorWithDomain:@"org.neostation.libretro.gl" code:1 userInfo:@{NSLocalizedDescriptionKey : detail}];
}

@interface LibretroGLRenderer () {
 @public
  GLuint _framebuffer;
}
@end

/// libretro's framebuffer callbacks carry no context pointer.
static __unsafe_unretained LibretroGLRenderer *gCurrentGLRenderer = nil;

static uintptr_t LibretroGLCurrentFramebuffer(void) {
  LibretroGLRenderer *renderer = gCurrentGLRenderer;
  return renderer != nil ? (uintptr_t)renderer->_framebuffer : 0;
}

static retro_proc_address_t LibretroGLProcAddress(const char *symbol) {
  static void *library = NULL;
  if (library == NULL) library = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY);
  if (symbol == NULL) return NULL;
  return (retro_proc_address_t)dlsym(library != NULL ? library : RTLD_DEFAULT, symbol);
}

@implementation LibretroGLRenderer {
  EAGLRenderingAPI _api;
  BOOL _depth;
  BOOL _stencil;
  id<MTLDevice> _device;
  EAGLContext *_context;
  CVOpenGLESTextureCacheRef _glCache;
  CVMetalTextureCacheRef _metalCache;
  CVPixelBufferRef _pixelBuffer;
  CVOpenGLESTextureRef _glTexture;
  CVMetalTextureRef _metalTexture;
  id<MTLTexture> _texture;
  GLuint _depthStencil;
  unsigned _width;
  unsigned _height;
}

+ (nullable instancetype)rendererForCallback:(struct retro_hw_render_callback *)callback device:(id<MTLDevice>)device {
  EAGLRenderingAPI api;
  switch (callback->context_type) {
    case RETRO_HW_CONTEXT_OPENGLES2:
      api = kEAGLRenderingAPIOpenGLES2;
      break;
    case RETRO_HW_CONTEXT_OPENGLES3:
      api = kEAGLRenderingAPIOpenGLES3;
      break;
    case RETRO_HW_CONTEXT_OPENGLES_VERSION:
      if (callback->version_major > 3 || (callback->version_major == 3 && callback->version_minor > 0)) return nil;
      api = callback->version_major >= 3 ? kEAGLRenderingAPIOpenGLES3 : kEAGLRenderingAPIOpenGLES2;
      break;
    default:
      return nil;
  }
  LibretroGLRenderer *renderer = [[self alloc] init];
  renderer->_api = api;
  renderer->_depth = callback->depth;
  renderer->_stencil = callback->stencil;
  renderer->_bottomLeftOrigin = callback->bottom_left_origin;
  renderer->_device = device;
  callback->get_current_framebuffer = LibretroGLCurrentFramebuffer;
  callback->get_proc_address = LibretroGLProcAddress;
  gCurrentGLRenderer = renderer;
  return renderer;
}

- (void)dealloc {
  [self teardown];
}

- (void)makeCurrent {
  if (_context != nil && [EAGLContext currentContext] != _context) [EAGLContext setCurrentContext:_context];
}

- (void)releaseSurface {
  if (_glTexture != NULL) {
    CFRelease(_glTexture);
    _glTexture = NULL;
  }
  if (_metalTexture != NULL) {
    CFRelease(_metalTexture);
    _metalTexture = NULL;
  }
  _texture = nil;
  if (_pixelBuffer != NULL) {
    CVPixelBufferRelease(_pixelBuffer);
    _pixelBuffer = NULL;
  }
  if (_depthStencil != 0) {
    glDeleteRenderbuffers(1, &_depthStencil);
    _depthStencil = 0;
  }
}

- (BOOL)prepareWithWidth:(unsigned)width height:(unsigned)height error:(NSError **)error {
  width = MAX(width, 1u);
  height = MAX(height, 1u);
  if (_context == nil) {
    _context = [[EAGLContext alloc] initWithAPI:_api];
    if (_context == nil) {
      if (error) *error = GLError(@"EAGLContext creation failed");
      return NO;
    }
    [EAGLContext setCurrentContext:_context];
    if (CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_glCache) != kCVReturnSuccess ||
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_metalCache) != kCVReturnSuccess) {
      if (error) *error = GLError(@"texture cache creation failed");
      return NO;
    }
    glGenFramebuffers(1, &_framebuffer);
  }
  [self makeCurrent];
  if (_texture != nil && width <= _width && height <= _height) return YES;
  [self releaseSurface];

  NSDictionary *attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferOpenGLESCompatibilityKey : @YES,
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                          (__bridge CFDictionaryRef)attributes, &_pixelBuffer) != kCVReturnSuccess) {
    if (error) *error = GLError(@"pixel buffer creation failed");
    return NO;
  }
  if (CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _glCache, _pixelBuffer, NULL, GL_TEXTURE_2D,
                                                   GL_RGBA, (GLsizei)width, (GLsizei)height, GL_BGRA_EXT,
                                                   GL_UNSIGNED_BYTE, 0, &_glTexture) != kCVReturnSuccess) {
    if (error) *error = GLError(@"GL texture creation failed");
    return NO;
  }
  GLuint textureName = CVOpenGLESTextureGetName(_glTexture);
  glBindTexture(GL_TEXTURE_2D, textureName);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);

  glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textureName, 0);
  if (_depth || _stencil) {
    glGenRenderbuffers(1, &_depthStencil);
    glBindRenderbuffer(GL_RENDERBUFFER, _depthStencil);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)width, (GLsizei)height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthStencil);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _depthStencil);
    glBindRenderbuffer(GL_RENDERBUFFER, 0);
  }
  GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    if (error) *error = GLError([NSString stringWithFormat:@"framebuffer incomplete 0x%x", status]);
    return NO;
  }
  glViewport(0, 0, (GLsizei)width, (GLsizei)height);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

  if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _metalCache, _pixelBuffer, NULL,
                                                MTLPixelFormatBGRA8Unorm, width, height, 0,
                                                &_metalTexture) != kCVReturnSuccess) {
    if (error) *error = GLError(@"Metal texture creation failed");
    return NO;
  }
  _texture = CVMetalTextureGetTexture(_metalTexture);
  _width = width;
  _height = height;
  return _texture != nil;
}

- (id<MTLTexture>)finishFrame {
  [self makeCurrent];
  glFinish();
  return _texture;
}

- (void)teardown {
  if (_context == nil) return;
  [EAGLContext setCurrentContext:_context];
  [self releaseSurface];
  if (_framebuffer != 0) {
    glDeleteFramebuffers(1, &_framebuffer);
    _framebuffer = 0;
  }
  if (_glCache != NULL) {
    CVOpenGLESTextureCacheFlush(_glCache, 0);
    CFRelease(_glCache);
    _glCache = NULL;
  }
  if (_metalCache != NULL) {
    CVMetalTextureCacheFlush(_metalCache, 0);
    CFRelease(_metalCache);
    _metalCache = NULL;
  }
  [EAGLContext setCurrentContext:nil];
  _context = nil;
  if (gCurrentGLRenderer == self) gCurrentGLRenderer = nil;
}

@end
