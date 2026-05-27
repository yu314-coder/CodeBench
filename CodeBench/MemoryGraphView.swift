import UIKit
import Darwin.Mach
import os

/// Tiny always-on RAM sparkline pinned to the top-right of the main
/// UI. Polls THIS APP's memory footprint every 1.5s, plots the last
/// 60 samples as a smoothed line with a gradient fill, and shows the
/// current "<used>/<limit>" next to the chart.
///
/// Why "this app" vs "the device": iOS sandboxes apps. The system-
/// wide `host_statistics64` reading is essentially useless inside a
/// sandboxed process — it returns either the device's full memory
/// (which the app can never reach because jetsam kills you long
/// before) or filtered values that depend on entitlements. What
/// matters is YOUR FOOTPRINT vs YOUR JETSAM LIMIT, which is what
/// Xcode's gauge / Apple's Activity Monitor on macOS show.
///
/// Implementation:
///   used  = task_vm_info_data_t.phys_footprint  — same number Xcode's
///           debug-gauge calls "Memory" (= dirty + compressed pages
///           charged to this process).
///   limit = phys_footprint + os_proc_available_memory()
///           — the jetsam ceiling, dynamically reported by iOS 13+.
///           os_proc_available_memory() returns 0 if not yet supported
///           or if called too early; we fall back to ~50% of physical
///           in that case (a reasonable iOS-app default).
///
/// Tap to bring up a detailed breakdown sheet (footprint, available,
/// resident, virtual) — same data CodeBench's `top` builtin shows.
@_silgen_name("os_proc_available_memory") private func _os_proc_available_memory() -> Int
final class MemoryGraphView: UIView {

    // MARK: - Public

    /// Fired when the user taps the graph — used by the parent VC to
    /// present a detailed-breakdown sheet. Optional.
    var onTap: (() -> Void)?

    // MARK: - Visual constants

    private let bgColor       = UIColor(red: 0.130, green: 0.137, blue: 0.157, alpha: 0.85)
    private let strokeColor   = UIColor(red: 0.40, green: 0.84, blue: 0.55, alpha: 1.0)
    private let fillTopColor  = UIColor(red: 0.40, green: 0.84, blue: 0.55, alpha: 0.40)
    private let fillBotColor  = UIColor(red: 0.40, green: 0.84, blue: 0.55, alpha: 0.00)
    private let textColor     = UIColor(white: 0.95, alpha: 1)
    private let dimColor      = UIColor(white: 0.55, alpha: 1)

    // MARK: - State

    private let lineLayer = CAShapeLayer()
    private let fillLayer = CAGradientLayer()
    private let fillMask  = CAShapeLayer()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private var samples: [Double] = []          // 0…1, most recent at end
    private let maxSamples = 60                  // 90 s @ 1.5 s tick
    private var pollTimer: Timer?
    private var totalRAM: UInt64 = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        // Sample one immediately so the graph has data before the
        // first timer tick (otherwise the first 1.5 s shows a flat
        // baseline at 0).
        sample()
        startPolling()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupUI() {
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        backgroundColor = bgColor

        titleLabel.text = "APP RAM"
        titleLabel.font = UIFont.systemFont(ofSize: 9, weight: .bold).rounded
        titleLabel.textColor = dimColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        valueLabel.text = "—"
        valueLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        valueLabel.textColor = textColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        // Gradient fill below the line, masked by a closed-path
        // version of the same line. The mask layer's path is
        // updated together with the line layer's path on every
        // sample.
        fillLayer.colors = [fillTopColor.cgColor, fillBotColor.cgColor]
        fillLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fillLayer.endPoint   = CGPoint(x: 0.5, y: 1)
        fillLayer.mask = fillMask
        layer.addSublayer(fillLayer)

        lineLayer.fillColor = UIColor.clear.cgColor
        lineLayer.strokeColor = strokeColor.cgColor
        lineLayer.lineWidth = 1.2
        lineLayer.lineJoin = .round
        lineLayer.lineCap = .round
        layer.addSublayer(lineLayer)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        // Tap gesture for the detail-sheet hand-off.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
        accessibilityHint = "RAM usage. Tap for details."
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Line + fill area sits below the labels (top-row 16pt for
        // RAM / value, remaining for the chart).
        let chartY: CGFloat = 18
        let chartFrame = CGRect(x: 6, y: chartY,
                                width: bounds.width - 12,
                                height: bounds.height - chartY - 4)
        fillLayer.frame = bounds   // gradient covers the whole view; mask clips to chartFrame
        rebuildPath(in: chartFrame)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.sample()
        }
        // Run while scrolling too — the user is most likely to look
        // at the graph during long-running work, when the runloop
        // mode might otherwise pause the timer.
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func sample() {
        // Match Xcode's memory graph exactly: it shows
        // `phys_footprint` (the jetsam ledger). Anything else
        // diverges from what the user sees in Xcode and in iOS's
        // own per-app memory accounting. Mmap'd CLEAN pages
        // (model weights) won't show here — that's correct,
        // because they don't count against jetsam either.
        guard let usedBytes = appPhysFootprint() else { return }

        // For the ceiling we still use the jetsam-aware number
        // (footprint + os_proc_available_memory). resident_size
        // can technically exceed the jetsam limit because clean
        // pages are evictable on demand, so capping the ratio at 1.0
        // keeps the visual sane during high-resident situations.
        // Denominator: device physical RAM. The jetsam-aware ceiling
        // (footprint + os_proc_available_memory) excludes clean mmap
        // pages, so resident_size routinely exceeds it during model
        // load — produced nonsensical "5GB/3GB" readings. Device RAM
        // gives the intuitive "X GB out of your iPad's Y GB" view.
        if totalRAM == 0 { totalRAM = sysctlMemSize() }
        let total = totalRAM
        guard total > 0 else { return }
        let ratio = min(1.0, max(0.0, Double(usedBytes) / Double(total)))

        samples.append(ratio)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }

        valueLabel.text = "\(formatBytes(usedBytes))/\(formatBytes(total))"
        setNeedsLayout()   // triggers rebuildPath via layoutSubviews
    }

