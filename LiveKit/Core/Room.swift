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
import Network
import Promises
import WebRTC

public class Room: MulticastDelegate<RoomDelegate> {

    // MARK: - Public

    public var sid: Sid? { _state.sid }
    public var name: String? { _state.name }
    public var metadata: String? { _state.metadata }
    public var serverVersion: String? { _state.serverVersion }
    public var serverRegion: String? { _state.serverRegion }

    public var localParticipant: LocalParticipant? { _state.localParticipant }
    public var remoteParticipants: [Sid: RemoteParticipant] { _state.remoteParticipants }
    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    // expose engine's vars
    public var url: String? { engine._state.url }
    public var token: String? { engine._state.token }
    public var connectionState: ConnectionState { engine._state.connectionState }
    public var connectStopwatch: Stopwatch { engine._state.connectStopwatch }

    // MARK: - Internal

    // Reference to Engine
    internal let engine: Engine
    internal private(set) var options: RoomOptions

    internal struct State {
        var sid: String?
        var name: String?
        var metadata: String?
        var serverVersion: String?
        var serverRegion: String?

        var localParticipant: LocalParticipant?
        var remoteParticipants = [Sid: RemoteParticipant]()
        var activeSpeakers = [Participant]()
    }

    // MARK: - Private

    private var _state = StateSync(State())

    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions = ConnectOptions(),
                roomOptions: RoomOptions = RoomOptions()) {

        self.options = roomOptions
        self.engine = Engine(connectOptions: connectOptions,
                             roomOptions: roomOptions)
        super.init()

        print()

        // listen to engine & signalClient
        engine.add(delegate: self)
        engine.signalClient.add(delegate: self)

        if let delegate = delegate {
            add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.add(delegate: self)
    }

    deinit {
        print()
    }

    @discardableResult
    public func connect(_ url: String,
                        _ token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) -> Promise<Room> {

        // update options if specified
        self.options = roomOptions ?? self.options

        guard _state.localParticipant == nil else {
            return Promise(EngineError.state(message: "localParticipant is not nil"))
        }

        // monitor.start(queue: monitorQueue)
        return engine.connect(url, token,
                              connectOptions: connectOptions,
                              roomOptions: roomOptions).then(on: .sdk) { () -> Room in
                                return self
                              }
    }

    @discardableResult
    public func disconnect() -> Promise<Void> {

        // return if already disconnected state
        if case .disconnected = connectionState { return Promise(()) }

        return engine.signalClient.sendLeave()
            .recover(on: .sdk) { print("Failed to send leave, error: \($0)") }
            .then(on: .sdk) {
                self.cleanUp(reason: .user)
            }
    }
}

// MARK: - Internal

internal extension Room.State {

    @discardableResult
    mutating func getOrCreateRemoteParticipant(sid: Sid, info: Livekit_ParticipantInfo? = nil, room: Room) -> RemoteParticipant {

        if let participant = remoteParticipants[sid] {
            return participant
        }

        let participant = RemoteParticipant(sid: sid, info: info, room: room)
        remoteParticipants[sid] = participant
        return participant
    }
}

// MARK: - Private

private extension Room {

    // Resets state of Room
    @discardableResult
    private func cleanUp(reason: DisconnectReason? = nil) -> Promise<Void> {

        print("reason: \(String(describing: reason))")

        return engine.cleanUp(reason: reason)
            .then(on: .sdk) {
                self.cleanUpParticipants()
            }.then(on: .sdk) {
                // reset state
                self._state.mutate { $0 = State() }
            }.catch(on: .sdk) { error in
                // this should never happen
            }
    }

