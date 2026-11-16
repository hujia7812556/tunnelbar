import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: UUID?
    @State private var editingProfile: TunnelProfile?
    @State private var sidebarVisible = true

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let issue = model.configurationIssue {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("配置读取失败，原文件已保留").font(.headline)
                            Text(issue).font(.caption)
                        }
                        Spacer()
                        Button("查看配置文件") { model.revealConfiguration() }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    Divider()
                }

                GeometryReader { splitGeometry in
                    HSplitView {
                        if sidebarVisible {
                            sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                        }
                        if let profile = model.profiles.first(where: { $0.id == selectedID }) {
                            HostDetailView(model: model, profile: profile) { editingProfile = profile }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            emptySelection
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: splitGeometry.size.width, height: splitGeometry.size.height)
                }
            }
            // 分栏和表格共用窗口实际尺寸，避免原生表格的理想高度扩张整个界面。
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { selectAvailableProfile() }
        .onChange(of: model.profiles.map { $0.id }) { _ in selectAvailableProfile() }
        .onReceive(NotificationCenter.default.publisher(for: .tunnelBarAddHost)) { _ in
            if model.configurationIssue == nil { editingProfile = TunnelProfile() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tunnelBarToggleSidebar)) { _ in sidebarVisible.toggle() }
        .sheet(item: $editingProfile) { profile in
            HostEditor(profile: profile) { updated in
                let error = saveProfile(updated)
                if error == nil {
                    selectedID = updated.id
                    editingProfile = nil
                }
                return error
            } onCancel: {
                editingProfile = nil
            }
        }
        .alert(isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Alert(title: Text("操作未完成"), message: Text(model.errorMessage ?? ""), dismissButton: .default(Text("好")))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("主机").font(.subheadline).foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            Divider()
            List(selection: $selectedID) {
                ForEach(model.profiles) { profile in
                    let state = model.state(for: profile.id)
                    HStack(spacing: 10) {
                        Circle().fill(state.phase.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.body).fontWeight(.medium).lineLimit(1)
                            Text(state.phase.title).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .tag(profile.id)
                }
            }
            .listStyle(SidebarListStyle())
            Divider()
            HStack {
                Text("\(model.profiles.count) 个主机").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: { model.revealConfiguration() }) { Image(systemName: "folder") }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("查看本地配置")
            }
            .padding(12)
        }
    }

    private var emptySelection: some View {
        VStack(spacing: 16) {
            Image(systemName: "network").font(.system(size: 46)).foregroundColor(.accentColor)
            Text(model.profiles.isEmpty ? "添加第一台 SSH 主机" : "选择一个主机").font(.title2)
            Text("集中管理本地端口转发，连接状态在菜单栏随时可见。")
                .foregroundColor(.secondary)
            if model.profiles.isEmpty {
                Button("添加主机") { editingProfile = TunnelProfile() }
                    .disabled(model.configurationIssue != nil)
            }
        }
        .padding(30)
    }

    /// 删除或首次加载配置后，保持侧栏选择有效。
    private func selectAvailableProfile() {
        if !model.profiles.contains(where: { $0.id == selectedID }) {
            selectedID = model.profiles.first?.id
        }
    }

    /// 将保存错误交给当前表单展示，避免失败时关闭编辑窗口。
    private func saveProfile(_ profile: TunnelProfile) -> String? {
        model.errorMessage = nil
        model.saveProfile(profile)
        let error = model.errorMessage
        model.errorMessage = nil
        return error
    }
}

private struct HostDetailView: View {
    @ObservedObject var model: AppModel
    let profile: TunnelProfile
    let onEditHost: () -> Void
    @State private var editingRule: ForwardRule?
    @State private var removal: RemovalRequest?
    @State private var editingRemarkID: UUID?
    @State private var remarkDraft = ""
    @State private var showingDetails = false
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var followsLatest = true
    @State private var selectedRuleID: UUID?
    @FocusState private var focusedRemarkID: UUID?

