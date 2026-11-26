import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    /// Day ids the user has opened. The newest day is not in here; it stays open.
    @State private var expandedDays: Set<String> = []
    @State private var thinningOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            if model.libraries.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    libraries
                        .frame(width: 230)
                    hairlineVertical
                    versions
                        .frame(width: 268)
                    hairlineVertical
                    browser
                }
            }
            hairline
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear { model.start() }
        .onChange(of: model.selection) { _ in model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chronicle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(AppInfo.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            if let totals = model.totals, totals.snapshotCount > 0 {
                stat("Stored", ByteText.string(totals.storedBytes))
                stat("Full copies", ByteText.string(totals.rawCopyBytes))
                stat("Saved", totals.savedPercent.map { "\($0)%" } ?? "—")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(title == "Saved" ? Theme.green : Theme.amberBright)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Watch a folder.\nKeep every version.\nStore only what changed.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Text("A full copy of every version is the expensive way.\nChronicle keeps the bytes that are new.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Add Folder…") { model.addFolder() }
                .buttonStyle(ChronicleButtonStyle(kind: .primary))
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraries: some View {
        VStack(spacing: 0) {
            paneTitle("Folders") {
                Button("Add") { model.addFolder() }
                    .buttonStyle(ChronicleButtonStyle(kind: .secondary))
            }
            List(selection: $model.selection) {
                ForEach(model.libraries) { library in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if model.selection == library.id && model.selectedIsDirty {
                                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                            }
                            Text(library.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                        }
                        Text(library.source)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 3)
                    .tag(library.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Schedule", selection: Binding(
                    get: { model.selectedLibrary?.policy ?? "manual" },
                    set: { model.setPolicy($0) }
                )) {
                    Text("Manual").tag("manual")
                    Text("Every 15 minutes").tag("quarter")
                    Text("Hourly").tag("hour")
                    Text("Daily").tag("day")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Skips \(model.skipLine)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                Text("Snapshots")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                Text(model.snapshotLocation)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button("Store…") { model.chooseSnapshotPlace() }
                    .buttonStyle(ChronicleButtonStyle())
                    .disabled(model.busy)
                HStack {
                    Button("Folder") { model.revealSource() }
                        .buttonStyle(ChronicleButtonStyle())
                    Button("History") { model.revealVault() }
                        .buttonStyle(ChronicleButtonStyle())
                    Spacer()
                    Button("Remove") { model.removeSelectedLibrary() }
                        .buttonStyle(ChronicleButtonStyle(kind: .danger))
                        .disabled(model.busy)
                }
            }
            .padding(12)
        }
        .background(Theme.panel)
    }

    private var versions: some View {
        VStack(spacing: 0) {
            paneTitle("Versions") {
                Button("Verify") { model.verifySelected() }
                    .buttonStyle(ChronicleButtonStyle(kind: .secondary))
                    .disabled(model.busy || model.selectedLibrary == nil)
            }
            List(selection: $model.selectedSnapshotID) {
                ForEach(versionDays) { day in
                    if day.opensFlat {
                        if day.showsHeader {
                            Section {
                                versionRows(day)
                            } header: {
                                dayLabel(day)
                            }
                        } else {
                            versionRows(day)
                        }
                    } else {
                        DisclosureGroup(isExpanded: expanded(day.id)) {
                            versionRows(day)
                        } label: {
                            dayLabel(day)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onChange(of: model.selection) { _ in
                expandedDays = []
                thinningOpen = false
            }
            .onChange(of: model.selectedSnapshotID) { id in
                if let id {
                    if let day = versionDays.first(where: { !$0.opensFlat && $0.heads.contains { $0.id == id } }) {
                        expandedDays.insert(day.id)
                    }
                    model.loadRows(id)
                }
            }
            hairline
            thinning
            VStack(alignment: .leading, spacing: 8) {
                TextField("Label", text: $model.labelText)
                    .textFieldStyle(.roundedBorder)
                Button(snapshotButtonTitle) {
                    if model.snapshotActive {
                        model.stopSnapshot()
                    } else {
                        model.takeSnapshot()
                    }
                }
                    .buttonStyle(ChronicleButtonStyle(kind: model.snapshotActive ? .danger : .primary))
                    .disabled((model.busy && !model.snapshotActive) || model.snapshotStopping)
            }
            .padding(12)
        }
        .background(Theme.panel)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Text("This version")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                Spacer()
                TextField("Filter", text: $model.filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(selection: $model.selectedPath) {
                ForEach(shownRows) { row in
                    HStack(spacing: 8) {
                        Text(badge(row.change))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(color(row.change))
                            .frame(width: 58, alignment: .leading)
                        Text(row.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(row.change == "removed" ? "gone" : (row.kind == "dir" ? "folder" : ByteText.string(row.size)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                    .tag(row.path)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            detail
            restoreBar
        }
        .background(Theme.bg)
    }

    private var detail: some View {
        HStack {
            if let row = model.selectedRow {
                Text(detailLine(row))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Select a file to see what this version kept.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var snapshotButtonTitle: String {
        if model.snapshotStopping { return "Stopping…" }
        if model.snapshotActive { return "Stop" }
        if model.busy { return "Working…" }
        return "Snapshot"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
                Text(model.snapshotStopping || model.progressPath.isEmpty ? model.banner : model.progressPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !model.banner.isEmpty {
                Text(model.banner).lineLimit(3)
            } else {
                Text(model.idleLine).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.panel)
    }

    private var thinning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("THINNING")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.muted)
            if !model.thinningReadable {
                Text("The thinning log could not be read.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.thinningLog.removed == 0 {
                Text("Nothing logged yet. Earlier thinning is not included.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Since logging began")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(ThinningText.total(model.thinningLog))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let latest = model.thinningLog.passes.first {
                    thinningPass(latest)
                }
                if model.thinningLog.passes.count > 1 {
                    DisclosureGroup(isExpanded: $thinningOpen) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.thinningLog.passes.dropFirst())) { pass in
                                    thinningPass(pass)
                                }
                            }
                        }
                        .frame(height: min(120, CGFloat(model.thinningLog.passes.count - 1) * 44))
                    } label: {
                        Text("Earlier")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func thinningPass(_ pass: ThinningPass) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(TimeText.display(pass.at))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(ThinText.sentence(
                names: ThinText.names(pass),
                freed: pass.freed,
                complete: pass.complete
            ))
            .font(.system(size: 10))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var versionDays: [VersionDay] {
        VersionDays.group(model.summaries)
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedDays.contains(id) },
            set: { open in
                if open {
                    expandedDays.insert(id)
                } else {
                    expandedDays.remove(id)
                }
            }
        )
    }

    private func dayLabel(_ day: VersionDay) -> some View {
        HStack(spacing: 8) {
            Text(day.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            Text("\(day.heads.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 2)
    }

    private func versionRows(_ day: VersionDay) -> some View {
        ForEach(day.heads) { head in
            versionRow(head, timeOnly: day.showsHeader)
                .tag(head.id)
        }
    }

    private func versionRow(_ head: SnapshotHead, timeOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(versionWhen(head, timeOnly: timeOnly))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(head.label.isEmpty ? Policy.reason(head.reason) : head.label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.amber)
                .lineLimit(1)
            Text(versionDetail(head))
                .font(.system(size: 11))
                .foregroundStyle(head.stats.statusLine == nil ? Theme.muted : Theme.danger)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    private func versionWhen(_ head: SnapshotHead, timeOnly: Bool) -> String {
        if timeOnly, let date = TimeText.parse(head.created) {
            return TimeText.clock(date)
        }
        return TimeText.display(head.created)
    }

    private var canRestoreFolder: Bool {
        !model.busy && model.selectedLibrary != nil && model.selectedSnapshotID != nil
    }

    private var restoreBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                restoreVersionButton
                restoreFileButton
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                restoreFolderButton
                Spacer(minLength: 8)
                deleteVersionButton
            }
        }
        .padding(12)
    }

    private var restoreVersionButton: some View {
        Button("Restore Version…") { model.restoreSelected() }
            .buttonStyle(ChronicleButtonStyle(kind: .primary))
            .disabled(model.busy || model.selectedSnapshotID == nil)
            .fixedSize()
    }

    private var restoreFileButton: some View {
        Button("Restore File…") { model.restoreSelectedFile() }
            .buttonStyle(ChronicleButtonStyle())
            .disabled(model.busy || model.selectedRow == nil || model.selectedRow?.kind == "dir" || model.selectedRow?.change == "removed" || model.selectedRow?.change == "unread")
            .fixedSize()
    }

    private var restoreFolderButton: some View {
        Button("Restore Folder…") { model.restoreSelectedDirectory() }
            .buttonStyle(ChronicleButtonStyle())
            .disabled(!canRestoreFolder)
            .fixedSize()
            .help("Pick a folder from this version. Folders that did not change are included.")
    }

    private var deleteVersionButton: some View {
        Button("Delete Version") { model.deleteSelectedSnapshot() }
            .buttonStyle(ChronicleButtonStyle(kind: .danger))
            .disabled(model.busy || model.selectedSnapshotID == nil)
            .fixedSize()
    }

    private var shownRows: [BrowserRow] {
        let query = model.filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.rows }
        return model.rows.filter { $0.path.lowercased().contains(query) }
    }

    private func versionDetail(_ head: SnapshotHead) -> String {
        let stats = head.stats
        let glance = model.glances[head.id]
        let newBytes = glance?.newBytes ?? stats.newChunkBytes
        let quiet = glance?.quiet ?? (stats.newChunkBytes == 0 && stats.addedFiles == 0 && stats.changedFiles == 0 && stats.removedFiles == 0)
        let bytes: String
        if quiet {
            bytes = "Nothing new · \(ByteText.string(stats.logicalBytes)) in the folder"
        } else {
            bytes = "\(ByteText.string(newBytes)) new · a full copy is \(ByteText.string(stats.logicalBytes))"
        }
        if let status = stats.statusLine {
            return status + "\n" + bytes
        }
        return bytes
    }

    private func detailLine(_ row: BrowserRow) -> String {
        if row.kind == "dir" {
            return "\(row.path)  ·  \(word(row.change)) folder"
        }
        if row.change == "carried" {
            return "\(row.path)  ·  carried forward. Chronicle could not read the current file."
        }
        if row.change == "unread" {
            return "\(row.path)  ·  unreadable. This version does not have it."
        }
        return "\(row.path)  ·  \(word(row.change))  ·  \(row.chunkCount) chunks  ·  \(ByteText.string(row.newBytes)) new since the previous version"
    }

    private func badge(_ change: String) -> String {
        switch change {
        case "added": return "ADDED"
        case "changed": return "CHANGED"
        case "removed": return "GONE"
        case "carried": return "CARRIED"
        case "unread": return "UNREAD"
        default: return "SAME"
        }
    }

    private func word(_ change: String) -> String {
        switch change {
        case "added": return "added"
        case "changed": return "changed"
        case "removed": return "gone since the previous version"
        case "carried": return "carried forward"
        case "unread": return "unreadable"
        default: return "unchanged"
        }
    }

    private func color(_ change: String) -> Color {
        switch change {
        case "added": return Theme.green
        case "changed": return Theme.amber
        case "removed", "carried", "unread": return Theme.danger
        default: return Theme.muted
        }
    }

    private func paneTitle<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    private var hairlineVertical: some View {
        Rectangle().fill(Theme.border).frame(width: 1)
    }
}
