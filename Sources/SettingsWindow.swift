import AppKit

// One editable row of the settings window: a non-archived project of the Projects group.
struct SettingsRow: Equatable {
    let key: String
    let name: String
    let registryID: String?
    let port: Int
    var hidden: Bool
    var production: String
    var api: String
}

// One Registry.writeLinks call. nil clears that key.
struct RegistryChange: Equatable {
    let name: String
    let registryID: String
    let production: String?
    let api: String?
}

// Every registry write of the app goes through one serial queue, so saves from a window that
// was closed mid-save and from a reopened one never overlap and drop each other's edit.
enum RegistryWrites {
    static let queue = DispatchQueue(label: "com.jorgedelacruz.mini-bar.registry-writes", qos: .userInitiated)

    // Applies the changes in order and stops at the first failure.
    static func apply(_ changes: [RegistryChange], write: (RegistryChange) throws -> Void)
        -> (written: [RegistryChange], failure: (change: RegistryChange, error: Error)?) {
        var written: [RegistryChange] = []
        for change in changes {
            do { try write(change) } catch { return (written, (change, error)) }
            written.append(change)
        }
        return (written, nil)
    }
}

// Pure decisions behind the settings window, covered by menuSelfTest().
enum SettingsModel {
    enum OpenAction: Equatable { case show, busy, create }

    // A window built while a save is still writing would load links that are about to change.
    static func openAction(hasWindow: Bool, saving: Bool) -> OpenAction {
        hasWindow ? .show : (saving ? .busy : .create)
    }

    static let productionField = "Production URL"
    static let apiField = "API URL"
    static let registryNote = "Registry changed in ~/Projects. Run `npm run workspace:sync` and commit to update ProjectsDocs."

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Launcher projects match by the lowercased folder name (the entries key). Registry-only
    // projects ("registry-<id>") carry their registry name, not their folder, so they match by id.
    static func entry(for project: Project, in entries: [String: RegistryEntry]) -> RegistryEntry? {
        if project.key.hasPrefix("registry-") {
            let id = String(project.key.dropFirst("registry-".count))
            if let entry = entries.values.first(where: { $0.id == id }) { return entry }
        }
        return entries[project.name.lowercased()] ?? entries[project.directory.lowercased()]
    }

    static func rows(statuses: [ProjectStatus], entries: [String: RegistryEntry], prefs: MenuPreferences) -> [SettingsRow] {
        prefs.ordered(statuses.filter { MenuModel.group(of: $0.project) == .projects }).map { status in
            let project = status.project
            let entry = entry(for: project, in: entries)
            return SettingsRow(key: project.key, name: project.name, registryID: entry?.id, port: project.webPort,
                               hidden: prefs.hidden.contains(project.key),
                               production: entry?.links.production?.absoluteString ?? "",
                               api: entry?.links.api?.absoluteString ?? "")
        }
    }

    // First non-empty URL that is not an acceptable https URL, in row order, production before API.
    // Rows without a registry entry have disabled fields and are never written, so they are skipped.
    static func firstInvalid(_ rows: [SettingsRow]) -> (project: String, field: String)? {
        for row in rows where row.registryID != nil {
            for (field, text) in [(productionField, row.production), (apiField, row.api)]
            where !trimmed(text).isEmpty && Registry.httpsURL(text) == nil {
                return (row.name, field)
            }
        }
        return nil
    }

    // Rows with a registry entry whose trimmed production or API text differs from what was loaded.
    // Rows are matched by key, so reordering or hiding alone writes nothing.
    static func registryChanges(original: [SettingsRow], edited: [SettingsRow]) -> [RegistryChange] {
        let before = Dictionary(original.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return edited.compactMap { row in
            guard let id = row.registryID else { return nil }
            let production = trimmed(row.production), api = trimmed(row.api)
            guard production != trimmed(before[row.key]?.production ?? "") || api != trimmed(before[row.key]?.api ?? "") else { return nil }
            return RegistryChange(name: row.name, registryID: id, production: production.isEmpty ? nil : production, api: api.isEmpty ? nil : api)
        }
    }

    // The rows decide visibility and order of the projects they show; keys of projects that are
    // not listed right now (for example a checkout that is temporarily missing) are kept.
    static func preferences(_ rows: [SettingsRow], previous: MenuPreferences) -> MenuPreferences {
        let keys = Set(rows.map { $0.key })
        let hidden = previous.hidden.subtracting(keys).union(rows.filter { $0.hidden }.map { $0.key })
        return MenuPreferences(hidden: hidden, order: rows.map { $0.key } + previous.order.filter { !keys.contains($0) })
    }

    static func move(_ rows: [SettingsRow], index: Int, offset: Int) -> [SettingsRow]? {
        let target = index + offset
        guard offset != 0, rows.indices.contains(index), rows.indices.contains(target) else { return nil }
        var result = rows
        result.insert(result.remove(at: index), at: target)
        return result
    }
}

// Text fields inside rows take focus on the first click instead of selecting the row first.
private final class SettingsTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

// "Configure Projects…" window. Created by show() and torn down in windowWillClose; the owner
// keeps this object only until onClosed. No timers or observers outlive the window.
final class ProjectSettingsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Column {
        static let show = NSUserInterfaceItemIdentifier("show")
        static let project = NSUserInterfaceItemIdentifier("project")
        static let port = NSUserInterfaceItemIdentifier("port")
        static let production = NSUserInterfaceItemIdentifier("production")
        static let api = NSUserInterfaceItemIdentifier("api")
        static let order = NSUserInterfaceItemIdentifier("order")
    }

