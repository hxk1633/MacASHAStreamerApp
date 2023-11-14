//
//  BluetoothViewModel.swift
//  ASHA
//
//  Created by Harrison Kaiser on 11/4/23.
//
import Foundation
import CoreBluetooth
import AVFoundation


// The MIN_CE_LEN parameter for Connection Parameters based on the current
// Connection Interval
let MIN_CE_LEN_10MS_CI: UInt16 = 0x0006
let MIN_CE_LEN_20MS_CI: UInt16 = 0x000C
let MAX_CE_LEN_20MS_CI: UInt16 = 0x000C
let CE_LEN_20MS_CI_ISO_RUNNING: UInt16 = 0x0000
let CONNECTION_INTERVAL_10MS_PARAM: UInt16 = 0x0008
let CONNECTION_INTERVAL_20MS_PARAM: UInt16 = 0x0010
let CODEC_G722_16KHZ: UInt8 = 0x01
let CODEC_G722_24KHZ: UInt8 = 0x02

// Audio control point opcodes
let CONTROL_POINT_OP_START: UInt8 = 0x01
let CONTROL_POINT_OP_STOP: UInt8 = 0x02
let CONTROL_POINT_OP_STATE_CHANGE: UInt8 = 0x03
let STATE_CHANGE_OTHER_SIDE_DISCONNECTED: UInt8 = 0x00
let STATE_CHANGE_OTHER_SIDE_CONNECTED: UInt8 = 0x01
let STATE_CHANGE_CONN_UPDATE: UInt8 = 0x02

// Used to mark current_volume as not yet known, or possibly old
let VOLUME_UNKNOWN: Int8 = 127
let VOLUME_MIN: Int8 = -127

// Audio type
let AUDIOTYPE_UNKNOWN: UInt8 = 0x00

// Status of the other side Hearing Aids device
let OTHER_SIDE_NOT_STREAMING: UInt8 = 0x00
let OTHER_SIDE_IS_STREAMING: UInt8 = 0x01

// This ADD_RENDER_DELAY_INTERVALS is the number of connection intervals when
// the audio data packet is sent by Audio Engine to when the Hearing Aids device
// receives it from the air. We assume that there are 2 data buffers queued from
// audio subsystem to the bluetooth chip. Then the estimated OTA delay is two
// connection intervals.
let ADD_RENDER_DELAY_INTERVALS: UInt16 = 4

let ashaServiceCBUUID                      = CBUUID(string: "0xFDF0")
let readOnlyPropertiesCharacteristicCBUUID = CBUUID(string: "6333651e-c481-4a3e-9169-7c902aad37bb")
let audioControlPointCharacteristicCBUUID  = CBUUID(string: "f0d4de7e-4a88-476c-9d9f-1937b0996cc0")
let audioStatusCharacteristicCBUUID        = CBUUID(string: "38663f1a-e711-4cac-b641-326b56404837")
let volumeCharacteristicCBUUID             = CBUUID(string: "00e4ca9e-ab14-41e4-8823-f9e70c7e91df")
let lePsmOutPointCharacteristicCBUUID      = CBUUID(string: "2d410339-82b6-42aa-b34e-e2e01df8cc1a")

class BluetoothViewModel: NSObject, ObservableObject {
    private var hciController: IOBluetoothHostController?
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
        self.hciController = IOBluetoothHostController.default()
//        self.delegate = [[HCIDelegate alloc] init];
//        self.hciController.delegate = self.delegate;
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

extension BluetoothViewModel: CBPeripheralDelegate, StreamDelegate, IOBluetoothHostControllerDelegate {


    func startRecording() throws {

        let audioEngine = AVAudioEngine()

        let inputNode = audioEngine.inputNode
        let srate:UInt32 = UInt32(inputNode.inputFormat(forBus: 0).sampleRate)
        print("sample rate = \(srate)")
        if srate == 0 {
            return;
        }
        // Create an AVAudioConverter to perform the downsampling
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false);
        
