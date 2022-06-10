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

internal struct TrackSettings: Equatable {

    let enabled: Bool
    let dimensions: Dimensions
    let videoQuality: VideoQuality

    init(enabled: Bool = false,
         dimensions: Dimensions = .zero,
         videoQuality: VideoQuality = .low) {

        self.enabled = enabled
        self.dimensions = dimensions
        self.videoQuality = videoQuality
    }

    func copyWith(enabled: Bool? = nil,
                  dimensions: Dimensions? = nil,
                  videoQuality: VideoQuality? = nil) -> TrackSettings {
        TrackSettings(enabled: enabled ?? self.enabled,
                      dimensions: dimensions ?? self.dimensions,
                      videoQuality: videoQuality ?? self.videoQuality)
    }
}
