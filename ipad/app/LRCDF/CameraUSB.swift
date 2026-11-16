/*
 CameraUSB — Sony A7R V (ILCE-7RM5), USB PC Remote, 2026-11-16.

 Research / configuration (read before integrating):
 • Xcode 27.2 (27B52), iPhoneOS27.2.sdk, ImageCaptureCore.framework/Headers:
   ImageCapturePlatform.h:63–67 maps IC_AVAILABLE / IC_UNAVAILABLE to
   API_AVAILABLE / API_UNAVAILABLE. ICDeviceBrowser / ICCameraDevice,
   cameraDevice:didAddItems:, downloads and PTP events are API_AVAILABLE(ios(13.0)).
   requestSendPTPCommand:outData:completion: is API_AVAILABLE(macos(10.15), ios(13.0)).
   requestTakePicture, requestEnableTethering, requestDisableTethering and
   cancelDownload are explicitly API_UNAVAILABLE(ios) (ICCameraDevice.h:246,333–345).
   tetheredCaptureEnabled itself only lists macos(10.4), without API_UNAVAILABLE(ios).
   Physical shutter capture plus PTP transport does NOT require those forbidden APIs.
 • MSC is file import, not concurrent shooting. MTP import alone does not establish
   Sony remote shooting. Choose USB Connection Mode = PC Remote / Remote Shooting.
   Sony Transfer & Tagging lists A7R V USB PC Remote with firmware 3.00+; use current
   camera firmware. Also set Remote Shoot Setting → Still Img. Save Dest. = PC+Camera
   (keeps a card copy), and choose the RAW/JPEG/HEIF files to send on the camera.
   Turn off competing remote/FTP apps; keep this app in the foreground and iPad unlocked.
 • Downloaded Sony Camera Remote Command 2.02.00; README pp4–6 confirms A7R V PTP3/USB.
   Camera Control PTP 3 Reference pp43–49,114–120: ICC opens the PTP session, then
   9201[1,0,0], 9201[2,0,0], 9202[0x012C], 9201[3,0,0]. Check negotiated version.
   Poll 9209 (UINT64 property count; PTP3 enum descriptors have TWO enum lists).
   D215 bit15 + nonzero low15 indicates ready files. C201 wakes polling, but polling
   also covers lost events. 1008/1009 at FFFFC001 read the FIFO HEAD, not a stable ID.
   Re-query until empty; RAW+JPEG/HEIF is two files, with JPEG/HEIF first (pp48–49).
   D222 is read-only in the current reference (p454): 1=PC, 0x10=card, 0x11=both.
   This implementation does not change camera settings or trigger the shutter.
   A7R V compatibility was checked in the PDF tables (pp85,97,107).
 • GetObject is deliberate: the documented shooting FIFO uses it; partial-read
   commands do not document when that FIFO advances. One complete file is held in
   memory at a time (limit 512 MiB). Large RAW/burst memory and throughput need hardware
   validation. A successful PTP response, exact advertised byte count, successful
   write/close and rename are required before onFile. This is transport validation,
   not a claim that every RAW can be decoded by the rest of the app.
 • Existing card files / ICC didAdd catalog entries are never imported. Only the Sony
   ready FIFO is drained, including any untransferred photos already in that FIFO at
   connection time. A reused FFFFC001 handle must NOT be deduplicated. Unsupported
   extensions are drained without callbacks so they cannot block following photos.
   Received count counts files (RAW+JPEG produces two callbacks).
 • Info.plist: add NSCameraUsageDescription, e.g. "连接 USB 相机，自动接收新拍摄的照片。"
   start() fails safely through lastError if it is absent. Existing photo-library keys
   concern the app's separate PhotoKit features; tmp output does not save to Photos.
   iOS contents/control authorization is ios(14.0), API_UNAVAILABLE(macos), so gated.
   macOS 14+ sandbox USB access needs com.apple.security.device.usb entitlement.
   Apple also documents Hardened Runtime / Photos Library entitlement for macOS ICC.
   No project.yml / Info.plist / entitlement changes are made here. Until the host adds
   those settings and wires onFile/start/stop, compiling this file does not enable UI.
 • All public state and onFile run on MainActor. stop() invalidates pending work;
   unplug keeps discovery alive. A close-acknowledgement fence separates old/new sessions;
   a stuck open/close requires unplugging, not unsafe reuse after a timeout.
   iOS suspension pauses polling and active-time timeouts; foreground resumes it.
   Background operation, recovery of a photo consumed by the camera during disconnect,
   denied permission, power loss, firmware differences and sustained bursts require
   hardware testing. Keep PC+Camera for recovery; no files on the card are deleted.

 Usage: retain CameraUSB, set onFile = { url in ... }, call start()/stop(). Inspect
 state, received and lastError. A delivered temporary file belongs to the caller;
 move it into app storage before the OS purges temporary files.

 Sources:
 https://developer.apple.com/documentation/imagecapturecore
 https://support.d-imaging.sony.co.jp/app/cameraremotecommand/licenseagreement_d/en.html
 https://support.d-imaging.sony.co.jp/app/transfer/en/instruction/23_usbpc.php
 https://support.d-imaging.sony.co.jp/app/transfer/en/devices/cameras.php
 https://helpguide.sony.net/ilc/2230/v1/en/contents/TP0002887823.html
 ICC packet adaptation cross-check (original implementation, not copied):
 https://github.com/sohtamei/CrCmd.DPCC.ios/tree/c46fc57b45233421c4d95ee358ae067b7d0285dc
 It passes transactionID=0 to ICC and receives (inData, response, error). We use our
 own request identity for cancellation, not an assumption about ICC's wire IDs.

 Validation on 2026-11-16: macOS Release and generic iOS arm64 Release app builds
 succeeded; this file also passed strict-concurrency=complete type checking on both.
 Temporary tests outside the repository passed 2923 parser, 47 file-persistence and
 31 actual-runtime lifecycle mock checks. No physical camera/iPad was used; protocol
 negotiation, real permission prompts, firmware formats, large-RAW memory, sustained
 bursts, USB disconnect timing and foreground recovery still require hardware testing.
 */

