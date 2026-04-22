import UIKit

protocol ModelsManagerDelegate: AnyObject {
    func modelsManagerDidUpdateModels(_ controller: ModelsManagerViewController)
    func modelsManager(_ controller: ModelsManagerViewController, requestDownloadFor slot: ModelSlot)
    func modelsManager(_ controller: ModelsManagerViewController, requestLoadFor slot: ModelSlot)
}

extension ModelsManagerDelegate {
    func modelsManager(_ controller: ModelsManagerViewController, requestDownloadFor slot: ModelSlot) {}
    func modelsManager(_ controller: ModelsManagerViewController, requestLoadFor slot: ModelSlot) {}
}

final class ModelsManagerViewController: UIViewController {
    struct Entry {
        let url: URL
        let displayName: String
        let sizeBytes: Int64
        let slot: ModelSlot?
    }

    struct CatalogEntry {
        let slot: ModelSlot
        let displayName: String
        let isDownloaded: Bool
        let fileURL: URL?
        let sizeBytes: Int64
    }

    weak var delegate: ModelsManagerDelegate?
    var isEmbedded: Bool = false

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchBar = UISearchBar()
    private var dataSource: UITableViewDiffableDataSource<Int, String>!
    private var entries: [Entry] = []
    private var catalogEntries: [CatalogEntry] = []
    private var isApplyingSnapshot = false
    private let sectionCatalog = 0
    private let sectionDownloaded = 1
    private let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloaded Models"
        view.backgroundColor = .clear

        configureTableView()
        configureDataSource()
        layoutUI()

