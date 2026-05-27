//
//  ADBClient.swift
//  CodeBench
//
//  High-level ADB client. Connects to adbd, runs shell commands,
//  pushes / pulls files, reboots the device.
//

import Foundation

/// One ADB session to a single device (one TCP socket under the hood).
public final class ADBClient {

    public let host: String
    public let port: UInt16

    /// Device's CNXN banner (e.g. "device::ro.product.name=…").
    /// Populated by ``connect()``; nil if not connected.
    public private(set) var banner: String?

    private let transport: ADBNetworkTransport
    private var nextLocalId: UInt32 = 1

    /// Host identity sent in the CNXN handshake. Real adb uses
    /// "host::" plus optional feature flags; we tag with the app
    /// name so devices' authorized-hosts lists are readable.
    private static let hostBanner = "host::adb-codebench"

    public init(host: String,
                port: UInt16 = ADBFastboot.defaultADBPort,
                timeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.transport = ADBNetworkTransport(host: host, port: port, timeout: timeout)
    }

    // MARK: - Lifecycle

    /// Open the TCP socket and complete the ADB CNXN handshake.
    /// Throws ``ADBError.authRequired`` if the device wants an RSA-
    /// signed AUTH (we don't sign — pre-authorize once from desktop).
    public func connect() throws {
        try transport.connect()

        let cnxn = ADBMessage(
            command: ADBCommand.cnxn.rawValue,
            arg0: A_VERSION,
            arg1: MAX_PAYLOAD,
            data: Data(ADBClient.hostBanner.utf8)
        )
        try transport.sendMessage(cnxn)

        let reply = try transport.receiveMessage()
        if reply.command == ADBCommand.auth.rawValue {
            transport.disconnect()
            throw ADBError.authRequired
        }
        guard reply.command == ADBCommand.cnxn.rawValue else {
            transport.disconnect()
            throw ADBError.unexpectedCommand(reply.command, expected: "CNXN")
        }
        // Banner is null-padded; strip controls.
        self.banner = String(data: reply.data, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    public func disconnect() {
        transport.disconnect()
    }

    // MARK: - Shell

    /// Run one shell command on the device, return its combined output.
    /// Interactive PTY shells aren't supported — pass a single line.
    public func shell(_ cmd: String) throws -> String {
        let dest = Data("shell:\(cmd)".utf8)
        let bytes = try openStreamCollect(destination: dest)
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - Reboot

    /// Reboot device. ``mode`` may be empty, "bootloader", "recovery",
    /// or "sideload". The socket gets torn down by the device as it
    /// reboots — that's expected; we swallow that disconnect.
    public func reboot(mode: String = "") throws {
        let dest = Data("reboot:\(mode)".utf8)
        do {
            _ = try openStreamCollect(destination: dest)
        } catch let e as ADBError {
            // Acceptable: transport closed mid-reboot.
            if case .transport = e { return }
            throw e
        }
    }

    // MARK: - File push / pull (SYNC sub-protocol)

    /// Push a local file to ``remote``. Returns bytes sent.
    @discardableResult
    public func push(local localURL: URL, remote: String, mode: UInt32 = 0o644) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let mtime = UInt32(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        let data = try Data(contentsOf: localURL)
        return try syncSend(remotePath: remote, data: data, mode: mode, mtime: mtime)
    }

    /// Pull ``remote`` from device to a local URL. Returns bytes received.
    @discardableResult
    public func pull(remote: String, local localURL: URL) throws -> Int {
        let data = try syncRecv(remotePath: remote)
        try data.write(to: localURL, options: .atomic)
        return data.count
    }

    // MARK: - Stream primitives

    private func allocLocalId() -> UInt32 {
        defer { nextLocalId &+= 1 }
        return nextLocalId
    }

    /// Open a stream and return the negotiated (localId, remoteId).
    private func openStream(destination: Data) throws -> (UInt32, UInt32) {
        let localId = allocLocalId()
        // Trailing NUL is required.
        var dst = destination
        if dst.last != 0 { dst.append(0) }

        try transport.sendMessage(ADBMessage(
            command: ADBCommand.open.rawValue,
            arg0: localId, arg1: 0,
            data: dst
        ))
        let reply = try transport.receiveMessage()
        if reply.command == ADBCommand.clse.rawValue {
            let label = String(data: destination, encoding: .utf8) ?? "(binary)"
            throw ADBError.streamRefused(label)
        }
        guard reply.command == ADBCommand.okay.rawValue else {
            throw ADBError.unexpectedCommand(reply.command, expected: "OKAY")
        }
        return (localId, reply.arg0)
    }

    /// Open a stream, read all WRTE payloads until CLSE, return collected bytes.
    private func openStreamCollect(destination: Data) throws -> Data {
        let (localId, remoteId) = try openStream(destination: destination)
        var collected = Data()
        while true {
            let msg = try transport.receiveMessage()
            switch ADBCommand(rawValue: msg.command) {
            case .wrte:
                collected.append(msg.data)
                // Ack so the device sends more.
                try transport.sendMessage(ADBMessage(
                    command: ADBCommand.okay.rawValue,
                    arg0: localId, arg1: remoteId,
                    data: Data()
                ))
            case .clse:
                // Polite ack so the device cleans up.
                try transport.sendMessage(ADBMessage(
                    command: ADBCommand.clse.rawValue,
                    arg0: localId, arg1: remoteId,
                    data: Data()
                ))
                return collected
            default:
                throw ADBError.unexpectedCommand(
                    msg.command,
                    expected: "WRTE/CLSE during stream"
                )
            }
        }
    }

    // MARK: - SYNC sub-protocol (used by push/pull)
    //
    // SYNC is a tiny request/response framing nested inside a "sync:"
    // stream. Each frame:
    //
    //     ┌─ id  (4 ASCII)   "SEND" / "RECV" / "DATA" / "DONE" / ...
    //     └─ arg (4 LE u32)  meaning varies by id
    //
    // For SEND/RECV the arg is the byte-length of the path that
    // follows; for DATA it's the chunk length; for DONE it's mtime.

    private func syncOpen() throws -> (UInt32, UInt32) {
        return try openStream(destination: Data("sync:".utf8))
    }

    private func syncSend(remotePath: String, data: Data, mode: UInt32, mtime: UInt32) throws -> Int {
        let (localId, remoteId) = try syncOpen()
        let pathMode = Data("\(remotePath),\(mode)".utf8)

        // SEND <path,mode>
        var sendReq = Data("SEND".utf8)
        sendReq.appendUInt32LE(UInt32(pathMode.count))
        sendReq.append(pathMode)
        try syncWrite(localId: localId, remoteId: remoteId, payload: sendReq)

        // DATA chunks (max 64KiB per upstream impl)
        let chunkSize = 64 * 1024
        var sent = 0
        var i = 0
        while i < data.count {
            let end = min(i + chunkSize, data.count)
            let chunk = data.subdata(in: i..<end)
            var req = Data("DATA".utf8)
            req.appendUInt32LE(UInt32(chunk.count))
            req.append(chunk)
            try syncWrite(localId: localId, remoteId: remoteId, payload: req)
            sent += chunk.count
            i = end
        }

        // DONE <mtime>
        var done = Data("DONE".utf8)
        done.appendUInt32LE(mtime)
        try syncWrite(localId: localId, remoteId: remoteId, payload: done)

        // Expect OKAY back
        let resp = try syncRead(localId: localId, remoteId: remoteId)
        let tag = resp.prefix(4)
        if tag != Data("OKAY".utf8) {
            let msg = String(data: resp.dropFirst(8), encoding: .utf8) ?? "(binary)"
            throw ADBError.protocolError("SEND failed: \(msg)")
        }

        // Polite QUIT (some adbd variants need it; cheap)
        var quit = Data("QUIT".utf8); quit.appendUInt32LE(0)
        try? syncWrite(localId: localId, remoteId: remoteId, payload: quit)

        return sent
    }

    private func syncRecv(remotePath: String) throws -> Data {
        let (localId, remoteId) = try syncOpen()
        let pathBytes = Data(remotePath.utf8)

        var req = Data("RECV".utf8)
        req.appendUInt32LE(UInt32(pathBytes.count))
        req.append(pathBytes)
        try syncWrite(localId: localId, remoteId: remoteId, payload: req)

        var out = Data()
        while true {
            let chunk = try syncRead(localId: localId, remoteId: remoteId)
            let tag = chunk.prefix(4)
            if tag == Data("DATA".utf8) {
                // Frame: "DATA" + 4-byte LE length + payload
                out.append(chunk.dropFirst(8))
            } else if tag == Data("DONE".utf8) {
                break
            } else if tag == Data("FAIL".utf8) {
                let msg = String(data: chunk.dropFirst(8), encoding: .utf8) ?? "(binary)"
                throw ADBError.protocolError("RECV failed: \(msg)")
            } else {
                let t = String(data: tag, encoding: .utf8) ?? "(?)"
                throw ADBError.protocolError("unexpected sync tag: \(t)")
            }
        }
        var quit = Data("QUIT".utf8); quit.appendUInt32LE(0)
        try? syncWrite(localId: localId, remoteId: remoteId, payload: quit)
        return out
    }

    /// Wrap a SYNC frame in a WRTE message + wait for the OKAY ack.
    private func syncWrite(localId: UInt32, remoteId: UInt32, payload: Data) throws {
        try transport.sendMessage(ADBMessage(
            command: ADBCommand.wrte.rawValue,
            arg0: localId, arg1: remoteId,
            data: payload
        ))
        let ack = try transport.receiveMessage()
        guard ack.command == ADBCommand.okay.rawValue else {
            throw ADBError.unexpectedCommand(
                ack.command, expected: "OKAY after sync write"
            )
        }
    }

    /// Read one SYNC response framed inside a WRTE message + ack so
    /// the device keeps streaming.
    private func syncRead(localId: UInt32, remoteId: UInt32) throws -> Data {
        let msg = try transport.receiveMessage()
        guard msg.command == ADBCommand.wrte.rawValue else {
            throw ADBError.unexpectedCommand(
                msg.command, expected: "WRTE during sync read"
            )
        }
        try transport.sendMessage(ADBMessage(
            command: ADBCommand.okay.rawValue,
            arg0: localId, arg1: remoteId,
            data: Data()
        ))
        return msg.data
    }
}

// MARK: - adb CLI entry point

/// Argv-shaped main() for `adb`. Output goes to FileHandle.standardOutput,
/// errors to standardError. Returns a POSIX-style exit code.
enum ADBCLI {

    static let usage = """
    Usage: adb [options] <command> [args]

    Options:
      -s, -H <host[:port]>    target device (default: 127.0.0.1:5555)
      -P <port>               port          (default: 5555)
      -t <seconds>            socket timeout (default: 10)

    Commands:
      connect [host[:port]]     handshake-only; verify a device is reachable
      devices                   query the target and report it
      shell <cmd>               run a single shell command on the device
      push <local> <remote>     upload a file
      pull <remote> <local>     download a file
      reboot [mode]             reboot device (mode: bootloader/recovery/sideload)
      help                      this message

    Notes:
      • Wi-Fi: connect to the Android device's IP + port 5555 after
        enabling "Wireless debugging" in Developer options.
      • USB-C cable: enable USB tethering on Android, plug it in, then
        connect to the tethered IP (usually 192.168.42.129). See
        USBTetheringHelper.setupInstructions for the full sequence.
    """

    static func run(argv: [String]) -> Int32 {
        var host = "127.0.0.1"
        var port: UInt16 = ADBFastboot.defaultADBPort
        var timeout: TimeInterval = 10

        // Option parse
        var i = 0
        while i < argv.count, argv[i].hasPrefix("-") {
            let opt = argv[i]
            switch opt {
            case "-s", "-H":
                guard i + 1 < argv.count else {
                    writeStderr("adb: \(opt) needs an argument\n"); return 2
                }
                (host, port) = parseTarget(argv[i + 1], defaultPort: port)
                i += 2
            case "-P":
                guard i + 1 < argv.count, let p = UInt16(argv[i + 1]) else {
                    writeStderr("adb: -P needs a port number\n"); return 2
                }
                port = p; i += 2
            case "-t":
                guard i + 1 < argv.count, let t = TimeInterval(argv[i + 1]) else {
                    writeStderr("adb: -t needs a seconds value\n"); return 2
                }
                timeout = t; i += 2
            case "-h", "--help", "help":
                writeStdout(usage + "\n"); return 0
            default:
                writeStderr("adb: unknown option \(opt)\n\(usage)\n"); return 2
            }
        }

        guard i < argv.count else {
            writeStdout(usage + "\n"); return 1
        }
        let cmd = argv[i]
        let rest = Array(argv[(i + 1)...])

        do {
            switch cmd {
            case "connect":
                let target = rest.first ?? "\(host):\(port)"
                let (h, p) = parseTarget(target, defaultPort: port)
                let c = ADBClient(host: h, port: p, timeout: timeout)
                try c.connect()
                writeStdout("connected to \(h):\(p)\n")
                if let banner = c.banner { writeStdout("  banner: \(banner)\n") }
                c.disconnect()
                return 0

            case "devices":
                let c = ADBClient(host: host, port: port, timeout: timeout)
                do {
                    try c.connect()
                    let serial = try c.shell("getprop ro.serialno")
                                      .trimmingCharacters(in: .whitespacesAndNewlines)
                    let model = try c.shell("getprop ro.product.model")
                                     .trimmingCharacters(in: .whitespacesAndNewlines)
                    writeStdout("List of devices attached\n")
                    writeStdout("\(host):\(port)\tdevice  \(model) (serial \(serial))\n")
                    c.disconnect()
                } catch {
                    writeStdout("List of devices attached\n")
                    writeStderr("(no devices — \(error.localizedDescription))\n")
                    return 1
                }
                return 0

            case "shell":
                guard !rest.isEmpty else {
                    writeStderr("adb: shell needs a command\n"); return 2
                }
                let c = ADBClient(host: host, port: port, timeout: timeout)
                try c.connect()
                defer { c.disconnect() }
                let out = try c.shell(rest.joined(separator: " "))
                writeStdout(out)
                if !out.hasSuffix("\n") { writeStdout("\n") }
                return 0

            case "push":
                guard rest.count == 2 else {
                    writeStderr("adb: usage: push <local> <remote>\n"); return 2
                }
                let local = URL(fileURLWithPath: rest[0])
                let n = try ADBFastboot.adbPush(
                    host: host, port: port,
                    localPath: local, remotePath: rest[1],
                    timeout: timeout)
                writeStdout("pushed \(n) bytes → \(rest[1])\n")
                return 0

            case "pull":
                guard rest.count == 2 else {
                    writeStderr("adb: usage: pull <remote> <local>\n"); return 2
                }
                let local = URL(fileURLWithPath: rest[1])
                let n = try ADBFastboot.adbPull(
                    host: host, port: port,
                    remotePath: rest[0], localPath: local,
                    timeout: timeout)
                writeStdout("pulled \(n) bytes ← \(rest[0])\n")
                return 0

            case "reboot":
                let mode = rest.first ?? ""
                try ADBFastboot.adbReboot(host: host, port: port,
                                          mode: mode, timeout: timeout)
                writeStdout("reboot\(mode.isEmpty ? "" : " \(mode)") sent\n")
                return 0

            default:
                writeStderr("adb: unknown command \(cmd)\n\(usage)\n"); return 2
            }
        } catch {
            writeStderr("adb: \(error.localizedDescription)\n")
            return 1
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

    private static func writeStdout(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
    private static func writeStderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}
