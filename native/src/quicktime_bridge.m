#include "quicktime_bridge.h"
#include "carbon_bridge.h"
#include "compat_runtime.h"
#include "resource_bridge.h"
#include "objc_bridge.h"
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#include <limits.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
/* The removed QuickTime movie API is backed by AVFoundation. Guest pointers
 * are never used as host Movie, GWorld, or TimeBase objects. */
@interface LP32Movie : NSObject {
@public
  AVPlayer *player;
  AVPlayerItemVideoOutput *output;
  AVAsset *asset;
  NSMutableDictionary *sample_times;
  Rect bounds;
  uint32_t world, callback, callback_data;
  BOOL started;
}
@end
@implementation LP32Movie
- (void)dealloc {
  [player pause];
  [player release];
  [output release];
  [asset release];
  [sample_times release];
  [super dealloc];
}
@end
@interface LP32GraphicsImporter : NSObject {
@public
  CGImageSourceRef source;
  CGImageRef image;
  Rect bounds;
  uint32_t world;
  int32_t matrix[9];
}
@end
@implementation LP32GraphicsImporter
- (void)dealloc {
  if (image)
    CGImageRelease(image);
  if (source)
    CFRelease(source);
  [super dealloc];
}
@end
static NSMutableDictionary *graphics_importers;
static uint32_t next_importer = 0x75200000;
static _Thread_local uint32_t current_world;
static BOOL select_image(LP32GraphicsImporter *importer, size_t index) {
  CGImageRef image =
      CGImageSourceCreateImageAtIndex(importer->source, index, NULL);
  if (!image)
    return NO;
  if (importer->image)
    CGImageRelease(importer->image);
  importer->image = image;
  importer->bounds = (Rect){0, 0, (int16_t)CGImageGetHeight(image),
                            (int16_t)CGImageGetWidth(image)};
  return YES;
}
struct world32 {
  uint32_t token, pixels, stride, format, pixmap, map_data, pixel_state;
  Rect bounds, clip;
  uint16_t foreground[3], background[3];
  struct world32 *next;
};
static struct world32 *worlds;
static uint32_t next_world = 0x75000000;
static NSMutableDictionary *movies, *movie_files;
static uint32_t next_movie = 0x75100000;
struct movie_callback {
  uint32_t token, movie, function, refcon, flags;
  int32_t type, value, scale;
  BOOL armed, disposed;
  struct movie_callback *next;
};
static struct movie_callback *movie_callbacks;
static uint32_t next_movie_callback = 0x75700000;
static struct movie_callback *movie_callback(uint32_t token) {
  for (struct movie_callback *p = movie_callbacks; p; p = p->next)
    if (p->token == token && !p->disposed) return p;
  return NULL;
}
static uint16_t next_file = 1;
static NSMutableDictionary *pointer_handlers;
static uint32_t next_pointer_handler = 0x75410000;
static NSData *copy_guest_handle(uint32_t handle) {
  if (!handle) return nil;
  uint32_t args[] = {handle}; uint64_t size = 0;
  if (!resource_bridge32_dispatch("_GetHandleSize", args, &size) || size > 1048576) return nil;
  uint32_t data = *(uint32_t *)(uintptr_t)handle;
  return data ? [NSData dataWithBytes:(void *)(uintptr_t)data length:size] : nil;
}
static uint32_t make_guest_handle(NSData *data) {
  uint32_t args[] = {(uint32_t)[data length]}; uint64_t handle = 0;
  if (!data || !resource_bridge32_dispatch("_NewHandle", args, &handle) || !handle) return 0;
  memcpy((void *)(uintptr_t)*(uint32_t *)(uintptr_t)handle, [data bytes], [data length]);
  return (uint32_t)handle;
}

