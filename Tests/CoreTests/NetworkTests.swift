import XCTest
import Network
@testable import Z30LabCore

private final class MockCamera: @unchecked Sendable {
    let listener: NWListener
    let ready = XCTestExpectation(description: "Mock camera listening")
    let gotInfo = XCTestExpectation(description: "GetDeviceInfo received")
    let repliedToProbe = XCTestExpectation(description: "Event probe response")
    let heartbeatSeen = XCTestExpectation(description: "Foreground heartbeat")
    private let queue = DispatchQueue(label: "Z30Lab.tests.camera")
    private var channels: [Channel] = []
    let omitProperties: Bool
    let hang: Bool
    let rejectSelection: Bool
    let dropSelectionResponse: Bool
    let rejectRecipe: Bool
    let dropRecipeResponse: Bool
    private var droppedRecipeResponse = false
    private var c9Payload: Data?
    private var otherPayloads: [UInt16: Data] = [:]
    private var recipeWrites: [(slot: UInt16, bytes: Data)] = []
    let rejectRecipeAt: Int?
    let allSlots: Bool
    let extendedSlot: UInt16?
    let normalizeFlag: UInt8?
    let corruptParameter: Bool
    let currentStateDiffers: Bool
    let stripCurve: Bool
    let corruptCurve: Bool
    func allRecipeWrites() -> [(slot: UInt16, bytes: Data)] { queue.sync { recipeWrites } }
    private var c9Attempts: [Data] = []
    func recipeSnapshot() -> (value: Data?, attempts: [Data]) { queue.sync { (c9Payload, c9Attempts) } }
    private var droppedSelectionResponse = false
    private var currentSelection: UInt16 = 8
    private var selectionAttempts: [UInt16] = []
    func selectionSnapshot() -> (value: UInt16, attempts: [UInt16]) {
        queue.sync { (currentSelection, selectionAttempts) }
    }
    private var channelCount = 0
    private var openCount = 0
    private var closeCount = 0
    private var heartbeatCount = 0
    private var transactionIDs: [UInt32] = []
    func snapshot() -> (channels: Int, opens: Int, closes: Int, heartbeats: Int, ids: [UInt32]) {
        queue.sync { (channelCount, openCount, closeCount, heartbeatCount, transactionIDs) }
    }
    init(omitProperties: Bool = false, hang: Bool = false, rejectSelection: Bool = false, dropSelectionResponse: Bool = false,
         enableC9: Bool = false, rejectRecipe: Bool = false, dropRecipeResponse: Bool = false, rejectRecipeAt: Int? = nil,
         allSlots: Bool = false, extendedSlot: UInt16? = nil, normalizeFlag: UInt8? = nil, corruptParameter: Bool = false,
         currentStateDiffers: Bool = false, stripCurve: Bool = false, corruptCurve: Bool = false, curvedDestination: Bool = false) throws {
        self.omitProperties = omitProperties; self.hang = hang
        self.rejectSelection = rejectSelection; self.dropSelectionResponse = dropSelectionResponse
        self.rejectRecipe = rejectRecipe; self.dropRecipeResponse = dropRecipeResponse
        self.rejectRecipeAt = rejectRecipeAt
        self.allSlots = allSlots; self.extendedSlot = extendedSlot
        self.normalizeFlag = normalizeFlag; self.corruptParameter = corruptParameter
        self.currentStateDiffers = currentStateDiffers; self.stripCurve = stripCurve; self.corruptCurve = corruptCurve
        if enableC9 || curvedDestination { c9Payload = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: curvedDestination ? "neutral-payload" : "standard", withExtension: "bin"))) }
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.channelCount += 1
            let channel = Channel(connection: connection, camera: self)
            self.channels.append(channel); channel.start(on: self.queue)
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.sync { listener.cancel(); channels.forEach { $0.connection.cancel() }; channels.removeAll() }
    }
    private final class Channel {
        let connection: NWConnection
        unowned let camera: MockCamera
        var framer = PacketFramer()
        var pendingWrite: UInt32?
        var pendingWriteCode: UInt16?
        var pendingProfile: UInt16?
        var pendingByteCount: UInt64 = 0
        var receivedWriteStart = false
        init(connection: NWConnection, camera: MockCamera) { self.connection = connection; self.camera = camera }
        func start(on queue: DispatchQueue) { connection.start(queue: queue); receive() }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data {
                    do { for packet in try self.framer.append(data) { try self.handle(packet) } }
                    catch { XCTFail("Mock protocol failure: \(error)") }
                }
                if !complete && error == nil { self.receive() }
            }
        }
        func send(_ packets: [PTPPacket]) {
            let data = packets.reduce(into: Data()) { $0.append($1.encoded) }
            // Real TCP can split a header or combine several protocol packets.
            for start in stride(from: 0, to: data.count, by: 7) {
                connection.send(content: data.subdata(in: start..<min(start + 7, data.count)), completion: .contentProcessed { _ in })
            }
        }
        func handle(_ packet: PTPPacket) throws {
            switch packet.type {
            case 1:
                XCTAssertEqual(packet.payload.suffix(4), Data([0, 0, 1, 0]))
                var ack = Data(); ack.put32(42); ack.append(Data(repeating: 0, count: 16))
                ack.append("Z 30\0".data(using: .utf16LittleEndian)!); ack.put32(0x00010000)
                send([PTPPacket(type: 2, payload: ack)])
            case 3:
                XCTAssertEqual(packet.payload, Data([42, 0, 0, 0]))
                send([PTPPacket(type: 4, payload: Data()), PTPPacket(type: 13, payload: Data())])
            case 14: camera.repliedToProbe.fulfill()
            case 13: send([PTPPacket(type: 14, payload: Data())])
            case 9:
                var r = BinaryReader(data: packet.payload)
                XCTAssertEqual(try r.u32(), pendingWrite)
                pendingByteCount = try r.u64()
                XCTAssertTrue(pendingWriteCode == 0x90CD ? [36,614].contains(pendingByteCount) : pendingByteCount == 2)
                XCTAssertEqual(r.offset, packet.payload.count)
                receivedWriteStart = true
            case 12:
                var r = BinaryReader(data: packet.payload)
                let tid = try r.u32()
                XCTAssertEqual(tid, pendingWrite); XCTAssertTrue(receivedWriteStart)
                if pendingWriteCode == 0x90CD {
                    let bytes = Data(packet.payload.dropFirst(4)); XCTAssertEqual(UInt64(bytes.count), pendingByteCount)
                    let profile = try XCTUnwrap(pendingProfile)
                    if profile == 209 { camera.c9Attempts.append(bytes) }
                    camera.recipeWrites.append((profile, bytes))
                    let rejected = camera.rejectRecipe || camera.recipeWrites.count == camera.rejectRecipeAt
                    if !rejected {
                        var stored = bytes
                        if let flag = camera.normalizeFlag { stored[23] = flag }
                        if camera.corruptParameter { stored[25] &+= 1 }
                        if camera.stripCurve { stored = Data(stored.prefix(36)) }
                        if camera.corruptCurve && stored.count > 36 { stored[stored.count - 1] ^= 1 }
                        if profile == 209 { camera.c9Payload = stored }
                        else { camera.otherPayloads[profile] = stored }
                    }
                    pendingWrite = nil; pendingWriteCode = nil; receivedWriteStart = false
                    if camera.dropRecipeResponse, !camera.droppedRecipeResponse {
                        camera.droppedRecipeResponse = true; connection.cancel(); return
                    }
                    var response = Data(); response.put16(rejected ? 0x200F : 0x2001); response.put32(tid)
                    send([PTPPacket(type: 7, payload: response)]); return
                }
                let value = try r.u16(); XCTAssertEqual(r.offset, packet.payload.count)
                camera.selectionAttempts.append(value)
                let status: UInt16 = camera.rejectSelection ? 0x200F : 0x2001
                if !camera.rejectSelection { camera.currentSelection = value }
                pendingWrite = nil; pendingWriteCode = nil; receivedWriteStart = false
                if camera.dropSelectionResponse, !camera.droppedSelectionResponse {
                    camera.droppedSelectionResponse = true; connection.cancel(); return
                }
                var response = Data(); response.put16(status); response.put32(tid)
                send([PTPPacket(type: 7, payload: response)])
            case 6:
                var r = BinaryReader(data: packet.payload)
                let phase = try r.u32()
                let op = try r.u16(), tid = try r.u32()
                XCTAssertTrue([0x1002, 0x1003, 0x1001, 0x1014, 0x1015, 0x1016, 0x90CD, 0x90CF, 0x90CC, 0x90C8].contains(op))
                camera.transactionIDs.append(tid)
                if op == 0x90CD {
                    XCTAssertEqual(phase, 2)
                    let profile = try r.u32(); XCTAssertTrue((201...209).contains(profile)); pendingProfile = UInt16(profile)
                    XCTAssertEqual(try r.u32(), 0)
                    XCTAssertEqual(r.offset, packet.payload.count)
                    pendingWrite = tid; pendingWriteCode = op; return
                }
                if op == 0x1016 {
                    XCTAssertEqual(phase, 2); XCTAssertEqual(try r.u32(), 0xD200)
                    XCTAssertEqual(r.offset, packet.payload.count)
                    pendingWrite = tid; pendingWriteCode = op; return
                }
                XCTAssertEqual(phase, 1)
                var payload: Data?
                var status: UInt16 = 0x2001
                switch op {
                case 0x1002:
                    camera.openCount += 1
                    XCTAssertEqual(tid, 0); XCTAssertEqual(try r.u32(), 1)
                case 0x1003: camera.closeCount += 1
                case 0x90C8:
                    camera.heartbeatCount += 1
                    if camera.heartbeatCount == 1 { camera.heartbeatSeen.fulfill() }
                case 0x1001:
                    camera.gotInfo.fulfill()
                    if camera.hang { return }
                    payload = try fixture("deviceinfo")
                case 0x1014:
                    XCTAssertEqual(try r.u32(), 0xD200)
                    if camera.omitProperties { status = 0x200A }
                    else {
                        var data = try fixture("photo-control-desc")
                        var value = Data(); value.put16(camera.currentSelection)
                        data.replaceSubrange(7..<9, with: value); payload = data
                    }
                case 0x1015:
                    XCTAssertEqual(try r.u32(), 0xD200)
                    if camera.omitProperties { status = 0x200A }
                    else { var data = Data(); data.put16(camera.currentSelection); payload = data }
                case 0x90CF: XCTAssertEqual(try r.u32(), 8); payload = Data(repeating: 0x80, count: 28)
                case 0x90CC:
                    let profile = try r.u32(), mode = try r.u32()
                    if (1...6).contains(profile) {
                        var native = try fixture("standard")
                        native[0] = UInt8(profile); native[1] = profile == 4 ? 1 : 0
                        if profile == 4 { native[30] = 7; native[31] = 9; native[34] = 11 }
                        payload = native
                    }
                    else if let written = camera.otherPayloads[UInt16(profile)] { XCTAssertTrue(mode <= 1); payload = written }
                    else if profile == 209, let c9 = camera.c9Payload { XCTAssertTrue(mode <= 1); payload = c9 }
                    else if camera.allSlots, (201...209).contains(profile) {
                        payload = Data(repeating: 0, count: camera.extendedSlot == UInt16(profile) && mode == 1 ? 37 : 36)
                    }
                    else if profile == 8 { XCTAssertEqual(mode, 0); payload = try fixture("current-picture-control") }
                    else {
                        XCTAssertTrue((201...209).contains(profile))
                        if profile == 201 && mode == 0 {
                            var data = Data(); data.put16(201)
                            data.append("MY PRESET".data(using: .ascii)!); data.append(Data(repeating: 0, count: 11))
                            data.append(Data(repeating: 0x80, count: 14)); payload = data
                        } else { status = 0x201D }
                    }
                default: XCTFail("Unexpected operation")
                }
                if op == 0x90CC, camera.currentStateDiffers, packet.payload.suffix(4) == Data([1,0,0,0]), let data = payload, data.count == 614 {
                    var current = Data(data.prefix(36)); current[35] = 0; payload = current
                }
                var packets: [PTPPacket] = []
                if let payload {
                    var start = Data(); start.put32(tid); start.put64(UInt64(payload.count))
                    var first = Data(); first.put32(tid); first.append(payload.prefix(payload.count / 2))
                    var last = Data(); last.put32(tid); last.append(payload.dropFirst(payload.count / 2))
                    packets = [PTPPacket(type: 9, payload: start), PTPPacket(type: 10, payload: first), PTPPacket(type: 12, payload: last)]
                }
                var response = Data(); response.put16(status); response.put32(tid)
                packets.append(PTPPacket(type: 7, payload: response)); send(packets)
            default: XCTFail("Unexpected packet \(packet.type)")
            }
        }
        func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin")))
        }
    }
}

