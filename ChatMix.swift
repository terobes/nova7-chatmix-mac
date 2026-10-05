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
import UserNotifications
import Charts

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
    struct Status {
        var headsetOn: Bool? = nil     // nil = unbekannt
        var battery: Int? = nil        // 0…100 %
        var charging = false
    }

    enum MediaButton { case playPause, next, previous }

    var onValues: ((Int, Int) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onStatus: ((Status) -> Void)?
    /// Power-Taste am Headset: 1×, 2×, 3× drücken
    var onMediaButton: ((MediaButton) -> Void)?
    private(set) var status = Status()
    /// Schnittstelle für Statusabfragen (Usage Page 0xffc0, Interface 3)
    private var commandDevices: [IOHIDDevice] = []
    private var pollTimer: Timer?
    private(set) var connected = 0
    /// Verbindungsweg des Headsets, z. B. "USB" oder "Bluetooth"
    private(set) var transports: [String] = []
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    func start() {
        // Erkennung über Produkt-ID (USB-Dongle) oder Produktname (z. B. Bluetooth mit anderer ID)
        let byID: [String: Any] = [
            kIOHIDVendorIDKey: 0x1038,
            kIOHIDProductIDKey: 0x227e,
            kIOHIDPrimaryUsagePageKey: 0xff00
        ]
        let byName: [String: Any] = [
            kIOHIDVendorIDKey: 0x1038,
            kIOHIDProductKey: "Arctis Nova 7 Gen 2",
            kIOHIDPrimaryUsagePageKey: 0xff00
        ]
        // Befehls-Schnittstelle nur am Dongle: Das per USB-C-Kabel angeschlossene Headset (0x227c)
        // hat zwar auch eine, beantwortet aber keine Statusabfragen.
        var cmdByID = byID; cmdByID[kIOHIDPrimaryUsagePageKey] = 0xffc0
        // Medientasten-Schnittstelle des Dongles (Consumer Control, Interface 4)
        var mediaByID = byID; mediaByID[kIOHIDPrimaryUsagePageKey] = 0x000c
        IOHIDManagerSetDeviceMatchingMultiple(manager, [byID, byName, cmdByID, mediaByID] as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DialReader>.fromOpaque(ctx).takeUnretainedValue().changed(+1, device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DialReader>.fromOpaque(ctx).takeUnretainedValue().changed(-1, device)
        }, ctx)
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, sender, _, reportID, report, length in
            guard let ctx else { return }
            let reader = Unmanaged<DialReader>.fromOpaque(ctx).takeUnretainedValue()
            if let sender {
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                if reader.usagePage(device) == 0x000c {
                    reader.handleMedia(reportID: reportID, report: report, length: Int(length))
                    return
                }
            }
            reader.handle(reportID: reportID, report: report, length: Int(length))
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        // Akkustand alle 60 s nachfragen (Änderungen meldet das Headset zusätzlich von selbst)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.requestStatus()
        }
    }

    /// Statusabfrage 0xb0 an die Befehls-Schnittstelle; Antwort: b0 <verbunden> <akku> <laden>
    func requestStatus() {
        var buf = [UInt8](repeating: 0, count: 63)
        buf[0] = 0xb0
        for dev in commandDevices {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, buf, buf.count)
        }
    }

    fileprivate func usagePage(_ device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
    }

    private func changed(_ delta: Int, _ device: IOHIDDevice) {
        if usagePage(device) == 0x000c { return }
        if usagePage(device) == 0xffc0 {
            if delta > 0 {
                commandDevices.append(device)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.requestStatus() }
            } else {
                commandDevices.removeAll { $0 === device }
                if commandDevices.isEmpty {
                    status = Status()
                    onStatus?(status)
                } else {
                    requestStatus()
                }
            }
            return
        }
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "?"
        if delta > 0 {
            transports.append(transport)
        } else if let i = transports.firstIndex(of: transport) {
            transports.remove(at: i)
        }
        let was = connected > 0
        connected = max(0, connected + delta)
        if was != (connected > 0) || delta != 0 { onConnectionChange?(connected > 0) }
    }

    private var lastMediaPress = Date.distantPast

    fileprivate func handleMedia(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        let start = reportID != 0 ? 1 : 0          // Report-ID-Byte überspringen, falls vorhanden
        guard length > start else { return }
        var mask: UInt8 = 0
        for i in start..<length where report[i] != 0 { mask = report[i]; break }
        let button: MediaButton
        switch mask {
        case 0x02: button = .playPause
        case 0x04: button = .next
        case 0x01: button = .previous
        default: return                           // 00 = Taste losgelassen
        }
        let now = Date()
        guard now.timeIntervalSince(lastMediaPress) > 0.15 else { return }
        lastMediaPress = now
        onMediaButton?(button)
    }

    fileprivate func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        if length >= 2 {
            var s = status
            switch report[0] {
            case 0xb0 where length >= 4:            // Antwort auf Statusabfrage
                s.headsetOn = report[1] == 0x03
                s.battery = s.headsetOn == true ? min(Int(report[2]), 100) : nil
                s.charging = report[3] == 0x01
            case 0xb7:                               // neuer Akkustand
                s.battery = min(Int(report[1]), 100)
            case 0xb9:                               // Headset ein/aus
                s.headsetOn = report[1] == 0x03
                if s.headsetOn == false { s.battery = nil }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestStatus() } }
            case 0xbb:                               // Laden ja/nein
                s.charging = report[1] == 0x01
            default:
                break
            }
            if s.headsetOn != status.headsetOn || s.battery != status.battery || s.charging != status.charging {
                status = s
                onStatus?(s)
            }
        }
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

