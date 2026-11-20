import SwiftUI
import UniformTypeIdentifiers

@main
struct IPAWorkshopApp: App {
    var body: some Scene {
        WindowGroup {
            WorkshopView()
                .environment(\.locale, Locale(identifier: "zh_TW"))
                .tint(Color(red: 0.20, green: 0.42, blue: 0.92))
        }
    }
}

private struct WorkshopView: View {
    private enum ImportKind { case ipa, image }

    @State private var package: IPAPackage?
    @State private var newName = ""
    @State private var targetImage = ""
    @State private var replacement: Data?
    @State private var replacementName = ""
    @State private var output: URL?
    @State private var busy: String?
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var picking = false
    @State private var showImages = false
    @State private var importKind: ImportKind = .ipa

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let package {
                        LabeledContent("應用程式", value: package.displayName)
                        LabeledContent("識別碼", value: package.bundleID)
                        LabeledContent("版本", value: package.version)
                        LabeledContent("來源", value: package.sourceName)
                    }
                    Button {
                        pick(.ipa)
                    } label: {
                        Label(package == nil ? "選擇 IPA" : "更換 IPA", systemImage: "folder")
                    }
                } header: {
                    Text("來源檔案")
                } footer: {
                    Text("選擇「檔案」中的已解密 IPA。檔案會在這台裝置上處理。")
                }

                if let package {
                    Section("修改項目") {
                        TextField("新 App 顯示名稱", text: $newName)
                            .onChange(of: newName) { _ in clearOutput() }
                        if !package.images.isEmpty {
                            Button {
                                showImages = true
                            } label: {
                                LabeledContent("要替換的 PNG", value: targetImage.isEmpty ? "選擇資源" : targetImage)
                            }
                            Button {
                                pick(.image)
                            } label: {
                                Label(replacementName.isEmpty ? "匯入替換 PNG" : replacementName, systemImage: "photo")
                            }
                            .disabled(targetImage.isEmpty)
                            if replacement != nil {
                                Button("取消圖片替換", role: .destructive) {
                                    clearOutput()
                                    replacement = nil
                                    replacementName = ""
                                }
                            }
                        }
                    }
                    Section {
                        Button {
                            export(package)
                        } label: {
                            Label("封裝 IPA", systemImage: "archivebox")
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replacement == nil)
                        if let output {
                            ShareLink(item: output) {
                                Label("分享或儲存 IPA", systemImage: "square.and.arrow.up")
                            }
                        }
                    } header: {
                        Text("輸出")
                    } footer: {
                        Text("安裝匯出的 IPA 前需要重新簽名。")
                    }
                }
            }
            .disabled(busy != nil)
            .navigationTitle("IPA 工坊")
            .overlay {
                if let busy {
                    ProgressView(busy)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showImages) {
                if let package {
                    ImagePicker(paths: package.images, selected: targetImage) { path in
                        if path != targetImage {
                            clearOutput()
                            targetImage = path
                            replacement = nil
                            replacementName = ""
                        }
                        showImages = false
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: importKind == .image ? [.png] : [.item]) { result in
                do {
                    let url = try result.get()
                    switch importKind {
                    case .ipa: open(url)
                    case .image: loadImage(url)
                    }
                } catch {
                    display(error)
                }
            }
            .alert("處理失敗", isPresented: $showError) {
                Button("確定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func pick(_ kind: ImportKind) {
        importKind = kind
        picking = true
    }

    private func open(_ url: URL) {
        busy = "正在檢查並解壓縮 IPA…"
        Task {
            defer { busy = nil }
            do {
                let imported = try await Task.detached(priority: .userInitiated) { try IPAPackage.open(url) }.value
                clearOutput()
                if let previous = package { try? FileManager.default.removeItem(at: previous.directory) }
                package = imported
                newName = ""
                targetImage = ""
                replacement = nil
                replacementName = ""
            } catch { display(error) }
        }
    }

    private func loadImage(_ url: URL) {
        busy = "正在讀取 PNG…"
        Task {
            defer { busy = nil }
            do {
                let image = try await Task.detached(priority: .userInitiated) { try IPAPackage.loadPNG(url) }.value
                clearOutput()
                replacement = image
                replacementName = url.lastPathComponent
            } catch { display(error) }
        }
    }

    private func export(_ package: IPAPackage) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = targetImage
        let image = replacement
        busy = "正在封裝 IPA…"
        Task {
            defer { busy = nil }
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try package.export(name: name, imagePath: path, replacement: image)
                }.value
                clearOutput()
                output = file
            } catch { display(error) }
        }
    }

    private func clearOutput() {
        if let output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        output = nil
    }

    private func display(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

private struct ImagePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let paths: [String]
    let selected: String
    let choose: (String) -> Void

    var body: some View {
        NavigationStack {
            List(query.isEmpty ? paths : paths.filter { $0.localizedCaseInsensitiveContains(query) }, id: \.self) { path in
                Button {
                    choose(path)
                } label: {
                    HStack {
                        Text(path)
                        Spacer()
                        if path == selected { Image(systemName: "checkmark") }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜尋檔名或路徑")
            .navigationTitle("PNG 資源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
