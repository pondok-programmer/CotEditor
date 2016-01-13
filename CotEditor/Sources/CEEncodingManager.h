/*
 
 CEEncodingManager.h
 
 CotEditor
 http://coteditor.com
 
 Created by 1024jp on 2014-09-24.

 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2016 1024jp
 
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

@import Cocoa;


// notifications
/// Posted when current encoding list menu items is ready to build
extern NSString *_Nonnull const CEEncodingListDidUpdateNotification;


@interface CEEncodingManager : NSObject

@property (readonly, nonatomic, nonnull, copy) NSArray<NSMenuItem *> *encodingMenuItems;


// singleton
+ (nonnull CEEncodingManager *)sharedManager;

/// returns corresponding NSStringEncoding from a encoding name
+ (NSStringEncoding)encodingFromName:(nonnull NSString *)encodingName;

/// whether Yen sign (U+00A5) can be converted to the given encoding
+ (BOOL)isInvalidYenEncoding:(NSStringEncoding)encoding;

@end
