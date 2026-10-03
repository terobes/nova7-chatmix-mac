// ChatMix für SteelSeries Arctis Nova 7 Gen 2 auf macOS 14.2+
// Liest das ChatMix-Rad per HID (Report 0x45: [0x45, game 0-100, chat 0-100])
// und regelt Chat-Apps und alle übrigen Apps getrennt über Core-Audio-Process-Taps.

import Cocoa
import CoreAudio
import AVFoundation
import IOKit.hid
import os
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Core-Audio-Helfer

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let unknownObject = AudioObjectID(kAudioObjectUnknown)

func propAddress(_ sel: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ fallback: T) -> T {
    var addr = propAddress(sel)
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let err = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
    return err == noErr ? value : fallback
}

func readString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = propAddress(sel)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
    return r.takeRetainedValue() as String
}

func readIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = propAddress(sel)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func ownProcessObject() -> AudioObjectID {
    var addr = propAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = getpid()
    var obj = unknownObject
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
    return err == noErr ? obj : unknownObject
}

func processPID(_ obj: AudioObjectID) -> pid_t { readValue(obj, kAudioProcessPropertyPID, pid_t(-1)) }

func processBundleID(_ obj: AudioObjectID) -> String {
    if let b = readString(obj, kAudioProcessPropertyBundleID), !b.isEmpty { return b }
    return NSRunningApplication(processIdentifier: processPID(obj))?.bundleIdentifier ?? ""
}

/// "com.hnc.Discord.helper.Renderer" -> "com.hnc.Discord"
func baseBundleID(_ bid: String) -> String {
    if let r = bid.range(of: ".helper", options: .caseInsensitive) { return String(bid[..<r.lowerBound]) }
    return bid
}

// MARK: - Ringpuffer (Stereo, interleaved)

final class StereoRing {
    private let capFrames: Int
    private let maxLatencyFrames: Int
    private let data: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var writePos = 0, readPos = 0, available = 0

    init(capacityFrames: Int = 16384, maxLatencyFrames: Int = 2048) {
        self.capFrames = capacityFrames
        self.maxLatencyFrames = maxLatencyFrames
        data = .allocate(capacity: capacityFrames * 2)
        data.initialize(repeating: 0, count: capacityFrames * 2)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    @inline(__always) private func push(_ l: Float, _ r: Float) {
        data[writePos * 2] = l
        data[writePos * 2 + 1] = r
        writePos = (writePos + 1) % capFrames
        if available < capFrames { available += 1 } else { readPos = (readPos + 1) % capFrames }
    }

    func writeInterleaved(_ p: UnsafePointer<Float>, frames: Int, channels: Int) {
        os_unfair_lock_lock(lock)
        for i in 0..<frames {
            let l = p[i * channels]
            push(l, channels > 1 ? p[i * channels + 1] : l)
        }
        os_unfair_lock_unlock(lock)
    }

    func writePlanar(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(lock)
        for i in 0..<frames { push(l[i], r[i]) }
        os_unfair_lock_unlock(lock)
    }

    func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(lock)
        if available > maxLatencyFrames + frames {          // Latenz begrenzen
            let drop = available - maxLatencyFrames
            readPos = (readPos + drop) % capFrames
            available -= drop
        }
        let n = min(frames, available)
        for i in 0..<n {
            out[i * 2] = data[readPos * 2]
            out[i * 2 + 1] = data[readPos * 2 + 1]
            readPos = (readPos + 1) % capFrames
        }
        available -= n
        os_unfair_lock_unlock(lock)
        if n < frames { (out + n * 2).update(repeating: 0, count: (frames - n) * 2) }
    }

    func clear() {
        os_unfair_lock_lock(lock)
        readPos = 0; writePos = 0; available = 0
        os_unfair_lock_unlock(lock)
    }
}

// MARK: - Process Tap -> Ringpuffer

/// Pegel-/Paketzähler für die Diagnose im Menü (nur grob, ohne Synchronisation).
final class Meter {
    var peak: Float = 0
    var packets = 0
}

final class TapCapture {
    private(set) var sampleRate: Double = 0
    private var tapID = unknownObject
    private var aggregateID = unknownObject
    private var procID: AudioDeviceIOProcID?
    private var desc: CATapDescription?
    private let ring: StereoRing
    private let name: String
    let meter = Meter()

