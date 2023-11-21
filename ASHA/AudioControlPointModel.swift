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

struct AudioControlPointStart {
    let opcode: UInt8
    let audiotype: UInt8
    let codec: UInt8
    let volume: Int8
    let otherstate: UInt8

    init?(codecId: UInt8, audioType: UInt8, volumeLevel: Int8, otherState: UInt8) {
        opcode = CONTROL_POINT_OP_START
        audiotype = audioType
        codec = codecId
        volume = volumeLevel
        otherstate = otherState
    }
    
    func asData() -> Data {
        return Data([opcode, codec, audiotype, uint8(volume), otherstate])
    }
}

struct AudioControlPointStop {
    let opcode: UInt8
    init?() {
        opcode = CONTROL_POINT_OP_STOP
    }
    
    func asData() -> Data {
        return Data([opcode])
    }
}

struct AudioControlPointStatus {
    let opcode: UInt8
    let connected: UInt8
    let interval: UInt8
    
    init?(connectedStatus: UInt8, intervalCurrent: UInt8) {
        opcode = CONTROL_POINT_OP_STATE_CHANGE
        connected = connectedStatus
        interval = intervalCurrent
    }
    
    func asData() -> Data {
        return Data([opcode, connected, interval])
    }
}
