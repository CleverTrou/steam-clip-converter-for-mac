import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 380), spacing: 12)]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            grid
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { exportBar }
        .frame(minWidth: 960, minHeight: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            sourceSection
            filterSections
        }
        .listStyle(.sidebar)
        // The summary is read-only. Keeping it out of the List -- below a divider,
        // on its own material -- stops it reading as another row you can click.
        .safeAreaInset(edge: .bottom, spacing: 0) { summaryPanel }
    }

    private var sourceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                // The folder being read, stated as a fact rather than a control.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.libraryRoot?.lastPathComponent ?? "No folder chosen")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let parent = model.libraryRoot?.deletingLastPathComponent().path {
                            Text(parent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                .help(model.libraryRoot?.path ?? "")

                // One control, one font. Both ways of changing the source live
                // inside it, so their relationship to the folder above is obvious.
                Menu {
                    Button("Choose Folder on Disk…") { model.chooseFolder() }
                    if !model.steamRoots.isEmpty {
                        Section("Detected Steam Locations") {
                            ForEach(model.steamRoots, id: \.self) { url in
                                Button(url.path) { model.libraryRoot = url }
                            }
                        }
                    }
                } label: {
                    Label("Change Reading Folder…", systemImage: "arrow.triangle.2.circlepath")
                }
                .menuStyle(.button)
                .controlSize(.regular)

                if let root = model.libraryRoot {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    } label: {
                        Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Reading Clips From")
        } footer: {
            Text("Clips are read only. Nothing here is modified or deleted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var filterSections: some View {
        Section("Filter by Game") {
            FilterRow(title: "All Games", count: model.clips.count, isOn: model.gameFilter == nil) {
                model.gameFilter = nil
            }
            ForEach(model.games, id: \.self) { game in
                FilterRow(title: game,
                          count: model.clips.filter { $0.displayName == game }.count,
                          isOn: model.gameFilter == game) {
                    model.gameFilter = (model.gameFilter == game) ? nil : game
                }
            }
        }

        Section("Filter by Status") {
            FilterRow(title: "All Clips", count: model.clips.count, isOn: model.statusFilter == nil) {
                model.statusFilter = nil
            }
            ForEach(AppModel.StatusFilter.allCases) { status in
                FilterRow(title: status.rawValue,
                          count: status == .converted ? model.convertedCount : model.clips.count - model.convertedCount,
                          isOn: model.statusFilter == status) {
                    model.statusFilter = (model.statusFilter == status) ? nil : status
                }
            }
        }

        Section("Filter by Quality") {
            FilterRow(title: "Any Quality", count: model.clips.count, isOn: model.qualityFilter == nil) {
                model.qualityFilter = nil
            }
            ForEach(model.qualities, id: \.self) { quality in
                FilterRow(title: quality,
                          count: model.clips.filter { $0.qualityBucket == quality }.count,
                          isOn: model.qualityFilter == quality) {
                    model.qualityFilter = (model.qualityFilter == quality) ? nil : quality
                }
            }
        }
    }

    private var summaryPanel: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("SUMMARY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)
                    .accessibilityLabel("Summary")
                    .accessibilityAddTraits(.isHeader)
                SummaryRow(label: "Clips in folder", value: "\(model.clips.count)")
                SummaryRow(label: "Shown after filters", value: "\(model.visibleClips.count)")
                SummaryRow(label: "Selected", value: "\(model.selection.count)")
                SummaryRow(label: "Already converted", value: "\(model.convertedCount) of \(model.clips.count)")
                SummaryRow(label: model.selection.isEmpty ? "Size shown" : "Size selected",
                           value: ByteCountFormatter.string(
                               fromByteCount: model.selection.isEmpty ? model.visibleBytes : model.selectedBytes,
                               countStyle: .file))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.quaternary.opacity(0.4))
    }

    // MARK: - Grid

    private var grid: some View {
        Group {
            if model.isScanning {
                ProgressView("Scanning recordings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleClips.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "film.stack",
                    description: Text("Choose a folder containing Steam recording folders (bg_… with session.mpd inside).")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.visibleClips) { clip in
                            ClipCard(clip: clip,
                                     isSelected: model.selection.contains(clip.id),
                                     conversion: model.record(for: clip)) {
                                if model.selection.contains(clip.id) {
                                    model.selection.remove(clip.id)
                                } else {
                                    model.selection.insert(clip.id)
                                }
                            }
                            .contextMenu {
                                Button("Reveal Original in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([clip.url])
                                }
                                if let record = model.record(for: clip) {
                                    Divider()
                                    Button("Reveal Converted File") { model.reveal(record.outputURL) }
                                    Button("Mark as Not Converted") { model.forgetConversion(clip) }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Steam Clip Converter for Mac")
        .navigationSubtitle(model.libraryRoot?.lastPathComponent ?? "")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            TextField("Search", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        ToolbarItem(placement: .primaryAction) {
            // Grouped in opposite pairs so the sort direction is always explicit.
            Menu {
                ForEach(AppModel.SortOrder.Criterion.allCases, id: \.self) { criterion in
                    Section(criterion.rawValue) {
                        ForEach(AppModel.SortOrder.options(for: criterion)) { option in
                            Button {
                                model.sort = option
                            } label: {
                                if model.sort == option {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                    }
                }
            } label: {
                Label("Sort: \(model.sort.rawValue)", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                if model.selection.count == model.visibleClips.count {
                    model.selection.removeAll()
                } else {
                    model.selection = Set(model.visibleClips.map(\.id))
                }
            } label: {
                Label(model.selection.count == model.visibleClips.count && !model.visibleClips.isEmpty
                      ? "Deselect All" : "Select All",
                      systemImage: "checklist")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    // MARK: - Export bar

    private var exportBar: some View {
        VStack(spacing: 8) {
            Divider()
            if model.isConverting {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.conversionLabel).font(.callout)
                    ProgressView(value: model.conversionProgress)
                        .accessibilityLabel(model.conversionLabel)
                }
                .padding(.horizontal, 16)
            } else {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        // The captions above these two controls are visual only;
                        // each control carries its own accessible name.
                        Text("Convert to format")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Picker("Convert to format", selection: $model.container) {
                            ForEach(ClipConverter.Container.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .help(model.container.keepsAllMetadata
                              ? "QuickTime keeps all 12 metadata fields, including the Steam-specific ones."
                              : "MPEG-4 is more portable for sharing, but drops the Steam-specific metadata.")
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Converted file destination")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Button {
                            model.chooseOutputFolder()
                        } label: {
                            Label(model.outputFolder.lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                        }
                        .help(model.outputFolder.path)
                        .accessibilityLabel("Converted file destination")
                        .accessibilityValue(model.outputFolder.lastPathComponent)
                    }

                    Spacer(minLength: 8)

                    if let result = model.lastResult {
                        HStack(spacing: 6) {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button("Show") { model.revealOutput() }
                        }
                        .frame(maxWidth: 320)
                    }

                    Button {
                        model.convertSelected()
                    } label: {
                        Label(model.selection.isEmpty ? "Convert All (\(model.visibleClips.count))"
                                                      : "Convert Selected (\(model.selection.count))",
                              systemImage: "square.and.arrow.down")
                        .frame(height: 22)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.visibleClips.isEmpty)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 12)
        .background(.bar)
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FilterRow: View {
    let title: String
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.caption)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The circle/checkmark is the only visual cue for the active filter, so
        // state it as a trait instead of letting VoiceOver read the symbol name.
        .accessibilityLabel(title)
        .accessibilityValue("\(count) clip\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