        guard let converter = AVAudioConverter(from: inputNode.inputFormat(forBus: 0), to:targetFormat!) else {
            return;
        }
        let encoderBuffer = UnsafeMutablePointer<g722_encode_state_t>.allocate(capacity: 1)
        g722_encode_init(encoderBuffer, 64000, 0)
        var seqCounter: UInt64 = 0
        let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0,
          bufferSize: 320*srate/16000,
            format: recordingFormat) {
                (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                let n = buffer.frameLength
                let c = buffer.stride
                guard let downsampledBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat!, frameCapacity: 320) else {
                    return;
                }
                
                do {
                    try converter.convert(to: downsampledBuffer, from: buffer)
                    let encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: 160) // Adjust capacity as needed
                    let chunkData = Data(bytes: downsampledBuffer.int16ChannelData![0], count: 320 * MemoryLayout<Float>.size)
                    chunkData.withUnsafeBytes { int16Buffer in
                        if let int16Pointer = int16Buffer.bindMemory(to: Int16.self).baseAddress {
                                g722_encode(encoderBuffer, encodedData, int16Pointer, Int32(320))
                            }
                        }
                    // Convert the encodedData pointer to a Data object
                    let encodedChunk = Data(bytes: encodedData, count: 160) // Adjust count as needed
                    
                    // Append the sequence counter to the encoded chunk
                    var chunkWithSeqCounter = Data()
                    withUnsafePointer(to: &seqCounter) { chunkWithSeqCounter.append(UnsafeBufferPointer(start: $0, count: 1)) }
                    chunkWithSeqCounter.append(contentsOf: encodedChunk)
        //            withUnsafePointer(to: &seqCounter) { chunkWithSeqCounter.append(UnsafeBufferPointer(start: $0, count: 1)) }
                    // Append the G.722 encoded chunk with the sequence counter to the array
                    self.send(data: chunkWithSeqCounter);
                    
                    // Increment the sequence counter
                    seqCounter &+= 1

                } catch {
                    print("Error during audio conversion: \(error)")
                }
                
            }

        try audioEngine.start()
    }
  
    func bluetoothHCIEventNotificationMessage(_ controller: IOBluetoothHostController, in message: IOBluetoothHCIEventNotificationMessageRef) {
          print("HCI event message: \(message)")

  //        let event_code = message.move()
  //        print("event code: \(event_code)")
  //        print("event code: \(event_code.eventParameterBytes)")
  //        print("event code: \(event_code.eventParameterBytes.load(as: Int.self))")
  //        if event_code.eventParameterBytes.load(as: Int.self) == 0x3E {
  //            let codec = Codec.g722at16kHz
  //            let audiotype = AudioType.Media
  //            let volume = 20
  //            let startAudioStream = AudioControlPointStart(codecId: codec, audioType: audiotype, volumeLevel: Int8(volume), otherState: OtherState.OtherSideDisconnected)?.asData()
  //            if let startStream = startAudioStream {
  //                print("Starting stream...")
  //                if let characteristic = audioControlPointCharacteristic {
  //                    print("Writing value for audio control characteristic")
  //                    hearingDevicePeripheral?.writeValue(startStream, for: characteristic, type: CBCharacteristicWriteType.withResponse)
  //                    if let audioStatus = audioStatusCharacteristic {
  //                        sleep(2)
  //                        hearingDevicePeripheral?.setNotifyValue(true, for: audioStatus)
  //                    }
  //                }
  //            }
  //        }
      }    

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
    
    private func pcmBufferForFile(url: URL, sampleRate: Float) -> AVAudioPCMBuffer? {
        guard let newFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true) else {
            preconditionFailure()
        }
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            preconditionFailure()
        }
        guard let tempBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            preconditionFailure()
        }
        print("OG sample rate: \(tempBuffer.format.sampleRate)")

        let conversionRatio = sampleRate / Float(tempBuffer.format.sampleRate)
        let newLength = Float(audioFile.length) * conversionRatio
        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: newFormat,
                                               frameCapacity: AVAudioFrameCount(newLength)) else {
            preconditionFailure()
        }

        do { try audioFile.read(into: tempBuffer) } catch {
            preconditionFailure()
        }
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: newFormat) else {
            preconditionFailure()
        }
        var error: NSError?
        converter.convert(to: newBuffer, error: &error, withInputFrom: { (packetCount, statusPtr) -> AVAudioBuffer? in
            statusPtr.pointee = .haveData
            return tempBuffer
        })
        if error != nil {
            print("*** Conversion error: \(error!)")
        }
        return newBuffer
    }
    
    func writeAudioStream(from inputPath: String) {
        print("inputPath: \(inputPath)")
        
        let path = Bundle.main.path(forResource: inputPath, ofType: nil)!
        print("Audio file path: \(path)")
//        print("Audio file path: \(path)")
        guard let inputBuffer = pcmBufferForFile(url: URL(string: path)!, sampleRate: 16000.0) else {
            fatalError("failed to read \(inputPath)")
        }
        
        print("downsampled inputBuffer: \(inputBuffer)")
        print("downsampled inputBuffer frameLength: \(inputBuffer.frameLength)")
        print("downsampled inputBuffer frameCapacity: \(inputBuffer.frameCapacity)")
        print("downsampled inputBuffer format: \(inputBuffer.format)")
        print("downsampled inputBuffer sample rate: \(inputBuffer.format.sampleRate)")
        print("downsampled inputBuffer channel data: \(String(describing: inputBuffer.int16ChannelData))")
        print("downsampled inputBuffer channel data pointee: \(String(describing: inputBuffer.int16ChannelData?.pointee))")

        // Assuming you have an AVAudioPCMBuffer named audioBuffer
        let sampleRate = inputBuffer.format.sampleRate
        let chunkSizeInFrames = Int(0.02 * sampleRate) // 20ms in frames
        print("chunkSizeInFrame: \(chunkSizeInFrames)")

        // Create an array to store the G.722 encoded chunks with sequence counters
        var encodedChunks: [Data] = []
        var startIndex = 0
        var seqCounter: UInt64 = 0

        // Initialize G.722 encoder
        var encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: 160)
        let encoderBuffer = UnsafeMutablePointer<g722_encode_state_t>.allocate(capacity: 1)
        g722_encode_init(encoderBuffer, 64000, 0)

        while startIndex < inputBuffer.frameLength {
            let endIndex = min(startIndex + chunkSizeInFrames, Int(inputBuffer.frameLength))
            let chunkLength = endIndex - startIndex
            let chunkData = Data(bytes: inputBuffer.int16ChannelData![0], count: chunkLength * MemoryLayout<Float>.size)
            // Create a new Data object for the audio chunk
            // Encode the audio chunk with G.722
            encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: 160) // Adjust capacity as needed
            chunkData.withUnsafeBytes { int16Buffer in
                 if let int16Pointer = int16Buffer.bindMemory(to: Int16.self).baseAddress {
                     g722_encode(encoderBuffer, encodedData, int16Pointer, Int32(chunkLength))
                 }
             }
            
            // Convert the encodedData pointer to a Data object
            let encodedChunk = Data(bytes: encodedData, count: 160) // Adjust count as needed
            
            // Append the sequence counter to the encoded chunk
            var chunkWithSeqCounter = Data()