    init(ring: StereoRing, name: String) {
        self.ring = ring
        self.name = name
    }

    /// Erstellt einen Tap für genau diese Prozesse (Stereo-Mixdown, an der Quelle stummgeschaltet).
    func start(processes: [AudioObjectID]) -> Bool {
        let d = CATapDescription(stereoMixdownOfProcesses: processes)
        d.name = name
        d.isPrivate = true
        d.muteBehavior = .mutedWhenTapped
        desc = d
        return start(d)
    }

    /// Ändert die Prozessliste eines laufenden Taps ohne Unterbrechung.
    func update(processes: [AudioObjectID]) -> Bool {
        guard let d = desc, tapID != unknownObject else { return false }
        d.processes = processes
        var addr = propAddress(kAudioTapPropertyDescription)
        var ref = d
        let err = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        return err == noErr
    }

    private func start(_ desc: CATapDescription) -> Bool {
        var tap = unknownObject
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != unknownObject else { return false }
        tapID = tap

        let fmt: AudioStreamBasicDescription = readValue(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        sampleRate = fmt.mSampleRate
        guard fmt.mFormatID == kAudioFormatLinearPCM,
              (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              fmt.mBitsPerChannel == 32 else { stop(); return false }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ChatMix \(desc.name)",
            kAudioAggregateDeviceUIDKey: "local.chatmix.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString
            ]]
        ]
        var agg = unknownObject
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else { stop(); return false }
        aggregateID = agg

        let ring = self.ring
        let meter = self.meter
        let planar = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        var pid: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&pid, agg, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let count = abl.count
            guard count > 0 else { return }
            meter.packets &+= 1
            if planar && count >= 2 {
                let lb = abl[count - 2], rb = abl[count - 1]
                guard let l = lb.mData?.assumingMemoryBound(to: Float.self),
                      let r = rb.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(lb.mDataByteSize) / 4
                var pk: Float = 0
                for i in 0..<frames { pk = max(pk, abs(l[i])) }
                if pk > meter.peak { meter.peak = pk }
                ring.writePlanar(l, r, frames: frames)
            } else {
                let b = abl[count - 1]
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
                let ch = max(Int(b.mNumberChannels), 1)
                let frames = Int(b.mDataByteSize) / 4 / ch
                var pk: Float = 0
                for i in 0..<frames { pk = max(pk, abs(p[i * ch])) }
                if pk > meter.peak { meter.peak = pk }
                ring.writeInterleaved(p, frames: frames, channels: ch)
            }
        }
        guard err == noErr, let p = pid else { stop(); return false }
        procID = p
        guard AudioDeviceStart(agg, p) == noErr else { stop(); return false }
        return true
    }

    func stop() {
        if let p = procID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        if aggregateID != unknownObject { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = unknownObject }
        if tapID != unknownObject { AudioHardwareDestroyProcessTap(tapID); tapID = unknownObject }
    }
}

// MARK: - Prozesse erkennen (App, Spiel, Systemdienst)

enum Channel: Int, CaseIterable {
    case game = 0, chat = 1, normal = 2

    var title: String {
        switch self {
        case .game: return "Game"
        case .chat: return "Chat"
        case .normal: return "Normal"
        }
    }
}

struct AudioProcInfo {
    let bundleID: String        // Bundle-ID des Prozesses (z. B. Helper)
    let appBundleID: String     // Bundle-ID der umgebenden App, sonst = bundleID
    let appURL: URL?            // äußerste .app, in der der Prozess liegt
    let isGame: Bool
    let isSystem: Bool
}

func executablePath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}

/// Äußerste .app in einem Pfad, z. B. ".../Discord.app/Contents/Frameworks/Discord Helper.app/..." -> Discord.app
func outermostApp(in path: String) -> URL? {
    if let r = path.range(of: ".app/") {
        return URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app", isDirectory: true)
    }
    if path.hasSuffix(".app") { return URL(fileURLWithPath: path, isDirectory: true) }
    return nil
}

