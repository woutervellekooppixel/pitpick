// One photo filling the screen. Click or Z/space = 100% at that spot, drag = pan.
// The image is a CALayer with the decoded image as its contents: switching costs almost nothing.
import AppKit
import QuartzCore

final class LoupeView: NSView {
    weak var controller: Controller?

    private let root = CALayer()
    private let imageLayer = CALayer()
    private let infoLayer = CATextLayer()
    private let badgeLayer = CALayer()
    private let checkLayer = CAShapeLayer()
    private let starsLayer = CATextLayer()
    private let labelLayer = CALayer()
    private let hintLayer = CATextLayer()
    private let barLayer = CALayer()

    private(set) var photoID: Int?
    private var orientation = 1
    private var fullSize = CGSize.zero
    private(set) var zoomed = false
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var dragStart: CGPoint?
    private var dragMoved = false
    private var dragCenterStart = CGPoint.zero

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.backgroundColor = NSColor.black.cgColor
        let noAnim: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                          "transform": NSNull(), "hidden": NSNull(), "string": NSNull(),
                                          "frame": NSNull(), "path": NSNull(), "backgroundColor": NSNull()]
        for l in [imageLayer, barLayer, infoLayer, badgeLayer, checkLayer, starsLayer, labelLayer, hintLayer] as [CALayer] {
            l.actions = noAnim
            root.addSublayer(l)
        }
        barLayer.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear

        for t in [infoLayer, starsLayer, hintLayer] {
            t.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            t.fontSize = 13
            t.foregroundColor = NSColor(white: 0.85, alpha: 1).cgColor
            t.truncationMode = .middle
        }
        starsLayer.fontSize = 17
        starsLayer.foregroundColor = NSColor.white.cgColor
        starsLayer.alignmentMode = .right
        hintLayer.alignmentMode = .center
        hintLayer.foregroundColor = NSColor(white: 0.7, alpha: 1).cgColor

        badgeLayer.cornerRadius = 7
        badgeLayer.borderWidth = 2
        checkLayer.fillColor = nil
        checkLayer.strokeColor = NSColor.black.cgColor
        checkLayer.lineWidth = 3.4
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        labelLayer.cornerRadius = 4
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [root, imageLayer, barLayer, infoLayer, badgeLayer, checkLayer, starsLayer, labelLayer, hintLayer] as [CALayer] { l.contentsScale = s }
    }

    // MARK: tonen

    func clear() {
        photoID = nil
        imageLayer.contents = nil
        fullSize = .zero
        relayout()
        updateInfo()
    }

    /// Shows the best image available now. For the same photo, only a sharper one replaces it.
    func show(_ p: Photo, image: Decoded?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let samePhoto = photoID == p.id
        photoID = p.id
        orientation = p.orientation
        if let d = image {
            // an IOSurface (libjpeg-turbo) is shown without a copy; screenshots need the CGImage
            imageLayer.contents = (Snapshot.capturing ? nil : d.surface) ?? d.image
            // thumbnails only know the aspect ratio; keep the last full size if it matches
            if d.isFull || d.fullSize.width >= 2000 || fullSize == .zero || !sameAspect(d.fullSize, fullSize) {
                fullSize = d.fullSize
            }
        } else if !samePhoto {
            imageLayer.contents = nil
        }
        CATransaction.commit()
        relayout()
        updateInfo()
    }

    private func sameAspect(_ a: CGSize, _ b: CGSize) -> Bool {
        guard a.height > 0, b.height > 0 else { return false }
        return abs(a.width / a.height - b.width / b.height) < 0.01
    }

    private var displayedPixelSize: CGSize {
        Orientation.swapsAxes(orientation) ? CGSize(width: fullSize.height, height: fullSize.width) : fullSize
    }

    private var pointsPerPixel: CGFloat {
        if zoomed { return 1 / (window?.backingScaleFactor ?? 2) }
        let d = displayedPixelSize
        guard d.width > 0, d.height > 0 else { return 1 }
        let avail = bounds.insetBy(dx: 6, dy: 6)
        return min(avail.width / d.width, avail.height / d.height)
    }

    /// Where the image sits in fit view (for clicks).
    private var fitRect: CGRect {
        let d = displayedPixelSize
        guard d.width > 0 else { return .zero }
        let avail = bounds.insetBy(dx: 6, dy: 6)
        let s = min(avail.width / d.width, avail.height / d.height)
        let w = d.width * s, h = d.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = bounds
        layoutOverlay()
        guard fullSize.width > 0, imageLayer.contents != nil else {
            imageLayer.isHidden = true
            return
        }
        imageLayer.isHidden = false
        let s = pointsPerPixel
        let d = displayedPixelSize
        let dw = d.width * s, dh = d.height * s
        let swap = Orientation.swapsAxes(orientation)
        imageLayer.setAffineTransform(.identity)
        imageLayer.bounds = CGRect(x: 0, y: 0, width: swap ? dh : dw, height: swap ? dw : dh)
        var pos = CGPoint(x: b.midX, y: b.midY)
        if zoomed {
            pos.x = b.midX + (0.5 - zoomCenter.x) * dw
            pos.y = b.midY + (0.5 - zoomCenter.y) * dh
            pos.x = dw > b.width ? min(max(pos.x, b.maxX - dw / 2), b.minX + dw / 2) : b.midX
            pos.y = dh > b.height ? min(max(pos.y, b.maxY - dh / 2), b.minY + dh / 2) : b.midY
            zoomCenter = CGPoint(x: 0.5 - (pos.x - b.midX) / dw, y: 0.5 - (pos.y - b.midY) / dh)
        }
        imageLayer.position = pos
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: Orientation.angle(orientation)))
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func layoutOverlay() {
        let b = bounds
        barLayer.frame = CGRect(x: 0, y: 0, width: b.width, height: 38)
        infoLayer.frame = CGRect(x: 14, y: 10, width: max(0, b.width - 200), height: 20)
        badgeLayer.frame = CGRect(x: b.maxX - 50, y: b.maxY - 50, width: 36, height: 36)
        checkLayer.frame = badgeLayer.frame
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 9, y: 18))
        path.addLine(to: CGPoint(x: 15, y: 11))
        path.addLine(to: CGPoint(x: 27, y: 25))
        checkLayer.path = path
        starsLayer.frame = CGRect(x: b.maxX - 230, y: 8, width: 200, height: 24)
        labelLayer.frame = CGRect(x: b.maxX - 26, y: 12, width: 14, height: 14)
        hintLayer.frame = CGRect(x: 0, y: b.midY - 10, width: b.width, height: 22)
    }

    func updateInfo() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let c = controller, let p = c.session.currentPhoto, p.id == photoID else {
            infoLayer.string = ""
            starsLayer.string = ""
            badgeLayer.isHidden = true
            checkLayer.isHidden = true
            labelLayer.isHidden = true
            hintLayer.string = controller?.session.visible.isEmpty == false ? "" : "No photo"
            return
        }
        hintLayer.string = imageLayer.contents == nil ? "Loading..." : ""
        let when = ExifDate.displayFormatter.string(from: p.captureDate)
        var info = "\(c.session.currentIndex + 1) / \(c.session.visible.count)     \(p.name)     \(when)"
        if zoomed { info += "     100%" }
        infoLayer.string = info
        starsLayer.string = p.rating > 0 ? String(repeating: "★", count: p.rating) : ""
        badgeLayer.isHidden = false
        badgeLayer.backgroundColor = p.tagged ? NSColor.white.cgColor : NSColor(white: 0, alpha: 0.4).cgColor
        badgeLayer.borderColor = p.tagged ? NSColor.white.cgColor : NSColor(white: 1, alpha: 0.6).cgColor
        checkLayer.isHidden = !p.tagged
        if let l = p.label {
            labelLayer.isHidden = false
            labelLayer.backgroundColor = l.color.cgColor
            starsLayer.frame.origin.x = bounds.maxX - 240
        } else {
            labelLayer.isHidden = true
            starsLayer.frame.origin.x = bounds.maxX - 220
        }
    }

    // MARK: zoom

    func setZoom(_ on: Bool, at viewPoint: CGPoint?) {
        guard on != zoomed else { return }
        if on {
            let fr = fitRect
            let pt = viewPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
            var u = CGPoint(x: 0.5, y: 0.5)
            if fr.width > 0, fr.contains(pt) {
                u = CGPoint(x: (pt.x - fr.minX) / fr.width, y: (pt.y - fr.minY) / fr.height)
            }
            zoomed = true
            let d = displayedPixelSize
            let s = pointsPerPixel
            let dw = d.width * s, dh = d.height * s
            if dw > 0, dh > 0 {
                zoomCenter = CGPoint(x: u.x - (pt.x - bounds.midX) / dw, y: u.y - (pt.y - bounds.midY) / dh)
            }
        } else {
            zoomed = false
        }
        relayout()
        updateInfo()
        controller?.zoomChanged()
    }

    func mouseLocationInView() -> CGPoint? {
        guard let w = window else { return nil }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2 && !zoomed {
            controller?.setMode(.grid)
            return
        }
        dragStart = p
        dragMoved = false
        dragCenterStart = zoomCenter
        if !zoomed { setZoom(true, at: p) ; dragCenterStart = zoomCenter; dragMoved = true }
    }

    override func mouseDragged(with e: NSEvent) {
        guard zoomed, let start = dragStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        let d = displayedPixelSize
        let s = pointsPerPixel
        let dw = d.width * s, dh = d.height * s
        guard dw > 0, dh > 0 else { return }
        if abs(p.x - start.x) + abs(p.y - start.y) > 3 { dragMoved = true }
        zoomCenter = CGPoint(x: dragCenterStart.x - (p.x - start.x) / dw, y: dragCenterStart.y - (p.y - start.y) / dh)
        relayout()
    }

    override func mouseUp(with e: NSEvent) {
        defer { dragStart = nil }
        guard dragStart != nil else { return }
        if zoomed && !dragMoved { setZoom(false, at: nil) }
    }

    override func scrollWheel(with e: NSEvent) {
        guard zoomed else { return super.scrollWheel(with: e) }
        let d = displayedPixelSize
        let s = pointsPerPixel
        let dw = d.width * s, dh = d.height * s
        guard dw > 0, dh > 0 else { return }
        zoomCenter.x -= e.scrollingDeltaX / dw
        zoomCenter.y += e.scrollingDeltaY / dh
        relayout()
    }

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return super.keyDown(with: e) }
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty {
            switch e.keyCode {
            case 123, 126: c.move(-1); return
            case 124, 125: c.move(1); return
            case 115: c.setCurrent(0); return
            case 119: c.setCurrent(c.session.visible.count - 1); return
            case 36, 76:
                if zoomed { setZoom(false, at: nil) } else { c.setMode(.grid) }
                return
            case 53:
                if zoomed { setZoom(false, at: nil) } else { c.setMode(.grid) }
                return
            case 49:
                setZoom(!zoomed, at: mouseLocationInView())
                return
            default: break
            }
            if e.charactersIgnoringModifiers?.lowercased() == "z" {
                setZoom(!zoomed, at: mouseLocationInView())
                return
            }
        }
        if c.handleCommonKey(e) { return }
        super.keyDown(with: e)
    }

    /// For the self test: the geometry as it is on screen now.
    var debugGeometry: (bounds: CGRect, position: CGPoint, transform: CGAffineTransform, contents: Bool) {
        (imageLayer.bounds, imageLayer.position, imageLayer.affineTransform(), imageLayer.contents != nil)
    }
}
