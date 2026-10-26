#include "objc_bridge.h"
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/gl.h>
#include "carbon_ui.h"
#include "carbon_text.h"
#include "hitch_recorder.h"
#include "audio_bridge.h"
#include "saga_controller_keys.h"
#import <GameController/GameController.h>
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* Carbon remains the guest's control model and event target. AppKit presents
 * that model because several Carbon widgets no longer exist in 64-bit macOS. */
static void *carbon;
static void *api(const char *name) {
  if (!carbon)
    carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon",
                    RTLD_NOW | RTLD_LOCAL);
  return dlsym(carbon, name);
}
static BOOL game_application_active(void) {
  /* This application runs Carbon's event loop. AppKit's cached isActive can
     lag the Process Manager, especially during the first window transition. */
  OSStatus (*current)(ProcessSerialNumber *) = api("GetCurrentProcess");
  OSStatus (*front)(ProcessSerialNumber *) = api("GetFrontProcess");
  ProcessSerialNumber self, foreground;
  if (current && front && current(&self) == noErr && front(&foreground) == noErr)
    return self.highLongOfPSN == foreground.highLongOfPSN &&
           self.lowLongOfPSN == foreground.lowLongOfPSN;
  return [NSApp isActive];
}
static unsigned char game_key_map[16];
static unsigned char game_hardware_keys[16];
static uint64_t controller_key_map;
static unsigned game_deactivation_depth;
void carbon_ui_begin_deactivation(void) { ++game_deactivation_depth; }
void carbon_ui_end_deactivation(void) {
  if (game_deactivation_depth) --game_deactivation_depth;
}
struct pending_game_event { EventRef event; struct pending_game_event *next; };
static struct pending_game_event *game_event_head, *game_event_tail;
static OSStatus queue_game_event(EventRef event) {
  struct pending_game_event *entry = calloc(1, sizeof(*entry));
  if (!entry) return memFullErr;
  entry->event = RetainEvent(event);
  if (game_event_tail) game_event_tail->next = entry;
  else game_event_head = entry;
  game_event_tail = entry;
  return noErr;
}
static void flush_game_events(BOOL deliver) {
  struct pending_game_event *entry = game_event_head;
  game_event_head = game_event_tail = NULL;
  while (entry) {
    struct pending_game_event *next = entry->next;
    if (deliver) PostEventToQueue(GetMainEventQueue(), entry->event, kEventPriorityStandard);
    ReleaseEvent(entry->event); free(entry); entry = next;
  }
}
static void clear_game_keys(void) {
  memset(game_key_map, 0, sizeof(game_key_map));
  memset(game_hardware_keys, 0, sizeof(game_hardware_keys));
  controller_key_map = 0;
  flush_game_events(NO);
}
@interface LP32GameWindow : NSWindow {
@public
  void *legacyWindow;
  BOOL forwardsGameKeys;
}
@end
@implementation LP32GameWindow
- (void)resignKeyWindow {
  if (forwardsGameKeys) clear_game_keys();
  [super resignKeyWindow];
}
- (void)sendEvent:(NSEvent *)event {
  /* The Carbon guest consumes keyboard events before AppKit's menu-key
     handling. Keep the standard Mac fullscreen shortcut on the host side. */
  NSEventModifierFlags shortcut = NSEventModifierFlagControl | NSEventModifierFlagCommand;
  if (forwardsGameKeys &&
      (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
      event.keyCode == 3 && (event.modifierFlags & shortcut) == shortcut) {
    if (event.type == NSEventTypeKeyDown && !event.isARepeat) {
      clear_game_keys();
      [self toggleFullScreen:nil];
    }
    return;
  }
  if (forwardsGameKeys && (event.type == NSEventTypeKeyDown ||
                          event.type == NSEventTypeKeyUp)) {
    UInt32 forwarded = 0;
    EventRef original = (EventRef)event.eventRef;
    if (original && GetEventParameter(original, 'lp32', typeUInt32, NULL,
          sizeof(forwarded), NULL, &forwarded) == noErr && forwarded) return;
    unsigned key = event.keyCode;
    if (key < 128) {
      if (event.type == NSEventTypeKeyUp) game_key_map[key / 8] &= ~(1u << (key % 8));
      else game_key_map[key / 8] |= 1u << (key % 8);
    }
    EventRef legacy = NULL;
    UInt32 kind = event.type == NSEventTypeKeyUp ? kEventRawKeyUp :
        (event.isARepeat ? kEventRawKeyRepeat : kEventRawKeyDown);
    OSStatus status = CreateEvent(NULL, kEventClassKeyboard, kind,
                                 event.timestamp, kEventAttributeUserEvent, &legacy);
    if (status == noErr) {
      UInt32 code = event.keyCode, modifiers = 0;
      NSEventModifierFlags flags = event.modifierFlags;
      if (flags & NSEventModifierFlagShift) modifiers |= shiftKey;
      if (flags & NSEventModifierFlagControl) modifiers |= controlKey;
      if (flags & NSEventModifierFlagOption) modifiers |= optionKey;
      if (flags & NSEventModifierFlagCommand) modifiers |= cmdKey;
      if (flags & NSEventModifierFlagCapsLock) modifiers |= alphaLock;
      NSString *characters = event.charactersIgnoringModifiers;
      char character = characters.length ? (char)[characters characterAtIndex:0] : 0;
      SetEventParameter(legacy, kEventParamKeyCode, typeUInt32, sizeof(code), &code);
      SetEventParameter(legacy, kEventParamKeyModifiers, typeUInt32, sizeof(modifiers), &modifiers);
      SetEventParameter(legacy, kEventParamKeyMacCharCodes, typeChar, 1, &character);
      SetEventParameter(legacy, kEventParamWindowRef, typeWindowRef, sizeof(legacyWindow), &legacyWindow);
      UInt32 forwarded = 1;
      SetEventParameter(legacy, 'lp32', typeUInt32, sizeof(forwarded), &forwarded);
      /* The game polls the Carbon queue before dispatching events through
         its input-device selector. Direct window dispatch skips that step. */
      status = queue_game_event(legacy);
      if (status != noErr) fprintf(stderr, "compat32: Cocoa keyboard delivery failed code=%u status=%d\n", code, (int)status);
      ReleaseEvent(legacy);
      if (status == noErr) return;
    }
  }
  [super sendEvent:event];
}
@end
@interface LP32FlippedView : NSView
@end
@implementation LP32FlippedView
- (BOOL)isFlipped {
  return YES;
}
@end
@interface LP32GameBackdrop : NSView
@end
@implementation LP32GameBackdrop
- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor blackColor] setFill];
  NSRectFill(dirtyRect);
}
@end
@interface LP32CarbonPanel : NSObject <NSWindowDelegate, NSTextFieldDelegate> {
@public
  void *native;
  NSWindow *window;
  NSView *render_view;
  NSSize render_size;