/// Erkennt Spiele: Steam-Ordner, Wine/CrossOver/Whisky, GeForce NOW oder App-Kategorie „Games“.
func looksLikeGame(path: String, appURL: URL?) -> Bool {
    let p = path.lowercased()
    let markers = ["/steamapps/common/", "crossover", "whisky", "/wine", "wine64", "geforcenow", "geforce now"]
    if markers.contains(where: { p.contains($0) }) { return true }
    guard let url = appURL, let info = Bundle(url: url)?.infoDictionary else { return false }
    let category = (info["LSApplicationCategoryType"] as? String ?? "").lowercased()
    let sub = (info["LSApplicationSecondaryCategoryType"] as? String ?? "").lowercased()
    return category.contains("games") || sub.contains("games")
}

final class ProcessCatalog {
    static let shared = ProcessCatalog()
    private var cache: [pid_t: AudioProcInfo] = [:]
    private var gameCache: [String: Bool] = [:]

    func info(objectID: AudioObjectID, pid: pid_t) -> AudioProcInfo {
        if let c = cache[pid] { return c }
        let path = executablePath(pid)
        let appURL = outermostApp(in: path)
        var bid = readString(objectID, kAudioProcessPropertyBundleID) ?? ""
        if bid.isEmpty { bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
        let appBID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? bid

        let key = appURL?.path ?? path
        let isGame: Bool
        if let g = gameCache[key] { isGame = g } else {
            isGame = looksLikeGame(path: path, appURL: appURL)
            gameCache[key] = isGame
        }
        // Systemdienst: keine App drumherum oder App aus /System/Library (z. B. Mitteilungszentrale).
        // Ausnahme WebKit: darüber läuft der Ton von Safari und anderen Web-Apps.
        let isWebKit = bid.hasPrefix("com.apple.WebKit")
        let isSystem = !isGame && !isWebKit && (appURL == nil || appURL!.path.hasPrefix("/System/Library/"))

        let info = AudioProcInfo(bundleID: bid, appBundleID: appBID, appURL: appURL, isGame: isGame, isSystem: isSystem)
        if pid > 0 { cache[pid] = info }
        return info
    }

    func prune(keeping pids: Set<pid_t>) {
        cache = cache.filter { pids.contains($0.key) }
    }

    func isGameApp(_ url: URL) -> Bool {
        if let g = gameCache[url.path] { return g }
        let g = looksLikeGame(path: url.path, appURL: url)
        gameCache[url.path] = g
        return g
    }
}

// MARK: - Router: Taps + Mixer + Ausgabe

final class Router {
    /// Entscheidet pro Prozess, über welchen Kanal er läuft (setzt das App-Modell).
    var classify: (AudioProcInfo) -> Channel = { _ in .game }
    var gameGain: Float = 1
    var chatGain: Float = 1
    private(set) var active = false
    private(set) var lastError: String?

    private let gameRing = StereoRing()
    private let chatRing = StereoRing()
    private var gameTap: TapCapture?
    private var chatTap: TapCapture?
    private var currentGameIDs: [AudioObjectID] = []
    private var currentChatIDs: [AudioObjectID] = []

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var engineRate: Double = 0
    private let scratchG = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
    private let scratchC = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)

