import Foundation
@preconcurrency import Network

// All socket state is confined to queue. Every timeout retires that socket,
// so late packets cannot be consumed by a subsequent transaction.
final class PacketSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Z30Lab.socket.\(UUID())")
    private let connection: NWConnection
    private var framer = PacketFramer()
    private var packets: [PTPPacket] = []
    private var queuedBytes = 0
    private var waiter: CheckedContinuation<PTPPacket, Error>?
    private var opening: CheckedContinuation<Void, Error>?
    private var sending: CheckedContinuation<Void, Error>?
    private var pendingWrites: [(PTPPacket, UUID, CheckedContinuation<Void, Error>)] = []
    private var activeWriteID: UUID?
    private var failure: Error?
    private var readGeneration: UInt64 = 0
    private var sendGeneration: UInt64 = 0

    init(host: String, port: UInt16, requireWiFi: Bool) {
        let parameters = NWParameters.tcp
        if requireWiFi { parameters.requiredInterfaceType = .wifi }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }
    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async {
                    if let failure = self.failure { c.resume(throwing: failure); return }
                    self.opening = c
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            let c = self.opening; self.opening = nil; c?.resume(); self.receive()
                        case .failed(let error): self.fail(error)
                        case .cancelled: self.fail(CameraError.closed)
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 12) {
                        if self.opening != nil { self.fail(CameraError.timeout) }
                    }
                }
            }
        } onCancel: { self.close() }
    }
    func close() { queue.async { self.fail(CameraError.closed) } }
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        connection.stateUpdateHandler = nil
        connection.cancel()
        let o = opening, s = sending, w = waiter
        opening = nil; sending = nil; waiter = nil
        let pending = pendingWrites; pendingWrites = []; activeWriteID = nil
        packets.removeAll(); queuedBytes = 0
        o?.resume(throwing: error); s?.resume(throwing: error); w?.resume(throwing: error)
        for (_, _, continuation) in pending { continuation.resume(throwing: error) }
    }
    private func receive() {
        guard failure == nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            guard self.failure == nil else { return }
            if let data, !data.isEmpty {
                do {
                    for packet in try self.framer.append(data) {
                        if let w = self.waiter {
                            self.waiter = nil; w.resume(returning: packet)
                        } else {
                            guard self.packets.count < 1024, packet.payload.count <= PacketFramer.maxPacketBytes - self.queuedBytes else {
                                throw CameraError.invalid("相机待处理数据过多")
                            }
                            self.queuedBytes += packet.payload.count; self.packets.append(packet)
                        }
                    }
                } catch { self.fail(error); return }
            }
            if let error { self.fail(error) }
            else if complete { self.fail(CameraError.closed) }
            else { self.receive() }
        }
    }
    func read(timeout: TimeInterval? = 12) async throws -> PTPPacket {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                queue.async {
                    if let failure = self.failure { c.resume(throwing: failure); return }
                    if !self.packets.isEmpty {
                        let packet = self.packets.removeFirst(); self.queuedBytes -= packet.payload.count
                        c.resume(returning: packet); return
                    }
                    guard self.waiter == nil else { c.resume(throwing: CameraError.invalid("重复读取通道")); return }
                    self.waiter = c; self.readGeneration &+= 1
                    let generation = self.readGeneration
                    if let timeout {
                        self.queue.asyncAfter(deadline: .now() + timeout) {
                            if self.waiter != nil, generation == self.readGeneration { self.fail(CameraError.timeout) }
                        }
                    }
                }
            }
        } onCancel: { self.close() }
    }
    func write(_ packet: PTPPacket) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async {
                    if let failure = self.failure { c.resume(throwing: failure); return }
                    guard self.pendingWrites.count < 32 else { c.resume(throwing: CameraError.invalid("发送队列已满")); return }
                    let id = UUID()
                    self.pendingWrites.append((packet, id, c))
                    self.pumpWrites()
                    self.queue.asyncAfter(deadline: .now() + 12) {
                        if self.activeWriteID == id || self.pendingWrites.contains(where: { $0.1 == id }) { self.fail(CameraError.timeout) }
                    }
                }
            }
        } onCancel: { self.close() }
    }
    private func pumpWrites() {
        guard failure == nil, sending == nil, !pendingWrites.isEmpty else { return }
        let (packet, id, continuation) = pendingWrites.removeFirst()
        sending = continuation; activeWriteID = id; sendGeneration &+= 1
        let generation = sendGeneration
        connection.send(content: packet.encoded, completion: .contentProcessed { error in
            guard generation == self.sendGeneration, self.sending != nil else { return }
            if let error { self.fail(error) }
            else {
                let c = self.sending; self.sending = nil; self.activeWriteID = nil
                c?.resume(); self.pumpWrites()
            }
        })
    }
}