    private let root: URL
    private let appRoot: URL
    private let onSaved: () -> Void
    private let onSaving: (Bool) -> Void
    private let onClosed: () -> Void
    private var prefs: MenuPreferences
    private var original: [SettingsRow]
    private var rows: [SettingsRow]
    private var saving = false

    private var window: NSWindow?
    private var table: NSTableView?
    private var saveButton: NSButton?
    private var spinner: NSProgressIndicator?
    private var statusLabel: NSTextField?

    init(root: URL, appRoot: URL, statuses: [ProjectStatus], entries: [String: RegistryEntry], prefs: MenuPreferences,
         onSaved: @escaping () -> Void, onSaving: @escaping (Bool) -> Void, onClosed: @escaping () -> Void) {
        self.root = root
        self.appRoot = appRoot
        self.prefs = prefs
        self.onSaved = onSaved
        self.onSaving = onSaving
        self.onClosed = onClosed
        let rows = SettingsModel.rows(statuses: statuses, entries: entries, prefs: prefs)
        self.original = rows
        self.rows = rows
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        // Released on close by dropping the only strong reference (windowWillClose). AppKit's own
        // isReleasedWhenClosed = true over-releases a window that Swift also owns and crashes.
        window.isReleasedWhenClosed = false
        window.title = "Configure Projects"
        window.minSize = NSSize(width: 760, height: 300)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        self.window = window
        updateStatus()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let content = NSView()
        let header = NSTextField(wrappingLabelWithString: "Choose which projects the menu shows and in which order; this is saved for this Mac only. Production and API URLs are saved to workspace.registry.json in ~/Projects. Local ports come from project-dev.sh and are read-only.")
        header.textColor = .secondaryLabelColor

        let table = SettingsTableView()
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (identifier, title, width, flexible) in [
            (Column.show, "Show", 44.0, false), (Column.project, "Project", 170.0, false), (Column.port, "Local port", 74.0, false),
            (Column.production, SettingsModel.productionField, 240.0, true), (Column.api, SettingsModel.apiField, 240.0, true),
            (Column.order, "Order", 72.0, false),
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = flexible ? 140 : width
            column.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : []
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        for view in [header, scroll, save, cancel, spinner, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -16),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            save.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            spinner.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])
        self.table = table
        self.saveButton = save
        self.spinner = spinner
        self.statusLabel = status
        return content
    }

    // Centers a control vertically in its cell; fill stretches it to the cell width.
    private func cell(_ view: NSView, fill: Bool) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        var constraints = [view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                           view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3)]
        if fill { constraints.append(view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3)) }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func orderButton(symbol: String, label: String, offset: Int, enabled: Bool) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button = NSButton(image: image, target: self, action: #selector(move(_:)))
        } else {
            button = NSButton(title: label, target: self, action: #selector(move(_:)))
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = offset
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = enabled
        return button
    }

    private func updateStatus() {
        guard !saving else { return }
        let shown = rows.filter { !$0.hidden }.count
        statusLabel?.stringValue = rows.isEmpty ? "No projects to configure." : "\(shown) of \(rows.count) projects shown in the menu."
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        switch identifier {
        case Column.show:
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleVisible(_:)))
            box.state = item.hidden ? .off : .on
            box.setAccessibilityLabel("Show \(item.name) in the menu")
            return cell(box, fill: false)
        case Column.project:
            let label = NSTextField(labelWithString: item.name)
            label.lineBreakMode = .byTruncatingTail
            return cell(label, fill: true)
        case Column.port:
            let label = NSTextField(labelWithString: item.port > 0 ? String(item.port) : "—")
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            return cell(label, fill: true)
        case Column.production, Column.api:
            let isProduction = identifier == Column.production
            let field = NSTextField(string: item.registryID == nil ? "" : (isProduction ? item.production : item.api))
            field.identifier = identifier
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.cell?.isScrollable = true
            field.isEnabled = item.registryID != nil
            field.placeholderString = item.registryID == nil ? "No registry entry" : (isProduction ? "https://example.com" : "https://api.example.com")
            field.setAccessibilityLabel("\(item.name) \(isProduction ? SettingsModel.productionField : SettingsModel.apiField)")
            field.delegate = self
            return cell(field, fill: true)
        case Column.order:
            let stack = NSStackView(views: [
                orderButton(symbol: "chevron.up", label: "Move Up", offset: -1, enabled: row > 0),
                orderButton(symbol: "chevron.down", label: "Move Down", offset: 1, enabled: row < rows.count - 1),
            ])
            stack.orientation = .horizontal
            stack.spacing = 4
            return cell(stack, fill: false)
        default:
            return nil
        }
    }

    // The model follows every keystroke, so reloads and Save never lose an edit in progress.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let table else { return }
        let row = table.row(for: field)
        guard rows.indices.contains(row) else { return }
        if field.identifier == Column.production { rows[row].production = field.stringValue }
        if field.identifier == Column.api { rows[row].api = field.stringValue }
    }

    @objc private func toggleVisible(_ sender: NSButton) {
        guard let row = table?.row(for: sender), rows.indices.contains(row) else { return }
        rows[row].hidden = sender.state != .on
        updateStatus()
    }

    @objc private func move(_ sender: NSButton) {
        guard let table, let moved = SettingsModel.move(rows, index: table.row(for: sender), offset: sender.tag) else { return }
        window?.makeFirstResponder(nil)
        rows = moved
        table.reloadData()
    }

    // MARK: Save

    @objc private func cancel(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc private func save(_ sender: Any?) {
        guard !saving, let window else { return }
        window.makeFirstResponder(nil)
        if let invalid = SettingsModel.firstInvalid(rows) {
            present("\(invalid.project): \(invalid.field) is not valid.",
                    info: "Use an https URL with a host and no user name or password, or leave the field empty to remove it. Nothing was saved.")
            return
        }
        let next = SettingsModel.preferences(rows, previous: prefs)
        do { try next.save(appRoot: appRoot) } catch {
            present("Could not save menu preferences.", info: error.localizedDescription)
            return
        }
        prefs = next
        let changes = SettingsModel.registryChanges(original: original, edited: rows)
        guard !changes.isEmpty else {
            onSaved()
            window.close()
            return
        }

        // writeLinks runs node for validation and Controller.command has no timeout, so the
        // writes stay off the main thread; a hung validator must not freeze the menu bar.
        // onSaving is held here, not through self, so the owner learns the end of a save
        // even when the window was closed (and this controller released) while it ran.
        setSaving(true)
        let root = self.root, onSaved = self.onSaved, onSaving = self.onSaving
        onSaving(true)
        RegistryWrites.queue.async { [weak self] in
            let (written, failure) = RegistryWrites.apply(changes) { change in
                try Registry.writeLinks(root: root, registryID: change.registryID, production: change.production, api: change.api)
            }
            DispatchQueue.main.async {
                onSaving(false)
                // Preferences, and any links written before a failure, are on disk: the menu reloads them.
                onSaved()
                if let self {
                    self.finishSave(written: written, failure: failure)
                } else {
                    // The window was closed while saving; report without it.
                    let (message, info) = ProjectSettingsController.outcome(written: written, failure: failure)
                    ProjectSettingsController.presentDetached(message, info: info)
                }
            }
        }
    }

    private static func outcome(written: [RegistryChange], failure: (change: RegistryChange, error: Error)?) -> (message: String, info: String) {
        let note = written.isEmpty ? "" : "\n\n" + SettingsModel.registryNote
        if let failure {
            let saved = written.isEmpty ? "" : "\n\nLinks saved before the failure: \(written.map { $0.name }.joined(separator: ", "))."
            return ("Could not save the links of \(failure.change.name).", failure.error.localizedDescription + saved + note)
        }
        return ("Settings saved.", SettingsModel.registryNote)
    }

    private func finishSave(written: [RegistryChange], failure: (change: RegistryChange, error: Error)?) {
        setSaving(false)
        // Written rows become the new baseline, so a retry only rewrites what is still pending.
        for change in written {
            for index in original.indices where original[index].registryID == change.registryID {
                original[index].production = change.production ?? ""
                original[index].api = change.api ?? ""
            }
        }
        let (message, info) = Self.outcome(written: written, failure: failure)
        if failure != nil {
            present(message, info: info)
        } else {
            // The sheet is still attached inside its handler, so close on the next turn.
            present(message, info: info, style: .informational) { [weak self] in
                DispatchQueue.main.async { self?.window?.close() }
            }
        }
    }

    private func setSaving(_ on: Bool) {
        saving = on
        saveButton?.isEnabled = !on
        if on {
            spinner?.startAnimation(nil)
            statusLabel?.stringValue = "Saving links to workspace.registry.json…"
        } else {
            spinner?.stopAnimation(nil)
            updateStatus()
        }
    }

    private func present(_ message: String, info: String, style: NSAlert.Style = .warning, then: (() -> Void)? = nil) {
        guard let window, window.isVisible else {
            Self.presentDetached(message, info: info, style: style)
            then?()
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in then?() }
    }

    private static func presentDetached(_ message: String, info: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Close

    func windowWillClose(_ notification: Notification) {
        spinner?.stopAnimation(nil)
        table?.dataSource = nil
        table?.delegate = nil
        window?.delegate = nil
        table = nil
        saveButton = nil
        spinner = nil
        statusLabel = nil
        window = nil
        // Last: the owner may release this object here.
        onClosed()
    }
}
