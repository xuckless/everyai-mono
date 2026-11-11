// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.
//
// everyai-ax: what the `app` tool and the Preview need to see and drive a desktop app's window on macOS, as a small
// command-line program (so it works from the app, its tests and outside agents alike). Output is JSON, or JPEG frames
// for `stream`. Reading the accessibility tree and sending input need the Accessibility permission; pictures need
// Screen Recording. Child processes count as the app that started them, so EveryAI asks for both once.
//
//   windows [--pid N]...                         the windows on screen
//   tree --pid N [--window W]                    a window's accessibility tree (W: index or title; default: main)
//   act --pid N --path P --action A [--text T | --text-stdin]   AXPress, AXIncrement, AXDecrement, AXShowMenu, AXConfirm, AXCancel,
//                                                AXRaise, focus, setvalue
//   click --pid N --x X --y Y [--count C] [--right] [--front]   a mouse click at screen point (X, Y)
//   drag --pid N --x X --y Y --to-x X2 --to-y Y2 [--front]
//   scroll --pid N --x X --y Y --dy D [--front]
//   key --pid N (--text T | --text-stdin | --keycode K) [--mods cmd,shift,alt,ctrl]
//   raise --pid N [--window W]                   brings the app and its window to the front
//   shot --window ID --out FILE                  a PNG of one window
//   stream --window ID [--fps F] [--scale S]     JPEG frames as multipart/x-mixed-replace on stdout
//   trusted [--prompt]                           {"ax": bool, "screen": bool}
//
// Input goes to the app's process (CGEvent postToPid) so the user's own cursor and keyboard focus stay put; --front
// raises the window and posts to the system instead, for apps that ignore events sent to them in the background.
// Real (--front) input is guarded: it waits while the user is using the mouse or keyboard, a pointer event goes only
// to a point where the app's own window is on top, and keys go only while the app is in front and no password field
// has secure input on (exit codes 7 and 8 say why not).

import AppKit
import Carbon
import ApplicationServices
import CoreImage
import Foundation
import ScreenCaptureKit

// MARK: arguments and output

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func value(_ name: String) -> String? {
  guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
  return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains("--\(name)") }
/// The text to type or set: from stdin with --text-stdin (a saved password never reaches the process list), else
/// --text.
func textArg() -> String? {
  if flag("text-stdin") {
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  }
  return value("text")
}
func number(_ name: String) -> Double? { value(name).flatMap(Double.init) }

func emit(_ object: Any) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
  exit(code)
}

func needPid() -> pid_t {
  guard let p = value("pid").flatMap({ pid_t($0) }) else { fail("--pid is needed") }
  return p
}

// MARK: accessibility

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
  var out: CFTypeRef?
  guard AXUIElementCopyAttributeValue(e, name as CFString, &out) == .success else { return nil }
  return out
}

func str(_ e: AXUIElement, _ name: String) -> String? {
  guard let v = attr(e, name) else { return nil }
  if let s = v as? String { return s }
  if let n = v as? NSNumber { return n.stringValue }
  return nil
}

func frame(_ e: AXUIElement) -> CGRect? {
  guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
  var point = CGPoint.zero
  var size = CGSize.zero
  AXValueGetValue(p as! AXValue, .cgPoint, &point)
  AXValueGetValue(s as! AXValue, .cgSize, &size)
  return CGRect(origin: point, size: size)
}

func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func actions(_ e: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
  return (names as? [String]) ?? []
}

func appElement(_ pid: pid_t) -> AXUIElement {
  if !AXIsProcessTrusted() { fail("EveryAI needs the Accessibility permission (System Settings > Privacy & Security)", code: 3) }
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 3)
  return app
}

