// micwatch — notifies Home Assistant when the default audio input device
// starts or stops being used, as a proxy for "on a call".
//
// The signal is CoreAudio's kAudioDevicePropertyDeviceIsRunningSomewhere, which
// reports whether ANY process is running I/O on the device. Reading it requires
// no microphone access, so this daemon triggers no privacy prompts at all.
//
// Webhooks are fired with /usr/bin/curl rather than URLSession: curl is not
// subject to App Transport Security, which would otherwise block plain HTTP to
// a LAN address from a binary that has no Info.plist.

import CoreAudio
import Foundation
#if canImport(AppKit)
import AppKit
#endif

// ── logging ─────────────────────────────────────────────────────────────────
setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

@Sendable func log(_ message: String) {
    print("[\(stamp.string(from: Date()))] \(message)")
}

// ── configuration ───────────────────────────────────────────────────────────
// Settings come from the environment first, then from a config file
// (~/.config/micwatch/config by default, override with MICWATCH_CONFIG), so
// webhook URLs stay out of this source file and out of git.

let configPath = ProcessInfo.processInfo.environment["MICWATCH_CONFIG"]
    ?? "\(NSHomeDirectory())/.config/micwatch/config"

/// Parses a simple KEY=value file. Blank lines and # comments are ignored; an
/// optional `export ` prefix and surrounding quotes are stripped.
func loadConfigFile(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var settings: [String: String] = [:]
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let separator = line.firstIndex(of: "=") else { continue }
        var key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("export ") { key = String(key.dropFirst("export ".count)) }
        var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        settings[key] = value
    }
    return settings
}

let fileSettings = loadConfigFile(configPath)

func setting(_ key: String) -> String? {
    if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
    if let value = fileSettings[key], !value.isEmpty { return value }
    return nil
}

// ── CoreAudio helpers ───────────────────────────────────────────────────────
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultInputDevice() -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size, &device)
    return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
}

func isInUse(_ device: AudioObjectID) -> Bool {
    guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
    var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
    return status == noErr && value != 0
}

func deviceName(_ device: AudioObjectID) -> String {
    guard device != AudioObjectID(kAudioObjectUnknown) else { return "none" }
    var addr = address(kAudioObjectPropertyName)
    var name: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
    }
    return status == noErr ? (name as String? ?? "unknown") : "unknown"
}

// ── argument handling and required settings ─────────────────────────────────
let args = CommandLine.arguments

if args.contains("--once") {
    // Device state only, so this works without any configuration.
    let device = defaultInputDevice()
    print("device=\(deviceName(device)) id=\(device) inUse=\(isInUse(device))")
    exit(0)
}

guard let startURL = setting("MICWATCH_START_URL"),
      let endURL = setting("MICWATCH_END_URL") else {
    let message = """
        micwatch: missing MICWATCH_START_URL and/or MICWATCH_END_URL.
        Set them in \(configPath) or in the environment. See config.example.
        """
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(78)  // EX_CONFIG
}

/// Seconds the mic must stay continuously idle before call-end is sent.
/// Switching audio devices mid-call briefly drops the in-use flag, so this
/// must be comfortably longer than a device switch takes.
let idleDebounce = setting("MICWATCH_IDLE_SECONDS").flatMap(Double.init) ?? 10
let httpTimeout = setting("MICWATCH_HTTP_TIMEOUT") ?? "2"

// ── config check ────────────────────────────────────────────────────────────
if args.contains("--check") {
    // Webhook IDs are secrets, so mask them: output is safe to paste into an issue.
    func masked(_ url: String) -> String {
        guard let id = url.split(separator: "/").last, id.count > 8 else { return url }
        let hint = id.prefix(4) + "..." + id.suffix(4)
        return url.replacingOccurrences(of: String(id), with: String(hint))
    }
    print("config:         \(configPath)")
    print("start webhook:  \(masked(startURL))")
    print("end webhook:    \(masked(endURL))")
    print("idle debounce:  \(Int(idleDebounce))s")
    print("http timeout:   \(httpTimeout)s")
    exit(0)
}

// ── state ───────────────────────────────────────────────────────────────────
enum Event: String { case start, end }

let stateQueue = DispatchQueue(label: "micwatch.state")  // serializes all state below
let netQueue = DispatchQueue(label: "micwatch.net")      // serial, so POSTs keep their order

var lastSent: Event?
var idleTimer: DispatchSourceTimer?
var watchedDevice = AudioObjectID(kAudioObjectUnknown)

