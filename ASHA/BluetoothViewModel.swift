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
    private var audioControlPointCharacteristic: CBCharacteristic?
    private var volumeCharacteristic: CBCharacteristic?
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    @Published var isConnected: Bool = false
    @Published var peripheralNames: [String] = []
    @Published var readOnlyPropertiesState: ReadOnlyProperties?
    @Published var audioStatusPointState: AudioStatusPoint?
    @Published var psm: CBL2CAPPSM?
    @Published var volume: UInt8?
    
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

    func readPCMBuffer(url: URL) -> AVAudioPCMBuffer? {
        guard let input = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false) else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)) else {
            return nil
        }
        do {
            try input.read(into: buffer)
        } catch {
            return nil
        }

        return buffer
    }

    func writePCMBuffer(url: URL, buffer: AVAudioPCMBuffer) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: buffer.format.settings[AVFormatIDKey] ?? kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: buffer.format.settings[AVNumberOfChannelsKey] ?? 2,
            AVSampleRateKey: buffer.format.settings[AVSampleRateKey] ?? 44100,
            AVLinearPCMBitDepthKey: buffer.format.settings[AVLinearPCMBitDepthKey] ?? 16
        ]

        do {
            let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
            try output.write(from: buffer)
        } catch {
            throw error
        }
    }
    
    func writeAudioStream(from inputPath: String) {
        let path = Bundle.main.path(forResource: inputPath, ofType: nil)!
        print(path)
        guard let inputBuffer = readPCMBuffer(url: URL(string: path)!) else {
            fatalError("failed to read \(inputPath)")
        }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: inputBuffer.format, frameCapacity: inputBuffer.frameLength) else {
            fatalError("failed to create a buffer for writing")
        }
        guard let inputInt16ChannelData = inputBuffer.int16ChannelData else {
            fatalError("failed to obtain underlying input buffer")
        }
        guard let outputInt16ChannelData = outputBuffer.int16ChannelData else {
            fatalError("failed to obtain underlying output buffer")
        }
        print("Channel count: \(Int(inputBuffer.format.channelCount))")
        for channel in 0 ..< Int(inputBuffer.format.channelCount) {
            let p1: UnsafeMutablePointer<Int16> = inputInt16ChannelData[channel]
            let p2: UnsafeMutablePointer<Int16> = outputInt16ChannelData[channel]

            for i in 0 ..< Int(inputBuffer.frameLength) {
                p2[i] = p1[i]
            }
        }

        outputBuffer.frameLength = inputBuffer.frameLength
        // TODO: Encode buffer as G.722 frame and write to L2Cap channel using write function
        let buffer = UnsafeMutablePointer<g722_encode_state_t>.allocate(capacity: 16)
        g722_encode_init(buffer, 64000, 0)

        let encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(outputBuffer.frameLength))
        g722_encode(buffer, encodedData, outputInt16ChannelData[0], Int32(outputBuffer.frameLength))

        // TODO: Write the encoded data to a destination (e.g., a file or network)
        // Replace 'destinationURL' with the actual destination URL where you want to write the data.
        write(stuff: encodedData, to: self.l2capChannel, withMaxLength: 160)
        
        // Don't forget to deallocate memory when you're done
        buffer.deallocate()
        encodedData.deallocate()
        
    }

    // Test function write buffer from wav file to another wave file
    func copyPCMBuffer(from inputPath: String, to outputPath: String) {
        guard let inputBuffer = readPCMBuffer(url: URL(string: inputPath)!) else {
            fatalError("failed to read \(inputPath)")
        }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: inputBuffer.format, frameCapacity: inputBuffer.frameLength) else {
            fatalError("failed to create a buffer for writing")
        }
        guard let inputInt16ChannelData = inputBuffer.int16ChannelData else {
            fatalError("failed to obtain underlying input buffer")
        }
        guard let outputInt16ChannelData = outputBuffer.int16ChannelData else {
            fatalError("failed to obtain underlying output buffer")
        }
        for channel in 0 ..< Int(inputBuffer.format.channelCount) {
            let p1: UnsafeMutablePointer<Int16> = inputInt16ChannelData[channel]
            let p2: UnsafeMutablePointer<Int16> = outputInt16ChannelData[channel]

            for i in 0 ..< Int(inputBuffer.frameLength) {
                p2[i] = p1[i]
            }
        }

        outputBuffer.frameLength = inputBuffer.frameLength

        do {
            try writePCMBuffer(url: URL(string: outputPath)!, buffer: outputBuffer)
        } catch {
            fatalError("failed to write \(outputPath)")
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("Stream Event occurred: \(eventCode)")
        switch eventCode {
            case Stream.Event.openCompleted:
                print("Stream is open")
                let codec = Codec.g722at16kHz
                let audiotype = AudioType.Media
                let volume = 30
                let startAudioStream = AudioControlPointStart(codecId: codec, audioType: audiotype, volumeLevel: Int8(volume), otherState: OtherState.OtherSideDisconnected)?.asData()
                if let startStream = startAudioStream {
                    print("Starting stream...")
                    if let characteristic = audioControlPointCharacteristic {
                        print("Writing value for audio control characteristic")
                        hearingDevicePeripheral?.writeValue(startStream, for: characteristic, type: CBCharacteristicWriteType.withResponse)
                    }
                }
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
                writeAudioStream(from: "batman_theme_x.wav")
            case Stream.Event.errorOccurred:
                print("Stream error")
                let stopAudioStream = AudioControlPointStop()?.asData()
                if let stopStream = stopAudioStream {
                    if let characteristic = audioControlPointCharacteristic {
                        hearingDevicePeripheral?.writeValue(stopStream, for: characteristic, type: CBCharacteristicWriteType.withoutResponse)
                    }
                }
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
            print("Characteristic uuid discovered: \(characteristic)")
            if characteristic.uuid.data == audioControlPointCharacteristicCBUUID.data {
                print("set audio control characteristic")
                audioControlPointCharacteristic = characteristic
            }
            if characteristic.uuid.data == volumeCharacteristicCBUUID.data {
                print("set volume characteristic")
                volumeCharacteristic = characteristic
            }
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
                print("audio status update: \(audioStatusPointState)")
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
        if let error = error {
               print("Error setting a value for characteristic - \(error.localizedDescription)")
               return
        }
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
    
    public func setVolume(volumeLevel: UInt8) {
        print("setVolume called with \(volumeLevel)")
        if let characteristic = volumeCharacteristic {
            print("Volume set to \(volumeLevel)")
            hearingDevicePeripheral?.writeValue(Data([volumeLevel]), for: characteristic, type: CBCharacteristicWriteType.withoutResponse)
        }
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
