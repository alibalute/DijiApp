import UIKit
import WebKit
import CoreBluetooth

private let eTarServiceUUID = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
private let eTarCharUUID   = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

final class WebViewController: UIViewController, WKScriptMessageHandler, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var webView: WKWebView!
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var midiCharacteristic: CBCharacteristic?
    private var pendingScanCallbackId: Int?
    private var pendingConnectCallbackId: Int?
    private var pendingConnectDeviceId: String?
    private var discoveredPeripherals: [String: (CBPeripheral, String)] = [:]
    private var isCentralReady = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.userContentController.add(self, name: "iosBLE")

        let bridgeScript = """
        (function() {
            if (typeof window.AndroidBLE !== 'undefined') return;
            window.AndroidBLE = {
                requestDevice: function(id) {
                    window.webkit.messageHandlers.iosBLE.postMessage(JSON.stringify({ method: 'requestDevice', callbackId: id }));
                },
                connect: function(deviceId, cid) {
                    window.webkit.messageHandlers.iosBLE.postMessage(JSON.stringify({ method: 'connect', deviceId: deviceId, callbackId: cid }));
                },
                writeValueBase64: function(b64) {
                    window.webkit.messageHandlers.iosBLE.postMessage(JSON.stringify({ method: 'writeValueBase64', base64: b64 }));
                },
                startNotifications: function() {
                    window.webkit.messageHandlers.iosBLE.postMessage(JSON.stringify({ method: 'startNotifications' }));
                }
            };
        })();
        """
        let script = WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)

        centralManager = CBCentralManager(delegate: self, queue: .main)

        if let url = Bundle.main.url(forResource: "qui-skinned", withExtension: "html", subdirectory: nil) {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "iosBLE", let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else { return }

        switch method {
        case "requestDevice":
            if let callbackId = json["callbackId"] as? Int {
                pendingScanCallbackId = callbackId
                if isCentralReady {
                    centralManager.scanForPeripherals(withServices: [eTarServiceUUID], options: nil)
                }
            }
        case "connect":
            if let deviceId = json["deviceId"] as? String, let callbackId = json["callbackId"] as? Int {
                pendingConnectDeviceId = deviceId
                pendingConnectCallbackId = callbackId
                if let (periph, _) = discoveredPeripherals[deviceId] {
                    peripheral = periph
                    centralManager.stopScan()
                    centralManager.connect(periph, options: nil)
                }
            }
        case "writeValueBase64":
            if let base64 = json["base64"] as? String,
               let data = Data(base64Encoded: base64),
               let char = midiCharacteristic {
                peripheral?.writeValue(data, for: char, type: .withResponse)
            }
        case "startNotifications":
            if let char = midiCharacteristic {
                peripheral?.setNotifyValue(true, for: char)
            }
        default:
            break
        }
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isCentralReady = (central.state == .poweredOn)
        if isCentralReady, pendingScanCallbackId != nil {
            centralManager.scanForPeripherals(withServices: [eTarServiceUUID], options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "eTar"
        discoveredPeripherals[id] = (peripheral, name)
        if let callbackId = pendingScanCallbackId {
            let deviceDict: [String: String] = ["id": id, "name": name]
            if let data = try? JSONSerialization.data(withJSONObject: deviceDict),
               let json = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") {
                webView.evaluateJavaScript("window._bleResolve(\(callbackId), '\(json)');") { _, _ in }
            }
            pendingScanCallbackId = nil
            centralManager.stopScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([eTarServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let cid = pendingConnectCallbackId {
            let errMsg = (error?.localizedDescription ?? "Connection failed").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("window._bleReject(\(cid), '\(errMsg)');") { _, _ in }
            pendingConnectCallbackId = nil
        }
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == eTarServiceUUID }) else { return }
        peripheral.discoverCharacteristics([eTarCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        midiCharacteristic = service.characteristics?.first(where: { $0.uuid == eTarCharUUID })
        if let cid = pendingConnectCallbackId {
            webView.evaluateJavaScript("window._bleOnConnect(\(cid));") { _, _ in }
            pendingConnectCallbackId = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let b64 = data.base64EncodedString().replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window._bleOnNotification('\(b64)');") { _, _ in }
    }
}