/// Schickt eine Medientaste (Play/Pause, Weiter, Zurück) an macOS – wie die Tasten F7–F9.
func postMediaKey(_ key: Int) {
    for down in [true, false] {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       subtype: 8, data1: data1, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
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
    let batteryTracker = BatteryTracker()
    private var batteryTimer: Timer?

    @Published var connected = false { didSet { updateIcon() } }
    /// z. B. "USB-Dongle", "Bluetooth" oder "USB-Dongle + Bluetooth"
    @Published var connectionType = ""
    @Published var headsetOn: Bool?
    @Published var battery: Int?
    @Published var charging = false

    /// Kurzer Text für Akku/Zustand, z. B. "Akku 48 % ⚡" oder "Headset aus"
    var batteryText: String? {
        if headsetOn == false { return "Headset aus" }
        guard let b = battery else { return nil }
        return "Akku \(b) %" + (charging ? " ⚡" : "")
    }
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
    /// Power-Taste des Headsets als Medientaste (1× Play/Pause, 2× Weiter, 3× Zurück)
    @Published var mediaKeysEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaKeysEnabled, forKey: "mediaKeys") }
    }
    /// Freigabe unter Bedienungshilfen (nötig, um Medientasten an macOS zu schicken)
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    private var tickCount = 0

    private var extraApps: [String]
    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        curve = GainCurve(rawValue: d.integer(forKey: "curve")) ?? .natural
        showPercent = (d.object(forKey: "showPercent") as? Bool) ?? true
        mediaKeysEnabled = (d.object(forKey: "mediaKeys") as? Bool) ?? true
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

    private func channelOverride(for info: AudioProcInfo) -> Channel? {
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
        channelOverride(for: info) ?? defaultChannel(isGame: info.isGame, isSystem: info.isSystem)
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
            let names = Set(self.dial.transports.map { $0.lowercased().contains("bluetooth") ? "Bluetooth" : "USB-Dongle" })
            self.connectionType = names.sorted(by: >).joined(separator: " + ")
            if self.connected != isConnected { self.connected = isConnected }
            if isConnected {
                self.router.activate()
            } else {
                self.router.deactivate()
                self.game = 100
                self.chat = 100
                self.applyGains()
            }
        }
        dial.onMediaButton = { [weak self] button in
            guard let self, self.mediaKeysEnabled else { return }
            self.accessibilityTrusted = AXIsProcessTrusted()
            switch button {
            case .playPause: postMediaKey(16)     // NX_KEYTYPE_PLAY
            case .next: postMediaKey(17)          // NX_KEYTYPE_NEXT
            case .previous: postMediaKey(18)      // NX_KEYTYPE_PREVIOUS
            }
        }
        dial.onStatus = { [weak self] st in
            guard let self else { return }
            self.headsetOn = st.headsetOn
            self.battery = st.battery
            self.charging = st.charging
            self.batteryTracker.record(pct: st.battery, charging: st.charging, headsetOn: st.headsetOn)
        }
        // einmal pro Minute aufzeichnen, damit der Verlauf auch ohne Änderung dicht bleibt
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.connected else { return }
            self.batteryTracker.record(pct: self.battery, charging: self.charging, headsetOn: self.headsetOn)
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
        tickCount += 1
        if tickCount % 20 == 0 {
            let trusted = AXIsProcessTrusted()
            if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        }
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

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !accessibilityTrusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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