  NSMutableDictionary *controls;
  NSTimer *timer;
  BOOL modal, native_rendering, syncing, fullscreen_transition;
  unsigned gl_visibility, surface_refresh_frames;
}
- (void)sync;
- (void)action:(NSControl *)sender;
- (void)layoutGameSurface;
@end
static NSMutableDictionary *panels;
static void place_test_panel(NSWindow *window) {
  const char *setting = getenv("LP32_TEST_DISPLAY");
  if (!setting || !*setting || [window sheetParent])
    return;
  CGDirectDisplayID display = (CGDirectDisplayID)strtoul(setting, NULL, 0);
  for (NSScreen *screen in [NSScreen screens]) {
    if ([[[screen deviceDescription] objectForKey:@"NSScreenNumber"]
            unsignedIntValue] != display)
      continue;
    NSRect available = [screen visibleFrame], frame = [window frame];
    NSPoint origin = NSMakePoint(
        NSMidX(available) - frame.size.width / 2,
        NSMaxY(available) - frame.size.height -
            fmax(0, (available.size.height - frame.size.height) / 3));
    if (!NSEqualPoints(frame.origin, origin))
      [window setFrameOrigin:origin];
    return;
  }
}
static NSString *title(void *view, BOOL text) {
  CFStringRef string = NULL;
  if (text) {
    ByteCount size = 0;
    ((OSStatus (*)(void *, int16_t, uint32_t, ByteCount, void *,
                   ByteCount *))api("GetControlData"))(
        view, 0, 'cfst', sizeof(string), &string, &size);
  }
  if (!string)
    ((OSStatus (*)(void *, CFStringRef *))api("CopyControlTitleAsCFString"))(
        view, &string);
  return string ? [(NSString *)string autorelease] : @"";
}
static void sync_children(LP32CarbonPanel *panel, void *parent, void *root,
                          NSMutableSet *seen, unsigned depth) {
  if (depth > 32)
    return;
  void *view = ((void *(*)(void *))api("HIViewGetFirstSubview"))(parent);
  for (; view; view = ((void *(*)(void *))api("HIViewGetNextView"))(view)) {
    if (!((Boolean (*)(void *))api("HIViewIsLatentlyVisible"))(view))
      continue;
    ControlKind kind = {0};
    ((OSStatus (*)(void *, ControlKind *))api("GetControlKind"))(view, &kind);
    BOOL edit = carbon_text_is_control(view), label = kind.kind == 'stxt';
    BOOL button = kind.kind == 'push' || kind.kind == 'cbox' ||
                  kind.kind == 'rdio' || kind.kind == 'bevl' ||
                  kind.kind == 'rndb' || kind.kind == 'cgrp';
    BOOL popup = kind.kind == 'popb', slider = kind.kind == 'sldr';
    if (edit || label || button || popup || slider) {
      NSValue *key = [NSValue valueWithPointer:view];
      [seen addObject:key];
      NSControl *control = [panel->controls objectForKey:key];
      if (!control) {
        if (edit || label) {
          NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
          [field setEditable:edit];
          [field setSelectable:edit];
          [field setBezeled:edit];
          [field setDrawsBackground:edit];
          [field setFont:[NSFont systemFontOfSize:13]];
          if (edit)
            [field setDelegate:panel];
          control = field;
        } else if (popup)
          control = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                               pullsDown:NO];
        else if (slider)
          control = [[NSSlider alloc] initWithFrame:NSZeroRect];
        else {
          NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
          [b setButtonType:kind.kind == 'cbox' || kind.kind == 'cgrp'
                               ? NSSwitchButton
                           : kind.kind == 'rdio' ? NSRadioButton
                                                 : NSMomentaryPushInButton];
          [b setBezelStyle:NSBezelStyleRounded];
          control = b;
        }
        [control setTag:(NSInteger)view];
        [control setTarget:panel];
        [control setAction:@selector(action:)];
        [[panel->window contentView] addSubview:control];
        [panel->controls setObject:control forKey:key];
        [control release];
      }
      CGRect rect = {0};
      ((OSStatus (*)(void *, CGRect *))api("HIViewGetBounds"))(view, &rect);
      ((OSStatus (*)(CGRect *, void *, void *))api("HIViewConvertRect"))(
          &rect, view, root);
      if (edit) {
        rect.origin.y -= 2;
        rect.size.height = fmax(22, rect.size.height + 4);
      } else if (button || popup) {
        rect.origin.y -= 2;
        rect.size.height = fmax(24, rect.size.height + 4);
      }
      [control setFrame:rect];
      [control setHidden:NO];
      [control setEnabled:((Boolean (*)(void *))api("HIViewIsEnabled"))(view)];
      if (edit) {
        NSString *value = (NSString *)carbon_text_copy_value(view);
        if (![[control stringValue] isEqualToString:value])
          [control setStringValue:value ?: @""];
        [value release];
      } else if (label)
        [control setStringValue:title(view, YES)];
      else if (button) {
        [(NSButton *)control setTitle:title(view, NO)];
        if (kind.kind == 'cbox' || kind.kind == 'cgrp' || kind.kind == 'rdio')
          [(NSButton *)control
              setState:((int32_t (*)(void *))api("HIViewGetValue"))(view)
                           ? NSControlStateValueOn
                           : NSControlStateValueOff];
      } else if (slider) {
        [(NSSlider *)control
            setMinValue:((int32_t (*)(void *))api("HIViewGetMinimum"))(view)];
        [(NSSlider *)control
            setMaxValue:((int32_t (*)(void *))api("HIViewGetMaximum"))(view)];
        [control
            setIntValue:((int32_t (*)(void *))api("HIViewGetValue"))(view)];
      } else if (popup) {
        void *menu = NULL;
        ByteCount size = 0;
        ((OSStatus (*)(void *, int16_t, uint32_t, ByteCount, void *,
                       ByteCount *))api("GetControlData"))(
            view, 0, 'mhan', sizeof(menu), &menu, &size);
        if (menu) {
          uint16_t count = ((uint16_t (*)(void *))api("CountMenuItems"))(menu);
          NSPopUpButton *p = (NSPopUpButton *)control;
          if ([p numberOfItems] != count) {
            [p removeAllItems];
            for (uint16_t i = 1; i <= count; ++i) {
              CFStringRef text = NULL;
              ((OSStatus (*)(void *, uint16_t, CFStringRef *))api(
                  "CopyMenuItemTextAsCFString"))(menu, i, &text);
              [p addItemWithTitle:(NSString *)text ?: @""];
              if (text)
                CFRelease(text);
            }
          }
          int32_t value = ((int32_t (*)(void *))api("HIViewGetValue"))(view);
          if (value > 0 && value <= count)
            [p selectItemAtIndex:value - 1];
        }
      }
    }
    sync_children(panel, view, root, seen, depth + 1);
  }
}
/* Older Carbon launchers put mutually exclusive controls in the same slots.
   Their Cocoa counterparts need a real row rather than those legacy frames. */
