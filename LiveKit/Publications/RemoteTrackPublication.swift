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
import CoreGraphics
import Promises
import WebRTC

public enum SubscriptionState {
    case subscribed
    case notAllowed
    case unsubscribed
}

public class RemoteTrackPublication: TrackPublication {

    public var subscriptionAllowed: Bool { _state.subscriptionAllowed }
    public var enabled: Bool { _state.trackSettings.enabled }
    override public var muted: Bool { track?.muted ?? metadataMuted }
    public var streamState: StreamState { _state.streamState }

    // MARK: - Private

    // user's preference to subscribe or not
    private var preferSubscribed: Bool?
    private var metadataMuted: Bool = false

    // adaptiveStream
    // this must be on .main queue
    private var asTimer = DispatchQueueTimer(timeInterval: 0.3, queue: .main)

    override internal init(info: Livekit_TrackInfo,
                           track: Track? = nil,
                           participant: Participant) {

        super.init(info: info,
                   track: track,
                   participant: participant)

        asTimer.handler = { [weak self] in self?.onAdaptiveStreamTimer() }
    }

    deinit {
        asTimer.suspend()
    }

    override func updateFromInfo(info: Livekit_TrackInfo) {
        super.updateFromInfo(info: info)
        track?.set(muted: info.muted)
        set(metadataMuted: info.muted)
    }

    override public var subscribed: Bool {
        if !subscriptionAllowed { return false }
        return preferSubscribed != false && super.subscribed
    }

    public var subscriptionState: SubscriptionState {
        if !subscriptionAllowed { return .notAllowed }
        return self.subscribed ? .subscribed : .unsubscribed
    }

    /// Subscribe or unsubscribe from this track.
    @discardableResult
    public func set(subscribed newValue: Bool) -> Promise<Void> {

        guard self.preferSubscribed != newValue else { return Promise(()) }

        guard let participant = participant else {
            return Promise(EngineError.state(message: "Participant is nil"))
        }

        return participant.room.engine.signalClient.sendUpdateSubscription(
            participantSid: participant.sid,
            trackSid: sid,
            subscribed: newValue
        ).then(on: .sdk) {
            self.preferSubscribed = newValue
        }
    }

    /// Enable or disable server from sending down data for this track.
    ///
    /// This is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements.
    @discardableResult
    public func set(enabled newValue: Bool) -> Promise<Void> {
        // no-op if already the desired value
        guard _state.trackSettings.enabled != newValue else { return Promise(()) }

        guard userCanModifyTrackSettings else { return Promise(TrackError.state(message: "adaptiveStream must be disabled and track must be subscribed")) }

        // keep old settings
        let oldSettings = _state.trackSettings
        // update state
        _state.mutate { $0.trackSettings = $0.trackSettings.copyWith(enabled: newValue) }
        // attempt to set the new settings
        return send(trackSettings: _state.trackSettings).catch(on: .sdk) { [weak self] error in

            guard let self = self else { return }

            // revert track settings on failure
            self._state.mutate { $0.trackSettings = oldSettings }

            print("failed to update enabled: \(newValue), sid: \(self.sid), error: \(error)")
        }
    }

    @discardableResult
    internal override func set(track newValue: Track?) -> Track? {

        print("RemoteTrackPublication set track: \(String(describing: track))")

        let oldValue = super.set(track: newValue)
        if newValue != oldValue {
            // always suspend adaptiveStream timer first
            asTimer.suspend()

            if let newValue = newValue {

                // reset track settings, track is initially disabled only if adaptive stream and is a video track
                resetTrackSettings()

                print("[adaptiveStream] did reset trackSettings: \(_state.trackSettings), kind: \(newValue.kind)")

                // start adaptiveStream timer only if it's a video track
                if isAdaptiveStreamEnabled {
                    asTimer.restart()
                }

                // if new Track has been set to this RemoteTrackPublication,
                // update the Track's muted state from the latest info.
                newValue.set(muted: metadataMuted,
                             notify: false)
            }

            if let oldValue = oldValue, newValue == nil, let participant = participant as? RemoteParticipant {
                participant.notify { $0.participant(participant, didUnsubscribe: self, track: oldValue) }
                participant.room.notify { $0.room(participant.room, participant: participant, didUnsubscribe: self, track: oldValue) }
            }
        }

        return oldValue
    }
}

// MARK: - Private

private extension RemoteTrackPublication {

    var isAdaptiveStreamEnabled: Bool { (participant?.room.options ?? RoomOptions()).adaptiveStream && .video == kind }

    var engineConnectionState: ConnectionState {

        guard let participant = participant else {
            return .disconnected()
        }

        return participant.room.engine._state.connectionState
    }

