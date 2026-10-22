import Foundation
import CryptoKit

enum CameraError: LocalizedError {
    case invalid(String)
    case timeout
    case closed
    case response(UInt16)
    case verification(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "相机数据异常：\(reason)"
        case .verification(let reason): return "读回尚未确认：\(reason)"
        case .timeout: return "连接超时。请检查相机 Wi-Fi、IP 地址，并确认 SnapBridge 已断开。"
        case .closed: return "连接已断开，请重新连接相机 Wi-Fi 后重试。"
        case .response(let code):
            if code == 0x2019 { return "相机忙碌，请稍后重试（0x2019）。" }
            if code == 0x200F { return "相机拒绝此写入（0x200F）；文件数据或当前拍摄状态未被接受。" }
            if code == 0x2005 { return "相机在当前连接模式下不支持这条指令（0x2005）。" }
            return String(format: "相机返回 0x%04X", code)
        }
    }
}

struct BinaryReader {
    let data: Data
    private(set) var offset = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw CameraError.invalid("数据长度不足") }
        defer { offset += count }
        return Data(data.dropFirst(offset).prefix(count))
    }
    mutating func u8() throws -> UInt8 { try bytes(1).first! }
    mutating func u16() throws -> UInt16 {
        let b = Array(try bytes(2)); return UInt16(b[0]) | UInt16(b[1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let b = Array(try bytes(4)); return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    mutating func u64() throws -> UInt64 {
        let low = try u32(), high = try u32(); return UInt64(low) | UInt64(high) << 32
    }
    mutating func string() throws -> String {
        let length = Int(try u8())
        guard length > 0 else { return "" }
        let raw = try bytes(length * 2)
        guard raw.suffix(2) == Data([0, 0]), let value = String(data: raw.dropLast(2), encoding: .utf16LittleEndian) else {
            throw CameraError.invalid("PTP 字符串格式错误")
        }
        return value
    }
    mutating func array16() throws -> [UInt16] {
        let count = Int(try u32())
        guard count <= (data.count - offset) / 2 else { throw CameraError.invalid("数组越界") }
        return try (0..<count).map { _ in try u16() }
    }
}

struct NP3Document: Sendable {
    let records: [UInt32: Data]
    init(_ data: Data) throws {
        guard data.count <= 65536 else { throw CameraError.invalid("配方文件过大") }
        var reader = BinaryReader(data: data)
        guard try reader.bytes(4) == Data([78, 67, 80, 0]) else {
            throw CameraError.invalid("不是 Nikon Picture Control 文件")
        }
        func big32(_ data: Data) -> UInt32 { data.reduce(0) { ($0 << 8) | UInt32($1) } }
        var records: [UInt32: Data] = [:]
        while true {
            let tag = big32(try reader.bytes(4))
            if tag == 0 {
                guard reader.offset == data.count else { throw CameraError.invalid("配方结束标记后有额外数据") }
                break
            }
            guard records.count < 64, records[tag] == nil else { throw CameraError.invalid("配方记录重复或过多") }
            let count = Int(big32(try reader.bytes(4)))
            records[tag] = try reader.bytes(count)
        }
        self.records = records
    }
}

// Classic NCP storage is distinct from the Z30's PTP wire dataset. Retain the
// complete original, including the author's LUT, until that wire layout is verified.
struct ClassicNCPRecipe: Sendable {
    let original: Data
    let name: String
    let base: UInt16
    let settings: Data
    let curve: Data?
    var baseName: String {
        [UInt16(0x0001): "标准", 0x03C2: "自然", 0x00C3: "鲜艳",
         0x0486: "人像", 0x04C7: "风景", 0x064D: "单色"][base] ?? "未知"
    }
    init(_ data: Data) throws {
        let records = try NP3Document(data).records
        guard Set(records.keys) == [1] || Set(records.keys) == [1, 2],
              let body = records[1], body.count == 36, body.prefix(4) == Data("0100".utf8),
              [UInt8(0),2].contains(body[26]), body[27] == 255 else {
            throw CameraError.invalid("尚不支持此 NCP 版本或扩展设置")
        }
        let nameData = body.subdata(in: 4..<24)
        guard let end = nameData.firstIndex(of: 0), end > 0,
              nameData[..<end].allSatisfy({ (32...126).contains($0) }),
              nameData[end...].allSatisfy({ $0 == 0 }) else {
            throw CameraError.invalid("NCP 名称须为 1–19 个 ASCII 字符")
        }
        let base = UInt16(body[24]) << 8 | UInt16(body[25])
        guard [UInt16(0x0001), 0x03C2, 0x00C3, 0x0486, 0x04C7, 0x064D].contains(base) else {
            throw CameraError.invalid("此 NCP 的基础优化校准暂未支持")
        }
        let usesCurve = body[29] == 1 || body[30] == 1
        guard (body[28] == 0 || (128...137).contains(body[28])),
              (body[29] == 0 || body[29] == 1 || (125...131).contains(body[29])),
              (body[30] == 1 || (127...129).contains(body[30])),
              (usesCurve ? body[29] == 1 && body[30] == 1 && records[2] != nil : records[2] == nil) else {
            throw CameraError.invalid("NCP 参数或曲线标记不完整")
        }
        if base == 0x064D {
            guard body[31] == 255, body[32] == 255,
                  (128...132).contains(body[33]), (128...137).contains(body[34]),
                  (body[35] == 255 || (128...135).contains(body[35])) else {
                throw CameraError.invalid("NCP 单色设置超出支持范围")
            }
        } else {
            guard (body[31] == 0 || (125...131).contains(body[31])),
                  (125...131).contains(body[32]), body.suffix(3) == Data([255,255,255]) else {
                throw CameraError.invalid("NCP 色彩设置超出支持范围")
            }
        }
        if let curve = records[2] { try Self.validateCurve(curve) }
        original = data; settings = body; curve = records[2]; self.base = base
        name = String(decoding: nameData.prefix(upTo: end), as: UTF8.self)
    }
    static func validateCurve(_ curve: Data, allowLUTOnly: Bool = false) throws {
        guard curve.count == 578, curve.prefix(2) == Data([0x49, 0x30]),
              curve[2] < curve[3], curve[4] <= curve[5],
              (1...9).contains(curve[6]) || (curve[6] == 0 && curve[7] > 0) else {
            throw CameraError.invalid("NCP 曲线头或长度异常")
        }
        let points = Int(curve[8])
        guard curve[7] < 100, (allowLUTOnly && points == 0 || (2...20).contains(points)),
              (points < 2 || (1..<points).allSatisfy({ curve[9 + ($0 - 1) * 2] < curve[9 + $0 * 2] })),
              curve[(9 + points * 2)..<64].allSatisfy({ $0 == 0 }),
              (0..<257).allSatisfy({ (UInt16(curve[64 + $0 * 2]) << 8 | UInt16(curve[65 + $0 * 2])) <= 32767 }) else {
            throw CameraError.invalid("NCP 曲线控制点或查找表异常")
        }
    }
    var transferIssue: String? { nil }
    func wirePayload() throws -> Data {
        var bytes = Data(repeating: 0, count: 36)
        bytes[0] = Self.wireBaseIDs[base]!
        bytes.replaceSubrange(2..<22, with: settings.subdata(in: 4..<24))
        func quarter(_ value: UInt8) -> UInt8 {
            // Auto and N/A are sent as sentinels, not multiplied into zero.
            if value == 0 { return 128 }
            if value == 255 { return 127 }
            return UInt8(truncatingIfNeeded: (Int(value) - 128) * 4)
        }
        bytes[25] = quarter(settings[28])
        if base == 0x064D {
            bytes[30] = 127; bytes[31] = 127
            bytes[32] = settings[33] - 128
            bytes[33] = settings[34] - 128
            bytes[34] = quarter(settings[35])
        } else {
            bytes[30] = quarter(settings[31]); bytes[31] = quarter(settings[32])
        }
        if let curve { bytes[35] = 1; bytes.append(curve) }
        else {
            bytes[28] = quarter(settings[29]); bytes[29] = quarter(settings[30])
        }
        _ = try PictureControlWirePayload(bytes)
        return bytes
    }
    static let wireBaseIDs: [UInt16: UInt8] = [0x0001:1, 0x03C2:2, 0x00C3:3, 0x064D:4, 0x0486:5, 0x04C7:6]
    var summary: String {
        "\(baseName) · " + (curve.map { "自定义曲线（\($0[8]) 个控制点）" } ?? "基本参数")
    }
}

enum PhoneRecipeDocument: Sendable {
    case np3(StandardNP3Recipe)
    case neutralNP3(NeutralNP3Recipe)
    case ncp(ClassicNCPRecipe)
    case ordinaryNP3(OrdinaryNP3Recipe)
    init(_ data: Data) throws {
        let records = try NP3Document(data).records
        if records[1] != nil { self = .ncp(try ClassicNCPRecipe(data)) }
        else if records[0x100] == Data("0310".utf8), records[0x300] == Data([0,32]) {
            throw CameraError.invalid("这是灵活色彩云创配方，Z30 无法直接载入。请选择兼容的 NCP 或普通优化校准 NP3。")
        } else { self = .ordinaryNP3(try OrdinaryNP3Recipe(data)) }
    }
    var name: String { switch self { case .np3(let r): return r.name; case .neutralNP3(let r): return r.name; case .ncp(let r): return r.name; case .ordinaryNP3(let r): return r.name } }
    var summary: String { switch self { case .np3(let r): return r.summary; case .neutralNP3(let r): return r.summary; case .ncp(let r): return r.summary; case .ordinaryNP3(let r): return r.summary } }
    var fileExtension: String { switch self { case .np3, .neutralNP3, .ordinaryNP3: return "NP3"; case .ncp: return "NCP" } }
    var transferIssue: String? { nil }
    func verifiedPayload() throws -> Data {
        switch self { case .np3(let r): return r.payload; case .neutralNP3(let r): return r.payload; case .ncp(let r): return try r.wirePayload(); case .ordinaryNP3(let r): return r.payload }
    }
}

// Transport validation checks dataset framing, not an approved-style whitelist.
struct PictureControlWirePayload {
    let bytes: Data
    init(_ bytes: Data) throws {
        guard [36,614].contains(bytes.count), bytes[35] == (bytes.count == 614 ? 1 : 0) else {
            throw CameraError.invalid("配方数据长度或曲线标记不完整")
        }
        let name = bytes.subdata(in: 2..<22)
        guard let end = name.firstIndex(of: 0), end > 0,
              name[..<end].allSatisfy({ (32...126).contains($0) }), name[end...].allSatisfy({ $0 == 0 }) else {
            throw CameraError.invalid("优化校准名称无效")
        }
        if bytes.count == 614 { try ClassicNCPRecipe.validateCurve(bytes.subdata(in: 36..<614), allowLUTOnly: true) }
        self.bytes = bytes
    }
}

struct RecipeImportResult: Sendable {
    var importedIDs: [String] = []
    var duplicateIDs: [String] = []
    var failures: [String] = []
    var summary: String {
        "已导入 \(importedIDs.count) 个，重复 \(duplicateIDs.count) 个，失败 \(failures.count) 个。"
    }
}

enum RecipeLibraryImporter {
    static func importFiles(_ urls: [URL], into folder: URL) throws -> RecipeImportResult {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var existing: [Data: String] = [:]
        for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            guard ["np3", "ncp"].contains(file.pathExtension.lowercased()),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
                  let data = try? Data(contentsOf: file) else { continue }
            existing[data] = file.lastPathComponent
        }
        var result = RecipeImportResult()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard ["np3", "ncp"].contains(url.pathExtension.lowercased()),
                      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536 else {
                    throw CameraError.invalid("请选择不超过 64 KB 的 NCP 或 NP3 文件")
                }
                let data = try Data(contentsOf: url)
                let recipe = try PhoneRecipeDocument(data)
                if let duplicate = existing[data] {
                    result.duplicateIDs.append(duplicate); continue
                }
                let id = "\(UUID().uuidString).\(recipe.fileExtension)"
                try data.write(to: folder.appendingPathComponent(id), options: .atomic)
                existing[data] = id; result.importedIDs.append(id)
            } catch { result.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }
}

struct OrdinaryNP3Recipe: Sendable {
    let name: String
    let summary: String
    let payload: Data
    init(_ data: Data) throws {
        let records = try NP3Document(data).records
        guard let version = records[0x100], [Data("0300".utf8),Data("0310".utf8)].contains(version),
              let baseData = records[0x300], baseData.count == 2,
              let nameData = records[0x200], nameData.count == 20 else {
            throw CameraError.invalid("NP3 缺少版本、基础风格或名称数据")
        }
        let base = UInt16(baseData[0]) << 8 | UInt16(baseData[1])
        guard let wireBase = ClassicNCPRecipe.wireBaseIDs[base] else {
            throw CameraError.invalid("此 NP3 基础风格尚无对应的无线数据编码")
        }
        var bytes = Data(repeating: 0, count: 36); bytes[0] = wireBase
        bytes.replaceSubrange(2..<22, with: nameData)
        let curve = records[2]
        for parameter in StandardNP3Recipe.parameters {
            guard let value = records[parameter.tag], value.count == 2 else {
                throw CameraError.invalid("NP3 缺少\(parameter.label)参数")
            }
            if curve != nil && [UInt32(0x800),0x900].contains(parameter.tag) { continue }
            bytes[parameter.offset] = UInt8(truncatingIfNeeded: Int(value[0])-128)
        }
        if wireBase == 4 {
            for (tag, offset): (UInt32, Int) in [(0xC00,32),(0xD00,33),(0xE00,34)] {
                guard let value = records[tag], value.count == 2 else { throw CameraError.invalid("NP3 单色参数不完整") }
                bytes[offset] = UInt8(truncatingIfNeeded: Int(value[0])-128)
            }
        }
        if let curve { bytes[35] = 1; bytes.append(curve) }
        _ = try PictureControlWirePayload(bytes)
        name = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)
        let baseName = [1:"标准",2:"自然",3:"鲜艳",4:"单色",5:"人像",6:"风景"][Int(wireBase)]!
        summary = "\(baseName) · " + (curve == nil ? "参数配方" : "自定义曲线")
        payload = bytes
    }
}

