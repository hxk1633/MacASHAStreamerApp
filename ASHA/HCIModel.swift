//
//  HCIModel.swift
//  ASHA
//
//  Created by Harrison Kaiser on 11/8/23.
//

import Foundation

struct HCIConnectionUpdateCommand {
    let packettype: UInt8
    let opcode: UInt16
    let parameterlength: UInt8
    let connection_handle: UInt16
    let conn_interval_min: UInt16
    let conn_interval_max: UInt16
    let conn_latency: UInt16
    let supervision_timeout: UInt16
    let minimum_ce_length: UInt16
    let maximum_ce_length: UInt16

    init?(connectionHandle: UInt16, connIntervalMin: UInt16,
        connIntervalMax: UInt16, connLatency: UInt16, supervisionTimeout: UInt16, minimumCELength: UInt16, maximumCELength: UInt16 ) {
        packettype = 0x01
        opcode = 0x2013
        parameterlength = 0x7
        connection_handle = connectionHandle
        conn_interval_min = connIntervalMin
        conn_interval_max = connIntervalMax
        conn_latency = connLatency
        supervision_timeout = supervisionTimeout
        minimum_ce_length = minimumCELength
        maximum_ce_length = maximumCELength
    }
    
    func asData() -> Data {
        var commandPacket = Data()
        var packet_type = packettype
        var op_code = opcode
        var parm_length = parameterlength
        var params = [connection_handle, conn_interval_min, conn_interval_max,
                      conn_latency, supervision_timeout, minimum_ce_length, maximum_ce_length]
        var bytes: [UInt8] = []
        
        withUnsafeBytes(of: &packet_type) { bufferPointer in
            bytes.append(contentsOf: bufferPointer)
        }
        
        withUnsafeBytes(of: &op_code) { bufferPointer in
            bytes.append(contentsOf: bufferPointer)
        }
        
        withUnsafeBytes(of: &parm_length) { bufferPointer in
            bytes.append(contentsOf: bufferPointer)
        }
        
        withUnsafeBytes(of: &params) { bufferPointer in
            bytes.append(contentsOf: bufferPointer)
        }

        return commandPacket
    }
}

struct HCIEvent {
    let eventcode: UInt8
    let paramlength: UInt8
    let params: Data
    
    init?(byteData: Data) {
        eventcode = byteData.first!
        paramlength = byteData[1]
        params = byteData[2...]
    }
    
    func eventCode() -> UInt8 {
        return eventcode
    }
    
    func parameterLength() -> UInt8 {
        return paramlength
    }
    
    func parameters() -> Data {
        return params
    }
}
