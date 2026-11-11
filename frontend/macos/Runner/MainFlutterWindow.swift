import Cocoa
import FlutterMacOS
import Sparkle
import VideoToolbox
import WebKit

class MainFlutterWindow: NSWindow {
  private var updater: UpdaterBridge?
  private var video: VideoDecoderBridge?
  private var webviews: WebviewBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // AppKit saves and restores the size and position under this name.
    self.setFrameAutosaveName("EveryAIMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    updater = UpdaterBridge(messenger: flutterViewController.engine.binaryMessenger)
    let registrar = flutterViewController.registrar(forPlugin: "EveryAIVideoDecoder")
    video = VideoDecoderBridge(messenger: registrar.messenger, textures: registrar.textures)
    webviews = WebviewBridge(messenger: flutterViewController.engine.binaryMessenger, window: self,
                             flutterView: flutterViewController.view)

    super.awakeFromNib()
  }
}

/// In-place updates through Sparkle, driven from Dart (`lib/features/updates/data/sparkle_updater.dart`).
///
/// Dart picks the release (its channel setting decides pre-releases) and hands over that release's appcast; Sparkle
/// downloads it quietly, checks the EdDSA signature (SUPublicEDKey) and the code signature, and holds the install.
/// "Restart to update" in the app runs the held install, which swaps the bundle and relaunches. Unsigned or
/// differently signed builds report themselves unavailable and never update.
final class UpdaterBridge: NSObject, SPUUpdaterDelegate {
  /// The team the release is signed by; any other signature (a local or dev build) turns updates off.
  private static let releaseTeam = "2MGLZ5685D"
  private static let feedKey = "EveryAIUpdateFeed"

  private let channel: FlutterMethodChannel
  private var controller: SPUStandardUpdaterController?
  private var installNow: (() -> Void)?
  private var readyVersion = ""

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "everyai/updater", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "available":
      result(UpdaterBridge.signedByReleaseTeam())
    case "check":
      guard UpdaterBridge.signedByReleaseTeam() else { return result(false) }
      if let feed = (call.arguments as? [String: Any])?["feed"] as? String {
        UserDefaults.standard.set(feed, forKey: UpdaterBridge.feedKey)
      }
      if controller == nil {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
          try controller!.updater.start()
        } catch {
          controller = nil
          return result(FlutterError(code: "start", message: error.localizedDescription, details: nil))
        }
        controller!.updater.automaticallyChecksForUpdates = true
        controller!.updater.automaticallyDownloadsUpdates = true
      }
      // Already downloaded: say so again, so the app doesn't wait for an answer that never comes.
      if installNow != nil {
        channel.invokeMethod("ready", arguments: ["version": readyVersion])
        return result(true)
      }
      controller!.updater.checkForUpdatesInBackground()
      result(true)
    case "installNow":
      guard let install = installNow else { return result(false) }
      result(true)
      install()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    UserDefaults.standard.string(forKey: UpdaterBridge.feedKey)
  }

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock: @escaping () -> Void
  ) -> Bool {
    installNow = immediateInstallationBlock
    readyVersion = item.displayVersionString
    channel.invokeMethod("ready", arguments: ["version": item.displayVersionString])
    return true
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    channel.invokeMethod("none", arguments: nil)
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    let e = error as NSError
    // "No update" also arrives here as an error code; it isn't a failure.
    if e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue) { return }
    channel.invokeMethod("error", arguments: error.localizedDescription)
  }

  private static func signedByReleaseTeam() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
      == errSecSuccess, let dict = info as? [String: Any]
    else { return false }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String == releaseTeam
  }
}

/// H.264 decoding for live device views (an Android device's scrcpy stream), from Dart
/// (`lib/features/code/live/h264_texture.dart`): `create` returns a texture id, `decode {id, data, config}` takes one
/// Annex-B packet (config = the SPS/PPS packet), `dispose {id}`. Frames are decoded by VideoToolbox into BGRA pixel
/// buffers that Flutter draws as a Texture; Dart hears `size {id, width, height}` when the picture's size changes.
final class VideoDecoderBridge {
  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private var decoders: [Int64: H264Texture] = [:]

