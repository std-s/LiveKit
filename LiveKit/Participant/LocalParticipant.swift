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
import Promises

public class LocalParticipant: Participant {

    public var localAudioTracks: [LocalTrackPublication] { audioTracks.compactMap { $0 as? LocalTrackPublication } }
    public var localVideoTracks: [LocalTrackPublication] { videoTracks.compactMap { $0 as? LocalTrackPublication } }

    convenience init(from info: Livekit_ParticipantInfo,
                     room: Room) {

        self.init(sid: info.sid,
                  identity: info.identity,
                  name: info.name,
                  room: room)

        updateFromInfo(info: info)
    }

    public func getTrackPublication(sid: Sid) -> LocalTrackPublication? {
        return tracks[sid] as? LocalTrackPublication
    }

    internal func publish(track: LocalTrack,
                          publishOptions: PublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let publisher = room.engine.publisher else {
            return Promise(EngineError.state(message: "publisher is null"))
        }

        guard _state.tracks.values.first(where: { $0.track === track }) == nil else {
            return Promise(TrackError.publish(message: "This track has already been published."))
        }

        guard track is LocalVideoTrack || track is LocalAudioTrack else {
            return Promise(TrackError.publish(message: "Unknown LocalTrack type"))
        }

        // try to start the track
        return track.start().then(on: .sdk) { _ -> Promise<Dimensions?> in
            // ensure dimensions are resolved for VideoTracks
            guard let track = track as? LocalVideoTrack else { return Promise(nil) }

            print("[publish] waiting for dimensions to resolve...")

            // wait for dimensions
            return track.capturer._state.mutate { $0.dimensionsCompleter.wait(on: .sdk,
                                                                              .defaultCaptureStart,
                                                                              throw: { TrackError.timedOut(message: "unable to resolve dimensions") }) }.then(on: .sdk) { $0 }

        }.then(on: .sdk) { dimensions -> Promise<(result: RTCRtpTransceiverInit, trackInfo: Livekit_TrackInfo)> in
            // request a new track to the server
            self.room.engine.signalClient.sendAddTrack(cid: track.mediaTrack.trackId,
                                                       name: track.name,
                                                       type: track.kind.toPBType(),
                                                       source: track.source.toPBType()) { populator in

                let transInit = DispatchQueue.webRTC.sync { RTCRtpTransceiverInit() }
                transInit.direction = .sendOnly

                if let track = track as? LocalVideoTrack {

                    guard let dimensions = dimensions else {
                        throw TrackError.publish(message: "VideoCapturer dimensions are unknown")
                    }

                    print("[publish] computing encode settings with dimensions: \(dimensions)...")

                    let publishOptions = (publishOptions as? VideoPublishOptions) ?? self.room.options.defaultVideoPublishOptions

#if LK_COMPUTE_VIDEO_SENDER_PARAMETERS
                    let encodings = Utils.computeEncodings(dimensions: dimensions,
                                                           publishOptions: publishOptions,
                                                           isScreenShare: track.source == .screenShareVideo)

                    print("[publish] using encodings: \(encodings)")
                    transInit.sendEncodings = encodings

                    let videoLayers = dimensions.videoLayers(for: encodings)

                    print("[publish] using layers: \(videoLayers.map { String(describing: $0) }.joined(separator: ", "))")

                    populator.width = UInt32(dimensions.width)
                    populator.height = UInt32(dimensions.height)
                    populator.layers = videoLayers

                    print("[publish] requesting add track to server with \(populator)...")
#endif
                } else if track is LocalAudioTrack {
                    // additional params for Audio
                    let publishOptions = (publishOptions as? AudioPublishOptions) ?? self.room.options.defaultAudioPublishOptions
                    populator.disableDtx = !publishOptions.dtx
                }

                return transInit
            }

        }.then(on: .sdk) { (transInit, trackInfo) -> Promise<(transceiver: RTCRtpTransceiver, trackInfo: Livekit_TrackInfo)> in

            print("[publish] server responded trackInfo: \(trackInfo)")

            // add transceiver to pc
            return publisher.addTransceiver(with: track.mediaTrack,
                                            transceiverInit: transInit).then(on: .sdk) { transceiver in
                                                // pass down trackInfo and created transceiver
                                                (transceiver, trackInfo)
                                            }
        }.then(on: .sdk) { params -> Promise<(RTCRtpTransceiver, trackInfo: Livekit_TrackInfo)> in
            print("[publish] added transceiver: \(params.trackInfo)...")
            return track.onPublish().then(on: .sdk) { _ in params }
        }.then(on: .sdk) { (transceiver, trackInfo) -> LocalTrackPublication in

            // store publishOptions used for this track
            track.publishOptions = publishOptions
            track.transceiver = transceiver

            // disable degradationPreference
            let params = transceiver.sender.parameters
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.disabled.rawValue)
            // changing params directly doesn't work so we need to update params
            // and set it back to sender.parameters
            transceiver.sender.parameters = params

            self.room.engine.publisherShouldNegotiate()

            let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
            self.addTrack(publication: publication)

            // notify didPublish
            self.notify { $0.localParticipant(self, didPublish: publication) }
            self.room.notify { $0.room(self.room, localParticipant: self, didPublish: publication) }

            return publication

        }.catch(on: .sdk) { error in

            // stop the track
            track.stop().catch(on: .sdk) { error in
            }
        }
    }

    /// publish a new audio track to the Room
    public func publishAudioTrack(track: LocalAudioTrack,
                                  publishOptions: AudioPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        publish(track: track, publishOptions: publishOptions)
    }

    /// publish a new video track to the Room
    public func publishVideoTrack(track: LocalVideoTrack,
                                  publishOptions: VideoPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        publish(track: track, publishOptions: publishOptions)
    }

    public override func unpublishAll(notify _notify: Bool = true) -> Promise<Void> {
        // build a list of promises
        let promises = _state.tracks.values.compactMap { $0 as? LocalTrackPublication }
            .map { unpublish(publication: $0, notify: _notify) }
        // combine promises to wait all to complete
        return super.unpublishAll(notify: _notify).then(on: .sdk) {
            promises.all(on: .sdk)
        }
    }

    /// unpublish an existing published track
    /// this will also stop the track
    public func unpublish(publication: LocalTrackPublication, notify _notify: Bool = true) -> Promise<Void> {

        func notifyDidUnpublish() -> Promise<Void> {

            Promise<Void>(on: .sdk) {
                guard _notify else { return }
                // notify unpublish
                self.notify { $0.localParticipant(self, didUnpublish: publication) }
                self.room.notify { $0.room(self.room, localParticipant: self, didUnpublish: publication) }
            }
        }

        // remove the publication
        _state.mutate { $0.tracks.removeValue(forKey: publication.sid) }

        // if track is nil, only notify unpublish and return
        guard let track = publication.track as? LocalTrack else {
            return notifyDidUnpublish()
        }

        // build a conditional promise to stop track if required by option
        func stopTrackIfRequired() -> Promise<Bool> {
            if room.options.stopLocalTrackOnUnpublish {
                return track.stop()
            }
            // Do nothing
            return Promise(false)
        }

        // wait for track to stop
        return stopTrackIfRequired().then(on: .sdk) { _ -> Promise<Void> in

            guard let publisher = self.room.engine.publisher, let sender = track.sender else {
                return Promise(())
            }

            return publisher.removeTrack(sender).then(on: .sdk) {
                self.room.engine.publisherShouldNegotiate()
            }
        }.then(on: .sdk) {
            track.onUnpublish()
        }.then(on: .sdk) { _ -> Promise<Void> in
            notifyDidUnpublish()
        }
    }

    /**
     publish data to the other participants in the room

     Data is forwarded to each participant in the room. Each payload must not exceed 15k.
     - Parameter data: Data to send
     - Parameter reliability: Toggle between sending relialble vs lossy delivery.
     For data that you need delivery guarantee (such as chat messages), use Reliable.
     For data that should arrive as quickly as possible, but you are ok with dropped packets, use Lossy.
     - Parameter destination: SIDs of the participants who will receive the message. If empty, deliver to everyone
     */
    @discardableResult
    public func publishData(data: Data,
                            reliability: Reliability = .reliable,
                            destination: [String] = []) -> Promise<Void> {

        let userPacket = Livekit_UserPacket.with {
            $0.destinationSids = destination
            $0.payload = data
            $0.participantSid = self.sid
        }

        return room.engine.send(userPacket: userPacket,
                                reliability: reliability)
    }

    /**
     * Control who can subscribe to LocalParticipant's published tracks.
     *
     * By default, all participants can subscribe. This allows fine-grained control over
     * who is able to subscribe at a participant and track level.
     *
     * Note: if access is given at a track-level (i.e. both ``allParticipantsAllowed`` and
     * ``ParticipantTrackPermission/allTracksAllowed`` are false), any newer published tracks
     * will not grant permissions to any participants and will require a subsequent
     * permissions update to allow subscription.
     *
     * - Parameter allParticipantsAllowed Allows all participants to subscribe all tracks.
     *  Takes precedence over ``participantTrackPermissions`` if set to true.
     *  By default this is set to true.
     * - Parameter participantTrackPermissions Full list of individual permissions per
     *  participant/track. Any omitted participants will not receive any permissions.
     */
    @discardableResult
    public func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                                trackPermissions: [ParticipantTrackPermission] = []) -> Promise<Void> {

        return room.engine.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                         trackPermissions: trackPermissions)
    }

    internal func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {

        if !room.options.dynacast {
            return
        }

        guard let pub = getTrackPublication(sid: trackSid),
              let track = pub.track as? LocalVideoTrack,
              let sender = track.transceiver?.sender
        else { return }

        let parameters = sender.parameters
        let encodings = parameters.encodings

        var hasChanged = false
        for quality in subscribedQualities {

            var rid: String
            switch quality.quality {
            case Livekit_VideoQuality.high: rid = "f"
            case Livekit_VideoQuality.medium: rid = "h"
            case Livekit_VideoQuality.low: rid = "q"
            default: continue
            }

            guard let encoding = encodings.first(where: { $0.rid == rid }) else {
                continue
            }

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
            }
        }

        // Non simulcast streams don't have rids, handle here.
        if encodings.count == 1 && subscribedQualities.count >= 1 {
            let encoding = encodings[0]
            let quality = subscribedQualities[0]

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
            }
        }

        if hasChanged {
            sender.parameters = parameters
        }
    }

    internal override func set(permissions newValue: ParticipantPermissions) -> Bool {

        let didUpdate = super.set(permissions: newValue)

        if didUpdate {
            notify { $0.participant(self, didUpdate: newValue) }
            room.notify { $0.room(self.room, participant: self, didUpdate: newValue) }
        }

        return didUpdate
    }
}