// MARK: - Akku-Tracker (Verlauf, Schätzungen, Ladegrenze, Kapazität)

struct BatterySample: Codable {
    let t: Date
    let pct: Int
    let charging: Bool
}

struct ChargeSession: Codable, Identifiable {
    var id = UUID()
    let start: Date
    let startPct: Int
    var end: Date?
    var endPct: Int
    /// Zuletzt gemeldeter Prozentwert und wann er sich zuletzt geändert hat (zum Erkennen eines Ladestopps)
    var lastChange: Date
    /// Mit einem USB-C-Messgerät gemessene Ladung in mAh (vom Nutzer eingetragen)
    var measuredMAh: Double?

    var deltaPct: Int { endPct - startPct }

    /// Hochgerechnete Akkukapazität: gemessene mAh × Ladewirkungsgrad ÷ geladener Anteil
    var capacityEstimate: Double? {
        guard let mah = measuredMAh, mah > 0, deltaPct >= 20 else { return nil }
        return mah * BatteryTracker.chargeEfficiency / (Double(deltaPct) / 100)
    }
}

final class BatteryTracker: ObservableObject {
    /// Typischer Wirkungsgrad beim Laden kleiner Li-Ionen-Akkus (Verluste in Ladeelektronik und Wärme)
    static let chargeEfficiency = 0.85

    @Published private(set) var samples: [BatterySample] = []
    @Published private(set) var sessions: [ChargeSession] = []

    @Published var limitEnabled: Bool { didSet { UserDefaults.standard.set(limitEnabled, forKey: "limitEnabled"); askForNotifications() } }
    @Published var limit: Int { didSet { UserDefaults.standard.set(limit, forKey: "chargeLimit") } }
    @Published var shortcutName: String { didSet { UserDefaults.standard.set(shortcutName, forKey: "limitShortcut") } }
    @Published var lowWarning: Bool { didSet { UserDefaults.standard.set(lowWarning, forKey: "lowWarning"); askForNotifications() } }

    private var lastCharging: Bool?
    private var notifiedLimit = false
    private var notifiedLow = false
    private let fileURL: URL

    init() {
        let d = UserDefaults.standard
        limitEnabled = (d.object(forKey: "limitEnabled") as? Bool) ?? false
        limit = (d.object(forKey: "chargeLimit") as? Int) ?? 80
        shortcutName = d.string(forKey: "limitShortcut") ?? ""
        lowWarning = (d.object(forKey: "lowWarning") as? Bool) ?? true

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("battery.json")
        load()
        askForNotifications()
    }

    // Speichern / Laden