static LP32Movie *movie(uint32_t token) {
  return [movies objectForKey:@(token)];
}
static struct world32 *world(uint32_t token) {
  for (struct world32 *p = worlds; p; p = p->next)
    if (p->token == token)
      return p;
  return NULL;
}
static NSArray *movie_sample_times(LP32Movie *m, uint32_t type) {
  if (!m->sample_times) m->sample_times = [[NSMutableDictionary alloc] init];
  NSArray *cached = m->sample_times[@(type)];
  if (cached) return cached;
  NSString *mediaType = type == 0x76696465 ? AVMediaTypeVideo :
      type == 0x736f756e ? AVMediaTypeAudio : nil;
  NSMutableArray *samples = [NSMutableArray array];
  for (AVAssetTrack *track in mediaType ? [m->asset tracksWithMediaType:mediaType] : @[]) {
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:m->asset error:NULL];
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    if (![reader canAddOutput:output]) continue;
    [reader addOutput:output];
    if (![reader startReading]) continue;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
      CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
      CMTime duration = CMSampleBufferGetDuration(sample);
      if (CMTIME_IS_NUMERIC(pts)) {
        int64_t time = CMTimeConvertScale(pts, 600, kCMTimeRoundingMethod_Default).value;
        int64_t length = CMTIME_IS_NUMERIC(duration) ?
            CMTimeConvertScale(duration, 600, kCMTimeRoundingMethod_Default).value : 0;
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
        BOOL sync = YES;
        if (attachments && CFArrayGetCount(attachments))
          sync = CFDictionaryGetValue(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync) != kCFBooleanTrue;
        [samples addObject:@[@(time), @(MAX(length, 1)), @(sync)]];
      }
      CFRelease(sample);
    }
  }
  [samples sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
  m->sample_times[@(type)] = samples;
  fprintf(stderr, "compat32: indexed QuickTime media type=%08x samples=%lu\n", type, (unsigned long)samples.count);
  return samples;
}
static uint32_t new_movie(NSString *path) {
  LP32Movie *m = [[LP32Movie alloc] init];
  if (path) {
    m->asset = [[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                    options:nil] retain];
    if (![m->asset isPlayable]) {
      [m release];
      return 0;
    }
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:m->asset];
    m->output =
        [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
          (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
        }];
    [item addOutput:m->output];
    m->player = [[AVPlayer alloc] initWithPlayerItem:item];
    m->player.muted = getenv("LP32_MUTE_AUDIO") != NULL;
    AVAssetTrack *track =
        [[m->asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    CGSize size = track.naturalSize;
    m->bounds = (Rect){0, 0, (int16_t)size.height, (int16_t)size.width};
  }
  if (!movies)
    movies = [[NSMutableDictionary alloc] init];
  uint32_t token = next_movie;
  next_movie += 16;
  [movies setObject:m forKey:@(token)];
  [m release];
  return token;
}
static void movie_task(uint32_t token) {
  LP32Movie *m = movie(token);
  if (m && m->started) {
    double now = CMTimeGetSeconds(m->player.currentTime);
    double end = CMTimeGetSeconds(m->asset.duration);
    BOOL failed = m->player.status == AVPlayerStatusFailed;
    for (struct movie_callback *p = movie_callbacks; p; p = p->next) {
      if (p->disposed || !p->armed || p->movie != token) continue;
      BOOL due = p->type == 4 ?
          (((p->flags & 2) && (failed || (isfinite(end) && now >= end))) ||
           ((p->flags & 1) && isfinite(now) && now <= 0)) :
          (p->type == 1 && p->scale > 0 && (p->flags & 1) &&
           isfinite(now) && now >= (double)p->value / p->scale);
      if (due) {
        uint32_t args[] = {p->token, p->refcon};
        uint32_t function = p->function;
        p->armed = NO;
        fprintf(stderr, "compat32: QuickTime callback fired movie=%08x type=%d failed=%d\n", token, p->type, failed);
        compat_runtime32_call(function, args, 2);
      }
    }
    /* An end callback may have disposed or replaced the movie. */
    m = movie(token);
  }
  struct world32 *w = m ? world(m->world) : NULL;
  if (!m || !w || !m->output)
    return;
  CMTime time = m->player.currentTime;
  if (![m->output hasNewPixelBufferForItemTime:time])
    return;
  CVPixelBufferRef frame = [m->output copyPixelBufferForItemTime:time
                                              itemTimeForDisplay:NULL];
  if (!frame)
    return;
  CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
  const unsigned char *source = CVPixelBufferGetBaseAddress(frame);
  size_t width = CVPixelBufferGetWidth(frame),
         height = CVPixelBufferGetHeight(frame),
         stride = CVPixelBufferGetBytesPerRow(frame);
  size_t dw = (uint16_t)(w->bounds.right - w->bounds.left),
         dh = (uint16_t)(w->bounds.bottom - w->bounds.top);
  BOOL yuv = w->format == kCVPixelFormatType_422YpCbCr8;
  if (width && height && dw && dh && w->stride >= dw * (yuv ? 2 : 4) &&
      (!yuv || (CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_422YpCbCr8 && !(dw & 1)))) {
    for (size_t y = 0; y < dh; ++y) {
      unsigned char *dest = (void *)(uintptr_t)(w->pixels + y * w->stride);
      const unsigned char *row = source + (y * height / dh) * stride;
      if (yuv) {
        for (size_t x = 0; x < dw; x += 2) {
          size_t sx = (x * width / dw) & ~(size_t)1;
          memcpy(dest + x * 2, row + sx * 2, 4);
        }
        continue;
      }
      for (size_t x = 0; x < dw; ++x) {
        const unsigned char *p = row + (x * width / dw) * 4;
        if (w->format == k32BGRAPixelFormat)
          memcpy(dest + x * 4, p, 4);
        else if (w->format == k32RGBAPixelFormat) {
          dest[x * 4] = p[2];
          dest[x * 4 + 1] = p[1];
          dest[x * 4 + 2] = p[0];
          dest[x * 4 + 3] = p[3];
        } else {
          dest[x * 4] = p[3];
          dest[x * 4 + 1] = p[2];
          dest[x * 4 + 2] = p[1];
          dest[x * 4 + 3] = p[0];
        }
      }
    }
    if (m->callback) {
      uint32_t a[] = {token, m->callback_data};
      compat_runtime32_call(m->callback, a, 2);
    }
  }
  CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(frame);
}
/* Core Media uses fixed-width time structures on both ABIs, but pointers
 * and size_t outputs still need conversion. Borrowed payloads follow their
 * sample/format owner, including pixel data accessed between lock/unlock. */
static int core_media_dispatch(const char *name,const uint32_t *a,uint64_t *out) {
#define M(s) (!strcmp(name,s))
#define G(i) ((void *)(uintptr_t)a[i])
#define O(i) objc_bridge32_host_object(a[i])
    if(strncmp(name,"_CM",3)&&strncmp(name,"_CV",3))return 0;
    *out=0;
    if(M("_CMAudioFormatDescriptionGetStreamBasicDescription")) {
        void *o=O(0);const AudioStreamBasicDescription *p=CMAudioFormatDescriptionGetStreamBasicDescription(o);
        *out=objc_bridge32_borrowed_bytes(o,p,p?sizeof(*p):0,0);
    } else if(M("_CMAudioFormatDescriptionGetMagicCookie")) {
        void *o=O(0);size_t size=0;const void *p=CMAudioFormatDescriptionGetMagicCookie(o,&size);
        if(a[1])*(uint32_t *)G(1)=(uint32_t)size;
        *out=objc_bridge32_borrowed_bytes(o,p,size,1);
    } else if(M("_CMSampleBufferGetAudioStreamPacketDescriptionsPtr")) {
        void *o=O(0);size_t size=0;const AudioStreamPacketDescription *p=NULL;
        *out=(uint32_t)CMSampleBufferGetAudioStreamPacketDescriptionsPtr(o,&p,&size);
        if(a[1])*(uint32_t *)G(1)=objc_bridge32_borrowed_bytes(o,p,size,2);
        if(a[2])*(uint32_t *)G(2)=(uint32_t)size;
    } else if(M("_CMSampleBufferGetDataBuffer")) {
        void *o=O(0);*out=objc_bridge32_borrowed_object(o,CMSampleBufferGetDataBuffer(o),0);
    } else if(M("_CMSampleBufferGetImageBuffer")) {
        void *o=O(0);*out=objc_bridge32_borrowed_object(o,CMSampleBufferGetImageBuffer(o),1);
    } else if(M("_CMSampleBufferGetNumSamples"))*out=(uint32_t)CMSampleBufferGetNumSamples(O(0));
    else if(M("_CMBlockBufferGetDataLength"))*out=(uint32_t)CMBlockBufferGetDataLength(O(0));
    else if(M("_CMBlockBufferCopyDataBytes"))*out=(uint32_t)CMBlockBufferCopyDataBytes(O(0),a[1],a[2],G(3));
    else if(M("_CMSampleBufferGetPresentationTimeStamp")) {
        CMTime t=CMSampleBufferGetPresentationTimeStamp(O(1));memcpy(G(0),&t,sizeof(t));*out=a[0];
    } else if(M("_CMTimeMakeWithSeconds")) {
        double seconds;memcpy(&seconds,a+1,8);CMTime t=CMTimeMakeWithSeconds(seconds,(int32_t)a[3]);
        memcpy(G(0),&t,sizeof(t));*out=a[0];
    } else if(M("_CMTimeRangeMake")) {
        CMTime start,duration;memcpy(&start,a+1,24);memcpy(&duration,a+7,24);
        CMTimeRange range=CMTimeRangeMake(start,duration);memcpy(G(0),&range,sizeof(range));*out=a[0];
    } else if(M("_CMTimeGetSeconds")) {
        CMTime t;memcpy(&t,a,24);*out=compat_runtime32_return_double(CMTimeGetSeconds(t));
    } else if(M("_CVPixelBufferGetTypeID"))*out=(uint32_t)CVPixelBufferGetTypeID();
    else if(M("_CVPixelBufferGetBytesPerRow"))*out=(uint32_t)CVPixelBufferGetBytesPerRow(O(0));
    else if(M("_CVPixelBufferLockBaseAddress"))*out=(uint32_t)CVPixelBufferLockBaseAddress(O(0),a[1]);
    else if(M("_CVPixelBufferGetBaseAddress")) {
        CVPixelBufferRef b=O(0);size_t size=CVPixelBufferGetBytesPerRow(b)*CVPixelBufferGetHeight(b);
        if(CVPixelBufferIsPlanar(b))return 0;
        *out=objc_bridge32_borrowed_bytes(b,CVPixelBufferGetBaseAddress(b),size,3);
    } else if(M("_CVPixelBufferUnlockBaseAddress")) {
        CVPixelBufferRef b=O(0);
        if(!(a[1]&kCVPixelBufferLock_ReadOnly) && !CVPixelBufferIsPlanar(b))
            objc_bridge32_commit_borrowed_bytes(b,CVPixelBufferGetBaseAddress(b),
                CVPixelBufferGetBytesPerRow(b)*CVPixelBufferGetHeight(b),3);
        *out=(uint32_t)CVPixelBufferUnlockBaseAddress(O(0),a[1]);
        if(!*out)objc_bridge32_release_borrowed_bytes(b,3);
    } else if(M("_CVImageBufferGetColorSpace")) {
        void *o=O(0);*out=objc_bridge32_borrowed_object(o,CVImageBufferGetColorSpace(o),2);
    } else return 0;
    return 1;
#undef M
#undef G
#undef O
}

int quicktime_bridge32_dispatch(const char *name, const uint32_t *a,
                                uint64_t *out) {
  if(core_media_dispatch(name,a,out))return 1;
#define IS(s) (!strcmp(name, s))
#define P(i) ((void *)(uintptr_t)a[i])
  if (name[0] != '_' || !strchr("CEGMNODQISLURPFB", name[1]))
    return 0;
  @autoreleasepool {
    if (IS("_NewCallBack")) {
      int type = a[1] & 0x7fff;
      if (!movie(a[0]) || (type != 1 && type != 4)) { *out = 0; return 1; }
      struct movie_callback *p = calloc(1, sizeof(*p));
      if (!p) { *out = 0; return 1; }
      p->token = next_movie_callback; next_movie_callback += 16;
      p->movie = a[0]; p->type = type;
      p->next = movie_callbacks; movie_callbacks = p;
      *out = p->token; return 1;
    }
    if (IS("_CallMeWhen") || IS("_DisposeCallBack") || IS("_CancelCallBack")) {
      struct movie_callback *p = movie_callback(a[0]);
      if (!p) { *out = (uint32_t)-50; return 1; }
      if (IS("_CallMeWhen")) {
        p->function = a[1]; p->refcon = a[2]; p->flags = a[3];
        p->value = a[4]; p->scale = a[5]; p->armed = a[1] != 0;
        fprintf(stderr, "compat32: QuickTime callback armed movie=%08x type=%d flags=%u\n", p->movie, p->type, p->flags);
      } else {
        p->armed = NO;
        if (IS("_DisposeCallBack")) p->disposed = YES;
      }
      *out = 0; return 1;
    }
    struct world32 *current = world(current_world);
    if (current && IS("_ClipRect")) {
      current->clip = *(Rect *)P(0);
      *out = 0;
      return 1;
    }
    if (current && IS("_SetClip")) {
      if (!carbon_bridge32_region_bounds(a[0], &current->clip))
        return 0;
      *out = 0;
      return 1;
    }
    if (current && IS("_GetClip")) {
      Rect r = current->clip;
      uint32_t args[] = {a[0], (uint32_t)(int32_t)r.left,
                         (uint32_t)(int32_t)r.top, (uint32_t)(int32_t)r.right,
                         (uint32_t)(int32_t)r.bottom};
      return carbon_bridge32_dispatch("_SetRectRgn", args, out);
    }
    if (IS("_GetPort") && current) {
      if (a[0])
        *(uint32_t *)P(0) = current_world;
      *out = 0;
      return 1;
    }
    if (IS("_SetPort") && world(a[0])) {
      current_world = a[0];
      *out = 0;
      return 1;
    }
    if (current && (IS("_RGBForeColor") || IS("_RGBBackColor") ||
                    IS("_GetForeColor") || IS("_GetBackColor"))) {
      uint16_t *color = IS("_RGBForeColor") || IS("_GetForeColor")
                            ? current->foreground
                            : current->background;
      if (IS("_GetForeColor") || IS("_GetBackColor"))
        memcpy(P(0), color, 6);
      else
        memcpy(color, P(0), 6);
      *out = 0;
      return 1;
    }
    if (current && (IS("_EraseRect") || IS("_PaintRect"))) {
      Rect rect = *(Rect *)P(0);
      const uint16_t *color =
          IS("_EraseRect") ? current->background : current->foreground;
      rect.left = MAX(rect.left, current->clip.left);
      rect.top = MAX(rect.top, current->clip.top);
      rect.right = MIN(rect.right, current->clip.right);
      rect.bottom = MIN(rect.bottom, current->clip.bottom);
      int width = current->bounds.right - current->bounds.left,
          height = current->bounds.bottom - current->bounds.top;
      for (int y = MAX(0, rect.top - current->bounds.top);
           y < MIN(height, rect.bottom - current->bounds.top); ++y)
        for (int x = MAX(0, rect.left - current->bounds.left);
             x < MIN(width, rect.right - current->bounds.left); ++x) {
          uint8_t *dest = (void *)(uintptr_t)(current->pixels +
                                              y * current->stride + x * 4);
          uint8_t r = color[0] >> 8, g = color[1] >> 8, b = color[2] >> 8;
          if (current->format == k32BGRAPixelFormat) {
            dest[0] = b;
            dest[1] = g;
            dest[2] = r;
            dest[3] = 255;
          } else if (current->format == k32RGBAPixelFormat) {
            dest[0] = r;
            dest[1] = g;
            dest[2] = b;
            dest[3] = 255;
          } else {
            dest[0] = 255;
            dest[1] = r;
            dest[2] = g;
            dest[3] = b;
          }
        }
      *out = 0;
      return 1;
    }
    if (IS("_SetIdentityMatrix")) {
      int32_t identity[9] = {1 << 16, 0, 0, 0, 1 << 16, 0, 0, 0, 1 << 30};
      memcpy(P(0), identity, sizeof(identity));
      *out = 0;
      return 1;
    }
    if (IS("_GetPixelsState") || IS("_SetPixelsState") || IS("_LockPixels") ||
        IS("_UnlockPixels") || IS("_GetPixBaseAddr") || IS("_GetPixRowBytes")) {
      struct world32 *w = worlds;
      while (w && w->pixmap != a[0])
        w = w->next;
      if (!w)
        return 0;
      if (IS("_GetPixelsState"))
        *out = w->pixel_state;
      else if (IS("_GetPixBaseAddr"))
        *out = w->pixels;
      else if (IS("_GetPixRowBytes"))
        *out = w->stride;
      else if (IS("_LockPixels")) {
        w->pixel_state |= 0x80;
        *out = 1;
      } else {
        if (IS("_SetPixelsState"))
          w->pixel_state = a[1];
        else
          w->pixel_state &= ~0x80u;
        *out = 0;
      }
      return 1;
    }
    if (IS("_GetGraphicsImporterForDataRef")) {
      NSData *ref = copy_guest_handle(a[0]);
      uint32_t token = 0;
      if (a[1] == 0x70747220 && [ref length] >= 8) {
        const uint32_t *record = [ref bytes];
        if (record[0] && record[1] && record[1] < 536870912) {
          LP32GraphicsImporter *image = [[LP32GraphicsImporter alloc] init];
          NSData *data = [NSData dataWithBytes:(void *)(uintptr_t)record[0] length:record[1]];
          image->source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
          if (image->source && select_image(image, 0)) {
            image->matrix[0] = image->matrix[4] = 1 << 16;
            image->matrix[8] = 1 << 30;
            if (!graphics_importers) graphics_importers = [[NSMutableDictionary alloc] init];
            token = next_importer; next_importer += 16;
            [graphics_importers setObject:image forKey:@(token)];
            fprintf(stderr, "compat32: imported pointer-backed image %dx%d\n",
                image->bounds.right, image->bounds.bottom);
          }
          [image release];
        }
      }
      if (a[2]) *(uint32_t *)P(2) = token;
      *out = token ? 0 : (uint32_t)-2048;
      return 1;
    }
    if (IS("_GetGraphicsImporterForFile")) {
      char path[PATH_MAX];
      int status = carbon_bridge32_path_from_spec(a[0], path, sizeof(path));
      uint32_t token = 0;
      if (!status) {
        LP32GraphicsImporter *importer = [[LP32GraphicsImporter alloc] init];
        importer->source = CGImageSourceCreateWithURL(
            (CFURLRef)
                [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]],
            NULL);
        if (importer->source && select_image(importer, 0)) {
          importer->matrix[0] = importer->matrix[4] = 1 << 16;
          importer->matrix[8] = 1 << 30;
          if (!graphics_importers)
            graphics_importers = [[NSMutableDictionary alloc] init];
          token = next_importer;
          next_importer += 16;
          [graphics_importers setObject:importer forKey:@(token)];
        } else
          status = -2048;
        [importer release];
      }
      if (a[1])
        *(uint32_t *)P(1) = token;
      *out = (uint32_t)status;
      return 1;
    }
    LP32GraphicsImporter *importer = [graphics_importers objectForKey:@(a[0])];
    if (importer) {
      if (IS("_CloseComponent")) {
        [graphics_importers removeObjectForKey:@(a[0])];
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportGetNaturalBounds")) {
        *(Rect *)P(1) = (Rect){0, 0, (int16_t)CGImageGetHeight(importer->image),
                               (int16_t)CGImageGetWidth(importer->image)};
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportSetBoundsRect")) {
        importer->bounds = *(Rect *)P(1);
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportSetGWorld")) {
        importer->world = a[1];
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportGetImageCount")) {
        *(uint32_t *)P(1) = (uint32_t)CGImageSourceGetCount(importer->source);
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportSetImageIndex")) {
        *out = a[1] && select_image(importer, a[1] - 1) ? 0 : (uint32_t)-50;
        return 1;
      }
      if (IS("_GraphicsImportGetQuality")) {
        *(uint32_t *)P(1) = 0x200;
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportGetMatrix") ||
          IS("_GraphicsImportGetDefaultMatrix")) {
        int32_t identity[9] = {1 << 16, 0, 0, 0, 1 << 16, 0, 0, 0, 1 << 30};
        memcpy(P(1),
               IS("_GraphicsImportGetMatrix") ? importer->matrix : identity,
               sizeof(identity));
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportSetMatrix")) {
        memcpy(importer->matrix, P(1), sizeof(importer->matrix));
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportGetImageDescription")) {
        uint32_t args[] = {86};
        uint64_t handle = 0;
        resource_bridge32_dispatch("_NewHandleClear", args, &handle);
        if (!handle) {
          *out = (uint32_t)-108;
          return 1;
        }
        unsigned char *desc = (void *)(uintptr_t)*(uint32_t *)(uintptr_t)handle;
        uint32_t size = 86, type = 0x72617720, res = 72 << 16;
        uint16_t width = CGImageGetWidth(importer->image),
                 height = CGImageGetHeight(importer->image), frames = 1,
                 depth = 32, clut = 0xffff;
        memcpy(desc, &size, 4);
        memcpy(desc + 4, &type, 4);
        memcpy(desc + 32, &width, 2);
        memcpy(desc + 34, &height, 2);
        memcpy(desc + 36, &res, 4);
        memcpy(desc + 40, &res, 4);
        memcpy(desc + 48, &frames, 2);
        memcpy(desc + 82, &depth, 2);
        memcpy(desc + 84, &clut, 2);
        *(uint32_t *)P(1) = (uint32_t)handle;
        *out = 0;
        return 1;
      }
      if (IS("_GraphicsImportDraw")) {
        struct world32 *w =
            world(importer->world ? importer->world : current_world);
        if (!w) {
          *out = (uint32_t)-50;
          return 1;
        }
        size_t width = w->bounds.right - w->bounds.left,
               height = w->bounds.bottom - w->bounds.top;
        CGBitmapInfo info =
            w->format == k32BGRAPixelFormat
                ? kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
            : w->format == k32RGBAPixelFormat
                ? kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast
                : kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst;
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGContextRef context =
            CGBitmapContextCreate((void *)(uintptr_t)w->pixels, width, height,
                                  8, w->stride, color, info);
        CGColorSpaceRelease(color);
        if (!context) {
          *out = (uint32_t)-50;
          return 1;
        }
        Rect clip = w->clip;
        CGContextClipToRect(context,
                            CGRectMake(clip.left - w->bounds.left,
                                       clip.top - w->bounds.top,
                                       MAX(0, clip.right - clip.left),
                                       MAX(0, clip.bottom - clip.top)));
        const int32_t *m = importer->matrix;
        CGContextConcatCTM(
            context, CGAffineTransformMake(m[0] / 65536.0, m[1] / 65536.0,
                                           m[3] / 65536.0, m[4] / 65536.0,
                                           m[6] / 65536.0, m[7] / 65536.0));
        Rect b = importer->bounds;
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context,
                           CGRectMake(b.left - w->bounds.left,
                                      b.top - w->bounds.top, b.right - b.left,
                                      b.bottom - b.top),
                           importer->image);
        CGContextRelease(context);
        *out = 0;
        return 1;
      }
    }
    if (IS("_SetGWorld")) {
      current_world = a[0];
      *out = 0;
      return 1;
    }
    if (IS("_GetGWorld")) {
      if (a[0])
        *(uint32_t *)P(0) = current_world;
      if (a[1])
        *(uint32_t *)P(1) = 0;
      *out = 0;
      return 1;
    }
    if (IS("_OpenADataHandler")) {
      NSData *ref = copy_guest_handle(a[0]);
      if (a[1] != 0x70747220 || [ref length] < 8 || !a[6]) { *out = (uint32_t)-50; return 1; }
      if (!pointer_handlers) pointer_handlers = [[NSMutableDictionary alloc] init];
      uint32_t token = next_pointer_handler++;
      [pointer_handlers setObject:ref forKey:@(token)];
      *(uint32_t *)P(6) = token;
      *out = 0; return 1;
    }
    NSData *pointer_ref = [pointer_handlers objectForKey:@(a[0])];
    if (pointer_ref && IS("_DataHSetDataRefExtension")) {
      /* Type/name hints are unnecessary for AVFoundation content sniffing. */
      *out = 0; return 1;
    }
    if (pointer_ref && IS("_DataHGetDataRef")) {
      uint32_t handle = make_guest_handle(pointer_ref);
      if (a[1]) *(uint32_t *)P(1) = handle;
      *out = handle ? 0 : (uint32_t)-108; return 1;
    }
    if (pointer_ref && IS("_CloseComponent")) {
      [pointer_handlers removeObjectForKey:@(a[0])]; *out = 0; return 1;
    }
    if (IS("_FindNextComponent") && a[1]) {
      const uint32_t *description = P(1);
      fprintf(stderr, "compat32: component search type=%#x subtype=%#x manufacturer=%#x\n",
          description[0], description[1], description[2]);
    }
    if (IS("_FindNextComponent") && a[1] && *(uint32_t *)P(1) == 0x65617420) {
      *out = a[0] ? 0 : 0x75400000; return 1;
    }
    if ((IS("_OpenComponent") && a[0] == 0x75400000) ||
        (IS("_OpenDefaultComponent") && a[0] == 0x65617420)) {
      *out = 0x75400000; return 1;
    }
    if (IS("_CallComponentVersion") && a[0] == 0x75400000) { *out = 0x07000000; return 1; }
    if (IS("_CloseComponent") && a[0] == 0x75400000) { *out = 0; return 1; }
    if (IS("_MovieImportDataRef") && a[0] == 0x75400000) {
      NSData *ref = copy_guest_handle(a[1]);
      uint32_t token = 0;
      if (a[2] == 0x70747220 && [ref length] >= 8) {
        const uint32_t *record = [ref bytes];
        if (record[0] && record[1] && record[1] < 536870912) {
          NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
              [NSString stringWithFormat:@"lp32-movie-%@.mov", [[NSUUID UUID] UUIDString]]];
          NSData *media = [NSData dataWithBytes:(void *)(uintptr_t)record[0] length:record[1]];
          if ([media writeToFile:path atomically:YES]) token = new_movie(path);
          if (token) {
            LP32Movie *loaded = movie(token);
            [movies setObject:loaded forKey:@(a[3])];
            [movies removeObjectForKey:@(token)];
            if (a[7]) *(int32_t *)P(7) = (int32_t)(CMTimeGetSeconds(loaded->asset.duration) * 600);
            if (a[9]) *(uint32_t *)P(9) = 64;
            if (a[5]) *(uint32_t *)P(5) = 0;
            fprintf(stderr, "compat32: imported pointer-backed QuickTime movie (%u bytes)\n", record[1]);
          } else [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
      }
      *out = token ? 0 : (uint32_t)-2048;
      return 1;
    }
    if (IS("_EnterMovies") || IS("_ExitMovies")) {
      *out = 0;
      return 1;
    }
    if (IS("_OpenMovieFile")) {
      char path[PATH_MAX];
      int status = carbon_bridge32_path_from_spec(a[0], path, sizeof(path));
      if (!status && access(path, R_OK))
        status = -43;
      if (!status) {
        if (!movie_files)
          movie_files = [[NSMutableDictionary alloc] init];
        uint16_t token = next_file++;
        [movie_files setObject:[NSString stringWithUTF8String:path]
                        forKey:@(token)];
        if (a[1])
          *(int16_t *)P(1) = (int16_t)token;
      }
      *out = (uint32_t)status;
      return 1;
    }
    if (IS("_CloseMovieFile")) {
      [movie_files removeObjectForKey:@((uint16_t)a[0])];
      *out = 0;
      return 1;
    }
    if (IS("_NewMovieFromFile")) {
      NSString *path = [movie_files objectForKey:@((uint16_t)a[1])];
      uint32_t token = path ? new_movie(path) : 0;
      if (a[0])
        *(uint32_t *)P(0) = token;
      if (a[5])
        *(uint8_t *)P(5) = 0;
      *out = token ? 0 : (uint32_t)-2048;
      return 1;
    }
    if (IS("_NewMovie")) {
      *out = new_movie(nil);
      return 1;
    }
    if (IS("_DisposeMovie")) {
      for (struct movie_callback *p = movie_callbacks; p; p = p->next)
        if (p->movie == a[0]) { p->armed = NO; p->disposed = YES; }
      [movies removeObjectForKey:@(a[0])];
      *out = 0;
      return 1;
    }
    if (IS("_MoviesTask")) {
      if (a[0]) movie_task(a[0]);
      else for (NSNumber *key in [[[movies allKeys] copy] autorelease]) movie_task(key.unsignedIntValue);
      *out = 0;
      return 1;
    }
    if (IS("_NewGWorldFromPtr") || IS("_QTNewGWorldFromPtr")) {
      if (a[0])
        *(uint32_t *)P(0) = 0;
      if (!a[0] || !a[2] || !a[6]) {
        *out = (uint32_t)-50;
        return 1;
      }
      Rect bounds = *(Rect *)P(2);
      int width = bounds.right - bounds.left,
          height = bounds.bottom - bounds.top;
      BOOL yuv = a[1] == kCVPixelFormatType_422YpCbCr8;
      if ((a[1] != 32 && a[1] != k32ARGBPixelFormat &&
           a[1] != k32BGRAPixelFormat && a[1] != k32RGBAPixelFormat && !yuv) ||
          width <= 0 || height <= 0 || (yuv && (width & 1)) ||
          a[7] < (uint32_t)width * (yuv ? 2 : 4) ||
          (uint64_t)a[6] + (uint64_t)a[7] * height > UINT32_MAX) {
        *out = (uint32_t)-50;
        return 1;
      }
      struct world32 *w = calloc(1, sizeof(*w));
      if (!w) {
        *out = (uint32_t)-108;
        return 1;
      }
      w->token = next_world;
      next_world += 16;
      w->format = a[1];
      w->bounds = *(Rect *)P(2);
      w->background[0] = w->background[1] = w->background[2] = 65535;
      w->clip = w->bounds;
      w->pixels = a[6];
      w->stride = a[7];
      w->pixmap = compat_runtime32_allocate(4, 1);
      w->map_data = compat_runtime32_allocate(50, 1);
      if (!w->pixmap || !w->map_data) {
        compat_runtime32_deallocate(w->pixmap);
        compat_runtime32_deallocate(w->map_data);
        free(w);
        *out = (uint32_t)-108;
        return 1;
      }
      *(uint32_t *)(uintptr_t)w->pixmap = w->map_data;
      unsigned char *p = (void *)(uintptr_t)w->map_data;
      memcpy(p, &w->pixels, 4);
      uint16_t rowbytes = (uint16_t)(0x8000 | (w->stride & 0x3fff));
      memcpy(p + 4, &rowbytes, 2);
      memcpy(p + 6, &w->bounds, 8);
      uint16_t pixel[4] = {16, yuv ? 16 : 32, 3, 8};
      memcpy(p + 30, pixel, 8);
      memcpy(p + 38, &w->format, 4);
      w->next = worlds;
      worlds = w;
      if (a[0])
        *(uint32_t *)P(0) = w->token;
      *out = 0;
      return 1;
    }
    if (IS("_DisposeGWorld")) {
      for (struct world32 **p = &worlds; *p; p = &(*p)->next)
        if ((*p)->token == a[0]) {
          struct world32 *w = *p;
          *p = w->next;
          compat_runtime32_deallocate(w->pixmap);
          compat_runtime32_deallocate(w->map_data);
          free(w);
          break;
        }
      *out = 0;
      return 1;
    }
    if (IS("_GetGWorldPixMap")) {
      struct world32 *w = world(a[0]);
      *out = w ? w->pixmap : 0;
      return 1;
    }
    if (IS("_IsValidPort") && world(a[0])) {
      *out = 1;
      return 1;
    }
    if (IS("_GetPortBounds") && world(a[0])) {
      if (a[1])
        *(Rect *)P(1) = world(a[0])->bounds;
      *out = a[1];
      return 1;
    }
    LP32Movie *m = movie(a[0]);
    if (!m)
      return 0;
    if (IS("_GetMovieBox")) {
      if (a[1])
        *(Rect *)P(1) = m->bounds;
      *out = 0;
      return 1;
    }
    if (IS("_GetMovieNextInterestingTime")) {
      int64_t best = -1, duration = 0;
      BOOL backward = (int32_t)a[5] < 0, edge = (a[1] & 0x4000) != 0;
      int32_t origin = a[4];
      const uint32_t *types = P(3);
      for (unsigned i = 0; types && i < MIN(a[2], 32u); ++i) {
        for (NSArray *sample in movie_sample_times(m, types[i])) {
          int64_t time = [sample[0] longLongValue];
          if ((a[1] & 8) && ![sample[2] boolValue]) continue;
          BOOL eligible = backward ? (time < origin || (edge && time == origin)) :
                                      (time > origin || (edge && time == origin));
          if (eligible && (best < 0 || (backward ? time > best : time < best))) {
            best = time; duration = [sample[1] longLongValue];
          }
        }
      }
      if (a[6]) *(int32_t *)P(6) = (int32_t)best;
      if (a[7]) *(int32_t *)P(7) = (int32_t)duration;
      *out = 0; return 1;
    }
    if (IS("_SetMovieBox")) {
      m->bounds = *(Rect *)P(1);
      *out = 0;
      return 1;
    }
    if (IS("_SetMovieLanguage")) {
      CFStringRef localeID = CFLocaleCreateCanonicalLocaleIdentifierFromScriptManagerCodes(
          kCFAllocatorDefault, (LangCode)a[1], 0);
      if (localeID) {
        NSLocale *locale = [[[NSLocale alloc] initWithLocaleIdentifier:(NSString *)localeID] autorelease];
        AVMediaSelectionGroup *group = [m->asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
        NSArray *options = group ? [AVMediaSelectionGroup mediaSelectionOptionsFromArray:group.options withLocale:locale] : nil;
        if (options.count) [[m->player currentItem] selectMediaOption:options[0] inMediaSelectionGroup:group];
        CFRelease(localeID);
      }
      *out = 0; return 1;
    }
    if (IS("_SetMovieGWorld")) {
      m->world = a[1];
      struct world32 *w = world(a[1]);
      if (w && m->player) {
        uint32_t format = w->format == kCVPixelFormatType_422YpCbCr8 ?
            kCVPixelFormatType_422YpCbCr8 : kCVPixelFormatType_32BGRA;
        AVPlayerItem *item = m->player.currentItem;
        if (m->output) { [item removeOutput:m->output]; [m->output release]; }
        m->output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:
            @{(id)kCVPixelBufferPixelFormatTypeKey:@(format)}];
        [item addOutput:m->output];
        fprintf(stderr, "compat32: QuickTime movie output format=%08x world=%08x\n", format, w->token);
      }
      *out = 0;
      return 1;
    }
    if (IS("_SetMovieDrawingCompleteProc")) {
      m->callback = a[2];
      m->callback_data = a[3];
      *out = 0;
      return 1;
    }
    if (IS("_StartMovie")) {
      m->started = YES;
      [m->player play];
      *out = 0;
      return 1;
    }
    if (IS("_StopMovie")) {
      [m->player pause];
      *out = 0;
      return 1;
    }
    if (IS("_GoToBeginningOfMovie") || IS("_SetMovieTimeValue")) {
      [m->player seekToTime:CMTimeMake(
                                IS("_GoToBeginningOfMovie") ? 0 : (int32_t)a[1],
                                600)
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero];
      *out = 0;
      return 1;
    }
    if (IS("_IsMovieDone")) {
      *out = m->player.status == AVPlayerStatusFailed ||
             (m->started &&
              CMTimeCompare(m->player.currentTime, m->asset.duration) >= 0);
      return 1;
    }
    if (IS("_GetMovieTimeScale")) {
      *out = 600;
      return 1;
    }
    if (IS("_GetMovieTimeBase")) {
      *out = a[0];
      return 1;
    }
    if (IS("_GetMovieTime") || IS("_GetTimeBaseStartTime") ||
        IS("_GetTimeBaseStopTime")) {
      int64_t value =
          IS("_GetTimeBaseStartTime")
              ? 0
              : CMTimeConvertScale(IS("_GetTimeBaseStopTime")
                                       ? m->asset.duration
                                       : m->player.currentTime,
                                   600, kCMTimeRoundingMethod_Default)
                    .value;
      unsigned record_arg = IS("_GetMovieTime") ? 1 : 2;
      int32_t scale = IS("_GetMovieTime") ? 600 : (int32_t)a[1];
      if (scale > 0 && scale != 600)
        value = value * scale / 600;
      if (a[record_arg]) {
        uint32_t record[] = {(uint32_t)(value >> 32), (uint32_t)value,
                             (uint32_t)scale, a[0]};
        memcpy(P(record_arg), record, sizeof(record));
      }
      *out = (uint32_t)value;
      return 1;
    }
  }
  return 0;
#undef IS
#undef P
}

