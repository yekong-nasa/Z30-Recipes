import XCTest
@testable import Z30LabCore

final class CodecTests: XCTestCase {
    func testBatchImportKeepsBothFilesAndSkipsDuplicatesWithinAndAcrossBatches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try XCTUnwrap(Bundle.module.url(forResource: "neutral-curve", withExtension: "NCP"))
        let second = try XCTUnwrap(Bundle.module.url(forResource: "mono-curve", withExtension: "NCP"))
        let originals = try [Data(contentsOf:first),Data(contentsOf:second)]
        let result = try RecipeLibraryImporter.importFiles([first,second,first], into: folder)
        XCTAssertEqual(result.importedIDs.count,2); XCTAssertEqual(result.duplicateIDs.count,1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try result.importedIDs.map { try Data(contentsOf:folder.appendingPathComponent($0)) },originals)
        let repeated = try RecipeLibraryImporter.importFiles([second,first],into:folder)
        XCTAssertTrue(repeated.importedIDs.isEmpty); XCTAssertEqual(repeated.duplicateIDs.count,2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path).count,2)
        XCTAssertEqual(try Data(contentsOf:first), originals[0])
    }
    func testBatchImportReportsBadFileAndStillImportsFollowingValidFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let bad = root.appendingPathComponent("broken.NCP"); try Data([1,2,3]).write(to:bad)
        let valid = try XCTUnwrap(Bundle.module.url(forResource:"standard",withExtension:"NP3"))
        let result = try RecipeLibraryImporter.importFiles([bad,valid],into:root.appendingPathComponent("Library"))
        XCTAssertEqual(result.importedIDs.count,1); XCTAssertEqual(result.failures.count,1)
        XCTAssertTrue(result.failures[0].contains("broken.NCP"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("Library").appendingPathComponent(result.importedIDs[0])),try Data(contentsOf:valid))
    }
    private func userNCP() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "neutral-curve", withExtension: "NCP")))
    }
    func testZeroStateFlagRetainsSourceAndCurve() throws {
        let source = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "neutral-state-zero", withExtension: "NCP")))
        let recipe = try ClassicNCPRecipe(source)
        XCTAssertEqual(recipe.name, "FIXTURE-COLOR"); XCTAssertEqual(recipe.settings[26], 0)
        XCTAssertEqual(recipe.original, source); XCTAssertNil(recipe.transferIssue)
        let payload = try recipe.wirePayload()
        XCTAssertEqual(payload.count, 614); XCTAssertEqual(payload[25], 8)
        XCTAssertEqual(payload.suffix(578), source.subdata(in: 56..<634))
        XCTAssertEqual(recipe.curve?[8], 6)
        var fullControl = source; fullControl[38] = 2
        XCTAssertEqual(try PhoneRecipeDocument(fullControl).verifiedPayload(), payload)
        var invalid = source; invalid[38] = 255
        XCTAssertThrowsError(try ClassicNCPRecipe(invalid))
    }
    func testSyntheticNCPRetainsCurvePointsAndEveryLUTEntry() throws {
        let source = try userNCP(), recipe = try ClassicNCPRecipe(source)
        XCTAssertEqual(recipe.original, source)
        XCTAssertEqual(recipe.name, "NEUTRAL-TEST"); XCTAssertEqual(recipe.base, 0x03C2)
        let curve = try XCTUnwrap(recipe.curve)
        XCTAssertEqual(curve.count, 578); XCTAssertEqual(curve[8], 3)
        XCTAssertEqual(Array(curve[9..<15]), [0,0,82,82,255,255])
        XCTAssertEqual(curve.suffix(514), source.subdata(in: 120..<634))
        XCTAssertEqual(curve[64], 0); XCTAssertEqual(curve[65], 0)
        let document = try PhoneRecipeDocument(source)
        XCTAssertEqual(document.fileExtension, "NCP")
        XCTAssertNil(document.transferIssue)
        XCTAssertEqual(try document.verifiedPayload(), try fixture("neutral-payload"))
        XCTAssertThrowsError(try StandardNP3Recipe(source))
    }
    func testNCPRejectsTruncationsMissingCurveInvalidPointsAndOutOfRangeLUT() throws {
        let source = try userNCP()
        for count in 0..<source.count { XCTAssertThrowsError(try ClassicNCPRecipe(Data(source.prefix(count)))) }
        let original = try NP3Document(source).records
        for (offset, value): (Int, UInt8) in [(8, 29), (11, 0), (64, 128), (66, 128)] {
            var records = original; records[2]![offset] = value
            XCTAssertThrowsError(try ClassicNCPRecipe(encodedNP3(records)))
        }
        var records = original; records[2] = nil
        XCTAssertThrowsError(try ClassicNCPRecipe(encodedNP3(records)))
        records = original; records[1]![29] = 128
        XCTAssertThrowsError(try ClassicNCPRecipe(encodedNP3(records)))
        records = original; records[3] = Data([0])
        XCTAssertThrowsError(try ClassicNCPRecipe(encodedNP3(records)))
    }
    func testNCPAndNP3FixturesProduceIdenticalCompleteDataset() throws {
        let ncp = try PhoneRecipeDocument(userNCP()).verifiedPayload()
        let exported = try PhoneRecipeDocument(np3("neutral-export")).verifiedPayload()
        XCTAssertEqual(ncp, exported); XCTAssertEqual(ncp, try fixture("neutral-payload"))
        for index in ncp.indices where index != 23 {
            var wrong = ncp; wrong[index] ^= 1
            XCTAssertThrowsError(try RecipeReadback(expected: ncp, basic: wrong, extended: wrong))
        }
    }
    func testNeutralNCPManualParametersPreserveCurveAndRejectAutomaticValues() throws {
        var records = try NP3Document(userNCP()).records
        records[1]![28] = 132; records[1]![31] = 125; records[1]![32] = 131
        let recipe = try PhoneRecipeDocument(encodedNP3(records)), payload = try recipe.verifiedPayload()
        XCTAssertEqual(payload[25],16); XCTAssertEqual(payload[30],244); XCTAssertEqual(payload[31],12)
        XCTAssertEqual(payload.suffix(578), try ClassicNCPRecipe(userNCP()).curve)
        records[1]![28] = 0
        XCTAssertNil(try PhoneRecipeDocument(encodedNP3(records)).transferIssue)
        XCTAssertEqual(try PhoneRecipeDocument(encodedNP3(records)).verifiedPayload()[25], 128)
    }
    func testMonochromeNCPIsNotBlockedByTheNeutralWhitelist() throws {
        let source = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "mono-curve", withExtension: "NCP")))
        let recipe = try PhoneRecipeDocument(source), payload = try recipe.verifiedPayload()
        XCTAssertEqual(recipe.name, "FIXTURE-MONO"); XCTAssertNil(recipe.transferIssue)
        XCTAssertEqual(payload[0], 4); XCTAssertEqual(payload.count, 614)
        XCTAssertEqual(payload[25], 12); XCTAssertEqual(payload[32], 0); XCTAssertEqual(payload[33], 0)
        XCTAssertEqual(payload.suffix(578), try NP3Document(source).records[2])
        _ = try RecipeReadback(expected: payload, basic: payload, extended: payload)
    }
    func testAllSixTraditionalNCPBasesCanProduceWirelessData() throws {
        let color = try NP3Document(userNCP()).records
        for (base, wire) in ClassicNCPRecipe.wireBaseIDs {
            var records = color
            records[1]![24] = UInt8(base >> 8); records[1]![25] = UInt8(truncatingIfNeeded: base)
            if wire == 4 {
                records[1]![31] = 255; records[1]![32] = 255
                records[1]![33] = 128; records[1]![34] = 128; records[1]![35] = 255
            }
            let document = try PhoneRecipeDocument(encodedNP3(records))
            XCTAssertNil(document.transferIssue)
            XCTAssertEqual(try document.verifiedPayload()[0], wire)
            XCTAssertEqual(try document.verifiedPayload().suffix(578), color[2])
        }
    }
    func testNeutralNP3RejectsMissingCurveAndSupportsLUTOnlyWithoutRangeCrash() throws {
        var records = try NP3Document(np3("neutral-export")).records
        records[2] = nil
        XCTAssertThrowsError(try NeutralNP3Recipe(encodedNP3(records)))
        records = try NP3Document(np3("neutral-export")).records
        records[2]![8] = 0
        for i in 9..<64 { records[2]![i] = 0 }
        XCTAssertEqual(try NeutralNP3Recipe(encodedNP3(records)).payload.count, 614)
        records[2]![64] = 128
        XCTAssertThrowsError(try NeutralNP3Recipe(encodedNP3(records)))
    }
    func testFlexibleColorCloudFileHasExplicitCompatibilityError() throws {
        var records = try NP3Document(np3("standard")).records
        records[0x100] = Data("0310".utf8); records[0x300] = Data([0,32])
        do { _ = try PhoneRecipeDocument(encodedNP3(records)); XCTFail("Flexible Color must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("灵活色彩")) }
    }
    func testReadbackAllowsOnlyTheTwoObservedFlagsAndNoOtherByteChanges() throws {
        let source = try StandardNP3Recipe(np3("standard")).payload
        var observed = source; observed[23] = 1
        XCTAssertTrue(try RecipeReadback(expected: source, basic: observed, extended: observed).cameraFlagNormalized)
        for index in source.indices where index != 23 {
            var wrong = observed; wrong[index] ^= 1
            XCTAssertThrowsError(try RecipeReadback(expected: source, basic: wrong, extended: wrong))
        }
        observed[23] = 2
        XCTAssertThrowsError(try RecipeReadback(expected: source, basic: observed, extended: observed))
    }
    func testDifferentCurrentStateDoesNotInvalidateStoredRecipe() throws {
        let source = try StandardNP3Recipe(np3("standard")).payload
        var other = source; other[23] = 1
        XCTAssertFalse(try RecipeReadback(expected: source, basic: source, extended: other).currentStateMatchesStored)
    }
    private func np3(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "NP3")))
    }
    private func encodedNP3(_ records: [UInt32: Data]) -> Data {
        var result = Data([78, 67, 80, 0])
        for (tag, bytes) in records.sorted(by: { $0.key < $1.key }) {
            result.put32(tag.bigEndian); result.put32(UInt32(bytes.count).bigEndian); result.append(bytes)
        }
        result.put32(0); return result
    }
    func testNP3ConversionMatchesCameraImportedPatternIncludingSignedAndQuarterValues() throws {
        let recipe = try StandardNP3Recipe(np3("parameter-map"))
        XCTAssertEqual(recipe.name, "Z30LAB-MAP")
        XCTAssertEqual(recipe.payload, try fixture("parameter-map"))
        _ = try C9RecipePayload(recipe.payload)
        XCTAssertEqual(recipe.payload[30], 252); XCTAssertEqual(recipe.payload[31], 1)
    }
    func testCameraExportedStandardNP3MatchesBodyDataExceptLoaderFlag() throws {
        let recipe = try StandardNP3Recipe(np3("standard"))
        var bodyData = try fixture("standard")
        XCTAssertEqual(bodyData[23], 1); bodyData[23] = 0
        XCTAssertEqual(recipe.name, "STANDARD-02"); XCTAssertEqual(recipe.payload, bodyData)
    }
    func testNP3AllTruncationsDuplicateRecordsAndTrailingDataAreRejected() throws {
        let source = try np3("standard")
        for length in 0..<source.count { XCTAssertThrowsError(try NP3Document(Data(source.prefix(length)))) }
        var duplicate = Data(source.dropLast(4)); duplicate.append(source.subdata(in: 4..<16)); duplicate.put32(0)
        XCTAssertThrowsError(try NP3Document(duplicate))
        var trailing = source; trailing.append(0); XCTAssertThrowsError(try NP3Document(trailing))
    }
    func testNP3RejectsUnsupportedFormatsParametersAndCurves() throws {
        let original = try NP3Document(np3("standard")).records
        for (tag, value): (UInt32, Data) in [
            (0x100, Data("0310".utf8)), (0x300, Data([3,194])), (2, Data(repeating: 0, count: 578)),
            (0x600, Data([0,4])), (0x800, Data([1,4])), (0x900, Data([255,4])),
            (0x1600, Data([149,4])), (0x1400, Data([255,1]))
        ] {
            var records = original; records[tag] = value
            XCTAssertThrowsError(try StandardNP3Recipe(encodedNP3(records)))
        }
        var records = original; records[0x200] = Data(repeating: 65, count: 20)
        XCTAssertThrowsError(try StandardNP3Recipe(encodedNP3(records)))
    }
    func testC9NameChangePreservesAllOtherBytesAndRejectsUnknownLayouts() throws {
        let original = try fixture("standard")
        let payload = try C9RecipePayload(original)
        XCTAssertEqual(payload.name, "STANDARD-02")
        let changed = try payload.renamedForTest()
        XCTAssertEqual(try C9RecipePayload(changed).name, "Z30LAB-TEST")
        XCTAssertEqual(changed.prefix(2), original.prefix(2)); XCTAssertEqual(changed.suffix(14), original.suffix(14))
        for index in [0, 22, 24, 35] {
            var invalid = original; invalid[index] ^= 1
            XCTAssertThrowsError(try C9RecipePayload(invalid))
        }
        XCTAssertThrowsError(try C9RecipePayload(original.dropLast()))
        var unterminated = original; unterminated.replaceSubrange(2..<22, with: Data(repeating: 65, count: 20))
        XCTAssertThrowsError(try C9RecipePayload(unterminated))
    }
    func testRecoveryRecordSurvivesStoreRecreation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Recovery/selection.json")
        let record = SelectionRecovery(cameraIdentity: "fixture-identity", original: 8, temporary: 1)
        try FileSelectionRecoveryStore(url: url).save(record)
        let reopened = FileSelectionRecoveryStore(url: url)
        XCTAssertEqual(try reopened.load(), record)
        try reopened.clear(); XCTAssertNil(try reopened.load())
    }
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin")))
    }
    func testDeviceInfoParsing() throws {
        let info = try DeviceInfo(fixture("deviceinfo"))
        XCTAssertEqual(info.model, "Z 30"); XCTAssertEqual(info.firmware, "V1.20")
        XCTAssertTrue(info.operations.contains(0x90CD)); XCTAssertTrue(info.operations.contains(0x90CC))
    }
    func testPropertyDescriptorParsing() throws {
        let desc = try PictureControlDescriptor(fixture("photo-control-desc"))
        XCTAssertTrue(desc.writable); XCTAssertEqual(desc.current, 8); XCTAssertEqual(desc.choices.count, 37)
        XCTAssertEqual(desc.choices.suffix(9), Array(UInt16(201)...UInt16(209))[...])
    }
    func testTruncatedDataRejected() throws {
        let raw = try fixture("deviceinfo")
        for count in [0, 2, 20, raw.count - 1] { XCTAssertThrowsError(try DeviceInfo(raw.prefix(count))) }
        XCTAssertThrowsError(try PictureControlDescriptor(Data([0, 0])))
    }
    func testFragmentedAndCoalescedFrames() throws {
        let packets = [PTPPacket(type: 2, payload: Data(repeating: 4, count: 53)), PTPPacket(type: 4, payload: Data())]
        let wire = packets.reduce(into: Data()) { $0.append($1.encoded) }
        var framer = PacketFramer(), received: [PTPPacket] = []
        for byte in wire { received += try framer.append(Data([byte])) }
        XCTAssertEqual(received.map(\.type), [2, 4]); XCTAssertEqual(received.first?.payload.count, 53)
        var other = PacketFramer()
        XCTAssertEqual(try other.append(wire).count, 2)
    }
    func testInvalidFrameLengthRejected() {
        for length: UInt32 in [0, 7, UInt32.max] {
            var wire = Data(); wire.put32(length); wire.put32(9)
            var framer = PacketFramer(); XCTAssertThrowsError(try framer.append(wire))
        }
    }
    func testMultipartDataAndUnknownLength() throws {
        for length: UInt64 in [5, UInt64.max] {
            var t = PTPDataTransaction(id: 12)
            var start = Data(); start.put32(12); start.put64(length)
            XCTAssertNil(try t.consume(PTPPacket(type: 9, payload: start)))
            var a = Data(); a.put32(12); a.append(Data([1, 2]))
            var b = Data(); b.put32(12); b.append(Data([3, 4, 5]))
            XCTAssertNil(try t.consume(PTPPacket(type: 10, payload: a)))
            XCTAssertNil(try t.consume(PTPPacket(type: 12, payload: b)))
            var response = Data(); response.put16(0x2001); response.put32(12)
            XCTAssertEqual(try t.consume(PTPPacket(type: 7, payload: response)), Data([1, 2, 3, 4, 5]))
        }
    }
    func testTransactionMismatchAndMissingEndRejected() throws {
        var t = PTPDataTransaction(id: 5)
        var response = Data(); response.put16(0x2001); response.put32(6)
        XCTAssertThrowsError(try t.consume(PTPPacket(type: 7, payload: response)))
        var start = Data(); start.put32(5); start.put64(2)
        _ = try t.consume(PTPPacket(type: 9, payload: start))
        var finish = Data(); finish.put16(0x2001); finish.put32(5)
        XCTAssertThrowsError(try t.consume(PTPPacket(type: 7, payload: finish)))
    }
    func testDeclaredDataLengthEnforced() throws {
        var t = PTPDataTransaction(id: 7)
        var start = Data(); start.put32(7); start.put64(3)
        _ = try t.consume(PTPPacket(type: 9, payload: start))
        var end = Data(); end.put32(7); end.append(1)
        XCTAssertThrowsError(try t.consume(PTPPacket(type: 12, payload: end)))
    }
}
