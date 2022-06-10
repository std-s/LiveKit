/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import <WebRTC/RTCMacros.h>
#import <WebRTC/RTCVideoCapturer.h>

NS_ASSUME_NONNULL_BEGIN

RTC_OBJC_EXPORT
@protocol RTC_OBJC_TYPE
(DesktopCapturerDelegate)<NSObject> -
    (void)didCaptureVideoFrame
    : (RTC_OBJC_TYPE(RTCVideoFrame) *)frame;
@end

typedef NS_ENUM(NSInteger, RTCDesktopCapturerType) {
  RTCDesktopCapturerTypeScreen,
  RTCDesktopCapturerTypeWindow,
};

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCDesktopCapturerSource) : NSObject

@property(retain, nonatomic) NSString *sourceId;

@property(retain, nonatomic) NSString *name;

@property(nonatomic) RTCDesktopCapturerType type;

@property(retain, nonatomic) RTC_OBJC_TYPE(RTCVideoFrame) *thumbnail;

@end


RTC_OBJC_EXPORT
// Screen capture that implements RTCVideoCapturer. Delivers frames to a
// RTCVideoCapturerDelegate (usually RTCVideoSource).
@interface RTC_OBJC_TYPE (RTCDesktopCapturer) : RTC_OBJC_TYPE(RTCVideoCapturer)

- (instancetype)initWithDelegate:(__weak id<RTC_OBJC_TYPE(RTCVideoCapturerDelegate)>)delegate type:(RTCDesktopCapturerType)type;

// Starts the capture session asynchronously.
- (void)startCapture:(NSString *)sourceId fps:(NSInteger)fps;

// Stops the capture session asynchronously.
- (void)stopCapture;

- (NSArray<RTC_OBJC_TYPE(RTCDesktopCapturerSource) *> *) getSources;

@end

NS_ASSUME_NONNULL_END
