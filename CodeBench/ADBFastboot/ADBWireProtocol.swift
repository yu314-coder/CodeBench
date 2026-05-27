//
//  ADBWireProtocol.swift
//  CodeBench
//
//  ADB wire-protocol message types. Mirrors the format documented at
//    https://android.googlesource.com/platform/system/core/+/master/adb/protocol.txt
//

import Foundation

/// 4-byte command magics from the ADB protocol. Stored as the
/// little-endian read of the 4-ASCII tag so they can be compared
/// directly against a header field.
enum ADBCommand: UInt32 {
    case cnxn = 0x4e584e43   // "CNXN" — handshake
    case auth = 0x48545541   // "AUTH" — auth challenge/response
    case open = 0x4e45504f   // "OPEN" — open a stream
    case okay = 0x59414b4f   // "OKAY" — ack
    case clse = 0x45534c43   // "CLSE" — close stream
    case wrte = 0x45545257   // "WRTE" — stream payload
    case sync = 0x434e5953   // "SYNC" — file-sync sub-protocol

    /// Human-readable form for log lines.
    var tag: String {
        switch self {
        case .cnxn: return "CNXN"
        case .auth: return "AUTH"
        case .open: return "OPEN"
        case .okay: return "OKAY"
        case .clse: return "CLSE"
        case .wrte: return "WRTE"
        case .sync: return "SYNC"
        }
    }

    /// Convenience: format an arbitrary command value (possibly invalid)
    /// for log lines, using the known tag when possible.
    static func describe(_ raw: UInt32) -> String {
        if let known = ADBCommand(rawValue: raw) { return known.tag }
        return String(format: "?0x%08x", raw)
    }
}

/// Earliest ADB protocol version we negotiate. Upstream uses
/// 0x01000000 for "version 1" and 0x01000001 for the v2 length-prefixed
/// variant. Plain v1 is enough for shell, sync, and reboot.
let A_VERSION: UInt32 = 0x01000000

/// Maximum payload size the device should send us. Lowest-common
/// denominator that every stock adbd will accept without complaint.
let MAX_PAYLOAD: UInt32 = 4096

/// One ADB wire-protocol message: a 24-byte header plus optional
/// payload bytes. ``encode()`` packs the two together; ``decodeHeader``
/// parses an incoming 24-byte header.
struct ADBMessage {
    let command: UInt32
    let arg0:    UInt32
    let arg1:    UInt32
    let data:    Data

    /// Pack the header + payload into a single byte blob ready to send.
    /// Header layout (little-endian uint32s):
    ///
    ///   command | arg0 | arg1 | data_length | data_checksum | magic
    ///
    /// ``magic`` is ``command ^ 0xffffffff``; ``data_checksum`` is the
    /// sum of every payload byte modulo 2³².
    func encode() -> Data {
        let dataLen = UInt32(data.count)
        let dataCrc = data.reduce(UInt32(0)) { acc, byte in acc &+ UInt32(byte) }
        let magic   = command ^ 0xffffffff

        var out = Data(capacity: 24 + data.count)
        out.appendUInt32LE(command)
        out.appendUInt32LE(arg0)
        out.appendUInt32LE(arg1)
        out.appendUInt32LE(dataLen)
        out.appendUInt32LE(dataCrc)
        out.appendUInt32LE(magic)
        out.append(data)
        return out
    }

    /// Parse a raw 24-byte header. Returns the parsed fields *and*
    /// the data_length (which the caller will use to read the payload).
    /// Throws if the magic field is wrong.
    static func decodeHeader(_ raw: Data) throws ->
        (command: UInt32, arg0: UInt32, arg1: UInt32, dataLen: UInt32)
    {
        guard raw.count == 24 else {
            throw ADBError.protocolError(
                "ADB header must be 24 bytes, got \(raw.count)"
            )
        }
        let cmd   = raw.readUInt32LE(at:  0)
        let arg0  = raw.readUInt32LE(at:  4)
        let arg1  = raw.readUInt32LE(at:  8)
        let dlen  = raw.readUInt32LE(at: 12)
        // skip dcrc at 16 — we don't validate on receive
        let magic = raw.readUInt32LE(at: 20)
        let expected = cmd ^ 0xffffffff
        guard magic == expected else {
            throw ADBError.protocolError(
                "ADB header magic mismatch: got 0x\(String(magic, radix: 16))"
                + ", expected 0x\(String(expected, radix: 16))"
                + " for command 0x\(String(cmd, radix: 16))"
            )
        }
        return (cmd, arg0, arg1, dlen)
    }
}

// MARK: - Data helpers (little-endian read/write)

extension Data {
    /// Append a UInt32 in little-endian byte order.
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { raw in
            self.append(raw.bindMemory(to: UInt8.self))
        }
    }

    /// Read a UInt32 at the given byte offset, treating the bytes as
    /// little-endian. Caller is responsible for bounds.
    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1])
        let b2 = UInt32(self[startIndex + offset + 2])
        let b3 = UInt32(self[startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// Convenience constructor: 4-byte little-endian encoding of a UInt32.
    static func uint32LE(_ value: UInt32) -> Data {
        var d = Data(); d.appendUInt32LE(value); return d
    }
}
