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
import WebRTC
import Promises
import ReplayKit
//import OrderedCollections

public class CameraCapturer: VideoCapturer {

    private let capturer: RTCCameraVideoCapturer

    public static func captureDevices() -> [AVCaptureDevice] {
        DispatchQueue.webRTC.sync { RTCCameraVideoCapturer.captureDevices() }
    }

    /// Checks whether both front and back capturing devices exist, and can be switched.
    public static func canSwitchPosition() -> Bool {
        let devices = captureDevices()
        return devices.contains(where: { $0.position == .front }) &&
            devices.contains(where: { $0.position == .back })
    }

    /// Current device used for capturing
    public private(set) var device: AVCaptureDevice?

    /// Current position of the device
    public var position: AVCaptureDevice.Position? {
        device?.position
    }

    public var options: CameraCaptureOptions

    init(delegate: RTCVideoCapturerDelegate, options: CameraCaptureOptions) {
        self.capturer = DispatchQueue.webRTC.sync { RTCCameraVideoCapturer(delegate: delegate) }
        self.options = options
        super.init(delegate: delegate)
    }

    /// Switches the camera position between `.front` and `.back` if supported by the device.
    @discardableResult
    public func switchCameraPosition() -> Promise<Bool> {
        // cannot toggle if current position is unknown
        guard position != .unspecified else {
            return Promise(TrackError.state(message: "Camera position unknown"))
        }

        return setCameraPosition(position == .front ? .back : .front)
    }

    /// Sets the camera's position to `.front` or `.back` when supported
    public func setCameraPosition(_ position: AVCaptureDevice.Position) -> Promise<Bool> {

        print("setCameraPosition(position: \(position)")

        // update options to use new position
        options = options.copyWith(position: position)

        // restart capturer
        return restartCapture()
    }

    public override func startCapture() -> Promise<Bool> {

        super.startCapture().then(on: .sdk) { didStart -> Promise<Bool> in

            guard didStart else {
                // already started
                return Promise(false)
            }

            let preferredPixelFormat = self.capturer.preferredOutputPixelFormat()
            print("CameraCapturer.preferredPixelFormat: \(preferredPixelFormat.toString())")

            let devices = CameraCapturer.captureDevices()
            // TODO: FaceTime Camera for macOS uses .unspecified, fall back to first device

            guard let device = devices.first(where: { $0.position == self.options.position }) ?? devices.first else {
                throw TrackError.capturer(message: "No camera video capture devices available")
            }

            // list of all formats in order of dimensions size
            let formats = DispatchQueue.webRTC.sync { RTCCameraVideoCapturer.supportedFormats(for: device) }
            // create a dictionary sorted by dimensions size
            let sortedFormats = OrderedDictionary(uniqueKeysWithValues: formats.map { ($0, CMVideoFormatDescriptionGetDimensions($0.formatDescription)) })
                .sorted { $0.value.area < $1.value.area }

            // default to the smallest
            var selectedFormat = sortedFormats.first

            // find preferred capture format if specified in options
            if let preferredFormat = self.options.preferredFormat,
               let foundFormat = sortedFormats.first(where: { $0.key == preferredFormat }) {
                selectedFormat = foundFormat
            } else {
                print("formats: \(sortedFormats.map { String(describing: $0.value) }), target: \(self.options.dimensions)")
                // find format that satisfies preferred dimensions
                selectedFormat = sortedFormats.first(where: { $0.value.area >= self.options.dimensions.area })
            }

            // format should be resolved at this point
            guard let selectedFormat = selectedFormat else {
                throw TrackError.capturer(message: "Unable to determine format for camera capturer")
            }

            guard let fpsRange = selectedFormat.key.fpsRange() else {
                throw TrackError.capturer(message: "Unable to determine supported fps range for format: \(selectedFormat)")
            }

            // default to fps in options
            var selectedFps = self.options.fps

            if !fpsRange.contains(selectedFps) {
                // log a warning, but continue
                // clamp to supported fps range
                selectedFps = selectedFps.clamped(to: fpsRange)
            }

            // adapt if requested dimensions and camera's dimensions don't match
            if let videoSource = self.delegate as? RTCVideoSource,
               selectedFormat.value != self.options.dimensions {

                // print("adaptOutputFormat to: \(options.dimensions) fps: \(self.options.fps)")
                videoSource.adaptOutputFormat(toWidth: self.options.dimensions.width,
                                              height: self.options.dimensions.height,
                                              fps: Int32(self.options.fps))
            }

            // return promise that waits for capturer to start
            return Promise<Bool>(on: .webRTC) { resolve, fail in
                // start the RTCCameraVideoCapturer
                self.capturer.startCapture(with: device, format: selectedFormat.key, fps: selectedFps) { error in
                    if let error = error {
                        fail(error)
                        return
                    }

                    // update internal vars
                    self.device = device
                    // this will trigger to re-compute encodings for sender parameters if dimensions have updated
                    self.dimensions = self.options.dimensions

                    // successfully started
                    resolve(true)
                }
            }
        }
    }

    public override func stopCapture() -> Promise<Bool> {

        super.stopCapture().then(on: .sdk) { didStop -> Promise<Bool> in

            guard didStop else {
                // already stopped
                return Promise(false)
            }

            return Promise<Bool>(on: .webRTC) { resolve, _ in
                // stop the RTCCameraVideoCapturer
                self.capturer.stopCapture {
                    // update internal vars
                    self.device = nil
                    self.dimensions = nil

                    // successfully stopped
                    resolve(true)
                }
            }
        }
    }
}

extension LocalVideoTrack {

    public static func createCameraTrack(name: String = Track.cameraName,
                                         options: CameraCaptureOptions = CameraCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: false)
        let capturer = CameraCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: name,
            source: .camera,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}

extension AVCaptureDevice.Position: CustomStringConvertible {
    public var description: String {
        switch self {
        case .front: return ".front"
        case .back: return ".back"
        case .unspecified: return ".unspecified"
        default: return "unknown"
        }
    }
}

extension Comparable {

    // clamp a value within the range
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension AVFrameRateRange {

    // convert to a ClosedRange
    func toRange() -> ClosedRange<Int> {
        Int(minFrameRate)...Int(maxFrameRate)
    }
}

extension AVCaptureDevice.Format {

    // computes a ClosedRange of supported FPSs for this format
    func fpsRange() -> ClosedRange<Int>? {

        videoSupportedFrameRateRanges.map { $0.toRange() }.reduce(into: nil as ClosedRange<Int>?) { result, current in
            // first element
            guard let previous = result else {
                result = current
                return
            }

            // merge previous element
            result = merge(range: previous, with: current)
        }
    }
}