struct NeutralPictureControlPayload {
    let bytes: Data
    init(_ bytes: Data) throws {
        guard [36,614].contains(bytes.count), bytes.prefix(2) == Data([2,0]),
              bytes[22] == 0, bytes[23] <= 1, bytes[24] == 0,
              bytes[32..<35].allSatisfy({ $0 == 0 }),
              bytes[35] == (bytes.count == 614 ? 1 : 0),
              StandardNP3Recipe.parameters.allSatisfy({ $0.quarters.contains(Int(Int8(bitPattern: bytes[$0.offset]))) }),
              bytes.count != 614 || (bytes[28] == 0 && bytes[29] == 0) else {
            throw CameraError.invalid("自然优化校准的数据格式或参数范围不符")
        }
        let name = bytes.subdata(in: 2..<22)
        guard let end = name.firstIndex(of: 0), end > 0,
              name[..<end].allSatisfy({ (32...126).contains($0) }), name[end...].allSatisfy({ $0 == 0 }) else {
            throw CameraError.invalid("优化校准名称无效")
        }
        if bytes.count == 614 { try ClassicNCPRecipe.validateCurve(bytes.subdata(in: 36..<614), allowLUTOnly: true) }
        self.bytes = bytes
    }
}

struct NeutralNP3Recipe: Sendable {
    let name: String
    let payload: Data
    let hasCurve: Bool
    init(_ data: Data) throws {
        let records = try NP3Document(data).records
        let hasCurve = records[2] != nil
        let required = Set((1...22).map { UInt32($0 * 256) }).union(hasCurve ? [2] : [])
        guard Set(records.keys) == required, records[0x100] == Data("0300".utf8),
              records[0x300] == Data([3,194]), [Data([0,0]),Data([2,0])].contains(records[0x400] ?? Data()) else {
            throw CameraError.invalid("此自然基底 NP3 版本或扩展设置暂不支持")
        }
        let constants: [UInt32:Data] = [0x500:Data([255,1]),0xC00:Data([255,0]),0xD00:Data([255,0]),0xE00:Data([255,4]),
            0xF00:Data([255,1]),0x1000:Data([255,1]),0x1100:Data([255,1]),0x1200:Data([255,1]),
            0x1300:Data([255,1]),0x1400:Data([128,1]),0x1500:Data([255,10])]
        guard constants.allSatisfy({ records[$0.key] == $0.value }), let nameData = records[0x200], nameData.count == 20 else {
            throw CameraError.invalid("NP3 含未支持的扩展设置")
        }
        var bytes = Data(repeating: 0, count: 36); bytes[0] = 2; bytes.replaceSubrange(2..<22, with: nameData)
        for parameter in StandardNP3Recipe.parameters {
            guard let value = records[parameter.tag], value.count == 2, value[1] == 4 else { throw CameraError.invalid("NP3 参数格式不符") }
            if hasCurve && [UInt32(0x800),0x900].contains(parameter.tag) {
                guard value[0] == 1 else { throw CameraError.invalid("NP3 曲线标记不一致") }
            } else {
                guard parameter.quarters.contains(Int(value[0])-128) else { throw CameraError.invalid("NP3 自动参数暂不支持") }
                bytes[parameter.offset] = UInt8(truncatingIfNeeded: Int(value[0])-128)
            }
        }
        if let curve = records[2] { bytes[35] = 1; bytes.append(curve) }
        _ = try NeutralPictureControlPayload(bytes)
        name = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self); payload = bytes; self.hasCurve = hasCurve
    }
    var summary: String { "自然 · " + (hasCurve ? "自定义曲线" : "手动参数") }
}

