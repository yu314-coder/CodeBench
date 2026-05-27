//
//  ADBFastboot.swift
//  CodeBench
//
//  Self-contained ADB + fastboot client for iOS. Drop this folder in
//  to enable, delete the whole folder to remove. Nothing outside the
//  folder references these types.
//
//  Tested target: iPhone 16 Pro (USB-C, iOS 17+), iPad M3 (USB-C,
//  iPadOS 17+). Older Lightning iPads / pre-USB-C iPhones won't have
//  a USB-C cable path; they can still use the Wi-Fi route.
//
//  ───────────────────────────────────────────────────────────────────
//  How USB-C cable works (the part you specifically asked about)
//  ───────────────────────────────────────────────────────────────────
//
//  iOS apps can't open raw USB bulk endpoints — that requires a
//  Driver Extension target with an Apple-approved entitlement
//  (com.apple.developer.driverkit.transport.usb), which is a
//  separate Xcode target type and can't live inside this folder.
//
//  However, USB-C *does* work for ADB through this path, with NO
//  special entitlement, NO dext, and nothing outside this folder:
//
//      ┌────────────────────────────┐
//      │ iPhone 16 Pro / iPad M3    │
//      │  ── USB-C cable ──────────►│ ◄─── Android USB tethering
//      │  iOS sees Android as a     │      (RNDIS / NCM ethernet
//      │  wired ethernet interface  │       over USB; standard Linux
//      │                            │       gadget on every Android)
//      └────────────────────────────┘
//                ▲
//                │ adb-over-network (port 5555)
//                │
//                ▼
//      ┌────────────────────────────┐
//      │ adbd on the Android device │
//      │ (listening on the tethered │
//      │  IP, e.g. 192.168.42.129)  │
//      └────────────────────────────┘
//
//  Setup on the user side (one-time):
//    1. On Android: Settings → Network & Internet → Hotspot &
//       tethering → enable "USB tethering".
//    2. On Android: Settings → System → Developer options →
//       enable "Wireless debugging".
//    3. Plug Android into iPhone 16 Pro / iPad M3 via USB-C.
//    4. From this app:
//         try ADBFastboot.adbShell(host: "192.168.42.129",
//                                  cmd: "getprop ro.product.model")
//
//  The IP can be auto-discovered via USBTetheringHelper. The byte
//  stream travels through the USB-C cable end-to-end — there's no
//  Wi-Fi involved even though the framing is TCP.
//
//  ───────────────────────────────────────────────────────────────────
//  Files in this folder
//  ───────────────────────────────────────────────────────────────────
//
//   • ADBFastboot.swift              ← you are here; public umbrella API
//   • ADBWireProtocol.swift          ← Message struct, command magics
//   • ADBNetworkTransport.swift      ← NWConnection-backed TCP transport
//   • ADBClient.swift                ← CNXN handshake, shell, push, pull, reboot
//   • FastbootClient.swift           ← Fastboot-over-TCP (getvar/flash/erase/reboot)
//   • USBTetheringHelper.swift       ← Auto-detect tethered Android interface
//   • README.md                      ← End-user setup guide + API examples
//

import Foundation

// MARK: - Public umbrella

/// Public namespace for the ADBFastboot module. Use the static convenience
/// functions for one-shot calls; for anything more involved (multi-shot
/// sessions, streaming, etc.) construct ``ADBClient`` / ``FastbootClient``
/// directly.
public enum ADBFastboot {

    /// Package version. Bumped manually when the wire-protocol code or
    /// public API changes.
    public static let version = "0.1.0"

    /// Standard ADB-over-network port. Android's adbd listens on this
    /// once the user enables "Wireless debugging" on the device.
    public static let defaultADBPort: UInt16 = 5555

    /// Standard fastboot-over-TCP port. Available on Android 12+ devices
    /// when in the bootloader with TCP mode enabled.
    public static let defaultFastbootPort: UInt16 = 5554

    // MARK: One-shot ADB convenience

    /// Run a single shell command against an Android device and return
    /// its combined stdout+stderr. Opens, runs, closes — no session
    /// kept open after this call returns.
    @discardableResult
    public static func adbShell(
        host: String,
        port: UInt16 = defaultADBPort,
        cmd: String,
        timeout: TimeInterval = 10
    ) throws -> String {
        let client = ADBClient(host: host, port: port, timeout: timeout)
        try client.connect()
        defer { client.disconnect() }
        return try client.shell(cmd)
    }

    /// One-shot push: upload a local file to ``remotePath`` on the device.
    /// Returns the number of bytes sent.
    @discardableResult
    public static func adbPush(
        host: String,
        port: UInt16 = defaultADBPort,
        localPath: URL,
        remotePath: String,
        timeout: TimeInterval = 30
    ) throws -> Int {
        let client = ADBClient(host: host, port: port, timeout: timeout)
        try client.connect()
        defer { client.disconnect() }
        return try client.push(local: localPath, remote: remotePath)
    }