/// The window [w] names (an index into the app's windows, or a title), else the main or focused one.
func window(_ app: AXUIElement, _ w: String?) -> (AXUIElement, Int)? {
  let all = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
  if let w, let i = Int(w), i >= 0, i < all.count { return (all[i], i) }
  if let w, let i = all.firstIndex(where: { (str($0, kAXTitleAttribute) ?? "") == w }) { return (all[i], i) }
  if let w, let i = all.firstIndex(where: { (str($0, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(w) }) {
    return (all[i], i)
  }
  for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
    if let m = attr(app, name), CFGetTypeID(m) == AXUIElementGetTypeID() {
      let main = m as! AXUIElement
      if let i = all.firstIndex(where: { CFEqual($0, main) }) { return (all[i], i) }
    }
  }
  return all.first.map { ($0, 0) }
}

func describe(_ e: AXUIElement, path: String) -> [String: Any] {
  var node: [String: Any] = ["path": path]
  for (key, name) in [
    ("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute),
    ("desc", kAXDescriptionAttribute), ("value", kAXValueAttribute), ("help", kAXHelpAttribute),
    ("placeholder", "AXPlaceholderValue"), ("label", "AXLabelValue"), ("identifier", "AXIdentifier"),
  ] {
    if let s = str(e, name), !s.isEmpty { node[key] = s.count > 500 ? String(s.prefix(500)) : s }
  }
  if let f = frame(e) { node["x"] = f.minX; node["y"] = f.minY; node["w"] = f.width; node["h"] = f.height }
  for (key, name) in [("enabled", kAXEnabledAttribute), ("focused", kAXFocusedAttribute), ("selected", kAXSelectedAttribute)] {
    if let b = attr(e, name) as? Bool { node[key] = b }
  }
  let acts = actions(e)
  if !acts.isEmpty { node["actions"] = acts }
  return node
}

func tree(pid: pid_t, window w: String?) {
  let app = appElement(pid)
  guard let (win, index) = window(app, w) else { fail("the app has no window open", code: 4) }
  var nodes: [[String: Any]] = []
  func walk(_ e: AXUIElement, _ path: String, _ depth: Int) {
    if nodes.count >= 4000 || depth > 60 { return }
    nodes.append(describe(e, path: path))
    for (i, c) in children(e).enumerated() { walk(c, "\(path).\(i)", depth + 1) }
  }
  walk(win, "\(index)", 0)
  var out: [String: Any] = ["nodes": nodes, "window": index]
  if let f = frame(win) { out["x"] = f.minX; out["y"] = f.minY; out["w"] = f.width; out["h"] = f.height }
  if let t = str(win, kAXTitleAttribute) { out["title"] = t }
  emit(out)
}

func element(pid: pid_t, path: String) -> AXUIElement {
  let app = appElement(pid)
  let parts = path.split(separator: ".").compactMap { Int($0) }
  let all = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
  guard let first = parts.first, first < all.count else { fail("no element at \(path): take a new tree", code: 4) }
  var e = all[first]
  for i in parts.dropFirst() {
    let kids = children(e)
    guard i < kids.count else { fail("no element at \(path): take a new tree", code: 4) }
    e = kids[i]
  }
  return e
}

func act(pid: pid_t, path: String, action: String, text: String?) {
  let e = element(pid: pid, path: path)
  let status: AXError
  switch action {
  case "focus":
    status = AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  case "select":
    status = AXUIElementSetAttributeValue(e, kAXSelectedAttribute as CFString, kCFBooleanTrue)
  case "show":
    // Scrolls the element into view where its container supports it; nothing to report otherwise.
    _ = AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
    status = .success
  case "setvalue":
    status = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, (text ?? "") as CFString)
  default:
    status = AXUIElementPerformAction(e, action as CFString)
  }
  if status != .success { fail("\(action) failed on \(path) (AXError \(status.rawValue))", code: 5) }
  emit(["ok": true])
}

// MARK: input

func post(_ event: CGEvent?, pid: pid_t, front: Bool) {
  guard let event else { return }
  if front { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
}

func raise(pid: pid_t, window w: String?) {
  // A background process can't activate another app any more (cooperative activation); accessibility can make it
  // frontmost. Its key window (a dialog it shows, say) keeps the keyboard; a named window is raised too.
  // Already in front: raising again would close its open pop-up list or menu.
  if w == nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
  let app = AXUIElementCreateApplication(pid)
  if AXIsProcessTrusted() {
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let w, let (win, _) = window(app, w) {
      AXUIElementPerformAction(win, kAXRaiseAction as CFString)
      AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
  } else {
    NSRunningApplication(processIdentifier: pid)?.activate(options: [])
  }
  for _ in 0..<20 {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
    usleep(25_000)
  }
  usleep(60_000)
}

/// Waits (up to 8 s) until the user has left the mouse and keyboard alone for a moment, so real input doesn't fight
/// them. Our own posted events count as input too, so the pause is short.
func waitForUser() {
  let any = CGEventType(rawValue: ~0)!
  for _ in 0..<80 {
    if CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any) >= 0.6 { return }
    usleep(100_000)
  }
  fail("the user is using the mouse or keyboard: try again in a moment", code: 8)
}

/// Where screen point [p] is when the app [pid]'s own window (or pop-up) isn't on top there ("under Safari's
/// window", "on the menu bar", "outside the app's windows"); nil when it is.
func coveredBy(_ p: CGPoint, pid: pid_t) -> String? {
  let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
  for w in list {
    let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if layer < 0 || layer >= 1000 || alpha < 0.05 { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
      let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(p)
    else { continue }
    let owning = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
    if owning == pid { return nil }
    if owner == "Window Server" { return "on the menu bar" }
    return "under \(owner.isEmpty ? "another app" : owner)'s window"
  }
  return "outside the app's windows"
}

/// Real pointer input at [points] is only sent where the app's own window is on top.
func guardPointer(pid: pid_t, _ points: [CGPoint]) {
  waitForUser()
  raise(pid: pid, window: value("window"))
  for p in points {
    if let other = coveredBy(p, pid: pid) {
      fail("nothing was sent: that point is \(other) right now, so a click there would miss the app", code: 7)
    }
  }
}

/// Real keys only go to the app in front, and never while a password field has secure input on.
func guardKeys(pid: pid_t) {
  waitForUser()
  raise(pid: pid, window: value("window"))
  if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
    fail("the app didn't come to the front, so the keys would go to another app: nothing was sent", code: 7)
  }
  if IsSecureEventInputEnabled() {
    fail("a password field has secure input on: EveryAI never types into password fields", code: 7)
  }
}

func click(pid: pid_t, at p: CGPoint, count: Int, right: Bool, front: Bool) {
  if front { guardPointer(pid: pid, [p]) }
  let source = CGEventSource(stateID: .hidSystemState)
  let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
    right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
  for n in 1...max(1, count) {
    for type in [down, up] {
      let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
      e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
      post(e, pid: pid, front: front)
      usleep(12_000)
    }
  }
}

func drag(pid: pid_t, from a: CGPoint, to b: CGPoint, front: Bool) {
  if front { guardPointer(pid: pid, [a, b]) }
  let source = CGEventSource(stateID: .hidSystemState)
  post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left), pid: pid, front: front)
  let steps = 16
  for i in 1...steps {
    let t = Double(i) / Double(steps)
    let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left), pid: pid, front: front)
    usleep(16_000)
  }
  post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left), pid: pid, front: front)
}