struct StandardNP3Recipe: Sendable {
    let document: NP3Document
    let name: String
    // Tags and offsets were paired against a camera-exported Z30 0300 file.
    static let parameters: [(tag: UInt32, offset: Int, label: String, quarters: ClosedRange<Int>)] = [
        (0x600, 25, "锐化", -12...36), (0x1600, 26, "中等范围锐化", -20...20),
        (0x700, 27, "清晰度", -20...20), (0x800, 28, "对比度", -12...12),
        (0x900, 29, "亮度", -6...6), (0xA00, 30, "饱和度", -12...12), (0xB00, 31, "色相", -12...12)
    ]
    init(_ data: Data) throws {
        let document = try NP3Document(data)
        let records = document.records
        guard Set(records.keys) == Set((1...22).map { UInt32($0 * 256) }),
              records[0x100] == Data("0300".utf8), records[0x300] == Data([0, 1]) else {
            throw CameraError.invalid("这份 NP3 的版本、基础风格或扩展设置暂不支持")
        }
        let constants: [UInt32: Data] = [0x400: Data([0,0]), 0x500: Data([255,1]),
            0xC00: Data([255,0]), 0xD00: Data([255,0]), 0xE00: Data([255,4]),
            0xF00: Data([255,1]), 0x1000: Data([255,1]), 0x1100: Data([255,1]),
            0x1200: Data([255,1]), 0x1300: Data([255,1]), 0x1400: Data([128,1]), 0x1500: Data([255,10])]
        guard constants.allSatisfy({ records[$0.key] == $0.value }) else {
            throw CameraError.invalid("NP3 含尚未验证的扩展设置，未允许载入")
        }
        guard let nameData = records[0x200], nameData.count == 20,
              let end = nameData.firstIndex(of: 0), end > 0,
              nameData[..<end].allSatisfy({ (32...126).contains($0) }),
              nameData[end...].allSatisfy({ $0 == 0 }) else {
            throw CameraError.invalid("NP3 名称须为 1–19 个 ASCII 字符")
        }
        for parameter in Self.parameters {
            guard let record = records[parameter.tag], record.count == 2, record[1] == 4,
                  parameter.quarters.contains(Int(record[0]) - 128) else {
                throw CameraError.invalid("\(parameter.label) 含不支持的自动、曲线或超范围数值")
            }
        }
        self.document = document
        name = String(decoding: nameData.prefix(upTo: end), as: UTF8.self)
    }
    var summary: String {
        Self.parameters.map { "\($0.label) \(Double(Int(document.records[$0.tag]![0]) - 128) / 4)" }.joined(separator: " · ")
    }
    var payload: Data {
        var data = Data([1, 0]); data.append(document.records[0x200]!)
        // The camera's own NP3 loader produces 0 at byte 23 (the body-created
        // unmodified STANDARD copy uses 1); both were observed on this Z30.
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        for parameter in Self.parameters {
            data[parameter.offset] = UInt8(truncatingIfNeeded: Int(document.records[parameter.tag]![0]) - 128)
        }
        return data
    }
}

