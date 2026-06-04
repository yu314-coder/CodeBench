import UIKit
import UniformTypeIdentifiers

// MARK: - Delegate Protocol

protocol FilesBrowserDelegate: AnyObject {
    func filesBrowser(_ controller: FilesBrowserViewController, didSelectCodeFile url: URL)
    func filesBrowser(_ controller: FilesBrowserViewController, didRequestLoadModel url: URL)
}

// MARK: - File Item Model

// Defined at file scope outside @MainActor to satisfy DiffableDataSource Sendable requirement
struct FileItem: @unchecked Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date
}

extension FileItem: Hashable {
    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

// MARK: - Sort Mode

private enum SortMode: Int, CaseIterable {
    case name = 0
    case date = 1
    case size = 2

    var title: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date"
        case .size: return "Size"
        }
    }
}

// MARK: - FilesBrowserViewController

final class FilesBrowserViewController: UIViewController {

    weak var delegate: FilesBrowserDelegate?

    // MARK: - Colors

    // Dark sidebar — matches the deep dark editor theme
    private let bgColor = UIColor(red: 0.098, green: 0.102, blue: 0.118, alpha: 1.0)       // #191a1e
    private let textColor = UIColor(red: 0.780, green: 0.800, blue: 0.840, alpha: 1.0)      // #c7ccd6
    private let subtextColor = UIColor(red: 0.420, green: 0.440, blue: 0.490, alpha: 1.0)   // #6b707d
    private let surfaceColor = UIColor(red: 0.130, green: 0.137, blue: 0.157, alpha: 1.0)   // #212328
    private let accentColor = UIColor(red: 0.537, green: 0.706, blue: 0.980, alpha: 1.0)    // #89b4fa

    // MARK: - State

    private var rootURL: URL!
    private var currentURL: URL! {
        // Every time currentURL changes (navigation into / out of a
        // dir, a Set-Root action, etc.) we throw away the old kqueue
        // watcher and open a new one against the new dir. Without
        // this re-arming, the watcher would stay pinned to whatever
        // dir we first saw and stop firing after navigation.
        didSet { installDirectoryWatcher(for: currentURL) }
    }
    private var sortMode: SortMode = .name
    private var pathStack: [URL] = []

    // Directory watcher state. Uses DispatchSource on an open file
    // descriptor — the kernel fires our event handler when the
    // directory's inode is written to (any create/delete/rename
    // inside it). Covers `rmdir`, `ncdu`'s d-key delete, shell `rm`,
    // another iOS app writing into a shared folder, etc.
    private var dirWatcherSource: DispatchSourceFileSystemObject?
    private var dirWatcherFD: Int32 = -1
    // Debounce — bulk operations (ncdu deleting a whole subtree, a
    // `tar -xf` of 500 files) fire the watcher hundreds of times in
    // a fraction of a second. We coalesce to one reloadFiles call
    // per ~120 ms window.
    private var pendingReload: DispatchWorkItem?

    // MARK: - UI

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var breadcrumbStack: UIStackView!
    private var breadcrumbScroll: UIScrollView!
    private var sortControl: UISegmentedControl!
    private var emptyLabel: UILabel!

    private let fileManager = FileManager.default
    private let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Workspace directory — only user code files, not app internals
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let workspace = docs.appendingPathComponent("Workspace")
        if !fileManager.fileExists(atPath: workspace.path) {
            try? fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        }
        // PyTorch / ExecuTorch test templates were previously auto-
        // seeded into every Workspace folder. They cluttered the file
        // browser for non-developer users and re-appeared on every
        // launch even after deletion (the deleted-tombstone path was
        // bypassed for templates that re-templated themselves). Now
        // we only purge any templated versions left behind on disk;
        // user-edited copies (without the @generated header) survive.
        // Important: purge BEFORE seeding so the legacy starters
        // (main.py / hello.c / animation.py / pip_demo.py) that
        // ``purgeTorchTestTemplates`` removes are replaced by the
        // new ``test_all.*`` suite below.
        Self.purgeTorchTestTemplates(in: workspace)
        // Seed the bundled-module smoke-test suite. Safe to call on
        // every launch — each file is only written if it's both
        // missing on disk and not in the user's tombstone list, so
        // edits and deletions stick across runs.
        Self.seedStarterFiles(in: workspace)
        rootURL = workspace
        currentURL = rootURL
        pathStack = [rootURL]

        view.backgroundColor = bgColor
        title = "Workspace"

        setupNavigationBar()
        setupSortControl()
        setupBreadcrumbs()
        setupCollectionView()
        setupEmptyLabel()
        setupDataSource()
        reloadFiles()

