import Cocoa
import FlutterMacOS
import Sparkle
import VideoToolbox

class MainFlutterWindow: NSWindow {
  private var updater: UpdaterBridge?
  private var video: VideoDecoderBridge?

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
      if installNow != nil { return result(true) }
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