    init() {
        scratchG.initialize(repeating: 0, count: 16384 * 2)
        scratchC.initialize(repeating: 0, count: 16384 * 2)

        var addr = propAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.processListChanged()
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            guard let self, self.active else { return }
            self.engineRate = 0
            self.rebuild()
        }
    }

    func activate() {
        guard !active else { return }
        active = true
        rebuild()
    }

    func deactivate() {
        active = false
        stopTaps()
        engine.stop()
        engineRate = 0
    }

    /// Teilt alle Audio-Prozesse (außer ChatMix selbst) auf Game und Chat auf; „Normal“ bleibt unberührt.
    private func splitProcesses() -> (game: [AudioObjectID], chat: [AudioObjectID]) {
        let me = getpid()
        var game: [AudioObjectID] = [], chat: [AudioObjectID] = []
        var pids = Set<pid_t>()
        for id in readIDs(systemObject, kAudioHardwarePropertyProcessObjectList) {
            let pid = processPID(id)
            pids.insert(pid)
            if pid == me { continue }
            switch classify(ProcessCatalog.shared.info(objectID: id, pid: pid)) {
            case .game: game.append(id)
            case .chat: chat.append(id)
            case .normal: break
            }
        }
        ProcessCatalog.shared.prune(keeping: pids)
        return (game.sorted(), chat.sorted())
    }

    /// Neu einteilen, z. B. wenn Apps starten/enden oder Einstellungen sich ändern.
    func processListChanged() {
        guard active else { return }
        let (game, chat) = splitProcesses()
        var ok = true
        if game != currentGameIDs {
            ok = Router.updateTap(&gameTap, ring: gameRing, name: "Game", ids: game) && ok
            currentGameIDs = game
        }
        if chat != currentChatIDs {
            ok = Router.updateTap(&chatTap, ring: chatRing, name: "Chat", ids: chat) && ok
            currentChatIDs = chat
        }
        if !ok { lastError = "Kein Zugriff auf Systemaudio – Berechtigung prüfen" }
        adjustRate()
    }

    private static func updateTap(_ tap: inout TapCapture?, ring: StereoRing, name: String, ids: [AudioObjectID]) -> Bool {
        if ids.isEmpty { tap?.stop(); tap = nil; return true }
        if let t = tap, t.update(processes: ids) { return true }
        tap?.stop(); tap = nil
        let t = TapCapture(ring: ring, name: name)
        guard t.start(processes: ids) else { return false }
        tap = t
        return true
    }

    /// Spitzenpegel seit dem letzten Aufruf (nil = Tap läuft nicht).
    func takeLevels() -> (game: (Float, Int)?, chat: (Float, Int)?) {
        func take(_ t: TapCapture?) -> (Float, Int)? {
            guard let m = t?.meter else { return nil }
            defer { m.peak = 0; m.packets = 0 }
            return (m.peak, m.packets)
        }
        return (take(gameTap), take(chatTap))
    }

    private func stopTaps() {
        gameTap?.stop(); gameTap = nil
        chatTap?.stop(); chatTap = nil
        currentGameIDs = []; currentChatIDs = []
    }

    private func adjustRate() {
        let rate = gameTap?.sampleRate ?? chatTap?.sampleRate ?? 0
        if rate > 0 && rate != engineRate { _ = ensureEngine(rate: rate) }
    }

    private func rebuild() {
        guard active else { return }
        stopTaps()
        gameRing.clear(); chatRing.clear()

        // 1. Ausgabe starten
        let out = readValue(systemObject, kAudioHardwarePropertyDefaultOutputDevice, unknownObject)
        let outRate = readValue(out, kAudioDevicePropertyNominalSampleRate, Float64(48000))
        guard ensureEngine(rate: outRate) else { lastError = "Audio-Ausgabe ließ sich nicht starten"; return }

        // 2. Taps anlegen (ChatMix selbst ist nie enthalten -> keine Rückkopplung)
        lastError = nil
        processListChanged()
    }

    private func ensureEngine(rate: Double) -> Bool {
        if engine.isRunning && rate == engineRate { return true }
        engine.stop()
        if let s = source { engine.detach(s); source = nil }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return false }

        let s = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, ablPtr -> OSStatus in
            guard let self else { return noErr }
            let n = min(Int(frameCount), 16384)
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            self.gameRing.read(into: self.scratchG, frames: n)
            self.chatRing.read(into: self.scratchC, frames: n)
            let gg = self.gameGain, cg = self.chatGain
            let g = self.scratchG, c = self.scratchC
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<n {
                l[i] = g[i * 2] * gg + c[i * 2] * cg
                r[i] = g[i * 2 + 1] * gg + c[i * 2 + 1] * cg
            }
            return noErr
        }
        engine.attach(s)
        engine.connect(s, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        do { try engine.start() } catch { engine.detach(s); return false }
        source = s
        engineRate = rate
        return true
    }
}

// MARK: - ChatMix-Rad per HID

