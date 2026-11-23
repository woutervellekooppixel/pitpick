// The side panel: this job's fields, ingest, write/rename, copy the selection, and the metadata template.
import SwiftUI

struct SidePanel: View {
    @ObservedObject var session: Session
    @ObservedObject var pad: Pad
    let controller: Controller
    @State private var copyRename = true
    @State private var copyMetadata = true
    @State private var showTemplate = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if session.readOnly { banner }
                if let b = session.busy { busy(b) }
                jobSection
                ingestSection
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
                Menu {
                    ForEach(pad.knownVenues, id: \.self) { z in Button(z) { pad.set("location", z) } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
            }
            Button { pad.togglePin(f.key) } label: {
                Image(systemName: pad.pinned.contains(f.key) ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(pad.pinned.contains(f.key) ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
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
                Text("\(session.photos.count) photos · \(session.taggedCount) tagged").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Open…") { controller.chooseFolder() }
                Toggle("Tagged only", isOn: Binding(get: { session.onlyTagged }, set: { controller.setOnlyTagged($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(session.photos.isEmpty)
            }
        }
    }

    private var banner: some View {
        Text(session.lockedVolume
             ? "Locked card: Pitpick writes nothing on it. Tags, stars and labels stay in Pitpick and go along with the ingest."
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
        }
    }

    private var count: Int { session.scopeTagged ? session.taggedCount : session.photos.count }

    private var applySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Write and rename")
            Picker("", selection: $session.scopeTagged) {
                Text("Tagged (\(session.taggedCount))").tag(true)
                Text("All (\(session.photos.count))").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
            HStack(spacing: 8) {
                Button("Copy \(count) photos") { controller.copySelection(rename: copyRename, withMetadata: copyMetadata) }
                    .disabled(count == 0 || session.busy != nil)
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

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            title("Keys")
            Group {
                Text("T tag  ·  1-5 stars  ·  0 no stars")
                Text("6 red  ·  7 yellow  ·  8 green  ·  9 blue")
                Text("↩ or double-click: loupe  ·  esc: back")
                Text("space, Z or click: 100%  ·  drag: pan")
                Text("← → browse  ·  ⌘T tagged only")
                Text("⇥ panel  ·  ⌘+ and ⌘- thumbnail size")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}