struct SlotBackup: Codable, Sendable, Identifiable {
    var slot: Int
    var pictureControlID: UInt16
    var payload: Data?
    var expandedPayload: Data?
    var response: UInt16?
    var expandedResponse: UInt16?
    var id: Int { slot }
    var name: String? {
        guard let payload, payload.count >= 22 else { return nil }
        let bytes = payload.dropFirst(2).prefix(20).prefix { $0 != 0 }
        return String(data: Data(bytes), encoding: .ascii)
    }
}

struct ProbeResult: Codable, Sendable {
    var model: String
    var firmware: String
    var operations: [String]
    var profileID: UInt16?
    var profileName: String?
    var selectionReportedWritable: Bool?
    var availableProfileCount: Int?
    var profilePayloadHex: String?
    var capabilityPayloadHex: String?
    var warnings: [String] = []
    var transport = "Wi-Fi PTP/IP"
    var writeTested = false
    var testedAt = Date()
    var slotBackups: [SlotBackup] = []
    var supportsRecipeWrite: Bool { operations.contains("0x90CD") }
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}


// A Swift actor alone does not serialize operations across await points.
// This FIFO lease covers each complete read, heartbeat, or connection lifecycle.
struct SelectionRecovery: Codable, Sendable, Equatable {
    var cameraIdentity: String
    var original: UInt16
    var temporary: UInt16
    var recordedAt = Date()
}

protocol SelectionRecoveryStore: Sendable {
    func load() throws -> SelectionRecovery?
    func save(_ recovery: SelectionRecovery) throws
    func clear() throws
}

struct FileSelectionRecoveryStore: SelectionRecoveryStore {
    let url: URL
    func load() throws -> SelectionRecovery? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SelectionRecovery.self, from: Data(contentsOf: url))
    }
    func save(_ recovery: SelectionRecovery) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recovery).write(to: url, options: .atomic)
        // Read back the checkpoint before permitting a write to the camera.
        guard try load() == recovery else { throw CameraError.invalid("恢复记录保存校验失败") }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct SelectionTestResult: Codable, Sendable {
    let original: UInt16
    let temporary: UInt16
    let observedTemporary: UInt16
    let restored: UInt16
    var recipeWriteTested = false
    var testedAt = Date()
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}

// Limited to basic STANDARD datasets without curves or automatic parameters.
// Parameter offsets are verified against a camera-imported NP3 test pattern.
struct C9RecipePayload {
    let bytes: Data
    init(_ bytes: Data) throws {
        guard bytes.count == 36, bytes.prefix(2) == Data([1, 0]),
              bytes[22] == 0, bytes[23] <= 1, bytes[24] == 0,
              bytes.suffix(4) == Data(repeating: 0, count: 4),
              StandardNP3Recipe.parameters.allSatisfy({ $0.quarters.contains(Int(Int8(bitPattern: bytes[$0.offset]))) }) else {
            throw CameraError.invalid("C9 不是已验证格式的基本标准配方，未执行写入")
        }
        let nameBytes = bytes.subdata(in: 2..<22)
        guard let zero = nameBytes.firstIndex(of: 0), zero > 0,
              nameBytes[..<zero].allSatisfy({ (32...126).contains($0) }),
              nameBytes[zero...].allSatisfy({ $0 == 0 }) else {
            throw CameraError.invalid("C9 测试配方名称格式不符")
        }
        self.bytes = bytes
    }
    var name: String { String(decoding: bytes.dropFirst(2).prefix(20).prefix { $0 != 0 }, as: UTF8.self) }
    func renamedForTest() throws -> Data {
        let name = self.name == "Z30LAB-TEST" ? "Z30LAB-CHECK" : "Z30LAB-TEST"
        var result = bytes
        var field = Data(name.utf8); field.append(Data(repeating: 0, count: 20 - field.count))
        result.replaceSubrange(2..<22, with: field)
        return result
    }
}

struct RecipeRecovery: Codable, Sendable, Equatable {
    let cameraIdentity: String
    let original: Data
    let temporary: Data
    let originalSelection: UInt16
}

struct FileRecipeRecoveryStore: Sendable {
    let url: URL
    func load() throws -> RecipeRecovery? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RecipeRecovery.self, from: Data(contentsOf: url))
    }
    func save(_ record: RecipeRecovery) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        guard try load() == record else { throw CameraError.invalid("C9 恢复记录保存校验失败") }
    }
    func clear() throws { try FileManager.default.removeItem(at: url) }
}

struct RecipeTestResult: Codable, Sendable {
    let originalName: String
    let temporaryName: String
    let restoredName: String
    let restoredBytesMatch: Bool
    let selectionRestored: UInt16
    var testedAt = Date()
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}

struct RecipeTransfer: Sendable {
    let slot: Int
    let np3: Data
}
struct RecipeTransferredItem: Codable, Sendable {
    let slot: Int
    let name: String
    let verifiedBytes: Int
    var cameraFlagNormalized = false
    var currentStateMatchesStored = true
}