final class DialReader {
    var onValues: ((Int, Int) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var connected = 0
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    func start() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x1038,
            kIOHIDProductIDKey: 0x227e,
            kIOHIDPrimaryUsagePageKey: 0xff00
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<DialReader>.fromOpaque(ctx).takeUnretainedValue().changed(+1)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<DialReader>.fromOpaque(ctx).takeUnretainedValue().changed(-1)
        }, ctx)
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, _, _, reportID, report, length in
            guard let ctx else { return }
            Unmanaged<DialReader>.fromOpaque(ctx).takeUnretainedValue()
                .handle(reportID: reportID, report: report, length: Int(length))
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func changed(_ delta: Int) {
        let was = connected > 0
        connected = max(0, connected + delta)
        if was != (connected > 0) { onConnectionChange?(connected > 0) }
    }

    private func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        var game = -1, chat = -1
        if length >= 3 && report[0] == 0x45 {
            game = Int(report[1]); chat = Int(report[2])
        } else if reportID == 0x45 && length >= 2 {
            game = Int(report[0]); chat = Int(report[1])
        }
        guard (0...100).contains(game), (0...100).contains(chat) else { return }
        onValues?(game, chat)
    }
}

// MARK: - App-Modell (verbindet HID, Router und Oberfläche)

enum GainCurve: Int, CaseIterable {
    case natural = 0, linear = 1

    func gain(_ v: Int) -> Float {
        let x = Float(v) / 100
        switch self {
        case .natural: return x * x
        case .linear: return x
        }
    }
}

struct AppEntry: Identifiable {
    let id: String          // Bundle-ID (ohne .helper-Suffix)
    let name: String
    let icon: NSImage?
    let isExtra: Bool       // manuell hinzugefügt
    let isGame: Bool
}

