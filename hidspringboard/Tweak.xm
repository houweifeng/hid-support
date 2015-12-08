/**
 * Click injection
 *
 * swiped from and update of Lance Fetter's MouseSupport and Jay Freeman's Veency
 *
 * next steps:
 *   handle device rotation
 *   show mouse cursor - decide on keep-alive
 */
  
#include <dlfcn.h>
#include <objc/runtime.h>
#include <mach/mach_port.h>
#include <mach/mach_init.h>
#include <sys/sysctl.h>

#include <mach/mach_time.h>
#include <UIKit/UIKit.h>

#include <IOKit/hid/IOHIDEvent.h>
#include <IOKit/hid/IOHIDEventSystemClient.h>
#include "RocketBootstrap.h"

// kenytm
#import <GraphicsServices/GSEvent.h>

#include "../hid-support-internal.h"

// MSHookSymbol is not available in the autogenerated substrate.h
template <typename Type_>
static inline void MyMSHookSymbol(Type_ *&value, const char *name, void *handle = RTLD_DEFAULT) {
    value = reinterpret_cast<Type_ *>(dlsym(handle, name));
}

extern "C" uint64_t   GSCurrentEventTimestamp(void);
extern "C" GSEventRef _GSCreateSyntheticKeyEvent(UniChar key, BOOL up, BOOL repeating);

// used interface from CAWindowServer & CAWindowServerDisplay
@interface CAWindowServer : NSObject
+ (CAWindowServer *)serverIfRunning;
- (NSArray *)displays;
@end
@interface CAWindowServerDisplay : NSObject
- (unsigned int)clientPortAtPosition:(struct CGPoint)position;
- (int) contextIdAtPosition:(CGPoint)position;
- (mach_port_t) taskPortOfContextId:(int)context;
@end

@interface BKHIDClientConnectionManager : NSObject
- (IOHIDEventSystemConnectionRef) clientForTaskPort:(mach_port_t)port;
@end

@interface BKAccessibility : NSObject
+ (BKHIDClientConnectionManager *) _eventRoutingClientConnectionManager;
@end

#if !defined(__IPHONE_3_2) || __IPHONE_3_2 > __IPHONE_OS_VERSION_MAX_ALLOWED
typedef enum {
    UIUserInterfaceIdiomPhone,           // iPhone and iPod touch style UI
    UIUserInterfaceIdiomPad,             // iPad style UI
} UIUserInterfaceIdiom;
@interface UIDevice (privateAPI)
- (BOOL) userInterfaceIdiom;
@end
#endif

@interface UIScreen (fourZeroAndLater)
@property(nonatomic,readonly) CGFloat scale;
@end

@interface SpringBoard : NSObject
// unlock && undim on 3.0 & 3.1 - 6.x
-(void)resetIdleTimerAndUndim:(BOOL)fp8; 
// iOS 7+
-(void)resetIdleTimerAndUndim;
// frontmost app port on 6.0+
-(unsigned)_frontmostApplicationPort;
@end

@interface SBAwayController : NSObject
+ (id)sharedAwayController;
- (BOOL)undimsDisplay;
- (id)awayView;
- (void)lock;
- (void)_unlockWithSound:(BOOL)fp8;
- (void)unlockWithSound:(BOOL)fp8;
- (void)unlockWithSound:(BOOL)fp8 alertDisplay:(id)fp12;
- (void)loadPasscode;
- (id)devicePasscode;
- (BOOL)isPasswordProtected;
- (void)activationChanged:(id)fp8;
- (BOOL)isDeviceLockedOrBlocked;
- (void)setDeviceLocked:(BOOL)fp8;
- (void)applicationRequestedDeviceUnlock;
- (void)cancelApplicationRequestedDeviceLockEntry;
- (BOOL)isBlocked;
- (BOOL)isPermanentlyBlocked:(double *)fp8;
- (BOOL)isLocked;
- (void)attemptUnlock;
- (BOOL)isAttemptingUnlock;
- (BOOL)attemptDeviceUnlockWithPassword:(id)fp8 alertDisplay:(id)fp12;
- (void)cancelDimTimer;
- (void)restartDimTimer:(float)fp8;
- (id)dimTimer;
- (BOOL)isDimmed;
- (void)finishedDimmingScreen;
- (void)dimScreen:(BOOL)fp8;
- (void)undimScreen;
- (void)userEventOccurred;
- (void)activate;
- (void)deactivate;
@end