    @discardableResult
    func cleanUpParticipants(notify _notify: Bool = true) -> Promise<Void> {

        print("notify: \(_notify)")

        // Stop all local & remote tracks
        let allParticipants = ([[localParticipant],
                                _state.remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let cleanUpPromises = allParticipants.map { $0.cleanUp(notify: _notify) }

        return cleanUpPromises.all(on: .sdk).then {
            //
            self._state.mutate {
                $0.localParticipant = nil
                $0.remoteParticipants = [:]
            }
        }
    }

    @discardableResult
    func onParticipantDisconnect(sid: Sid) -> Promise<Void> {

        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: sid) }) else {
            return Promise(EngineError.state(message: "Participant not found for \(sid)"))
        }

        return participant.cleanUp(notify: true)
    }
}

// MARK: - Internal

internal extension Room {

    func set(metadata: String?) {
        guard self.metadata != metadata else { return }

        self._state.mutate { state in
            state.metadata = metadata
        }

        notify { $0.room(self, didUpdate: metadata) }
    }
}

// MARK: - Debugging

extension Room {

    @discardableResult
    public func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        engine.signalClient.sendSimulate(scenario: scenario)
    }
}

// MARK: - Session Migration

internal extension Room {

    func resetTrackSettings() {

        print("resetting track settings...")

        // create an array of RemoteTrackPublication
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.tracks.values.compactMap { $0 as? RemoteTrackPublication }
        }.joined()

        // reset track settings for all RemoteTrackPublication
        for publication in remoteTrackPublications {
            publication.resetTrackSettings()
        }
    }

    func sendSyncState() -> Promise<Void> {

        guard let subscriber = engine.subscriber,
              let localDescription = subscriber.localDescription else {
            // No-op
            return Promise(())
        }

        let sendUnSub = engine.connectOptions.autoSubscribe
        let participantTracks = _state.remoteParticipants.values.map { participant in
            Livekit_ParticipantTracks.with {
                $0.participantSid = participant.sid
                $0.trackSids = participant._state.tracks.values
                    .filter { $0.subscribed != sendUnSub }
                    .map { $0.sid }
            }
        }

        // Backward compatibility
        let trackSids = participantTracks.map { $0.trackSids }.flatMap { $0 }

        print("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids // Deprecated
            $0.participantTracks = participantTracks
            $0.subscribe = !sendUnSub
        }

        return engine.signalClient.sendSyncState(answer: localDescription.toPBType(),
                                                 subscription: subscription,
                                                 publishTracks: _state.localParticipant?.publishedTracksInfo(),
                                                 dataChannels: engine.dataChannelInfo())
    }
}

// MARK: - SignalClientDelegate

extension Room: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool) -> Bool {

        print("canReconnect: \(canReconnect)")

