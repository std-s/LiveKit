/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import WebRTC

public protocol VideoTrack: Track {

}

extension VideoTrack {

    public func add(videoView: VideoView) {

        // should always be on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            return
        }

        guard !videoViews.contains(weakElement: videoView) else {
            return
        }

        while let otherVideoView = videoViews.allObjects.first(where: { $0 != videoView }) {
            videoTrack.remove(otherVideoView)
            videoViews.remove(weakElement: otherVideoView)
        }

        assert(videoViews.allObjects.count <= 1, "multiple VideoViews attached")

        videoTrack.add(videoView)
        videoViews.add(weakElement: videoView)
    }

    public func remove(videoView: VideoView) {

        // should always be on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoViews.remove(weakElement: videoView)

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            return
        }

        videoTrack.remove(videoView)
    }

    @available(*, deprecated, message: "Use add(videoView:) instead")
    public func add(renderer: VideoView) {
        add(videoView: renderer)
    }

    @available(*, deprecated, message: "Use remove(videoView:) instead")
    public func remove(renderer: VideoView) {
        remove(videoView: renderer)
    }
}
