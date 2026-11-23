// The brain: keys, browsing, preloading, ingest and the actions from the side panel.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class MainView: NSView {
    let gridScroll = NSScrollView()
    let grid = GridView()
    let loupe = LoupeView()
    let compare = CompareView()
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
        compare.isHidden = true
        addSubview(compare)
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
        compare.frame = photoRect
        panel?.frame = CGRect(x: b.width - pw, y: 0, width: pw, height: b.height)
        panel?.isHidden = !panelVisible
        grid.relayout()
        loupe.relayout()
        compare.relayout()
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
        main.compare.controller = self
        let panel = NSHostingView(rootView: SidePanel(session: session, pad: pad, cards: cards, controller: self))
        // The panel gets its frame from MainView, so SwiftUI need not work out its ideal size: without this, every
        // tag, star or label measured the whole panel again (about 80% of the time of a key press).
        panel.sizingOptions = []
        main.setPanel(panel)
        window.contentView = main
        window.setFrameAutosaveName("Pitpick.window")
        if !window.setFrameUsingName("Pitpick.window") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(main.grid)
        cards.start()
        IngestHistory.shared.preload()
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

    /// A folder is being read while the previous photos are still on screen: actions wait until it is in.
    private(set) var opening = false
    private var openToken = 0

    func open(_ urls: [URL], then: (() -> Void)? = nil) {
        guard leavingCardIsOK("Open") else { return }
        cullUndo.removeAllActions()
        afterLoad = then
        writer.flush(wait: true)
        let roots = urls.map { $0.standardizedFileURL }
        let title = roots.map { $0.lastPathComponent }.joined(separator: " + ")
        openToken += 1
        let token = openToken
        opening = true
        // Most folders are read in well under 0.15 s: the new photos then simply replace the old ones, without an
        // empty grid in between and with one update of the side panel instead of two. A card or a network drive
        // that takes longer shows "Reading..." after 0.15 s.
        let showReading = DispatchWorkItem { [weak self] in
            guard let self = self, self.openToken == token else { return }
            self.clearForReading(roots: roots, title: title)
        }
        if session.photos.isEmpty {
            clearForReading(roots: roots, title: title)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: showReading)
        }
        let start = nowMs()
        DispatchQueue.global(qos: .userInitiated).async {
            let onCard = roots.contains(where: { CardWatcher.isOnCard($0) })
            // a folder on the NAS: an index on this Mac, so opening it again only reads what changed
            let index = FolderIndex.wanted(for: roots) ? FolderIndex(roots: roots) : nil
            var files: [URL] = [], stamps: [String: FolderIndex.Stamp] = [:]
            if index != nil { (files, stamps) = Scanner.collectFilesWithStamps(roots) } else { files = Scanner.collectFiles(roots) }
            let groups = Scanner.group(files)
            let total = groups.count
            let photos = Scanner.load(groups, onCard: onCard, index: index, stamps: stamps) { done in
                // a count only when reading takes a while: every update of the panel costs a few ms
                guard nowMs() - start > 250 else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.openToken == token, self.session.loading != nil else { return }
                    self.session.loading = "Reading \(done) / \(total)"
                    self.main.grid.needsDisplay = true
                }
            }
            let ms = nowMs() - start
            // photos that were ingested before: their job folder, to continue that job (incremental ingest)
            let previous = onCard ? IngestHistory.shared.previousJob(of: photos) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.openToken == token else { return }   // another folder was opened meanwhile
                showReading.cancel()
                self.loaded(photos, roots: roots, title: title, ms: ms, onCard: onCard, previousJob: previous)
            }
            index?.save()
        }
    }

    /// An empty grid with "Reading..." while a folder is read.
    private func clearForReading(roots: [URL], title: String) {
        pipeline.reset()
        session.setPhotos([], roots: roots)
        session.loading = "Reading..."
        session.mode = .grid
        applyMode()
        main.grid.relayout()
        window.title = "Pitpick - \(title)"
        session.title = title
    }

    private func loaded(_ photos: [Photo], roots: [URL], title: String, ms: Double, onCard: Bool,
                        previousJob: (folder: String, count: Int)? = nil) {
        opening = false
        pipeline.reset()
        session.mode = .grid
        var photos = photos
        if applyClocks(photos) { photos.sort(by: Session.before) }
        session.setPhotos(photos, roots: roots)
        session.bodies = Controller.bodies(in: photos)
        main.grid.relayout()   // asks for the visible thumbnails first, before the rest below
        session.loading = nil
        window.title = "Pitpick - \(title)"
        session.title = title
        // A memory card, or any locked disk, is treated like a read-only folder: Pitpick writes nothing there,
        // tags stay in Pitpick and go along with the ingest (no exiftool error for every key press on a locked card).
        session.lockedVolume = roots.contains { (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true }
        session.onCard = onCard
        session.readOnly = session.onCard || session.lockedVolume || roots.contains { pad.isReadOnly($0.path) }
        writer.enabled = !session.readOnly
        let firstDay = photos.first.map { $0.shootDate } ?? ""
        let newJob = pad.open(folderKey: roots.map(\.path).joined(separator: "|"), firstDay: firstDay) {
            guard let p = photos.first else { return nil }
            if p.kind == .embedded { return Scanner.embeddedXMP(p.url) }
            return p.sidecar.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        var continuing = ""
        if newJob, let prev = previousJob, let text = jobXMP(in: URL(fileURLWithPath: prev.folder)) {
            // cards that were ingested before: same job, same fields, so the new photos go into the same folder
            pad.fill(from: text)
            continuing = " \(prev.count) of them were ingested before into \((prev.folder as NSString).abbreviatingWithTildeInPath): that job continues."
        }
        normalizePeople(photos)
        session.scope = .tagged
        let took = ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
        session.message = photos.isEmpty ? nil : "Read \(photos.count) photos in \(took)." + continuing
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

    /// The metadata of one photo in a job folder (its XMP sidecar, or inside a JPG/DNG).
    private func jobXMP(in folder: URL) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let x = files.first(where: { $0.pathExtension.lowercased() == "xmp" }) { return try? String(contentsOf: x, encoding: .utf8) }
        if let e = files.first(where: { Scanner.embeddedExts.contains($0.pathExtension.lowercased()) }) { return Scanner.embeddedXMP(e) }
        return nil
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
        let mode = session.mode
        main.loupe.isHidden = mode != .loupe
        main.gridScroll.isHidden = mode != .grid
        main.compare.isHidden = mode != .compare
        switch mode {
        case .loupe:
            window.makeFirstResponder(main.loupe)
            showCurrent()
        case .grid:
            window.makeFirstResponder(main.grid)
            main.grid.needsDisplay = true
            main.grid.scrollToCurrent()
            main.grid.requestVisibleThumbs()
        case .compare:
            window.makeFirstResponder(main.compare)
        }
        updatePrefetch()
    }

    // MARK: compare (G2)

    /// C: the selected photos side by side (two to four), or this photo and the next one.
    func compare() {
        let v = session.visible
        guard v.count > 1 else { return }
        var set = session.mode == .grid ? session.selectedPhotos : []
        if set.count > 4 {
            session.message = "Compare shows four photos at most: the first four of the selection."
            set = Array(set.prefix(4))
        }
        if set.count < 2 {
            let i = session.currentIndex
            set = i + 1 < v.count ? [v[i], v[i + 1]] : [v[i - 1], v[i]]
        }
        let first = set.firstIndex { $0 === session.currentPhoto } ?? 0
        if main.loupe.zoomed { main.loupe.setZoom(false, at: nil) }
        session.mode = .compare
        applyMode()
        main.compare.show(set, active: first)
        updatePrefetch()
    }

    /// Back from comparing: to the grid, or to the active photo in the loupe.
    func leaveCompare(toLoupe: Bool) {
        guard session.mode == .compare else { return }
        let p = main.compare.activePhoto
        session.mode = toLoupe ? .loupe : .grid
        applyMode()
        if let p = p, let i = session.visible.firstIndex(where: { $0 === p }) { setCurrent(i) }
        main.grid.needsDisplay = true
        pipeline.releaseFulls()
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
        if session.mode == .compare {
            // the screen images of the photos side by side; zoomed: all of them at 100%, the active one first
            let set = main.compare.photos
            pipeline.want(set.map { $0.ref })
            pipeline.requestPreviews(set.map { $0.ref })
            let a = main.compare.activePhoto
            pipeline.wantFull(main.compare.zoomed ? set.map { FullRequest(ref: $0.ref, urgent: $0 === a) } : [])
            return
        }
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
        if session.mode == .compare { main.compare.refresh(id: id) }
    }

    private func screenReady(_ id: Int) {
        if session.mode == .loupe, let p = session.currentPhoto, p.id == id { showCurrent() }
        if session.mode == .compare { main.compare.refresh(id: id) }
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
        case "c": if session.mode == .compare { leaveCompare(toLoupe: false) } else { compare() }
        case "p": editPeople()
        default: return false
        }
        return true
    }

    // MARK: culling (one route for tags, stars and labels: undo, filters and auto-advance)

    /// The photos a key press works on: the selection when there is one, otherwise the photo you are on.
    var cullTargets: [Photo] {
        // in the loupe a key works on the photo you see, when comparing on the active one; in the grid on the selection
        if session.mode == .compare { return main.compare.activePhoto.map { [$0] } ?? [] }
        if session.mode == .grid {
            let sel = session.selectedPhotos
            if sel.count > 1 { return sel }
        }
        return session.currentPhoto.map { [$0] } ?? []
    }

    // MARK: selection (grid)

    private var selectionAnchor: Int?

    func isSelected(_ i: Int) -> Bool {
        session.visible.indices.contains(i) && session.selection.contains(ObjectIdentifier(session.visible[i]))
    }

    func clearSelection() {
        selectionAnchor = nil
        guard !session.selection.isEmpty else { return }
        session.selection = []
        main.grid.needsDisplay = true
    }

    /// ⌘-click: add or remove one photo (the photo you were on joins the selection).
    func toggleSelect(_ i: Int) {
        guard session.visible.indices.contains(i) else { return }
        if session.selection.isEmpty, let cur = session.currentPhoto { session.selection.insert(ObjectIdentifier(cur)) }
        let id = ObjectIdentifier(session.visible[i])
        if session.selection.contains(id) { session.selection.remove(id) } else { session.selection.insert(id) }
        selectionAnchor = i
        setCurrent(i)
        main.grid.needsDisplay = true
    }

    /// Shift-click or shift-arrow: everything from the anchor to here.
    func extendSelection(to i: Int) {
        let n = session.visible.count
        guard n > 0 else { return }
        let target = max(0, min(n - 1, i))
        let anchor = selectionAnchor ?? session.currentIndex
        selectionAnchor = anchor
        session.selection = Set((min(anchor, target)...max(anchor, target)).map { ObjectIdentifier(session.visible[$0]) })
        setCurrent(target)
        main.grid.needsDisplay = true
    }

    func selectAll() {
        session.selection = Set(session.visible.map { ObjectIdentifier($0) })
        selectionAnchor = session.currentIndex
        main.grid.needsDisplay = true
    }

    /// After a tag, stars or a label: the next photo (setting, or Caps Lock as in Lightroom).
    var autoAdvance: Bool {
        get { pad.autoAdvance }
        set { pad.autoAdvance = newValue }
    }

    typealias CullState = (p: Photo, tagged: Bool, rating: Int, label: ColorLabel?, people: [String]?)

    /// Undo for tags, stars and labels, apart from the text fields (⌘Z there undoes typing, as always).
    /// One undo step per key press, made explicitly (not per pass through the run loop).
    let cullUndo: UndoManager = {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }()

    /// Edit > Undo and Redo while the photos have the focus: the menu says what it undoes ("Undo Tag").
    func validateCullMenu(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case Selector(("undo:")): item.title = cullUndo.undoMenuItemTitle; return cullUndo.canUndo
        case Selector(("redo:")): item.title = cullUndo.redoMenuItemTitle; return cullUndo.canRedo
        default: return true
        }
    }

    private func cull(_ name: String, _ change: ([Photo]) -> Void) {
        let targets = cullTargets
        guard !targets.isEmpty else { return }
        let before: [CullState] = targets.map { ($0, $0.tagged, $0.rating, $0.label, $0.people) }
        change(targets)
        cullUndo.beginUndoGrouping()
        registerCullUndo(before, name: name)
        cullUndo.endUndoGrouping()
        culled(targets, advance: autoAdvance || NSEvent.modifierFlags.contains(.capsLock))
    }

    func toggleTag() {
        let label = ColorLabel(rawValue: pad.tagLabel)
        cull("Tag") { ps in
            let on = ps.contains { !$0.tagged }
            for p in ps {
                p.tagged = on
                // for Lightroom, which does not read the tag: the chosen label goes along (and only that one comes off)
                if let l = label {
                    if on { if p.label == nil { p.label = l } } else if p.label == l { p.label = nil }
                }
            }
        }
    }

    /// Protected in the camera = tagged, also for the card that is open now.
    func setProtectedIsTagged(_ on: Bool) {
        pad.protectedIsTagged = on
        guard session.onCard else { return }
        for p in session.photos where p.locked {
            p.tagged = on
            main.grid.redraw(p)
        }
        session.recount()
        main.loupe.updateInfo()
    }

    // MARK: camera clocks (G8)

    /// Sets each photo's clock correction from its body; true when any photo has one (then sort again).
    @discardableResult
    func applyClocks(_ photos: [Photo]) -> Bool {
        let offsets = pad.clockOffsets
        var any = false
        for p in photos {
            let o = p.body.flatMap { offsets[$0] } ?? 0
            p.clockOffset = o
            if o != 0 { any = true }
        }
        return any
    }

    /// The bodies in a set of photos, most photos first. Only listed in the panel when there are two or more.
    static func bodies(in photos: [Photo]) -> [CameraBody] {
        var count: [String: Int] = [:], model: [String: String] = [:]
        for p in photos {
            guard let b = p.body else { continue }
            count[b, default: 0] += 1
            if model[b] == nil, let m = p.model { model[b] = m }
        }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { b, n in
            let m = (model[b] ?? "").replacingOccurrences(of: "Canon EOS ", with: "").replacingOccurrences(of: "Canon ", with: "")
            let name = b == model[b] ? (m.isEmpty ? b : m) : (m.isEmpty ? "" : m + " ") + "·" + String(b.suffix(4))
            return CameraBody(id: b, name: name, count: n)
        }
    }

    /// A clock correction for one body (seconds; 0 removes it). Sorting, {shootdate} and {time} follow.
    func setClockOffset(_ body: String, _ seconds: TimeInterval) {
        if seconds == 0 { pad.clockOffsets.removeValue(forKey: body) } else { pad.clockOffsets[body] = seconds }
        let keep = session.currentPhoto
        applyClocks(session.photos)
        session.resort(keeping: keep)
        refreshAll()
        let name = session.bodies.first { $0.id == body }?.name ?? body
        session.message = seconds == 0
            ? "The clock of \(name) is no longer corrected."
            : "The clock of \(name) is corrected by \(ExifDate.offsetText(seconds)). The photos are in shooting order again; names and the capture time in the XMP follow when you ingest, rename or write metadata."
    }

    /// Type a clock correction for one body.
    func editClockOffset(_ b: CameraBody) {
        let alert = NSAlert()
        alert.messageText = "Clock of \(b.name)"
        alert.informativeText = "How much later than its own clock were these \(b.count) photos taken? For example +1:12 (1 minute 12 seconds later), -5 (5 seconds earlier), or 0 for no correction."
        let field = NSTextField(string: pad.clockOffsets[b.id].map { ExifDate.offsetText($0) } ?? "+0:00:00")
        field.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self = self else { return }
            if let v = ExifDate.parseOffset(field.stringValue) {
                self.setClockOffset(b.id, v)
            } else {
                self.session.message = "Could not read \"\(field.stringValue)\": type for example +1:12 or -5."
            }
        }
    }

    /// Two photos of the same moment, one per body: the body with fewer photos follows the other.
    func syncClocks() {
        let sel = session.selectedPhotos
        guard sel.count == 2, let a = sel.first?.body, let b = sel.last?.body, a != b else {
            session.message = "Select two photos of the same moment, one from each camera (⌘-click), then click Same moment."
            return
        }
        let counts = Dictionary(uniqueKeysWithValues: session.bodies.map { ($0.id, $0.count) })
        let (ref, other) = (counts[a] ?? 0) >= (counts[b] ?? 0) ? (sel[0], sel[1]) : (sel[1], sel[0])
        guard let otherBody = other.body else { return }
        setClockOffset(otherBody, ref.captureDate.timeIntervalSince(other.cameraDate))
    }

    /// Tagged, rated or labelled: copied first when "Tagged and rated photos first" is on.
    static func isMarked(_ p: Photo) -> Bool { p.tagged || p.rating > 0 || p.label != nil }

    func setRating(_ n: Int) {
        cull("Stars") { ps in
            let value = ps.allSatisfy { $0.rating == n } ? 0 : n
            ps.forEach { $0.rating = value }
        }
    }

    /// P: who is in this photo (or the selection). Empty = as the job. Codes from the code file work here.
    func editPeople() {
        let targets = cullTargets
        guard let first = targets.first else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Person shown in \(first.name)" : "Person shown in \(targets.count) photos"
        let job = pad.v.value("personshown")
        alert.informativeText = "Separate names with ; and use codes from your code file, like \\jb\\. Leave it empty to use the job's" + (job.isEmpty ? " (empty)." : ": \(job).")
        let field = NSTextField(string: first.people?.joined(separator: "; ") ?? "")
        field.placeholderString = job.isEmpty ? "Name; Name" : job
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self = self else { return }
            let names = field.stringValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.cull("Person Shown") { ps in ps.forEach { $0.people = names.isEmpty ? nil : names } }
            self.focusPhotos()
        }
    }

    /// After reading: a photo whose people are the job's follows the job (so changing the job changes it too).
    func normalizePeople(_ photos: [Photo]) {
        let job = pad.v.list("personshown")
        for p in photos where p.people != nil {
            if p.people!.map({ Codes.expand($0) }) == job { p.people = nil }
        }
    }

    func toggleLabel(_ l: ColorLabel) {
        cull("Label") { ps in
            let value: ColorLabel? = ps.allSatisfy { $0.label == l } ? nil : l
            ps.forEach { $0.label = value }
        }
    }

    private func registerCullUndo(_ states: [CullState], name: String) {
        cullUndo.registerUndo(withTarget: self) { c in
            let redo: [CullState] = states.map { ($0.p, $0.p.tagged, $0.p.rating, $0.p.label, $0.p.people) }
            for s in states { s.p.tagged = s.tagged; s.p.rating = s.rating; s.p.label = s.label; s.p.people = s.people }
            c.registerCullUndo(redo, name: name)
            c.culled(states.map { $0.p }, advance: false)
            // back to the photo it was about (after auto-advance you were already on the next one)
            if c.session.mode == .compare {
                if states.count == 1, let k = c.main.compare.photos.firstIndex(where: { $0 === states[0].p }) { c.main.compare.setActive(k) }
            } else if states.count == 1, let i = c.session.visible.firstIndex(where: { $0 === states[0].p }), i != c.session.currentIndex {
                c.setCurrent(i)
            }
        }
        cullUndo.setActionName(name)
    }

    /// Saves and redraws changed photos; a photo that no longer fits the filter drops out (the next one is then current).
    private func culled(_ ps: [Photo], advance: Bool) {
        session.recount()
        for p in ps {
            writer.schedule(p)
            main.grid.redraw(p)
        }
        main.loupe.updateInfo()
        if session.mode == .compare { main.compare.updateInfo() }
        if session.filtering {
            // a photo that no longer fits the filter drops out; one that fits again (undo) comes back
            var shown: Set<ObjectIdentifier>?
            let changes = ps.contains { p in
                let isShown: Bool
                if p === session.currentPhoto { isShown = true } else {
                    if shown == nil { shown = Set(session.visible.map { ObjectIdentifier($0) }) }
                    isShown = shown!.contains(ObjectIdentifier(p))
                }
                return session.passes(p) != isShown
            }
            if changes {
                session.rebuildVisible(keeping: session.currentPhoto)
                refreshAll()
                return
            }
        }
        if advance && ps.count == 1 {
            if session.mode == .compare { main.compare.setActive(main.compare.active + 1) } else { move(1) }
        }
    }

    func setOnlyTagged(_ on: Bool) {
        guard on != session.onlyTagged else { return }
        session.onlyTagged = on
        filterChanged()
    }

    /// At least n stars (0 = any). The same n again clears it.
    func setMinRating(_ n: Int) {
        session.minRating = session.minRating == n ? 0 : n
        filterChanged()
    }

    func setLabelFilter(_ l: ColorLabel?) {
        session.labelFilter = session.labelFilter == l ? nil : l
        filterChanged()
    }

    func clearFilters() {
        session.onlyTagged = false
        session.minRating = 0
        session.labelFilter = nil
        filterChanged()
    }

    private func filterChanged() {
        if session.scope == .shown && !session.filtering { session.scope = .tagged }
        session.rebuildVisible(keeping: session.currentPhoto)
        if session.visible.isEmpty && session.mode != .grid { session.mode = .grid; applyMode() }
        refreshAll()
    }

    func refreshAll() {
        main.grid.relayout()
        main.grid.scrollToCurrent()
        if session.mode == .loupe { showCurrent() }
        updatePrefetch()
    }

    func togglePanel() { main.panelVisible.toggle() }

    /// Copy selection as JPEG: the camera's own JPEG (or smaller), named, with the camera's EXIF and your fields.
    func exportJPEGs(rename: Bool, withMetadata: Bool) {
        let photos = scopePhotos
        guard !photos.isEmpty else { session.message = emptyScopeMessage; return }
        guard !pad.copyRoot.isEmpty else { chooseCopyRoot(); return }
        if rename && !namesReady([pad.v.fileTemplate]) { return }
        if pad.copyFolderOverride.trimmingCharacters(in: .whitespaces).isEmpty && !namesReady([pad.v.folderTemplate]) { return }
        if withMetadata && !ExifTool.shared.isAvailable { session.message = "exiftool is missing: export without metadata, or install exiftool."; return }
        if withMetadata && !metadataReady() { return }
        writer.flush(wait: true)
        let dest = URL(fileURLWithPath: pad.copyRoot).appendingPathComponent(pad.copyFolderName, isDirectory: true)
        let values = pad.v
        let edge = pad.jpegLongEdge > 0 ? pad.jpegLongEdge : nil
        let total = photos.count
        let start = nowMs()
        session.busy = "Exporting JPEGs: 0 / \(total)"
        DispatchQueue.global(qos: .userInitiated).async {
            let res = Export.run(photos, to: dest, name: { p, n in rename ? values.fileName(photo: p, seq: n) : nil }, longEdge: edge,
                                 progress: { done in DispatchQueue.main.async { [weak self] in self?.session.busy = "Exporting JPEGs: \(done) / \(total)" } },
                                 cancelled: { false })
            var metaFailed = 0
            if !res.done.isEmpty && ExifTool.shared.isAvailable {
                DispatchQueue.main.async { [weak self] in self?.session.busy = "Writing metadata into the JPEGs..." }
                let cmds = res.done.enumerated().map { i, item in
                    Export.metadataCommand(item, fields: withMetadata ? values.metadataArgs(photo: item.photo, seq: i + 1) : [])
                }
                metaFailed = ExifTool.shared.run(cmds).filter { !$0.ok }.count
            }
            let secs = (nowMs() - start) / 1000
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.session.busy = nil
                if withMetadata { self.pad.rememberVenue() }
                self.session.lastCopyFolder = dest
                var msg = "Exported \(res.done.count) JPEG\(res.done.count == 1 ? "" : "s") (\(String(format: "%.0f", Double(res.bytes) / 1_000_000)) MB) to \(dest.lastPathComponent) in \(String(format: "%.1f", secs)) s."
                if !res.skipped.isEmpty { msg += " Skipped \(res.skipped.count) that were already there." }
                if !res.errors.isEmpty { msg += " Errors: \(res.errors.prefix(3).joined(separator: "; "))" }
                if metaFailed > 0 { msg += " Metadata failed for \(metaFailed)." }
                self.session.message = msg
            }
        }
    }

    @objc func menuPeople(_ sender: Any?) { editPeople() }

    func chooseCodeFile() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.prompt = "Choose"
        p.message = "A text file with on each line a code, a tab and its text (as in Photo Mechanic)."
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = p.url, let self = self else { return }
            self.pad.codeFile = u.path
            self.session.message = "\(Codes.count) codes from \(u.lastPathComponent). Type \\code\\ in any field, or as the person in a photo (P)."
        }
    }

    @objc func menuCompare(_ sender: Any?) {
        if session.mode == .compare { leaveCompare(toLoupe: false) } else { compare() }
    }

    /// The venues you used before, under the mouse (the chevron next to Location).
    func showVenueMenu() {
        let menu = NSMenu()
        for v in pad.knownVenues {
            let item = NSMenuItem(title: v, action: #selector(pickVenue(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pickVenue(_ item: NSMenuItem) {
        if let v = item.representedObject as? String { pad.set("location", v) }
    }

    func changeThumbSize(_ delta: CGFloat) {
        main.grid.cellWidth = max(110, min(420, main.grid.cellWidth + delta))
        main.grid.scrollToCurrent()
    }

    func focusPhotos() {
        window.makeFirstResponder(session.mode == .loupe ? main.loupe as NSView : main.grid as NSView)
    }

    // MARK: checks

    var scopePhotos: [Photo] {
        switch session.scope {
        case .tagged: return session.photos.filter { $0.tagged }
        case .shown: return session.visible
        case .selected: return session.selectedPhotos
        case .all: return session.photos
        }
    }

    var emptyScopeMessage: String {
        switch session.scope {
        case .tagged: return "Nothing tagged yet."
        case .shown: return "No photos are shown."
        case .selected: return "Nothing selected."
        case .all: return "No photos."
        }
    }

    private func writable(_ what: String) -> Bool {
        if session.busy != nil || opening { return false }
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
        guard !photos.isEmpty else { session.message = emptyScopeMessage; return }
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
        guard !photos.isEmpty else { session.message = emptyScopeMessage; return }
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

    /// The second copy during an ingest, or none.
    func chooseBackupRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        p.message = "A second copy of every ingest goes here, on another disk: <job folder>/\(pad.v.rawFolder), with the same names."
        if !pad.backupRoot.isEmpty { p.directoryURL = URL(fileURLWithPath: pad.backupRoot) }
        p.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = p.url { self?.pad.backupRoot = u.path }
        }
    }

    var backupDestination: URL? {
        guard !pad.backupRoot.isEmpty else { return nil }
        return URL(fileURLWithPath: pad.backupRoot)
            .appendingPathComponent(pad.v.folderName, isDirectory: true)
            .appendingPathComponent(pad.v.rawFolder.isEmpty ? "raw" : safeFileName(pad.v.rawFolder), isDirectory: true)
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
        guard session.busy == nil, !opening else { return }
        var sources = session.photos
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
        // Incremental ingest: what was ingested before (from these cards, into any folder) is skipped.
        let history = IngestHistory.shared
        var skipped = 0
        if pad.skipIngested {
            let fresh = sources.filter { !history.contains($0) }
            skipped = sources.count - fresh.count
            if fresh.isEmpty {
                session.message = "All \(sources.count) photos were ingested before, so there is nothing new to copy. Turn off \"Skip photos ingested before\" to copy them again."
                return
            }
            sources = fresh
        }
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
        let backup = backupDestination
        if let b = backup {
            if b.path == dest.path || b.path.hasPrefix(dest.path + "/") || dest.path.hasPrefix(b.path + "/") {
                session.message = "The backup folder is inside the ingest folder: choose one on another disk."
                return
            }
            if !FileManager.default.fileExists(atPath: pad.backupRoot) {
                session.message = "The backup disk is not there (\((pad.backupRoot as NSString).abbreviatingWithTildeInPath)). Connect it, or choose another backup folder."
                return
            }
            let bfree = (try? URL(fileURLWithPath: pad.backupRoot).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
            if bfree > 0 && bytes > bfree {
                session.message = "Not enough space on the backup disk: the photos need \(gb(bytes)), there is \(gb(bfree)) free."
                return
            }
        }
        let verify = pad.verifyCopies
        let example = values.fileName(photo: sources.first, seq: 1) + "." + (sources.first?.url.pathExtension.lowercased() ?? "cr3")
        var text = "To \((dest.path as NSString).abbreviatingWithTildeInPath)\n\nNames like:\n\(example)\n\n\(gb(bytes))" + (free > 0 ? " (\(gb(free)) free)." : ".")
        if already > 0 { text += " \(already) photos are already there and are not copied again." }
        if skipped > 0 { text += "\n\n\(skipped) photos were ingested before and are skipped (incremental ingest)." }
        let marked = pad.priorityFirst ? sources.filter(Controller.isMarked).count : 0
        if marked > 0 && marked < sources.count { text += "\n\nThe \(marked) tagged, rated or labelled photos are copied first." }
        if let b = backup { text += "\n\nA second copy goes to \((b.path as NSString).abbreviatingWithTildeInPath)." }
        if verify { text += (backup == nil ? "\n\n" : " ") + "Every copy is read back and checked against the card." }
        text += " The cards stay untouched. You can start culling while it copies."
        if !missingMeta.isEmpty { text += "\n\nNote: \(missingMeta.joined(separator: ", ")) \(missingMeta.count == 1 ? "is" : "are") empty." }
        guard confirm("Ingest \(sources.count) photos?", text, "Ingest") else { return }

        let labels = values.labelNames
        // the cards to eject afterwards (when that is on): the open folders that are on a card
        var eject: [URL] = []
        if pad.ejectCards {
            for root in session.roots { if let v = CardWatcher.cardVolume(of: root), !eject.contains(v) { eject.append(v) } }
        }
        let priority: ((Photo) -> Bool)? = pad.priorityFirst ? Controller.isMarked : nil
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
        ingestedCount = 0
        let total = sources.count
        let start = nowMs()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The job folder's own photos (an earlier ingest of this job) are on screen first; the new ones
            // slot in between them in shooting order as they arrive.
            let existing = FileManager.default.fileExists(atPath: dest.path)
                ? Scanner.load(Scanner.group(Scanner.collectFiles([dest]))) { _ in } : []
            if !existing.isEmpty {
                DispatchQueue.main.sync { self?.showJobFolder(existing, dest: dest) }
            }
            let r = FileOps.ingest(sources, to: dest, name: { p, n in values.fileName(photo: p, seq: n) },
                                   metadata: { p in values.metadataArgs(photo: p, seq: 1) + Metadata.stateArgs(p, labelNames: labels) },
                                   cancelled: { self?.ingestCancelled ?? true },
                                   history: history, idBase: (existing.map { $0.id }.max() ?? -1) + 1, showReused: existing.isEmpty,
                                   priority: priority, backup: backup, verify: verify,
                                   onPhoto: { p in DispatchQueue.main.async { self?.ingested(p, total: total) } })
            let ms = nowMs() - start
            DispatchQueue.main.async { self?.ingestDone(r, dest: dest, ms: ms, skipped: skipped, eject: eject, backup: backup, verified: verify) }
        }
    }

    private var ingestedCount = 0

    /// An ingest into a job folder that already has photos: show those right away.
    private func showJobFolder(_ existing: [Photo], dest: URL) {
        var existing = existing
        if applyClocks(existing) { existing.sort(by: Session.before) }
        session.setPhotos(existing, roots: [dest])
        session.bodies = Controller.bodies(in: existing)
        session.title = "\(dest.deletingLastPathComponent().lastPathComponent)/\(dest.lastPathComponent)"
        main.grid.relayout()
        updatePrefetch()
    }

    func stopIngest() { ingestCancelled = true }

    private func ingested(_ p: Photo, total: Int) {
        if p.clockOffset == 0, let b = p.body, let o = pad.clockOffsets[b] { p.clockOffset = o }
        session.insertSorted(p)
        ingestedCount += 1
        session.busy = "Ingest: \(ingestedCount) / \(total)"
        main.grid.relayout()
        if ingestedCount <= 12 { updatePrefetch() }
    }

    private func ingestDone(_ r: IngestResult, dest: URL, ms: Double, skipped: Int = 0, eject: [URL] = [],
                            backup: URL? = nil, verified: Bool = false) {
        session.ingesting = false
        session.busy = nil
        session.bodies = Controller.bodies(in: session.photos)
        pad.rememberVenue()
        let secs = Int(ms / 1000)
        var msg = "Ingested \(r.copied) photo\(r.copied == 1 ? "" : "s") (\(String(format: "%.1f", Double(r.bytes) / 1_000_000_000)) GB) in \(secs / 60):\(String(format: "%02d", secs % 60))."
        if backup != nil && r.copied > 0 { msg += " A second copy is in the backup folder." }
        if verified && r.copied > 0 && r.errors.isEmpty { msg += " Every copy checked against the card." }
        if r.alreadyThere > 0 { msg += " \(r.alreadyThere) were already there." }
        if skipped > 0 { msg += " \(skipped) were ingested before and skipped." }
        if r.suffixed > 0 { msg += " \(r.suffixed) got -2 because the name was taken." }
        if ingestCancelled { msg += " Stopped before the end." }
        if r.diskFull {
            msg += " Stopped: \(r.errors.first ?? "the destination disk is full.")"
        } else if !r.errors.isEmpty {
            msg += " Problems: \(r.errors.prefix(3).joined(separator: "; "))"
        }
        if !eject.isEmpty {
            if ingestCancelled || r.diskFull || !r.errors.isEmpty {
                msg += " The card\(eject.count == 1 ? " stays" : "s stay") in, because not everything was copied."
            } else {
                ejectCards(eject)
            }
        }
        session.message = msg
        updatePrefetch()
    }

    /// Ejects the cards after an ingest (in the background: it can take a few seconds).
    private func ejectCards(_ volumes: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed: [String] = []
            for v in volumes {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: v) } catch { failed.append(v.lastPathComponent) }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let note = failed.isEmpty
                    ? (volumes.count == 1 ? "The card is ejected." : "The \(volumes.count) cards are ejected.")
                    : "Could not eject \(failed.joined(separator: ", ")): is it still open in another app?"
                self.session.message = (self.session.message.map { $0 + " " } ?? "") + note
            }
        }
    }

    /// Starts the ingest history over (the old one is kept under a dated name).
    func forgetIngestHistory() {
        let n = IngestHistory.shared.count
        guard confirm("Forget the ingest history?", "Pitpick remembers \(n) ingested photos, so it does not copy them again. After this, every photo on a card counts as new.", "Forget") else { return }
        IngestHistory.shared.forget()
        session.message = "The ingest history starts over. The old one is kept in ~/Library/Application Support/Pitpick."
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
        guard session.busy == nil, !opening else { return }
        if pad.copyFormat == 1 { exportJPEGs(rename: rename, withMetadata: withMetadata); return }
        let photos = scopePhotos
        guard !photos.isEmpty else { session.message = emptyScopeMessage; return }
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
