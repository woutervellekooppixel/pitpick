// The brain: keys, browsing, preloading, ingest and the actions from the side panel.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class MainView: NSView {
    let gridScroll = NSScrollView()
    let grid = GridView()
    let loupe = LoupeView()
    var panel: NSView!
    var panelVisible = true { didSet { needsLayout = true } }
    let panelWidth: CGFloat = 360
    weak var controller: Controller?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = true
        gridScroll.backgroundColor = .black
        gridScroll.scrollerStyle = .overlay
        gridScroll.contentView.postsBoundsChangedNotifications = true
        addSubview(gridScroll)
        addSubview(loupe)
        loupe.isHidden = true
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: gridScroll.contentView, queue: .main) { [weak self] _ in
            self?.grid.requestVisibleThumbs()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPanel(_ v: NSView) {
        panel = v
        addSubview(v)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let pw = panelVisible ? panelWidth : 0
        let photoRect = CGRect(x: 0, y: 0, width: max(100, b.width - pw), height: b.height)
        gridScroll.frame = photoRect
        loupe.frame = photoRect
        panel?.frame = CGRect(x: b.width - pw, y: 0, width: pw, height: b.height)
        panel?.isHidden = !panelVisible
        grid.relayout()
        loupe.relayout()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        controller?.openOrImport(urls)
        return true
    }
}

final class Controller: NSObject, NSWindowDelegate {
    let session = Session()
    let pad = Pad()
    let pipeline = ImagePipeline()
    let writer = StateWriter()
    var window: NSWindow!
    var main: MainView!
    private var direction = 1
    private var ingestCancelled = false

    override init() {
        super.init()
        pipeline.onThumbReady = { [weak self] id in self?.thumbReady(id) }
        pipeline.onScreenReady = { [weak self] id in self?.screenReady(id) }
        pipeline.onFullReady = { [weak self] id in self?.screenReady(id) }
        writer.labelNames = { [weak self] in self?.pad.v.labelNames ?? [] }
        writer.onError = { [weak self] msg in self?.session.message = msg }
    }

    // MARK: window

