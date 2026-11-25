// ClaudeBell 설정 창 — 앱을 직접 열면(--message 없이) 뜬다.
// 고른 이미지·노래는 ~/.claude/bell/assets 로 복사해 두고 config.json 에 그 경로를 쓴다(원본을 옮겨도 안 깨진다).
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

let configURL = URL(fileURLWithPath: ("~/.claude/bell/config.json" as NSString).expandingTildeInPath)
let assetsURL = URL(fileURLWithPath: ("~/.claude/bell/assets" as NSString).expandingTildeInPath)

func existingPath(_ path: String?) -> String? {
  guard let path = expandPath(path), FileManager.default.fileExists(atPath: path) else { return nil }
  return path
}

final class SettingsModel: ObservableObject {
  static let maxImages = 5

  @Published var imagePaths: [String] { didSet { save() } }
  @Published var soundPath: String? { didSet { stopPreview(); save() } }
  @Published var isMuted: Bool { didSet { if isMuted { stopPreview() }; save() } }
  @Published var displaySeconds: Double { didSet { save() } }
  @Published var playsFullSong: Bool { didSet { save() } }
  @Published var playSeconds: Double { didSet { save() } }
  @Published var isPreviewing = false

  private var previewPlayer: AVAudioPlayer?

  init() {
    let config = loadConfig()
    imagePaths = config.imagePaths
    soundPath = existingPath(config.sound)
    isMuted = config.muted ?? false
    displaySeconds = config.displaySeconds ?? 6
    playsFullSong = config.playSeconds == nil
    playSeconds = config.playSeconds ?? 8
  }

  var soundName: String { soundPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "기본 효과음 (Glass)" }
  var canAddImage: Bool { imagePaths.count < SettingsModel.maxImages }

  /// 여러 장을 한 번에 골라도 남은 자리(최대 5장)만큼만 넣는다
  func addImages() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }

    try? FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    let room = SettingsModel.maxImages - imagePaths.count
    var added: [String] = []
    for source in panel.urls.prefix(room) {
      let name = "character-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
      let destination = assetsURL.appendingPathComponent(name)
      do {
        try FileManager.default.copyItem(at: source, to: destination)
        added.append(destination.path)
      } catch {
        NSAlert(error: error).runModal()
      }
    }
    imagePaths += added
    if panel.urls.count > room {
      let alert = NSAlert()
      alert.messageText = "이미지는 \(SettingsModel.maxImages)장까지 넣을 수 있어요"
      alert.informativeText = "앞에서부터 \(room)장만 넣었어요."
      alert.runModal()
    }
  }

  func removeImage(_ path: String) {
    imagePaths.removeAll { $0 == path }
    // assets 에 복사해 둔 파일만 지운다
    if path.hasPrefix(assetsURL.path) { try? FileManager.default.removeItem(atPath: path) }
  }

  func pickSound() {
    if let path = pickFile(types: [.audio], baseName: "song") { soundPath = path }
  }

  func togglePreview() {
    if isPreviewing { stopPreview(); return }
    guard let soundPath, let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: soundPath)) else {
      NSSound(named: "Glass")?.play()
      return
    }
    previewPlayer = player
    player.play()
    isPreviewing = true
    let seconds = playsFullSong ? player.duration : playSeconds
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak player] in
      guard let self, player === self.previewPlayer else { return }
      self.stopPreview()
    }
  }

  func stopPreview() {
    previewPlayer?.stop()
    previewPlayer = nil
    isPreviewing = false
  }

  func testNotify() {
    stopPreview()
    NotificationCenter.default.post(name: .bellTest, object: nil)
  }

  private func pickFile(types: [UTType], baseName: String) -> String? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = types
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let source = panel.url else { return nil }

    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    // 같은 종류의 이전 파일은 지운다 (character.png → character.jpg 로 바뀌어도 하나만 남게)
    let old = (try? fileManager.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil)) ?? []
    old.filter { $0.deletingPathExtension().lastPathComponent == baseName }.forEach { try? fileManager.removeItem(at: $0) }

    let destination = assetsURL.appendingPathComponent(baseName).appendingPathExtension(source.pathExtension.lowercased())
    do {
      try fileManager.copyItem(at: source, to: destination)
      return destination.path
    } catch {
      NSAlert(error: error).runModal()
      return nil
    }
  }

  private func save() {
    var json: [String: Any] = ["displaySeconds": displaySeconds, "muted": isMuted]
    json["images"] = imagePaths
    if let soundPath { json["sound"] = soundPath }
    if !playsFullSong { json["playSeconds"] = playSeconds }
    guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: configURL)
  }
}

struct SettingsView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    Form {
      Section {
        HStack(spacing: 10) {
          if model.imagePaths.isEmpty {
            Text("🔔").font(.system(size: 44)).frame(width: 68, height: 68)
            Text("이미지가 없으면 🔔가 나와요").foregroundStyle(.secondary)
          }
          ForEach(model.imagePaths, id: \.self) { path in
            ZStack(alignment: .topTrailing) {
              Group {
                if let image = NSImage(contentsOfFile: path) {
                  Image(nsImage: image).resizable().scaledToFit()
                } else {
                  Text("?").foregroundStyle(.secondary)
                }
              }
              .frame(width: 68, height: 68)
              .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

              Button { model.removeImage(path) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
              }
              .buttonStyle(.plain)
              .help("빼기")
              .offset(x: 6, y: -6)
            }
          }
        }
        HStack {
          Button("이미지 추가… (\(model.imagePaths.count)/\(SettingsModel.maxImages))") { model.addImages() }
            .disabled(!model.canAddImage)
          Spacer()
        }
      } header: {
        Text("이미지")
      } footer: {
        Text("알림마다 이 중 한 장이 무작위로 나와요").font(.footnote).foregroundStyle(.secondary)
      }

      Section("노래") {
        Toggle("무음 — 말풍선만 띄우고 소리는 내지 않아요", isOn: $model.isMuted)
        Group {
          Text(model.soundName).foregroundStyle(.secondary)
          HStack {
            Button("노래 선택…") { model.pickSound() }
            Button(model.isPreviewing ? "정지" : "미리 듣기") { model.togglePreview() }
            Button("기본으로") { model.soundPath = nil }.disabled(model.soundPath == nil)
          }
          Toggle("끝까지 재생", isOn: $model.playsFullSong)
          if !model.playsFullSong {
            Stepper("재생 시간 \(Int(model.playSeconds))초", value: $model.playSeconds, in: 1...60)
          }
        }
        .disabled(model.isMuted)
      }

      Section("말풍선") {
        Stepper("떠 있는 시간 \(Int(model.displaySeconds))초", value: $model.displaySeconds, in: 2...30)
      }

      HStack {
        Text("바꾸면 바로 저장돼요").font(.footnote).foregroundStyle(.secondary)
        Spacer()
        Button("테스트 알림") { model.testNotify() }.keyboardShortcut(.defaultAction)
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize()
  }
}

final class SettingsWindowController {
  private var window: NSWindow?
  private let model = SettingsModel()

  func syncMuted(_ muted: Bool) {
    if model.isMuted != muted { model.isMuted = muted }
  }

  func show() {
    if let window {
      NSApp.setActivationPolicy(.regular)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let hosting = NSHostingView(rootView: SettingsView(model: model))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "ClaudeBell 설정"
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    window.center()
    // 설정 창을 닫으면 Dock 아이콘을 다시 숨긴다 (메뉴 막대에는 남는다)
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      self?.model.stopPreview()
      NSApp.setActivationPolicy(.accessory)
    }
    self.window = window
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
