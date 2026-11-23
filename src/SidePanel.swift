// The side panel: this job's fields, ingest, write/rename, copy the selection, and the metadata template.
import SwiftUI

/// Follows the counters (a tag, the selection) without rebuilding the whole panel.
private struct WithCounts<Content: View>: View {
    @ObservedObject var counts: Counts
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

struct SidePanel: View {
    @ObservedObject var session: Session
    @ObservedObject var pad: Pad
    @ObservedObject var cards: CardWatcher
    let controller: Controller
    @State private var copyRename = true
    @State private var copyMetadata = true
    @State private var showTemplate = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !cards.cards.isEmpty { cardsSection }
                if session.readOnly { banner }
                if let b = session.busy { busy(b) }
                jobSection
                ingestSection
                if session.bodies.count > 1 || session.bodies.contains(where: { pad.clockOffsets[$0.id] != nil }) {
                    ClocksSection(bodies: session.bodies, offsets: pad.clockOffsets, controller: controller)
                }
                applySection
                copySection
                if let m = session.message {
                    Text(m)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                templateSection
                    .id("template")
                legend
            }
            .padding(16)
            .onChange(of: session.openTemplate) { _, open in
                guard open else { return }
                session.openTemplate = false
                showTemplate = true
                withAnimation { proxy.scrollTo("template", anchor: .top) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(white: 0.105))
        .environment(\.colorScheme, .dark)
        }
    }

    // MARK: building blocks

