// Two to four photos side by side, to pick the best of a burst. Zoom and pan are linked: space or a click shows
// every photo at 100% on the same spot, and dragging moves them together. Keys work on the active photo (white frame).
import AppKit

final class CompareView: NSView {
    weak var controller: Controller?
    /// ⌘Z on the photos undoes tags, stars and labels.
    override var undoManager: UndoManager? { controller?.cullUndo ?? super.undoManager }
    @objc func undo(_ sender: Any?) { controller?.cullUndo.undo() }
    @objc func redo(_ sender: Any?) { controller?.cullUndo.redo() }

    private final class Pane {
        let clip = CALayer()        // the pane: clips its photo when zoomed in
        let image = CALayer()
        let frame = CAShapeLayer()  // white frame: the active photo
        let info = CATextLayer()
        var photo: Photo?
        var fullSize = CGSize.zero
        var orientation = 1
        var rect = CGRect.zero
    }

    private var panes: [Pane] = []
    private(set) var photos: [Photo] = []
    private(set) var active = 0
    private(set) var zoomed = false
    /// The same spot in every photo, as a fraction of the image (0.5, 0.5 is the middle).
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var dragStart: CGPoint?
    private var dragCenterStart = CGPoint.zero
    private var dragMoved = false
    private let noAnim: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                                              "transform": NSNull(), "hidden": NSNull(), "string": NSNull(), "path": NSNull()]

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var activePhoto: Photo? { photos.indices.contains(active) ? photos[active] : nil }

    /// Shows these photos, at fit size, with one of them active.
    func show(_ ps: [Photo], active a: Int) {
        photos = ps
        active = max(0, min(ps.count - 1, a))
        zoomed = false
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
        panes.forEach { $0.clip.removeFromSuperlayer() }
        panes = ps.map { p in
            let pane = Pane()
            pane.photo = p
            pane.orientation = p.orientation
            pane.clip.masksToBounds = true
            pane.clip.actions = noAnim
            pane.image.actions = noAnim
            pane.frame.actions = noAnim
            pane.info.actions = noAnim
            pane.frame.fillColor = nil
            pane.frame.strokeColor = NSColor.white.cgColor
            pane.frame.lineWidth = 2
            pane.info.fontSize = 12
            pane.info.foregroundColor = NSColor(white: 0.92, alpha: 1).cgColor
            pane.info.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
            pane.info.cornerRadius = 4
            pane.info.contentsScale = window?.backingScaleFactor ?? 2
            pane.clip.addSublayer(pane.image)
            pane.clip.addSublayer(pane.info)
            pane.clip.addSublayer(pane.frame)
            layer?.addSublayer(pane.clip)
            return pane
        }
        refresh()
    }

    func setActive(_ i: Int) {
        guard !photos.isEmpty else { return }
        active = max(0, min(photos.count - 1, i))
        relayout()
    }

    /// The best image there is for each photo: 100% when zoomed, else the screen image, the stand-in or the thumbnail.
    func refresh() {
        guard let c = controller else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pane in panes {
            guard let p = pane.photo else { continue }
            let full = zoomed ? c.pipeline.full(p.id) : nil
            if let d = full ?? c.pipeline.screen(p.id) ?? c.pipeline.preview(p.id) ?? c.pipeline.thumb(p.id) {
                pane.image.contents = (Snapshot.capturing ? nil : d.surface) ?? d.image
                if d.isFull || d.fullSize.width >= 2000 || pane.fullSize == .zero { pane.fullSize = d.fullSize }
            }
        }
        CATransaction.commit()
        updateInfo()
    }

    /// A new image for one photo is ready.
    func refresh(id: Int) {
        if panes.contains(where: { $0.photo?.id == id }) { refresh() }
    }

    /// 2 side by side, 3 or 4 in two rows.
    private func paneRects() -> [CGRect] {
        let b = bounds, n = panes.count, gap: CGFloat = 4
        guard n > 0 else { return [] }
        if n <= 2 {
            let w = (b.width - gap * CGFloat(n - 1)) / CGFloat(n)
            return (0..<n).map { CGRect(x: b.minX + CGFloat($0) * (w + gap), y: b.minY, width: w, height: b.height) }
        }
        let w = (b.width - gap) / 2, h = (b.height - gap) / 2
        return (0..<n).map { i in
            let col = i % 2, row = i / 2
            return CGRect(x: b.minX + CGFloat(col) * (w + gap), y: b.maxY - CGFloat(row + 1) * h - CGFloat(row) * gap, width: w, height: h)
        }
    }

    private func displayed(_ pane: Pane) -> CGSize {
        Orientation.swapsAxes(pane.orientation) ? CGSize(width: pane.fullSize.height, height: pane.fullSize.width) : pane.fullSize
    }

    private func scale(_ pane: Pane) -> CGFloat {
        if zoomed { return 1 / (window?.backingScaleFactor ?? 2) }
        let d = displayed(pane)
        guard d.width > 0, d.height > 0 else { return 1 }
        let avail = CGRect(origin: .zero, size: pane.rect.size).insetBy(dx: 4, dy: 4)
        return min(avail.width / d.width, avail.height / d.height)
    }

    func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (i, (pane, r)) in zip(panes, paneRects()).enumerated() {
            pane.rect = r
            pane.clip.frame = r
            let local = CGRect(origin: .zero, size: r.size)
            pane.frame.path = i == active && panes.count > 1 ? CGPath(rect: local.insetBy(dx: 1, dy: 1), transform: nil) : nil
            layoutInfo(pane, in: local)
            guard pane.fullSize.width > 0, pane.image.contents != nil else { pane.image.isHidden = true; continue }
            pane.image.isHidden = false
            let s = scale(pane), d = displayed(pane)
            let dw = d.width * s, dh = d.height * s
            let swap = Orientation.swapsAxes(pane.orientation)
            pane.image.setAffineTransform(.identity)
            pane.image.bounds = CGRect(x: 0, y: 0, width: swap ? dh : dw, height: swap ? dw : dh)
            var pos = CGPoint(x: local.midX, y: local.midY)
            if zoomed {
                pos.x = local.midX + (0.5 - zoomCenter.x) * dw
                pos.y = local.midY + (0.5 - zoomCenter.y) * dh
                pos.x = dw > local.width ? min(max(pos.x, local.maxX - dw / 2), local.minX + dw / 2) : local.midX
                pos.y = dh > local.height ? min(max(pos.y, local.maxY - dh / 2), local.minY + dh / 2) : local.midY
            }
            pane.image.position = pos
            pane.image.setAffineTransform(CGAffineTransform(rotationAngle: Orientation.angle(pane.orientation)))
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()

    /// Name, time to the hundredth (bursts), tag, stars and label at the top of each photo.
    private func layoutInfo(_ pane: Pane, in local: CGRect) {
        let text = (pane.info.string as? String) ?? ""
        let w = min(local.width - 16, CGFloat(text.count) * 7.2 + 8)
        pane.info.frame = CGRect(x: 8, y: local.maxY - 28, width: w, height: 19)
        pane.info.isHidden = text.isEmpty
    }

    /// The texts above the photos (after a tag, stars or a label).
    func updateInfo() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pane in panes {
            guard let p = pane.photo else { continue }
            var parts: [String] = []
            if p.tagged { parts.append("✓ Tagged") }
            if p.rating > 0 { parts.append(String(repeating: "★", count: p.rating)) }
            if let l = p.label { parts.append(l.englishName) }
            CompareView.timeFormatter.timeZone = p.captureZone ?? .current
            parts.append(p.name)
            parts.append(CompareView.timeFormatter.string(from: p.captureDate))
            pane.info.string = "  " + parts.joined(separator: "   ") + "  "
        }
        CATransaction.commit()
        relayout()
    }

    // MARK: zoom, pan, keys

    private func paneIndex(at p: CGPoint) -> Int? { panes.firstIndex { $0.rect.contains(p) } }

    func setZoom(_ on: Bool, at viewPoint: CGPoint?) {
        guard on != zoomed else { return }
        if on, let pt = viewPoint, let i = paneIndex(at: pt) {
            // the spot under the mouse, in that photo, becomes the spot shown in all of them
            let pane = panes[i]
            let s = scale(pane), d = displayed(pane)
            let dw = d.width * s, dh = d.height * s
            if dw > 0, dh > 0 {
                let local = CGPoint(x: pt.x - pane.rect.minX, y: pt.y - pane.rect.minY)
                let fit = CGRect(x: pane.rect.width / 2 - dw / 2, y: pane.rect.height / 2 - dh / 2, width: dw, height: dh)
                if fit.contains(local) {
                    zoomCenter = CGPoint(x: (local.x - fit.minX) / dw, y: (local.y - fit.minY) / dh)
                }
            }
        } else if on {
            zoomCenter = CGPoint(x: 0.5, y: 0.5)
        }
        zoomed = on
        refresh()
        controller?.zoomChanged()
    }

    private func mouseInView() -> CGPoint? {
        guard let w = window else { return nil }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if let i = paneIndex(at: p), i != active { setActive(i) }
        if e.clickCount == 2 && !zoomed { controller?.leaveCompare(toLoupe: true); return }
        dragStart = p
        dragMoved = false
        dragCenterStart = zoomCenter
        if !zoomed { setZoom(true, at: p); dragCenterStart = zoomCenter; dragMoved = true }
    }

    override func mouseDragged(with e: NSEvent) {
        guard zoomed, let start = dragStart, let pane = panes.indices.contains(active) ? panes[active] : nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        let s = scale(pane), d = displayed(pane)
        let dw = d.width * s, dh = d.height * s
        guard dw > 0, dh > 0 else { return }
        if abs(p.x - start.x) + abs(p.y - start.y) > 3 { dragMoved = true }
        zoomCenter = CGPoint(x: min(1, max(0, dragCenterStart.x - (p.x - start.x) / dw)),
                             y: min(1, max(0, dragCenterStart.y - (p.y - start.y) / dh)))
        relayout()
    }

    override func mouseUp(with e: NSEvent) {
        defer { dragStart = nil }
        guard dragStart != nil else { return }
        if zoomed && !dragMoved { setZoom(false, at: nil) }
    }

    override func scrollWheel(with e: NSEvent) {
        guard zoomed, let pane = panes.indices.contains(active) ? panes[active] : nil else { return super.scrollWheel(with: e) }
        let s = scale(pane), d = displayed(pane)
        let dw = d.width * s, dh = d.height * s
        guard dw > 0, dh > 0 else { return }
        zoomCenter.x = min(1, max(0, zoomCenter.x - e.scrollingDeltaX / dw))
        zoomCenter.y = min(1, max(0, zoomCenter.y + e.scrollingDeltaY / dh))
        relayout()
    }

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return super.keyDown(with: e) }
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty {
            switch e.keyCode {
            case 123, 126: setActive(active - 1); return          // ← ↑: the previous photo becomes active
            case 124, 125: setActive(active + 1); return          // → ↓: the next one
            case 36, 76: c.leaveCompare(toLoupe: true); return     // return: this photo in the loupe
            case 53:
                if zoomed { setZoom(false, at: nil) } else { c.leaveCompare(toLoupe: false) }
                return
            case 49: setZoom(!zoomed, at: mouseInView()); return
            default: break
            }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "z": setZoom(!zoomed, at: mouseInView()); return
            case "c": c.leaveCompare(toLoupe: false); return
            default: break
            }
        }
        if c.handleCommonKey(e) { return }
        super.keyDown(with: e)
    }
}

extension CompareView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool { controller?.validateCullMenu(item) ?? true }
}
