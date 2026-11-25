// ClaudeBell — 여러 Claude Code 세션을 메뉴 막대 하나에서 보고, 끝나거나 확인이 필요하면 말풍선·노래로 알린다.
// 훅(notify.sh)이 ~/.claude/bell/sessions/<세션>.json 을 쓰면 이 앱이 폴더를 지켜보다 반응한다.
// 실행: 직접 열면 설정 창, `--agent` 면 메뉴 막대만 (notify.sh 가 앱이 꺼져 있을 때 이렇게 띄운다)
import AppKit
import AVFoundation

struct BellConfig: Decodable {
  var images: [String]?
  var image: String?  // 예전 설정(한 장) 호환

  /// 실제로 있는 이미지 경로들 (최대 5장)
  var imagePaths: [String] {
    let paths = (images ?? []) + [image].compactMap { $0 }
    return Array(paths.compactMap(expandPath).filter { FileManager.default.fileExists(atPath: $0) }.prefix(5))
  }
  var sound: String?
  var displaySeconds: Double?
  var playSeconds: Double?
  var muted: Bool?
}

let configFileURL = URL(fileURLWithPath: ("~/.claude/bell/config.json" as NSString).expandingTildeInPath)

/// 설정 창이 없을 때 메뉴에서 무음만 바꾼다 (다른 값은 그대로 둔다)
func writeMuted(_ muted: Bool) {
  var json = (try? Data(contentsOf: configFileURL))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
  json["muted"] = muted
  if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: configFileURL)
  }
}

struct SessionEvent: Decodable {
  let sessionId: String
  let repo: String
  let branch: String?
  let title: String?
  let cwd: String?
  let workspace: String?  // 세션을 시작한 폴더 (VS Code 창에 열린 폴더)
  let status: String  // running | done | waiting
  let message: String?
  let updatedAt: Double

  var needsAttention: Bool { status != "running" }
  var statusIcon: String { ["running": "⏳", "done": "✅", "waiting": "🙋"][status] ?? "•" }
  var statusText: String { ["running": "작업 중", "done": "끝남", "waiting": "확인 필요"][status] ?? status }
  var defaultMessage: String { status == "waiting" ? "확인이 필요해요" : "작업이 끝났어요" }
}

extension Notification.Name {
  static let bellTest = Notification.Name("local.claudebell.test")
}

let sessionsURL = URL(fileURLWithPath: ("~/.claude/bell/sessions" as NSString).expandingTildeInPath)

func expandPath(_ path: String?) -> String? {
  guard let path, !path.isEmpty else { return nil }
  return (path as NSString).expandingTildeInPath
}

func loadConfig() -> BellConfig {
  let url = URL(fileURLWithPath: ("~/.claude/bell/config.json" as NSString).expandingTildeInPath)
  guard let data = try? Data(contentsOf: url),
        let config = try? JSONDecoder().decode(BellConfig.self, from: data) else { return BellConfig() }
  return config
}

func emojiImage(_ emoji: String, size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: size * 0.7)])
  let textSize = text.size()
  text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
  image.unlockFocus()
  return image
}

/// 지금 앞에 있는 앱의 맨 앞 창이 걸친 모니터 (VS Code 를 보고 있으면 그 화면)
func frontmostWindowScreen() -> NSScreen? {
  guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
        let window = windows.first(where: { ($0["kCGWindowOwnerPID"] as? Int32) == pid && ($0["kCGWindowLayer"] as? Int) == 0 }),
        let boundsDict = window["kCGWindowBounds"] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDict),
        let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
  // CG 좌표(주 모니터 왼쪽 위 원점) → AppKit 좌표(왼쪽 아래 원점)
  let center = NSPoint(x: bounds.midX, y: mainHeight - bounds.midY)
  return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
}

func relativeTime(_ timestamp: Double) -> String {
  let seconds = Int(Date().timeIntervalSince1970 - timestamp)
  if seconds < 60 { return "방금" }
  if seconds < 3600 { return "\(seconds / 60)분 전" }
  return "\(seconds / 3600)시간 전"
}

/// 세션 상태 파일 폴더를 지켜본다. 새로 끝났거나 확인이 필요해진 세션을 onAlert 로 알린다
final class SessionStore {
  private(set) var sessions: [SessionEvent] = []
  var onChange: (() -> Void)?
  var onAlert: ((SessionEvent) -> Void)?

  private var lastSeen: [String: Double] = [:]
  private var source: DispatchSourceFileSystemObject?
  private var timer: Timer?