//            withUnsafePointer(to: &seqCounter) { chunkWithSeqCounter.append(UnsafeBufferPointer(start: $0, count: 1)) }
            chunkWithSeqCounter.append(contentsOf: encodedChunk)
            withUnsafePointer(to: &seqCounter) { chunkWithSeqCounter.append(UnsafeBufferPointer(start: $0, count: 1)) }
//            withUnsafePointer(to: &seqCounter) { chunkWithSeqCounter.append(UnsafeBufferPointer(start: $0, count: 1)) }
            // Append the G.722 encoded chunk with the sequence counter to the array
            send(data: chunkWithSeqCounter)
            encodedChunks.append(chunkWithSeqCounter)
            
            // Increment the sequence counter
            seqCounter &+= 1

            startIndex = endIndex
        }

        // Now, encodedChunks contains G.722 encoded Data objects with sequence counters for each 20ms chunk
        print("audioChunks: \(encodedChunks)")
        print("audioChunks size: \(encodedChunks.count)")
        
        encoderBuffer.deallocate()
        encodedData.deallocate()
        
//        let buffer = UnsafeMutablePointer<g722_encode_state_t>.allocate(capacity: Int(inputBuffer.frameLength))
//        print("buffer: \(buffer)")
//        g722_encode_init(buffer, 64000, 0)
//        print("buffer: \(buffer)")
//
//        let encodedData = UnsafeMutablePointer<g722_encode_state_t>.allocate(capacity: Int(inputBuffer.frameLength))
//        g722_encode(buffer, encodedData, inputBuffer.int16ChannelData?.pointee, Int32(inputBuffer.frameLength))
//        let data = Data(bytes: encodedData, count: 160)
        
