// The contact sheet: draws only what is visible and requests thumbnails for what comes next.
import AppKit

final class GridView: NSView {
    weak var controller: Controller?
    var cellWidth: CGFloat = 184 { didSet { relayout() } }
    let gap: CGFloat = 8
    let pad: CGFloat = 12
    let labelHeight: CGFloat = 20
    private(set) var columns = 1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var imageHeight: CGFloat { (cellWidth * 0.72).rounded() }
    var cellHeight: CGFloat { imageHeight + labelHeight + 6 }

    private var photos: [Photo] { controller?.session.visible ?? [] }

    func relayout() {
        guard let sv = enclosingScrollView else { return }
        let w = sv.contentSize.width
        columns = max(1, Int((w - pad * 2 + gap) / (cellWidth + gap)))
        let n = photos.count
        let rows = (n + columns - 1) / columns
        let h = max(sv.contentSize.height, pad * 2 + CGFloat(rows) * (cellHeight + gap))
        setFrameSize(NSSize(width: w, height: h))
        needsDisplay = true
        requestVisibleThumbs()
    }

    func cellRect(_ i: Int) -> CGRect {
        let totalW = CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap
        let x0 = max(pad, ((bounds.width - totalW) / 2).rounded())
        let r = i / columns, c = i % columns
        return CGRect(x: x0 + CGFloat(c) * (cellWidth + gap), y: pad + CGFloat(r) * (cellHeight + gap),
                      width: cellWidth, height: cellHeight)
    }

    func index(at p: CGPoint) -> Int? {
        let row = Int((p.y - pad) / (cellHeight + gap))
        guard row >= 0 else { return nil }
        let totalW = CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap
        let x0 = max(pad, ((bounds.width - totalW) / 2).rounded())
        let col = Int((p.x - x0) / (cellWidth + gap))
        guard col >= 0, col < columns else { return nil }
        let i = row * columns + col
        guard i < photos.count, cellRect(i).contains(p) else { return nil }
        return i
    }

    private func tagRect(_ cell: CGRect) -> CGRect {
        CGRect(x: cell.maxX - 26, y: cell.minY + 6, width: 20, height: 20)
    }

    /// Visible thumbnails first, then one screen below and one screen above.
    func requestVisibleThumbs() {
        guard let c = controller, !photos.isEmpty, c.session.mode == .grid else { return }
        let vr = visibleRect
        let rowH = cellHeight + gap
        func range(_ minY: CGFloat, _ maxY: CGFloat) -> ClosedRange<Int>? {
            let first = max(0, Int((minY - pad) / rowH)) * columns
            let last = min(photos.count - 1, (Int((maxY - pad) / rowH) + 1) * columns - 1)
            return first <= last ? first...last : nil
        }
        var refs: [SourceRef] = []
        var seen = Set<Int>()
        for r in [range(vr.minY, vr.maxY), range(vr.maxY, vr.maxY + vr.height), range(vr.minY - vr.height, vr.minY)] {
            guard let r = r else { continue }
            for i in r where !seen.contains(i) { seen.insert(i); refs.append(photos[i].ref) }
        }
        c.pipeline.requestThumbs(refs)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let c = controller else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(dirtyRect)
        let list = photos
        if list.isEmpty {
            drawEmpty(c)
            return
        }
        let rowH = cellHeight + gap
        let first = max(0, Int((dirtyRect.minY - pad) / rowH)) * columns
        let last = min(list.count - 1, (Int((dirtyRect.maxY - pad) / rowH) + 1) * columns - 1)
        guard first <= last else { return }
        for i in first...last {
            let r = cellRect(i)
            guard r.intersects(dirtyRect) else { continue }
            drawCell(ctx, list[i], r, current: i == c.session.currentIndex)
        }
    }