// 3.2+
@interface SBBrightnessController : NSObject
+ (id)sharedBrightnessController;
- (void)adjustBacklightLevel:(BOOL)fp8;
@end

// from iOS 7+
@interface SBLockScreenManager
+(id)sharedInstance;
-(void)unlockUIFromSource:(int)source withOptions:(id)options;
@property(readonly, assign) BOOL isUILocked;
@end

@interface SBMediaController : NSObject 
+(SBMediaController*) sharedInstance;
-(void)togglePlayPause;
-(BOOL)isPlaying;
-(void)changeTrack:(int)change;
@end

// from iOS 7+
@interface SBUserAgent
+(id)sharedUserAgent;
-(void)undimScreen;
@end

@interface VolumeControl : NSObject 
+ (id)sharedVolumeControl;
- (void)toggleMute;
@end


@interface UIKeyboardImpl : NSObject
+(UIKeyboardImpl*)sharedInstance;
-(void)addInputString:(NSString*)string;
@end

// types for touches
typedef enum __GSHandInfoType2 {
        kGSHandInfoType2TouchDown    = 1,    // first down
        kGSHandInfoType2TouchDragged = 2,    // drag
        kGSHandInfoType2TouchChange  = 5,    // nr touches change
        kGSHandInfoType2TouchFinal   = 6,    // final up
} GSHandInfoType2;

static CFDataRef myCallBack(CFMessagePortRef local, SInt32 msgid, CFDataRef cfData, void *info);

// globals

// GS functions
static GSEventRef  (*$GSEventCreateKeyEvent)(int, CGPoint, CFStringRef, CFStringRef, uint32_t, UniChar, short, short);
static GSEventRef  (*$GSCreateSyntheticKeyEvent)(UniChar, BOOL, BOOL);
static void        (*$GSEventSetKeyCode)(GSEventRef event, uint16_t keyCode);
static CGSize      (*$GSMainScreenSize)(void);
static float       (*$GSMainScreenScaleFactor)(void);
static float       (*$GSMainScreenOrientation)(void);
static CFStringRef (*$GSEventCopyCharacters)(GSEventRef event);
static GSEventType (*$GSEventGetType)(GSEventRef event);

// IOHID functions
static void (*$IOHIDEventSetSenderID)(IOHIDEventRef event, uint64_t senderID) = NULL;

// GSEvent being sent
static uint8_t  touchEvent[sizeof(GSEventRecord) + sizeof(GSHandInfo) + sizeof(GSPathInfo)];

// Screen dimension - fallback for very old iOS versions
static float screen_width = 320;
static float screen_height = 480;
static float retina_factor = 1.0f;
static float screen_orientation = 0.0f;

// Mouse area (might be rotated)
static float mouse_max_x = 0;
static float mouse_max_y = 0;

// Mouse position
static float mouse_x = 0;
static float mouse_y = 0;

// iOS version level
static int Level_;  // 0 = < 3.0, 1 = 3.0-3.1.x, 2 = 3.2-4.3.3, 3 = 5.0-5.1.1, 4 = 6.0-6.1.x, 5 = 7.0+ 

// backboardd/springboard
static BOOL inSpringBoard = NO;
static BOOL inBackboardd  = NO;


// iPad support
static int is_iPad1 = 0;

static enum { PORTRAIT, MODE_A, MODE_B } screen_rotation = PORTRAIT;

static Class $SBAwayController = objc_getClass("SBAwayController");

template <typename Type_>
static void dlset(Type_ &function, const char *name) {
    function = reinterpret_cast<Type_>(dlsym(RTLD_DEFAULT, name));
    // NSLog(@"hid-support: dlset %s = %p", name, function);
}

