// Pitpick (formerly Snelkeus): fast culling, IPTC metadata and renaming. Nothing else.
import AppKit

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

let launchArgs = CommandLine.arguments
if let i = launchArgs.firstIndex(of: "--selftest") { exit(SelfTest.run(Array(launchArgs[(i + 1)...]))) }
if let i = launchArgs.firstIndex(of: "--bench") { exit(Bench.run(Array(launchArgs[(i + 1)...]))) }
if let i = launchArgs.firstIndex(of: "--bench-ingest") { exit(Bench.ingest(Array(launchArgs[(i + 1)...]))) }

extension Controller {
    @objc func menuOpen(_ sender: Any?) { chooseFolder() }
    @objc func menuReload(_ sender: Any?) { reopen() }
    @objc func menuImportPreset(_ sender: Any?) { chooseImportPreset() }
    @objc func menuExportPreset(_ sender: Any?) { chooseExportPreset() }
    @objc func menuOnlyTagged(_ sender: Any?) { setOnlyTagged(!session.onlyTagged) }
    @objc func menuMinRating(_ sender: NSMenuItem) { setMinRating(sender.tag) }
    @objc func menuClearFilters(_ sender: Any?) { clearFilters() }
    @objc func menuAutoAdvance(_ sender: Any?) { autoAdvance.toggle() }
    @objc func menuBigger(_ sender: Any?) { changeThumbSize(32) }
    @objc func menuSmaller(_ sender: Any?) { changeThumbSize(-32) }
    @objc func menuPanel(_ sender: Any?) { togglePanel() }
    @objc func menuGridLoupe(_ sender: Any?) { setMode(session.mode == .grid ? .loupe : .grid) }
    @objc func menuNewJob(_ sender: Any?) { pad.newJob() }
}

enum Menus {
    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject?,
                             _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }

    static func build(_ c: Controller) -> NSMenu {
        let bar = NSMenu()

        let app = NSMenu(title: "Pitpick")
        app.addItem(item("About Pitpick", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", nil))
        app.addItem(.separator())
        app.addItem(item("Hide Pitpick", #selector(NSApplication.hide(_:)), "h", nil))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", nil, [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", nil))
        app.addItem(.separator())
        app.addItem(item("Quit Pitpick", #selector(NSApplication.terminate(_:)), "q", nil))

        let file = NSMenu(title: "File")
        file.addItem(item("Open Folder…", #selector(Controller.menuOpen(_:)), "o", c))
        file.addItem(item("Reload", #selector(Controller.menuReload(_:)), "r", c))
        file.addItem(.separator())
        file.addItem(item("New Job", #selector(Controller.menuNewJob(_:)), "n", c))
        file.addItem(item("Load Preset…", #selector(Controller.menuImportPreset(_:)), "", c))
        file.addItem(item("Save Preset…", #selector(Controller.menuExportPreset(_:)), "", c))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", nil))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z", nil))
        edit.addItem(item("Redo", Selector(("redo:")), "z", nil, [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", nil))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", nil))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", nil))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", nil))

        let view = NSMenu(title: "View")
        view.addItem(item("Grid or Loupe (↩)", #selector(Controller.menuGridLoupe(_:)), "", c))
        view.addItem(item("Tagged Only", #selector(Controller.menuOnlyTagged(_:)), "t", c))
        view.addItem(item("Compare Side by Side (C)", #selector(Controller.menuCompare(_:)), "", c))
        view.addItem(item("Person Shown in This Photo… (P)", #selector(Controller.menuPeople(_:)), "", c))
        for n in 1...5 {
            let i = item(n == 5 ? "Five Stars" : "\(n) Star\(n == 1 ? "" : "s") or More", #selector(Controller.menuMinRating(_:)), "\(n)", c, [.command, .option])
            i.tag = n
            view.addItem(i)
        }
        view.addItem(item("Show All (Clear Filters)", #selector(Controller.menuClearFilters(_:)), "0", c, [.command, .option]))
        view.addItem(item("Next Photo After Tagging (or Caps Lock)", #selector(Controller.menuAutoAdvance(_:)), "", c))
        view.addItem(.separator())
        view.addItem(item("Larger Thumbnails", #selector(Controller.menuBigger(_:)), "+", c))
        let eq = item("Larger Thumbnails", #selector(Controller.menuBigger(_:)), "=", c)
        eq.isHidden = true
        eq.allowsKeyEquivalentWhenHidden = true
        view.addItem(eq)
        view.addItem(item("Smaller Thumbnails", #selector(Controller.menuSmaller(_:)), "-", c))
        view.addItem(item("Show or Hide Panel (⇥)", #selector(Controller.menuPanel(_:)), "", c))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", nil, [.command, .control]))

        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.miniaturize(_:)), "m", nil))
        NSApp.windowsMenu = win

        for m in [app, file, edit, view, win] {
            let top = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            top.submenu = m
            bar.addItem(top)
        }
        return bar
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller?
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.fromSnelkeus()
        let c = Controller()
        controller = c
        c.buildWindow()
        NSApp.mainMenu = Menus.build(c)
        NSApp.activate(ignoringOtherApps: true)
        if let i = launchArgs.firstIndex(of: "--snapshot") {
            Snapshot.start(c, args: Array(launchArgs[(i + 1)...]))
            return
        }
        if let i = launchArgs.firstIndex(of: "--snapshot-ingest") {
            Snapshot.startIngest(c, args: Array(launchArgs[(i + 1)...]))
            return
        }
        let given = launchArgs.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        let all = pendingOpen + given
        pendingOpen = []
        if !all.isEmpty { c.openOrImport(all) }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let c = controller { c.openOrImport(urls) } else { pendingOpen += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let c = controller, !c.leavingCardIsOK("Quit") { return .terminateCancel }
        controller?.writer.flush(wait: true)
        ExifTool.shared.stop()
        return .terminateNow
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