    private func drawEmpty(_ c: Controller) {
        let text: String
        if let l = c.session.loading { text = l }
        else if c.session.roots.isEmpty {
            text = c.cards.cards.isEmpty
                ? "Put in a memory card, or drop a folder here (File > Open Folder, ⌘O)"
                : "Your cards are at the top of the panel: View to look at them on the card, Ingest to copy them"
        }
        else if c.session.ingesting { text = "Copying the first photos..." }
        else { text = c.session.onlyTagged ? "Nothing tagged yet. Press T to tag, ⌘T shows everything again." : "No photos found in this folder." }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.6, alpha: 1)]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let vr = visibleRect
        s.draw(at: CGPoint(x: vr.midX - size.width / 2, y: vr.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawCell(_ ctx: CGContext, _ p: Photo, _ r: CGRect, current: Bool) {
        let bg = current ? NSColor(white: 0.26, alpha: 1) : NSColor(white: 0.09, alpha: 1)
        ctx.setFillColor(bg.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        let imgArea = CGRect(x: r.minX + 6, y: r.minY + 6, width: r.width - 12, height: imageHeight)
        if let t = controller?.pipeline.thumb(p.id) {
            let swap = Orientation.swapsAxes(p.orientation)
            let iw = CGFloat(swap ? t.image.height : t.image.width)
            let ih = CGFloat(swap ? t.image.width : t.image.height)
            let s = min(imgArea.width / iw, imgArea.height / ih)
            let dw = iw * s, dh = ih * s
            let target = CGRect(x: imgArea.midX - dw / 2, y: imgArea.midY - dh / 2, width: dw, height: dh)
            ctx.interpolationQuality = .medium
            drawImage(ctx, t.image, in: target, orientation: p.orientation)
            if let l = p.label {
                ctx.setFillColor(l.color.cgColor)
                ctx.fill(CGRect(x: target.minX, y: target.maxY - 4, width: target.width, height: 4))
            }
        }

        if p.tagged {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.5)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1.25, dy: 1.25), cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.strokePath()
        }
        drawTagBox(ctx, tagRect(r), on: p.tagged)

        // name and stars
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor(white: current ? 0.95 : 0.62, alpha: 1),
        ]
        let labelY = r.maxY - labelHeight - 1
        var nameX = r.minX + 7
        if p.rating > 0 {
            let stars = String(repeating: "★", count: p.rating) as NSString
            let sa: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor(white: 0.95, alpha: 1)]
            stars.draw(at: CGPoint(x: nameX, y: labelY + 3), withAttributes: sa)
            nameX += stars.size(withAttributes: sa).width + 6
        }
        let nameRect = CGRect(x: nameX, y: labelY + 3, width: r.maxX - 7 - nameX, height: 14)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        var na = nameAttrs
        na[.paragraphStyle] = style
        (p.name as NSString).draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: na)
    }

    private func drawTagBox(_ ctx: CGContext, _ r: CGRect, on: Bool) {
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        if on {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(2.2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: r.minX + 5, y: r.midY))
            ctx.addLine(to: CGPoint(x: r.minX + 8.5, y: r.maxY - 5.5))
            ctx.addLine(to: CGPoint(x: r.maxX - 4.5, y: r.minY + 5.5))
            ctx.strokePath()
        } else {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.55).cgColor)
            ctx.setLineWidth(1.2)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.6, dy: 0.6), cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
        }
    }

    func redraw(_ p: Photo) {
        guard let i = photos.firstIndex(where: { $0 === p }) else { return }
        setNeedsDisplay(cellRect(i).insetBy(dx: -3, dy: -3))
    }

    func redraw(index i: Int) {
        guard i >= 0, i < photos.count else { return }
        setNeedsDisplay(cellRect(i).insetBy(dx: -3, dy: -3))
    }

    func redrawThumb(id: Int) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let r = cellRect(i)
        if r.intersects(visibleRect) { setNeedsDisplay(r) }
    }

    func scrollToCurrent() {
        guard let c = controller, !photos.isEmpty else { return }
        scrollToVisible(cellRect(c.session.currentIndex).insetBy(dx: 0, dy: -gap))
    }

    // MARK: invoer

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        guard let c = controller, let i = index(at: p) else { return }
        if tagRect(cellRect(i)).insetBy(dx: -4, dy: -4).contains(p) {
            c.setCurrent(i)
            c.toggleTag()
            return
        }
        c.setCurrent(i)
        if e.clickCount == 2 { c.setMode(.loupe) }
    }

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return super.keyDown(with: e) }
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty {
            switch e.keyCode {
            case 123: c.move(-1); return
            case 124: c.move(1); return
            case 125: c.move(columns); return
            case 126: c.move(-columns); return
            case 115: c.setCurrent(0); return
            case 119: c.setCurrent(photos.count - 1); return
            case 116: c.move(-columns * max(1, Int(visibleRect.height / (cellHeight + gap)))); return
            case 121: c.move(columns * max(1, Int(visibleRect.height / (cellHeight + gap)))); return
            case 36, 76, 49: c.setMode(.loupe); return
            default: break
            }
        }
        if c.handleCommonKey(e) { return }
        super.keyDown(with: e)
    }
}

/// Draws a camera image upright into a (flipped) context.
func drawImage(_ ctx: CGContext, _ img: CGImage, in target: CGRect, orientation: Int) {
    ctx.saveGState()
    ctx.translateBy(x: target.midX, y: target.midY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.rotate(by: Orientation.angle(orientation))
    let swap = Orientation.swapsAxes(orientation)
    let w = swap ? target.height : target.width
    let h = swap ? target.width : target.height
    ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    ctx.restoreGState()
}