    /// All pages this process has resident in physical RAM right
    /// now — clean, dirty, and compressed alike. Includes mmap'd
    /// file pages (model weights, frameworks, etc.) which is what
    /// the user expects to see when they ask "how much RAM is my
    /// model using". Different from phys_footprint, which excludes
    /// clean mmap pages because jetsam doesn't count them.
    private func appResidentSize() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reb, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    /// Dirty + compressed pages charged to THIS process — the
    /// number jetsam uses for kill decisions. Used only for the
    /// ceiling computation (footprint + available = jetsam limit).
    private func appPhysFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reb, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Bytes the app can still allocate before iOS jetsams it.
    /// Returns 0 if the symbol resolved at startup but the OS
    /// returned 0 (rare), or if we caught the call at a point the
    /// kernel hasn't initialised the limit yet.
    private func osProcAvailableMemory() -> Int {
        // _silgen_name binding declared at module top; the symbol
        // exists from iOS 13.0 onward.
        let v = _os_proc_available_memory()
        return v > 0 ? v : 0
    }

    private func sysctlMemSize() -> UInt64 {
        var size: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &sz, nil, 0)
        return size
    }

    // MARK: - Path drawing

    private func rebuildPath(in rect: CGRect) {
        guard !samples.isEmpty, rect.width > 0, rect.height > 0 else {
            lineLayer.path = nil
            fillMask.path = nil
            return
        }
        let n = samples.count
        // X spacing — most-recent sample at the right edge so new
        // data appears at the right and old data slides off the left.
        let stepX = rect.width / CGFloat(max(1, maxSamples - 1))
        let yScale = rect.height
        let baseX = rect.maxX - stepX * CGFloat(n - 1)

        let line = UIBezierPath()
        for i in 0..<n {
            let x = baseX + stepX * CGFloat(i)
            let y = rect.maxY - CGFloat(samples[i]) * yScale
            if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
            else      { line.addLine(to: CGPoint(x: x, y: y)) }
        }
        lineLayer.path = line.cgPath

        // Fill mask: same line, then close along the bottom edge so
        // the gradient masks to the area between the line and the
        // chart's baseline.
        let fill = UIBezierPath(cgPath: line.cgPath)
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.addLine(to: CGPoint(x: baseX, y: rect.maxY))
        fill.close()
        fillMask.path = fill.cgPath
    }

    // MARK: - Tap

    @objc private func handleTap() { onTap?() }

    // MARK: - Helpers

    private func formatBytes(_ n: UInt64) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let v = Double(n)
        if v >= gb { return String(format: "%.1fG", v / gb) }
        if v >= mb { return String(format: "%.0fM", v / mb) }
        return String(format: "%.0fK", v / kb)
    }
}