    private struct Store: Codable {
        var samples: [BatterySample]
        var sessions: [ChargeSession]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        samples = store.samples
        sessions = store.sessions
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)      // 90 Tage aufheben
        samples.removeAll { $0.t < cutoff }
        if sessions.count > 200 { sessions.removeFirst(sessions.count - 200) }
        if let data = try? JSONEncoder().encode(Store(samples: samples, sessions: sessions)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // Aufzeichnen (bei jeder Statusänderung und einmal pro Minute)

    func record(pct: Int?, charging: Bool, headsetOn: Bool?) {
        guard let pct, headsetOn != false else {
            lastCharging = nil
            return
        }
        let now = Date()
        var changed = false

        // Verlaufspunkt: bei Änderung, sonst spätestens alle 10 Minuten
        if let last = samples.last, last.pct == pct, last.charging == charging,
           now.timeIntervalSince(last.t) < 600 {
        } else {
            samples.append(BatterySample(t: now, pct: pct, charging: charging))
            changed = true
        }

        // Ladevorgänge
        if charging && lastCharging != true {
            sessions.append(ChargeSession(start: now, startPct: pct, endPct: pct, lastChange: now))
            notifiedLimit = false
            changed = true
        } else if charging, let i = sessions.indices.last, sessions[i].end == nil {
            if sessions[i].endPct != pct {
                sessions[i].endPct = pct
                sessions[i].lastChange = now
                changed = true
            }
        } else if !charging && lastCharging == true, let i = sessions.indices.last, sessions[i].end == nil {
            sessions[i].end = now
            sessions[i].endPct = pct
            changed = true
        }
        lastCharging = charging

        // Ladegrenze
        if limitEnabled && charging && pct >= limit && !notifiedLimit {
            notifiedLimit = true
            notify("Ladegrenze erreicht", "Headset-Akku bei \(pct) % – Ladekabel abziehen.")
            runShortcut()
        }
        // Akku fast leer
        if lowWarning && !charging && pct <= 15 && !notifiedLow {
            notifiedLow = true
            notify("Headset-Akku fast leer", "Nur noch \(pct) % – bald aufladen.")
        }
        if pct >= 20 || charging { notifiedLow = false }

        if changed { save() }
    }

    func setMeasuredMAh(_ value: Double?, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].measuredMAh = value
        save()
    }

    func clearHistory() {
        samples = []
        sessions = []
        save()
    }

    // Auswertung

    /// Verbrauch in %/h, aus Abschnitten ohne Laden mit dichtem Messabstand (Headset war an)
    var dischargeRate: Double? {
        rate(charging: false, window: 14 * 24 * 3600, maxGap: 1800, perSeconds: 3600)
    }

    /// Ladegeschwindigkeit in %/min
    var chargeRate: Double? {
        rate(charging: true, window: 30 * 24 * 3600, maxGap: 1800, perSeconds: 60)
    }

    private func rate(charging: Bool, window: TimeInterval, maxGap: TimeInterval, perSeconds: Double) -> Double? {
        let cutoff = Date().addingTimeInterval(-window)
        let recent = samples.filter { $0.t >= cutoff }
        guard recent.count > 1 else { return nil }
        var pct = 0.0, secs = 0.0
        for k in 1..<recent.count {
            let a = recent[k - 1], b = recent[k]
            let dt = b.t.timeIntervalSince(a.t)
            guard a.charging == charging, b.charging == charging, dt > 0, dt <= maxGap else { continue }
            let dp = Double(charging ? b.pct - a.pct : a.pct - b.pct)
            guard dp >= 0 else { continue }
            pct += dp
            secs += dt
        }
        guard pct >= 5, secs > 0 else { return nil }      // zu wenig Daten
        return pct / secs * perSeconds
    }

    /// Geschätzte Laufzeit mit voller Ladung in Stunden
    var fullRuntimeHours: Double? { dischargeRate.map { 100 / $0 } }

    /// Laufender Ladevorgang, der seit mindestens 30 Minuten nicht mehr gestiegen ist (unter 100 %)
    var stalledSession: ChargeSession? {
        guard let s = sessions.last, s.end == nil, s.endPct < 100,
              Date().timeIntervalSince(s.lastChange) > 1800 else { return nil }
        return s
    }