        if !isEmbedded {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Close", style: .done, target: self, action: #selector(closeTapped))
        }
        reloadEntries()
    }

    func reloadEntries() {
        DispatchQueue.main.async {
            let modelsDirectory = Self.modelsDirectoryURL()
            let urls = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            let ggufFiles = urls.filter { $0.pathExtension.lowercased() == "gguf" }

            self.entries = ggufFiles.map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                let slot = ModelSlot.allCases.first { url.lastPathComponent.hasPrefix($0.filePrefix) }
                let displayName = slot?.title ?? url.lastPathComponent
                return Entry(url: url, displayName: displayName, sizeBytes: size, slot: slot)
            }.sorted { $0.displayName < $1.displayName }

            self.catalogEntries = ModelSlot.allCases.map { slot in
                let file = ggufFiles.first { $0.lastPathComponent.hasPrefix(slot.filePrefix) }
                let size = (try? file?.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                return CatalogEntry(
                    slot: slot,
                    displayName: slot.title,
                    isDownloaded: file != nil,
                    fileURL: file,
                    sizeBytes: size
                )
            }.sorted { $0.displayName < $1.displayName }

            self.applySnapshot(animated: self.view.window != nil)
        }
    }

    private func configureTableView() {
        tableView.delegate = self
        tableView.rowHeight = 72
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ModelCell")
        tableView.keyboardDismissMode = .onDrag
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, String>(tableView: tableView) { [weak self] (tableView: UITableView, indexPath: IndexPath, itemID: String) in
            guard let self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(withIdentifier: "ModelCell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
            content.textProperties.font = titleFont.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? titleFont
            let subtitleFont = UIFont.systemFont(ofSize: 12, weight: .regular)
            content.secondaryTextProperties.font = subtitleFont.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? subtitleFont
            content.secondaryTextProperties.color = UIColor.secondaryLabel

            if let slotRaw = self.slotRawValue(from: itemID) {
                guard let entry = self.catalogEntries.first(where: { $0.slot.rawValue == slotRaw }) else {
                    content.text = "Unknown model"
                    cell.contentConfiguration = content
                    cell.accessoryView = nil
                    return cell
                }
                content.text = entry.displayName
                if entry.isDownloaded, let url = entry.fileURL {
                    let sizeText = self.sizeFormatter.string(fromByteCount: entry.sizeBytes)
                    content.secondaryText = "\(sizeText) • \(url.lastPathComponent)"
                    cell.accessoryView = self.makeStatePill(text: "Installed", color: .systemGreen)
                } else {
                    content.secondaryText = "Not installed"
                    cell.accessoryView = self.makeStatePill(text: "Not installed", color: .systemGray)
                }
                cell.accessoryType = .disclosureIndicator
            } else if let path = self.downloadedPath(from: itemID) {
                guard let entry = self.entries.first(where: { $0.url.path == path }) else {
                    content.text = "Unknown file"
                    cell.contentConfiguration = content
                    cell.accessoryView = nil
                    return cell
                }
                content.text = entry.displayName
                let sizeText = self.sizeFormatter.string(fromByteCount: entry.sizeBytes)
                content.secondaryText = "\(sizeText) • \(entry.url.lastPathComponent)"
                cell.accessoryView = self.makeStatePill(text: "Installed", color: .systemGreen)
                cell.accessoryType = .none
            } else {
                content.text = "Unknown"
                content.secondaryText = nil
            }

            cell.contentConfiguration = content
            return cell
        }
    }

    private func layoutUI() {
        searchBar.placeholder = "Search models"
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchBar)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeStatePill(text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = "  \(text)  "
        let baseFont = UIFont.systemFont(ofSize: 10, weight: .bold)
        label.font = baseFont.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? baseFont
        label.textColor = UIColor.white
        label.backgroundColor = color.withAlphaComponent(0.75)
        label.layer.cornerRadius = 8
        label.layer.cornerCurve = .continuous
        label.layer.masksToBounds = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func filteredCatalogEntries() -> [CatalogEntry] {
        let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if query.isEmpty {
            return catalogEntries
        }
        return catalogEntries.filter { $0.displayName.lowercased().contains(query) }
    }

    private func filteredDownloadedEntries() -> [Entry] {
        let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if query.isEmpty {
            return entries
        }
        return entries.filter {
            $0.displayName.lowercased().contains(query) || $0.url.lastPathComponent.lowercased().contains(query)
        }
    }

    private func applySnapshot(animated: Bool) {
        guard !isApplyingSnapshot else { return }
        isApplyingSnapshot = true
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([sectionCatalog, sectionDownloaded])

        let filteredCatalog = filteredCatalogEntries()
        let filteredDownloaded = filteredDownloadedEntries()

        snapshot.appendItems(filteredCatalog.map { catalogItemID(for: $0.slot) }, toSection: sectionCatalog)
        snapshot.appendItems(filteredDownloaded.map { downloadedItemID(for: $0.url.path) }, toSection: sectionDownloaded)

        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.isApplyingSnapshot = false
        }
    }

    private func handleCatalogSelection(_ entry: CatalogEntry) {
        if entry.isDownloaded {
            delegate?.modelsManager(self, requestLoadFor: entry.slot)
        } else {
            delegate?.modelsManager(self, requestDownloadFor: entry.slot)
        }
    }

    private func handleDownloadedSelection(_ entry: Entry) {
        if let slot = entry.slot {
            delegate?.modelsManager(self, requestLoadFor: slot)
        } else {
            UIPasteboard.general.string = entry.url.path
        }
    }

    private func deleteEntry(_ entry: Entry) {
        do {
            try FileManager.default.removeItem(at: entry.url)
            reloadEntries()
            delegate?.modelsManagerDidUpdateModels(self)
        } catch {
            NSLog("ModelsManager delete failed for %@: %@", entry.url.path, error.localizedDescription)
        }
    }

    private static func modelsDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func catalogItemID(for slot: ModelSlot) -> String {
        "catalog:\(slot.rawValue)"
    }

    private func downloadedItemID(for path: String) -> String {
        "downloaded:\(path)"
    }

    private func slotRawValue(from itemID: String) -> Int? {
        guard itemID.hasPrefix("catalog:") else { return nil }
        return Int(itemID.replacingOccurrences(of: "catalog:", with: ""))
    }

    private func downloadedPath(from itemID: String) -> String? {
        guard itemID.hasPrefix("downloaded:") else { return nil }
        return itemID.replacingOccurrences(of: "downloaded:", with: "")
    }
}

