import Foundation

/// 轻量 usbmux + lockdownd 客户端（纯 Swift，无外部依赖）。
/// 第一步只做：列出设备、连上 lockdownd、读设备信息。
/// 会话加密（StartSession + TLS）与 AFC 在下一层。
final class AFClient {

    enum AFError: LocalizedError {
        case socket(String)
        case protocolError(String)
        case deviceNotFound

        var errorDescription: String? {
            switch self {
            case .socket(let m): return "连接失败：\(m)"
            case .protocolError(let m): return "协议错误：\(m)"
            case .deviceNotFound: return "没有找到设备"
            }
        }
    }

    struct MuxDevice {
        let deviceID: Int
        let serial: String
        let connectionType: String
        let productID: Int
    }

    private let socketPath = "/var/run/usbmuxd"

    // MARK: - usbmux

    func listDevices() throws -> [MuxDevice] {
        let fd = try openMuxSocket()
        defer { close(fd) }

        let request: [String: Any] = [
            "MessageType": "ListDevices",
            "ClientVersionString": "cleanmyiphone",
            "ProgName": "cleanmyiphone",
            "kLibUSBMuxVersion": 3
        ]
        try sendMux(fd: fd, payload: request, tag: 1)
        let response = try receiveMux(fd: fd)

        guard let list = response["DeviceList"] as? [[String: Any]] else {
            throw AFError.protocolError("DeviceList 缺失")
        }
        return list.compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any],
                  let id = entry["DeviceID"] as? Int ?? props["DeviceID"] as? Int
            else { return nil }
            return MuxDevice(
                deviceID: id,
                serial: props["SerialNumber"] as? String ?? "",
                connectionType: props["ConnectionType"] as? String ?? "USB",
                productID: props["ProductID"] as? Int ?? 0
            )
        }
    }

    /// 连接设备的 lockdownd（62078），返回一个可读写的 fd。
    func connectLockdown(deviceID: Int) throws -> Int32 {
        let fd = try openMuxSocket()
        let request: [String: Any] = [
            "MessageType": "Connect",
            "DeviceID": deviceID,
            "PortNumber": UInt32(62078).byteSwapped,
            "ClientVersionString": "cleanmyiphone",
            "ProgName": "cleanmyiphone",
            "kLibUSBMuxVersion": 3
        ]
        try sendMux(fd: fd, payload: request, tag: 2)
        let response = try receiveMux(fd: fd)

        if let result = response["Result"] as? Int, result != 0 {
            close(fd)
            throw AFError.protocolError("Connect 被拒绝（Result=\(result)），可能需要在 iPhone 上点「信任」")
        }
        return fd
    }

    // MARK: - lockdownd

    func queryType(fd: Int32) throws -> String {
        let response = try lockdown(fd: fd, request: [
            "Label": "cleanmyiphone",
            "Request": "QueryType"
        ])
        return response["Type"] as? String ?? "未知"
    }

    func getValue(fd: Int32, key: String? = nil, domain: String? = nil) throws -> [String: Any] {
        var request: [String: Any] = [
            "Label": "cleanmyiphone",
            "Request": "GetValue"
        ]
        if let key { request["Key"] = key }
        if let domain { request["Domain"] = domain }
        return try lockdown(fd: fd, request: request)
    }

    private func lockdown(fd: Int32, request: [String: Any]) throws -> [String: Any] {
        let payload = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(fd, header + payload)

        let sizeData = try readExactly(fd, 4)
        let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard size > 0, size < 32 * 1024 * 1024 else {
            throw AFError.protocolError("响应长度异常：\(size)")
        }
        let body = try readExactly(fd, Int(size))
        guard let plist = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
            throw AFError.protocolError("响应不是字典")
        }
        return plist
    }

    // MARK: - 底层 socket

    private func openMuxSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AFError.socket("socket() 失败") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            let maxLen = min(bytes.count, raw.count - 1)
            for index in 0..<maxLen { raw[index] = bytes[index] }
            raw[maxLen] = 0
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, size)
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw AFError.socket("usbmuxd: \(message)")
        }
        return fd
    }

    private func sendMux(fd: Int32, payload: [String: Any], tag: Int) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(8).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(tag).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).littleEndian) { Data($0) })
        try writeAll(fd, header + body)
    }

    private func receiveMux(fd: Int32) throws -> [String: Any] {
        let header = try readExactly(fd, 16)
        let length = header[12..<16].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length < 32 * 1024 * 1024 else {
            throw AFError.protocolError("头长度异常：\(length)")
        }
        let body = try readExactly(fd, Int(length))
        guard let plist = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
            throw AFError.protocolError("响应不是字典")
        }
        return plist
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = write(fd, base.advanced(by: offset), data.count - offset)
                if written <= 0 { throw AFError.socket("写入失败") }
                offset += written
            }
        }
    }

    private func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while data.count < count {
            let got = read(fd, &buffer, count - data.count)
            if got <= 0 { throw AFError.socket("读取失败（连接被关闭）") }
            data.append(contentsOf: buffer[0..<got])
        }
        return data
    }
}
