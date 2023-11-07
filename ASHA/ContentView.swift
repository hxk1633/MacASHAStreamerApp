//
//  ContentView.swift
//  ASHA
//
//  Created by Harrison Kaiser on 11/2/23.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var bluetoothViewModel = BluetoothViewModel()
    @State var volume: Float = 0
    var body: some View {
        if bluetoothViewModel.isConnected {
            VStack {
                Text("Connected to \(bluetoothViewModel.peripheralNames.joined(separator: ", "))")
                    .font(/*@START_MENU_TOKEN@*/.title/*@END_MENU_TOKEN@*/)
//                Slider(
//                    value: Binding(get: {
//                        self.volume
//                    }, set: { (newVal) in
//                        self.volume = newVal
//                        bluetoothViewModel.setVolume(volumeLevel: UInt8(newVal))
//                    }),
//                    in: 0...128,
//                    step: 1,
//                    onEditingChanged: { editing in
//                        if editing {
//                            print("editing")
//                        }
//                    },
//                    minimumValueLabel: Text("0"),
//                    maximumValueLabel: Text("127"),
//                    label: { Text("Volume") }
//                )
//                .padding(.all)
                Text(String(volume))
                Text(buildReadOnlyPropertiesText())
                if let audioStatus = bluetoothViewModel.audioStatusPointState {
                    Text("Audio status: \(audioStatus.rawValue)\n")
                } else {
                    Text("Audio status is not available\n")
                }
                if let psmId = bluetoothViewModel.psm {
                    Text("PSM: \(psmId)\n")
                } else {
                    Text("PSM is not available\n")
                }
            }
            
        } else {
            Text("Not connected to any hearing device")
                .font(/*@START_MENU_TOKEN@*/.title/*@END_MENU_TOKEN@*/)
        }
    }
    
    func buildReadOnlyPropertiesText() -> String {
        var readOnlyPropertiesText = ""
        
        if let deviceSide = bluetoothViewModel.readOnlyPropertiesState?.deviceCapabilities.deviceSide {
            readOnlyPropertiesText += "Device side: \(deviceSide.rawValue)\n"
        } else {
            readOnlyPropertiesText += "Device side is not available\n"
        }

        if let binauralType = bluetoothViewModel.readOnlyPropertiesState?.deviceCapabilities.binauralType {
            readOnlyPropertiesText += "Binaural type: \(binauralType.rawValue)\n"
        } else {
            readOnlyPropertiesText += "Binaural type is not available\n"
        }

        if let supportsCsis = bluetoothViewModel.readOnlyPropertiesState?.deviceCapabilities.supportsCsis {
            readOnlyPropertiesText += supportsCsis ? "Device supports CSIS\n" : "Device does not support CSIS\n"
        } else {
            readOnlyPropertiesText += "CSIS information is not available\n"
        }

        if let manufacturerId = bluetoothViewModel.readOnlyPropertiesState?.hiSyncId.manufacturerId {
            readOnlyPropertiesText += "Manufacturer ID (Company identifier assigned by BTSIG): \(manufacturerId)\n"
        } else {
            readOnlyPropertiesText += "Manufacturer ID is not available\n"
        }

        if let hearingAidSetId = bluetoothViewModel.readOnlyPropertiesState?.hiSyncId.hearingAidSetId {
            readOnlyPropertiesText += "Unique hearing aid set ID: \(hearingAidSetId)\n"
        } else {
            readOnlyPropertiesText += "Hearing aid set ID is not available\n"
        }

        if let leCocSupported = bluetoothViewModel.readOnlyPropertiesState?.featureMap.leCocSupported {
            readOnlyPropertiesText += leCocSupported ? "LE CoC audio output streaming supported\n" : "LE CoC audio output streaming not supported\n"
        } else {
            readOnlyPropertiesText += "LE CoC audio output streaming support information is not available\n"
        }

        if let renderDelay = bluetoothViewModel.readOnlyPropertiesState?.renderDelay {
            readOnlyPropertiesText += "Render delay (milliseconds): \(renderDelay)\n"
        } else {
            readOnlyPropertiesText += "Render delay information is not available\n"
        }

        if let supportedCodecIds = bluetoothViewModel.readOnlyPropertiesState?.supportedCodecIds {
            readOnlyPropertiesText += "Supported codec IDs: \(supportedCodecIds)\n"
        } else {
            readOnlyPropertiesText += "Supported codec IDs information is not available\n"
        }

        if let g722at16kHzSupported = bluetoothViewModel.readOnlyPropertiesState?.g722at16kHzSupported {
            readOnlyPropertiesText += g722at16kHzSupported ? "G.722 @ 16 kHz is supported\n" : "G.722 @ 16 kHz is not supported\n"
        } else {
            readOnlyPropertiesText += "G.722 @ 16 kHz support information is not available\n"
        }
        
        return readOnlyPropertiesText
    }
}

#Preview {
    ContentView()
}
