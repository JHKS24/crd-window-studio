#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Security/Security.h>
#import "../generated/SettingsSchema.h"
#import "../generated/Localization.h"
#import <dispatch/dispatch.h>
#include <cmath>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <libproc.h>
#include <limits.h>
#include <notify.h>

// CRD Window Studio overlay helper.
// A background agent that hides the Chrome Remote Desktop sharing window and shows a small
// configurable overlay (bar, card or dot) with a Stop control in its place. It reads its
// settings from config.json, restores the original window on exit, and has a self-test mode.

#pragma mark - Shared state
// Process-wide flags, the loaded configuration, file watchers and user geometry tracking.
static BOOL previewMode=NO,fixtureMode=NO,applying=NO;
static NSDictionary *currentConfig;
static NSData *lastConfigData;
static dispatch_source_t directoryWatcher,parentWatcher,fileWatcher;
static NSString *watchedParent;
static NSString *watchedDirectory,*lastObservedSignature;
static NSDate *lastConfigReloadDate;
static NSUInteger reloadGeneration,geometryGeneration,configReadCount,configReloadCount;
static BOOL reloadPending;
static BOOL userGeometryTracking,geometryDirty;
static NSRect geometryFrame,geometryVisibleFrame;
static NSUInteger geometryScreenIndex=NSNotFound;
@class CRDStopGestureGate;
static void WriteRuntimeStatus(NSString *event,NSWindowController *controller);
static void PresentStopContextMenu(NSMenu *menu,NSEvent *event,NSView *view,CRDStopGestureGate *gate=nil);
static void ReconcileFromConfig(BOOL needsAX=YES);
static void ConfigDirectoryReplaced(void);
static void ApplyOverlay(BOOL reposition);
static void BeginUserGeometry(NSWindow *window);
static void EndUserGeometry(void);
static BOOL TrackPress(NSWindow *window,NSEvent *down,BOOL canMove,void (^willMove)(void),NSEvent **upOut);
static NSEvent *NextTrackingEvent(void);
static NSPoint ScreenPoint(NSEvent *event);
static BOOL PassedDragThreshold(NSPoint start,NSPoint current);
static void InvalidateGeometry(void);


#pragma mark - Schema and localization
// The generated settings schema and the bundled English/Korean string catalog.

// Parses the generated settings schema once; it holds defaults, limits, choices and shapes.
static NSDictionary *Schema(void) {
    static NSDictionary *schema;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithBytes:kCRDSettingsSchemaJSON length:strlen(kCRDSettingsSchemaJSON)];
        schema = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSCAssert([schema[@"defaults"] isKindOfClass:NSDictionary.class], @"Invalid generated schema");
    });
    return schema;
}
// Path of config.json; CRD_WINDOW_CONFIG overrides it for isolated runs.
NSString *CRDConfigPath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CRD_WINDOW_CONFIG"];
    return override.length ? override : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/CRDWindowPatch/config.json"];
}
NSDictionary *CRDDefaults(void) { return Schema()[@"defaults"]; }
static BOOL IsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
// Parses the generated localization catalog once (language -> key -> text).
static NSDictionary *LocalizationCatalog(void) {
    static NSDictionary *catalog; static dispatch_once_t once;
    dispatch_once(&once,^{
        NSData *data=[NSData dataWithBytes:kCRDLocalizationJSON length:strlen(kCRDLocalizationJSON)];
        catalog=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSCAssert([catalog isKindOfClass:NSDictionary.class],@"Invalid generated localization catalog");
    });
    return catalog;
}
// Picks "ko" or "en" from an ordered list of preferred languages.
static NSString *LocalizationLanguageForPreferences(NSArray<NSString *> *preferences) {
    NSString *selected=[NSBundle preferredLocalizationsFromArray:@[@"en",@"ko"] forPreferences:preferences].firstObject;
    return [selected isEqual:@"ko"]?@"ko":@"en";
}
// Uses the settings app's AppleLanguages override when it is a non-empty list of strings, else the fallback.
static NSString *LocalizationLanguageWithStudioOverride(id override,NSArray<NSString *> *fallback) {
    BOOL valid=[override isKindOfClass:NSArray.class]&&[override count]>0;
    if(valid) for(id language in override) if(![language isKindOfClass:NSString.class]||![language length]) { valid=NO; break; }
    return LocalizationLanguageForPreferences(valid?override:fallback);
}
static NSString *fixtureLanguage; // Set only by isolated self-tests, never configuration or production input.
// Current UI language: the settings app's language preference, then the system languages.
static NSString *LocalizationLanguage(void) {
    if(fixtureMode&&fixtureLanguage) return fixtureLanguage;
    // Only this product's explicit language preference is read. No preferences are written.
    // Query on demand so a later menu opening can observe macOS app-language changes.
    id studioLanguages=CFBridgingRelease(CFPreferencesCopyValue(CFSTR("AppleLanguages"),CFSTR("local.crdwindow.studio"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost));
    return LocalizationLanguageWithStudioOverride(studioLanguages,NSLocale.preferredLanguages);
}
// Looks up a catalog key (the Korean source text) for a language; an unknown key returns itself.
static NSString *LocalizedForLanguage(NSString *key,NSString *language) {
    NSString *selected=[language.lowercaseString hasPrefix:@"ko"]?@"ko":@"en";
    id value=LocalizationCatalog()[selected][key];
    return [value isKindOfClass:NSString.class]&&[value length]?value:key;
}
static NSString *L(NSString *key) { return LocalizedForLanguage(key,LocalizationLanguage()); }
// Returns user-written text as is, and translates empty or default text.
static NSString *ConfiguredTextForLanguage(NSString *value,NSString *key,NSString *fallback,NSString *language) {
    // Only empty/default text is translated. User-written text is never passed through the catalog.
    if(!value.length||[value isEqual:CRDDefaults()[key]]||[value isEqual:fallback]) return LocalizedForLanguage(fallback,language);
    return value;
}
static NSString *ConfiguredText(NSString *value,NSString *key,NSString *fallback) {
    return ConfiguredTextForLanguage(value,key,fallback,LocalizationLanguage());
}
static BOOL IsNumber(id value) { return [value isKindOfClass:NSNumber.class] && !IsBoolean(value); }
static BOOL Fail(NSString **error, NSString *message) { if (error) *error = message; return NO; }
static NSArray *ChoiceIDs(NSString *key) { return [Schema()[@"choices"][key] valueForKey:@"id"]; }

#pragma mark - Configuration validation and storage
// Validation against the schema, locked atomic writes, and change signatures for config.json.

// Validates a configuration dictionary against the schema and fills missing keys with defaults.
// Returns nil and a localized error for an unknown key, a wrong type, an unsupported schema
// version, an out-of-range number, an unknown choice, shape or color, or text over 2,048 characters.
static NSDictionary *Validate(NSDictionary *input, NSString **error) {
    if (![input isKindOfClass:NSDictionary.class]) { Fail(error, L(@"설정 파일 형식이 올바르지 않습니다. 파일을 수정하거나 기본값으로 되돌리세요.")); return nil; }
    NSDictionary *defaults = CRDDefaults();
    NSMutableDictionary *d = [defaults mutableCopy];
    for (id key in input) {
        id base = defaults[key], value = input[key];
        if (!base) { Fail(error, [NSString stringWithFormat:L(@"알 수 없는 설정 항목(%@)이 있습니다. 설정 파일에서 지우거나 기본값으로 되돌리세요."), key]); return nil; }
        BOOL typed = [base isKindOfClass:NSString.class] ? [value isKindOfClass:NSString.class] :
            (IsBoolean(base) ? IsBoolean(value) : IsNumber(value));
        if (!typed) { Fail(error, [NSString stringWithFormat:L(@"%@ 값이 올바르지 않습니다. 설정 파일을 확인하거나 기본값으로 되돌리세요."), key]); return nil; }
        d[key] = value;
    }
    // "hidden" is not a supported mode; a saved "hidden" loads as custom, with no error, and the
    // next write saves custom.
    if ([d[@"mode"] isEqual:@"hidden"]) d[@"mode"] = @"custom";
    if (![d[@"schema"] isEqual:defaults[@"schema"]]) { Fail(error, L(@"지원하지 않는 설정 파일 버전입니다. 기본값으로 되돌리거나 앱을 업데이트하세요.")); return nil; }
    NSDictionary *ranges = Schema()[@"numericLimits"];
    for (NSString *key in ranges) {
        double n = [d[key] doubleValue]; NSArray *r = ranges[key];
        if (!std::isfinite(n) || n < [r[0] doubleValue] || n > [r[1] doubleValue]) {
            Fail(error, [NSString stringWithFormat:L(@"%@ 값은 %@~%@ 사이로 지정하세요."), key, r[0], r[1]]); return nil;
        }
    }
    for (NSString *key in Schema()[@"choices"]) {
        if (![key isEqual:@"accent"] && ![ChoiceIDs(key) containsObject:d[key]]) {
            Fail(error, [NSString stringWithFormat:L(@"%@ 설정이 올바르지 않습니다. 사용할 수 있는 값으로 바꾸거나 기본값으로 되돌리세요."),key]); return nil;
        }
    }
    if (![[Schema()[@"shapes"] valueForKey:@"id"] containsObject:d[@"shape"]]) {
        Fail(error, L(@"창 모양 설정이 올바르지 않습니다. 다른 창 모양을 고르거나 기본값으로 되돌리세요.")); return nil;
    }
    static NSRegularExpression *hex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9a-fA-F]{6}$" options:0 error:nil]; });
    for (NSString *key in @[@"background", @"foreground", @"accent", @"dotColor"]) {
        NSString *s = d[key]; BOOL semantic = [s isEqual:@"system"] || (([key isEqual:@"accent"]||[key isEqual:@"dotColor"]) && [ChoiceIDs(@"accent") containsObject:s]) || ([key isEqual:@"dotColor"]&&[s isEqual:@"accent"]);
        if (!semantic && [hex numberOfMatchesInString:s options:0 range:NSMakeRange(0,s.length)] != 1) {
            Fail(error, [NSString stringWithFormat:L(@"%@ 색상이 올바르지 않습니다. 시스템 색상 이름이나 #RRGGBB 형식으로 입력하세요."),key]); return nil;
        }
    }
    for (id value in d.allValues) {
        if (![value isKindOfClass:NSString.class]) continue;
        __block NSUInteger count = 0;
        [value enumerateSubstringsInRange:NSMakeRange(0,[value length]) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) {
            if (++count > 2048) *stop = YES;
        }];
        if (count > 2048) { Fail(error, L(@"안내 문구가 너무 깁니다. 2,048자 이하로 입력하세요.")); return nil; }
    }
    return [d copy];
}
NSDictionary *CRDValidateConfig(NSDictionary *input, NSString **error) { return Validate(input,error); }
// Identity and change signature of a file (device, inode, size, mtime, ctime); nil when missing.
static NSString *PathSignature(NSString *path) {
    struct stat info={};
    if(stat(path.fileSystemRepresentation,&info)!=0) return nil;
    return [NSString stringWithFormat:@"%llu:%llu:%lld:%ld:%ld:%ld:%ld",
        (unsigned long long)info.st_dev,(unsigned long long)info.st_ino,(long long)info.st_size,
        info.st_mtimespec.tv_sec,info.st_mtimespec.tv_nsec,info.st_ctimespec.tv_sec,info.st_ctimespec.tv_nsec];
}
static NSString *FileSignature(void) { return PathSignature(CRDConfigPath()); }
// Reads the raw config.json bytes and counts the read.
static NSData *ReadData(NSString **error) {
    configReadCount++;
    NSError *e; NSData *data = [NSData dataWithContentsOfFile:CRDConfigPath() options:0 error:&e];
    if (!data && error) *error = e.localizedDescription;
    return data;
}
// Parses JSON bytes and validates the result.
static NSDictionary *ParseData(NSData *data, NSString **error) {
    NSError *e; id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
    if (!obj) { if (error) *error = e.localizedDescription; return nil; }
    return Validate(obj,error);
}
// Reads and validates config.json; a missing file reads as the defaults.
NSDictionary *CRDReadConfig(NSString **error) {
    if (![NSFileManager.defaultManager fileExistsAtPath:CRDConfigPath()]) return CRDDefaults();
    NSData *data = ReadData(error); return data ? ParseData(data,error) : nil;
}
// Creates the support folder (0700) and tries the exclusive config.json.lock once. A busy
// writer never stalls the helper's main queue or delays restoration during shutdown.
static int LockConfig(NSString **error,BOOL *busy=nullptr) {
    if(busy) *busy=NO;
    NSError *e; NSString *path = CRDConfigPath();
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&e]) {
        if (error) *error = e.localizedDescription; return -1;
    }
    int fd=open([path stringByAppendingPathExtension:@"lock"].fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC,0600);
    if(fd<0 || flock(fd,LOCK_EX|LOCK_NB)!=0) {
        if(busy) *busy=fd>=0&&errno==EWOULDBLOCK;
        if(error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil].localizedDescription;
        if(fd>=0) close(fd); return -1;
    }
    return fd;
}
// Writes an already validated configuration atomically as sorted, pretty-printed JSON.
static BOOL WriteValidatedConfig(NSDictionary *d,NSString **error) {
    NSError *e; NSString *path=CRDConfigPath();
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&e];
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&e];
    if (!ok && error) *error = e.localizedDescription;
    return ok;
}
// Validates and writes a configuration under the config lock.
BOOL CRDWriteConfig(NSDictionary *input, NSString **error) {
    NSDictionary *d=Validate(input,error); if(!d) return NO;
    int fd=LockConfig(error); if(fd<0) return NO;
    BOOL ok=WriteValidatedConfig(d,error); flock(fd,LOCK_UN); close(fd); return ok;
}
// Read-modify-write of config.json under the lock. Returns the saved configuration, or nil when
// the file cannot be read, the change does not validate, or the write fails.
static NSDictionary *UpdateConfig(void (^change)(NSMutableDictionary *),BOOL *busy=nullptr) {
    int fd=LockConfig(nil,busy); if(fd<0) return nil;
    // Once loaded, disappearance is not permission to replace the file with defaults.
    NSDictionary *latest=lastConfigData&&!FileSignature()?nil:CRDReadConfig(nil);
    NSMutableDictionary *next=[latest mutableCopy];
    if(next) change(next);
    NSDictionary *valid=next?Validate(next,nil):nil;
    BOOL ok=valid&&WriteValidatedConfig(valid,nil);
    flock(fd,LOCK_UN); close(fd); return ok?valid:nil;
}

#pragma mark - Presets
// presets.json sits next to config.json. The settings app owns writes (under config.json.lock);
// the helper only reads it, and a missing or corrupt file means an empty list.
static const NSUInteger CRDPresetLimit=20,CRDPresetNameLimit=40;
static NSString *PresetsPath(void) { return [CRDConfigPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"presets.json"]; }
static NSSet<NSString *> *PresetExcludedKeys(void) { return [NSSet setWithArray:@[@"schema",@"enabled",@"mode",@"loggingEnabled"]]; }
// Counts user-perceived characters (composed character sequences).
static NSUInteger ComposedLength(NSString *text) {
    __block NSUInteger count=0;
    [text enumerateSubstringsInRange:NSMakeRange(0,text.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *a,NSRange b,NSRange c,BOOL *d){ count++; }];
    return count;
}
// Returns the preset's validated values. Unknown and excluded keys are dropped; any invalid kept
// value rejects the whole preset. A preset without stopStyle was saved with the red Stop, so that
// key alone is filled with "red".
static NSDictionary *PresetValues(id values) {
    if(![values isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *defaults=CRDDefaults(); NSSet *excluded=PresetExcludedKeys();
    NSMutableDictionary *kept=[NSMutableDictionary dictionary];
    for(id key in values) if([key isKindOfClass:NSString.class]&&defaults[key]&&![excluded containsObject:key]) kept[key]=values[key];
    if(!kept.count) return nil;
    NSDictionary *valid=Validate(kept,nil); if(!valid) return nil;
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *key in kept) result[key]=valid[key];
    if(!result[@"stopStyle"]) result[@"stopStyle"]=@"red";
    return result;
}
// Reads up to 20 valid presets with unique ids and 1-40 character names; anything else is skipped.
static NSArray<NSDictionary *> *ReadPresetsAtPath(NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path]; if(!data) return @[];
    id root=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![root isKindOfClass:NSDictionary.class]||![root[@"schema"] isEqual:@1]||IsBoolean(root[@"schema"])||![root[@"presets"] isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *presets=[NSMutableArray array];
    for(id item in root[@"presets"]) {
        if(presets.count>=CRDPresetLimit) break;
        if(![item isKindOfClass:NSDictionary.class]||![item[@"id"] isKindOfClass:NSString.class]||![item[@"id"] length]||![item[@"name"] isKindOfClass:NSString.class]) continue;
        if([[presets valueForKey:@"id"] containsObject:item[@"id"]]) continue; // The first entry with an id wins, as in the settings app.
        NSString *name=[item[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSUInteger length=ComposedLength(name); if(length<1||length>CRDPresetNameLimit) continue;
        NSDictionary *values=PresetValues(item[@"values"]); if(!values) continue;
        [presets addObject:@{@"id":item[@"id"],@"name":name,@"values":values}];
    }
    return presets;
}
static NSArray<NSDictionary *> *ReadPresets(void) { return ReadPresetsAtPath(PresetsPath()); }
// True when every value of a non-empty preset equals the configuration's value.
static BOOL PresetMatches(NSDictionary *values,NSDictionary *config) {
    if(!values.count||!config) return NO;
    for(NSString *key in values) if(![values[key] isEqual:config[key]]) return NO;
    return YES;
}

#pragma mark - Colors
// Resolves configured color values to NSColor.

// Resolves "system" (per role), a named system color, or #RRGGBB.
static NSColor *Color(NSString *value, NSString *role) {
    if ([value isEqual:@"system"]) {
        if ([role isEqual:@"background"]) return NSColor.windowBackgroundColor;
        if ([role isEqual:@"foreground"]) return NSColor.labelColor;
        return NSColor.controlAccentColor;
    }
    NSDictionary *semantic = @{@"blue":NSColor.systemBlueColor, @"purple":NSColor.systemPurpleColor,
        @"pink":NSColor.systemPinkColor, @"red":NSColor.systemRedColor, @"orange":NSColor.systemOrangeColor,
        @"yellow":NSColor.systemYellowColor, @"green":NSColor.systemGreenColor, @"graphite":NSColor.systemGrayColor};
    if (semantic[value]) return semantic[value];
    unsigned int n = 0; [[NSScanner scannerWithString:[value substringFromIndex:1]] scanHexInt:&n];
    return [NSColor colorWithSRGBRed:((n>>16)&255)/255.0 green:((n>>8)&255)/255.0 blue:(n&255)/255.0 alpha:1];
}
// The dot color, where "accent" or a missing value follows the accent color.
static NSColor *DotColor(NSDictionary *config) {
    NSString *value=config[@"dotColor"];
    if(!value||[value isEqual:@"accent"]) value=config[@"accent"];
    return Color(value,@"accent");
}

#pragma mark - Overlay background and grips
// The overlay's background view and its drag and resize grips, and the rules that keep a left
// click a left click: menus open only on a right mouse down.

// True only for a right mouse down: a right click, a two-finger click, or the right-mouse-down
// event AppKit makes for a keyboard or Accessibility menu request. A left click never opens a
// context menu, whatever its modifier flags, so AppKit's Control-click menu never replaces a click.
static BOOL OpensContextMenu(NSEvent *event) { return event.type==NSEventTypeRightMouseDown; }
// The same left mouse event without the Control flag; every other event unchanged.
static NSEvent *LeftClickWithoutControl(NSEvent *event) {
    NSEventType type=event.type;
    if((type!=NSEventTypeLeftMouseDown&&type!=NSEventTypeLeftMouseUp&&type!=NSEventTypeLeftMouseDragged)||!(event.modifierFlags&NSEventModifierFlagControl)) return event;
    return [NSEvent mouseEventWithType:type location:event.locationInWindow modifierFlags:event.modifierFlags&~NSEventModifierFlagControl
        timestamp:event.timestamp windowNumber:event.windowNumber context:nil eventNumber:event.eventNumber clickCount:event.clickCount pressure:event.pressure]?:event;
}

// Draws the rounded background and border, moves the window on drag, and routes double-clicks
// and context menus. Every press that is not on Stop reports its end to gestureEnded.
@interface CRDBackground : NSView
@property NSDictionary *config;
@property BOOL suppressBackground;
@property(copy) NSMenu *(^contextMenuProvider)(void);
// Views that act as the background for clicks: the caption, and the inline status mark outside dot layout.
@property(copy) BOOL (^passesThrough)(NSView *view);
// A double-click outside the exclusion rect (Stop plus a margin) runs this action.
@property(copy) void (^doubleClickAction)(NSEvent *);
@property(copy) void (^dragWillBegin)(void);
// Every press that is not on Stop reports its end (the mouse-up the tracking loop consumed) here.
@property(copy) void (^gestureEnded)(NSEvent *);
@property NSRect doubleClickExclusion;
@end
@implementation CRDBackground
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; } // The tracking loop below records its user origin.
// A press anywhere moves the window once it passes the drag threshold; an unmoved press stays a click.
- (void)mouseDown:(NSEvent *)event {
    NSEvent *up=nil;
    BOOL moved=TrackPress(self.window,event,[self.config[@"draggable"] boolValue],self.dragWillBegin,&up);
    if(self.gestureEnded) self.gestureEnded(up?:event);
    if(moved||event.clickCount<2||!self.doubleClickAction) return;
    if(NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.doubleClickExclusion)) return;
    self.doubleClickAction(up?:event);
}
- (NSView *)hitTest:(NSPoint)point {
    NSView *view=[super hitTest:point];
    return view&&view!=self&&self.passesThrough&&self.passesThrough(view)?self:view;
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    if(!OpensContextMenu(event)) return nil;
    return self.contextMenuProvider?self.contextMenuProvider():[super menuForEvent:event];
}
- (void)rightMouseDown:(NSEvent *)event {
    NSMenu *menu=[self menuForEvent:event];
    if(menu&&self.contextMenuProvider) PresentStopContextMenu(menu,event,self); else [super rightMouseDown:event];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirty {
    if(self.suppressBackground) return;
    CGFloat border = MIN([self.config[@"borderWidth"] doubleValue], MIN(self.bounds.size.width,self.bounds.size.height));
    NSRect r = NSInsetRect(self.bounds,border/2,border/2);
    CGFloat radius = MAX(0,MIN([self.config[@"radius"] doubleValue],MIN(r.size.width,r.size.height)/2));
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
    [Color(self.config[@"background"],@"background") setFill]; [path fill];
    if (border > 0) { [Color(self.config[@"accent"],@"accent") setStroke]; path.lineWidth=border; [path stroke]; }
}
@end
// Dedicated grips make drag/resize discoverable even with a borderless window.
@interface CRDDragHandle : NSView
@property NSDictionary *config;
@property BOOL resizeHandle;
@property(copy) NSMenu *(^contextMenuProvider)(void);
@property(copy) void (^gestureEnded)(NSEvent *); // Reports the end of each press, like CRDBackground.
@property(copy) void (^doubleClickAction)(NSEvent *); // A double-click that neither moved nor resized.
@end
@implementation CRDDragHandle
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    if(!OpensContextMenu(event)) return nil;
    return self.contextMenuProvider?self.contextMenuProvider():[super menuForEvent:event];
}
- (void)rightMouseDown:(NSEvent *)event {
    NSMenu *menu=[self menuForEvent:event];
    if(menu&&self.contextMenuProvider) PresentStopContextMenu(menu,event,self); else [super rightMouseDown:event];
}
- (void)resetCursorRects {
    BOOL enabled = [self.config[self.resizeHandle?@"resizable":@"draggable"] boolValue];
    if (enabled) [self addCursorRect:self.bounds cursor:self.resizeHandle?NSCursor.crosshairCursor:NSCursor.openHandCursor];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirty {
    CGFloat alpha=[self.config[@"handleOpacity"] doubleValue];
    BOOL enabled=[self.config[self.resizeHandle?@"resizable":@"draggable"] boolValue];
    [[NSColor.secondaryLabelColor colorWithAlphaComponent:enabled?alpha:alpha/2] setFill];
    [[NSColor.secondaryLabelColor colorWithAlphaComponent:enabled?alpha:alpha/2] setStroke];
    if (self.resizeHandle) {
        NSBezierPath *lines=[NSBezierPath bezierPath]; lines.lineWidth=1;
        for (CGFloat offset=2;offset<=8;offset+=3) {
            [lines moveToPoint:NSMakePoint(NSMaxX(self.bounds)-offset,2)];
            [lines lineToPoint:NSMakePoint(NSMaxX(self.bounds)-2,offset)];
        }
        [lines stroke];
    } else {
        CGFloat spacing=MIN(4,MIN(self.bounds.size.width,self.bounds.size.height)/3.5);
        CGFloat diameter=MAX(1.4,spacing/2);
        for (NSInteger col=0;col<2;col++) for (NSInteger row=0;row<3;row++) {
            NSRect dot=NSMakeRect(NSMidX(self.bounds)+(col-.5)*spacing-diameter/2,
                NSMidY(self.bounds)+(row-1)*spacing-diameter/2,diameter,diameter);
            [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        }
    }
}
// The move grip drags the window; the resize grip resizes it from the bottom-right corner,
// keeping the top edge fixed and the size within the window's min and max sizes. A double-click
// on either grip that neither moves nor resizes runs doubleClickAction, as on the background.
- (void)mouseDown:(NSEvent *)event {
    BOOL doubleClick=event.clickCount>=2&&self.doubleClickAction;
    if (!self.resizeHandle) {
        BOOL draggable=[self.config[@"draggable"] boolValue];
        if (draggable) [NSCursor.closedHandCursor push];
        NSEvent *up=nil; BOOL moved=NO;
        @try { moved=TrackPress(self.window,event,draggable,nil,&up); } @finally { if (draggable) [NSCursor pop]; }
        if (self.gestureEnded) self.gestureEnded(up?:event);
        if (doubleClick&&!moved) self.doubleClickAction(up?:event);
        return;
    }
    if (![self.config[@"resizable"] boolValue]) {
        NSEvent *up=nil; TrackPress(self.window,event,NO,nil,&up);
        if (self.gestureEnded) self.gestureEnded(up?:event);
        if (doubleClick) self.doubleClickAction(up?:event);
        return;
    }
    NSWindow *window=self.window; NSRect original=window.frame; NSPoint start=ScreenPoint(event);
    NSEvent *last=event; BOOL resizing=NO;
    @try {
        while (YES) {
            NSEvent *next=NextTrackingEvent();
            if (next) last=next;
            if (next.type==NSEventTypeLeftMouseUp || !next) break;
            if(next.type!=NSEventTypeLeftMouseDragged) continue;
            NSPoint current=ScreenPoint(next);
            if(!resizing) {
                if(!PassedDragThreshold(start,current)) continue;
                resizing=YES; BeginUserGeometry(window);
            }
            CGFloat width=MAX(window.minSize.width,MIN(window.maxSize.width,original.size.width+current.x-start.x));
            CGFloat height=MAX(window.minSize.height,MIN(window.maxSize.height,original.size.height-(current.y-start.y)));
            [window setFrame:NSMakeRect(original.origin.x,NSMaxY(original)-height,width,height) display:YES];
        }
    } @finally { if(resizing) EndUserGeometry(); if (self.gestureEnded) self.gestureEnded(last); }
    if (doubleClick&&!resizing) self.doubleClickAction(last);
}
@end

#pragma mark - Event log
// Local, bounded JSONL events. Reads occur only at startup, append or an expiry.
static const NSUInteger CRDLogMaxBytes=1024*1024;
static const NSTimeInterval CRDLogRetention=24*60*60;
static BOOL LoggingEnabled(void) { id value=currentConfig[@"loggingEnabled"]; return value?[value boolValue]:YES; }
// An append-only JSONL log of at most 1 MB that keeps 24 hours of events. The file is 0600 in a
// 0700 folder, shared through an flock'd .lock file, and compacted only when it changes outside
// this process, grows over the limit, or an entry expires.
@interface CRDEventLog : NSObject
@property NSString *path;
@property dispatch_source_t expiryTimer;
@property NSUInteger appendCount,maintenanceCount,fileReadCount,writeCount;
@property NSUInteger byteCount;
@property double expiryDeadline;
@property NSString *cachedSignature;
- (instancetype)initWithPath:(NSString *)path;
- (void)maintain;
- (void)append:(NSDictionary *)event enabled:(BOOL)enabled;
@end
@implementation CRDEventLog
- (instancetype)initWithPath:(NSString *)path { if((self=[super init])) { _path=[path copy]; _expiryDeadline=INFINITY; } return self; }
- (void)dealloc { if(_expiryTimer) dispatch_source_cancel(_expiryTimer); }
// Reads the last 1 MB of the log, drops a partial first line, and keeps records with a timestamp.
- (NSMutableArray *)readRecords {
    self.fileReadCount++;
    NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:self.path];
    if(!file) return [NSMutableArray array];
    NSData *data=nil;
    @try {
        unsigned long long size=[file seekToEndOfFile];
        unsigned long long offset=size>CRDLogMaxBytes?size-CRDLogMaxBytes:0;
        [file seekToFileOffset:offset]; data=[file readDataOfLength:CRDLogMaxBytes];
        if(offset&&data.length) {
            const char *bytes=(const char *)data.bytes; NSUInteger start=0;
            while(start<data.length&&bytes[start]!='\n') start++;
            data=start<data.length?[data subdataWithRange:NSMakeRange(start+1,data.length-start-1)]:NSData.data;
        }
    } @catch(NSException *exception) { data=nil; }
    [file closeFile];
    NSString *text=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
    NSMutableArray *records=[NSMutableArray array];
    for(NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if(!line.length) continue;
        id record=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if([record isKindOfClass:NSDictionary.class]&&[record[@"timestampSeconds"] isKindOfClass:NSNumber.class]) [records addObject:record];
    }
    return records;
}
// Keeps records newer than the retention window and not more than five minutes in the future.
- (NSMutableArray *)unexpired:(NSArray *)records now:(NSTimeInterval)now {
    NSMutableArray *kept=[NSMutableArray array];
    for(NSDictionary *record in records) {
        double time=[record[@"timestampSeconds"] doubleValue];
        if(std::isfinite(time)&&time>now-CRDLogRetention&&time<=now+300) [kept addObject:record];
    }
    return kept;
}
- (NSData *)boundedData:(NSMutableArray *)records {
    return [self boundedData:records limit:CRDLogMaxBytes];
}
// Serializes records as JSONL, dropping the oldest until the data fits the limit.
- (NSData *)boundedData:(NSMutableArray *)records limit:(NSUInteger)limit {
    NSMutableArray<NSData *> *lines=[NSMutableArray array]; NSUInteger total=0;
    for(NSDictionary *record in records) {
        NSData *line=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
        if(line) { [lines addObject:line]; total+=line.length+1; }
    }
    NSUInteger removed=0;
    while(total>limit&&removed<lines.count) { total-=[lines[removed] length]+1; removed++; }
    if(removed) [records removeObjectsInRange:NSMakeRange(0,MIN(removed,records.count))];
    NSMutableData *data=[NSMutableData dataWithCapacity:total];
    for(NSUInteger i=removed;i<lines.count;i++) { [data appendData:lines[i]]; [data appendBytes:"\n" length:1]; }
    return data;
}
// Atomically replaces the log file, enforcing 0700 on the folder and 0600 on the file.
- (void)write:(NSData *)data {
    NSString *directory=self.path.stringByDeletingLastPathComponent;
    NSError *error=nil;
    if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) return;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:directory error:nil];
    if([data writeToFile:self.path options:NSDataWritingAtomic error:&error]) {
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.path error:nil]; self.writeCount++;
    }
}
// Schedules the next maintenance at the oldest record's expiry.
- (void)scheduleExpiry:(NSArray *)records {
    double deadline=INFINITY;
    for(NSDictionary *record in records) deadline=MIN(deadline,[record[@"timestampSeconds"] doubleValue]+CRDLogRetention);
    [self scheduleDeadline:deadline];
}
// Arms a single wall-clock timer for the deadline; an infinite deadline cancels it.
- (void)scheduleDeadline:(double)deadline {
    if(std::isfinite(deadline)&&deadline==self.expiryDeadline&&self.expiryTimer) return;
    if(self.expiryTimer) { dispatch_source_cancel(self.expiryTimer); self.expiryTimer=nil; }
    self.expiryDeadline=deadline;
    if(!std::isfinite(deadline)) return;
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    self.expiryTimer=timer; __weak CRDEventLog *weakSelf=self;
    deadline=MAX(deadline,NSDate.date.timeIntervalSince1970+.01);
    struct timespec expiration={}; expiration.tv_sec=(time_t)std::floor(deadline);
    expiration.tv_nsec=(long)((deadline-std::floor(deadline))*NSEC_PER_SEC);
    dispatch_source_set_timer(timer,dispatch_walltime(&expiration,0),DISPATCH_TIME_FOREVER,10*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{ weakSelf.expiryDeadline=INFINITY; [weakSelf maintain]; }); dispatch_resume(timer);
}
// Takes the exclusive log lock file; returns its fd, or -1 when locking fails.
- (int)lock {
    NSString *path=[self.path stringByAppendingPathExtension:@"lock"];
    int fd=open(path.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC,0600);
    if(fd<0&&errno==ENOENT) {
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        fd=open(path.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC,0600);
    }
    if(fd>=0&&flock(fd,LOCK_EX)!=0) { close(fd); return -1; }
    return fd;
}
// Drops expired records, rewrites the file when it changed or exceeds the limit, and refreshes the cached size and signature.
- (void)compactTo:(NSUInteger)limit {
    self.maintenanceCount++;
    NSArray *before=[self readRecords]; NSMutableArray *kept=[self unexpired:before now:NSDate.date.timeIntervalSince1970];
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:self.path error:nil];
    BOOL oversized=[attributes[NSFileSize] unsignedLongLongValue]>limit;
    NSData *data=[self boundedData:kept limit:limit];
    if(kept.count!=before.count||oversized) [self write:data];
    self.byteCount=[[NSFileManager.defaultManager attributesOfItemAtPath:self.path error:nil][NSFileSize] unsignedIntegerValue];
    self.cachedSignature=PathSignature(self.path);
    [self scheduleExpiry:kept];
}
// Compacts the log under the lock.
- (void)maintain {
    int fd=[self lock]; if(fd<0) return;
    [self compactTo:CRDLogMaxBytes]; flock(fd,LOCK_UN); close(fd);
}
// Appends one event line under the lock, compacting first when the file changed elsewhere, an
// entry expired, or the line would push the file over 1 MB. A short write is truncated away.
- (void)append:(NSDictionary *)event enabled:(BOOL)enabled {
    if(!enabled) return; // No new file, append or write when logging is disabled.
    NSMutableData *line=[[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:nil] mutableCopy];
    if(!line) return; [line appendBytes:"\n" length:1];
    if(line.length>CRDLogMaxBytes) return;
    int lock=[self lock]; if(lock<0) return;
    NSString *signature=PathSignature(self.path);
    if(![signature isEqual:self.cachedSignature]||self.expiryDeadline<=NSDate.date.timeIntervalSince1970) [self compactTo:CRDLogMaxBytes];
    if(self.byteCount+line.length>CRDLogMaxBytes)
        [self compactTo:CRDLogMaxBytes-MAX(line.length,CRDLogMaxBytes/4)];
    int file=open(self.path.fileSystemRepresentation,O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC,0600);
    if(file>=0) {
        NSUInteger offset=0;
        while(offset<line.length) {
            ssize_t written=write(file,(const char *)line.bytes+offset,line.length-offset);
            if(written<0&&errno==EINTR) continue;
            if(written<=0) break;
            offset+=(NSUInteger)written;
        }
        if(offset==line.length) {
            self.appendCount++; self.writeCount++; self.byteCount+=offset;
            [self scheduleDeadline:MIN(self.expiryDeadline,[event[@"timestampSeconds"] doubleValue]+CRDLogRetention)];
        } else { ftruncate(file,(off_t)self.byteCount); }
        close(file); self.cachedSignature=PathSignature(self.path);
    }
    flock(lock,LOCK_UN); close(lock);
}
@end
static CRDEventLog *eventLog;
static NSDictionary *previousLoggedSettings,*previousLoggedState,*geometryPreviousSettings;
// The subset of settings recorded with each log event.
static NSDictionary *SettingsSnapshot(void) {
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"mode",@"shape",@"layout",@"placement",@"screen",@"x",@"y",@"width",@"height",@"radius",@"appearance",@"accent",@"dotColor",@"background",@"foreground",@"borderWidth",@"fontSize",@"dotDiameter",@"opacity",@"edgeInset",@"shadow",@"alwaysOnTop",@"draggable",@"resizable",@"constrainToScreen",@"showText",@"showStopButton",@"showDot",@"showHandle",@"handlePosition",@"handleSize",@"handleOpacity",@"loggingEnabled",@"enabled",@"stopRevealSeconds",@"stopStyle"]) {
        if(currentConfig[key]) snapshot[key]=currentConfig[key];
    }
    return snapshot;
}
// Logs a runtime event when settings or the tracked window state changed, or the event is explicit.
// The event kind is refined from what changed (lost window, restored original, mode change...).
// Fixture runs never log.
static void LogRuntimeEvent(NSString *event,NSDictionary *state) {
    if(fixtureMode||!eventLog) return;
    NSDictionary *settings=SettingsSnapshot();
    NSDictionary *beforeSettings=[event isEqual:@"geometry-saved"]&&geometryPreviousSettings?geometryPreviousSettings:previousLoggedSettings;
    BOOL changed=!previousLoggedState||![settings isEqual:beforeSettings];
    for(NSString *key in @[@"originalPid",@"originalWindowDetected",@"originalWindowGeneration",@"originalHidden",@"visible",@"frame",@"detectionReason",@"configReloadCount"]) {
        if(![state[key] isEqual:previousLoggedState[key]]) changed=YES;
    }
    BOOL explicitEvent=[event hasPrefix:@"context-menu-"]||[event hasPrefix:@"user-stop-"]||[event hasPrefix:@"stop-reveal-"]||[event hasPrefix:@"menu-"]||[event hasPrefix:@"settings-"]||[event isEqual:@"agent-stopped"]||[event isEqual:@"original-unexpectedly-shown"]||[event isEqual:@"original-hide-reapplied"];
    if(explicitEvent) changed=YES;
    if(changed) {
        NSString *kind=event;
        NSString *reason=state[@"detectionReason"]?:@"unknown";
        if([reason containsString:@"unavailable"]||[reason containsString:@"unknown"]||[reason containsString:@"unconfirmed"]) kind=@"ax-state-unavailable";
        if([reason isEqual:@"multiple-original-windows"]) kind=@"multiple-original-windows";
        if([previousLoggedState[@"originalHidden"] boolValue]&&![state[@"originalHidden"] boolValue]&&![event isEqual:@"original-unexpectedly-shown"]) kind=@"original-app-restored";
        if(previousLoggedState&&![state[@"configReloadCount"] isEqual:previousLoggedState[@"configReloadCount"]]) kind=@"settings-reloaded";
        if(previousLoggedState&&![state[@"originalWindowGeneration"] isEqual:previousLoggedState[@"originalWindowGeneration"]]) kind=@"sharing-window-detected-or-recreated";
        if([previousLoggedState[@"originalWindowDetected"] boolValue]&&![state[@"originalWindowDetected"] boolValue]) kind=@"sharing-window-lost";
        if(previousLoggedSettings&&![settings[@"mode"] isEqual:previousLoggedSettings[@"mode"]]) kind=@"mode-changed";
        if(explicitEvent||[event isEqual:@"geometry-saved"]) kind=event;
        static NSISO8601DateFormatter *formatter;
        static dispatch_once_t once; dispatch_once(&once,^{ formatter=[NSISO8601DateFormatter new]; formatter.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds; });
        NSDate *now=NSDate.date;
        NSMutableDictionary *record=[@{@"timestamp":[formatter stringFromDate:now],@"timestampSeconds":@(now.timeIntervalSince1970),@"event":kind?:@"state-changed",@"reason":state[@"detectionReason"]?:@"unknown",@"mode":settings[@"mode"]?:@"original",@"originalPid":state[@"originalPid"]?:NSNull.null,@"originalWindowDetected":state[@"originalWindowDetected"]?:@NO,@"originalWindowGeneration":state[@"originalWindowGeneration"]?:@0,@"originalHidden":state[@"originalHidden"]?:@NO,@"visible":state[@"visible"]?:@NO,@"previousSettings":beforeSettings?:NSNull.null,@"currentSettings":settings,@"previousFrame":previousLoggedState[@"frame"]?:NSNull.null,@"currentFrame":state[@"frame"]?:NSNull.null,@"frameCoordinateSpace":@"Cocoa global screen points, bottom-left origin",@"settingsCoordinateSpace":@"Selected NSScreen.visibleFrame top-left offsets, points"} mutableCopy];
        if(beforeSettings) { record[@"beforeMode"]=beforeSettings[@"mode"]?:@"original"; record[@"afterMode"]=settings[@"mode"]?:@"original"; }
        NSMutableArray *changes=[NSMutableArray array];
        if(beforeSettings&&![beforeSettings isEqual:settings]) [changes addObject:@"settings-changed"];
        if(beforeSettings&&![beforeSettings[@"mode"] isEqual:settings[@"mode"]]) [changes addObject:@"mode-changed"];
        if(previousLoggedState&&![state[@"originalPid"] isEqual:previousLoggedState[@"originalPid"]]) [changes addObject:@"original-process-changed"];
        if([previousLoggedState[@"originalHidden"] boolValue]&&![state[@"originalHidden"] boolValue]) [changes addObject:@"original-shown-or-restored"];
        if(![state[@"frame"] isEqual:previousLoggedState[@"frame"]]) [changes addObject:@"actual-frame-changed"];
        record[@"changes"]=changes;
        [eventLog append:record enabled:LoggingEnabled()];
    }
    previousLoggedSettings=[settings copy]; previousLoggedState=[state copy];
}

#pragma mark - Stop gesture gate
// Decides whether a mouse-down may press Stop.
// Temporary monitors complement native menu tracking for a nonactivating accessory panel.
// They exist only for the synchronous popup, and never inspect or retain input text.
// A reveal gesture cannot also choose Stop, even when a new window resets clickCount.
// Only event timestamps advance this gate; there is no idle timer or polling.
@interface CRDStopGestureGate : NSObject
@property NSTimeInterval blockedThrough;
@property BOOL rejectingMouseSequence;
- (BOOL)allowsMouseDown:(NSEvent *)event;
- (NSEvent *)filterEvent:(NSEvent *)event;
- (void)recordGesture:(NSEvent *)event;
- (void)blockFrom:(NSTimeInterval)timestamp;
@end
@implementation CRDStopGestureGate
// Any gesture that is not a press on Stop (its down and its mouse-up, including one a
// tracking loop consumed) keeps Stop closed for a further double-click interval, so a quick
// follow-up click that macOS reports as a fresh count-1 click cannot press Stop.
// Closes Stop for one double-click interval after this event.
- (void)recordGesture:(NSEvent *)event { if(event) [self blockFrom:event.timestamp]; }
- (void)blockFrom:(NSTimeInterval)timestamp { self.blockedThrough=MAX(self.blockedThrough,timestamp+NSEvent.doubleClickInterval); }
// Allows only a fresh single left click after the blocked interval. Any other press extends
// the block, so a double or late click of a reveal gesture can never press Stop.
- (BOOL)allowsMouseDown:(NSEvent *)event {
    BOOL fresh=event.type==NSEventTypeLeftMouseDown&&event.clickCount==1&&event.timestamp>self.blockedThrough;
    if(!fresh) self.blockedThrough=MAX(self.blockedThrough,event.timestamp+NSEvent.doubleClickInterval);
    return fresh;
}
// Drops both halves of a refused mouse sequence (down and its up) and extends the block on the up.
- (NSEvent *)filterEvent:(NSEvent *)event {
    if(event.type==NSEventTypeLeftMouseDown) self.rejectingMouseSequence=![self allowsMouseDown:event];
    if(event.type==NSEventTypeLeftMouseUp&&self.rejectingMouseSequence)
        self.blockedThrough=MAX(self.blockedThrough,event.timestamp+NSEvent.doubleClickInterval);
    if((event.type==NSEventTypeLeftMouseDown||event.type==NSEventTypeLeftMouseUp)&&self.rejectingMouseSequence) return nil;
    return event;
}
@end

#pragma mark - Context menu tracking
// Runs the status context menu from a nonactivating panel and restores focus afterwards.

// Tracks one open context menu: cancels it on Escape, on a click on app content or another app,
// or when the helper resigns active, and filters Stop selections through the menu's gate.
@interface CRDContextMenuTracking : NSObject
@property NSMenu *menu;
@property NSSet<NSWindow *> *contentWindows;
@property id localMonitor,globalMonitor,deactivationObserver;
@property BOOL active,clickedOutsideApplication,openingSettings;
@property CRDStopGestureGate *stopGestureGate;
@property BOOL stopSelectionArmed;
@property NSUInteger cancellationCount;
- (void)begin:(NSMenu *)menu;
- (void)end;
- (void)cancel;
- (NSEvent *)handleLocalEvent:(NSEvent *)event;
@end
@implementation CRDContextMenuTracking
// Installs the temporary local and global monitors and the deactivation observer.
- (void)begin:(NSMenu *)menu {
    self.menu=menu; self.active=YES;
    NSMutableSet *windows=[NSMutableSet set];
    for(NSWindow *window in NSApp.windows) if(window.visible) [windows addObject:window];
    self.contentWindows=windows;
    __weak CRDContextMenuTracking *weakSelf=self;
    NSEventMask mouse=NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskOtherMouseDown;
    self.localMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:mouse|NSEventMaskLeftMouseUp|NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event){ CRDContextMenuTracking *tracking=weakSelf; return tracking?[tracking handleLocalEvent:event]:event; }];
    // Global monitors receive only other applications' events, so menu-item clicks are excluded.
    self.globalMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:mouse handler:^(NSEvent *event){ weakSelf.clickedOutsideApplication=YES; [weakSelf cancel]; }];
    self.deactivationObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:NSApp queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){ [weakSelf cancel]; }];
}
// Filters local events while the menu is open. With a gate, a menu-item mouse-up counts only
// after its own accepted mouse-down, or after a separate Return, Enter or Space key press.
- (NSEvent *)handleLocalEvent:(NSEvent *)event {
    if(!self.active) return event;
    if(self.stopGestureGate) {
        if(![self.stopGestureGate filterEvent:event]) { self.stopSelectionArmed=NO; return nil; }
        if(event.type==NSEventTypeLeftMouseDown) self.stopSelectionArmed=YES;
        if(event.type==NSEventTypeLeftMouseUp&&!self.stopSelectionArmed) return nil;
        if(event.type==NSEventTypeKeyDown&&!event.isARepeat&&(event.keyCode==36||event.keyCode==76||event.keyCode==49))
            self.stopSelectionArmed=YES; // A separate Return/Enter/Space selection is deliberate.
    }
    if(event.type==NSEventTypeKeyDown) {
        if(event.keyCode==53) { [self cancel]; return nil; } // Escape, without examining typed text.
        return event;
    }
    // Menu tracking windows appear after begin; pre-existing visible windows are app content.
    // Unknown windows are left to AppKit rather than cancelling a valid menu-item selection.
    if(event.type!=NSEventTypeLeftMouseUp&&event.window&&[self.contentWindows containsObject:event.window]) [self cancel];
    return event;
}
- (void)cancel {
    if(!self.active) return;
    self.cancellationCount++; [self.menu cancelTracking];
}
// Removes every monitor and observer and forgets the menu.
- (void)end {
    self.active=NO;
    if(self.localMonitor) [NSEvent removeMonitor:self.localMonitor];
    if(self.globalMonitor) [NSEvent removeMonitor:self.globalMonitor];
    if(self.deactivationObserver) [NSNotificationCenter.defaultCenter removeObserver:self.deactivationObserver];
    self.localMonitor=nil; self.globalMonitor=nil; self.deactivationObserver=nil;
    self.contentWindows=nil; self.menu=nil;
}
@end
static CRDContextMenuTracking *activeContextMenu;
// The inline Stop's gate. Non-Stop gestures, menus and setting changes that move or
// show it keep it closed for a double-click interval; Stop then needs a separate later click.
static CRDStopGestureGate *inlineStopGate;
static void BlockInlineStop(void) { [inlineStopGate blockFrom:NSProcessInfo.processInfo.systemUptime]; }
static void (^fixtureActivatePrevious)(NSRunningApplication *);
static void (^fixtureOpenSettings)(NSURL *);
// Records a context menu the self-test would open; the isolated self-test never shows a menu.
static void (^fixturePresentMenu)(NSMenu *,NSEvent *,NSView *);
// Reactivates the app that was frontmost before the menu, unless the menu opened the settings
// app, the closing click went to another app, or focus already moved elsewhere.
static void RestorePreviousApplication(CRDContextMenuTracking *tracking,NSRunningApplication *previous,BOOL helperActive,pid_t frontmost) {
    if(!previous||tracking.openingSettings||tracking.clickedOutsideApplication||!helperActive||frontmost!=getpid()||previous.processIdentifier==getpid()||previous.terminated) return;
    if(fixtureMode) { if(fixtureActivatePrevious) fixtureActivatePrevious(previous); }
    else [previous activateWithOptions:0];
}
// Opens the settings app, launching it with --show-settings when it is not running yet.
static void OpenSettingsApplication(NSURL *target) {
    if(!target) return;
    activeContextMenu.openingSettings=YES; // This selection intentionally changes the foreground app.
    if(fixtureMode) { if(fixtureOpenSettings) fixtureOpenSettings(target); return; }
    BOOL alreadyRunning=NO;
    for(NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) if([application.bundleURL.path isEqual:target.path]) { alreadyRunning=YES; break; }
    if(alreadyRunning) {
        if(![NSWorkspace.sharedWorkspace openURL:target]) activeContextMenu.openingSettings=NO;
    } else {
        NSWorkspaceOpenConfiguration *configuration=NSWorkspaceOpenConfiguration.configuration;
        configuration.arguments=@[@"--show-settings"];
        [NSWorkspace.sharedWorkspace openApplicationAtURL:target configuration:configuration completionHandler:nil];
    }
}
// Shows a context menu for an overlay view. The app activates for native menu tracking, the
// inline Stop is blocked when the menu closes, and the previous app gets focus back.
static void PresentStopContextMenu(NSMenu *menu,NSEvent *event,NSView *view,CRDStopGestureGate *gate) {
    if(fixtureMode) { if(menu&&fixturePresentMenu) fixturePresentMenu(menu,event,view); return; }
    if(!menu||!view.window) return;
    [activeContextMenu cancel];
    NSRunningApplication *previousApplication=NSWorkspace.sharedWorkspace.frontmostApplication;
    // Native tracking needs an active application even though the overlay panel never becomes key.
    [NSApp activateIgnoringOtherApps:YES];
    CRDContextMenuTracking *tracking=[CRDContextMenuTracking new]; tracking.stopGestureGate=gate; activeContextMenu=tracking;
    [tracking begin:menu]; WriteRuntimeStatus(@"context-menu-opened",nil);
    @try {
        if(event) [NSMenu popUpContextMenu:menu withEvent:event forView:view];
        else [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMidX(view.bounds),NSMidY(view.bounds)) inView:view];
    } @finally {
        [tracking end]; if(activeContextMenu==tracking) activeContextMenu=nil;
        BlockInlineStop(); // A click that closed the menu may land on a Stop that is now under the pointer.
        WriteRuntimeStatus(tracking.clickedOutsideApplication?@"context-menu-closed-outside":@"context-menu-closed",nil);
        // An outside click belongs to its destination; never move focus away from it.
        RestorePreviousApplication(tracking,previousApplication,NSApp.active,NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    }
}

#pragma mark - Status dot and window state
// The status mark, the overlay's view references, and the screen it uses.

// The status mark. In dot layout it draws a geometric dot and owns the window-drag gesture.
@interface CRDStatusDot : NSTextField
@property BOOL windowDragEnabled,geometricDot;
@property CGFloat dotDiameter;
@property(copy) void (^doubleClickAction)(NSEvent *);
@property(copy) void (^dragWillBegin)(void);
@property(copy) void (^gestureEnded)(NSEvent *); // Reports the end of each press, like CRDBackground.
@property(copy) NSMenu *(^contextMenuProvider)(void);
@property CRDStopGestureGate *stopGestureGate;
- (NSRect)geometricDotRect;
@end
@implementation CRDStatusDot
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
// The dot's circle, centered and no larger than the view.
- (NSRect)geometricDotRect {
    CGFloat diameter=MAX(0,MIN(self.dotDiameter,MIN(self.bounds.size.width,self.bounds.size.height)));
    return NSMakeRect(NSMidX(self.bounds)-diameter/2,NSMidY(self.bounds)-diameter/2,diameter,diameter);
}
- (void)drawRect:(NSRect)dirty {
    if(!self.geometricDot) { [super drawRect:dirty]; return; }
    [self.textColor setFill]; [[NSBezierPath bezierPathWithOvalInRect:self.geometricDotRect] fill];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self setNeedsDisplay:YES]; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
// The same tracking loop as the background. The double-click action runs only after the
// second press ends without moving, so its mouse-up can never reach a new control.
- (void)mouseDown:(NSEvent *)event {
    if(!self.geometricDot) return;
    NSEvent *up=nil;
    BOOL moved=TrackPress(self.window,event,self.windowDragEnabled,self.dragWillBegin,&up);
    if(self.gestureEnded) self.gestureEnded(up?:event);
    if(moved) return;
    if(event.clickCount>=2&&self.doubleClickAction) self.doubleClickAction(up?:event);
}
- (NSMenu *)menuForEvent:(NSEvent *)event { return OpensContextMenu(event)&&self.geometricDot&&self.contextMenuProvider?self.contextMenuProvider():nil; }
- (void)rightMouseDown:(NSEvent *)event {
    NSMenu *menu=[self menuForEvent:event];
    if(menu) PresentStopContextMenu(menu,event,self,self.stopGestureGate);
}
@end
// References to the overlay window's views and controller.
@interface CRDWindowState : NSObject
@property CRDBackground *customView;
@property NSTextField *label;
@property CRDStatusDot *dot;
@property NSButton *stop;
@property CRDDragHandle *handle,*resizeHandle;
@property NSString *message;
@property NSWindowController *controller;
@property BOOL shown;
@end
@implementation CRDWindowState
@end
static CRDWindowState *overlay;
// The configured screen, or the first screen when the index is out of range.
static NSScreen *SelectedScreen(NSDictionary *d) {
    NSArray *screens = NSScreen.screens; NSInteger index = [d[@"screen"] integerValue];
    return index >= 0 && index < (NSInteger)screens.count ? screens[index] : screens.firstObject;
}

#pragma mark - Stop pill
// The one Stop shape the helper draws everywhere: the inline Stop of the bar, capsule, compact and
// card shapes, and the Stop in the capsule a double-click opens. The stopStyle setting picks its
// colors: "red" is white semibold text on a red pill, "gray" is red semibold text on a grey pill.
// Both styles share every metric. The accent color never tints it. HelperOverlayLayout and StopPill
// in the settings app use the same metrics and colors.

// Text padding inside the pill. A short window may take the vertical padding down to its minimum,
// and a row that needs room for the dot the horizontal padding down to its minimum.
static const CGFloat CRDPillPaddingX=16,CRDPillPaddingY=7,CRDPillMinimumPaddingX=10,CRDPillMinimumPaddingY=2;
static NSColor *StopPillSRGB(uint32_t hex) { return [NSColor colorWithSRGBRed:((hex>>16)&0xFF)/255.0 green:((hex>>8)&0xFF)/255.0 blue:(hex&0xFF)/255.0 alpha:1]; }
// A color that resolves to `light` or `dark` with the appearance it is drawn in.
static NSColor *StopPillDynamic(uint32_t light,uint32_t dark) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL isDark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return StopPillSRGB(isDark?dark:light);
    }];
}
// True for the grey style; any other value draws the red style.
static BOOL StopPillIsGray(NSString *style) { return [style isEqual:@"gray"]; }
// #D93036 in light and dark. White text on it measures 4.74:1.
static NSColor *StopPillRed(void) { return StopPillSRGB(0xD93036); }
// The pill's fill. Red: red, a darker red while pressed, a faded red when disabled.
// Gray: #DCDCE0 in light and #3A3A3C in dark, a step darker while pressed, faded when disabled.
static NSColor *StopPillFill(NSString *style,BOOL enabled,BOOL pressed) {
    if(StopPillIsGray(style)) {
        NSColor *fill=pressed&&enabled?StopPillDynamic(0xCDCDD2,0x2C2C2E):StopPillDynamic(0xDCDCE0,0x3A3A3C);
        return enabled?fill:[fill colorWithAlphaComponent:.5];
    }
    if(!enabled) return [StopPillRed() colorWithAlphaComponent:.38];
    return pressed?StopPillSRGB(0xB22429):StopPillRed();
}
// The title color. Red: white. Gray: #B0201F in light (5.0:1 on its fill) and #FF8E87 in dark
// (5.1:1), a deeper red while pressed in light. Both fade when Stop is disabled.
static NSColor *StopPillTitleColor(NSString *style,BOOL enabled,BOOL pressed) {
    if(StopPillIsGray(style)) {
        NSColor *text=pressed&&enabled?StopPillDynamic(0x9E1C16,0xFF8E87):StopPillDynamic(0xB0201F,0xFF8E87);
        return enabled?text:[text colorWithAlphaComponent:.45];
    }
    return [NSColor.whiteColor colorWithAlphaComponent:enabled?1:.72];
}
static NSFont *StopPillFont(CGFloat size) { return [NSFont systemFontOfSize:size weight:NSFontWeightSemibold]; }
// One line of pill text, from ascender to descender, rounded up.
static CGFloat StopPillLineHeight(NSFont *font) { return ceil(font.ascender-font.descender); }
// The pill's natural size: the title plus 16 pt on each side and 7 pt above and below.
static NSSize StopPillSize(NSString *title,NSFont *font) {
    CGFloat text=ceil([title?:@"" sizeWithAttributes:@{NSFontAttributeName:font}].width);
    return NSMakeSize(text+2*CRDPillPaddingX,StopPillLineHeight(font)+2*CRDPillPaddingY);
}
// The lowest pill that still shows its text: 2 pt above and below the line.
static CGFloat StopPillMinimumHeight(NSFont *font) { return StopPillLineHeight(font)+2*CRDPillMinimumPaddingY; }
// The narrowest pill that keeps its whole title: 10 pt at each side.
static CGFloat StopPillCompactWidth(NSString *title,NSFont *font) { return ceil([title?:@"" sizeWithAttributes:@{NSFontAttributeName:font}].width)+2*CRDPillMinimumPaddingX; }
// Gives a Stop button its title, semibold font and style. The button draws the pill itself
// (CRDSessionStopButton), so it has no bezel, and its title stays its accessibility label.
static void StyleStopPill(NSButton *button,NSString *title,CGFloat size,NSString *style);

#pragma mark - Placement and layout
// Placement on screen and the arrangement of the overlay's controls.

// The placement a preset is saved with must be reachable on the display it will use, even
// with constrainToScreen off, and must stay so across later reloads. Returns the changes (a valid
// screen, or a custom position clamped inside that screen's visible frame) for the same locked write.
// Positions are measured from the visible frame's top-left, as ApplyOverlay places them.
static NSDictionary *ReachablePlacement(NSDictionary *d,NSArray<NSValue *> *visibleFrames) {
    if(!visibleFrames.count) return @{};
    NSInteger index=[d[@"screen"] integerValue]; BOOL valid=index>=0&&index<(NSInteger)visibleFrames.count;
    NSSize visible=visibleFrames[valid?index:0].rectValue.size;
    CGFloat width=[d[@"width"] doubleValue],height=[d[@"height"] doubleValue],inset=[d[@"edgeInset"] doubleValue];
    NSString *placement=d[@"placement"];
    CGFloat x=(visible.width-width)/2,y=(visible.height-height)/2;
    if([placement isEqual:@"top"]) y=inset;
    else if([placement isEqual:@"bottom"]) y=visible.height-inset-height;
    else if([placement isEqual:@"custom"]) { x=[d[@"x"] doubleValue]; y=[d[@"y"] doubleValue]; }
    CGFloat cx=MAX(0,MIN(x,visible.width-width)),cy=MAX(0,MIN(y,visible.height-height));
    NSMutableDictionary *changes=[NSMutableDictionary dictionary];
    if(!valid) changes[@"screen"]=@0;
    if(fabs(cx-x)>.01||fabs(cy-y)>.01) { changes[@"placement"]=@"custom"; changes[@"x"]=@(cx); changes[@"y"]=@(cy); }
    return changes;
}
// Visible frames of all screens, in NSScreen order.
static NSArray<NSValue *> *VisibleFrames(void) {
    NSMutableArray *frames=[NSMutableArray array];
    for(NSScreen *screen in NSScreen.screens) [frames addObject:[NSValue valueWithRect:screen.visibleFrame]];
    return frames;
}
static BOOL SettingsEnabled(void) { id enabled=currentConfig[@"enabled"]; return enabled?[enabled boolValue]:YES; }
// The active mode: "original" when the helper is disabled, else the configured mode.
static NSString *EffectiveMode(void) { return SettingsEnabled()?(currentConfig[@"mode"]?:@"original"):@"original"; }
static BOOL Custom(void) { return ![EffectiveMode() isEqual:@"original"]; }
// The schema's minimum (index 0) or maximum (index 1) window size.
static NSSize NumericWindowLimit(NSUInteger index) {
    NSDictionary *ranges = Schema()[@"numericLimits"];
    return NSMakeSize([ranges[@"width"][index] doubleValue], [ranges[@"height"][index] doubleValue]);
}
// Keeps the grip inside rounded corners (1 - 1/sqrt(2) of the radius reaches the arc).
// A full capsule end (radius at half the height) gets 3 pt more, so the ticks clear the curve.
// HelperOverlayLayout in the settings app uses the same rule.
static CGFloat GripInset(NSDictionary *d,CGFloat w,CGFloat h) {
    CGFloat corner=MAX(0,MIN([d[@"radius"] doubleValue],MIN(w,h)/2));
    return round(corner*0.293)+(corner>0&&corner>=MIN(w,h)/2-.5?3:0);
}
// Lays out the grips, status mark, caption and Stop button for the current configuration.
// Dot layout fills the window with the dot; column layout stacks Stop, dot and caption; the bar
// layout places them in a row. A control is shown only when its minimum usable size fits.
static void Layout(CRDWindowState *s) {
    NSDictionary *d=currentConfig; NSRect b=s.customView.bounds;
    CGFloat w=b.size.width,h=b.size.height;
    BOOL dotLayout=[d[@"layout"] isEqual:@"dot"];
    s.dot.geometricDot=dotLayout;
    s.dot.dotDiameter=[d[@"dotDiameter"] doubleValue];
    s.dot.windowDragEnabled=dotLayout&&[d[@"draggable"] boolValue];
    s.dot.accessibilityLabel=L(@"상태 점");
    // The tooltip explains the double-click that opens the Stop capsule on every shape. In dot layout
    // the dot covers the window and carries it; otherwise the background does.
    NSString *doubleClickHint=L(@"두 번 클릭하면 공유 중지 버튼이 나타나고, 다시 두 번 클릭하면 원래 모양으로 돌아갑니다");
    s.dot.toolTip=dotLayout?doubleClickHint:nil;
    s.customView.toolTip=doubleClickHint;
    [s.dot setNeedsDisplay:YES];
    s.handle.config=s.resizeHandle.config=d;
    s.handle.hidden=YES; s.resizeHandle.hidden=YES;
    s.handle.frame=s.resizeHandle.frame=NSZeroRect;
    CGFloat handleSize=[d[@"handleSize"] doubleValue], handleGap=4;
    CGFloat handleLeft=0,handleRight=0,handleTop=0;
    if (!dotLayout && [d[@"showHandle"] boolValue] && w>=handleSize && h>=handleSize) {
        s.handle.hidden=NO; NSString *position=d[@"handlePosition"];
        if ([position isEqual:@"top"]) {
            s.handle.frame=NSMakeRect((w-handleSize)/2,h-handleSize-2,handleSize,handleSize);
            handleTop=handleSize+handleGap;
        } else if ([position isEqual:@"trailing"]) {
            s.handle.frame=NSMakeRect(w-handleSize-2,(h-handleSize)/2,handleSize,handleSize);
            handleRight=handleSize+handleGap;
        } else {
            s.handle.frame=NSMakeRect(2,(h-handleSize)/2,handleSize,handleSize);
            handleLeft=handleSize+handleGap;
        }
    }
    if (!dotLayout && [d[@"resizable"] boolValue] && w>=80 && h>=24) {
        CGFloat inset=GripInset(d,w,h);
        s.resizeHandle.hidden=NO; s.resizeHandle.frame=NSMakeRect(w-11-inset,inset,11,11);
    }
    [s.handle setNeedsDisplay:YES]; [s.resizeHandle setNeedsDisplay:YES];
    [s.handle.window invalidateCursorRectsForView:s.handle]; [s.resizeHandle.window invalidateCursorRectsForView:s.resizeHandle];
    CGFloat font=[d[@"fontSize"] doubleValue]; if (font==0) font=NSFont.systemFontSize;
    CGFloat line=ceil([NSFont systemFontOfSize:font].ascender-[NSFont systemFontOfSize:font].descender)+4;
    CGFloat pad=MIN(12,MIN(w,h)/4), gap=8, dotWidth=MAX(12,font+4);
    s.customView.config=d;
    s.label.font=s.dot.font=[NSFont systemFontOfSize:font];
    s.label.stringValue=ConfiguredText(d[@"text"],@"text",@"화면을 공유하고 있습니다");
    s.label.textColor=Color(d[@"foreground"],@"foreground");
    s.dot.textColor=DotColor(d);
    StyleStopPill(s.stop,ConfiguredText(d[@"buttonText"],@"buttonText",@"공유 중지"),font,d[@"stopStyle"]);
    // The pill's natural size, at least 36 x 24 pt. A short window lowers it to its minimum height.
    NSSize pill=StopPillSize(s.stop.title,s.stop.font);
    CGFloat buttonW=MAX(36,pill.width), buttonH=MAX(24,pill.height), minimumButtonH=MAX(24,StopPillMinimumHeight(s.stop.font));
    s.label.hidden=s.dot.hidden=s.stop.hidden=YES;
    s.label.frame=s.dot.frame=s.stop.frame=NSZeroRect;
    NSString *layout=d[@"layout"];
    if ([layout isEqual:@"dot"]) {
        if ([d[@"showDot"] boolValue] && w>0 && h>0) {
            s.dot.hidden=NO; s.dot.alignment=NSTextAlignmentCenter;
            s.dot.frame=b; // The whole background remains a drag target, even for a tiny point.
        }
    } else if ([layout isEqual:@"column"]) {
        // A top handle sits in the top padding instead of adding to it.
        CGFloat inner=MAX(0,w-2*pad-handleLeft-handleRight), top=h-(handleTop>0?MAX(pad,handleTop+2):pad);
        CGFloat centerX=handleLeft+(w-handleLeft-handleRight)/2;
        // Keep the real stop action visible whenever its minimum usable area fits.
        buttonH=MAX(minimumButtonH,MIN(buttonH,h-2*pad));
        if ([d[@"showStopButton"] boolValue] && inner>=36 && h>=buttonH+2*pad) {
            s.stop.hidden=NO; buttonW=MIN(buttonW,inner);
            s.stop.frame=NSMakeRect(centerX-buttonW/2,pad,buttonW,buttonH);
        }
        CGFloat floor=s.stop.hidden?pad:NSMaxY(s.stop.frame)+gap;
        if ([d[@"showDot"] boolValue] && inner>=dotWidth && top-floor>=line) {
            s.dot.hidden=NO; s.dot.alignment=NSTextAlignmentCenter;
            s.dot.frame=NSMakeRect(centerX-dotWidth/2,top-line,dotWidth,line); top-=line+gap;
        }
        if ([d[@"showText"] boolValue] && inner>=12 && top-floor>=line) {
            s.label.hidden=NO; s.label.alignment=NSTextAlignmentCenter;
            s.label.frame=NSMakeRect(pad+handleLeft,top-line,inner,line);
        }
    } else {
        CGFloat left=pad+handleLeft,right=w-pad-handleRight;
        CGFloat availableHeight=h-handleTop;
        buttonH=MAX(minimumButtonH,MIN(buttonH,availableHeight));
        // The stop button stays clear of the grip when their heights overlap.
        if (!s.resizeHandle.hidden && (availableHeight-buttonH)/2<NSMaxY(s.resizeHandle.frame)+1)
            right=MIN(right,NSMinX(s.resizeHandle.frame)-2);
        if ([d[@"showStopButton"] boolValue] && availableHeight>=buttonH && right-left>=36) {
            // A tight row narrows the pill's side padding before it gives up the dot beside it.
            if ([d[@"showDot"] boolValue] && availableHeight>=line) buttonW=MIN(buttonW,MAX(StopPillCompactWidth(s.stop.title,s.stop.font),right-left-dotWidth-gap));
            buttonW=MIN(buttonW,right-left); s.stop.hidden=NO;
            s.stop.frame=NSMakeRect(right-buttonW,(availableHeight-buttonH)/2,buttonW,buttonH); right-=buttonW+gap;
        }
        if ([d[@"showDot"] boolValue] && availableHeight>=line && right-left>=dotWidth) {
            s.dot.hidden=NO; s.dot.alignment=NSTextAlignmentCenter;
            s.dot.frame=NSMakeRect(left,(availableHeight-line)/2,dotWidth,line); left+=dotWidth+gap;
        }
        if ([d[@"showText"] boolValue] && availableHeight>=line && right-left>=12) {
            s.label.hidden=NO; s.label.alignment=NSTextAlignmentLeft;
            s.label.frame=NSMakeRect(left,(availableHeight-line)/2,right-left,line);
        }
    }
    [s.customView setNeedsDisplay:YES];
}

#pragma mark - User move and resize tracking
// The helper's own drag loop and the bookkeeping that saves user geometry.

// Starts a new geometry generation, so pending user geometry is discarded.
static void InvalidateGeometry(void) {
    geometryGeneration++; geometryDirty=NO; userGeometryTracking=NO;
}
static void BeginUserGeometry(NSWindow *window) { userGeometryTracking=window==overlay.controller.window; }
static void EndUserGeometry(void) { userGeometryTracking=NO; }
// The helper's own move loop. The window server never drags the panel, so macOS
// tiling and top-edge arrangement never apply. Fixtures feed events without a real mouse.
static NSEvent *(^fixtureNextTrackingEvent)(void);
// Remote clients can shift either coordinate by up to 4 pt during a click.
// Move and resize start only beyond that tolerance, including on a double-click.
static const CGFloat CRDDragThreshold=4;
static BOOL PassedDragThreshold(NSPoint start,NSPoint current) {
    return MAX(fabs(current.x-start.x),fabs(current.y-start.y))>CRDDragThreshold;
}
// Next drag or mouse-up event; fixtures supply events, and self-tests never wait for real input.
static NSEvent *NextTrackingEvent(void) {
    if(fixtureNextTrackingEvent) return fixtureNextTrackingEvent();
    if(fixtureMode) return nil; // Never wait for real input inside the isolated self-test.
    return [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];
}
// The event location in global screen coordinates.
static NSPoint ScreenPoint(NSEvent *event) {
    return event.window?[event.window convertPointToScreen:event.locationInWindow]:event.locationInWindow;
}
// The screen containing a point, or the fallback.
static NSScreen *ScreenAtPoint(NSPoint point,NSScreen *fallback) {
    for(NSScreen *screen in NSScreen.screens) if(NSPointInRect(point,screen.frame)) return screen;
    return fallback;
}
// Offsets a frame by the pointer movement, clamped inside the visible frame when constrained.
static NSRect MovedFrame(NSRect start,NSPoint from,NSPoint to,NSRect visible,BOOL constrain) {
    NSRect frame=start; frame.origin.x+=to.x-from.x; frame.origin.y+=to.y-from.y;
    if(constrain&&!NSIsEmptyRect(visible)) {
        frame.origin.x=MAX(NSMinX(visible),MIN(frame.origin.x,NSMaxX(visible)-frame.size.width));
        frame.origin.y=MAX(NSMinY(visible),MIN(frame.origin.y,NSMaxY(visible)-frame.size.height));
    }
    return frame;
}
// Consumes the press through its mouse-up. Returns YES only when it moved the window; a press
// that never passes the threshold (or any press while the position is locked) stays a click.
static BOOL TrackPress(NSWindow *window,NSEvent *down,BOOL canMove,void (^willMove)(void),NSEvent **upOut) {
    NSPoint from=ScreenPoint(down); NSRect start=window.frame; BOOL moving=NO; NSEvent *up=nil;
    @try {
        while(YES) {
            NSEvent *next=NextTrackingEvent();
            if(!next||next.type==NSEventTypeLeftMouseUp) { up=next; break; }
            if(next.type!=NSEventTypeLeftMouseDragged||!window) continue;
            NSPoint to=ScreenPoint(next);
            if(!moving) {
                if(!canMove||!PassedDragThreshold(from,to)) continue;
                moving=YES; if(willMove) willMove(); BeginUserGeometry(window);
            }
            NSScreen *screen=ScreenAtPoint(to,window.screen?:SelectedScreen(currentConfig));
            [window setFrameOrigin:MovedFrame(start,from,to,screen.visibleFrame,[currentConfig[@"constrainToScreen"] boolValue]).origin];
        }
    } @finally { if(moving) EndUserGeometry(); }
    if(upOut) *upOut=up;
    return moving;
}
// True for a size that neither the configuration nor the helper's own grip produced.
static BOOL SystemResized(NSWindow *window) {
    if(applying||userGeometryTracking||!window||!currentConfig) return NO;
    NSSize size=window.frame.size;
    return fabs(size.width-[currentConfig[@"width"] doubleValue])>.5||fabs(size.height-[currentConfig[@"height"] doubleValue])>.5;
}
// Saves the captured user geometry to config.json as a custom position (and a custom shape when
// the size changed), only in custom mode, and records a geometry-saved event. A busy lock keeps
// that captured frame dirty for a later attempt; shutdown makes only one attempt.
static void ScheduleGeometry(CRDWindowState *s);
static void PersistGeometry(CRDWindowState *s,BOOL retry=YES) {
    if (!geometryDirty || previewMode || applying || !Custom() || !s.shown || !s.controller) return;
    // Capture at the user event, not at flush time: WindowServer can move a window later.
    NSRect f=geometryFrame,visible=geometryVisibleFrame; BOOL busy=NO;
    NSDictionary *d=UpdateConfig(^(NSMutableDictionary *latest){
        if(![latest[@"mode"] isEqual:@"custom"]) return;
        if(geometryScreenIndex!=NSNotFound) latest[@"screen"]=@(geometryScreenIndex);
        latest[@"x"]=@(f.origin.x-visible.origin.x); latest[@"y"]=@(NSMaxY(visible)-NSMaxY(f));
        if([currentConfig[@"width"] doubleValue]!=f.size.width||[currentConfig[@"height"] doubleValue]!=f.size.height) {
            latest[@"width"]=@(f.size.width); latest[@"height"]=@(f.size.height); latest[@"shape"]=@"custom";
        }
        latest[@"placement"]=@"custom";
    },&busy);
    if (d) {
        geometryDirty=NO;
        // Preserve the prior settings before replacing the committed geometry.
        geometryPreviousSettings=SettingsSnapshot();
        currentConfig=[d copy]; lastConfigData=ReadData(nil); lastObservedSignature=FileSignature(); lastConfigReloadDate=NSDate.date;
        WriteRuntimeStatus(@"geometry-saved",s.controller); geometryPreviousSettings=nil;
    } else if(busy&&retry) ScheduleGeometry(s);
}
// Coalesces pending geometry and retries lock contention without waiting on the main thread.
// There is no scheduled work once geometry is saved, invalidated, or the helper exits.
static void ScheduleGeometry(CRDWindowState *s) {
    NSUInteger generation=++geometryGeneration;
    __weak CRDWindowState *weakState=s;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(generation==geometryGeneration) { CRDWindowState *state=weakState; if(state) PersistGeometry(state); }
    });
}
// Captures the frame after a user move or resize and saves it 150 ms later, once the gesture settles.
static void SaveGeometry(CRDWindowState *s) {
    // Only the helper's move loop and grip produce user geometry, never a live system resize.
    if (previewMode || applying || !Custom() || !s.shown || !userGeometryTracking) return;
    NSScreen *screen=s.controller.window.screen?:SelectedScreen(currentConfig);
    if(!screen) return;
    geometryDirty=YES; geometryFrame=s.controller.window.frame; geometryVisibleFrame=screen.visibleFrame;
    geometryScreenIndex=[NSScreen.screens indexOfObject:screen];
    ScheduleGeometry(s);
}

#pragma mark - Configuration reload and file watching
// Reloads config.json when it changes on disk and keeps watchers on the file and its folders.

// Reloads config.json on the main thread when its signature changed. An unreadable or invalid
// file keeps the last valid configuration; a valid one is applied and reconciled.
void CRDReload(void) {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{ CRDReload(); }); return; }
    NSString *signature=FileSignature();
    if(!signature || [signature isEqual:lastObservedSignature]) return;
    NSData *data=ReadData(nil); lastObservedSignature=signature;
    // A missing/partially replaced file keeps the last valid configuration.
    if(!data || [data isEqual:lastConfigData]) return;
    NSString *error; NSDictionary *d=ParseData(data,&error);
    lastConfigData=data;
    if(!d) { NSLog(@"CRDOverlayAgent: retaining previous valid configuration: %@",error); return; }
    BOOL needsAX=![d[@"mode"] isEqual:currentConfig[@"mode"]]||![d[@"enabled"] isEqual:currentConfig[@"enabled"]];
    currentConfig=d; lastConfigReloadDate=NSDate.date; configReloadCount++;
    ApplyOverlay(YES); ReconcileFromConfig(needsAX);
}
static void StartWatchers(void);
// Coalesces change notifications into one reload 80 ms later.
static void ScheduleReload(void) {
    if(reloadPending) return;
    reloadPending=YES; NSUInteger generation=++reloadGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(generation!=reloadGeneration) return;
        reloadPending=NO; CRDReload();
    });
}
// Watches a path for writes, deletes, renames and revokes; each event rearms watchers and may reload.
static dispatch_source_t WatchPath(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_EVTONLY|O_CLOEXEC); if(fd<0) return nil;
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,
        DISPATCH_VNODE_WRITE|DISPATCH_VNODE_DELETE|DISPATCH_VNODE_RENAME|DISPATCH_VNODE_REVOKE,
        dispatch_get_main_queue());
    if(!source) { close(fd); return nil; }
    __weak dispatch_source_t weakSource=source;
    dispatch_source_set_event_handler(source,^{
        dispatch_source_t strongSource=weakSource; if(!strongSource) return;
        StartWatchers();
        NSString *signature=FileSignature();
        if(signature&&![signature isEqual:lastObservedSignature]) ScheduleReload();
    });
    dispatch_source_set_cancel_handler(source,^{ close(fd); });
    dispatch_resume(source); return source;
}
// Watches config.json, its folder and the nearest existing parent folder. A watcher whose path
// now names a different file is replaced; a replaced folder is reported to ConfigDirectoryReplaced.
static void StartWatchers(void) {
    if(!watchedDirectory) watchedDirectory=CRDConfigPath().stringByDeletingLastPathComponent;
    NSString *parent=watchedDirectory.stringByDeletingLastPathComponent;
    while(![NSFileManager.defaultManager fileExistsAtPath:parent]&&![parent isEqual:@"/"]) parent=parent.stringByDeletingLastPathComponent;
    if(![parent isEqual:watchedParent]&&parentWatcher) { dispatch_source_cancel(parentWatcher); parentWatcher=nil; }
    watchedParent=parent;
    auto rearm=[](dispatch_source_t source,NSString *path) {
        struct stat a={},b={};
        if(source&&(stat(path.fileSystemRepresentation,&a)!=0||fstat((int)dispatch_source_get_handle(source),&b)!=0||a.st_ino!=b.st_ino||a.st_dev!=b.st_dev)) {
            dispatch_source_cancel(source); source=nil;
        }
        return source?:WatchPath(path);
    };
    dispatch_source_t previousDirectory=directoryWatcher;
    directoryWatcher=rearm(directoryWatcher,watchedDirectory);
    parentWatcher=rearm(parentWatcher,watchedParent);
    fileWatcher=rearm(fileWatcher,CRDConfigPath());
    if(previousDirectory&&directoryWatcher!=previousDirectory) ConfigDirectoryReplaced();
}

#pragma mark - Overlay panel and Stop button
// The nonactivating overlay panel and the session-bound Stop button.

// A single-line label that truncates at the tail.
static NSTextField *OverlayLabel(NSString *text) {
    NSTextField *label=[NSTextField labelWithString:text]; label.lineBreakMode=NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines=1; return label;
}
// A panel that never becomes key or main, so the overlay never takes focus. Every left mouse event
// reaches its views without the Control flag (LeftClickWithoutControl), so a Control-click, or a
// Control flag stuck in remote input, stays an ordinary click.
@interface CRDOverlayPanel : NSPanel
@end
@implementation CRDOverlayPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)sendEvent:(NSEvent *)event { [super sendEvent:LeftClickWithoutControl(event)]; }
@end
// The Stop button, drawn as the Stop pill in its style. A press captures the current session token, and the
// action acts only on that token, so a press that began for one sharing window can never stop a later one.
@interface CRDSessionStopButton : NSButton
@property NSDictionary *sessionToken;
@property NSDictionary *gestureToken;
@property BOOL trackingGesture;
@property BOOL rejectingPress;
@property CRDStopGestureGate *stopGestureGate;
@property(copy) NSMenu *(^contextMenuProvider)(void);
/// The drawn pill inside a larger press area (the capsule's Stop), in the button's coordinates. The
/// frame, and so every press rule, covers the whole press area. Zero draws the pill over the whole frame.
@property NSRect pillFrame;
/// The stopStyle setting the pill is drawn in: "red" or "gray".
@property(nonatomic,copy) NSString *stopStyle;
- (BOOL)acceptsPress:(NSEvent *)event;
- (NSRect)pillRect;
@end
@implementation CRDSessionStopButton
- (void)setStopStyle:(NSString *)stopStyle { _stopStyle=[stopStyle copy]; [self setNeedsDisplay:YES]; }
- (NSRect)pillRect { return NSIsEmptyRect(self.pillFrame)?self.bounds:NSIntersectionRect(self.bounds,self.pillFrame); }
// Fills the pill (pressed and disabled states included) and draws the title centered in one
// line, truncated at the tail when the pill is narrower than its text.
- (void)drawRect:(NSRect)dirty {
    NSRect pill=[self pillRect]; if(NSIsEmptyRect(pill)) return;
    CGFloat radius=NSHeight(pill)/2;
    [StopPillFill(self.stopStyle,self.enabled,self.cell.isHighlighted) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:radius yRadius:radius] fill];
    NSFont *font=self.font?:StopPillFont(NSFont.systemFontSize);
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=NSTextAlignmentCenter; style.lineBreakMode=NSLineBreakByTruncatingTail;
    NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:StopPillTitleColor(self.stopStyle,self.enabled,self.cell.isHighlighted),NSParagraphStyleAttributeName:style};
    CGFloat text=ceil([self.title sizeWithAttributes:attributes].width),line=StopPillLineHeight(font);
    CGFloat inset=MAX(8,MIN(CRDPillPaddingX,floor((NSWidth(pill)-text)/2)));
    [self.title drawInRect:NSMakeRect(NSMinX(pill)+inset,round(NSMidY(pill)-line/2),MAX(0,NSWidth(pill)-2*inset),line) withAttributes:attributes];
}
// The gate first (so a rejected press still extends it), then a single click only:
// the second click of a double-click never presses Stop.
- (BOOL)acceptsPress:(NSEvent *)event {
    if(self.stopGestureGate&&![self.stopGestureGate allowsMouseDown:event]) return NO;
    return event.clickCount==1&&self.enabled;
}
- (void)mouseDown:(NSEvent *)event {
    self.rejectingPress=![self acceptsPress:event];
    if(self.rejectingPress) return;
    self.gestureToken=self.sessionToken; self.trackingGesture=YES;
    @try { [super mouseDown:event]; }
    @finally { self.trackingGesture=NO; self.gestureToken=nil; }
}
// A refused down still owns its release. Extend the gate from that release, even when
// remote input delays it and resets the click count on the next press.
- (void)mouseUp:(NSEvent *)event {
    if(self.rejectingPress) { [self.stopGestureGate recordGesture:event]; self.rejectingPress=NO; return; }
    [super mouseUp:event];
}
// The session token of the press in progress; nil outside a tracked press.
- (NSDictionary *)actionToken { return self.trackingGesture?self.gestureToken:nil; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    if(!OpensContextMenu(event)) return nil;
    return self.contextMenuProvider?self.contextMenuProvider():[super menuForEvent:event];
}
- (void)rightMouseDown:(NSEvent *)event {
    NSMenu *menu=[self menuForEvent:event];
    if(menu) PresentStopContextMenu(menu,event,self,self.stopGestureGate); else [super rightMouseDown:event];
}
@end

static void StyleStopPill(NSButton *button,NSString *title,CGFloat size,NSString *style) {
    button.bordered=NO; button.hasDestructiveAction=YES; button.contentTintColor=nil;
    button.title=title?:@""; button.font=StopPillFont(size);
    if([button isKindOfClass:CRDSessionStopButton.class]) ((CRDSessionStopButton *)button).stopStyle=style;
    [button setNeedsDisplay:YES];
}

#pragma mark - Self-test fixture types
// Native tracking fixtures use hidden windows and enqueue only this app's events.
// A button cell that runs a block during native tracking and then posts its own mouse-up.
@interface CRDTrackingFixtureCell : NSButtonCell
@property(copy) void (^duringTracking)(void);
@end
@implementation CRDTrackingFixtureCell
- (BOOL)startTrackingAt:(NSPoint)point inView:(NSView *)view {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),dispatch_get_main_queue(),self.duringTracking);
    NSTimer *up=[NSTimer timerWithTimeInterval:.10 repeats:NO block:^(NSTimer *timer){
        NSEvent *event=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:[view convertPoint:point toView:nil] modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
        [NSApp postEvent:event atStart:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:up forMode:NSRunLoopCommonModes];
    return [super startTrackingAt:point inView:view];
}
@end
// Records the token a Stop action received.
@interface CRDTrackingRecorder : NSObject
@property NSDictionary *received,*legacyReceived;
- (void)clicked:(CRDSessionStopButton *)button;
@end
@implementation CRDTrackingRecorder
- (void)clicked:(CRDSessionStopButton *)button { self.received=[button actionToken]; self.legacyReceived=button.sessionToken; }
@end
// Stands in for NSRunningApplication in self-tests.
@interface CRDFixtureApplication : NSObject
@property pid_t processIdentifier;
@property(getter=isTerminated) BOOL terminated;
@end
@implementation CRDFixtureApplication
@end

#pragma mark - Stop reveal capsule geometry
// Sizes and frames of the temporary Stop capsule a double-click opens on any shape. The capsule holds
// the status dot on the left and the Stop pill on the right, vertically centered, with no empty bezel.
// Its Stop metrics are independent of the saved font; a visible dot-layout dot keeps its diameter.
// ExpandedStopCapsule in the settings app draws the same layout.
static const CGFloat CRDCapsulePadding=6,CRDCapsuleDotInset=12,CRDCapsuleDotGap=10,CRDCapsuleDotDiameter=12;
// The capsule's Stop press area is at least 120 x 36 pt; a pill wider than the maximum truncates its label.
static const CGFloat CRDStopHitWidth=120,CRDStopHitHeight=36,CRDCapsulePillMaximumWidth=280;
static const CGFloat CRDStopShrinkMargin=6; // A double-click this close to Stop does nothing.
static const CGFloat CRDStopTextPadding=12; // Text padding of the native Stop menu.
static const NSTimeInterval CRDRevealOpenDuration=.20,CRDRevealCloseDuration=.16;
// The capsule's parts in its own coordinates (origin bottom-left).
struct CRDCapsuleLayout { NSSize size; NSRect dot,pill,press; };
// Lays out the capsule for a natural pill size and a visible fold dot. The space above,
// below and at the right end of the pill is 6 pt (more when the dot is taller than the pill). The dot
// sits 12 pt from the left end and 10 pt before the pill, leaving room to fold outside Stop.
// The press area is the pill, the capsule's padding around it and half the gap, and the pill widens
// so that the press area is at least 120 x 36 pt.
static CRDCapsuleLayout CapsuleLayout(NSSize pill,CGFloat dotDiameter) {
    CRDCapsuleLayout layout={};
    CGFloat dot=dotDiameter>0?dotDiameter:CRDCapsuleDotDiameter;
    CGFloat height=MAX(pill.height,dot)+2*CRDCapsulePadding,inset=round((height-pill.height)/2);
    CGFloat pillX=CRDCapsuleDotInset+dot+CRDCapsuleDotGap;
    CGFloat pressX=pillX-CRDCapsuleDotGap/2;
    CGFloat pillWidth=MIN(CRDCapsulePillMaximumWidth,MAX(pill.width,CRDStopHitWidth-(pillX-pressX)-inset));
    layout.size=NSMakeSize(pillX+pillWidth+inset,height);
    layout.pill=NSMakeRect(pillX,inset,pillWidth,pill.height);
    layout.press=NSMakeRect(pressX,0,layout.size.width-pressX,height);
    layout.dot=NSMakeRect(CRDCapsuleDotInset,(height-dot)/2,dot,dot);
    return layout;
}
// Fits unusually large dots or labels on a small display without substituting a menu. First
// shorten the label and reduce the dot, retaining the 120 pt Stop target where space permits.
// A display smaller than the minimum capsule scales the entire layout to its available size.
static CRDCapsuleLayout CapsuleLayoutOnScreen(NSSize pill,CGFloat dotDiameter,NSSize available) {
    CRDCapsuleLayout layout=CapsuleLayout(pill,dotDiameter);
    if(layout.size.width<=available.width&&layout.size.height<=available.height) return layout;
    CGFloat dot=MIN(dotDiameter,MAX(MIN(dotDiameter,CRDCapsuleDotDiameter),MIN(available.height-2*CRDCapsulePadding,available.width-CRDStopHitWidth-CRDCapsuleDotInset-CRDCapsuleDotGap/2)));
    layout=CapsuleLayout(pill,dot);
    CGFloat trim=MIN(MAX(0,layout.size.width-available.width),layout.press.size.width-CRDStopHitWidth);
    layout.pill.size.width-=trim; layout.press.size.width-=trim; layout.size.width-=trim;
    CGFloat scale=MIN(1,MIN(available.width/layout.size.width,available.height/layout.size.height));
    if(scale<1) {
        layout.size=NSMakeSize(layout.size.width*scale,layout.size.height*scale);
        NSRect *parts[]={&layout.dot,&layout.pill,&layout.press};
        for(NSRect *rect:parts)
            *rect=NSMakeRect(rect->origin.x*scale,rect->origin.y*scale,rect->size.width*scale,rect->size.height*scale);
    }
    return layout;
}
// Centers the capsule, then moves it inside the visible frame at whole points. It covers the
// anchor's center when that point is on-screen; an off-screen center uses the nearest position.
static NSRect CapsuleFrame(NSRect anchor,NSRect visible,NSSize size,BOOL *fits) {
    NSRect frame=NSMakeRect(round(NSMidX(anchor)-size.width/2),round(NSMidY(anchor)-size.height/2),size.width,size.height);
    frame.origin.x=MAX(ceil(NSMinX(visible)),MIN(frame.origin.x,floor(NSMaxX(visible)-size.width)));
    frame.origin.y=MAX(ceil(NSMinY(visible)),MIN(frame.origin.y,floor(NSMaxY(visible)-size.height)));
    if(fits) *fits=NSContainsRect(visible,frame);
    return frame;
}
static NSNumber *fixtureReduceMotion;
static NSValue *fixtureRevealVisibleFrame;
// False when Reduce Motion is on (or a fixture says so).
static BOOL RevealAnimationsEnabled(void) { return !(fixtureMode&&fixtureReduceMotion?fixtureReduceMotion.boolValue:NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion); }
// True when two Stop tokens name the same process, window generation, window and Stop element.
static BOOL SameStopToken(NSDictionary *token,NSDictionary *current) {
    if(!token||!current||![token[@"pid"] isEqual:current[@"pid"]]||![token[@"generation"] isEqual:current[@"generation"]]) return NO;
    id window=token[@"window"],currentWindow=current[@"window"],stop=token[@"stop"],currentStop=current[@"stop"];
    return window&&currentWindow&&stop&&currentStop&&CFEqual((__bridge CFTypeRef)window,(__bridge CFTypeRef)currentWindow)&&CFEqual((__bridge CFTypeRef)stop,(__bridge CFTypeRef)currentStop);
}

#pragma mark - Status line
// The status title and symbol shared by the menu bar item and the settings app.
// macOS 27 names the permission's Privacy & Security pane Device Control and Data Access
// (기기 제어 및 데이터 접근); earlier systems call it Accessibility.
static NSString *PermissionRequiredKey(BOOL deviceControl) { return deviceControl?@"기기 제어 권한 필요":@"손쉬운 사용 권한 필요"; }
// True on macOS 27 and later.
static BOOL UsesDeviceControlName(void) { return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){27,0,0}]; }
// One status line for the menu bar item, with the same titles as the settings app.
// Returns the localized title, and the SF Symbol name and attention flag through the pointers.
static NSString *StatusLine(BOOL trusted,BOOL restorationBlocked,BOOL enabled,NSString *effectiveMode,BOOL detected,NSString **symbol,BOOL *attention) {
    NSString *name,*title; BOOL needsAttention=NO;
    if(!trusted) { name=@"exclamationmark.triangle"; title=PermissionRequiredKey(UsesDeviceControlName()); needsAttention=YES; }
    else if(restorationBlocked) { name=@"exclamationmark.triangle"; title=@"확인 필요"; needsAttention=YES; }
    else if(!enabled) { name=@"rectangle.dashed"; title=@"공유 창 바꾸기 꺼짐"; }
    else {
        title=detected?@"작동 중":@"준비됨";
        name=[effectiveMode isEqual:@"original"]?@"rectangle.dashed":detected?@"rectangle.badge.checkmark":@"rectangle.badge.person.crop";
    }
    if(symbol) *symbol=name;
    if(attention) *attention=needsAttention;
    return L(title);
}
@class CRDOverlayCoordinator;
static CRDOverlayCoordinator *coordinator;

#pragma mark - Overlay coordinator interface
// The coordinator owns the CRD host process, its sharing window and Stop element (through
// Accessibility), the hide/restore obligation, the overlay, the menu bar item and the Stop capsule.
@interface CRDOverlayCoordinator : NSObject <NSApplicationDelegate,NSMenuDelegate>
@property NSString *hostAppPath,*hostExecutablePath;
@property NSRunningApplication *original;
@property id applicationElement,windowElement,stopElement,axObserver;
@property id launchObserver,terminateObserver,moveObserver,resizeObserver,screenObserver;
@property NSArray *observedWindows;
@property dispatch_source_t terminateSignal,interruptSignal;
@property BOOL trusted,observerReady,windowDetected,originalHidden,stopAvailable,ownsHidden,pending,stopping;
@property BOOL originalHiddenKnown,restorationBlocked,observerRetryPending,restorationOnly;
@property NSDictionary *restoreIntent;
@property NSString *originalBirth;
@property NSUInteger observerRetryGeneration,observerAttempts;
@property AXError observerError;
@property NSString *lastEvent,*detectionReason;
@property NSUInteger reconcileCount,windowGeneration;
@property BOOL workspaceReady;
@property BOOL refreshRegistered,refreshRequested;
@property int refreshNotifyToken;
@property NSStatusItem *statusItem;
@property NSPanel *stopRevealPanel;
@property dispatch_source_t revealTimer;
@property NSDictionary *revealToken;
@property NSString *revealModeSignature;
@property NSUInteger revealGeneration;
@property BOOL revealSavedIgnoresMouseEvents;
@property CGFloat revealSavedDotAlpha;
// True while the capsule stands in for a shape other than the dot, which is hidden under it.
@property BOOL revealHidesWindow;
@property CRDStatusDot *revealDot;
@property CRDSessionStopButton *revealStopButton;
@property id revealInputMonitor;
@property NSRect revealStopZone;
@property BOOL revealGuardedSequence;
- (NSDictionary *)currentStopToken;
- (NSEvent *)filterRevealInput:(NSEvent *)input gate:(CRDStopGestureGate *)gate;
- (void)presentStopRevealWithToken:(NSDictionary *)token;
- (void)presentStopRevealWithToken:(NSDictionary *)token afterEvent:(NSEvent *)event;
- (void)closeStopReveal:(NSString *)reason;
- (void)validateStopRevealForToken:(NSDictionary *)token modeSignature:(NSString *)signature windowDetected:(BOOL)detected;
- (NSMenu *)stopContextMenu;
- (NSMenu *)windowContextMenu;
- (void)refreshStatusItem;
- (void)scheduleReconcile:(NSString *)event;
- (void)requestReconcile;
- (void)refreshTrust;
- (void)screenParametersChanged;
- (void)reconcile;
- (void)stopSharingClicked:(id)sender;
- (void)cleanExit;
- (BOOL)releaseOriginal;
@end

#pragma mark - Accessibility boundary
// Fixtures replace the AX boundary, never an actual host element or action.
static id (^fixtureAXRead)(id,CFStringRef,AXError *);
static AXError (^fixtureAXWrite)(id,BOOL);
static AXError (^fixtureAXPress)(id);
static id fixtureApplication;
static NSString *fixtureBirth;
static NSNumber *fixtureProcessUID;
static AXError (^fixtureObserverSetup)(void);
static BOOL (^fixtureJournalWrite)(NSDictionary *);
static int fixtureProcessExistenceError;
static NSNumber *fixtureTrusted;
static void (^fixtureReconcile)(CRDOverlayCoordinator *);
static void (^fixtureRefreshAcknowledged)(void);
static NSDictionary *fixtureStopToken; // A session token the self-test supplies for its double-click checks.
// Accessibility trust; fixtures supply their own value.
static BOOL CurrentTrust(void) { return fixtureMode?(fixtureTrusted?fixtureTrusted.boolValue:coordinator.trusted):AXIsProcessTrusted()!=0; }
// Per-user, per-process Darwin notification names for refresh requests and their acknowledgement.
static NSString *RefreshNotification(BOOL acknowledged) {
    return [NSString stringWithFormat:@"local.crdwindow.host.refresh.%u.%d%@",getuid(),getpid(),acknowledged?@".done":@""];
}

#pragma mark - Host process identity and restoration journal
// Identifies the CRD host process and keeps the durable obligation to unhide it.

// The process start time as "seconds:microseconds", which tells a reused pid apart; also returns
// the owning uid. nil when the process cannot be inspected.
static NSString *ProcessBirth(pid_t pid,NSNumber **uid=nullptr) {
    if(uid) *uid=nil;
    if(fixtureMode) { if(uid) *uid=fixtureProcessUID; return fixtureBirth; }
    struct proc_bsdinfo info={};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)) return nil;
    if(uid) *uid=@(info.pbi_uid);
    return [NSString stringWithFormat:@"%llu:%llu",info.pbi_start_tvsec,info.pbi_start_tvusec];
}
// True only when the recorded process is provably gone: a different birth, or ESRCH.
static BOOL OriginalProcessEnded(pid_t pid,NSString *birth,NSString *recordedBirth) {
    if(birth) return ![birth isEqual:recordedBirth];
    // An unavailable birth can also mean permission failure. Only ESRCH proves death.
    return fixtureMode?fixtureProcessExistenceError==ESRCH:(kill(pid,0)==-1&&errno==ESRCH);
}
// restore-state.json, the journal that records a pending unhide of the host.
static NSString *RestorePath(void) {
    return [CRDConfigPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"restore-state.json"];
}
// Writes the restore journal atomically (0600 in a 0700 folder) and remembers it on success.
static BOOL StoreRestoreIntent(CRDOverlayCoordinator *owner,NSDictionary *intent) {
    BOOL ok=NO;
    if(fixtureMode&&fixtureJournalWrite) ok=fixtureJournalWrite(intent);
    else {
        NSString *path=RestorePath();
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        NSData *data=[NSJSONSerialization dataWithJSONObject:intent options:NSJSONWritingSortedKeys error:nil];
        ok=[data writeToFile:path options:NSDataWritingAtomic error:nil];
        if(ok) chmod(path.fileSystemRepresentation,0600);
    }
    if(ok) owner.restoreIntent=intent;
    return ok;
}
// Clears the journal after the host is visible again. If the journal cannot be cleared,
// restoration stays blocked so the obligation is never silently dropped.
static BOOL CompleteRestore(CRDOverlayCoordinator *owner) {
    if(!StoreRestoreIntent(owner,@{@"pending":@NO})) { owner.restorationBlocked=YES; return NO; }
    owner.ownsHidden=NO; owner.restorationBlocked=NO; return YES;
}
// Reads an AX attribute; fixtures answer instead of a real element.
static id AXRead(AXUIElementRef element,CFStringRef attribute,AXError *status) {
    if(fixtureMode) {
        if(status) *status=kAXErrorNoValue;
        return fixtureAXRead?fixtureAXRead((__bridge id)element,attribute,status):nil;
    }
    CFTypeRef value=nullptr; AXError error=AXUIElementCopyAttributeValue(element,attribute,&value);
    if(status) *status=error;
    return error==kAXErrorSuccess?CFBridgingRelease(value):nil;
}
// Reads a boolean AX attribute; known is NO when the value is missing or not a boolean.
static BOOL AXBoolean(AXUIElementRef element,CFStringRef attribute,BOOL *known) {
    id value=AXRead(element,attribute,nullptr);
    BOOL valid=value && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
    if(known) *known=valid;
    return valid?[value boolValue]:NO;
}
// True when the element offers the AXPress action.
static BOOL SupportsPress(AXUIElementRef element) {
    if(fixtureMode) return [AXRead(element,CFSTR("fixturePress"),nullptr) boolValue];
    CFArrayRef actions=nullptr; AXError error=AXUIElementCopyActionNames(element,&actions);
    NSArray *names=CFBridgingRelease(actions);
    return error==kAXErrorSuccess && [names containsObject:(__bridge NSString *)kAXPressAction];
}
// Accepts only the real Chrome Remote Desktop host: owned by this user, the expected bundle id and
// executable path, and a valid code signature from Google's team identifier.
static BOOL OriginalIdentity(NSRunningApplication *app,NSString *executable) {
    NSNumber *uid=nil;
    if(!app||!ProcessBirth(app.processIdentifier,&uid)||!uid||uid.unsignedIntegerValue!=getuid()) return NO;
    if(fixtureMode) return app&&app==fixtureApplication;
    if(!app || app.terminated || ![app.bundleIdentifier isEqual:@"com.google.chromeremotedesktop.me2me-host"] ||
       ![app.executableURL.URLByResolvingSymlinksInPath.path isEqual:executable]) return NO;
    SecStaticCodeRef code=nullptr; SecRequirementRef requirement=nullptr;
    OSStatus status=SecStaticCodeCreateWithPath((__bridge CFURLRef)app.executableURL,kSecCSDefaultFlags,&code);
    if(status==errSecSuccess) status=SecRequirementCreateWithString(CFSTR("anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\" and identifier \"com.google.chromeremotedesktop.me2me-host\""),kSecCSDefaultFlags,&requirement);
    if(status==errSecSuccess) status=SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement);
    if(requirement) CFRelease(requirement); if(code) CFRelease(code);
    return status==errSecSuccess;
}

#pragma mark - Sharing window inspection
// Finds the sharing window's Stop button through Accessibility.
// Inspect only structural roles and arrow button labels; never read account text.
static void InspectTree(AXUIElementRef element,NSMutableArray *buttons,NSUInteger *textCount,NSUInteger *budget,BOOL *complete,NSUInteger depth) {
    if(depth>6 || !*budget) { *complete=NO; return; } --*budget;
    AXError roleStatus; NSString *role=AXRead(element,kAXRoleAttribute,&roleStatus);
    if(roleStatus!=kAXErrorSuccess || ![role isKindOfClass:NSString.class]) { *complete=NO; return; }
    if([role isEqual:(__bridge NSString *)kAXButtonRole]) [buttons addObject:(__bridge id)element];
    if([role isEqual:(__bridge NSString *)kAXStaticTextRole] || [role isEqual:(__bridge NSString *)kAXTextFieldRole]) ++*textCount;
    AXError childrenStatus; id children=AXRead(element,kAXChildrenAttribute,&childrenStatus);
    if(childrenStatus==kAXErrorAttributeUnsupported || childrenStatus==kAXErrorNoValue) return;
    if(childrenStatus!=kAXErrorSuccess || ![children isKindOfClass:NSArray.class]) { *complete=NO; return; }
    for(id child in children) InspectTree((__bridge AXUIElementRef)child,buttons,textCount,budget,complete,depth+1);
}
// Returns the sharing window's Stop button: the window must hold text and exactly two buttons,
// one of them the ▲/▼ arrow. Any incomplete or different tree returns nil.
static id SharingStopButton(AXUIElementRef window,BOOL *known) {
    NSMutableArray *buttons=[NSMutableArray array]; NSUInteger texts=0,budget=128; BOOL complete=YES;
    InspectTree(window,buttons,&texts,&budget,&complete,0);
    if(known) *known=complete;
    if(!complete || buttons.count!=2 || texts==0) return nil;
    id arrow=nil,other=nil;
    for(id button in buttons) {
        NSString *title=AXRead((__bridge AXUIElementRef)button,kAXTitleAttribute,nullptr);
        if(![title isKindOfClass:NSString.class]) title=AXRead((__bridge AXUIElementRef)button,kAXValueAttribute,nullptr);
        BOOL isArrow=[title isKindOfClass:NSString.class] && [@[@"▲",@"▼"] containsObject:[title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        if(isArrow) { if(arrow) return nil; arrow=button; } else other=button;
    }
    return arrow&&other?other:nil;
}
// AX observer callback: a created or destroyed window invalidates Stop at once, then reconciles.
static void AXNotification(AXObserverRef observer,AXUIElementRef element,CFStringRef notification,void *context) {
    CRDOverlayCoordinator *owner=(__bridge CRDOverlayCoordinator *)context;
    if(CFEqual(notification,kAXWindowCreatedNotification)||CFEqual(notification,kAXUIElementDestroyedNotification)) {
        owner.stopAvailable=NO; owner.windowGeneration++; // Invalidate before the debounce.
        [owner closeStopReveal:@"original-window-changed"];
    }
    [owner scheduleReconcile:@"accessibility-event"];
}

#pragma mark - Hiding and restoring the host
// Hides the host app only while this helper owns the obligation to show it again.

// Hides or shows the host through AXHidden and verifies the result. Hiding writes the restore
// journal first and never takes over an app that was already hidden by someone else; showing
// clears the journal only after the host reads as visible.
static BOOL TrySetOriginalHidden(CRDOverlayCoordinator *owner,BOOL hidden) {
    if(!owner.original || owner.original.terminated || !owner.applicationElement) return NO;
    if(![ProcessBirth(owner.original.processIdentifier) isEqual:owner.originalBirth]) return NO;
    if(hidden&&owner.restorationBlocked) return NO;
    if(!hidden&&!owner.ownsHidden) return YES;
    BOOL known=NO; BOOL before=AXBoolean((__bridge AXUIElementRef)owner.applicationElement,kAXHiddenAttribute,&known);
    owner.originalHiddenKnown=known; if(known) owner.originalHidden=before;
    if(hidden) {
        if(!known || (before&&!owner.ownsHidden)) return NO;
        if(!owner.ownsHidden) {
            NSDictionary *intent=@{@"pending":@YES,@"pid":@(owner.original.processIdentifier),
                @"birth":owner.originalBirth,@"executable":owner.hostExecutablePath};
            if(!StoreRestoreIntent(owner,intent)) return NO;
            owner.ownsHidden=YES; // Written before AXHidden, including uncertain writes.
        }
    }
    if(!known || before!=hidden) {
        owner.originalHiddenKnown=NO;
        AXError error=fixtureMode?(fixtureAXWrite?fixtureAXWrite(owner.applicationElement,hidden):kAXErrorFailure):
            AXUIElementSetAttributeValue((__bridge AXUIElementRef)owner.applicationElement,kAXHiddenAttribute,hidden?kCFBooleanTrue:kCFBooleanFalse);
        if(error!=kAXErrorSuccess) return NO;
    }
    BOOL after=AXBoolean((__bridge AXUIElementRef)owner.applicationElement,kAXHiddenAttribute,&known);
    owner.originalHiddenKnown=known;
    if(known) owner.originalHidden=after;
    if(!known || after!=hidden) return NO;
    return hidden?YES:CompleteRestore(owner);
}
// As TrySetOriginalHidden; a failed show of an owned hide blocks restoration.
static BOOL SetOriginalHidden(CRDOverlayCoordinator *owner,BOOL hidden) {
    BOOL result=TrySetOriginalHidden(owner,hidden);
    if(!hidden&&owner.ownsHidden&&!result) owner.restorationBlocked=YES;
    return result;
}
// Rewrites the restore journal when the support folder was replaced; if that fails, unhides the host.
static void ConfigDirectoryReplaced(void) {
    // Recreate the durable obligation from memory when its directory was replaced.
    // This runs on the vnode event, not on every AX reconciliation or idle tick.
    if(!coordinator.restoreIntent||(!coordinator.ownsHidden&&coordinator.restorationBlocked)) return;
    if(!StoreRestoreIntent(coordinator,coordinator.restoreIntent)) {
        coordinator.restorationBlocked=YES;
        if(coordinator.ownsHidden) SetOriginalHidden(coordinator,NO);
        WriteRuntimeStatus(@"restore-journal-unavailable",nil);
    }
}

#pragma mark - Runtime status and overlay application
// Publishes runtime-status.json and applies the configuration to the overlay window.

// Writes runtime-status.json (readiness, host and window state, frame, mode, counters), logs the
// event, and refreshes the menu bar item.
static void WriteRuntimeStatus(NSString *event,NSWindowController *unused) {
    NSRect frame=overlay.controller.window.frame;
    NSDictionary *status=@{@"backendKind":@"accessibility-overlay",@"agentReady":@(coordinator.trusted&&!coordinator.stopping&&!coordinator.restorationBlocked&&(fixtureMode||coordinator.refreshRegistered)),
        @"observerReady":@(coordinator.original?coordinator.observerReady:coordinator.workspaceReady),@"accessibility":@(coordinator.trusted),
        @"pid":@(getpid()),@"originalPid":coordinator.original?@(coordinator.original.processIdentifier):NSNull.null,
        @"originalExecutablePath":coordinator.hostExecutablePath?:@"",@"originalWindowDetected":@(coordinator.windowDetected),@"originalWindowGeneration":@(coordinator.windowGeneration),
        @"originalHidden":coordinator.originalHiddenKnown?@(coordinator.originalHidden):NSNull.null,
        @"restorationPending":@(coordinator.ownsHidden||coordinator.restorationBlocked),@"restorationBlocked":@(coordinator.restorationBlocked),@"stopActionAvailable":@(coordinator.stopAvailable),
        @"visible":@(overlay.controller.window.visible),@"frame":@{@"x":@(frame.origin.x),@"y":@(frame.origin.y),@"width":@(frame.size.width),@"height":@(frame.size.height)},
        @"mode":currentConfig[@"mode"]?:@"original",@"enabled":@(SettingsEnabled()),@"effectiveMode":EffectiveMode(),@"stopRevealVisible":@(coordinator.stopRevealPanel.visible),@"lastEvent":event?:@"state",@"lastEventTimestamp":@(NSDate.date.timeIntervalSince1970),
        @"fixture":@(fixtureMode),@"axReconcileCount":@(coordinator.reconcileCount),@"configReadCount":@(configReadCount),@"configReloadCount":@(configReloadCount),
        @"lastConfigReloadTimestamp":@(lastConfigReloadDate.timeIntervalSince1970),@"detectionReason":coordinator.detectionReason?:@"not-observed"};
    LogRuntimeEvent(event,status);
    NSString *path=[CRDConfigPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"runtime-status.json"];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    [[NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingSortedKeys error:nil] writeToFile:path options:NSDataWritingAtomic error:nil];
    [coordinator refreshStatusItem];
}
// Applies the configuration to the overlay window: level, shadow, opacity and appearance, and
// with reposition, the frame from placement and screen. Then lays out the controls and binds
// Stop to the current session token.
static void ApplyOverlay(BOOL reposition) {
    if(reposition) InvalidateGeometry();
    if(!overlay) return;
    NSWindow *w=overlay.controller.window; NSDictionary *d=currentConfig; BOOL previous=applying; applying=YES;
    // Reads the old Stop frame before any window or layout change. setFrame below, and the
    // Layout its resize notification runs, would otherwise make it already describe the new Stop.
    NSRect stopBefore=overlay.stop.hidden?NSZeroRect:NSOffsetRect(overlay.stop.frame,NSMinX(w.frame),NSMinY(w.frame));
    // Never Resizable and never movable by the window server, so macOS cannot tile,
    // arrange or enlarge the panel. The helper's own loop and grip move and resize it.
    w.styleMask=NSWindowStyleMaskNonactivatingPanel;
    w.minSize=NumericWindowLimit(0); w.maxSize=NumericWindowLimit(1);
    w.movable=NO; w.movableByWindowBackground=NO;
    w.level=[d[@"alwaysOnTop"] boolValue]?NSStatusWindowLevel:NSNormalWindowLevel;
    w.hasShadow=[d[@"shadow"] boolValue]; w.alphaValue=[d[@"opacity"] doubleValue]; w.opaque=NO; w.backgroundColor=NSColor.clearColor;
    NSString *appearance=d[@"appearance"];
    w.appearance=[appearance isEqual:@"system"]?nil:[NSAppearance appearanceNamed:[appearance isEqual:@"dark"]?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];
    if(reposition) {
        NSRect visible=SelectedScreen(d).visibleFrame;
        CGFloat width=[d[@"width"] doubleValue],height=[d[@"height"] doubleValue],inset=[d[@"edgeInset"] doubleValue];
        NSRect frame=NSMakeRect(NSMidX(visible)-width/2,NSMidY(visible)-height/2,width,height);
        NSString *placement=d[@"placement"];
        if([placement isEqual:@"top"]) frame.origin.y=NSMaxY(visible)-inset-height;
        else if([placement isEqual:@"bottom"]) frame.origin.y=NSMinY(visible)+inset;
        else if([placement isEqual:@"custom"]) { frame.origin.x=NSMinX(visible)+[d[@"x"] doubleValue]; frame.origin.y=NSMaxY(visible)-[d[@"y"] doubleValue]-height; }
        if([d[@"constrainToScreen"] boolValue]) {
            frame.origin.x=MAX(NSMinX(visible),MIN(frame.origin.x,NSMaxX(visible)-width));
            frame.origin.y=MAX(NSMinY(visible),MIN(frame.origin.y,NSMaxY(visible)-height));
        }
        [w setFrame:frame display:YES];
    }
    Layout(overlay); overlay.stop.enabled=!previewMode&&coordinator.stopAvailable;
    // A preset, menu or settings change that moves or shows the inline Stop arms its gate.
    NSRect stopAfter=overlay.stop.hidden?NSZeroRect:NSOffsetRect(overlay.stop.frame,NSMinX(w.frame),NSMinY(w.frame));
    if(!NSEqualRects(stopBefore,stopAfter)&&!overlay.stop.hidden) BlockInlineStop();
    ((CRDSessionStopButton *)overlay.stop).sessionToken=[coordinator currentStopToken];
    // While the Stop capsule is open, the window under it keeps no shadow, and a shape other than
    // the dot stays hidden, whatever this pass applied.
    if(coordinator.stopRevealPanel) { w.hasShadow=NO; if(coordinator.revealHidesWindow) w.alphaValue=0; }
    applying=previous;
}
// Tiling, Stage Manager or a screen change resized the panel. A pending user move is
// saved first (its frame was captured at the user event), then the configured frame comes back
// on the next turn of the run loop. Reverts coalesce, and a system that keeps forcing a size
// gets at most a few reverts per second instead of a resize loop.
static NSUInteger systemResizeReverts;
static BOOL systemResizeRevertPending;
static NSTimeInterval systemResizeWindowStart;
static NSUInteger systemResizeWindowCount;
// A burst never drops the last correction. While one is pending, later resizes join it
// (it applies the configured frame when it runs). Past 4 in a second, the next one is a single
// trailing correction at the end of that second; there is no repeating timer.
static void RevertSystemResize(void) {
    if(geometryDirty) PersistGeometry(overlay);
    if(systemResizeRevertPending) return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(now-systemResizeWindowStart>1) { systemResizeWindowStart=now; systemResizeWindowCount=0; }
    NSTimeInterval delay=++systemResizeWindowCount>4?MAX(0,systemResizeWindowStart+1-now):0;
    systemResizeRevertPending=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        systemResizeRevertPending=NO; systemResizeReverts++;
        if(geometryDirty) {
            // A busy writer must not discard the user's captured frame or its pending retry.
            BOOL previous=applying; applying=YES;
            [overlay.controller.window setFrame:geometryFrame display:YES]; applying=previous;
        } else ApplyOverlay(YES);
        WriteRuntimeStatus(@"system-resize-reverted",nil);
    });
}
// Builds the overlay panel and its views, wires double-click, drag, context menu and Stop gate
// callbacks, and observes moves and resizes.
static void CreateOverlay(void) {
    overlay=[CRDWindowState new]; overlay.message=L(@"화면을 공유하고 있습니다");
    CRDOverlayPanel *window=[[CRDOverlayPanel alloc] initWithContentRect:NSMakeRect(0,0,440,48) styleMask:NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO; window.hidesOnDeactivate=NO; window.floatingPanel=YES; window.title=L(@"공유 창");
    window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    overlay.controller=[[NSWindowController alloc] initWithWindow:window];
    overlay.customView=[[CRDBackground alloc] initWithFrame:window.contentView.bounds];
    overlay.customView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; overlay.customView.autoresizesSubviews=NO;
    window.contentView=overlay.customView;
    overlay.label=OverlayLabel(overlay.message); overlay.dot=[CRDStatusDot labelWithString:@"●"];
    overlay.dot.lineBreakMode=NSLineBreakByTruncatingTail; overlay.dot.maximumNumberOfLines=1;
    __weak CRDOverlayCoordinator *weakCoordinator=coordinator;
    // A double-click anywhere on the window except Stop opens the Stop capsule, on every shape: on
    // the background (which also takes clicks on the caption and the inline dot), on the dot in dot
    // layout, and on either grip.
    void (^expand)(NSEvent *)=^(NSEvent *event){
        [weakCoordinator presentStopRevealWithToken:[weakCoordinator currentStopToken] afterEvent:event];
    };
    overlay.dot.doubleClickAction=expand;
    overlay.dot.dragWillBegin=^{ [weakCoordinator closeStopReveal:@"dot-drag-began"]; };
    overlay.stop=[CRDSessionStopButton buttonWithTitle:ConfiguredText(CRDDefaults()[@"buttonText"],@"buttonText",@"공유 중지") target:coordinator action:@selector(stopSharingClicked:)];
    inlineStopGate=[CRDStopGestureGate new]; ((CRDSessionStopButton *)overlay.stop).stopGestureGate=inlineStopGate;
    overlay.handle=[CRDDragHandle new]; overlay.handle.toolTip=L(@"끌어서 옮기기"); overlay.handle.accessibilityLabel=L(@"이동 핸들");
    overlay.resizeHandle=[CRDDragHandle new]; overlay.resizeHandle.resizeHandle=YES; overlay.resizeHandle.toolTip=L(@"끌어서 크기 조절");
    // A right click anywhere on the custom window offers the same small menu.
    NSMenu *(^windowMenu)(void)=^{ [weakCoordinator closeStopReveal:@"context-menu-opened"]; return [weakCoordinator windowContextMenu]; };
    // The dot window offers the same menu, so its locks and presets are one right click away.
    overlay.customView.contextMenuProvider=windowMenu; overlay.handle.contextMenuProvider=windowMenu; overlay.resizeHandle.contextMenuProvider=windowMenu;
    overlay.dot.contextMenuProvider=windowMenu;
    overlay.customView.doubleClickAction=expand; overlay.customView.dragWillBegin=overlay.dot.dragWillBegin;
    overlay.handle.doubleClickAction=expand; overlay.resizeHandle.doubleClickAction=expand;
    CRDStopGestureGate *inlineGate=inlineStopGate;
    void (^recordInline)(NSEvent *)=^(NSEvent *ended){ [inlineGate recordGesture:ended]; };
    overlay.customView.gestureEnded=recordInline; overlay.dot.gestureEnded=recordInline;
    overlay.handle.gestureEnded=recordInline; overlay.resizeHandle.gestureEnded=recordInline;
    NSTextField *label=overlay.label; CRDStatusDot *dot=overlay.dot;
    overlay.customView.passesThrough=^BOOL(NSView *view){ return view==label||(view==dot&&!dot.geometricDot); };
    for(NSView *view in @[overlay.label,overlay.dot,overlay.stop,overlay.handle,overlay.resizeHandle]) [overlay.customView addSubview:view];
    coordinator.moveObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidMoveNotification object:window queue:nil usingBlock:^(NSNotification *n){ if(!applying) [coordinator closeStopReveal:@"anchor-moved"]; SaveGeometry(overlay); }];
    coordinator.resizeObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification object:window queue:nil usingBlock:^(NSNotification *n){
        if(!applying) [coordinator closeStopReveal:@"anchor-resized"];
        Layout(overlay);
        if(SystemResized(window)) { RevertSystemResize(); return; } // A system size is never saved.
        SaveGeometry(overlay);
    }];
    ApplyOverlay(YES);
}
// After a reload, closes the Stop capsule and reconciles AX state when mode or enabled changed.
static void ReconcileFromConfig(BOOL needsAX) {
    [coordinator closeStopReveal:@"settings-changed"];
    if(!fixtureMode&&needsAX) [coordinator scheduleReconcile:@"config-reloaded"];
    else WriteRuntimeStatus(@"config-reloaded",nil);
}

#pragma mark - Coordinator: host binding and observers
// Binds to the CRD host process, registers AX notifications and retries observer setup.
@implementation CRDOverlayCoordinator
// Stops tracking the current host. An owned hide is undone first (or cleared when the process
// provably ended); if that fails, restoration is blocked and the host stays bound.
- (BOOL)releaseOriginal {
    [self closeStopReveal:@"original-target-released"];
    if(self.ownsHidden) {
        NSString *birth=ProcessBirth(self.original.processIdentifier);
        BOOL ended=OriginalProcessEnded(self.original.processIdentifier,birth,self.originalBirth);
        if(ended) { if(!CompleteRestore(self)) return NO; }
        else if(!SetOriginalHidden(self,NO)) { self.restorationBlocked=YES; return NO; }
    }
    self.observerRetryGeneration++; self.observerRetryPending=NO;
    if(self.axObserver) CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource((__bridge AXObserverRef)self.axObserver),kCFRunLoopCommonModes);
    self.axObserver=nil; self.applicationElement=nil; self.windowElement=nil; self.stopElement=nil; self.observedWindows=nil; self.original=nil;
    self.observerReady=NO; self.windowDetected=NO; self.originalHiddenKnown=NO; self.stopAvailable=NO; self.originalBirth=nil;
    self.windowGeneration++;
    return YES;
}
// Retries a transient AX observer failure up to three times with backoff (0.25, 0.5, 1 s).
- (void)retryObserverIfNeeded {
    if(self.observerReady||self.stopping||self.observerRetryPending||self.observerAttempts>=3||
       (self.observerError!=kAXErrorCannotComplete&&self.observerError!=kAXErrorFailure)) return;
    NSUInteger generation=++self.observerRetryGeneration;
    self.observerRetryPending=YES;
    NSTimeInterval delay=.25*(1<<self.observerAttempts++);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(self.stopping||self.observerRetryGeneration!=generation||self.original.terminated) return;
        self.observerRetryPending=NO;
        [self bindOriginal:self.original];
        [self scheduleReconcile:@"observer-retry"];
    });
}
// Releases the previous host and binds to this one when it belongs to this user, then creates
// the AX observer. In restoration-only mode it binds the app element only.
- (void)bindOriginal:(NSRunningApplication *)application {
    BOOL same=self.original==application;
    if(![self releaseOriginal]) return;
    if(!same) self.observerAttempts=0;
    // Reuse the birth snapshot for UID, after a potentially slow release of the old target.
    NSNumber *uid=nil; NSString *birth=application?ProcessBirth(application.processIdentifier,&uid):nil;
    if(!birth||!uid||uid.unsignedIntegerValue!=getuid()) return;
    self.original=application; self.originalBirth=birth;
    self.applicationElement=fixtureMode?@"fixture-application":CFBridgingRelease(AXUIElementCreateApplication(application.processIdentifier));
    if(self.restorationOnly) return; // One unhide attempt; no observers, retries or normal reconciliation.
    if(fixtureMode) {
        self.observerError=fixtureObserverSetup?fixtureObserverSetup():kAXErrorFailure;
        self.observerReady=self.observerError==kAXErrorSuccess; [self retryObserverIfNeeded]; return;
    }
    AXObserverRef observer=nullptr;
    self.observerError=AXObserverCreate(application.processIdentifier,AXNotification,&observer);
    if(self.observerError!=kAXErrorSuccess) { [self retryObserverIfNeeded]; return; }
    self.axObserver=CFBridgingRelease(observer);
    BOOL ready=YES;
    for(NSString *notification in @[(__bridge NSString *)kAXWindowCreatedNotification,(__bridge NSString *)kAXUIElementDestroyedNotification,(__bridge NSString *)kAXApplicationHiddenNotification,(__bridge NSString *)kAXApplicationShownNotification]) {
        AXError error=AXObserverAddNotification(observer,(__bridge AXUIElementRef)self.applicationElement,(__bridge CFStringRef)notification,(__bridge void *)self);
        if(error!=kAXErrorSuccess && error!=kAXErrorNotificationAlreadyRegistered) { ready=NO; self.observerError=error; }
    }
    CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),kCFRunLoopCommonModes); self.observerReady=ready;
    [self retryObserverIfNeeded];
}
// Keeps a live host, or releases a terminated one and binds to the first valid running host.
- (void)findOriginal {
    if(self.original && !self.original.terminated) {
        return;
    }
    if(![self releaseOriginal]||self.restorationBlocked) return;
    for(NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        if(OriginalIdentity(application,self.hostExecutablePath)) { [self bindOriginal:application]; return; }
    }
}

#pragma mark - Coordinator: reconciliation
// Matches the host's sharing window, hides or restores the host, and shows or hides the overlay.

// Coalesces reconcile requests into one pass 80 ms later and acknowledges a pending refresh request.
- (void)scheduleReconcile:(NSString *)event {
    if(self.stopping) return; self.lastEvent=event;
    if(self.pending) return; self.pending=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        self.pending=NO;
        if(self.stopping) return;
        [self reconcile];
        if(self.refreshRequested) {
            self.refreshRequested=NO;
            if(fixtureMode) { if(fixtureRefreshAcknowledged) fixtureRefreshAcknowledged(); }
            else notify_post(RefreshNotification(YES).UTF8String);
        }
    });
}
// Handles an external refresh request: reconciles and then posts the acknowledgement.
- (void)requestReconcile {
    if(self.stopping) return;
    self.refreshRequested=YES; [self scheduleReconcile:@"status-requested"];
}
// Re-reads Accessibility trust; a loss disables Stop at once.
- (void)refreshTrust {
    BOOL trusted=CurrentTrust();
    if(trusted==self.trusted) return;
    self.trusted=trusted;
    if(!trusted) { self.stopAvailable=NO; [self closeStopReveal:@"accessibility-unavailable"]; }
    [self scheduleReconcile:@"accessibility-trust-changed"];
    WriteRuntimeStatus(@"accessibility-trust-changed",nil);
}
// One reconciliation pass. Without trust it restores the host and hides the overlay. Otherwise
// it reads the host's windows and requires exactly one window whose structure matches the
// sharing window; any unknown or ambiguous state leaves the host visible. In custom mode with
// a confirmed window it hides the host and shows the overlay; in every other case it restores
// the host. Every current window gets a destroy observer, so no polling is needed.
- (void)reconcile {
    if(self.stopping) return;
    if(fixtureMode) { if(fixtureReconcile) fixtureReconcile(self); return; }
    self.reconcileCount++; self.trusted=CurrentTrust();
    if(!self.trusted) {
        [self closeStopReveal:@"accessibility-unavailable"]; self.windowDetected=NO; self.stopAvailable=NO;
        if(self.ownsHidden) SetOriginalHidden(self,NO);
        [overlay.controller.window orderOut:nil]; overlay.shown=NO; self.detectionReason=@"accessibility-unavailable";
        WriteRuntimeStatus(self.lastEvent,nil); return;
    }
    [self findOriginal]; self.windowDetected=NO; self.stopAvailable=NO;
    NSString *reason=@"original-not-running"; BOOL snapshotKnown=NO;
    id matchedWindow=nil,matchedStop=nil;
    if(self.original && self.observerReady) {
        AXError error; NSArray *windows=AXRead((__bridge AXUIElementRef)self.applicationElement,kAXWindowsAttribute,&error);
        BOOL hiddenKnown=NO; BOOL hidden=AXBoolean((__bridge AXUIElementRef)self.applicationElement,kAXHiddenAttribute,&hiddenKnown);
        self.originalHiddenKnown=hiddenKnown; if(hiddenKnown) self.originalHidden=hidden;
        snapshotKnown=error==kAXErrorSuccess&&[windows isKindOfClass:NSArray.class]&&hiddenKnown;
        reason=snapshotKnown?@"sharing-window-not-found":@"accessibility-state-unknown";
        if(snapshotKnown) {
            // Observe every current window's destruction, including ambiguous ones,
            // so a later return to one sharing window needs no polling.
            for(id previous in self.observedWindows) if(![windows containsObject:previous])
                AXObserverRemoveNotification((__bridge AXObserverRef)self.axObserver,(__bridge AXUIElementRef)previous,kAXUIElementDestroyedNotification);
            for(id window in windows) if(![self.observedWindows containsObject:window]) {
                AXError registered=AXObserverAddNotification((__bridge AXObserverRef)self.axObserver,(__bridge AXUIElementRef)window,kAXUIElementDestroyedNotification,(__bridge void *)self);
                if(registered!=kAXErrorSuccess&&registered!=kAXErrorNotificationAlreadyRegistered) {
                    snapshotKnown=NO; reason=@"destroy-observer-unavailable";
                    self.observerReady=NO; self.observerError=registered; [self retryObserverIfNeeded];
                }
            }
            self.observedWindows=windows;
            if(windows.count>1) { snapshotKnown=NO; reason=@"multiple-original-windows"; }
        }
        if(snapshotKnown) {
            NSUInteger matches=0;
            for(id window in windows) {
                BOOL known=NO; id stop=SharingStopButton((__bridge AXUIElementRef)window,&known);
                if(!known) { snapshotKnown=NO; reason=@"window-structure-unknown"; break; }
                if(stop) { ++matches; matchedWindow=window; matchedStop=stop; }
            }
            if(matches>1) { snapshotKnown=NO; reason=@"ambiguous-sharing-windows"; }
            if(snapshotKnown&&matches==1) { self.windowDetected=YES; reason=@"sharing-window-observed"; }
        }
    } else if(self.original) reason=@"observer-unavailable";
    if(self.windowDetected) {
        if(!self.windowElement||!CFEqual((__bridge CFTypeRef)self.windowElement,(__bridge CFTypeRef)matchedWindow)) self.windowGeneration++;
        self.windowElement=matchedWindow; self.stopElement=matchedStop;
        BOOL enabledKnown=NO; BOOL enabled=AXBoolean((__bridge AXUIElementRef)matchedStop,kAXEnabledAttribute,&enabledKnown);
        self.stopAvailable=self.windowDetected&&enabledKnown&&enabled&&SupportsPress((__bridge AXUIElementRef)matchedStop);
    } else { self.windowElement=nil; self.stopElement=nil; }
    NSString *mode=EffectiveMode();
    NSString *modeSignature=[NSString stringWithFormat:@"%@:%@:%@",@(SettingsEnabled()),currentConfig[@"mode"],currentConfig[@"layout"]];
    [self validateStopRevealForToken:[self currentStopToken] modeSignature:modeSignature windowDetected:self.windowDetected];
    BOOL custom=[mode isEqual:@"custom"];
    if(snapshotKnown&&self.windowDetected&&custom) {
        BOOL unexpectedlyShown=self.ownsHidden&&!self.originalHidden;
        if(unexpectedlyShown) WriteRuntimeStatus(@"original-unexpectedly-shown",nil);
        if(!SetOriginalHidden(self,YES)) { self.stopAvailable=NO; reason=@"hide-unconfirmed"; SetOriginalHidden(self,NO); custom=NO; }
        else if(unexpectedlyShown) self.lastEvent=@"original-hide-reapplied";
    } else {
        custom=NO;
        if(self.ownsHidden) SetOriginalHidden(self,NO);
    }
    self.detectionReason=self.restorationBlocked?@"original-restore-unconfirmed":reason; ApplyOverlay(NO);
    overlay.shown=custom;
    if(custom) [overlay.controller.window orderFrontRegardless]; else [overlay.controller.window orderOut:nil];
    WriteRuntimeStatus(self.lastEvent,nil);
}

#pragma mark - Coordinator: Stop action
// Validates and performs the press of the host's own Stop button.

// The token of the current sharing session (pid, window generation, window and Stop elements),
// or nil when Stop is not available.
- (NSDictionary *)currentStopToken {
    if(fixtureMode&&fixtureStopToken) return fixtureStopToken;
    if(!self.stopAvailable||!self.windowDetected||!self.original||self.original.terminated||!self.windowElement||!self.stopElement) return nil;
    return @{@"pid":@(self.original.processIdentifier),@"generation":@(self.windowGeneration),@"window":self.windowElement,@"stop":self.stopElement};
}
// Presses the host's Stop button. The press must carry the current session token, the host must
// be the same process, and the window and Stop element are re-read and must still match and be
// enabled. A menu selection opened by a reveal gesture is refused. Every outcome is logged.
- (void)stopSharingClicked:(id)sender {
    if([sender isKindOfClass:NSMenuItem.class]&&activeContextMenu.stopGestureGate&&!activeContextMenu.stopSelectionArmed) {
        WriteRuntimeStatus(@"user-stop-rejected-reveal-gesture",nil); return;
    }
    NSDictionary *token=nil;
    if([sender isKindOfClass:CRDSessionStopButton.class]) token=[sender actionToken];
    else if([sender isKindOfClass:NSMenuItem.class]&&[sender action]==@selector(stopSharingClicked:)) token=[sender representedObject];
    if(self.stopping||!SameStopToken(token,[self currentStopToken])||
       ![ProcessBirth(self.original.processIdentifier) isEqual:self.originalBirth]) { WriteRuntimeStatus(@"user-stop-rejected-stale-target",nil); return; }
    AXError windowsError; NSArray *windows=AXRead((__bridge AXUIElementRef)self.applicationElement,kAXWindowsAttribute,&windowsError);
    BOOL currentWindow=windowsError==kAXErrorSuccess&&[windows isKindOfClass:NSArray.class]&&windows.count==1&&
        CFEqual((__bridge CFTypeRef)windows[0],(__bridge CFTypeRef)token[@"window"]);
    BOOL known=NO; id fresh=currentWindow?SharingStopButton((__bridge AXUIElementRef)token[@"window"],&known):nil;
    BOOL enabledKnown=NO; BOOL enabled=fresh?AXBoolean((__bridge AXUIElementRef)fresh,kAXEnabledAttribute,&enabledKnown):NO;
    if(!known||!fresh||!enabledKnown||!enabled||!CFEqual((__bridge CFTypeRef)fresh,(__bridge CFTypeRef)self.stopElement)||!SupportsPress((__bridge AXUIElementRef)fresh)) {
        self.stopAvailable=NO; WriteRuntimeStatus(@"user-stop-rejected-unconfirmed-control",nil); [self scheduleReconcile:@"stop-target-unconfirmed"]; return;
    }
    AXError error=fixtureMode?(fixtureAXPress?fixtureAXPress(fresh):kAXErrorFailure):
        AXUIElementPerformAction((__bridge AXUIElementRef)fresh,kAXPressAction);
    WriteRuntimeStatus(error==kAXErrorSuccess?@"user-stop-action-sent":@"user-stop-action-failed",nil);
    [self closeStopReveal:@"user-stop-action-completed"];
    [self scheduleReconcile:error==kAXErrorSuccess?@"user-stop-action-sent":@"user-stop-action-failed"];
}
// A Stop menu item bound to the current session token; disabled when there is none.
- (NSMenuItem *)stopMenuItem {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:L(@"공유 중지") action:@selector(stopSharingClicked:) keyEquivalent:@""];
    item.target=self; item.representedObject=[self currentStopToken]; item.enabled=item.representedObject!=nil; return item;
}
// The one-item menu that offers Stop.
- (NSMenu *)stopContextMenu {
    NSMenu *menu=[NSMenu new]; menu.autoenablesItems=NO;
    menu.font=[NSFont menuFontOfSize:0];
    menu.minimumWidth=MAX(160,ceil([L(@"공유 중지") sizeWithAttributes:@{NSFontAttributeName:menu.font}].width)+4*CRDStopTextPadding);
    [menu addItem:[self stopMenuItem]]; return menu;
}

#pragma mark - Coordinator: Stop reveal capsule
// The capsule a double-click opens on any shape to offer Stop, and its input gate.
- (void)presentStopRevealWithToken:(NSDictionary *)token {
    [self presentStopRevealWithToken:token afterEvent:nil];
}
// Opens the Stop capsule in custom mode, on any shape, centered on the window and moved inside the
// screen near an edge or a corner. In dot layout the capsule grows from the dot: its panel sits
// below the dot window and a duplicate dot slides to the capsule's left end. On the other shapes
// the window fades out and the capsule fades in at its center, with a dot in the dot color. Stop
// stays disabled until the opening finishes and is gated from the triggering event. A missing
// target leaves Stop disabled, and an unusually small screen gets a fitted capsule.
- (void)presentStopRevealWithToken:(NSDictionary *)token afterEvent:(NSEvent *)event {
    if((token&&!fixtureMode&&!SameStopToken(token,[self currentStopToken]))||![EffectiveMode() isEqual:@"custom"]) return;
    [self closeStopReveal:@"reopened"];
    BOOL dotLayout=[currentConfig[@"layout"] isEqual:@"dot"];
    NSString *title=ConfiguredText(currentConfig[@"buttonText"],@"buttonText",@"공유 중지");
    CRDSessionStopButton *button=[CRDSessionStopButton buttonWithTitle:title target:self action:@selector(stopSharingClicked:)];
    // The capsule always has a gate, seeded from the triggering event (or now).
    CRDStopGestureGate *gate=[CRDStopGestureGate new];
    [gate blockFrom:event?event.timestamp:NSProcessInfo.processInfo.systemUptime];
    button.sessionToken=token; button.enabled=NO; button.stopGestureGate=gate;
    StyleStopPill(button,title,NSFont.systemFontSize,currentConfig[@"stopStyle"]); button.accessibilityLabel=L(@"공유 중지");
    NSWindow *anchorWindow=overlay.controller.window;
    NSRect anchor=anchorWindow.frame,visible=(anchorWindow.screen?:SelectedScreen(currentConfig)).visibleFrame;
    if(fixtureMode&&fixtureRevealVisibleFrame) visible=fixtureRevealVisibleFrame.rectValue;
    // A visible dot-layout dot keeps its drawn diameter. Every other capsule has a 12 pt dot,
    // even when showDot is off, so a manual fold target always remains outside Stop.
    CGFloat diameter=dotLayout&&!overlay.dot.hidden?MIN(overlay.dot.dotDiameter,MIN(anchor.size.width,anchor.size.height)):CRDCapsuleDotDiameter;
    NSSize pill=StopPillSize(title,button.font);
    NSSize available=NSMakeSize(floor(NSMaxX(visible))-ceil(NSMinX(visible)),floor(NSMaxY(visible))-ceil(NSMinY(visible)));
    CRDCapsuleLayout layout=CapsuleLayoutOnScreen(pill,diameter,available);
    if(layout.pill.size.height<pill.height) button.font=[NSFont systemFontOfSize:button.font.pointSize*layout.pill.size.height/pill.height];
    NSRect frame=CapsuleFrame(anchor,visible,layout.size,nullptr);
    self.revealToken=token;
    self.revealModeSignature=[NSString stringWithFormat:@"%@:%@:%@",@(SettingsEnabled()),currentConfig[@"mode"],currentConfig[@"layout"]];
    CGFloat width=frame.size.width,height=frame.size.height,windowAlpha=anchorWindow.alphaValue;
    CRDOverlayPanel *panel=[[CRDOverlayPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO; panel.hidesOnDeactivate=NO; panel.level=anchorWindow.level; panel.title=L(@"공유 중지");
    panel.hasShadow=anchorWindow.hasShadow; panel.appearance=anchorWindow.appearance;
    panel.opaque=NO; panel.backgroundColor=NSColor.clearColor; panel.alphaValue=windowAlpha;
    panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    CRDBackground *background=[[CRDBackground alloc] initWithFrame:NSMakeRect(0,0,width,height)];
    background.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; background.autoresizesSubviews=NO; background.clipsToBounds=YES;
    NSMutableDictionary *appearance=[currentConfig mutableCopy]; appearance[@"radius"]=@(height/2); appearance[@"draggable"]=@NO; background.config=appearance; panel.contentView=background;
    // The button's frame is the whole press area; the pill is drawn inside it.
    button.frame=layout.press; button.pillFrame=NSOffsetRect(layout.pill,-NSMinX(layout.press),-NSMinY(layout.press));
    __weak CRDOverlayCoordinator *weakSelf=self;
    // A double-click anywhere except Stop (plus a margin) folds the capsule back.
    // The capsule itself stays unmovable (its background config has draggable off).
    void (^shrink)(NSEvent *)=^(NSEvent *input){ [weakSelf closeStopReveal:@"user-collapsed"]; };
    NSRect stopZone=NSInsetRect(layout.press,-CRDStopShrinkMargin,-CRDStopShrinkMargin);
    background.doubleClickAction=shrink; background.doubleClickExclusion=stopZone;
    void (^recordCapsule)(NSEvent *)=^(NSEvent *ended){ [gate recordGesture:ended]; };
    background.gestureEnded=recordCapsule;
    button.contextMenuProvider=^{ return [weakSelf stopContextMenu]; };
    [background addSubview:button]; self.stopRevealPanel=panel; self.revealStopButton=button;
    CRDStatusDot *movingDot=[CRDStatusDot labelWithString:@""];
    movingDot.geometricDot=YES; movingDot.windowDragEnabled=NO;
    movingDot.dotDiameter=diameter; movingDot.textColor=overlay.dot.textColor;
    movingDot.contextMenuProvider=^{ return [weakSelf stopContextMenu]; };
    movingDot.stopGestureGate=gate; movingDot.doubleClickAction=shrink; movingDot.gestureEnded=recordCapsule;
    movingDot.accessibilityLabel=L(@"상태 점");
    // In dot layout the duplicate starts at the dot's own place in the window, so hiding the
    // original does not blink.
    NSRect centeredDot=NSMakeRect((anchor.size.width-diameter)/2,(anchor.size.height-diameter)/2,diameter,diameter);
    NSRect leftDot=layout.dot;
    BOOL animate=RevealAnimationsEnabled();
    movingDot.frame=dotLayout&&animate?centeredDot:leftDot; [background addSubview:movingDot]; self.revealDot=movingDot;
    self.revealSavedDotAlpha=overlay.dot.alphaValue; self.revealHidesWindow=!dotLayout;
    self.revealSavedIgnoresMouseEvents=anchorWindow.ignoresMouseEvents;
    anchorWindow.ignoresMouseEvents=YES;
    button.alphaValue=animate?0:1;
    if(dotLayout) {
        overlay.customView.suppressBackground=YES; anchorWindow.hasShadow=NO; [overlay.customView setNeedsDisplay:YES];
        if(animate) [panel setFrame:anchor display:NO];
    } else if(animate) panel.alphaValue=0;
    else { anchorWindow.alphaValue=0; anchorWindow.hasShadow=NO; }
    if(!fixtureMode) [panel orderWindow:NSWindowBelow relativeTo:anchorWindow.windowNumber];
    if(gate) {
        self.revealStopZone=stopZone; self.revealGuardedSequence=NO;
        self.revealInputMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *input) {
            CRDOverlayCoordinator *strongSelf=weakSelf;
            if(!strongSelf||strongSelf.stopRevealPanel!=panel) return input.window==panel||input.window==anchorWindow?[gate filterEvent:input]:input;
            return [strongSelf filterRevealInput:input gate:gate];
        }];
    }
    if(dotLayout) overlay.dot.alphaValue=0;
    NSUInteger generation=++self.revealGeneration;
    void (^opened)(void)=^{
        CRDOverlayCoordinator *strongSelf=weakSelf;
        if(!strongSelf||strongSelf.stopRevealPanel!=panel||strongSelf.revealGeneration!=generation) return;
        if(!dotLayout) anchorWindow.hasShadow=NO;
        button.enabled=!fixtureMode&&SameStopToken(token,[strongSelf currentStopToken])&&strongSelf.stopAvailable&&!strongSelf.stopping;
        // stopRevealSeconds is the auto-fold delay; 0 keeps the capsule open until folded.
        NSTimeInterval seconds=currentConfig[@"stopRevealSeconds"]?[currentConfig[@"stopRevealSeconds"] doubleValue]:5;
        if(seconds>0) {
            dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue()); strongSelf.revealTimer=timer;
            dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,10*NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer,^{ [weakSelf closeStopReveal:@"timeout"]; }); dispatch_resume(timer);
        }
        WriteRuntimeStatus(@"stop-reveal-opened",nil);
    };
    if(animate) [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){
        context.duration=CRDRevealOpenDuration; [[button animator] setAlphaValue:1];
        if(dotLayout) { [[panel animator] setFrame:frame display:YES]; [[movingDot animator] setFrame:leftDot]; }
        else { [[panel animator] setAlphaValue:windowAlpha]; [[anchorWindow animator] setAlphaValue:0]; }
    } completionHandler:opened]; else opened();
}
// Presses that start on Stop (plus the margin) go through the gate. Other presses on the
// capsule pass, so its double-click can shrink it, but they still extend the gate, so a fast
// continuation of any sequence cannot press Stop either.
- (NSEvent *)filterRevealInput:(NSEvent *)input gate:(CRDStopGestureGate *)gate {
    NSPanel *panel=self.stopRevealPanel;
    if(!gate) return input;
    if(input.window==overlay.controller.window) return [gate filterEvent:input];
    if(!panel||input.window!=panel) return input;
    if(input.type==NSEventTypeLeftMouseDown)
        self.revealGuardedSequence=NSPointInRect([panel.contentView convertPoint:input.locationInWindow fromView:nil],self.revealStopZone);
    if(self.revealGuardedSequence) return [gate filterEvent:input];
    [gate recordGesture:input]; // The down and any delivered up of a non-Stop press.
    return input;
}
// Closes the capsule when the window was lost, the session changed, or mode or layout changed.
- (void)validateStopRevealForToken:(NSDictionary *)token modeSignature:(NSString *)signature windowDetected:(BOOL)detected {
    BOOL sameTarget=(!self.revealToken&&!token)||SameStopToken(self.revealToken,token);
    if(self.stopRevealPanel&&(!detected||!sameTarget||![signature isEqual:self.revealModeSignature])) [self closeStopReveal:@"target-or-mode-changed"];
}
// Closes the capsule: cancels any open menu, the timer and the input monitor, disables Stop at
// once, and gives the window back its configured look and input. The inline Stop that comes back
// under the pointer is gated like any other Stop that appears. A timeout or a fold by the user
// animates when motion is allowed: the dot slides back in dot layout, and the capsule fades out
// while the window fades in on the other shapes.
- (void)closeStopReveal:(NSString *)reason {
    [activeContextMenu cancel]; // A menu must not outlive its dot/panel/session anchor.
    if(self.revealTimer) { dispatch_source_cancel(self.revealTimer); self.revealTimer=nil; }
    if(self.revealInputMonitor) { [NSEvent removeMonitor:self.revealInputMonitor]; self.revealInputMonitor=nil; }
    self.revealStopButton.enabled=NO; self.revealStopButton.contextMenuProvider=nil; self.revealDot.contextMenuProvider=nil;
    NSUInteger generation=++self.revealGeneration;
    NSPanel *panel=self.stopRevealPanel; if(!panel) return;
    BOOL hidesWindow=self.revealHidesWindow;
    NSWindow *anchorWindow=overlay.controller.window;
    CGFloat windowAlpha=[currentConfig[@"opacity"] doubleValue];
    __weak CRDOverlayCoordinator *weakSelf=self;
    void (^closed)(void)=^{
        CRDOverlayCoordinator *strongSelf=weakSelf;
        if(!strongSelf||strongSelf.stopRevealPanel!=panel||strongSelf.revealGeneration!=generation) return;
        [panel orderOut:nil]; strongSelf.stopRevealPanel=nil; strongSelf.revealStopButton=nil; strongSelf.revealDot=nil; strongSelf.revealToken=nil; strongSelf.revealModeSignature=nil;
        strongSelf.revealHidesWindow=NO;
        overlay.dot.alphaValue=strongSelf.revealSavedDotAlpha;
        anchorWindow.ignoresMouseEvents=strongSelf.revealSavedIgnoresMouseEvents;
        if(hidesWindow) anchorWindow.alphaValue=windowAlpha;
        overlay.customView.suppressBackground=NO; anchorWindow.hasShadow=[currentConfig[@"shadow"] boolValue]; [overlay.customView setNeedsDisplay:YES];
        BlockInlineStop();
        WriteRuntimeStatus([@"stop-reveal-closed-" stringByAppendingString:reason],nil);
    };
    if(([reason isEqual:@"timeout"]||[reason isEqual:@"user-collapsed"])&&RevealAnimationsEnabled()) {
        // The disappearing panel must not swallow a new gesture on the original window.
        panel.ignoresMouseEvents=YES; anchorWindow.ignoresMouseEvents=self.revealSavedIgnoresMouseEvents;
        BlockInlineStop();
        NSRect anchor=anchorWindow.frame; CGFloat diameter=self.revealDot.dotDiameter;
        NSRect center=NSMakeRect((anchor.size.width-diameter)/2,(anchor.size.height-diameter)/2,diameter,diameter);
        CRDStatusDot *dot=self.revealDot;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){
            context.duration=CRDRevealCloseDuration;
            if(hidesWindow) { [[panel animator] setAlphaValue:0]; [[anchorWindow animator] setAlphaValue:windowAlpha]; return; }
            [[panel animator] setFrame:anchor display:YES];
            [[dot animator] setFrame:center];
            for(NSView *view in panel.contentView.subviews) if(view!=dot) [[view animator] setAlphaValue:0];
        } completionHandler:closed];
    } else closed();
}

#pragma mark - Coordinator: menu actions
// Menu commands that edit config.json, apply presets and open the settings app.

// Merges changes into config.json under the lock, reloads, and logs the event (or the rejection).
- (void)changeSettings:(NSDictionary *)changes event:(NSString *)event {
    if(!UpdateConfig(^(NSMutableDictionary *next){ [next addEntriesFromDictionary:changes]; })) { WriteRuntimeStatus(@"menu-configuration-edit-rejected",nil); return; }
    CRDReload(); WriteRuntimeStatus(event,nil);
}
- (void)toggleEnabled:(id)sender { [self changeSettings:@{@"enabled":@(!SettingsEnabled())} event:@"menu-enabled-toggled"]; }
- (void)selectMode:(NSMenuItem *)sender { [self changeSettings:@{@"mode":sender.representedObject} event:@"menu-mode-selected"]; }
- (void)centerOverlay:(id)sender { [self changeSettings:@{@"placement":@"center"} event:@"menu-center-selected"]; }
// Position lock (위치 잠금) is draggable off and size lock (크기 잠금) is resizable off; no extra settings keys.
- (void)togglePositionLock:(id)sender { [self changeSettings:@{@"draggable":@(![currentConfig[@"draggable"] boolValue])} event:@"menu-position-lock-toggled"]; }
- (void)toggleSizeLock:(id)sender { [self changeSettings:@{@"resizable":@(![currentConfig[@"resizable"] boolValue])} event:@"menu-size-lock-toggled"]; }
// Applies a preset in one locked config write that never touches mode or enabled (PresetValues drops them),
// then the usual placement rules, clamped to the visible frame of the preset's screen or the main one.
- (void)applyPreset:(NSMenuItem *)sender {
    NSDictionary *values=PresetValues(sender.representedObject);
    if(!values) { WriteRuntimeStatus(@"menu-preset-rejected",nil); return; }
    NSArray<NSValue *> *frames=VisibleFrames();
    // The reachable position is part of the one locked write, so later reloads keep it.
    if(!UpdateConfig(^(NSMutableDictionary *next){ [next addEntriesFromDictionary:values]; [next addEntriesFromDictionary:ReachablePlacement(next,frames)]; })) {
        WriteRuntimeStatus(@"menu-configuration-edit-rejected",nil); return;
    }
    CRDReload(); BlockInlineStop(); WriteRuntimeStatus(@"menu-preset-applied",nil);
}
// Opens the settings app: the path recorded at install time, then ~/Applications and
// /Applications, then any app with the settings bundle id.
- (void)openSettings:(id)sender {
    NSString *configured=nil; NSURL *resource=[NSBundle.mainBundle URLForResource:@"original-host" withExtension:@"json"];
    NSData *data=resource?[NSData dataWithContentsOfURL:resource]:nil;
    id metadata=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if([metadata isKindOfClass:NSDictionary.class]&&[metadata[@"settingsAppPath"] isKindOfClass:NSString.class]) configured=metadata[@"settingsAppPath"];
    NSMutableArray *candidates=[NSMutableArray array]; if(configured.length&&configured.isAbsolutePath) [candidates addObject:configured];
    [candidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/CRD Window Studio.app"]];
    [candidates addObject:@"/Applications/CRD Window Studio.app"];
    NSURL *target=nil;
    for(NSString *path in candidates) if([[[NSBundle bundleWithPath:path] bundleIdentifier] isEqual:@"local.crdwindow.studio"]) { target=[NSURL fileURLWithPath:path]; break; }
    if(!target) target=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"local.crdwindow.studio"];
    OpenSettingsApplication(target);
    WriteRuntimeStatus(target?@"settings-open-requested":@"settings-app-not-found",nil);
}

#pragma mark - Coordinator: menus
// The window context menu, the menu bar menu and their shared items.
- (NSMenuItem *)centerMenuItem {
    NSMenuItem *center=[[NSMenuItem alloc] initWithTitle:L(@"가운데로 이동") action:@selector(centerOverlay:) keyEquivalent:@""]; center.target=self;
    center.enabled=[EffectiveMode() isEqual:@"custom"]; return center; // Only the custom window can be moved.
}
// Checked when the window cannot be dragged.
- (NSMenuItem *)positionLockMenuItem {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:L(@"위치 잠금") action:@selector(togglePositionLock:) keyEquivalent:@""]; item.target=self;
    item.state=[currentConfig[@"draggable"] boolValue]?NSControlStateValueOff:NSControlStateValueOn; return item;
}
// Checked when the window cannot be resized.
- (NSMenuItem *)sizeLockMenuItem {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:L(@"크기 잠금") action:@selector(toggleSizeLock:) keyEquivalent:@""]; item.target=self;
    item.state=[currentConfig[@"resizable"] boolValue]?NSControlStateValueOff:NSControlStateValueOn; return item;
}
// A Presets submenu with a check on the preset that matches the current settings.
- (NSMenuItem *)presetsMenuItem {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:L(@"프리셋") action:nil keyEquivalent:@""];
    NSMenu *submenu=[NSMenu new]; submenu.autoenablesItems=NO;
    NSArray<NSDictionary *> *presets=ReadPresets();
    for(NSDictionary *preset in presets) {
        // Preset names are the user's own text and never go through the catalog.
        NSMenuItem *entry=[[NSMenuItem alloc] initWithTitle:preset[@"name"] action:@selector(applyPreset:) keyEquivalent:@""];
        entry.target=self; entry.representedObject=preset[@"values"];
        entry.state=PresetMatches(preset[@"values"],currentConfig)?NSControlStateValueOn:NSControlStateValueOff;
        [submenu addItem:entry];
    }
    if(!presets.count) { NSMenuItem *none=[[NSMenuItem alloc] initWithTitle:L(@"저장된 프리셋 없음") action:nil keyEquivalent:@""]; none.enabled=NO; [submenu addItem:none]; }
    item.submenu=submenu; return item;
}
// Adds center, the two locks and presets.
- (void)addWindowControlItems:(NSMenu *)menu {
    [menu addItem:[self centerMenuItem]]; [menu addItem:[self positionLockMenuItem]]; [menu addItem:[self sizeLockMenuItem]]; [menu addItem:[self presetsMenuItem]];
}
- (NSMenuItem *)settingsMenuItem {
    NSMenuItem *settings=[[NSMenuItem alloc] initWithTitle:L(@"설정 열기") action:@selector(openSettings:) keyEquivalent:@""]; settings.target=self; return settings;
}
// The custom window's own menu. The stop item keeps its fresh validation.
// The same order as the menu bar menu where the items exist: window controls, settings, stop.
- (NSMenu *)windowContextMenu {
    NSMenu *menu=[self stopContextMenu];
    NSMenuItem *stop=menu.itemArray.firstObject; [menu removeItem:stop];
    [self addWindowControlItems:menu];
    [menu addItem:NSMenuItem.separatorItem]; [menu addItem:[self settingsMenuItem]];
    [menu addItem:NSMenuItem.separatorItem]; [menu addItem:stop];
    return menu;
}
// Rebuilds the menu bar menu when it opens: status line; the switch; the two modes; center, the
// locks and presets; settings; stop. Each group has a separator before it.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self refreshTrust];
    [menu removeAllItems]; menu.autoenablesItems=NO;
    BOOL attention=NO; NSString *status=StatusLine(self.trusted,self.restorationBlocked,SettingsEnabled(),EffectiveMode(),self.windowDetected,nil,&attention);
    NSMenuItem *line=[[NSMenuItem alloc] initWithTitle:status action:attention?@selector(openSettings:):nil keyEquivalent:@""];
    line.target=attention?self:nil; line.enabled=attention; [menu addItem:line];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *enabled=[[NSMenuItem alloc] initWithTitle:L(@"공유 창 바꾸기") action:@selector(toggleEnabled:) keyEquivalent:@""]; enabled.target=self; enabled.state=SettingsEnabled()?NSControlStateValueOn:NSControlStateValueOff; [menu addItem:enabled];
    [menu addItem:NSMenuItem.separatorItem];
    NSMutableDictionary *titles=[NSMutableDictionary dictionary];
    for(NSDictionary *choice in Schema()[@"choices"][@"mode"]) titles[choice[@"id"]]=choice[@"title"];
    for(NSString *mode in @[@"custom",@"original"]) {
        if(!titles[mode]) continue;
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:L(titles[mode]) action:@selector(selectMode:) keyEquivalent:@""]; item.target=self; item.representedObject=mode;
        item.state=[currentConfig[@"mode"] isEqual:mode]?NSControlStateValueOn:NSControlStateValueOff;
        item.enabled=SettingsEnabled(); [menu addItem:item]; // The saved mode has no effect while the switch is off.
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self addWindowControlItems:menu];
    [menu addItem:NSMenuItem.separatorItem]; [menu addItem:[self settingsMenuItem]];
    [menu addItem:NSMenuItem.separatorItem]; [menu addItem:[self stopMenuItem]];
}
// Updates the menu bar icon, tooltip and accessibility label from the status line.
- (void)refreshStatusItem {
    if(!self.statusItem) return;
    NSString *symbol=nil; NSString *status=StatusLine(self.trusted,self.restorationBlocked,SettingsEnabled(),EffectiveMode(),self.windowDetected,&symbol,nil);
    NSImage *image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:status]?:[NSImage imageWithSystemSymbolName:@"rectangle.badge.person.crop" accessibilityDescription:status];
    [image setTemplate:YES]; self.statusItem.button.image=image;
    self.statusItem.button.toolTip=status; self.statusItem.button.accessibilityLabel=status;
}
// Creates the menu bar item with its attached menu.
- (void)createStatusItem {
    self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    [self refreshStatusItem];
    // AppKit positions attached status menus within the visible screen for both mouse buttons.
    // A manual popup above the button can hide the first item behind the menu scroll arrow.
    self.statusItem.menu=[self statusMenu];
}
// The menu bar menu; this coordinator is its delegate and observes its end of tracking.
- (NSMenu *)statusMenu {
    NSMenu *menu=[NSMenu new]; menu.autoenablesItems=NO; menu.delegate=self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(statusMenuDidEndTracking:) name:NSMenuDidEndTrackingNotification object:menu];
    return menu;
}
// Blocks the inline Stop and the capsule's Stop when the status menu closes, as the window menu
// does in PresentStopContextMenu. The click that chose an item, and a quick click after it, may
// land on an inline Stop that the action left in place, moved or showed, and macOS can report
// that click as a fresh count-1 click in the helper window.
// AppKit sends both the delegate close and the end-of-tracking notification; either one blocks.
- (void)blockStopAfterStatusMenu {
    BlockInlineStop();
    [self.revealStopButton.stopGestureGate blockFrom:NSProcessInfo.processInfo.systemUptime];
}
- (void)menuDidClose:(NSMenu *)menu { [self blockStopAfterStatusMenu]; }
- (void)statusMenuDidEndTracking:(NSNotification *)notification { [self blockStopAfterStatusMenu]; }

#pragma mark - Coordinator: launch, recovery and exit
// Startup recovery of an earlier hide, launch wiring, and a clean exit that restores the host.

// Reads the restore journal at launch. A pending entry blocks restoration until the recorded
// host is unhidden or provably ended. Without a journal, a runtime status that reports a hidden
// host also blocks it. A malformed journal blocks restoration; restoration-only mode needs one.
- (void)recoverPreviousHide {
    NSData *data=[NSData dataWithContentsOfFile:RestorePath()];
    if(!data) {
        if(self.restorationOnly) { self.restorationBlocked=YES; return; }
        NSString *runtime=[CRDConfigPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"runtime-status.json"];
        NSData *previous=[NSData dataWithContentsOfFile:runtime];
        NSDictionary *status=previous?[NSJSONSerialization JSONObjectWithData:previous options:0 error:nil]:nil;
        BOOL legacyHidden=[status isKindOfClass:NSDictionary.class]&&
            ([status[@"originalHidden"] isEqual:@YES]||[status[@"restorationPending"] isEqual:@YES]);
        if([NSFileManager.defaultManager fileExistsAtPath:RestorePath()]||legacyHidden||!CompleteRestore(self)) self.restorationBlocked=YES;
        return;
    }
    NSDictionary *intent=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![intent isKindOfClass:NSDictionary.class]||!IsBoolean(intent[@"pending"])) { self.restorationBlocked=YES; return; }
    self.restoreIntent=intent;
    if(![intent[@"pending"] boolValue]) return;
    self.restorationBlocked=YES;
    if(!IsNumber(intent[@"pid"])||![intent[@"birth"] isKindOfClass:NSString.class]||![intent[@"birth"] length]||
       ![intent[@"executable"] isEqual:self.hostExecutablePath]) return;
    double recordedPID=[intent[@"pid"] doubleValue];
    if(recordedPID<1||recordedPID>INT_MAX||floor(recordedPID)!=recordedPID) return;
    pid_t pid=(pid_t)recordedPID;
    NSString *birth=ProcessBirth(pid);
    if(OriginalProcessEnded(pid,birth,intent[@"birth"])) { CompleteRestore(self); return; }
    NSRunningApplication *original=fixtureMode?fixtureApplication:[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!birth||!OriginalIdentity(original,self.hostExecutablePath)) return;
    [self bindOriginal:original]; self.ownsHidden=YES;
    if(self.trusted) SetOriginalHidden(self,NO);
}
// Removes the temporary capsule before a display change repositions its anchor. System layout
// invalidates pending geometry instead of turning a screen change into a saved user move.
- (void)screenParametersChanged {
    [self closeStopReveal:@"screens-changed"];
    ApplyOverlay(YES); [self scheduleReconcile:@"screens-changed"];
}
// Starts the helper: event log, journal recovery, refresh notification, overlay, menu bar item,
// config watchers, host launch/terminate and screen observers, and SIGTERM/SIGINT handlers
// that exit cleanly.
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.trusted=CurrentTrust(); self.lastEvent=@"agent-started";
    NSString *logPath=[CRDConfigPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"logs/events.jsonl"];
    eventLog=[[CRDEventLog alloc] initWithPath:logPath]; [eventLog maintain];
    [self recoverPreviousHide];
    __weak CRDOverlayCoordinator *weakSelf=self;
    int refreshToken=NOTIFY_TOKEN_INVALID;
    self.refreshRegistered=notify_register_dispatch(RefreshNotification(NO).UTF8String,&refreshToken,dispatch_get_main_queue(),^(int token){ [weakSelf requestReconcile]; })==NOTIFY_STATUS_OK;
    self.refreshNotifyToken=refreshToken;
    CreateOverlay(); [self createStatusItem]; StartWatchers(); CRDReload();
    self.launchObserver=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidLaunchApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
        NSRunningApplication *application=n.userInfo[NSWorkspaceApplicationKey];
        if([application.bundleIdentifier isEqual:@"com.google.chromeremotedesktop.me2me-host"]) [self scheduleReconcile:@"original-launched"];
    }];
    self.terminateObserver=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidTerminateApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
        NSRunningApplication *application=n.userInfo[NSWorkspaceApplicationKey];
        if(application.processIdentifier==self.original.processIdentifier) { [self releaseOriginal]; [self scheduleReconcile:@"original-terminated"]; }
    }];
    self.screenObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
        [self screenParametersChanged];
    }];
    self.workspaceReady=self.launchObserver!=nil&&self.terminateObserver!=nil;
    signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN);
    self.terminateSignal=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    self.interruptSignal=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
    for(dispatch_source_t source in @[self.terminateSignal,self.interruptSignal]) {
        dispatch_source_set_event_handler(source,^{ [self cleanExit]; [NSApp terminate:nil]; }); dispatch_resume(source);
    }
    [self reconcile];
}
// Restores the host before optional persistence, then removes the helper UI. Geometry gets
// one nonblocking save attempt; shutdown never waits for another configuration writer.
- (void)cleanExit {
    if(self.stopping) return; self.stopping=YES;
    if(self.refreshRegistered) { notify_cancel(self.refreshNotifyToken); self.refreshRegistered=NO; }
    self.refreshRequested=NO;
    self.observerRetryGeneration++;
    [self releaseOriginal];
    PersistGeometry(overlay,NO); InvalidateGeometry();
    [self closeStopReveal:@"agent-stopped"];
    if(self.statusItem) { [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem]; self.statusItem=nil; }
    [overlay.controller.window orderOut:nil]; overlay.shown=NO;
    WriteRuntimeStatus(@"agent-stopped",nil);
}
// Exits with status 1 while restoration is still owed, so launchd can start the helper again.
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self cleanExit];
    if(self.ownsHidden||self.restorationBlocked) exit(1); // launchd can retry; journal survives bootout too.
}
@end

#pragma mark - Self-test helpers
// Run loop, watcher, snapshot and menu dump helpers used by the isolated self-test.

// Runs the main run loop for a number of seconds.
static void RunFor(NSTimeInterval seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(until.timeIntervalSinceNow>0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
}
// Runs the main run loop in short steps until `condition` holds or `limit` seconds pass, for checks
// that wait for an animation or a timer; a slow machine only takes longer. Returns the condition.
static BOOL RunUntil(NSTimeInterval limit,BOOL (^condition)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:limit];
    while(!condition()) {
        if(deadline.timeIntervalSinceNow<=0) return NO;
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    }
    return YES;
}
// Cancels the config file and folder watchers.
static void StopWatchers(void) {
    if(fileWatcher) { dispatch_source_cancel(fileWatcher); fileWatcher=nil; }
    if(directoryWatcher) { dispatch_source_cancel(directoryWatcher); directoryWatcher=nil; }
    if(parentWatcher) { dispatch_source_cancel(parentWatcher); parentWatcher=nil; }
}
// Writes a PNG snapshot of a view: only inside the isolated self-test, only when CRD_OVERLAY_SNAPSHOTS names an
// absolute folder. Views are cached offscreen at 2x on a neutral backdrop; nothing is ordered in.
static void WriteViewSnapshot(NSView *view,NSString *directory,NSString *name) {
    if(!view||NSIsEmptyRect(view.bounds)) return;
    NSRect bounds=view.bounds; CGFloat pad=16,scale=2;
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(bounds.size.width*scale) pixelsHigh:(NSInteger)(bounds.size.height*scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size=bounds.size; [view cacheDisplayInRect:bounds toBitmapImageRep:rep];
    NSSize size=NSMakeSize(bounds.size.width+2*pad,bounds.size.height+2*pad);
    NSBitmapImageRep *canvas=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(size.width*scale) pixelsHigh:(NSInteger)(size.height*scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    canvas.size=size;
    [NSGraphicsContext saveGraphicsState]; NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
    [[NSColor colorWithSRGBRed:.55 green:.61 blue:.69 alpha:1] setFill]; NSRectFill(NSMakeRect(0,0,size.width,size.height));
    [rep drawInRect:NSMakeRect(pad,pad,bounds.size.width,bounds.size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    [[canvas representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
// Appends a plain-text dump of a menu (state, title, disabled, submenu) for snapshot output.
static void AppendMenuText(NSMenu *menu,NSMutableString *text,NSString *indent) {
    for(NSMenuItem *item in menu.itemArray) {
        if(item.separatorItem) { [text appendFormat:@"%@----\n",indent]; continue; }
        [text appendFormat:@"%@%@%@%@%@\n",indent,item.state==NSControlStateValueOn?@"[x] ":@"[ ] ",item.title,item.enabled?@"":@"  (disabled)",item.submenu?@"  >":@""];
        if(item.submenu) AppendMenuText(item.submenu,text,[indent stringByAppendingString:@"    "]);
    }
}

#pragma mark - Overlay self-test
// The isolated self-test behind --crd-overlay-self-test. It uses a temporary config folder,
// fixture AX, process and journal boundaries, and hidden windows; it never touches the real
// CRD host, real permissions or real input. It prints each check and returns nonzero on failure.
static int OverlaySelfTest(NSDictionary *(*permissionOptions)(int,const char *const *)) {
    fixtureMode=YES; previewMode=YES;
    fixtureProcessUID=@(getuid());
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"crd-overlay-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    setenv("CRD_WINDOW_CONFIG",[dir stringByAppendingPathComponent:@"config.json"].fileSystemRepresentation,1);
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    coordinator=[CRDOverlayCoordinator new]; currentConfig=CRDDefaults(); lastConfigReloadDate=NSDate.date;
    CreateOverlay(); StartWatchers(); CRDReload();
    NSMutableArray *checks=[NSMutableArray array];
    NSMutableDictionary *measurements=[NSMutableDictionary dictionary];
    auto check=[&](NSString *name,BOOL passed){ [checks addObject:@{@"name":name,@"passed":@(passed)}]; };
    // Exercise the actual argument parser only; neither trust API is called by these checks.
    const char *plainArgs[]={"fixture","--crd-permission-status"};
    const char *promptArgs[]={"fixture","--crd-permission-status","--prompt"};
    NSDictionary *plainOptions=permissionOptions(2,plainArgs),*promptOptions=permissionOptions(3,promptArgs);
    check(@"permission_status_is_non_prompting_by_default",plainOptions!=nil&&plainOptions.count==0);
    id promptValue=promptOptions[(__bridge NSString *)kAXTrustedCheckOptionPrompt];
    check(@"permission_prompt_is_explicit_cfboolean_true",promptOptions.count==1&&promptValue&&
          CFGetTypeID((__bridge CFTypeRef)promptValue)==CFBooleanGetTypeID()&&[promptValue isEqual:@YES]);
    const char *invalidArgs[][5]={{"fixture"},{"fixture","--crd-overlay-self-test"},{"fixture","--prompt","--crd-permission-status"},
        {"fixture","--crd-permission-status","--prompt","extra"},{"fixture","--crd-permission-status","--other"},
        {"fixture","--crd-permission-status","--prompt","--crd-overlay-self-test"}};
    const int invalidCounts[]={1,2,3,4,3,4};
    BOOL invalidRejected=YES;
    for(size_t i=0;i<sizeof(invalidCounts)/sizeof(invalidCounts[0]);i++) invalidRejected=invalidRejected&&permissionOptions(invalidCounts[i],invalidArgs[i])==nil;
    check(@"permission_prompt_rejects_other_argument_sequences",invalidRejected);
    auto apply=[&](NSDictionary *config){ currentConfig=Validate(config,nil); ApplyOverlay(YES); };
    // The tracking loop reads queued fixture events in screen coordinates (window number 0).
    NSMutableArray<NSEvent *> *trackingQueue=[NSMutableArray array];
    fixtureNextTrackingEvent=^NSEvent *{
        if(!trackingQueue.count) return nil;
        NSEvent *next=trackingQueue.firstObject; [trackingQueue removeObjectAtIndex:0]; return next;
    };
    auto mouseAt=[](NSEventType type,NSPoint point,NSInteger count,NSTimeInterval timestamp,NSInteger windowNumber)->NSEvent * {
        return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:timestamp windowNumber:windowNumber context:nil eventNumber:1 clickCount:count pressure:type==NSEventTypeLeftMouseUp?0:1];
    };
    // A press at a point, drags along the path, then the release at the last point.
    auto press=[&](NSView *view,NSPoint point,NSArray<NSValue *> *path,NSInteger count) {
        [trackingQueue removeAllObjects]; NSPoint last=point;
        for(NSValue *step in path) { last=step.pointValue; [trackingQueue addObject:mouseAt(NSEventTypeLeftMouseDragged,last,count,0,0)]; }
        [trackingQueue addObject:mouseAt(NSEventTypeLeftMouseUp,last,count,0,0)];
        [view mouseDown:mouseAt(NSEventTypeLeftMouseDown,point,count,0,0)];
    };
    auto at=[](CGFloat x,CGFloat y){ return [NSValue valueWithPoint:NSMakePoint(x,y)]; };
    check(@"first_run_defaults_to_custom_mode",[currentConfig[@"mode"] isEqual:@"custom"]&&[CRDDefaults()[@"mode"] isEqual:@"custom"]);
    // A saved hidden mode loads as custom with no error, and the next write saves custom.
    // The file part runs on its own temporary config path, so the fixture's config is untouched.
    {
        NSString *migrationError=nil; NSDictionary *migrated=Validate(@{@"mode":@"hidden",@"width":@321},&migrationError);
        NSString *fixturePath=CRDConfigPath(),*migrationPath=[dir stringByAppendingPathComponent:@"migration/config.json"];
        [NSFileManager.defaultManager createDirectoryAtPath:migrationPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [@"{\"schema\":1,\"mode\":\"hidden\",\"width\":321}" writeToFile:migrationPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        setenv("CRD_WINDOW_CONFIG",migrationPath.fileSystemRepresentation,1);
        NSString *readError=nil; NSDictionary *read=CRDReadConfig(&readError);
        NSDictionary *written=UpdateConfig(^(NSMutableDictionary *next){ next[@"height"]=@44; });
        NSDictionary *onDisk=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:migrationPath] options:0 error:nil];
        setenv("CRD_WINDOW_CONFIG",fixturePath.fileSystemRepresentation,1);
        check(@"saved_hidden_mode_loads_as_custom_and_next_write_saves_custom",migrated&&!migrationError&&[migrated[@"mode"] isEqual:@"custom"]&&[migrated[@"width"] isEqual:@321]&&
            read&&!readError&&[read[@"mode"] isEqual:@"custom"]&&[written[@"mode"] isEqual:@"custom"]&&[onDisk[@"mode"] isEqual:@"custom"]&&[onDisk[@"width"] isEqual:@321]&&
            ![ChoiceIDs(@"mode") containsObject:@"hidden"]&&[ChoiceIDs(@"mode") isEqual:@[@"custom",@"original"]]&&[CRDConfigPath() isEqual:fixturePath]);
    }
    NSMutableDictionary *d=[CRDDefaults() mutableCopy]; d[@"mode"]=@"custom"; apply(d);
    NSString *stopKey=@"공유 중지",*messageKey=@"화면을 공유하고 있습니다";
    NSString *translatedStop=LocalizationCatalog()[@"en"][stopKey];
    check(@"english_native_caption_comes_from_shared_catalog",translatedStop.length>0&&![translatedStop isEqual:stopKey]&&[LocalizedForLanguage(stopKey,@"en") isEqual:translatedStop]);
    check(@"studio_explicit_app_language_overrides_helper_without_preference_writes",[LocalizationLanguageWithStudioOverride(@[@"en-US"],@[@"ko-KR"]) isEqual:@"en"]&&[LocalizationLanguageWithStudioOverride(@[@"ko-KR"],@[@"en-US"]) isEqual:@"ko"]);
    check(@"missing_or_malformed_studio_language_uses_system_fallback",[LocalizationLanguageWithStudioOverride(nil,@[@"ko-KR"]) isEqual:@"ko"]&&[LocalizationLanguageWithStudioOverride(@[],@[@"en-US"]) isEqual:@"en"]&&[LocalizationLanguageWithStudioOverride(@[@1],@[@"ko-KR"]) isEqual:@"ko"]);
    check(@"native_language_resolution_matches_shared_core",[LocalizationLanguageForPreferences(@[@"ko-KR",@"en-US"]) isEqual:@"ko"]&&[LocalizationLanguageForPreferences(@[@"en-US",@"ko-KR"]) isEqual:@"en"]&&[LocalizationLanguageForPreferences(@[@"fr-FR"]) isEqual:@"en"]);
    check(@"korean_native_caption_and_unknown_locale_fallback",[LocalizedForLanguage(stopKey,@"ko-KR") isEqual:stopKey]&&[LocalizedForLanguage(stopKey,@"fr") isEqual:translatedStop]);
    check(@"default_and_blank_native_captions_localize",[ConfiguredTextForLanguage(@"",@"buttonText",stopKey,@"en") isEqual:translatedStop]&&[ConfiguredTextForLanguage(stopKey,@"buttonText",stopKey,@"en") isEqual:translatedStop]&&[ConfiguredTextForLanguage(@"",@"text",messageKey,@"en") isEqual:LocalizationCatalog()[@"en"][messageKey]]);
    check(@"custom_user_captions_are_preserved_in_both_languages",[ConfiguredTextForLanguage(@"fixture custom stop",@"buttonText",stopKey,@"en") isEqual:@"fixture custom stop"]&&[ConfiguredTextForLanguage(@"사용자 지정 문구",@"text",messageKey,@"en") isEqual:@"사용자 지정 문구"]&&[ConfiguredTextForLanguage(@"fixture custom stop",@"buttonText",stopKey,@"ko") isEqual:@"fixture custom stop"]);
    fixtureLanguage=@"en"; apply(d);
    NSMenu *englishMenu=[NSMenu new]; [coordinator menuNeedsUpdate:englishMenu];
    check(@"english_native_controls_use_catalog_without_rewriting_config",[overlay.stop.title isEqual:translatedStop]&&[overlay.label.stringValue isEqual:LocalizationCatalog()[@"en"][messageKey]]&&[englishMenu itemWithTitle:LocalizationCatalog()[@"en"][@"설정 열기"]]!=nil&&[englishMenu.itemArray.lastObject.title isEqual:translatedStop]&&[currentConfig[@"buttonText"] isEqual:CRDDefaults()[@"buttonText"]]);
    fixtureLanguage=nil; apply(d);
    check(@"standalone_panel_has_no_google_dependency",[overlay.controller.window isKindOfClass:CRDOverlayPanel.class]&&NSClassFromString(@"DisconnectWindowController")==Nil);
    check(@"native_stop_disabled_without_original",!overlay.stop.enabled&&coordinator.original==nil);
    check(@"schema_semantic_defaults",[d[@"background"] isEqual:@"system"]&&[d[@"foreground"] isEqual:@"system"]&&[d[@"accent"] isEqual:@"system"]);
    NSRect visible=SelectedScreen(d).visibleFrame,frame=overlay.controller.window.frame;
    check(@"default_center_placement",fabs(NSMidX(frame)-NSMidX(visible))<=.51&&fabs(NSMidY(frame)-NSMidY(visible))<=.51);
    d[@"placement"]=@"custom"; d[@"constrainToScreen"]=@NO; d[@"width"]=@317; d[@"height"]=@73; d[@"x"]=@52; d[@"y"]=@111; apply(d); frame=overlay.controller.window.frame;
    check(@"exact_custom_geometry",frame.size.width==317&&frame.size.height==73&&fabs(frame.origin.x-NSMinX(visible)-52)<.1&&fabs(NSMaxY(visible)-NSMaxY(frame)-111)<.1);
    d[@"placement"]=@"top"; apply(d); check(@"top_visible_frame",fabs(NSMaxY(visible)-NSMaxY(overlay.controller.window.frame)-[d[@"edgeInset"] doubleValue])<.1);
    d[@"placement"]=@"bottom"; apply(d); check(@"bottom_visible_frame",fabs(NSMinY(overlay.controller.window.frame)-NSMinY(visible)-[d[@"edgeInset"] doubleValue])<.1);
    for(NSString *appearance in @[@"light",@"dark",@"system"]) {
        d[@"appearance"]=appearance; apply(d);
        NSString *expected=[appearance isEqual:@"light"]?NSAppearanceNameAqua:NSAppearanceNameDarkAqua;
        check([@"appearance_" stringByAppendingString:appearance],[appearance isEqual:@"system"]?overlay.controller.window.appearance==nil:[overlay.controller.window.appearance.name isEqual:expected]);
    }
    BOOL semantic=YES; for(NSString *accent in ChoiceIDs(@"accent")) if(!Validate(@{@"accent":accent},nil)||!Color(accent,@"accent")) semantic=NO;
    check(@"all_semantic_accents",semantic);
    BOOL pointSemantics=YES; for(NSString *value in ChoiceIDs(@"accent")) if(!Validate(@{@"dotColor":value},nil)||!DotColor(Validate(@{@"dotColor":value},nil))) pointSemantics=NO;
    check(@"dot_color_accepts_accent_semantics_and_custom_hex",pointSemantics&&Validate(@{@"dotColor":@"accent"},nil)!=nil&&Validate(@{@"dotColor":@"#1234EF"},nil)!=nil);
    check(@"dot_color_inheritance_keyword_is_field_specific",Validate(@{@"dotColor":@"accent"},nil)!=nil&&Validate(@{@"accent":@"accent"},nil)==nil&&Validate(@{@"background":@"accent"},nil)==nil&&Validate(@{@"foreground":@"accent"},nil)==nil&&Validate(@{@"dotColor":@"invalid"},nil)==nil);
    NSMutableDictionary *pointColors=[CRDDefaults() mutableCopy]; pointColors[@"mode"]=@"custom"; pointColors[@"accent"]=@"blue"; pointColors[@"dotColor"]=@"red"; apply(pointColors);
    check(@"point_color_is_independent_of_global_accent_in_row",[overlay.dot.textColor isEqual:NSColor.systemRedColor]&&overlay.stop.hasDestructiveAction&&overlay.stop.contentTintColor==nil&&[currentConfig[@"accent"] isEqual:@"blue"]);
    pointColors[@"layout"]=@"dot"; pointColors[@"width"]=@40; pointColors[@"height"]=@40; apply(pointColors);
    check(@"point_color_is_independent_of_global_accent_in_dot",[overlay.dot.textColor isEqual:NSColor.systemRedColor]&&[currentConfig[@"accent"] isEqual:@"blue"]);
    pointColors[@"dotColor"]=@"accent"; pointColors[@"accent"]=@"green"; apply(pointColors);
    check(@"point_color_restores_accent_inheritance",[overlay.dot.textColor isEqual:NSColor.systemGreenColor]&&[Validate(@{@"accent":@"green"},nil)[@"dotColor"] isEqual:@"accent"]);
    apply(d);
    BOOL shapes=YES,contained=YES;
    for(NSDictionary *shape in Schema()[@"shapes"]) {
        [d addEntriesFromDictionary:shape[@"values"]]; d[@"shape"]=shape[@"id"]; apply(d);
        if(overlay.controller.window.frame.size.width!=[d[@"width"] doubleValue]||overlay.controller.window.frame.size.height!=[d[@"height"] doubleValue]) shapes=NO;
        for(NSView *view in overlay.customView.subviews) if(!view.hidden&&!NSContainsRect(overlay.customView.bounds,view.frame)) contained=NO;
    }
    check(@"all_serialized_shape_presets",shapes); check(@"preset_controls_fit",contained);
    d=[CRDDefaults() mutableCopy]; d[@"mode"]=@"custom";
    BOOL handles=YES;
    for(NSString *position in ChoiceIDs(@"handlePosition")) {
        d[@"handlePosition"]=position; apply(d);
        if(overlay.handle.hidden||!NSContainsRect(overlay.customView.bounds,overlay.handle.frame)) handles=NO;
        for(NSView *view in @[overlay.dot,overlay.label,overlay.stop]) if(!view.hidden&&NSIntersectsRect(view.frame,overlay.handle.frame)) handles=NO;
    }
    check(@"handle_positions_are_visible_and_separate",handles); check(@"explicit_resize_grip",!overlay.resizeHandle.hidden);
    NSMutableDictionary *grip=[d mutableCopy]; grip[@"handlePosition"]=@"leading";
    BOOL gripInside=YES,gripClear=YES;
    for(NSDictionary *shape in Schema()[@"shapes"]) {
        if([shape[@"values"][@"layout"] isEqual:@"dot"]) continue;
        [grip addEntriesFromDictionary:shape[@"values"]]; apply(grip);
        if(overlay.resizeHandle.hidden) continue;
        NSRect g=overlay.resizeHandle.frame; CGFloat inset=GripInset(currentConfig,overlay.customView.bounds.size.width,overlay.customView.bounds.size.height);
        if(fabs(NSMinY(g)-inset)>.01||fabs(NSWidth(overlay.customView.bounds)-NSMaxX(g)-inset)>.01||!NSContainsRect(overlay.customView.bounds,g)) gripInside=NO;
        if([currentConfig[@"layout"] isEqual:@"row"]&&!overlay.stop.hidden&&NSIntersectsRect(overlay.stop.frame,g)) gripClear=NO;
    }
    check(@"resize_grip_inset_by_corner_radius",gripInside); check(@"row_stop_button_clear_of_resize_grip",gripClear);
    grip[@"radius"]=@24; grip[@"height"]=@48; grip[@"width"]=@380; grip[@"layout"]=@"row"; apply(grip);
    check(@"capsule_grip_sits_inside_the_rounded_end",NSMinY(overlay.resizeHandle.frame)==10&&NSMaxX(overlay.resizeHandle.frame)==370);
    check(@"stop_button_is_a_borderless_destructive_pill",overlay.stop.hasDestructiveAction&&!overlay.stop.bordered&&overlay.stop.contentTintColor==nil&&!overlay.stop.enabled&&
        [overlay.stop.font isEqual:StopPillFont(NSFont.systemFontSize)]&&[overlay.stop isKindOfClass:CRDSessionStopButton.class]);
    check(@"caption_and_inline_dot_act_as_background",overlay.customView.passesThrough(overlay.label)&&overlay.customView.passesThrough(overlay.dot)&&!overlay.customView.passesThrough(overlay.stop)&&!overlay.customView.passesThrough(overlay.handle));
    NSEvent *rightClick=[NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSMakePoint(20,20) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:9 clickCount:1 pressure:1];
    NSMenu *windowMenu=[overlay.customView menuForEvent:rightClick];
    check(@"whole_window_menu_is_controls_settings_then_validated_stop",windowMenu.numberOfItems==8&&[windowMenu itemAtIndex:0].action==@selector(centerOverlay:)&&
        [windowMenu itemAtIndex:1].action==@selector(togglePositionLock:)&&[[windowMenu itemAtIndex:1].title isEqual:L(@"위치 잠금")]&&[windowMenu itemAtIndex:2].action==@selector(toggleSizeLock:)&&[[windowMenu itemAtIndex:2].title isEqual:L(@"크기 잠금")]&&
        [[windowMenu itemAtIndex:3].title isEqual:L(@"프리셋")]&&[windowMenu itemAtIndex:3].submenu!=nil&&[windowMenu itemAtIndex:4].separatorItem&&[windowMenu itemAtIndex:5].action==@selector(openSettings:)&&
        [windowMenu itemAtIndex:6].separatorItem&&[windowMenu itemAtIndex:7].action==@selector(stopSharingClicked:)&&![windowMenu itemAtIndex:7].enabled);
    check(@"handle_and_grip_offer_the_window_menu",[overlay.handle menuForEvent:rightClick].numberOfItems==8&&[overlay.resizeHandle menuForEvent:rightClick].numberOfItems==8);
    check(@"inline_dot_has_no_menu_of_its_own",[overlay.dot menuForEvent:rightClick]==nil&&overlay.dot.toolTip==nil);
    d[@"layout"]=@"dot"; d[@"width"]=@40; d[@"height"]=@40;
    d[@"showHandle"]=@YES; d[@"showDot"]=@YES; d[@"handlePosition"]=@"top"; d[@"draggable"]=@YES;
    apply(d);
    check(@"dot_is_centered_without_separate_handles",!overlay.dot.hidden&&overlay.handle.hidden&&overlay.resizeHandle.hidden&&fabs(NSMidX(overlay.dot.frame)-NSMidX(overlay.customView.bounds))<.1&&fabs(NSMidY(overlay.dot.frame)-NSMidY(overlay.customView.bounds))<.1);
    check(@"dot_preserves_show_handle_setting",[currentConfig[@"showHandle"] boolValue]);
    check(@"dot_tooltip_mentions_double_click_and_return",[overlay.dot.toolTip isEqual:L(@"두 번 클릭하면 공유 중지 버튼이 나타나고, 다시 두 번 클릭하면 원래 모양으로 돌아갑니다")]&&!overlay.customView.passesThrough(overlay.dot));
    NSRect oval=overlay.dot.geometricDotRect;
    check(@"dot_oval_bounds_geometric_center",overlay.dot.geometricDot&&fabs(NSMidX(oval)-NSMidX(overlay.dot.bounds))<.001&&fabs(NSMidY(oval)-NSMidY(overlay.dot.bounds))<.001&&fabs(oval.size.width-oval.size.height)<.001);
    overlay.dot.textColor=NSColor.redColor; overlay.dot.stringValue=@"NOT A CIRCLE GLYPH";
    NSBitmapImageRep *dotBitmap=[overlay.dot bitmapImageRepForCachingDisplayInRect:overlay.dot.bounds];
    [overlay.dot cacheDisplayInRect:overlay.dot.bounds toBitmapImageRep:dotBitmap];
    double mass=0,cx=0,cy=0;
    for(NSInteger y=0;y<dotBitmap.pixelsHigh;y++) for(NSInteger x=0;x<dotBitmap.pixelsWide;x++) {
        NSColor *pixel=[[dotBitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if(pixel.redComponent>.6&&pixel.greenComponent<.3&&pixel.blueComponent<.3&&pixel.alphaComponent>.2) { mass++; cx+=x; cy+=y; }
    }
    check(@"dot_raster_center_independent_of_text_baseline",mass>0&&fabs(cx/mass-(dotBitmap.pixelsWide-1)/2.0)<=.51&&fabs(cy/mass-(dotBitmap.pixelsHigh-1)/2.0)<=.51);
    overlay.dot.stringValue=@"●";
    check(@"explicit_dot_diameter_not_background_fraction",fabs(overlay.dot.geometricDotRect.size.width-[currentConfig[@"dotDiameter"] doubleValue])<.001&&NSEqualRects(overlay.dot.frame,overlay.customView.bounds));
    d[@"width"]=@3; d[@"height"]=@5; d[@"fontSize"]=@64; d[@"dotDiameter"]=@10; apply(d);
    check(@"tiny_dot_keeps_full_drag_target_and_clamps_diameter",!overlay.dot.hidden&&NSEqualRects(overlay.dot.frame,overlay.customView.bounds)&&overlay.dot.geometricDotRect.size.width==3);
    d[@"showDot"]=@NO; apply(d); check(@"dot_visibility_setting_respected_at_tiny_size",overlay.dot.hidden);
    d[@"showDot"]=@YES; d[@"width"]=@40; d[@"height"]=@40; d[@"fontSize"]=@0; apply(d);
    NSEvent *fixtureClick=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(20,20) modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
    // Move, lock and double-click: real views, the real window and the helper's own loop with fixture events.
    NSWindow *panelWindow=overlay.controller.window; BOOL wasShown=overlay.shown;
    __block NSUInteger doubleClicks=0; void (^expandAction)(NSEvent *)=overlay.dot.doubleClickAction;
    overlay.dot.doubleClickAction=^(NSEvent *event){ doubleClicks++; }; overlay.customView.doubleClickAction=overlay.dot.doubleClickAction;
    d[@"constrainToScreen"]=@NO; d[@"placement"]=@"center"; apply(d);
    previewMode=NO; overlay.shown=YES; InvalidateGeometry();
    NSRect startFrame=panelWindow.frame; NSPoint grab=NSMakePoint(NSMidX(startFrame),NSMidY(startFrame));
    press(overlay.dot,grab,@[at(grab.x+1,grab.y+1),at(grab.x+2,grab.y)],1);
    check(@"click_without_movement_does_not_move_window",NSEqualRects(panelWindow.frame,startFrame)&&!geometryDirty&&doubleClicks==0);
    press(overlay.dot,grab,@[at(grab.x+2,grab.y),at(grab.x+40,grab.y-25)],1);
    check(@"drag_past_threshold_moves_through_own_loop_and_records_user_geometry",fabs(NSMinX(panelWindow.frame)-NSMinX(startFrame)-40)<.01&&fabs(NSMinY(panelWindow.frame)-NSMinY(startFrame)+25)<.01&&geometryDirty&&NSEqualRects(geometryFrame,panelWindow.frame)&&!userGeometryTracking);
    InvalidateGeometry(); d[@"showDot"]=@NO; apply(d);
    press(overlay.customView,grab,@[at(grab.x-30,grab.y+10)],1);
    check(@"margin_press_moves_window_from_anywhere",fabs(NSMinX(panelWindow.frame)-NSMinX(startFrame)+30)<.01&&fabs(NSMinY(panelWindow.frame)-NSMinY(startFrame)-10)<.01&&geometryDirty);
    InvalidateGeometry(); apply(d);
    press(overlay.customView,NSMakePoint(NSMinX(startFrame)+1,NSMinY(startFrame)+1),@[],2);
    d[@"showDot"]=@YES; apply(d);
    press(overlay.dot,NSMakePoint(NSMaxX(startFrame)-1,NSMaxY(startFrame)-1),@[at(NSMaxX(startFrame)-2,NSMaxY(startFrame)-1)],2);
    check(@"double_click_anywhere_on_dot_window_expands",doubleClicks==2&&NSEqualRects(panelWindow.frame,startFrame)&&!geometryDirty);
    d[@"constrainToScreen"]=@YES; apply(d);
    press(overlay.dot,grab,@[at(grab.x+5,grab.y),at(grab.x+200000,grab.y+200000)],1);
    NSRect clampVisible=(panelWindow.screen?:SelectedScreen(d)).visibleFrame;
    check(@"drag_honors_constrain_to_screen_visible_frame",NSMaxX(panelWindow.frame)<=NSMaxX(clampVisible)+.01&&NSMaxY(panelWindow.frame)<=NSMaxY(clampVisible)+.01&&NSMinX(panelWindow.frame)>=NSMinX(clampVisible)-.01);
    InvalidateGeometry(); d[@"draggable"]=@NO; apply(d); startFrame=panelWindow.frame;
    press(overlay.dot,grab,@[at(grab.x+40,grab.y+40)],1); press(overlay.customView,grab,@[at(grab.x-40,grab.y-40)],1);
    press(overlay.dot,grab,@[],2);
    check(@"position_lock_blocks_drags_but_not_double_click",NSEqualRects(panelWindow.frame,startFrame)&&!geometryDirty&&doubleClicks==3&&!overlay.dot.windowDragEnabled&&!overlay.dot.mouseDownCanMoveWindow);
    d[@"draggable"]=@YES; d[@"resizable"]=@YES; d[@"width"]=@120; d[@"height"]=@120; apply(d);
    BOOL neverResizable=!(panelWindow.styleMask&NSWindowStyleMaskResizable)&&!panelWindow.movable&&!panelWindow.movableByWindowBackground&&overlay.resizeHandle.hidden;
    // Tiling, Stage Manager or a screen change; the configured frame comes back, unsaved.
    InvalidateGeometry(); NSString *beforeSystemResize=FileSignature(); NSUInteger reverts=systemResizeReverts; NSRect configuredFrame=panelWindow.frame;
    [panelWindow setFrame:NSMakeRect(NSMinX(visible),NSMinY(visible),NSWidth(visible)/2,NSHeight(visible)) display:NO]; RunFor(.25);
    check(@"system_resize_is_reverted_and_never_saved",systemResizeReverts==reverts+1&&NSEqualRects(panelWindow.frame,configuredFrame)&&!geometryDirty&&
        ((!beforeSystemResize&&!FileSignature())||[FileSignature() isEqual:beforeSystemResize]));
    // A burst of separately delivered resizes (more than 4 in a second) ends at the configured frame.
    systemResizeWindowStart=0; systemResizeWindowCount=0; reverts=systemResizeReverts;
    for(int burst=0;burst<6;burst++) { [panelWindow setFrame:NSMakeRect(NSMinX(visible),NSMinY(visible),300+burst*4,300) display:NO]; RunFor(.02); }
    BOOL trailingPending=systemResizeRevertPending&&!NSEqualRects(panelWindow.frame,configuredFrame);
    RunFor(1.3); NSUInteger settledReverts=systemResizeReverts; RunFor(.3);
    check(@"system_resize_burst_keeps_one_trailing_correction_and_then_stops",trailingPending&&NSEqualRects(panelWindow.frame,configuredFrame)&&!systemResizeRevertPending&&
        settledReverts==reverts+5&&systemResizeReverts==settledReverts&&!geometryDirty&&((!beforeSystemResize&&!FileSignature())||[FileSignature() isEqual:beforeSystemResize]));
    previewMode=YES; overlay.shown=wasShown; [trackingQueue removeAllObjects];
    overlay.dot.doubleClickAction=expandAction; overlay.customView.doubleClickAction=expandAction;
    d[@"layout"]=@"row"; d[@"width"]=@440; d[@"height"]=@48; d[@"draggable"]=@YES; apply(d);
    check(@"return_to_bar_restores_configured_handles",!overlay.handle.hidden&&!overlay.resizeHandle.hidden&&!overlay.dot.windowDragEnabled);
    check(@"panel_never_resizable_or_server_movable_in_any_layout",neverResizable&&!(panelWindow.styleMask&NSWindowStyleMaskResizable)&&!panelWindow.movable&&!panelWindow.movableByWindowBackground);
    d[@"showHandle"]=@NO; apply(d); check(@"bar_respects_handle_disabled_setting",overlay.handle.hidden&&![currentConfig[@"showHandle"] boolValue]);
    d[@"width"]=@1; d[@"height"]=@1; apply(d);
    check(@"tiny_window_hides_clipped_controls",overlay.label.hidden&&overlay.dot.hidden&&overlay.stop.hidden&&overlay.handle.hidden);
    check(@"reject_unknown",Validate(@{@"unknown":@1},nil)==nil);
    check(@"reject_numeric_boolean",Validate(@{@"width":@YES},nil)==nil&&Validate(@{@"showDot":@1},nil)==nil);
    check(@"reject_malformed_choices",Validate(@{@"shape":@"triangle"},nil)==nil&&Validate(@{@"placement":@"left"},nil)==nil);
    check(@"reject_invalid_color_and_size",Validate(@{@"background":@"red"},nil)==nil&&Validate(@{@"width":@(-1)},nil)==nil);
    d=[CRDDefaults() mutableCopy]; d[@"mode"]=@"custom"; d[@"width"]=@421;
    check(@"atomic_configuration_write",CRDWriteConfig(d,nil)); RunFor(.3);
    check(@"vnode_configuration_reload",overlay.controller.window.frame.size.width==421&&configReloadCount>0);
    [@"{invalid" writeToFile:CRDConfigPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; RunFor(.3);
    check(@"malformed_preserves_last_valid",overlay.controller.window.frame.size.width==421&&[currentConfig[@"mode"] isEqual:@"custom"]);
    CRDWriteConfig(d,nil); RunFor(.3);
    previewMode=NO; overlay.shown=YES;
    BeginUserGeometry(overlay.controller.window);
    [overlay.controller.window setFrameOrigin:NSMakePoint(NSMinX(visible)+80,NSMinY(visible)+90)]; EndUserGeometry(); PersistGeometry(overlay); previewMode=YES;
    NSDictionary *saved=CRDReadConfig(nil);
    check(@"move_preserves_shape_and_sets_custom_placement",[saved[@"shape"] isEqual:d[@"shape"]]&&[saved[@"placement"] isEqual:@"custom"]&&fabs([saved[@"x"] doubleValue]-80)<.1);
    previewMode=NO; BeginUserGeometry(overlay.controller.window); [overlay.controller.window setContentSize:NSMakeSize(500,60)]; EndUserGeometry(); PersistGeometry(overlay); previewMode=YES;
    check(@"resize_changes_shape_to_custom",[CRDReadConfig(nil)[@"shape"] isEqual:@"custom"]);
    apply(saved); check(@"saved_geometry_restores",fabs(overlay.controller.window.frame.origin.x-NSMinX(visible)-80)<.1);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil]; RunFor(.3);
    d[@"width"]=@411; CRDWriteConfig(d,nil); RunFor(.3);
    check(@"directory_recreation_rearms",overlay.controller.window.frame.size.width==411&&directoryWatcher!=nil);
    d[@"width"]=@412;
    NSData *inPlace=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    [inPlace writeToFile:CRDConfigPath() options:0 error:nil]; RunFor(.3);
    check(@"in_place_file_edit_reloads",overlay.controller.window.frame.size.width==412&&fileWatcher!=nil);
    UpdateConfig(^(NSMutableDictionary *value){ value[@"x"]=@123; });
    NSDictionary *merged=UpdateConfig(^(NSMutableDictionary *value){ value[@"height"]=@62; });
    check(@"config_patch_keeps_other_writer_fields",[merged[@"x"] isEqual:@123]&&[merged[@"height"] isEqual:@62]);
    CRDReload();
    RunFor(.2); NSUInteger reads=configReadCount,reconciles=coordinator.reconcileCount; RunFor(1.1);
    check(@"idle_has_no_config_reads",configReadCount==reads); check(@"fixture_never_reconciles_original",coordinator.reconcileCount==0&&reconciles==0&&coordinator.original==nil);
    WriteRuntimeStatus(@"self-test",nil);
    NSData *statusData=[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"runtime-status.json"]];
    NSDictionary *status=[NSJSONSerialization JSONObjectWithData:statusData options:0 error:nil];
    check(@"status_identifies_isolated_fixture",[status[@"backendKind"] isEqual:@"accessibility-overlay"]&&[status[@"fixture"] boolValue]&&status[@"originalPid"]==NSNull.null);
    check(@"status_contains_no_connection_text",!status[@"text"]&&!status[@"email"]&&!status[@"title"]);
    // Logger fixtures use only this test's temporary directory, never user logs.
    NSString *logPath=[dir stringByAppendingPathComponent:@"logs/events.jsonl"];
    CRDEventLog *log=[[CRDEventLog alloc] initWithPath:logPath];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSDictionary *oldRecord=@{@"event":@"old",@"timestampSeconds":@(now-CRDLogRetention-10)};
    NSDictionary *recentRecord=@{@"event":@"recent",@"timestampSeconds":@(now-60)};
    NSMutableArray *seed=[@[oldRecord,recentRecord] mutableCopy]; [log write:[log boundedData:seed]]; [log maintain];
    NSArray *kept=[log readRecords];
    check(@"log_retention_removes_older_than_24h",kept.count==1&&[kept[0][@"event"] isEqual:@"recent"]);
    NSData *beforeDisabled=[NSData dataWithContentsOfFile:logPath]; NSUInteger disabledWrites=log.writeCount;
    [log append:@{@"event":@"disabled",@"timestampSeconds":@(now)} enabled:NO];
    check(@"logging_disabled_does_not_append_or_write",log.writeCount==disabledWrites&&[[NSData dataWithContentsOfFile:logPath] isEqual:beforeDisabled]);
    CRDEventLog *disabledLog=[[CRDEventLog alloc] initWithPath:[dir stringByAppendingPathComponent:@"disabled/events.jsonl"]];
    [disabledLog append:recentRecord enabled:NO];
    check(@"logging_disabled_does_not_create_file",![NSFileManager.defaultManager fileExistsAtPath:disabledLog.path]&&disabledLog.writeCount==0);
    NSUInteger idleLogReads=log.fileReadCount,idleMaintenance=log.maintenanceCount; RunFor(.15);
    check(@"logger_idle_has_no_polling",log.fileReadCount==idleLogReads&&log.maintenanceCount==idleMaintenance&&log.expiryTimer!=nil);
    NSUInteger appendReads=log.fileReadCount; dispatch_source_t originalExpiry=log.expiryTimer;
    for(int i=0;i<50;i++) [log append:@{@"event":@"small",@"timestampSeconds":@(now)} enabled:YES];
    check(@"logger_small_appends_do_not_rescan_or_replace_expiry",log.fileReadCount==appendReads&&log.expiryTimer==originalExpiry);
    NSString *payload=[@"x" stringByPaddingToLength:600000 withString:@"x" startingAtIndex:0];
    [log append:@{@"event":@"cap-old",@"timestampSeconds":@(now),@"fixturePayload":payload} enabled:YES];
    [log append:@{@"event":@"cap-new",@"timestampSeconds":@(now),@"fixturePayload":payload} enabled:YES];
    kept=[log readRecords];
    check(@"logger_1mib_cap_drops_oldest",[[NSFileManager.defaultManager attributesOfItemAtPath:logPath error:nil][NSFileSize] unsignedLongLongValue]<=CRDLogMaxBytes&&kept.count==1&&[kept[0][@"event"] isEqual:@"cap-new"]);
    NSNumber *fileMode=[NSFileManager.defaultManager attributesOfItemAtPath:logPath error:nil][NSFilePosixPermissions];
    NSNumber *dirMode=[NSFileManager.defaultManager attributesOfItemAtPath:logPath.stringByDeletingLastPathComponent error:nil][NSFilePosixPermissions];
    check(@"logger_private_file_and_directory_modes",(fileMode.unsignedIntegerValue&0777)==0600&&(dirMode.unsignedIntegerValue&0777)==0700);
    CRDEventLog *expiryLog=[[CRDEventLog alloc] initWithPath:[dir stringByAppendingPathComponent:@"expiry/events.jsonl"]];
    NSMutableArray *expiring=[@[@{@"event":@"expiring",@"timestampSeconds":@(NSDate.date.timeIntervalSince1970-CRDLogRetention+.15)}] mutableCopy];
    [expiryLog write:[expiryLog boundedData:expiring]]; [expiryLog maintain]; RunFor(.35);
    check(@"logger_one_shot_expiry_removes_record",[expiryLog readRecords].count==0&&expiryLog.expiryTimer==nil&&expiryLog.maintenanceCount==2);
    NSDictionary *snapshot=SettingsSnapshot(); check(@"log_settings_allowlist_excludes_custom_text",!snapshot[@"text"]&&!snapshot[@"buttonText"]&&snapshot[@"width"]&&snapshot[@"layout"]);
    log=nil; expiryLog=nil; disabledLog=nil;
    // Native menus and stop-token logic are tested without an original process.
    CRDContextMenuTracking *tracking=[CRDContextMenuTracking new]; NSMenu *trackingMenu=[NSMenu new];
    NSWindow *contentFixture=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,10,10) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [tracking begin:trackingMenu]; tracking.contentWindows=[NSSet setWithObject:contentFixture];
    check(@"context_dismissal_monitors_exist_only_during_tracking",tracking.active&&tracking.localMonitor!=nil&&tracking.globalMonitor!=nil&&tracking.deactivationObserver!=nil);
    NSEvent *outsideClick=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:contentFixture.windowNumber context:nil eventNumber:3 clickCount:1 pressure:1];
    [tracking handleLocalEvent:outsideClick];
    check(@"context_content_click_requests_tracking_cancellation",tracking.cancellationCount==1);
    NSEvent *escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:53];
    check(@"context_escape_requests_tracking_cancellation",[tracking handleLocalEvent:escape]==nil&&tracking.cancellationCount==2);
    NSWindow *newMenuWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,10,10) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    NSEvent *menuClick=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:newMenuWindow.windowNumber context:nil eventNumber:4 clickCount:1 pressure:1];
    [tracking handleLocalEvent:menuClick];
    check(@"context_does_not_cancel_new_native_menu_window_click",tracking.cancellationCount==2);
    [tracking end]; [contentFixture orderOut:nil];
    check(@"context_tracking_removes_all_monitors_and_observers",!tracking.active&&tracking.localMonitor==nil&&tracking.globalMonitor==nil&&tracking.deactivationObserver==nil&&tracking.menu==nil);
    NSMenu *attachedMenu=[coordinator statusMenu];
    check(@"status_menu_constructed_without_visible_status_item",attachedMenu.delegate==coordinator&&!attachedMenu.autoenablesItems&&coordinator.statusItem==nil);
    [coordinator menuNeedsUpdate:attachedMenu];
    BOOL statusAttention=NO; NSString *statusNow=StatusLine(coordinator.trusted,coordinator.restorationBlocked,SettingsEnabled(),EffectiveMode(),coordinator.windowDetected,nil,&statusAttention);
    check(@"attached_status_menu_starts_with_status_line",[attachedMenu.itemArray.firstObject.title isEqual:statusNow]&&attachedMenu.itemArray.firstObject.enabled==statusAttention&&(!statusAttention||attachedMenu.itemArray.firstObject.action==@selector(openSettings:)));
    NSMenu *statusMenu=[NSMenu new]; [coordinator menuNeedsUpdate:statusMenu];
    NSArray *menuModes=@[[statusMenu itemAtIndex:4].representedObject?:@"",[statusMenu itemAtIndex:5].representedObject?:@""];
    BOOL menuSeparators=YES; for(NSNumber *index in @[@1,@3,@6,@11,@13]) menuSeparators=menuSeparators&&[statusMenu itemAtIndex:index.integerValue].separatorItem;
    NSUInteger separatorCount=0; for(NSMenuItem *item in statusMenu.itemArray) if(item.separatorItem) separatorCount++;
    check(@"native_status_menu_is_status_switch_modes_controls_settings_stop",statusMenu.numberOfItems==15&&separatorCount==5&&menuSeparators&&[menuModes isEqual:@[@"custom",@"original"]]&&
        [statusMenu itemAtIndex:2].action==@selector(toggleEnabled:)&&[statusMenu itemAtIndex:7].action==@selector(centerOverlay:)&&[statusMenu itemAtIndex:8].action==@selector(togglePositionLock:)&&
        [statusMenu itemAtIndex:9].action==@selector(toggleSizeLock:)&&[statusMenu itemAtIndex:10].submenu!=nil&&
        [statusMenu itemAtIndex:12].action==@selector(openSettings:)&&[statusMenu itemAtIndex:14].action==@selector(stopSharingClicked:)&&![statusMenu itemAtIndex:14].enabled);
    BOOL modeChecks=YES; for(NSInteger i=4;i<=5;i++) if(([statusMenu itemAtIndex:i].state==NSControlStateValueOn)!=[currentConfig[@"mode"] isEqual:[statusMenu itemAtIndex:i].representedObject]) modeChecks=NO;
    check(@"status_menu_marks_saved_mode_only",modeChecks);
    NSString *symbol=nil; BOOL flagged=NO;
    BOOL lines=[StatusLine(NO,NO,YES,@"custom",YES,&symbol,&flagged) isEqual:L(PermissionRequiredKey(UsesDeviceControlName()))]&&flagged&&[symbol isEqual:@"exclamationmark.triangle"];
    lines=lines&&[StatusLine(YES,YES,YES,@"custom",NO,&symbol,&flagged) isEqual:L(@"확인 필요")]&&flagged&&[symbol isEqual:@"exclamationmark.triangle"];
    lines=lines&&[StatusLine(YES,NO,NO,@"original",NO,&symbol,&flagged) isEqual:L(@"공유 창 바꾸기 꺼짐")]&&!flagged&&[symbol isEqual:@"rectangle.dashed"];
    lines=lines&&[StatusLine(YES,NO,YES,@"original",YES,&symbol,&flagged) isEqual:L(@"작동 중")]&&!flagged&&[symbol isEqual:@"rectangle.dashed"];
    lines=lines&&[StatusLine(YES,NO,YES,@"custom",YES,&symbol,&flagged) isEqual:L(@"작동 중")]&&[symbol isEqual:@"rectangle.badge.checkmark"];
    lines=lines&&[StatusLine(YES,NO,YES,@"custom",NO,&symbol,&flagged) isEqual:L(@"준비됨")]&&[symbol isEqual:@"rectangle.badge.person.crop"];
    check(@"status_line_and_icon_follow_helper_state",lines);
    BOOL symbols=YES; for(NSString *name in @[@"exclamationmark.triangle",@"rectangle.dashed",@"rectangle.badge.checkmark",@"rectangle.badge.person.crop"]) if(![NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]) symbols=NO;
    check(@"status_icon_symbols_exist",symbols);
    [coordinator refreshStatusItem];
    check(@"status_icon_refresh_without_status_item_is_safe",coordinator.statusItem==nil);
    NSMutableDictionary *disabled=[CRDDefaults() mutableCopy]; disabled[@"mode"]=@"custom"; disabled[@"width"]=@313; disabled[@"enabled"]=@NO;
    apply(disabled); check(@"disabled_settings_use_original_without_overwriting_mode",[EffectiveMode() isEqual:@"original"]&&[currentConfig[@"mode"] isEqual:@"custom"]&&[currentConfig[@"width"] doubleValue]==313);
    CRDWriteConfig(disabled,nil); CRDReload(); [coordinator toggleEnabled:nil];
    check(@"menu_enable_toggle_preserves_mode_and_geometry",SettingsEnabled()&&[currentConfig[@"mode"] isEqual:@"custom"]&&[currentConfig[@"width"] doubleValue]==313);
    CRDWriteConfig(disabled,nil); CRDReload(); NSMenu *offMenu=[NSMenu new]; [coordinator menuNeedsUpdate:offMenu];
    check(@"switch_off_disables_modes_and_center",![offMenu itemAtIndex:4].enabled&&![offMenu itemAtIndex:5].enabled&&[offMenu itemAtIndex:2].state==NSControlStateValueOff&&![offMenu itemAtIndex:7].enabled&&[offMenu itemAtIndex:4].state==NSControlStateValueOn&&![[coordinator windowContextMenu] itemAtIndex:0].enabled);
    [coordinator toggleEnabled:nil];
    // The lock items toggle draggable and resizable through one locked config write.
    NSMenu *lockMenu=[coordinator windowContextMenu];
    BOOL unlockedStates=[lockMenu itemAtIndex:1].state==NSControlStateValueOff&&[lockMenu itemAtIndex:2].state==NSControlStateValueOff;
    [coordinator togglePositionLock:nil]; [coordinator toggleSizeLock:nil];
    NSDictionary *locked=CRDReadConfig(nil); NSMenu *lockedMenu=[coordinator windowContextMenu];
    check(@"lock_menu_items_toggle_draggable_and_resizable_only",unlockedStates&&![locked[@"draggable"] boolValue]&&![locked[@"resizable"] boolValue]&&[lockedMenu itemAtIndex:1].state==NSControlStateValueOn&&[lockedMenu itemAtIndex:2].state==NSControlStateValueOn&&
        [locked[@"mode"] isEqual:@"custom"]&&[locked[@"enabled"] isEqual:@YES]&&[locked[@"width"] isEqual:@313]&&[currentConfig isEqual:locked]);
    [coordinator togglePositionLock:nil]; [coordinator toggleSizeLock:nil];
    // presets.json is read only; values are validated with the config schema.
    NSString *presetsPath=PresetsPath();
    NSMutableArray *fixturePresets=[NSMutableArray array];
    [fixturePresets addObject:@{@"id":@"a",@"name":@"  Left dot  ",@"values":@{@"layout":@"dot",@"shape":@"custom",@"width":@42,@"height":@42,@"radius":@21,@"dotDiameter":@12,@"placement":@"custom",@"x":@60000,@"y":@40,
        @"constrainToScreen":@NO,@"draggable":@NO,@"stopRevealSeconds":@0,@"mode":@"original",@"enabled":@NO,@"loggingEnabled":@NO,@"schema":@99,@"futureKey":@1}}];
    [fixturePresets addObject:@{@"id":@"b",@"name":@"Bad width",@"values":@{@"width":@(-5)}}];
    [fixturePresets addObject:@{@"id":@"c",@"name":@"   ",@"values":@{@"width":@300}}];
    [fixturePresets addObject:@{@"id":@"d",@"name":[@"" stringByPaddingToLength:41 withString:@"가" startingAtIndex:0],@"values":@{@"width":@300}}];
    for(int i=0;i<25;i++) [fixturePresets addObject:@{@"id":[NSString stringWithFormat:@"n%d",i],@"name":[NSString stringWithFormat:@"Preset %d",i],@"values":@{@"width":@(200+i)}}];
    [[NSJSONSerialization dataWithJSONObject:@{@"schema":@1,@"presets":fixturePresets} options:0 error:nil] writeToFile:presetsPath atomically:YES];
    NSArray<NSDictionary *> *parsedPresets=ReadPresets(); NSDictionary *firstPreset=parsedPresets.firstObject; NSArray *presetIDs=[parsedPresets valueForKey:@"id"];
    check(@"presets_parse_trim_names_and_drop_excluded_and_unknown_keys",parsedPresets.count==20&&[firstPreset[@"name"] isEqual:@"Left dot"]&&!firstPreset[@"values"][@"mode"]&&!firstPreset[@"values"][@"enabled"]&&
        !firstPreset[@"values"][@"loggingEnabled"]&&!firstPreset[@"values"][@"schema"]&&!firstPreset[@"values"][@"futureKey"]&&[firstPreset[@"values"][@"dotDiameter"] isEqual:@12]);
    check(@"presets_reject_invalid_values_and_names_and_cap_at_20",![presetIDs containsObject:@"b"]&&![presetIDs containsObject:@"c"]&&![presetIDs containsObject:@"d"]&&[presetIDs[1] isEqual:@"n0"]&&[presetIDs.lastObject isEqual:@"n18"]);
    NSDictionary *beforePreset=CRDReadConfig(nil);
    NSMenu *presetSubmenu=[[coordinator windowContextMenu] itemAtIndex:3].submenu; NSMenuItem *leftDot=[presetSubmenu itemAtIndex:0];
    check(@"preset_submenu_lists_names_and_marks_none",presetSubmenu.numberOfItems==20&&[leftDot.title isEqual:@"Left dot"]&&leftDot.state==NSControlStateValueOff&&leftDot.action==@selector(applyPreset:));
    [coordinator applyPreset:leftDot];
    NSDictionary *afterPreset=CRDReadConfig(nil); NSRect presetFrame=overlay.controller.window.frame;
    check(@"preset_apply_is_one_config_write_that_keeps_mode_enabled_and_logging",[afterPreset[@"layout"] isEqual:@"dot"]&&[afterPreset[@"width"] isEqual:@42]&&[afterPreset[@"stopRevealSeconds"] isEqual:@0]&&![afterPreset[@"draggable"] boolValue]&&
        [afterPreset[@"mode"] isEqual:beforePreset[@"mode"]]&&[afterPreset[@"enabled"] isEqual:beforePreset[@"enabled"]]&&[afterPreset[@"loggingEnabled"] isEqual:beforePreset[@"loggingEnabled"]]&&[currentConfig isEqual:afterPreset]);
    NSRect presetVisible=SelectedScreen(afterPreset).visibleFrame;
    check(@"preset_position_is_saved_reachable_in_the_same_write",NSContainsRect(presetVisible,presetFrame)&&presetFrame.size.width==42&&[afterPreset[@"placement"] isEqual:@"custom"]&&
        fabs([afterPreset[@"x"] doubleValue]-(NSWidth(presetVisible)-42))<.01&&[afterPreset[@"y"] isEqual:@40]&&![afterPreset[@"constrainToScreen"] boolValue]);
    [coordinator togglePositionLock:nil]; BOOL stillReachable=NSContainsRect(presetVisible,overlay.controller.window.frame); [coordinator togglePositionLock:nil];
    check(@"later_reload_keeps_the_preset_position_reachable",stillReachable&&NSContainsRect(presetVisible,overlay.controller.window.frame));
    // A preset whose position had to be moved does not match; one that fits is checked after applying.
    BOOL clampedUnchecked=[[[coordinator windowContextMenu] itemAtIndex:3].submenu itemAtIndex:0].state==NSControlStateValueOff;
    [coordinator applyPreset:[[[coordinator windowContextMenu] itemAtIndex:3].submenu itemAtIndex:1]];
    NSMenu *statusPresets=[NSMenu new]; [coordinator menuNeedsUpdate:statusPresets];
    check(@"matching_preset_is_checked_in_both_menus",clampedUnchecked&&[[[coordinator windowContextMenu] itemAtIndex:3].submenu itemAtIndex:1].state==NSControlStateValueOn&&[[statusPresets itemAtIndex:10].submenu itemAtIndex:1].state==NSControlStateValueOn&&
        [[statusPresets itemAtIndex:10].submenu itemAtIndex:0].state==NSControlStateValueOff&&[statusPresets itemAtIndex:8].state==NSControlStateValueOn);
    [@"{corrupt" writeToFile:presetsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSMenu *corruptMenu=[[coordinator windowContextMenu] itemAtIndex:3].submenu;
    check(@"corrupt_presets_file_is_ignored_in_place_and_never_blocks_config",ReadPresets().count==0&&corruptMenu.numberOfItems==1&&![corruptMenu itemAtIndex:0].enabled&&[[corruptMenu itemAtIndex:0].title isEqual:L(@"저장된 프리셋 없음")]&&
        [NSFileManager.defaultManager fileExistsAtPath:presetsPath]&&CRDReadConfig(nil)!=nil);
    [NSFileManager.defaultManager removeItemAtPath:presetsPath error:nil];
    check(@"missing_presets_file_is_an_empty_list",ReadPresets().count==0);
    // A full preset saved before the Stop style existed loads, matches and applies as the red Stop;
    // an explicit gray preset keeps gray. The helper never rewrites presets.json.
    {
        NSMutableDictionary *older=[CRDDefaults() mutableCopy]; for(NSString *key in PresetExcludedKeys()) [older removeObjectForKey:key]; [older removeObjectForKey:@"stopStyle"];
        NSMutableDictionary *grayValues=[older mutableCopy]; grayValues[@"stopStyle"]=@"gray";
        [[NSJSONSerialization dataWithJSONObject:@{@"schema":@1,@"presets":@[@{@"id":@"older",@"name":@"Before styles",@"values":older},@{@"id":@"gray",@"name":@"Gray",@"values":grayValues}]} options:0 error:nil] writeToFile:presetsPath atomically:YES];
        NSData *presetBytes=[NSData dataWithContentsOfFile:presetsPath];
        NSArray<NSDictionary *> *styled=ReadPresets();
        UpdateConfig(^(NSMutableDictionary *next){ [next addEntriesFromDictionary:grayValues]; }); CRDReload();
        NSDictionary *grayConfig=CRDReadConfig(nil);
        BOOL loadsRed=styled.count==2&&[styled[0][@"values"][@"stopStyle"] isEqual:@"red"]&&[styled[1][@"values"][@"stopStyle"] isEqual:@"gray"]&&[styled[0][@"values"] count]==older.count+1;
        BOOL matching=!PresetMatches(styled[0][@"values"],grayConfig)&&PresetMatches(styled[1][@"values"],grayConfig);
        NSMenuItem *olderItem=[NSMenuItem new]; olderItem.representedObject=styled[0][@"values"]; [coordinator applyPreset:olderItem];
        NSDictionary *redApplied=CRDReadConfig(nil);
        NSMenuItem *grayItem=[NSMenuItem new]; grayItem.representedObject=styled[1][@"values"]; [coordinator applyPreset:grayItem];
        NSDictionary *grayApplied=CRDReadConfig(nil);
        check(@"preset_without_stop_style_loads_and_applies_as_red",loadsRed&&matching&&[redApplied[@"stopStyle"] isEqual:@"red"]&&[grayApplied[@"stopStyle"] isEqual:@"gray"]&&
            [redApplied[@"mode"] isEqual:grayConfig[@"mode"]]&&[redApplied[@"enabled"] isEqual:grayConfig[@"enabled"]]&&[grayApplied[@"mode"] isEqual:grayConfig[@"mode"]]&&
            [grayApplied[@"enabled"] isEqual:grayConfig[@"enabled"]]&&[[NSData dataWithContentsOfFile:presetsPath] isEqual:presetBytes]);
        UpdateConfig(^(NSMutableDictionary *next){ next[@"stopStyle"]=@"red"; }); CRDReload();
        [NSFileManager.defaultManager removeItemAtPath:presetsPath error:nil];
    }
    // A preset for a display that is not connected (screen 63) with an edge inset past it.
    NSMenuItem *farPreset=[NSMenuItem new]; farPreset.representedObject=@{@"screen":@63,@"placement":@"top",@"edgeInset":@5000,@"constrainToScreen":@NO,@"layout":@"row",@"width":@300,@"height":@40};
    [coordinator applyPreset:farPreset]; NSDictionary *farSaved=CRDReadConfig(nil);
    BOOL farReachable=NSContainsRect(NSScreen.screens.firstObject.visibleFrame,overlay.controller.window.frame);
    check(@"preset_for_a_missing_display_is_saved_on_the_main_display_and_reachable",farReachable&&(NSScreen.screens.count>63||[farSaved[@"screen"] isEqual:@0])&&[farSaved[@"placement"] isEqual:@"custom"]&&
        [farSaved[@"mode"] isEqual:beforePreset[@"mode"]]&&[farSaved[@"enabled"] isEqual:beforePreset[@"enabled"]]);
    // A preset that shows the inline Stop arms its gate; a quick count-1 click is refused,
    // a separate later click is accepted, and so is the pattern after an outside click on the bar.
    for(NSNumber *reduced in @[@NO,@YES]) {
        fixtureReduceMotion=reduced;
        NSMenuItem *barPreset=[NSMenuItem new]; barPreset.representedObject=@{@"layout":@"row",@"width":@(reduced.boolValue?441:440),@"height":@48,@"showStopButton":@YES,@"placement":@"center",@"draggable":@NO};
        [coordinator applyPreset:barPreset];
        CRDSessionStopButton *inlineStop=(CRDSessionStopButton *)overlay.stop; NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        NSPoint onInline=NSMakePoint(NSMidX(inlineStop.frame),NSMidY(inlineStop.frame));
        inlineStop.enabled=YES; // Decision checks only; the fixture never sends a press.
        BOOL afterPresetRejected=!inlineStop.hidden&&inlineStop.stopGestureGate==inlineStopGate&&![inlineStop acceptsPress:mouseAt(NSEventTypeLeftMouseDown,onInline,1,now,0)];
        BOOL separateAccepted=[inlineStop acceptsPress:mouseAt(NSEventTypeLeftMouseDown,onInline,1,inlineStopGate.blockedThrough+.01,0)];
        NSTimeInterval later=inlineStopGate.blockedThrough+1;
        [trackingQueue removeAllObjects]; [trackingQueue addObject:mouseAt(NSEventTypeLeftMouseUp,NSMakePoint(2,2),1,later+.05,0)];
        [overlay.customView mouseDown:mouseAt(NSEventTypeLeftMouseDown,NSMakePoint(2,2),1,later,0)];
        BOOL outsideThenQuickRejected=![inlineStop acceptsPress:mouseAt(NSEventTypeLeftMouseDown,onInline,1,later+.1,0)];
        BOOL deliberateAccepted=[inlineStop acceptsPress:mouseAt(NSEventTypeLeftMouseDown,onInline,1,inlineStopGate.blockedThrough+.01,0)];
        inlineStop.enabled=NO;
        check(@"inline_stop_after_preset_or_outside_click_needs_a_separate_later_click",afterPresetRejected&&separateAccepted&&outsideThenQuickRejected&&deliberateAccepted);
    }
    fixtureReduceMotion=nil;
    CRDWriteConfig(beforePreset,nil); CRDReload();
    NSDictionary *tokenA=@{@"pid":@100,@"generation":@1,@"window":@"fixture-window-a",@"stop":@"fixture-stop-a"};
    NSDictionary *tokenB=@{@"pid":@100,@"generation":@2,@"window":@"fixture-window-b",@"stop":@"fixture-stop-b"};
    check(@"stop_token_rejects_recreated_window_and_pid",SameStopToken(tokenA,[tokenA copy])&&!SameStopToken(tokenA,tokenB)&&!SameStopToken(tokenA,@{@"pid":@101,@"generation":@1,@"window":@"fixture-window-a",@"stop":@"fixture-stop-a"})&&!SameStopToken(tokenA,nil));
    NSMutableDictionary *reveal=[CRDDefaults() mutableCopy]; reveal[@"mode"]=@"custom"; reveal[@"layout"]=@"dot"; reveal[@"width"]=@40; reveal[@"height"]=@40; reveal[@"stopRevealSeconds"]=@1; apply(reveal);
    // Waits for the capsule's opening to finish: its fold timer starts then (stopRevealSeconds above 0),
    // or it did not open. With no fold timer there is no such signal, so it waits a fixed .3 s.
    auto waitForOpen=[&]{
        if([currentConfig[@"stopRevealSeconds"] doubleValue]>0) RunUntil(5,^BOOL{ return !coordinator.stopRevealPanel||coordinator.revealTimer!=nil; });
        else RunFor(.3);
    };
    // Waits for the capsule to close, its closing animation included.
    auto waitForClose=[&]{ RunUntil(5,^BOOL{ return !coordinator.stopRevealPanel; }); };
    __block NSUInteger revealRequests=0; overlay.dot.doubleClickAction=^(NSEvent *event){ revealRequests++; };
    NSRect revealAnchor=overlay.controller.window.frame;
    press(overlay.dot,NSMakePoint(NSMidX(revealAnchor),NSMidY(revealAnchor)),@[],1);
    check(@"dot_single_click_does_not_reveal",revealRequests==0);
    press(overlay.dot,NSMakePoint(NSMidX(revealAnchor),NSMidY(revealAnchor)),@[at(NSMidX(revealAnchor)+1,NSMidY(revealAnchor))],2);
    check(@"dot_double_click_reveals_after_mouseup_without_drag",revealRequests==1&&NSEqualRects(overlay.controller.window.frame,revealAnchor)&&trackingQueue.count==0);
    overlay.dot.doubleClickAction=expandAction;
    NSEvent *doubleUp=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(20,20) modifierFlags:0 timestamp:.01 windowNumber:0 context:nil eventNumber:3 clickCount:2 pressure:0];
    auto gateEvent=[](NSEventType type,NSTimeInterval timestamp,NSInteger count)->NSEvent * {
        return [NSEvent mouseEventWithType:type location:NSMakePoint(20,20) modifierFlags:0 timestamp:timestamp windowNumber:0 context:nil eventNumber:1 clickCount:count pressure:1];
    };
    for(NSNumber *reduced in @[@NO,@YES]) {
        fixtureReduceMotion=reduced;
        [coordinator presentStopRevealWithToken:tokenA afterEvent:doubleUp];
        CRDSessionStopButton *guarded=coordinator.revealStopButton;
        CRDStopGestureGate *gate=guarded.stopGestureGate;
        check(@"reveal_input_gate_exists_with_and_without_motion",gate!=nil&&!guarded.enabled);
        NSTimeInterval interval=NSEvent.doubleClickInterval;
        check(@"reveal_continuation_rejected_even_if_new_window_resets_click_count",
              [gate filterEvent:gateEvent(NSEventTypeLeftMouseDown,.01+interval/2,1)]==nil&&
              [gate filterEvent:gateEvent(NSEventTypeLeftMouseUp,.02+interval/2,1)]==nil);
        NSTimeInterval next=gate.blockedThrough+.01;
        check(@"separate_post_reveal_gesture_is_accepted",[gate filterEvent:gateEvent(NSEventTypeLeftMouseDown,next,1)]!=nil&&
              [gate filterEvent:gateEvent(NSEventTypeLeftMouseUp,next+.01,1)]!=nil);
        [coordinator closeStopReveal:@"fixture"];
        check(@"closing_reveal_disarms_button_and_removes_monitor",!guarded.enabled&&coordinator.revealInputMonitor==nil);
    }
    // Shrink, Stop protection and auto-shrink 0 on the real capsule (never ordered on screen).
    for(NSNumber *reduced in @[@NO,@YES]) {
        fixtureReduceMotion=reduced;
        NSRect anchorBefore=overlay.controller.window.frame;
        [coordinator presentStopRevealWithToken:tokenA afterEvent:doubleUp]; waitForOpen();
        NSPanel *capsule=coordinator.stopRevealPanel; CRDBackground *capsuleBackground=(CRDBackground *)capsule.contentView;
        CRDSessionStopButton *capsuleStop=coordinator.revealStopButton; CRDStopGestureGate *capsuleGate=capsuleStop.stopGestureGate;
        NSRect stopZone=NSInsetRect(capsuleStop.frame,-CRDStopShrinkMargin,-CRDStopShrinkMargin);
        NSTimeInterval interval=NSEvent.doubleClickInterval;
        capsuleStop.enabled=YES; // Only for the decision checks; fixtures never enable the real action.
        BOOL expandingRejected=![capsuleStop acceptsPress:gateEvent(NSEventTypeLeftMouseDown,.01+interval/2,1)];
        BOOL secondClickRejected=![capsuleStop acceptsPress:gateEvent(NSEventTypeLeftMouseDown,capsuleGate.blockedThrough+1,2)];
        BOOL deliberateAccepted=[capsuleStop acceptsPress:gateEvent(NSEventTypeLeftMouseDown,capsuleGate.blockedThrough+.01,1)];
        capsuleStop.enabled=NO;
        check(@"stop_needs_a_separate_single_click_never_the_expanding_or_second_click",expandingRejected&&secondClickRejected&&deliberateAccepted);
        NSPoint outside=NSMakePoint(2,NSMidY(capsuleBackground.bounds)),onStop=NSMakePoint(NSMidX(capsuleStop.frame),NSMidY(capsuleStop.frame));
        NSTimeInterval later=capsuleGate.blockedThrough+.5;
        NSEvent *outsideDown=mouseAt(NSEventTypeLeftMouseDown,outside,2,later,capsule.windowNumber);
        NSEvent *stopDown=mouseAt(NSEventTypeLeftMouseDown,onStop,2,later+.01,capsule.windowNumber);
        BOOL outsidePasses=outsideDown.window==capsule&&[coordinator filterRevealInput:outsideDown gate:capsuleGate]!=nil;
        BOOL stopGated=[coordinator filterRevealInput:stopDown gate:capsuleGate]==nil&&[coordinator filterRevealInput:mouseAt(NSEventTypeLeftMouseUp,onStop,2,later+.02,capsule.windowNumber) gate:capsuleGate]==nil;
        check(@"capsule_presses_outside_stop_pass_and_presses_on_stop_are_gated",outsidePasses&&stopGated&&NSContainsRect(stopZone,capsuleStop.frame));
        press(capsuleBackground,outside,@[],1); BOOL singleIgnored=coordinator.stopRevealPanel==capsule;
        press(capsuleBackground,NSMakePoint(NSMinX(capsuleStop.frame)-CRDStopShrinkMargin/2,NSMidY(capsuleStop.frame)),@[],2); BOOL marginIgnored=coordinator.stopRevealPanel==capsule;
        press(capsuleBackground,outside,@[],2); waitForClose();
        check(@"capsule_double_click_outside_stop_shrinks_at_same_anchor",singleIgnored&&marginIgnored&&coordinator.stopRevealPanel==nil&&NSEqualRects(overlay.controller.window.frame,anchorBefore)&&overlay.dot.alphaValue==1&&!overlay.controller.window.ignoresMouseEvents&&!overlay.customView.suppressBackground);
        [coordinator presentStopRevealWithToken:tokenA afterEvent:doubleUp]; waitForOpen();
        CRDStatusDot *capsuleDot=coordinator.revealDot;
        press(capsuleDot,NSMakePoint(NSMidX(capsuleDot.frame),NSMidY(capsuleDot.frame)),@[],2); waitForClose();
        check(@"capsule_status_dot_double_click_shrinks",coordinator.stopRevealPanel==nil&&NSEqualRects(overlay.controller.window.frame,anchorBefore));
    }
    // A fresh outside click through the capsule's own loop (its mouse-up consumed there),
    // then a quick click on Stop that macOS reports as count 1, is refused in both motion modes.
    for(NSNumber *reduced in @[@NO,@YES]) {
        fixtureReduceMotion=reduced;
        [coordinator presentStopRevealWithToken:tokenA afterEvent:doubleUp]; waitForOpen();
        NSPanel *capsule=coordinator.stopRevealPanel; CRDBackground *capsuleBackground=(CRDBackground *)capsule.contentView;
        CRDSessionStopButton *capsuleStop=coordinator.revealStopButton; CRDStopGestureGate *capsuleGate=capsuleStop.stopGestureGate;
        NSPoint outside=NSMakePoint(2,NSMidY(capsuleBackground.bounds));
        NSTimeInterval fresh=capsuleGate.blockedThrough+1;
        [trackingQueue removeAllObjects]; [trackingQueue addObject:mouseAt(NSEventTypeLeftMouseUp,outside,1,fresh+.05,0)];
        [capsuleBackground mouseDown:mouseAt(NSEventTypeLeftMouseDown,outside,1,fresh,0)];
        capsuleStop.enabled=YES;
        BOOL quickCountOneRejected=![capsuleStop acceptsPress:gateEvent(NSEventTypeLeftMouseDown,fresh+.1,1)];
        BOOL quickCountTwoRejected=![capsuleStop acceptsPress:gateEvent(NSEventTypeLeftMouseDown,fresh+.15,2)];
        BOOL separateAccepted=[capsuleStop acceptsPress:gateEvent(NSEventTypeLeftMouseDown,capsuleGate.blockedThrough+.01,1)];
        capsuleStop.enabled=NO;
        NSTimeInterval monitored=capsuleGate.blockedThrough+1;
        [coordinator filterRevealInput:mouseAt(NSEventTypeLeftMouseDown,outside,1,monitored,capsule.windowNumber) gate:capsuleGate];
        BOOL monitorAdvances=capsuleGate.blockedThrough>=monitored+NSEvent.doubleClickInterval-.001;
        check(@"capsule_outside_click_then_quick_stop_click_is_refused_until_a_separate_click",quickCountOneRejected&&quickCountTwoRejected&&separateAccepted&&monitorAdvances&&coordinator.stopRevealPanel==capsule);
        [coordinator closeStopReveal:@"fixture"]; RunFor(.3);
    }
    fixtureReduceMotion=nil;
    check(@"auto_shrink_range_allows_zero_and_matches_schema",Validate(@{@"stopRevealSeconds":@0},nil)!=nil&&Validate(@{@"stopRevealSeconds":@30},nil)!=nil&&Validate(@{@"stopRevealSeconds":@(-1)},nil)==nil&&Validate(@{@"stopRevealSeconds":@31},nil)==nil&&
        [Schema()[@"numericLimits"][@"stopRevealSeconds"] isEqual:(@[@0,@30])]&&[CRDDefaults()[@"stopRevealSeconds"] isEqual:@5]);
    NSMutableDictionary *stayOpen=[reveal mutableCopy]; stayOpen[@"stopRevealSeconds"]=@0; apply(stayOpen);
    [coordinator presentStopRevealWithToken:tokenA]; RunFor(1.3);
    check(@"auto_shrink_off_keeps_capsule_open_until_shrunk",coordinator.stopRevealPanel!=nil&&coordinator.revealTimer==nil&&overlay.customView.suppressBackground);
    [coordinator closeStopReveal:@"fixture"]; apply(reveal);
    NSMenu *context=[overlay.dot menuForEvent:rightClick];
    check(@"dot_context_menu_is_window_menu_with_safe_stop_action",context.numberOfItems==8&&[context itemAtIndex:7].action==@selector(stopSharingClicked:)&&![context itemAtIndex:7].enabled&&[context itemAtIndex:1].action==@selector(togglePositionLock:));
    fixtureLanguage=@"en";
    [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
    CRDSessionStopButton *englishReveal=coordinator.revealStopButton;
    CGFloat englishText=ceil([englishReveal.title sizeWithAttributes:@{NSFontAttributeName:englishReveal.font}].width);
    check(@"english_reveal_title_fits_the_pill",[englishReveal.title isEqual:translatedStop]&&NSWidth([englishReveal pillRect])>=englishText+2*CRDPillPaddingX);
    [coordinator closeStopReveal:@"english-fixture-complete"]; fixtureLanguage=nil;
    // The capsule's Stop takes the stopStyle setting with the same press area, pill and gate.
    {
        NSDictionary *saved=[currentConfig copy]; NSMutableDictionary *gray=[saved mutableCopy]; gray[@"stopStyle"]=@"gray"; apply(gray);
        [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
        CRDSessionStopButton *grayReveal=coordinator.revealStopButton; NSRect grayFrame=grayReveal.frame,grayPill=[grayReveal pillRect],grayPanel=coordinator.stopRevealPanel.frame;
        BOOL grayGated=grayReveal.stopGestureGate!=nil&&[grayReveal.stopStyle isEqual:@"gray"];
        [coordinator closeStopReveal:@"gray-fixture-complete"]; apply(saved);
        [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
        CRDSessionStopButton *redReveal=coordinator.revealStopButton;
        check(@"capsule_stop_takes_the_style_with_unchanged_metrics_and_gate",grayGated&&[redReveal.stopStyle isEqual:@"red"]&&redReveal.stopGestureGate!=nil&&
            NSEqualRects(grayFrame,redReveal.frame)&&NSEqualRects(grayPill,[redReveal pillRect])&&NSEqualSizes(grayPanel.size,coordinator.stopRevealPanel.frame.size));
        [coordinator closeStopReveal:@"red-fixture-complete"];
    }
    NSRect mainBefore=overlay.controller.window.frame; NSDictionary *settingsBefore=[currentConfig copy];
    [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
    check(@"stop_reveal_does_not_change_main_geometry_or_config",coordinator.stopRevealPanel!=nil&&!coordinator.stopRevealPanel.visible&&NSEqualRects(mainBefore,overlay.controller.window.frame)&&[settingsBefore isEqual:currentConfig]);
    CRDSessionStopButton *revealed=coordinator.revealStopButton;
    CGFloat revealedText=ceil([revealed.title sizeWithAttributes:@{NSFontAttributeName:revealed.font}].width);
    check(@"reveal_full_single_line_title_and_readable_target",[revealed.title isEqual:L(@"공유 중지")]&&[revealed.accessibilityLabel isEqual:L(@"공유 중지")]&&
        revealed.frame.size.width>=CRDStopHitWidth&&revealed.frame.size.height>=CRDStopHitHeight&&NSWidth([revealed pillRect])>=revealedText+2*CRDPillPaddingX&&
        NSContainsRect(revealed.bounds,[revealed pillRect]));
    check(@"reveal_system_font_independent_of_dot_font",revealed.font.pointSize==NSFont.systemFontSize&&[revealed.font isEqual:StopPillFont(NSFont.systemFontSize)]&&revealed.controlSize==NSControlSizeRegular);
    check(@"reveal_stop_is_the_default_red_pill",[revealed isKindOfClass:CRDSessionStopButton.class]&&[revealed.stopStyle isEqual:@"red"]&&!revealed.bordered&&revealed.hasDestructiveAction&&revealed.contentTintColor==nil);
    NSRect capsuleFrame=coordinator.stopRevealPanel.frame;
    // The pill is as high as the inline pill at the system font; the space above, below and at
    // the right end of the pill is 6 pt; the dot sits 12 pt from the left end and 10 pt before the pill.
    {
        NSRect pill=[revealed convertRect:[revealed pillRect] toView:revealed.superview],dot=coordinator.revealDot.frame;
        CGFloat natural=StopPillSize(revealed.title,StopPillFont(NSFont.systemFontSize)).height;
        check(@"capsule_layout_has_even_padding_and_dot_insets",fabs(NSHeight(pill)-natural)<.01&&fabs(NSMinY(pill)-CRDCapsulePadding)<.01&&
            fabs(capsuleFrame.size.height-NSMaxY(pill)-CRDCapsulePadding)<.01&&fabs(capsuleFrame.size.width-NSMaxX(pill)-CRDCapsulePadding)<.01&&
            fabs(NSMinX(dot)-CRDCapsuleDotInset)<.01&&fabs(NSMinX(pill)-NSMaxX(dot)-CRDCapsuleDotGap)<.01&&fabs(NSMidY(dot)-NSMidY(pill))<.01&&
            fabs(NSMidY(revealed.frame)-capsuleFrame.size.height/2)<.01&&fabs(NSMaxX(revealed.frame)-capsuleFrame.size.width)<.01);
    }
    // Window origins are whole points, so the centers agree within half a point.
    check(@"capsule_expands_symmetrically_around_unchanged_dot",fabs(NSMidX(capsuleFrame)-NSMidX(mainBefore))<=.51&&fabs(NSMidY(capsuleFrame)-NSMidY(mainBefore))<=.51&&overlay.customView.suppressBackground&&fabs([((CRDBackground *)coordinator.stopRevealPanel.contentView).config[@"radius"] doubleValue]-capsuleFrame.size.height/2)<.1);
    check(@"expanded_point_copies_dedicated_color",[coordinator.revealDot.textColor isEqual:overlay.dot.textColor]);
    check(@"expanded_dot_left_text_right_and_main_does_not_intercept",NSMidX(coordinator.revealDot.frame)<capsuleFrame.size.width/2&&NSMidX(revealed.frame)>capsuleFrame.size.width/2&&coordinator.revealDot.alphaValue==1&&overlay.dot.alphaValue==0&&overlay.controller.window.ignoresMouseEvents);
    check(@"expanded_button_and_point_retain_safe_context_menu",[revealed menuForEvent:rightClick].numberOfItems==1&&[coordinator.revealDot menuForEvent:rightClick].numberOfItems==1);
    check(@"context_menu_uses_native_font_and_readable_minimum",context.minimumWidth>=160&&context.font.pointSize==[NSFont menuFontOfSize:0].pointSize);
    [coordinator validateStopRevealForToken:tokenB modeSignature:coordinator.revealModeSignature windowDetected:YES];
    check(@"stop_reveal_closes_when_session_token_changes",coordinator.stopRevealPanel==nil&&coordinator.revealTimer==nil&&!overlay.customView.suppressBackground&&overlay.dot.alphaValue==1&&!overlay.controller.window.ignoresMouseEvents);
    // At an edge or a corner a double-click still opens the capsule, moved inside the visible frame
    // over the dot's center, and the dot window keeps its place.
    {
        NSMutableDictionary *edgeSettings=[currentConfig mutableCopy]; edgeSettings[@"width"]=@17; edgeSettings[@"height"]=@17; apply(edgeSettings);
        BOOL edgesOpen=YES,smallScreens=YES,motionFrames=YES,noWrites=YES;
        NSData *configBytes=[NSData dataWithContentsOfFile:CRDConfigPath()];
        fixtureStopToken=tokenA;
        for(NSNumber *reduced in @[@NO,@YES]) {
            fixtureReduceMotion=reduced;
            for(NSValue *screen in @[[NSValue valueWithRect:visible],[NSValue valueWithRect:NSMakeRect(-320,-100,320,200)],
                                     [NSValue valueWithRect:NSMakeRect(2000,0,100,30)]]) {
                fixtureRevealVisibleFrame=screen; NSRect area=screen.rectValue;
                CGFloat side=17;
                for(NSValue *origin in @[at(NSMidX(area),NSMaxY(area)-side),at(NSMidX(area),NSMinY(area)),
                    at(NSMinX(area),NSMidY(area)),at(NSMaxX(area)-side,NSMidY(area)),
                    at(NSMinX(area),NSMinY(area)),at(NSMinX(area),NSMaxY(area)-side),
                    at(NSMaxX(area)-side,NSMinY(area)),at(NSMaxX(area)-side,NSMaxY(area)-side),
                    at(NSMinX(area)-side/2+1,NSMidY(area)),at(NSMaxX(area)+4,NSMidY(area))]) {
                    [overlay.controller.window setFrame:NSMakeRect(origin.pointValue.x,origin.pointValue.y,side,side) display:NO];
                    NSRect anchor=overlay.controller.window.frame;
                    press(overlay.dot,NSMakePoint(8,8),@[],2);
                    NSPanel *panel=coordinator.stopRevealPanel; CRDStatusDot *dot=coordinator.revealDot;
                    waitForOpen(); NSRect frame=panel.frame;
                    BOOL inside=panel!=nil&&NSContainsRect(area,frame);
                    if(NSPointInRect(NSMakePoint(NSMidX(anchor),NSMidY(anchor)),area))
                        inside=inside&&NSPointInRect(NSMakePoint(NSMidX(anchor),NSMidY(anchor)),frame);
                    if(NSWidth(area)>=320) edgesOpen=edgesOpen&&inside; else smallScreens=smallScreens&&inside;
                    motionFrames=motionFrames&&dot!=nil&&(NSIsEmptyRect(dot.frame)||NSMinX(dot.frame)<NSMinX(coordinator.revealStopButton.frame));
                    [coordinator closeStopReveal:@"user-collapsed"]; waitForClose();
                    if(!reduced.boolValue) motionFrames=motionFrames&&NSEqualRects(panel.frame,anchor)&&
                        fabs(NSMidX(dot.frame)-NSWidth(anchor)/2)<.1&&fabs(NSMidY(dot.frame)-NSHeight(anchor)/2)<.1;
                    noWrites=noWrites&&NSEqualRects(overlay.controller.window.frame,anchor)&&[edgeSettings isEqual:currentConfig]&&
                        [[NSData dataWithContentsOfFile:CRDConfigPath()] isEqual:configBytes];
                }
            }
        }
        check(@"screen_edges_corners_and_offscreen_anchors_open_capsules",edgesOpen);
        check(@"screens_smaller_than_the_natural_capsule_still_open_capsules",smallScreens);
        check(@"edge_capsule_dot_slides_left_and_returns_to_the_original_anchor",motionFrames);
        check(@"edge_capsule_never_moves_or_saves_the_original_window",noWrites);
        fixtureRevealVisibleFrame=nil; fixtureReduceMotion=nil; fixtureStopToken=nil; apply(settingsBefore);
    }
    [overlay.controller.window setFrame:mainBefore display:YES];
    [coordinator presentStopRevealWithToken:tokenA]; RunFor(.3);
    [coordinator validateStopRevealForToken:tokenA modeSignature:@"different-mode" windowDetected:YES];
    check(@"stop_reveal_closes_on_mode_change",coordinator.stopRevealPanel==nil);
    [coordinator presentStopRevealWithToken:tokenA]; waitForOpen(); waitForClose();
    check(@"stop_reveal_one_shot_timeout",coordinator.stopRevealPanel==nil&&coordinator.revealTimer==nil&&overlay.dot.alphaValue==1&&!overlay.controller.window.ignoresMouseEvents);
    [coordinator presentStopRevealWithToken:tokenA];
    NSPanel *stalePanel=coordinator.stopRevealPanel;
    [coordinator presentStopRevealWithToken:tokenB]; waitForOpen();
    check(@"capsule_reentry_cancels_stale_animation_and_timeout",coordinator.stopRevealPanel!=stalePanel&&[coordinator.revealToken isEqual:tokenB]&&coordinator.revealTimer!=nil&&overlay.customView.suppressBackground);
    if(overlay.dot.dragWillBegin) overlay.dot.dragWillBegin();
    check(@"dot_drag_closes_capsule_before_moving",coordinator.stopRevealPanel==nil&&!overlay.customView.suppressBackground);
    [coordinator presentStopRevealWithToken:tokenA]; NSMenu *replacementMenu=[overlay.dot menuForEvent:rightClick]; RunFor(.3);
    check(@"context_reentry_cancels_capsule",replacementMenu.numberOfItems==8&&coordinator.stopRevealPanel==nil&&coordinator.revealTimer==nil&&!overlay.customView.suppressBackground);
    NSMutableDictionary *small=[reveal mutableCopy]; small[@"width"]=@7; small[@"height"]=@5; small[@"dotDiameter"]=@10;
    apply(small); NSRect exactOriginal=overlay.controller.window.frame; NSDictionary *exactSettings=[currentConfig copy];
    fixtureReduceMotion=@NO; // These checks follow the animated collapse, whatever the machine's Reduce Motion setting.
    [coordinator presentStopRevealWithToken:tokenA]; NSPanel *smallPanel=coordinator.stopRevealPanel; CRDStatusDot *smallMovingDot=coordinator.revealDot;
    waitForOpen();
    check(@"moving_dot_retains_clamped_original_diameter",smallMovingDot.dotDiameter==5&&smallMovingDot.geometricDotRect.size.width==5&&smallMovingDot.alphaValue==1);
    waitForClose();
    check(@"timeout_restores_exact_tiny_frame_and_settings",coordinator.stopRevealPanel==nil&&NSEqualRects(smallPanel.frame,exactOriginal)&&NSEqualRects(overlay.controller.window.frame,exactOriginal)&&[currentConfig isEqual:exactSettings]&&overlay.dot.alphaValue==1&&!overlay.controller.window.ignoresMouseEvents);
    check(@"moving_dot_returns_to_original_center_before_restore",fabs(NSMidX(smallMovingDot.frame)-exactOriginal.size.width/2)<.1&&fabs(NSMidY(smallMovingDot.frame)-exactOriginal.size.height/2)<.1);
    fixtureReduceMotion=nil;
    // With Reduce Motion the capsule closes at once, without the collapse, and the tiny dot window
    // comes back with its exact frame, settings, opacity and clicks.
    fixtureReduceMotion=@YES;
    [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
    BOOL reducedOpened=coordinator.stopRevealPanel!=nil&&coordinator.revealTimer!=nil&&overlay.customView.suppressBackground;
    waitForClose();
    check(@"reduced_motion_timeout_restores_exact_tiny_frame_and_settings",reducedOpened&&coordinator.stopRevealPanel==nil&&NSEqualRects(overlay.controller.window.frame,exactOriginal)&&[currentConfig isEqual:exactSettings]&&overlay.dot.alphaValue==1&&!overlay.controller.window.ignoresMouseEvents);
    fixtureReduceMotion=nil;
    apply(reveal);
    [coordinator presentStopRevealWithToken:tokenA]; ReconcileFromConfig(); RunFor(.3);
    check(@"configuration_changes_cancel_stale_capsule_and_restore_hit_testing",coordinator.stopRevealPanel==nil&&!overlay.customView.suppressBackground&&overlay.dot.alphaValue==1&&!overlay.controller.window.ignoresMouseEvents);
    // A double-click opens the Stop capsule on every shape, through the real views and the helper's
    // own tracking loop, with or without the Control flag. Menus open only on a right mouse down;
    // the fixture records them instead of showing them.
    {
        __block NSUInteger menusShown=0; __block NSMenu *lastMenu=nil;
        fixturePresentMenu=^(NSMenu *menu,NSEvent *event,NSView *view){ menusShown++; lastMenu=menu; };
        fixtureStopToken=tokenA;
        auto flagged=[](NSEventType type,NSPoint point,NSInteger count,NSTimeInterval timestamp,NSEventModifierFlags flags)->NSEvent * {
            return [NSEvent mouseEventWithType:type location:point modifierFlags:flags timestamp:timestamp windowNumber:0 context:nil eventNumber:1 clickCount:count pressure:type==NSEventTypeLeftMouseUp?0:1];
        };
        // A press at a point and its release there, with modifier flags on both.
        auto pressFlagged=[&](NSView *view,NSPoint point,NSInteger count,NSEventModifierFlags flags) {
            [trackingQueue removeAllObjects]; [trackingQueue addObject:flagged(NSEventTypeLeftMouseUp,point,count,0,flags)];
            [view mouseDown:flagged(NSEventTypeLeftMouseDown,point,count,0,flags)];
        };
        NSMutableArray<NSDictionary *> *shapeList=[NSMutableArray array];
        for(NSDictionary *shape in Schema()[@"shapes"]) if(![shape[@"id"] isEqual:@"custom"]) [shapeList addObject:@{@"id":shape[@"id"],@"values":shape[@"values"]}];
        [shapeList addObject:@{@"id":@"custom",@"values":@{@"layout":@"row",@"width":@260,@"height":@36,@"radius":@8,@"showText":@NO,@"showStopButton":@YES,@"showDot":@YES}}];
        BOOL everyShapeOpens=YES,controlOpens=YES,noMenuOnLeft=YES,foldRestores=YES,stopDisabledWhileOpening=YES,openingNeverPresses=YES;
        NSMutableSet<NSString *> *capsuleSizes=[NSMutableSet set];
        for(NSDictionary *shape in shapeList) {
            NSMutableDictionary *values=[CRDDefaults() mutableCopy]; [values addEntriesFromDictionary:shape[@"values"]];
            values[@"mode"]=@"custom"; values[@"shape"]=shape[@"id"]; values[@"placement"]=@"center"; values[@"stopRevealSeconds"]=@30; apply(values); // A long fold delay: no timeout during the checks, and a fold timer that marks the end of the opening.
            BOOL dotLayout=[values[@"layout"] isEqual:@"dot"];
            NSView *target=dotLayout?overlay.dot:overlay.customView;
            NSPoint point=NSMakePoint(NSWidth(overlay.customView.bounds)*.2,NSHeight(overlay.customView.bounds)*.5);
            if(!dotLayout&&[overlay.customView hitTest:point]!=overlay.customView) everyShapeOpens=NO; // The point is background, never Stop.
            NSRect frameBefore=overlay.controller.window.frame; CGFloat alphaBefore=overlay.controller.window.alphaValue;
            for(NSNumber *control in @[@NO,@YES]) {
                NSEventModifierFlags flags=control.boolValue?NSEventModifierFlagControl:0;
                NSUInteger menusBefore=menusShown;
                if([target menuForEvent:flagged(NSEventTypeLeftMouseDown,point,2,0,flags)]!=nil) noMenuOnLeft=NO;
                pressFlagged(target,point,1,flags);
                BOOL singleIgnored=coordinator.stopRevealPanel==nil;
                pressFlagged(target,point,2,flags);
                CRDSessionStopButton *capsuleStop=coordinator.revealStopButton;
                BOOL opened=coordinator.stopRevealPanel!=nil&&singleIgnored&&trackingQueue.count==0&&menusShown==menusBefore;
                if(!opened) { if(control.boolValue) controlOpens=NO; else everyShapeOpens=NO; continue; }
                if(capsuleStop.enabled) stopDisabledWhileOpening=NO;
                // The opening double-click, and a quick click after it, can never press the capsule's Stop.
                capsuleStop.enabled=YES;
                if([capsuleStop acceptsPress:mouseAt(NSEventTypeLeftMouseDown,NSZeroPoint,2,0,0)]||[capsuleStop acceptsPress:mouseAt(NSEventTypeLeftMouseDown,NSZeroPoint,1,NSEvent.doubleClickInterval/2,0)]) openingNeverPresses=NO;
                capsuleStop.enabled=NO;
                waitForOpen();
                if(!dotLayout&&(overlay.controller.window.alphaValue!=0||!overlay.controller.window.ignoresMouseEvents)) everyShapeOpens=NO;
                [capsuleSizes addObject:NSStringFromSize(coordinator.stopRevealPanel.frame.size)];
                CRDBackground *capsuleBackground=(CRDBackground *)coordinator.stopRevealPanel.contentView;
                pressFlagged(capsuleBackground,NSMakePoint(2,NSMidY(capsuleBackground.bounds)),2,flags); waitForClose();
                if(coordinator.stopRevealPanel||!NSEqualRects(overlay.controller.window.frame,frameBefore)||overlay.controller.window.alphaValue!=alphaBefore||
                   overlay.controller.window.ignoresMouseEvents||overlay.customView.suppressBackground||inlineStopGate.blockedThrough<NSProcessInfo.processInfo.systemUptime) foldRestores=NO;
            }
        }
        check(@"double_click_on_every_shape_opens_the_stop_capsule",everyShapeOpens);
        check(@"control_double_click_opens_the_capsule_and_no_menu",controlOpens&&noMenuOnLeft&&menusShown==0);
        check(@"opening_double_click_never_presses_stop",openingNeverPresses);
        check(@"capsule_stop_is_disabled_while_the_capsule_opens",stopDisabledWhileOpening);
        check(@"folding_returns_the_window_to_its_shape_and_gates_the_inline_stop",foldRestores);
        // The dot layout's own dot changes the capsule's height only when it is taller than the pill.
        check(@"capsule_is_the_same_on_every_shape_but_the_dot",capsuleSizes.count<=2);
        // The grips: a double-click that neither moves nor resizes opens the capsule too.
        NSMutableDictionary *bar=[CRDDefaults() mutableCopy]; bar[@"mode"]=@"custom"; bar[@"placement"]=@"center"; bar[@"stopRevealSeconds"]=@0; apply(bar);
        BOOL grips=YES;
        for(CRDDragHandle *grip in @[overlay.handle,overlay.resizeHandle]) {
            NSRect before=overlay.controller.window.frame;
            pressFlagged(grip,NSMakePoint(NSMidX(grip.bounds),NSMidY(grip.bounds)),2,0);
            if(!coordinator.stopRevealPanel||!NSEqualRects(before,overlay.controller.window.frame)) grips=NO;
            [coordinator closeStopReveal:@"fixture"];
        }
        check(@"double_click_on_either_grip_opens_the_capsule",grips);
        // Remote pointer jitter must neither move nor resize the original, on either click.
        // Larger movement still drags/resizes, even when macOS reports clickCount 2.
        BOOL jitterOpens=YES,largeDrags=YES,lockedRelease=YES;
        for(NSView *view in @[overlay.customView,overlay.dot,overlay.handle,overlay.resizeHandle]) {
            NSMutableDictionary *values=[bar mutableCopy]; values[@"layout"]=view==overlay.dot?@"dot":@"row";
            values[@"width"]=@300; values[@"height"]=@60; values[@"draggable"]=@YES; values[@"resizable"]=@YES; values[@"constrainToScreen"]=@NO;
            apply(values); NSRect before=overlay.controller.window.frame; InvalidateGeometry();
            for(NSInteger count=1;count<=2;count++) press(view,NSMakePoint(2,2),@[at(3,3),at(6,6)],count);
            jitterOpens=jitterOpens&&coordinator.stopRevealPanel!=nil&&NSEqualRects(before,overlay.controller.window.frame)&&!geometryDirty;
            [coordinator closeStopReveal:@"fixture"];
            press(view,NSMakePoint(2,2),@[at(14,-10)],2);
            largeDrags=largeDrags&&!NSEqualRects(before,overlay.controller.window.frame)&&coordinator.stopRevealPanel==nil;
            // A stationary double-click immediately after a drag must open normally.
            press(view,NSMakePoint(2,2),@[],2);
            largeDrags=largeDrags&&coordinator.stopRevealPanel!=nil; [coordinator closeStopReveal:@"fixture"];
        }
        check(@"four_point_remote_jitter_keeps_double_clicks_on_all_grips_and_shapes",jitterOpens);
        check(@"larger_drags_and_resizes_stay_gestures_and_the_next_double_click_opens",largeDrags);
        // A one-point remote wobble on either click stays a click on every resize grip;
        // a deliberate resize still captures geometry and never opens Stop.
        BOOL resizeJitter=YES,resizeDrag=YES;
        for(NSDictionary *shape in Schema()[@"shapes"]) {
            NSMutableDictionary *values=[bar mutableCopy]; [values addEntriesFromDictionary:shape[@"values"]];
            values[@"resizable"]=@YES; apply(values);
            if(overlay.resizeHandle.hidden) continue;
            NSRect before=overlay.controller.window.frame;
            previewMode=NO; overlay.shown=YES;
            for(NSInteger count=1;count<=2;count++) press(overlay.resizeHandle,NSMakePoint(2,2),@[at(3,2)],count);
            resizeJitter=resizeJitter&&coordinator.stopRevealPanel!=nil&&NSEqualRects(before,overlay.controller.window.frame)&&!geometryDirty;
            [coordinator closeStopReveal:@"fixture"];
            apply(values);
            press(overlay.resizeHandle,NSMakePoint(2,2),@[at(12,-8)],2);
            resizeDrag=resizeDrag&&coordinator.stopRevealPanel==nil&&geometryDirty&&fabs(NSWidth(overlay.controller.window.frame)-NSWidth(before)-10)<.01;
            InvalidateGeometry(); previewMode=YES; overlay.shown=NO;
        }
        check(@"resize_grip_one_point_jitter_opens_capsule_without_saving_geometry",resizeJitter);
        check(@"resize_grip_real_drag_saves_geometry_instead_of_opening_capsule",resizeDrag);
        bar[@"resizable"]=@NO; apply(bar);
        press(overlay.resizeHandle,NSMakePoint(2,2),@[],2);
        lockedRelease=coordinator.stopRevealPanel!=nil&&trackingQueue.count==0;
        check(@"locked_resize_grip_waits_for_mouse_up_before_opening",lockedRelease);
        [coordinator closeStopReveal:@"fixture"];
        // A new gesture during the closing animation belongs to the original window. The old
        // completion cannot close the newly opened capsule; its fresh gate still rejects continuations.
        fixtureReduceMotion=@NO; apply(reveal);
        [coordinator presentStopRevealWithToken:tokenA afterEvent:doubleUp]; waitForOpen();
        NSPanel *closing=coordinator.stopRevealPanel;
        [coordinator closeStopReveal:@"user-collapsed"];
        BOOL acceptsReopen=closing.ignoresMouseEvents&&!overlay.controller.window.ignoresMouseEvents;
        if(acceptsReopen) press(overlay.dot,NSMakePoint(2,2),@[],2);
        NSPanel *reopened=coordinator.stopRevealPanel; RunFor(.3);
        check(@"double_click_during_close_reopens_without_a_stale_completion",acceptsReopen&&reopened!=closing&&coordinator.stopRevealPanel==reopened&&coordinator.revealStopButton.stopGestureGate!=nil);
        [coordinator closeStopReveal:@"fixture"]; fixtureReduceMotion=@YES;
        // Missing Stop is a disabled capsule, not a lost double-click. A new target closes it,
        // so the button never silently becomes armed while the pointer is already over it.
        fixtureStopToken=nil; apply(reveal); press(overlay.dot,NSMakePoint(2,2),@[],2);
        BOOL unavailableOpens=coordinator.stopRevealPanel!=nil&&!coordinator.revealStopButton.enabled&&!coordinator.revealStopButton.sessionToken;
        [coordinator validateStopRevealForToken:nil modeSignature:coordinator.revealModeSignature windowDetected:YES];
        unavailableOpens=unavailableOpens&&coordinator.stopRevealPanel!=nil;
        [coordinator validateStopRevealForToken:tokenA modeSignature:coordinator.revealModeSignature windowDetected:YES];
        check(@"unavailable_stop_opens_disabled_and_target_change_closes_it",unavailableOpens&&coordinator.stopRevealPanel==nil);
        fixtureStopToken=tokenA;
        for(NSString *layout in @[@"row",@"column",@"dot"]) {
            NSMutableDictionary *values=[bar mutableCopy]; values[@"layout"]=layout; values[@"width"]=@300; values[@"height"]=@120; values[@"showDot"]=@NO; apply(values);
            press(overlay.customView,NSMakePoint(2,2),@[],2);
            check(@"hidden_dot_keeps_background_double_click_available",coordinator.stopRevealPanel!=nil&&!coordinator.revealDot.hidden);
            [coordinator closeStopReveal:@"fixture"];
            if(![layout isEqual:@"dot"]) {
                values[@"showDot"]=@YES; apply(values);
                NSPoint point=NSMakePoint(NSMidX(overlay.dot.frame),NSMidY(overlay.dot.frame));
                NSView *hit=[overlay.customView hitTest:point]; press(hit,point,@[],2);
                check(@"inline_dot_passes_double_click_to_the_background",!overlay.dot.hidden&&hit==overlay.customView&&coordinator.stopRevealPanel!=nil);
                [coordinator closeStopReveal:@"fixture"];
            }
        }
        // All shapes keep a visible, correctly colored fold dot with showDot off. Manual
        // duration must be foldable from the background outside Stop and its margin.
        BOOL hiddenDotFolds=YES,hiddenDotMetrics=YES,visibleDotMetrics=YES;
        for(NSNumber *reduced in @[@NO,@YES]) for(NSDictionary *shape in Schema()[@"shapes"]) {
            fixtureReduceMotion=reduced;
            NSMutableDictionary *values=[bar mutableCopy]; [values addEntriesFromDictionary:shape[@"values"]];
            values[@"showDot"]=@NO; values[@"stopRevealSeconds"]=@0; apply(values);
            press(overlay.customView,NSMakePoint(2,2),@[],2); waitForOpen();
            CRDStatusDot *dot=coordinator.revealDot; NSPanel *capsule=coordinator.stopRevealPanel;
            NSPoint fold=NSMakePoint(NSMinX(dot.frame)+1,NSMidY(dot.frame));
            hiddenDotMetrics=hiddenDotMetrics&&capsule&&!dot.hidden&&NSWidth(dot.frame)==12&&dot.dotDiameter==12&&
                [dot.textColor isEqual:overlay.dot.textColor]&&!NSPointInRect(fold,coordinator.revealStopZone)&&!coordinator.revealTimer;
            press(capsule.contentView,fold,@[],2); waitForClose();
            hiddenDotFolds=hiddenDotFolds&&coordinator.stopRevealPanel==nil&&!overlay.controller.window.ignoresMouseEvents;
            [coordinator closeStopReveal:@"fixture"];
            values[@"showDot"]=@YES; values[@"dotDiameter"]=@24; apply(values);
            [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
            CGFloat expected=[currentConfig[@"layout"] isEqual:@"dot"]?MIN(24,MIN(NSWidth(overlay.controller.window.frame),NSHeight(overlay.controller.window.frame))):12;
            visibleDotMetrics=visibleDotMetrics&&!coordinator.revealDot.hidden&&coordinator.revealDot.dotDiameter==expected&&NSWidth(coordinator.revealDot.frame)==expected;
            [coordinator closeStopReveal:@"fixture"];
        }
        check(@"hidden_dot_capsules_keep_twelve_point_colored_fold_target_on_every_shape",hiddenDotMetrics);
        check(@"hidden_dot_manual_capsules_fold_outside_stop_in_both_motion_modes",hiddenDotFolds);
        check(@"only_visible_dot_layout_uses_the_original_dot_diameter",visibleDotMetrics);
        // Exercise the screen-notification handler itself. The real offscreen anchor is
        // displaced so its layout notification can observe whether the capsule closed first.
        BOOL screenCloses=YES,screenBeforeLayout=YES,screenKeepsConfig=YES;
        for(NSNumber *reduced in @[@NO,@YES]) for(NSValue *oldVisible in @[[NSValue valueWithRect:NSMakeRect(0,0,1440,876)],
            [NSValue valueWithRect:NSMakeRect(0,0,1366,744)],[NSValue valueWithRect:NSMakeRect(-1440,0,1440,876)]]) {
            fixtureReduceMotion=reduced; fixtureRevealVisibleFrame=oldVisible;
            apply(reveal); NSRect configured=overlay.controller.window.frame;
            [overlay.controller.window setFrameOrigin:NSMakePoint(NSMaxX(oldVisible.rectValue)-40,NSMaxY(oldVisible.rectValue)-40)];
            [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
            NSString *signature=FileSignature(); NSDictionary *config=currentConfig;
            __block BOOL sawLayout=NO,closedAtLayout=YES;
            id observer=[NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidMoveNotification object:overlay.controller.window queue:nil usingBlock:^(NSNotification *note){
                sawLayout=YES; closedAtLayout=closedAtLayout&&coordinator.stopRevealPanel==nil;
            }];
            [coordinator screenParametersChanged];
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            NSDictionary *status=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"runtime-status.json"]] options:0 error:nil];
            screenBeforeLayout=screenBeforeLayout&&sawLayout&&closedAtLayout;
            screenCloses=screenCloses&&!coordinator.stopRevealPanel&&!coordinator.revealTimer&&!coordinator.revealInputMonitor&&!overlay.controller.window.ignoresMouseEvents&&NSEqualRects(configured,overlay.controller.window.frame);
            screenKeepsConfig=screenKeepsConfig&&!geometryDirty&&[currentConfig isEqual:config]&&[FileSignature() isEqual:signature]&&[status[@"lastEvent"] isEqual:@"stop-reveal-closed-screens-changed"];
            [coordinator closeStopReveal:@"fixture"];
        }
        fixtureRevealVisibleFrame=nil;
        check(@"screen_change_closes_capsule_before_repositioning_the_anchor",screenCloses&&screenBeforeLayout);
        check(@"screen_change_does_not_persist_geometry_or_change_config",screenKeepsConfig);
        for(NSDictionary *change in @[@{@"mode":@"original"},@{@"enabled":@NO}]) {
            NSMutableDictionary *values=[bar mutableCopy]; [values addEntriesFromDictionary:change]; apply(values);
            press(overlay.customView,NSMakePoint(2,2),@[],2);
            check(@"non_custom_effective_mode_cannot_open_a_capsule",coordinator.stopRevealPanel==nil);
        }
        fixtureReduceMotion=nil; bar[@"resizable"]=@YES; apply(bar);
        // A right mouse down opens the window menu on the background and the grips, and the one-item
        // Stop menu on the capsule's Stop and dot; it never opens the capsule. A Control-left event
        // asks no view for a menu.
        NSEvent *controlLeft=flagged(NSEventTypeLeftMouseDown,NSMakePoint(20,20),1,0,NSEventModifierFlagControl);
        BOOL rightOpensMenus=YES;
        for(NSView *view in @[overlay.customView,overlay.handle,overlay.resizeHandle]) {
            NSUInteger before=menusShown; [view rightMouseDown:rightClick];
            if(menusShown!=before+1||lastMenu.numberOfItems!=8||coordinator.stopRevealPanel) rightOpensMenus=NO;
        }
        BOOL leftNeverAsks=[overlay.customView menuForEvent:controlLeft]==nil&&[overlay.handle menuForEvent:controlLeft]==nil&&[overlay.resizeHandle menuForEvent:controlLeft]==nil&&
            [overlay.stop menuForEvent:controlLeft]==nil&&[overlay.customView menuForEvent:fixtureClick]==nil;
        [coordinator presentStopRevealWithToken:tokenA]; waitForOpen();
        for(NSView *view in @[(NSView *)coordinator.revealStopButton,(NSView *)coordinator.revealDot]) {
            NSUInteger before=menusShown; [view rightMouseDown:rightClick];
            if(menusShown!=before+1||lastMenu.numberOfItems!=1) rightOpensMenus=NO;
            if([view menuForEvent:controlLeft]!=nil) leftNeverAsks=NO;
        }
        [coordinator closeStopReveal:@"fixture"];
        apply(reveal); NSUInteger dotBefore=menusShown; [overlay.dot rightMouseDown:rightClick];
        if(menusShown!=dotBefore+1||lastMenu.numberOfItems!=8||coordinator.stopRevealPanel) rightOpensMenus=NO;
        if([overlay.dot menuForEvent:controlLeft]!=nil) leftNeverAsks=NO;
        check(@"right_click_opens_the_menu_and_never_the_capsule",rightOpensMenus);
        check(@"left_events_never_ask_any_view_for_a_menu",leftNeverAsks);
        // The panels hand AppKit left events without the Control flag; every other event is unchanged.
        NSEvent *controlDouble=flagged(NSEventTypeLeftMouseDown,NSMakePoint(7,9),2,3.5,NSEventModifierFlagControl|NSEventModifierFlagShift);
        NSEvent *cleaned=LeftClickWithoutControl(controlDouble);
        check(@"panels_remove_the_control_flag_from_left_events_only",cleaned.type==NSEventTypeLeftMouseDown&&cleaned.clickCount==2&&cleaned.timestamp==3.5&&
            NSEqualPoints(cleaned.locationInWindow,NSMakePoint(7,9))&&!(cleaned.modifierFlags&NSEventModifierFlagControl)&&(cleaned.modifierFlags&NSEventModifierFlagShift)&&
            !(LeftClickWithoutControl(flagged(NSEventTypeLeftMouseUp,NSZeroPoint,2,0,NSEventModifierFlagControl)).modifierFlags&NSEventModifierFlagControl)&&
            LeftClickWithoutControl(rightClick)==rightClick&&LeftClickWithoutControl(fixtureClick)==fixtureClick&&
            ([CRDOverlayPanel instanceMethodForSelector:@selector(sendEvent:)]!=[NSPanel instanceMethodForSelector:@selector(sendEvent:)]));
        fixturePresentMenu=nil; fixtureStopToken=nil;
    }
    // The Stop pill: one red with white text above 4.5:1, darker when pressed, faded when disabled,
    // a press area at least the size of a native rounded button with the same title, and a height that fits short windows.
    {
        auto luminance=[](NSColor *color)->double {
            NSColor *c=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            auto channel=[](double v){ return v<=.04045?v/12.92:pow((v+.055)/1.055,2.4); };
            return .2126*channel(c.redComponent)+.7152*channel(c.greenComponent)+.0722*channel(c.blueComponent);
        };
        double contrast=1.05/(luminance(StopPillFill(@"red",YES,NO))+.05),pressedContrast=1.05/(luminance(StopPillFill(@"red",YES,YES))+.05);
        NSColor *red=[StopPillFill(@"red",YES,NO) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        check(@"stop_pill_red_keeps_white_text_above_4_5_to_1",contrast>=4.5&&pressedContrast>contrast&&fabs(red.redComponent*255-0xD9)<.5&&fabs(red.greenComponent*255-0x30)<.5&&fabs(red.blueComponent*255-0x36)<.5&&
            [StopPillTitleColor(@"red",YES,NO) isEqual:NSColor.whiteColor]&&StopPillFill(@"red",NO,NO).alphaComponent<.5&&StopPillTitleColor(@"red",NO,NO).alphaComponent<1);
        // The grey style, resolved in each look: red text on a grey pill at 4.5:1 or more, pressed
        // included; a pressed fill that differs from the resting one; faded colors when disabled.
        {
            auto resolved=[](NSColor *color,NSString *look)->NSColor * {
                __block NSColor *result=nil;
                [[NSAppearance appearanceNamed:[look isEqual:@"dark"]?NSAppearanceNameDarkAqua:NSAppearanceNameAqua] performAsCurrentDrawingAppearance:^{ result=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; }];
                return result;
            };
            auto ratio=[&](NSColor *a,NSColor *b,NSString *look) {
                double x=luminance(resolved(a,look)),y=luminance(resolved(b,look));
                return (MAX(x,y)+.05)/(MIN(x,y)+.05);
            };
            BOOL grayReadable=YES,grayHues=YES,grayStates=YES;
            for(NSString *look in @[@"light",@"dark"]) {
                if(ratio(StopPillTitleColor(@"gray",YES,NO),StopPillFill(@"gray",YES,NO),look)<4.5||ratio(StopPillTitleColor(@"gray",YES,YES),StopPillFill(@"gray",YES,YES),look)<4.5) grayReadable=NO;
                NSColor *fill=resolved(StopPillFill(@"gray",YES,NO),look),*text=resolved(StopPillTitleColor(@"gray",YES,NO),look),*pressed=resolved(StopPillFill(@"gray",YES,YES),look);
                if(fabs(fill.redComponent-fill.greenComponent)>.03||fabs(fill.greenComponent-fill.blueComponent)>.03||text.redComponent-text.greenComponent<.3||text.redComponent-text.blueComponent<.3) grayHues=NO;
                if(fabs(pressed.redComponent-fill.redComponent)<.02||resolved(StopPillFill(@"gray",NO,NO),look).alphaComponent>=1||resolved(StopPillTitleColor(@"gray",NO,NO),look).alphaComponent>=.6) grayStates=NO;
            }
            BOOL looksDiffer=resolved(StopPillFill(@"gray",YES,NO),@"light").redComponent>resolved(StopPillFill(@"gray",YES,NO),@"dark").redComponent+.4;
            check(@"stop_pill_gray_keeps_red_text_above_4_5_to_1_in_light_and_dark",grayReadable&&grayHues&&grayStates&&looksDiffer);
            NSColor *unknown=[StopPillFill(@"unknown",YES,NO) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            check(@"stop_style_is_validated_and_defaults_to_red",[CRDDefaults()[@"stopStyle"] isEqual:@"red"]&&[ChoiceIDs(@"stopStyle") isEqual:(@[@"red",@"gray"])]&&
                Validate(@{@"stopStyle":@"gray"},nil)!=nil&&Validate(@{@"stopStyle":@"blue"},nil)==nil&&Validate(@{@"stopStyle":@1},nil)==nil&&[unknown isEqual:red]&&
                [PresetValues(@{@"stopStyle":@"gray"})[@"stopStyle"] isEqual:@"gray"]);
        }
        NSMutableDictionary *bar=[CRDDefaults() mutableCopy]; bar[@"mode"]=@"custom"; bar[@"accent"]=@"green"; bar[@"borderWidth"]=@2;
        BOOL atLeastNative=YES,accentFree=YES; NSColor *firstEdge=nil;
        for(NSString *language in @[@"ko",@"en"]) for(NSString *look in @[@"light",@"dark"]) {
            fixtureLanguage=language; bar[@"appearance"]=look; apply(bar);
            NSButton *native=[NSButton buttonWithTitle:overlay.stop.title target:nil action:nil]; native.bezelStyle=NSBezelStyleRounded; native.font=[NSFont systemFontOfSize:NSFont.systemFontSize]; [native sizeToFit];
            if(NSWidth(overlay.stop.frame)<NSWidth(native.frame)||NSHeight(overlay.stop.frame)<MAX(24,NSHeight(native.frame))) atLeastNative=NO;
            // The pill draws its red in both looks; the accent colors only the dot and the border.
            overlay.stop.enabled=YES;
            NSBitmapImageRep *raster=[overlay.stop bitmapImageRepForCachingDisplayInRect:overlay.stop.bounds]; [overlay.stop cacheDisplayInRect:overlay.stop.bounds toBitmapImageRep:raster];
            NSColor *edge=[[raster colorAtX:(NSInteger)(raster.pixelsWide*.08) y:raster.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            // The cache bitmap uses the display's color space, so the sample is compared with the
            // first look and checked for a red hue rather than for the exact sRGB value.
            if(!firstEdge) firstEdge=edge;
            if(edge.redComponent<.7||edge.greenComponent>.35||edge.blueComponent>.35||fabs(edge.redComponent-firstEdge.redComponent)>.01||
               fabs(edge.greenComponent-firstEdge.greenComponent)>.01||fabs(edge.blueComponent-firstEdge.blueComponent)>.01) accentFree=NO;
            overlay.stop.enabled=NO;
        }
        fixtureLanguage=nil;
        check(@"inline_stop_pill_press_area_is_at_least_the_native_button",atLeastNative);
        // Every built-in shape keeps its dot, its caption and its Stop pill, in both languages.
        BOOL shapesKeepControls=YES;
        for(NSString *language in @[@"ko",@"en"]) for(NSDictionary *shape in Schema()[@"shapes"]) {
            if([shape[@"id"] isEqual:@"custom"]||[shape[@"values"][@"layout"] isEqual:@"dot"]) continue;
            fixtureLanguage=language; NSMutableDictionary *values=[CRDDefaults() mutableCopy]; [values addEntriesFromDictionary:shape[@"values"]]; values[@"mode"]=@"custom"; apply(values);
            if(overlay.dot.hidden||overlay.stop.hidden||overlay.label.hidden!=![values[@"showText"] boolValue]||NSIntersectsRect(overlay.dot.frame,overlay.stop.frame)) shapesKeepControls=NO;
        }
        fixtureLanguage=nil;
        check(@"every_shape_keeps_its_dot_caption_and_stop",shapesKeepControls);
        // The grey style keeps every inline Stop frame of the red one, and draws a grey pill whose
        // shade follows the look.
        BOOL sameFrames=YES,grayRaster=YES; NSColor *lightGray=nil,*darkGray=nil;
        for(NSString *language in @[@"ko",@"en"]) for(NSDictionary *shape in Schema()[@"shapes"]) {
            if([shape[@"id"] isEqual:@"custom"]||[shape[@"values"][@"layout"] isEqual:@"dot"]) continue;
            fixtureLanguage=language; NSMutableDictionary *values=[CRDDefaults() mutableCopy]; [values addEntriesFromDictionary:shape[@"values"]]; values[@"mode"]=@"custom";
            apply(values); NSRect redFrame=overlay.stop.frame;
            values[@"stopStyle"]=@"gray"; apply(values);
            if(!NSEqualRects(redFrame,overlay.stop.frame)||![((CRDSessionStopButton *)overlay.stop).stopStyle isEqual:@"gray"]) sameFrames=NO;
        }
        for(NSString *look in @[@"light",@"dark"]) {
            NSMutableDictionary *grayBar=[bar mutableCopy]; grayBar[@"appearance"]=look; grayBar[@"stopStyle"]=@"gray"; apply(grayBar); overlay.stop.enabled=YES;
            NSBitmapImageRep *raster=[overlay.stop bitmapImageRepForCachingDisplayInRect:overlay.stop.bounds]; [overlay.stop cacheDisplayInRect:overlay.stop.bounds toBitmapImageRep:raster];
            NSColor *edge=[[raster colorAtX:(NSInteger)(raster.pixelsWide*.08) y:raster.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if(fabs(edge.redComponent-edge.greenComponent)>.05||fabs(edge.greenComponent-edge.blueComponent)>.05) grayRaster=NO;
            if([look isEqual:@"light"]) lightGray=edge; else darkGray=edge;
            overlay.stop.enabled=NO;
        }
        fixtureLanguage=nil;
        check(@"gray_stop_keeps_every_inline_frame_and_draws_grey_in_both_looks",sameFrames&&grayRaster&&lightGray.redComponent>darkGray.redComponent+.3);
        check(@"stop_pill_is_red_in_light_and_dark_whatever_the_accent",accentFree);
        NSMutableDictionary *shortBar=[bar mutableCopy]; shortBar[@"height"]=@26; shortBar[@"shape"]=@"custom"; apply(shortBar);
        BOOL shortFits=!overlay.stop.hidden&&NSHeight(overlay.stop.frame)==26;
        shortBar[@"height"]=@22; apply(shortBar); BOOL tooShortHides=overlay.stop.hidden;
        NSMutableDictionary *longLabel=[bar mutableCopy]; longLabel[@"buttonText"]=[@"" stringByPaddingToLength:120 withString:@"공유 중지 " startingAtIndex:0]; apply(longLabel);
        BOOL inlineClamped=!overlay.stop.hidden&&NSMaxX(overlay.stop.frame)<=NSWidth(overlay.customView.bounds);
        CRDCapsuleLayout longCapsule=CapsuleLayout(StopPillSize(overlay.stop.title,StopPillFont(NSFont.systemFontSize)),CRDCapsuleDotDiameter);
        check(@"stop_pill_fits_short_windows_and_long_labels",shortFits&&tooShortHides&&inlineClamped&&NSWidth(longCapsule.pill)==CRDCapsulePillMaximumWidth);
        // The capsule layout: 6 pt around the pill, a 12 pt dot 12 pt from the left end and
        // 10 pt before the pill, everything centered, and a press area of at least 120 x 36 pt.
        CRDCapsuleLayout layout=CapsuleLayout(StopPillSize(L(@"공유 중지"),StopPillFont(NSFont.systemFontSize)),CRDCapsuleDotDiameter);
        CRDCapsuleLayout fallbackDot=CapsuleLayout(StopPillSize(L(@"공유 중지"),StopPillFont(NSFont.systemFontSize)),0);
        check(@"capsule_layout_metrics",NSMinY(layout.pill)==6&&layout.size.height-NSMaxY(layout.pill)==6&&layout.size.width-NSMaxX(layout.pill)==6&&
            NSMinX(layout.dot)==12&&NSWidth(layout.dot)==12&&NSMinX(layout.pill)-NSMaxX(layout.dot)==10&&NSMidY(layout.dot)==NSMidY(layout.pill)&&NSMidY(layout.pill)==layout.size.height/2&&
            NSWidth(layout.press)>=CRDStopHitWidth&&NSHeight(layout.press)>=CRDStopHitHeight&&NSContainsRect(layout.press,layout.pill)&&NSMaxX(layout.press)==layout.size.width&&NSMinX(layout.press)>NSMaxX(layout.dot)&&
            NSEqualRects(fallbackDot.dot,layout.dot)&&NSEqualRects(fallbackDot.press,layout.press));
        apply(reveal);
    }
    // Verify an actual comparable JSONL record, including explicit prior geometry settings.
    eventLog=[[CRDEventLog alloc] initWithPath:[dir stringByAppendingPathComponent:@"comparison/events.jsonl"]];
    NSMutableDictionary *before=[currentConfig mutableCopy]; before[@"width"]=@111; before[@"text"]=@"SECRET-CONNECTION-TEXT"; before[@"buttonText"]=@"SECRET-BUTTON-TEXT"; currentConfig=before;
    geometryPreviousSettings=SettingsSnapshot(); previousLoggedSettings=@{@"width":@999};
    NSDictionary *oldFrame=@{@"x":@1,@"y":@2,@"width":@111,@"height":@40};
    previousLoggedState=@{@"frame":oldFrame}; NSMutableDictionary *after=[before mutableCopy]; after[@"width"]=@222; after[@"shape"]=@"custom"; currentConfig=after;
    NSDictionary *newFrame=@{@"x":@80,@"y":@90,@"width":@222,@"height":@40};
    NSDictionary *fixtureState=@{@"frame":newFrame,@"mode":@"custom",@"originalPid":NSNull.null,@"originalWindowDetected":@NO,@"originalWindowGeneration":@0,@"originalHidden":@NO,@"visible":@NO,@"detectionReason":@"fixture",@"configReloadCount":@0};
    fixtureMode=NO; LogRuntimeEvent(@"geometry-saved",fixtureState); fixtureMode=YES; geometryPreviousSettings=nil;
    NSArray *comparison=[eventLog readRecords]; NSDictionary *comparisonEvent=comparison.lastObject;
    check(@"log_compares_prior_settings_and_actual_frames",[comparisonEvent[@"previousSettings"][@"width"] isEqual:@111]&&[comparisonEvent[@"currentSettings"][@"width"] isEqual:@222]&&[comparisonEvent[@"previousFrame"] isEqual:oldFrame]&&[comparisonEvent[@"currentFrame"] isEqual:newFrame]&&[comparisonEvent[@"timestamp"] length]>0&&[comparisonEvent[@"timestampSeconds"] doubleValue]>0);
    NSString *loggedText=[[NSString alloc] initWithData:[NSData dataWithContentsOfFile:eventLog.path] encoding:NSUTF8StringEncoding];
    check(@"log_omits_custom_text_values",![loggedText containsString:@"SECRET-CONNECTION-TEXT"]&&![loggedText containsString:@"SECRET-BUTTON-TEXT"]);
    eventLog=nil; previousLoggedSettings=nil; previousLoggedState=nil;
    // Hide, restore and Stop checks exercise production decisions with a recorder at the AX boundary.
    CRDFixtureApplication *fakeApp=[CRDFixtureApplication new]; fakeApp.processIdentifier=9876;
    fixtureApplication=fakeApp; fixtureBirth=@"fixture-birth-1";
    fixtureProcessUID=@(getuid()==0?501:0);
    check(@"foreign_uid_host_is_rejected_before_binding",!OriginalIdentity((id)fakeApp,@"/fixture/CRD host"));
    [coordinator bindOriginal:(id)fakeApp];
    check(@"binding_rechecks_uid_before_creating_ax_target",coordinator.original==nil&&coordinator.applicationElement==nil);
    fixtureProcessUID=nil;
    check(@"unavailable_uid_metadata_is_not_accepted",!OriginalIdentity((id)fakeApp,@"/fixture/CRD host"));
    fixtureProcessUID=@(getuid());
    check(@"current_uid_host_remains_eligible",OriginalIdentity((id)fakeApp,@"/fixture/CRD host"));
    CRDFixtureApplication *previousApp=[CRDFixtureApplication new]; previousApp.processIdentifier=getpid()+1;
    CRDContextMenuTracking *focusTracking=[CRDContextMenuTracking new];
    __block NSUInteger activations=0,settingsOpens=0;
    fixtureActivatePrevious=^(NSRunningApplication *app){ activations++; };
    fixtureOpenSettings=^(NSURL *url){ settingsOpens++; };
    activeContextMenu=focusTracking;
    RestorePreviousApplication(focusTracking,(id)previousApp,YES,getpid());
    check(@"cancelled_menu_restores_previous_application",activations==1);
    focusTracking.clickedOutsideApplication=YES;
    RestorePreviousApplication(focusTracking,(id)previousApp,YES,getpid());
    focusTracking.clickedOutsideApplication=NO;
    RestorePreviousApplication(focusTracking,(id)previousApp,NO,previousApp.processIdentifier);
    RestorePreviousApplication(focusTracking,(id)previousApp,YES,previousApp.processIdentifier);
    check(@"outside_click_and_changed_frontmost_application_keep_focus",activations==1);
    OpenSettingsApplication(nil);
    RestorePreviousApplication(focusTracking,(id)previousApp,YES,getpid());
    check(@"missing_settings_target_keeps_normal_menu_dismissal",activations==2&&settingsOpens==0);
    OpenSettingsApplication([NSURL fileURLWithPath:@"/fixture/CRD Window Studio.app"]);
    RestorePreviousApplication(focusTracking,(id)previousApp,YES,getpid()); // LaunchServices has not activated Settings yet.
    RestorePreviousApplication(focusTracking,(id)previousApp,NO,previousApp.processIdentifier); // It has already activated.
    check(@"settings_request_never_reactivates_previous_app",settingsOpens==1&&activations==2&&focusTracking.openingSettings);
    activeContextMenu=nil; fixtureActivatePrevious=nil; fixtureOpenSettings=nil;
    coordinator.original=(id)fakeApp; coordinator.originalBirth=fixtureBirth;
    coordinator.hostExecutablePath=@"/fixture/CRD host"; coordinator.applicationElement=@"fixture-application";
    coordinator.trusted=YES;
    __block BOOL hidden=NO,hiddenKnown=YES,writeSucceeds=YES,readAfterWrite=YES;
    __block NSUInteger hiddenWrites=0,presses=0;
    NSDictionary *arrow=@{@"AXRole":@"AXButton",@"AXTitle":@"▲",@"AXChildren":@[]};
    NSDictionary *stop=@{@"AXRole":@"AXButton",@"AXEnabled":@YES,@"fixturePress":@YES,@"AXChildren":@[]};
    NSDictionary *text=@{@"AXRole":@"AXStaticText",@"AXChildren":@[]};
    NSDictionary *windowA=@{@"AXRole":@"AXWindow",@"AXChildren":@[arrow,stop,text],@"fixtureID":@"A"};
    NSDictionary *windowB=@{@"AXRole":@"AXWindow",@"AXChildren":@[arrow,stop,text],@"fixtureID":@"B"};
    __block NSArray *freshWindows=@[windowA];
    fixtureAXRead=^id(id element,CFStringRef attribute,AXError *error){
        id value=nil;
        if([element isEqual:@"fixture-application"]) {
            if(CFEqual(attribute,kAXHiddenAttribute)&&hiddenKnown) value=@(hidden);
            if(CFEqual(attribute,kAXWindowsAttribute)) value=freshWindows;
        } else if([element isKindOfClass:NSDictionary.class]) value=element[(__bridge NSString *)attribute];
        if(error) *error=value?kAXErrorSuccess:kAXErrorAttributeUnsupported;
        return value;
    };
    fixtureAXWrite=^AXError(id element,BOOL value){
        hiddenWrites++;
        if(!writeSucceeds) return kAXErrorCannotComplete;
        hidden=value; hiddenKnown=readAfterWrite; return kAXErrorSuccess;
    };
    fixtureAXPress=^AXError(id element){ presses++; return kAXErrorSuccess; };
    fixtureJournalWrite=^BOOL(NSDictionary *intent){ return NO; };
    check(@"hide_refused_when_intent_write_fails",!SetOriginalHidden(coordinator,YES)&&hiddenWrites==0&&!coordinator.ownsHidden);
    fixtureJournalWrite=nil;
    readAfterWrite=NO;
    check(@"uncertain_hide_keeps_durable_intent",!SetOriginalHidden(coordinator,YES)&&coordinator.ownsHidden&&[coordinator.restoreIntent[@"pending"] boolValue]&&[NSFileManager.defaultManager fileExistsAtPath:RestorePath()]);
    writeSucceeds=NO;
    check(@"failed_restore_cannot_release_target",![coordinator releaseOriginal]&&coordinator.original==(id)fakeApp&&coordinator.ownsHidden&&coordinator.restorationBlocked);
    writeSucceeds=YES; readAfterWrite=YES;
    check(@"restore_writes_even_when_preread_unknown",SetOriginalHidden(coordinator,NO)&&!hidden&&!coordinator.ownsHidden&&!coordinator.restorationBlocked);
    hiddenKnown=YES;
    SetOriginalHidden(coordinator,YES); writeSucceeds=NO;
    BOOL directRestore=SetOriginalHidden(coordinator,NO);
    WriteRuntimeStatus(@"fixture-mode-restore-failed",nil);
    NSDictionary *blockedStatus=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"runtime-status.json"]] options:0 error:nil];
    check(@"failed_mode_unhide_blocks_readiness_and_keeps_journal",!directRestore&&hidden&&coordinator.ownsHidden&&coordinator.restorationBlocked&&[blockedStatus[@"agentReady"] isEqual:@NO]&&[blockedStatus[@"restorationBlocked"] isEqual:@YES]&&[coordinator.restoreIntent[@"pending"] isEqual:@YES]);
    NSUInteger blockedWrites=hiddenWrites;
    check(@"blocked_restore_cannot_hide_again",!SetOriginalHidden(coordinator,YES)&&hiddenWrites==blockedWrites);
    writeSucceeds=YES; SetOriginalHidden(coordinator,NO); SetOriginalHidden(coordinator,YES);
    readAfterWrite=NO;
    check(@"failed_unhide_readback_also_blocks",!SetOriginalHidden(coordinator,NO)&&coordinator.restorationBlocked&&coordinator.ownsHidden);
    readAfterWrite=YES;
    check(@"explicit_unhide_retry_clears_block_only_after_confirmation",SetOriginalHidden(coordinator,NO)&&!coordinator.restorationBlocked&&!coordinator.ownsHidden);
    SetOriginalHidden(coordinator,YES);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil]; RunFor(.3);
    NSData *recreatedJournal=[NSData dataWithContentsOfFile:RestorePath()];
    NSDictionary *recreatedIntent=recreatedJournal?[NSJSONSerialization JSONObjectWithData:recreatedJournal options:0 error:nil]:nil;
    check(@"directory_recreation_preserves_pending_restore_journal",[recreatedIntent[@"pending"] isEqual:@YES]);
    coordinator.ownsHidden=NO; coordinator.original=nil; coordinator.applicationElement=nil; // Simulated crash.
    fixtureObserverSetup=^AXError{ return kAXErrorSuccess; };
    [coordinator recoverPreviousHide];
    check(@"relaunch_recovers_intent_before_discovery",!hidden&&!coordinator.ownsHidden&&!coordinator.restorationBlocked);
    SetOriginalHidden(coordinator,YES); NSUInteger writesBeforeReuse=hiddenWrites;
    coordinator.ownsHidden=NO; coordinator.original=nil; coordinator.applicationElement=nil; fixtureBirth=@"fixture-birth-2";
    [coordinator recoverPreviousHide];
    check(@"reused_pid_never_receives_restore_write",hiddenWrites==writesBeforeReuse&&![coordinator.restoreIntent[@"pending"] boolValue]);
    hidden=NO;
    [coordinator bindOriginal:(id)fakeApp]; SetOriginalHidden(coordinator,YES);
    fixtureBirth=nil; fixtureProcessExistenceError=EPERM;
    NSUInteger beforeUnknown=hiddenWrites;
    check(@"uninspectable_live_target_keeps_obligation",![coordinator releaseOriginal]&&coordinator.ownsHidden&&coordinator.restorationBlocked&&hiddenWrites==beforeUnknown);
    fixtureProcessExistenceError=ESRCH;
    check(@"confirmed_dead_target_clears_even_before_workspace_updates",!fakeApp.terminated&&[coordinator releaseOriginal]&&!coordinator.ownsHidden&&[coordinator.restoreIntent[@"pending"] isEqual:@NO]&&hiddenWrites==beforeUnknown);
    fixtureProcessExistenceError=0; fixtureBirth=@"fixture-birth-2";
    NSDictionary *pendingIntent=@{@"pending":@YES,@"pid":@(fakeApp.processIdentifier),@"birth":fixtureBirth,@"executable":coordinator.hostExecutablePath};
    StoreRestoreIntent(coordinator,pendingIntent); hidden=YES; hiddenKnown=YES;
    coordinator.restorationOnly=YES; coordinator.trusted=NO;
    __block NSUInteger recoveryObserverSetups=0;
    fixtureObserverSetup=^AXError{ recoveryObserverSetups++; return kAXErrorSuccess; };
    [coordinator recoverPreviousHide];
    check(@"restore_only_without_permission_retains_live_obligation",coordinator.ownsHidden&&coordinator.restorationBlocked&&hidden&&hiddenWrites==beforeUnknown&&recoveryObserverSetups==0);
    coordinator.trusted=YES;
    [coordinator recoverPreviousHide];
    check(@"restore_only_after_grant_unhides_without_observers_or_rehide",!hidden&&!coordinator.ownsHidden&&!coordinator.restorationBlocked&&recoveryObserverSetups==0&&hiddenWrites==beforeUnknown+1);
    [coordinator releaseOriginal];
    StoreRestoreIntent(coordinator,pendingIntent); fixtureBirth=nil; fixtureProcessExistenceError=EPERM;
    [coordinator recoverPreviousHide];
    check(@"restore_only_unknown_birth_never_clears_journal",coordinator.restorationBlocked&&[coordinator.restoreIntent[@"pending"] isEqual:@YES]);
    fixtureProcessExistenceError=ESRCH; coordinator.trusted=NO;
    [coordinator recoverPreviousHide];
    check(@"restore_only_dead_target_needs_no_permission_or_ax_write",!coordinator.restorationBlocked&&[coordinator.restoreIntent[@"pending"] isEqual:@NO]&&hiddenWrites==beforeUnknown+1);
    [NSFileManager.defaultManager removeItemAtPath:RestorePath() error:nil];
    [coordinator recoverPreviousHide];
    check(@"restore_only_missing_journal_is_not_new_installation",coordinator.restorationBlocked&&![NSFileManager.defaultManager fileExistsAtPath:RestorePath()]);
    NSMutableDictionary *invalidIntent=[pendingIntent mutableCopy]; invalidIntent[@"birth"]=@"";
    StoreRestoreIntent(coordinator,invalidIntent); fixtureBirth=@"fixture-birth-2"; fixtureProcessExistenceError=0;
    [coordinator recoverPreviousHide];
    check(@"restore_only_empty_birth_is_not_evidence_of_replacement",coordinator.restorationBlocked&&[coordinator.restoreIntent[@"pending"] isEqual:@YES]&&hiddenWrites==beforeUnknown+1);
    invalidIntent=[pendingIntent mutableCopy]; invalidIntent[@"pid"]=@9876.5;
    StoreRestoreIntent(coordinator,invalidIntent); fixtureBirth=nil; fixtureProcessExistenceError=ESRCH;
    [coordinator recoverPreviousHide];
    check(@"malformed_journal_pid_is_not_truncated_into_death_evidence",coordinator.restorationBlocked&&[coordinator.restoreIntent[@"pending"] isEqual:@YES]);
    CompleteRestore(coordinator);
    fixtureProcessExistenceError=0; fixtureBirth=@"fixture-birth-2"; coordinator.restorationOnly=NO; coordinator.trusted=YES;
    fixtureObserverSetup=^AXError{ return kAXErrorSuccess; };
    [coordinator bindOriginal:(id)fakeApp];
    coordinator.windowElement=windowA; coordinator.stopElement=stop; coordinator.windowDetected=YES; coordinator.stopAvailable=YES;
    // Real status-menu actions with the end-of-tracking notification, and the GUI preset path
    // (a config write and the real CRDReload, never applyPreset:), then fast continuation clicks on the
    // inline Stop through native button tracking: the off-screen fixture cell, the synthetic AX tree and
    // the press recorder. Every continuation presses nothing; a separate click after the interval presses once.
    {
        NSDictionary *savedConfig=[currentConfig copy]; BOOL savedPreview=previewMode; NSNumber *savedTrusted=fixtureTrusted;
        previewMode=NO; fixtureTrusted=@YES;
        CRDSessionStopButton *inlineButton=(CRDSessionStopButton *)overlay.stop; NSCell *savedCell=inlineButton.cell;
        CRDTrackingFixtureCell *fixtureCell=[[CRDTrackingFixtureCell alloc] initTextCell:@"Fixture Stop"]; fixtureCell.duringTracking=^{};
        inlineButton.cell=fixtureCell; inlineButton.target=coordinator; inlineButton.action=@selector(stopSharingClicked:);
        void (^ready)(void)=^{
            coordinator.windowElement=windowA; coordinator.stopElement=stop; coordinator.windowDetected=YES; coordinator.stopAvailable=YES;
            freshWindows=@[windowA]; inlineButton.enabled=YES; inlineButton.sessionToken=[coordinator currentStopToken];
        };
        NSEvent *(^click)(NSEventType,NSInteger,NSTimeInterval)=^NSEvent *(NSEventType type,NSInteger count,NSTimeInterval time){
            return [NSEvent mouseEventWithType:type location:NSMakePoint(NSMidX(inlineButton.frame),NSMidY(inlineButton.frame)) modifierFlags:0
                timestamp:time windowNumber:inlineButton.window.windowNumber context:nil eventNumber:11 clickCount:count pressure:1];
        };
        BOOL (^continuationsThenSeparateClick)(void)=^BOOL{
            NSUInteger before=presses; NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            ready(); [inlineButton mouseDown:click(NSEventTypeLeftMouseDown,1,now)]; [inlineButton mouseUp:click(NSEventTypeLeftMouseUp,1,now+.02)];
            ready(); [inlineButton mouseDown:click(NSEventTypeLeftMouseDown,2,now+.05)]; [inlineButton mouseUp:click(NSEventTypeLeftMouseUp,2,now+.07)];
            BOOL continuationsPressedNothing=presses==before;
            ready(); [inlineButton mouseDown:click(NSEventTypeLeftMouseDown,1,inlineStopGate.blockedThrough+.01)];
            return !inlineButton.hidden&&continuationsPressedNothing&&presses==before+1&&!inlineButton.window.visible;
        };
        NSDictionary *names=@{@8:@"lock_position",@7:@"center",@4:@"mode",@2:@"switch",@9:@"lock_size_control"};
        for(NSNumber *reduced in @[@NO,@YES]) {
            fixtureReduceMotion=reduced;
            for(NSNumber *index in @[@8,@7,@4,@2,@9]) {
                NSMutableDictionary *config=[CRDDefaults() mutableCopy];
                config[@"mode"]=[index isEqual:@4]?@"original":@"custom"; config[@"enabled"]=@(![index isEqual:@2]);
                config[@"layout"]=@"row"; config[@"width"]=@(reduced.boolValue?441:440); config[@"height"]=@48;
                config[@"placement"]=@"custom"; config[@"x"]=@50; config[@"y"]=@50;
                CRDWriteConfig(config,nil); CRDReload(); ready(); inlineStopGate.blockedThrough=0;
                NSMenu *menu=[coordinator statusMenu]; [coordinator menuNeedsUpdate:menu];
                [menu performActionForItemAtIndex:index.integerValue];
                [NSNotificationCenter.defaultCenter postNotificationName:NSMenuDidEndTrackingNotification object:menu];
                check([NSString stringWithFormat:@"status_menu_%@_then_fast_clicks_press_nothing_and_a_later_click_presses_once",names[index]],continuationsThenSeparateClick());
            }
            NSMutableDictionary *dot=[CRDDefaults() mutableCopy]; dot[@"mode"]=@"custom"; dot[@"layout"]=@"dot"; dot[@"width"]=@40; dot[@"height"]=@40;
            CRDWriteConfig(dot,nil); CRDReload(); BOOL dotHidesStop=inlineButton.hidden; inlineStopGate.blockedThrough=0;
            NSMutableDictionary *bar=[dot mutableCopy]; bar[@"layout"]=@"row"; bar[@"width"]=@(reduced.boolValue?441:440); bar[@"height"]=@48;
            CRDWriteConfig(bar,nil); CRDReload();
            check(@"gui_reload_dot_to_bar_then_fast_clicks_press_nothing_and_a_later_click_presses_once",dotHidesStop&&continuationsThenSeparateClick());
            // The frame change itself (setFrame and the Layout its resize notification runs) moves this Stop.
            inlineStopGate.blockedThrough=0; bar[@"width"]=@(reduced.boolValue?561:560);
            CRDWriteConfig(bar,nil); CRDReload();
            check(@"gui_reload_that_resizes_the_bar_blocks_its_moved_stop",continuationsThenSeparateClick());
        }
        fixtureReduceMotion=nil;
        // A menu dismissed without an action: the delegate close alone blocks, and so does the end of tracking for the expanded dot's Stop.
        ready(); inlineStopGate.blockedThrough=0;
        NSMenu *dismissed=[coordinator statusMenu]; [coordinator menuNeedsUpdate:dismissed]; [dismissed.delegate menuDidClose:dismissed];
        check(@"status_menu_delegate_close_alone_blocks_the_inline_stop",continuationsThenSeparateClick());
        NSMutableDictionary *expandable=[CRDDefaults() mutableCopy]; expandable[@"mode"]=@"custom"; expandable[@"layout"]=@"dot"; expandable[@"width"]=@40; expandable[@"height"]=@40;
        CRDWriteConfig(expandable,nil); CRDReload(); ready();
        [coordinator presentStopRevealWithToken:[coordinator currentStopToken] afterEvent:nil];
        CRDSessionStopButton *capsuleStop=coordinator.revealStopButton; capsuleStop.stopGestureGate.blockedThrough=0;
        NSMenu *closed=[coordinator statusMenu]; [coordinator menuNeedsUpdate:closed];
        [NSNotificationCenter.defaultCenter postNotificationName:NSMenuDidEndTrackingNotification object:closed];
        capsuleStop.enabled=YES; // Decision checks only; this capsule never sends a press.
        NSPoint onCapsule=NSMakePoint(NSMidX(capsuleStop.frame),NSMidY(capsuleStop.frame));
        BOOL capsuleQuickRejected=![capsuleStop acceptsPress:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:onCapsule modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil eventNumber:12 clickCount:1 pressure:1]];
        BOOL capsuleLaterAccepted=[capsuleStop acceptsPress:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:onCapsule modifierFlags:0 timestamp:capsuleStop.stopGestureGate.blockedThrough+.01 windowNumber:0 context:nil eventNumber:13 clickCount:1 pressure:1]];
        capsuleStop.enabled=NO; [coordinator closeStopReveal:@"fixture"];
        check(@"status_menu_close_also_blocks_the_expanded_dot_stop",capsuleStop!=nil&&capsuleQuickRejected&&capsuleLaterAccepted&&!capsuleStop.window.visible);
        inlineButton.cell=savedCell; previewMode=savedPreview; fixtureTrusted=savedTrusted;
        CRDWriteConfig(savedConfig,nil); CRDReload(); presses=0;
        coordinator.windowElement=windowA; coordinator.stopElement=stop; coordinator.windowDetected=YES; coordinator.stopAvailable=YES;
        freshWindows=@[windowA];
    }
    NSMenuItem *stopItem=[coordinator stopMenuItem];
    freshWindows=@[windowA,windowB]; [coordinator stopSharingClicked:stopItem];
    check(@"click_rejects_ambiguous_current_windows_even_if_cached_tree_survives",presses==0);
    coordinator.stopAvailable=YES; freshWindows=@[windowB]; [coordinator stopSharingClicked:stopItem];
    check(@"click_rejects_replaced_current_window",presses==0);
    coordinator.stopAvailable=YES; freshWindows=@[windowA]; [coordinator stopSharingClicked:stopItem];
    check(@"current_user_menu_action_presses_exact_stop_once",presses==1);
    coordinator.stopAvailable=YES;
    NSDictionary *beforeToken=[coordinator currentStopToken];
    AXNotification(nullptr,nullptr,kAXWindowCreatedNotification,(__bridge void *)coordinator);
    check(@"window_event_invalidates_token_before_debounce",![coordinator currentStopToken]&&!SameStopToken(beforeToken,[coordinator currentStopToken]));
    NSWindow *trackingWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(-20000,-20000,200,100) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    CRDSessionStopButton *trackingButton=[[CRDSessionStopButton alloc] initWithFrame:NSMakeRect(10,10,120,36)];
    CRDTrackingFixtureCell *trackingCell=[[CRDTrackingFixtureCell alloc] initTextCell:@"Fixture"];
    CRDTrackingRecorder *recorder=[CRDTrackingRecorder new];
    trackingButton.cell=trackingCell; trackingButton.sessionToken=tokenA; trackingButton.target=recorder; trackingButton.action=@selector(clicked:);
    [trackingWindow.contentView addSubview:trackingButton];
    trackingCell.duringTracking=^{ trackingButton.sessionToken=tokenB; };
    NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(40,25) modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:trackingWindow.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    [trackingButton mouseDown:down];
    check(@"native_tracking_reproduces_mutable_token_bug_without_showing_window",SameStopToken(recorder.legacyReceived,tokenB)&&!trackingWindow.visible);
    check(@"native_tracking_pins_mousedown_token_and_clears_after_action",SameStopToken(recorder.received,tokenA)&&trackingButton.gestureToken==nil&&![trackingButton actionToken]);
    // The refused down returns immediately, but AppKit later delivers its release to the
    // button. A reset click count cannot turn that same continuing gesture into Stop.
    trackingButton.stopGestureGate=[CRDStopGestureGate new];
    [trackingButton.stopGestureGate blockFrom:100];
    trackingCell.duringTracking=^{}; recorder.received=nil;
    auto inlineEvent=[&](NSEventType type,NSTimeInterval timestamp) {
        return mouseAt(type,down.locationInWindow,1,timestamp,trackingWindow.windowNumber);
    };
    [trackingButton mouseDown:inlineEvent(NSEventTypeLeftMouseDown,100.1)];
    [trackingButton mouseUp:inlineEvent(NSEventTypeLeftMouseUp,102)];
    NSTimeInterval afterDelayedUp=trackingButton.stopGestureGate.blockedThrough;
    [trackingButton mouseDown:inlineEvent(NSEventTypeLeftMouseDown,102.01)];
    [trackingButton mouseUp:inlineEvent(NSEventTypeLeftMouseUp,102.05)];
    BOOL continuationRejected=recorder.received==nil;
    [trackingButton mouseDown:inlineEvent(NSEventTypeLeftMouseDown,102.05+NSEvent.doubleClickInterval+.01)];
    check(@"inline_rejected_release_blocks_reset_click_count_then_accepts_deliberate_click",
        afterDelayedUp>=102+NSEvent.doubleClickInterval&&continuationRejected&&SameStopToken(recorder.received,tokenB)&&!trackingButton.trackingGesture);
    measurements[@"inlineBlockedThroughAfterDelayedUp"]=@(afterDelayedUp);
    measurements[@"inlineRequiredAfterDelayedUp"]=@(102+NSEvent.doubleClickInterval);
    trackingButton.stopGestureGate=nil;
    coordinator.stopAvailable=YES; trackingButton.sessionToken=[coordinator currentStopToken]; trackingButton.target=coordinator; trackingButton.action=@selector(stopSharingClicked:);
    trackingCell.duringTracking=^{
        coordinator.windowElement=windowB; coordinator.windowGeneration++; coordinator.stopAvailable=YES;
        freshWindows=@[windowB]; trackingButton.sessionToken=[coordinator currentStopToken];
    };
    [trackingButton mouseDown:down];
    check(@"native_mouseup_on_replaced_target_sends_no_press",presses==1);
    trackingButton.stopGestureGate=[CRDStopGestureGate new]; trackingButton.stopGestureGate.blockedThrough=down.timestamp+NSEvent.doubleClickInterval;
    trackingCell.duringTracking=^{};
    [trackingButton mouseDown:down];
    check(@"native_reveal_continuation_sends_no_press",presses==1&&trackingButton.gestureToken==nil);
    NSTimeInterval deliberateTime=trackingButton.stopGestureGate.blockedThrough+.01;
    NSEvent *deliberate=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:down.locationInWindow modifierFlags:0 timestamp:deliberateTime windowNumber:trackingWindow.windowNumber context:nil eventNumber:3 clickCount:1 pressure:1];
    [trackingButton mouseDown:deliberate];
    check(@"native_separate_reveal_click_presses_current_target_once",presses==2);
    CRDContextMenuTracking *fallbackTracking=[CRDContextMenuTracking new];
    fallbackTracking.active=YES; fallbackTracking.stopGestureGate=[CRDStopGestureGate new];
    fallbackTracking.stopGestureGate.blockedThrough=1+NSEvent.doubleClickInterval;
    activeContextMenu=fallbackTracking;
    NSMenuItem *fallbackStop=[coordinator stopMenuItem];
    [coordinator stopSharingClicked:fallbackStop];
    check(@"fallback_menu_cannot_select_on_triggering_mouseup",presses==2&&[fallbackTracking handleLocalEvent:gateEvent(NSEventTypeLeftMouseUp,1,2)]==nil);
    BOOL continuationBlocked=[fallbackTracking handleLocalEvent:gateEvent(NSEventTypeLeftMouseDown,1.01,1)]==nil;
    [coordinator stopSharingClicked:fallbackStop];
    check(@"fallback_menu_continuation_cannot_press",continuationBlocked&&presses==2&&!fallbackTracking.stopSelectionArmed);
    [fallbackTracking handleLocalEvent:gateEvent(NSEventTypeLeftMouseDown,fallbackTracking.stopGestureGate.blockedThrough+.01,1)];
    [coordinator stopSharingClicked:fallbackStop];
    check(@"fallback_menu_separate_selection_presses_current_target_once",presses==3&&fallbackTracking.stopSelectionArmed);
    fallbackTracking.stopSelectionArmed=NO;
    NSEvent *enter=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:2 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:36];
    [fallbackTracking handleLocalEvent:enter]; [coordinator stopSharingClicked:fallbackStop];
    check(@"fallback_menu_explicit_keyboard_selection_remains_available",presses==4);
    activeContextMenu=nil;
    trackingCell.duringTracking=nil;
    [coordinator releaseOriginal];
    __block NSUInteger setups=0;
    fixtureObserverSetup=^AXError{ return ++setups==1?kAXErrorCannotComplete:kAXErrorSuccess; };
    [coordinator bindOriginal:(id)fakeApp]; RunFor(.4);
    check(@"transient_observer_failure_recovers_once_without_polling",coordinator.observerReady&&setups==2);
    NSUInteger setupCount=setups; RunFor(.3);
    check(@"observer_success_cancels_retry_work",setups==setupCount);
    [coordinator releaseOriginal]; setups=0;
    fixtureObserverSetup=^AXError{ setups++; return kAXErrorCannotComplete; };
    [coordinator bindOriginal:(id)fakeApp]; RunFor(2.0); setupCount=setups; RunFor(.3);
    check(@"observer_retries_are_bounded",setups==4&&setupCount==4&&!coordinator.observerReady);
    SetOriginalHidden(coordinator,YES);
    fixtureJournalWrite=^BOOL(NSDictionary *intent){ return NO; };
    check(@"restored_visibility_does_not_discard_failed_journal_completion",!SetOriginalHidden(coordinator,NO)&&!hidden&&coordinator.ownsHidden&&coordinator.restorationBlocked);
    fixtureJournalWrite=nil;
    check(@"journal_completion_can_be_retried_without_another_ax_write",SetOriginalHidden(coordinator,NO)&&!coordinator.ownsHidden);
    SetOriginalHidden(coordinator,YES); writeSucceeds=NO;
    [coordinator cleanExit]; coordinator.stopping=NO;
    WriteRuntimeStatus(@"fixture-unconfirmed-restore",nil);
    NSData *failedExitData=[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"runtime-status.json"]];
    NSDictionary *failedExit=[NSJSONSerialization JSONObjectWithData:failedExitData options:0 error:nil];
    check(@"failed_exit_keeps_pending_journal_and_reports_not_ready",coordinator.ownsHidden&&[coordinator.restoreIntent[@"pending"] isEqual:@YES]&&[failedExit[@"restorationPending"] isEqual:@YES]&&[failedExit[@"agentReady"] isEqual:@NO]&&failedExit[@"originalHidden"]==NSNull.null);
    writeSucceeds=YES; SetOriginalHidden(coordinator,NO); SetOriginalHidden(coordinator,YES);
    [coordinator cleanExit];
    check(@"normal_exit_restores_then_clears_journal_and_target",!hidden&&!coordinator.ownsHidden&&coordinator.original==nil&&[coordinator.restoreIntent[@"pending"] isEqual:@NO]);
    coordinator.stopping=NO;
    __block NSUInteger acknowledged=0,refreshes=0;
    fixtureRefreshAcknowledged=^{ acknowledged++; };
    fixtureReconcile=^(CRDOverlayCoordinator *owner){ refreshes++; owner.reconcileCount++; owner.trusted=CurrentTrust(); WriteRuntimeStatus(@"fixture-refresh",nil); };
    fixtureTrusted=@NO; coordinator.trusted=YES; coordinator.stopAvailable=YES;
    NSMenu *permissionMenu=[NSMenu new]; [coordinator menuNeedsUpdate:permissionMenu];
    check(@"menu_rechecks_trust_without_a_prompt_and_disarms_stop",!coordinator.trusted&&!coordinator.stopAvailable&&[permissionMenu.itemArray.firstObject.title isEqual:L(PermissionRequiredKey(UsesDeviceControlName()))]);
    check(@"permission_line_follows_macos_27_pane_name",[PermissionRequiredKey(YES) isEqual:@"기기 제어 권한 필요"]&&[PermissionRequiredKey(NO) isEqual:@"손쉬운 사용 권한 필요"]&&
        LocalizationCatalog()[@"en"][PermissionRequiredKey(YES)]!=nil&&LocalizationCatalog()[@"en"][PermissionRequiredKey(NO)]!=nil&&
        UsesDeviceControlName()==(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27));
    RunFor(.12);
    fixtureTrusted=@YES; refreshes=0;
    [coordinator requestReconcile]; [coordinator requestReconcile]; [coordinator requestReconcile]; RunFor(.12);
    NSDictionary *refreshedStatus=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"runtime-status.json"]] options:0 error:nil];
    check(@"explicit_status_requests_coalesce_and_acknowledge_after_status_write",refreshes==1&&acknowledged==1&&[refreshedStatus[@"accessibility"] isEqual:@YES]&&!coordinator.refreshRequested);
    RunFor(.12);
    check(@"trust_refresh_has_no_idle_polling",refreshes==1&&acknowledged==1);
    coordinator.stopping=YES; [coordinator requestReconcile]; RunFor(.12);
    check(@"stopped_helper_ignores_refresh_requests",refreshes==1&&acknowledged==1&&!coordinator.refreshRequested);
    coordinator.stopping=NO; fixtureTrusted=nil; fixtureReconcile=nil; fixtureRefreshAcknowledged=nil;
    auto resetGeometry=[&](NSString *placement) {
        NSMutableDictionary *config=[CRDDefaults() mutableCopy]; config[@"placement"]=placement;
        CRDWriteConfig(config,nil); CRDReload(); ApplyOverlay(YES);
        coordinator.stopping=NO; previewMode=NO; overlay.shown=YES;
    };
    for(NSString *placement in @[@"center",@"top",@"bottom"]) {
        resetGeometry(placement);
        NSString *signature=FileSignature();
        [coordinator cleanExit];
        check(@"shutdown_without_user_geometry_preserves_placement_and_file",[FileSignature() isEqual:signature]&&[CRDReadConfig(nil)[@"placement"] isEqual:placement]);
    }
    resetGeometry(@"center");
    [overlay.controller.window setFrameOrigin:NSMakePoint(100,100)]; SaveGeometry(overlay); RunFor(.2);
    check(@"system_move_never_marks_geometry_dirty",!geometryDirty&&[CRDReadConfig(nil)[@"placement"] isEqual:@"center"]);
    BeginUserGeometry(overlay.controller.window);
    [overlay.controller.window setFrameOrigin:NSMakePoint(NSMinX(visible)+80,NSMinY(visible)+90)]; SaveGeometry(overlay); EndUserGeometry();
    [overlay.controller.window setFrameOrigin:NSMakePoint(NSMinX(visible)+300,NSMinY(visible)+300)];
    [coordinator cleanExit];
    NSDictionary *userGeometry=CRDReadConfig(nil);
    check(@"shutdown_flushes_unsaved_user_frame_not_later_system_frame",[userGeometry[@"placement"] isEqual:@"custom"]&&fabs([userGeometry[@"x"] doubleValue]-80)<.1&&!geometryDirty);
    coordinator.stopping=NO; overlay.shown=YES;
    NSString *savedSignature=FileSignature(); [coordinator cleanExit];
    check(@"already_saved_geometry_is_not_written_again_on_shutdown",[FileSignature() isEqual:savedSignature]);
    resetGeometry(@"center");
    BeginUserGeometry(overlay.controller.window); [overlay.controller.window setFrameOrigin:NSMakePoint(120,120)]; SaveGeometry(overlay); EndUserGeometry();
    ApplyOverlay(YES); RunFor(.2);
    check(@"screen_reposition_invalidates_pending_user_geometry",!geometryDirty&&[CRDReadConfig(nil)[@"placement"] isEqual:@"center"]);
    BeginUserGeometry(overlay.controller.window); [overlay.controller.window setFrameOrigin:NSMakePoint(130,130)]; SaveGeometry(overlay); EndUserGeometry();
    NSMutableDictionary *externalGeometry=[CRDReadConfig(nil) mutableCopy]; externalGeometry[@"placement"]=@"bottom"; externalGeometry[@"width"]=@515;
    CRDWriteConfig(externalGeometry,nil); CRDReload(); RunFor(.2);
    check(@"external_configuration_wins_over_pending_geometry",!geometryDirty&&[CRDReadConfig(nil)[@"placement"] isEqual:@"bottom"]&&[CRDReadConfig(nil)[@"width"] isEqual:@515]);
    // A scratch-only competing writer holds the lock for 600 ms. The delayed unlock bounds
    // the fixture even if a lock attempt blocks unexpectedly.
    auto holdConfigLock=[&]() -> dispatch_semaphore_t {
        int fd=open([CRDConfigPath() stringByAppendingPathExtension:@"lock"].fileSystemRepresentation,O_RDWR|O_CLOEXEC);
        NSCAssert(fd>=0&&flock(fd,LOCK_EX)==0,@"Fixture lock must be held");
        dispatch_semaphore_t released=dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
            flock(fd,LOCK_UN); close(fd); dispatch_semaphore_signal(released);
        });
        return released;
    };
    auto markUserGeometry=[&] {
        BeginUserGeometry(overlay.controller.window);
        [overlay.controller.window setFrameOrigin:NSMakePoint(NSMinX(visible)+80,NSMinY(visible)+90)];
        SaveGeometry(overlay); EndUserGeometry();
    };
    resetGeometry(@"center"); RunFor(.2); markUserGeometry();
    dispatch_semaphore_t saveLock=holdConfigLock();
    NSTimeInterval saveStart=NSProcessInfo.processInfo.systemUptime; PersistGeometry(overlay);
    NSTimeInterval saveDelay=NSProcessInfo.processInfo.systemUptime-saveStart;
    NSRect capturedFrame=geometryFrame;
    [overlay.controller.window setContentSize:NSMakeSize(NSWidth(capturedFrame)+30,NSHeight(capturedFrame)+20)];
    RunFor(.3); // Let the original debounce and contended retries run before the lock releases.
    BOOL retainedWhileBusy=geometryDirty&&[CRDReadConfig(nil)[@"placement"] isEqual:@"center"];
    check(@"busy_user_save_survives_system_resize_without_saving_the_system_frame",retainedWhileBusy&&NSEqualRects(overlay.controller.window.frame,capturedFrame));
    dispatch_semaphore_wait(saveLock,DISPATCH_TIME_FOREVER); RunFor(.25);
    check(@"busy_geometry_save_returns_without_waiting_and_retries_captured_frame",saveDelay<.2&&retainedWhileBusy&&!geometryDirty&&
        [CRDReadConfig(nil)[@"placement"] isEqual:@"custom"]&&[CRDReadConfig(nil)[@"x"] isEqual:@80]);
    measurements[@"busyGeometrySaveSeconds"]=@(saveDelay);
    NSString *afterRetrySignature=FileSignature(); NSUInteger afterRetryReads=configReadCount; RunFor(.35);
    check(@"geometry_retry_stops_when_saved",[FileSignature() isEqual:afterRetrySignature]&&configReadCount==afterRetryReads);
    resetGeometry(@"center"); RunFor(.2); markUserGeometry();
    coordinator.original=(id)fakeApp; coordinator.originalBirth=fixtureBirth;
    coordinator.applicationElement=@"fixture-application"; coordinator.trusted=YES;
    SetOriginalHidden(coordinator,YES);
    AXError (^savedAXWrite)(id,BOOL)=fixtureAXWrite;
    __block BOOL restoredWithLockHeld=NO,restoredBeforePersistence=NO;
    __block NSTimeInterval restoreAt=0;
    fixtureAXWrite=^AXError(id element,BOOL value){
        if(!value) {
            restoreAt=NSProcessInfo.processInfo.systemUptime;
            restoredBeforePersistence=geometryDirty&&[CRDReadConfig(nil)[@"placement"] isEqual:@"center"];
            int probe=open([CRDConfigPath() stringByAppendingPathExtension:@"lock"].fileSystemRepresentation,O_RDWR|O_CLOEXEC);
            restoredWithLockHeld=probe>=0&&flock(probe,LOCK_EX|LOCK_NB)!=0&&errno==EWOULDBLOCK;
            if(probe>=0) close(probe);
        }
        return savedAXWrite(element,value);
    };
    dispatch_semaphore_t exitLock=holdConfigLock(); NSString *beforeExit=FileSignature();
    NSTimeInterval exitStart=NSProcessInfo.processInfo.systemUptime; [coordinator cleanExit];
    NSTimeInterval exitDelay=NSProcessInfo.processInfo.systemUptime-exitStart;
    BOOL stoppedBeforeUnlock=exitDelay<.2&&!hidden&&!coordinator.ownsHidden&&restoredWithLockHeld;
    dispatch_semaphore_wait(exitLock,DISPATCH_TIME_FOREVER); RunFor(.25);
    check(@"shutdown_restores_before_optional_persistence_even_with_config_lock_held",restoredBeforePersistence&&restoredWithLockHeld&&restoreAt-exitStart<.2);
    check(@"shutdown_lock_attempt_is_bounded_and_leaves_no_geometry_retry",stoppedBeforeUnlock&&!geometryDirty&&[FileSignature() isEqual:beforeExit]);
    measurements[@"shutdownRestoreSeconds"]=@(restoreAt-exitStart); measurements[@"shutdownWithBusyLockSeconds"]=@(exitDelay);
    fixtureAXWrite=savedAXWrite;
    previewMode=YES; overlay.shown=NO; coordinator.stopping=NO;
    fixtureAXRead=nil; fixtureAXWrite=nil; fixtureAXPress=nil; fixtureObserverSetup=nil; fixtureApplication=nil; fixtureBirth=nil;
    // Near every edge and corner, and for a window partly off screen, the capsule moves inside the
    // visible frame at whole points with its size unchanged. In the middle it stays centered. A
    // smaller screen reduces the temporary layout, keeping the Stop target where space permits.
    BOOL fits=YES,edgesInside=YES; NSRect bounds=NSMakeRect(0,0,1000,800); NSSize capsuleSize=CapsuleLayout(NSMakeSize(88,30),12).size;
    for(NSValue *edge in @[[NSValue valueWithPoint:NSMakePoint(497.5,795)],[NSValue valueWithPoint:NSMakePoint(497.5,0)],[NSValue valueWithPoint:NSMakePoint(0,400)],[NSValue valueWithPoint:NSMakePoint(995,400)],
        [NSValue valueWithPoint:NSMakePoint(0,0)],[NSValue valueWithPoint:NSMakePoint(995,795)],[NSValue valueWithPoint:NSMakePoint(0,795)],[NSValue valueWithPoint:NSMakePoint(995,0)],[NSValue valueWithPoint:NSMakePoint(-20,810)]]) {
        NSRect frame=CapsuleFrame(NSMakeRect(edge.pointValue.x,edge.pointValue.y,5,5),bounds,capsuleSize,&fits);
        edgesInside=edgesInside&&fits&&NSContainsRect(bounds,frame)&&NSEqualSizes(frame.size,capsuleSize)&&frame.origin.x==round(frame.origin.x)&&frame.origin.y==round(frame.origin.y);
    }
    check(@"capsule_near_any_edge_moves_inside_the_visible_frame",edgesInside);
    NSRect centered=CapsuleFrame(NSMakeRect(497.5,397.5,5,5),bounds,capsuleSize,&fits);
    check(@"center_capsule_fits",fits&&fabs(NSMidX(centered)-500)<=.51&&fabs(NSMidY(centered)-400)<=.51);
    CRDCapsuleLayout fitted=CapsuleLayoutOnScreen(NSMakeSize(280,30),128,NSMakeSize(320,200));
    NSRect fittedFrame=CapsuleFrame(NSMakeRect(-8,180,17,17),NSMakeRect(0,0,320,200),fitted.size,&fits);
    check(@"large_capsule_fits_small_screen_and_keeps_stop_target",fits&&NSContainsRect(NSMakeRect(0,0,320,200),fittedFrame)&&fitted.press.size.width>=120&&fitted.press.size.height>=36);
    CRDCapsuleLayout tiny=CapsuleLayoutOnScreen(NSMakeSize(88,30),17,NSMakeSize(100,30));
    check(@"small_screen_capsule_keeps_a_fold_dot_outside_stop_margin",NSWidth(tiny.dot)>0&&NSHeight(tiny.dot)>0&&
        NSMinX(tiny.dot)<NSMinX(tiny.press)-CRDStopShrinkMargin&&tiny.size.width<=100&&tiny.size.height<=30);
    BOOL invisible=coordinator.statusItem==nil;
    for(NSWindow *window in NSApp.windows) invisible=invisible&&!window.visible;
    check(@"self_test_never_orders_any_fixture_window_or_status_item",invisible);
    NSString *snapshotDirectory=NSProcessInfo.processInfo.environment[@"CRD_OVERLAY_SNAPSHOTS"];
    if(snapshotDirectory.isAbsolutePath&&[NSFileManager.defaultManager createDirectoryAtPath:snapshotDirectory withIntermediateDirectories:YES attributes:nil error:nil]) {
        // A small dot window: dot layout, 42 x 42, radius 21, dot 12, auto-shrink off.
        NSMutableDictionary *smallDot=[CRDDefaults() mutableCopy];
        [smallDot addEntriesFromDictionary:@{@"mode":@"custom",@"layout":@"dot",@"shape":@"custom",@"width":@42,@"height":@42,@"radius":@21,@"dotDiameter":@12,
            @"showText":@NO,@"showStopButton":@NO,@"stopRevealSeconds":@0,@"placement":@"center"}];
        [[NSJSONSerialization dataWithJSONObject:@{@"schema":@1,@"presets":@[@{@"id":@"small-dot",@"name":@"Small dot",@"values":@{@"layout":@"dot",@"width":@42,@"height":@42,@"dotDiameter":@12,@"stopRevealSeconds":@0}},
            @{@"id":@"bar",@"name":@"Bar",@"values":@{@"layout":@"row",@"width":@440,@"height":@48}}]} options:0 error:nil] writeToFile:PresetsPath() atomically:YES];
        // Every built-in shape with its Stop, the Stop pill's states, and the capsule a double-click
        // opens on each shape, in both Stop styles, both languages and both looks. Stop is enabled
        // only for the drawing.
        for(NSString *style in ChoiceIDs(@"stopStyle")) for(NSString *language in @[@"ko",@"en"]) for(NSString *look in @[@"light",@"dark"]) {
            fixtureLanguage=language; fixtureReduceMotion=@YES;
            NSString *tag=[NSString stringWithFormat:@"%@_%@_%@",style,look,language];
            smallDot[@"appearance"]=look; smallDot[@"stopStyle"]=style; apply(smallDot);
            WriteViewSnapshot(overlay.customView,snapshotDirectory,[@"helper_dot_collapsed_" stringByAppendingString:tag]);
            for(NSDictionary *shape in Schema()[@"shapes"]) {
                NSMutableDictionary *values=[smallDot mutableCopy];
                if(![shape[@"id"] isEqual:@"custom"]) { values=[CRDDefaults() mutableCopy]; [values addEntriesFromDictionary:shape[@"values"]]; values[@"shape"]=shape[@"id"]; }
                values[@"mode"]=@"custom"; values[@"appearance"]=look; values[@"stopStyle"]=style; values[@"placement"]=@"center"; values[@"stopRevealSeconds"]=@0; apply(values);
                overlay.stop.enabled=YES;
                WriteViewSnapshot(overlay.customView,snapshotDirectory,[NSString stringWithFormat:@"helper_shape_%@_%@",shape[@"id"],tag]);
                if([shape[@"id"] isEqual:@"bar"]) {
                    WriteViewSnapshot(overlay.stop,snapshotDirectory,[@"helper_stop_enabled_" stringByAppendingString:tag]);
                    overlay.stop.cell.highlighted=YES; WriteViewSnapshot(overlay.stop,snapshotDirectory,[@"helper_stop_pressed_" stringByAppendingString:tag]); overlay.stop.cell.highlighted=NO;
                    overlay.stop.enabled=NO; WriteViewSnapshot(overlay.stop,snapshotDirectory,[@"helper_stop_disabled_" stringByAppendingString:tag]);
                }
                overlay.stop.enabled=NO;
                [coordinator presentStopRevealWithToken:tokenA]; RunFor(.05);
                coordinator.revealStopButton.enabled=YES;
                WriteViewSnapshot(coordinator.stopRevealPanel.contentView,snapshotDirectory,[NSString stringWithFormat:@"helper_capsule_%@_%@",shape[@"id"],tag]);
                coordinator.revealStopButton.enabled=NO; [coordinator closeStopReveal:@"snapshot"];
            }
            fixtureReduceMotion=nil;
        }
        fixtureLanguage=nil;
        smallDot[@"draggable"]=@NO; smallDot[@"stopStyle"]=@"red"; apply(smallDot);
        for(NSString *language in @[@"ko",@"en"]) {
            fixtureLanguage=language; NSMutableString *text=[NSMutableString string];
            [text appendString:@"# Right-click menu of the custom window (position locked, preset Small dot applied)\n"]; AppendMenuText([coordinator windowContextMenu],text,@"");
            NSMenu *statusSnapshot=[NSMenu new]; [coordinator menuNeedsUpdate:statusSnapshot];
            [text appendString:@"\n# Menu bar menu\n"]; AppendMenuText(statusSnapshot,text,@"");
            [text appendFormat:@"\n# Status dot tooltip\n%@\n",overlay.dot.toolTip];
            [text writeToFile:[snapshotDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"helper_menus_%@.txt",language]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        fixtureLanguage=nil; [NSFileManager.defaultManager removeItemAtPath:PresetsPath() error:nil];
    }
    fixtureNextTrackingEvent=nil;
    [overlay.controller.window orderOut:nil]; StopWatchers(); [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    BOOL passed=YES; for(NSDictionary *item in checks) if(![item[@"passed"] boolValue]) passed=NO;
    NSDictionary *report=@{@"passed":@(passed),@"checks":checks,@"measurements":measurements,@"boundary":@"Standalone renderer only. No Google library load, original host access, AX writes, or service changes.",@"schemaSHA256":@(kCRDSettingsSchemaSHA256),@"localizationSHA256":@(kCRDLocalizationSHA256),@"language":LocalizationLanguage()};
    puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding].UTF8String);
    return passed?0:1;
}

#pragma mark - Entry point
// Command line: --crd-overlay-self-test, --crd-permission-status [--prompt], or the agent itself
// with optional --crd-restore-only and --crd-host-app <path>. Restore-only mode unhides a host
// left hidden by an earlier run and exits; the agent mode runs the overlay until terminated.
int main(int argc,char **argv) {
    @autoreleasepool {
        auto permissionOptions=[](int count,const char *const *arguments)->NSDictionary * {
            if((count==2||count==3)&&strcmp(arguments[1],"--crd-permission-status")==0) {
                if(count==2) return @{};
                if(strcmp(arguments[2],"--prompt")==0) return @{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
            }
            return nil;
        };
        if(argc==2&&strcmp(argv[1],"--crd-overlay-self-test")==0) return OverlaySelfTest(permissionOptions);
        NSDictionary *options=permissionOptions(argc,argv);
        if(options) {
            // The OS request is asynchronous; report current trust and keep the probe's normal exit/cleanup contract.
            BOOL trusted=options.count?AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)!=0:AXIsProcessTrusted()!=0;
            NSDictionary *status=@{@"accessibility":@(trusted),@"bundleId":NSBundle.mainBundle.bundleIdentifier?:@"",@"pid":@(getpid())};
            puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding].UTF8String); return 0;
        }
        NSString *hostApp=nil; BOOL restorationOnly=NO;
        for(int i=1;i<argc;i++) {
            if(strcmp(argv[i],"--crd-host-app")==0&&i+1<argc) hostApp=@(argv[++i]);
            else if(strcmp(argv[i],"--crd-restore-only")==0&&!restorationOnly) restorationOnly=YES;
            else { fprintf(stderr,"Usage: OverlayAgent [--crd-restore-only] [--crd-host-app /original/ChromeRemoteDesktopHost.app] | --crd-permission-status [--prompt] | --crd-overlay-self-test\n"); return 2; }
        }
        if(!hostApp) {
            NSURL *resource=[NSBundle.mainBundle URLForResource:@"original-host" withExtension:@"json"];
            if(resource) {
                NSData *data=[NSData dataWithContentsOfURL:resource];
                id object=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
                id path=[object isKindOfClass:NSDictionary.class]?object[@"path"]:nil;
                if(![path isKindOfClass:NSString.class]||![path length]) { fprintf(stderr,"Invalid original-host.json path\n"); return 2; }
                hostApp=path;
            }
        }
        if(!hostApp) hostApp=@"/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app";
        if(!hostApp.isAbsolutePath||![hostApp.pathExtension isEqual:@"app"]) { fprintf(stderr,"An absolute original .app path is required.\n"); return 2; }
        coordinator=[CRDOverlayCoordinator new]; coordinator.hostAppPath=hostApp.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        coordinator.hostExecutablePath=[coordinator.hostAppPath stringByAppendingPathComponent:@"Contents/MacOS/remoting_me2me_host"];
        if(restorationOnly) {
            // The controller runs this retained signed executable in a bounded, independent
            // per-user job. Never load settings, show UI, prompt, or hide a new target.
            [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            coordinator.restorationOnly=YES; coordinator.trusted=AXIsProcessTrusted()!=0;
            [coordinator recoverPreviousHide];
            BOOL restored=!coordinator.ownsHidden&&!coordinator.restorationBlocked&&[coordinator.restoreIntent[@"pending"] isEqual:@NO];
            NSDictionary *result=@{@"restored":@(restored),@"pid":@(getpid()),@"bundleId":NSBundle.mainBundle.bundleIdentifier?:@""};
            puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding].UTF8String);
            return restored?0:1;
        }
        BOOL exists=[NSFileManager.defaultManager fileExistsAtPath:CRDConfigPath()];
        NSData *initial=ReadData(nil); currentConfig=initial?ParseData(initial,nil):(exists?nil:CRDDefaults());
        if(!currentConfig) { NSMutableDictionary *fallback=[CRDDefaults() mutableCopy]; fallback[@"mode"]=@"original"; currentConfig=fallback; }
        lastConfigData=initial; lastObservedSignature=FileSignature(); lastConfigReloadDate=NSDate.date;
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; NSApp.delegate=coordinator;
        [NSApp run]; return 0;
    }
}
