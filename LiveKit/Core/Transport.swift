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
import Promises
import WebRTC
import SwiftProtobuf

internal typealias TransportOnOffer = (RTCSessionDescription) -> Promise<Void>

internal class Transport: MulticastDelegate<TransportDelegate> {

    // MARK: - Public

    public let target: Livekit_SignalTarget
    public let primary: Bool

    public var restartingIce: Bool = false
    public var onOffer: TransportOnOffer?

    public var connectionState: RTCPeerConnectionState {
        DispatchQueue.webRTC.sync { pc.connectionState }
    }

    public var localDescription: RTCSessionDescription? {
        DispatchQueue.webRTC.sync { pc.localDescription }
    }

    public var remoteDescription: RTCSessionDescription? {
        DispatchQueue.webRTC.sync { pc.remoteDescription }
    }

    public var signalingState: RTCSignalingState {
        DispatchQueue.webRTC.sync { pc.signalingState }
    }

    public var isConnected: Bool {
        connectionState == .connected
    }

    // create debounce func
    public lazy var negotiate = Utils.createDebounceFunc(wait: 0.1, onCreateWorkItem: { [weak self] workItem in
        self?.debounceWorkItem = workItem
    }, fnc: { [weak self] in
        self?.createAndSendOffer()
    })

    // MARK: - Private

    private var renegotiate: Bool = false

    // forbid direct access to PeerConnection
    private let pc: RTCPeerConnection
    private var pendingCandidates: [RTCIceCandidate] = []

    // used for stats timer
    private let statsTimer = DispatchQueueTimer(timeInterval: 1, queue: .webRTC)
    private var stats = [String: TrackStats]()

    // keep reference to cancel later
    private var debounceWorkItem: DispatchWorkItem?

    init(config: RTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate,
         reportStats: Bool = false) throws {

        // try create peerConnection
        guard let pc = Engine.createPeerConnection(config,
                                                   constraints: .defaultPCConstraints) else {

            throw EngineError.webRTC(message: "failed to create peerConnection")
        }

        self.target = target
        self.primary = primary
        self.pc = pc

        super.init()

        print()

        DispatchQueue.webRTC.sync { pc.delegate = self }
        add(delegate: delegate)

        statsTimer.handler = { [weak self] in
            self?.onStatsTimer()
        }

        set(reportStats: reportStats)
    }

    deinit {
        statsTimer.suspend()
        print()
    }

    internal func set(reportStats: Bool) {
        print("reportStats: \(reportStats)")
        reportStats ? statsTimer.resume() : statsTimer.suspend()
    }

    @discardableResult
    func addIceCandidate(_ candidate: RTCIceCandidate) -> Promise<Void> {

        if remoteDescription != nil && !restartingIce {
            return addIceCandidatePromise(candidate)
        }

        return Promise(on: .sdk) {
            self.pendingCandidates.append(candidate)
        }
    }

    @discardableResult
    func setRemoteDescription(_ sd: RTCSessionDescription) -> Promise<Void> {

        self.setRemoteDescriptionPromise(sd).then(on: .sdk) { _ in
            self.pendingCandidates.map { self.addIceCandidatePromise($0) }.all(on: .sdk)
        }.then(on: .sdk) { () -> Promise<Void> in

            self.pendingCandidates = []
            self.restartingIce = false

            if self.renegotiate {
                self.renegotiate = false
                return self.createAndSendOffer()
            }

            return Promise(())
        }
    }

    @discardableResult
    func createAndSendOffer(iceRestart: Bool = false) -> Promise<Void> {

        guard let onOffer = onOffer else {
            return Promise(())
        }

        var constraints = [String: String]()
        if iceRestart {
            print("Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            restartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            renegotiate = true
            return Promise(())
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            return setRemoteDescriptionPromise(sd).then(on: .sdk) { _ in
                negotiateSequence()
            }
        }

        // actually negotiate
        func negotiateSequence() -> Promise<Void> {
            createOffer(for: constraints).then(on: .sdk) { offer in
                self.setLocalDescription(offer)
            }.then(on: .sdk) { offer in
                onOffer(offer)
            }
        }

        return negotiateSequence()
    }

    func close() -> Promise<Void> {
        // prevent debounced negotiate firing
        debounceWorkItem?.cancel()
        statsTimer.suspend()

        return Promise(on: .webRTC) { [pc] in
            // Stop listening to delegate
            pc.delegate = nil
            // Remove all senders (if any)
            for sender in pc.senders {
                pc.removeTrack(sender)
            }
            pc.close()
        }
    }
}

// MARK: - Stats

extension Transport {