    private var state: HostRuntimeState { model.state(for: profile.id) }
    private var failedRules: [ForwardRule] {
        profile.forwards.filter { model.ruleState(profileID: profile.id, rule: $0).phase == .failed }
    }
    private var listeningCount: Int {
        profile.forwards.filter { model.ruleState(profileID: profile.id, rule: $0).phase == .listening }.count
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header.fixedSize(horizontal: false, vertical: true)
                    if let message = state.message {
                        Text(message)
                            .font(.callout)
                            .foregroundColor(state.phase == .connected ? .secondary : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let connection = state.connectedConfiguration, connection != profile.connection {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("主机连接参数已修改，重连后生效。")
                            Spacer()
                            Button("立即重连") { model.reconnect(profile.id) }
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(8)
                    }
                    forwardList
                    HStack {
                        Image(systemName: "info.circle")
                        Text("已监听表示本机入口已建立，远端服务仍需保持可用。")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    Divider()
                    preferences.fixedSize(horizontal: false, vertical: true)
                    logPanel.fixedSize(horizontal: false, vertical: true)
                }
                // 小窗口或较长错误信息允许滚动，始终保留设置和日志的入口。
                .frame(minHeight: max(0, geometry.size.height - 40), alignment: .topLeading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: profile.id) { _ in
            editingRemarkID = nil
            selectedRuleID = nil
            showingSettings = false
            showingLogs = false
        }
        .sheet(item: $editingRule) { rule in
            ForwardEditor(rule: rule) { updated in
                let error = saveRule(updated)
                if error == nil { editingRule = nil }
                return error
            } onCancel: {
                editingRule = nil
            }
        }
        .sheet(isPresented: $showingDetails) {
            ConnectionDetailsView(profile: profile, state: state, entries: model.logs[profile.id] ?? [],
                                  storageIssue: model.logStorageIssue) { showingDetails = false }
        }
        .alert(item: $removal) { request in
            switch request {
            case .host:
                return Alert(
                    title: Text("删除“\(profile.name)”？"),
                    message: Text("将断开这个主机，并删除其端口转发配置和日志。"),
                    primaryButton: .destructive(Text("删除")) { model.deleteProfile(profile.id) },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .rule(let rule):
                return Alert(
                    title: Text("删除这条端口转发？"),
                    message: Text("停止接收新的连接，其他端口转发不受影响。"),
                    primaryButton: .destructive(Text("删除")) { deleteRule(rule.id) },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name).font(.title2).fontWeight(.semibold).lineLimit(1)
                    .help(profile.name)
                HStack(spacing: 8) {
                    Label(profile.connection.hostname, systemImage: "server.rack")
                        .lineLimit(1)
                    Text("·")
                    Circle().fill(state.phase.color).frame(width: 7, height: 7)
                    Text(state.phase.title)
                }
                .font(.callout).foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            Button(state.phase.isActive ? "断开连接" : "连接") {
                if state.phase.isActive { model.disconnect(profile.id) }
                else { model.connect(profile.id) }
            }
            .keyboardShortcut("k", modifiers: [.command])
            Menu {
                if state.phase == .connected { Button("重新连接") { model.reconnect(profile.id) } }
                Button("连接详情…") { showingDetails = true }
                Divider()
                Button("编辑主机…") { onEditHost() }
                    .disabled(model.configurationIssue != nil)
                Button("删除主机…", role: .destructive) { removal = .host }
                    .disabled(model.configurationIssue != nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .fixedSize()
            .help("主机操作")
            .accessibilityLabel("主机操作")
        }
        .padding(.bottom, 4)
    }

    private var preferences: some View {
        DisclosureGroup(isExpanded: $showingSettings) {
            HStack(spacing: 28) {
                Toggle("状态变化通知", isOn: preferenceBinding(\.notifyOnChange))
                    .help("通知此主机和端口转发的状态变化")
                Toggle("启动时自动连接", isOn: preferenceBinding(\.autoConnect))
                Spacer(minLength: 0)
            }
            .toggleStyle(CheckboxToggleStyle())
            .padding(.top, 10).padding(.bottom, 4)
            .disabled(model.configurationIssue != nil)
        } label: {
            Button("主机设置") { showingSettings.toggle() }
                .buttonStyle(.plain)
        }
        .font(.callout)
        .overlay(alignment: .topTrailing) {
            if profile.notifyOnChange && model.notificationPermissionDenied {
                Button("允许系统通知…") { model.openNotificationSettings() }
                    .font(.caption).buttonStyle(.link)
            }
        }
    }

    private var forwardList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("端口转发").font(.headline)
                Text("启用 \(profile.forwards.filter { $0.isEnabled }.count) · 已监听 \(listeningCount)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if !failedRules.isEmpty {
                    Button("重试 \(failedRules.count) 条失败规则") { model.retryForwards(profile.id) }
                }
                Button(action: addRule) { Label("添加转发", systemImage: "plus") }
                    .disabled(model.configurationIssue != nil)
            }
            if profile.forwards.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right").font(.title).foregroundColor(.secondary)
                    Text("尚未添加端口转发").font(.headline)
                    Text("设置这台 Mac 的入口和 SSH 服务器上的目标。")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            } else {
                GeometryReader { geometry in
                    portTable.frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(minHeight: 130)
                HStack(spacing: 12) {
                    Button("全部启用") { setAllRulesEnabled(true) }
                        .disabled(model.configurationIssue != nil || profile.forwards.allSatisfy { $0.isEnabled })
                    Button("全部停用") { setAllRulesEnabled(false) }
                        .disabled(model.configurationIssue != nil || profile.forwards.allSatisfy { !$0.isEnabled })
                    Spacer()
                    Text("勾选即启用").foregroundColor(.secondary)
                }
                .font(.caption).controlSize(.small)
            }
            if let rule = failedRules.first(where: { $0.id == selectedRuleID }) ?? failedRules.first,
               let message = model.ruleState(profileID: profile.id, rule: rule).message {
                Label {
                    Text("\(endpoint(rule.bindAddress, port: rule.localPort))：\(message)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var portTable: some View {
        Table(profile.forwards, selection: $selectedRuleID) {
            TableColumn("启用") { rule in
                Toggle("启用 \(String(rule.localPort))", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { enabled in var updated = rule; updated.isEnabled = enabled; updateRule(updated) }
                ))
                .labelsHidden().toggleStyle(CheckboxToggleStyle())
                .disabled(model.configurationIssue != nil)
            }.width(38)
            TableColumn("备注") { rule in remarkCell(rule) }.width(min: 95, ideal: 125)
            TableColumn("本地入口") { rule in endpointCell(endpoint(rule.bindAddress, port: rule.localPort)) }
                .width(min: 145, ideal: 165)
            TableColumn("远端目标") { rule in endpointCell(endpoint(rule.remoteHost, port: rule.remotePort)) }
                .width(min: 145, ideal: 165)
            TableColumn("状态") { rule in
                let runtime = model.ruleState(profileID: profile.id, rule: rule)
                HStack(spacing: 6) {
                    Circle().fill(runtime.phase.color).frame(width: 6, height: 6)
                    Text(runtime.phase.title).font(.caption)
                }.help(runtime.message ?? runtime.phase.title)
            }.width(75)
            TableColumn("") { rule in
                Menu {
                    Button("编辑转发…") { editingRule = rule }
                    Button("编辑备注") { beginEditingRemark(rule) }
                    Divider()
                    Button("删除转发…", role: .destructive) { removal = .rule(rule) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(BorderlessButtonMenuStyle()).fixedSize()
                .accessibilityLabel("端口 \(String(rule.localPort)) 的操作")
                .disabled(model.configurationIssue != nil)
            }.width(24)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: UUID.self) { ids in
            if model.configurationIssue == nil, let id = ids.first, let rule = profile.forwards.first(where: { $0.id == id }) {
                Button("编辑转发…") { editingRule = rule }
                Button("编辑备注") { beginEditingRemark(rule) }
                Button("删除转发…", role: .destructive) { removal = .rule(rule) }
            }
        } primaryAction: { ids in
            if model.configurationIssue == nil, let id = ids.first { editingRule = profile.forwards.first(where: { $0.id == id }) }
        }
        .onDeleteCommand {
            if model.configurationIssue == nil, let rule = profile.forwards.first(where: { $0.id == selectedRuleID }) {
                removal = .rule(rule)
            }
        }
    }

    /// 地址使用等宽字体并提供完整提示，长地址不会撑坏表格。
    private func endpointCell(_ endpoint: String) -> some View {
        Text(endpoint).font(.system(.body, design: .monospaced)).lineLimit(1)
            .truncationMode(.middle).help(endpoint)
    }

    /// IPv6 地址加上方括号，与端口保持明确边界。
    private func endpoint(_ host: String, port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(String(port))"
    }

    /// 备注保留明确保存与取消操作，纯备注编辑不会触发重连。
    @ViewBuilder private func remarkCell(_ rule: ForwardRule) -> some View {
        if editingRemarkID == rule.id {
            HStack(spacing: 4) {
                TextField("备注", text: $remarkDraft, onCommit: { saveRemark(rule.id) })
                    .textFieldStyle(.plain)
                    .focused($focusedRemarkID, equals: rule.id)
                    .onExitCommand { editingRemarkID = nil }
                Button(action: { saveRemark(rule.id) }) { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless).help("保存备注")
            }
        } else {
            Button(action: { beginEditingRemark(rule) }) {
                Text(rule.name.isEmpty ? "添加备注" : rule.name).lineLimit(1)
                    .foregroundColor(rule.name.isEmpty ? .secondary : .primary)
            }.buttonStyle(.plain).help("编辑备注")
        }
    }

    private var logPanel: some View {
        DisclosureGroup(isExpanded: $showingLogs) {
            VStack(spacing: 8) {
                HStack {
                    Text("最近 \(model.logs[profile.id]?.count ?? 0) 条").foregroundColor(.secondary)
                    Spacer()
                    Toggle("跟随最新", isOn: $followsLatest).toggleStyle(CheckboxToggleStyle())
                    Button("复制日志", action: copyLogs).disabled(model.logs[profile.id, default: []].isEmpty)
                    Button("连接详情…") { showingDetails = true }
                }.font(.caption).controlSize(.small)
                if let issue = model.logStorageIssue { Text(issue).font(.caption).foregroundColor(.orange) }
                ConnectionLogList(entries: model.logs[profile.id] ?? [], followsLatest: $followsLatest)
                    .frame(height: 155)
            }.padding(.top, 10)
        } label: {
            Button("连接日志") { showingLogs.toggle() }
                .buttonStyle(.plain)
        }
        .font(.callout)
    }

    /// 复制当前主机的可见日志，不包含其他主机的数据。
    private func copyLogs() {
        let text = (["主机：\(profile.name)（\(profile.connection.hostname)）"] +
                    (model.logs[profile.id] ?? []).map { $0.plainText }).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 批量勾选只保存一次最新配置，由连接管理器调整实际变化的端口。
    private func setAllRulesEnabled(_ enabled: Bool) {
        guard var updated = model.profiles.first(where: { $0.id == profile.id }) else { return }
        for index in updated.forwards.indices { updated.forwards[index].isEnabled = enabled }
        model.saveProfile(updated)
    }

    /// 在列表中编辑现有备注，只有明确保存才写入配置。
    private func beginEditingRemark(_ rule: ForwardRule) {
        remarkDraft = rule.name
        editingRemarkID = rule.id
        focusedRemarkID = rule.id
    }

    /// 仅修改最新规则的备注，避免覆盖编辑期间刚切换的勾选状态。
    private func saveRemark(_ id: UUID) {
        guard var updated = model.profiles.first(where: { $0.id == profile.id }),
              let index = updated.forwards.firstIndex(where: { $0.id == id }) else { return }
        updated.forwards[index].name = remarkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.errorMessage = nil
        model.saveProfile(updated)
        if model.errorMessage == nil { editingRemarkID = nil }
    }

    /// 两个主机偏好分别保存，不触发界面自行重连。
    private func preferenceBinding(_ keyPath: WritableKeyPath<TunnelProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { value in
                guard var updated = model.profiles.first(where: { $0.id == profile.id }) else { return }
                updated[keyPath: keyPath] = value
                model.saveProfile(updated)
            }
        )
    }

    /// 新建规则选择本配置中未使用的默认端口，实际占用仍由连接管理检查。
    private func addRule() {
        let used = Set(profile.forwards.map { $0.localPort })
        var rule = ForwardRule()
        rule.localPort = (8080...65535).first(where: { !used.contains($0) }) ?? 8080
        editingRule = rule
    }

    /// 保存表单中的规则并把失败原因留在表单中。
    private func saveRule(_ rule: ForwardRule) -> String? {
        model.errorMessage = nil
        updateRule(rule)
        let error = model.errorMessage
        model.errorMessage = nil
        return error
    }

    /// 始终从最新配置替换单条规则，避免覆盖刚保存的主机偏好。
    private func updateRule(_ rule: ForwardRule) {
        guard var updated = model.profiles.first(where: { $0.id == profile.id }) else { return }
        if let index = updated.forwards.firstIndex(where: { $0.id == rule.id }) {
            updated.forwards[index] = rule
        } else {
            updated.forwards.append(rule)
        }
        model.saveProfile(updated)
    }

    /// 删除配置中的指定规则，由模型取消相应监听。
    private func deleteRule(_ id: UUID) {
        guard var updated = model.profiles.first(where: { $0.id == profile.id }) else { return }
        updated.forwards.removeAll { $0.id == id }
        model.saveProfile(updated)
    }
}

struct ConnectionDetailsView: View {
    let profile: TunnelProfile
    let state: HostRuntimeState
    let entries: [ConnectionLogEntry]
    let storageIssue: String?
    let onClose: () -> Void
    @State private var followsLatest = true

    private var connection: SSHConnection { state.connectedConfiguration ?? profile.connection }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(profile.name) · 详细信息").font(.title2).fontWeight(.semibold)
                Spacer()
                Text(state.phase.title).foregroundColor(state.phase.color)
            }
            GroupBox(label: Text(state.connectedConfiguration == nil ? "连接配置" : "当前连接使用的配置")) {
                VStack(spacing: 8) {
                    detailRow("SSH 主机或别名", connection.hostname)
                    Divider()
                    detailRow("用户名", connection.username.isEmpty ? "沿用 SSH 配置" : connection.username)
                    Divider()
                    detailRow("SSH 端口", connection.port.map(String.init) ?? "沿用 SSH 配置")
                }
                .padding(8)
            }
            HStack {
                Text("连接日志").font(.headline)
                Text("\(String(entries.count)) 条").font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle("跟随最新", isOn: $followsLatest).toggleStyle(CheckboxToggleStyle())
                Button("复制日志", action: copyLogs).disabled(entries.isEmpty)
            }
            if let issue = storageIssue {
                Text(issue).font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ConnectionLogList(entries: entries, followsLatest: $followsLatest)
            HStack {
                Text("每个主机保留最近 300 条；日志不记录转发的业务内容。")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 740, height: 620)
    }

    /// 只展示明确的配置值，不把 SSH 别名推测为实际地址或协商结果。
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }

    /// 用户主动复制时导出当前主机的可见日志，不夹带其他主机或敏感配置。
    private func copyLogs() {
        let text = (["主机：\(profile.name)（\(connection.hostname)）"] + entries.map { $0.plainText }).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ConnectionLogList: View {
    let entries: [ConnectionLogEntry]
    @Binding var followsLatest: Bool

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                if entries.isEmpty {
                    Text("暂无日志。连接主机或调整端口配置后，记录会显示在这里。")
                        .foregroundColor(.secondary).padding(24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(entry.timestamp.formatted(date: .numeric, time: .standard))
                                        .foregroundColor(.secondary)
                                    Text(entry.level.title).foregroundColor(entry.level.color)
                                }
                                .font(.system(.caption, design: .monospaced))
                                Text(entry.message).foregroundColor(entry.level.color)
                                    .font(.system(.callout, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                        }
                    }
                    .padding(14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .onAppear { if let id = entries.last?.id { reader.scrollTo(id, anchor: .bottom) } }
            .onChange(of: entries.last?.id) { id in
                if followsLatest, let id = id { reader.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: followsLatest) { enabled in
                if enabled, let id = entries.last?.id { reader.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

private extension ConnectionLogLevel {
    var color: Color {
        switch self {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private enum RemovalRequest: Identifiable {
    case host
    case rule(ForwardRule)

    var id: String {
        switch self {
        case .host: return "host"
        case .rule(let rule): return rule.id.uuidString
        }
    }
}

private struct HostEditor: View {
    @State private var draft: TunnelProfile
    @State private var portText: String
    @State private var error: String?
    let onSave: (TunnelProfile) -> String?
    let onCancel: () -> Void

    /// 编辑期间只持有草稿，确定保存才改变持久化配置。
    init(profile: TunnelProfile, onSave: @escaping (TunnelProfile) -> String?, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: profile)
        _portText = State(initialValue: profile.connection.port.map(String.init) ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("主机配置").font(.title2).fontWeight(.semibold)
            Form {
                TextField("显示名称", text: $draft.name)
                TextField("SSH 主机或别名", text: $draft.connection.hostname)
                TextField("用户名（可选）", text: $draft.connection.username)
                TextField("SSH 端口（可选）", text: $portText)
                HStack {
                    TextField("密钥文件（可选）", text: $draft.connection.identityFile)
                    Button("选择…", action: chooseIdentity)
                }
            }
            .textFieldStyle(RoundedBorderTextFieldStyle())
            Text("例如 ty-ubuntu。用户名、端口和密钥留空时，沿用现有 SSH 配置。首版使用已配置的密钥或 SSH Agent 登录。")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("连接状态变化时发送系统通知", isOn: $draft.notifyOnChange)
            Toggle("应用启动时自动连接", isOn: $draft.autoConnect)
            if let error = error {
                Text(error).foregroundColor(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    /// 先检查表单输入，再交由模型保存；保存失败时保留草稿。
    private func save() {
        let port = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if port.isEmpty {
            draft.connection.port = nil
        } else if let value = Int(port), (1...65535).contains(value) {
            draft.connection.port = value
        } else {
            error = "SSH 端口必须是 1～65535 之间的整数。"
            return
        }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.connection.hostname = draft.connection.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.connection.username = draft.connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.connection.identityFile = draft.connection.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try draft.validate()
            error = onSave(draft)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 使用系统文件选择器保存路径，不读取或保存私钥内容。
    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.connection.identityFile = url.path
        }
    }
}

private struct ForwardEditor: View {
    @State private var draft: ForwardRule
    @State private var localPort: String
    @State private var remotePort: String
    @State private var error: String?
    let onSave: (ForwardRule) -> String?
    let onCancel: () -> Void

    /// 端口先以文本编辑，保存时再验证，避免输入中途改变连接。
    init(rule: ForwardRule, onSave: @escaping (ForwardRule) -> String?, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: rule)
        _localPort = State(initialValue: String(rule.localPort))
        _remotePort = State(initialValue: String(rule.remotePort))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("本地端口转发").font(.title2).fontWeight(.semibold)
            TextField("备注（可选，如 Redis 开发库）", text: $draft.name)
            GroupBox(label: Text("这台 Mac 的入口")) {
                Form {
                    TextField("监听地址", text: $draft.bindAddress)
                    TextField("本地端口", text: $localPort)
                }.padding(8)
            }
            GroupBox(label: Text("SSH 服务器上的目标")) {
                Form {
                    TextField("目标地址", text: $draft.remoteHost)
                    TextField("目标端口", text: $remotePort)
                }.padding(8)
            }
            Toggle("启用这条转发", isOn: $draft.isEnabled)
            Text("目标地址从 SSH 服务器访问。保存后只调整这条规则，其他端口保持连接。")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = error {
                Text(error).foregroundColor(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .padding(24)
        .frame(width: 500)
    }

    /// 校验单条规则后提交，端口占用等运行时错误由主界面显示。
    private func save() {
        guard let local = Int(localPort.trimmingCharacters(in: .whitespacesAndNewlines)),
              let remote = Int(remotePort.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(local), (1...65535).contains(remote) else {
            error = "本地端口和目标端口必须是 1～65535 之间的整数。"
            return
        }
        draft.localPort = local
        draft.remotePort = remote
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.bindAddress = draft.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.remoteHost = draft.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try draft.validate()
            error = onSave(draft)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension ConnectionPhase {
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }
}

private extension ForwardPhase {
    var color: Color {
        switch self {
        case .listening: return .green
        case .failed: return .red
        case .disabled, .waiting: return .gray
        }
    }
}
