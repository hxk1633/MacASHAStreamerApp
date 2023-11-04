//
//  ReadOnlyPropertiesModel.swift
//  ASHA
//
//  Created by Harrison Kaiser on 11/3/23.
//

import Foundation

enum DeviceSide: String {
    case Left = "Left"
    case Right = "Right"
}

enum BinauralType: String {
    case Monaural = "Monaural"
    case Binaural = "Binaural"
}

struct DeviceCapabilities {
    let deviceSide: DeviceSide
    let binauralType: BinauralType
    let supportsCsis: Bool
    let reserved: UInt8

    init(byte: UInt8) {
        deviceSide = (byte & 0b00000001) == 0b00000001 ? .Right : .Left
        binauralType = (byte & 0b00000010) == 0b00000010 ? .Binaural : .Monaural
        supportsCsis = (byte & 0b00000100) == 0b00000100
        reserved = byte & 0b11111000
    }
}

struct HiSyncID {
    let manufacturerId: UInt16
    let hearingAidSetId: UInt64

    init(byteData: Data) {
        print(byteData)
        manufacturerId = byteData[2...3].withUnsafeBytes { $0.load(as: UInt16.self) }
        var hearingAidSetIdValue: UInt64 = 0

        if byteData.count >= 6 {
            hearingAidSetIdValue = byteData.prefix(6).enumerated().reduce(0) { result, pair in
                let (index, byte) = pair
                return result | (UInt64(byte) << (8 * index))
            }
        }
        hearingAidSetId = hearingAidSetIdValue
    }
}

struct FeatureMap {
    let leCocSupported: Bool
    let reserved: UInt8

    init(byte: UInt8) {
        leCocSupported = (byte & 0b00000001) == 0b00000001
        reserved = byte & 0b11111110
    }
}

struct ReadOnlyProperties {
    let version: UInt8
    let deviceCapabilities: DeviceCapabilities
    let hiSyncId: HiSyncID
    let featureMap: FeatureMap
    let renderDelay: UInt16
    let reserved: UInt16
    let supportedCodecIds: UInt16
    let g722at16kHzSupported: Bool

    init?(byteData: Data) {
        guard byteData.count == 17 else {
            return nil
        }
        version = byteData.first!
        deviceCapabilities = DeviceCapabilities(byte: byteData[1])
        hiSyncId = HiSyncID(byteData: byteData)
        featureMap = FeatureMap(byte: byteData[10])
        renderDelay = UInt16(byteData[11]) | (UInt16(byteData[12]) << 8)
        reserved = UInt16(byteData[13]) | (UInt16(byteData[14]) << 8)
        supportedCodecIds = UInt16(byteData[15]) | (UInt16(byteData[16]) << 8)
        g722at16kHzSupported = (supportedCodecIds & (1 << 1)) != 0 ? true : false
    }
}