    func onStatsTimer() {

        statsTimer.suspend()
        pc.stats(for: nil, statsOutputLevel: .standard) { [weak self] reports in

            guard let self = self else { return }

            self.statsTimer.resume()

            let tracks = reports
                .filter { $0.type == TrackStats.keyTypeSSRC }
                .map { entry -> TrackStats? in

                    let findPrevious = { () -> TrackStats? in
                        guard let ssrc = entry.values[TrackStats.keyTypeSSRC],
                              let previous = self.stats[ssrc] else { return nil }
                        return previous
                    }

                    return TrackStats(from: entry.values, previous: findPrevious())
                }
                .compactMap { $0 }

            for track in tracks {
                // cache
                self.stats[track.ssrc] = track
            }

            if !tracks.isEmpty {
                self.notify { $0.transport(self, didGenerate: tracks, target: self.target) }
            }

            // clean up
            // for key in self.stats.keys {
            //    if !tracks.contains(where: { $0.ssrc == key }) {
            //        self.stats.removeValue(forKey: key)
            //    }
            // }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension Transport: RTCPeerConnectionDelegate {

    internal func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        print("did update state \(state) for \(target)")
        notify { $0.transport(self, didUpdate: state) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection,
                                 didGenerate candidate: RTCIceCandidate) {

        print("Did generate ice candidates \(candidate) for \(target)")
        notify { $0.transport(self, didGenerate: candidate) }
    }

    internal func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("ShouldNegotiate for \(target)")
        notify { $0.transportShouldNegotiate(self) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection,
                                 didAdd rtpReceiver: RTCRtpReceiver,
                                 streams mediaStreams: [RTCMediaStream]) {

        guard let track = rtpReceiver.track else {
            return
        }

        print("didAdd track \(track.trackId)")
        notify { $0.transport(self, didAdd: track, streams: mediaStreams) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection,
                                 didRemove rtpReceiver: RTCRtpReceiver) {

        guard let track = rtpReceiver.track else {
            return
        }

        print("didRemove track: \(track.trackId)")
        notify { $0.transport(self, didRemove: track) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("Received data channel \(dataChannel.label) for \(target)")
        notify { $0.transport(self, didOpen: dataChannel) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

// MARK: - Private

private extension Transport {

    func createOffer(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                       optionalConstraints: nil)

            self.pc.offer(for: mediaConstraints) { sd, error in

                guard let sd = sd else {
                    fail(EngineError.webRTC(message: "Failed to create offer", error))
                    return
                }

                complete(sd)
            }
        }
    }

    func setRemoteDescriptionPromise(_ sd: RTCSessionDescription) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            self.pc.setRemoteDescription(sd) { error in

                guard error == nil else {
                    fail(EngineError.webRTC(message: "failed to set remote description", error))
                    return
                }

                complete(sd)
            }
        }
    }

    func addIceCandidatePromise(_ candidate: RTCIceCandidate) -> Promise<Void> {

        Promise<Void>(on: .webRTC) { complete, fail in

            self.pc.add(candidate) { error in

                guard error == nil else {
                    fail(EngineError.webRTC(message: "failed to add ice candidate", error))
                    return
                }

                complete(())
            }
        }
    }
}

// MARK: - Internal

internal extension Transport {

    func createAnswer(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                       optionalConstraints: nil)

            self.pc.answer(for: mediaConstraints) { sd, error in

                guard let sd = sd else {
                    fail(EngineError.webRTC(message: "failed to create answer", error))
                    return
                }

                complete(sd)
            }
        }
    }

    func setLocalDescription(_ sd: RTCSessionDescription) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            self.pc.setLocalDescription(sd) { error in

                guard error == nil else {
                    fail(EngineError.webRTC(message: "failed to set local description", error))
                    return
                }

                complete(sd)
            }
        }
    }

    func addTransceiver(with track: RTCMediaStreamTrack,
                        transceiverInit: RTCRtpTransceiverInit) -> Promise<RTCRtpTransceiver> {

        Promise<RTCRtpTransceiver>(on: .webRTC) { complete, fail in

            guard let transceiver = self.pc.addTransceiver(with: track, init: transceiverInit) else {
                fail(EngineError.webRTC(message: "failed to add transceiver"))
                return
            }

            complete(transceiver)
        }
    }

    func removeTrack(_ sender: RTCRtpSender) -> Promise<Void> {

        Promise<Void>(on: .webRTC) { complete, fail in

            guard self.pc.removeTrack(sender) else {
                fail(EngineError.webRTC(message: "failed to remove track"))
                return
            }

            complete(())
        }
    }

    func dataChannel(for label: String,
                     configuration: RTCDataChannelConfiguration,
                     delegate: RTCDataChannelDelegate) -> RTCDataChannel? {

        let result = DispatchQueue.webRTC.sync { pc.dataChannel(forLabel: label,
                                                                configuration: configuration) }
        result?.delegate = delegate
        return result
    }
}
