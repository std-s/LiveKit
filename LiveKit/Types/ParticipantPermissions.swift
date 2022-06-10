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

public struct ParticipantPermissions: Equatable {

    let canSubscribe: Bool
    /// allow participant to publish new tracks to room
    let canPublish: Bool
    /// allow participant to publish data
    let canPublishData: Bool
    /// indicates that it's hidden to others
    let hidden: Bool
    /// indicates it's a recorder instance
    let recorder: Bool

    public init(canSubscribe: Bool = false,
                canPublish: Bool = false,
                canPublishData: Bool = false,
                hidden: Bool = false,
                recorder: Bool = false) {

        self.canSubscribe = canSubscribe
        self.canPublish = canPublish
        self.canPublishData = canPublishData
        self.hidden = hidden
        self.recorder = recorder
    }

    public static func == (lhs: ParticipantPermissions, rhs: ParticipantPermissions) -> Bool {
        return lhs.canSubscribe == rhs.canSubscribe &&
            lhs.canPublish == rhs.canPublish &&
            lhs.canPublishData == rhs.canPublishData &&
            lhs.hidden == rhs.hidden &&
            lhs.recorder == rhs.recorder
    }
}

extension Livekit_ParticipantPermission {

    func toLKType() -> ParticipantPermissions {
        ParticipantPermissions(canSubscribe: canSubscribe,
                               canPublish: canPublish,
                               canPublishData: canPublishData,
                               hidden: hidden,
                               recorder: recorder)
    }
}