// ── webhooks (fire and forget) ──────────────────────────────────────────────
@Sendable func post(_ url: String, label: String, waitForCompletion: Bool = false) {
    let work: @Sendable () -> Void = {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                          "-X", "POST",
                          "--connect-timeout", httpTimeout,
                          "--max-time", httpTimeout,
                          "--retry", "0",
                          url]
        let out = Pipe()
        curl.standardOutput = out
        curl.standardError = Pipe()
        guard (try? curl.run()) != nil else { return }
        let code = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? "?"
        curl.waitUntilExit()
        if curl.terminationStatus == 0 && code.hasPrefix("2") {
            log("    \(label) delivered (HTTP \(code))")
        } else {
            // Away from the home network, HA restarting, etc. Expected: no retry, no noise.
            log("    \(label) not delivered (curl \(curl.terminationStatus), HTTP \(code))")
        }
    }
    if waitForCompletion { work() } else { netQueue.async(execute: work) }
}

/// Sends an event unless it is identical to the previous one.
func send(_ event: Event, waitForCompletion: Bool = false) {
    guard lastSent != event else { return }
    lastSent = event
    log("--> POST call-\(event.rawValue)")
    post(event == .start ? startURL : endURL,
         label: "call-\(event.rawValue)",
         waitForCompletion: waitForCompletion)
}

// ── transition logic (always runs on stateQueue) ────────────────────────────
func evaluate(_ reason: String) {
    let device = defaultInputDevice()

    if isInUse(device) {
        if idleTimer != nil {
            log("mic active again within debounce window (\(reason)) — cancelling call-end")
            idleTimer?.cancel()
            idleTimer = nil
        }
        if lastSent != .start { log("mic ACTIVE — \(reason)") }
        send(.start)
        return
    }

    if idleTimer != nil { return }   // already counting down
    if lastSent == .end { return }   // nothing to report

    log("mic idle — \(reason); waiting \(Int(idleDebounce))s before call-end")
    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now() + idleDebounce)
    timer.setEventHandler {
        idleTimer = nil
        if isInUse(defaultInputDevice()) {
            log("mic still in use after debounce — no call-end")
            send(.start)
        } else {
            log("mic idle for \(Int(idleDebounce))s")
            send(.end)
        }
    }
    idleTimer = timer
    timer.resume()
}

// ── listener wiring ─────────────────────────────────────────────────────────
let inUseListener: AudioObjectPropertyListenerBlock = { _, _ in
    evaluate("device in-use changed")
}

func watch(_ device: AudioObjectID) {
    var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    if watchedDevice != AudioObjectID(kAudioObjectUnknown) {
        AudioObjectRemovePropertyListenerBlock(watchedDevice, &addr, stateQueue, inUseListener)
    }
    watchedDevice = device
    guard device != AudioObjectID(kAudioObjectUnknown) else {
        log("no default input device")
        return
    }
    let status = AudioObjectAddPropertyListenerBlock(device, &addr, stateQueue, inUseListener)
    if status == noErr {
        log("watching input device: \(deviceName(device)) [id \(device)]")
    } else {
        log("warning: could not add listener to device \(device) (status \(status))")
    }
}

let defaultDeviceListener: AudioObjectPropertyListenerBlock = { _, _ in
    let device = defaultInputDevice()
    if device != watchedDevice {
        log("default input device changed to \(deviceName(device))")
        watch(device)
    }
    evaluate("default input device changed")
}

// ── manual webhook test ─────────────────────────────────────────────────────
if let index = args.firstIndex(of: "--fire"), index + 1 < args.count {
    guard let event = Event(rawValue: args[index + 1]) else {
        print("usage: micwatch --fire start|end")
        exit(2)
    }
    post(event == .start ? startURL : endURL,
         label: "call-\(event.rawValue)",
         waitForCompletion: true)
    exit(0)
}

// ── run ─────────────────────────────────────────────────────────────────────
log("micwatch starting (pid \(getpid()))")
log("config: \(configPath)")

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: stateQueue)
    source.setEventHandler {
        log("received signal \(sig), shutting down")
        if lastSent == .start { send(.end, waitForCompletion: true) }
        exit(0)
    }
    source.resume()
    signalSources.append(source)   // keep alive for the process lifetime
}

var systemAddr = address(kAudioHardwarePropertyDefaultInputDevice)
let systemStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                       &systemAddr, stateQueue, defaultDeviceListener)
if systemStatus != noErr {
    log("warning: could not watch default-input-device changes (status \(systemStatus))")
}

#if canImport(AppKit)
// The CoreAudio listener can miss a transition that happened across sleep.
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                  object: nil, queue: nil) { _ in
    stateQueue.async { evaluate("system wake") }
}
#endif

stateQueue.async {
    watch(defaultInputDevice())
    send(.end)              // resync HA after a reboot, or a call-end it missed
    evaluate("startup")     // ...then correct that if a call is already in progress
}

RunLoop.main.run()