// MARK: - Session Migration

extension LocalParticipant {

    internal func publishedTracksInfo() -> [Livekit_TrackPublishedResponse] {
        _state.tracks.values.filter { $0.track != nil }
            .map { publication in
                Livekit_TrackPublishedResponse.with {
                    $0.cid = publication.track!.mediaTrack.trackId
                    if let info = publication.latestInfo {
                        $0.track = info
                    }
                }
            }
    }

    internal func republishTracks() -> Promise<Void> {

        let mediaTracks = _state.tracks.values.map { $0.track }.compactMap { $0 }

        return unpublishAll().then(on: .sdk) { () -> Promise<Void> in

            let promises = mediaTracks.map { track -> Promise<LocalTrackPublication>? in
                guard let track = track as? LocalTrack else { return nil }
                return self.publish(track: track, publishOptions: track.publishOptions)
            }.compactMap { $0 }

            // TODO: use .all extension
            return all(on: .sdk, promises).then(on: .sdk) { _ in }
        }
    }
}

// MARK: - Simplified API

extension LocalParticipant {

    public func setCamera(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .camera, enabled: enabled)
    }

    public func setMicrophone(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .microphone, enabled: enabled)
    }

    /// Enable or disable screen sharing. This has different behavior depending on the platform.
    ///
    /// For iOS, this will use ``InAppScreenCapturer`` to capture in-app screen only due to Apple's limitation.
    /// If you would like to capture the screen when the app is in the background, you will need to create a "Broadcast Upload Extension".
    ///
    /// For macOS, this will use ``MacOSScreenCapturer`` to capture the main screen. ``MacOSScreenCapturer`` has the ability
    /// to capture other screens and windows. See ``MacOSScreenCapturer`` for details.
    ///
    /// For advanced usage, you can create a relevant ``LocalVideoTrack`` and call ``LocalParticipant/publishVideoTrack(track:publishOptions:)``.
    public func setScreenShare(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .screenShareVideo, enabled: enabled)
    }

    public func set(source: Track.Source, enabled: Bool) -> Promise<LocalTrackPublication?> {
        let publication = getTrackPublication(source: source)
        if let publication = publication as? LocalTrackPublication {
            // publication already exists
            if enabled {
                return publication.unmute().then(on: .sdk) { publication }
            } else {
                return publication.mute().then(on: .sdk) { nil }
            }
        } else if enabled {
            // try to create a new track
            if source == .camera {
                let localTrack = LocalVideoTrack.createCameraTrack(options: room.options.defaultCameraCaptureOptions)
                return publishVideoTrack(track: localTrack).then(on: .sdk) { return $0 }
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(options: room.options.defaultAudioCaptureOptions)
                return publishAudioTrack(track: localTrack).then(on: .sdk) { return $0 }
            } else if source == .screenShareVideo {

                var localTrack: LocalVideoTrack?

                #if os(iOS)
                // iOS defaults to in-app screen share only since background screen share
                // requires a broadcast extension (iOS limitation).
                localTrack = LocalVideoTrack.createInAppScreenShareTrack(options: room.options.defaultScreenShareCaptureOptions)
                #elseif os(macOS)
                localTrack = LocalVideoTrack.createMacOSScreenShareTrack(options: room.options.defaultScreenShareCaptureOptions)
                #endif

                if let localTrack = localTrack {
                    return publishVideoTrack(track: localTrack).then(on: .sdk) { publication in return publication }
                }
            }
        }

        return Promise(EngineError.state())
    }
}
