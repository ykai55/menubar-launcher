import SwiftUI
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var model: LauncherModel
    @State private var baseline: PreferencesDraft
    @State private var draft: PreferencesDraft
    @State private var error: String?
    @State private var saved = false
    @State private var trusted = AXIsProcessTrusted()
    @State private var selectedTab = 0
    let close: () -> Void

    init(model: LauncherModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        let preferences = PreferencesDraft(model.config, mode: model.mode)
        _baseline = State(initialValue: preferences)
        _draft = State(initialValue: preferences)
    }

    private var language: AppLanguage { draft.language }

    var body: some View {
        VStack(spacing: 0) {
            Picker(language.text("Settings", "设置"), selection: $selectedTab) {
                Text(language.text("General", "通用")).tag(0)
                Text(language.text("Shortcuts", "快捷键")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: 240).padding(.top, 20).padding(.bottom, 8)
            Group {
                if selectedTab == 0 { general } else { shortcuts }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if !model.failedShortcuts.isEmpty {
                    Text(language.text("Could not register these shortcuts; they may be in use: ",
                                       "以下快捷键注册失败，可能已被占用：") + model.failedShortcuts.joined(separator: ", "))
                        .foregroundStyle(.orange)
                }
                HStack {
                    if saved { Label(language.text("Saved", "已保存"), systemImage: "checkmark").foregroundStyle(.secondary) }
                    Spacer()
                    Button(language.text("Cancel", "取消"), action: close).keyboardShortcut(.cancelAction)
                    Button(language.text("Save", "保存"), action: save)
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == baseline)
                }
            }
            .font(.system(size: 12))
            .padding(16)
        }
        .frame(width: 580, height: 540)
        .onChange(of: draft) { saved = false; error = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    private var general: some View {
        Form {
            Section {
                Picker(language.text("Language", "语言"), selection: $draft.language) {
                    Text(language.text("Follow system", "跟随系统")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("简体中文").tag(AppLanguage.chinese)
                }
                Text(language.text("Applies after saving. App and folder names keep their original language.",
                                   "保存后立即生效。应用名和自定义目录名保持原样。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(language.text("Record usage locally", "在本机记录使用情况"), isOn: $draft.recordUsage)
                Text(language.text("Records panel opens and app launches in usage.jsonl. Nothing is uploaded and your layout stays fixed.",
                                   "将面板打开和应用启动记录到 usage.jsonl，不上传，也不会自动调整应用顺序。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(language.text("Browse mode", "浏览模式"), selection: $draft.mode) {
                    Text(BrowseMode.custom.title(language)).tag(BrowseMode.custom)
                    Text(BrowseMode.sorted.title(language)).tag(BrowseMode.sorted)
                }
                .pickerStyle(.segmented)
                Text(language.text("Custom keeps your folders and order. A–Z lists apps by name.",
                                   "定制模式保留目录和手动排序；顺序模式按名称或拼音排列应用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(language.text("Configuration", "配置文件")) {
                Text(ConfigStore.url.path).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button(language.text("Open config…", "打开配置文件…")) { model.openConfig() }
                    Button(language.text("Rescan apps", "重新扫描应用")) { model.reload() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(language.text("Keyboard shortcuts", "键盘快捷键")).font(.headline)
                    Spacer()
                    Button(language.text("Use ⌥Space", "使用 ⌥Space")) {
                        draft.hotkeys = Shortcut.defaults.joined(separator: "\n")
                    }
                }
                Text(language.text("One per line, e.g. option+space or command+shift+l. Leave blank to disable. Only F1–F20 work without modifiers.",
                                   "每行一个，例如 option+space 或 command+shift+l。留空关闭。只有 F1–F20 可以不带修饰键。"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.hotkeys)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70).border(Color.secondary.opacity(0.3))
                    .accessibilityLabel(language.text("Keyboard shortcuts", "键盘快捷键"))
                Divider()
                HStack {
                    Text(language.text("Mouse buttons", "鼠标触发")).font(.headline)
                    Spacer()
                    Button(language.text("Add", "添加")) {
                        draft.mouse.append(MousePreference(button: "back", modifiers: ""))
                    }
                }
                Text(language.text("Button: back / forward / middle / number. Modifiers: command+option+control+shift (optional). Matching clicks are consumed.",
                                   "按键：back / forward / middle / 编号。修饰键可填 command+option+control+shift 的组合，也可留空。匹配的点击会被拦截。"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($draft.mouse) { $row in
                    HStack {
                        TextField(language.text("Button", "按键"), text: $row.button).frame(width: 100)
                        TextField(language.text("Modifiers (optional)", "修饰键（可选）"), text: $row.modifiers)
                        Button {
                            draft.mouse.removeAll { $0.id == row.id }
                        } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel(language.text("Remove mouse binding", "移除鼠标触发"))
                    }.textFieldStyle(.roundedBorder)
                }
                if draft.mouse.isEmpty {
                    Text(language.text("No mouse triggers", "未启用鼠标触发")).foregroundStyle(.secondary)
                }
                Divider()
                Text(trusted ? language.text("Accessibility access granted", "已获得辅助功能权限")
                             : language.text("Mouse triggers need Accessibility access", "鼠标触发需要辅助功能权限"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(language.text("Open Accessibility Settings…", "打开辅助功能设置…")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }.padding(16)
        }
    }

    private func save() {
        do {
            try model.savePreferences(draft, baseline: baseline)
            let current = PreferencesDraft(model.config, mode: model.mode)
            baseline = current
            draft = current
            error = nil
            // Set after onChange has processed the refreshed draft.
            DispatchQueue.main.async { saved = true }
        } catch {
            self.error = ConfigStore.describe(error, language: language)
        }
    }
}
