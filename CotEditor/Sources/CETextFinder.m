/*
 
 CETextFinder.m
 
 CotEditor
 http://coteditor.com
 
 Created by 1024jp on 2015-01-03.

 ------------------------------------------------------------------------------
 
 © 2015-2016 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

#import "CETextFinder.h"

#import "CotEditor-Swift.h"

#import "CEErrors.h"
#import "CEDefaults.h"


// keys for highlight
static NSString * _Nonnull const CEFindHighlightRange = @"range";
static NSString * _Nonnull const CEFindHighlightColor = @"color";

static const NSUInteger kMaxHistorySize = 20;


@interface CETextFinder ()

@property (nonatomic, nullable) __kindof NSWindowController *findPanelController;
@property (nonatomic, nonnull) NSNumberFormatter *integerFormatter;
@property (nonatomic, nonnull) NSColor *highlightColor;
@property (nonatomic, nonnull) NSMutableSet<NSTextView *> *busyTextViews;

#pragma mark Settings
@property (readonly, nonatomic) BOOL usesRegularExpression;
@property (readonly, nonatomic) BOOL isWrap;
@property (readonly, nonatomic) BOOL inSelection;
@property (readonly, nonatomic) NSStringCompareOptions textualOptions;
@property (readonly, nonatomic) NSRegularExpressionOptions regexOptions;
@property (readonly, nonatomic) BOOL closesIndicatorWhenDone;

@end




#pragma mark -

@implementation CETextFinder

#pragma mark Singleton

// ------------------------------------------------------
/// return singleton instance
+ (nonnull CETextFinder *)sharedTextFinder
// ------------------------------------------------------
{
    static dispatch_once_t onceToken;
    __strong static id shared = nil;
    
    dispatch_once(&onceToken, ^{
        shared = [[self _alloc] _init];
    });
    
    return shared;
}


// ------------------------------------------------------
/// for Interface Builder compatible singleton
+ (nonnull instancetype)alloc
// ------------------------------------------------------
{
    return [self sharedTextFinder];
}


// ------------------------------------------------------
/// for Interface Builder compatible singleton
+ (nonnull instancetype)allocWithZone:(nullable NSZone *)zone
// ------------------------------------------------------
{
    return [self sharedTextFinder];
}


// ------------------------------------------------------
/// for Interface Builder compatible singleton
+ (nonnull instancetype)_alloc
// ------------------------------------------------------
{
    return [super allocWithZone:NULL];
}


// ------------------------------------------------------
/// for Interface Builder compatible singleton
- (nonnull instancetype)init
// ------------------------------------------------------
{
    return self;
}


// ------------------------------------------------------
/// for Interface Builder compatible singleton
- (nullable instancetype)initWithCoder:(nonnull NSCoder *)decoder
// ------------------------------------------------------
{
    return self;
}



#pragma mark Sueprclass Methods

// ------------------------------------------------------
/// register default setting for find panel
+ (void)initialize
// ------------------------------------------------------
{
    [super initialize];
    
    // register defaults for find panel here
    // sicne FindPanelController can be initialized before registering user defaults in AppDelegate. (2015-01 by 1024jp)
    NSDictionary<NSString *, id> *defaults = @{CEDefaultFindHistoryKey: @[],
                                               CEDefaultReplaceHistoryKey: @[],
                                               CEDefaultFindUsesRegularExpressionKey: @NO,
                                               CEDefaultFindInSelectionKey: @NO,
                                               CEDefaultFindIsWrapKey: @YES,
                                               CEDefaultFindNextAfterReplaceKey: @YES,
                                               CEDefaultFindClosesIndicatorWhenDoneKey: @YES,
                                               CEDefaultFindIgnoresCaseKey: @NO,
                                               
                                               CEDefaultFindTextIsLiteralSearchKey: @NO,
                                               CEDefaultFindTextIgnoresDiacriticMarksKey: @NO,
                                               CEDefaultFindTextIgnoresWidthKey: @NO,
                                               
                                               CEDefaultFindRegexIsSinglelineKey: @NO,
                                               CEDefaultFindRegexIsMultilineKey: @YES,
                                               CEDefaultFindRegexUsesUnicodeBoundariesKey: @NO,
                                               };
    
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}


// ------------------------------------------------------
/// private instance initializer
- (nonnull instancetype)_init
// ------------------------------------------------------
{
    self = [super init];
    if (self) {
        _findString = @"";
        _replacementString = @"";
        _busyTextViews = [NSMutableSet set];
        _integerFormatter = [[NSNumberFormatter alloc] init];
        [_integerFormatter setUsesGroupingSeparator:YES];
        [_integerFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
        
        _highlightColor = [NSColor colorWithCalibratedHue:0.24 saturation:0.8 brightness:0.8 alpha:0.4];
        // Highlight color is currently not customizable. (2015-01-04)
        // It might better when it can be set in theme also for incompatible chars highlight.
        // Just because I'm lazy.
        
        // add to responder chain
        [NSApp setNextResponder:self];
        
        // observe application activation to sync find string with other apps
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:NSApplicationWillResignActiveNotification
                                                   object:nil];
    }
    return self;
}


// ------------------------------------------------------
/// clean up
- (void)dealloc
// ------------------------------------------------------
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


// ------------------------------------------------------
/// validate menu item
- (BOOL)validateMenuItem:(nonnull NSMenuItem *)menuItem
// ------------------------------------------------------
{
    SEL action = [menuItem action];
    
    if (action == @selector(findNext:) ||
        action == @selector(findPrevious:) ||
        action == @selector(findSelectedText:) ||
        action == @selector(findAll:) ||
        action == @selector(highlight:) ||
        action == @selector(unhighlight:) ||
        action == @selector(replace:) ||
        action == @selector(replaceAndFind:) ||
        action == @selector(replaceAll:) ||
        action == @selector(centerSelectionInVisibleArea:))
    {
        return ([self client] != nil);
        
    } else if (action == @selector(useSelectionForFind:)) {
        return ([self selectedString] != nil);
        
    } else if (action == @selector(useSelectionForReplace:)) {
        return ([self client] != nil);  // replacement string accepts empty string
    }
    
    return YES;
}



#pragma mark Notification

// ------------------------------------------------------
/// sync search string on activating application
- (void)applicationDidBecomeActive:(nonnull NSNotification *)notification
// ------------------------------------------------------
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultSyncFindPboardKey]) {
        NSString *sharedFindString = [self findStringFromPasteboard];
        if (sharedFindString) {
            [self setFindString:sharedFindString];
        }
    }
}


// ------------------------------------------------------
/// sync search string on activating application
- (void)applicationWillResignActive:(nonnull NSNotification *)notification
// ------------------------------------------------------
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultSyncFindPboardKey]) {
        [self setFindStringToPasteboard:[self findString]];
    }
}



#pragma mark Action Messages

// ------------------------------------------------------
/// activate find panel
- (IBAction)showFindPanel:(nullable id)sender
// ------------------------------------------------------
{
    [[self findPanelController] showWindow:sender];
}


// ------------------------------------------------------
/// find next matched string
- (IBAction)findNext:(nullable id)sender
// ------------------------------------------------------
{
    if ([NSEvent modifierFlags] & NSShiftKeyMask) {
        // find backwards if Shift key pressed
        [self findForward:NO];
    } else {
        [self findForward:YES];
    }
}


// ------------------------------------------------------
/// find previous matched string
- (IBAction)findPrevious:(nullable id)sender
// ------------------------------------------------------
{
    [self findForward:NO];
}


// ------------------------------------------------------
/// perform find action with the selected string
- (IBAction)findSelectedText:(nullable id)sender
// ------------------------------------------------------
{
    [self useSelectionForFind:sender];
    [self findNext:sender];
}


// ------------------------------------------------------
/// find all matched string in the target and show results in a table
- (IBAction)findAll:(nullable id)sender
// ------------------------------------------------------
{
    if (![self checkIsReadyToFind]) { return; }
    
    NSNumberFormatter *integerFormatter = [self integerFormatter];
    NSTextView *textView = [self client];
    NSString *findString = [self sanitizedFindString];
    NSRegularExpression *regex = [self regex];
    NSArray<NSValue *> *scopeRanges = [self scopeRanges];
    
    [[self busyTextViews] addObject:textView];
    
    NSUInteger numberOfGroups = [regex numberOfCaptureGroups];
    NSArray<NSColor *> *highlightColors = [[self highlightColor] decompositeInto:numberOfGroups + 1];
    
    NSRegularExpression *lineRegex = [NSRegularExpression regularExpressionWithPattern:@"\n" options:0 error:nil];
    NSString *string = [NSString stringWithString:[textView string]];
    
    // setup progress sheet
    NSAssert([textView window], @"The find target text view must be embedded in a window.");
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:-1];
    ProgressViewController *indicator = [[ProgressViewController alloc] initWithProgress:progress message:NSLocalizedString(@"Find All", nil)];
    [[[[textView window] windowController] contentViewController] presentViewControllerAsSheet:indicator];
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeof(self) self = weakSelf;
        if (!self) { return; }
        
        NSMutableArray<TextFindResult *> *results = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *highlights = [NSMutableArray array];
        
        __block NSUInteger lineNumber = 1;
        __block NSUInteger lineCountedLocation = 0;
        [self enumerateMatchsInString:string ranges:scopeRanges
                           usingBlock:^(NSRange matchedRange,
                                        NSTextCheckingResult * _Nullable match,
                                        BOOL * _Nonnull stop)
         {
             if ([progress isCancelled]) {
                 [indicator dismissController:self];
                 [[self busyTextViews] removeObject:textView];
                 *stop = YES;
                 return;
             }
             
             // calc line number
             NSRange diffRange = NSMakeRange(lineCountedLocation, matchedRange.location - lineCountedLocation);
             lineNumber += [lineRegex numberOfMatchesInString:string options:0 range:diffRange];
             lineCountedLocation = matchedRange.location;
             
             // highlight both string in textView and line string for result table
             NSRange lineRange = [string lineRangeForRange:matchedRange];
             NSRange inlineRange = matchedRange;
             inlineRange.location -= lineRange.location;
             NSString *lineString = [string substringWithRange:lineRange];
             NSMutableAttributedString *lineAttrString = [[NSMutableAttributedString alloc] initWithString:lineString];
             
             [lineAttrString addAttribute:NSBackgroundColorAttributeName value:[highlightColors firstObject] range:inlineRange];
             
             [highlights addObject:@{CEFindHighlightRange: [NSValue valueWithRange:matchedRange],
                                     CEFindHighlightColor: [highlightColors firstObject]}];
             
             if (match) {
                 for (NSUInteger i = 1; i < numberOfGroups + 1; i++) {
                     NSRange range = [match rangeAtIndex:i];
                     
                     if (range.length == 0) { continue; }
                     
                     NSColor *color = highlightColors[i];
                     
                     [lineAttrString addAttribute:NSBackgroundColorAttributeName value:color
                                            range:NSMakeRange(range.location - lineRange.location, range.length)];
                     [highlights addObject:@{CEFindHighlightRange: [NSValue valueWithRange:range],
                                             CEFindHighlightColor: color}];
                 }
             }
             
             [results addObject:[[TextFindResult alloc] initWithRange:matchedRange
                                                            lineRange:inlineRange
                                                           lineNumber:lineNumber
                                                 attributedLineString:lineAttrString]];
             
             NSString *informativeFormat = ([results count] == 1) ? @"%@ string found." : @"%@ strings found.";
             NSString *informative = [NSString stringWithFormat:NSLocalizedString(informativeFormat, nil),
                                      [integerFormatter stringFromNumber:@([results count])]];
             dispatch_async(dispatch_get_main_queue(), ^{
                 [progress setLocalizedDescription:informative];
             });
         } scopeCompletionHandler:nil];
        
        if ([progress isCancelled]) { return; }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // highlight
            [[textView layoutManager] removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, [string length])];
            for (NSDictionary<NSString *, id> *highlight in highlights) {
                [[textView layoutManager] addTemporaryAttribute:NSBackgroundColorAttributeName value:highlight[CEFindHighlightColor]
                                              forCharacterRange:[highlight[CEFindHighlightRange] rangeValue]];
            }
            
            [indicator doneWithButtonTitle:nil];
            
            if ([results count] > 0) {
                if ([[self delegate] respondsToSelector:@selector(textFinder:didFinishFindingAll:results:textView:)]) {
                    [[self delegate] textFinder:self didFinishFindingAll:findString results:results textView:textView];
                }
                
            } else {
                NSBeep();
                [progress setLocalizedDescription:NSLocalizedString(@"Not Found.", nil)];
            }
            
            // -> close also if matched since result view will be shown when succeed
            if ([results count] > 0 || [self closesIndicatorWhenDone]) {
                [indicator dismissController:self];
                if ([[[self findPanelController] window] isVisible]) {
                    [[[self findPanelController] window] makeKeyWindow];
                }
            }
            
            [[self busyTextViews] removeObject:textView];
        });
    });
    
    [self appendFindHistory:[self findString]];
}


// ------------------------------------------------------
/// highlight all matched strings
- (IBAction)highlight:(nullable id)sender
// ------------------------------------------------------
{
    if (![self checkIsReadyToFind]) { return; }
    
    NSNumberFormatter *integerFormatter = [self integerFormatter];
    NSTextView *textView = [self client];
    NSRegularExpression *regex = [self regex];
    NSArray<NSValue *> *scopeRanges = [self scopeRanges];
    
    [[self busyTextViews] addObject:textView];
    
    NSUInteger numberOfGroups = [regex numberOfCaptureGroups];
    NSArray<NSColor *> *highlightColors = [[self highlightColor] decompositeInto:numberOfGroups + 1];
    
    NSString *string = [NSString stringWithString:[textView string]];
    
    // setup progress sheet
    NSAssert([textView window], @"The find target text view must be embedded in a window.");
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:-1];
    ProgressViewController *indicator = [[ProgressViewController alloc] initWithProgress:progress message:NSLocalizedString(@"Highlight", nil)];
    [[[[textView window] windowController] contentViewController] presentViewControllerAsSheet:indicator];
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeof(self) self = weakSelf;
        if (!self) { return; }
        
        NSMutableArray<NSDictionary *> *highlights = [NSMutableArray array];
        [self enumerateMatchsInString:string ranges:scopeRanges
                           usingBlock:^(NSRange matchedRange,
                                        NSTextCheckingResult * _Nullable match,
                                        BOOL * _Nonnull stop)
         {
             if ([progress isCancelled]) {
                 [indicator dismissController:self];
                 [[self busyTextViews] removeObject:textView];
                 *stop = YES;
                 return;
             }
             
             [highlights addObject:@{CEFindHighlightRange: [NSValue valueWithRange:matchedRange],
                                     CEFindHighlightColor: [highlightColors firstObject]}];
             
             for (NSUInteger i = 1; i < numberOfGroups + 1; i++) {
                 NSRange range = [match rangeAtIndex:i];
                 
                 if (range.length == 0) { continue; }
                 
                 NSColor *color = highlightColors[i];
                 [highlights addObject:@{CEFindHighlightRange: [NSValue valueWithRange:range],
                                         CEFindHighlightColor: color}];
             }
             
             NSString *informativeFormat = ([highlights count] == 1) ? @"%@ string found." : @"%@ strings found.";
             NSString *informative = [NSString stringWithFormat:NSLocalizedString(informativeFormat, nil),
                                      [integerFormatter stringFromNumber:@([highlights count])]];
             dispatch_async(dispatch_get_main_queue(), ^{
                 [progress setLocalizedDescription:informative];
             });
         } scopeCompletionHandler:nil];
        
        if ([progress isCancelled]) { return; }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // highlight
            [[textView layoutManager] removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, [string length])];
            for (NSDictionary<NSString *, id> *highlight in highlights) {
                [[textView layoutManager] addTemporaryAttribute:NSBackgroundColorAttributeName value:highlight[CEFindHighlightColor]
                                              forCharacterRange:[highlight[CEFindHighlightRange] rangeValue]];
            }
            
            [indicator doneWithButtonTitle:nil];
            
            if ([highlights count] == 0) {
                NSBeep();
                [progress setLocalizedDescription:NSLocalizedString(@"Not Found", nil)];
            }
            
            if ([self closesIndicatorWhenDone]) {
                [indicator dismissController:self];
                if ([[[self findPanelController] window] isVisible]) {
                    [[[self findPanelController] window] makeKeyWindow];
                }
            }
            
            [[self busyTextViews] removeObject:textView];
        });
    });
    
    [self appendFindHistory:[self findString]];
}


// ------------------------------------------------------
/// remove all of current highlights in the frontmost textView
- (IBAction)unhighlight:(nullable id)sender
// ------------------------------------------------------
{
    NSTextView *textView = [self client];
    [[textView layoutManager] removeTemporaryAttribute:NSBackgroundColorAttributeName
                                     forCharacterRange:NSMakeRange(0, [[textView string] length])];
}


// ------------------------------------------------------
/// replace matched string in selection with replacementStirng
- (IBAction)replace:(nullable id)sender
// ------------------------------------------------------
{
    if (![self checkIsReadyToFind]) { return; }
    
    BOOL success = [self replace];
    if (!success) {
        NSBeep();
    } else {
        [[self client] scrollRangeToVisible:[[self client] selectedRange]];
    }
    
    [self appendFindHistory:[self findString]];
    [self appendReplaceHistory:[self replacementString]];
}


// ------------------------------------------------------
/// replace matched string with replacementStirng and select the next match
- (IBAction)replaceAndFind:(nullable id)sender
// ------------------------------------------------------
{
    if (![self checkIsReadyToFind]) { return; }
    
    [self replace];  // don't care if succeed
    [self findForward:YES];
}


// ------------------------------------------------------
/// replace all matched strings with given string
- (IBAction)replaceAll:(nullable id)sender
// ------------------------------------------------------
{
    if (![self checkIsReadyToFind]) { return; }
    
    NSNumberFormatter *integerFormatter = [self integerFormatter];
    NSTextView *textView = [self client];
    NSString *replacementString = [self replacementString];
    NSString *template = [self replacementString] ?: @"";
    NSArray<NSValue *> *scopeRanges = [self scopeRanges];
    BOOL inSelection = [self inSelection];
    
    [[self busyTextViews] addObject:textView];
    
    NSString *string = [NSString stringWithString:[textView string]];
    
    // setup progress sheet
    NSAssert([textView window], @"The find target text view must be embedded in a window.");
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:-1];
    ProgressViewController *indicator = [[ProgressViewController alloc] initWithProgress:progress message:NSLocalizedString(@"Replace All", nil)];
    [[[[textView window] windowController] contentViewController] presentViewControllerAsSheet:indicator];
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeof(self) self = weakSelf;
        if (!self) { return; }
        
        NSMutableArray<NSString *> *replacementStrings = [NSMutableArray array];
        NSMutableArray<NSValue *> *replacementRanges = [NSMutableArray array];
        NSMutableArray<NSValue *> *selectedRanges = [NSMutableArray array];
        __block NSUInteger count = 0;
        
        // variables to calcurate new selection ranges
        __block NSInteger locationDelta = 0;
        __block NSInteger lengthDelta = 0;
        
        [self enumerateMatchsInString:string ranges:scopeRanges
                           usingBlock:^(NSRange matchedRange,
                                        NSTextCheckingResult * _Nullable match,
                                        BOOL * _Nonnull stop)
         {
             if ([progress isCancelled]) {
                 [indicator dismissController:self];
                 [[self busyTextViews] removeObject:textView];
                 *stop = YES;
                 return;
             }
             
             NSString *replacedString;
             if (match) {
                 replacedString = [[match regularExpression] replacementStringForResult:match inString:string offset:0 template:template];
             } else {
                 replacedString = replacementString;
             }
             
             [replacementStrings addObject:replacedString];
             [replacementRanges addObject:[NSValue valueWithRange:matchedRange]];
             count++;
             
             lengthDelta -= (NSInteger)matchedRange.length - [replacedString length];
             
             NSString *informativeFormat = (count == 1) ? @"%@ string replaced." : @"%@ strings replaced.";
             NSString *informative = [NSString stringWithFormat:NSLocalizedString(informativeFormat, nil),
                                      [integerFormatter stringFromNumber:@(count)]];
             dispatch_async(dispatch_get_main_queue(), ^{
                 [progress setLocalizedDescription:informative];
             });
             
         } scopeCompletionHandler:^(NSRange scopeRange) {
             NSRange selectedRange = NSMakeRange(scopeRange.location + locationDelta,
                                                 scopeRange.length + lengthDelta);
             locationDelta += (NSInteger)selectedRange.length - scopeRange.length;
             lengthDelta = 0;
             [selectedRanges addObject:[NSValue valueWithRange:selectedRange]];
         }];
        
        if ([progress isCancelled]) { NSLog(@"cancel"); return; }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [indicator doneWithButtonTitle:nil];
            
            if (count > 0) {
                // apply found strings to the text view
                [textView replaceWithStrings:replacementStrings ranges:replacementRanges
                              selectedRanges:inSelection ? selectedRanges : nil
                                  actionName:NSLocalizedString(@"Replace All", nil)];
                
            } else {
                NSBeep();
                [progress setLocalizedDescription:NSLocalizedString(@"Not Found", nil)];
            }
            
            if ([self closesIndicatorWhenDone]) {
                [indicator dismissController:self];
                if ([[[self findPanelController] window] isVisible]) {
                    [[[self findPanelController] window] makeKeyWindow];
                }
            }
            
            [[self busyTextViews] removeObject:textView];
        });
    });
    
    [self appendFindHistory:[self findString]];
    [self appendReplaceHistory:[self replacementString]];
}


// ------------------------------------------------------
/// set selected string to find field
- (IBAction)useSelectionForFind:(nullable id)sender
// ------------------------------------------------------
{
    NSString *selectedString = [self selectedString];
    
    if (selectedString) {
        [self setFindString:selectedString];
        
        // auto-disable regex
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:CEDefaultFindUsesRegularExpressionKey];
        
    } else {
        NSBeep();
    }
}


// ------------------------------------------------------
/// set selected string to replace field
- (IBAction)useSelectionForReplace:(nullable id)sender
// ------------------------------------------------------
{
    NSString *selectedString = [self selectedString] ?: @"";
    
    [self setReplacementString:selectedString];
}


// ------------------------------------------------------
/// jump to selection in client
- (IBAction)centerSelectionInVisibleArea:(nullable id)sender
// ------------------------------------------------------
{
    [[self client] centerSelectionInVisibleArea:sender];
}



#pragma mark Private Methods

// ------------------------------------------------------
/// lazy creation of panel controller
- (__kindof NSWindowController *)findPanelController
// ------------------------------------------------------
{
    if (!_findPanelController) {
        _findPanelController = [[NSStoryboard storyboardWithName:@"FindPanel" bundle:nil] instantiateInitialController];
        
    }
    return _findPanelController;
}


// ------------------------------------------------------
/// target text view
- (nullable NSTextView *)client
// ------------------------------------------------------
{
    id<CETextFinderClientProvider> provider = [NSApp targetForAction:@selector(textFinderClient)];
    if (provider) {
        return [provider textFinderClient];
    }
    
    return nil;
}


// ------------------------------------------------------
/// selected string in the current tareget
- (nullable NSString *)selectedString
// ------------------------------------------------------
{
    NSRange selectedRange = [[self client] selectedRange];
    
    if (selectedRange.length == 0) { return nil; }
    
    return [[[self client] string] substringWithRange:selectedRange];
}


// ------------------------------------------------------
/// ranges to find in
- (NSArray<NSValue *> *)scopeRanges
// ------------------------------------------------------
{
    NSTextView *textView = [self client];
    
    return [self inSelection] ? [textView selectedRanges] : @[[NSValue valueWithRange:NSMakeRange(0, [[textView string] length])]];
}


// ------------------------------------------------------
/// find string of which line endings are standardized to LF
- (NSString *)sanitizedFindString
// ------------------------------------------------------
{
    // TODO: ```return self.findString.replacingLineEndings(with: .LF)```
    
    NSString *string = [self findString];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\r\\n|[\\n\\r\\u2028\\u2029]"
                                                                           options:0 error:nil];
    return [regex stringByReplacingMatchesInString:string
                                           options:0
                                             range:NSMakeRange(0, [string length])
                                      withTemplate:@"\n"];
}


// ------------------------------------------------------
/// regex object with current settings
- (nullable NSRegularExpression *)regex
// ------------------------------------------------------
{
    return [NSRegularExpression regularExpressionWithPattern:[self sanitizedFindString]
                                                     options:[self regexOptions]
                                                       error:nil];
}


// ------------------------------------------------------
/// perform "Find Next" or "Find Previous" and return number of found
- (NSUInteger)findForward:(BOOL)forward
// ------------------------------------------------------
{
    if (![self checkIsReadyToFind]) { return 0; }
    
    NSTextView *textView = [self client];
    NSString *string = [textView string];
    NSUInteger startLocation = forward ? NSMaxRange([textView selectedRange]) : [textView selectedRange].location;
    
    NSRange range = NSMakeRange(0, [string length]);
    
    if (range.length == 0) { return 0; }
    
    NSMutableArray *matches = [NSMutableArray array];
    [self enumerateMatchsInString:string ranges:@[[NSValue valueWithRange:range]]
                       usingBlock:^(NSRange matchedRange,
                                    NSTextCheckingResult * _Nullable match,
                                    BOOL * _Nonnull stop)
     {
         [matches addObject:[NSValue valueWithRange:matchedRange]];
     } scopeCompletionHandler:nil];
    
    NSRange foundRange = NSMakeRange(NSNotFound, 0);
    
    if ([matches count] == 0) { return 0; }
    
    NSRange lastMatchedRange = NSMakeRange(NSNotFound, 0);
    for (NSValue *match in matches) {
        NSRange matchedRange = [match rangeValue];
        
        if (matchedRange.location >= startLocation) {
            foundRange = forward ? matchedRange : lastMatchedRange;
            break;
        }
        
        lastMatchedRange = matchedRange;
    }
    
    // wrap search
    BOOL isWrapped = NO;
    if (foundRange.location == NSNotFound && [self isWrap]) {
        foundRange = forward ? [[matches firstObject] rangeValue] : [[matches lastObject] rangeValue];
        isWrapped = YES;
    }
    
    // found feedback
    if (foundRange.location != NSNotFound) {
        [textView setSelectedRange:foundRange];
        [textView scrollRangeToVisible:foundRange];
        [textView showFindIndicatorForRange:foundRange];
        
        if (isWrapped) {
            HUDController *hudController = [[HUDController alloc] initWithSymbol:HUDSymbolWrap];
            [hudController setIsReversed:!forward];
            [hudController showIn:[[textView enclosingScrollView] superview]];
        }
    } else {
        NSBeep();
    }
    if ([[self delegate] respondsToSelector:@selector(textFinder:didFound:textView:)]) {
        [[self delegate] textFinder:self didFound:[matches count] textView:textView];
    }
    
    [self appendFindHistory:[self findString]];
    
    return [matches count];
}


// ------------------------------------------------------
/// replace matched string in selection with replacementStirng
- (BOOL)replace
// ------------------------------------------------------
{
    NSTextView *textView = [self client];
    NSString *string = [textView string];
    
    if ([string length] == 0) { return NO; }
    
    NSRange matchedRange;
    NSString *replacedString;
    if ([self usesRegularExpression]) {
        NSRegularExpression *regex = [self regex];
        NSTextCheckingResult *match = [regex firstMatchInString:string
                                                        options:0
                                                          range:[textView selectedRange]];
        
        if (!match) { return NO; }
        
        matchedRange = [match range];
        replacedString = [regex replacementStringForResult:match
                                                  inString:string
                                                    offset:0
                                                  template:[self replacementString] ?: @""];
        
    } else {
        matchedRange = [[textView string] rangeOfString:[self sanitizedFindString]
                                                options:[self textualOptions]
                                                  range:[textView selectedRange]];
        
        if (matchedRange.location == NSNotFound) { return NO; }
        
        replacedString = [self replacementString] ?: @"";
    }
    
    // apply replacement to text view
//    return [textView replaceWithString:replacedString range:matchedRange
//                         selectedRange:NSMakeRange(matchedRange.location, [replacedString length])  // TODO: use single replacement func
//                            actionName:NSLocalizedString(@"Replace", nil)];
    return [textView replaceWithStrings:@[replacedString] ranges:@[[NSValue valueWithRange: matchedRange]]
                         selectedRanges:@[[NSValue valueWithRange: NSMakeRange(matchedRange.location, [replacedString length])]]
                                          actionName:NSLocalizedString(@"Replace", nil)];
}


// ------------------------------------------------------
/// enumerate matchs in string using current settings
- (void)enumerateMatchsInString:(nullable NSString *)string ranges:(NSArray<NSValue *> *)ranges usingBlock:(nonnull void (^)(NSRange matchedRange, NSTextCheckingResult * _Nullable match, BOOL * _Nonnull stop))block scopeCompletionHandler:(nullable void (^)(NSRange scopeRange))scopeCompletionHandler
// ------------------------------------------------------
{
    if ([self usesRegularExpression]) {
        [self enumerateRegularExpressionMatchsInString:string ranges:ranges usingBlock:block scopeCompletionHandler:scopeCompletionHandler];
    } else {
        [self enumerateTextualMatchsInString:string ranges:ranges usingBlock:block scopeCompletionHandler:scopeCompletionHandler];
    }
}


// ------------------------------------------------------
/// enumerate matchs in string using textual search
- (void)enumerateTextualMatchsInString:(nullable NSString *)string ranges:(NSArray<NSValue *> *)ranges usingBlock:(nonnull void (^)(NSRange matchedRange, NSTextCheckingResult * _Nullable match, BOOL * _Nonnull stop))block scopeCompletionHandler:(nullable void (^)(NSRange scopeRange))scopeCompletionHandler
// ------------------------------------------------------
{
    if ([string length] == 0) { return; }
    
    NSString *findString = [self sanitizedFindString];
    NSStringCompareOptions options = [self textualOptions];
    
    for (NSValue *rangeValue in ranges) {
        NSRange scopeRange = [rangeValue rangeValue];
        
        NSRange searchRange = scopeRange;
        while (searchRange.location != NSNotFound) {
            searchRange.length = string.length - searchRange.location;
            NSRange foundRange = [string rangeOfString:findString options:options range:searchRange];
            
            if (NSMaxRange(foundRange) > NSMaxRange(scopeRange)) { break; }
            
            BOOL stop = NO;
            block(foundRange, nil, &stop);
            
            if (stop) { return; }
            
            searchRange.location = NSMaxRange(foundRange);
        }
        
        if (scopeCompletionHandler) {
            scopeCompletionHandler(scopeRange);
        }
    }
}


// ------------------------------------------------------
/// enumerate matchs in string using regular expression
- (void)enumerateRegularExpressionMatchsInString:(nullable NSString *)string ranges:(NSArray<NSValue *> *)ranges usingBlock:(nonnull void (^)(NSRange matchedRange, NSTextCheckingResult * _Nullable match, BOOL * _Nonnull stop))block scopeCompletionHandler:(nullable void (^)(NSRange scopeRange))scopeCompletionHandler
// ------------------------------------------------------
{
    if ([string length] == 0) { return; }
    
    NSRegularExpression *regex = [self regex];
    
    for (NSValue *rangeValue in ranges) {
        NSRange scopeRange = [rangeValue rangeValue];
        [regex enumerateMatchesInString:string options:0 range:scopeRange
                             usingBlock:^(NSTextCheckingResult * _Nullable result,
                                          NSMatchingFlags flags,
                                          BOOL * _Nonnull stop)
         {
             block([result range], result, stop);
         }];
        
        if (scopeCompletionHandler) {
            scopeCompletionHandler(scopeRange);
        }
    }
}


// ------------------------------------------------------
/// check Find can be performed and alert if needed
- (BOOL)checkIsReadyToFind
// ------------------------------------------------------
{
    if (![self client]) {
        NSBeep();
        return NO;
    }
    
    if ([[self busyTextViews] containsObject:[self client]]) {
        NSBeep();
        return NO;
    }
    
    NSWindow *findPanel = [[self findPanelController] window];
    if ([findPanel attachedSheet]) {
        [self.findPanelController showWindow:self];
        NSBeep();
        return NO;
    }
    
    if ([[self findString] length] == 0) {
        NSBeep();
        return NO;
    }
    
    // check regular expression syntax
    if ([self usesRegularExpression]) {
        // try compile regex
        NSError *error;
        [NSRegularExpression regularExpressionWithPattern:[self sanitizedFindString]
                                                  options:[self regexOptions]
                                                    error:&error];
        
        // show error alert if invalid
        if (error) {
            NSDictionary<NSString *, id> *userInfo = nil;
            userInfo = @{NSLocalizedDescriptionKey: NSLocalizedString(@"Invalid regular expression", nil),
                         NSLocalizedRecoverySuggestionErrorKey: [error localizedFailureReason],
                         NSUnderlyingErrorKey: error};

            NSError *error = [NSError errorWithDomain:CEErrorDomain code:CERegularExpressionError userInfo:userInfo];
            [[self findPanelController] showWindow:self];
            [self presentError:error modalForWindow:[[self findPanelController] window] delegate:nil didPresentSelector:NULL contextInfo:NULL];
            NSBeep();
            
            return NO;
        }
    }
    
    return YES;
}


// ------------------------------------------------------
/// load find string from global domain
- (nullable NSString *)findStringFromPasteboard
// ------------------------------------------------------
{
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSFindPboard];
    
    return [pasteboard stringForType:NSStringPboardType];
}


// ------------------------------------------------------
/// put local find string to global domain
- (void)setFindStringToPasteboard:(nonnull NSString *)string
// ------------------------------------------------------
{
    if ([string length] == 0) { return; }
    
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSFindPboard];
    
    [pasteboard declareTypes:@[NSStringPboardType] owner:nil];
    [pasteboard setString:string forType:NSStringPboardType];
}


// ------------------------------------------------------
/// append given string to find history
- (void)appendFindHistory:(nonnull NSString *)string
// ------------------------------------------------------
{
    if ([string length] == 0) { return; }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // append new string to history
    NSMutableArray<NSString *> *history = [NSMutableArray arrayWithArray:[defaults stringArrayForKey:CEDefaultFindHistoryKey]];
    [history removeObject:string];  // remove duplicated item
    [history addObject:string];
    if ([history count] > kMaxHistorySize) {  // remove overflow
        [history removeObjectsInRange:NSMakeRange(0, [history count] - kMaxHistorySize)];
    }
    
    [defaults setObject:history forKey:CEDefaultFindHistoryKey];
}


// ------------------------------------------------------
/// append given string to replace history
- (void)appendReplaceHistory:(nonnull NSString *)string
// ------------------------------------------------------
{
    if ([string length] == 0) { return; }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // append new string to history
    NSMutableArray<NSString *> *history = [NSMutableArray arrayWithArray:[defaults stringArrayForKey:CEDefaultReplaceHistoryKey]];
    [history removeObject:string];  // remove duplicated item
    [history addObject:string];
    if ([history count] > kMaxHistorySize) {  // remove overflow
        [history removeObjectsInRange:NSMakeRange(0, [history count] - kMaxHistorySize)];
    }
    
    [defaults setObject:history forKey:CEDefaultReplaceHistoryKey];
}



#pragma mark Private Dynamic Accessors

// ------------------------------------------------------
/// return value from user defaults
- (BOOL)usesRegularExpression
// ------------------------------------------------------
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultFindUsesRegularExpressionKey];
}


// ------------------------------------------------------
/// return value from user defaults
- (BOOL)isWrap
// ------------------------------------------------------
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultFindIsWrapKey];
}


// ------------------------------------------------------
/// return value from user defaults
- (BOOL)inSelection
// ------------------------------------------------------
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultFindInSelectionKey];
}


// ------------------------------------------------------
/// return value from user defaults
- (NSStringCompareOptions)textualOptions
// ------------------------------------------------------
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSStringCompareOptions options = 0;
    
    if ([defaults boolForKey:CEDefaultFindIgnoresCaseKey])               { options |= NSCaseInsensitiveSearch; }
    if ([defaults boolForKey:CEDefaultFindTextIsLiteralSearchKey])       { options |= NSLiteralSearch; }
    if ([defaults boolForKey:CEDefaultFindTextIgnoresDiacriticMarksKey]) { options |= NSDiacriticInsensitiveSearch; }
    if ([defaults boolForKey:CEDefaultFindTextIgnoresWidthKey])          { options |= NSWidthInsensitiveSearch; }
    
    return options;
}


// ------------------------------------------------------
/// return value from user defaults
- (NSRegularExpressionOptions)regexOptions
// ------------------------------------------------------
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSRegularExpressionOptions options = 0;
    
    if ([defaults boolForKey:CEDefaultFindIgnoresCaseKey])                { options |= NSRegularExpressionCaseInsensitive; }
    if ([defaults boolForKey:CEDefaultFindRegexIsSinglelineKey])          { options |= NSRegularExpressionDotMatchesLineSeparators; }
    if ([defaults boolForKey:CEDefaultFindRegexIsMultilineKey])           { options |= NSRegularExpressionAnchorsMatchLines; }
    if ([defaults boolForKey:CEDefaultFindRegexUsesUnicodeBoundariesKey]) { options |= NSRegularExpressionUseUnicodeWordBoundaries; }
    
    return options;
}


// ------------------------------------------------------
/// return value from user defaults
- (BOOL)closesIndicatorWhenDone
// ------------------------------------------------------
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:CEDefaultFindClosesIndicatorWhenDoneKey];
}

@end
