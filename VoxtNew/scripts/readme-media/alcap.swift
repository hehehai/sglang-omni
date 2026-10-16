// alcap: screen captures and window chores for the README's media
// (scripts/readme-media/). It captures only the windows of the apps it
// is told to include (ScreenCaptureKit), over a backdrop window of its
// own, so that whatever else is on the screen stays out of the picture;
// and it moves windows and sets a text selection through Accessibility,
// never with the mouse or the keyboard.
//
//   swiftc -O alcap.swift -o alcap
//   alcap windows                                  # on-screen windows
//   alcap backdrop image.png                       # until killed
//   alcap shot   --rect x y w h --include b1,b2 --out f.png
//   alcap record --rect x y w h --include b1,b2 --out f.mov [--fps 30]   # until SIGINT/SIGTERM
//   alcap place  <pid> x y w h                     # the app's front window
//   alcap select <pid> <start> <length>            # in the focused text (-1 -1: the end)
//   alcap activate <pid>
//
// --include names apps by bundle ID or process ID; the backdrop's process
// (alcap) is always included. Points, top-left origin.
import AppKit
import ApplicationServices
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { fail("usage: alcap windows|backdrop|shot|record|place|select|activate …") }
let cmd = args.removeFirst()

func opt(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    return nil
}
func rectOpt() -> CGRect? {
    guard let i = args.firstIndex(of: "--rect"), i + 4 < args.count else { return nil }
    let v = args[(i + 1)...(i + 4)].compactMap(Double.init)
    args.removeSubrange(i...(i + 4))
    return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
}

func axWindow(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v) == .success { return (v as! AXUIElement) }
    if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &v) == .success { return (v as! AXUIElement) }
    var ws: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ws) == .success, let list = ws as? [AXUIElement], let w = list.first { return w }
    return nil
}

switch cmd {
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print("id=\(w[kCGWindowNumber as String] ?? 0) pid=\(w[kCGWindowOwnerPID as String] ?? 0) layer=\(w[kCGWindowLayer as String] ?? 0) owner=\(w[kCGWindowOwnerName as String] ?? "") name=\(w[kCGWindowName as String] ?? "") x=\(b["X"] ?? 0) y=\(b["Y"] ?? 0) w=\(b["Width"] ?? 0) h=\(b["Height"] ?? 0)")
    }

case "activate":
    guard let pid = args.first.flatMap(Int32.init), let app = NSRunningApplication(processIdentifier: pid) else { fail("activate <pid>") }
    app.activate()
    if let w = axWindow(pid) { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }

case "place":
    guard args.count >= 5, let pid = Int32(args[0]) else { fail("place <pid> x y w h") }
    let v = args[1...4].compactMap(Double.init)
    guard let w = axWindow(pid) else { fail("no window for \(pid)") }
    var p = CGPoint(x: v[0], y: v[1]), s = CGSize(width: v[2], height: v[3])
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)

case "select":
    guard args.count >= 3, let pid = Int32(args[0]), let loc = Int(args[1]), let len = Int(args[2]) else { fail("select <pid> <start> <length>") }
    let app = AXUIElementCreateApplication(pid)
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success else { fail("no focused element") }
    // A negative start counts from the end; a negative length runs to it.
    var n: CFTypeRef?
    AXUIElementCopyAttributeValue(f as! AXUIElement, kAXNumberOfCharactersAttribute as CFString, &n)
    let total = (n as? Int) ?? 0
    let start = loc < 0 ? max(0, total + loc + 1) : loc
    var r = CFRange(location: start, length: len < 0 ? max(0, total - start) : len)
    let e = AXUIElementSetAttributeValue(f as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
    print("selected \(r.location)+\(r.length) of \(total)")
    if e != .success { fail("select: \(e.rawValue)") }

case "menuextra": // menuextra <pid> <out.png>: opens the app's menu bar item and captures it with its menu
    guard args.count >= 2, let pid = Int32(args[0]) else { fail("menuextra <pid> <out.png>") }
    let out = args[1]
    let app = AXUIElementCreateApplication(pid)
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success else { fail("no menu bar item") }
    var kids: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
    guard let item = (kids as? [AXUIElement])?.first else { fail("no menu bar item") }
    func frame(_ e: AXUIElement) -> CGRect {
        var p: CFTypeRef?, s: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s)
        var pt = CGPoint.zero, sz = CGSize.zero
        if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
        return CGRect(origin: pt, size: sz)
    }
    let icon = frame(item)
    DispatchQueue.global().async { AXUIElementPerformAction(item, kAXPressAction as CFString) }
    usleep(900_000)
    var menu = CGRect.zero
    var mk: CFTypeRef?
    AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &mk)
    if let m = (mk as? [AXUIElement])?.first { menu = frame(m) }
    print("icon \(icon) menu \(menu)")
    let r = icon.union(menu).insetBy(dx: -40, dy: -30)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["shot", "--rect", "\(r.minX)", "\(max(0, r.minY))", "\(r.width)", "\(r.height)", "--include", "\(pid)", "--out", out]
    try? p.run(); p.waitUntilExit()
    // The item itself is drawn by the system, not the app: from the screen
    // (the menu bar is clear over the backdrop).
    let sc = Process()
    sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    sc.arguments = ["-x", "-R", "\(icon.minX - 4),0,\(icon.width + 8),34", out.replacingOccurrences(of: ".png", with: "-item.png")]
    try? sc.run(); sc.waitUntilExit()
    print("item at \(icon.minX - 4),0 in a shot from \(r.minX),\(max(0, r.minY))")
    // Escape closes the menu.
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)

