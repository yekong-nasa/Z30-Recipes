import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers

@main
struct Z30LabApp: App {
    var body: some Scene { WindowGroup { RecipeLibraryView() } }
}

@MainActor
private final class BackgroundTransferLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "TransferPictureControls") { [weak self] in self?.end() }
    }
    func end() {
        guard identifier != .invalid else { return }
        let old = identifier; identifier = .invalid
        UIApplication.shared.endBackgroundTask(old)
    }
}

struct PhoneRecipe: Identifiable {
    let id: String
    let url: URL
    let name: String
    let summary: String
    let transferIssue: String?
}

@MainActor
final class RecipeLibraryModel: ObservableObject {
    @Published var recipes: [PhoneRecipe] = []
    @Published var selectedID: String?
    @Published var running = false
    @Published var connected = false
    @Published var critical = false
    @Published var error: String?
    @Published var report: RecipeTransferResult?
    @Published var currentProfile: String?
    @Published var logs: [String] = []
    @Published var legacyRecovery = false
    @Published var importNotice: String?
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let session = PTPIPSession()
    private var task: Task<Void, Never>?
    private var folder: URL { documents.appendingPathComponent("Recipes", isDirectory: true) }
    private var selectionStore: FileSelectionRecoveryStore { .init(url: documents.appendingPathComponent("Recovery/selection.json")) }
    private var recipeStore: FileRecipeRecoveryStore { .init(url: documents.appendingPathComponent("Recovery/c9.json")) }
    var selected: PhoneRecipe? { recipes.first { $0.id == selectedID } }
    init() { reloadLibrary(); refreshRecovery() }
    private func refreshRecovery() {
        do { legacyRecovery = try selectionStore.load() != nil || recipeStore.load() != nil }
        catch { legacyRecovery = true; self.error = "上次测试恢复记录无法读取：\(error.localizedDescription)" }
    }
    func reloadLibrary() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            recipes = files.filter { ["np3", "ncp"].contains($0.pathExtension.lowercased()) }.compactMap { url in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
                      let data = try? Data(contentsOf: url), let recipe = try? PhoneRecipeDocument(data) else { return nil }
                return PhoneRecipe(id: url.lastPathComponent, url: url, name: recipe.name, summary: recipe.summary, transferIssue: recipe.transferIssue)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !recipes.contains(where: { $0.id == selectedID }) { selectedID = recipes.first?.id }
        } catch { self.error = "手机配方库读取失败：\(error.localizedDescription)" }
    }
    func importFiles(_ urls: [URL]) {
        guard !running, !urls.isEmpty else { return }
        do {
            let result = try RecipeLibraryImporter.importFiles(urls, into: folder)
            reloadLibrary()
            if let selection = result.importedIDs.first ?? result.duplicateIDs.first { selectedID = selection }
            importNotice = result.summary; report = nil
            error = result.failures.isEmpty ? nil : result.failures.joined(separator: "\n")
        } catch { self.error = error.localizedDescription }
    }
    func deleteRecipe(_ recipe: PhoneRecipe) {
        guard !running, let stored = recipes.first(where: { $0.id == recipe.id }) else { return }
        do {
            try FileManager.default.removeItem(at: stored.url)
            reloadLibrary()
            error = nil; report = nil
        } catch { self.error = "手机配方删除失败：\(error.localizedDescription)" }
    }
    func transfer(host: String, assignments: [Int: String], activeSlot: Int) {
        guard !running else { return }
        do {
            let items = try assignments.sorted { $0.key < $1.key }.map { slot, id in
                guard let recipe = recipes.first(where: { $0.id == id }) else { throw CameraError.invalid("所选手机配方已不存在") }
                let data = try Data(contentsOf: recipe.url)
                _ = try PhoneRecipeDocument(data).verifiedPayload()
                return RecipeTransfer(slot: slot, np3: data)
            }
            run(host: host, critical: true) {
                guard try self.selectionStore.load() == nil, try self.recipeStore.load() == nil else {
                    throw CameraError.invalid("有未完成的旧操作，请先在连接设置中恢复")
                }
                let report = try await self.session.transferRecipes(items, activeSlot: activeSlot)
                self.report = report
                self.currentProfile = "C\(report.activeSlot) · \(report.items.first { $0.slot == report.activeSlot }?.name ?? "")"
                do { try Data(report.json.utf8).write(to: self.documents.appendingPathComponent("LatestTransfer.json"), options: .atomic) }
                catch { self.append("相机载入已确认，手机报告保存失败：\(error.localizedDescription)") }
            }
        } catch { self.error = error.localizedDescription }
    }
    func read(host: String) {
        run(host: host, critical: false) {
            let result = try await self.session.read()
            self.currentProfile = result.profileName ?? result.profileID.map { "编号 \($0)" }
            let slot = UserDefaults.standard.integer(forKey: "targetSlot")
            if (1...9).contains(slot) { try await self.session.inspectSlot(slot) }
        }
    }
    func recoverLegacy(host: String) {
        run(host: host, critical: true) {
            if try self.recipeStore.load() != nil { _ = try await self.session.restorePendingC9(store: self.recipeStore) }
            if try self.selectionStore.load() != nil { _ = try await self.session.restorePendingSelection(store: self.selectionStore) }
            self.refreshRecovery()
        }
    }
    private func run(host: String, critical: Bool, action: @escaping @MainActor () async throws -> Void) {
        guard !running else { return }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("://"), !host.contains("/"), !host.contains(":") else {
            error = "请输入有效的相机 IPv4 地址或主机名。"; return
        }
        running = true; self.critical = critical; error = nil; report = nil; logs = []
        let guid = UserDefaults.standard.string(forKey: "initiatorGUID").flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(guid.uuidString, forKey: "initiatorGUID")
        let lease = critical ? BackgroundTransferLease() : nil
        task = Task {
            defer { running = false; self.critical = false; task = nil; lease?.end(); refreshRecovery() }
            do {
                try await session.connect(host: host, guid: guid,
                    log: { [weak self] line in await self?.append(line) },
                    state: { [weak self] connected in await self?.setConnected(connected) })
                try await action()
            } catch { self.error = error.localizedDescription }
        }
    }
    func disconnect() {
        guard !running else { return }
        task = Task { await session.disconnect(); task = nil }
    }
    func enterBackground() {
        if !critical { task?.cancel() }
        Task { await session.disconnect() }
    }
    private func setConnected(_ value: Bool) { connected = value }
    private func append(_ line: String) {
        logs.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(line)")
        try? Data(logs.joined(separator: "\n").utf8).write(to: documents.appendingPathComponent("LatestDiagnostics.txt"), options: .atomic)
    }
}