    func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1460, height: 900)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Pitpick"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 820, height: 520)
        window.delegate = self
        main = MainView(frame: frame)
        main.controller = self
        main.grid.controller = self
        main.loupe.controller = self
        let panel = NSHostingView(rootView: SidePanel(session: session, pad: pad, controller: self))
        main.setPanel(panel)
        window.contentView = main
        window.setFrameAutosaveName("Pitpick.window")
        if !window.setFrameUsingName("Pitpick.window") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(main.grid)
    }

    func windowWillClose(_ notification: Notification) {
        writer.flush(wait: true)
    }

    /// A blocking yes/no question. The screenshot test answers yes by itself.
    func confirm(_ title: String, _ text: String, _ ok: String) -> Bool {
        if Snapshot.active { return true }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: opening

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Open"
        p.message = "Choose a folder or memory card. Two cards at once: drag both onto the window."
        p.beginSheetModal(for: window) { [weak self] r in
            if r == .OK { self?.open(p.urls) }
        }
    }

    /// Folders open; .pitpick (and old .snelkeus) files are presets.
    func openOrImport(_ urls: [URL]) {
        let presets = urls.filter { Controller.presetExtensions.contains($0.pathExtension.lowercased()) }
        for u in presets { importPreset(from: u) }
        let rest = urls.filter { !Controller.presetExtensions.contains($0.pathExtension.lowercased()) }
        if !rest.isEmpty { open(rest) }
    }

    func open(_ urls: [URL]) {
        writer.flush(wait: true)
        pipeline.reset()
        let roots = urls.map { $0.standardizedFileURL }
        session.setPhotos([], roots: roots)
        session.loading = "Reading..."
        session.mode = .grid
        applyMode()
        main.grid.relayout()
        let title = roots.map { $0.lastPathComponent }.joined(separator: " + ")
        window.title = "Pitpick - \(title)"
        session.title = title
        let start = nowMs()
        DispatchQueue.global(qos: .userInitiated).async {
            let files = Scanner.collectFiles(roots)
            let groups = Scanner.group(files)
            let total = groups.count
            let photos = Scanner.load(groups) { done in
                DispatchQueue.main.async { [weak self] in
                    self?.session.loading = "Reading \(done) / \(total)"
                    self?.main.grid.needsDisplay = true
                }
            }
            let ms = nowMs() - start
            DispatchQueue.main.async { [weak self] in self?.loaded(photos, roots: roots, ms: ms) }
        }
    }

    private func loaded(_ photos: [Photo], roots: [URL], ms: Double) {
        session.setPhotos(photos, roots: roots)
        session.loading = nil
        session.readOnly = roots.contains { pad.isReadOnly($0.path) }
        writer.enabled = !session.readOnly
        let firstDay = photos.first.map { $0.shootDate } ?? ""
        pad.open(folderKey: roots.map(\.path).joined(separator: "|"), firstDay: firstDay) {
            guard let p = photos.first else { return nil }
            if p.kind == .embedded { return Scanner.embeddedXMP(p.url) }
            return p.sidecar.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        session.scopeTagged = true
        let took = ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
        session.message = photos.isEmpty ? nil : "Read \(photos.count) photos in \(took)."
        main.grid.relayout()
        main.grid.scrollToCurrent()
        applyMode()
        updatePrefetch()
        NSDocumentController.shared.noteNewRecentDocumentURL(roots[0])
    }

    func reopen() {
        guard !session.roots.isEmpty, session.busy == nil else { return }
        open(session.roots)
    }

    // MARK: browsing

    func setMode(_ m: ViewMode) {
        guard !session.visible.isEmpty || m == .grid else { return }
        session.mode = m
        if m == .grid && main.loupe.zoomed { main.loupe.setZoom(false, at: nil) }
        applyMode()
    }

    private func applyMode() {
        let loupe = session.mode == .loupe
        main.loupe.isHidden = !loupe
        main.gridScroll.isHidden = loupe
        if loupe {
            window.makeFirstResponder(main.loupe)
            showCurrent()
        } else {
            window.makeFirstResponder(main.grid)
            main.grid.needsDisplay = true
            main.grid.scrollToCurrent()
            main.grid.requestVisibleThumbs()
        }
        updatePrefetch()
    }

    func move(_ delta: Int) {
        guard !session.visible.isEmpty else { return }
        if delta != 0 { direction = delta > 0 ? 1 : -1 }
        setCurrent(session.currentIndex + delta)
    }

    func setCurrent(_ i: Int) {
        let n = session.visible.count
        guard n > 0 else { return }
        let new = max(0, min(n - 1, i))
        let old = session.currentIndex
        if new != old {
            direction = new < old ? -1 : 1
            session.currentIndex = new
            main.grid.redraw(index: old)
            main.grid.redraw(index: new)
        }
        if session.mode == .grid { main.grid.scrollToCurrent() } else { showCurrent() }
        updatePrefetch()
    }

    /// The best image there is: 100% (when zoomed), the screen image, or the thumbnail as a stand-in.
    func showCurrent() {
        guard session.mode == .loupe else { return }
        guard let p = session.currentPhoto else { main.loupe.clear(); return }
        let full = main.loupe.zoomed ? pipeline.full(p.id) : nil
        let best = full ?? pipeline.screen(p.id) ?? pipeline.thumb(p.id)
        main.loupe.show(p, image: best)
        if best == nil { pipeline.requestThumbs([p.ref]) }
    }

    func updatePrefetch() {
        let v = session.visible
        guard !v.isEmpty else { pipeline.want([]); pipeline.wantFull(nil); return }
        let i = session.currentIndex
        var refs: [SourceRef] = []
        func add(_ j: Int) { if j >= 0 && j < v.count { refs.append(v[j].ref) } }
        add(i)
        for k in 1...7 { add(i + direction * k) }
        for k in 1...2 { add(i - direction * k) }
        pipeline.want(refs)
        if session.mode == .loupe && main.loupe.zoomed, let p = session.currentPhoto {
            pipeline.wantFull(p.ref)
        } else {
            pipeline.wantFull(nil)
        }
    }

    func zoomChanged() {
        updatePrefetch()
        showCurrent()
    }

    private func thumbReady(_ id: Int) {
        main.grid.redrawThumb(id: id)
        if session.mode == .loupe, let p = session.currentPhoto, p.id == id, pipeline.screen(id) == nil { showCurrent() }
    }

    private func screenReady(_ id: Int) {
        if session.mode == .loupe, let p = session.currentPhoto, p.id == id { showCurrent() }
    }

    // MARK: tag, stars, labels

    func handleCommonKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }
        if e.keyCode == 48 { togglePanel(); return true }
        guard let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case "t": toggleTag()
        case "1", "2", "3", "4", "5": setRating(Int(ch) ?? 0)
        case "0": setRating(0)
        case "6": toggleLabel(.red)
        case "7": toggleLabel(.yellow)
        case "8": toggleLabel(.green)
        case "9": toggleLabel(.blue)
        default: return false
        }
        return true
    }

    func toggleTag() {
        guard let p = session.currentPhoto else { return }
        p.tagged.toggle()
        changed(p)
        if session.onlyTagged && !p.tagged {
            session.rebuildVisible(keeping: p)
            refreshAll()
        }
    }

    func setRating(_ n: Int) {
        guard let p = session.currentPhoto else { return }
        p.rating = p.rating == n ? 0 : n
        changed(p)
    }

    func toggleLabel(_ l: ColorLabel) {
        guard let p = session.currentPhoto else { return }
        p.label = p.label == l ? nil : l
        changed(p)
    }

    private func changed(_ p: Photo) {
        session.recount()
        writer.schedule(p)
        main.grid.redraw(p)
        main.loupe.updateInfo()
    }

    func setOnlyTagged(_ on: Bool) {
        guard on != session.onlyTagged else { return }
        let keep = session.currentPhoto
        session.onlyTagged = on
        session.rebuildVisible(keeping: keep)
        if session.visible.isEmpty && session.mode == .loupe { session.mode = .grid; applyMode() }
        refreshAll()
    }

    func refreshAll() {
        main.grid.relayout()
        main.grid.scrollToCurrent()
        if session.mode == .loupe { showCurrent() }
        updatePrefetch()
    }

    func togglePanel() { main.panelVisible.toggle() }

    func changeThumbSize(_ delta: CGFloat) {
        main.grid.cellWidth = max(110, min(420, main.grid.cellWidth + delta))
        main.grid.scrollToCurrent()
    }

    func focusPhotos() {
        window.makeFirstResponder(session.mode == .loupe ? main.loupe as NSView : main.grid as NSView)
    }

    // MARK: checks

    var scopePhotos: [Photo] { session.scopeTagged ? session.photos.filter { $0.tagged } : session.photos }

    private func writable(_ what: String) -> Bool {
        if session.busy != nil { return false }
        if session.readOnly {
            session.message = "This folder is set as read-only, so Pitpick writes nothing here. Copy the selection to another folder first."
            return false
        }
        if !ExifTool.shared.isAvailable {
            session.message = "exiftool is missing, so \(what) is not possible."
            return false
        }
        return true
    }

    /// Names must not contain empty fields (a file called "2026-11-19_-_3777" helps nobody).
    private func namesReady(_ templates: [String]) -> Bool {
        let missing = pad.v.emptyReferences(in: templates)
        if missing.isEmpty { return true }
        session.message = "Fill in \(missing.joined(separator: ", ")) first: the names are built from it."
        return false
    }

    /// Metadata that refers to empty fields: ask before writing.
    private func metadataReady() -> Bool {
        let missing = pad.v.emptyReferences(in: pad.v.writtenTexts)
        if missing.isEmpty { return true }
        return confirm("Some fields are empty", "The metadata refers to \(missing.joined(separator: ", ")), which \(missing.count == 1 ? "is" : "are") empty. Write it anyway?", "Write anyway")
    }

    // MARK: metadata and rename

    func writeMetadata() {
        guard writable("writing metadata") else { return }
        let photos = scopePhotos
        guard !photos.isEmpty else { session.message = session.scopeTagged ? "Nothing tagged yet." : "No photos."; return }
        guard metadataReady() else { return }
        writer.flush(wait: true)
        let values = pad.v
        let names = values.labelNames
        let targets = photos.map { $0.metadataTarget }
        let commands = photos.enumerated().map { i, p in
            ["-overwrite_original"] + values.metadataArgs(photo: p, seq: i + 1) + Metadata.stateArgs(p, labelNames: names) + [targets[i].path]
        }
        session.busy = "Writing metadata: 0 / \(photos.count)"
        DispatchQueue.global(qos: .userInitiated).async {
            let results = ExifTool.shared.run(commands) { done in
                DispatchQueue.main.async { [weak self] in self?.session.busy = "Writing metadata: \(done) / \(photos.count)" }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var failed: [String] = []
                for (i, r) in results.enumerated() where i < photos.count {
                    if r.ok {
                        if photos[i].kind != .embedded { photos[i].sidecar = targets[i] }
                        photos[i].hasStoredOriginal = true
                    } else { failed.append(photos[i].name) }
                }
                self.session.busy = nil
                self.pad.rememberVenue()
                self.session.message = failed.isEmpty
                    ? "Metadata written to \(photos.count) photos."
                    : "Metadata written to \(photos.count - failed.count) photos, failed for: \(failed.prefix(5).joined(separator: ", "))"
            }
        }
    }

    func rename() {
        guard writable("renaming") else { return }
        let photos = scopePhotos
        guard !photos.isEmpty else { session.message = session.scopeTagged ? "Nothing tagged yet." : "No photos."; return }
        guard namesReady([pad.v.fileTemplate]) else { return }
        writer.flush(wait: true)
        // store the camera file name in the XMP first, so {filename} and {frame} keep working afterwards
        let needOriginal = photos.filter { !$0.hasStoredOriginal }
        if !needOriginal.isEmpty {
            let names = pad.v.labelNames
            let cmds = needOriginal.map { ["-overwrite_original"] + Metadata.stateArgs($0, labelNames: names) + [$0.metadataTarget.path] }
            let targets = needOriginal.map { $0.metadataTarget }
            for (i, r) in ExifTool.shared.run(cmds).enumerated() where r.ok {
                if needOriginal[i].kind != .embedded { needOriginal[i].sidecar = targets[i] }
                needOriginal[i].hasStoredOriginal = true
            }
        }
        let values = pad.v
        let plan = FileOps.planRename(photos) { p, n in values.fileName(photo: p, seq: n) }
        guard !plan.items.isEmpty else {
            session.message = plan.skipped.isEmpty ? "All names are already right." : "Nothing renamed: \(plan.skipped.count) skipped."
            return
        }
        let examples = plan.items.prefix(3).map { "\($0.photo.name)  →  \($0.main.lastPathComponent)" }.joined(separator: "\n")
        guard confirm("Rename \(plan.items.count) photos?",
                      examples + "\n\nThe XMP files move along, and you can undo it. Rename before you import into Lightroom.",
                      "Rename") else { return }
        let result = FileOps.executeRename(plan.items)
        session.lastRenameLog = result.log
        session.message = result.errors.isEmpty
            ? "Renamed \(result.done) photos." + (plan.skipped.isEmpty ? "" : " Skipped \(plan.skipped.count).")
            : "Renamed \(result.done), problems: \(result.errors.prefix(3).joined(separator: "; "))"
        main.grid.needsDisplay = true
        main.loupe.updateInfo()
        updatePrefetch()
    }

    func undoRename() {
        guard let log = session.lastRenameLog else { return }
        let r = FileOps.undo(log)
        session.lastRenameLog = nil
        session.message = "Undone: \(r.restored) files" + (r.skipped > 0 ? ", \(r.skipped) skipped." : ".")
        reopen()
    }

    // MARK: ingest

    func chooseIngestRoot(then next: (() -> Void)? = nil) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        p.message = "Where do your job folders go? Pitpick creates <job folder>/\(pad.v.rawFolder) in here."
        if !pad.ingestRoot.isEmpty { p.directoryURL = URL(fileURLWithPath: pad.ingestRoot) }
        p.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = p.url {
                self?.pad.ingestRoot = u.path
                next?()
            }
        }
    }

    var ingestDestination: URL? {
        guard !pad.ingestRoot.isEmpty else { return nil }
        return URL(fileURLWithPath: pad.ingestRoot)
            .appendingPathComponent(pad.v.folderName, isDirectory: true)
            .appendingPathComponent(pad.v.rawFolder.isEmpty ? "raw" : safeFileName(pad.v.rawFolder), isDirectory: true)
    }

    /// Both cards in, everything copied to <ingest folder>/<job folder>/raw with names and metadata from the pad.
    /// The view switches to the copies right away, so culling can start while the rest is still copying.
    func ingest() {
        guard session.busy == nil else { return }
        let sources = session.photos
        guard !sources.isEmpty else { session.message = "Open your card(s) first."; return }
        guard namesReady([pad.v.fileTemplate, pad.v.folderTemplate]) else { return }
        guard !pad.ingestRoot.isEmpty, let dest = ingestDestination else { chooseIngestRoot { [weak self] in self?.ingest() }; return }
        guard ExifTool.shared.isAvailable else { session.message = "exiftool is missing, so ingest is not possible."; return }
        if pad.isReadOnly(dest.path) {
            session.message = "Ingest goes to a folder you can cull in, and this one is set as read-only: pick a folder on your Mac or SSD."
            return
        }
        if session.roots.contains(where: { dest.path == $0.path || dest.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(dest.path + "/") || $0.path == dest.path }) {
            session.message = "These photos are already in that ingest folder."
            return
        }
        let missingMeta = pad.v.emptyReferences(in: pad.v.writtenTexts)
        writer.flush(wait: true)
        let bytes = sources.reduce(Int64(0)) { sum, p in sum + max(0, FileOps.fileSize(p.url)) + p.companions.reduce(0) { $0 + max(0, FileOps.fileSize($1)) } }
        let free = (try? URL(fileURLWithPath: pad.ingestRoot).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_000_000_000) }
        if free > 0 && bytes > free {
            session.message = "Not enough space: the photos need \(gb(bytes)), there is \(gb(free)) free."
            return
        }
        let values = pad.v
        let example = values.fileName(photo: sources.first, seq: 1) + "." + (sources.first?.url.pathExtension.lowercased() ?? "cr3")
        var text = "To \((dest.path as NSString).abbreviatingWithTildeInPath)\n\nNames like:\n\(example)\n\n\(gb(bytes))" + (free > 0 ? " (\(gb(free)) free)." : ".")
        text += " The cards stay untouched. You can start culling while it copies."
        if !missingMeta.isEmpty { text += "\n\nNote: \(missingMeta.joined(separator: ", ")) \(missingMeta.count == 1 ? "is" : "are") empty." }
        guard confirm("Ingest \(sources.count) photos?", text, "Ingest") else { return }

        let labels = values.labelNames
        pipeline.reset()
        session.setPhotos([], roots: [dest])
        session.title = "\(dest.deletingLastPathComponent().lastPathComponent)/\(dest.lastPathComponent)"
        window.title = "Pitpick - \(session.title)"
        session.readOnly = false
        writer.enabled = true
        pad.continueJob(in: dest.path)
        session.mode = .grid
        applyMode()
        main.grid.relayout()
        ingestCancelled = false
        session.ingesting = true
        session.busy = "Ingest: 0 / \(sources.count)"
        let total = sources.count
        let start = nowMs()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = FileOps.ingest(sources, to: dest, name: { p, n in values.fileName(photo: p, seq: n) },
                                   metadata: { p in values.metadataArgs(photo: p, seq: 1) + Metadata.stateArgs(p, labelNames: labels) },
                                   cancelled: { self?.ingestCancelled ?? true },
                                   onPhoto: { p in DispatchQueue.main.async { self?.ingested(p, total: total) } })
            let ms = nowMs() - start
            DispatchQueue.main.async { self?.ingestDone(r, dest: dest, ms: ms) }
        }
    }

    func stopIngest() { ingestCancelled = true }

    private func ingested(_ p: Photo, total: Int) {
        session.append(p)
        session.busy = "Ingest: \(session.photos.count) / \(total)"
        main.grid.relayout()
        if session.photos.count <= 12 { updatePrefetch() }
    }

    private func ingestDone(_ r: IngestResult, dest: URL, ms: Double) {
        session.ingesting = false
        session.busy = nil
        pad.rememberVenue()
        let secs = Int(ms / 1000)
        var msg = "Ingested \(r.copied) photos (\(String(format: "%.1f", Double(r.bytes) / 1_000_000_000)) GB) in \(secs / 60):\(String(format: "%02d", secs % 60))."
        if r.alreadyThere > 0 { msg += " \(r.alreadyThere) were already there." }
        if r.suffixed > 0 { msg += " \(r.suffixed) got -2 because the name was taken." }
        if ingestCancelled { msg += " Stopped before the end." }
        if !r.errors.isEmpty { msg += " Problems: \(r.errors.prefix(3).joined(separator: "; "))" }
        session.message = msg
        updatePrefetch()
    }

    // MARK: copy the selection

    func chooseCopyRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        p.message = "Where does the new folder with your selection go?"
        if !pad.copyRoot.isEmpty { p.directoryURL = URL(fileURLWithPath: pad.copyRoot) }
        p.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = p.url { self?.pad.copyRoot = u.path }
        }
    }

    func copySelection(rename: Bool, withMetadata: Bool) {
        guard session.busy == nil else { return }
        let photos = scopePhotos
        guard !photos.isEmpty else { session.message = session.scopeTagged ? "Nothing tagged yet." : "No photos."; return }
        guard !pad.copyRoot.isEmpty else { chooseCopyRoot(); return }
        if rename && !namesReady([pad.v.fileTemplate]) { return }
        if pad.copyFolderOverride.trimmingCharacters(in: .whitespaces).isEmpty && !namesReady([pad.v.folderTemplate]) { return }
        if withMetadata && !ExifTool.shared.isAvailable { session.message = "exiftool is missing: copy without metadata, or install exiftool."; return }
        if withMetadata && !metadataReady() { return }
        writer.flush(wait: true)
        let dest = URL(fileURLWithPath: pad.copyRoot).appendingPathComponent(pad.copyFolderName, isDirectory: true)
        let values = pad.v
        let labels = values.labelNames
        let snapshot = photos.map { (tagged: $0.tagged, rating: $0.rating, label: $0.label, original: $0.originalFileName) }
        session.busy = "Copying: 0 / \(photos.count)"
        DispatchQueue.global(qos: .userInitiated).async {
            let res = FileOps.copy(photos, to: dest, name: { p, n in rename ? values.fileName(photo: p, seq: n) : nil },
                                   progress: { done in DispatchQueue.main.async { [weak self] in self?.session.busy = "Copying: \(done) / \(photos.count)" } },
                                   cancelled: { false })
            var metaFailed = 0
            if withMetadata && !res.copied.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.session.busy = "Writing metadata into the copies..." }
                let cmds: [[String]] = res.copied.map { item in
                    let i = photos.firstIndex { $0 === item.photo } ?? 0
                    let st = snapshot[i]
                    return ["-overwrite_original"] + values.metadataArgs(photo: item.photo, seq: i + 1)
                        + Metadata.stateArgs(tagged: st.tagged, rating: st.rating, label: st.label, original: st.original, labelNames: labels)
                        + [item.metadataTarget.path]
                }
                metaFailed = ExifTool.shared.run(cmds).filter { !$0.ok }.count
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.session.busy = nil
                if withMetadata { self.pad.rememberVenue() }
                var msg = "Copied \(res.copied.count) photos to \(dest.lastPathComponent)."
                if !res.skipped.isEmpty { msg += " Skipped \(res.skipped.count) that were already there." }
                if !res.errors.isEmpty { msg += " Errors: \(res.errors.prefix(3).joined(separator: "; "))" }
                if metaFailed > 0 { msg += " Metadata failed for \(metaFailed)." }
                self.session.message = msg
                self.session.lastCopyFolder = dest
            }
        }
    }

    func revealLastCopy() {
        if let u = session.lastCopyFolder { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    // MARK: presets

    func importPreset(from url: URL) {
        do {
            try pad.importPreset(try Data(contentsOf: url))
            session.message = "Loaded preset \(url.deletingPathExtension().lastPathComponent)."
        } catch {
            session.message = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Preset files; .snelkeus is the name from before Pitpick was renamed.
    static let presetExtensions = ["pitpick", "snelkeus"]

    func chooseImportPreset() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowedContentTypes = Controller.presetExtensions.compactMap { UTType(filenameExtension: $0) } + [.json]
        p.prompt = "Load"
        p.message = "Load a Pitpick preset (.pitpick)"
        p.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = p.url { self?.importPreset(from: u) }
        }
    }

    func chooseExportPreset() {
        guard let data = pad.exportPreset() else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "My metadata.pitpick"
        p.message = "Save the metadata template, pins and known locations as a preset"
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            do {
                try data.write(to: u)
                self?.session.message = "Saved preset \(u.lastPathComponent)."
            } catch {
                self?.session.message = "Could not save the preset: \(error.localizedDescription)"
            }
        }
    }
}
