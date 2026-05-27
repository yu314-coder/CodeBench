# ADBFastboot

Self-contained ADB + fastboot client for the CodeBench iOS app.
**Delete this folder anytime** — nothing outside it references these
types. Add the folder back and it's enabled again.

Built and tested for **iPhone 16 Pro** and **iPad M3** (USB-C era).
Older Lightning iPads / pre-USB-C iPhones can still use the Wi-Fi
path; only the USB-C cable path needs USB-C on both ends.

---

## USB-C cable setup (the part you asked about)

iOS apps can't open raw USB bulk endpoints from inside the app
sandbox — that requires a separate Driver Extension target with an
Apple-approved entitlement that doesn't fit in one folder. **But**
there's a different USB-C path that works *today*, with no
entitlement, no dext, nothing outside this folder: **Android USB
tethering.**

When you plug an Android device into iPhone 16 Pro / iPad M3 via
USB-C, and the device has USB tethering enabled, iOS routes the
traffic as if Android were a wired-ethernet adapter. ADB-over-network
to the tethered IP then flows straight through the USB-C cable.

### One-time setup on the Android device

1. **Enable Developer options** — Settings → About phone → tap
   "Build number" seven times.
2. **Enable Wireless debugging** — Settings → System → Developer
   options → Wireless debugging.
3. **Enable USB tethering** — Settings → Network & Internet → Hotspot
   & tethering → USB tethering. (This option is greyed out unless a
   USB cable is plugged in.)

### Connecting

```swift
// Plug Android into iPhone 16 Pro / iPad M3 via USB-C, then:

// 1) Auto-discover (recommended)
let client = try USBTetheringHelper.autoConnect()
print("connected:", client.banner ?? "?")
print(try client.shell("getprop ro.product.model"))
client.disconnect()

// 2) Or, if you already know the tethered IP (default 192.168.42.129):
let model = try ADBFastboot.adbShell(
    host: "192.168.42.129",
    cmd:  "getprop ro.product.model"
)
```

### Why it actually goes through the USB-C cable

Android USB tethering exposes the phone as a standard RNDIS or NCM
ethernet device — the same Linux gadget profile that's worked on
desktops since the Linux 2.6 days. iOS handles those exactly like
any wired ethernet adapter: it shows up as `en2` (or `en3`, etc.) in
the interface table, gets a DHCP lease from the phone, and routes
TCP through it. The bytes never touch Wi-Fi. `getifaddrs(3)` is a
public POSIX API on iOS, so we can detect this without any
entitlements at all — that's what `USBTetheringHelper` does.

## Files

```
ADBFastboot/
├── ADBFastboot.swift            ← public umbrella API + error types
├── ADBWireProtocol.swift        ← Message struct, command magics
├── ADBNetworkTransport.swift    ← NWConnection-based TCP transport
├── ADBClient.swift              ← CNXN handshake, shell, push, pull, reboot + adb CLI
├── FastbootClient.swift         ← Fastboot-over-TCP + fastboot CLI
├── USBTetheringHelper.swift     ← Auto-detect tethered Android via USB-C
└── README.md                    ← you are here
```

## API surface

### One-shot calls (most common)

```swift
// adb shell
let out = try ADBFastboot.adbShell(
    host: "192.168.42.129", cmd: "ls /sdcard"
)

// adb push
try ADBFastboot.adbPush(
    host: "192.168.42.129",
    localPath: localURL,
    remotePath: "/sdcard/hello.txt"
)

// adb pull
try ADBFastboot.adbPull(
    host: "192.168.42.129",
    remotePath: "/sdcard/hello.txt",
    localPath: destinationURL
)

// adb reboot
try ADBFastboot.adbReboot(
    host: "192.168.42.129", mode: "bootloader"
)

// fastboot
try ADBFastboot.fastbootGetvar(host: "192.168.42.129", name: "version")
try ADBFastboot.fastbootFlash(
    host: "192.168.42.129",
    partition: "boot",
    filePath: URL(fileURLWithPath: "/path/to/boot.img")
)
try ADBFastboot.fastbootReboot(host: "192.168.42.129")
```

### Long-lived sessions

```swift
let c = ADBClient(host: "192.168.42.129")
try c.connect()
defer { c.disconnect() }

// Reuse the same TCP connection for multiple shell calls
let model   = try c.shell("getprop ro.product.model")
let battery = try c.shell("dumpsys battery | grep level")
let display = try c.shell("dumpsys display | head -5")
```

### CLI-style entry points

These let the in-app shell wire `adb` and `fastboot` as builtins
with one line each:

```swift
// adb
let exitCode = ADBFastboot.adbMain(["-s", "192.168.42.129",
                                     "shell", "getprop", "ro.product.model"])

// fastboot
let exitCode = ADBFastboot.fastbootMain(["getvar", "version"])
```

Stdout writes go to `FileHandle.standardOutput`, errors to
`standardError`, so a shell pipeline picks them up naturally.

## Limitations (call out before you debug them)

| Limitation | Reason | Workaround |
|---|---|---|
| `AUTH` (RSA-signed challenge) not implemented | Would need CommonCrypto or a 200-line RSA — kept the file tree small | Pair the device once from desktop `adb` so it remembers the host key, then this client connects without AUTH |
| `adb shell` (interactive PTY) not supported | Single-shot model | Send one command per call — that covers `getprop`, `am start`, `pm list`, `dumpsys`, file ops, etc. |
| `adb logcat`, `adb forward`, `adb reverse` not implemented | Out of scope for v0.1 — easy to add when you need them | The stream-open primitive is in `ADBClient.openStream`; logcat is `openStreamCollect(destination: "shell:logcat".data(using: .utf8)!)` |
| Raw USB ADB (no tethering) | Needs a DriverKit Driver Extension target with `com.apple.developer.driverkit.transport.usb` entitlement | USB tethering already routes through the cable end-to-end |

## To remove

```sh
rm -rf CodeBench/ADBFastboot/
```

Xcode auto-discovers Swift files in the `CodeBench/` group (the
project uses synchronized folder references — there are no per-file
entries in `project.pbxproj`), so a clean build will simply not
compile this module any more. Nothing else in the project references
these types, so nothing else needs to change.