static void layout_game_launcher(LP32CarbonPanel *panel) {
  NSButton *play = nil, *quit = nil, *view = nil, *info = nil, *registerButton = nil, *always = nil;
  NSPopUpButton *faqs = nil;
  for (NSControl *control in [panel->controls allValues]) {
    if ([control isHidden]) continue;
    if ([control isKindOfClass:[NSPopUpButton class]]) { faqs = (NSPopUpButton *)control; continue; }
    if (![control isKindOfClass:[NSButton class]]) continue;
    NSButton *button = (NSButton *)control;
    NSString *text = button.title;
    if ([text isEqualToString:@"Play"]) play = button;
    else if ([text isEqualToString:@"Quit"]) quit = button;
    else if ([text hasPrefix:@"View"]) view = button;
    else if ([text hasPrefix:@"More Info"]) info = button;
    else if ([text hasPrefix:@"Register"]) registerButton = button;
    else if ([text hasPrefix:@"Always show"]) always = button;
  }
  if (!play || !quit || !view || !info || !registerButton || !faqs || !always) return;
  [panel->window setContentSize:NSMakeSize(680, 350)];
  NSControl *row[] = {faqs, view, info, registerButton};
  for (unsigned i = 0; i < 4; ++i) [row[i] setFrame:NSMakeRect(24 + i * 161, 220, 149, 28)];
  [always setFrame:NSMakeRect(24, 269, 430, 24)];
  [quit setFrame:NSMakeRect(478, 308, 80, 28)];
  [play setFrame:NSMakeRect(574, 308, 82, 28)];
  NSMutableArray *labels = [NSMutableArray array];
  for (NSControl *control in [panel->controls allValues])
    if (![control isHidden] && [control isKindOfClass:[NSTextField class]] &&
        ![(NSTextField *)control isEditable])
      [labels addObject:control];
  [labels sortUsingComparator:^NSComparisonResult(NSControl *a, NSControl *b) {
    if (a.frame.origin.y < b.frame.origin.y) return NSOrderedAscending;
    if (a.frame.origin.y > b.frame.origin.y) return NSOrderedDescending;
    return NSOrderedSame;
  }];
  for (NSUInteger i = 0; i < labels.count; ++i)
    [labels[i] setFrame:NSMakeRect(24, 24 + i * 32, 632, 26)];
}