struct RecipeLibraryView: View {
    @StateObject private var model = RecipeLibraryModel()
    @AppStorage("cameraHost") private var host = "192.168.1.1"
    @AppStorage("targetSlot") private var targetSlot = 9
    @State private var importing = false
    @State private var batch = false
    @State private var recipeToDelete: PhoneRecipe?
    @State private var confirmingDeletion = false
    @Environment(\.scenePhase) private var scenePhase
    private let gold = Color(red: 0.96, green: 0.76, blue: 0.30)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Z30 RECIPES").font(.caption.bold()).tracking(4).foregroundStyle(gold)
                            Text("把喜欢的配方，\n随时换上。").font(.system(size: 30, weight: .semibold))
                            Text("配方存在手机，C1–C9 一键载入。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "camera.aperture").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(gold)
                    }.padding(.top, 12)
                    panel {
                        HStack {
                            Label(model.connected ? "相机已连接" : "连接相机 Wi-Fi 后即可载入", systemImage: "wifi")
                                .font(.subheadline).foregroundStyle(model.connected ? .green : .secondary)
                            Spacer()
                        }
                        if let current = model.currentProfile { Text("当前：\(current)").font(.caption).foregroundStyle(.secondary) }
                        DisclosureGroup("连接设置") {
                            Text("相机保持 P／S／A／M 档，开启「连接至智能设备 → Wi-Fi」，iPhone 加入相机网络，关闭 SnapBridge 的相机会话。")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                            TextField("相机地址", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.numbersAndPunctuation).font(.system(.subheadline, design: .monospaced))
                            HStack {
                                Button("连接并查看") { model.read(host: host) }
                                Spacer()
                                Button("断开") { model.disconnect() }
                            }.font(.subheadline).disabled(model.running)
                            if model.legacyRecovery {
                                Button("恢复未完成的旧操作") { model.recoverLegacy(host: host) }.tint(.orange).disabled(model.running)
                            }
                        }.font(.subheadline)
                    }
                    panel {
                        HStack {
                            Label("手机配方库", systemImage: "square.stack").font(.headline)
                            Spacer()
                            Button { importing = true } label: { Label("批量导入", systemImage: "plus") }
                                .font(.subheadline).disabled(model.running)
                        }
                        if let notice = model.importNotice {
                            Text(notice).font(.caption).foregroundStyle(gold)
                        }
                        if model.recipes.isEmpty {
                            Text("从「文件」导入 NCP 或 NP3，配方会保存在这台 iPhone，下次可以直接选择。")
                                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(model.recipes) { recipe in
                            HStack(alignment: .center, spacing: 8) {
                                Button { model.selectedID = recipe.id } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: model.selectedID == recipe.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.selectedID == recipe.id ? gold : .secondary)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(recipe.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                            Text(recipe.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.running)
                                Button(role: .destructive) {
                                    recipeToDelete = recipe; confirmingDeletion = true
                                } label: {
                                    Image(systemName: "trash").font(.subheadline)
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(.red)
                                    .accessibilityLabel("删除\(recipe.name)").disabled(model.running)
                            }
                        }
                        Text("传统 NCP／NP3 可选择槽位实际载入，写入后记录相机响应并读回核对。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    panel {
                        Label("载入相机", systemImage: "arrow.up.right.circle").font(.headline)
                        Picker("替换槽位", selection: $targetSlot) {
                            ForEach(1...9, id: \.self) { Text("C\($0)").tag($0) }
                        }.disabled(model.running)
                        Text(model.selected.map { "将 \($0.name) 替换到 C\(targetSlot)，并设为当前优化校准。" } ?? "先从手机配方库选一个配方。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let issue = model.selected?.transferIssue {
                            Text(issue).font(.subheadline).foregroundStyle(.orange)
                        }
                        Button {
                            if let id = model.selectedID { model.transfer(host: host, assignments: [targetSlot: id], activeSlot: targetSlot) }
                        } label: {
                            HStack {
                                if model.running { ProgressView().tint(.black) }
                                else { Image(systemName: "paperplane.fill") }
                                Text(model.running ? "正在载入…" : "一键替换 C\(targetSlot) 并应用").fontWeight(.semibold)
                            }.frame(maxWidth: .infinity).padding(.vertical, 14)
                        }.buttonStyle(.plain).foregroundStyle(.black)
                            .background(gold.opacity(model.selected == nil || model.selected?.transferIssue != nil || model.running ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 13))
                            .disabled(model.selected == nil || model.selected?.transferIssue != nil || model.running || model.legacyRecovery)
                        Button { batch = true } label: { Label("批量配置 C1–C9", systemImage: "square.grid.3x3") }
                            .font(.subheadline).disabled(model.recipes.isEmpty || model.running || model.legacyRecovery)
                        Text("仅替换选中的槽位；写入后自动读回核对。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let report = model.report {
                        panel {
                            Label("已载入并应用 C\(report.activeSlot)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                            ForEach(report.items, id: \.slot) { item in
                                Text("C\(item.slot) · \(item.name)").font(.subheadline)
                            }
                            Text("保存的参数、曲线及当前槽位均已读回确认。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.error {
                        panel {
                            Label("操作未完成", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.headline)
                            Text(error).font(.subheadline)
                        }
                    }
                    if !model.logs.isEmpty {
                        DisclosureGroup("查看连接记录") {
                            ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }.font(.subheadline).padding(.horizontal, 8)
                    }
                    Text("1.0.4 · 配方保存在本机。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 12)
                }.padding(.horizontal, 22)
            }.background(Color(red: 0.055, green: 0.065, blue: 0.08))
                .toolbar(.hidden, for: .navigationBar)
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): model.importFiles(urls)
                    case .failure(let error): model.error = error.localizedDescription
                    }
                }
                .onChange(of: model.selectedID) { _, _ in model.report = nil }
                .alert("删除手机配方？", isPresented: $confirmingDeletion, presenting: recipeToDelete) { recipe in
                    Button("删除", role: .destructive) { model.deleteRecipe(recipe); recipeToDelete = nil }
                    Button("取消", role: .cancel) { recipeToDelete = nil }
                } message: { recipe in
                    Text("删除手机配方库中的“\(recipe.name)”？相机中的配方和原始文件会保留。")
                }
                .sheet(isPresented: $batch) { BatchTransferView(model: model, host: host) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.enterBackground() }
                    if phase == .active { model.reloadLibrary() }
                }
        }.preferredColorScheme(.dark).tint(gold)
    }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.10, green: 0.12, blue: 0.14), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct BatchTransferView: View {
    @ObservedObject var model: RecipeLibraryModel
    let host: String
    @State private var assignments: [Int: String] = [:]
    @State private var activeSlot = 1
    @Environment(\.dismiss) private var dismiss
    private var chosen: [Int: String] { assignments.filter { !$0.value.isEmpty } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(1...9, id: \.self) { slot in
                        Picker("C\(slot)", selection: Binding(get: { assignments[slot] ?? "" }, set: { assignments[slot] = $0 })) {
                            Text("不替换").tag("")
                            ForEach(model.recipes.filter { $0.transferIssue == nil }) { recipe in Text(recipe.name).tag(recipe.id) }
                        }
                    }
                } header: { Text("指定每个槽位的配方") }
                Section {
                    Picker("完成后应用", selection: $activeSlot) {
                        ForEach(chosen.keys.sorted(), id: \.self) { slot in Text("C\(slot)").tag(slot) }
                    }
                    Text("只写入已指定的槽位。若途中中断，已完成的槽位会保留更新，可重新连接后重试。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("批量载入 C1–C9").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("同步 \(chosen.count) 个") {
                            model.transfer(host: host, assignments: chosen, activeSlot: activeSlot); dismiss()
                        }.disabled(chosen.isEmpty || chosen[activeSlot] == nil)
                    }
                }
                .onChange(of: assignments) { _, _ in
                    if chosen[activeSlot] == nil { activeSlot = chosen.keys.sorted().first ?? 1 }
                }
        }.preferredColorScheme(.dark)
    }
}
