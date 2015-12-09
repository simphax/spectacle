#import <Sparkle/Sparkle.h>

#import "SpectacleAccessibilityElement.h"
#import "SpectacleAppDelegate.h"
#import "SpectacleConstants.h"
#import "SpectaclePreferencesController.h"
#import "SpectacleScreenDetector.h"
#import "SpectacleShortcutManager.h"
#import "SpectacleShortcutTranslator.h"
#import "SpectacleShortcutUserDefaultsStorage.h"
#import "SpectacleUtilities.h"
#import "SpectacleWindowPositionCalculator.h"
#import "SpectacleWindowPositionManager.h"

@implementation SpectacleAppDelegate
{
  NSDictionary *_shortcutMenuItems;
  NSStatusItem *_statusItem;
  id<SpectacleShortcutStorageProtocol> _shortcutStorage;
  SpectacleShortcutManager *_shortcutManager;
  SpectacleWindowPositionManager *_windowPositionManager;
  SpectaclePreferencesController *_preferencesController;
  NSTimer *_disableShortcutsForAnHourTimer;
  NSSet *_blacklistedApplications;
  NSMutableSet *_disabledApplications;
  BOOL _shortcutsAreDisabledForAnHour;
  CFMachPortRef _eventTap;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

  [notificationCenter addObserver:self
                         selector:@selector(enableStatusItem)
                             name:kStatusItemEnabledNotification
                           object:nil];

  [notificationCenter addObserver:self
                         selector:@selector(disableStatusItem)
                             name:kStatusItemDisabledNotification
                           object:nil];

  [notificationCenter addObserver:self
                         selector:@selector(updateShortcutMenuItems)
                             name:kShortcutChangedNotification
                           object:nil];

  [notificationCenter addObserver:self
                         selector:@selector(updateShortcutMenuItems)
                             name:kRestoreDefaultShortcutsNotification
                           object:nil];

  [notificationCenter addObserver:self
                         selector:@selector(menuDidSendAction:)
                             name:NSMenuDidSendActionNotification
                           object:nil];

  NSNotificationCenter *workspaceNotificationCenter = [NSWorkspace sharedWorkspace].notificationCenter;

  [workspaceNotificationCenter addObserver:self
                                  selector:@selector(applicationDidActivate:)
                                      name:NSWorkspaceDidActivateApplicationNotification
                                    object:nil];

  [workspaceNotificationCenter addObserver:self
                                  selector:@selector(applicationDidDeactivate:)
                                      name:NSWorkspaceDidDeactivateApplicationNotification
                                    object:nil];

  [SpectacleUtilities registerDefaultsForBundle:[NSBundle mainBundle]];

  _shortcutMenuItems = @{kWindowActionMoveToCenter: _moveToCenterShortcutMenuItem,
                         kWindowActionMoveToFullscreen: _moveToFullscreenShortcutMenuItem,
                         kWindowActionMoveToLeftHalf: _moveToLeftShortcutMenuItem,
                         kWindowActionMoveToRightHalf: _moveToRightShortcutMenuItem,
                         kWindowActionMoveToTopHalf: _moveToTopShortcutMenuItem,
                         kWindowActionMoveToBottomHalf: _moveToBottomShortcutMenuItem,
                         kWindowActionMoveToUpperLeft: _moveToUpperLeftShortcutMenuItem,
                         kWindowActionMoveToLowerLeft: _moveToLowerLeftShortcutMenuItem,
                         kWindowActionMoveToUpperRight: _moveToUpperRightShortcutMenuItem,
                         kWindowActionMoveToLowerRight: _moveToLowerRightShortcutMenuItem,
                         kWindowActionMoveToNextDisplay: _moveToNextDisplayShortcutMenuItem,
                         kWindowActionMoveToPreviousDisplay: _moveToPreviousDisplayShortcutMenuItem,
                         kWindowActionMoveToNextThird: _moveToNextThirdShortcutMenuItem,
                         kWindowActionMoveToPreviousThird: _moveToPreviousThirdShortcutMenuItem,
                         kWindowActionMakeLarger: _makeLargerShortcutMenuItem,
                         kWindowActionMakeSmaller: _makeSmallerShortcutMenuItem,
                         kWindowActionUndoLastMove: _undoLastMoveShortcutMenuItem,
                         kWindowActionRedoLastMove: _redoLastMoveShortcutMenuItem};

  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

  _blacklistedApplications = [NSSet setWithArray:[userDefaults objectForKey:kBlacklistedApplicationsPreference]];
  _disabledApplications = [NSMutableSet setWithArray:[userDefaults objectForKey:kDisabledApplicationsPreference]];

  _shortcutStorage = [SpectacleShortcutUserDefaultsStorage new];
  _shortcutManager = [[SpectacleShortcutManager alloc] initWithShortcutStorage:_shortcutStorage];

  _windowPositionManager = [[SpectacleWindowPositionManager alloc] initWithScreenDetector:[SpectacleScreenDetector new]
                                                                 windowPositionCalculator:[SpectacleWindowPositionCalculator new]
                                                                          sharedWorkspace:[NSWorkspace sharedWorkspace]];

  _preferencesController = [[SpectaclePreferencesController alloc] initWithShortcutManager:_shortcutManager
                                                                     windowPositionManager:_windowPositionManager
                                                                           shortcutStorage:_shortcutStorage];

  _shortcutsAreDisabledForAnHour = NO;

  [self registerShortcuts];

  [self disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled];

  BOOL automaticallyChecksForUpdates = [userDefaults boolForKey:kAutomaticUpdateCheckEnabledPreference];
  BOOL statusItemEnabled = [userDefaults boolForKey:kStatusItemEnabledPreference];

  if (statusItemEnabled) {
    [self enableStatusItem];
  }

  [[SUUpdater sharedUpdater] setAutomaticallyChecksForUpdates:automaticallyChecksForUpdates];

  [self updateShortcutMenuItems];
    
    _eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, CGEventMaskBit(kCGEventScrollWheel), eventTapCallback, (__bridge void * _Nullable)(self));
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0), kCFRunLoopCommonModes);
    CGEventTapEnable(_eventTap, true);

  if (!AXIsProcessTrustedWithOptions(NULL)) {
    [[NSApplication sharedApplication] runModalForWindow:self.accessiblityAccessDialogWindow];
  }
    
}

