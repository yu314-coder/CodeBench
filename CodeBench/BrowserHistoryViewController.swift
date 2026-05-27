import UIKit

/// Hidden viewer for the embedded WebView's navigation history and
/// cookie snapshot. Reachable only via 5 quick taps on the Settings
/// title (no menu, no docked entry).
final class BrowserHistoryViewController: UIViewController {

    private enum Mode: Int { case history = 0, cookies = 1 }

    private let bgColor      = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)
    private let surfaceColor = UIColor(red: 0.130, green: 0.137, blue: 0.157, alpha: 1)
    private let textColor    = UIColor(red: 0.820, green: 0.835, blue: 0.870, alpha: 1)
    private let dimColor     = UIColor(red: 0.520, green: 0.540, blue: 0.580, alpha: 1)
    private let accentColor  = UIColor(red: 0.400, green: 0.588, blue: 0.929, alpha: 1)

    private let segment = UISegmentedControl(items: ["History", "Cookies"])
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    private var history: [BrowserDataStore.Visit] = []
    private var cookies: [BrowserDataStore.CookieRow] = []
    private var mode: Mode = .history

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        title = "Browser data"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear", style: .plain,
            target: self, action: #selector(clearTapped))
        navigationController?.navigationBar.tintColor = accentColor

        segment.selectedSegmentIndex = 0
        segment.selectedSegmentTintColor = accentColor
        segment.setTitleTextAttributes([.foregroundColor: textColor], for: .normal)
        segment.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        view.addSubview(segment)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorColor = surfaceColor
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        table.estimatedRowHeight = 64
        table.rowHeight = UITableView.automaticDimension
        view.addSubview(table)

        emptyLabel.text = "Nothing logged yet."
        emptyLabel.textColor = dimColor
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            segment.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            segment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            table.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        reload()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func modeChanged() {
        mode = Mode(rawValue: segment.selectedSegmentIndex) ?? .history
        reload()
    }

    private func reload() {
        switch mode {
        case .history:
            history = BrowserDataStore.shared.loadHistory().reversed()
            emptyLabel.isHidden = !history.isEmpty
            table.reloadData()
        case .cookies:
            BrowserDataStore.shared.snapshotCookies { [weak self] rows in
                guard let self else { return }
                self.cookies = rows.sorted { $0.domain < $1.domain }
                self.emptyLabel.isHidden = !self.cookies.isEmpty
                self.table.reloadData()
            }
        }
    }

    @objc private func clearTapped() {
        let label = mode == .history ? "history" : "cookies"
        let alert = UIAlertController(
            title: "Clear \(label)?",
            message: "This deletes the persisted browser \(label). Cannot be undone.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            guard let self else { return }
            switch self.mode {
            case .history:
                BrowserDataStore.shared.clearHistory()
                self.history = []
                self.emptyLabel.isHidden = false
                self.table.reloadData()
            case .cookies:
                BrowserDataStore.shared.clearCookies { [weak self] in
                    self?.cookies = []
                    self?.emptyLabel.isHidden = false
                    self?.table.reloadData()
                }
            }
        })
        present(alert, animated: true)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

extension BrowserHistoryViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int {
        mode == .history ? history.count : cookies.count
    }

    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "row", for: ip)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.contentConfiguration = nil
        var c = UIListContentConfiguration.subtitleCell()
        c.textProperties.color = textColor
        c.textProperties.font = .systemFont(ofSize: 14, weight: .medium)
        c.secondaryTextProperties.color = dimColor
        c.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        c.secondaryTextProperties.numberOfLines = 2

        switch mode {
        case .history:
            let v = history[ip.row]
            c.text = v.title.isEmpty ? v.url : v.title
            c.secondaryText = "\(Self.dateFmt.string(from: v.timestamp))   \(v.url)"
        case .cookies:
            let r = cookies[ip.row]
            let flags = [r.isSecure ? "Secure" : nil, r.isHTTPOnly ? "HTTPOnly" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            let exp = r.expiresDate.map { "expires \(Self.dateFmt.string(from: $0))" } ?? "session"
            c.text = "\(r.name) — \(r.domain)\(r.path)"
            c.secondaryText = "\(truncated(r.value, 80))\n\(exp)\(flags.isEmpty ? "" : "   \(flags)")"
        }
        cell.contentConfiguration = c
        return cell
    }

    func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        guard mode == .history else { return }
        UIPasteboard.general.string = history[ip.row].url
        let banner = UILabel()
        banner.text = "URL copied"
        banner.textColor = .white
        banner.backgroundColor = accentColor
        banner.textAlignment = .center
        banner.font = .systemFont(ofSize: 12, weight: .semibold)
        banner.layer.cornerRadius = 8
        banner.clipsToBounds = true
        banner.alpha = 0
        banner.frame = CGRect(x: view.bounds.midX - 60, y: view.bounds.maxY - 100,
                              width: 120, height: 28)
        view.addSubview(banner)
        UIView.animate(withDuration: 0.2, animations: { banner.alpha = 1 }, completion: { _ in
            UIView.animate(withDuration: 0.2, delay: 0.9, options: [], animations: { banner.alpha = 0 }) { _ in
                banner.removeFromSuperview()
            }
        })
    }

    private func truncated(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
