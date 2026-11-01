import CoreFoundation
import Foundation

/// 通过系统自带的 MobileDevice.framework 走 AFC。
/// macOS 26/27 上 `/var/run/usbmuxd` 已不再对第三方进程提供原始协议，
/// 但系统框架本身仍然能拿到设备句柄与 AFC 服务。
final class MobileDeviceAPI {

    struct DeviceInfo {
        let identifier: String
        let name: String
        let productType: String
        let productVersion: String
    }

    private let handle: UnsafeMutableRawPointer

    // 函数签名按 MobileDevice 的 C ABI 声明
    private typealias CreateDeviceListFn = @convention(c) (UnsafeMutablePointer<CFArray?>?) -> Int32
    private typealias SubscribeFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UInt, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias ConnectFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ValidatePairFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias StartSessionFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias CopyValueFn = @convention(c) (UnsafeMutableRawPointer?, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias SecureStartServiceFn = @convention(c) (UnsafeMutableRawPointer?, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias ServiceGetSocketFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ServiceSendFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int) -> Int32
    private typealias ServiceReceiveFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int) -> Int32
    private typealias AFCConnectionCreateFn = @convention(c) (CFAllocator?, Int32, UInt8, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias AFCDirectoryOpenFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias AFCDirectoryReadFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias AFCDirectoryCloseFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias AFCFileOpenFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias AFCFileReadFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias AFCFileCloseFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    // 实测签名是（conn, ref, offset, whence）/（conn, ref, &size），不是只有 ref
    private typealias AFCFileSeekFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int64, Int32) -> Int32
    private typealias AFCFileTellFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32
    private typealias AFCRemovePathFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Int32
    // 收尾用：不走这套就退出，设备侧的 afcd 会留半截连接，
    // 之后所有 AFC 连接都被设备直接关掉（实测 `--probe-afc` 连三次全是「连接被关闭」）
    private typealias AFCConnectionCloseFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias AFCConnectionInvalidateFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias StopSessionFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    private let createDeviceList: CreateDeviceListFn
    private let subscribe: SubscribeFn
    private let connect: ConnectFn
    private let validatePair: ValidatePairFn
    private let startSession: StartSessionFn
    private let copyValue: CopyValueFn
    private let startService: SecureStartServiceFn
    private let serviceGetSocket: ServiceGetSocketFn
    private let serviceSend: ServiceSendFn
    private let serviceReceive: ServiceReceiveFn
    private let afcCreate: AFCConnectionCreateFn
    private let afcDirOpen: AFCDirectoryOpenFn
    private let afcDirRead: AFCDirectoryReadFn
    private let afcDirClose: AFCDirectoryCloseFn
    private let afcFileOpen: AFCFileOpenFn
    private let afcFileRead: AFCFileReadFn
    private let afcFileClose: AFCFileCloseFn
    private let afcFileSeek: AFCFileSeekFn?
    private let afcFileTell: AFCFileTellFn?
    private let afcRemovePath: AFCRemovePathFn?
    private let afcClose: AFCConnectionCloseFn?
    private let afcInvalidate: AFCConnectionInvalidateFn?
    private let stopSessionFn: StopSessionFn?

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else {
            throw NSError(domain: "cleanmyiphone", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法加载 MobileDevice.framework"])
        }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw NSError(domain: "cleanmyiphone", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "缺少符号 \(name)"])
            }
            return unsafeBitCast(pointer, to: T.self)
        }

        createDeviceList = try symbol("AMDCreateDeviceList", as: CreateDeviceListFn.self)
        subscribe = try symbol("AMDeviceNotificationSubscribe", as: SubscribeFn.self)
        connect = try symbol("AMDeviceConnect", as: ConnectFn.self)
        validatePair = try symbol("AMDeviceValidatePairing", as: ValidatePairFn.self)
        startSession = try symbol("AMDeviceStartSession", as: StartSessionFn.self)
        copyValue = try symbol("AMDeviceCopyValue", as: CopyValueFn.self)
        startService = try symbol("AMDeviceSecureStartService", as: SecureStartServiceFn.self)
        serviceGetSocket = try symbol("AMDServiceConnectionGetSocket", as: ServiceGetSocketFn.self)
        serviceSend = try symbol("AMDServiceConnectionSend", as: ServiceSendFn.self)
        serviceReceive = try symbol("AMDServiceConnectionReceive", as: ServiceReceiveFn.self)
        afcCreate = try symbol("AFCConnectionCreate", as: AFCConnectionCreateFn.self)
        afcDirOpen = try symbol("AFCDirectoryOpen", as: AFCDirectoryOpenFn.self)
        afcDirRead = try symbol("AFCDirectoryRead", as: AFCDirectoryReadFn.self)
        afcDirClose = try symbol("AFCDirectoryClose", as: AFCDirectoryCloseFn.self)
        afcFileOpen = try symbol("AFCFileRefOpen", as: AFCFileOpenFn.self)
        afcFileRead = try symbol("AFCFileRefRead", as: AFCFileReadFn.self)
        afcFileClose = try symbol("AFCFileRefClose", as: AFCFileCloseFn.self)
        // 取文件大小用：符号不存在时降级成估算，不阻塞启动
        afcFileSeek = dlsym(handle, "AFCFileRefSeek").map { unsafeBitCast($0, to: AFCFileSeekFn.self) }
        afcFileTell = dlsym(handle, "AFCFileRefTell").map { unsafeBitCast($0, to: AFCFileTellFn.self) }
        afcRemovePath = dlsym(handle, "AFCRemovePath").map { unsafeBitCast($0, to: AFCRemovePathFn.self) }
        afcClose = dlsym(handle, "AFCConnectionClose").map { unsafeBitCast($0, to: AFCConnectionCloseFn.self) }
        afcInvalidate = dlsym(handle, "AFCConnectionInvalidate").map { unsafeBitCast($0, to: AFCConnectionInvalidateFn.self) }
        stopSessionFn = dlsym(handle, "AMDeviceStopSession").map { unsafeBitCast($0, to: StopSessionFn.self) }
    }

    // 不要 dlclose：框架里的通知回调可能还活着，卸载代码会直接把进程写崩

    // MARK: - 设备

    /// 设备插上时回调里拿到的指针
    private static var arrived: UnsafeMutableRawPointer?
    private static var subscribed = false

    /// 全进程只留一个实例、只连一次。
    /// 每次 `try MobileDeviceAPI.shared()` 都会重新 dlopen + 订阅通知 + AMDeviceConnect，
    /// 连多次不配对 disconnect 会把设备连接占死，icdd 那边的 PTP 会话跟着一起挂，
    /// 表现就是「缩略图/预览一直转圈」。
    private static let sharedInstance: MobileDeviceAPI? = try? MobileDeviceAPI()

    static func shared() throws -> MobileDeviceAPI {
        guard let instance = sharedInstance else {
            throw NSError(domain: "cleanmyiphone", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法加载 MobileDevice.framework"])
        }
        return instance
    }

    private var sessionOpened = false
    private var connected = false

    /// 所有对 C API 的调用都要过这把锁。
    /// 缩略图下载现在在后台队列跑，和主线程的 lockdownd/服务调用并发使用同一个
    /// am_device 句柄会把 AFC 的 CF 对象写坏（崩溃报告里就是 AFCFileRefRead → CFRelease → BPT trap）。
    let apiLock = NSRecursiveLock()

    func firstDevice(timeout: TimeInterval = 20) throws -> UnsafeMutableRawPointer {
        if let existing = Self.arrived { return existing }
        guard !Self.subscribed else {
            throw NSError(domain: "cleanmyiphone", code: 33,
                          userInfo: [NSLocalizedDescriptionKey: "没有检测到设备"])
        }
        Self.subscribed = true

        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { notification, _ in
            guard let notification else { return }
            // 结构体：{ am_device *dev; uint32 msg; notification *sub; }
            let device = notification.load(fromByteOffset: 0, as: UnsafeMutableRawPointer?.self)
            let message = notification.load(fromByteOffset: 8, as: UInt32.self)
            if let device, message == 1 {
                MobileDeviceAPI.arrived = device
            }
        }

        var subscription: UnsafeMutableRawPointer?
        let status = subscribe(unsafeBitCast(callback, to: UnsafeMutableRawPointer.self), 0, 0, 0, &subscription)
        guard status == 0 else {
            throw NSError(domain: "cleanmyiphone", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "订阅设备通知失败（\(status)）"])
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Self.arrived == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let device = Self.arrived else {
            throw NSError(domain: "cleanmyiphone", code: 32,
                          userInfo: [NSLocalizedDescriptionKey: "20 秒内没有检测到设备"])
        }
        return device
    }

    private func string(_ device: UnsafeMutableRawPointer, _ key: String) -> String {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let value = copyValue(device, nil, key as CFString)?.takeRetainedValue() else { return "—" }
        return (value as? String) ?? "—"
    }

    func info(_ device: UnsafeMutableRawPointer) -> DeviceInfo {
        DeviceInfo(
            identifier: string(device, "UniqueDeviceID"),
            name: string(device, "DeviceName"),
            productType: string(device, "ProductType"),
            productVersion: string(device, "ProductVersion")
        )
    }

    /// 幂等：一个进程只连一次、只开一次会话。重复调用直接返回。
    func openSession(_ device: UnsafeMutableRawPointer) throws {
        if sessionOpened { return }
        if !connected {
            guard connect(device) == 0 else {
                throw NSError(domain: "cleanmyiphone", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "AMDeviceConnect 失败"])
            }
            let paired = validatePair(device)
            guard paired == 0 else {
                throw NSError(domain: "cleanmyiphone", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "配对校验失败（\(paired)），请在 iPhone 上点「信任」"])
            }
            connected = true
        }
        guard startSession(device) == 0 else {
            throw NSError(domain: "cleanmyiphone", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "AMDeviceStartSession 失败"])
        }
        sessionOpened = true
    }

    /// 读 lockdownd 域里的值（容量等）
    func deviceValue(_ device: UnsafeMutableRawPointer, domain: String, key: String) -> Int64 {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let value = copyValue(device, domain as CFString, key as CFString)?.takeRetainedValue() else { return 0 }
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }

    /// 应用图标（com.apple.springboardservices）
    func appIcon(_ device: UnsafeMutableRawPointer, bundleID: String) throws -> Data? {
        let service = try openService(device, name: "com.apple.springboardservices")
        let response = serviceRequest(service, [
            "command": "getIconPNGData",
            "bundleIdentifier": bundleID
        ])
        for value in response.values {
            if let data = value as? Data, data.count > 256 { return data }
        }
        return nil
    }

    /// 读整个 lockdownd 域（key 传 nil）
    func allValues(_ device: UnsafeMutableRawPointer, domain: String? = nil) -> [String: Any] {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let value = copyValue(device, domain as CFString?, nil)?.takeRetainedValue(),
              let dict = value as? [String: Any] else { return [:] }
        return dict
    }

    /// 截一张设备当前画面（com.apple.screenshotr）
    func screenshot(_ device: UnsafeMutableRawPointer) throws -> Data? {
        let service = try openService(device, name: "com.apple.screenshotr")

        guard let payload = try? PropertyListSerialization.data(
            fromPropertyList: ["MessageType": "ScreenShotRequest"],
            format: .xml,
            options: 0
        ) else { return nil }
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        _ = (header + payload).withUnsafeBytes { raw in
            serviceSend(service, raw.baseAddress, payload.count + 4)
        }

        var sizeBuffer = [UInt8](repeating: 0, count: 4)
        guard readService(service, into: &sizeBuffer, count: 4) else {
            throw NSError(domain: "cleanmyiphone", code: 30, userInfo: [NSLocalizedDescriptionKey: "截图没有响应"])
        }
        let size = sizeBuffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard size > 0, size < 128 * 1024 * 1024 else {
            throw NSError(domain: "cleanmyiphone", code: 31, userInfo: [NSLocalizedDescriptionKey: "截图尺寸异常"])
        }
        var body = [UInt8](repeating: 0, count: Int(size))
        guard readService(service, into: &body, count: Int(size)) else {
            throw NSError(domain: "cleanmyiphone", code: 32, userInfo: [NSLocalizedDescriptionKey: "截图读取失败"])
        }
        let data = Data(body)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        if let dict = plist as? [String: Any] {
            for value in dict.values {
                if let data = value as? Data, data.count > 1024 { return data }
            }
        }
        return nil
    }


    /// 读字符串值（机型、系统版本、设备名）
    func deviceString(_ device: UnsafeMutableRawPointer, key: String) -> String? {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let value = copyValue(device, nil, key as CFString)?.takeRetainedValue() else { return nil }
        return value as? String
    }

    /// 布尔值（`PasswordProtected` 等）。键不存在返回 nil，不能落到 false 上。
    func deviceBool(_ device: UnsafeMutableRawPointer, key: String) -> Bool? {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let value = copyValue(device, nil, key as CFString)?.takeRetainedValue() else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "true" || text == "1" }
        return nil
    }

    /// 任意域的字符串值（`com.apple.mobile.iTunes` 之类）
    func deviceString(_ device: UnsafeMutableRawPointer, domain: String, key: String) -> String? {
        guard let value = copyValue(device, domain as CFString, key as CFString)?.takeRetainedValue() else { return nil }
        return value as? String
    }

    // MARK: - 电池 IORegistry（diagnostics_relay）

    /// 设备是否已锁屏：锁屏时读相册库会一直卡住，不如直接让用户去解锁
    func isLocked(_ device: UnsafeMutableRawPointer) -> Bool {
        // PasswordProtected 在锁屏时为 true；个别版本没这个键，用 DeviceLocked 兜底
        if let protected = deviceBool(device, key: "PasswordProtected"), protected { return true }
        if let locked = deviceBool(device, key: "DeviceLocked"), locked { return true }
        return false
    }

    /// `com.apple.mobile.diagnostics_relay` 的 GasGauge：与系统电池诊断同一条通道。
    /// 实测（iPhone 14 Pro / iOS 26.7）能拿到 `DesignCapacity`（mAh）、`FullChargeCapacity`
    /// （这里给的是百分比）、`CycleCount`。IORegistry 那条路的树是空的，温度拿不到。
    func batteryGauge(_ device: UnsafeMutableRawPointer) -> [String: Any] {
        guard let service = try? openService(device, name: "com.apple.mobile.diagnostics_relay") else { return [:] }
        for request in [["Request": "GasGauge"], ["Request": "All"]] {
            let response = serviceRequest(service, request)
            guard let diagnostics = response["Diagnostics"] as? [String: Any] else { continue }
            if let gauge = diagnostics["GasGauge"] as? [String: Any], !gauge.isEmpty { return gauge }
        }
        return [:]
    }

    /// IORegistry 里的电池节点（`AppleSmartBattery` / `pmu` 之类）。
    ///
    /// diagnostics_relay 回的是一棵**树**：`Diagnostics.<名字>.{regEntry, children:[...]}`，
    /// 只取根的一层会什么都看不到（之前的结论「IORegistry 只有一层」就是这么来的）。
    /// 这里按 children 递归，找到同时带 capacity 和 cycle 的那一层就返回它的属性。
    func batteryNodeProps(_ device: UnsafeMutableRawPointer) -> [String: Any] {
        var log: [String] = []
        defer { Self.writeBatteryDump(log) }
        guard let service = try? openService(device, name: "com.apple.mobile.diagnostics_relay") else {
            log.append("diagnostics_relay 服务打不开")
            return [:]
        }
        // 设备只回**一层** children，所以必须按名字/类名逐个点名请求，
        // 光递归是走不到深处的。名字在不同 SoC 上不一样，全都试一遍。
        var requests: [[String: Any]] = [
            ["Request": "IORegistry", "CurrentPlane": "IOService"],
            ["Request": "IORegistry"]
        ]
        for name in ["AppleSmartBattery", "AppleARMPMUCharger", "pmu", "battery", "AppleSmartBatteryManager"] {
            requests.append(["Request": "IORegistry", "CurrentPlane": "IOService", "EntryName": name])
            requests.append(["Request": "IORegistry", "CurrentPlane": "IOService", "EntryClass": name])
        }
        requests.append(["Request": "All"])

        for request in requests {
            let response = serviceRequest(service, request)
            let diagnostics = response["Diagnostics"] as? [String: Any]
            let keyList = response.keys.sorted().joined(separator: ",")
            let diagList = (diagnostics?.keys.sorted() ?? []).joined(separator: ",")
            log.append("请求 \(Self.describe(request)) → 顶层[\(keyList)] Diagnostics[\(diagList)]")
            if let diagnostics {
                for (name, value) in diagnostics {
                    guard let node = value as? [String: Any] else { continue }
                    let props = (node["regEntry"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-"
                    let kids = (node["children"] as? [Any])?.count ?? 0
                    log.append("  \(name): children=\(kids) regEntry[\(props)]")
                }
            }
            guard !response.isEmpty else { continue }
            if let hit = Self.findBatteryNode(response) {
                log.append("命中电池节点：\(hit.keys.sorted().joined(separator: ","))")
                return hit
            }
        }
        log.append("没有命中电池节点")
        return [:]
    }

    /// 现场写到能确定有权限的地方（App Support 下），顺便打一份到 stderr
    private static func writeBatteryDump(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data("[battery]\n".utf8))
        FileHandle.standardError.write(Data(text.utf8))
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanmyiphone", isDirectory: true)
        DeviceFiles.makePrivateDirectory(base)
        try? text.write(to: base.appendingPathComponent("battery-dump.txt"), atomically: true, encoding: .utf8)
    }

    private static func describe(_ request: [String: Any]) -> String {
        request.keys.sorted().map { "\($0)=\(request[$0] ?? "")" }.joined(separator: " ")
    }

    /// 在一棵任意嵌套的 plist 结构里找「像电池」的那层字典
    static func findBatteryNode(_ value: Any, depth: Int = 0) -> [String: Any]? {
        guard depth < 8 else { return nil }
        if let dict = value as? [String: Any] {
            let keys = dict.keys.map { $0.lowercased() }
            let hasCapacity = keys.contains { $0.contains("capacity") }
            let hasCycle = keys.contains { $0.contains("cycle") }
            if hasCapacity, hasCycle {
                return dict
            }
            // children 优先，避免先在 Summary 那类浅层字典上浪费
            if let children = dict["children"] as? [Any] {
                for child in children {
                    if let hit = findBatteryNode(child, depth: depth + 1) { return hit }
                }
            }
            for (key, child) in dict where key != "children" {
                if let hit = findBatteryNode(child, depth: depth + 1) { return hit }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let hit = findBatteryNode(child, depth: depth + 1) { return hit }
            }
        }
        return nil
    }

    // MARK: - House Arrest（App 容器 / 文稿与数据）

    /// 打开某个 App 的沙盒容器。`container` = false 只给 Documents（需要 App 打开文件共享）。
    /// 返回的 AFC 句柄根目录就是该 App 的容器，路径都相对它。
    func openHouseArrest(_ device: UnsafeMutableRawPointer,
                         bundleID: String,
                         container: Bool = true) throws -> UnsafeMutableRawPointer {
        let command = container ? "VendContainer" : "VendDocuments"
        let (afc, reply) = try startHouseArrest(device, bundleID: bundleID, command: command)
        if afc == nil {
            let error = (reply["Error"] as? String) ?? "没有拿到 AFC 通道"
            throw NSError(domain: "cleanmyiphone", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: "\(bundleID)：\(error)"])
        }
        return afc!
    }

    /// 探针用：直接把命令字典发过去，看服务怎么回
    func houseArrestRaw(_ device: UnsafeMutableRawPointer, command: [String: Any]) -> ([String: Any], Bool) {
        var service: UnsafeMutableRawPointer?
        let status = startService(device, "com.apple.mobile.house_arrest" as CFString, nil, &service)
        guard status == 0, let service else {
            return (["Error": "startService \(status)"], false)
        }
        let reply = serviceRequest(service, command)
        let text = (reply["Status"] as? String) ?? ""
        guard reply["Error"] == nil, text.lowercased() != "failure" else { return (reply, false) }
        guard let socket = serviceGetSocket(service) as Int32?, socket > 0,
              afcCreate(nil, socket, 0, nil, nil) != nil else {
            return (reply.merging(["Error": "AFC 通道建立失败"]) { $1 }, false)
        }
        return (reply, true)
    }

    private func startHouseArrest(_ device: UnsafeMutableRawPointer,
                                  bundleID: String,
                                  command: String) throws -> (UnsafeMutableRawPointer?, [String: Any]) {
        var service: UnsafeMutableRawPointer?
        let status = startService(device, "com.apple.mobile.house_arrest" as CFString, nil, &service)
        guard status == 0, let service else {
            throw NSError(domain: "cleanmyiphone", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "启动 house_arrest 失败（\(status)）"])
        }

        // 先发 Vend 指令，成功之后这条连接就变成 AFC 通道
        let reply = serviceRequest(service, ["Command": command, "Identifier": bundleID])
        let text = (reply["Status"] as? String) ?? ""
        guard reply["Error"] == nil, text.lowercased() != "failure" else {
            return (nil, reply)
        }

        let socket = serviceGetSocket(service)
        guard socket > 0, let afc = afcCreate(nil, socket, 0, nil, nil) else {
            return (nil, reply.merging(["Error": "AFC 通道建立失败"]) { $1 })
        }
        return (afc, reply)
    }


    /// 目录条目大小（开文件后 seek 到末尾取长度）。目录或空文件返回 0。
    func entrySize(_ afc: UnsafeMutableRawPointer, path: String) -> Int64 {
        guard let ref = try? openFile(afc, path: path) else { return 0 }
        defer { closeFile(afc, ref) }
        return fileSize(afc, ref)
    }

    /// 启动任意服务并返回 service connection
    func openService(_ device: UnsafeMutableRawPointer, name: String) throws -> UnsafeMutableRawPointer {
        var service: UnsafeMutableRawPointer?
        let status = startService(device, name as CFString, nil, &service)
        guard status == 0, let service else {
            throw NSError(domain: "cleanmyiphone", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "启动服务 \(name) 失败（\(status)）"])
        }
        return service
    }

    /// 服务上的一次 plist 请求（4 字节大端长度 + plist）
    func serviceRequest(_ service: UnsafeMutableRawPointer, _ request: [String: Any]) -> [String: Any] {
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0) else {
            return [:]
        }
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        let packet = header + payload
        _ = packet.withUnsafeBytes { raw in
            serviceSend(service, raw.baseAddress, packet.count)
        }

        var sizeBuffer = [UInt8](repeating: 0, count: 4)
        guard readService(service, into: &sizeBuffer, count: 4) else { return [:] }
        let size = sizeBuffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard size > 0, size < 64 * 1024 * 1024 else { return [:] }

        var body = [UInt8](repeating: 0, count: Int(size))
        guard readService(service, into: &body, count: Int(size)) else { return [:] }
        let data = Data(body)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    private func readService(_ service: UnsafeMutableRawPointer, into buffer: inout [UInt8], count: Int) -> Bool {
        var received = 0
        while received < count {
            let got = buffer.withUnsafeMutableBytes { raw -> Int32 in
                let base = raw.baseAddress!.advanced(by: received)
                return serviceReceive(service, base, count - received)
            }
            if got <= 0 { return received == count }
            received += Int(got)
        }
        return true
    }

    /// 打开 AFC 连接（com.apple.afc）
    func openAFC(_ device: UnsafeMutableRawPointer) throws -> UnsafeMutableRawPointer {
        var service: UnsafeMutableRawPointer?
        let status = startService(device, "com.apple.afc" as CFString, nil, &service)
        guard status == 0, let service else {
            throw NSError(domain: "cleanmyiphone", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "启动 AFC 服务失败（\(status)）"])
        }
        let socket = serviceGetSocket(service)
        guard socket > 0 else {
            throw NSError(domain: "cleanmyiphone", code: 70,
                          userInfo: [NSLocalizedDescriptionKey: "服务连接没有可用 socket"])
        }
        guard let afc = afcCreate(nil, socket, 0, nil, nil) else {
            throw NSError(domain: "cleanmyiphone", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "AFCConnectionCreate 失败"])
        }
        return afc
    }

    /// 优雅关掉 AFC 连接。
    /// 先 invalidate（让另一条线程里阻塞中的 `AFCFileRefOpen/Read` 立刻返回），
    /// 再 close（发 CLOSE 包并释放）。顺序反了会在阻塞线程里 UAF。
    func closeAFC(_ afc: UnsafeMutableRawPointer) {
        _ = afcInvalidate?(afc)
        _ = afcClose?(afc)
    }

    /// 结束 lockdownd 会话。子进程退出前调用，设备侧才认为这次 AFC 使用结束。
    func stopSession(_ device: UnsafeMutableRawPointer) {
        guard sessionOpened else { return }
        _ = stopSessionFn?(device)
        sessionOpened = false
    }

    /// 读取设备上的文件（AFC_FOPEN_RDONLY = 1）
    func readFile(_ afc: UnsafeMutableRawPointer, path: String, limit: Int = 64 * 1024 * 1024) throws -> Data {
        var ref: UnsafeMutableRawPointer?
        let openStatus = afcFileOpen(afc, path, 1, &ref)
        guard openStatus == 0, let ref else {
            throw NSError(domain: "cleanmyiphone", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "打不开 \(path)（\(openStatus)）"])
        }
        defer { _ = afcFileClose(afc, ref) }

        var data = Data()
        let chunk = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while data.count < limit {
            var lengthSlot: UInt64 = UInt64(chunk)
            let status = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &lengthSlot) { slot in
                    afcFileRead(afc, ref, raw.baseAddress,
                                UnsafeMutableRawPointer(slot).assumingMemoryBound(to: UInt32.self))
                }
            }
            let length = UInt32(truncatingIfNeeded: lengthSlot)
            if status != 0 { break }
            if length == 0 { break }
            // AFC 回 0 长度时 length 是脏值，不 clamp 会越界崩
            let count = min(Int(length), chunk)
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// 打开文件并返回 AFC 原始状态码（0 = 成功）。诊断用：
    /// 目录里明明有这个文件却「打不开」时，状态码能区分「没有文件」和「文件在但设备不给」。
    func openFileStatus(_ afc: UnsafeMutableRawPointer,
                        path: String,
                        _ ref: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
        apiLock.lock()
        defer { apiLock.unlock() }
        return afcFileOpen(afc, path, 1, ref)
    }

    /// 打开文件用于分片读取
    func openFile(_ afc: UnsafeMutableRawPointer, path: String) throws -> UnsafeMutableRawPointer {
        apiLock.lock()
        defer { apiLock.unlock() }
        var ref: UnsafeMutableRawPointer?
        let status = afcFileOpen(afc, path, 1, &ref)
        guard status == 0, let ref else {
            throw NSError(domain: "cleanmyiphone", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "打不开 \(path)（\(status)）"])
        }
        return ref
    }

    func closeFile(_ afc: UnsafeMutableRawPointer, _ ref: UnsafeMutableRawPointer) {
        apiLock.lock()
        defer { apiLock.unlock() }
        _ = afcFileClose(afc, ref)
    }


    /// 文件总字节数（seek 到末尾再 tell，随后回到开头）。拿不到返回 0。
    func fileSize(_ afc: UnsafeMutableRawPointer, _ ref: UnsafeMutableRawPointer) -> Int64 {
        apiLock.lock()
        defer { apiLock.unlock() }
        guard let afcFileSeek, let afcFileTell else { return 0 }
        guard afcFileSeek(afc, ref, 0, 2) == 0 else { return 0 }
        var size: UInt64 = 0
        let ok = afcFileTell(afc, ref, &size) == 0
        _ = afcFileSeek(afc, ref, 0, 0)
        guard ok, size > 0, size < 64 * 1024 * 1024 * 1024 else { return 0 }
        return Int64(size)
    }

    /// 最近一次 AFCFileRefRead 的返回码（0 正常，4 = READ_ERROR）
    private(set) var lastReadStatus: Int32 = 0

    /// 读一块（≤256 KB），返回 nil 表示读完或出错
    func readChunk(_ afc: UnsafeMutableRawPointer, _ ref: UnsafeMutableRawPointer, size: Int = 256 * 1024) -> Data? {
        apiLock.lock()
        defer { apiLock.unlock() }
        var buffer = [UInt8](repeating: 0, count: size)
        // 长度槽按 8 字节给：AFC 在某些系统上按 size_t 写回，
        // 只给 4 字节会踩到栈上的 canary（__stack_chk_fail 崩就是这个）
        var lengthSlot: UInt64 = UInt64(size)
        let status = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &lengthSlot) { slot in
                afcFileRead(afc, ref, raw.baseAddress,
                            UnsafeMutableRawPointer(slot).assumingMemoryBound(to: UInt32.self))
            }
        }
        lastReadStatus = status
        let length = UInt32(truncatingIfNeeded: lengthSlot)
        guard status == 0, length > 0 else { return nil }
        return Data(buffer[0..<min(Int(length), size)])
    }






    /// 流式下载到本地文件，返回写入字节数。`onBytes` 每 4 MB 回一次已写字节数，
    /// 父进程据此显示「已读 / 总量」。
    @discardableResult
    /// 下载一个文件。
    /// `expected` 给的是计划时量到的字节数：读到它就当文件尾，
    /// **不要**再用「连续 400 次空读 × 30ms」判尾 —— 那是每个文件固定多花 12 秒的来源，
    /// 相册库四件套就是因此出现好几次「卡住十几秒」。
    func downloadFile(_ afc: UnsafeMutableRawPointer,
                      path: String,
                      to destination: URL,
                      expected: Int64 = 0,
                      onBytes: ((Int64) -> Void)? = nil) throws -> Int64 {
        var ref: UnsafeMutableRawPointer?
        let openStatus = afcFileOpen(afc, path, 1, &ref)
        guard openStatus == 0, let ref else {
            throw NSError(domain: "cleanmyiphone", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "打不开 \(path)（\(openStatus)）"])
        }
        defer { _ = afcFileClose(afc, ref) }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw NSError(domain: "cleanmyiphone", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入 \(destination.path)"])
        }
        defer { try? handle.close() }

        let chunk = 256 * 1024   // AFC 单次读取上限，超过会返回 READ_ERROR
        var buffer = [UInt8](repeating: 0, count: chunk)
        var total: Int64 = 0
        var zeroReads = 0
        var slices = 0
        while true {
            var lengthSlot: UInt64 = UInt64(chunk)
            let status = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &lengthSlot) { slot in
                    afcFileRead(afc, ref, raw.baseAddress,
                                UnsafeMutableRawPointer(slot).assumingMemoryBound(to: UInt32.self))
                }
            }
            let length = UInt32(truncatingIfNeeded: lengthSlot)
            if status != 0 { break }
            if length == 0 {
                // 0 字节有两种：真的读完了，或者 USB 通道瞬时没数据。
                // 已经读到计划字节数 → 连空 3 拍（60 ms）就收工；
                // 还没读够 → 继续等，最多 40 拍（0.8 s）。
                zeroReads += 1
                let reachedPlan = expected > 0 && total >= expected
                if reachedPlan ? zeroReads > 3 : zeroReads > 40 { break }
                usleep(20_000)
                continue
            }
            zeroReads = 0
            let count = min(Int(length), chunk)
            handle.write(Data(buffer[0..<count]))
            total += Int64(count)
            slices += 1
            if let onBytes, slices % 16 == 0 { onBytes(total) }
        }
        if ProcessInfo.processInfo.environment["CMI_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[afc] end total=\(total) zeroReads=\(zeroReads) status=\(lastReadStatus)\n".utf8))
        }
        return total
    }

    func listDirectory(_ afc: UnsafeMutableRawPointer, path: String) throws -> [String] {
        apiLock.lock()
        defer { apiLock.unlock() }
        var dir: UnsafeMutableRawPointer?
        let status = afcDirOpen(afc, path, &dir)
        guard status == 0, let dir else {
            throw NSError(domain: "cleanmyiphone", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "打不开目录 \(path)（\(status)）"])
        }
        defer { _ = afcDirClose(afc, dir) }

        var names: [String] = []
        while true {
            var entry: UnsafeMutablePointer<CChar>?
            let readStatus = afcDirRead(afc, dir, &entry)
            if readStatus != 0 || entry == nil { break }
            names.append(String(cString: entry!))
        }
        return names.filter { $0 != "." && $0 != ".." }
    }
}
