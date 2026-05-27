import UIKit
import WebKit

/// Multi-tab in-app browser with bookmarks + DevTools-lite (console
/// + network log). Two persistence modes:
///   • fresh = true  — ephemeral WKWebsiteDataStore, no cookies leak
///   • fresh = false — shared `WKWebsiteDataStore.default()` with the
///                     embedded pywebview WebView so a logged-in
///                     session carries between them.
final class MiniBrowserViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate, WKScriptMessageHandler {

    // MARK: - Tabs

    private final class Tab {
        let id = UUID()
        var webView: WKWebView
        var title: String = "New tab"
        var urlString: String = ""
        // DevTools captures
        var consoleLog: [String] = []
        var networkLog: [String] = []
        init(webView: WKWebView) { self.webView = webView }
    }
    private var tabs: [Tab] = []
    private var activeIdx: Int = 0
    private var activeTab: Tab? { tabs.indices.contains(activeIdx) ? tabs[activeIdx] : nil }

    // MARK: - Config

    private let fresh: Bool
    private let initialURL: URL

    // MARK: - Views

    private let urlField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let webContainer = UIView()
    private let tabBar = UIScrollView()
    private let tabStack = UIStackView()

    // MARK: - Theme

    private let bgColor      = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)
    private let surfaceColor = UIColor(red: 0.130, green: 0.137, blue: 0.157, alpha: 1)
    private let textColor    = UIColor(red: 0.820, green: 0.835, blue: 0.870, alpha: 1)
    private let accentColor  = UIColor(red: 0.400, green: 0.588, blue: 0.929, alpha: 1)

    // MARK: - Init

    init(url: URL, fresh: Bool) {
        self.initialURL = url
        self.fresh = fresh
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        title = fresh ? "Fresh browser" : "Browser"
        installChrome()
        installTabBar()
        openTab(url: initialURL)
    }

    // MARK: - Chrome

    private func installChrome() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))

        // Editable URL field
        urlField.borderStyle = .roundedRect
        urlField.backgroundColor = surfaceColor
        urlField.textColor = textColor
        urlField.font = .systemFont(ofSize: 13)
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.returnKeyType = .go
        urlField.clearButtonMode = .whileEditing
        urlField.delegate = self
        urlField.placeholder = "URL"
        navigationItem.titleView = urlField

        // Right side: menu (bookmarks / devtools / new-tab / size)
        let menu = UIMenu(children: [
            UIAction(title: "New tab", image: UIImage(systemName: "plus.square.on.square")) { _ in self.openTab(url: nil) },
            UIAction(title: "Bookmarks", image: UIImage(systemName: "bookmark")) { _ in self.showBookmarks() },
            UIAction(title: "Add bookmark", image: UIImage(systemName: "bookmark.fill")) { _ in self.toggleBookmark() },
            UIAction(title: "DevTools", image: UIImage(systemName: "ladybug")) { _ in self.showDevTools() },
            UIAction(title: "Resize", image: UIImage(systemName: "rectangle.expand.vertical")) { _ in self.cycleSize() },
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu),
            UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
                            style: .plain, target: self, action: #selector(reload)),
        ]

        // Progress + container
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = accentColor
        progressView.trackTintColor = .clear
        view.addSubview(progressView)

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = bgColor
        view.addSubview(webContainer)

        // Bottom toolbar
        toolbarItems = [
            UIBarButtonItem(image: UIImage(systemName: "chevron.backward"),
                            style: .plain, target: self, action: #selector(goBack)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "chevron.forward"),
                            style: .plain, target: self, action: #selector(goForward)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"),
                            style: .plain, target: self, action: #selector(share)),
        ]
        navigationController?.isToolbarHidden = false
        navigationController?.toolbar.tintColor = accentColor
    }

    private func installTabBar() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.showsHorizontalScrollIndicator = false
        tabBar.backgroundColor = surfaceColor
        view.addSubview(tabBar)

        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabStack.axis = .horizontal
        tabStack.spacing = 4
        tabStack.layoutMargins = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        tabStack.isLayoutMarginsRelativeArrangement = true
        tabBar.addSubview(tabStack)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 34),

            tabStack.topAnchor.constraint(equalTo: tabBar.topAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            tabStack.heightAnchor.constraint(equalTo: tabBar.heightAnchor),

            progressView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            webContainer.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Tabs

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = fresh
            ? .nonPersistent() : .default()
        if #available(iOS 16.0, *) {
            cfg.preferences.isElementFullscreenEnabled = true
        }

        // DevTools-lite: intercept console.log/warn/error + fetch/XHR
        // by injecting a tiny script that posts back to Swift via
        // WKScriptMessage. Per-tab logs are stored on `Tab`.
        let inject = """
        (function(){
          if (window.__cb_devtools_installed) return;
          window.__cb_devtools_installed = true;
          function post(kind, payload){
            try { window.webkit.messageHandlers.cbDevTools.postMessage({kind:kind, ...payload}); } catch(_){}
          }
          ['log','warn','error','info'].forEach(function(level){
            var orig = console[level];
            console[level] = function(){
              try { post('console', {level:level, args:Array.from(arguments).map(String).join(' ')}); } catch(_){}
              orig.apply(console, arguments);
            };
          });
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function(input, init){
              var url = (typeof input === 'string') ? input : (input && input.url) || '';
              var method = (init && init.method) || 'GET';
              var t0 = performance.now();
              return origFetch.apply(this, arguments).then(function(r){
                post('net', {url:url, method:method, status:r.status, ms:Math.round(performance.now()-t0)});
                return r;
              }).catch(function(e){
                post('net', {url:url, method:method, status:-1, ms:Math.round(performance.now()-t0), error:String(e)});
                throw e;
              });
            };
          }
          var OX = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
          if (OX) {
            window.XMLHttpRequest.prototype.open = function(m, u){
              this.__cb_m = m; this.__cb_u = u; this.__cb_t = performance.now();
              this.addEventListener('loadend', function(){
                post('net', {url:this.__cb_u, method:this.__cb_m, status:this.status, ms:Math.round(performance.now()-this.__cb_t)});
              });
              return OX.apply(this, arguments);
            };
          }
          window.addEventListener('error', function(e){ post('console', {level:'error', args:String(e.message)}); });
        })();
        """
        let userScript = WKUserScript(source: inject,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
        cfg.userContentController.addUserScript(userScript)
        cfg.userContentController.add(self, name: "cbDevTools")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        return wv
    }

    @discardableResult
    private func openTab(url: URL?) -> Tab {
        let wv = makeWebView()
        let tab = Tab(webView: wv)
        tabs.append(tab)
        activeIdx = tabs.count - 1
        rebuildTabBar()
        showActiveTab()
        if let u = url {
            tab.urlString = u.absoluteString
            wv.load(URLRequest(url: u))
            urlField.text = u.absoluteString
        } else {
            wv.loadHTMLString(
                "<html><body style='background:#1a1d22;color:#aaa;font:14px system-ui;display:flex;align-items:center;justify-content:center;height:100vh'>New tab — type a URL above</body></html>",
                baseURL: nil)
            urlField.text = ""
        }
        return tab
    }

    private func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.webView.removeFromSuperview()
        tabs.remove(at: idx)
        if tabs.isEmpty { openTab(url: nil); return }
        activeIdx = min(activeIdx, tabs.count - 1)
        rebuildTabBar()
        showActiveTab()
    }

    private func switchTo(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        activeIdx = idx
        rebuildTabBar()
        showActiveTab()
    }

    private func showActiveTab() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let t = activeTab else { return }
        webContainer.addSubview(t.webView)
        NSLayoutConstraint.activate([
            t.webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            t.webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            t.webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            t.webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        urlField.text = t.urlString
        title = t.title
    }

    private func rebuildTabBar() {
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        for (idx, t) in tabs.enumerated() {
            let chip = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.title = String(t.title.prefix(22))
            cfg.image = UIImage(systemName: "xmark.circle.fill")
            cfg.imagePlacement = .trailing
            cfg.imagePadding = 6
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 6)
            cfg.baseForegroundColor = idx == activeIdx ? .white : textColor
            cfg.background.backgroundColor = idx == activeIdx ? accentColor : bgColor
            cfg.background.cornerRadius = 6
            chip.configuration = cfg
            chip.tag = idx
            chip.addTarget(self, action: #selector(tabChipTapped(_:)), for: .touchUpInside)
            // Long-press on chip = close
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(tabChipLongPress(_:)))
            chip.addGestureRecognizer(lp)
            tabStack.addArrangedSubview(chip)
        }
        // "+" button
        let add = UIButton(type: .system)
        add.setImage(UIImage(systemName: "plus"), for: .normal)
        add.tintColor = textColor
        add.addAction(UIAction { [weak self] _ in self?.openTab(url: nil) }, for: .touchUpInside)
        tabStack.addArrangedSubview(add)
    }

    @objc private func tabChipTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard tabs.indices.contains(idx) else { return }
        switchTo(tabs[idx])
    }

    @objc private func tabChipLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let chip = g.view as? UIButton else { return }
        let idx = chip.tag
        guard tabs.indices.contains(idx) else { return }
        closeTab(tabs[idx])
    }

    // MARK: - Toolbar actions

    @objc private func done()      { dismiss(animated: true) }
    @objc private func goBack()    { activeTab.map { if $0.webView.canGoBack { $0.webView.goBack() } } }
    @objc private func goForward() { activeTab.map { if $0.webView.canGoForward { $0.webView.goForward() } } }
    @objc private func reload()    { activeTab?.webView.reload() }
    @objc private func share() {
        guard let url = activeTab?.webView.url else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        av.popoverPresentationController?.barButtonItem = toolbarItems?.last
        present(av, animated: true)
    }

    // MARK: - URL field

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        field.resignFirstResponder()
        guard var text = field.text?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty, let t = activeTab else { return true }
        if !text.contains("://") { text = "https://" + text }
        guard let u = URL(string: text) else { return true }
        t.urlString = u.absoluteString
        t.webView.load(URLRequest(url: u))
        return true
    }

    // MARK: - Bookmarks

    private func toggleBookmark() {
        guard let t = activeTab, !t.urlString.isEmpty else { return }
        if BrowserDataStore.shared.isBookmarked(url: t.urlString) {
            BrowserDataStore.shared.removeBookmark(url: t.urlString)
            toast("Bookmark removed")
        } else {
            BrowserDataStore.shared.addBookmark(url: t.urlString, title: t.title)
            toast("Bookmark added")
        }
    }

    private func showBookmarks() {
        let list = BrowserDataStore.shared.loadBookmarks()
        let alert = UIAlertController(title: "Bookmarks",
                                      message: list.isEmpty ? "None yet." : nil,
                                      preferredStyle: .actionSheet)
        for b in list.reversed().prefix(20) {
            alert.addAction(UIAlertAction(title: b.title.isEmpty ? b.url : b.title,
                                          style: .default) { _ in
                guard let u = URL(string: b.url) else { return }
                self.openTab(url: u)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(alert, animated: true)
    }

    // MARK: - DevTools-lite

    func userContentController(_ ucc: WKUserContentController,
                               didReceive msg: WKScriptMessage) {
        guard msg.name == "cbDevTools",
              let d = msg.body as? [String: Any],
              let kind = d["kind"] as? String,
              let t = activeTab else { return }
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if kind == "console" {
            let lvl = (d["level"] as? String ?? "log").uppercased()
            let args = d["args"] as? String ?? ""
            t.consoleLog.append("[\(ts)] \(lvl): \(args)")
            if t.consoleLog.count > 500 { t.consoleLog.removeFirst(t.consoleLog.count - 500) }
        } else if kind == "net" {
            let m = d["method"] as? String ?? "?"
            let u = d["url"] as? String ?? ""
            let s = d["status"] as? Int ?? 0
            let ms = d["ms"] as? Int ?? 0
            t.networkLog.append("[\(ts)] \(m) \(s) \(ms)ms — \(u)")
            if t.networkLog.count > 500 { t.networkLog.removeFirst(t.networkLog.count - 500) }
        }
    }

    private func showDevTools() {
        guard let t = activeTab else { return }
        let vc = DevToolsPanelViewController(tabTitle: t.title,
                                             console: t.consoleLog,
                                             network: t.networkLog)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if #available(iOS 16.0, *), let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    // MARK: - Size cycler

    private enum Size: Int { case small, medium, full }
    private var sizeMode: Size = .full
    private func cycleSize() {
        sizeMode = Size(rawValue: (sizeMode.rawValue + 1) % 3) ?? .full
        guard #available(iOS 16.0, *),
              let sheet = navigationController?.sheetPresentationController else { return }
        let small = UISheetPresentationController.Detent.custom(
            identifier: .init("mini-small")) { $0.maximumDetentValue * 0.30 }
        sheet.animateChanges {
            sheet.detents = [small, .medium(), .large()]
            switch sizeMode {
            case .small:  sheet.selectedDetentIdentifier = .init("mini-small")
            case .medium: sheet.selectedDetentIdentifier = .medium
            case .full:   sheet.selectedDetentIdentifier = .large
            }
            sheet.prefersGrabberVisible = true
            sheet.largestUndimmedDetentIdentifier = .large
        }
    }

    // MARK: - Toast

    private func toast(_ msg: String) {
        let l = UILabel()
        l.text = "  \(msg)  "
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = accentColor
        l.layer.cornerRadius = 8
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        l.alpha = 0
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
            l.heightAnchor.constraint(equalToConstant: 28),
        ])
        UIView.animate(withDuration: 0.2, animations: { l.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.1, options: [], animations: { l.alpha = 0 }) { _ in
                l.removeFromSuperview()
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ wv: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
        progressView.alpha = 1
        progressView.setProgress(0.1, animated: false)
    }

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        progressView.setProgress(1.0, animated: true)
        UIView.animate(withDuration: 0.3) { self.progressView.alpha = 0 }
        guard let tab = tabs.first(where: { $0.webView === wv }) else { return }
        if let u = wv.url?.absoluteString { tab.urlString = u; if tab === activeTab { urlField.text = u } }
        wv.evaluateJavaScript("document.title") { [weak self] r, _ in
            guard let self, let t = r as? String, !t.isEmpty else { return }
            tab.title = t
            if tab === self.activeTab { self.title = t }
            self.rebuildTabBar()
            if !self.fresh, let u = wv.url?.absoluteString {
                BrowserDataStore.shared.recordVisit(url: u, title: t)
            }
        }
    }
}

// MARK: - DevTools panel

final class DevToolsPanelViewController: UIViewController {
    private let tabTitle: String
    private let console: [String]
    private let network: [String]
    private let segment = UISegmentedControl(items: ["Console", "Network"])
    private let textView = UITextView()

    init(tabTitle: String, console: [String], network: [String]) {
        self.tabTitle = tabTitle
        self.console = console
        self.network = network
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)
        title = "DevTools — \(tabTitle)"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain, target: self, action: #selector(copyAll))

        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.selectedSegmentIndex = 0
        segment.addTarget(self, action: #selector(switchPane), for: .valueChanged)
        view.addSubview(segment)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.textColor = UIColor(red: 0.82, green: 0.835, blue: 0.87, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            segment.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            textView.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        refresh()
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func switchPane() { refresh() }
    @objc private func copyAll() { UIPasteboard.general.string = textView.text }

    private func refresh() {
        let lines = segment.selectedSegmentIndex == 0 ? console : network
        textView.text = lines.isEmpty ? "(empty — interact with the page first)" : lines.joined(separator: "\n")
    }
}