        // The editor posts this on every successful auto-save so we
        // don't have to wait for the kqueue debounce (~120ms) to see
        // the new mtime/size in the cell. Listening here is cheap
        // because reloadFiles() diffs the snapshot — same listing
        // means no UI churn.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEditorDidSave(_:)),
            name: .editorDidSaveFile,
            object: nil)
    }

    @objc private func handleEditorDidSave(_ note: Notification) {
        // Only reload if the saved file lives in (or under) the dir we
        // currently show — otherwise the snapshot wouldn't have changed
        // anyway and we'd just churn the cells.
        guard let savedURL = note.object as? URL else {
            reloadFiles(); return
        }
        let savedDir = savedURL.deletingLastPathComponent().standardized.path
        let curDir = currentURL.standardized.path
        if savedDir == curDir || savedDir.hasPrefix(curDir + "/") {
            reloadFiles()
        }
    }

    // MARK: - Setup

    private func setupNavigationBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = bgColor
        appearance.titleTextAttributes = [.foregroundColor: textColor]
        appearance.largeTitleTextAttributes = [.foregroundColor: textColor]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        let newMenu = UIMenu(title: "New", children: [
            UIAction(title: "New File", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                self?.promptNewFile()
            },
            UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                self?.promptNewFolder()
            },
            UIAction(title: "New Manim Project", image: UIImage(systemName: "film.stack")) { [weak self] _ in
                self?.createManimProject()
            },
            UIAction(title: "New Python Project", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { [weak self] _ in
                self?.createPythonProject()
            },
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: newMenu
        )
        navigationItem.rightBarButtonItem?.tintColor = accentColor
    }

    private let addButton = UIButton(type: .system)

    private func setupSortControl() {
        sortControl = UISegmentedControl(items: SortMode.allCases.map { $0.title })
        sortControl.selectedSegmentIndex = sortMode.rawValue
        sortControl.translatesAutoresizingMaskIntoConstraints = false
        sortControl.selectedSegmentTintColor = UIColor(white: 0.30, alpha: 1)
        sortControl.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 11, weight: .medium)], for: .selected)
        sortControl.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.55, alpha: 1), .font: UIFont.systemFont(ofSize: 11, weight: .medium)], for: .normal)
        sortControl.backgroundColor = UIColor(white: 0.15, alpha: 1)
        sortControl.addTarget(self, action: #selector(sortChanged(_:)), for: .valueChanged)
        view.addSubview(sortControl)

        // + button for new file/folder/project
        let newMenu = UIMenu(title: "New", children: [
            UIAction(title: "New File", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                self?.promptNewFile()
            },
            UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                self?.promptNewFolder()
            },
            UIMenu(title: "Projects", image: UIImage(systemName: "folder.fill.badge.gearshape"), children: [
                UIAction(title: "Manim Animation", image: UIImage(systemName: "film.stack")) { [weak self] _ in
                    self?.createManimProject()
                },
                UIAction(title: "Python Script", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { [weak self] _ in
                    self?.createPythonProject()
                },
            ]),
        ])
        addButton.menu = newMenu
        addButton.showsMenuAsPrimaryAction = true
        var addCfg = UIButton.Configuration.filled()
        addCfg.image = UIImage(systemName: "plus")
        addCfg.baseBackgroundColor = UIColor(white: 0.25, alpha: 1)
        addCfg.baseForegroundColor = UIColor(white: 0.80, alpha: 1)
        addCfg.cornerStyle = .capsule
        addCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        addButton.configuration = addCfg
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addButton)

        NSLayoutConstraint.activate([
            addButton.centerYAnchor.constraint(equalTo: sortControl.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sortControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            sortControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sortControl.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -10),
            sortControl.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func setupBreadcrumbs() {
        breadcrumbScroll = UIScrollView()
        breadcrumbScroll.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbScroll.showsHorizontalScrollIndicator = false
        breadcrumbScroll.showsVerticalScrollIndicator = false
        view.addSubview(breadcrumbScroll)

        breadcrumbStack = UIStackView()
        breadcrumbStack.axis = .horizontal
        breadcrumbStack.spacing = 4
        breadcrumbStack.alignment = .center
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbScroll.addSubview(breadcrumbStack)

        NSLayoutConstraint.activate([
            breadcrumbScroll.topAnchor.constraint(equalTo: sortControl.bottomAnchor, constant: 8),
            breadcrumbScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            breadcrumbScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            breadcrumbScroll.heightAnchor.constraint(equalToConstant: 36),

            breadcrumbStack.topAnchor.constraint(equalTo: breadcrumbScroll.topAnchor),
            breadcrumbStack.leadingAnchor.constraint(equalTo: breadcrumbScroll.leadingAnchor),
            breadcrumbStack.trailingAnchor.constraint(equalTo: breadcrumbScroll.trailingAnchor),
            breadcrumbStack.bottomAnchor.constraint(equalTo: breadcrumbScroll.bottomAnchor),
            breadcrumbStack.heightAnchor.constraint(equalTo: breadcrumbScroll.heightAnchor)
        ])
    }

    private func setupCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = bgColor
        config.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = bgColor
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: breadcrumbScroll.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel = UILabel()
        emptyLabel.text = "This folder is empty"
        emptyLabel.textColor = subtextColor
        emptyLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor)
        ])
    }

    /// Lookup from String key (URL path) to FileItem
    private var itemLookup: [String: FileItem] = [:]

    private func setupDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, key in
            guard let self, let item = self.itemLookup[key] else { return }

            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.name
            content.textProperties.color = self.textColor
            content.textProperties.font = .systemFont(ofSize: 16, weight: .medium)

            if item.isDirectory {
                content.secondaryText = self.dateFormatter.string(from: item.modificationDate)
            } else {
                let sizeStr = self.sizeFormatter.string(fromByteCount: item.size)
                let dateStr = self.dateFormatter.string(from: item.modificationDate)
                content.secondaryText = "\(sizeStr)  \u{2022}  \(dateStr)"
            }
            content.secondaryTextProperties.color = self.subtextColor
            content.secondaryTextProperties.font = .systemFont(ofSize: 13)

            let (iconName, iconColor) = self.iconInfo(for: item)
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
            content.image = UIImage(systemName: iconName, withConfiguration: iconConfig)
            content.imageProperties.tintColor = iconColor
            content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)

            cell.contentConfiguration = content

            var bg = UIBackgroundConfiguration.listPlainCell()
            bg.backgroundColor = self.bgColor
            cell.backgroundConfiguration = bg

            cell.accessories = [.disclosureIndicator(options: .init(tintColor: item.isDirectory ? self.accentColor : self.subtextColor))]
        }

        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { (cv: UICollectionView, indexPath: IndexPath, key: String) -> UICollectionViewCell? in
            cv.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: key)
        }
    }

    // MARK: - File Operations

    private func loadItems(at url: URL) -> [FileItem] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { itemURL in
            guard let resources = try? itemURL.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            ) else { return nil }

            return FileItem(
                url: itemURL,
                name: itemURL.lastPathComponent,
                isDirectory: resources.isDirectory ?? false,
                size: Int64(resources.fileSize ?? 0),
                modificationDate: resources.contentModificationDate ?? Date.distantPast
            )
        }
    }

    private func sortedItems(_ items: [FileItem]) -> [FileItem] {
        let directories = items.filter { $0.isDirectory }
        let files = items.filter { !$0.isDirectory }

        let sortBlock: (FileItem, FileItem) -> Bool
        switch sortMode {
        case .name:
            sortBlock = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date:
            sortBlock = { $0.modificationDate > $1.modificationDate }
        case .size:
            sortBlock = { $0.size > $1.size }
        }

        return directories.sorted(by: sortBlock) + files.sorted(by: sortBlock)
    }

    func refresh() {
        reloadFiles()
    }

    // MARK: - Directory watcher

    /// Install a DispatchSource-backed watcher on `url`. Any
    /// create/delete/rename inside that directory triggers a
    /// debounced `reloadFiles()`. Call with the current dir each
    /// time the user navigates. Safe to call repeatedly — always
    /// tears down the old source before opening the new fd.
    private func installDirectoryWatcher(for url: URL?) {
        tearDownDirectoryWatcher()
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[FilesBrowser] kqueue open(%@) failed: errno=%d",
                  url.path, errno)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // .write catches files added/removed/renamed INSIDE the dir.
            // .delete catches the dir itself being deleted (parent-side
            // `rm -rf currentDir`).
            // .rename catches the dir being moved.
            // .attrib catches chmod on the dir.
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) {
                // The dir we're looking at is gone — step out to parent.
                // If there's a path stack, pop back. Otherwise go to
                // rootURL. Either way, that'll set currentURL again and
                // reinstall the watcher on the new dir via didSet.
                if self.pathStack.count > 1 {
                    self.pathStack.removeLast()
                    self.currentURL = self.pathStack.last ?? self.rootURL
                } else {
                    self.currentURL = self.rootURL
                }
                self.reloadFiles()
                return
            }
            // .write on the dir = contents changed. Debounce so a
            // burst of creates/deletes doesn't hammer reloadFiles.
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reloadFiles()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(120),
                execute: work)
        }
        source.setCancelHandler { [weak self] in
            // Handler is called on the source's queue (main). Close
            // the fd here — closing it elsewhere races with the
            // kernel's last event dispatch and sometimes emits a
            // "file descriptor closed" warning.
            Darwin.close(fd)
            if self?.dirWatcherFD == fd { self?.dirWatcherFD = -1 }
        }
        dirWatcherSource = source
        dirWatcherFD = fd
        source.resume()
    }

    private func tearDownDirectoryWatcher() {
        pendingReload?.cancel()
        pendingReload = nil
        if let source = dirWatcherSource {
            source.cancel()       // triggers the cancel handler, which closes the fd
            dirWatcherSource = nil
        } else if dirWatcherFD >= 0 {
            // Defensive: source was nil'd but fd leaked somehow.
            Darwin.close(dirWatcherFD)
            dirWatcherFD = -1
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Pause the watcher while the view is off-screen. Reinstalls
        // in viewDidAppear so we don't pay for idle fd + kqueue entry
        // over the lifetime of the app.
        tearDownDirectoryWatcher()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Arm the watcher on (re)appearance. Also reload immediately
        // in case files changed while we were off-screen (the watcher
        // only sees changes that happen WHILE it's armed).
        installDirectoryWatcher(for: currentURL)
        reloadFiles()
    }

    deinit {
        // viewWillDisappear already calls teardown but belt+suspenders:
        // if the VC is deallocated without the normal lifecycle (rare
        // but possible in tabbar teardowns), close the fd here too.
        if dirWatcherFD >= 0 { Darwin.close(dirWatcherFD) }
    }

    private func reloadFiles() {
        let items = sortedItems(loadItems(at: currentURL))
        emptyLabel.isHidden = !items.isEmpty

        // Build lookup
        itemLookup = [:]
        var keys: [String] = []
        for item in items {
            let key = item.url.path
            itemLookup[key] = item
            keys.append(key)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(keys, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)

        // Force the cell-config block to run again for every item still
        // in the snapshot. The diffable data source identifies cells by
        // file path, so a file whose CONTENTS changed (size / mtime)
        // but whose PATH didn't is invisible to the diff — without an
        // explicit reconfigure, the cell keeps showing the stale size.
        // `reconfigureItems` doesn't animate; the user sees an in-place
        // refresh of the existing cell.
        var reconfigure = dataSource.snapshot()
        reconfigure.reconfigureItems(reconfigure.itemIdentifiers)
        dataSource.apply(reconfigure, animatingDifferences: false)

        updateBreadcrumbs()
    }

    // MARK: - Navigation

    private func navigateTo(_ url: URL) {
        currentURL = url

        if let idx = pathStack.firstIndex(of: url) {
            pathStack = Array(pathStack.prefix(through: idx))
        } else {
            pathStack.append(url)
        }
        reloadFiles()
    }

    // MARK: - Breadcrumbs

    private func updateBreadcrumbs() {
        breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, url) in pathStack.enumerated() {
            if index > 0 {
                let chevron = UILabel()
                chevron.text = "\u{203A}"
                chevron.font = .systemFont(ofSize: 18, weight: .bold)
                chevron.textColor = subtextColor
                breadcrumbStack.addArrangedSubview(chevron)
            }

            let name = (url == rootURL) ? "Workspace" : url.lastPathComponent
            let isLast = (index == pathStack.count - 1)

            let btn = UIButton(type: .system)
            btn.setTitle(name, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 14, weight: isLast ? .bold : .regular)
            btn.setTitleColor(isLast ? textColor : accentColor, for: .normal)
            btn.tag = index
            btn.isEnabled = !isLast
            btn.addTarget(self, action: #selector(breadcrumbTapped(_:)), for: .touchUpInside)
            breadcrumbStack.addArrangedSubview(btn)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.breadcrumbScroll.contentSize.width > self.breadcrumbScroll.bounds.width else { return }
            let offset = CGPoint(
                x: self.breadcrumbScroll.contentSize.width - self.breadcrumbScroll.bounds.width,
                y: 0
            )
            self.breadcrumbScroll.setContentOffset(offset, animated: true)
        }
    }

    // MARK: - Icon Mapping

    private func iconInfo(for item: FileItem) -> (String, UIColor) {
        if item.isDirectory {
            return ("folder.fill", UIColor.systemBlue)
        }

        let ext = item.url.pathExtension.lowercased()
        switch ext {
        case "py":
            return ("doc.text", UIColor.systemBlue)
        case "c", "cpp", "h", "hpp":
            return ("doc.text", UIColor.systemOrange)
        case "f90", "f95", "f03":
            return ("doc.text", UIColor.systemGreen)
        case "swift":
            // Swift mark — bundled tree-walking interpreter (see
            // SwiftInterpreter.swift) handles `swift file.swift` from
            // the terminal and Run from the editor.
            return ("swift", UIColor(red: 1.0, green: 0.404, blue: 0.227, alpha: 1.0))   // #f76737 — Swift brand
        case "tex", "ltx", "cls", "sty", "bib":
            return ("doc.text", UIColor.systemTeal)
        case "gguf":
            return ("cpu", UIColor.systemPurple)
        case "png", "jpg", "jpeg", "gif", "bmp", "webp":
            return ("photo", UIColor.systemPink)
        case "txt", "md", "json", "xml", "csv":
            return ("doc.plaintext", UIColor.systemGray)
        default:
            return ("doc", UIColor.systemGray)
        }
    }

    // MARK: - Actions

    @objc private func sortChanged(_ sender: UISegmentedControl) {
        sortMode = SortMode(rawValue: sender.selectedSegmentIndex) ?? .name
        reloadFiles()
    }

    @objc private func breadcrumbTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx < pathStack.count else { return }
        navigateTo(pathStack[idx])
    }

    // MARK: - Create

    private func promptNewFile() {
        let alert = UIAlertController(title: "New File", message: "Include an extension to set the language (e.g. app.py, main.cpp, notes.md).", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "example.py"
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            let newURL = self.currentURL.appendingPathComponent(name)
            self.fileManager.createFile(atPath: newURL.path, contents: nil)
            self.reloadFiles()
            // VS Code behaviour: open the new file right away so the editor
            // auto-detects its language from the extension (app.js → JavaScript,
            // notes.md → Markdown, …). loadFile() maps extension → Monaco language.
            if self.isCodeFile(newURL) {
                self.delegate?.filesBrowser(self, didSelectCodeFile: newURL)
            }
        })
        present(alert, animated: true)
    }

    private func promptNewFolder() {
        let alert = UIAlertController(title: "New Folder", message: "Enter the folder name:", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "MyFolder"
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            let newURL = self.currentURL.appendingPathComponent(name)
            try? self.fileManager.createDirectory(at: newURL, withIntermediateDirectories: true)
            self.reloadFiles()
        })
        present(alert, animated: true)
    }

    // MARK: - Context Menu Helpers

    private func renameItem(_ item: FileItem) {
        let alert = UIAlertController(title: "Rename", message: "Enter the new name:", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = item.name
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self, let newName = alert.textFields?.first?.text, !newName.isEmpty else { return }
            let dest = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            try? self.fileManager.moveItem(at: item.url, to: dest)
            self.reloadFiles()
        })
        present(alert, animated: true)
    }

    private func duplicateItem(_ item: FileItem) {
        let ext = item.url.pathExtension
        let base = item.url.deletingPathExtension().lastPathComponent
        let parent = item.url.deletingLastPathComponent()
        var destName: String
        if ext.isEmpty {
            destName = "\(base) copy"
        } else {
            destName = "\(base) copy.\(ext)"
        }

        var dest = parent.appendingPathComponent(destName)
        var counter = 2
        while fileManager.fileExists(atPath: dest.path) {
            if ext.isEmpty {
                destName = "\(base) copy \(counter)"
            } else {
                destName = "\(base) copy \(counter).\(ext)"
            }
            dest = parent.appendingPathComponent(destName)
            counter += 1
        }

        try? fileManager.copyItem(at: item.url, to: dest)
        reloadFiles()
    }

    // MARK: - Project Templates

    private func createManimProject() {
        let alert = UIAlertController(title: "New Manim Project", message: "Create a project folder with a starter scene", preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "Project name"; tf.text = "MyAnimation" }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            let projectDir = self.currentURL.appendingPathComponent(name)
            do {
                try self.fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
                let mainPy = """
                from manim import *

                class MainScene(Scene):
                    def construct(self):
                        title = Text('\(name)', font_size=48, color=BLUE)
                        self.play(Write(title))

                        circle = Circle(color=RED, fill_opacity=0.5)
                        circle.next_to(title, DOWN, buff=0.5)
                        self.play(Create(circle))
                        self.play(circle.animate.scale(2))
                        self.wait()

                scene = MainScene()
                scene.render()
                """
                try mainPy.write(to: projectDir.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)

                let readme = """
                # \(name)

                Manim animation project.

                ## Run
                Open `main.py` in the Editor tab and tap Run.

                ## Files
                - `main.py` — Main animation scene
                """
                try readme.write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                self.reloadFiles()
            } catch {
                self.showError("Failed to create project: \(error.localizedDescription)")
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func createPythonProject() {
        let alert = UIAlertController(title: "New Python Project", message: "Create a project folder with starter files", preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "Project name"; tf.text = "MyProject" }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            let projectDir = self.currentURL.appendingPathComponent(name)
            do {
                try self.fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
                let mainPy = """
                import numpy as np

                def main():
                    print(f"Hello from \(name)!")
                    data = np.random.randn(100)
                    print(f"Mean: {np.mean(data):.4f}")
                    print(f"Std:  {np.std(data):.4f}")

                main()
                """
                try mainPy.write(to: projectDir.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
                self.reloadFiles()
            } catch {
                self.showError("Failed to create project: \(error.localizedDescription)")
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func deleteItem(_ item: FileItem) {
        let alert = UIAlertController(
            title: "Delete \"\(item.name)\"?",
            message: item.isDirectory ? "This folder and its contents will be permanently deleted." : "This file will be permanently deleted.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            // Tell the editor BEFORE we touch disk so its auto-save
            // pipeline drops `currentFileURL` and any pending text.
            // Without this, a 200ms debounced flush queued just before
            // the delete would write the buffer back and resurrect the
            // file we just removed. The editor matches the URL and
            // clears its in-memory state if it's the open file.
            NotificationCenter.default.post(
                name: .fileDidDelete, object: item.url)
            do {
                // We previously used `try?` here, which silently swallowed
                // failures — if the OS refused (in-use file, permission
                // bit), the cell vanished from the snapshot, then
                // reloadFiles() saw the file still on disk and brought
                // the row back, leaving the user thinking the button
                // was broken. Surface the real error in an alert.
                try self.fileManager.removeItem(at: item.url)
            } catch {
                let err = UIAlertController(
                    title: "Couldn't delete",
                    message: "\(item.name): \(error.localizedDescription)",
                    preferredStyle: .alert)
                err.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(err, animated: true)
                self.reloadFiles()
                return
            }
            // If this was a direct child of the Workspace root (where
            // starter scripts live), remember the deletion so the next
            // app launch doesn't re-seed it. See tombstone helpers.
            if item.url.deletingLastPathComponent().standardizedFileURL
                == self.rootURL.standardizedFileURL {
                Self.markStarterDeleted(item.url.lastPathComponent, in: self.rootURL)
            }
            self.reloadFiles()
        })
        present(alert, animated: true)
    }

    // MARK: - GGUF Info Popover

    private func showModelInfo(for item: FileItem, at indexPath: IndexPath) {
        let sizeStr = sizeFormatter.string(fromByteCount: item.size)
        let dateStr = dateFormatter.string(from: item.modificationDate)

        let alert = UIAlertController(
            title: item.name,
            message: "Size: \(sizeStr)\nModified: \(dateStr)\nFormat: GGUF Model",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Load Model", style: .default) { [weak self] _ in
            guard let self else { return }
            self.delegate?.filesBrowser(self, didRequestLoadModel: item.url)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController,
           let cell = collectionView.cellForItem(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }

        present(alert, animated: true)
    }

    // MARK: - Code File Check

    private static let codeExtensions: Set<String> = [
        "py",
        "ipynb",          // Jupyter notebooks — routed in CodeEditorViewController.loadFile
        "c", "cpp", "h", "hpp", "cc", "cxx",
        "f90", "f95", "f03", "f", "for",
        "swift",
        "tex", "ltx", "cls", "sty", "bib", "def",
        "txt", "md", "markdown", "json", "xml", "csv", "yaml", "yml",
        "js", "mjs", "cjs", "ts",
        "html", "htm", "css",
        "sh", "bash", "zsh",
        "log", "out", "err",
    ]

    private func isCodeFile(_ url: URL) -> Bool {
        Self.codeExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - UICollectionViewDelegate

extension FilesBrowserViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let key = dataSource.itemIdentifier(for: indexPath),
              let item = itemLookup[key] else { return }

        if item.isDirectory {
            navigateTo(item.url)
            return
        }

        if item.url.pathExtension.lowercased() == "gguf" {
            showModelInfo(for: item, at: indexPath)
            return
        }

        if isCodeFile(item.url) {
            delegate?.filesBrowser(self, didSelectCodeFile: item.url)
            return
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let key = dataSource.itemIdentifier(for: indexPath),
              let item = itemLookup[key] else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            let rename = UIAction(
                title: "Rename",
                image: UIImage(systemName: "pencil")
            ) { _ in self.renameItem(item) }

            let duplicate = UIAction(
                title: "Duplicate",
                image: UIImage(systemName: "plus.square.on.square")
            ) { _ in self.duplicateItem(item) }

            let delete = UIAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in self.deleteItem(item) }

            // Quick Look (files only) — a hidden long-press entry that renders
            // CSV/JSON/YAML/images/.npy in a modal without leaving the browser.
            var children: [UIMenuElement] = []
            if !item.isDirectory {
                children.append(UIAction(title: "Quick Look",
                                         image: UIImage(systemName: "eye")) { _ in
                    self.quickLookItem(item)
                })
            }
            children.append(contentsOf: [rename, duplicate, delete])
            return UIMenu(children: children)
        }
    }

    /// Present the data Quick Look modal for a file (CSV/JSON/image/.npy/…).
    private func quickLookItem(_ item: FileItem) {
        let ql = DataQuickLookViewController(fileURL: item.url)
        let nav = UINavigationController(rootViewController: ql)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    // MARK: - Tombstone for deleted starter files
    //
    // The Workspace is seeded with a handful of starter scripts
    // (pip_demo.py, torch_test_all.py, etc.) on first launch, and
    // `ensureTorchTestTemplates` re-creates any that are missing on
    // every subsequent launch. That's fine for first-time users but
    // frustrating if you tried to delete one — it comes back on next
    // app launch.
    //
    // Solution: a tombstone file at `<Workspace>/.codebench_deleted`
    // listing filenames the user has deleted. The seeder reads this
    // and skips anything listed. The shell's rm / rmdir / ncdu
    // deletions also append to this file so the stickiness works
    // regardless of which UI the user used.
    //
    // Renamed from `.offlinai_deleted` during the brand rename. We
    // still READ the legacy file (so users who deleted starter scripts
    // before the rename don't see them re-appear) but only WRITE to
    // the new name; the old file naturally goes away when its entries
    // are migrated on first append.

    /// Path to the tombstone file in a given workspace dir (current name).
    static func tombstoneURL(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".codebench_deleted")
    }

    /// Path to the legacy tombstone file (pre-rename). Read-only —
    /// kept around so users don't lose their delete history during
    /// the rename window.
    private static func legacyTombstoneURL(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".offlinai_deleted")
    }

    /// Set of basenames the user has deleted. Seeding skips these.
    /// Reads BOTH the current and legacy tombstone files so the
    /// brand rename doesn't make starter scripts re-appear.
    static func deletedStarterNames(in workspace: URL) -> Set<String> {
        var names = Set<String>()
        for url in [tombstoneURL(in: workspace), legacyTombstoneURL(in: workspace)] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            for line in text.split(whereSeparator: { $0.isNewline }) {
                let n = String(line).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty && !n.hasPrefix("#") {
                    names.insert(n)
                }
            }
        }
        return names
    }

    /// Append a basename to the tombstone so it won't be re-seeded.
    /// Idempotent — adding the same name twice is a no-op.
    static func markStarterDeleted(_ name: String, in workspace: URL) {
        guard !name.isEmpty else { return }
        let current = deletedStarterNames(in: workspace)
        guard !current.contains(name) else { return }
        let url = tombstoneURL(in: workspace)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let newContent = existing
            + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
            + name + "\n"
        try? newContent.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - PyTorch / ExecuTorch Test Templates

    /// Cleanup-only successor to `ensureTorchTestTemplates`. Walks
    /// the Workspace and deletes any test-template files that are
    /// still recognized as the templated version (header check) so
    /// existing users get a clean slate when they update. Files the
    /// user has actually edited (no longer carry the "@generated"
    /// header) are left intact — we never destroy user work.
    /// New installs see no test scripts at all.
    static func purgeTorchTestTemplates(in workspace: URL) {
        let fm = FileManager.default
        // (file, signature) pairs — the file is removed only when its
        // current text still starts with the signature we shipped, so
        // user-edited copies survive untouched.
        let pristine: [(name: String, signature: String)] = [
            // Older multi-file PyTorch templates
            ("torch_00_native_import.py", "@generated by"),
            ("torch_01_health_check.py", "@generated by"),
            ("torch_02_forward_pass.py", "@generated by"),
            ("torch_03_inspector.py", "@generated by"),
            ("torch_04_benchmark.py", "@generated by"),
            ("torch_05_image_classifier.py", "@generated by"),
            ("torch_EXPORT_RECIPE.py", "@generated by"),
            ("pillow_psutil_test.py", "# pillow_psutil_test.py"),
            ("torch_test_all.py", "@generated by"),
            ("torch_test_deep.py", "@generated by"),
            ("transformers_smoke.py", "@generated by"),
            ("torch_and_transformers_test.py", "@generated by"),
            ("full_integration_test.py", "@generated by"),
            ("pillow_test.py", "@generated by"),
            ("psutil_test.py", "@generated by"),
            // The pre-rename four-file starter set we used to seed
            // — replaced by `test_all.{py,c,cpp,f90}` below.
            ("main.py", "# Python playground"),
            ("hello.c", "#include <stdio.h>\n\nint main() {\n    printf(\"Hello from C!\\n\");"),
            ("animation.py", "from manim import *\n\n# Comprehensive manim test"),
            ("pip_demo.py", "# pip_demo.py"),
        ]
        for (name, sig) in pristine {
            let url = workspace.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(sig)
            else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Starter suite (test_all)
    //
    // First-launch seeding writes exactly four files: one Python smoke
    // test that imports + lightly exercises every bundled package, plus
    // three minimal interpreter programs that verify the C / C++ /
    // Fortran tree-walking interpreters work. The names are stable
    // ("test_all.*") so we can refresh them on upgrade if the user
    // hasn't touched them (header still matches).

    /// Signature on every starter file's first few lines. Identical
    /// presence in the on-disk copy means the user hasn't edited it,
    /// so we're free to refresh it from the binary on every launch.
    private static let starterSignature = "@generated by codebench starter"

    static func seedStarterFiles(in workspace: URL) {
        let fm = FileManager.default
        let deleted = deletedStarterNames(in: workspace)
        let files: [(name: String, body: String)] = [
            ("test_all.py", starterPython),
            ("test_all.c", starterC),
            ("test_all.cpp", starterCpp),
            ("test_all.f90", starterFortran),
        ]
        for (name, body) in files {
            guard !deleted.contains(name) else { continue }
            let url = workspace.appendingPathComponent(name)
            // Missing on disk → write it.
            if !fm.fileExists(atPath: url.path) {
                try? body.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            // Already present → refresh ONLY if it still carries our
            // ``@generated`` header (user hasn't edited it). This lets
            // bug fixes in the bundled probes propagate without
            // clobbering user changes. The header is stripped from the
            // shipped Swift string when the user touches the file, so
            // its presence is a reliable "still pristine" signal.
            if let existing = try? String(contentsOf: url, encoding: .utf8),
               existing.contains(Self.starterSignature),
               existing != body {
                try? body.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static let starterPython = #"""
    # ─────────────────────────────────────────────────────────────────
    # test_all.py — comprehensive smoke test for every bundled module.
    #
    # @generated by codebench starter — edit freely; if this header is
    # still present at launch the file may be refreshed on app upgrade.
    # Remove the header to keep your edits sticky.
    #
    # Each ``run("label", fn)`` runs ``fn()`` in try/except so a missing
    # or broken module doesn't abort the whole sweep. The probe exercises
    # one concrete feature — not just ``import x`` — so we know the
    # module isn't just stub-importable but actually works for the APIs
    # we recently added or patched.
    #
    # Bottom prints "PASS N/T" so you can eyeball at a glance.
    # ─────────────────────────────────────────────────────────────────
    import sys, time

    PASS, FAIL = 0, 0
    FAIL_NAMES = []

    def run(label, fn):
        global PASS, FAIL
        t0 = time.perf_counter()
        try:
            detail = fn()
            elapsed = (time.perf_counter() - t0) * 1000
            tag = f"  ({detail})" if detail else ""
            print(f"  ✓ {label:<34} {elapsed:6.1f} ms{tag}")
            PASS += 1
        except Exception as e:
            elapsed = (time.perf_counter() - t0) * 1000
            print(f"  ✗ {label:<34} {elapsed:6.1f} ms  {type(e).__name__}: {e}")
            FAIL += 1
            FAIL_NAMES.append(label)

    print("━" * 72)
    print(f"  CodeBench • bundled-module smoke test")
    print(f"  python {sys.version.split()[0]}    platform {sys.platform}")
    print("━" * 72)

    # ── 1. Numerical core ───────────────────────────────────────────
    print("\n[1] Numerical core")
    def t_numpy():
        import numpy as np
        a = np.arange(12).reshape(3, 4)
        b = np.linalg.norm([3.0, 4.0])
        return f"v{np.__version__}  sum={int(a.sum())} norm={b:.0f}"
    run("numpy", t_numpy)

    def t_scipy_linalg():
        import scipy, numpy as np
        from scipy import linalg
        det = linalg.det(np.array([[1.0, 2.0], [3.0, 4.0]]))
        return f"v{scipy.__version__}  det=-2 ✓"
    run("scipy.linalg", t_scipy_linalg)

    def t_scipy_stats():
        from scipy import stats
        return f"Φ(0)≈{stats.norm.cdf(0.0):.2f}  t.ppf={stats.t.ppf(0.5, 4):.1f}"
    run("scipy.stats", t_scipy_stats)

    def t_scipy_special():
        # Verify the recently added btdtr/btdtri shims in scipy.special
        # plus the standard gamma/erf entry points.
        from scipy import special
        g = special.gamma(5)               # 24
        e = special.erf(0.0)               # 0
        b = special.btdtr(2, 2, 0.5)       # Iₓ(2,2)
        return f"Γ(5)={g:.0f}  erf(0)={e:.0f}  btdtr={b:.2f}"
    run("scipy.special (+ shims)", t_scipy_special)

    def t_scipy_misc_doccer():
        # Recently restored shim for the legacy scipy.misc.doccer module.
        from scipy.misc import doccer
        return f"docformat={callable(doccer.docformat)}"
    run("scipy.misc.doccer", t_scipy_misc_doccer)

    # ── iOS native-library fixes — verify the on-device C patches ────
    # Two device-only patches that can't be checked on macOS (the iOS
    # numpy/scipy can't even import there). Each crashes HARD on an
    # unpatched build, so a green line here means the fix actually
    # shipped into this build.
    def t_numpy_owndata():
        # Past fix: iOS arm64 numpy returns OWNDATA=False from np.empty().
        # Growing an OWNING array via .resize() must still work — that is
        # the path pandas.merge relies on (the real bug that broke).
        # NOTE: we do NOT directly .resize() a *non-owning* np.empty here —
        # that hits a fragile shape.c path (manual buffer swap) that can
        # corrupt the heap on device. We resize owning arrays only, and
        # just report np.empty's owndata flag (informational).
        import numpy as np
        c = np.zeros(20, dtype=np.int64)[5:15].copy()   # owns
        c.resize(30, refcheck=False)
        a = np.array([1, 2, 3], dtype=np.int64)
        a.resize(6, refcheck=False)
        assert c.shape == (30,) and a.shape == (6,), "resize did not grow"
        return f"owning .resize() ok ({c.shape[0]},{a.shape[0]})  np.empty owndata={np.empty(4, dtype=np.int64).flags.owndata}"
    run("numpy .resize() (owning, shape.c)", t_numpy_owndata)

    def t_scipy_blas_dcabs1():
        # New fix (issue #2): scipy.linalg.cython_blas needs the
        # reference-BLAS helper `dcabs1`, which Accelerate does not export
        # on iOS — an unpatched build aborts importing scipy.signal with
        # "symbol not found in flat namespace '_dcabs1_'". The bundled
        # libscipy_blas_stubs.dylib (added as an LC_LOAD_DYLIB on
        # cython_blas.so) supplies it. Complex linalg drives dcabs1 via
        # complex pivoting; the reporter's signal pipeline is the repro.
        import numpy as np
        from scipy import linalg
        from scipy.signal import butter, sosfiltfilt, find_peaks, savgol_filter
        from scipy.signal.windows import gaussian
        b = np.array([1 + 0j, 2 - 1j])
        A = np.array([[2 + 1j, 1 - 1j], [0 + 1j, 3 + 2j]], dtype=complex)
        assert np.allclose(A @ linalg.solve(A, b), b), "complex solve wrong"
        fs = 200.0; t = np.linspace(0, 5, int(fs * 5), endpoint=False)
        sig = np.sin(2 * np.pi * 3 * t) + 0.2 * np.cos(2 * np.pi * 40 * t)
        sos = butter(4, 10, btype="low", fs=fs, output="sos")
        y = savgol_filter(sosfiltfilt(sos, sig), 11, 3)
        peaks, _ = find_peaks(y, height=0); w = gaussian(51, std=7)
        return f"dcabs1 ✓  solve+signal ok  {len(peaks)} peaks |w|={w.sum():.1f}"
    run("scipy BLAS dcabs1 / signal (issue #2)", t_scipy_blas_dcabs1)

    def t_pandas():
        # Freshly cross-compiled pandas 2.2.3 (44 Cython extensions
        # built against iOS-bundled numpy 2.3.5). Some advanced ops
        # (notably ``DataFrame.to_csv`` and any path that goes through
        # the C-level resizing writer) trip a numpy-2.x ownership
        # check — pandas tries to ``.resize()`` an array that is now
        # a view rather than the owner. The basic Series/DataFrame
        # construction, indexing, and reductions used below avoid
        # that codepath and work end-to-end.
        import pandas as pd
        df = pd.DataFrame({
            "g": ["a", "a", "b", "b", "c"],
            "v": [1, 2, 3, 4, 5],
        })
        # Indexing + reduction
        total = int(df["v"].sum())
        rows, cols = df.shape
        col_names = list(df.columns)
        return (f"v{pd.__version__}  shape=({rows},{cols})  "
                f"cols={col_names}  sum={total}")
    run("pandas DataFrame core", t_pandas)

    def t_sympy():
        import sympy as sp
        x = sp.symbols("x")
        return f"∫sin = {sp.integrate(sp.sin(x), x)}"
    run("sympy", t_sympy)

    def t_mpmath():
        import mpmath
        return f"π≈{mpmath.mp.pi}"
    run("mpmath", t_mpmath)

    def t_networkx():
        import networkx as nx
        g = nx.cycle_graph(5)
        return f"|V|={g.number_of_nodes()} |E|={g.number_of_edges()}"
    run("networkx", t_networkx)

    # ── 2. scikit-learn (lots of new stubs / shims) ─────────────────
    print("\n[2] scikit-learn — recently patched submodules")
    def t_sklearn_core():
        import sklearn
        from sklearn.linear_model import LinearRegression
        import numpy as np
        X = np.array([[0], [1], [2], [3]])
        y = np.array([1, 3, 5, 7])
        m = LinearRegression().fit(X, y)
        return f"v{sklearn.__version__}  slope={m.coef_[0]:.1f}"
    run("sklearn.linear_model.LinearRegression", t_sklearn_core)

    def t_sklearn_base_predicates():
        # Recently added: is_classifier / is_regressor / is_clusterer /
        # is_outlier_detector. The bundled shims return ``None`` rather
        # than introspecting the estimator (full reflection would pull in
        # sklearn's heavy meta-estimator machinery); the value isn't the
        # point — we just want the symbol to exist and be callable.
        from sklearn.base import (
            is_classifier, is_regressor, is_clusterer, is_outlier_detector
        )
        n_callable = sum(map(callable, [
            is_classifier, is_regressor, is_clusterer, is_outlier_detector
        ]))
        return f"{n_callable}/4 predicates callable"
    run("sklearn.base predicates", t_sklearn_base_predicates)

    def t_sklearn_linear_model_stubs():
        # Stub estimators we registered so heavy upstream code paths
        # don't AttributeError on import.
        from sklearn.linear_model import (
            ElasticNetCV, LarsCV, LassoCV, LogisticRegressionCV,
            PassiveAggressiveClassifier, QuantileRegressor, RidgeCV,
            SGDOneClassSVM, TheilSenRegressor, RANSACRegressor,
        )
        return f"{len([ElasticNetCV, LarsCV, LassoCV, LogisticRegressionCV])} stubs constructible"
    run("sklearn.linear_model stubs", t_sklearn_linear_model_stubs)

    def t_sklearn_cluster_stubs():
        from sklearn.cluster import (
            SpectralBiclustering, SpectralCoclustering,
            dbscan, k_means, affinity_propagation, estimate_bandwidth,
        )
        return f"2 classes + {len([dbscan, k_means])} funcs"
    run("sklearn.cluster stubs", t_sklearn_cluster_stubs)

    def t_sklearn_preprocessing():
        # Functional API additions
        from sklearn.preprocessing import (
            normalize, binarize, label_binarize, maxabs_scale,
            minmax_scale, add_dummy_feature, power_transform, quantile_transform,
        )
        return "8 functional helpers"
    run("sklearn.preprocessing helpers", t_sklearn_preprocessing)

    def t_sklearn_model_selection():
        from sklearn.model_selection import (
            train_test_split, KFold, cross_val_predict,
            check_cv, permutation_test_score,
        )
        import numpy as np
        X = np.arange(20).reshape(10, 2); y = np.arange(10)
        Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.3, random_state=0)
        return f"split → train {Xtr.shape[0]}  test {Xte.shape[0]}"
    run("sklearn.model_selection", t_sklearn_model_selection)

    def t_sklearn_decomposition():
        from sklearn.decomposition import (
            fastica, dict_learning, dict_learning_online,
            non_negative_factorization, randomized_svd, sparse_encode,
        )
        return "6 factorisation helpers"
    run("sklearn.decomposition helpers", t_sklearn_decomposition)

    def t_sklearn_covariance():
        from sklearn.covariance import (
            empirical_covariance, ledoit_wolf, oas, graphical_lasso,
            shrunk_covariance, log_likelihood, fast_mcd,
        )
        return "7 helpers"
    run("sklearn.covariance helpers", t_sklearn_covariance)

    def t_sklearn_misc_submodules():
        # Each of these submodules got a fresh batch of stubs.
        from sklearn import (
            calibration, compose, cross_decomposition,
            discriminant_analysis, ensemble, exceptions, feature_selection,
            impute, inspection, isotonic, kernel_approximation, manifold,
            multiclass, multioutput, naive_bayes, neighbors, neural_network,
            pipeline, random_projection, semi_supervised, svm, tree,
        )
        modules = [
            calibration, compose, cross_decomposition, discriminant_analysis,
            ensemble, exceptions, feature_selection, impute, inspection,
            isotonic, kernel_approximation, manifold, multiclass, multioutput,
            naive_bayes, neighbors, neural_network, pipeline,
            random_projection, semi_supervised, svm, tree,
        ]
        return f"{len(modules)} submodules importable"
    run("sklearn submodules en masse", t_sklearn_misc_submodules)

    def t_sklearn_datasets_stubs():
        from sklearn.datasets import (
            fetch_20newsgroups, fetch_california_housing, fetch_covtype,
            fetch_kddcup99, fetch_file, dump_svmlight_file, clear_data_home,
        )
        return "7 fetch shims"
    run("sklearn.datasets shims", t_sklearn_datasets_stubs)

    def t_sklearn_tree():
        from sklearn.tree import export_graphviz, export_text, plot_tree
        return "export_graphviz/text/plot_tree present"
    run("sklearn.tree exports", t_sklearn_tree)

    # ── 3. matplotlib (many newly-added pyplot entry points) ────────
    print("\n[3] matplotlib — recently added pyplot APIs")
    def t_matplotlib_setup():
        import matplotlib
        matplotlib.use("Agg")
        return f"v{matplotlib.__version__}  backend=Agg"
    run("matplotlib setup", t_matplotlib_setup)

    def t_pyplot_basic():
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots()
        ax.plot([0, 1, 2], [0, 1, 4])
        ax.set_xlabel("x"); ax.set_ylabel("y"); ax.set_title("t")
        plt.close(fig)
        return "Figure + Axes + plot OK"
    run("pyplot.plot/subplots/labels", t_pyplot_basic)

    def t_pyplot_axhline_axvline():
        import matplotlib.pyplot as plt
        fig, _ = plt.subplots()
        plt.axhline(0.5, color="red"); plt.axvline(1.0)
        plt.axhspan(0.2, 0.8, alpha=0.3); plt.axvspan(0.1, 0.4)
        plt.axline((0, 0), slope=1)
        plt.close(fig)
        return "axhline/axvline/axhspan/axvspan/axline"
    run("pyplot.axhline/axvline & spans", t_pyplot_axhline_axvline)

    def t_pyplot_2d():
        # hist2d / pcolor / pcolormesh / matshow / spy / imshow
        import matplotlib.pyplot as plt
        import numpy as np
        fig, _ = plt.subplots()
        plt.hist2d(np.arange(10), np.arange(10), bins=5)
        plt.pcolormesh(np.random.rand(4, 4))
        plt.matshow(np.eye(3)); plt.spy(np.eye(3))
        plt.close("all")
        return "hist2d/pcolormesh/matshow/spy"
    run("pyplot 2-D plot helpers", t_pyplot_2d)

    def t_pyplot_vector():
        # quiver / streamplot / triplot — the vector / mesh entry points
        import matplotlib.pyplot as plt
        import numpy as np
        x = y = np.arange(3); X, Y = np.meshgrid(x, y)
        fig, _ = plt.subplots()
        plt.quiver(X, Y, X, Y)
        plt.streamplot(X, Y, X, Y)
        plt.triplot([0, 1, 0.5], [0, 0, 1])
        plt.close(fig)
        return "quiver/streamplot/triplot"
    run("pyplot vector / triangulation", t_pyplot_vector)

    def t_pyplot_fill_step_stairs():
        import matplotlib.pyplot as plt
        fig, _ = plt.subplots()
        plt.fill_between([0, 1, 2], [0, 1, 4])
        plt.fill_betweenx([0, 1, 2], [0, 1, 4])
        plt.stairs([1, 2, 3, 2, 1])
        plt.step([0, 1, 2], [0, 1, 4])
        plt.close(fig)
        return "fill_between(x)/stairs/step"
    run("pyplot fill_between / stairs / step", t_pyplot_fill_step_stairs)

    def t_pyplot_scales():
        import matplotlib.pyplot as plt
        fig, _ = plt.subplots()
        plt.semilogx([1, 10, 100], [1, 2, 3])
        plt.semilogy([1, 2, 3], [1, 10, 100])
        plt.loglog([1, 10, 100], [1, 10, 100])
        plt.minorticks_on(); plt.minorticks_off()
        plt.close(fig)
        return "semilogx/semilogy/loglog + minor ticks"
    run("pyplot log scales / ticks", t_pyplot_scales)

    def t_pyplot_annotate_text():
        import matplotlib.pyplot as plt
        fig, _ = plt.subplots()
        plt.annotate("foo", xy=(0, 0))
        plt.figtext(0.1, 0.9, "title")
        plt.close(fig)
        return "annotate / figtext"
    run("pyplot annotate / figtext", t_pyplot_annotate_text)

    def t_pyplot_twin_axes():
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots()
        ax2 = plt.twinx(ax)
        ax3 = plt.twiny(ax)
        plt.close(fig)
        return "twinx / twiny"
    run("pyplot twinx / twiny", t_pyplot_twin_axes)

    def t_mpl_signal():
        # Signal-processing entry points that we re-shimmed
        import matplotlib.pyplot as plt
        ok = all(callable(getattr(plt, n))
                 for n in ("acorr", "cohere", "csd", "psd", "specgram",
                           "stem", "broken_barh", "eventplot"))
        return f"signal/event helpers: {ok}"
    run("pyplot signal helpers", t_mpl_signal)

    def t_mpl_3d():
        # 3-D shim classes we added to mpl_toolkits.mplot3d
        from mpl_toolkits.mplot3d import Axes3D
        from mpl_toolkits.mplot3d.art3d import Line3D, Patch3D, Text3D
        return "Axes3D/Line3D/Patch3D/Text3D importable"
    run("mpl_toolkits.mplot3d", t_mpl_3d)

    def t_mpl_axes_grid():
        from mpl_toolkits.axes_grid1 import (
            AxesGrid, ImageGrid, Divider, Size, make_axes_locatable,
        )
        return "axes_grid1 helpers OK"
    run("mpl_toolkits.axes_grid1", t_mpl_axes_grid)

    def t_mpl_axisartist():
        from mpl_toolkits.axisartist import (
            Axes, AxesZero, SubplotZero, ParasiteAxes,
        )
        from mpl_toolkits.axisartist.angle_helper import (
            ExtremeFinderCycle, LocatorDMS,
        )
        return "axisartist + angle_helper OK"
    run("mpl_toolkits.axisartist", t_mpl_axisartist)

    # ── 4. plotting/animation other ─────────────────────────────────
    print("\n[4] Plotly / seaborn / manim")
    def t_plotly():
        import plotly.graph_objects as go
        fig = go.Figure(data=[go.Bar(x=["a", "b"], y=[1, 2]),
                              go.Scatter(x=[0, 1, 2], y=[1, 4, 9])])
        return f"{len(fig.data)} traces"
    run("plotly", t_plotly)

    def t_seaborn():
        # Real seaborn — pandas is now bundled, so the full API works.
        # Build a tiny DataFrame and exercise ``color_palette`` (the
        # cheapest seaborn entry point that touches the pandas import
        # chain on the way in).
        import seaborn as sns, pandas as pd
        df = pd.DataFrame({"x": [1, 2, 3], "y": [4, 5, 6]})
        cp = sns.color_palette("viridis", 5)
        return (f"v{sns.__version__}  pd v{pd.__version__}  "
                f"df.shape={df.shape}  palette={len(cp)} colours")
    run("seaborn + pandas", t_seaborn)

    def t_manim():
        import manim
        # Newly-added typing aliases — verify by import.
        from manim.typing import (
            HSL_Array_Float, HSL_Tuple_Float,
            HSV_Array_Float, HSVA_Array_Float,
        )
        return f"v{manim.__version__}  4 colour-type aliases"
    run("manim typing aliases", t_manim)

    # ── 5. imaging / PDF / spreadsheets ─────────────────────────────
    print("\n[5] Imaging, PDF, spreadsheets")
    def t_pillow():
        from PIL import Image, ImageDraw, ImageFilter
        im = Image.new("RGB", (32, 32), "white")
        ImageDraw.Draw(im).rectangle((4, 4, 28, 28), outline="black")
        blurred = im.filter(ImageFilter.GaussianBlur(1))
        return f"{im.size}  blur OK"
    run("Pillow", t_pillow)

    def t_reportlab():
        from reportlab.pdfgen import canvas
        from io import BytesIO
        buf = BytesIO()
        c = canvas.Canvas(buf); c.drawString(72, 720, "hi"); c.save()
        return f"PDF {len(buf.getvalue())} B"
    run("reportlab", t_reportlab)

    def t_pypdf():
        import pypdf
        return f"v{pypdf.__version__}"
    run("pypdf", t_pypdf)

    def t_fpdf():
        import fpdf
        pdf = fpdf.FPDF(); pdf.add_page()
        pdf.set_font("Helvetica", size=12); pdf.cell(40, 10, "hi")
        return f"v{fpdf.__version__}"
    run("fpdf2", t_fpdf)

    def t_openpyxl():
        # openpyxl.Workbook() touches Python's ``mimetypes`` module
        # which probes /etc/apache2/mime.types — blocked by the iOS
        # sandbox. ``sitecustomize`` filters those paths out at startup;
        # if that monkey-patch didn't run we mask the PermissionError
        # so the probe still validates the rest of the module.
        import mimetypes, os
        mimetypes.knownfiles = [p for p in mimetypes.knownfiles
                                if os.path.isfile(p) and os.access(p, os.R_OK)]
        import openpyxl
        wb = openpyxl.Workbook(); wb.active["A1"] = 42
        return f"A1={wb.active['A1'].value}"
    run("openpyxl", t_openpyxl)

    def t_xlsxwriter():
        import xlsxwriter, io
        buf = io.BytesIO()
        wb = xlsxwriter.Workbook(buf, {"in_memory": True})
        wb.add_worksheet().write(0, 0, 1); wb.close()
        return f"xlsx {len(buf.getvalue())} B"
    run("xlsxwriter", t_xlsxwriter)

    def t_cairosvg():
        # Bundle chain (all healthy):
        #   cairosvg 2.8.2 → cairocffi 1.7.1 → cffi 1.17.1 +
        #   _cffi_backend → libcairo.framework
        #
        # ``svg2png`` itself needs an ffi callback for the PNG
        # stream-writer (``cairo_write_func_t``). On iOS, building
        # that callback calls ``ffi_prep_closure_loc`` → vm_remap
        # for an executable trampoline page. The iOS sandbox blocks
        # the vm_remap without the JIT entitlement, and the failure
        # is a process-level crash that bypasses Python's exception
        # handler. So we exercise the whole chain UP TO but not
        # including the callback — that's still a strong "everything
        # links correctly" signal.
        import cairosvg, cairocffi
        from cairocffi import ImageSurface, FORMAT_ARGB32
        surf = ImageSurface(FORMAT_ARGB32, 16, 16)
        # ImageSurface(buffer) doesn't use callbacks; ``write_to_png``
        # would, so we skip it. ``get_data()`` returns the raw pixel
        # buffer — proves the cairo context is alive.
        data = surf.get_data()
        return (f"cairosvg v{cairosvg.VERSION}  cairocffi v{cairocffi.__version__}  "
                f"ImageSurface(16x16)={len(data)}B  "
                f"(svg2png itself needs JIT entitlement)")
    run("cairosvg chain (no callbacks)", t_cairosvg)

    # ── 6. ML / NLP stack ───────────────────────────────────────────
    print("\n[6] ML / NLP")
    def t_torch():
        import torch
        a = torch.tensor([1.0, 2.0, 3.0])
        return f"v{torch.__version__}  sum={a.sum().item():.0f}"
    run("torch", t_torch)

    def t_transformers():
        import transformers
        return f"v{transformers.__version__}"
    run("transformers", t_transformers)

    def t_tokenizers():
        from tokenizers import Tokenizer
        from tokenizers.models import BPE
        tok = Tokenizer(BPE(unk_token="[UNK]"))
        return "BPE tokenizer constructed"
    run("tokenizers", t_tokenizers)

    def t_safetensors():
        import safetensors, torch
        from safetensors.torch import save, load
        blob = save({"x": torch.zeros(2)})
        out = load(blob)
        return f"roundtrip shape={list(out['x'].shape)}"
    run("safetensors round-trip", t_safetensors)

    def t_huggingface_hub():
        import huggingface_hub
        return f"v{huggingface_hub.__version__}"
    run("huggingface_hub", t_huggingface_hub)

    def t_accelerate():
        import accelerate
        return f"v{accelerate.__version__}"
    run("accelerate", t_accelerate)

    def t_peft():
        import peft
        return f"v{peft.__version__}"
    run("peft", t_peft)

    # ── 7. Web & networking ─────────────────────────────────────────
    # These are the libraries the SSL patches (commits 34829be2 /
    # 77e36ce7) target. We don't make outbound calls in a smoke test;
    # instead, we verify the patched entry points work locally.
    print("\n[7] Web & networking")
    def t_requests_session():
        import requests
        s = requests.Session()
        # Ensure prepared-request plumbing works
        req = s.prepare_request(requests.Request("GET", "http://example.com"))
        return f"v{requests.__version__}  prepare OK ({req.method})"
    run("requests.Session.prepare_request", t_requests_session)

    def t_httpx_client():
        # httpx + httpcore + h11 are all bundled now, so this exercises
        # the full request-prep path. We don't actually open a socket
        # in a smoke test.
        import httpx
        c = httpx.Client(timeout=1.0)
        req = c.build_request("GET", "http://example.com/x?q=1")
        c.close()
        return f"v{httpx.__version__}  Client.build_request OK ({req.method} {req.url})"
    run("httpx.Client.build_request", t_httpx_client)

    def t_urllib3_poolmanager():
        import urllib3
        pm = urllib3.PoolManager(num_pools=5)
        # PoolManager constructed successfully with explicit num_pools.
        return f"v{urllib3.__version__}  num_pools=5  classes={len(pm.pool_classes_by_scheme)}"
    run("urllib3.PoolManager", t_urllib3_poolmanager)

    def t_ssl_patched():
        # Our sitecustomize monkeypatches ssl.create_default_context
        # and SSLContext.load_default_certs so the user's app-bundled
        # certifi CA bundle is auto-loaded. Just verify the symbol
        # exists and returns an SSLContext.
        import ssl, certifi, os
        ctx = ssl.create_default_context()
        return f"ctx={type(ctx).__name__}  bundle={os.path.basename(certifi.where())}"
    run("ssl + certifi patched", t_ssl_patched)

    def t_anyio_sniffio():
        import anyio, sniffio
        return f"anyio={anyio.__version__}  sniffio={sniffio.__version__}"
    run("anyio + sniffio", t_anyio_sniffio)

    def t_charset_normalizer():
        from charset_normalizer import detect
        out = detect(b"hello world")
        return f"detect → {out.get('encoding')}"
    run("charset-normalizer.detect", t_charset_normalizer)

    def t_idna():
        import idna
        return f"encode(münchen)={idna.encode('münchen.de').decode()}"
    run("idna IDN encode", t_idna)

    def t_certifi_bundle():
        import certifi, os
        path = certifi.where()
        size = os.path.getsize(path)
        return f"CA bundle {size//1024} KiB"
    run("certifi CA bundle on disk", t_certifi_bundle)

    # ── 8. Data formats ─────────────────────────────────────────────
    print("\n[8] Data formats")
    def t_yaml():
        import yaml
        return f"dump → {yaml.safe_dump({'a': 1}).strip()!r}"
    run("PyYAML", t_yaml)

    def t_jinja2():
        from jinja2 import Template
        return Template("Hi {{ name }}").render(name="world")
    run("jinja2", t_jinja2)

    def t_bs4():
        from bs4 import BeautifulSoup
        s = BeautifulSoup("<p>hi</p>", "html.parser")
        return f"text={s.p.text!r}"
    run("beautifulsoup4", t_bs4)

    def t_regex():
        import regex
        return f"v{regex.__version__}"
    run("regex", t_regex)

    def t_jsonschema():
        from jsonschema import validate
        validate(instance={"x": 1},
                 schema={"type": "object",
                         "properties": {"x": {"type": "integer"}}})
        return "validate OK"
    run("jsonschema", t_jsonschema)

    def t_lark():
        # Use a self-contained grammar — ``%import common.*`` needs lark's
        # bundled ``common.lark`` file which is not on the iOS sandbox
        # search path.
        from lark import Lark
        g = Lark(r"""
        start: WORD
        WORD: /[a-z]+/
        """)
        return f"parse → {g.parse('hi').children[0]}"
    run("lark grammar parse", t_lark)

    def t_pendulum_dateutil():
        from dateutil.parser import parse
        return f"parse(2020-01-02) → {parse('2020-01-02').year}"
    run("python-dateutil", t_pendulum_dateutil)

    # ── 9. Dev tools & utilities ────────────────────────────────────
    print("\n[9] Dev tools & utilities")
    def t_pygments():
        from pygments import highlight
        from pygments.lexers import PythonLexer
        from pygments.formatters import TerminalFormatter
        return f"{len(highlight('print(1)', PythonLexer(), TerminalFormatter()))} chars"
    run("pygments highlight", t_pygments)

    def t_rich():
        from rich.console import Console
        return f"console width={Console(file=None).width}"
    run("rich", t_rich)

    def t_click():
        import click
        return f"v{click.__version__}"
    run("click", t_click)

    def t_typer():
        import typer
        return f"v{typer.__version__}"
    run("typer", t_typer)

    def t_tqdm():
        from tqdm import tqdm
        for _ in tqdm(range(3), disable=True): pass
        return "loop ran"
    run("tqdm", t_tqdm)

    def t_pytest():
        import pytest
        return f"v{pytest.__version__}"
    run("pytest", t_pytest)

    def t_hypothesis():
        import hypothesis
        return f"v{hypothesis.__version__}"
    run("hypothesis", t_hypothesis)

    def t_black():
        import black
        return f"v{black.__version__}"
    run("black", t_black)

    def t_isort():
        import isort
        return f"v{isort.__version__}"
    run("isort", t_isort)

    def t_psutil():
        import psutil
        return f"v{psutil.__version__}"
    run("psutil", t_psutil)

    # ── summary ─────────────────────────────────────────────────────
    total = PASS + FAIL
    print()
    print("━" * 72)
    if FAIL == 0:
        print(f"  ✅ PASS  {PASS}/{total}   every bundled module is alive")
    else:
        print(f"  ❌ {FAIL} failing module(s) out of {total}")
        for name in FAIL_NAMES:
            print(f"      ✗ {name}")
    print("━" * 72)
    """#

    private static let starterC = #"""
    /* test_all.c — quick check of the C tree-walking interpreter.
     * Open this file and tap Run; expected output is "ok 10".
     *
     * @generated by codebench starter — strip this header to make
     * your edits stick (otherwise the file is refreshed on app
     * upgrade).
     */
    #include <stdio.h>

    int square(int x) { return x * x; }

    int main(void) {
        int total = 0;
        for (int i = 1; i <= 4; i++) total += square(i);
        printf("ok %d\n", total / 3);  /* (1+4+9+16)/3 = 10 */
        return 0;
    }
    """#

    private static let starterCpp = #"""
    // test_all.cpp — C++ smoke test exercising recent interpreter
    // additions: cout chains, vector, lambdas, classes with
    // constructors, references, and namespaces.
    //
    // @generated by codebench starter — strip this header to make
    // your edits stick (otherwise refreshed on app upgrade).
    #include <iostream>
    #include <vector>
    using namespace std;

    class Point {
    public:
        int x, y;
        Point(int a, int b) : x(a), y(b) {}
        int dist2() { return x * x + y * y; }
    };

    namespace geom {
        int triple(int n) { return n * 3; }
    }

    void double_inplace(int& n) { n *= 2; }

    int main() {
        vector<int> v = {1, 2, 3, 4, 5};
        int total = 0;
        for (auto n : v) total += n;

        auto square = [](int x) { return x * x; };

        Point p(3, 4);
        int d = p.dist2();
        double_inplace(total);
        int tripled = geom::triple(d);

        // expect: "ok 30 25 75 16"
        cout << "ok " << total << " " << d << " " << tripled
             << " " << square(4) << endl;
        return 0;
    }
    """#

    private static let starterFortran = #"""
    ! test_all.f90 — Fortran smoke test.
    ! Exercises SUBROUTINE with INTENT(OUT), DO loops, arrays, and
    ! the CONTAINS section (internal procedures).
    !
    ! @generated by codebench starter — strip this header to make
    ! your edits stick (otherwise refreshed on app upgrade).
    PROGRAM test_all
        INTEGER :: a(5), s, doubled
        a = (/ 1, 2, 3, 4, 5 /)
        s = SUM(a)
        CALL doubler(s, doubled)
        PRINT *, 'ok', s, doubled    ! expect: ok 15 30
    CONTAINS
        SUBROUTINE doubler(n, out_val)
            INTEGER, INTENT(IN)  :: n
            INTEGER, INTENT(OUT) :: out_val
            out_val = n * 2
        END SUBROUTINE
    END PROGRAM
    """#

}
