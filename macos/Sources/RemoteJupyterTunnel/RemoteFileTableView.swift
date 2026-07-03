import AppKit
import SwiftUI

enum RemoteFileContextAction {
    case open
    case download
    case uploadHere
    case copyToDirectory
    case rename
    case delete
    case refresh
    case newFolder
    case editPermissions
}

enum RemoteFileSortColumn: String {
    case name
    case modified
    case size
    case kind
}

struct RemoteFileTableView: NSViewRepresentable {
    let entries: [RemoteFileEntry]
    @Binding var selectedEntry: RemoteFileEntry?
    @Binding var sortColumn: RemoteFileSortColumn
    @Binding var sortAscending: Bool
    let currentPath: String
    let loadingPath: String?
    let canNavigate: Bool
    let canMutate: Bool
    let onOpen: (RemoteFileEntry) -> Void
    let onContextAction: (RemoteFileContextAction, RemoteFileEntry?) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let tableView = RemoteFileNSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 54
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClick(_:))
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator, weak tableView] event in
            guard let tableView else { return nil }
            return coordinator?.contextMenu(for: event, in: tableView)
        }

        addColumn(to: tableView, id: .name, title: "名称", width: 300, minWidth: 240)
        addColumn(to: tableView, id: .modified, title: "修改时间", width: 150, minWidth: 145)
        addColumn(to: tableView, id: .size, title: "大小", width: 92, minWidth: 84)
        addColumn(to: tableView, id: .kind, title: "类型", width: 90, minWidth: 84)

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(entries: entries)
        context.coordinator.applySortIndicator(column: sortColumn, ascending: sortAscending)
        context.coordinator.applyTableWidth()
        context.coordinator.applySelection(selectedEntry)

        let scrollKey = "\(currentPath)::\(loadingPath ?? "")"
        if context.coordinator.lastScrollKey != scrollKey {
            context.coordinator.lastScrollKey = scrollKey
            context.coordinator.scrollToTop()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func addColumn(
        to tableView: NSTableView,
        id: RemoteFileColumn,
        title: String,
        width: CGFloat,
        minWidth: CGFloat
    ) {
        let column = NSTableColumn(identifier: id.identifier)
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.resizingMask = .userResizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
        tableView.addTableColumn(column)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: RemoteFileTableView
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        var entries: [RemoteFileEntry] = []
        var lastScrollKey = ""
        private var suppressSelectionCallback = false

        init(parent: RemoteFileTableView) {
            self.parent = parent
        }

        func apply(entries newEntries: [RemoteFileEntry]) {
            guard entries != newEntries else { return }
            entries = newEntries
            tableView?.reloadData()
        }

        func applySortIndicator(column: RemoteFileSortColumn, ascending: Bool) {
            guard let tableView else { return }
            let descriptor = NSSortDescriptor(key: column.rawValue, ascending: ascending)
            if tableView.sortDescriptors != [descriptor] {
                tableView.sortDescriptors = [descriptor]
            }
        }

        func applyTableWidth() {
            guard let tableView, let scrollView else { return }
            let minimumWidth = tableView.tableColumns.reduce(CGFloat(0)) { $0 + $1.minWidth }
            let targetWidth = max(scrollView.contentSize.width, minimumWidth)
            guard abs(tableView.frame.width - targetWidth) > 0.5 else { return }
            tableView.setFrameSize(NSSize(width: targetWidth, height: tableView.frame.height))
        }

        func applySelection(_ selectedEntry: RemoteFileEntry?) {
            guard let tableView else { return }
            suppressSelectionCallback = true
            defer { suppressSelectionCallback = false }

            guard let selectedEntry else {
                tableView.deselectAll(nil)
                return
            }

            if let row = entries.firstIndex(where: { $0.path == selectedEntry.path }) {
                let indexes = IndexSet(integer: row)
                if tableView.selectedRow != row {
                    tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                }
            } else {
                tableView.deselectAll(nil)
            }
        }

        func scrollToTop() {
            let entriesAreEmpty = entries.isEmpty
            let tableView = tableView
            let scrollView = scrollView

            DispatchQueue.main.async {
                guard let tableView else { return }
                if entriesAreEmpty {
                    scrollView?.contentView.scroll(to: .zero)
                    if let contentView = scrollView?.contentView {
                        scrollView?.reflectScrolledClipView(contentView)
                    }
                } else {
                    tableView.scrollRowToVisible(0)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            54
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < entries.count, let columnID = tableColumn?.identifier else { return nil }
            let entry = entries[row]

            switch columnID {
            case RemoteFileColumn.name.identifier:
                let cell = tableView.makeView(withIdentifier: RemoteNameCellView.reuseIdentifier, owner: self) as? RemoteNameCellView
                    ?? RemoteNameCellView()
                cell.configure(entry)
                return cell

            case RemoteFileColumn.modified.identifier:
                return textCell(tableView: tableView, text: entry.modified, identifier: columnID)

            case RemoteFileColumn.size.identifier:
                return textCell(tableView: tableView, text: entry.displaySize, identifier: columnID)

            case RemoteFileColumn.kind.identifier:
                return kindCell(tableView: tableView, entry: entry, identifier: columnID)

            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback, let tableView else { return }
            let row = tableView.selectedRow
            guard row >= 0, row < entries.count else {
                parent.selectedEntry = nil
                return
            }
            parent.selectedEntry = entries[row]
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = RemoteFileSortColumn(rawValue: key)
            else {
                return
            }
            parent.sortColumn = column
            parent.sortAscending = descriptor.ascending
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < entries.count else { return }
            parent.onOpen(entries[row])
        }

        func contextMenu(for event: NSEvent, in tableView: NSTableView) -> NSMenu {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            let entry = row >= 0 && row < entries.count ? entries[row] : nil

            if let entry {
                select(entry: entry, row: row, in: tableView)
                return rowMenu(for: entry)
            }

            parent.selectedEntry = nil
            tableView.deselectAll(nil)
            return backgroundMenu()
        }

        private func select(entry: RemoteFileEntry, row: Int, in tableView: NSTableView) {
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            parent.selectedEntry = entry
        }

        private func rowMenu(for entry: RemoteFileEntry) -> NSMenu {
            let menu = NSMenu()
            let isParentEntry = entry.name == ".."
            let canOpen = entry.isDirectory ? parent.canNavigate : parent.canMutate
            menu.addItem(menuItem("打开", action: .open, entry: entry, image: "arrow.up.right.square", enabled: canOpen && !isParentEntry))
            menu.addItem(menuItem("下载到本地", action: .download, entry: entry, image: "arrow.down.doc", enabled: parent.canMutate && !isParentEntry))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem("复制到目标目录", action: .copyToDirectory, entry: entry, image: "doc.on.doc", enabled: parent.canMutate && !isParentEntry))
            menu.addItem(menuItem("重命名", action: .rename, entry: entry, image: "pencil", enabled: parent.canMutate && !isParentEntry))
            menu.addItem(menuItem("删除", action: .delete, entry: entry, image: "trash", enabled: parent.canMutate && !isParentEntry, destructive: true))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem("刷新", action: .refresh, entry: nil, image: "arrow.clockwise", enabled: parent.canNavigate))
            menu.addItem(menuItem("新建文件夹", action: .newFolder, entry: nil, image: "folder.badge.plus", enabled: parent.canMutate))
            menu.addItem(menuItem("修改权限", action: .editPermissions, entry: entry, image: "lock.open", enabled: parent.canMutate && !isParentEntry))
            return menu
        }

        private func backgroundMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(menuItem("刷新", action: .refresh, entry: nil, image: "arrow.clockwise", enabled: parent.canNavigate))
            menu.addItem(menuItem("新建文件夹", action: .newFolder, entry: nil, image: "folder.badge.plus", enabled: parent.canMutate))
            menu.addItem(menuItem("上传到当前目录", action: .uploadHere, entry: nil, image: "arrow.up.doc", enabled: parent.canMutate))
            return menu
        }

        private func menuItem(
            _ title: String,
            action: RemoteFileContextAction,
            entry: RemoteFileEntry?,
            image: String,
            enabled: Bool,
            destructive: Bool = false
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(handleContextMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RemoteFileMenuCommand(action: action, entry: entry)
            item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: image, accessibilityDescription: title)

            if destructive {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }

            return item
        }

        @objc private func handleContextMenuItem(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? RemoteFileMenuCommand else { return }
            parent.onContextAction(command.action, command.entry)
        }

        private func textCell(tableView: NSTableView, text: String, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? RemoteTextCellView
                ?? RemoteTextCellView(identifier: identifier)
            cell.configure(text: text, color: .secondaryLabelColor)
            return cell
        }

        private func kindCell(
            tableView: NSTableView,
            entry: RemoteFileEntry,
            identifier: NSUserInterfaceItemIdentifier
        ) -> NSTableCellView {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? RemoteKindCellView
                ?? RemoteKindCellView(identifier: identifier)
            cell.configure(entry: entry)
            return cell
        }
    }
}