BOOL handledSwipeLeft = false;
BOOL handledSwipeRight = false;

-(CGEventRef) handleScrollEvent:(NSEvent*)event {
    //NSLog(@"eventTapCallback: %f", event.deltaX);
    
    if(event.phase != NSEventPhaseEnded) {
        if(handledSwipeLeft && event.scrollingDeltaX > -1) {
            NSLog(@"reset swipe left, %f", event.deltaX);
            handledSwipeLeft = false;
        }
        if(handledSwipeRight && event.scrollingDeltaX < 1) {
            NSLog(@"reset swipe right, %f", event.deltaX);
            handledSwipeRight = false;
        }
    }
    
    NSEventModifierFlags flags = event.modifierFlags;
    if( (flags & NSAlternateKeyMask) && (flags & NSAlternateKeyMask) && (flags & NSAlternateKeyMask)) {
        
        /*
         EventHotKeyID shortcutID;
         OSStatus err = GetEventParameter([event eventRef],
         kEventParamDirectObject,
         typeEventHotKeyID,
         NULL,
         sizeof(EventHotKeyID),
         NULL,
         &shortcutID);
         
         shortcutID.id = 32;
         
         
         
         NSLog(@"233333333 shorcutID: %i",shortcutID.id);
         
         SpectacleShortcut *shortcut = [(__bridge SpectacleShortcutManager *)shortcutManager registeredShortcutForShortcutID:shortcutID];
         
         [shortcut triggerShortcutAction];
         */
        /*
         [shortcut setShortcutAction:^(SpectacleShortcut *shortcut) {
         SpectacleWindowAction windowAction = [_windowPositionManager windowActionForShortcut:shortcut];
         
         [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
         action:windowAction];
         }];
         */
        if(!handledSwipeLeft && !handledSwipeRight) {
            [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                    offset:CGPointMake(event.deltaX*8, -event.deltaY*8)];
        }
    
        if(!handledSwipeLeft && event.deltaX < -3) {
            handledSwipeLeft = true;
            [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                        action:SpectacleWindowActionLeftHalf];
            NSLog(@"swipe left, %f", event.deltaX);
            
        }
        if(!handledSwipeRight && event.deltaX > 3) {
            handledSwipeRight = true;
            [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                        action:SpectacleWindowActionRightHalf];
            NSLog(@"swipe right, %f", event.deltaX);
        }
        return NULL;
    } else {
        return [event CGEvent];
    }
    
    // return the CGEventRef

}

//NSEventMask eventMask = NSEventMaskGesture|NSEventMaskMagnify|NSEventMaskSwipe|NSEventMaskRotate|NSEventMaskBeginGesture|NSEventMaskEndGesture;
NSEventMask eventMask = NSScrollWheelMask;

CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef eventRef, void *appDelegate) {
    
    SpectacleAppDelegate *self = (__bridge SpectacleAppDelegate *)appDelegate;
    
    if(type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(self->_eventTap, true);
        return eventRef;
    }
    
    @try {
        NSEvent *event = [NSEvent eventWithCGEvent:eventRef];
        if (!(eventMask & NSEventMaskFromType([event type]))) { return [event CGEvent]; }
        
        return [self handleScrollEvent:event];
    }
    @catch (NSException *e) {
        //We catch any exceptions to prevent the event tap from being messed up.
        NSLog(@"*** ignoring exception: %@", e);
    }
    
    return eventRef;
}




#pragma mark -

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visibleWindows
{
  [self showPreferencesWindow:self];

  return YES;
}

#pragma mark -

- (IBAction)showPreferencesWindow:(id)sender
{
  [_preferencesController showWindow:sender];
}

#pragma mark -

- (IBAction)moveFrontmostWindowToFullscreen:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionFullscreen];
}

- (IBAction)moveFrontmostWindowToCenter:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionCenter];
}

#pragma mark -

- (IBAction)moveFrontmostWindowToLeftHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionLeftHalf];
}

- (IBAction)moveFrontmostWindowToRightHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionRightHalf];
}

- (IBAction)moveFrontmostWindowToTopHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionTopHalf];
}

- (IBAction)moveFrontmostWindowToBottomHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionBottomHalf];
}

#pragma mark -

- (IBAction)moveFrontmostWindowToUpperLeft:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionUpperLeft];
}

- (IBAction)moveFrontmostWindowToLowerLeft:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionLowerLeft];
}

#pragma mark -

- (IBAction)moveFrontmostWindowToUpperRight:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionUpperRight];
}

- (IBAction)moveFrontmostWindowToLowerRight:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionLowerRight];
}

#pragma mark -

- (IBAction)moveFrontmostWindowToNextDisplay:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionNextDisplay];
}

- (IBAction)moveFrontmostWindowToPreviousDisplay:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionPreviousDisplay];
}

#pragma mark -

- (IBAction)moveFrontmostWindowToNextThird:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:SpectacleWindowActionNextThird];
}

- (IBAction)moveFrontmostWindowToPreviousThird:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement] action:SpectacleWindowActionPreviousThird];
}

#pragma mark -

- (IBAction)makeFrontmostWindowLarger:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement] action:SpectacleWindowActionLarger];
}

- (IBAction)makeFrontmostWindowSmaller:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement] action:SpectacleWindowActionSmaller];
}

#pragma mark -

- (IBAction)undoLastWindowAction:(id)sender
{
  [_windowPositionManager undoLastWindowAction];
}

- (IBAction)redoLastWindowAction:(id)sender
{
  [_windowPositionManager redoLastWindowAction];
}

#pragma mark -

- (IBAction)disableOrEnableShortcutsForAnHour:(id)sender
{
  NSInteger newMenuItemState = NSMixedState;

  if (_shortcutsAreDisabledForAnHour) {
    _shortcutsAreDisabledForAnHour = NO;

    [_disableShortcutsForAnHourTimer invalidate];

    [self enableShortcutsIfPermitted];

    newMenuItemState = NSOffState;
  } else {
    _shortcutsAreDisabledForAnHour = YES;

    _disableShortcutsForAnHourTimer = [NSTimer scheduledTimerWithTimeInterval:3600
                                                                       target:self
                                                                     selector:@selector(disableOrEnableShortcutsForAnHour:)
                                                                     userInfo:nil
                                                                      repeats:NO];

    [_shortcutManager disableShortcuts];

    newMenuItemState = NSOnState;
  }

  self.disableShortcutsForAnHourMenuItem.state = newMenuItemState;
}

- (IBAction)disableOrEnableShortcutsForApplication:(id)sender
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;

  if ([_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    [_disabledApplications removeObject:frontmostApplication.bundleIdentifier];

    [self enableShortcutsIfPermitted];

    self.disableShortcutsForApplicationMenuItem.state = NSOffState;
  } else {
    [_disabledApplications addObject:frontmostApplication.bundleIdentifier];

    [_shortcutManager disableShortcuts];

    self.disableShortcutsForApplicationMenuItem.state = NSOnState;
  }

  [NSUserDefaults.standardUserDefaults setObject:_disabledApplications.allObjects
                                          forKey:kDisabledApplicationsPreference];
}

#pragma mark -