func scroll(pid: pid_t, at p: CGPoint, dy: Double, front: Bool) {
  if front { guardPointer(pid: pid, [p]) }
  // Scroll events go where the pointer is: move it there first when posting to the system.
  if front { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
  let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0)
  e?.location = p
  post(e, pid: pid, front: front)
}

func modifiers(_ s: String?) -> CGEventFlags {
  var f: CGEventFlags = []
  for m in (s ?? "").split(separator: ",") {
    switch m.trimmingCharacters(in: .whitespaces).lowercased() {
    case "cmd", "command": f.insert(.maskCommand)
    case "shift": f.insert(.maskShift)
    case "alt", "option": f.insert(.maskAlternate)
    case "ctrl", "control": f.insert(.maskControl)
    default: break
    }
  }
  return f
}

func key(pid: pid_t, text: String?, keycode: Int?, mods: String?, front: Bool) {
  if front { guardKeys(pid: pid) }
  let source = CGEventSource(stateID: .hidSystemState)
  if let keycode {
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keycode), keyDown: down)
      e?.flags = modifiers(mods)
      post(e, pid: pid, front: front)
      usleep(8_000)
    }
    return
  }
  // Text as unicode key events, a few characters at a time.
  let units = Array((text ?? "").utf16)
  var i = 0
  while i < units.count {
    let chunk = Array(units[i..<min(i + 16, units.count)])
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
      e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
      post(e, pid: pid, front: front)
      usleep(8_000)
    }
    i += 16
  }
}