  init(messenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
    channel = FlutterMethodChannel(name: "everyai/h264", binaryMessenger: messenger)
    self.textures = textures
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "create":
      let texture = H264Texture()
      let id = textures.register(texture)
      texture.onFrame = { [weak self] size in
        guard let self else { return }
        self.textures.textureFrameAvailable(id)
        if let size {
          DispatchQueue.main.async {
            self.channel.invokeMethod("size", arguments: ["id": id, "width": size.0, "height": size.1])
          }
        }
      }
      decoders[id] = texture
      result(id)
    case "decode":
      guard let id = (args?["id"] as? NSNumber)?.int64Value, let texture = decoders[id],
        let data = args?["data"] as? FlutterStandardTypedData
      else { return result(FlutterError(code: "bad_args", message: "decode needs id and data", details: nil)) }
      texture.feed(data.data, config: (args?["config"] as? Bool) ?? false)
      result(nil)
    case "dispose":
      if let id = (args?["id"] as? NSNumber)?.int64Value, let texture = decoders.removeValue(forKey: id) {
        texture.close()
        textures.unregisterTexture(id)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// One H.264 stream decoded into the latest frame Flutter draws.
final class H264Texture: NSObject, FlutterTexture {
  /// A frame is ready; the picture's new size when it changed.
  var onFrame: (((Int, Int)?) -> Void)?

  private let queue = DispatchQueue(label: "everyai.h264")
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var parameterSets: [Data] = []
  private var size: (Int, Int)?

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func feed(_ packet: Data, config: Bool) {
    queue.async { self.decode(packet, config: config) }
  }

  func close() {
    queue.sync {
      if let session { VTDecompressionSessionInvalidate(session) }
      session = nil
      onFrame = nil
    }
  }

  /// The NAL units of an Annex-B packet (start codes 00 00 01 or 00 00 00 01).
  static func nalUnits(_ data: Data) -> [Data] {
    let bytes = [UInt8](data)
    var units: [Data] = []
    var start = -1
    var i = 0
    while i + 2 < bytes.count {
      if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
        if start >= 0 {
          var end = i
          if end > start, bytes[end - 1] == 0 { end -= 1 }
          units.append(Data(bytes[start..<end]))
        }
        start = i + 3
        i += 3
      } else {
        i += 1
      }
    }
    if start >= 0, start < bytes.count { units.append(Data(bytes[start...])) }
    return units
  }

  private func decode(_ packet: Data, config: Bool) {
    let units = H264Texture.nalUnits(packet)
    let sets = units.filter { let t = $0.first.map { $0 & 0x1F } ?? 0; return t == 7 || t == 8 }
    if !sets.isEmpty, sets != parameterSets {
      parameterSets = sets
      makeSession()
    }
    if config { return }
    let frames = units.filter { let t = $0.first.map { $0 & 0x1F } ?? 0; return t != 7 && t != 8 }
    guard !frames.isEmpty, let session, let format else { return }
    // AVCC: each unit with a 4-byte big-endian length instead of a start code.
    var avcc = Data()
    for unit in frames {
      var length = UInt32(unit.count).bigEndian
      avcc.append(Data(bytes: &length, count: 4))
      avcc.append(unit)
    }
    var block: CMBlockBuffer?
    let count = avcc.count
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == noErr,
      let block
    else { return }
    let copied = avcc.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
    }
    guard copied == noErr else { return }
    var sample: CMSampleBuffer?
    var sizes = [count]
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
        sampleBufferOut: &sample) == noErr,
      let sample
    else { return }
    VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      [weak self] status, _, image, _, _ in
      guard let self, status == noErr, let image else { return }
      let size = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
      self.lock.lock()
      self.latest = image
      let changed = self.size.map { $0 != size } ?? true
      self.size = size
      self.lock.unlock()
      self.onFrame?(changed ? size : nil)
    }
  }

  private func makeSession() {
    if let session { VTDecompressionSessionInvalidate(session) }
    session = nil
    format = nil
    guard let sps = parameterSets.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
      let pps = parameterSets.first(where: { ($0.first ?? 0) & 0x1F == 8 })
    else { return }
    var desc: CMFormatDescription?
    let status = sps.withUnsafeBytes { s in
      pps.withUnsafeBytes { p in
        let pointers = [
          s.baseAddress!.assumingMemoryBound(to: UInt8.self), p.baseAddress!.assumingMemoryBound(to: UInt8.self),
        ]
        let lengths = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
          parameterSetSizes: lengths, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
      }
    }
    guard status == noErr, let desc else { return }
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var created: VTDecompressionSession?
    guard
      VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault, formatDescription: desc, decoderSpecification: nil,
        imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
        decompressionSessionOut: &created) == noErr
    else { return }
    format = desc
    session = created
  }
}