- (IBAction)openSystemPreferences:(id)sender
{
  NSURL *preferencePaneURL = [NSURL fileURLWithPath:[SpectacleUtilities pathForPreferencePaneNamed:kSecurityPreferencePaneName]];
  NSBundle *applicationBundle = NSBundle.mainBundle;
  NSURL *scriptURL = [applicationBundle URLForResource:kSecurityAndPrivacyPreferencesScriptName
                                         withExtension:kAppleScriptFileExtension];

  [[NSApplication sharedApplication] stopModal];

  [self.accessiblityAccessDialogWindow orderOut:self];

  if (![[[NSAppleScript alloc] initWithContentsOfURL:scriptURL error:nil] executeAndReturnError:nil]) {
    [[NSWorkspace sharedWorkspace] openURL:preferencePaneURL];
  }
}

#pragma mark -

- (void)registerShortcuts
{
  NSArray *shortcuts = [_shortcutStorage loadShortcutsWithAction:^(SpectacleShortcut *shortcut) {
    SpectacleWindowAction windowAction = [_windowPositionManager windowActionForShortcut:shortcut];

    [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                action:windowAction];
  }];

  [_shortcutManager registerShortcuts:shortcuts];
}

#pragma mark -

- (void)enableStatusItem
{
  _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

  NSImage *statusImage = [NSBundle.mainBundle imageForResource:kStatusItemIcon];

  [statusImage setTemplate:YES];

  _statusItem.highlightMode = YES;
  _statusItem.image = statusImage;
  _statusItem.menu = _statusItemMenu;
  _statusItem.toolTip = [@"Spectacle " stringByAppendingString:SpectacleUtilities.applicationVersion];
}

- (void)disableStatusItem
{
  [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}

#pragma mark -

- (void)updateShortcutMenuItems
{
  SpectacleShortcutTranslator *shortcutTranslator = [SpectacleShortcutTranslator sharedTranslator];

  for (NSString *shortcutName in _shortcutMenuItems.allKeys) {
    NSMenuItem *shortcutMenuItem = _shortcutMenuItems[shortcutName];
    SpectacleShortcut *shortcut = [_shortcutManager registeredShortcutForName:shortcutName];

    if (shortcut) {
      shortcutMenuItem.keyEquivalent = [[shortcutTranslator translateKeyCode:shortcut.shortcutCode] lowercaseString];
      shortcutMenuItem.keyEquivalentModifierMask = [SpectacleShortcutTranslator convertModifiersToCocoaIfNecessary:shortcut.shortcutModifiers];
    } else {
      shortcutMenuItem.keyEquivalent = @"";
      shortcutMenuItem.keyEquivalentModifierMask = 0;
    }
  }
}

#pragma mark -

- (void)enableShortcutsIfPermitted
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;

  // Do not enable shortcuts if they should remain disabled for an hour.
  if (_shortcutsAreDisabledForAnHour) return;

  // Do not enable shortcuts if the application is blacklisted or disabled.
  if ([_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]
      || [_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    return;
  }

  [_shortcutManager enableShortcuts];
}

- (void)disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;

  // Do not disable shortcuts if the application is not blacklisted or disabled.
  if (![_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]
      && ![_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    return;
  }

  [_shortcutManager disableShortcuts];
}

#pragma mark -

- (void)applicationDidActivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];

  if ([_blacklistedApplications containsObject:application.bundleIdentifier]
      || [_disabledApplications containsObject:application.bundleIdentifier]) {
    [_shortcutManager disableShortcuts];
  }
}

- (void)applicationDidDeactivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];

  if ([_blacklistedApplications containsObject:application.bundleIdentifier]
      || [_disabledApplications containsObject:application.bundleIdentifier]) {
    [self enableShortcutsIfPermitted];
  }
}

#pragma mark -

- (void)menuWillOpen:(NSMenu *)menu
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;

  self.disableShortcutsForApplicationMenuItem.hidden = NO;

  if ([_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]) {
    self.disableShortcutsForApplicationMenuItem.hidden = YES;
  } else {
    self.disableShortcutsForApplicationMenuItem.title =
      [NSString stringWithFormat:NSLocalizedString(@"MenuItemTitleDisableShortcutsForApplication", @"The menu item title that displays the application to disable shortcuts for"), frontmostApplication.localizedName];
  }

  if ([_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    self.disableShortcutsForApplicationMenuItem.state = NSOnState;
  } else {
    self.disableShortcutsForApplicationMenuItem.state = NSOffState;
  }
}

- (void)menuDidSendAction:(NSNotification *)notification
{
  NSMenuItem *menuItem = notification.userInfo[@"MenuItem"];

  if (menuItem.tag == kMenuItemActivateIgnoringOtherApps) {
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
  }
}

@end