        if canReconnect {
            // force .full for next reconnect
            engine._state.mutate { $0.nextPreferredReconnectMode = .full }
        } else {
            // server indicates it's not recoverable
            cleanUp(reason: .networkError(NetworkError.disconnected(message: "did receive leave")))
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) -> Bool {

        print()

        guard let localParticipant = _state.localParticipant else { return true }
        localParticipant.onSubscribedQualitiesUpdate(trackSid: trackSid, subscribedQualities: subscribedQualities)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) -> Bool {


        _state.mutate {
            $0.sid = joinResponse.room.sid
            $0.name = joinResponse.room.name
            $0.metadata = joinResponse.room.metadata
            $0.serverVersion = joinResponse.serverVersion
            $0.serverRegion = joinResponse.serverRegion.isEmpty ? nil : joinResponse.serverRegion

            if joinResponse.hasParticipant {
                $0.localParticipant = LocalParticipant(from: joinResponse.participant, room: self)
            }

            if !joinResponse.otherParticipants.isEmpty {
                for otherParticipant in joinResponse.otherParticipants {
                    $0.getOrCreateRemoteParticipant(sid: otherParticipant.sid, info: otherParticipant, room: self)
                }
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room) -> Bool {
        set(metadata: room.metadata)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) -> Bool {

        let activeSpeakers = _state.mutate { state -> [Participant] in

            var lastSpeakers = state.activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
            for speaker in speakers {

                guard let participant = speaker.sid == state.localParticipant?.sid ? state.localParticipant : state.remoteParticipants[speaker.sid] else {
                    continue
                }

                participant._state.mutate {
                    $0.audioLevel = speaker.level
                    $0.isSpeaking = speaker.active
                }

                if speaker.active {
                    lastSpeakers[speaker.sid] = participant
                } else {
                    lastSpeakers.removeValue(forKey: speaker.sid)
                }
            }

            state.activeSpeakers = lastSpeakers.values.sorted(by: { $1.audioLevel > $0.audioLevel })

            return state.activeSpeakers
        }

        notify { $0.room(self, didUpdate: activeSpeakers) }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) -> Bool {

        for entry in connectionQuality {
            if let localParticipant = _state.localParticipant,
               entry.participantSid == localParticipant.sid {
                // update for LocalParticipant
                localParticipant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            } else if let participant = _state.remoteParticipants[entry.participantSid] {
                // udpate for RemoteParticipant
                participant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) -> Bool {
        print("trackSid: \(trackSid) muted: \(muted)")

        guard let publication = _state.localParticipant?._state.tracks[trackSid] as? LocalTrackPublication else {
            // publication was not found but the delegate was handled
            return true
        }

        if muted {
            publication.mute()
        } else {
            publication.unmute()
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) -> Bool {

        print("did update subscriptionPermission: \(subscriptionPermission)")

        guard let participant = _state.remoteParticipants[subscriptionPermission.participantSid],
              let publication = participant.getTrackPublication(sid: subscriptionPermission.trackSid) else {
            return true
        }

        publication.set(subscriptionAllowed: subscriptionPermission.allowed)

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) -> Bool {

        print("did update trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

        for update in trackStates {
            // Try to find RemoteParticipant
            guard let participant = _state.remoteParticipants[update.participantSid] else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant._state.tracks[update.trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication._state.mutate { $0.streamState = update.state.toLKType() }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) -> Bool {
        print("participants: \(participants)")

        var disconnectedParticipants = [Sid]()
        var newParticipants = [RemoteParticipant]()

        _state.mutate {

            for info in participants {

                if info.sid == $0.localParticipant?.sid {
                    $0.localParticipant?.updateFromInfo(info: info)
                    continue
                }

                let isNewParticipant = $0.remoteParticipants[info.sid] == nil
                let participant = $0.getOrCreateRemoteParticipant(sid: info.sid, info: info, room: self)

                if info.state == .disconnected {
                    disconnectedParticipants.append(info.sid)
                } else if isNewParticipant {
                    newParticipants.append(participant)
                } else {
                    participant.updateFromInfo(info: info)
                }
            }
        }

        for sid in disconnectedParticipants {
            onParticipantDisconnect(sid: sid)
        }

        for participant in newParticipants {
            notify { $0.room(self, participantDidJoin: participant) }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse) -> Bool {
        print()

        guard let localParticipant = localParticipant,
              let publication = localParticipant._state.tracks[localTrack.trackSid] as? LocalTrackPublication else {
            return true
        }

        localParticipant.unpublish(publication: publication).then(on: .sdk) { [weak self] _ in
            print("unpublished track(\(localTrack.trackSid)")
        }.catch(on: .sdk) { [weak self] error in
        }

        return true
    }
}

// MARK: - EngineDelegate

extension Room: EngineDelegate {

    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {
        //
    }

    func engine(_ engine: Engine, didMutate state: Engine.State, oldState: Engine.State) {

        if state.connectionState != oldState.connectionState {
            // connectionState did update

            // only if quick-reconnect
            if case .connected = state.connectionState, case .quick = state.reconnectMode {

                sendSyncState().catch(on: .sdk) { error in
                }

                resetTrackSettings()
            }

            notify { $0.room(self, didUpdate: state.connectionState, oldValue: oldState.connectionState) }
        }

        if state.connectionState.isReconnecting && state.reconnectMode == .full && oldState.reconnectMode != .full {
            // started full reconnect
            cleanUpParticipants(notify: true)
        }
    }

    func engine(_ engine: Engine, didGenerate trackStats: [TrackStats], target: Livekit_SignalTarget) {

        let allParticipants = ([[localParticipant],
                                _state.remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let allTracks = allParticipants.map { $0._state.tracks.values.map { $0.track } }.joined()
            .compactMap { $0 }

        // this relies on the last stat entry being the latest
        for track in allTracks {
            if let stats = trackStats.last(where: { $0.trackId == track.mediaTrack.trackId }) {
                track.set(stats: stats)
            }
        }
    }

    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo]) {

        let activeSpeakers = _state.mutate { state -> [Participant] in

            var activeSpeakers: [Participant] = []
            var seenSids = [String: Bool]()
            for speaker in speakers {
                seenSids[speaker.sid] = true
                if let localParticipant = state.localParticipant,
                   speaker.sid == localParticipant.sid {
                    localParticipant._state.mutate {
                        $0.audioLevel = speaker.level
                        $0.isSpeaking = true
                    }
                    activeSpeakers.append(localParticipant)
                } else {
                    if let participant = state.remoteParticipants[speaker.sid] {
                        participant._state.mutate {
                            $0.audioLevel = speaker.level
                            $0.isSpeaking = true
                        }
                        activeSpeakers.append(participant)
                    }
                }
            }

            if let localParticipant = state.localParticipant, seenSids[localParticipant.sid] == nil {
                localParticipant._state.mutate {
                    $0.audioLevel = 0.0
                    $0.isSpeaking = false
                }
            }

            for participant in state.remoteParticipants.values {
                if seenSids[participant.sid] == nil {
                    participant._state.mutate {
                        $0.audioLevel = 0.0
                        $0.isSpeaking = false
                    }
                }
            }

            return activeSpeakers
        }

        notify { $0.room(self, didUpdate: activeSpeakers) }
    }

    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {

        guard !streams.isEmpty else {
            return
        }

        let unpacked = streams[0].streamId.unpack()
        let participantSid = unpacked.sid
        var trackSid = unpacked.trackId
        if trackSid == "" {
            trackSid = track.trackId
        }

        let participant = _state.mutate { $0.getOrCreateRemoteParticipant(sid: participantSid, room: self) }

        print("added media track from: \(participantSid), sid: \(trackSid)")

        _ = retry(attempts: 10, delay: 0.2) { _, error in
            // if error is invalidTrackState, retry
            guard case TrackError.state = error else { return false }
            return true
        } _: {
            participant.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
        }
    }

    func engine(_ engine: Engine, didRemove track: RTCMediaStreamTrack) {
        // find the publication
        guard let publication = _state.remoteParticipants.values.map({ $0._state.tracks.values }).joined()
                .first(where: { $0.sid == track.trackId }) else { return }
        publication.set(track: nil)
    }

    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {
        // participant could be null if data broadcasted from server
        let participant = _state.remoteParticipants[userPacket.participantSid]

        notify { $0.room(self, participant: participant, didReceive: userPacket.payload) }
        participant?.notify { [weak participant] (delegate) -> Void in
            guard let participant = participant else { return }
            delegate.participant(participant, didReceive: userPacket.payload)
        }
    }
}

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {

    func appDidEnterBackground() {

        guard options.suspendLocalVideoTracksInBackground else { return }

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.suspend() }

        guard !promises.isEmpty else { return }

        promises.all(on: .sdk).then(on: .sdk) {
            print("suspended all video tracks")
        }
    }

    func appWillEnterForeground() {

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.resume() }

        guard !promises.isEmpty else { return }

        promises.all(on: .sdk).then(on: .sdk) {
            print("resumed all video tracks")
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        disconnect()
    }
}
