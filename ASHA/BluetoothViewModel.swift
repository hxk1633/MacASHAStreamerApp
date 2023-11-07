//
//  BluetoothViewModel.swift
//  ASHA
//
//  Created by Harrison Kaiser on 11/4/23.
//
import Foundation
import CoreBluetooth
import AVFoundation
import IOBluetooth

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
    private var audioStatusCharacteristic: CBCharacteristic?
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    private var queueQueue = DispatchQueue(label: "queue queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    private var outputData = Data()
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
    
    func readAndDownsamplePCMBuffer(url: URL, targetSampleRate: Double) -> AVAudioPCMBuffer? {
        print("Reading audio file...")
        guard let input = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false) else {
            return nil
        }
        
        print("Creating AVAudioFormat...")
        // Create an AVAudioFormat for the target sample rate
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: false)
        
        print("Creating AVAudioConverter...")
        // Create an AVAudioConverter to perform the downsampling
        guard let converter = AVAudioConverter(from: input.processingFormat, to: targetFormat!) else {
            return nil
        }
        
        print("Creating AVAudioPCMBuffer...")
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat!, frameCapacity: AVAudioFrameCount(input.length)) else {
            return nil
        }
        
        do {
            try input.read(into: buffer)
            
            print("Creating buffer for downsampled audio...")
            // Create a buffer for the downsampled audio
            guard let downsampledBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat!, frameCapacity: buffer.frameLength) else {
                return nil
            }
            
            print("Downsampling audio...")
            // Perform the downsampling
            do {
                try converter.convert(to: downsampledBuffer, from: buffer)
            } catch {
                print("Error during audio conversion: \(error)")
            }
            
            return downsampledBuffer
        } catch {
            return nil
        }
    }
    
    func writeAudioStream(from inputPath: String) {
        let path = Bundle.main.path(forResource: inputPath, ofType: nil)!
        print("Audio file path: \(path)")
        guard let inputBuffer = readAndDownsamplePCMBuffer(url: URL(string: path)!, targetSampleRate: 16000.0) else {
            fatalError("failed to read \(inputPath)")
        }

        guard let inputInt16ChannelData = inputBuffer.int16ChannelData else {
            fatalError("failed to obtain underlying input buffer")
        }

        let buffer = UnsafeMutablePointer<g722_encode_state_t>.allocate(capacity: Int(inputBuffer.frameLength))
        g722_encode_init(buffer, 64000, 0)
        print("inputBuffer.frameLegnth \(Int(inputBuffer.frameLength))")
        
        let encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(inputBuffer.frameLength))
        g722_encode(buffer, encodedData, inputInt16ChannelData[0], Int32(inputBuffer.frameLength))
        let data = Data(bytes: encodedData, count: Int(inputBuffer.frameLength))
        send(data: data)
        
        buffer.deallocate()
        encodedData.deallocate()
        
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("Stream Event occurred: \(eventCode)")
        switch eventCode {
            case Stream.Event.openCompleted:
                print("Stream is open")
                let codec = Codec.g722at16kHz
                let audiotype = AudioType.Media
                let volume = 0
                let startAudioStream = AudioControlPointStart(codecId: codec, audioType: audiotype, volumeLevel: Int8(volume), otherState: OtherState.OtherSideDisconnected)?.asData()
                if let startStream = startAudioStream {
                    print("Starting stream...")
                    if let characteristic = audioControlPointCharacteristic {
                        print("Writing value for audio control characteristic")
                        hearingDevicePeripheral?.writeValue(startStream, for: characteristic, type: CBCharacteristicWriteType.withResponse)
                        if let audioStatus = audioStatusCharacteristic {
                            hearingDevicePeripheral?.setNotifyValue(true, for: audioStatus)
                        }
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
                print("Space is available, audio status \(audioStatusPointState)")
                self.send()
//                writeAudioStream(from: "batman_theme_x.wav")

//            if audioStatusPointState == AudioStatusPoint.StatusOK {
//                    print("Writing audio file to peripheral")
//                    writeAudioStream(from: "batman_theme_x.wav")
//                } else {
//                    print("Didn't write anything, error audio status: \(String(describing: audioStatusPointState))")
//                }
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
    
    private func send(data: Data) -> Void {
        queueQueue.sync  {
            self.outputData.append(data)
        }
        self.send()
    }
    
    private func send() {
        
        guard let ostream = self.l2capChannel?.outputStream, !self.outputData.isEmpty, ostream.hasSpaceAvailable  else{
            return
        }
        
        let bytesWritten = self.outputData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            if let baseAddress = ptr.baseAddress {
                return ostream.write(baseAddress.assumingMemoryBound(to: UInt8.self), maxLength: ptr.count)
            } else {
                return 0
            }
        }

//        let bytesWritten =  ostream.write(self.outputData, maxLength: 160)
        
        print("bytesWritten = \(bytesWritten)")
//        self.sentDataCallback?(self,bytesWritten)
        queueQueue.sync {
            if bytesWritten < outputData.count {
                outputData = outputData.advanced(by: bytesWritten)
            } else {
                outputData.removeAll()
            }
        }
    }

    func write(stuff: UnsafePointer<UInt8>, to channel: CBL2CAPChannel?, withMaxLength maxLength: Int) {
        let result = channel?.outputStream.write(stuff, maxLength: maxLength)
        print("Write result: \(String(describing: result))")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
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
            if characteristic.uuid.data == lePsmOutPointCharacteristicCBUUID.data {
                print("read value from psm characteristic")
                peripheral.readValue(for: characteristic)
            }
            if characteristic.uuid.data == readOnlyPropertiesCharacteristicCBUUID.data {
                print("read value from read only properties")
                peripheral.readValue(for: characteristic)
            }
            if characteristic.uuid.data == audioStatusCharacteristicCBUUID.data {
                print("set audio status characteristic")
                audioStatusCharacteristic = characteristic
            }
//            if characteristic.properties.contains(.notify) {
//                print("\(characteristic.uuid): properties contains .notify")
//                peripheral.setNotifyValue(true, for: characteristic)
//            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        switch characteristic.uuid {
            case readOnlyPropertiesCharacteristicCBUUID:
                readOnlyPropertiesState = readOnlyProperties(from: characteristic)
            case audioStatusCharacteristicCBUUID:
                audioStatusPointState = audioStatusPoint(from: characteristic)
                print("audio status update: \(String(describing: audioStatusPointState))")
                if audioStatusPointState == AudioStatusPoint.StatusOK {
                    print("writeAudioStream()")
                    writeAudioStream(from: "batman_theme_x.wav")
                }
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
               print("Error setting a value for characteristic, \(characteristic), \(error.localizedDescription)")
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
        self.l2capChannel?.inputStream.delegate = self
        self.l2capChannel?.outputStream.delegate = self
        self.l2capChannel?.inputStream.schedule(in: RunLoop.main, forMode: .default)
        self.l2capChannel?.outputStream.schedule(in: RunLoop.main, forMode: .default)
        self.l2capChannel?.inputStream.open()
        self.l2capChannel?.outputStream.open()
//        self.l2capChannel = channel
//        self.outputStream = channel.outputStream
//        self.outputStream!.delegate = self
//        self.outputStream!.schedule(in: .main, forMode: .default)
//        self.outputStream!.open()
//
//        self.inputStream = channel.inputStream
//        self.inputStream!.delegate = self
//        self.inputStream!.schedule(in: .main, forMode: .default)
//        self.inputStream!.open()
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