// project GSEventRecord for OS < 3 if needed
void detectOSLevel(){
    if (kCFCoreFoundationVersionNumber > 800) { // iOS 7.x
        Level_ = 5;
        return;
    }

    if (dlsym(RTLD_DEFAULT, "GSGetPurpleWorkspacePort")){
        Level_ = 4;
        return;
    }

    if (dlsym(RTLD_DEFAULT, "GSLibraryCopyGenerationInfoValueForKey")){
        Level_ = 3;
        return;
    }
    if (dlsym(RTLD_DEFAULT, "GSKeyboardCreate")) {
        Level_ = 2;
        return;
    }
    if (dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId")) {
        Level_ = 1;
        return;
    }
    Level_ = 0;
}

void FixRecord(GSEventRecord *record) {
    if (Level_ < 1) {
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->infoSize);
    }
}

static float box(float min, float value, float max){
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

static bool isSBUserNotificationAlertVisible(void){

    if (!%c(UIApplication)) return NO;
    if (!%c(UIAlertView)) return NO;

    UIView * keyWindow = [[%c(UIApplication) sharedApplication] keyWindow];
    if (!keyWindow) return false;
    if (![keyWindow.subviews count]) return false;
    UIView * firstSubview = [keyWindow.subviews objectAtIndex:0];
    return [firstSubview isKindOfClass:[%c(UIAlertView) class]];
}

static void sendGSEvent(GSEventRecord *eventRecord, CGPoint point){

    mach_port_t port(0);
    CGPoint point2;

    switch (screen_rotation){
        case PORTRAIT:
            // framebuffer is portrait 
            point2.x = point.x;
            point2.y = point.y;
            break;
        case MODE_A:
            // framebuffer is landscape, with home on the right side
            point2.x = point.y;
            point2.y = screen_width - 1 - point.x;    
            break;
        case MODE_B:
            // framebuffer is landscape, with home on the left side
            point2.x = screen_height - 1 - point.y;
            point2.y = point.x;
            break;
    }

    point2.x *= retina_factor;
    point2.y *= retina_factor;

    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0){
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0]) { 
                port = [display clientPortAtPosition:point2];
                // NSLog(@"hid-support: display port : %x at %f/%f (%f/%f)", (int) port, point2.x, point2.y, point.x, point.y);
            }
        }
    }

    // NSLog(@"display port : %x at %f/%f", (int) port, point2.x, point2.y);
        
    if (port) {
        // FixRecord(eventRecord);
        GSSendEvent(eventRecord, port);
    } else {
        GSSendSystemEvent(eventRecord);
    }
}

// decide on GSHandInfoType
static GSHandInfoType getHandInfoType(int touch_before, int touch_now){
    if (!touch_before) {
        return (GSHandInfoType) kGSHandInfoType2TouchDown;
    }
    if (touch_before == touch_now){
        return (GSHandInfoType) kGSHandInfoType2TouchDragged;        
    }
    if (touch_now) {
        return (GSHandInfoType) kGSHandInfoType2TouchChange;
    }
    return (GSHandInfoType) kGSHandInfoType2TouchFinal;
}

static void postMouseEventGS(float x, float y, int click){

    static int prev_click = 0;

    if (!click && !prev_click) return;

    CGPoint location = CGPointMake(x, y);

    // structure of touch GSEvent
    struct GSTouchEvent {
        GSEventRecord record;
        GSHandInfo    handInfo;
    } * event = (struct GSTouchEvent*) &touchEvent;
    bzero(touchEvent, sizeof(touchEvent));
    
    // set up GSEvent
    event->record.type = kGSEventHand;
    event->record.windowLocation = location;
    event->record.timestamp = GSCurrentEventTimestamp();
    event->record.infoSize = sizeof(GSHandInfo) + sizeof(GSPathInfo);
    event->handInfo.type = getHandInfoType(prev_click, click);
    if (Level_ >= 3){
        event->handInfo.x52 = 1;
    } else {
    	event->handInfo.pathInfosCount = 1;
    }
    bzero(&event->handInfo.pathInfos[0], sizeof(GSPathInfo));
    event->handInfo.pathInfos[0].pathIndex     = 1;
    event->handInfo.pathInfos[0].pathIdentity  = 2;
    event->handInfo.pathInfos[0].pathProximity = click ? 0x03 : 0x00;;
    event->handInfo.pathInfos[0].pathLocation  = location;

    // send GSEvent
    sendGSEvent( (GSEventRecord*) event, location);  
    
    prev_click = click;  
}