/// Menüleisten-Symbol: Controller | Sprechblase, Deckkraft je nach Lautstärke.
func menuBarIcon(game: Int, chat: Int, connected: Bool, showPercent: Bool) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    let pad = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Game")?
        .withSymbolConfiguration(cfg) ?? NSImage()
    let bubble = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "Chat")?
        .withSymbolConfiguration(cfg) ?? NSImage()
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    func alpha(_ v: Int) -> CGFloat { connected ? 0.25 + 0.75 * CGFloat(v) / 100 : 0.35 }
    func text(_ s: String, _ a: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(a)])
    }

    let show = showPercent && connected
    let gText = text(show ? " \(game)" : "", alpha(game))
    let sep = text("  |  ", connected ? 0.6 : 0.35)
    let cText = text(show ? "\(chat) " : "", alpha(chat))
    let height: CGFloat = 18
    let width = pad.size.width + gText.size().width + sep.size().width + cText.size().width + bubble.size.width

    let img = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
        var x: CGFloat = 0
        func drawImage(_ i: NSImage, _ a: CGFloat) {
            i.draw(in: NSRect(x: x, y: (height - i.size.height) / 2, width: i.size.width, height: i.size.height),
                   from: .zero, operation: .sourceOver, fraction: a)
            x += i.size.width
        }
        func drawText(_ t: NSAttributedString) {
            let s = t.size()
            t.draw(at: NSPoint(x: x, y: (height - s.height) / 2))
            x += s.width
        }
        drawImage(pad, alpha(game))
        drawText(gText)
        drawText(sep)
        drawText(cText)
        drawImage(bubble, alpha(chat))
        return true
    }
    img.isTemplate = true
    return img
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Voreingestellte Chat-Apps (Präfix-Abgleich, deckt auch Helper-Prozesse ab)
    static let defaultChatApps = [
        "com.hnc.Discord",
        "com.microsoft.teams2", "com.microsoft.teams",
        "com.apple.FaceTime",
        "us.zoom.xos", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram"
    ]
    /// Systemdienste, über die FaceTime-Audio und weitergeleitete iPhone-Anrufe laufen
    static let systemCallIDs = ["com.apple.avconferenced", "com.apple.TelephonyUtilities", "com.apple.telephonyutilities"]

    let router = Router()
    let dial = DialReader()

    @Published var connected = false { didSet { updateIcon() } }
    @Published var game = 100 { didSet { updateIcon() } }
    @Published var chat = 100 { didSet { updateIcon() } }
    @Published var errorText: String?
    /// Live-Pegel 0…1, nil = Kanal läuft nicht
    @Published var gameLevel: Double?
    @Published var chatLevel: Double?
    @Published var menuIcon = menuBarIcon(game: 100, chat: 100, connected: false, showPercent: true)
    @Published var showPercent: Bool {
        didSet {
            UserDefaults.standard.set(showPercent, forKey: "showPercent")
            updateIcon()
        }
    }
    @Published var curve: GainCurve {
        didSet {
            UserDefaults.standard.set(curve.rawValue, forKey: "curve")
            applyGains()
        }
    }

    // Kanal-Regeln
    @Published var overrides: [String: Channel] = [:] { didSet { saveRules() } }
    @Published var gamesChannel: Channel { didSet { saveRules() } }
    @Published var otherChannel: Channel { didSet { saveRules() } }
    @Published var systemChannel: Channel { didSet { saveRules() } }

    @Published var games: [AppEntry] = []
    @Published var apps: [AppEntry] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    private var extraApps: [String]
    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        curve = GainCurve(rawValue: d.integer(forKey: "curve")) ?? .natural
        showPercent = (d.object(forKey: "showPercent") as? Bool) ?? true
        extraApps = d.stringArray(forKey: "extraApps") ?? []
        gamesChannel = Channel(rawValue: (d.object(forKey: "gamesChannel") as? Int) ?? 0) ?? .game
        otherChannel = Channel(rawValue: (d.object(forKey: "otherChannel") as? Int) ?? 0) ?? .game
        systemChannel = Channel(rawValue: (d.object(forKey: "systemChannel") as? Int) ?? 0) ?? .game

        if let saved = d.dictionary(forKey: "channels") as? [String: Int] {
            overrides = saved.compactMapValues { Channel(rawValue: $0) }
        } else {
            // Erststart bzw. Umstieg von älteren Versionen (nur Chat-Liste)
            let chatList = d.stringArray(forKey: "chatApps") ?? (AppModel.defaultChatApps + AppModel.systemCallIDs)
            overrides = Dictionary(chatList.map { ($0, Channel.chat) }, uniquingKeysWith: { a, _ in a })
        }
        router.classify = { [unowned self] info in self.channel(for: info) }
        updateIcon()
    }

    // Klassifizierung

    private func override(for info: AudioProcInfo) -> Channel? {
        var best: (len: Int, ch: Channel)?
        for (key, ch) in overrides where info.bundleID.hasPrefix(key) || info.appBundleID.hasPrefix(key) {
            if best == nil || key.count > best!.len { best = (key.count, ch) }
        }
        return best?.ch
    }

    func defaultChannel(isGame: Bool, isSystem: Bool) -> Channel {
        if isGame { return gamesChannel }
        if isSystem { return systemChannel }
        return otherChannel
    }

    func channel(for info: AudioProcInfo) -> Channel {
        override(for: info) ?? defaultChannel(isGame: info.isGame, isSystem: info.isSystem)
    }

    private func saveRules() {
        let d = UserDefaults.standard
        d.set(overrides.mapValues { $0.rawValue }, forKey: "channels")
        d.set(gamesChannel.rawValue, forKey: "gamesChannel")
        d.set(otherChannel.rawValue, forKey: "otherChannel")
        d.set(systemChannel.rawValue, forKey: "systemChannel")
        router.processListChanged()
    }

    // Lebenszyklus

    func start() {
        dial.onValues = { [weak self] g, c in
            guard let self else { return }
            self.game = g
            self.chat = c
            self.applyGains()
        }
        dial.onConnectionChange = { [weak self] isConnected in
            guard let self else { return }
            self.connected = isConnected
            if isConnected {
                self.router.activate()
            } else {
                self.router.deactivate()
                self.game = 100
                self.chat = 100
                self.applyGains()
            }
        }
        dial.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() { router.deactivate() }

    private func updateIcon() {
        menuIcon = menuBarIcon(game: game, chat: chat, connected: connected, showPercent: showPercent)
    }

    private func applyGains() {
        router.gameGain = curve.gain(game)
        router.chatGain = curve.gain(chat)
    }

    private func tick() {
        if errorText != router.lastError { errorText = router.lastError }
        let lv = router.takeLevels()
        // Spitzenwert mit sanftem Abfall, damit die Balken ruhig wirken
        func smooth(_ new: (Float, Int)?, _ old: Double?) -> Double? {
            guard let new else { return nil }
            return max(Double(min(new.0, 1)), (old ?? 0) * 0.75)
        }
        let g = smooth(lv.game, gameLevel), c = smooth(lv.chat, chatLevel)
        if g != gameLevel { gameLevel = g }
        if c != chatLevel { chatLevel = c }
    }

    // Einstellungen: Apps

    func channelBinding(for app: AppEntry) -> Binding<Channel> {
        Binding(
            get: { self.overrides[app.id] ?? self.defaultChannel(isGame: app.isGame, isSystem: false) },
            set: { ch in
                if ch == self.defaultChannel(isGame: app.isGame, isSystem: false) {
                    self.overrides[app.id] = nil
                } else {
                    self.overrides[app.id] = ch
                }
            })
    }

    func hasOverride(_ app: AppEntry) -> Bool { overrides[app.id] != nil }
    func resetOverride(_ app: AppEntry) { overrides[app.id] = nil }

    var systemCallsBinding: Binding<Bool> {
        Binding(
            get: { AppModel.systemCallIDs.allSatisfy { self.overrides[$0] == .chat } },
            set: { on in
                var o = self.overrides
                for id in AppModel.systemCallIDs { o[id] = on ? .chat : nil }
                self.overrides = o
            })
    }

    func refreshApps() {
        let own = Bundle.main.bundleIdentifier ?? ""
        var urls: [URL] = []

        // 1. Apps, die gerade Ton abspielen
        for id in readIDs(systemObject, kAudioHardwarePropertyProcessObjectList)
        where readValue(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0 {
            let pid = processPID(id)
            if let url = ProcessCatalog.shared.info(objectID: id, pid: pid).appURL { urls.append(url) }
        }
        // 2. Apps mit eigener Regel und manuell hinzugefügte
        for id in Array(overrides.keys) + extraApps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { urls.append(url) }
        }
        // 3. Installierte Spiele: Steam-Bibliothek und Programme-Ordner (Kategorie „Games“)
        let fm = FileManager.default
        let steam = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common")
        for dir in (try? fm.contentsOfDirectory(at: steam, includingPropertiesForKeys: nil)) ?? [] {
            if dir.pathExtension == "app" { urls.append(dir); continue }
            for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where item.pathExtension == "app" { urls.append(item) }
        }
        for item in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"),
                                                  includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "app" && ProcessCatalog.shared.isGameApp(item) {
            urls.append(item)
        }

        var seen = Set<String>()
        var gameList: [AppEntry] = [], appList: [AppEntry] = []
        for url in urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != own, !url.path.hasPrefix("/System/Library/"), seen.insert(id).inserted else { continue }
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let isGame = ProcessCatalog.shared.isGameApp(url)
            let entry = AppEntry(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path),
                                 isExtra: extraApps.contains(id), isGame: isGame)
            if isGame { gameList.append(entry) } else { appList.append(entry) }
        }
        let byName: (AppEntry, AppEntry) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        games = gameList.sorted(by: byName)
        apps = appList.sorted(by: byName)
    }

    func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !extraApps.contains(id) { extraApps.append(id) }
        }
        UserDefaults.standard.set(extraApps, forKey: "extraApps")
        refreshApps()
    }

    func removeApp(_ app: AppEntry) {
        extraApps.removeAll { $0 == app.id }
        UserDefaults.standard.set(extraApps, forKey: "extraApps")
        overrides[app.id] = nil
        refreshApps()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Nicht möglich (\(error.localizedDescription)). Liegt ChatMix im Programme-Ordner?"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Menüleiste

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.connected ? "Headset verbunden" : "Headset nicht verbunden")
        if model.connected {
            Text("Game \(model.game) %  ·  Chat \(model.chat) %")
        }
        if let err = model.errorText {
            Text("⚠️ \(err)")
        }
        Divider()
        Button("Einstellungen …") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("ChatMix beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Einstellungsfenster

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            ChannelSettings(model: model)
                .tabItem { Label("Kanäle", systemImage: "slider.horizontal.3") }
            AboutSettings()
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 620)
    }
}