  func start() {
    try? FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    reload(isInitial: true)

    let descriptor = open(sessionsURL.path, O_EVTONLY)
    if descriptor >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
      source.setEventHandler { [weak self] in self?.reload(isInitial: false) }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      self.source = source
    }
    // 폴더 감시를 놓쳐도 따라잡고, 메뉴의 "n분 전" 도 갱신한다
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload(isInitial: false) }
  }

  func reload(isInitial: Bool) {
    let fileManager = FileManager.default
    let files = (try? fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)) ?? []
    let cutoff = Date().timeIntervalSince1970 - 24 * 3600
    var loaded: [SessionEvent] = []

    for file in files where file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file),
            let event = try? JSONDecoder().decode(SessionEvent.self, from: data) else { continue }
      if event.updatedAt < cutoff {
        try? fileManager.removeItem(at: file)  // 하루 지난 세션은 정리
        continue
      }
      loaded.append(event)
    }
    loaded.sort { $0.updatedAt > $1.updatedAt }

    for event in loaded.reversed() {
      let previous = lastSeen[event.sessionId]
      if !isInitial, event.needsAttention, previous.map({ event.updatedAt > $0 }) ?? true {
        onAlert?(event)
      }
      lastSeen[event.sessionId] = event.updatedAt
    }
    sessions = loaded
    onChange?()
  }
}

/// 왼쪽(캐릭터 쪽)으로 꼬리가 난 말풍선
final class BubbleView: NSView {
  static let tail: CGFloat = 12

  override func draw(_ dirtyRect: NSRect) {
    let tail = BubbleView.tail
    let body = NSRect(x: bounds.minX + tail, y: bounds.minY, width: bounds.width - tail, height: bounds.height)
    let path = NSBezierPath(roundedRect: body, xRadius: 18, yRadius: 18)
    let tailPath = NSBezierPath()
    tailPath.move(to: NSPoint(x: body.minX + 2, y: body.midY + 10))
    tailPath.line(to: NSPoint(x: bounds.minX, y: body.midY - 2))
    tailPath.line(to: NSPoint(x: body.minX + 2, y: body.midY - 10))
    tailPath.close()
    NSColor.textBackgroundColor.setFill()
    path.fill()
    tailPath.fill()
  }
}

/// 말풍선 바탕 — 클릭하면 onClick, 좌우로 밀면(트랙패드 두 손가락·마우스 끌기) onDismiss
final class SwipeView: NSView {
  var onClick: (() -> Void)?
  var onDismiss: ((_ direction: CGFloat) -> Void)?
  /// 만지기 시작하면 자동으로 사라지는 타이머를 멈춘다
  var onInteractionStart: (() -> Void)?
  /// 덜 밀어서 제자리로 돌아오면 다시 타이머를 건다
  var onInteractionCancel: (() -> Void)?

  private let threshold: CGFloat = 60
  private var dragStart: NSPoint?
  private var originStart: NSPoint?
  private var scrollOffset: CGFloat = 0

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // 이미지·글자 위에서 눌러도 이 뷰가 받는다
  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(convert(point, from: superview)) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    dragStart = NSEvent.mouseLocation
    originStart = window?.frame.origin
    onInteractionStart?()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStart, let originStart else { return }
    window?.setFrameOrigin(NSPoint(x: originStart.x + NSEvent.mouseLocation.x - dragStart.x, y: originStart.y))
  }

  override func mouseUp(with event: NSEvent) {
    guard let start = dragStart, let origin = originStart else { return }
    dragStart = nil
    let offset = NSEvent.mouseLocation.x - start.x
    if abs(offset) < 4 {
      window?.setFrameOrigin(origin)
      onClick?()
    } else {
      settle(offset: offset, origin: origin)
    }
  }

  override func scrollWheel(with event: NSEvent) {
    guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
    if event.phase.contains(.began) {
      scrollOffset = 0
      originStart = window?.frame.origin
      onInteractionStart?()
    }
    guard let origin = originStart else { return }
    // 손가락이 움직인 방향으로 맞춘다 (자연스러운 스크롤 설정과 무관하게)
    let fingerDelta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    scrollOffset += fingerDelta
    window?.setFrameOrigin(NSPoint(x: origin.x + scrollOffset, y: origin.y))
    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      settle(offset: scrollOffset, origin: origin)
      originStart = nil
    }
  }

  private func settle(offset: CGFloat, origin: NSPoint) {
    if abs(offset) > threshold {
      onDismiss?(offset > 0 ? 1 : -1)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      window?.animator().setFrameOrigin(origin)
    }
    onInteractionCancel?()
  }
}

