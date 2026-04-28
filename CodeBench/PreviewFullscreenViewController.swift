import UIKit
import WebKit
import PDFKit
import AVKit
import AVFoundation

/// Modal full-screen viewer for a single output artefact (image, PDF,
/// HTML / SVG / GIF, or video). Presented from the editor's preview
/// pane via the "expand" button so the user can inspect a render at
/// full canvas size rather than the 40%-width side pane.
///
/// One renderer per content kind, picked from the file extension:
///   • PDF                 → PDFKit `PDFView`
///   • PNG / JPEG          → `UIImageView` inside a pinch-zoom scroll view
///   • MP4 / MOV / M4V     → `AVPlayerViewController` (native scrubber, PiP, AirPlay)
///   • WEBM                → `WKWebView` (AVPlayer can't decode webm on iOS)
///   • GIF                 → `WKWebView` with HTML5 <img> wrapper
///   • HTML / SVG          → `WKWebView` loaded directly
final class PreviewFullscreenViewController: UIViewController {

    private let path: String
    private let ext: String

    init(path: String) {
        self.path = path
        self.ext = (path as NSString).pathExtension.lowercased()
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installContent()
        installCloseButton()
        installShareButton()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Content

    private func installContent() {
        let url = URL(fileURLWithPath: path)
        switch ext {
        case "pdf":
            installPDF(url: url)
        case "png", "jpg", "jpeg", "bmp", "tiff", "heic":
            installImage(url: url)
        case "mp4", "mov", "m4v":
            installVideoNative(url: url)
        case "webm":
            installWebVideo(url: url)
        case "gif":
            installGIF(url: url)
        case "svg", "html", "htm":
            installWeb(url: url)
        default:
            installUnsupported()
        }
    }

    private func installPDF(url: URL) {
        let v = PDFView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .black
        v.document = PDFDocument(url: url)
        view.addSubview(v)
        pinToSafeArea(v)
    }

    private func installImage(url: URL) {
        guard let img = UIImage(contentsOfFile: url.path) else {
            installUnsupported(); return
        }
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .black
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = self

        let iv = UIImageView(image: img)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFit
        iv.tag = 4242  // viewForZooming uses this to find the image
        scroll.addSubview(iv)

        view.addSubview(scroll)
        pinToSafeArea(scroll)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            iv.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            iv.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        // Double-tap to toggle zoom.
        let dt = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapZoom(_:)))
        dt.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(dt)
    }

    private func installVideoNative(url: URL) {
        // AVPlayerViewController gives us the system playback chrome
        // (scrubber, PiP, AirPlay, captions menu). Embed as a child VC
        // so we can keep our own close/share buttons on top.
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        let pvc = AVPlayerViewController()
        pvc.player = player
        pvc.allowsPictureInPicturePlayback = true
        pvc.entersFullScreenWhenPlaybackBegins = false
        pvc.exitsFullScreenWhenPlaybackEnds = false
        addChild(pvc)
        pvc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pvc.view)
        pinToSafeArea(pvc.view)
        pvc.didMove(toParent: self)

        // Loop indefinitely.
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
    }

    private func installWebVideo(url: URL) {
        // webm — AVFoundation can't decode it on iOS, so use WKWebView
        // with an HTML5 <video> tag.
        let html = """
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;display:flex;align-items:center;justify-content:center}
        video{max-width:100%;max-height:100%}</style></head>
        <body><video src="\(url.lastPathComponent)" controls autoplay loop playsinline></video></body></html>
        """
        let htmlURL = url.deletingLastPathComponent()
            .appendingPathComponent("_fs_webm.html")
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let wv = makeWebView()
        view.addSubview(wv)
        pinToSafeArea(wv)
        wv.loadFileURL(htmlURL, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func installGIF(url: URL) {
        let html = """
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;display:flex;align-items:center;justify-content:center}
        img{max-width:100%;max-height:100%}</style></head>
        <body><img src="\(url.lastPathComponent)"></body></html>
        """
        let htmlURL = url.deletingLastPathComponent()
            .appendingPathComponent("_fs_gif.html")
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let wv = makeWebView()
        view.addSubview(wv)
        pinToSafeArea(wv)
        wv.loadFileURL(htmlURL, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func installWeb(url: URL) {
        let wv = makeWebView()
        view.addSubview(wv)
        pinToSafeArea(wv)
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func installUnsupported() {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = "No fullscreen viewer for .\(ext)"
        l.textColor = .lightGray
        l.font = .systemFont(ofSize: 16, weight: .medium)
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.backgroundColor = .black
        wv.isOpaque = false
        wv.scrollView.backgroundColor = .black
        return wv
    }

    // MARK: - Chrome (close + share)

    private func installCloseButton() {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        btn.setImage(UIImage(systemName: "xmark", withConfiguration: cfg), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor(white: 0, alpha: 0.55)
        btn.layer.cornerRadius = 22
        btn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btn.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            btn.widthAnchor.constraint(equalToConstant: 44),
            btn.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func installShareButton() {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        btn.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: cfg), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor(white: 0, alpha: 0.55)
        btn.layer.cornerRadius = 22
        btn.addTarget(self, action: #selector(shareTapped(_:)), for: .touchUpInside)
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            btn.widthAnchor.constraint(equalToConstant: 44),
            btn.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func shareTapped(_ sender: UIButton) {
        let url = URL(fileURLWithPath: path)
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = sender
        ac.popoverPresentationController?.sourceRect = sender.bounds
        present(ac, animated: true)
    }

    // MARK: - Helpers

    private func pinToSafeArea(_ v: UIView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func handleDoubleTapZoom(_ gr: UITapGestureRecognizer) {
        guard let scroll = gr.view as? UIScrollView else { return }
        if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
        } else {
            let target: CGFloat = min(3.0, scroll.maximumZoomScale)
            let pt = gr.location(in: scroll)
            let size = scroll.bounds.size
            let w = size.width / target
            let h = size.height / target
            let rect = CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h)
            scroll.zoom(to: rect, animated: true)
        }
    }
}

extension PreviewFullscreenViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView.viewWithTag(4242)
    }
}