struct LevelRow: View {
    let title: String
    let symbol: String
    let value: Double?      // 0…1, nil = aus
    var tint: Color = .accentColor

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                ProgressView(value: value ?? 0)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(width: 160)
                    .animation(.linear(duration: 0.1), value: value ?? 0)
                Text(value.map { "\(Int($0 * 100)) %" } ?? "aus")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Headset") {
                    Label(model.connected ? "Verbunden" : "Nicht verbunden",
                          systemImage: model.connected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.connected ? .green : .secondary)
                }
                if let err = model.errorText {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("ChatMix-Rad") {
                LevelRow(title: "Game", symbol: "gamecontroller.fill",
                         value: model.connected ? Double(model.game) / 100 : nil)
                LevelRow(title: "Chat", symbol: "bubble.left.fill",
                         value: model.connected ? Double(model.chat) / 100 : nil)
            }
            Section {
                LevelRow(title: "Game", symbol: "gamecontroller", value: model.gameLevel, tint: .green)
                LevelRow(title: "Chat", symbol: "bubble.left", value: model.chatLevel, tint: .green)
            } header: {
                Text("Signal (live)")
            } footer: {
                Text("Zeigt, ob gerade Ton auf dem jeweiligen Kanal ankommt – unabhängig von der Radstellung.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Lautstärkeverlauf", selection: $model.curve) {
                    Text("Natürlich").tag(GainCurve.natural)
                    Text("Linear").tag(GainCurve.linear)
                }
                Toggle("Prozentwerte in der Menüleiste anzeigen", isOn: $model.showPercent)
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                if let err = model.loginError {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Verhalten")
            } footer: {
                Text("„Natürlich“ wird zur Mitte hin langsamer leiser und entspricht eher dem Gehör.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ChannelPicker: View {
    let selection: Binding<Channel>

    var body: some View {
        Picker("Kanal", selection: selection) {
            ForEach(Channel.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
    }
}

struct AppRow: View {
    @ObservedObject var model: AppModel
    let app: AppEntry

    var body: some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            Text(app.name).lineLimit(1)
            if model.hasOverride(app) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Eigene Regel – Rechtsklick zum Zurücksetzen")
            }
            Spacer()
            ChannelPicker(selection: model.channelBinding(for: app))
        }
        .contextMenu {
            if model.hasOverride(app) {
                Button("Auf Standard zurücksetzen") { model.resetOverride(app) }
            }
            if app.isExtra {
                Button("Aus der Liste entfernen") { model.removeApp(app) }
            }
        }
    }
}

struct ChannelSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ChannelPicker(selection: $model.gamesChannel)
                } label: {
                    Label("Spiele", systemImage: "gamecontroller")
                }
                LabeledContent {
                    ChannelPicker(selection: $model.otherChannel)
                } label: {
                    Label("Andere Apps", systemImage: "square.grid.2x2")
                }
                LabeledContent {
                    ChannelPicker(selection: $model.systemChannel)
                } label: {
                    Label("Systemklänge", systemImage: "bell")
                }
                Toggle(isOn: model.systemCallsBinding) {
                    Label("Anrufe vom iPhone und FaceTime als Chat", systemImage: "phone")
                }
            } header: {
                Text("Standard")
            } footer: {
                Text("„Normal“ bedeutet: ChatMix lässt den Ton unverändert, das Rad wirkt nicht darauf. Spiele werden über Steam, CrossOver/Whisky und die App-Kategorie „Games“ erkannt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spiele") {
                if model.games.isEmpty {
                    Text("Keine Spiele gefunden.").foregroundStyle(.secondary)
                }
                ForEach(model.games) { AppRow(model: model, app: $0) }
            }

            Section {
                if model.apps.isEmpty {
                    Text("Keine Apps gefunden. Lass eine App kurz Ton abspielen oder füge sie hinzu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.apps) { AppRow(model: model, app: $0) }
            } header: {
                Text("Apps")
            } footer: {
                HStack {
                    Text("Apps erscheinen, sobald sie Ton abspielen. 📌 = eigene Regel.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Aktualisieren") { model.refreshApps() }
                    Button("App hinzufügen …") { model.addApps() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshApps() }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("ChatMix").font(.title).bold()
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")")
                .foregroundStyle(.secondary)
            Text("ChatMix-Rad für das Arctis Nova 7 Wireless Gen 2 auf dem Mac.")
                .multilineTextAlignment(.center)
            Text("Inoffizielles Community-Projekt, nicht von SteelSeries unterstützt. MIT-Lizenz.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { AppModel.shared.start() }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.stop() }
}

@main
struct ChatMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.menuIcon)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