static void postIOHIDEvent(IOHIDEventRef event){
    static IOHIDEventSystemClientRef ioSystemClient = NULL;
    if (!ioSystemClient){
        ioSystemClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        // NSLog(@"IOHIDEventSystemcClient %p", ioSystemClient);
    }
    IOHIDEventSystemClientDispatchEvent(ioSystemClient, event);
    CFRelease(event);
}

static void postMouseEventIOHID(float x, float y, int click){

    // NSLog(@"postMouseEventIOHID %f/%f down %u", x, y, click);

    static int prev_click = 0;

    uint32_t parent_flags;
    uint32_t child_flags;
    if (prev_click == 0 && click == 1) {
        parent_flags = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity;
        child_flags  = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
    } else if (prev_click == 1 && click == 1) {
        parent_flags = kIOHIDDigitizerEventPosition;
        child_flags  = kIOHIDDigitizerEventPosition;
    } else if (prev_click == 1 && click == 0) {
        parent_flags = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity | kIOHIDDigitizerEventPosition;
        child_flags  = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
    } else return;
    

    IOHIDFloat xf = x / screen_width;
    IOHIDFloat yf = y / screen_height;
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(), kIOHIDDigitizerTransducerTypeHand, 1<<22, 1, parent_flags, 0, xf, yf, 0, 0, 0, 0, 0, 0);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldIsBuiltIn, true);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, true);
    if ($IOHIDEventSetSenderID){
        // not in SDK 5.1 ARMv6 slice of IOKIT
        ($IOHIDEventSetSenderID)(parent, 0x8000000817319375);
    } else {
        // NSLog(@"hid-support: sendIOHIDEvent iOHIDEventSetSenderID missing");
    }
    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(), 3, 2, child_flags, xf, yf, 0, 0, 0, click, click, 0);
    IOHIDEventAppendEvent(parent, child);
    CFRelease(child);
    
    postIOHIDEvent(parent);
   
    prev_click = click;
}

// handle special function keys (>= 0f700)
typedef struct mapping {
    int specialFunction;
    int keyCode;
    int charCode;
    int modifier;
} mapping;

static mapping specialMapping[] = {
    { NSUpArrowFunctionKey,     0x52, 0x1e, 0x00 },
    { NSDownArrowFunctionKey,   0x51, 0x1f, 0x00 },
    { NSLeftArrowFunctionKey,   0x50, 0x1c, 0x00 },
    { NSRightArrowFunctionKey,  0x4f, 0x1d, 0x00 },

    { NSHomeFunctionKey,        0x52, 0x1e, CMD },   // up
    { NSEndFunctionKey,         0x51, 0x1f, CMD },   // down
    { NSBeginOfLineFunctionKey, 0x50, 0x1c, CMD },   // left
    { NSEndOfLineFunctionKey,   0x4f, 0x1d, CMD },   // right
};

static int specialMapppingCount = sizeof(specialMapping) / sizeof(mapping);