private enum RemoteFileColumn: String {
    case name
    case modified
    case size
    case kind

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }
}

private final class RemoteFileNSTableView: NSTableView {
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event) ?? super.menu(for: event)
    }
}

private final class RemoteFileMenuCommand {
    let action: RemoteFileContextAction
    let entry: RemoteFileEntry?

    init(action: RemoteFileContextAction, entry: RemoteFileEntry?) {
        self.action = action
        self.entry = entry
    }
}

private final class RemoteNameCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("remote-file-name-cell")

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.reuseIdentifier
        setup()
    }

    func configure(_ entry: RemoteFileEntry) {
        iconView.image = NSImage(systemSymbolName: iconName(for: entry), accessibilityDescription: entry.kind)
        iconView.contentTintColor = iconColor(for: entry)
        titleField.stringValue = entry.name
        detailField.stringValue = entry.permissions
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        detailField.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingMiddle
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(titleField)
        addSubview(detailField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2)
        ])
    }

    private func iconName(for entry: RemoteFileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isLink { return "arrowshape.turn.up.right.fill" }
        return "doc.fill"
    }

    private func iconColor(for entry: RemoteFileEntry) -> NSColor {
        if entry.isDirectory { return NSColor(calibratedRed: 0.32, green: 0.73, blue: 0.94, alpha: 1) }
        if entry.isLink { return .systemCyan }
        return .secondaryLabelColor
    }
}

private final class RemoteTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
    }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class RemoteKindCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(entry: RemoteFileEntry) {
        label.stringValue = entry.kind
        chevron.isHidden = !entry.isDirectory
    }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor

        addSubview(label)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),

            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6)
        ])
    }
}