@implementation LP32CarbonPanel
- (void)dealloc {
  [timer invalidate];
  [timer release];
  [window setDelegate:nil];
  [window close];
  [window release];
  [controls release];
  [super dealloc];
}
- (void)sync {
  if (syncing || native_rendering)
    return;
  syncing = YES;
  place_test_panel(window);
  void *root = NULL;
  ((OSStatus (*)(void *, void **))api("GetRootControl"))(native, &root);
  NSMutableSet *seen = [NSMutableSet set];
  if (root)
    sync_children(self, root, root, seen, 0);
  for (NSValue *key in controls)
    if (![seen containsObject:key])
      [[controls objectForKey:key] setHidden:YES];
  layout_game_launcher(self);
  syncing = NO;
}
- (void)action:(NSControl *)sender {
  [self retain];
  void *view = (void *)[sender tag];
  if ([sender isKindOfClass:[NSPopUpButton class]])
    ((OSStatus (*)(void *, int32_t))api("HIViewSetValue"))(
        view, (int32_t)[(NSPopUpButton *)sender indexOfSelectedItem] + 1);
  if ([sender isKindOfClass:[NSSlider class]])
    ((OSStatus (*)(void *, int32_t))api("HIViewSetValue"))(view,
                                                           [sender intValue]);
  ControlKind kind = {0};
  ((OSStatus (*)(void *, ControlKind *))api("GetControlKind"))(view, &kind);
  int16_t part = kind.kind == 'cbox' || kind.kind == 'cgrp' ? 11
                 : kind.kind == 'rdio'                      ? 12
                                                            : 10,
          clicked = 0;
  OSStatus (*click)(void *, int16_t, uint32_t, int16_t *) =
      api("HIViewSimulateClick");
  OSStatus status = click ? click(view, part, 0, &clicked) : eventNotHandledErr;
  if (!clicked && (status == noErr || status == eventNotHandledErr)) {
    EventRef event = NULL;
    CreateEvent(NULL, kEventClassControl, kEventControlHit,
                GetCurrentEventTime(), 0, &event);
    SetEventParameter(event, kEventParamDirectObject, typeControlRef,
                      sizeof(view), &view);
    SetEventParameter(event, kEventParamControlPart, typeControlPartCode,
                      sizeof(part), &part);
    uint32_t modifiers = 0;
    SetEventParameter(event, kEventParamKeyModifiers, typeUInt32,
                      sizeof(modifiers), &modifiers);
    status = SendEventToEventTarget(
        event, ((void *(*)(void *))api("GetControlEventTarget"))(view));
    ReleaseEvent(event);
  }
  if (status == eventNotHandledErr) {
    HICommandExtended command = {0};
    ((OSStatus (*)(void *, uint32_t *))api("HIViewGetCommandID"))(
        view, &command.commandID);
    if (command.commandID) {
      command.attributes = kHICommandFromControl;
      command.source.control = view;
      EventRef event = NULL;
      CreateEvent(NULL, kEventClassCommand, kEventCommandProcess,
                  GetCurrentEventTime(), 0, &event);
      SetEventParameter(event, kEventParamDirectObject, typeHICommand,
                        sizeof(command), &command);
      status = SendEventToEventTarget(
          event, ((void *(*)(void *))api("GetWindowEventTarget"))(native));
      ReleaseEvent(event);
    }
    fprintf(stderr, "compat32: control command=%#x status=%d\n",
            command.commandID, status);
  }
  [self sync];
  [self release];
}
- (void)controlTextDidChange:(NSNotification *)note {
  if (syncing)
    return;
  NSTextField *field = [note object];
  carbon_text_set_value((void *)[field tag], [field stringValue]);
  [self sync];
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
  (void)sender;
  for (NSControl *control in [controls allValues])
    if ([control isKindOfClass:[NSButton class]] &&
        [[(NSButton *)control title] isEqualToString:@"Quit"] &&
        ![control isHidden]) {
      [self action:control];
      return NO;
    }
  if (modal)
    [NSApp stopModal];
  return YES;
}
- (void)windowDidResize:(NSNotification *)note {
  (void)note;
  if (native_rendering) { [self layoutGameSurface]; surface_refresh_frames = 30; }
}
- (void)layoutGameSurface {
  if (!render_view || render_size.width <= 0 || render_size.height <= 0) return;
  NSRect bounds = [[window contentView] bounds];
  CGFloat scale = fmin(bounds.size.width / render_size.width,
                       bounds.size.height / render_size.height);
  NSSize size = NSMakeSize(floor(render_size.width * scale), floor(render_size.height * scale));
  [render_view setFrame:NSMakeRect(floor((bounds.size.width - size.width) / 2),
      floor((bounds.size.height - size.height) / 2), size.width, size.height)];
  [[window contentView] setNeedsDisplay:YES];
}
- (void)windowWillEnterFullScreen:(NSNotification *)note {
  (void)note;
  fullscreen_transition = YES;
  surface_refresh_frames = 30;
  clear_game_keys();
}
- (void)windowWillExitFullScreen:(NSNotification *)note {
  [self windowWillEnterFullScreen:note];
}
- (void)windowDidEnterFullScreen:(NSNotification *)note {
  (void)note;
  fullscreen_transition = NO;
  [self layoutGameSurface];
  surface_refresh_frames = 30;
  fprintf(stderr, "compat32: Cocoa game fullscreen entered\n");
}
- (void)windowDidExitFullScreen:(NSNotification *)note {
  (void)note;
  fullscreen_transition = NO;
  [self layoutGameSurface];
  surface_refresh_frames = 30;
  fprintf(stderr, "compat32: Cocoa game fullscreen exited\n");
}
- (void)windowDidFailToEnterFullScreen:(NSWindow *)sender {
  (void)sender;
  fullscreen_transition = NO;
  surface_refresh_frames = 30;
}
- (void)windowDidFailToExitFullScreen:(NSWindow *)sender {
  [self windowDidFailToEnterFullScreen:sender];
}
@end
static LP32CarbonPanel *panel_for(void *native, BOOL create) {
  if (!panels && create)
    panels = [[NSMutableDictionary alloc] init];
  NSValue *key = [NSValue valueWithPointer:native];
  LP32CarbonPanel *panel = [panels objectForKey:key];
  if (panel || !create)
    return panel;
  NSApplicationLoad();
  panel = [[LP32CarbonPanel alloc] init];
  panel->native = native;
  panel->controls = [[NSMutableDictionary alloc] init];
  Rect bounds = {0};
  ((OSStatus (*)(void *, uint32_t, Rect *))api("GetWindowBounds"))(native, 33,
                                                                   &bounds);
  CGRect screen = CGDisplayBounds(CGMainDisplayID());
  NSRect rect =
      NSMakeRect(bounds.left, screen.size.height - bounds.bottom,
                 bounds.right - bounds.left, bounds.bottom - bounds.top);
  panel->window = [[LP32GameWindow alloc]
      initWithContentRect:rect
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  ((LP32GameWindow *)panel->window)->legacyWindow = native;
  [panel->window setReleasedWhenClosed:NO];
  [panel->window setDelegate:panel];
  [panel->window setTitle:[[NSBundle mainBundle]
                              objectForInfoDictionaryKey:@"CFBundleName"]
                              ?: @"Game"];
  [panel->window
      setContentView:[[[LP32FlippedView alloc]
                         initWithFrame:NSMakeRect(0, 0, rect.size.width,
                                                  rect.size.height)]
                         autorelease]];
  [panels setObject:panel forKey:key];
  [panel release];
  return panel;
}
void carbon_ui_show(void *native) {
  LP32CarbonPanel *p = panel_for(native, YES);
  if (!p->native_rendering) [p sync];
  if (p->native_rendering) p->surface_refresh_frames = 30;
  if (getenv("LP32_BACKGROUND_TEST"))
    [p->window orderBack:nil];
  else {
    if (p->native_rendering) {
      if (@available(macOS 14.0, *)) [NSApp activate];
      else [NSApp activateIgnoringOtherApps:YES];
    }
    [p->window makeKeyAndOrderFront:nil];
  }
}
void carbon_ui_hide(void *native) {
  LP32CarbonPanel *p = panel_for(native, NO);
  if (p) {
    /* Fullscreen Carbon games hide their drawable while processing suspend.
       Our drawable is a normal window: retain it as the activation target so
       the user can click back into the game after switching applications. */
    if (p->native_rendering && game_deactivation_depth) {
      clear_game_keys();
      fprintf(stderr, "compat32: retained game window during Carbon deactivation\n");
      return;
    }
    if (p->native_rendering) { clear_game_keys(); fprintf(stderr, "compat32: game window hidden active=%d\n", [NSApp isActive]); }
    [p->window orderOut:nil];
  }
}
void carbon_ui_dispose(void *native) {
  LP32CarbonPanel *p = panel_for(native, NO);
  if (p && p->native_rendering) { clear_game_keys(); fprintf(stderr, "compat32: game window disposed active=%d\n", [NSApp isActive]); }
  if (p && p->modal)
    [NSApp stopModal];
  [panels removeObjectForKey:[NSValue valueWithPointer:native]];
}
int32_t carbon_ui_run_modal(void *native) {
  LP32CarbonPanel *p = [panel_for(native, YES) retain];
  carbon_ui_show(native);
  p->modal = YES;
  p->timer = [[NSTimer timerWithTimeInterval:0.15
                                      target:p
                                    selector:@selector(sync)
                                    userInfo:nil
                                     repeats:YES] retain];
  [[NSRunLoop mainRunLoop] addTimer:p->timer forMode:NSModalPanelRunLoopMode];
  [NSApp runModalForWindow:p->window];
  [p->timer invalidate];
  [p->timer release];
  p->timer = nil;
  p->modal = NO;
  [p release];
  return 0;
}
int carbon_ui_stop_modal(void *native) {
  LP32CarbonPanel *p = panel_for(native, NO);
  if (!p || !p->modal)
    return 0;
  [NSApp stopModal];
  return 1;
}
void carbon_ui_use_native(void *native) {
  LP32CarbonPanel *p = panel_for(native, YES);
  p->native_rendering = YES;
  ((LP32GameWindow *)p->window)->forwardsGameKeys = YES;
  carbon_ui_show(native);
}

int carbon_ui_is_visible(void *native) {
  LP32CarbonPanel *p = panel_for(native, NO);
  return !p || p->native_rendering ? -1 : [p->window isVisible];
}

int32_t carbon_ui_show_sheet(void *sheet, void *parent) {
  LP32CarbonPanel *p = panel_for(sheet, YES), *owner = panel_for(parent, YES);
  [p sync];
  if (!p->timer) {
    p->timer = [[NSTimer timerWithTimeInterval:0.15
                                        target:p
                                      selector:@selector(sync)
                                      userInfo:nil
                                       repeats:YES] retain];
    [[NSRunLoop mainRunLoop] addTimer:p->timer forMode:NSModalPanelRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:p->timer forMode:NSDefaultRunLoopMode];
  }
  [owner->window beginSheet:p->window completionHandler:nil];
  return 0;
}
int32_t carbon_ui_hide_sheet(void *sheet) {
  LP32CarbonPanel *p = panel_for(sheet, NO);
  if (!p)
    return -50;
  NSWindow *parent = [p->window sheetParent];
  if (parent)
    [parent endSheet:p->window];
  [p->window orderOut:nil];
  [p->timer invalidate];
  [p->timer release];
  p->timer = nil;
  return 0;
}

void carbon_ui_set_background(void *native, unsigned short r, unsigned short g, unsigned short b) {
  LP32CarbonPanel *p = panel_for(native, YES);
  [p->window setBackgroundColor:[NSColor colorWithCalibratedRed:r / 65535.0
      green:g / 65535.0 blue:b / 65535.0 alpha:1.0]];
}

void carbon_ui_screen_updates(int enabled) {
  if (enabled) NSEnableScreenUpdates(); else NSDisableScreenUpdates();
}

int carbon_ui_resize_limits(void *native, float *minimum, float *maximum, int set) {
  if (!native) return -50;
  LP32CarbonPanel *p = panel_for(native, YES);
  if (set) {
    if (minimum) [p->window setContentMinSize:NSMakeSize(minimum[0], minimum[1])];
    if (maximum) [p->window setContentMaxSize:NSMakeSize(maximum[0], maximum[1])];
  } else {
    NSSize lo = [p->window contentMinSize], hi = [p->window contentMaxSize];
    if (minimum) { minimum[0] = lo.width; minimum[1] = lo.height; }
    if (maximum) { maximum[0] = hi.width; maximum[1] = hi.height; }
  }
  return 0;
}

void carbon_ui_bring_front(void *native) {
  carbon_ui_show(native);
}

static NSMutableDictionary *legacy_gl_contexts, *legacy_gl_windows;
static void *latest_game_window;
void carbon_ui_game_prepare(void *native) {
  latest_game_window = native;
  LP32CarbonPanel *p = panel_for(native, YES);
  p->native_rendering = YES;
  ((LP32GameWindow *)p->window)->forwardsGameKeys = YES;
  [p->window setHidesOnDeactivate:NO];
  static BOOL watching_activation;
  if (!watching_activation) {
    watching_activation = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:NSApplicationDidResignActiveNotification object:NSApp queue:nil
        usingBlock:^(NSNotification *note) { (void)note; clear_game_keys(); }];
    for (NSString *name in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidUnhideNotification])
      [center addObserverForName:name object:NSApp queue:nil usingBlock:^(NSNotification *note) {
        (void)note;
        LP32CarbonPanel *game = panel_for(latest_game_window, NO);
        if (game && game->native_rendering) {
          game->surface_refresh_frames = 30;
          [game->window deminiaturize:nil];
          [game->window makeKeyAndOrderFront:nil];
          fprintf(stderr, "compat32: game window restored on activation\n");
        }
      }];
  }
  [p->window setStyleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
      NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable];
  [p->window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
}
int carbon_ui_game_geometry(void *native, int x, int y, int size) {
  LP32CarbonPanel *p = panel_for(native, NO);
  if (!p || !p->native_rendering) return 0;
  if (size && x > 0 && y > 0) {
    p->render_size = NSMakeSize(x, y);
    p->surface_refresh_frames = 30;
    [p layoutGameSurface];
  }
  /* AppKit owns the fullscreen frame. The guest stays in windowed mode so
     its old display-capture/deactivation code cannot tear down the drawable. */
  if (p->fullscreen_transition || ([p->window styleMask] & NSWindowStyleMaskFullScreen)) return 1;
  if (size) {
    if (x <= 0 || y <= 0) return 1;
    NSScreen *screen = [p->window screen] ?: [NSScreen mainScreen];
    NSRect maximum = [p->window contentRectForFrameRect:[screen visibleFrame]];
    NSSize fitted = NSMakeSize(fmin(x, maximum.size.width), fmin(y, maximum.size.height));
    p->render_size = fitted;
    [p->window setContentSize:fitted];
    [[p->window contentView] setFrame:NSMakeRect(0, 0, fitted.width, fitted.height)];
    [p layoutGameSurface];
  } else {
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    [p->window setFrameTopLeftPoint:NSMakePoint(x, screen.size.height - y)];
  }
  return 1;
}
int carbon_ui_gl_attach(void *context, void *native) {
  if (!legacy_gl_contexts) {
    legacy_gl_contexts = [[NSMutableDictionary alloc] init];
    legacy_gl_windows = [[NSMutableDictionary alloc] init];
  }
  void *cgl = NULL;
  static void *agl;
  if (!agl) agl = dlopen("/System/Library/Frameworks/AGL.framework/AGL", RTLD_NOW);
  unsigned char (*get)(void *, void **) = dlsym(agl, "aglGetCGLContext");
  if (!get || !get(context, &cgl) || !cgl) return 0;
  NSValue *key = [NSValue valueWithPointer:context];
  NSOpenGLContext *gl = [legacy_gl_contexts objectForKey:key];
  if (!gl) {
    gl = [[[NSOpenGLContext alloc] initWithCGLContextObj:cgl] autorelease];
    if (!gl) return 0;
    [legacy_gl_contexts setObject:gl forKey:key];
  }
  if (!native) {
    [gl clearDrawable]; [legacy_gl_windows removeObjectForKey:key]; return 1;
  }
  LP32CarbonPanel *p = panel_for(native, YES);
  p->native_rendering = YES;
  NSRect fitted = [p->window contentRectForFrameRect:[p->window frame]];
  if (!p->render_view) {
    NSView *backdrop = [[[LP32GameBackdrop alloc] initWithFrame:NSMakeRect(0, 0,
        fitted.size.width, fitted.size.height)] autorelease];
    p->render_view = [[[NSView alloc] initWithFrame:backdrop.bounds] autorelease];
    [backdrop addSubview:p->render_view];
    [p->window setContentView:backdrop];
    if (p->render_size.width <= 0 || p->render_size.height <= 0) p->render_size = fitted.size;
  }
  [p layoutGameSurface];
  [gl setView:p->render_view];
  [legacy_gl_windows setObject:[NSValue valueWithPointer:native] forKey:key];
  [gl update];
  GLint dimensions[2] = {p->render_size.width, p->render_size.height};
  if (dimensions[0] && dimensions[1]) {
    CGLSetParameter(cgl, kCGLCPSurfaceBackingSize, dimensions);
    CGLEnable(cgl, kCGLCESurfaceBackingSize);
  }
  /* Use the same frame pacer as the other presentation paths. It caps this
     frame-rate-dependent engine at 60 even on a ProMotion display. */
  GLint swap_interval = getenv("LP32_HONOR_SWAP_INTERVAL") ? 1 : 0;
  [gl setValues:&swap_interval forParameter:NSOpenGLContextParameterSwapInterval];
  carbon_ui_show(native);
  fprintf(stderr, "compat32: AGL context attached to Cocoa game window\n");
  return 1;
}
int carbon_ui_gl_operation(void *context, int operation) {
  NSValue *key = [NSValue valueWithPointer:context];
  NSOpenGLContext *gl = [legacy_gl_contexts objectForKey:key];
  if (!gl) return 0;
  if (operation == 0) {
    LP32CarbonPanel *p = panel_for([[legacy_gl_windows objectForKey:key] pointerValue], NO);
    if (p) {
      unsigned visibility = ([p->window isVisible] ? 1 : 0) |
          (([p->window occlusionState] & NSWindowOcclusionStateVisible) ? 2 : 0);
      if (visibility & ~p->gl_visibility) p->surface_refresh_frames = 30;
      p->gl_visibility = visibility;
      if (visibility && p->surface_refresh_frames) {
        [p layoutGameSurface];
        if ([gl view] != p->render_view) [gl setView:p->render_view];
        [gl update];
        GLint dimensions[2] = {p->render_size.width, p->render_size.height};
        if (dimensions[0] > 0 && dimensions[1] > 0) {
          CGLSetParameter([gl CGLContextObj], kCGLCPSurfaceBackingSize, dimensions);
          CGLEnable([gl CGLContextObj], kCGLCESurfaceBackingSize);
        }
        if (p->surface_refresh_frames-- == 30)
          fprintf(stderr, "compat32: refreshing Cocoa game GL surface backing=%dx%d view=%.0fx%.0f origin=%.0f,%.0f\n",
              dimensions[0], dimensions[1], p->render_view.frame.size.width, p->render_view.frame.size.height,
              p->render_view.frame.origin.x, p->render_view.frame.origin.y);
      }
    }
    static unsigned frames;
    ++frames;
    if (frames == 1 || frames == 120 || frames == 600) {
      GLint draw = 0, read = 0, fbo = 0, scissor[4] = {0};
      glGetIntegerv(GL_DRAW_BUFFER, &draw); glGetIntegerv(GL_READ_BUFFER, &read);
      glGetIntegerv(0x8ca6, &fbo); glGetIntegerv(GL_SCISSOR_BOX, scissor);
      unsigned lit = 0;
      for (int y = 0; y < 5; ++y) for (int x = 0; x < 5; ++x) {
        unsigned char sample[4] = {0};
        glReadPixels(x * 300 + 50, y * 200 + 50, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, sample);
        if (sample[0] || sample[1] || sample[2]) ++lit;
      }
      fprintf(stderr, "compat32: GL buffers draw=%#x read=%#x fbo=%d lit=%u scissor=%d [%d,%d,%d,%d]\n",
          draw, read, fbo, lit, glIsEnabled(GL_SCISSOR_TEST), scissor[0], scissor[1], scissor[2], scissor[3]);
      GLint viewport[4] = {0}; glGetIntegerv(GL_VIEWPORT, viewport);
      unsigned char pixels[4] = {0};
      glReadPixels(viewport[2] / 2, viewport[3] / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
      fprintf(stderr, "compat32: Cocoa GL frame=%u viewport=%d,%d,%d,%d pixel=%u,%u,%u current=%p attached=%p error=%#x\n",
          frames, viewport[0], viewport[1], viewport[2], viewport[3], pixels[0], pixels[1], pixels[2],
          CGLGetCurrentContext(), [gl CGLContextObj], glGetError());
    }
    uint64_t work_end = hitch_recorder_enabled ? hitch_now() : 0;
    [gl flushBuffer];
    uint64_t flush_end = hitch_recorder_enabled ? hitch_now() : 0;
    objc_bridge32_pace_frame(p ? p->window : nil);
    carbon_ui_pump_sleep(0);
    uint64_t presented = hitch_now();
    if (hitch_recorder_enabled)
      hitch_frame(frames, work_end, flush_end, presented, 16666667, [NSApp isActive]);
    audio_bridge32_note_frame_presented();
    static uint64_t last_presented, interval_total, interval_max;
    static unsigned interval_count;
    if (last_presented) {
      uint64_t interval = presented - last_presented;
      interval_total += interval;
      if (interval > interval_max) interval_max = interval;
      if (++interval_count == 120) {
        fprintf(stderr, "compat32: Cocoa frame timing fps=%.1f average_ms=%.2f worst_ms=%.2f active=%d\n",
            120e9 / interval_total, interval_total / 120e6, interval_max / 1e6, [NSApp isActive]);
        interval_total = interval_max = interval_count = 0;
      }
    }
    last_presented = presented;
  }
  if (operation == 1) [gl update];
  if (operation == 2) { [gl clearDrawable]; [legacy_gl_contexts removeObjectForKey:key]; [legacy_gl_windows removeObjectForKey:key]; }
  return 1;
}
void *carbon_ui_gl_window(void *context) {
  return [[legacy_gl_windows objectForKey:[NSValue valueWithPointer:context]] pointerValue];
}

int carbon_ui_gl_fullscreen(void *context) {
  if (!latest_game_window) return 0;
  LP32CarbonPanel *p = panel_for(latest_game_window, YES);
  [p->window setFrame:[[p->window screen] visibleFrame] display:YES];
  return carbon_ui_gl_attach(context, latest_game_window);
}

int carbon_ui_game_bounds(void *native, void *raw, int global) {
  LP32CarbonPanel *p = panel_for(native, NO);
  if (!p || !p->native_rendering || !raw) return 0;
  NSRect r = [p->window contentRectForFrameRect:[p->window frame]];
  if (p->render_view && (p->fullscreen_transition ||
      ([p->window styleMask] & NSWindowStyleMaskFullScreen))) {
    r = [p->window convertRectToScreen:[p->render_view convertRect:p->render_view.bounds toView:nil]];
    r.size = p->render_size;
  }
  Rect *rect = raw;
  if (global) {
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    *rect = (Rect){(int16_t)(screen.size.height - NSMaxY(r)), (int16_t)r.origin.x,
        (int16_t)(screen.size.height - r.origin.y), (int16_t)NSMaxX(r)};
  } else *rect = (Rect){0, 0, (int16_t)r.size.height, (int16_t)r.size.width};
  return 1;
}

int carbon_ui_gl_rect(const unsigned int *rect, int viewport) {
  /* The emulated desktop mode can be taller than this window's renderer.
     Track the guest's actual default-framebuffer viewport, not that mode,
     when sizing the fixed backing surface. Offscreen passes are independent. */
  if (viewport && rect[0] == 0 && rect[1] == 0 && rect[2] && rect[3]) {
    LP32CarbonPanel *p = panel_for(latest_game_window, NO);
    GLint framebuffer = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
    if (p && p->render_view && !framebuffer &&
        (p->render_size.width != rect[2] || p->render_size.height != rect[3])) {
      p->render_size = NSMakeSize(rect[2], rect[3]);
      p->surface_refresh_frames = 30;
      [p layoutGameSurface];
    }
  }
  return 0;
}

int carbon_ui_game_active(void *native) {
  LP32CarbonPanel *p = panel_for(native, NO);
  if (!p || !p->native_rendering) return -1;
  /* Carbon retains a hidden native key window. Its visible Cocoa rendering
     window therefore need not be AppKit's key/main window. */
  return game_application_active() && [p->window isVisible];
}
void *carbon_ui_front_window(void) {
  for (LP32CarbonPanel *p in [panels allValues])
    if ([p->window isKeyWindow]) return p->native;
  LP32CarbonPanel *game = panel_for(latest_game_window, NO);
  if (game_application_active() && game && [game->window isVisible]) return game->native;
  return NULL;
}
void *carbon_ui_next_window(void *native) {
  BOOL found = NO;
  for (NSWindow *window in [NSApp orderedWindows]) {
    for (LP32CarbonPanel *p in [panels allValues]) {
      if (p->window != window) continue;
      if (found) return p->native;
      if (p->native == native) found = YES;
      break;
    }
  }
  return NULL;
}
/* The 2011 App Store edition predates DualSense and uses a different HID
   record layout from later Saga builds. Feed its existing keyboard path
   instead of writing later-edition structures into guest memory. */
static unsigned controller_bindings[12]={13,1,0,2,32,38,4,40,59,49,36,53};
static void load_controller_bindings(void) {
  NSString *path=[@"~/Library/Application Support/Feral Interactive/LEGO Star Wars Saga/Controller Keys.plist" stringByExpandingTildeInPath];
  NSDictionary *config=[NSDictionary dictionaryWithContentsOfFile:path];
  if (!config) return;
  NSArray *actions=@[@"MoveUp",@"MoveDown",@"MoveLeft",@"MoveRight",@"Jump",
      @"Special",@"Attack",@"SwitchCharacter",@"CyclePrevious",@"CycleNext",@"Pause",@"Back"];
  NSDictionary *codes=@{@"a":@0,@"s":@1,@"d":@2,@"f":@3,@"h":@4,@"g":@5,
      @"z":@6,@"x":@7,@"c":@8,@"v":@9,@"b":@11,@"q":@12,@"w":@13,
      @"e":@14,@"r":@15,@"y":@16,@"t":@17,@"o":@31,@"u":@32,@"i":@34,
      @"p":@35,@"return":@36,@"enter":@36,@"l":@37,@"j":@38,@"k":@40,
      @"n":@45,@"m":@46,@"tab":@48,@"space":@49,@"escape":@53,@"esc":@53,
      @"control":@59,@"ctrl":@59};
  for (unsigned i=0;i<12;++i) {
    id value=[config objectForKey:actions[i]];
    if (!value) continue;
    NSNumber *code=[value isKindOfClass:[NSString class]]?codes[[value lowercaseString]]:nil;
    if (code) controller_bindings[i]=[code unsignedIntValue];
    else fprintf(stderr,"compat32: ignored unsupported controller key for %s\n",[actions[i] UTF8String]);
  }
  fprintf(stderr,"compat32: loaded custom controller bindings\n");
}
static void poll_saga_controller(void) {
  static GCController *selected;
  static int stick_x, stick_y;
  static int enabled = -1;
  if (enabled < 0) {
    enabled = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"LP32GuestCodeBundlePath"] != nil &&
        ![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"LP32DisableControllerKeyboard"] boolValue];
    if (enabled) load_controller_bindings();
  }
  if (!enabled) return;
  LP32CarbonPanel *panel = panel_for(latest_game_window, NO);
  if (!panel || !panel->native_rendering || !game_application_active()) {
    controller_key_map = 0; stick_x = stick_y = 0; return;
  }
  NSArray *connected = [GCController controllers];
  if (selected && ![connected containsObject:selected]) {
    [selected release]; selected = nil; stick_x = stick_y = 0;
  }
  if (!selected) {
    for (GCController *candidate in connected) {
      if (![candidate extendedGamepad]) continue;
      selected = [candidate retain];
      fprintf(stderr,"compat32: App Store keyboard controller connected: %s\n",
          [[candidate vendorName] UTF8String]);
      break;
    }
  }
  GCExtendedGamepad *pad = [selected extendedGamepad];
  unsigned buttons = 0;
  if (pad) {
    stick_x = saga_stick_direction(pad.leftThumbstick.xAxis.value, stick_x);
    stick_y = saga_stick_direction(pad.leftThumbstick.yAxis.value, stick_y);
    if (stick_y>0 || pad.dpad.up.isPressed) buttons |= SAGA_PAD_UP;
    if (stick_y<0 || pad.dpad.down.isPressed) buttons |= SAGA_PAD_DOWN;
    if (stick_x<0 || pad.dpad.left.isPressed) buttons |= SAGA_PAD_LEFT;
    if (stick_x>0 || pad.dpad.right.isPressed) buttons |= SAGA_PAD_RIGHT;
    if (pad.buttonA.isPressed) buttons |= SAGA_PAD_CROSS;
    if (pad.buttonB.isPressed) buttons |= SAGA_PAD_CIRCLE;
    if (pad.buttonX.isPressed) buttons |= SAGA_PAD_SQUARE;
    if (pad.buttonY.isPressed) buttons |= SAGA_PAD_TRIANGLE;
    if (pad.leftShoulder.isPressed) buttons |= SAGA_PAD_L1;
    if (pad.rightShoulder.isPressed) buttons |= SAGA_PAD_R1;
    if (pad.buttonMenu.isPressed) buttons |= SAGA_PAD_MENU;
    if (pad.buttonOptions.isPressed) buttons |= SAGA_PAD_BACK;
  }
  uint64_t next = saga_controller_keys_with_bindings(buttons, 1, controller_bindings);
  uint64_t changed = next ^ controller_key_map;
  controller_key_map = next;
  for (unsigned key=0;key<64;++key) {
    uint64_t bit = UINT64_C(1)<<key;
    if (!(changed & bit)) continue;
    EventRef event = NULL;
    if (CreateEvent(NULL,kEventClassKeyboard,(next&bit)?kEventRawKeyDown:kEventRawKeyUp,
          GetCurrentEventTime(),kEventAttributeUserEvent,&event) != noErr) continue;
    UInt32 code=key, modifiers=0, forwarded=1;
    char character=0;
    switch(key) {
      case 0: character='a'; break; case 1: character='s'; break;
      case 2: character='d'; break; case 4: character='h'; break;
      case 13: character='w'; break; case 32: character='u'; break;
      case 38: character='j'; break; case 40: character='k'; break;
      case 34: character='i'; break; case 37: character='l'; break;
      case 31: character='o'; break; case 35: character='p'; break;
      case 49: character=' '; break; case 36: character='\r'; break;
      case 53: character=27; break;
    }
    SetEventParameter(event,kEventParamKeyCode,typeUInt32,sizeof(code),&code);
    SetEventParameter(event,kEventParamKeyModifiers,typeUInt32,sizeof(modifiers),&modifiers);
    SetEventParameter(event,kEventParamKeyMacCharCodes,typeChar,1,&character);
    SetEventParameter(event,kEventParamWindowRef,typeWindowRef,sizeof(panel->native),&panel->native);
    SetEventParameter(event,'lp32',typeUInt32,sizeof(forwarded),&forwarded);
    queue_game_event(event);
    ReleaseEvent(event);
  }
}
int carbon_ui_game_keys(void *keys) {
  LP32CarbonPanel *p = panel_for(latest_game_window, NO);
  if (!p || !p->native_rendering) return 0;
  if (!game_application_active()) { clear_game_keys(); memset(keys, 0, 16); return 1; }
  unsigned char hardware[16] = {0};
  void (*getKeys)(void *) = api("GetKeys");
  if (getKeys) getKeys(hardware);
  for (unsigned i = 0; i < sizeof(game_key_map); ++i) {
    /* Once a physical key is observed down, its live hardware state wins
       over delayed Cocoa events. Synthetic window events retain their map. */
    game_hardware_keys[i] |= hardware[i];
    ((unsigned char *)keys)[i] = hardware[i] |
        (game_key_map[i] & ~game_hardware_keys[i]) |
        (i<8 ? (unsigned char)(controller_key_map>>(8*i)) : 0);
    game_key_map[i] &= hardware[i] | ~game_hardware_keys[i];
  }
  return 1;
}
int carbon_ui_pump_sleep(unsigned int microseconds) {
  if (![NSThread isMainThread] || !latest_game_window) return 0;
  static BOOL pumping;
  if (pumping) return 0;
  pumping = YES;
  @autoreleasepool {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:fmin(microseconds / 1e6, 0.05)];
    NSEvent *event;
    unsigned count = 0;
    while (count++ < 256 && (event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
                  inMode:NSDefaultRunLoopMode dequeue:YES])) {
      [NSApp sendEvent:event];
      until = [NSDate distantPast];
    }
  }
  /* Post after draining AppKit so it cannot consume our newly translated
     Carbon events before the game's own ReceiveNextEvent loop sees them. */
  poll_saga_controller();
  flush_game_events(game_application_active());
  pumping = NO;
  return 1;
}