private final class TestRecoveryStore: SelectionRecoveryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: SelectionRecovery?
    let failSave: Bool
    init(record: SelectionRecovery? = nil, failSave: Bool = false) { self.record = record; self.failSave = failSave }
    func load() throws -> SelectionRecovery? { lock.lock(); defer { lock.unlock() }; return record }
    func save(_ recovery: SelectionRecovery) throws {
        if failSave { throw CameraError.invalid("Simulated disk failure") }
        lock.lock(); defer { lock.unlock() }; record = recovery
    }
    func clear() throws { lock.lock(); defer { lock.unlock() }; record = nil }
}

final class NetworkTests: XCTestCase {
    private func mappingNP3() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "parameter-map", withExtension: "NP3")))
    }
    private func open(_ server: MockCamera) async throws -> PTPIPSession {
        await fulfillment(of: [server.ready], timeout: 3)
        let session = PTPIPSession()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        return session
    }
    func testAllNineSlotsTransferAndChosenSlotIsApplied() async throws {
        let server = try MockCamera(allSlots: true); defer { server.stop() }
        let session = try await open(server), source = try mappingNP3()
        let result = try await session.transferRecipes((1...9).map { RecipeTransfer(slot: $0, np3: source) }, activeSlot: 5)
        XCTAssertEqual(result.items.map(\.slot), Array(1...9)); XCTAssertEqual(result.activeSlot, 5)
        XCTAssertEqual(server.allRecipeWrites().map(\.slot), Array(UInt16(201)...UInt16(209)))
        XCTAssertEqual(server.selectionSnapshot().value, 205)
        XCTAssertEqual(server.selectionSnapshot().attempts, [205])
        XCTAssertTrue(server.allRecipeWrites().allSatisfy { $0.bytes == (try? StandardNP3Recipe(source).payload) })
        await session.disconnect()
    }
    private func curveNCP() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "neutral-curve", withExtension: "NCP")))
    }
    func testUnencodableNCPStopsWholeBatchBeforeAnyWrite() async throws {
        let server = try MockCamera(allSlots: true); defer { server.stop() }
        let session = try await open(server)
        var source = try curveNCP(); source[36] = 0x12; source[37] = 0x34
        do {
            _ = try await session.transferRecipes([.init(slot:1,np3:mappingNP3()),.init(slot:2,np3:source)],activeSlot:1)
            XCTFail("Unsupported NCP base must fail preflight")
        } catch { XCTAssertTrue(error.localizedDescription.contains("NCP")) }
        XCTAssertTrue(server.allRecipeWrites().isEmpty); XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty)
        await session.disconnect()
    }
    func testMixedCurveBatchWritesCompleteDatasetsAndAppliesChosenSlot() async throws {
        let server = try MockCamera(allSlots: true, currentStateDiffers: true); defer { server.stop() }
        let session = try await open(server), curve = try curveNCP()
        let result = try await session.transferRecipes([.init(slot: 2, np3: mappingNP3()), .init(slot: 8, np3: curve)], activeSlot: 8)
        XCTAssertEqual(server.allRecipeWrites().map(\.slot), [202,208])
        XCTAssertEqual(server.allRecipeWrites()[1].bytes, try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "neutral-payload", withExtension: "bin"))))
        XCTAssertEqual(result.items[1].verifiedBytes,614); XCTAssertFalse(result.items[1].currentStateMatchesStored)
        XCTAssertEqual(server.selectionSnapshot().value,208)
        await session.disconnect()
    }
    func testReplacingKnownCurvedDestinationWithCurveOrBasicRecipe() async throws {
        for source in [try curveNCP(), try mappingNP3()] {
            let server = try MockCamera(allSlots: true, currentStateDiffers: true, curvedDestination: true)
            let session = try await open(server)
            _ = try await session.transferRecipes([.init(slot:9,np3:source)],activeSlot:9)
            XCTAssertEqual(server.allRecipeWrites().count,1)
            XCTAssertEqual(server.selectionSnapshot().value,209)
            await session.disconnect(); server.stop()
        }
    }
    func testMissingOrCorruptedStoredCurveDoesNotApplyAndKeepsConnection() async throws {
        for strip in [true,false] {
            let server = try MockCamera(allSlots: true, stripCurve: strip, corruptCurve: !strip)
            let session = try await open(server)
            do { _ = try await session.transferRecipes([.init(slot:9,np3:curveNCP())],activeSlot:9); XCTFail("Must reject corrupted stored curve") } catch { }
            XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty)
            XCTAssertEqual(server.allRecipeWrites().count,1)
            let connected = await session.connected; XCTAssertTrue(connected)
            await session.disconnect(); server.stop()
        }
    }
    func testKnownCameraFlagNormalizationStillVerifiesEveryParameter() async throws {
        let server = try MockCamera(allSlots: true, normalizeFlag: 1); defer { server.stop() }
        let session = try await open(server)
        let result = try await session.transferRecipes([.init(slot: 2, np3: mappingNP3())], activeSlot: 2)
        XCTAssertTrue(result.items[0].cameraFlagNormalized); XCTAssertEqual(result.items[0].verifiedBytes, 35)
        XCTAssertEqual(server.selectionSnapshot().value, 202)
        let connected = await session.connected; XCTAssertTrue(connected)
        await session.disconnect()
    }
    func testParameterMismatchDoesNotCloseCameraSessionOrApplySlot() async throws {
        let server = try MockCamera(allSlots: true, corruptParameter: true); defer { server.stop() }
        let session = try await open(server)
        do { _ = try await session.transferRecipes([.init(slot: 2, np3: mappingNP3())], activeSlot: 2); XCTFail("Expected mismatch") } catch { }
        let connected = await session.connected; XCTAssertTrue(connected)
        XCTAssertEqual(server.snapshot().closes, 0); XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty)
        await session.disconnect()
    }
    func testDestinationOldShapeDoesNotBlockReplacement() async throws {
        let server = try MockCamera(allSlots: true, extendedSlot: 203); defer { server.stop() }
        let session = try await open(server), source = try mappingNP3()
        _ = try await session.transferRecipes([.init(slot: 1, np3: source), .init(slot: 3, np3: source)], activeSlot: 1)
        XCTAssertEqual(server.allRecipeWrites().map(\.slot), [201,203]); await session.disconnect()
    }
    func testMonochromeUsesCameraNativeFlagsAndSendsFullOriginalCurve() async throws {
        let server = try MockCamera(allSlots: true); defer { server.stop() }
        let session = try await open(server)
        let source = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "mono-curve", withExtension: "NCP")))
        let result = try await session.transferRecipes([.init(slot:6,np3:source)],activeSlot:6)
        let sent = try XCTUnwrap(server.allRecipeWrites().first?.bytes)
        XCTAssertEqual(sent[0],4); XCTAssertEqual(sent[1],1)
        XCTAssertEqual(sent[30],7); XCTAssertEqual(sent[31],9); XCTAssertEqual(sent[34],11)
        XCTAssertEqual(sent.suffix(578),try NP3Document(source).records[2])
        XCTAssertEqual(result.items[0].verifiedBytes,614); XCTAssertEqual(result.activeSlot,6)
        await session.disconnect()
    }
    func testSparseBatchOnlyTouchesChosenSlots() async throws {
        let server = try MockCamera(allSlots: true); defer { server.stop() }
        let session = try await open(server), source = try mappingNP3()
        _ = try await session.transferRecipes([.init(slot: 3, np3: source), .init(slot: 7, np3: source)], activeSlot: 7)
        XCTAssertEqual(server.allRecipeWrites().map(\.slot), [203,207])
        XCTAssertEqual(server.selectionSnapshot().value, 207); await session.disconnect()
    }
    func testBatchValidatesAllFilesAndTargetsBeforeWriting() async throws {
        let server = try MockCamera(allSlots: true); defer { server.stop() }
        let session = try await open(server), source = try mappingNP3()
        let invalidBatches: [([RecipeTransfer], Int)] = [
            ([.init(slot: 1, np3: source), .init(slot: 2, np3: Data([0]))], 1),
            ([.init(slot: 0, np3: source)], 0), ([.init(slot: 10, np3: source)], 10),
            ([.init(slot: 1, np3: source), .init(slot: 1, np3: source)], 1),
            ([.init(slot: 1, np3: source)], 9), ([], 1)
        ]
        for (items, active) in invalidBatches {
            do { _ = try await session.transferRecipes(items, activeSlot: active); XCTFail("Expected validation failure") } catch { }
        }
        XCTAssertTrue(server.allRecipeWrites().isEmpty); XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty)
        await session.disconnect()
    }
    func testPartialBatchReportsConfirmedSlotsAndDoesNotWriteRemainingSlots() async throws {
        let server = try MockCamera(rejectRecipeAt: 2, allSlots: true); defer { server.stop() }
        let session = try await open(server), source = try mappingNP3()
        do {
            _ = try await session.transferRecipes((1...3).map { .init(slot: $0, np3: source) }, activeSlot: 3)
            XCTFail("Expected second write rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("C1")); XCTAssertTrue(error.localizedDescription.contains("部分槽位可能已更新")) }
        XCTAssertEqual(server.allRecipeWrites().map(\.slot), [201,202])
        XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty); XCTAssertEqual(server.selectionSnapshot().value, 8)
        await session.disconnect()
    }
    func testLostRecipeResponseCanBeRetriedIdempotentlyWithoutRollbackOrBackup() async throws {
        let server = try MockCamera(dropRecipeResponse: true, allSlots: true); defer { server.stop() }
        let session = try await open(server), source = try mappingNP3()
        do { _ = try await session.transferRecipes([.init(slot: 4, np3: source)], activeSlot: 4); XCTFail("Expected lost response") } catch { }
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        let result = try await session.transferRecipes([.init(slot: 4, np3: source)], activeSlot: 4)
        XCTAssertEqual(result.activeSlot, 4); XCTAssertEqual(server.allRecipeWrites().map(\.slot), [204,204])
        XCTAssertEqual(server.selectionSnapshot().value, 204); await session.disconnect()
    }
    func testApplicationFailureRetainsWrittenRecipeAndReportsIncomplete() async throws {
        let server = try MockCamera(rejectSelection: true, allSlots: true); defer { server.stop() }
        let session = try await open(server), source = try mappingNP3()
        do { _ = try await session.transferRecipes([.init(slot: 9, np3: source)], activeSlot: 9); XCTFail("Expected apply rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("C9")) }
        XCTAssertEqual(server.recipeSnapshot().value, try StandardNP3Recipe(source).payload)
        XCTAssertEqual(server.allRecipeWrites().count, 1); XCTAssertEqual(server.selectionSnapshot().value, 8)
        await session.disconnect()
    }
    func testC9RecipeWriteAndExactRestoration() async throws {
        let server = try MockCamera(enableC9: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileRecipeRecoveryStore(url: folder.appendingPathComponent("record.json"))
        let original = server.recipeSnapshot().value
        let session = PTPIPSession()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        let result = try await session.testC9Recipe(store: store)
        XCTAssertEqual(result.originalName, "STANDARD-02"); XCTAssertEqual(result.temporaryName, "Z30LAB-TEST")
        XCTAssertEqual(result.restoredName, result.originalName); XCTAssertTrue(result.restoredBytesMatch)
        XCTAssertEqual(server.recipeSnapshot().value, original)
        XCTAssertEqual(server.recipeSnapshot().attempts.count, 2)
        XCTAssertEqual(server.recipeSnapshot().attempts.last, original)
        XCTAssertEqual(server.selectionSnapshot().value, 8); XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty)
        XCTAssertNil(try store.load()); await session.disconnect()
    }
    func testRejectedC9WriteConfirmsOriginalWithoutSecondWrite() async throws {
        let server = try MockCamera(enableC9: true, rejectRecipe: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileRecipeRecoveryStore(url: folder.appendingPathComponent("record.json"))
        let original = server.recipeSnapshot().value
        let session = PTPIPSession()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        do { _ = try await session.testC9Recipe(store: store); XCTFail("Expected rejection") }
        catch CameraError.response(let code) { XCTAssertEqual(code, 0x200F) }
        XCTAssertEqual(server.recipeSnapshot().value, original); XCTAssertEqual(server.recipeSnapshot().attempts.count, 1)
        XCTAssertNil(try store.load()); await session.disconnect()
    }
    func testC9LostWriteResponsePersistsRecoveryAcrossStoreRecreation() async throws {
        let server = try MockCamera(enableC9: true, dropRecipeResponse: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("record.json"), guid = UUID()
        let store = FileRecipeRecoveryStore(url: url), session = PTPIPSession()
        let original = server.recipeSnapshot().value, port = try XCTUnwrap(server.listener.port).rawValue
        try await session.connect(host: "127.0.0.1", port: port, guid: guid, requireWiFi: false) { _ in }
        do { _ = try await session.testC9Recipe(store: store); XCTFail("Expected disconnect") } catch { }
        XCTAssertNotEqual(server.recipeSnapshot().value, original); XCTAssertNotNil(try store.load())
        try await session.connect(host: "127.0.0.1", port: port, guid: guid, requireWiFi: false) { _ in }
        let reopened = FileRecipeRecoveryStore(url: url)
        let name = try await session.restorePendingC9(store: reopened)
        XCTAssertEqual(name, "STANDARD-02"); XCTAssertEqual(server.recipeSnapshot().value, original)
        XCTAssertNil(try reopened.load()); await session.disconnect()
    }
    func testC9CheckpointFailurePreventsWrite() async throws {
        let server = try MockCamera(enableC9: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: blocker); defer { try? FileManager.default.removeItem(at: blocker) }
        let store = FileRecipeRecoveryStore(url: blocker.appendingPathComponent("record.json"))
        let session = PTPIPSession()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        do { _ = try await session.testC9Recipe(store: store); XCTFail("Expected disk failure") } catch { }
        XCTAssertTrue(server.recipeSnapshot().attempts.isEmpty); await session.disconnect()
    }
    func testC9RecoveryRejectsWrongCameraAndKeepsCheckpoint() async throws {
        let server = try MockCamera(enableC9: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileRecipeRecoveryStore(url: folder.appendingPathComponent("record.json"))
        let original = try XCTUnwrap(server.recipeSnapshot().value)
        try store.save(RecipeRecovery(cameraIdentity: "other-camera", original: original,
                                      temporary: C9RecipePayload(original).renamedForTest(), originalSelection: 8))
        let session = PTPIPSession()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        do { _ = try await session.restorePendingC9(store: store); XCTFail("Expected identity mismatch") } catch { }
        XCTAssertTrue(server.recipeSnapshot().attempts.isEmpty); XCTAssertNotNil(try store.load())
        await session.disconnect()
    }
    func testSelectionChangesAndRestoresWithReadback() async throws {
        let server = try MockCamera(); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = PTPIPSession(), store = TestRecoveryStore()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        let report = try await session.testSelection(store: store)
        XCTAssertEqual(report.original, 8); XCTAssertEqual(report.observedTemporary, 1); XCTAssertEqual(report.restored, 8)
        XCTAssertEqual(server.selectionSnapshot().attempts, [1, 8]); XCTAssertEqual(server.selectionSnapshot().value, 8)
        XCTAssertNil(try store.load()); XCTAssertFalse(report.recipeWriteTested)
        await session.disconnect()
    }
    func testCheckpointMustSaveBeforeAnySelectionWrite() async throws {
        let server = try MockCamera(); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = PTPIPSession(), store = TestRecoveryStore(failSave: true)
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        do { _ = try await session.testSelection(store: store); XCTFail("Expected save failure") } catch { }
        XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty); XCTAssertEqual(server.selectionSnapshot().value, 8)
        await session.disconnect()
    }
    func testRejectedSelectionVerifiesOriginalAndClearsCheckpoint() async throws {
        let server = try MockCamera(rejectSelection: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = PTPIPSession(), store = TestRecoveryStore()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        do { _ = try await session.testSelection(store: store); XCTFail("Expected camera rejection") } catch { }
        XCTAssertEqual(server.selectionSnapshot().value, 8); XCTAssertEqual(server.selectionSnapshot().attempts, [1])
        XCTAssertNil(try store.load())
        await session.disconnect()
    }
    func testLostWriteResponseLeavesCheckpointAndCanRecoverAfterReconnect() async throws {
        let server = try MockCamera(dropSelectionResponse: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = PTPIPSession(), store = TestRecoveryStore(), guid = UUID()
        let port = try XCTUnwrap(server.listener.port).rawValue
        try await session.connect(host: "127.0.0.1", port: port, guid: guid, requireWiFi: false) { _ in }
        do { _ = try await session.testSelection(store: store); XCTFail("Expected transport failure") } catch { }
        XCTAssertEqual(server.selectionSnapshot().value, 1)
        XCTAssertEqual(try store.load()?.original, 8)
        try await session.connect(host: "127.0.0.1", port: port, guid: guid, requireWiFi: false) { _ in }
        let restored = try await session.restorePendingSelection(store: store)
        XCTAssertEqual(restored, 8); XCTAssertNil(try store.load()); XCTAssertEqual(server.selectionSnapshot().value, 8)
        await session.disconnect()
    }
    func testRecoveryCannotWriteToAnotherCameraIdentity() async throws {
        let server = try MockCamera(); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = PTPIPSession()
        let store = TestRecoveryStore(record: SelectionRecovery(cameraIdentity: "different-camera", original: 8, temporary: 1))
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        do { _ = try await session.restorePendingSelection(store: store); XCTFail("Expected identity mismatch") } catch { }
        XCTAssertTrue(server.selectionSnapshot().attempts.isEmpty); XCTAssertNotNil(try store.load())
        await session.disconnect()
    }
    func testSessionRemainsOpenAndHeartbeatsUntilExplicitDisconnect() async throws {
        let server = try MockCamera(); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let session = PTPIPSession(heartbeatInterval: .milliseconds(40))
        let guid = UUID()
        try await session.connect(host: "127.0.0.1", port: port, guid: guid, requireWiFi: false) { _ in }
        _ = try await session.read()
        let connected = await session.connected
        XCTAssertTrue(connected); XCTAssertEqual(server.snapshot().closes, 0)
        await fulfillment(of: [server.heartbeatSeen], timeout: 3)
        // Reconnecting to the same endpoint must reuse both existing TCP channels.
        try await session.connect(host: "127.0.0.1", port: port, guid: guid, requireWiFi: false) { _ in }
        _ = try await session.read(backupSlots: true)
        XCTAssertEqual(server.snapshot().channels, 2); XCTAssertEqual(server.snapshot().opens, 1)
        XCTAssertEqual(server.snapshot().closes, 0)
        await session.disconnect()
        let disconnected = await session.connected
        XCTAssertFalse(disconnected); XCTAssertEqual(server.snapshot().closes, 1)
        let ids = server.snapshot().ids
        XCTAssertEqual(ids, Array(UInt32(0)..<UInt32(ids.count)))
    }
    func testConcurrentReadsDoNotInterleaveTransactions() async throws {
        let server = try MockCamera(); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let session = PTPIPSession()
        try await session.connect(host: "127.0.0.1", port: XCTUnwrap(server.listener.port).rawValue,
                                  guid: UUID(), requireWiFi: false) { _ in }
        async let first = session.read(backupSlots: true)
        async let second = session.read()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.slotBackups.count, 9); XCTAssertEqual(b.profileName, "AUTO")
        await session.disconnect()
        let ids = server.snapshot().ids
        XCTAssertEqual(ids, Array(UInt32(0)..<UInt32(ids.count)))
    }
    func testBackupPreservesExactBytesAndFailedSlotResponses() async throws {
        let server = try MockCamera(); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let result = try await PTPIPProbe.run(host: "127.0.0.1", port: port, guid: UUID(), requireWiFi: false, backupSlots: true) { _ in }
        XCTAssertEqual(result.slotBackups.count, 9)
        let first = try XCTUnwrap(result.slotBackups.first)
        XCTAssertEqual(first.pictureControlID, 201); XCTAssertEqual(first.response, 0x2001)
        XCTAssertEqual(first.name, "MY PRESET"); XCTAssertEqual(first.payload?.count, 36)
        XCTAssertNil(first.expandedPayload); XCTAssertEqual(first.expandedResponse, 0x201D)
        for slot in result.slotBackups.dropFirst() {
            XCTAssertNil(slot.payload); XCTAssertEqual(slot.response, 0x201D)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ProbeResult.self, from: Data(result.json.utf8))
        XCTAssertEqual(restored.slotBackups.first?.payload, first.payload)
        XCTAssertFalse(result.writeTested)
    }
    func testFullProbeOverFragmentedTCPAndEventChannel() async throws {
        let server = try MockCamera(); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let result = try await PTPIPProbe.run(host: "127.0.0.1", port: port, guid: UUID(), requireWiFi: false) { _ in }
        XCTAssertEqual(result.model, "Z 30"); XCTAssertEqual(result.profileName, "AUTO")
        XCTAssertEqual(result.availableProfileCount, 37); XCTAssertTrue(result.supportsRecipeWrite)
        XCTAssertFalse(result.writeTested); XCTAssertTrue(result.warnings.isEmpty)
        await fulfillment(of: [server.repliedToProbe], timeout: 3)
    }
    func testUnsupportedWirelessPropertiesReturnPartialReport() async throws {
        let server = try MockCamera(omitProperties: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let result = try await PTPIPProbe.run(host: "127.0.0.1", port: port, guid: UUID(), requireWiFi: false) { _ in }
        XCTAssertNil(result.profileID); XCTAssertEqual(result.warnings.count, 2)
        XCTAssertEqual(result.model, "Z 30")
    }
    func testCancelClosesPendingReceive() async throws {
        let server = try MockCamera(hang: true); defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let task = Task {
            try await PTPIPProbe.run(host: "127.0.0.1", port: port, guid: UUID(), requireWiFi: false) { _ in }
        }
        await fulfillment(of: [server.gotInfo], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled probe unexpectedly completed") }
        catch { /* cancellation must retire both sockets */ }
    }
}
