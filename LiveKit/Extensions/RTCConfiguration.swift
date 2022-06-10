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

extension RTCConfiguration {

    public static let defaultIceServers = ["stun:stun.l.google.com:19302",
                                           "stun:stun1.l.google.com:19302"]

    public static func liveKitDefault() -> RTCConfiguration {

        let result = DispatchQueue.webRTC.sync { RTCConfiguration() }
        result.sdpSemantics = .unifiedPlan
        result.continualGatheringPolicy = .gatherContinually
        result.candidateNetworkPolicy = .all
        // don't send TCP candidates, they are passive and only server should be sending
        result.tcpCandidatePolicy = .disabled
        result.iceTransportPolicy = .all

        result.iceServers = [ DispatchQueue.webRTC.sync { RTCIceServer(urlStrings: defaultIceServers) } ]

        return result
    }

    internal func set(iceServers: [Livekit_ICEServer]) {

        // convert to a list of RTCIceServer
        let rtcIceServers = iceServers.map { $0.toRTCType() }

        if !rtcIceServers.isEmpty {
            // set new iceServers if not empty
            self.iceServers = rtcIceServers
        }
    }
}
