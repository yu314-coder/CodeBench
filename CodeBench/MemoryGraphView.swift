import UIKit
import Darwin.Mach

/// Tiny always-on RAM usage sparkline pinned to the top-right of the
/// main UI. Polls Mach `host_statistics64` every 1.5s, plots the
/// last 60 samples as a smoothed line with a gradient fill, and
/// displays the current "<used>/<total>" string next to the chart.
///
/// Tap to bring up a detailed breakdown sheet (active / inactive /
/// wired / compressor pages) — same data CodeBench's `top` builtin
/// shows, just summarized graphically.
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

        titleLabel.text = "RAM"
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
        guard let info = vmStats() else { return }
        // "Used" memory matches what Apple's Activity Monitor labels
        // app+wired+compressed: active + inactive + wired +
        // compressor pages. Excludes purgeable pages (those are
        // immediately reclaimable by the kernel and shouldn't count
        // as "in use" in a memory-pressure sense).
        let pageSize = vm_kernel_page_size
        let used =
            UInt64(info.active_count) +
            UInt64(info.inactive_count) +
            UInt64(info.wire_count) +
            UInt64(info.compressor_page_count)
        let usedBytes = used * UInt64(pageSize)
        let total = totalRAM > 0 ? totalRAM : sysctlMemSize()
        if totalRAM == 0 { totalRAM = total }
        guard total > 0 else { return }
        let ratio = min(1.0, max(0.0, Double(usedBytes) / Double(total)))

        samples.append(ratio)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }

        valueLabel.text = "\(formatBytes(usedBytes))/\(formatBytes(total))"
        setNeedsLayout()   // triggers rebuildPath via layoutSubviews
    }

    private func vmStats() -> vm_statistics64_data_t? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size /
                                            MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics64(host, HOST_VM_INFO64, reb, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
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