static void postKeyEvent(int down, uint16_t modifier, unichar unicode){
    CGPoint location = CGPointMake(100, 100);
    CFStringRef string = NULL;
    GSEventRef  event  = NULL;
    GSEventType type = down ? kGSEventKeyDown : kGSEventKeyUp;

    // handle special function keys on 3.2+
    int keycode = 0;
    if (Level_ >= 2 && unicode >= 0xf700){
        for (int i = 0; i < specialMapppingCount ; i ++){
            if (specialMapping[i].specialFunction == unicode){
                NSLog(@"Mapping 0x%04x -> 0x%02x/0x%02x", unicode, specialMapping[i].charCode, specialMapping[i].keyCode);
                unicode   = specialMapping[i].charCode;
                keycode   = specialMapping[i].keyCode;
                modifier |= specialMapping[i].modifier;
                break;
            }
        }
    }

    uint32_t flags = (GSEventFlags) 0;
    if (modifier & CMD){
        flags |= 1 << 16;   // 0x010000
    }
    if (modifier & SHIFT){  
        flags |= kGSEventFlagMaskShift;
    }
    if (modifier & ALT){
        flags |= kGSEventFlagMaskAlternate;
    }
    if (modifier & CTRL){
        flags |= 1 << 20;   // 0x100000
    }
    
    if ($GSEventCreateKeyEvent) {           // >= 3.2

        // NSLog(@"GSEventCreateKeyEvent type %u for %@ with flags %08x", type, modifier, string, flags); 
        string = CFStringCreateWithCharacters(kCFAllocatorDefault, &unicode, 1);
        event = (*$GSEventCreateKeyEvent)(type, location, string, string, (GSEventFlags) flags, 0, 0, 1);
        if ($GSEventSetKeyCode) {
            (*$GSEventSetKeyCode)(event, keycode);
        }
    } else if ($GSCreateSyntheticKeyEvent && down) { // < 3.2 - no up events
        // NSLog(@"GSCreateSyntheticKeyEvent down %u for %C", down, unicode);
        event = (*$GSCreateSyntheticKeyEvent)(unicode, down, YES);
        GSEventRecord *record((GSEventRecord*) _GSEventGetGSEventRecord(event));
        record->type = kGSEventSimulatorKeyDown;
        record->flags = (GSEventFlags) flags;

    } else return;

    // send events to SpringBoard if SBUserNotificationAlert is visible
    if (isSBUserNotificationAlertVisible()) {
        GSSendSystemEvent((GSEventRecord*) _GSEventGetGSEventRecord(event));
    } else {
        // send GSEvent
        sendGSEvent((GSEventRecord*) _GSEventGetGSEventRecord(event), location);
    }
        
    if (string){
        CFRelease(string);
    }
    CFRelease(event);
}

static void handleMouseEvent(const mouse_event_t *mouse_event){

    // NSLog(@"hid-support (%f/%f) - %u", mouse_event->x, mouse_event->y, mouse_event->buttons);

    float new_mouse_x, new_mouse_y;
    switch (mouse_event->type) {
        case REL_MOVE:
            new_mouse_x = mouse_x + mouse_event->x;
            new_mouse_y = mouse_y + mouse_event->y;
            break;
        case ABS_MOVE:
            new_mouse_x = mouse_event->x;
            new_mouse_y = mouse_event->y;
            break;
        default:
            return;
    }
    mouse_x = box(0, new_mouse_x, mouse_max_x);
    mouse_y = box(0, new_mouse_y, mouse_max_y);

    // NSLog(@"box x [0, %f, %f] = %f", new_mouse_x, mouse_max_x, mouse_x);
    // NSLog(@"box y [0, %f, %f] = %f", new_mouse_y, mouse_max_y, mouse_y);

    int buttons = mouse_event->buttons ? 1 : 0;
    // NSLog(@"MOUSE type %u, button %u, dx %f, dy %f", mouse_event->type, mouse_event->buttons, mouse_event->x, mouse_event->y);
    if (Level_ >= 5){
        postMouseEventIOHID(mouse_x, mouse_y, buttons);
    } else {
        postMouseEventGS(mouse_x, mouse_y, buttons);
    }
}


static void handleHomeLockVolumeButtonsGS(const button_event_t * button_event){

    // NSLog(@"handleHomeLockVolumeButtonsIOHID %x", button_event->action);

    struct GSEventRecord record;
    memset(&record, 0, sizeof(record));
    record.timestamp = GSCurrentEventTimestamp();

    switch (button_event->action){
        case HWButtonHome:
            record.type = (button_event->down) != 0 ? kGSEventMenuButtonDown : kGSEventMenuButtonUp;
            GSSendSystemEvent(&record);
            break;
        case HWButtonLock:
            record.type = (button_event->down) != 0 ? kGSEventLockButtonDown : kGSEventLockButtonUp;
            GSSendSystemEvent(&record);
            break;
        case HWButtonVolumeUp:
            record.type = (button_event->down) != 0 ? kGSEventVolumeUpButtonDown : kGSEventVolumeUpButtonUp;
            GSSendSystemEvent(&record);
            break;
        case HWButtonVolumeDown:
            record.type = (button_event->down) != 0 ? kGSEventVolumeDownButtonDown : kGSEventVolumeDownButtonUp;
            GSSendSystemEvent(&record);
            break;
        default:
            break;
    }
}

