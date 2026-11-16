import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 联机拍摄 (iPad only feature, user 2026-11-16: "拍一张，然后就会自动传到iPad上"): the camera's Auto FTP Transfer sends
/// each photo to the receiver in FTPServer.swift; it is imported as if picked, and the newest one is shown.
@MainActor
final class Tether: ObservableObject {
    static let shared = Tether()
    @Published private(set) var on = false
    @Published private(set) var state = ""
    @Published private(set) var address = ""
    @Published private(set) var addressChanged = false
    @Published private(set) var received = 0
    @Published private(set) var login: (String, String) = {
        #if TESTHOOKS
        if let p = ProcessInfo.processInfo.environment["LRCDF_FTP_PASS"] { return ("lrcdf", p) }   // tests only
        #endif
        return FTPServer.credentials()
    }()
    /// 无线 through the iPad's own Personal Hotspot (cellular iPads; user 2026-11-16, no test device): the camera joins
    /// the hotspot, the iPad is then always 172.20.10.1. The receiver already listens there (FTPServer: every interface
    /// but cellular); only the address shown and the steps differ. Nothing goes over cellular data.
    @Published var hotspot = UserDefaults.standard.bool(forKey: "tetherHotspot") {
        didSet { UserDefaults.standard.set(hotspot, forKey: "tetherHotspot"); addressChanged = false; refreshAddress(first: true) }
    }
    static let hotspotAddress = "172.20.10.1"     // iOS Personal Hotspot always gives the iPad this address
    private var watching: Task<Void, Never>?

    /// The user's own user name and password (nil = saved; else what is wrong). A running receiver starts again with it.
    func changeLogin(_ user: String, _ password: String) -> String? {
        if let p = FTPServer.problem(user: user, password: password) { return p }
        FTPServer.save(user: user, password: password)
        login = (user, password)
        if server != nil, let studio { stop(keepWanted: true); start(studio) }
        return nil
    }
    private var server: FTPServer?
    /// 有线: the camera on the iPad's USB-C port, Sony PC Remote (CameraUSB.swift); the alternative to Wi-Fi FTP.
    @Published private(set) var wired = false
    let usb = CameraUSB()
    private var studio: Studio?
    private var wanted = false          // the user switched it on (kept across a trip to the background)

    func start(_ studio: Studio) {
        self.studio = studio; wanted = true
        if wired {
            usb.onFile = { url in Tether.shared.arrived(url) }
            usb.start(); on = true
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            return
        }
        guard server == nil else { return }
        let s = FTPServer(user: login.0, password: login.1)
        s.onState = { st in Task { @MainActor in Tether.shared.state = st } }
        s.onFile = { url in Task { @MainActor in Tether.shared.arrived(url) } }
        s.start(); server = s; on = true
        refreshAddress(first: true)
        // the hotspot's interface appears only once the camera has joined: the address is looked at again every few seconds
        watching?.cancel()
        watching = Task { @MainActor in
            while !Task.isCancelled, Tether.shared.on {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                Tether.shared.refreshAddress(first: false)
            }
        }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true      // the screen stays on while photos come in
        #endif
    }

    func startWired(_ yes: Bool, _ studio: Studio) {
        guard yes != wired else { return }
        let was = on
        stop(); wired = yes
        if was { start(studio) }
    }

    func stop(keepWanted: Bool = false) {
        if wired, !keepWanted { usb.stop() }
        server?.stop(); server = nil; on = false; state = ""
        watching?.cancel(); watching = nil
        if !keepWanted { wanted = false }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    /// iPadOS stops listening in the background: stopped there, started again on return.
    func phase(active: Bool) {
        if wired { return }               // CameraUSB pauses and resumes itself
        if !active, on { stop(keepWanted: true) }
        if active, wanted, !on, let studio { start(studio) }
        if active, on { refreshAddress(first: false) }
    }

    func refreshAddress(first: Bool) {
        let all = FTPServer.addresses()
        let now = hotspot ? (all.first { $0.0.hasPrefix("bridge") }?.1 ?? Self.hotspotAddress)
                          : (all.first { !$0.0.hasPrefix("bridge") }?.1 ?? "")
        if !first, !address.isEmpty, now != address { addressChanged = true }
        address = now
    }
    func acknowledgeAddress() { addressChanged = false }

    fileprivate func arrived(_ url: URL) {
        let dest = Studio.folder.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + url.lastPathComponent)
        guard (try? FileManager.default.moveItem(at: url, to: dest)) != nil else { return }
        received += 1
        studio?.add([dest], show: true)
    }
}

