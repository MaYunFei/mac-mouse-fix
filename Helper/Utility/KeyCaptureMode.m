//
// --------------------------------------------------------------------------
// KeyCaptureMode.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import "KeyCaptureMode.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import "ModificationUtility.h"
#import "MFMessagePort.h"
#import "Logging.h"

@implementation KeyCaptureMode


/// Explanation for this class:
///  When the user records keyboard shortcuts in the mainApp we wanted to use eventTaps for that. I think otherwise certain keys weren't captured. Not sure though. The helper already has permissions to use eventTaps so the mainApp delegates the capturing to the helper.


CFMachPortRef _keyCaptureEventTap;

/// Deferred capture of standalone modifier keys (e.g. Right Command, Right Option, ...)
///     Why deferred: A modifier by itself only produces `kCGEventFlagsChanged` events, not `kCGEventKeyDown`.
///         If we captured the modifier immediately on its flagsChanged *press*, then recording a regular combination such as `⌘C` would incorrectly stop at `⌘`.
///         So we remember the pressed modifier, and only commit it once we know no other key follows – i.e. when the modifier is *released* (or a safety timeout fires).
///         If a non-modifier keyDown arrives while a modifier is pending, we discard the pending modifier and let the regular keyDown path capture the combination.
static CGKeyCode _pendingModifierKeyCode = USHRT_MAX;
static CGEventFlags _pendingModifierFlags = 0;
static NSTimer *_pendingModifierTimer = nil;

static BOOL isModifierKeyCode(CGKeyCode keyCode) {
    return keyCode == kVK_Command || keyCode == kVK_RightCommand ||
           keyCode == kVK_Option || keyCode == kVK_RightOption ||
           keyCode == kVK_Control || keyCode == kVK_RightControl ||
           keyCode == kVK_Shift || keyCode == kVK_RightShift;
}

static BOOL isModifierFlagsChangedKeyDown(CGKeyCode keyCode, CGEventFlags flags) {
    switch (keyCode) {
        case kVK_Command:      return (flags & NX_DEVICELCMDKEYMASK) != 0;
        case kVK_RightCommand: return (flags & NX_DEVICERCMDKEYMASK) != 0;
        case kVK_Option:       return (flags & NX_DEVICELALTKEYMASK) != 0;
        case kVK_RightOption:  return (flags & NX_DEVICERALTKEYMASK) != 0;
        case kVK_Control:      return (flags & NX_DEVICELCTLKEYMASK) != 0;
        case kVK_RightControl: return (flags & NX_DEVICERCTLKEYMASK) != 0;
        case kVK_Shift:        return (flags & NX_DEVICELSHIFTKEYMASK) != 0;
        case kVK_RightShift:   return (flags & NX_DEVICERSHIFTKEYMASK) != 0;
        default:               return NO;
    }
}

+ (void)enable {
    
    DDLogInfo("Enabling keyCaptureMode");
    
    if (_keyCaptureEventTap == nil) {
        _keyCaptureEventTap = [ModificationUtility createEventTapWithLocation:kCGHIDEventTap mask:CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(NSEventTypeSystemDefined) option:kCGEventTapOptionDefault placement:kCGHeadInsertEventTap callback:keyCaptureModeCallback];
    }
    clearPendingModifier();
    CGEventTapEnable(_keyCaptureEventTap, true);
}

+ (void)disable {
    CGEventTapEnable(_keyCaptureEventTap, false);
}

static void commitPendingModifierCapture(void) {
    
    [_pendingModifierTimer invalidate];
    _pendingModifierTimer = nil;
    
    if (_pendingModifierKeyCode == USHRT_MAX) return;
    
    CGKeyCode keyCode = _pendingModifierKeyCode;
    CGEventFlags flags = _pendingModifierFlags;
    
    _pendingModifierKeyCode = USHRT_MAX;
    _pendingModifierFlags = 0;
    
    NSDictionary *payload = @{
        @"keyCode": @(keyCode),
        @"flags": @(flags),
    };
    
    [MFMessagePort sendMessage:@"keyCaptureModeFeedback" withPayload:payload waitForReply:NO];
    [KeyCaptureMode disable];
}