    /// One-shot pull: download ``remotePath`` from the device to a local
    /// URL. Returns the number of bytes received.
    @discardableResult
    public static func adbPull(
        host: String,
        port: UInt16 = defaultADBPort,
        remotePath: String,
        localPath: URL,
        timeout: TimeInterval = 30
    ) throws -> Int {
        let client = ADBClient(host: host, port: port, timeout: timeout)
        try client.connect()
        defer { client.disconnect() }
        return try client.pull(remote: remotePath, local: localPath)
    }

    /// Reboot the device. ``mode`` may be empty (normal reboot),
    /// `"bootloader"`, `"recovery"`, or `"sideload"`.
    public static func adbReboot(
        host: String,
        port: UInt16 = defaultADBPort,
        mode: String = "",
        timeout: TimeInterval = 10
    ) throws {
        let client = ADBClient(host: host, port: port, timeout: timeout)
        try client.connect()
        defer { client.disconnect() }
        try client.reboot(mode: mode)
    }

    // MARK: One-shot fastboot convenience

    /// Read one bootloader variable (e.g. "version", "product", "serialno",
    /// "slot-count"). Device must be in the bootloader with TCP mode on.
    public static func fastbootGetvar(
        host: String,
        port: UInt16 = defaultFastbootPort,
        name: String,
        timeout: TimeInterval = 30
    ) throws -> String {
        let client = FastbootClient(host: host, port: port, timeout: timeout)
        try client.connect()
        defer { client.disconnect() }
        return try client.getvar(name)
    }

    /// Reboot out of the bootloader (back to normal Android).
    public static func fastbootReboot(
        host: String,
        port: UInt16 = defaultFastbootPort,
        timeout: TimeInterval = 30
    ) throws {
        let client = FastbootClient(host: host, port: port, timeout: timeout)
        try client.connect()
        defer { client.disconnect() }
        try client.reboot()
    }

    /// Flash a partition (e.g. "boot", "system") with the contents of a
    /// local file. Device must be in the bootloader.
    public static func fastbootFlash(
        host: String,
        port: UInt16 = defaultFastbootPort,
        partition: String,
        filePath: URL,
        timeout: TimeInterval = 120
    ) throws {
        let client = FastbootClient(host: host, port: port, timeout: timeout)
        try client.connect()
        defer { client.disconnect() }
        try client.flash(partition: partition, filePath: filePath)
    }

    // MARK: CLI-style entry points
    //
    // These match the argv-shaped main() shape so the in-app shell can
    // wire them in with a single ``builtin("adb")`` registration.

    /// CLI entry point: ``adb [-s host[:port]] <command> [args]``.
    /// Writes output to stdout and errors to stderr; returns an exit code.
    public static func adbMain(_ argv: [String]) -> Int32 {
        return ADBCLI.run(argv: argv)
    }

    /// CLI entry point: ``fastboot [-s host[:port]] <command> [args]``.
    public static func fastbootMain(_ argv: [String]) -> Int32 {
        return FastbootCLI.run(argv: argv)
    }
}

// MARK: - Errors

/// Anything that goes wrong inside the ADB protocol layer.
public enum ADBError: Error, LocalizedError {
    /// Device requires an RSA-signed AUTH response. The pure-Swift
    /// implementation doesn't sign — the host needs to be pre-authorized
    /// from a desktop ``adb`` first.
    case authRequired
    /// Generic protocol mismatch — checksum failure, bad magic, etc.
    case protocolError(String)
    /// The device refused a stream-open request (e.g. wrong shell command).
    case streamRefused(String)
    /// Got a command we didn't expect at this point in the state machine.
    case unexpectedCommand(UInt32, expected: String)
    /// The transport reported a problem we can't recover from.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .authRequired:
            return "device requires AUTH (RSA-signed challenge). " +
                   "Pair the device with desktop adb once so it remembers " +
                   "this host, then retry."
        case .protocolError(let s):
            return "ADB protocol error: \(s)"
        case .streamRefused(let dest):
            return "ADB stream refused for destination: \(dest)"
        case .unexpectedCommand(let cmd, let expected):
            return "expected \(expected), got command 0x\(String(cmd, radix: 16))"
        case .transport(let s):
            return "ADB transport error: \(s)"
        }
    }
}

/// Anything that goes wrong during a fastboot exchange.
public enum FastbootError: Error, LocalizedError {
    case handshakeFailed(String)
    case command(String)
    case dataPhaseFailed(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .handshakeFailed(let s):
            return "fastboot handshake failed: \(s)"
        case .command(let s):
            return "fastboot command failed: \(s)"
        case .dataPhaseFailed(let s):
            return "fastboot data phase failed: \(s)"
        case .transport(let s):
            return "fastboot transport error: \(s)"
        }
    }
}