static void handleHomeLockVolumeButtonsIOHID(const button_event_t * button_event){

    // NSLog(@"handleHomeLockVolumeButtonsIOHID %x", button_event->action);

    int usage_page = 0;
    int usage = 0;
    switch (button_event->action){
        case HWButtonHome:
            usage_page = 12;
            usage = 0x40;
            break;
        case HWButtonLock:
            usage_page = 12;
            usage = 0x30;
            break;
        case HWButtonVolumeUp:
            usage_page = 0xe9;
            usage = 0x40;
            break;
        case HWButtonVolumeDown:
            usage_page = 12;
            usage = 0xea;
            break;
        default:
            return;
    }
   postIOHIDEvent(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), usage_page, usage, button_event->down, 0));
}

static void handleButtonEvent(const button_event_t *button_event){
    
    // NSLog(@"handleButtonEvent %x", button_event->action);

    SBMediaController *mc = [%c(SBMediaController) sharedInstance];

    switch (button_event->action){
        case HWButtonHome:
        case HWButtonLock:
        case HWButtonVolumeUp:
        case HWButtonVolumeDown:
            if (Level_ >= 5){
                return handleHomeLockVolumeButtonsIOHID(button_event);
            } else {
                return handleHomeLockVolumeButtonsGS(button_event);               
            } 
            break;
        case HWButtonVolumeMute:
            if (!button_event->down) break;
            if (Level_ < 2) return;    // requires 3.2+
            [[%c(VolumeControl) sharedVolumeControl] toggleMute];
            break;
        case HWButtonBrightnessUp:
            if (!button_event->down) break;
            [[%c(SBBrightnessController) sharedBrightnessController] adjustBacklightLevel:YES];
            break;
        case HWButtonBrightnessDown:
            if (!button_event->down) break;
            [[%c(SBBrightnessController) sharedBrightnessController] adjustBacklightLevel:NO];
            break;
        case HWButtonTogglePlayPause:
            if (!button_event->down) break;
            [mc togglePlayPause];
            break;
        case HWButtonPlay:
            if (!button_event->down) break;
	        if ([mc isPlaying]) break;
		    [mc togglePlayPause];
            break;
        case HWButtonPause:
            if (!button_event->down) break;
	        if (![mc isPlaying]) break;
		    [mc togglePlayPause];
            break;
        case HWButtonPreviousTrack:
            if (!button_event->down) break;
            [mc changeTrack:-1];
            break;
        case HWButtonNextTrack:
            if (!button_event->down) break;
            [mc changeTrack:+1];
            break;
        default:
            break;
    }
}

static bool isLocked() {
    if (!inSpringBoard) return NO;

    // pre iOS 7:
    if ($SBAwayController){
        return [[$SBAwayController sharedAwayController] isLocked];
    }        
    if (%c(SBLockScreenManager)){
        // request device unlock, if locked
        SBLockScreenManager * sbLockScreenManager = (SBLockScreenManager*) [%c(SBLockScreenManager) sharedInstance];
        return [sbLockScreenManager isUILocked];
    }
    return NO;
}

static void undimDisplay(){
    if (!inSpringBoard) return;

    // pre iOS 7:
    if ($SBAwayController){
        // prevent dimming - from BTstack Keyboard
        [(SpringBoard *)[%c(SpringBoard) sharedApplication] resetIdleTimerAndUndim:YES];
    }
    if (%c(SBLockScreenManager)){
        // turn on screen (nop if already on)
        SBUserAgent * sbUserAget = [%c(SBUserAgent) sharedUserAgent];
        [sbUserAget undimScreen];

        // and prevent dimming
        [(SpringBoard *)[%c(SpringBoard) sharedApplication] resetIdleTimerAndUndim];
    }
}

static void unlockDevice(){
    if (!inSpringBoard) return;

    // pre iOS 7:
    if ($SBAwayController){
        // from BTstack Keyboard                    
        bool wasDimmed = [[$SBAwayController sharedAwayController] isDimmed ];
        bool wasLocked = [[$SBAwayController sharedAwayController] isLocked ];
        
        // handle user unlock
        if ( wasDimmed || wasLocked ){
            [[$SBAwayController sharedAwayController] attemptUnlock];
            [[$SBAwayController sharedAwayController] unlockWithSound:NO];
        }
    }
    if (%c(SBLockScreenManager)){
        // request device unlock, if locked
        SBLockScreenManager * sbLockScreenManager = (SBLockScreenManager*) [%c(SBLockScreenManager) sharedInstance];
        if ([sbLockScreenManager isUILocked]){
            [sbLockScreenManager unlockUIFromSource:0 withOptions:nil];
        }
    }
}

