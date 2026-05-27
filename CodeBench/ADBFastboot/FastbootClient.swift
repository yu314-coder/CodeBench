//
//  FastbootClient.swift
//  CodeBench
//
//  Fastboot-over-TCP client. Mirrors the framing the Android Open
//  Source Project's fastboot binary uses when given a `tcp:<host>`
//  serial spec.
//
//  Wire format:
//    Each side, every send, prefixes its payload with an 8-byte
//    big-endian length, then sends the payload bytes. A "command"
//    is one ASCII string up to 64 bytes long; a "response" starts
//    with a 4-byte ASCII tag (OKAY / FAIL / INFO / DATA) followed
//    by up to 60 bytes of message body.
//
//  Used in conjunction with the same NWConnection-backed transport
//  as ADB — most user-facing setups will be:
//
//      Android bootloader (TCP mode)  ◄── USB-C cable ──  iPad M3
//
//  via Android USB tethering. See USBTetheringHelper for setup.
//

import Foundation
import Network

/// One fastboot session (one TCP socket to a bootloader endpoint).
public final class FastbootClient {

    public let host: String
    public let port: UInt16

    /// Device's handshake reply ("FB" + version digits, 4 bytes).
    /// Populated by ``connect()``.
    public private(set) var handshake: String?

    private let transport: ADBNetworkTransport

    public init(host: String,
                port: UInt16 = ADBFastboot.defaultFastbootPort,
                timeout: TimeInterval = 30) {
        self.host = host
        self.port = port
        self.transport = ADBNetworkTransport(host: host, port: port, timeout: timeout)
    }

    // MARK: - Lifecycle

    /// Open the TCP socket and perform the fastboot-over-TCP handshake.
    /// Both sides exchange 4 bytes: ASCII "FB" + a 2-digit version
    /// (we send "01"). Anything starting with non-"FB" → throw.
    public func connect() throws {
        try transport.connect()

        let ours = Data("FB01".utf8)
        try transport.send(ours)

        let theirs = try transport.receive(4)
        guard theirs.starts(with: Data("FB".utf8)) else {
            transport.disconnect()
            let hex = theirs.map { String(format: "%02x", $0) }.joined()
            throw FastbootError.handshakeFailed("device sent: 0x\(hex)")
        }
        self.handshake = String(data: theirs, encoding: .ascii)
    }

    public func disconnect() {
        transport.disconnect()
    }

    // MARK: - Commands

    /// Read one bootloader variable. Common names: "version",
    /// "product", "serialno", "slot-count", "current-slot",
    /// "max-download-size".
    public func getvar(_ name: String) throws -> String {
        let (ok, info, _) = try command("getvar:\(name)")
        if !ok { throw FastbootError.command("getvar(\(name)): \(info)") }
        return info
    }

    /// Reboot out of the bootloader to normal Android. The device
    /// closes the socket as it reboots — we swallow that.
    public func reboot() throws {
        do {
            _ = try command("reboot")
        } catch FastbootError.transport, FastbootError.command {
            // Expected on reboot.
        }
    }

    /// Reboot back into the bootloader.
    public func rebootBootloader() throws {
        do {
            _ = try command("reboot-bootloader")
        } catch FastbootError.transport, FastbootError.command {}
    }

    /// Leave the bootloader and continue normal boot (e.g. after a
    /// firmware update that left the device in the bootloader).
    public func continueBoot() throws {
        do {
            _ = try command("continue")
        } catch FastbootError.transport, FastbootError.command {}
    }

    /// Flash a partition with the contents of a local file.
    /// Two-phase: ``download:<hex-size>`` then ``flash:<partition>``.
    public func flash(partition: String, filePath: URL) throws {
        let data = try Data(contentsOf: filePath)

        // Phase 1: ask the device to accept a download.
        let sizeHex = String(format: "%08x", data.count)
        let (ok1, info1, size) = try command("download:\(sizeHex)")
        if !ok1 {
            throw FastbootError.dataPhaseFailed("download phase: \(info1)")
        }
        // ``size`` is the device's expected payload length from the
        // DATA response. Sanity-check it matches what we said.
        if let s = size, s != data.count {
            throw FastbootError.dataPhaseFailed(
                "device expects \(s) bytes, we have \(data.count)"
            )
        }
        // Send the bytes (framed with the same 8-byte length prefix).
        try sendFramed(data)
        // Device should respond OKAY now.
        let ack = try recvResponse()
        guard ack.starts(with: Data("OKAY".utf8)) else {
            let body = String(data: ack.dropFirst(4),
                              encoding: .ascii) ?? "(non-ascii)"
            throw FastbootError.dataPhaseFailed(
                "download didn't OKAY: tag=\(ascii(ack.prefix(4))) body=\(body)"
            )
        }

        // Phase 2: tell the device to flash what we just sent.
        let (ok2, info2, _) = try command("flash:\(partition)")
        if !ok2 {
            throw FastbootError.command("flash \(partition): \(info2)")
        }
    }

