//
//  USBTetheringHelper.swift
//  CodeBench
//
//  Detects an Android device that's plugged into the iPhone 16 Pro /
//  iPad M3 via USB-C cable and has USB tethering enabled. On iOS,
//  the tethered Android device appears as a wired-ethernet interface
//  (RNDIS or NCM) with a self-assigned subnet — typically
//  192.168.42.0/24 with the Android device at .129 and the host at
//  .42.x.
//
//  No special entitlement is needed for this — enumerating network
//  interfaces and reading their IP addresses uses the public POSIX
//  ``getifaddrs`` API. We're not opening USB endpoints directly;
//  we're just looking at what the OS already attached to the network
//  stack for us.
//
//  Usage:
//
//      let suggestions = USBTetheringHelper.suggestADBTargets()
//      for s in suggestions {
//          print("try: adb connect \(s.host):\(s.port)  (\(s.note))")
//      }
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum USBTetheringHelper {

    /// One candidate ADB target — host + port the user can connect to,
    /// plus an explanatory note for the UI.
    public struct ADBTarget: Hashable {
        public let host: String
        public let port: UInt16
        /// Human-readable note about why we suggested this target,
        /// for display next to a "Connect" button.
        public let note: String
        /// Network interface this target is reachable on (e.g. "en2").
        public let interface: String
    }

    /// Tested-on-iPhone-16-Pro-/-iPad-M3 setup instructions. Display
    /// these in the UI before the user plugs anything in.
    public static let setupInstructions = """
    USB-C cable setup (iPhone 16 Pro / iPad M3):

    1. On the Android device → Settings → System → Developer
       options → enable "USB debugging" AND "Wireless debugging".
       (Developer options unlocked from Settings → About phone →
       tap "Build number" seven times.)

    2. On the Android device → Settings → Network & Internet →
       Hotspot & tethering → enable "USB tethering".
       (Greyed out until a USB cable is plugged in.)

    3. Plug the Android device into the iPhone 16 Pro / iPad M3
       USB-C port using a USB-C ↔ USB-C cable.

    4. The iPhone/iPad now sees the Android device as a wired
       ethernet interface — typically named "en2" with the host
       getting 192.168.42.x and the Android device at .129.

    5. In this app, call ADBFastboot.adbShell(host: "192.168.42.129",
       cmd: "...")  — or use USBTetheringHelper.suggestADBTargets()
       to auto-discover the IP.

    Why this works: USB tethering exposes the Android device as a
    standard RNDIS/NCM ethernet gadget; iOS routes it like any
    other ethernet adapter. ADB-over-network then flows through
    the USB-C cable end-to-end. There's no Wi-Fi involved.
    """

    // MARK: - Public helpers

    /// All current "wired-ethernet-shaped" network interfaces (en2,
    /// en3, etc. — anything in the en-series above en0/en1 which are
    /// reserved for Wi-Fi). When an Android phone is USB-tethered to
    /// iPhone 16 Pro / iPad M3 it shows up here.
    public static func wiredInterfaces() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in allInterfaceEntries() {
            // We want en2+ (en0 is Wi-Fi on iPhone, en1 is Bluetooth /
            // AWDL). Tethered USB devices land in en2 / en3 / ...
            // Skip non-en interfaces (lo0, pdp_ip*, utun*, etc.).
            guard entry.name.hasPrefix("en") else { continue }
            let suffix = entry.name.dropFirst(2)
            guard let n = Int(suffix), n >= 2 else { continue }
            if seen.insert(entry.name).inserted {
                out.append(entry.name)
            }
        }
        return out.sorted()
    }

    /// IPv4 addresses currently assigned on the given interface.
    public static func ipAddresses(forInterface name: String) -> [String] {
        return allInterfaceEntries()
            .filter { $0.name == name && $0.family == AF_INET }
            .map { $0.address }
    }

    /// Subnet gateway (".1" of the host's /24) for the given interface.
    /// Useful as a best-effort fallback when we can't sniff the actual
    /// peer IP. Returns nil if the host doesn't have a /24-shaped IPv4.
    public static func suggestedPeerForHostIP(_ ip: String) -> [String] {
        // Common Android tether subnets we've seen:
        //   192.168.42.0/24   ← stock AOSP, Pixel, most OEMs
        //   192.168.43.0/24   ← stock AOSP Wi-Fi hotspot subnet
        //   192.168.44.0/24   ← some Samsung
        //   172.20.10.0/28    ← iOS tether (we won't see this here)
        //
        // For any host IP, derive the .129 sibling (Android-side gateway).
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let base = "\(parts[0]).\(parts[1]).\(parts[2])"
        // Try the conventional Android end (.129) first, then a couple
        // of common alternatives.
        return ["\(base).129", "\(base).1"]
    }

    /// One-shot helper: enumerate all wired interfaces and produce a
    /// ranked list of ADB targets the user can try.
    public static func suggestADBTargets(port: UInt16 = ADBFastboot.defaultADBPort)
        -> [ADBTarget]
    {
        var targets: [ADBTarget] = []
        for iface in wiredInterfaces() {
            for hostIP in ipAddresses(forInterface: iface) {
                for peer in suggestedPeerForHostIP(hostIP) {
                    targets.append(ADBTarget(
                        host: peer,
                        port: port,
                        note: "USB-tethered (host=\(hostIP), iface=\(iface))",
                        interface: iface
                    ))
                }
            }
        }
        return targets
    }

    /// Same as ``suggestADBTargets`` but for the fastboot port.
    public static func suggestFastbootTargets(
        port: UInt16 = ADBFastboot.defaultFastbootPort
    ) -> [ADBTarget] {
        return suggestADBTargets(port: port).map {
            ADBTarget(host: $0.host, port: port,
                      note: $0.note, interface: $0.interface)
        }
    }

    /// Attempt the auto-connect dance: enumerate suggestions, try
    /// each in turn, return the first one that handshakes
    /// successfully. Throws if none work.
    public static func autoConnect(timeout: TimeInterval = 4) throws -> ADBClient {
        let candidates = suggestADBTargets()
        if candidates.isEmpty {
            throw ADBError.transport(
                "no USB-tethered interface detected. " +
                "Enable USB tethering on the Android device and " +
                "plug it into the USB-C port. See " +
                "USBTetheringHelper.setupInstructions."
            )
        }
        var lastError: Error?
        for cand in candidates {
            let client = ADBClient(
                host: cand.host, port: cand.port, timeout: timeout
            )
            do {
                try client.connect()
                return client
            } catch {
                lastError = error
                client.disconnect()
                continue
            }
        }
        throw ADBError.transport(
            "tried \(candidates.count) USB-tethered target(s), all failed. "
            + "Last error: \(lastError?.localizedDescription ?? "unknown"). "
            + "Make sure Wireless debugging is enabled on the Android device."
        )
    }
}

// MARK: - getifaddrs wrapper

/// One row from the OS-level interface table.
private struct InterfaceEntry {
    let name: String
    let family: Int32       // AF_INET or AF_INET6
    let address: String
}

/// Pull every "live" IPv4 interface address out of the kernel.
/// Uses POSIX ``getifaddrs`` — no entitlement needed.
private func allInterfaceEntries() -> [InterfaceEntry] {
    #if canImport(Darwin)
    var entries: [InterfaceEntry] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cur {
        defer { cur = entry.pointee.ifa_next }
        guard let saPtr = entry.pointee.ifa_addr else { continue }
        let family = saPtr.pointee.sa_family
        guard family == UInt8(AF_INET) else { continue }   // IPv4 only

        let name = String(cString: entry.pointee.ifa_name)
        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(
            saPtr,
            socklen_t(MemoryLayout<sockaddr_in>.size),
            &hostBuf, socklen_t(hostBuf.count),
            nil, 0,
            NI_NUMERICHOST
        )
        guard rc == 0 else { continue }
        let address = String(cString: hostBuf)
        entries.append(InterfaceEntry(
            name: name,
            family: Int32(family),
            address: address
        ))
    }
    return entries
    #else
    return []
    #endif
}