static void keepAwake(void){
    if (!inSpringBoard) return;
    if (isLocked()){
        unlockDevice();
    }
    undimDisplay();
}

static void init_graphicsservices(void){

    // GraphicsServices used
    dlset($GSEventCreateKeyEvent, "GSEventCreateKeyEvent");
    dlset($GSCreateSyntheticKeyEvent, "_GSCreateSyntheticKeyEvent");
    dlset($GSEventSetKeyCode, "GSEventSetKeyCode");
    dlset($GSMainScreenSize, "GSMainScreenSize");
    dlset($GSMainScreenScaleFactor, "GSMainScreenScaleFactor");
    dlset($GSMainScreenOrientation, "GSMainScreenOrientation");
    dlset($GSEventCopyCharacters, "GSEventCopyCharacters");
    dlset($GSEventGetType, "GSEventGetType");
}

static void detect_iPads(void){
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char machine[size];
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    is_iPad1 = strcmp(machine, "iPad1,1") == 0;
}

void initialize(void){

    init_graphicsservices();
    dlset($IOHIDEventSetSenderID, "IOHIDEventSetSenderID");
    detect_iPads();

    // Get main screen size and retina factor
    if ($GSMainScreenScaleFactor) {
        retina_factor = $GSMainScreenScaleFactor();
    }
    if ($GSMainScreenSize){
        CGSize screenSize = $GSMainScreenSize();
        screen_width = screenSize.width / retina_factor;
        screen_height = screenSize.height / retina_factor;
    }
    if ($GSMainScreenOrientation){
        screen_orientation = $GSMainScreenOrientation();
    }

    // current mouse bounds
    mouse_max_x = screen_width - 1;
    mouse_max_y = screen_height - 1;

    // NSLog(@"hid-support: screen size: %f x %f, retina %f, orientation %f, iPad1 %u",
    //    screen_width, screen_height, retina_factor, screen_orientation, is_iPad1);

    // orientation values
    // iPad 2:   768 x 1024  - 4.7123889923095703
    // iPad 3:   768 x 1024  - 4.7123889923095703
    // iPhone 5: 320 x 586   - 1.000000
    // iPad Mini: 768 x 1024 - 1.000000

    if (is_iPad1){
        // framebuffer is landscape, with home on the right side
        screen_rotation = MODE_A;
    } else if (screen_orientation == 0.0f) {
        // framebuffer is portrait, with home on bottom (my maths tells me )
        screen_rotation = PORTRAIT;
    } else {
        screen_rotation = MODE_B;
    }

}