func makeLabel(_ text: String, font: NSFont, color: NSColor, lines: Int) -> NSTextField {
  let label = lines == 1 ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
  label.font = font
  label.textColor = color
  label.maximumNumberOfLines = lines
  label.lineBreakMode = .byTruncatingTail
  return label
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, AVAudioPlayerDelegate {
  private let store = SessionStore()
  private var statusItem: NSStatusItem!
  private var settings: SettingsWindowController?
  private var acknowledged: [String: Double] = [:]

  private var panel: NSPanel?
  private var hideWork: DispatchWorkItem?
  private var player: AVAudioPlayer?
  private var stopWork: DispatchWorkItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    store.onChange = { [weak self] in self?.updateStatusTitle() }
    store.onAlert = { [weak self] event in self?.alert(event) }
    store.start()

    NotificationCenter.default.addObserver(forName: .bellTest, object: nil, queue: .main) { [weak self] _ in
      self?.showBubble(repo: "my-project", title: "테스트 세션", message: "테스트 알림이에요", sessionId: nil)
      self?.playSound()
    }

    if !CommandLine.arguments.contains("--agent") { openSettings() }
  }

  // 이미 떠 있을 때 다시 열면 설정 창
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openSettings()
    return false
  }

  @objc private func openSettings() {
    if settings == nil { settings = SettingsWindowController() }
    settings?.show()
  }

  // MARK: 메뉴 막대

  private var attentionCount: Int {
    store.sessions.filter { $0.needsAttention && $0.updatedAt > (acknowledged[$0.sessionId] ?? 0) }.count
  }

  private func updateStatusTitle() {
    let count = attentionCount
    statusItem.button?.title = count > 0 ? "🔔 \(count)" : "🔔"
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    if store.sessions.isEmpty {
      let empty = NSMenuItem(title: "최근 24시간 세션 없음", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    }

    for event in store.sessions {
      let item = NSMenuItem(title: "", action: #selector(openSession(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = event.sessionId
      let isNew = event.needsAttention && event.updatedAt > (acknowledged[event.sessionId] ?? 0)
      let head = "\(event.statusIcon) \(event.repo) · \(event.title ?? "제목 없음")"
      let detail = "\n     \(event.statusText) · \(relativeTime(event.updatedAt))\(event.branch.map { " · \($0)" } ?? "")"
      let text = NSMutableAttributedString(string: head, attributes: [
        .font: isNew ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13),
      ])
      text.append(NSAttributedString(string: detail, attributes: [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
      ]))
      item.attributedTitle = text
      menu.addItem(item)
    }

    menu.addItem(.separator())
    menu.addItem(withTitle: "모두 확인함", action: #selector(acknowledgeAll), keyEquivalent: "").target = self
    let muteItem = NSMenuItem(title: "무음", action: #selector(toggleMute), keyEquivalent: "")
    muteItem.target = self
    muteItem.state = loadConfig().muted == true ? .on : .off
    menu.addItem(muteItem)
    menu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",").target = self
    menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }

  @objc private func openSession(_ sender: NSMenuItem) {
    guard let sessionId = sender.representedObject as? String,
          let event = store.sessions.first(where: { $0.sessionId == sessionId }) else { return }
    openWorkspace(of: event)
  }

  private func openWorkspace(of event: SessionEvent) {
    acknowledge(event)
    // 이미 열린 폴더를 열면 VS Code 가 새 창 대신 그 창으로 이동한다 — 그래서 현재 폴더가 아니라 시작 폴더를 연다
    guard let path = event.workspace ?? event.cwd else { return }
    let folder = URL(fileURLWithPath: path)
    if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
      NSWorkspace.shared.open([folder], withApplicationAt: vscode, configuration: NSWorkspace.OpenConfiguration())
    } else {
      NSWorkspace.shared.open(folder)
    }
  }

  @objc private func toggleMute() {
    let muted = loadConfig().muted != true
    if muted { stopSound() }
    // 설정 창이 열려 있으면 그 화면 값도 같이 바꾼다 (창이 저장하며 덮어쓰지 않게)
    if let settings { settings.syncMuted(muted) } else { writeMuted(muted) }
  }

  @objc private func acknowledgeAll() {
    store.sessions.forEach { acknowledged[$0.sessionId] = $0.updatedAt }
    updateStatusTitle()
  }

  private func acknowledge(_ event: SessionEvent) {
    acknowledged[event.sessionId] = event.updatedAt
    updateStatusTitle()
  }

  // MARK: 알림

  private func alert(_ event: SessionEvent) {
    showBubble(repo: event.repo, title: event.title ?? "제목 없음",
               message: event.message ?? event.defaultMessage, sessionId: event.sessionId)
    playSound()
  }

  private func showBubble(repo: String, title: String, message: String, sessionId: String?) {
    hideWork?.cancel()
    panel?.orderOut(nil)

    let config = loadConfig()
    let width: CGFloat = 440, height: CGFloat = 150, imageSize: CGFloat = 124, gap: CGFloat = 6
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let root = SwipeView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    // 클릭: 그 세션의 VS Code 창으로 이동
    root.onClick = { [weak self] in
      guard let self else { return }
      if let sessionId, let event = self.store.sessions.first(where: { $0.sessionId == sessionId }) {
        self.openWorkspace(of: event)
      }
      self.hideBubble()
      self.stopSound()
    }
    // 스와이프: 민 방향으로 밀려 나가며 닫기
    root.onDismiss = { [weak self] direction in
      self?.stopSound()
      self?.slideAway(direction: direction)
    }
    root.onInteractionStart = { [weak self] in self?.hideWork?.cancel() }
    root.onInteractionCancel = { [weak self] in self?.scheduleHide(after: 3) }

    let imageView = NSImageView(frame: NSRect(x: 0, y: (height - imageSize) / 2, width: imageSize, height: imageSize))
    imageView.imageScaling = .scaleProportionallyUpOrDown
    // 넣어 둔 이미지 중 하나를 무작위로
    imageView.image = config.imagePaths.randomElement().flatMap { NSImage(contentsOfFile: $0) } ?? emojiImage("🔔", size: imageSize)
    root.addSubview(imageView)

    let bubbleFrame = NSRect(x: imageSize + gap, y: 12, width: width - imageSize - gap, height: height - 24)
    let bubble = BubbleView(frame: bubbleFrame)
    let textX = BubbleView.tail + 16
    let textWidth = bubbleFrame.width - textX - 16

    let repoLabel = makeLabel(repo, font: .boldSystemFont(ofSize: 11), color: .secondaryLabelColor, lines: 1)
    let titleLabel = makeLabel(title, font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor, lines: 2)
    let messageLabel = makeLabel(message, font: .systemFont(ofSize: 13), color: .labelColor, lines: 2)
    titleLabel.preferredMaxLayoutWidth = textWidth
    messageLabel.preferredMaxLayoutWidth = textWidth

    // 세 줄 묶음을 말풍선 세로 가운데에 둔다 (위에서부터 repo · 세션 제목 · 문구)
    let spacing: CGFloat = 3
    let repoHeight: CGFloat = 15
    let titleHeight = min(titleLabel.fittingSize.height, 36)
    let messageHeight = min(messageLabel.fittingSize.height, 34)
    var y = (bubbleFrame.height - (repoHeight + titleHeight + messageHeight + spacing * 2)) / 2
    for (label, labelHeight) in [(messageLabel, messageHeight), (titleLabel, titleHeight), (repoLabel, repoHeight)] {
      label.frame = NSRect(x: textX, y: y, width: textWidth, height: labelHeight)
      bubble.addSubview(label)
      y += labelHeight + spacing
    }

    root.addSubview(bubble)
    panel.contentView = root

    let screen = frontmostWindowScreen()
      ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let finalOrigin = NSPoint(x: visible.maxX - width - 16, y: visible.maxY - height - 12)
    panel.setFrameOrigin(NSPoint(x: finalOrigin.x + 40, y: finalOrigin.y))
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      panel.animator().alphaValue = 1
      panel.animator().setFrameOrigin(finalOrigin)
    }
    self.panel = panel

    if FileManager.default.fileExists(atPath: ("~/.claude/bell/debug" as NSString).expandingTildeInPath) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let line = "\(Date()) visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) alpha=\(panel.alphaValue) frame=\(panel.frame) screen=\(String(describing: screen?.frame)) occlusion=\(panel.occlusionState.contains(.visible))\n"
        let url = URL(fileURLWithPath: ("~/.claude/bell/debug.log" as NSString).expandingTildeInPath)
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
      }
    }

    scheduleHide(after: config.displaySeconds ?? 6)
  }

  private func scheduleHide(after seconds: Double) {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hideBubble() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func slideAway(direction: CGFloat) {
    hideWork?.cancel()
    guard let panel else { return }
    let target = NSPoint(x: panel.frame.origin.x + direction * (panel.frame.width + 40), y: panel.frame.origin.y)
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.2
      panel.animator().setFrameOrigin(target)
      panel.animator().alphaValue = 0
    }, completionHandler: { panel.orderOut(nil) })
  }

  private func hideBubble() {
    hideWork?.cancel()
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.3
      panel.animator().alphaValue = 0
    }, completionHandler: { panel.orderOut(nil) })
  }

  private func playSound() {
    stopSound()
    let config = loadConfig()
    if config.muted == true { return }
    guard let path = expandPath(config.sound), FileManager.default.fileExists(atPath: path),
          let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
      NSSound(named: "Glass")?.play()
      return
    }
    self.player = player
    player.play()
    if let seconds = config.playSeconds {
      let work = DispatchWorkItem { [weak self, weak player] in
        player?.setVolume(0, fadeDuration: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          if self?.player === player { self?.stopSound() }
        }
      }
      stopWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
  }

  private func stopSound() {
    stopWork?.cancel()
    player?.stop()
    player = nil
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
