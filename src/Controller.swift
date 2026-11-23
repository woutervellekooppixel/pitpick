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
    let cards = CardWatcher()
    var window: NSWindow!
    var main: MainView!
    private var direction = 1
    private var ingestCancelled = false
    /// Runs once the folders being opened are read (Ingest on the card list).
    private var afterLoad: (() -> Void)?
    /// The question about culling on a card was answered for this close or quit.
    private var leavingConfirmed = false

    override init() {
        super.init()
        pipeline.onThumbReady = { [weak self] id in self?.thumbReady(id) }
        pipeline.onPreviewReady = { [weak self] id in self?.previewReady(id) }
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
        let panel = NSHostingView(rootView: SidePanel(session: session, pad: pad, cards: cards, controller: self))
        main.setPanel(panel)
        window.contentView = main
        window.setFrameAutosaveName("Pitpick.window")
        if !window.setFrameUsingName("Pitpick.window") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(main.grid)
        cards.start()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        leavingConfirmed = leavingCardIsOK("Close")
        return leavingConfirmed
    }

    func windowWillClose(_ notification: Notification) {
        writer.flush(wait: true)
    }

    // MARK: memory cards

    /// Photos on a card with a tag, stars or a label: these live only in Pitpick until the ingest.
    var unsavedCardCulling: Int {
        guard session.onCard || session.lockedVolume else { return 0 }
        return session.photos.reduce(0) { $0 + ($1.tagged || $1.rating > 0 || $1.label != nil ? 1 : 0) }
    }

    /// Asks before tags, stars and labels set on a card would be lost (opening something else, closing, quitting).
    func leavingCardIsOK(_ action: String) -> Bool {
        if leavingConfirmed { return true }
        let n = unsavedCardCulling
        guard n > 0 else { return true }
        return confirm("\(n) photo\(n == 1 ? " has" : "s have") a tag, stars or a label on the card",
                       "Pitpick writes nothing on a card, so these stay in Pitpick until you ingest it. \(action) anyway and lose them?",
                       action)
    }

    /// Opens the checked cards together, to look at them on the card.
    func viewCards() {
        let urls = cards.checked.map { $0.url }
        guard !urls.isEmpty, session.busy == nil else { return }
        open(urls)
    }

    /// Opens the checked cards (unless they already are open) and starts the ingest.
    func ingestCards() {
        let urls = cards.checked.map { $0.url }
        guard !urls.isEmpty, session.busy == nil else { return }
        let open = Set(session.roots.map { $0.standardizedFileURL.path })
        if open == Set(urls.map { $0.path }) && session.loading == nil && !session.photos.isEmpty {
            ingest()
        } else {
            self.open(urls) { [weak self] in self?.ingest() }
        }
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

    func open(_ urls: [URL], then: (() -> Void)? = nil) {
        guard leavingCardIsOK("Open") else { return }
        afterLoad = then
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
        // A memory card, or any locked disk, is treated like a read-only folder: Pitpick writes nothing there,
        // tags stay in Pitpick and go along with the ingest (no exiftool error for every key press on a locked card).
        session.lockedVolume = roots.contains { (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true }
        session.onCard = roots.contains { CardWatcher.isOnCard($0) }
        session.readOnly = session.onCard || session.lockedVolume || roots.contains { pad.isReadOnly($0.path) }
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
        // exiftool ready before the first tag or ingest; not during the first read, which it slowed by ~120 ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ExifTool.shared.warmUp() }
        if let next = afterLoad, !photos.isEmpty {
            afterLoad = nil
            next()
        }
        afterLoad = nil
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
        // sharpest first; the PRVW stand-in (1620 px) keeps fast browsing from going black
        let best = full ?? pipeline.screen(p.id) ?? pipeline.preview(p.id) ?? pipeline.thumb(p.id)
        main.loupe.show(p, image: best)
        if best == nil { pipeline.requestThumbs([p.ref]) }
    }

    private var idleFull: DispatchWorkItem?

    func updatePrefetch() {
        idleFull?.cancel()
        idleFull = nil
        let v = session.visible
        guard !v.isEmpty else {
            pipeline.want([])
            pipeline.wantFull([])
            pipeline.requestPreviews([])
            return
        }
        let i = session.currentIndex
        func ref(_ j: Int) -> SourceRef? { j >= 0 && j < v.count ? v[j].ref : nil }
        // loupe: 7 ahead and 2 behind; grid: only what Return needs at once (a screen image is 45 MB)
        let ahead = session.mode == .loupe ? 7 : 2, behind = session.mode == .loupe ? 2 : 1
        var refs: [SourceRef] = []
        refs += [ref(i)].compactMap { $0 }
        for k in 1...ahead { if let r = ref(i + direction * k) { refs.append(r) } }
        for k in 1...behind { if let r = ref(i - direction * k) { refs.append(r) } }
        pipeline.want(refs)
        guard session.mode == .loupe, let p = session.currentPhoto else {
            pipeline.requestPreviews([])
            pipeline.releaseFulls()
            return
        }
        // stand-ins ahead: 12 photos in the browsing direction, 2 behind (about 6 ms each, in software)
        var previews: [SourceRef] = []
        for k in 0...12 { if let r = ref(i + direction * k) { previews.append(r) } }
        for k in 1...2 { if let r = ref(i - direction * k) { previews.append(r) } }
        pipeline.requestPreviews(previews)
        if main.loupe.zoomed {
            // zoomed: this photo first, then the next and the previous one, so a burst can be compared at 100%
            var full = [FullRequest(ref: p.ref, urgent: true)]
            if let r = ref(i + direction) { full.append(FullRequest(ref: r, urgent: false)) }
            if let r = ref(i - direction) { full.append(FullRequest(ref: r, urgent: false)) }
            pipeline.wantFull(full)
        } else {
            pipeline.wantFull([])
            // still on the same photo after a moment: prepare its 100%, so space or a click shows it at once
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.session.mode == .loupe, !self.main.loupe.zoomed, self.session.currentPhoto === p else { return }
                self.pipeline.wantFull([FullRequest(ref: p.ref, urgent: false)])
            }
            idleFull = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
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

    private func previewReady(_ id: Int) {
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
            session.message = session.onCard || session.lockedVolume
                ? "Pitpick writes nothing on a card. Ingest it first: your tags, stars and labels go along."
                : "This folder is set as read-only, so Pitpick writes nothing here. Copy the selection to another folder first."
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
        let unknown = pad.v.unknownTokens(in: templates)
        if !unknown.isEmpty {
            session.message = "\(unknown.joined(separator: ", ")) is not a known token, so it would end up in the names as it is. Check the spelling under Metadata template; the tokens are listed there."
            session.openTemplate = true
            return false
        }
        if let problem = pad.v.dateProblem {
            session.message = problem
            return false
        }
        let missing = pad.v.emptyReferences(in: templates)
        if missing.isEmpty { return true }
        var text = "Fill in \(missing.joined(separator: ", ")) first: the names are built from it."
        let pinnedMissing = missing.filter { label in Fields.all.contains { $0.label == label && pad.pinned.contains($0.key) } }
        if !pinnedMissing.isEmpty {
            text += " You find \(pinnedMissing.joined(separator: ", ")) under Metadata template, at the bottom of this panel."
            session.openTemplate = true
        }
        session.message = text
        return false
    }

    /// Metadata that refers to empty fields: ask before writing.
    private func metadataReady() -> Bool {
        if let problem = pad.v.dateProblem {
            session.message = problem
            return false
        }
        let missing = pad.v.emptyReferences(in: pad.v.writtenTexts)
        let unknown = pad.v.unknownTokens(in: pad.v.writtenTexts)
        if missing.isEmpty && unknown.isEmpty { return true }
        var text = ""
        if !missing.isEmpty { text += "The metadata refers to \(missing.joined(separator: ", ")), which \(missing.count == 1 ? "is" : "are") empty. " }
        if !unknown.isEmpty { text += "\(unknown.joined(separator: ", ")) is not a known token and would be written as it is. " }
        return confirm(missing.isEmpty ? "Unknown token" : "Some fields are empty", text + "Write anyway?", "Write anyway")
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
        let values = pad.v
        let labels = values.labelNames
        let preview = FileOps.planRename(photos) { p, n in values.fileName(photo: p, seq: n) }
        guard !preview.items.isEmpty else {
            session.message = preview.skipped.isEmpty ? "All names are already right." : "Nothing renamed: \(preview.skipped.count) skipped."
            return
        }
        let examples = preview.items.prefix(3).map { "\($0.photo.name)  →  \($0.main.lastPathComponent)" }.joined(separator: "\n")
        guard confirm("Rename \(preview.items.count) photos?",
                      examples + "\n\nThe XMP files move along, and you can undo it. Rename before you import into Lightroom.",
                      "Rename") else { return }
        // In the background, so the window keeps working. Tags set meanwhile are written afterwards, to the new names.
        session.busy = "Renaming: 0 / \(preview.items.count)"
        writer.paused = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. the camera file name into the XMP first, so {filename} and {frame} keep working afterwards
            let need = photos.filter { !$0.hasStoredOriginal }
            if !need.isEmpty {
                let cmds = need.map { ["-overwrite_original"] + Metadata.stateArgs($0, labelNames: labels) + [$0.metadataTarget.path] }
                let targets = need.map { $0.metadataTarget }
                let res = ExifTool.shared.run(cmds) { done in
                    DispatchQueue.main.async { self?.session.busy = "Saving the camera names: \(done) / \(need.count)" }
                }
                DispatchQueue.main.sync {
                    for (i, r) in res.enumerated() where r.ok {
                        if need[i].kind != .embedded { need[i].sidecar = targets[i] }
                        need[i].hasStoredOriginal = true
                    }
                }
            }
            // 2. plan again now every photo has its XMP, then move the files
            let plan = FileOps.planRename(photos) { p, n in values.fileName(photo: p, seq: n) }
            let result = FileOps.performRename(plan.items) { done in
                DispatchQueue.main.async { self?.session.busy = "Renaming: \(done) / \(plan.items.count)" }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                FileOps.apply(result.updates)
                self.pipeline.clearFailures()
                self.writer.paused = false
                self.writer.flush()
                self.session.busy = nil
                self.session.lastRenameLog = result.log
                self.session.message = result.errors.isEmpty
                    ? "Renamed \(result.done) photos." + (plan.skipped.isEmpty ? "" : " Skipped \(plan.skipped.count).")
                    : "Renamed \(result.done), problems: \(result.errors.prefix(3).joined(separator: "; "))"
                self.main.grid.needsDisplay = true
                self.main.loupe.updateInfo()
                self.updatePrefetch()
            }
        }
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
        let values = pad.v
        // Only what still has to be copied counts: on a resume the photos that are already there need no space.
        let plan = FileOps.planIngest(sources, to: dest) { p, n in values.fileName(photo: p, seq: n) }
        let bytes = plan.reduce(Int64(0)) { $0 + $1.bytes }
        let already = plan.filter { $0.reuse }.count
        let free = (try? URL(fileURLWithPath: pad.ingestRoot).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_000_000_000) }
        if free > 0 && bytes > free {
            session.message = "Not enough space: the photos need \(gb(bytes)), there is \(gb(free)) free."
            return
        }
        let example = values.fileName(photo: sources.first, seq: 1) + "." + (sources.first?.url.pathExtension.lowercased() ?? "cr3")
        var text = "To \((dest.path as NSString).abbreviatingWithTildeInPath)\n\nNames like:\n\(example)\n\n\(gb(bytes))" + (free > 0 ? " (\(gb(free)) free)." : ".")
        if already > 0 { text += " \(already) photos are already there and are not copied again." }
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
        if r.diskFull {
            msg += " Stopped: \(r.errors.first ?? "the destination disk is full.")"
        } else if !r.errors.isEmpty {
            msg += " Problems: \(r.errors.prefix(3).joined(separator: "; "))"
        }
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
