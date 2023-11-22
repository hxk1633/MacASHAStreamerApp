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
let AUDIOTYPE_RINGTONE: UInt8 = 0x01
let AUDIO_TYPE_PHONECALL: UInt8 = 0x02
let AUDIOTYPE_MEDIA: UInt8 = 0x03

// Status of the other side Hearing Aids device
let OTHER_SIDE_NOT_STREAMING: UInt8 = 0x00
let OTHER_SIDE_IS_STREAMING: UInt8 = 0x01

let G722_PACKED: Int32 = 0x0002
// If true, use input microphone
let AUDIO_MIC = true

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
//    private var l2capChannel: CBL2CAPChannel?
    private var l2capChannel: IOBluetoothL2CAPChannel?
    private var hearingDevicePeripheral: CBPeripheral?
    private var audioControlPointCharacteristic: CBCharacteristic?
    private var volumeCharacteristic: CBCharacteristic?
    private var audioStatusCharacteristic: CBCharacteristic?
    private var outputStream: OutputStream?
    private let audioEngine = AVAudioEngine()
    private var inputStream: InputStream?
    private var encodedData: [Data]?
    private var queueQueue = DispatchQueue(label: "queue queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem, target: nil)
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
        if central.state == .unauthorized {
            print("App is not authorized to use the Bluetooth Low Engery role")
        }
        if central.state == .unsupported {
            print("This device does not support the Bluetooth low engery central role")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        peripheralNames.append(peripheral.name ?? "Unnamed")
        hearingDevicePeripheral = peripheral
        if let hearingDevice = hearingDevicePeripheral {
            hearingDevice.delegate = self
            self.centralManager?.stopScan()
            let connectOptions: [String: Any] = [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ]
            self.centralManager?.connect(hearingDevice, options: connectOptions)
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

extension BluetoothViewModel: CBPeripheralDelegate, StreamDelegate, IOBluetoothHostControllerDelegate, IOBluetoothL2CAPChannelDelegate {
   
    func segment(of buffer: AVAudioPCMBuffer, from startFrame: AVAudioFramePosition, to endFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let framesToCopy = AVAudioFrameCount(endFrame - startFrame)
        guard let segment = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: framesToCopy) else { return nil }

        let sampleSize = buffer.format.streamDescription.pointee.mBytesPerFrame

        let srcPtr = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dstPtr = UnsafeMutableAudioBufferListPointer(segment.mutableAudioBufferList)
        for (src, dst) in zip(srcPtr, dstPtr) {
            memcpy(dst.mData, src.mData?.advanced(by: Int(startFrame) * Int(sampleSize)), Int(framesToCopy) * Int(sampleSize))
        }

        segment.frameLength = framesToCopy
        return segment
    }
    
    func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        print("l2cap Channel Open Complete")
    }

    func startRecording() throws {

        let time: Double = 0.02;
        let inputNode = audioEngine.inputNode
        let srate = inputNode.inputFormat(forBus: 0).sampleRate
        print("sample rate = \(srate)")
        if srate == 0 {
            return;
        }
        
        // Create an AVAudioConverter to perform the downsampling
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false);
        print("passsed")
        var encoderState = g722_encode_init(nil, 64000, G722_PACKED)
        var seqCounter: UInt8 = 0
        let recordingFormat = inputNode.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: recordingFormat, to:targetFormat!) else {
            return;
            
        }
        let buffersize=Int(srate * time)
        print("bufferSize \(buffersize)")
        inputNode.installTap(onBus: 0,
            bufferSize: UInt32( buffersize),
                             format: recordingFormat) {
            (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
        
            var startIndex = 0
            while startIndex < buffer.frameLength {
                let endIndex = min(startIndex + buffersize, Int(buffer.frameLength))
                let chunkLength = endIndex - startIndex
                let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = AVAudioConverterInputStatus.haveData
                    return self.segment(of: buffer, from: AVAudioFramePosition(startIndex), to: AVAudioFramePosition(endIndex))
                }

                guard let downsampledBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat!, frameCapacity: UInt32(targetFormat.unsafelyUnwrapped.sampleRate * time)) else {
                    return;
                }
                
                do {
                    let status = converter.convert(to: downsampledBuffer, error: nil, withInputFrom: inputCallback)
                    print( "Downsample AVAudioConverterOutputStatus hasData: \(status.rawValue == 0)")
                    print( "Downsampled PCM: \(downsampledBuffer.frameLength)")
                    
                    var g722_size: Int32 = 0
                    let encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(downsampledBuffer.frameLength/2)) // Adjust capacity as needed
                    let chunkData = Data(bytes: downsampledBuffer.int16ChannelData![0], count: Int(downsampledBuffer.frameLength) * MemoryLayout<Int16>.size)
                    chunkData.withUnsafeBytes { int16Buffer in
                        if let int16Pointer = int16Buffer.bindMemory(to: Int16.self).baseAddress {
                            g722_size =  g722_encode(encoderState, encodedData, int16Pointer, Int32(downsampledBuffer.frameLength))
                            print( "g722 size: \(g722_size)")
                        }
                    }
                    // Convert the encodedData pointer to a Data object
                    let encodedChunk = Data(bytes: encodedData, count: Int(g722_size)) // Adjust count as needed
                    
                    // Append the sequence counter to the encoded chunk
                    var chunkWithSeqCounter = Data()
                    withUnsafePointer(to: &seqCounter) { chunkWithSeqCounter.append(UnsafeBufferPointer(start: $0, count: 1)) }
                    chunkWithSeqCounter.append(contentsOf: encodedChunk)
                    // Append the G.722 encoded chunk with the sequence counter to the array
                    self.send(data: chunkWithSeqCounter);
                    // self.l2capChannel?.outputStream.write(chunkWithSeqCounter)
                    // Increment the sequence counter
                    if seqCounter == 255 {
                        seqCounter &= 0
                    } else {
                        seqCounter &+= 1
                    }
//                    seqCounter &+= 1
                    startIndex = endIndex;
                    if( buffersize < buffer.frameLength){
                        usleep(UInt32(time*1000000)) // 20ms wait
                    }
                } catch {
                    print("Error during audio conversion: \(error)")
                }
            }}
        audioEngine.prepare()
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

    
    func writeAudioStream(from inputPath: String) -> [Data] {
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
        var seqCounter: UInt8 = 0

        // Initialize G.722 encoder
        var encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: 160)
        var encoderState = g722_encode_init(nil, 64000, G722_PACKED)
        while startIndex < inputBuffer.frameLength {
            let endIndex = min(startIndex + chunkSizeInFrames, Int(inputBuffer.frameLength))
            let chunkLength = endIndex - startIndex
            var chunkData: Data = Data()
            if let segment = segment(of: inputBuffer, from: AVAudioFramePosition(startIndex), to: AVAudioFramePosition(endIndex)) {
                chunkData = Data(bytes: segment.int16ChannelData![0], count: chunkLength * MemoryLayout<UInt16>.size)
            }
            // Create a new Data object for the audio chunk
            // Encode the audio chunk with G.722
            var size: Int32 = 0;
            encodedData = UnsafeMutablePointer<UInt8>.allocate(capacity: 160) // Adjust capacity as needed
            chunkData.withUnsafeBytes { int16Buffer in
                 if let int16Pointer = int16Buffer.bindMemory(to: Int16.self).baseAddress {
                    size = g722_encode(encoderState, encodedData, int16Pointer, Int32(chunkLength))
                    print("Encoded size: \(size)")
            
                 }
             }
            // Convert the encodedData pointer to a Data object
            
            let encodedChunk = Data(bytes: encodedData, count: Int(size)) // Adjust count as needed
            
            // Append the sequence counter to the encoded chunk
            var chunkWithSeqCounter = Data()
            withUnsafePointer(to: &seqCounter) { chunkWithSeqCounter.append(UnsafeBufferPointer(start: $0, count: 1)) }
            chunkWithSeqCounter.append(contentsOf: encodedChunk)
            // Append the G.722 encoded chunk with the sequence counter to the array
            encodedChunks.append(chunkWithSeqCounter)
            
            // Increment the sequence counter
            if seqCounter == 255 {
                seqCounter &= 0
            } else {
                seqCounter &+= 1
            }
            startIndex = endIndex
        }

        // Now, encodedChunks contains G.722 encoded Data objects with sequence counters for each 20ms chunk
        print("audioChunks: \(encodedChunks)")
        print("audioChunks size: \(encodedChunks.count)")
        
        //encoderBuffer.deallocate()
        encodedData.deallocate()
    
        return encodedChunks
        
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("Stream Event occurred: \(eventCode)")
        switch eventCode {
            case Stream.Event.openCompleted:
                print("Stream is open")
            
            let statusUpdate = AudioControlPointStatus(connectedStatus: CONTROL_POINT_OP_STATE_CHANGE, intervalCurrent: UInt8(CONNECTION_INTERVAL_20MS_PARAM))

            if let characteristic = audioControlPointCharacteristic {
                if let status = statusUpdate {
                hearingDevicePeripheral?.writeValue(status.asData(), for: characteristic, type: CBCharacteristicWriteType.withoutResponse)
            }}
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
                print("Space is available, audio status \(String(describing: audioStatusPointState))")
                // self.send()
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
    
    private func send(data: Data) {
        // Assuming self.l2capChannel is an IOBluetoothL2CAPChannel
        guard let l2capChannel = self.l2capChannel else {
            // Handle the case where l2capChannel is nil, if needed
            return
        }

        // Convert Data to UnsafeMutableRawPointer
        let dataPointer = UnsafeMutableRawPointer(mutating: (data as NSData).bytes)

        // Get the length of the data
        let dataLength = UInt16(data.count)

        // Call the writeSync method
        l2capChannel.writeSync(dataPointer, length: dataLength)
    }
    
//    private func send(data: Data) -> Void {
//        self.l2capChannel?.writeSync(<#T##data: UnsafeMutableRawPointer!##UnsafeMutableRawPointer!#>, length: <#T##UInt16#>)
//        guard let ostream = self.l2capChannel?.outputStream, !data.isEmpty, ostream.hasSpaceAvailable  else{
//            print("Space avaliable:  \(self.l2capChannel?.outputStream.hasSpaceAvailable)")
//            return
//        }
//        
//        let bytesWritten =  ostream.write(data)
//        
//        print("bytesWritten = \(bytesWritten)")
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
                    
                    if AUDIO_MIC {
                        do{
                            try startRecording();
                        }
                        catch{
                            print("Error during audio recording: \(error)")
                        }
                    } else {
                        var seqCount: UInt8 = 0
                        for (index, frame) in encodedData!.enumerated() {
                            print("Frame \(index) sequence byte: \(seqCount): \(frame)")
//                            if index != 0 {
//                                let metaData = Data(value: [encodedData![index].count, seqCount])
//                                self.send(data: metaData)
                                self.send(data: frame)
                                usleep(20000) // 20ms wait
//                            }
                            if seqCount == 255 {
                                seqCount = 0
                            } else {
                                seqCount += 1
                            }
                        }
                    }
                }
            case lePsmOutPointCharacteristicCBUUID:
                if let psmValue = psmIdentifier(from: characteristic) {
                    print(psmValue)
                    psm = psmValue
                    print("Bluetooth devices:")
                    guard let devices = IOBluetoothDevice.pairedDevices() else {
                        print("No devices")
                        return
                    }
                    for item in devices {
                        if let device = item as? IOBluetoothDevice {
                            print("Name: \(String(describing: device.name))");
                            print("Paired?: \(device.isPaired())")
                            print("Connected?: \(device.isConnected())")

                            if(device.isConnected() && device.isPaired() && device.name == hearingDevicePeripheral?.name){
                                let channelPointer: AutoreleasingUnsafeMutablePointer<IOBluetoothL2CAPChannel?>? = nil

                                self.l2capChannel?.setDelegate(self)

                                // Pass the address of channelPointer to openL2CAPChannelSync
                                let result = device.openL2CAPChannelSync(channelPointer, withPSM: psm!, delegate: self.l2capChannel?.delegate())
                                self.l2capChannel = channelPointer?.pointee
                                guard result == kIOReturnSuccess else { // if timeout, show dialog instead of fatalError?
                                    fatalError("Failed to open l2cap channel PSM: \(String(describing: psm)) result: \(result)")
                                }
                            }
                        }
                    }
//                  peripheral.openL2CAPChannel(CBL2CAPPSM(psmValue))
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
        switch characteristic.uuid {
            case audioControlPointCharacteristicCBUUID:
//                self.encodedData = writeAudioStream(from: "batman_theme_x.wav")
//                self.send(data: encodedData![0])
                if let audioStatus = audioStatusCharacteristic {
                    hearingDevicePeripheral?.readValue(for: audioStatus)
                }
            default:
                print("Unhandled Characteristic UUID: \(characteristic.uuid)")
            
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        print("Peripheral \(peripheral) is again ready to send characteristic updates")
        let codec = CODEC_G722_16KHZ
        let audiotype = AUDIOTYPE_MEDIA
        let volume :Int8 = VOLUME_UNKNOWN
        let startAudioStream = AudioControlPointStart(codecId: codec, audioType: audiotype, volumeLevel: volume, otherState: OTHER_SIDE_NOT_STREAMING)
        if let startStream = startAudioStream {
            if let characteristic = audioControlPointCharacteristic {
                print("Writing value for audio control characteristic")
                
                hearingDevicePeripheral?.writeValue(startStream.asData(), for: characteristic, type: CBCharacteristicWriteType.withResponse)
    //                        if let audioStatus = audioStatusCharacteristic {
    //                            hearingDevicePeripheral?.setNotifyValue(true, for: audioStatus)
    //                        }
            }
        }
    }
 
//    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
//        if let error = error {
//               print("Error opening l2cap channel - \(error.localizedDescription)")
//               return
//        }
//        guard let channel = channel else {
//           return
//        }
//
//        print("Opened channel \(channel)")
//        self.l2capChannel = channel
//        self.l2capChannel?.outputStream.delegate = self
//        self.l2capChannel?.outputStream.schedule(in: RunLoop.main, forMode: .default)
//        self.l2capChannel?.outputStream.open()
//    }
    
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

extension UInt16 {
    var data: Data {
        var int = self
        return Data(bytes: &int, count: MemoryLayout<UInt16>.size)
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
    
    var uint16: UInt16 {
        get {
            let i16array = self.withUnsafeBytes { $0.load(as: UInt16.self) }
            return i16array
        }
    }
}