struct RecipeReadback {
    let cameraFlagNormalized: Bool
    let currentStateMatchesStored: Bool
    init(expected: Data, basic: Data, extended: Data) throws {
        _ = try PictureControlWirePayload(expected)
        guard basic.count == expected.count, basic[23] <= 1,
              expected.indices.allSatisfy({ $0 == 23 || basic[$0] == expected[$0] }) else {
            throw CameraError.verification("保存的名称、基础风格、参数或完整曲线与目标不一致")
        }
        // A native camera SD export independently confirmed the complete
        // registered curve even when mode 1 returned a different 36-byte state.
        // Do not conflate that state with the stored recipe, or rewrite it.
        cameraFlagNormalized = basic[23] != expected[23]
        currentStateMatchesStored = extended == basic
    }
}
struct RecipeTransferResult: Codable, Sendable {
    let items: [RecipeTransferredItem]
    let activeSlot: Int
    var testedAt = Date()
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}

private actor SessionGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if !held { held = true; c.resume() }
                else { waiters.append((id, c)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }
    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

actor PTPIPSession {
    private let gate = SessionGate()
    private let heartbeatInterval: Duration
    private var command: PacketSocket?
    private var event: PacketSocket?
    private var info: DeviceInfo?
    private var host: String?
    private var port: UInt16?
    private var generation = UUID()
    private var nextTransaction: UInt32 = 2
    private var eventTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var outstandingProbe: ContinuousClock.Instant?
    private var log: @Sendable (String) async -> Void = { _ in }
    private var state: @Sendable (Bool) async -> Void = { _ in }

    init(heartbeatInterval: Duration = .seconds(10)) { self.heartbeatInterval = heartbeatInterval }
    deinit { command?.close(); event?.close(); eventTask?.cancel(); heartbeatTask?.cancel() }
    var connected: Bool { command != nil && event != nil && info != nil }

    func connect(host: String, port: UInt16 = 15740, guid: UUID, requireWiFi: Bool = true,
                 log: @escaping @Sendable (String) async -> Void,
                 state: @escaping @Sendable (Bool) async -> Void = { _ in }) async throws {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        self.log = log; self.state = state
        if connected, self.host == host, self.port == port { await log("复用已建立的相机会话"); await state(true); return }
        if command != nil { await closeCurrentSession() }
        let command = PacketSocket(host: host, port: port, requireWiFi: requireWiFi)
        let event = PacketSocket(host: host, port: port, requireWiFi: requireWiFi)
        self.command = command; self.event = event; self.host = host; self.port = port
        let id = UUID(); generation = id
        do {
            await log("连接相机 \(host):\(port)")
            try await command.open()
            var uuid = guid.uuid
            var payload = withUnsafeBytes(of: &uuid) { Data($0) }
            payload.append("Z30 Recipes\0".data(using: .utf16LittleEndian)!); payload.put32(0x00010000)
            try await command.write(PTPPacket(type: 1, payload: payload))
            let ack = try await command.read()
            if ack.type == 5 { throw CameraError.invalid("相机拒绝连接，请关闭 SnapBridge 后重试") }
            guard ack.type == 2, ack.payload.count >= 26 else { throw CameraError.invalid("命令通道握手不完整") }
            var reader = BinaryReader(data: ack.payload)
            var eventPayload = Data(); eventPayload.put32(try reader.u32())
            await log("命令通道已连接")
            try await event.open(); try await event.write(PTPPacket(type: 3, payload: eventPayload))
            let eventAck = try await event.read()
            guard eventAck.type == 4, eventAck.payload.isEmpty else { throw CameraError.invalid("事件通道握手失败") }
            await log("事件通道已连接")
            eventTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        // Idle is normal. Active probes, rather than idle receive timeouts, check liveness.
                        let packet = try await event.read(timeout: nil)
                        if packet.type == 13 { try await event.write(PTPPacket(type: 14, payload: Data())) }
                        else if packet.type == 14 { await self?.receivedPong(id) }
                        else if packet.type != 8 { throw CameraError.invalid("事件通道收到意外数据") }
                    }
                } catch { await self?.lost(id, error: error) }
            }
            _ = try await operation(command, code: 0x1002, id: 0, parameters: [1])
            await log("相机会话已打开")
            let info = try DeviceInfo(await operation(command, code: 0x1001, id: 1))
            guard info.manufacturer.localizedCaseInsensitiveContains("nikon"), info.model.replacingOccurrences(of: " ", with: "").uppercased() == "Z30" else {
                throw CameraError.invalid("当前相机是 \(info.model)，本程序仅针对 Nikon Z30")
            }
            guard generation == id else { throw CameraError.closed }
            self.info = info; nextTransaction = 2
            await log("识别到 \(info.model)，固件 \(info.firmware)")
            await state(true)
            let interval = heartbeatInterval
            heartbeatTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: interval)
                        try await self?.heartbeat(id)
                    }
                } catch {
                    if !Task.isCancelled { await self?.lost(id, error: error) }
                }
            }
        } catch { await lost(id, error: error); throw error }
    }

    func read(backupSlots: Bool = false) async throws -> ProbeResult {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard let command, let info else { throw CameraError.closed }
        let id = generation
        do {
        var result = ProbeResult(model: info.model, firmware: info.firmware,
                                 operations: info.operations.map { String(format: "0x%04X", $0) })
        var transaction = nextTransaction
        defer { nextTransaction = transaction }
        do {
            let rawDesc = try await operation(command, code: 0x1014, id: transaction, parameters: [0xD200]); transaction += 1
            let descriptor = try PictureControlDescriptor(rawDesc)
            result.selectionReportedWritable = descriptor.writable
            result.availableProfileCount = descriptor.choices.count
        } catch CameraError.response(let status) {
            transaction += 1; result.warnings.append(String(format: "无线模式未读到优化校准属性表（0x%04X）", status))
        }
        do {
            let rawValue = try await operation(command, code: 0x1015, id: transaction, parameters: [0xD200]); transaction += 1
            var valueReader = BinaryReader(data: rawValue)
            let profile = try valueReader.u16()
            result.profileID = profile
            await log("当前优化校准编号：\(profile)")
        } catch CameraError.response(let status) {
            transaction += 1; result.warnings.append(String(format: "无线模式未读到当前优化校准（0x%04X）", status))
        }
        if let profile = result.profileID {
            if info.operations.contains(0x90CF) {
                do {
                    let capability = try await operation(command, code: 0x90CF, id: transaction, parameters: [UInt32(profile)]); transaction += 1
                    result.capabilityPayloadHex = capability.hex(); await log("已读取优化校准能力：\(capability.count) 字节")
                } catch CameraError.response(let status) {
                    transaction += 1; result.warnings.append(String(format: "能力查询返回 0x%04X", status))
                }
            }
            if info.operations.contains(0x90CC) {
                do {
                    let profileData = try await operation(command, code: 0x90CC, id: transaction, parameters: [UInt32(profile), 0]); transaction += 1
                    result.profilePayloadHex = profileData.hex(limit: 4096)
                    if profileData.count >= 22 {
                        let nameBytes = profileData.dropFirst(2).prefix(20).prefix { $0 != 0 }
                        result.profileName = String(data: Data(nameBytes), encoding: .ascii)
                    }
                    await log("已读取优化校准数据：\(profileData.count) 字节")
                } catch CameraError.response(let status) {
                    transaction += 1; result.warnings.append(String(format: "优化校准读取返回 0x%04X", status))
                }
            }
        }
        if backupSlots {
            guard info.operations.contains(0x90CC) else { throw CameraError.invalid("相机未声明支持优化校准读取") }
            for slot in 1...9 {
                let code = UInt16(200 + slot)
                var backup = SlotBackup(slot: slot, pictureControlID: code)
                // Rejected reads do not establish whether a slot is empty.
                do {
                    backup.payload = try await operation(command, code: 0x90CC, id: transaction, parameters: [UInt32(code), 0]); transaction += 1
                    backup.response = 0x2001
                } catch CameraError.response(let status) { transaction += 1; backup.response = status }
                do {
                    backup.expandedPayload = try await operation(command, code: 0x90CC, id: transaction, parameters: [UInt32(code), 1]); transaction += 1
                    backup.expandedResponse = 0x2001
                } catch CameraError.response(let status) { transaction += 1; backup.expandedResponse = status }
                result.slotBackups.append(backup)
                if let payload = backup.payload {
                    await log("C\(slot)：已读取 \(payload.count) 字节，\(backup.name ?? "未识别名称")")
                } else {
                    await log(String(format: "C%d：读取返回 0x%04X，槽位状态待确认", slot, backup.response ?? 0))
                }
            }
        }

            guard generation == id else { throw CameraError.closed }
            await log("读取完成，连接保持开启")
            return result
        } catch { await lost(id, error: error); throw error }
    }

    func disconnect() async {
        do { try await gate.acquire() } catch { return }
        defer { Task { await gate.release() } }
        await closeCurrentSession()
    }

    func testSelection(store: any SelectionRecoveryStore) async throws -> SelectionTestResult {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard let command, let info, let identity = info.identityFingerprint else {
            throw CameraError.invalid("需要连接相机并取得身份后再验证切换")
        }
        guard info.operations.contains(0x1016) else { throw CameraError.invalid("当前连接未声明支持设置写入") }
        guard try store.load() == nil else { throw CameraError.invalid("有待恢复的设置，请先点恢复上次设置") }
        let id = generation
        let descriptor = try await selectionDescriptor(command)
        guard descriptor.writable else { throw CameraError.invalid("当前拍摄模式不允许修改优化校准") }
        let original = try await selectionValue(command)
        guard descriptor.choices.contains(original),
              let target = [UInt16(1), 2].first(where: { $0 != original && descriptor.choices.contains($0) }) else {
            throw CameraError.invalid("未找到适合验证的机内预设")
        }
        let recovery = SelectionRecovery(cameraIdentity: identity, original: original, temporary: target)
        try store.save(recovery)
        await log("已保存恢复记录：原编号 \(original)，临时编号 \(target)")
        do {
            try await setSelection(command, value: target)
            let observed = try await selectionValue(command)
            guard observed == target else { throw CameraError.invalid("切换后的读回值与目标不一致") }
            await log("切换读回成功：\(original) → \(observed)")
            // Once a mutation may have happened, rollback runs in a fresh task so
            // cancelling the UI task cannot cancel the restoration attempt.
            let restored = try await Task.detached { try await self.restoreLocked(recovery, store: store, generation: id) }.value
            return SelectionTestResult(original: original, temporary: target, observedTemporary: observed, restored: restored)
        } catch {
            let originalError = error
            if (try? store.load()) != nil {
                do { _ = try await Task.detached { try await self.restoreLocked(recovery, store: store, generation: id) }.value }
                catch {
                    await log("尚未确认恢复，请重新连接后点恢复上次设置；原编号 \(original)")
                    await lost(id, error: error)
                }
            }
            throw originalError
        }
    }

    func restorePendingSelection(store: any SelectionRecoveryStore) async throws -> UInt16 {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard let recovery = try store.load() else { throw CameraError.invalid("没有待恢复的设置") }
        return try await restoreLocked(recovery, store: store, generation: generation)
    }

    func testC9Recipe(store: FileRecipeRecoveryStore) async throws -> RecipeTestResult {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard let command, let info, let identity = info.identityFingerprint else { throw CameraError.closed }
        guard info.operations.contains(0x90CD), info.operations.contains(0x90CC) else {
            throw CameraError.invalid("相机未声明支持配方数据读写")
        }
        guard try store.load() == nil else { throw CameraError.invalid("请先恢复上次 C9 测试") }
        let id = generation
        let original = try C9RecipePayload(await c9Data(command, mode: 0))
        guard try await c9Data(command, mode: 1) == original.bytes else {
            throw CameraError.invalid("C9 两种读取结果不同，未执行写入")
        }
        let selection = try await selectionValue(command)
        let descriptor = try await selectionDescriptor(command)
        guard descriptor.writable, descriptor.choices.contains(selection) else {
            throw CameraError.invalid("请使用 P／S／A／M 拍摄模式后重试")
        }
        let temporary = try original.renamedForTest()
        let record = RecipeRecovery(cameraIdentity: identity, original: original.bytes,
                                    temporary: temporary, originalSelection: selection)
        try store.save(record)
        await log("C9 原始数据与恢复记录已保存：\(original.name)")
        do {
            try await writeC9Data(command, bytes: temporary)
            guard try await c9Data(command, mode: 0) == temporary,
                  try await c9Data(command, mode: 1) == temporary else {
                throw CameraError.invalid("C9 写入后的数据读回不一致")
            }
            await log("C9 临时名称已写入并读回确认")
            let restored = try await Task.detached { try await self.restoreC9Locked(record, store: store, generation: id) }.value
            return RecipeTestResult(originalName: original.name, temporaryName: try C9RecipePayload(temporary).name,
                                    restoredName: restored, restoredBytesMatch: true, selectionRestored: selection)
        } catch {
            let initialError = error
            if (try? store.load()) != nil {
                do { _ = try await Task.detached { try await self.restoreC9Locked(record, store: store, generation: id) }.value }
                catch {
                    await log("C9 恢复尚未确认，请重新连接后点恢复 C9 测试配方")
                    await lost(id, error: error)
                }
            }
            throw initialError
        }
    }

    func restorePendingC9(store: FileRecipeRecoveryStore) async throws -> String {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard let record = try store.load() else { throw CameraError.invalid("没有待恢复的 C9 测试") }
        return try await restoreC9Locked(record, store: store, generation: generation)
    }

    func transferRecipes(_ items: [RecipeTransfer], activeSlot: Int) async throws -> RecipeTransferResult {
        guard !items.isEmpty, items.count <= 9,
              Set(items.map(\.slot)).count == items.count,
              items.allSatisfy({ (1...9).contains($0.slot) }),
              items.contains(where: { $0.slot == activeSlot }) else {
            throw CameraError.invalid("请选择 1–9 个不同槽位，并从中选择要应用的配方")
        }
        // Validate the entire batch before touching any camera setting.
        var prepared = try items.map { item in
            let recipe = try PhoneRecipeDocument(item.np3)
            return (slot: item.slot, recipe: recipe, payload: try recipe.verifiedPayload())
        }
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard let command, let info else { throw CameraError.closed }
        guard [UInt16(0x90CD), 0x90CC, 0x1016].allSatisfy({ info.operations.contains($0) }) else {
            throw CameraError.invalid("相机未声明支持所需的配方读写与选择指令")
        }
        let id = generation
        let descriptor = try await selectionDescriptor(command)
        guard descriptor.writable, prepared.allSatisfy({ descriptor.choices.contains(UInt16(200 + $0.slot)) }) else {
            throw CameraError.invalid("当前拍摄模式不允许载入和应用所选槽位，请切到 P／S／A／M 档")
        }
        // A destination may be empty or contain a different dataset. Its old
        // shape is not a reason to block replacement. Read built-in style data
        // to retain the camera's own monochrome flags and unused fields.
        var nativeStyles: [UInt8: Data] = [:]
        for index in prepared.indices {
            let base = prepared[index].payload[0]
            if base != 2, nativeStyles[base] == nil {
                do {
                    let native = try await recipeData(command, profile: UInt16(base), mode: 0)
                    if native.count >= 36 { nativeStyles[base] = native }
                    await log("机内基底 \(base)（\(native.count) 字节）：\(native.hex(limit: 4096))")
                } catch CameraError.response(let code) {
                    await log(String(format: "机内基底读取返回 0x%04X，继续发送文件参数", code))
                }
            }
            if let native = nativeStyles[base] {
                prepared[index].payload[1] = native[1]
                if base == 4 {
                    for offset in [30,31,34] where prepared[index].payload[offset] == 127 {
                        prepared[index].payload[offset] = native[offset]
                    }
                }
            }
        }
        var completed: [RecipeTransferredItem] = []
        do {
            for item in prepared {
                try Task.checkCancellation()
                let profile = UInt16(200 + item.slot)
                await log("C\(item.slot) 发送 \(item.recipe.name)（\(item.payload.count) 字节）：\(item.payload.hex(limit: 4096))")
                try await sendRecipeData(command, profile: profile, bytes: item.payload)
                await log("C\(item.slot) 相机已接受写入（0x2001），开始读回核对")
                let basic = try await recipeData(command, profile: profile, mode: 0)
                let extended = try await recipeData(command, profile: profile, mode: 1)
                if basic != item.payload {
                    await log("C\(item.slot) 目标：\(item.payload.hex(limit: 4096))")
                    await log("C\(item.slot) 读回 0：\(basic.hex(limit: 4096))")
                    await log("C\(item.slot) 读回 1：\(extended.hex(limit: 4096))")
                }
                let verification = try RecipeReadback(expected: item.payload, basic: basic, extended: extended)
                completed.append(RecipeTransferredItem(slot: item.slot, name: item.recipe.name,
                    verifiedBytes: item.payload.count - (verification.cameraFlagNormalized ? 1 : 0), cameraFlagNormalized: verification.cameraFlagNormalized, currentStateMatchesStored: verification.currentStateMatchesStored))
                await log("C\(item.slot)：\(item.recipe.name)，保存的名称、参数与完整曲线核对通过\(verification.cameraFlagNormalized ? "；相机返回了另一种已观测状态标记" : "")")
            }
            let active = UInt16(200 + activeSlot)
            try await setSelection(command, value: active)
            guard try await selectionValue(command) == active else { throw CameraError.verification("应用后的选择读回失败") }
            await log("已应用 C\(activeSlot)，保持相机连接")
            return RecipeTransferResult(items: completed, activeSlot: activeSlot)
        } catch {
            let confirmed = completed.map { "C\($0.slot)" }.joined(separator: "、")
            await log("同步未完成；已确认的槽位：\(confirmed.isEmpty ? "无" : confirmed)。未自动回退，重新连接后可重试。")
            switch error {
            case CameraError.response, CameraError.verification: break
            default: await lost(id, error: error)
            }
            throw CameraError.invalid("同步未完成，部分槽位可能已更新。已读回确认：\(confirmed.isEmpty ? "无" : confirmed)。\(error.localizedDescription)")
        }
    }

    func inspectSlot(_ slot: Int) async throws {
        guard (1...9).contains(slot) else { throw CameraError.invalid("槽位超出范围") }
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard let command else { throw CameraError.closed }
        let profile = UInt16(200 + slot)
        let basic = try await recipeData(command, profile: profile, mode: 0)
        let extended = try await recipeData(command, profile: profile, mode: 1)
        await log("C\(slot) 当前数据 0（\(basic.count) 字节）：\(basic.hex(limit: 4096))")
        await log("C\(slot) 当前数据 1（\(extended.count) 字节）：\(extended.hex(limit: 4096))")
    }

    private func restoreC9Locked(_ record: RecipeRecovery, store: FileRecipeRecoveryStore, generation id: UUID) async throws -> String {
        guard generation == id, let command, info?.identityFingerprint == record.cameraIdentity else {
            throw CameraError.invalid("C9 恢复记录与当前相机不匹配")
        }
        let original = try C9RecipePayload(record.original)
        guard try original.renamedForTest() == record.temporary else { throw CameraError.invalid("C9 恢复记录内容不符") }
        let current = try await c9Data(command, mode: 0)
        guard current == record.original || current == record.temporary else {
            throw CameraError.invalid("C9 出现测试之外的改动，请保留恢复记录并检查相机")
        }
        if current != record.original { try await writeC9Data(command, bytes: record.original) }
        guard try await c9Data(command, mode: 0) == record.original,
              try await c9Data(command, mode: 1) == record.original else {
            throw CameraError.invalid("C9 原始数据恢复读回失败")
        }
        let selection = try await selectionValue(command)
        if selection == 209, selection != record.originalSelection {
            let descriptor = try await selectionDescriptor(command)
            guard descriptor.writable, descriptor.choices.contains(record.originalSelection) else {
                throw CameraError.invalid("C9 已恢复，但当前模式无法恢复原选择")
            }
            try await setSelection(command, value: record.originalSelection)
        }
        guard try await selectionValue(command) == record.originalSelection else {
            throw CameraError.invalid("C9 已恢复，但优化校准选择发生了其他变化")
        }
        try store.clear()
        await log("C9 原名与全部 36 字节已恢复并读回确认；原选择保持不变")
        return original.name
    }

    private func c9Data(_ socket: PacketSocket, mode: UInt32) async throws -> Data {
        try await recipeData(socket, profile: 209, mode: mode)
    }
    private func recipeData(_ socket: PacketSocket, profile: UInt16, mode: UInt32) async throws -> Data {
        guard (1...8).contains(profile) || (201...209).contains(profile), mode <= 1 else { throw CameraError.invalid("配方槽位或读取模式不符") }
        let id = nextTransaction; nextTransaction &+= 1
        return try await operation(socket, code: 0x90CC, id: id, parameters: [UInt32(profile), mode])
    }
    private func writeC9Data(_ socket: PacketSocket, bytes: Data) async throws {
        try await writeRecipeData(socket, profile: 209, bytes: bytes)
    }
    private func writeRecipeData(_ socket: PacketSocket, profile: UInt16, bytes: Data) async throws {
        guard (201...209).contains(profile) else { throw CameraError.invalid("只允许 C1–C9 自定义槽位") }
        _ = try C9RecipePayload(bytes)
        try await sendRecipeData(socket, profile: profile, bytes: bytes)
    }
    private func sendRecipeData(_ socket: PacketSocket, profile: UInt16, bytes: Data) async throws {
        guard (201...209).contains(profile), bytes.count == 36 || bytes.count == 614 else {
            throw CameraError.invalid("配方写入槽位或长度超出已限定范围")
        }
        try Task.checkCancellation()
        let id = nextTransaction; nextTransaction &+= 1
        try await socket.write(.operation(0x90CD, transaction: id, parameters: [UInt32(profile), 0], dataPhase: 2))
        var start = Data(); start.put32(id); start.put64(UInt64(bytes.count))
        var end = Data(); end.put32(id); end.append(bytes)
        try await socket.write(PTPPacket(type: 9, payload: start))
        try await socket.write(PTPPacket(type: 12, payload: end))
        let response = try await socket.read()
        guard response.type == 7 else { socket.close(); throw CameraError.invalid("配方写入未收到有效响应") }
        var transaction = PTPDataTransaction(id: id)
        _ = try transaction.consume(response)
    }

    private func restoreLocked(_ recovery: SelectionRecovery, store: any SelectionRecoveryStore, generation id: UUID) async throws -> UInt16 {
        guard generation == id, let command, info?.identityFingerprint == recovery.cameraIdentity else {
            throw CameraError.invalid("恢复记录与当前相机不匹配，未执行恢复")
        }
        let descriptor = try await selectionDescriptor(command)
        guard descriptor.writable, descriptor.choices.contains(recovery.original) else {
            throw CameraError.invalid("当前模式无法恢复原优化校准，请调整拍摄模式后重试")
        }
        let current = try await selectionValue(command)
        if current != recovery.original { try await setSelection(command, value: recovery.original) }
        let restored = try await selectionValue(command)
        guard restored == recovery.original else { throw CameraError.invalid("原设置恢复读回失败") }
        try store.clear()
        await log("原设置已恢复并读回确认：\(restored)")
        return restored
    }

    private func selectionDescriptor(_ socket: PacketSocket) async throws -> PictureControlDescriptor {
        let id = nextTransaction; nextTransaction &+= 1
        return try PictureControlDescriptor(await operation(socket, code: 0x1014, id: id, parameters: [0xD200]))
    }
    private func selectionValue(_ socket: PacketSocket) async throws -> UInt16 {
        let id = nextTransaction; nextTransaction &+= 1
        let data = try await operation(socket, code: 0x1015, id: id, parameters: [0xD200])
        guard data.count == 2 else { throw CameraError.invalid("优化校准选择值长度不符") }
        var reader = BinaryReader(data: data); return try reader.u16()
    }
    private func setSelection(_ socket: PacketSocket, value: UInt16) async throws {
        guard (1...8).contains(value) || (101...120).contains(value) || (201...209).contains(value) else {
            throw CameraError.invalid("优化校准编号无效")
        }
        try Task.checkCancellation()
        let id = nextTransaction; nextTransaction &+= 1
        // The only allowed setting write is UInt16 to Nikon photo selection D200.
        // This does not modify custom Picture Control data (90CD is never sent).
        try await socket.write(.operation(0x1016, transaction: id, parameters: [0xD200], dataPhase: 2))
        var start = Data(); start.put32(id); start.put64(2)
        var end = Data(); end.put32(id); end.put16(value)
        try await socket.write(PTPPacket(type: 9, payload: start))
        try await socket.write(PTPPacket(type: 12, payload: end))
        let response = try await socket.read()
        guard response.type == 7 else { socket.close(); throw CameraError.invalid("设置写入未收到有效响应") }
        var transaction = PTPDataTransaction(id: id)
        _ = try transaction.consume(response)
    }

    private func closeCurrentSession() async {
        // Retire event/heartbeat ownership before intentional teardown.
        generation = UUID()
        heartbeatTask?.cancel(); heartbeatTask = nil
        if let command, info != nil {
            _ = try? await operation(command, code: 0x1003, id: nextTransaction)
        }
        invalidate()
        await state(false); await log("已主动断开相机")
    }
    private func invalidate() {
        generation = UUID()
        eventTask?.cancel(); eventTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        command?.close(); event?.close()
        command = nil; event = nil; info = nil; host = nil; port = nil; outstandingProbe = nil
    }
    private func lost(_ id: UUID, error: Error) async {
        guard generation == id else { return }
        invalidate(); await state(false)
        await log("连接已中断：\(error.localizedDescription)")
    }
    private func receivedPong(_ id: UUID) {
        if generation == id { outstandingProbe = nil }
    }
    private func heartbeat(_ id: UUID) async throws {
        try await gate.acquire()
        defer { Task { await gate.release() } }
        guard generation == id, let command, let event, let info else { return }
        if let sent = outstandingProbe {
            if sent.duration(to: .now) > .seconds(25) { throw CameraError.timeout }
        } else {
            outstandingProbe = .now
            try await event.write(PTPPacket(type: 13, payload: Data()))
        }
        if info.operations.contains(0x90C8) {
            let transaction = nextTransaction; nextTransaction &+= 1
            do { _ = try await operation(command, code: 0x90C8, id: transaction) }
            catch CameraError.response(let code) where code == 0x2019 { /* camera busy still proves connectivity */ }
        }
    }
    private func operation(_ socket: PacketSocket, code: UInt16, id: UInt32,
                                  parameters: [UInt32] = []) async throws -> Data {
        // Only session lifecycle, read queries, and Nikon readiness checks are allowed.
        guard [UInt16(0x1002), 0x1003, 0x1001, 0x1014, 0x1015, 0x90CF, 0x90CC, 0x90C8].contains(code) else {
            throw CameraError.invalid("此版本没有写入功能")
        }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        try await socket.write(.operation(code, transaction: id, parameters: parameters))
        var parser = PTPDataTransaction(id: id)
        for _ in 0..<4096 {
            guard ContinuousClock.now < deadline else { socket.close(); throw CameraError.timeout }
            let packet = try await socket.read()
            if let data = try parser.consume(packet) { return data }
        }
        socket.close(); throw CameraError.invalid("数据分段过多")
    }
}

// One-shot entry point retained for protocol tests and command-line callers.
// The iOS app uses PTPIPSession directly and keeps the foreground session alive.
enum PTPIPProbe {
    static func run(host: String, port: UInt16 = 15740, guid: UUID,
                    requireWiFi: Bool = true, backupSlots: Bool = false,
                    log: @escaping @Sendable (String) async -> Void) async throws -> ProbeResult {
        let session = PTPIPSession()
        do {
            try await session.connect(host: host, port: port, guid: guid, requireWiFi: requireWiFi, log: log)
            let result = try await session.read(backupSlots: backupSlots)
            await session.disconnect()
            return result
        } catch { await session.disconnect(); throw error }
    }
}
