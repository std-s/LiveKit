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

import Foundation
import SwiftLog
import Promises
import WebRTC

//internal let logger = Logger(label: "LiveKitSDK")

/// The open source platform for real-time communication.
///
/// See [LiveKit's Online Docs](https://docs.livekit.io/) for more information.
///
/// Comments are written in [DocC](https://developer.apple.com/documentation/docc) compatible format.
/// With Xcode 13 and above you can build documentation right into your Xcode documentation viewer by chosing
/// **Product** >  **Build Documentation** from Xcode's menu.
///
/// Download the [Multiplatform SwiftUI Example](https://github.com/livekit/multiplatform-swiftui-example)
/// to try out the features.
public class LiveKit {

    public static let version = "1.0.0"

    public static func connect(
        _ url: String,
        _ token: String,
        delegate: RoomDelegate? = nil,
        connectOptions: ConnectOptions = ConnectOptions(),
        roomOptions: RoomOptions = RoomOptions()) -> Promise<Room> {

        let room = Room(delegate: delegate,
                        connectOptions: connectOptions,
                        roomOptions: roomOptions)

        return room.connect(url, token)
    }
}