    var userCanModifyTrackSettings: Bool {
        // adaptiveStream must be disabled and must be subscribed
        !isAdaptiveStreamEnabled && subscribed
    }
}

// MARK: - Internal

internal extension RemoteTrackPublication {

    func set(metadataMuted newValue: Bool) {

        guard self.metadataMuted != newValue else { return }

        guard let participant = participant else {
            return
        }

        self.metadataMuted = newValue
        // if track exists, track will emit the following events
        if track == nil {
            participant.notify { $0.participant(participant, didUpdate: self, muted: newValue) }
            participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, muted: newValue) }
        }
    }

    func set(subscriptionAllowed newValue: Bool) {
        guard _state.subscriptionAllowed != newValue else { return }
        _state.mutate { $0.subscriptionAllowed = newValue }

        guard let participant = self.participant as? RemoteParticipant else { return }
        participant.notify { $0.participant(participant, didUpdate: self, permission: newValue) }
        participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, permission: newValue) }
    }
}

// MARK: - TrackSettings

internal extension RemoteTrackPublication {

    // reset track settings
    func resetTrackSettings() {
        // track is initially disabled when adaptive stream is enabled
        _state.mutate { $0.trackSettings = TrackSettings(enabled: !isAdaptiveStreamEnabled) }
    }

    // simply send track settings
    func send(trackSettings: TrackSettings) -> Promise<Void> {

        guard let participant = participant else {
            return Promise(EngineError.state(message: "Participant is nil"))
        }

        print("[adaptiveStream] sending \(trackSettings), sid: \(sid)")

        return participant.room.engine.signalClient.sendUpdateTrackSettings(sid: sid, settings: trackSettings)
    }
}

// MARK: - Adaptive Stream

internal extension Collection where Element == VideoView {

    func hasVisible() -> Bool {
        // not visible if no entry
        if isEmpty { return false }
        // at least 1 entry should be visible
        return contains { $0.isVisible }
    }

    func largestSize() -> CGSize? {

        func maxCGSize(_ s1: CGSize, _ s2: CGSize) -> CGSize {
            CGSize(width: Swift.max(s1.width, s2.width),
                   height: Swift.max(s1.height, s2.height))
        }

        // use post-layout nativeRenderer's view size otherwise return nil
        // which results lower layer to be requested (enabled: true, dimensions: 0x0)
        return filter { $0.isVisible }.compactMap { $0._state.rendererSize }.reduce(into: nil as CGSize?, { previous, current in
            guard let unwrappedPrevious = previous else {
                previous = current
                return
            }
            previous = maxCGSize(unwrappedPrevious, current)
        })
    }
}

extension RemoteTrackPublication {

    // executed on .main
    private func onAdaptiveStreamTimer() {

        // this should never happen
        assert(Thread.current.isMainThread, "this method must be called from main thread")

        // suspend timer first
        asTimer.suspend()

        // don't continue if the engine is disconnected
        guard !engineConnectionState.isDisconnected else {
            print("engine is disconnected")
            return
        }

        let asViews = track?.videoViews.allObjects ?? []

        if asViews.count > 1 {
        }

        let enabled = asViews.hasVisible()
        var dimensions: Dimensions = .zero

        // compute the largest video view size
        if enabled, let maxSize = asViews.largestSize() {
            dimensions = Dimensions(width: Int32(ceil(maxSize.width)),
                                    height: Int32(ceil(maxSize.height)))
        }

        let newSettings = _state.trackSettings.copyWith(enabled: enabled, dimensions: dimensions)

        guard _state.trackSettings != newSettings else {
            // no settings updated
            asTimer.resume()
            return
        }

        // keep old settings
        let oldSettings = _state.trackSettings
        // update state
        _state.mutate { $0.trackSettings = newSettings }

        // log when flipping from enabled -> disabled
        if oldSettings.enabled, !newSettings.enabled {
            let viewsString = asViews.enumerated().map { (i, view) in "view\(i).isVisible: \(view.isVisible)(didLayout: \(view._state.didLayout), isHidden: \(view._state.isHidden), isEnabled: \(view._state.isEnabled))" }.joined(separator: ", ")
            print("[adaptiveStream] disabling sid: \(sid), viewCount: \(asViews.count), \(viewsString)")
        }

        if let videoTrack = track?.mediaTrack as? RTCVideoTrack {
            print("VideoTrack.shouldReceive: \(enabled)")
            DispatchQueue.webRTC.sync { videoTrack.shouldReceive = enabled }
        }

        send(trackSettings: newSettings).catch(on: .sdk) { [weak self] error in
            guard let self = self else { return }
            // revert to old settings on failure
            self._state.mutate { $0.trackSettings = oldSettings }
        }.always(on: .sdk) { [weak self] in
            guard let self = self else { return }
            self.asTimer.restart()
        }
    }
}
