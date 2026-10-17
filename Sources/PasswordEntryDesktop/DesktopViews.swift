import SwiftUI
import AppKit
import Combine
import PasswordEntryCore

@MainActor
final class DesktopModel: ObservableObject {
    let store = VaultStore()
    private(set) var shareAPI: ShareAPIClient
    private let server: AgentServer
    private static let shareAPIURLKey = "shareAPIURL"
    @Published var isUnlocked = false
    @Published var entries: [LoginEntry] = []
    @Published var shares: [ShareRecord] = []
    @Published var shareAPIURL: String
    @Published var selectedID: UUID?
    @Published var errorMessage = ""
    @Published var isWorking = false

    init() {
        let storedURL = UserDefaults.standard.string(forKey: Self.shareAPIURLKey).flatMap(URL.init(string:))
        let configuredURL = storedURL.flatMap(Self.validShareAPIURL) ?? ShareAPIClient.defaultBaseURL
        shareAPIURL = configuredURL.absoluteString
        shareAPI = ShareAPIClient(baseURL: configuredURL)
        server = AgentServer(store: store)
        server.onVaultChanged = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        server.start()
    }

    func unlock(password: String) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.store.unlock(password: password)
                let loaded = try self.store.entries()
                let loadedShares = try self.store.shares()
                DispatchQueue.main.async {
                    self.entries = loaded
                    self.shares = loadedShares
                    self.selectedID = loaded.first?.id
                    self.isUnlocked = true
                    self.isWorking = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isWorking = false
                }
            }
        }
    }

    func lock() { store.lockVault(); isUnlocked = false; entries = []; shares = []; selectedID = nil }

    func refresh() {
        guard isUnlocked else { return }
        do {
            entries = try store.entries()
            shares = try store.shares()
            if selectedID == nil { selectedID = entries.first?.id }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func save(_ entry: LoginEntry) { do { try store.saveEntry(entry); refresh() } catch { errorMessage = error.localizedDescription } }
    func delete(_ entry: LoginEntry) {
        let activeShares = shares(for: entry).filter { !$0.isRevoked && !$0.isExpired }
        Task {
            do {
                for share in activeShares { try await revokeShare(share) }
                try store.deleteEntry(id: entry.id)
                refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func totp(for entry: LoginEntry) -> String? { guard let config = entry.totp else { return nil }; return try? TOTP.generate(config) }

    func shares(for entry: LoginEntry) -> [ShareRecord] {
        shares.filter { $0.entryID == entry.id }.sorted { $0.createdAt > $1.createdAt }
    }

    func updateShareAPIURL(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let validURL = Self.validShareAPIURL(url) else {
            throw ShareAPIError.invalidBaseURL
        }
        shareAPIURL = validURL.absoluteString
        shareAPI = ShareAPIClient(baseURL: validURL)
        UserDefaults.standard.set(shareAPIURL, forKey: Self.shareAPIURLKey)
    }

    func createShare(entry: LoginEntry, includeTotp: Bool, expiresAt: Date) async throws -> ShareRecord {
        let material = try ShareCrypto.prepare(entry: entry, includeTotp: includeTotp)
        let api = shareAPI
        let serverShareID = try await api.create(material: material, expiresAt: expiresAt)
        let record = ShareRecord(serverShareID: serverShareID, apiBaseURL: api.baseURL.absoluteString, entryID: entry.id, viewSecret: material.viewSecret, revokeSecret: material.revokeSecret, expiresAt: expiresAt)
        do {
            try store.saveShare(record)
        } catch {
            try? await api.revoke(shareID: serverShareID, revokeSecret: material.revokeSecret)
            throw error
        }
        shares = try store.shares()
        return record
    }

    func revokeShare(_ share: ShareRecord) async throws {
        let api = share.apiBaseURL.isEmpty ? shareAPI : ShareAPIClient(baseURL: URL(string: share.apiBaseURL) ?? shareAPI.baseURL)
        try await api.revoke(shareID: share.serverShareID, revokeSecret: share.revokeSecret)
        try store.revokeShare(id: share.id)
        shares = try store.shares()
    }

    private static func validShareAPIURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}

struct UnlockView: View {
    @ObservedObject var model: DesktopModel
    @State private var password = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 42)).foregroundStyle(.blue)
            Text("Password Entry").font(.title2.bold())
            Text(model.store.hasVault ? "输入主密码解锁保险库" : "设置一个至少 12 个字符的主密码").foregroundStyle(.secondary)
            SecureField("主密码", text: $password).textFieldStyle(.roundedBorder).frame(width: 300)
            if model.isWorking { ProgressView().controlSize(.small) }
            Button("解锁") { model.unlock(password: password); password = "" }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.isWorking)
            if !model.errorMessage.isEmpty { Text(model.errorMessage).foregroundStyle(.red).font(.caption) }
        }.padding(38).frame(width: 390, height: 310)
    }
}

private enum EntryEditorMode: Identifiable {
    case new
    case edit(LoginEntry)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let entry): return entry.id.uuidString
        }
    }

    var entry: LoginEntry? {
        if case .edit(let entry) = self { return entry }
        return nil
    }
}