    /// Erase a partition (zero-fill its blocks).
    public func erase(partition: String) throws {
        let (ok, info, _) = try command("erase:\(partition)")
        if !ok { throw FastbootError.command("erase \(partition): \(info)") }
    }

    /// Send an arbitrary fastboot command line and return the response
    /// text. Escape hatch for OEM-specific commands (``oem unlock``,
    /// ``oem device-info``) and any verb not modeled explicitly.
    ///
    /// Separator convention varies by command family:
    ///   • ``getvar:<name>``     — colon (use ``.getvar``)
    ///   • ``flash:<partition>`` — colon (use ``.flash``)
    ///   • ``oem <subcommand>``  — SPACE (pass through here)
    ///
    /// So a typical OEM call is ``client.raw("oem unlock")``.
    @discardableResult
    public func raw(_ commandLine: String) throws -> String {
        let (ok, info, _) = try command(commandLine)
        if !ok {
            throw FastbootError.command("\(commandLine): \(info)")
        }
        return info
    }

    // MARK: - Protocol primitives

    /// Send one fastboot command and drain responses until we hit
    /// OKAY / FAIL / DATA. Returns (success, info-or-error, optional-data-size).
    private func command(_ cmd: String) throws -> (Bool, String, Int?) {
        let bytes = Data(cmd.utf8)
        guard bytes.count <= 64 else {
            throw FastbootError.command("command too long (\(bytes.count) > 64): \(cmd)")
        }
        try sendFramed(bytes)

        var infos: [String] = []
        while true {
            let resp = try recvResponse()
            let tag  = resp.prefix(4)
            let body = String(data: resp.dropFirst(4), encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

            switch ascii(tag) {
            case "INFO":
                infos.append(body)
            case "OKAY":
                let joined = (infos + (body.isEmpty ? [] : [body])).joined(separator: "\n")
                return (true, joined, nil)
            case "FAIL":
                return (false, (infos + [body]).joined(separator: "\n"), nil)
            case "DATA":
                guard let size = Int(body, radix: 16) else {
                    throw FastbootError.command("bad DATA size from device: \(body)")
                }
                return (true, infos.joined(separator: "\n"), size)
            default:
                throw FastbootError.command("unknown fastboot tag \(ascii(tag))")
            }
        }
    }

    /// Wrap ``payload`` in the 8-byte big-endian length prefix and send.
    private func sendFramed(_ payload: Data) throws {
        var len = UInt64(payload.count).bigEndian
        var hdr = Data(count: 8)
        Swift.withUnsafeBytes(of: &len) { raw in
            hdr.replaceSubrange(0..<8, with: raw.bindMemory(to: UInt8.self))
        }
        try transport.send(hdr + payload)
    }

    /// Read one 8-byte big-endian length, then that many payload bytes.
    private func recvResponse() throws -> Data {
        let hdr = try transport.receive(8)
        var len: UInt64 = 0
        for i in 0..<8 { len = (len << 8) | UInt64(hdr[hdr.startIndex + i]) }
        if len == 0 { return Data() }
        if len > 4096 {
            throw FastbootError.command(
                "absurd fastboot response length \(len) — protocol desync"
            )
        }
        return try transport.receive(Int(len))
    }

    /// Decode a 4-byte tag region as ASCII (purely for log strings).
    private func ascii(_ d: Data) -> String {
        return String(data: d, encoding: .ascii) ?? "(?)"
    }
}

// MARK: - fastboot CLI entry point

enum FastbootCLI {