case "backdrop":
    guard let path = args.first, let img = NSImage(contentsOfFile: path) else { fail("backdrop <image>") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let frame = NSScreen.main!.frame
    let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    let v = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
    v.image = img
    v.imageScaling = .scaleAxesIndependently
    w.contentView = v
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    w.collectionBehavior = [.canJoinAllSpaces, .stationary]
    w.ignoresMouseEvents = true
    w.hasShadow = false
    w.orderFrontRegardless()
    print("backdrop pid=\(getpid()) \(frame)")
    signal(SIGTERM, SIG_DFL)
    app.run()

case "shot", "record":
    runCapture()

default:
    fail("unknown command \(cmd)")
}
exit(0)

// MARK: ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var frames = 0
    var dropped = 0
    var statuses: [Int: Int] = [:]
    let q = DispatchQueue(label: "rec")
    init(url: URL, w: Int, h: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let comp: [String: Any] = [AVVideoAverageBitRateKey: 40_000_000, AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoCompressionPropertiesKey: comp,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, type == .screen,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int else { return }
        statuses[raw, default: 0] += 1
        guard SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb); frames += 1 } else { dropped += 1 }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { FileHandle.standardError.write("stream stopped: \(error)\n".data(using: .utf8)!) }
}

func runCapture() {
    guard let out = opt("--out") else { fail("--out") }
    let fps = Int(opt("--fps") ?? "30")!
    let scale = Double(opt("--scale") ?? "2")!
    let include = (opt("--include") ?? "").split(separator: ",").map(String.init)
    let rect = rectOpt()
    let sem = DispatchSemaphore(value: 0)
    var content: SCShareableContent?
    var err: Error?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, e in content = c; err = e; sem.signal() }
    sem.wait()
    guard let c = content, let display = c.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? c.displays.first else {
        fail("no shareable content: \(String(describing: err))")
    }
    // The backdrop is an alcap process too.
    let apps = c.applications.filter { a in
        a.applicationName == "alcap" || include.contains(a.bundleIdentifier) || include.contains(String(a.processID))
    }
    FileHandle.standardError.write("including \(apps.map { "\($0.applicationName)(\($0.processID))" })\n".data(using: .utf8)!)
    // The display without the other apps: a filter that includes the apps
    // instead makes macOS put its window-sharing badge in place of their
    // windows' traffic lights (ALCAP_MODE=include).
    let filter = ProcessInfo.processInfo.environment["ALCAP_MODE"] != "include"
        ? SCContentFilter(display: display, excludingApplications: c.applications.filter { a in !apps.contains { $0.processID == a.processID } }, exceptingWindows: [])
        : SCContentFilter(display: display, including: apps, exceptingWindows: [])
    let r = rect ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = r
    cfg.width = Int((r.width * scale).rounded()) / 2 * 2
    cfg.height = Int((r.height * scale).rounded()) / 2 * 2
    cfg.showsCursor = false
    cfg.scalesToFit = true
    cfg.colorSpaceName = CGColorSpace.sRGB
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    cfg.queueDepth = 8

    if cmd == "shot" {
        var img: CGImage?
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { i, e in img = i; err = e; sem.signal() }
        sem.wait()
        guard let i = img else { fail("shot: \(String(describing: err))") }
        try! NSBitmapImageRep(cgImage: i).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("shot \(i.width)x\(i.height) \(out)")
        return
    }
    let rec: Recorder
    do { rec = try Recorder(url: URL(fileURLWithPath: out), w: cfg.width, h: cfg.height, fps: fps) } catch { fail("writer: \(error)") }
    let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
    do { try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.q) } catch { fail("output: \(error)") }
    stream.startCapture { e in err = e; sem.signal() }
    sem.wait()
    if let e = err { fail("start: \(e)") }
    print("recording \(cfg.width)x\(cfg.height)@\(fps) \(out)")
    // A window that changes size can drop out of a running stream (the
    // answer card stopped updating): the filter is made again twice a
    // second from the windows there are then.
    let refresh = DispatchSource.makeTimerSource(queue: .global())
    refresh.schedule(deadline: .now() + 0.5, repeating: 0.5)
    refresh.setEventHandler {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, _ in
            guard let c, let d = c.displays.first(where: { $0.displayID == display.displayID }) else { return }
            let keep = c.applications.filter { a in a.applicationName == "alcap" || include.contains(a.bundleIdentifier) || include.contains(String(a.processID)) }
            let f = ProcessInfo.processInfo.environment["ALCAP_MODE"] != "include"
                ? SCContentFilter(display: d, excludingApplications: c.applications.filter { a in !keep.contains { $0.processID == a.processID } }, exceptingWindows: [])
                : SCContentFilter(display: d, including: keep, exceptingWindows: [])
            stream.updateContentFilter(f) { _ in }
        }
    }
    refresh.resume()
    let stop = DispatchSemaphore(value: 0)
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let s1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global()); s1.setEventHandler { stop.signal() }; s1.resume()
    let s2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global()); s2.setEventHandler { stop.signal() }; s2.resume()
    stop.wait()
    refresh.cancel()
    stream.stopCapture { _ in sem.signal() }
    sem.wait()
    rec.q.sync {
        rec.input.markAsFinished()
        rec.writer.finishWriting { sem.signal() }
    }
    sem.wait()
    print("done frames=\(rec.frames) dropped=\(rec.dropped) statuses=\(rec.statuses) status=\(rec.writer.status.rawValue)")
}
