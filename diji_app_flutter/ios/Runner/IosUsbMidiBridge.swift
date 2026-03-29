import CoreMIDI
import Flutter
import Foundation

/// Mirrors [UsbMidiBridge.kt]: same MethodChannel / EventChannel names and payloads as Android.
final class IosUsbMidiBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName = "com.example.diji_app_flutter/usb_midi"
  private static let eventChannelName = "com.example.diji_app_flutter/usb_midi_stream"

  private static var instance: IosUsbMidiBridge?

  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var client: MIDIClientRef = 0
  private var inputPort: MIDIPortRef = 0
  private var running = false
  /// Sources currently connected to [inputPort].
  private var connectedSources: [MIDIEndpointRef] = []
  private var portNotifyWorkItem: DispatchWorkItem?

  private var selfRef: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(self).toOpaque()
  }

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    if instance != nil { return }
    let bridge = IosUsbMidiBridge()
    instance = bridge
    bridge.attach(binaryMessenger: binaryMessenger)
  }

  private func attach(binaryMessenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: Self.methodChannelName,
      binaryMessenger: binaryMessenger
    )
    methodChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "USB_MIDI", message: "Bridge released", details: nil))
        return
      }
      switch call.method {
      case "start":
        do {
          let n = try self.startInternal()
          result(n)
          self.schedulePortCountNotify(delayMs: 100)
          self.scheduleDelayedRescans()
        } catch {
          result(FlutterError(code: "USB_MIDI", message: error.localizedDescription, details: nil))
        }
      case "stop":
        self.stopInternal()
        result(nil)
      case "portCount":
        let n = self.connectedSources.count
        let names = self.connectedSourceDisplayNames()
        result(["count": n, "deviceNames": names])
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: binaryMessenger)
      .setStreamHandler(self)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Core MIDI

  private static let midiNotify: MIDINotifyProc = { message, refCon in
    guard let refCon else { return }
    let bridge = Unmanaged<IosUsbMidiBridge>.fromOpaque(refCon).takeUnretainedValue()
    let id = message.pointee.messageID
    if id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgPropertyChanged {
      DispatchQueue.main.async {
        guard bridge.running else { return }
        bridge.rescanSources()
        bridge.schedulePortCountNotify(delayMs: 120)
      }
    }
  }

  private static let midiReadProc: MIDIReadProc = { packetList, readProcRefCon, _ in
    guard let readProcRefCon else { return }
    let bridge = Unmanaged<IosUsbMidiBridge>.fromOpaque(readProcRefCon).takeUnretainedValue()
    bridge.handlePacketList(packetList)
  }

  private func startInternal() throws -> Int {
    if running {
      return connectedSources.count
    }
    running = true

    var c: MIDIClientRef = 0
    var status = MIDIClientCreate(
      "DijiUsbMidi" as CFString,
      Self.midiNotify,
      selfRef,
      &c
    )
    guard status == noErr else {
      running = false
      throw NSError(
        domain: "USB_MIDI",
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "MIDIClientCreate failed (\(status))"]
      )
    }
    client = c

    var port: MIDIPortRef = 0
    status = MIDIInputPortCreate(
      client,
      "DijiUsbMidiIn" as CFString,
      Self.midiReadProc,
      selfRef,
      &port
    )
    guard status == noErr else {
      MIDIClientDispose(client)
      client = 0
      running = false
      throw NSError(
        domain: "USB_MIDI",
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "MIDIInputPortCreate failed (\(status))"]
      )
    }
    inputPort = port

    rescanSources()
    return connectedSources.count
  }

  private func stopInternal() {
    guard running else { return }
    running = false
    portNotifyWorkItem?.cancel()
    portNotifyWorkItem = nil

    for src in connectedSources {
      _ = MIDIPortDisconnectSource(inputPort, src)
    }
    connectedSources.removeAll()

    if inputPort != 0 {
      MIDIPortDispose(inputPort)
      inputPort = 0
    }
    if client != 0 {
      MIDIClientDispose(client)
      client = 0
    }
  }

  private func rescanSources() {
    guard inputPort != 0 else { return }

    for src in connectedSources {
      _ = MIDIPortDisconnectSource(inputPort, src)
    }
    connectedSources.removeAll()

    let n = MIDIGetNumberOfSources()
    for i in 0..<n {
      let src = MIDIGetSource(i)
      guard src != 0 else { continue }
      let st = MIDIPortConnectSource(inputPort, src, nil)
      if st == noErr {
        connectedSources.append(src)
      }
    }
  }

  private func scheduleDelayedRescans() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.running else { return }
      self.rescanSources()
      self.schedulePortCountNotify(delayMs: 50)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.running else { return }
      self.rescanSources()
      self.schedulePortCountNotify(delayMs: 50)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
      guard let self, self.running else { return }
      self.schedulePortCountNotify(delayMs: 50)
    }
  }

  private func connectedSourceDisplayNames() -> String {
    guard !connectedSources.isEmpty else { return "" }
    var labels: [String] = []
    for ep in connectedSources {
      var pname: Unmanaged<CFString>?
      if MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &pname) == noErr,
         let cf = pname?.takeRetainedValue() {
        let s = cf as String
        if !s.isEmpty { labels.append(s); continue }
      }
      labels.append("MIDI input")
    }
    return labels.joined(separator: " · ")
  }

  private func schedulePortCountNotify(delayMs: Int) {
    portNotifyWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.portNotifyWorkItem = nil
      let n = self.connectedSources.count
      let names = self.connectedSourceDisplayNames()
      self.methodChannel?.invokeMethod(
        "usbMidiPortsUpdated",
        arguments: ["count": n, "deviceNames": names],
        result: { _ in }
      )
    }
    portNotifyWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
  }

  private func handlePacketList(_ list: UnsafePointer<MIDIPacketList>) {
    let packetList = list.pointee
    var packet = packetList.packet
    for _ in 0..<packetList.numPackets {
      let len = Int(packet.length)
      if len > 0 {
        let bytes = withUnsafePointer(to: packet.data) { dPtr in
          dPtr.withMemoryRebound(to: UInt8.self, capacity: len) { bp in
            Array(UnsafeBufferPointer(start: bp, count: len))
          }
        }
        forwardToFlutter(bytes)
      }
      packet = MIDIPacketNext(&packet).pointee
    }
  }

  /// EventSink must run on main (same as Android [Handler.postAtFrontOfQueue]).
  private func forwardToFlutter(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in
      guard let sink = self?.eventSink else { return }
      sink(bytes.map { NSNumber(value: $0) })
    }
  }
}