struct VaultView: View {
    @ObservedObject var model: DesktopModel
    @State private var search = ""
    @State private var editorMode: EntryEditorMode?

    var filtered: [LoginEntry] { model.entries.filter { search.isEmpty || "\($0.name) \($0.username) \($0.domains.joined(separator: " "))".localizedCaseInsensitiveContains(search) } }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $model.selectedID) { entry in
                HStack(spacing: 10) {
                    FaviconView(data: entry.faviconData, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.headline)
                        Text(entry.domains.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }.tag(entry.id)
            }.searchable(text: $search, prompt: "搜索保险库").toolbar {
                ToolbarItemGroup {
                    Button("新增") { editorMode = .new }
                    Button("锁定") { model.lock() }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                }
                Group {
                    if let id = model.selectedID, let entry = model.entries.first(where: { $0.id == id }) {
                        EntryDetail(entry: entry, model: model) {
                            editorMode = .edit(entry)
                        }
                    }
                    else { VStack(spacing: 10) { Image(systemName: "key.fill").font(.largeTitle); Text("选择一个登录项").font(.title3); Text("从左侧选择账号，或新增一个登录项").foregroundStyle(.secondary); Button("新增登录项") { editorMode = .new }.buttonStyle(.borderedProminent) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.sheet(item: $editorMode) { mode in EntryEditor(entry: mode.entry, model: model) }
        .frame(minWidth: 780, minHeight: 500)
    }
}

struct FaviconView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: "globe").resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("网站图标")
    }
}