static CFDataRef myCallBack(CFMessagePortRef local, SInt32 msgid, CFDataRef cfData, void *info) {

    static BOOL initialized = NO;
    if (!initialized) {
        initialize();
        initialized = true;
    }
    
    const char *data = (const char *) CFDataGetBytePtr(cfData);
    uint16_t dataLen = CFDataGetLength(cfData);
    char *buffer;
    NSString * text;
    unsigned int i;
    // have pointers ready
    key_event_t     * key_event;
    const mouse_event_t   * mouse_event;
    dimension_t dimension_result;
    CFDataRef returnData = NULL;
    CGPoint location;

    switch ( (hid_event_type_t) msgid){
        case TEXT:
            // regular text
            if (dataLen == 0 || !data) break;
            keepAwake();
            // append \0 byte for NSString conversion
            buffer = (char*) malloc(dataLen + 1);
            if (!buffer) {
                break;
            }
            memcpy(buffer, data, dataLen);
            buffer[dataLen] = 0;
            text = [NSString stringWithUTF8String:buffer];
            for (i=0; i< [text length]; i++){
                // NSLog(@"TEXT: sending %C", [text characterAtIndex:i]);
                postKeyEvent(1, 0, [text characterAtIndex:i]);
                postKeyEvent(0, 0, [text characterAtIndex:i]);
            }
            free(buffer);
            break;
            
        case KEY:
            keepAwake();
            // individual key events
            key_event = (key_event_t*) data;
            key_event->down = key_event->down ? 1 : 0;
            postKeyEvent(key_event->down, key_event->modifier, key_event->unicode);
            break;
            
        case MOUSE:
            if (dataLen != sizeof(mouse_event_t) || !data) break;
            mouse_event = (const mouse_event_t *) data;
            // when locked, keep device dimmed until user clicks to unlock
            if (inSpringBoard){
                if (isLocked()){
                    if (mouse_event->buttons){
                        undimDisplay();
                        unlockDevice();
                    }
                } else {
                    undimDisplay();
                }
            }
            handleMouseEvent(mouse_event);
            break;
            
        case BUTTON:
            keepAwake();
            if (dataLen != sizeof(button_event_t) || !data) break;
              handleButtonEvent((const button_event_t *) data);
              break;
                    
        case GSEVENTRECORD:
            // NSLog(@"GSEVENTRECORD");
            keepAwake();
            location = CGPointMake(100, 100);
            sendGSEvent((GSEventRecord*)data, location);
            break;
            
        case GET_SCREEN_DIMENSION:
            dimension_result.width  = screen_width;
            dimension_result.height = screen_height;
            returnData = CFDataCreate(kCFAllocatorDefault, (const uint8_t*) &dimension_result, sizeof(dimension_t));
            break;
        
        default:
            NSLog(@"HID_SUPPORT_PORT_NAME server, msgid %d not supported", (int) msgid);
            break;
    }
    return returnData;  // as stated in header, both data and returnData will be released for us after callback returns
}

static void try_rocketbootstrap_cfmessageportexposelocal(CFMessagePortRef local){
    void * rbs_lib = dlopen("/usr/lib/librocketbootstrap.dylib", RTLD_LAZY);
    if (!rbs_lib) return;
    void (*cfmessageportexposelocal)(CFMessagePortRef) =(void (*)(CFMessagePortRef)) dlsym(rbs_lib, "rocketbootstrap_cfmessageportexposelocal");
    if (!cfmessageportexposelocal);
    cfmessageportexposelocal(local);
}

static void setupSpringboardMessagePort(){
    CFMessagePortRef local = CFMessagePortCreateLocal(NULL, CFSTR(HID_SUPPORT_PORT_NAME), myCallBack, NULL, NULL);
    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, local, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    try_rocketbootstrap_cfmessageportexposelocal(local);
}

static void setupBackboarddMessagePort(){
    CFMessagePortRef local = CFMessagePortCreateLocal(NULL, CFSTR(HID_SUPPORT_PORT_NAME_BB), myCallBack, NULL, NULL);
    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, local, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    try_rocketbootstrap_cfmessageportexposelocal(local);
}

// Support GSEventKeyDown on iOS 7 and later
%hook UIApplication
- (BOOL)handleEvent:(GSEventRef)gsEvent withNewEvent:(id)arg2{
    if (Level_ >= 5 && gsEvent) {
        GSEventType gsType = $GSEventGetType(gsEvent);
        if (gsType == kGSEventKeyDown){
            CFStringRef text = $GSEventCopyCharacters(gsEvent);
            if (text){
                // NSLog(@"hid-support: injecting '%@'", text);
                UIKeyboardImpl * keyboardImpl = (UIKeyboardImpl*) [%c(UIKeyboardImpl) sharedInstance];
                [keyboardImpl addInputString:(NSString*)text];
                CFRelease(text);
            }
        }
    }
    return %orig;
}
%end

%ctor{
    detectOSLevel();
    // NSLog(@"hid-support detected OS level %u", Level_);

    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
    // NSLog(@"hid-support: inside %@", identifier);

    if ([identifier isEqualToString:@"com.apple.backboardd"]){
        inBackboardd = YES;
        setupBackboarddMessagePort();
        return;
    }

   if ([identifier isEqualToString:@"com.apple.springboard"]){
        inSpringBoard = YES;
        setupSpringboardMessagePort();
        return;
    }

    // Inside UIKit app
    if (Level_ >= 5){
        // setup GSEvent handler
        %init();
        init_graphicsservices();
    }
}