    /// Mittelwert aller Kapazitätsschätzungen
    var averageCapacity: Double? {
        let values = sessions.compactMap(\.capacityEstimate)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // Mitteilungen und Kurzbefehl

    private func askForNotifications() {
        guard limitEnabled || lowWarning else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func runShortcut() {
        let name = shortcutName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", name]
        try? p.run()
    }
}

// MARK: - Einstellungen: Akku

struct BatterySettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tracker: BatteryTracker
    @State private var range: TimeInterval = 24 * 3600

    private func hours(_ h: Double) -> String {
        h >= 10 ? "\(Int(h.rounded())) h" : String(format: "%.1f h", h)
    }

    var body: some View {
        Form {
            Section("Jetzt") {
                if let b = model.battery, model.connected, model.headsetOn != false {
                    LevelRow(title: model.charging ? "Akku (lädt)" : "Akku",
                             symbol: model.charging ? "battery.100.bolt" : "battery.75",
                             value: Double(b) / 100, tint: b > 20 ? .green : .red)
                    if model.charging {
                        if let r = tracker.chargeRate, r > 0 {
                            let target = tracker.limitEnabled ? max(tracker.limit, b) : 100
                            let minutes = Double(target - b) / r
                            LabeledContent(target < 100 ? "\(target) % erreicht in" : "Voll in",
                                           value: minutes < 1 ? "gleich" : "ca. \(Int(minutes.rounded())) Min.")
                        } else {
                            LabeledContent("Ladezeit", value: "wird ermittelt …")
                        }
                    } else if let rate = tracker.dischargeRate {
                        LabeledContent("Restlaufzeit", value: "ca. \(hours(Double(b) / rate))")
                    }
                } else {
                    Text(model.connected ? "Headset ist ausgeschaltet." : "Headset nicht verbunden (Dongle nötig).")
                        .foregroundStyle(.secondary)
                }
                if let s = tracker.stalledSession {
                    Label("Lädt seit über 30 Min. nicht weiter – das Headset hält den Akku offenbar bei \(s.endPct) %.",
                          systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Zeitraum", selection: $range) {
                    Text("24 Std.").tag(TimeInterval(24 * 3600))
                    Text("7 Tage").tag(TimeInterval(7 * 24 * 3600))
                    Text("30 Tage").tag(TimeInterval(30 * 24 * 3600))
                }
                .pickerStyle(.segmented)
                let from = Date().addingTimeInterval(-range)
                let points = tracker.samples.filter { $0.t >= from }
                if points.count < 2 {
                    Text("Noch zu wenig Messwerte. Der Verlauf füllt sich, solange ChatMix läuft und das Headset über den Dongle verbunden ist.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Chart(points, id: \.t) { p in
                        LineMark(x: .value("Zeit", p.t), y: .value("Akku", p.pct))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(.green)
                        if p.charging {
                            PointMark(x: .value("Zeit", p.t), y: .value("Akku", p.pct))
                                .symbolSize(12)
                                .foregroundStyle(.yellow)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXScale(domain: from...Date())
                    .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { _ in AxisGridLine(); AxisValueLabel() } }
                    .frame(height: 170)
                }
            } header: {
                Text("Verlauf")
            } footer: {
                Text("Gelbe Punkte = Laden.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Laufzeit") {
                if let h = tracker.fullRuntimeHours, let r = tracker.dischargeRate {
                    LabeledContent("Mit voller Ladung", value: "ca. \(hours(h))")
                    LabeledContent("Verbrauch", value: String(format: "%.1f %% pro Stunde", r))
                    // Herstellerangabe Arctis Nova 7 Gen 2: bis zu 54 h über 2,4 GHz
                    LabeledContent("Im Vergleich zur Herstellerangabe") {
                        Text("\(Int((h / 54 * 100).rounded())) % von 54 h")
                            .foregroundStyle(h / 54 >= 0.7 ? Color.primary : Color.orange)
                    }
                } else {
                    Text("Wird berechnet, sobald genug Messwerte ohne Laden vorliegen (mind. 5 % Verbrauch).")
                        .foregroundStyle(.secondary)
                }
                if let r = tracker.chargeRate {
                    LabeledContent("Ladegeschwindigkeit", value: String(format: "%.1f %% pro Minute", r))
                }
            }

            Section {
                Toggle("Bei Ladegrenze benachrichtigen", isOn: $tracker.limitEnabled)
                if tracker.limitEnabled {
                    Stepper("Ladegrenze: \(tracker.limit) %", value: $tracker.limit, in: 50...100, step: 5)
                    TextField("Kurzbefehl ausführen (optional)", text: $tracker.shortcutName,
                              prompt: Text("z. B. Ladesteckdose aus"))
                }
                Toggle("Warnung bei 15 % Akku", isOn: $tracker.lowWarning)
            } header: {
                Text("Ladegrenze")
            } footer: {
                Text("Das Headset entscheidet selbst, wie weit es lädt – ChatMix kann das Laden nicht stoppen. Bei Erreichen der Grenze erscheint eine Mitteilung. Lädst du über eine HomeKit-Steckdose, kann ein Kurzbefehl (App „Kurzbefehle“) sie automatisch ausschalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                let recent = Array(tracker.sessions.suffix(10).reversed())
                if recent.isEmpty {
                    Text("Noch keine Ladevorgänge aufgezeichnet.").foregroundStyle(.secondary)
                }
                ForEach(recent) { s in
                    SessionRow(session: s, tracker: tracker)
                }
                if let cap = tracker.averageCapacity {
                    LabeledContent("Geschätzte Kapazität", value: "≈ \(Int(cap.rounded())) mAh")
                        .bold()
                }
            } header: {
                Text("Ladevorgänge & Kapazität")
            } footer: {
                Text("Kapazität messen: Ein USB-C-Messgerät zwischen Ladekabel und Headset stecken, mindestens 20 % laden und die angezeigten mAh beim Ladevorgang eintragen. ChatMix rechnet auf 100 % hoch und berücksichtigt rund 15 % Ladeverluste. Mehrere Messungen über Monate zeigen, wie der Akku altert.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Verlauf löschen", role: .destructive) { tracker.clearHistory() }
            }
        }
        .formStyle(.grouped)
    }
}

struct SessionRow: View {
    let session: ChargeSession
    @ObservedObject var tracker: BatteryTracker

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.start.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text("\(s.startPct) % → \(s.endPct) %").monospacedDigit()
                if s.end == nil {
                    Text("lädt").font(.caption).foregroundStyle(.green)
                } else if let end = s.end {
                    Text("\(Int(end.timeIntervalSince(s.start) / 60)) Min.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if s.end != nil && s.endPct < 95 {
                    Text("Ladeende unter 100 % (abgezogen oder vom Headset gestoppt)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("mAh", value: Binding(
                    get: { s.measuredMAh ?? 0 },
                    set: { tracker.setMeasuredMAh($0 > 0 ? $0 : nil, for: s.id) }),
                    format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text("mAh").font(.caption).foregroundStyle(.secondary)
                if let cap = s.capacityEstimate {
                    Text("→ \(Int(cap.rounded())) mAh voll").font(.caption).bold()
                }
            }
        }
    }
}

// MARK: - Menüleiste

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.connected ? "Headset verbunden (\(model.connectionType))" : "Headset nicht verbunden")
        if model.connected {
            if let bt = model.batteryText { Text(bt) }
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
            BatterySettings(model: model, tracker: model.batteryTracker)
                .tabItem { Label("Akku", systemImage: "battery.75") }
            AboutSettings()
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 680)
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
                    Label(model.connected ? "Verbunden über \(model.connectionType)" : "Nicht verbunden",
                          systemImage: model.connected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.connected ? .green : .secondary)
                }
                if model.connected {
                    if model.headsetOn == false {
                        LabeledContent("Akku") { Text("Headset ausgeschaltet").foregroundStyle(.secondary) }
                    } else if let b = model.battery {
                        LevelRow(title: model.charging ? "Akku (lädt)" : "Akku",
                                 symbol: model.charging ? "battery.100.bolt"
                                     : b > 60 ? "battery.75" : b > 25 ? "battery.50" : "battery.25",
                                 value: Double(b) / 100,
                                 tint: b > 20 ? .green : .red)
                    }
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
                Toggle("Power-Taste als Medientaste (1× Play/Pause, 2× Weiter, 3× Zurück)",
                       isOn: $model.mediaKeysEnabled)
                if model.mediaKeysEnabled && !model.accessibilityTrusted {
                    HStack {
                        Label("Dafür braucht ChatMix eine Freigabe unter Bedienungshilfen.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Freigeben …") { model.requestAccessibility() }
                    }
                }
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