import Foundation
import Combine
import ImageCaptureCore
#if os(iOS)
import UIKit
#endif

@MainActor
final class CameraUSB: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate {
    @Published private(set) var state = "未连接"
    @Published private(set) var received = 0
    @Published private(set) var lastError: String?
    var onFile: (URL) -> Void = { _ in }

    private var wanted = false
    private var suspended = false
    private var browser: ICDeviceBrowser?
    private var retiredBrowsers: [ICDeviceBrowser] = []
    private var runID = UUID()
    private var connection: Connection?
    private var closing: [UUID: Connection] = [:]
    private var attempts: [ObjectIdentifier: Int] = [:]
    private var retry: Task<Void, Never>?
    private var retryID = UUID()
    private var notifications: [AnyCancellable] = []

    override init() {
        super.init()
        #if os(iOS)
        for (name, pause) in [(UIApplication.didEnterBackgroundNotification, true),
                              (UIApplication.willEnterForegroundNotification, false)] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.setSuspended(pause) }
            }.store(in: &notifications)
        }
        #endif
    }

    isolated deinit {
        browser?.delegate = nil
        browser?.stop()
        for b in retiredBrowsers { b.delegate = nil; b.stop() }
        // Pending async operations also notice the weak owner disappearing and finish
        // their continuations. Detach delegates before the owner can be destroyed.
        if let c = connection { c.camera.delegate = nil; c.camera.requestCloseSession() }
        for c in closing.values { c.camera.delegate = nil; c.camera.requestCloseSession() }
    }

    func start() {
        guard !wanted else { return }
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = "未连接"
            lastError = "缺少 Info.plist 的 NSCameraUsageDescription，请先配置 USB 相机用途说明。"
            return
        }
        wanted = true
        runID = UUID()
        let token = runID
        received = 0
        lastError = nil
        attempts.removeAll()
        #if os(iOS)
        suspended = UIApplication.shared.applicationState == .background
        #else
        suspended = false
        #endif
        let b = ICDeviceBrowser()
        browser = b
        b.delegate = self
        b.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        #if os(iOS)
        b.requestContentsAuthorization { [weak self] authorization in
            Task { @MainActor in
                guard let self, self.wanted, self.runID == token, let b = self.browser else { return }
                guard authorization == .authorized else {
                    self.authorizationFailed("未获准读取外接相机，请在系统设置中允许访问。")
                    return
                }
                b.requestControlAuthorization { [weak self] authorization in
                    Task { @MainActor in
                        guard let self, self.wanted, self.runID == token, let b = self.browser else { return }
                        guard authorization == .authorized else {
                            self.authorizationFailed("未获准控制外接相机，请在系统设置中允许相机访问。")
                            return
                        }
                        b.start()
                    }
                }
            }
        }
        #else
        b.start()
        #endif
    }

    func stop() {
        wanted = false
        runID = UUID()
        retryID = UUID()
        retry?.cancel()
        retry = nil
        let b = browser
        browser = nil                 // invalidate authorization/discovery callbacks first
        retireCurrent()
        if let b {
            if closing.isEmpty { b.delegate = nil; b.stop() }
            else { retiredBrowsers.append(b) } // listen for unplug until close is acknowledged
        }
        state = "未连接"
        lastError = nil
    }

    private func authorizationFailed(_ message: String) {
        stop()
        lastError = message
    }

    private func chooseCamera() {
        guard wanted, !suspended, connection == nil, closing.isEmpty, retry == nil,
              let browser else { return }
        for case let camera as ICCameraDevice in browser.devices ?? [] {
            guard camera.usbVendorID == 0x054C,
                  camera.transportType == ICDeviceTransport.transportTypeUSB.rawValue,
                  attempts[ObjectIdentifier(camera), default: 0] < 3 else { continue }
            let c = Connection(camera: camera, owner: self)
            connection = c
            c.open()
            return
        }
    }

    private func retireCurrent(removed: Bool = false) {
        guard let c = connection else { return }
        connection = nil
        closing[c.id] = c
        c.close(removed: removed)
    }

    private func finishedClosing(_ c: Connection) {
        closing[c.id] = nil
        if closing.isEmpty {
            for b in retiredBrowsers { b.delegate = nil; b.stop() }
            retiredBrowsers.removeAll()
        }
        chooseCamera()
    }

    private func failed(_ c: Connection, _ error: Error) {
        guard connection === c, wanted else { return }
        lastError = error.localizedDescription
        state = "未连接"
        attempts[ObjectIdentifier(c.camera), default: 0] += 1
        retry?.cancel()
        retryID = UUID()
        let token = retryID
        // Install the retry fence before a synchronous removed/closed callback can arrive.
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.wanted, self.retryID == token else { return }
            self.retry = nil
            self.chooseCamera()
        }
        retireCurrent()
    }

    private func removed(_ device: ICDevice) {
        attempts[ObjectIdentifier(device)] = nil
        if connection?.camera === device {
            retireCurrent(removed: true)
            state = "未连接"
            lastError = nil
        }
        for c in Array(closing.values) where c.camera === device { c.finishClose() }
        chooseCamera()
    }

    private func setSuspended(_ value: Bool) {
        suspended = value
        if !value { chooseCamera() }  // the connection's single loop also resumes
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard self.browser === browser, wanted else { return }
        attempts[ObjectIdentifier(device)] = nil
        chooseCamera()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if self.browser === browser { removed(device) }
        else if retiredBrowsers.contains(where: { $0 === browser }) {
            // An old browser's delayed event must never disconnect a new connection.
            for c in Array(closing.values) where c.camera === device { c.finishClose() }
        }
    }

    #if os(iOS)
    func deviceBrowserWillSuspendOperations(_ browser: ICDeviceBrowser) {
        if self.browser === browser { setSuspended(true) }
    }
    func deviceBrowserDidSuspendOperations(_ browser: ICDeviceBrowser) {
        if self.browser === browser { setSuspended(true) }
    }
    func deviceBrowserDidResumeOperations(_ browser: ICDeviceBrowser) {
        if self.browser === browser { setSuspended(false) }
    }
    func deviceBrowserDidCancelSuspendOperations(_ browser: ICDeviceBrowser) {
        if self.browser === browser { setSuspended(false) }
    }
    #endif

    @MainActor
    private final class Connection: NSObject, @preconcurrency ICCameraDeviceDelegate {
        let id = UUID()
        let camera: ICCameraDevice
        weak var owner: CameraUSB?
        private var worker: Task<Void, Never>?
        private var watchdog: Task<Void, Never>?
        private var pending: Pending?
        private var active = true
        private var closed = false
        private var opening = false
        private var opened = false
        private var closeRequested = false
        private var eventVersion: UInt64 = 0
        private let buffer: UInt32 = 0xFFFFC001

        init(camera: ICCameraDevice, owner: CameraUSB) {
            self.camera = camera
            self.owner = owner
        }
        private var current: Bool { active && owner?.wanted == true && owner?.connection === self }

        func open() {
            opening = true
            camera.delegate = self
            watchdog = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.activeDelay(seconds: 15)
                    if self.current { self.owner?.failed(self, USBFailure.message("相机打开超时，请确认 USB 模式为 PC Remote，并关闭其他联机软件。")) }
                } catch {
                    if self.owner == nil {
                        self.camera.delegate = nil
                        self.camera.requestCloseSession(options: nil) { _ in }
                    }
                }
            }
            camera.requestOpenSession()
        }

        func close(removed: Bool) {
            guard active else { return }
            active = false
            worker?.cancel()
            worker = nil
            watchdog?.cancel()
            pending?.finish(.failure(CancellationError()))
            pending = nil
            if removed { opening = false; finishClose(); return }
            if !opening, !opened, !camera.hasOpenSession { finishClose(); return }
            // Do not close before a pending open has resolved. A late successful open
            // gets its own close request in didOpenSession even though this run is retired.
            if !opening { requestClose() }
            watchdog = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, !self.closed else { return }
                self.owner?.lastError = "相机尚未确认关闭 USB 会话，请拔下相机后重新连接。"
                // Timeout is not a close acknowledgement. Keep discovery/retirement
                // alive for a real close or physical unplug; never reopen this device now.
            }
        }

        private func requestClose() {
            guard !closed, !closeRequested, !opening else { return }
            closeRequested = true
            camera.requestCloseSession(options: nil) { [weak self] error in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    if error == nil { self.finishClose() }
                    else { self.owner?.lastError = "关闭相机 USB 会话失败，请拔下相机后重新连接。" }
                }
            }
        }

        func finishClose() {
            guard !closed else { return }
            closed = true
            watchdog?.cancel()
            watchdog = nil
            if camera.delegate === self { camera.delegate = nil }
            owner?.finishedClosing(self)
        }

        private func requireCurrent() throws {
            try Task.checkCancellation()
            guard current else { throw CancellationError() }
        }

        private func activeDelay(seconds: Double) async throws {
            var remaining = seconds
            while remaining > 0 {
                try requireCurrent()
                try await Task.sleep(nanoseconds: 100_000_000)
                if owner?.suspended == false { remaining -= 0.1 }
            }
            try requireCurrent()
        }

        private func available() async throws {
            try requireCurrent()
            while owner?.suspended == true {
                try await Task.sleep(nanoseconds: 100_000_000)
                try requireCurrent()
            }
        }

        private func command(_ code: UInt16, _ parameters: [UInt32] = []) async throws -> Data {
            // Only DeviceBusy is replayed. A timeout/transport error on GetObject is ambiguous
            // (the FIFO may already have advanced), so never blindly retry that transaction.
            for attempt in 0..<20 {
                try await available()
                do { return try await send(code, parameters) }
                catch USBFailure.response(0x2019) where attempt < 19 {
                    try await activeDelay(seconds: 0.5)
                }
            }
            throw USBFailure.message("相机持续忙碌，请停止连拍后重试。")
        }

        private func send(_ code: UInt16, _ parameters: [UInt32]) async throws -> Data {
            try requireCurrent()
            guard pending == nil else { throw USBFailure.message("USB 命令队列冲突。") }
            let packet = CameraUSBPTP.command(code, parameters: parameters, transaction: 0)
            return try await withCheckedThrowingContinuation { continuation in
                let request = Pending(continuation)
                pending = request
                request.timer = Task { [weak self, weak request] in
                    guard let self, let request else { return }
                    do {
                        try await self.activeDelay(seconds: code == 0x1009 ? 120 : 20)
                        guard self.pending === request else { return }
                        self.pending = nil
                        request.finish(.failure(USBFailure.message("USB 传输超时，请重新连接相机。")))
                    } catch {
                        if self.pending === request {
                            self.pending = nil
                            request.finish(.failure(CancellationError()))
                        }
                    }
                }
                camera.requestSendPTPCommand(packet, outData: nil) { [weak self, request] data, response, error in
                    Task { @MainActor in
                        guard let self, self.current, self.pending === request else {
                            request.finish(.failure(CancellationError()))
                            return
                        }
                        self.pending = nil
                        do {
                            if let error { throw error }
                            let reply = try CameraUSBPTP.response(response)
                            guard reply.code == 0x2001 else { throw USBFailure.response(reply.code) }
                            request.finish(.success(data))
                        } catch { request.finish(.failure(error)) }
                    }
                }
            }
        }

        private func run() async throws {
            let info = try CameraUSBPTP.deviceInfo(await command(0x1001))
            guard info.model.trimmingCharacters(in: .whitespacesAndNewlines) == "ILCE-7RM5" else {
                throw USBFailure.message("此 USB 后端仅适配 Sony A7R V（相机报告：\(info.model)）。")
            }
            // Sony's reference does not require vendor operations to be advertised before
            // authentication. Negotiate them and check actual response codes instead.
            _ = try await command(0x9201, [1, 0, 0])
            _ = try await command(0x9201, [2, 0, 0])
            var negotiated = false
            for _ in 0..<20 {
                let ext = try await command(0x9202, [0x012C])
                if ext.isEmpty { try await activeDelay(seconds: 0.25); continue }
                guard ext.prefix(2) == Data([0x2C, 0x01]) else {
                    throw USBFailure.message("相机未协商 Sony PTP 3，请检查固件和 USB 模式。")
                }
                negotiated = true
                break
            }
            guard negotiated else { throw USBFailure.message("相机未返回 Sony PTP 3 信息，请重新连接。") }
            _ = try await command(0x9201, [3, 0, 0])
            try requireCurrent()
            owner?.lastError = nil
            if let owner {
                owner.state = owner.received == 0 ? "已连接 \(camera.name ?? info.model)" : "已收到 \(owner.received) 张"
            }

            while current {
                try await available()
                guard camera.hasOpenSession else {
                    opened = false
                    throw USBFailure.message("USB 会话已关闭，正在重新连接。")
                }
                let properties = try CameraUSBPTP.properties(await command(0x9209))
                guard let shooting = properties[0xD215], let destination = properties[0xD222] else {
                    throw USBFailure.message("相机没有报告拍摄队列或保存位置，请检查 PC Remote 模式和固件。")
                }
                if shooting.enabled, let value = shooting.current,
                   value & 0x8000 != 0, value & 0x7FFF != 0 {
                    try await receiveHead()
                    continue           // including the second file of RAW+JPEG/HEIF
                }
                if !shooting.enabled {
                    owner?.lastError = "相机暂不可传照片，请切换到静态照片拍摄模式。"
                } else if !destination.enabled || (destination.current ?? 0) & 1 == 0 {
                    owner?.lastError = "请在相机 Remote Shoot Setting 中把 Still Img. Save Dest. 设为 PC+Camera。"
                } else {
                    owner?.lastError = nil
                }
                let observed = eventVersion
                for _ in 0..<10 {
                    try await activeDelay(seconds: 0.05)
                    if eventVersion != observed { break }
                }
            }
        }

        private func receiveHead() async throws {
            let info = try CameraUSBPTP.objectInfo(await command(0x1008, [buffer]))
            guard info.size > 0, info.size <= CameraUSBIncoming.maximumSize else {
                throw USBFailure.message("相机照片大小无效或超过 512 MiB，已停止接收。")
            }
            // Check free space before consuming the camera's FIFO. Still keep a card copy.
            let filename = CameraUSBIncoming.filename(info.name)
            if filename != nil { try CameraUSBIncoming.checkSpace(for: info.size) }
            let data = try await command(0x1009, [buffer])
            try requireCurrent()
            guard data.count == info.size else {
                throw USBFailure.message("照片未完整下载（应有 \(info.size) 字节，收到 \(data.count) 字节）。")
            }
            guard let filename else { return }
            let url = try await Task.detached(priority: .utility) {
                try CameraUSBIncoming.save(data, filename: filename)
            }.value
            guard current, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            guard let owner else {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            owner.received += 1
            owner.lastError = nil
            owner.state = "已收到 \(owner.received) 张"
            owner.onFile(url)
        }

        func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
            guard device === camera, !closed, opening else { return }
            opening = false
            opened = error == nil
            if !current {
                if error == nil { requestClose() }
                else { finishClose() }
                return
            }
            watchdog?.cancel()
            watchdog = nil
            if let error { owner?.failed(self, error); return }
            worker = Task { [weak self] in
                guard let self else { return }
                do { try await self.run() }
                catch is CancellationError {
                    if self.owner == nil {
                        self.camera.delegate = nil
                        self.camera.requestCloseSession(options: nil) { _ in }
                    }
                }
                catch { if self.current { self.owner?.failed(self, error) } }
            }
        }
        func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
            guard device === camera else { return }
            if error == nil { opened = false }
            if current { owner?.failed(self, error ?? USBFailure.message("相机 USB 会话意外关闭。")) }
            else if !opening, error == nil { finishClose() }
        }
        func didRemove(_ device: ICDevice) {
            guard device === camera, !closed else { return }
            if current { owner?.removed(device) }
            else { finishClose() }
        }
        func device(_ device: ICDevice, didEncounterError error: Error?) {
            if current, device === camera, let error { owner?.failed(self, error) }
        }
        func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
            guard self.camera === camera, current,
                  let code = CameraUSBPTP.event(eventData), code == 0xC201 || code == 0xC203 else { return }
            eventVersion &+= 1
        }
        // Sony FIFO ownership stays with our serial PTP loop, not ICC's card catalog.
        func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
        func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
        func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
        func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
        func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
        func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
        func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
        func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
        func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
        func cameraDevice(_ cameraDevice: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool { false }
        func cameraDevice(_ cameraDevice: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }

        @MainActor private final class Pending {
            private var continuation: CheckedContinuation<Data, Error>?
            var timer: Task<Void, Never>?
            init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
            func finish(_ result: Result<Data, Error>) {
                guard let continuation else { return }
                self.continuation = nil
                timer?.cancel()
                timer = nil
                continuation.resume(with: result)
            }
        }
    }
}