int quicktime_bridge32_run_media_self_test(void) {
    @autoreleasepool {
        uint32_t memory=compat_runtime32_allocate(256,1);if(!memory)return -1;
        uint32_t a[16]={memory};uint64_t result;
        double seconds=2.5;memcpy(a+1,&seconds,8);a[3]=600;
        if(!core_media_dispatch("_CMTimeMakeWithSeconds",a,&result))return -1;
        CMTime *t=(void *)(uintptr_t)memory;if(t->value!=1500||t->timescale!=600)return -1;
        memcpy(a+1,t,24);memcpy(a+7,t,24);
        if(!core_media_dispatch("_CMTimeRangeMake",a,&result))return -1;
        CMTimeRange *range=(void *)(uintptr_t)memory;
        if(CMTimeGetSeconds(range->start)!=2.5||CMTimeGetSeconds(range->duration)!=2.5)return -1;
        for(unsigned pass=0;pass<2;++pass) {
            uint32_t make=compat_runtime32_copy_cstring(pass?"valueWithCMTimeRange:":"valueWithCMTime:");
            uint32_t get=compat_runtime32_copy_cstring(pass?"CMTimeRangeValue":"CMTimeValue");
            CMTimeRange expected=CMTimeRangeMake(CMTimeMake(1500,600),CMTimeMake(3000,600));
            uint32_t call[16]={objc_bridge32_guest_object([NSValue class]),make};
            size_t size=pass?sizeof(CMTimeRange):sizeof(CMTime);
            memcpy(call+2,&expected,size);
            if(!objc_bridge32_dispatch("_objc_msgSend",call,&result)||!result)return -1;
            uint32_t get_args[]={memory,(uint32_t)result,get};
            if(!objc_bridge32_dispatch("_objc_msgSend_stret",get_args,&result)||memcmp((void *)(uintptr_t)memory,&expected,size))return -1;
            compat_runtime32_deallocate(make);compat_runtime32_deallocate(get);
        }
        uint32_t dictionary_selector=compat_runtime32_copy_cstring("dictionaryWithObjects:forKeys:count:");
        uint32_t *entries=(void *)(uintptr_t)memory;
        entries[0]=objc_bridge32_guest_object(@42);entries[1]=objc_bridge32_guest_object(@"pixel-format");
        uint32_t saved_entries[2]={entries[0],entries[1]};
        uint32_t dictionary_args[]={objc_bridge32_guest_object([NSDictionary class]),dictionary_selector,memory,memory+4,1};
        if(!objc_bridge32_dispatch("_objc_msgSend",dictionary_args,&result)||
           ![[(NSDictionary *)objc_bridge32_host_object((uint32_t)result) objectForKey:@"pixel-format"] isEqual:@42] ||
           memcmp(entries,saved_entries,sizeof(saved_entries)))return -1;
        compat_runtime32_deallocate(dictionary_selector);
        AudioStreamBasicDescription format={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,
            .mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,.mBytesPerPacket=2,.mFramesPerPacket=1,.mBytesPerFrame=2,.mChannelsPerFrame=1,.mBitsPerChannel=16};
        CMAudioFormatDescriptionRef description=NULL;
        if(CMAudioFormatDescriptionCreate(NULL,&format,0,NULL,0,NULL,NULL,&description))return -1;
        uint32_t token=objc_bridge32_guest_owned_object((void *)description);CFRelease(description);
        a[0]=token;
        if(!core_media_dispatch("_CMAudioFormatDescriptionGetStreamBasicDescription",a,&result)||!result||memcmp((void *)(uintptr_t)result,&format,sizeof(format)))return -1;
        a[1]=memory;
        if(!core_media_dispatch("_CMAudioFormatDescriptionGetMagicCookie",a,&result)||result||*(uint32_t *)(uintptr_t)memory)return -1;
        objc_bridge32_dispatch("_CFRelease",&token,&result);
        CVPixelBufferRef pixel=NULL;
        if(CVPixelBufferCreate(NULL,4,4,kCVPixelFormatType_32BGRA,NULL,&pixel))return -1;
        token=objc_bridge32_guest_owned_object(pixel);CFRelease(pixel);a[0]=token;a[1]=0;
        if(!core_media_dispatch("_CVPixelBufferLockBaseAddress",a,&result)||result)return -1;
        memset(CVPixelBufferGetBaseAddress(pixel),0x35,CVPixelBufferGetBytesPerRow(pixel)*4);
        if(!core_media_dispatch("_CVPixelBufferGetBaseAddress",a,&result)||!result)return -1;
        unsigned char *bytes=(void *)(uintptr_t)result;if(bytes[0]!=0x35)return -1;bytes[0]=0x71;
        if(!core_media_dispatch("_CVPixelBufferUnlockBaseAddress",a,&result)||result)return -1;
        CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
        if(*(unsigned char *)CVPixelBufferGetBaseAddress(pixel)!=0x71)return -1;
        CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
        objc_bridge32_dispatch("_CFRelease",&token,&result);compat_runtime32_deallocate(memory);
        puts("Core Media bridge PASS (CMTime/CMTimeRange, borrowed PCM format, cookie size, readable/writable low-address pixels)");return 0;
    }
}