/// The 联机拍摄 sheet: what to type into the camera, the steps on the camera, and how many photos came in.
struct TetherView: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var tether = Tether.shared
    @ObservedObject var usb = Tether.shared.usb
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var newUser = ""
    @State private var newPassword = ""
    @State private var loginProblem: String?

    var body: some View {
        NavigationStack {
            Scrolling {
                VStack(alignment: .leading, spacing: 18) {
                    Text("拍一张，传一张：相机拍好的照片自动送到这台 iPad，到了就自动修好显示最新一张。目前只支持索尼 A7R V。")
                        .font(DS.body).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
                    Picker("连接方式", selection: Binding(get: { tether.wired }, set: { tether.startWired($0, studio) })) {
                        Text("无线（Wi-Fi）").tag(false)
                        Text("有线（USB 线）").tag(true)
                    }
                    .pickerStyle(.segmented).frame(minHeight: 44)
                    if tether.wired { wiredBody } else { wifiBody }
                    Text(tether.wired ? "只读取相机新拍的照片，不改相机设置，不删卡里的照片。关掉这一页后仍在接收（顶上有“联机中”），点它或“停止接收”就停。" : "只在局域网里接收相机发来的照片，不连接任何外部网址。关掉这一页后仍在接收（顶上有“联机中”），点它或“停止接收”就停；App 退到后台时也停，回来自动接着收。").font(DS.note).foregroundStyle(DS.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24).frame(maxWidth: 600, alignment: .leading)
            }
            .navigationTitle("联机拍摄")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .background(Color.black)
            // a photo came in: the page gets out of the way so it can be seen (user 2026-11-16); "联机中" stays on top
            .onChange(of: tether.received) { _, n in if n > 0 { dismiss() } }
            .alert("修改用户名和密码", isPresented: $editing) {
                TextField("用户名", text: $newUser).autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                TextField("密码", text: $newPassword).autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                Button("保存") { loginProblem = tether.changeLogin(newUser, newPassword) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("改好后，相机 Server Setting 里的 User 和 Password 也要改成一样的。只能用英文字母、数字和 - _ . @。")
            }
            .alert(loginProblem ?? "", isPresented: Binding(get: { loginProblem != nil }, set: { if !$0 { loginProblem = nil } })) {
                Button("重新输入") { loginProblem = nil; editing = true }
                Button("算了", role: .cancel) { loginProblem = nil }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var wifiBody: some View {
        Picker("相机连到", selection: $tether.hotspot) {
            Text("同一个 Wi-Fi / 路由器").tag(false)
            Text("这台 iPad 的个人热点").tag(true)
        }
        .pickerStyle(.segmented).frame(minHeight: 44)
        Text("无线比有线慢：RAW 每张要多等几秒，连拍时照片会排队一张张到。要快请用有线（USB 线）。")
            .font(DS.body).foregroundStyle(DS.focus).fixedSize(horizontal: false, vertical: true)
        if tether.on {
            HStack(spacing: 10) {
                Circle().fill(DS.focus).frame(width: 8, height: 8)
                Text(tether.received == 0 ? "正在等相机传照片…" : "已收到 \(tether.received) 张").font(DS.section)
            }
            if tether.addressChanged && !tether.hotspot {
                Text("iPad 的地址变了，请把相机里的 Host Name 改成下面的新地址。").font(DS.body).foregroundStyle(DS.focus)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                row("主机地址（Host Name）", tether.address.isEmpty ? "没有连上 Wi-Fi" : tether.address)
                row("端口（Port）", "\(FTPServer.port)")
                row("用户名（User）", tether.login.0)
                row("密码（Password）", tether.login.1)
                Button("修改用户名和密码") {
                    newUser = tether.login.0; newPassword = tether.login.1; editing = true
                }
                .font(DS.body).frame(maxWidth: .infinity, minHeight: 44)
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if tether.hotspot { hotspotSteps }
            steps
            Button("停止接收") { tether.stop() }.buttonStyle(QuietButton())
        } else {
            Text(tether.hotspot
                 ? "外拍没有 Wi-Fi 时：蜂窝版 iPad 打开个人热点，相机直接连 iPad。照片只在相机和 iPad 之间传，不用流量。"
                 : "相机和 iPad 要连在同一个 Wi-Fi 上；外拍没有 Wi-Fi 时，两个都连同一个便携路由器（5GHz 最好），或者改用上面的“个人热点”。")
                .font(DS.body).foregroundStyle(DS.soft).fixedSize(horizontal: false, vertical: true)
            if tether.hotspot { hotspotSteps }
            PrimaryButton(title: "开始接收", wide: true) { tether.start(studio) }
        }
    }

    /// The camera joins the iPad's own hotspot (written from Apple's and Sony's guides; not tried: no cellular iPad).
    private var hotspotSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("先让相机连上 iPad 的热点").font(DS.section)
            ForEach(Array([
                "iPad：设置 → 个人热点 → 打开“允许其他人加入”，记下那一页的“Wi-Fi 密码”（要蜂窝版 iPad，且套餐支持个人热点）",
                "相机：MENU → Network（网络）→ Wi-Fi → Access Point Set.（访问点设置）→ 选这台 iPad 的名字，输入那个 Wi-Fi 密码。相机第一次找热点时，iPad 停在“个人热点”那一页",
                "连上后，相机里的 Host Name 填 \(Tether.hotspotAddress)（个人热点下 iPad 总是这个地址）",
            ].enumerated()), id: \.offset) { i, t in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.onFocus)
                        .frame(width: 22, height: 22).background(DS.focus, in: Circle())
                    Text(t).font(DS.body).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var wiredBody: some View {
        if tether.on {
            HStack(spacing: 10) {
                Circle().fill(DS.focus).frame(width: 8, height: 8)
                Text(usb.received == 0 ? "\(usb.state)：拍一张试试" : "已收到 \(usb.received) 张").font(DS.section)
            }
            if let e = usb.lastError {
                Text(e).font(DS.body).foregroundStyle(DS.focus).fixedSize(horizontal: false, vertical: true)
            }
            wiredSteps
            Button("停止接收") { tether.stop() }.buttonStyle(QuietButton())
        } else {
            wiredSteps
            PrimaryButton(title: "开始接收", wide: true) { tether.start(studio) }
        }
    }

    private var wiredSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("相机上设置一次（之后不用再改）").font(DS.section)
            ForEach(Array([
                "MENU → Network（网络）→ Transfer/Remote（传输/遥控）→ PC Remote Function（PC 遥控功能）→ PC Remote（PC 遥控）选 On，PC Remote Cnct Method（PC 遥控连接方式）选 USB；相机固件要 3.00 或更新",
                "同一页 Still Img. Save Dest.（静态影像保存目的地）选 PC+Camera（电脑+相机），卡里也留一份",
                "MENU → Setup（设置）→ USB → USB Connection Mode（USB 连接模式）选 PC Remote（PC 遥控）",
                "用 USB-C 线把相机接到 iPad，点“开始接收”，iPad 问是否允许访问相机时点允许，然后拍一张试试",
            ].enumerated()), id: \.offset) { i, t in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.onFocus)
                        .frame(width: 22, height: 22).background(DS.focus, in: Circle())
                    Text(t).font(DS.body).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(DS.body).foregroundStyle(DS.soft)
            Spacer()
            Text(value).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(DS.ink).textSelection(.enabled)
        }
        .padding(.horizontal, 16).frame(minHeight: 48)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("相机上设置一次（之后不用再改）").font(DS.section)
            ForEach(Array([
                "MENU → Network（网络）→ FTP Transfer（FTP 传输）→ FTP Transfer Func.（FTP 传输功能）",
                "Server Setting（服务器设置）→ Server 1：Host Name 填上面的地址，Secure Protocol（安全协议）选 Off，Port 填 \(FTPServer.port)，User 和 Password 照上面填",
                "FTP Function（FTP 功能）选 On",
                "Auto FTP Transfer（自动 FTP 传输）选 On，然后拍一张试试",
            ].enumerated()), id: \.offset) { i, t in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.onFocus)
                        .frame(width: 22, height: 22).background(DS.focus, in: Circle())
                    Text(t).font(DS.body).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