//        buffer.deallocate()
//        encodedData.deallocate()
        
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("Stream Event occurred: \(eventCode)")
        switch eventCode {
            case Stream.Event.openCompleted:
                print("Stream is open")
                let codec = CODEC_G722_16KHZ
                let audiotype = AUDIOTYPE_UNKNOWN
                let volume = VOLUME_UNKNOWN
                let startAudioStream = AudioControlPointStart(codecId: codec, audioType: audiotype, volumeLevel: volume, otherState: OTHER_SIDE_NOT_STREAMING)
                if let startStream = startAudioStream {
                    print("Starting stream...")
                    if let characteristic = audioControlPointCharacteristic {
                        print("Writing value for audio control characteristic")
                        hearingDevicePeripheral?.writeValue(startStream.asData(), for: characteristic, type: CBCharacteristicWriteType.withResponse)
                        if let audioStatus = audioStatusCharacteristic {
                            sleep(2)
                           // hearingDevicePeripheral?.setNotifyValue(true, for: audioStatus)
                        }
                    }
                }
            case Stream.Event.endEncountered:
                print("End Encountered")
            case Stream.Event.hasBytesAvailable:
                print("Bytes are available")
              /*  if let iStream = aStream as? InputStream {
                    print("Input stream")
                    let bufLength = 1024
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLength)
                    let bytesRead = iStream.read(buffer, maxLength: bufLength)
                    print("bytesRead = \(bytesRead)")
                    if let string = String(bytesNoCopy: buffer, length: bytesRead, encoding: .utf8, freeWhenDone: false) {
                        print("Received data: \(string)")
                    }
                }*/
            case Stream.Event.hasSpaceAvailable:
                print("Space is available, audio status \(String(describing: audioStatusPointState))")
               // self.send()
            case Stream.Event.errorOccurred:
                print("Stream error")
               /* let stopAudioStream = AudioControlPointStop()?.asData()
                if let stopStream = stopAudioStream {
                    if let characteristic = audioControlPointCharacteristic {
                        hearingDevicePeripheral?.writeValue(stopStream, for: characteristic, type: CBCharacteristicWriteType.withoutResponse)
                    }
                }*/
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
        
        let bytesWritten =  ostream.write(self.outputData)
        
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

//    func write(stuff: UnsafePointer<UInt8>, to channel: CBL2CAPChannel?, withMaxLength maxLength: Int) {
//        let result = channel?.outputStream.write(stuff, maxLength: maxLength)
//        print("Write result: \(String(describing: result))")
//    }
    
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
    
    private func leUpdateConnectionCommand() {
        var request: BluetoothHCIRequestID = 1
        var nullPointer: UnsafeMutableRawPointer? = nil
        let hciController = IOBluetoothHostController.default()
        var connectionHandle: UInt16 = 0;
            print("Bluetooth devices:")
            guard let devices = IOBluetoothDevice.pairedDevices() else {
                print("No devices")
                return
            }
            for item in devices {
                if let device = item as? IOBluetoothDevice {
                    print("Name: \(device.name)");
                    print("Paired?: \(device.isPaired())")
                    print("Connected?: \(device.isConnected())")

                    // todo implemeent this if block
                    // confirmthis is correct
                    if(device.isConnected() && device.isPaired() && device.name == hearingDevicePeripheral?.name){
                        connectionHandle = device.connectionHandle;
                        hciController?.bluetoothHCILEConnectionUpdate(connectionHandle, connectionIntervalMin: 0x0008, connectionIntervalMax: 0x0008, connectionLatency:0x000A, supervisionTimeout:0x0064, minimumCELength: 0x0006, maximumCELength: 0x0006)
                    }
                }
        }
        // is this needed needed?
        /*
        var error = BluetoothHCIRequestCreate(&request, 1000, &nullPointer, 0);
        print("error \(error)")
        print("Create request: \(request)")
        
        if ((error) != 0) {
            BluetoothHCIRequestDelete(request);
            print("Couldnt create error: \(error)");
        }
        let commandSize = 12 + 3
        var command = [UInt16](repeating: 0, count: commandSize)
        command[0] = 0x0013 // OCF
        command[1] = 0x01   // OGF
        command[2] = 12     // parameter total length
        command[3] = connectionHandle // connection handle
        command[4] = 0x0010 // Conn_Interval_Min
        command[5] = 0x0010 // Conn_Interval_Max
        command[6] = 0x000A // Conn_Latency
        command[7] = 0x0064 // Supervision_Timeout
        command[8] = 0x0006 // Minimum_CE_Length
        command[9] = 0x0006 // Maximum_CE_Length

            print("Issuing HCI command")
            error = BluetoothHCISendRawCommand(request, &command, commandSize)

            if error != 0 {
                BluetoothHCIRequestDelete(request)
                print("Send HCI command Error: \(error)")
            }

        
        sleep(0x1);
        
        BluetoothHCIRequestDelete(request);*/
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
                    sleep(5)
                    writeAudioStream(from: "pcm1644m.wav")
                }
            case lePsmOutPointCharacteristicCBUUID:
                if let psmValue = psmIdentifier(from: characteristic) {
                    print(psmValue)
                    psm = psmValue
                  peripheral.openL2CAPChannel(CBL2CAPPSM(psmValue))
                  //  leUpdateConnectionCommand()
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

extension OutputStream {
    func write(_ data: Data) -> Int {
        return data.withUnsafeBytes({ (rawBufferPointer: UnsafeRawBufferPointer) -> Int in
            let bufferPointer = rawBufferPointer.bindMemory(to: UInt8.self)
            return self.write(bufferPointer.baseAddress!, maxLength: data.count)
        })
    }
}

extension Data {
    init<T>(value: T) {
        self = withUnsafePointer(to: value) { (ptr: UnsafePointer<T>) -> Data in
            return Data(buffer: UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    mutating func append<T>(value: T) {
        withUnsafePointer(to: value) { (ptr: UnsafePointer<T>) in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }
}