static void clearPendingModifier(void) {
    [_pendingModifierTimer invalidate];
    _pendingModifierTimer = nil;
    _pendingModifierKeyCode = USHRT_MAX;
    _pendingModifierFlags = 0;
}

CGEventRef  _Nullable keyCaptureModeCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    
    CGEventFlags flags  = CGEventGetFlags(event);
    
    NSDictionary *payload;
    
    if (type == kCGEventKeyDown) {
        
        CGKeyCode keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        
        /// A regular (non-modifier) key was pressed while a modifier is pending -> This is a combination such as `⌘C`.
        /// Discard the pending modifier so we capture the combination below instead.
        if (!isModifierKeyCode(keyCode)) {
            clearPendingModifier();
        }
        
        if (keyCaptureModePayloadIsValidWithKeyCode(keyCode, flags)) {
            
            payload = @{
                @"keyCode": @(keyCode),
                @"flags": @(flags),
            };
            
            [MFMessagePort sendMessage:@"keyCaptureModeFeedback" withPayload:payload waitForReply:NO];
            [KeyCaptureMode disable];
        }
        
    } else if (type == kCGEventFlagsChanged) {
        
        CGKeyCode keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        
        if (isModifierKeyCode(keyCode)) {
            
            if (isModifierFlagsChangedKeyDown(keyCode, flags)) {
                
                /// Modifier pressed -> Defer. See explanation on `_pendingModifierKeyCode`.
                _pendingModifierKeyCode = keyCode;
                _pendingModifierFlags = flags;
                
                [_pendingModifierTimer invalidate];
                _pendingModifierTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *timer) {
                    /// Safety net: Commit even if we never see the release event (e.g. eventTap got re-enabled while key held)
                    commitPendingModifierCapture();
                }];
                
            } else {
                
                /// Modifier released -> If it's the one we're waiting on, commit it as a standalone shortcut.
                if (keyCode == _pendingModifierKeyCode) {
                    commitPendingModifierCapture();
                }
            }
        }
        
    } else if (type == NSEventTypeSystemDefined) {
        
        NSEvent *e = [NSEvent eventWithCGEvent:event];
        
        MFSystemDefinedEventType type = (MFSystemDefinedEventType)(e.data1 >> 16);
        
        if (keyCaptureModePayloadIsValidWithEvent(e, flags, type)) {
            
            DDLogDebug("Capturing system event with data1: %ld, data2: %ld", e.data1, e.data2);
            
            payload = @{
                @"systemEventType": @(type),
                @"flags": @(flags),
            };
            
            [MFMessagePort sendMessage:@"keyCaptureModeFeedbackWithSystemEvent" withPayload:payload waitForReply:NO];
            [KeyCaptureMode disable];
        }
        
    }
    
    
    return nil;
}
bool keyCaptureModePayloadIsValidWithKeyCode(CGKeyCode keyCode, CGEventFlags flags) {
    return true; /// keyCode 0 is 'A'
}

bool keyCaptureModePayloadIsValidWithEvent(NSEvent *e, CGEventFlags flags, MFSystemDefinedEventType type) {
    
    BOOL isSub8 = (e.subtype == 8); /// 8 -> NSEventSubtypeScreenChanged
    BOOL isKeyDown = (e.data1 & kMFSystemDefinedEventPressedMask) == 0;
    BOOL secondDataIsNil = e.data2 == -1; /// The power key up event has both data fields be 0
    BOOL typeIsBlackListed = type == kMFSystemEventTypeCapsLock;
    
    BOOL isValid = isSub8 && isKeyDown && secondDataIsNil && !typeIsBlackListed;
    
    if (!isValid) {
        DDLogDebug("KeyCaptureMode received systemDefinedEvent but it is not valid – isSubtype8: %d, isKeyDown: %d, secondDataIsNil: %d, typeIsBlackListed: %d – event: %@, flags: %llu, type: %d", isSub8, isKeyDown, secondDataIsNil, typeIsBlackListed, e, flags, type);
    }
    
    return isValid;
}

@end