struct EntryDetail: View {
    let entry: LoginEntry
    @ObservedObject var model: DesktopModel
    let onEdit: () -> Void
    @State private var code = ""
    @State private var clock = Date()
    @State private var codeCounter: Int?
    @State private var showPassword = false
    @State private var showShare = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    FaviconView(data: entry.faviconData, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.title2.bold())
                        Text(entry.domains.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("分享", systemImage: "square.and.arrow.up") { showShare = true }
                        .buttonStyle(.bordered)
                    Button("编辑", systemImage: "pencil") { onEdit() }
                        .buttonStyle(.bordered)
                }
            }
            Section("登录信息") {
                LabeledContent("用户名") { Text(entry.username); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.username, forType: .string) } label: { Image(systemName: "doc.on.doc") } }
                LabeledContent("密码") { HStack { Text(showPassword ? entry.password : String(repeating: "•", count: 10)); Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }; Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.password, forType: .string) } label: { Image(systemName: "doc.on.doc") } } }
            }
            if let totp = entry.totp {
                Section("一次性验证码") {
                    let remaining = TOTP.secondsRemaining(totp, date: clock)
                    HStack(spacing: 14) {
                        Text(code.isEmpty ? "点击读取" : code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("有效期剩余 \(remaining) 秒").foregroundStyle(.secondary).font(.caption)
                            ProgressView(value: Double(remaining), total: Double(max(totp.period, 1))).frame(width: 110)
                        }
                        Spacer()
                        Button("读取并复制") {
                            do {
                                try LocalAuth.authenticate(reason: "允许读取并复制验证码")
                                code = try TOTP.generate(totp, date: clock)
                                codeCounter = Int(clock.timeIntervalSince1970 / Double(max(totp.period, 1)))
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                            } catch { model.errorMessage = error.localizedDescription }
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
            let entryShares = model.shares(for: entry)
            if !entryShares.isEmpty {
                Section("分享历史") {
                    ForEach(entryShares) { share in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(share.isRevoked ? "已撤销" : (share.isExpired ? "已过期" : "有效分享链接"))
                                    .foregroundStyle(share.isRevoked || share.isExpired ? .secondary : .primary)
                                Text("有效期至 \(share.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !share.isRevoked && !share.isExpired {
                                Button("复制链接") {
                                    if let url = share.shareURL(baseURL: model.shareAPI.baseURL) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                }
                                Button("撤销", role: .destructive) {
                                    Task {
                                        do { try await model.revokeShare(share) }
                                        catch { model.errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section { Button("删除此登录项", role: .destructive) { model.delete(entry) } }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showShare) { ShareSheet(entry: entry, model: model) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            clock = value
            if let totp = entry.totp, let codeCounter, Int(value.timeIntervalSince1970 / Double(max(totp.period, 1))) != codeCounter { code = ""; self.codeCounter = nil }
        }
    }
}

private enum ShareExpiry: String, CaseIterable, Identifiable {
    case hour
    case day
    case week
    case twoWeeks
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "1 小时"
        case .day: return "1 天"
        case .week: return "7 天"
        case .twoWeeks: return "14 天"
        case .month: return "30 天"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .twoWeeks: return 14 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }
}

struct ShareSheet: View {
    let entry: LoginEntry
    @ObservedObject var model: DesktopModel
    @Environment(\.dismiss) private var dismiss
    @State private var expiry: ShareExpiry = .week
    @State private var includeTotp = false
    @State private var isWorking = false
    @State private var link: URL?
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("分享登录项").font(.title2.bold())
            Text(entry.name).font(.headline)
            Text("云端只保存加密后的副本；分享链接中的密钥由接收方浏览器本地使用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let link {
                Text("分享链接已创建").font(.headline).foregroundStyle(.green)
                TextField("分享链接", text: .constant(link.absoluteString))
                    .textFieldStyle(.roundedBorder)
                    .textSelection(.enabled)
                HStack {
                    Button("复制链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("完成") { dismiss() }
                }
            } else {
                Picker("有效期", selection: $expiry) {
                    ForEach(ShareExpiry.allCases) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.menu)
                Toggle("包含 TOTP 密钥", isOn: $includeTotp)
                Text("包含 TOTP 后，接收方可以看到并使用该一次性验证码配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    Button("创建分享链接") { create() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func create() {
        isWorking = true
        message = ""
        let expiresAt = Date().addingTimeInterval(expiry.seconds)
        Task {
            do {
                let record = try await model.createShare(entry: entry, includeTotp: includeTotp, expiresAt: expiresAt)
                guard let url = record.shareURL(baseURL: model.shareAPI.baseURL) else { throw ShareAPIError.invalidBaseURL }
                link = url
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }
}

struct EntryEditor: View {
    let original: LoginEntry?
    @ObservedObject var model: DesktopModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var domain: String
    @State private var username: String
    @State private var password: String
    @State private var totpSecret: String

    init(entry: LoginEntry?, model: DesktopModel) {
        original = entry; self.model = model
        _name = State(initialValue: entry?.name ?? ""); _domain = State(initialValue: entry?.domains.first ?? ""); _username = State(initialValue: entry?.username ?? ""); _password = State(initialValue: entry?.password ?? ""); _totpSecret = State(initialValue: entry?.totp?.secret ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "新增登录项" : "编辑登录项").font(.title2.bold())
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("网站，例如 github.com", text: $domain).textFieldStyle(.roundedBorder)
            TextField("用户名", text: $username).textFieldStyle(.roundedBorder)
            SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
            TextField("TOTP 密钥或 otpauth:// 链接（可选）", text: $totpSecret).textFieldStyle(.roundedBorder)
            Text("在阿里云 RAM 的 MFA 开通页面复制手工密钥；也可以粘贴 otpauth://totp 链接。不要把真实密钥发送给任何人。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 430)
    }

    private func save() {
        guard !name.isEmpty, !domain.isEmpty else { return }
        let config: TotpConfig?
        if totpSecret.isEmpty { config = nil }
        else if let originalTotp = original?.totp, totpSecret == originalTotp.secret { config = originalTotp }
        else if totpSecret.lowercased().hasPrefix("otpauth://") { config = try? TotpConfig(otpauthURI: totpSecret) }
        else { config = TotpConfig(secret: totpSecret) }
        model.save(LoginEntry(id: original?.id ?? UUID(), name: name, domains: [domain], username: username, password: password, totp: config, faviconData: original?.faviconData, faviconMimeType: original?.faviconMimeType, createdAt: original?.createdAt ?? .now, updatedAt: .now))
        dismiss()
    }
}

struct SettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var shareAPIURL: String
    @State private var message = ""

    init(model: DesktopModel) {
        self.model = model
        _shareAPIURL = State(initialValue: model.shareAPIURL)
    }

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时自动启动 Password Entry", isOn: Binding(
                    get: { launchAtLogin },
                    set: { updateLaunchAtLogin($0) }
                ))
                Text("关闭主窗口后，Password Entry 仍会在菜单栏运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("分享服务") {
                TextField("API 地址", text: $shareAPIURL)
                    .textFieldStyle(.roundedBorder)
                Text("填写部署后的 HTTPS 地址，例如 https://share.example.com。开发环境可使用 http://127.0.0.1:8787。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("保存分享服务地址") { updateShareAPIURL() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }

    private func updateShareAPIURL() {
        do {
            try model.updateShareAPIURL(shareAPIURL)
            shareAPIURL = model.shareAPIURL
            message = "分享服务地址已保存"
        } catch {
            message = error.localizedDescription
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled
            message = enabled
                ? (launchAtLogin ? "已启用登录时自动启动" : "已请求启用自动启动；如果系统要求，请在系统设置中允许")
                : "已关闭登录时自动启动"
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            message = "无法更新自动启动设置：\(error.localizedDescription)"
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 Password Entry") { openWindow(id: "main") }
        Text(model.isUnlocked ? "保险库已解锁" : "保险库已锁定")
        if model.isUnlocked {
            Button("锁定保险库") { model.lock() }
        }
        Divider()
        Button("设置…") { openWindow(id: "settings") }
        Button("退出 Password Entry") { NSApplication.shared.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PasswordEntryDesktop: App {
    @StateObject private var model = DesktopModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Password Entry", id: "main") {
            if model.isUnlocked { VaultView(model: model) } else { UnlockView(model: model) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("锁定保险库") { model.lock() }
                    .keyboardShortcut("L", modifiers: [.command, .shift])
            }
        }
        Window("设置", id: "settings") { SettingsView(model: model) }
        MenuBarExtra("Password Entry", systemImage: "key.fill") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}
