//
//  BluetoothViewModel.swift
//  ASHA
//
//  Created by Harrison Kaiser on 11/4/23.
//
import Foundation
import CoreBluetooth
import AVFoundation

let ashaServiceCBUUID                      = CBUUID(string: "0xFDF0")
let readOnlyPropertiesCharacteristicCBUUID = CBUUID(string: "6333651e-c481-4a3e-9169-7c902aad37bb")
let audioControlPointCharacteristicCBUUID  = CBUUID(string: "f0d4de7e-4a88-476c-9d9f-1937b0996cc0")
let audioStatusCharacteristicCBUUID        = CBUUID(string: "38663f1a-e711-4cac-b641-326b56404837")
let volumeCharacteristicCBUUID             = CBUUID(string: "00e4ca9e-ab14-41e4-8823-f9e70c7e91df")
let lePsmOutPointCharacteristicCBUUID      = CBUUID(string: "2d410339-82b6-42aa-b34e-e2e01df8cc1a")

class BluetoothViewModel: NSObject, ObservableObject {
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var l2capChannel: CBL2CAPChannel?
    private var hearingDevicePeripheral: CBPeripheral?
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    @Published var isConnected: Bool = false
    @Published var peripheralNames: [String] = []
    @Published var readOnlyPropertiesState: ReadOnlyProperties?
    @Published var audioStatusPointState: AudioStatusPoint?
    @Published var psm: CBL2CAPPSM?
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }
}

extension BluetoothViewModel: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            self.centralManager?.scanForPeripherals(withServices: [ashaServiceCBUUID])
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print(peripheral)
        peripheralNames.append(peripheral.name ?? "Unnamed")
        hearingDevicePeripheral = peripheral
        if let hearingDevice = hearingDevicePeripheral {
            hearingDevice.delegate = self
            self.centralManager?.stopScan()
            self.centralManager?.connect(hearingDevice)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected!")
        isConnected = true
        if let hearingDevice = hearingDevicePeripheral {
            hearingDevice.discoverServices([ashaServiceCBUUID])
        }
    }
    
}

extension BluetoothViewModel: CBPeripheralDelegate, StreamDelegate {
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("Stream Event occurred: \(eventCode)")
        switch eventCode {
            case Stream.Event.openCompleted:
                print("Stream is open")
            case Stream.Event.endEncountered:
                print("End Encountered")
            case Stream.Event.hasBytesAvailable:
                print("Bytes are available")
                if let iStream = aStream as? InputStream {
                    print("Input stream")
                    let bufLength = 1024
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLength)
                    let bytesRead = iStream.read(buffer, maxLength: bufLength)
                    print("bytesRead = \(bytesRead)")
                    if let string = String(bytesNoCopy: buffer, length: bytesRead, encoding: .utf8, freeWhenDone: false) {
                        print("Received data: \(string)")
                    }
                }
            case Stream.Event.hasSpaceAvailable:
                print("Space is available")
                // TODO: Write audio data to peripheral here after writing <<Start>> opcode to AudioControlPoint chracteristic
                // We need to use these methods in the following order:
                //  1. hearingDevicePeripheral.writeValue(Data, for: CBCharacteristic, type: CBCharacteristicWriteType)
                //  2. AVAudioEngine or audio libary for processing audio data
                //  3. write(stuff: UnsafePointer<UInt8>, to channel: CBL2CAPChannel?, withMaxLength maxLength: Int)
            case Stream.Event.errorOccurred:
                print("Stream error")
            default:
                print("Unknown stream event")
            }
    }

    func write(stuff: UnsafePointer<UInt8>, to channel: CBL2CAPChannel?, withMaxLength maxLength: Int) {
        let result = channel?.outputStream.write(stuff, maxLength: maxLength)
        print("Write result: \(String(describing: result))")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            print(service)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            print(characteristic)
            if characteristic.properties.contains(.read) {
                print("\(characteristic.uuid): properties contains .read")
                peripheral.readValue(for: characteristic)
            }
            if characteristic.properties.contains(.notify) {
                print("\(characteristic.uuid): properties contains .notify")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        switch characteristic.uuid {
            case readOnlyPropertiesCharacteristicCBUUID:
                readOnlyPropertiesState = readOnlyProperties(from: characteristic)
            case audioStatusCharacteristicCBUUID:
                audioStatusPointState = audioStatusPoint(from: characteristic)
            case lePsmOutPointCharacteristicCBUUID:
                if let psmValue = psmIdentifier(from: characteristic) {
                    print(psmValue)
                    psm = psmValue
                    peripheral.openL2CAPChannel(CBL2CAPPSM(psmValue))
                }
            default:
                print("Unhandled Characteristic UUID: \(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("Peripheral successfully set value for characteristic: \(characteristic)")
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        print("Peripheral \(peripheral) is again ready to send characteristic updates")
    }
 
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
               print("Error opening l2cap channel - \(error.localizedDescription)")
               return
        }
        guard let channel = channel else {
           return
        }
        print("Opened channel \(channel)")
        self.l2capChannel = channel
        self.outputStream = channel.outputStream
        self.outputStream!.delegate = self
        self.outputStream!.schedule(in: .main, forMode: .default)
        self.outputStream!.open()

        self.inputStream = channel.inputStream
        self.inputStream!.delegate = self
        self.inputStream!.schedule(in: .main, forMode: .default)
        self.inputStream!.open()
    }

    private func psmIdentifier(from characteristic: CBCharacteristic) -> UInt16? {
        guard let characteristicData = characteristic.value else { return nil }
        let psmIdentifier = UInt16(characteristicData[0]) | (UInt16(characteristicData[1]) << 8)
        return psmIdentifier
    }
    
    private func readOnlyProperties(from characteristic: CBCharacteristic) -> ReadOnlyProperties? {
        guard let characteristicData = characteristic.value,
              let readOnlyProperties = ReadOnlyProperties(byteData: characteristicData) else { return nil }
        return readOnlyProperties
    }

    private func audioStatusPoint(from characteristic: CBCharacteristic) -> AudioStatusPoint? {
        guard let characteristicData = characteristic.value,
                let byte = characteristicData.first else { return nil }

        switch Int8(bitPattern: byte) {
            case 0: return AudioStatusPoint.StatusOK
            case -1: return AudioStatusPoint.UnknownCommand
            case -2: return AudioStatusPoint.IllegalParameters
            default:
                return nil
        }
    }
}

extension BluetoothViewModel: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            peripheral.publishL2CAPChannel(withEncryption: true)
        }
    }
}