extension ModelsManagerViewController: UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = headerTitle(for: section) else { return nil }
        let label = UILabel()
        label.text = title
        let headerFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        label.font = headerFont.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? headerFont
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6)
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        headerTitle(for: section) == nil ? 0 : 28
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let itemID = dataSource.itemIdentifier(for: indexPath) else {
            NSLog("ModelsManager stale selection at section %ld row %ld", indexPath.section, indexPath.row)
            return
        }
        if let slotRaw = slotRawValue(from: itemID) {
            guard let entry = catalogEntries.first(where: { $0.slot.rawValue == slotRaw }) else {
                NSLog("ModelsManager missing catalog entry for slot %ld", slotRaw)
                return
            }
            handleCatalogSelection(entry)
        } else if let path = downloadedPath(from: itemID) {
            guard let entry = entries.first(where: { $0.url.path == path }) else {
                NSLog("ModelsManager missing downloaded entry for path %@", path)
                return
            }
            handleDownloadedSelection(entry)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let itemID = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            if let slotRaw = self.slotRawValue(from: itemID) {
                guard let entry = self.catalogEntries.first(where: { $0.slot.rawValue == slotRaw }) else { return nil }
                let primary = UIAction(title: entry.isDownloaded ? "Load" : "Download", image: UIImage(systemName: entry.isDownloaded ? "play.fill" : "arrow.down.circle")) { _ in
                    self.handleCatalogSelection(entry)
                }
                if entry.isDownloaded, let url = entry.fileURL {
                    let copy = UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = url.path
                    }
                    let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                        let removable = Entry(url: url, displayName: entry.displayName, sizeBytes: entry.sizeBytes, slot: entry.slot)
                        self.deleteEntry(removable)
                    }
                    return UIMenu(title: entry.displayName, children: [primary, copy, delete])
                }
                return UIMenu(title: entry.displayName, children: [primary])
            } else if let path = self.downloadedPath(from: itemID) {
                guard let entry = self.entries.first(where: { $0.url.path == path }) else { return nil }
                var actions: [UIAction] = []
                if let slot = entry.slot {
                    actions.append(UIAction(title: "Load", image: UIImage(systemName: "play.fill")) { _ in
                        self.delegate?.modelsManager(self, requestLoadFor: slot)
                    })
                }
                actions.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = entry.url.path
                })
                actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.deleteEntry(entry)
                })
                return UIMenu(title: entry.displayName, children: actions)
            } else {
                return nil
            }
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let itemID = dataSource.itemIdentifier(for: indexPath) else { return nil }
        guard let path = downloadedPath(from: itemID), let entry = entries.first(where: { $0.url.path == path }) else {
            return nil
        }
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            self.deleteEntry(entry)
            completion(true)
        }
        let copyAction = UIContextualAction(style: .normal, title: "Copy") { _, _, completion in
            UIPasteboard.general.string = entry.url.path
            completion(true)
        }
        copyAction.backgroundColor = UIColor.systemTeal
        return UISwipeActionsConfiguration(actions: [deleteAction, copyAction])
    }

    private func headerTitle(for section: Int) -> String? {
        switch section {
        case 0:
            let modelCount = filteredCatalogEntries().count
            return "Available Models (\(modelCount))"
        case 1:
            let filtered = filteredDownloadedEntries()
            let total = filtered.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let sizeText = sizeFormatter.string(fromByteCount: total)
            return "Downloaded (\(filtered.count)) • \(sizeText)"
        default:
            return nil
        }
    }
}

extension ModelsManagerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applySnapshot(animated: true)
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        searchBar.resignFirstResponder()
        searchBar.setShowsCancelButton(false, animated: true)
        applySnapshot(animated: true)
    }
}