/// What the webview plugin doesn't give the Code session browser (`lib/features/code/live/webview_native.dart`):
/// each session's cookie store, keeping a webview the Preview let go of live in the window, keeping keys away from a
/// view the agent has, the browser shortcuts typed in a view, and "Ask the agent about this" in its context menu.
/// A webview is found by a token its page carries in the "everyai" script world, which the Dart side sets just
/// before [bind].
final class WebviewBridge: NSObject {
  static weak var shared: WebviewBridge?

  private let channel: FlutterMethodChannel
  fileprivate weak var window: NSWindow?
  private weak var flutterView: NSView?
  private var views: [String: WKWebView] = [:]
  private var locked = Set<String>()
  private var shown = Set<String>()
  private var monitor: Any?
  private let world = WKContentWorld.world(name: "everyai")

  /// Holds parked views: in the window's frame view, under the Flutter view (which covers them and takes every
  /// click), at full opacity, so WebKit counts them as visible and runs their pages at full speed.
  private lazy var parking: NSView = {
    let v = NSView(frame: .zero)
    v.autoresizingMask = [.width, .height]
    return v
  }()

  init(messenger: FlutterBinaryMessenger, window: NSWindow, flutterView: NSView) {
    channel = FlutterMethodChannel(name: "everyai/webview", binaryMessenger: messenger)
    self.window = window
    self.flutterView = flutterView
    super.init()
    WebviewBridge.shared = self
    WebviewBridge.addMenuHook()
    WebviewBridge.addWindowLending()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self else { return event }
      return self.filter(event)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    let token = a["token"] as? String ?? ""
    switch call.method {
    case "bind":
      bind(token, viewId: a["viewId"] as? String, result)
    case "release":
      views[token] = nil
      locked.remove(token)
      shown.remove(token)
      result(nil)
    case "cookies":
      guard let store = views[token]?.configuration.websiteDataStore.httpCookieStore else { return result([]) }
      store.getAllCookies { cookies in result(cookies.map(WebviewBridge.cookieMap)) }
    case "setCookies":
      guard let store = views[token]?.configuration.websiteDataStore.httpCookieStore else { return result(nil) }
      let list = (a["cookies"] as? [[String: Any]] ?? []).compactMap(WebviewBridge.cookie)
      let group = DispatchGroup()
      for c in list {
        group.enter()
        store.setCookie(c) { group.leave() }
      }
      group.notify(queue: .main) { result(nil) }
    case "deleteCookies":
      guard let store = views[token]?.configuration.websiteDataStore.httpCookieStore else { return result(nil) }
      let wanted = (a["cookies"] as? [[String: Any]] ?? []).map {
        "\($0["name"] ?? "")|\($0["domain"] ?? "")|\($0["path"] ?? "/")"
      }
      store.getAllCookies { cookies in
        let group = DispatchGroup()
        for c in cookies where wanted.contains("\(c.name)|\(c.domain)|\(c.path)") {
          group.enter()
          store.delete(c) { group.leave() }
        }
        group.notify(queue: .main) { result(nil) }
      }
    case "clearData":
      guard let store = views[token]?.configuration.websiteDataStore else { return result(nil) }
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
        result(nil)
      }
    case "lend":
      WebviewBridge.lending = max(0, WebviewBridge.lending + (a["on"] as? Bool == true ? 1 : -1))
      result(nil)
    case "debug":
      WebviewBridge.debug = a["on"] as? Bool == true
      result(nil)
    case "park":
      park(token, width: a["width"] as? Int ?? 1280, height: a["height"] as? Int ?? 800, attempt: 0, result)
    case "unfocus":
      unfocus(token)
      result(nil)
    case "lock":
      if a["locked"] as? Bool == true {
        locked.insert(token)
        unfocus(token)
      } else {
        locked.remove(token)
      }
      result(nil)
    case "shown":
      if a["shown"] as? Bool == true { shown.insert(token) } else { shown.remove(token) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func bind(_ token: String, viewId: String?, _ result: @escaping FlutterResult) {
    if views[token] != nil { return result(true) }
    var all: [WKWebView] = []
    func walk(_ v: NSView) {
      if let w = v as? WKWebView { all.append(w) }
      for s in v.subviews { walk(s) }
    }
    // From the frame view: parked views sit beside the content view.
    for w in NSApp.windows { if let c = w.contentView { walk(c.superview ?? c) } }
    // The plugin's own id for the view (internal to it, read by reflection): exact, whatever page it shows.
    if let viewId, let w = all.first(where: { pluginId(of: $0) == viewId }) {
      views[token] = w
      return result(true)
    }
    let group = DispatchGroup()
    var found: WKWebView?
    for w in all where !views.values.contains(where: { $0 === w }) {
      group.enter()
      w.evaluateJavaScript("window.__everyaiToken || ''", in: nil, in: world) { r in
        if case .success(let v) = r, let s = v as? String, s == token { found = w }
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      if WebviewBridge.debug {
        print("EVERYAI bind \(token): \(all.count) views, found=\(found != nil) in \(NSApp.windows.count) windows")
      }
      if let f = found { self?.views[token] = f }
      result(found != nil)
    }
  }

  /// The view's container (the plugin's view) goes into [parking]: a headless view the plugin left in its own
  /// nearly transparent holder at once, a view the Preview let go of once the engine has (it leaves the window a frame
  /// after the widget goes); tried for up to three seconds.
  private func park(_ token: String, width: Int, height: Int, attempt: Int, _ result: @escaping FlutterResult) {
    guard let wv = views[token], let window = window, let content = window.contentView,
          let frameView = content.superview else { return result(false) }
    let container = wv.superview ?? wv
    let size = NSRect(x: 0, y: 0, width: width, height: height)
    if container.superview === parking {
      container.frame = size
      return result(true)
    }
    let holder = container.superview
    let headless = holder != nil && holder!.frame.size == .zero && holder!.superview === content
    if container.window != nil && !headless {
      // Still on screen: the engine hasn't let go yet, or the Preview shows it again.
      if attempt >= 60 {
        if WebviewBridge.debug {
          print("EVERYAI park \(token) gave up: holder=\(String(describing: holder.map { type(of: $0) })) hidden=\(container.isHiddenOrHasHiddenAncestor) chain=\(chain(container))")
        }
        return result(false)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.park(token, width: width, height: height, attempt: attempt + 1, result)
      }
      return
    }
    if parking.superview == nil {
      parking.frame = content.frame
      frameView.addSubview(parking, positioned: .below, relativeTo: content)
    }
    container.removeFromSuperview()
    container.alphaValue = 1
    container.frame = size
    parking.addSubview(container)
    if headless { holder?.removeFromSuperview() }
    if WebviewBridge.debug {
      print("EVERYAI park \(token) parked (headless=\(headless), attempt \(attempt))")
    }
    result(true)
  }

  /// The `id` the plugin gives its webview (its headless id or platform view id).
  private func pluginId(of w: WKWebView) -> String? {
    for child in Mirror(reflecting: w).children where child.label == "id" {
      // `Any?` holding a String (headless) or a number (a platform view).
      if let s = child.value as? String { return s }
      if let o = child.value as? String? { return o }
      return String(describing: child.value)
    }
    return nil
  }

  private func chain(_ v: NSView) -> String {
    var out: [String] = []
    var at: NSView? = v
    while let x = at {
      out.append("\(type(of: x))\(x.isHidden ? "[h]" : "")\(x.frame.size == .zero ? "[0]" : "")")
      at = x.superview
    }
    return out.joined(separator: " < ")
  }

  private func unfocus(_ token: String) {
    guard let wv = views[token], let w = wv.window ?? window else { return }
    if let fr = w.firstResponder as? NSView, fr === wv || fr.isDescendant(of: wv) {
      w.makeFirstResponder(flutterView)
    }
  }

  private func tokenOwning(_ view: NSView?) -> String? {
    guard let view = view else { return nil }
    return views.first(where: { view === $0.value || view.isDescendant(of: $0.value) })?.key
  }

  /// Keys typed in a session view: kept from it while the agent has it; the browser's own shortcuts go to Dart.
  private func filter(_ event: NSEvent) -> NSEvent? {
    // Posted events may carry no window: the key window's first responder gets them.
    let target = (event.window ?? NSApp.keyWindow ?? window)?.firstResponder as? NSView
    guard let token = tokenOwning(target) else { return event }
    if WebviewBridge.debug {
      print("EVERYAI key \(event.type.rawValue) responder=\(String(describing: target.map { type(of: $0) })) locked=\(locked.contains(token))")
    }
    if locked.contains(token) {
      if event.type == .keyDown { channel.invokeMethod("blocked", arguments: ["token": token]) }
      return nil
    }
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.type == .keyDown, shown.contains(token), mods.contains(.command), !mods.contains(.option),
       let key = event.charactersIgnoringModifiers?.lowercased(), ["l", "r", "[", "]", "f"].contains(key) {
      channel.invokeMethod("shortcut", arguments: ["token": token, "key": key])
      return nil
    }
    return event
  }

  /// Adds "Ask the agent about this" to the context menu of a session view the user has.
  fileprivate func extend(menu: NSMenu, of view: WKWebView, event: NSEvent) {
    guard let token = tokenOwning(view), shown.contains(token), !locked.contains(token) else { return }
    let p = view.convert(event.locationInWindow, from: nil)
    let y = view.isFlipped ? p.y : view.bounds.height - p.y
    let item = NSMenuItem(title: "Ask the agent about this", action: #selector(ask(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = ["token": token, "x": Double(p.x), "y": Double(y)]
    menu.addItem(.separator())
    menu.addItem(item)
  }

  @objc private func ask(_ sender: NSMenuItem) {
    channel.invokeMethod("ask", arguments: sender.representedObject)
  }

  /// While above zero, `NSApp.mainWindow` is this window even when the app isn't active: the plugin puts a new
  /// headless webview in the main window, and with none (the user is in another app) it would run in no window at
  /// all (unfindable, and throttled).
  fileprivate static var lending = 0
  private static var lendingAdded = false

  /// The live rig's trace of keys reaching session views.
  static var debug = false

  private static func addWindowLending() {
    if lendingAdded { return }
    lendingAdded = true
    let cls: AnyClass = NSApplication.self
    guard let original = class_getInstanceMethod(cls, #selector(getter: NSApplication.mainWindow)),
          let ours = class_getInstanceMethod(cls, #selector(getter: NSApplication.everyaiMainWindow)) else { return }
    method_exchangeImplementations(original, ours)
  }

  private static var hooked = false

  /// WKWebView's `willOpenMenu(_:with:)` also lets the bridge add its item (views of other features are left as
  /// they are: [extend] only touches bound session views).
  private static func addMenuHook() {
    if hooked { return }
    hooked = true
    let cls: AnyClass = WKWebView.self
    let sel = #selector(NSView.willOpenMenu(_:with:))
    guard let method = class_getInstanceMethod(cls, sel) else { return }
    typealias Fn = @convention(c) (AnyObject, Selector, NSMenu, NSEvent) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
    let block: @convention(block) (AnyObject, NSMenu, NSEvent) -> Void = { obj, menu, event in
      original(obj, sel, menu, event)
      if let wv = obj as? WKWebView { WebviewBridge.shared?.extend(menu: menu, of: wv, event: event) }
    }
    let imp = imp_implementationWithBlock(block)
    // WKWebView may only inherit NSView's: then it gets its own, and NSView's stays as it is.
    if !class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) {
      method_setImplementation(method, imp)
    }
  }

  private static func cookieMap(_ c: HTTPCookie) -> [String: Any?] {
    var same: String?
    if let p = c.sameSitePolicy {
      same = p == .sameSiteStrict ? "Strict" : p == .sameSiteLax ? "Lax" : nil
    }
    return [
      "name": c.name,
      "value": c.value,
      "domain": c.domain,
      "path": c.path,
      "expiresMs": c.expiresDate.map { Int($0.timeIntervalSince1970 * 1000) },
      "secure": c.isSecure,
      "httpOnly": c.isHTTPOnly,
      "sameSite": same,
    ]
  }

  private static func cookie(_ m: [String: Any]) -> HTTPCookie? {
    guard let name = m["name"] as? String, let domain = m["domain"] as? String else { return nil }
    var p: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: m["value"] as? String ?? "",
      .domain: domain,
      .path: m["path"] as? String ?? "/",
    ]
    if let ms = m["expiresMs"] as? NSNumber {
      p[.expires] = Date(timeIntervalSince1970: ms.doubleValue / 1000)
    } else {
      p[.discard] = "TRUE"
    }
    if m["secure"] as? Bool == true { p[.secure] = "TRUE" }
    if m["httpOnly"] as? Bool == true { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    if let s = m["sameSite"] as? String { p[.sameSitePolicy] = s.lowercased() }
    return HTTPCookie(properties: p)
  }
}

extension NSApplication {
  /// Swapped with `mainWindow` (see `WebviewBridge.addWindowLending`): calling it calls the original.
  @objc var everyaiMainWindow: NSWindow? {
    let w = self.everyaiMainWindow
    if w == nil, WebviewBridge.lending > 0 { return WebviewBridge.shared?.window }
    return w
  }
}