// MARK: windows and pictures

func windows(pids: Set<pid_t>) {
  let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
  var out: [[String: Any]] = []
  for w in list {
    let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
    if !pids.isEmpty && !pids.contains(pid) { continue }
    guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
    let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    out.append([
      "id": w[kCGWindowNumber as String] ?? 0, "pid": pid, "app": w[kCGWindowOwnerName as String] ?? "",
      "title": w[kCGWindowName as String] ?? "", "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0,
      "h": b["Height"] ?? 0,
    ])
  }
  emit(out)
}

func scWindow(_ id: CGWindowID) async -> SCWindow { await capture(id).window }

/// The window [id] and a filter that shows it with the same app's windows over it (menus, pop-up lists, sheets:
/// separate windows a one-window capture leaves out), cut to the window's frame.
func capture(_ id: CGWindowID) async -> (window: SCWindow, filter: SCContentFilter, source: CGRect?) {
  guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
    fail("EveryAI needs the Screen Recording permission (System Settings > Privacy & Security)", code: 3)
  }
  guard let w = content.windows.first(where: { $0.windowID == id }) else { fail("no window \(id)", code: 4) }
  let pid = w.owningApplication?.processID
  let display = content.displays.first(where: { $0.frame.intersects(w.frame) })
  let over = content.windows.filter {
    $0.windowID != id && $0.isOnScreen && $0.owningApplication?.processID == pid && $0.windowLayer > w.windowLayer
      && $0.frame.intersects(w.frame)
  }
  guard let display, w.isOnScreen, !over.isEmpty else {
    return (w, SCContentFilter(desktopIndependentWindow: w), nil)
  }
  let source = w.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
  return (w, SCContentFilter(display: display, including: [w] + over), source)
}

func configuration(for w: SCWindow, scale: Double, fps: Double) -> SCStreamConfiguration {
  let c = SCStreamConfiguration()
  // Backing pixels: the window's points times the screen's scale, then [scale].
  let backing = NSScreen.main?.backingScaleFactor ?? 2
  c.width = max(1, Int(w.frame.width * backing * scale))
  c.height = max(1, Int(w.frame.height * backing * scale))
  c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
  c.pixelFormat = kCVPixelFormatType_32BGRA
  c.showsCursor = false
  c.ignoreShadowsSingleWindow = true
  return c
}

func shot(id: CGWindowID, out: String) async {
  let (w, filter, source) = await capture(id)
  let config = configuration(for: w, scale: 1, fps: 1)
  if let source { config.sourceRect = source }
  do {
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    emit(["ok": true, "width": image.width, "height": image.height])
  } catch {
    fail("the picture failed: \(error.localizedDescription)", code: 5)
  }
}

final class Streamer: NSObject, SCStreamOutput, SCStreamDelegate {
  let context = CIContext()
  let quality: Double
  var stream: SCStream?
  init(quality: Double) { self.quality = quality }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sample.isValid,
      let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
      let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let pixels = CMSampleBufferGetImageBuffer(sample)
    else { return }
    let image = CIImage(cvPixelBuffer: pixels)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let jpeg = context.jpegRepresentation(of: image, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    else { return }
    var head = "--everyaiframe\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".data(using: .utf8)!
    head.append(jpeg)
    head.append("\r\n".data(using: .utf8)!)
    FileHandle.standardOutput.write(head)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    fail("the window's stream stopped: \(error.localizedDescription)", code: 6)
  }
}