private enum USBFailure: LocalizedError {
    case message(String)
    case response(UInt16)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .response(let code): return String(format: "相机返回 PTP 错误 0x%04X；请检查 USB 模式和相机状态。", code)
        }
    }
}

private enum CameraUSBIncoming {
    static let maximumSize = 512 * 1024 * 1024
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usb-incoming", isDirectory: true)
    }
    static func filename(_ original: String) -> String? {
        var name = original.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["jpg", "jpeg", "hif", "heif", "heic", "arw", "dng"].contains(ext) else { return nil }
        name = (name as NSString).deletingPathExtension
        name = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        while name.utf8.count > 120 { name.removeLast() }
        if name.isEmpty || name == "." || name == ".." { name = "photo" }
        return UUID().uuidString + "-" + name + "." + ext
    }
    static func checkSpace(for size: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let attributes = try fm.attributesOfFileSystem(forPath: directory.path)
        if let available = attributes[.systemFreeSize] as? NSNumber,
           available.uint64Value < UInt64(size) + 64 * 1024 * 1024 {
            throw USBFailure.message("iPad/Mac 临时目录空间不足，未读取该照片。")
        }
    }
    static func save(_ data: Data, filename: String) throws -> URL {
        let fm = FileManager.default
        let root = directory
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).partial")
        let destination = root.appendingPathComponent(filename)
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let attributes = try fm.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.intValue == data.count else {
            throw USBFailure.message("照片写入不完整，已丢弃临时文件。")
        }
        // Same directory/volume; never overwrite an already delivered file.
        try fm.moveItem(at: temporary, to: destination)
        return destination
    }
}
/// Sony PTP 3 datasets (Remote Command 2.02, pp. 114–120) and standard USB PTP containers.
/// All reads are explicitly little-endian and bounds-checked; no aligned pointer loads.
private enum CameraUSBPTP {
    enum Error: Swift.Error, LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "相机 PTP 数据格式错误：\(detail)"
            }
        }
    }

    struct Response {
        let code: UInt16
        let parameters: [UInt32]
        let transaction: UInt32
    }

    struct Property {
        /// Raw integer bits for scalar values up to 64 bits; nil for strings/arrays/128-bit values.
        let current: UInt64?
        let enabled: Bool
        let dataType: UInt16
        let settable: Bool
    }

    struct ObjectInfo {
        let size: Int
        let name: String
        let format: UInt16
        let sequence: UInt32
    }

    struct DeviceInfo {
        let model: String
        let operations: Set<UInt16>
        let manufacturer: String
        let version: String
    }

    static func command(_ code: UInt16, parameters: [UInt32], transaction: UInt32) -> Data {
        // Programming error, never data from the camera: USB PTP permits five command parameters.
        precondition(parameters.count <= 5)
        var data = Data()
        append(UInt32(12 + parameters.count * 4), to: &data)
        append(UInt16(1), to: &data)
        append(code, to: &data)
        append(transaction, to: &data)
        for parameter in parameters { append(parameter, to: &data) }
        return data
    }

    static func response(_ data: Data) throws -> Response {
        var reader = Reader(data)
        let header = try container(&reader, type: 3, maxParameters: 5)
        var parameters: [UInt32] = []
        while !reader.finished { parameters.append(try reader.u32()) }
        return Response(code: header.code, parameters: parameters, transaction: header.transaction)
    }

    static func event(_ data: Data) -> UInt16? {
        var reader = Reader(data)
        guard let header = try? container(&reader, type: 4, maxParameters: 3) else { return nil }
        return header.code
    }

    static func properties(_ data: Data) throws -> [UInt16: Property] {
        guard data.count <= 16 * 1024 * 1024 else { throw Error.malformed("property dataset too large") }
        var reader = Reader(data)
        // Sony's array count is UINT64, unlike the UINT32 count in standard PTP arrays.
        let count = try reader.u64()
        guard count <= 16_384, count <= UInt64(reader.remaining / 9) else {
            throw Error.malformed("property count")
        }
        var result: [UInt16: Property] = [:]
        for _ in 0..<Int(count) {
            let code = try reader.u16()
            let type = try reader.u16()
            let getSet = try reader.u8()
            let enabled = try reader.u8()
            guard getSet <= 1, enabled <= 2, result[code] == nil else {
                throw Error.malformed("property flags or duplicate code")
            }
            _ = try reader.value(type) // Factory Default Value (reserved in many Sony properties).
            let current = try reader.value(type)
            switch try reader.u8() {
            case 0:
                break
            case 1:
                // Minimum, maximum, step, all using the property's declared datatype.
                try reader.values(type, count: 3)
            case 2:
                // Sony PTP 3 has TWO enumeration lists; omitting the second misaligns every later property.
                let setCount = Int(try reader.u16())
                try reader.values(type, count: setCount)
                let getSetCount = Int(try reader.u16())
                try reader.values(type, count: getSetCount)
            default:
                throw Error.malformed("property form")
            }
            result[code] = Property(current: current, enabled: enabled != 0,
                                    dataType: type, settable: getSet == 1)
        }
        guard reader.finished else { throw Error.malformed("trailing property bytes") }
        return result
    }

    static func objectInfo(_ data: Data) throws -> ObjectInfo {
        var reader = Reader(data)
        _ = try reader.u32() // StorageID
        let format = try reader.u16()
        _ = try reader.u16() // ProtectionStatus
        let size = try reader.u32()
        try reader.skip(36) // Thumbnail, image dimensions, association and parent metadata.
        let sequence = try reader.u32() // End of the 52-byte fixed prefix.
        let name = try reader.string()
        _ = try reader.string() // CaptureDate
        _ = try reader.string() // ModificationDate
        _ = try reader.string() // Keywords
        guard reader.finished else { throw Error.malformed("trailing ObjectInfo bytes") }
        return ObjectInfo(size: Int(size), name: name, format: format, sequence: sequence)
    }

    static func deviceInfo(_ data: Data) throws -> DeviceInfo {
        var reader = Reader(data)
        _ = try reader.u16() // StandardVersion
        _ = try reader.u32() // VendorExtensionID
        _ = try reader.u16() // VendorExtensionVersion
        _ = try reader.string() // VendorExtensionDesc
        _ = try reader.u16() // FunctionalMode
        let operations = Set(try reader.u16Array())
        for _ in 0..<4 { _ = try reader.u16Array() } // Events, properties, capture and image formats.
        let manufacturer = try reader.string()
        let model = try reader.string()
        let version = try reader.string()
        _ = try reader.string() // SerialNumber; deliberately not retained/logged.
        guard reader.finished else { throw Error.malformed("trailing DeviceInfo bytes") }
        return DeviceInfo(model: model, operations: operations, manufacturer: manufacturer, version: version)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        for index in 0..<MemoryLayout<T>.size {
            data.append(UInt8(truncatingIfNeeded: value >> (index * 8)))
        }
    }

    private static func container(_ reader: inout Reader, type: UInt16,
                                  maxParameters: Int) throws -> (code: UInt16, transaction: UInt32) {
        let length = try reader.u32()
        guard length == reader.data.count, length >= 12,
              length <= UInt32(12 + maxParameters * 4), (length - 12) % 4 == 0,
              try reader.u16() == type else { throw Error.malformed("PTP container header") }
        let code = try reader.u16()
        let transaction = try reader.u32()
        return (code, transaction)
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var remaining: Int { data.count - offset }
        var finished: Bool { offset == data.count }
        init(_ data: Data) { self.data = data }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= remaining else { throw Error.malformed("truncated dataset") }
            offset += count
        }

        mutating func integer(_ width: Int) throws -> UInt64 {
            guard width > 0, width <= 8, width <= remaining else {
                throw Error.malformed("truncated integer")
            }
            var result: UInt64 = 0
            // Data slices may have nonzero startIndex; offsets here are relative to startIndex.
            for index in 0..<width {
                result |= UInt64(data[data.startIndex + offset + index]) << (index * 8)
            }
            offset += width
            return result
        }
        mutating func u8() throws -> UInt8 { UInt8(try integer(1)) }
        mutating func u16() throws -> UInt16 { UInt16(try integer(2)) }
        mutating func u32() throws -> UInt32 { UInt32(try integer(4)) }
        mutating func u64() throws -> UInt64 { try integer(8) }

        mutating func string() throws -> String {
            let count = Int(try u8())
            guard count > 0 else { return "" }
            guard count <= remaining / 2 else { throw Error.malformed("truncated PTP string") }
            var units: [UInt16] = []
            units.reserveCapacity(count)
            for _ in 0..<count { units.append(try u16()) }
            guard units.removeLast() == 0, !units.contains(0) else {
                throw Error.malformed("PTP string terminator")
            }
            var position = 0
            while position < units.count {
                let unit = units[position]
                if (0xD800...0xDBFF).contains(unit) {
                    guard position + 1 < units.count, (0xDC00...0xDFFF).contains(units[position + 1]) else {
                        throw Error.malformed("invalid UTF-16 surrogate pair")
                    }
                    position += 2
                } else {
                    guard !(0xDC00...0xDFFF).contains(unit) else {
                        throw Error.malformed("unpaired UTF-16 low surrogate")
                    }
                    position += 1
                }
            }
            return String(decoding: units, as: UTF16.self)
        }

        mutating func u16Array() throws -> [UInt16] {
            let count = try u32()
            guard count <= 65_536, UInt64(count) <= UInt64(remaining / 2) else {
                throw Error.malformed("UINT16 array count")
            }
            var result: [UInt16] = []
            result.reserveCapacity(Int(count))
            for _ in 0..<Int(count) { result.append(try u16()) }
            return result
        }

        /// Return raw bits for scalar integers up to 64 bits; safely skip other supported PTP types.
        mutating func value(_ type: UInt16) throws -> UInt64? {
            if let width = scalarWidth(type) {
                if width <= 8 { return try integer(width) }
                try skip(width)
                return nil
            }
            if (0x4001...0x400A).contains(type), let width = scalarWidth(type - 0x4000) {
                let count = try u32()
                guard count <= 1_048_576, UInt64(count) <= UInt64(remaining / width) else {
                    throw Error.malformed("PTP array count")
                }
                try skip(Int(count) * width)
                return nil
            }
            if type == 0xFFFF {
                _ = try string()
                return nil
            }
            throw Error.malformed("unsupported datatype \(type)")
        }

        mutating func values(_ type: UInt16, count: Int) throws {
            guard count >= 0, count <= 65_535 else { throw Error.malformed("value count") }
            if let width = scalarWidth(type) {
                guard count <= remaining / width else { throw Error.malformed("truncated values") }
                try skip(count * width)
            } else {
                // Every variable-width value has at least one length/count byte.
                guard count <= remaining else { throw Error.malformed("truncated variable values") }
                for _ in 0..<count { _ = try value(type) }
            }
        }

        func scalarWidth(_ type: UInt16) -> Int? {
            switch type {
            case 0x0001, 0x0002: return 1
            case 0x0003, 0x0004: return 2
            case 0x0005, 0x0006: return 4
            case 0x0007, 0x0008: return 8
            case 0x0009, 0x000A: return 16
            default: return nil
            }
        }
    }
}