    private func title(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { pad.get(key) }, set: { pad.set(key, $0) })
    }

    private func fieldRow(_ f: FieldDef) -> some View {
        HStack(spacing: 6) {
            Text(f.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)
            TextField(f.list ? "\(f.label) (separate with ;)" : f.label, text: binding(f.key))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { controller.focusPhotos() }
                .onExitCommand { controller.focusPhotos() }
            if f.key == "location" && !pad.knownVenues.isEmpty {
                // drawn by SwiftUI itself; the menu is AppKit's, built when you click (a SwiftUI Menu is measured
                // again with every update of the panel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.showVenueMenu() }
            }
            Image(systemName: pad.pinned.contains(f.key) ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(pad.pinned.contains(f.key) ? .primary : .secondary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .onTapGesture { pad.togglePin(f.key) }
            .help(pad.pinned.contains(f.key)
                  ? "Kept for every job. Click to make it a per-job field."
                  : "Starts empty for every new job. Click to keep the value.")
        }
    }

    private func preview(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            if let l = session.loading {
                Text(l).foregroundStyle(.secondary)
            } else if !session.photos.isEmpty {
                WithCounts(counts: session.counts) {
                    Text("\(session.photos.count) photos · \(session.taggedCount) tagged"
                         + (session.filtering ? " · \(session.visible.count) shown" : "")
                         + (session.selection.count > 1 ? " · \(session.selection.count) selected" : ""))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button("Open…") { controller.chooseFolder() }
                Toggle("Tagged only", isOn: Binding(get: { session.onlyTagged }, set: { controller.setOnlyTagged($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(session.photos.isEmpty)
            }
            FilterBar(minRating: session.minRating, label: session.labelFilter?.rawValue ?? 0,
                      filtering: session.filtering, disabled: session.photos.isEmpty, controller: controller)
        }
    }

    private var banner: some View {
        Text(session.onCard || session.lockedVolume
             ? "On the card: Pitpick writes nothing on it. Tags, stars and labels stay in Pitpick and go along with the ingest."
             : "Read-only folder: view and copy only. Tags are not saved here.")
            .font(.system(size: 12))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
    }

    private func busy(_ b: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(b).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if session.ingesting { Button("Stop") { controller.stopIngest() } }
        }
    }

    private func cardDetail(_ c: Card) -> String {
        let gb = String(format: "%.1f GB", Double(c.usedBytes) / 1_000_000_000)
        let photos = c.photos.map { "\($0) photo\($0 == 1 ? "" : "s")" } ?? "counting…"
        return photos + " · " + gb + (c.locked ? " · locked" : "")
    }

    /// Cards that are in: checked when they go in. View = cull on the card, Ingest = copy them first.
    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            title("Cards")
            ForEach(cards.cards) { c in
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { c.checked }, set: { cards.setChecked(c.id, $0) })) {
                        Text(c.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    Spacer(minLength: 4)
                    Text(cardDetail(c)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Toggle("Photos protected in the camera are tagged", isOn: Binding(get: { pad.protectedIsTagged }, set: { controller.setProtectedIsTagged($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Protect your best photos in the camera during the show: they are tagged here, and with \"Tagged and rated photos first\" they are copied first.")
            HStack(spacing: 8) {
                Button("View") { controller.viewCards() }
                    .help("Look at the checked cards here, on the card. Pitpick writes nothing on them.")
                Button("Ingest") { controller.ingestCards() }
                    .help("Copy the checked cards to your ingest folder, named and with metadata. You can cull while it copies.")
            }
            .disabled(cards.checked.isEmpty || session.busy != nil)
        }
    }

    private var jobSection: some View {
        let v = pad.v
        let first = session.photos.first
        let ext = first.map { "." + $0.url.pathExtension.lowercased() } ?? ".cr3"
        let anyJobValue = pad.jobFields.contains { !pad.get($0.key).trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                title("This job")
                Spacer()
                Button("New job") { pad.newJob() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Clear the per-job fields")
            }
            ForEach(pad.jobFields, id: \.key) { f in fieldRow(f) }
            HStack(spacing: 6) {
                Text("Date").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
                TextField("yyyy-mm-dd", text: $pad.v.date)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { pad.normalizeDate(); controller.focusPhotos() }
            }
            VStack(alignment: .leading, spacing: 4) {
                if anyJobValue {
                    preview(v.value("headline", photo: first))
                    preview(v.value("caption", photo: first))
                    preview(v.fileName(photo: first, seq: 1) + ext)
                } else {
                    preview("Fill in this job's fields. Headline, caption, folder and file names follow from them.")
                }
            }
            .padding(.top, 2)
        }
    }

    private var ingestable: Bool {
        guard !pad.ingestRoot.isEmpty else { return true }
        return !session.roots.contains { $0.path.hasPrefix(pad.ingestRoot + "/") || $0.path == pad.ingestRoot }
    }

    private var ingestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Ingest")
            HStack(spacing: 8) {
                Text(pad.ingestRoot.isEmpty ? "No ingest folder chosen yet" : short(pad.ingestRoot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Choose…") { controller.chooseIngestRoot() }
            }
            preview("→ \(pad.v.folderName.isEmpty ? "job folder" : pad.v.folderName)/\(pad.v.rawFolder)")
            if ingestable {
                Button("Ingest \(session.photos.count) photos") { controller.ingest() }
                    .disabled(session.photos.isEmpty || session.busy != nil)
            } else {
                preview("These photos are already in your ingest folder.")
            }
            HStack(spacing: 6) {
                Toggle("Skip photos ingested before", isOn: $pad.skipIngested)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Incremental ingest, like Photo Mechanic: Pitpick remembers every photo it ingested (camera file name and capture time). Ingest the same card again and only the new photos are copied, also when the copies were renamed or moved.")
                Spacer()
                Button("Forget…") { controller.forgetIngestHistory() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Start the ingest history over")
            }
            HStack(spacing: 8) {
                Text(pad.backupRoot.isEmpty ? "Second copy: none" : "Second copy: " + short(pad.backupRoot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !pad.backupRoot.isEmpty {
                    Text("Off")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .onTapGesture { pad.backupRoot = "" }
                }
                Text("Choose…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { controller.chooseBackupRoot() }
            }
            .help("A second copy of every photo during the ingest, on another disk: read once from the card, written twice.")
            Toggle("Check every copy against the card", isOn: $pad.verifyCopies)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Each copy (and the second copy) is read back from its disk and its SHA-256 compared with the card's. Takes a little longer; then you can format the cards with peace of mind.")
            Toggle("Tagged and rated photos first", isOn: $pad.priorityFirst)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Tagged, rated and labelled photos (also protected or rated in the camera) are copied first, from all cards, so you can start on them while the rest copies.")
            Toggle("Eject the cards when done", isOn: $pad.ejectCards)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("When everything is copied without problems, the cards are ejected, as in Photo Mechanic.")
        }
    }

    private var count: Int {
        switch session.scope {
        case .tagged: return session.taggedCount
        case .shown: return session.visible.count
        case .selected: return session.selection.count
        case .all: return session.photos.count
        }
    }

    private var applySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Write and rename")
            ScopePicker(counts: session.counts, scope: session.scope, shown: session.visible.count, all: session.photos.count,
                        filtering: session.filtering, session: session)
            HStack(spacing: 8) {
                Button("Write metadata") { controller.writeMetadata() }
                Button("Rename") { controller.rename() }
                if session.lastRenameLog != nil { Button("Undo rename") { controller.undoRename() } }
            }
            .disabled(session.readOnly || session.busy != nil || session.photos.isEmpty)
        }
    }

    private var copySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Copy selection")
            HStack(spacing: 8) {
                Text(pad.copyRoot.isEmpty ? "No destination chosen yet" : short(pad.copyRoot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Choose…") { controller.chooseCopyRoot() }
            }
            TextField(pad.v.folderName.isEmpty ? "New folder" : pad.v.folderName, text: $pad.copyFolderOverride)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { controller.focusPhotos() }
            HStack(spacing: 14) {
                Toggle("Rename", isOn: $copyRename).toggleStyle(.checkbox)
                Toggle("Write metadata", isOn: $copyMetadata).toggleStyle(.checkbox)
            }
            FormatChoice(pad: pad)
            HStack(spacing: 8) {
                WithCounts(counts: session.counts) {
                    Button(pad.copyFormat == 1 ? "Export \(count) JPEGs" : "Copy \(count) photos") { controller.copySelection(rename: copyRename, withMetadata: copyMetadata) }
                        .disabled(count == 0 || session.busy != nil)
                }
                if session.lastCopyFolder != nil { Button("Show in Finder") { controller.revealLastCopy() } }
            }
        }
    }

    private func templateRow(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { controller.focusPhotos() }
        }
    }

    private var templateSection: some View {
        DisclosureGroup(isExpanded: $showTemplate) {
            VStack(alignment: .leading, spacing: 8) {
                preview("Pinned fields keep their value for every job. Unpin a field to make it a per-job field.")
                ForEach(pad.templateFields, id: \.key) { f in fieldRow(f) }
                Divider().padding(.vertical, 4)
                templateRow("File name", $pad.v.fileTemplate)
                templateRow("Folder name", $pad.v.folderTemplate)
                Toggle("Spaces become dashes in names", isOn: $pad.v.spacesToDashes)
                    .toggleStyle(.checkbox)
                    .help("Ziggo Dome becomes Ziggo-Dome in folder and file names")
                templateRow("Ingest subfolder", $pad.v.rawFolder)
                templateRow("Lightroom colour label names", $pad.v.labels)
                HStack(spacing: 8) {
                    Text(pad.codeFile.isEmpty ? "Code replacements: none" : "Code replacements: \((pad.codeFile as NSString).lastPathComponent) (\(Codes.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !pad.codeFile.isEmpty { Button("Off") { pad.codeFile = "" } }
                    Button("Choose…") { controller.chooseCodeFile() }
                }
                .help("A text file with on each line a code, a tab and its text, as in Photo Mechanic. Type \\jb\\ in any field, or as the person in a photo (P), and the metadata says James Bay.")
                templateRow("Read-only folders (separate with ;)", Binding(
                    get: { pad.readOnlyFolders.joined(separator: "; ") },
                    set: { pad.readOnlyFolders = $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                preview("Tokens: {event} {location} {city} {photographer} or any field name, {shootdate} and {time} (when the photo was taken, 21-04-37), {date} {date-dmy} {year} {month} {day} (the job date), {frame} (camera frame number), {filename} (camera file name), {seq}.")
                HStack(spacing: 8) {
                    Button("Load preset…") { controller.chooseImportPreset() }
                    Button("Save preset…") { controller.chooseExportPreset() }
                    Spacer()
                    Button("Reset") { pad.resetTemplate() }
                        .help("Put the template fields and names back to the defaults")
                }
            }
            .padding(.top, 6)
        } label: {
            title("Metadata template")
        }
    }

    private var legend: some View { KeysSection(pad: pad) }
}

/// The filters on stars and labels. A view of its own with plain values, so SwiftUI leaves the two menus alone
/// unless a filter changes: updating them with the rest of the panel made opening a folder 25 ms slower.
private struct FilterBar: View {
    let minRating: Int
    let label: Int
    let filtering: Bool
    let disabled: Bool
    let controller: Controller

    var body: some View {
        HStack(spacing: 12) {
            // click the third star: three stars or more; click it again: any
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Image(systemName: n <= minRating ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(n <= minRating ? Color.primary : Color.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.setMinRating(n) }
                }
            }
            .help("Only photos with at least this many stars. Click the same star again to show all.")
            HStack(spacing: 5) {
                ForEach(ColorLabel.allCases, id: \.rawValue) { l in
                    LabelDot(label: l, chosen: label == l.rawValue, dimmed: label != 0 && label != l.rawValue)
                        .onTapGesture { controller.setLabelFilter(l) }
                }
            }
            .help("Only photos with this colour label. Click it again to show all.")
            if filtering {
                Text("Show all")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { controller.clearFilters() }
            }
        }
        .allowsHitTesting(!disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// A colour label as a small dot (pure SwiftUI: cheap to lay out, unlike a menu).
private struct LabelDot: View {
    let label: ColorLabel
    let chosen: Bool
    var dimmed = false

    var body: some View {
        Circle()
            .fill(Color(nsColor: label.color))
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color.white, lineWidth: chosen ? 1.5 : 0).padding(-2.5))
            .opacity(dimmed ? 0.35 : 1)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
    }
}

/// What Write metadata, Rename and Copy work on, with the counts. Follows the counters itself.
private struct ScopePicker: View {
    @ObservedObject var counts: Counts
    let scope: Scope
    let shown: Int
    let all: Int
    let filtering: Bool
    let session: Session

    var body: some View {
        Picker("", selection: Binding(get: { scope }, set: { session.scope = $0 })) {
            Text("Tagged (\(counts.tagged))").tag(Scope.tagged)
            if filtering { Text("Shown (\(shown))").tag(Scope.shown) }
            if counts.selected > 1 { Text("Selected (\(counts.selected))").tag(Scope.selected) }
            Text("All (\(all))").tag(Scope.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// The keys, auto-advance and the label that goes with a tag. Only follows the pad, not the photos.
private struct KeysSection: View {
    @ObservedObject var pad: Pad

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("KEYS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Toggle("Next photo after a tag, stars or label", isOn: $pad.autoAdvance)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Or keep Caps Lock on, as in Lightroom")
                .padding(.bottom, 2)
            HStack(spacing: 4) {
                Text("T also sets a label").font(.system(size: 12))
                ForEach(ColorLabel.allCases, id: \.rawValue) { l in
                    LabelDot(label: l, chosen: pad.tagLabel == l.rawValue)
                        .onTapGesture { pad.tagLabel = pad.tagLabel == l.rawValue ? 0 : l.rawValue }
                }
                if pad.tagLabel == 0 { Text("(none)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .help("For Lightroom, which does not read the tag: a tagged photo also gets this colour label, so you can filter on it after importing.")
            .padding(.bottom, 2)
            Group {
                Text("T tag  ·  1-5 stars  ·  0 no stars  ·  ⌘Z undo")
                Text("6 red  ·  7 yellow  ·  8 green  ·  9 blue")
                Text("↩ or double-click: loupe  ·  esc: back")
                Text("space, Z or click: 100%  ·  drag: pan")
                Text("← → browse  ·  ⌘T tagged only  ·  ⌥⌘1-5 stars")
                Text("shift- or ⌘-click, ⌘A: select several")
                Text("C compare 2-4 side by side, linked zoom")
                Text("P person shown in this photo")
                Text("⇥ panel  ·  ⌘+ and ⌘- thumbnail size")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

/// Camera clocks: one correction per body, so two cameras sort and name as one. Pure SwiftUI (text you click):
/// a text field in the panel would be measured again with every update.
private struct ClocksSection: View {
    let bodies: [CameraBody]
    let offsets: [String: Double]
    let controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAMERA CLOCKS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            ForEach(bodies) { b in
                HStack(spacing: 8) {
                    Text(b.name).font(.system(size: 12)).lineLimit(1)
                    Text("\(b.count) photos").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(offsets[b.id].map { ExifDate.offsetText($0) } ?? "+0:00:00")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(offsets[b.id] == nil ? Color.secondary : Color.accentColor)
                        .onTapGesture { controller.editClockOffset(b) }
                        .help("Click to correct this camera's clock")
                }
            }
            HStack(spacing: 6) {
                Text("Same moment")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { controller.syncClocks() }
                Text("· two photos of one moment selected, one per camera")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help("The camera with fewer photos gets the clock of the other.")
        }
    }
}

/// Copy as raw files, or as the camera's JPEG (full size or smaller). Text you click: no AppKit control to measure.
private struct FormatChoice: View {
    @ObservedObject var pad: Pad

    var body: some View {
        HStack(spacing: 6) {
            Chip(title: "Raw files", on: pad.copyFormat == 0) { pad.copyFormat = 0 }
            Chip(title: "Camera JPEG", on: pad.copyFormat == 1) { pad.copyFormat = 1 }
            if pad.copyFormat == 1 {
                Text("·").foregroundStyle(.secondary)
                Chip(title: "Full", on: pad.jpegLongEdge == 0) { pad.jpegLongEdge = 0 }
                Chip(title: "3000 px", on: pad.jpegLongEdge == 3000) { pad.jpegLongEdge = 3000 }
                Chip(title: "2048 px", on: pad.jpegLongEdge == 2048) { pad.jpegLongEdge = 2048 }
            }
        }
        .help("Camera JPEG: the JPEG your camera made, taken out of the raw, with the camera's EXIF and your caption. Full size is not compressed again.")
    }
}

private struct Chip: View {
    let title: String
    let on: Bool
    let tap: () -> Void

    var body: some View {
        Text(title)
            .font(.system(size: 11.5))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color(white: 0.32) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.3), lineWidth: on ? 0 : 1))
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
    }
}