    static let usage = """
    Usage: fastboot [options] <command> [args]

    Options:
      -s, -H <host[:port]>    target (default: 127.0.0.1:5554)
      -P <port>               port   (default: 5554)
      -t <seconds>            timeout (default: 30)

    Commands:
      getvar <name>             read a bootloader variable
      reboot                    reboot to normal mode
      reboot-bootloader         reboot back into the bootloader
      flash <partition> <file>  flash partition from a local file
      erase <partition>         erase partition
      continue                  leave bootloader, continue boot
      oem <subcommand> ...      OEM-specific command (passed through)
      <anything-else>           passed to the device verbatim
      help                      this message

    Notes:
      • TCP only — device must be in fastboot mode with TCP enabled
        (Android 12+).
      • USB-C cable: enable USB tethering on the device first; iOS
        sees it as a wired-ethernet interface and the bootloader's
        TCP endpoint is reachable on the tethered IP.
    """

    static func run(argv: [String]) -> Int32 {
        var host = "127.0.0.1"
        var port: UInt16 = ADBFastboot.defaultFastbootPort
        var timeout: TimeInterval = 30

        var i = 0
        while i < argv.count, argv[i].hasPrefix("-") {
            let opt = argv[i]
            switch opt {
            case "-s", "-H":
                guard i + 1 < argv.count else {
                    err("fastboot: \(opt) needs an argument\n"); return 2
                }
                (host, port) = parseTarget(argv[i + 1], defaultPort: port)
                i += 2
            case "-P":
                guard i + 1 < argv.count, let p = UInt16(argv[i + 1]) else {
                    err("fastboot: -P needs a port number\n"); return 2
                }
                port = p; i += 2
            case "-t":
                guard i + 1 < argv.count, let t = TimeInterval(argv[i + 1]) else {
                    err("fastboot: -t needs a seconds value\n"); return 2
                }
                timeout = t; i += 2
            case "-h", "--help", "help":
                out(usage + "\n"); return 0
            default:
                err("fastboot: unknown option \(opt)\n\(usage)\n"); return 2
            }
        }

        guard i < argv.count else { out(usage + "\n"); return 1 }
        let cmd = argv[i]
        let rest = Array(argv[(i + 1)...])

        do {
            let fb = FastbootClient(host: host, port: port, timeout: timeout)
            try fb.connect()
            defer { fb.disconnect() }

            switch cmd {
            case "getvar":
                guard let name = rest.first else {
                    err("fastboot: getvar needs a variable name\n"); return 2
                }
                out(try fb.getvar(name) + "\n"); return 0
            case "reboot":
                try fb.reboot(); out("reboot sent\n"); return 0
            case "reboot-bootloader":
                try fb.rebootBootloader(); out("reboot-bootloader sent\n"); return 0
            case "continue":
                try fb.continueBoot(); out("continue sent\n"); return 0
            case "flash":
                guard rest.count == 2 else {
                    err("fastboot: usage: flash <partition> <file>\n"); return 2
                }
                try fb.flash(partition: rest[0],
                             filePath: URL(fileURLWithPath: rest[1]))
                out("flashed \(rest[0]) from \(rest[1])\n"); return 0
            case "erase":
                guard let part = rest.first else {
                    err("fastboot: usage: erase <partition>\n"); return 2
                }
                try fb.erase(partition: part)
                out("erased \(part)\n"); return 0
            default:
                // Generic pass-through. Anything we don't recognise gets
                // reassembled into a single command line and sent verbatim:
                //   fastboot oem unlock      → "oem unlock"
                //   fastboot snapshot-update → "snapshot-update"
                //   fastboot get_staged ...  → "get_staged ..."
                let rawCmd = ([cmd] + rest).joined(separator: " ")
                let info = try fb.raw(rawCmd)
                if !info.isEmpty { out(info + "\n") }
                return 0
            }
        } catch {
            err("fastboot: \(error.localizedDescription)\n"); return 1
        }
    }

    // ──────────────────────────────────────────────────────────────

    private static func parseTarget(_ spec: String, defaultPort: UInt16) -> (String, UInt16) {
        if let colon = spec.lastIndex(of: ":"),
           let p = UInt16(spec[spec.index(after: colon)...]) {
            return (String(spec[..<colon]), p)
        }
        return (spec, defaultPort)
    }
    private static func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
    private static func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
}