extension Data {
    mutating func put16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func put32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> shift) & 255)) } }
    mutating func put64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { append(UInt8((value >> shift) & 255)) } }
    func hex(limit: Int = 48) -> String { prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct PTPPacket: Sendable {
    let type: UInt32
    let payload: Data
    var encoded: Data {
        var output = Data(); output.put32(UInt32(8 + payload.count)); output.put32(type); output.append(payload); return output
    }
    static func operation(_ code: UInt16, transaction: UInt32, parameters: [UInt32] = [], dataPhase: UInt32 = 1) -> PTPPacket {
        var p = Data(); p.put32(dataPhase); p.put16(code); p.put32(transaction)
        parameters.forEach { p.put32($0) }
        return PTPPacket(type: 6, payload: p)
    }
}

struct PacketFramer {
    static let maxPacketBytes = 8 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [PTPPacket] {
        buffer.append(data)
        var packets: [PTPPacket] = []
        while buffer.count >= 8 {
            var r = BinaryReader(data: buffer)
            let length = Int(try r.u32()), type = try r.u32()
            guard length >= 8, length <= Self.maxPacketBytes else { throw CameraError.invalid("PTP/IP 包长度无效") }
            guard buffer.count >= length else { break }
            packets.append(PTPPacket(type: type, payload: Data(buffer.dropFirst(8).prefix(length - 8))))
            buffer = Data(buffer.dropFirst(length))
        }
        return packets
    }
}

struct DeviceInfo: Sendable {
    let manufacturer: String
    let model: String
    let firmware: String
    let operations: [UInt16]
    let identityFingerprint: String?
    init(_ data: Data) throws {
        var r = BinaryReader(data: data)
        _ = try r.u16(); _ = try r.u32(); _ = try r.u16(); _ = try r.string(); _ = try r.u16()
        operations = try r.array16()
        for _ in 0..<4 { _ = try r.array16() }
        manufacturer = try r.string(); model = try r.string(); firmware = try r.string()
        let serial = try r.string()
        // Keep only a local fingerprint for matching recovery to the same camera.
        identityFingerprint = serial.isEmpty ? nil : SHA256.hash(data: Data((manufacturer + "\0" + model + "\0" + serial).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct PictureControlDescriptor: Sendable {
    let writable: Bool
    let current: UInt16
    let choices: [UInt16]
    init(_ data: Data) throws {
        var r = BinaryReader(data: data)
        guard try r.u16() == 0xD200, try r.u16() == 4 else { throw CameraError.invalid("优化校准属性类型不符") }
        writable = try r.u8() == 1
        _ = try r.u16(); current = try r.u16()
        let form = try r.u8()
        if form == 2 {
            let count = Int(try r.u16()); choices = try (0..<count).map { _ in try r.u16() }
        } else if form == 0 { choices = [] }
        else { throw CameraError.invalid("未识别的优化校准属性表") }
    }
}

struct PTPDataTransaction {
    let id: UInt32
    private var expected: UInt64?
    private var ended = false
    private var output = Data()
    init(id: UInt32) { self.id = id }
    mutating func consume(_ packet: PTPPacket) throws -> Data? {
        var r = BinaryReader(data: packet.payload)
        switch packet.type {
        case 9:
            guard expected == nil, !ended, try r.u32() == id else { throw CameraError.invalid("数据开始包或事务编号错误") }
            let size = try r.u64()
            guard r.offset == packet.payload.count, size == UInt64.max || size <= UInt64(PacketFramer.maxPacketBytes) else {
                throw CameraError.invalid("读取数据过大或开始包格式错误")
            }
            expected = size
        case 10, 12:
            guard expected != nil, !ended, try r.u32() == id else { throw CameraError.invalid("数据分段顺序或事务编号错误") }
            let chunk = try r.bytes(packet.payload.count - r.offset)
            guard chunk.count <= PacketFramer.maxPacketBytes - output.count else { throw CameraError.invalid("读取数据过大") }
            output.append(chunk)
            if let expected, expected != UInt64.max, UInt64(output.count) > expected { throw CameraError.invalid("数据超出声明长度") }
            if packet.type == 12 {
                ended = true
                guard expected == UInt64.max || UInt64(output.count) == expected else { throw CameraError.invalid("数据未传输完整") }
            }
        case 7:
            let status = try r.u16()
            guard try r.u32() == id else { throw CameraError.invalid("响应事务编号错误") }
            guard status == 0x2001 else { throw CameraError.response(status) }
            guard expected == nil || ended else { throw CameraError.invalid("缺少数据结束包") }
            return output
        default: throw CameraError.invalid("命令通道收到意外的数据包 \(packet.type)")
        }
        return nil
    }
}
