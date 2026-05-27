//
//  ADBNetworkTransport.swift
//  CodeBench
//
//  TCP transport using NWConnection. Both ADB and fastboot speak over
//  TCP — ADB to the adbd port (default 5555), fastboot to the
//  fastbootd port (default 5554). When the user's setup is "Android
//  via USB-C cable + USB tethering", those ports are reachable on the
//  tethered IP (typically 192.168.42.129).
//

import Foundation
import Network

/// Thin synchronous wrapper around NWConnection.
///
/// We picked sync over async/await because ADB is a request/response
/// state machine where each step is a few-dozen-bytes header — the
/// readable client code reads ``sendMessage`` / ``receiveMessage``
/// linearly. The semaphore-based send/recv is heavier per-op than
/// async but the latency is dominated by the device round-trip
/// anyway, not by the wrapper.
final class ADBNetworkTransport {

    let host: String
    let port: UInt16
    let timeout: TimeInterval

    private var connection: NWConnection?
    private let queue: DispatchQueue

    init(host: String, port: UInt16, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.timeout = timeout
        // Per-instance serial queue so callbacks don't interleave
        // across send/receive.
        self.queue = DispatchQueue(label: "ADBFastboot.transport.\(host)")
    }

    // MARK: Lifecycle

    /// Open the TCP connection and block until it's .ready (or fails
    /// / times out).
    func connect() throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        let sem  = DispatchSemaphore(value: 0)
        var connectError: NWError?

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let e):
                connectError = e
                sem.signal()
            case .cancelled:
                // Only matters if the cancellation happens before .ready.
                if connectError == nil {
                    connectError = NWError.posix(.ECANCELED)
                }
                sem.signal()
            case .waiting(let e):
                // .waiting fires for slow paths (e.g. trying multiple
                // network paths). Don't treat as failure yet, but if
                // we eventually time out we'll surface this error.
                connectError = e
            default:
                break
            }
        }
        conn.start(queue: queue)

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            conn.cancel()
            throw ADBError.transport(
                "connect to \(host):\(port) timed out after \(Int(timeout))s"
            )
        }
        if let e = connectError {
            conn.cancel()
            throw ADBError.transport(
                "connect to \(host):\(port) failed: \(e.debugDescription)"
            )
        }
        self.connection = conn
    }

    /// Tear down the connection. Safe to call multiple times.
    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: Raw byte I/O

    /// Send arbitrary bytes. Blocks until the send completes.
    func send(_ data: Data) throws {
        guard let conn = connection else {
            throw ADBError.transport("not connected")
        }
        let sem = DispatchSemaphore(value: 0)
        var sendErr: NWError?
        conn.send(content: data, completion: .contentProcessed { err in
            sendErr = err
            sem.signal()
        })
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw ADBError.transport("send timed out (\(data.count) bytes)")
        }
        if let e = sendErr {
            throw ADBError.transport("send failed: \(e.debugDescription)")
        }
    }

    /// Receive exactly ``n`` bytes. NWConnection delivers in arbitrary
    /// chunks so we loop until we have what we asked for or hit a
    /// timeout / EOF.
    func receive(_ n: Int) throws -> Data {
        guard let conn = connection else {
            throw ADBError.transport("not connected")
        }
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while collected.count < n {
            let need = n - collected.count
            let sem  = DispatchSemaphore(value: 0)
            var chunk: Data?
            var rxErr: NWError?
            var isComplete = false

            conn.receive(minimumIncompleteLength: 1, maximumLength: need) {
                data, _, complete, err in
                chunk      = data
                rxErr      = err
                isComplete = complete
                sem.signal()
            }

            let remaining = max(0.01, deadline.timeIntervalSinceNow)
            if sem.wait(timeout: .now() + remaining) == .timedOut {
                throw ADBError.transport(
                    "recv timed out (had \(collected.count) of \(n) bytes)"
                )
            }
            if let e = rxErr {
                throw ADBError.transport("recv failed: \(e.debugDescription)")
            }
            if let d = chunk, !d.isEmpty {
                collected.append(d)
            } else if isComplete {
                throw ADBError.transport(
                    "peer closed after \(collected.count) of \(n) bytes"
                )
            }
        }
        return collected
    }

    // MARK: ADB-message I/O

    /// Encode + send an ADB protocol message.
    func sendMessage(_ msg: ADBMessage) throws {
        try send(msg.encode())
    }

    /// Receive one full ADB message (header + payload).
    func receiveMessage() throws -> ADBMessage {
        let header = try receive(24)
        let (cmd, arg0, arg1, dlen) = try ADBMessage.decodeHeader(header)
        let data = dlen > 0 ? try receive(Int(dlen)) : Data()
        return ADBMessage(command: cmd, arg0: arg0, arg1: arg1, data: data)
    }
}
