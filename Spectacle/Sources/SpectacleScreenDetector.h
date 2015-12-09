#import <Cocoa/Cocoa.h>

#import "SpectacleWindowPositionManager.h"

@class SpectacleAccessibilityElement;

@interface SpectacleScreenDetector : NSObject

- (NSScreen *)screenWithAction:(SpectacleWindowAction)action
        frontmostWindowElement:(SpectacleAccessibilityElement *)frontmostWindowElement
                       screens:(NSArray *)screens
                    mainScreen:(NSScreen *)mainScreen;

- (NSScreen *)screenContainingFrontmostWindowElement:(SpectacleAccessibilityElement*)frontmostWindowElement
                                             screens:(NSArray *)screens
                                          mainScreen:(NSScreen *)mainScreen;

@end