func startStream(id: CGWindowID, fps: Double, scale: Double) async -> Streamer {
  // Pop-ups that open later aren't in this filter: the stream shows the window alone (pictures the agent takes do
  // include them).
  let w = await scWindow(id)
  let s = Streamer(quality: 0.7)
  let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: configuration(for: w, scale: scale, fps: fps), delegate: s)
  do {
    try stream.addStreamOutput(s, type: .screen, sampleHandlerQueue: DispatchQueue(label: "everyai.stream"))
    try await stream.startCapture()
  } catch {
    fail("the window's stream didn't start: \(error.localizedDescription)", code: 5)
  }
  s.stream = stream
  return s
}

// MARK: main

signal(SIGPIPE, SIG_IGN)
// Window pictures need a window-server connection, which AppKit makes.
if ["shot", "stream"].contains(command) { _ = NSApplication.shared }

/// Runs [work] while the main run loop turns (ScreenCaptureKit answers on it).
func wait(_ work: @escaping () async -> Void) {
  var done = false
  Task {
    await work()
    done = true
  }
  while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
}

switch command {
case "trusted":
  if flag("prompt") {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    _ = CGRequestScreenCaptureAccess()
  }
  emit(["ax": AXIsProcessTrusted(), "screen": CGPreflightScreenCaptureAccess()])
case "windows":
  var pids = Set<pid_t>()
  var i = 0
  while i < args.count {
    if args[i] == "--pid", i + 1 < args.count, let p = pid_t(args[i + 1]) { pids.insert(p) }
    i += 1
  }
  windows(pids: pids)
case "tree":
  tree(pid: needPid(), window: value("window"))
case "act":
  guard let path = value("path"), let action = value("action") else { fail("act needs --path and --action") }
  act(pid: needPid(), path: path, action: action, text: textArg())
case "click":
  guard let x = number("x"), let y = number("y") else { fail("click needs --x and --y") }
  click(pid: needPid(), at: CGPoint(x: x, y: y), count: Int(number("count") ?? 1), right: flag("right"), front: flag("front"))
  emit(["ok": true])
case "drag":
  guard let x = number("x"), let y = number("y"), let tx = number("to-x"), let ty = number("to-y") else {
    fail("drag needs --x, --y, --to-x and --to-y")
  }
  drag(pid: needPid(), from: CGPoint(x: x, y: y), to: CGPoint(x: tx, y: ty), front: flag("front"))
  emit(["ok": true])
case "scroll":
  guard let x = number("x"), let y = number("y"), let dy = number("dy") else { fail("scroll needs --x, --y and --dy") }
  scroll(pid: needPid(), at: CGPoint(x: x, y: y), dy: dy, front: flag("front"))
  emit(["ok": true])
case "key":
  key(pid: needPid(), text: textArg(), keycode: value("keycode").flatMap(Int.init), mods: value("mods"), front: flag("front"))
  emit(["ok": true])
case "raise":
  raise(pid: needPid(), window: value("window"))
  emit(["ok": true])
case "shot":
  guard let id = value("window").flatMap(UInt32.init), let out = value("out") else { fail("shot needs --window and --out") }
  wait { await shot(id: id, out: out) }
case "stream":
  guard let id = value("window").flatMap(UInt32.init) else { fail("stream needs --window") }
  let fps = number("fps") ?? 10, scale = number("scale") ?? 0.5
  var keep: Streamer?
  wait { keep = await startStream(id: id, fps: fps, scale: scale) }
  _ = keep
  // Until stdout closes (the reader went away) or the process is killed.
  RunLoop.main.run()
default:
  FileHandle.standardError.write("usage: everyai-ax windows|tree|act|click|drag|scroll|key|raise|shot|stream|trusted …\n".data(using: .utf8)!)
  exit(2)
}
