//
//  AudioControlPointModel.swift
//  ASHA
//
//  Created by Harrison Kaiser on 11/4/23.
//

import Foundation

enum AudioStatusPoint: String {
    case StatusOK = "Status OK"
    case UnknownCommand = "Unknown Command"
    case IllegalParameters = "Illegal Parameters"
}

enum AudioType: UInt8 {
    case Unknown = 0
    case Ringtone = 1
    case Phonecall = 2
    case Media = 3
}

enum OtherState: UInt8 {
    case OtherSideDisconnected = 0
    case OtherSideConnected = 1
}

enum Codec: UInt8 {
    case otherCodecs = 0
    case g722at16kHz = 1
}

enum ConnectedStatus: UInt8 {
    case OtherPeripheralDisconnected = 0
    case OtherPeripheralConnected = 1
    case LeConnectionParameterUpdate = 2
}

struct AudioControlPointStart {
    let opcode: UInt8
    let audiotype: AudioType
    let codec: Codec
    let volume: Int8
    let otherstate: OtherState

    init?(codecId: Codec, audioType: AudioType, volumeLevel: Int8, otherState: OtherState) {
        opcode = 1
        audiotype = audioType
        codec = codecId
        volume = volumeLevel
        otherstate = otherState
    }
    
    func asData() -> Data {
        return Data([opcode, codec.rawValue, audiotype.rawValue, UInt8(volume), UInt8(otherstate.rawValue)])
    }
}

struct AudioControlPointStop {
    let opcode: UInt8
    init?() {
        opcode = 2
    }
    
    func asData() -> Data {
        return Data([opcode])
    }
}

struct AudioControlPointStatus {
    let opcode: UInt8
    let connected: ConnectedStatus
    init?(connectedStatus: ConnectedStatus) {
        opcode = 3
        connected = connectedStatus
    }
    
    func asData() -> Data {
        return Data([opcode, connected.rawValue])
    }
}
