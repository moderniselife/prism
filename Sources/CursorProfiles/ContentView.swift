import SwiftUI
import UniformTypeIdentifiers

enum SortMode: String, CaseIterable, Identifiable {
    case name = "Name"
    case recent = "Recently Used"
    case size = "Size"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @State private var search = ""
    @State private var sortMode: SortMode = .recent
    @State private var showingAdd = false
    @State private var editingProfile: CursorProfile?
    @State private var deletingProfile: CursorProfile?

    private var filtered: [CursorProfile] {
        var list = store.profiles
        if !search.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(search) ||
                $0.folderName.localizedCaseInsensitiveContains(search)
            }
        }
        list.sort { a, b in
            if a.isSystem != b.isSystem { return a.isSystem }
            if a.isPinned != b.isPinned { return a.isPinned }
            switch sortMode {
            case .name:
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            case .recent:
                return (a.lastLaunchedAt ?? .distantPast) > (b.lastLaunchedAt ?? .distantPast)
            case .size:
                return (store.sizes[a.folderName] ?? 0) > (store.sizes[b.folderName] ?? 0)
            }
        }
        return list
    }

    var body: some View {
        ZStack {
            MeshBackgroundView()

            if store.profiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    if store.resolvedCursorPath == nil {
                        cursorMissingBanner
                            .padding([.horizontal, .top])
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(filtered) { profile in
                            ProfileCard(
                                profile: profile,
                                onEdit: { editingProfile = profile },
                                onDelete: { deletingProfile = profile }
                            )
                        }
                    }
                    .padding(16)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: filtered)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .navigationTitle("Prism")
        .searchable(text: $search, placement: .toolbar, prompt: "Search profiles")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Sort", selection: $sortMode) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help("Sort profiles")

                Button {
                    showingAdd = true
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Create a new profile (⌘N)")
            }
        }
        .sheet(isPresented: $showingAdd) {
            ProfileEditorSheet(mode: .create)
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorSheet(mode: .edit(profile))
        }
        .confirmationDialog(
            "Delete “\(deletingProfile?.displayName ?? "")”?",
            isPresented: Binding(get: { deletingProfile != nil },
                                 set: { if !$0 { deletingProfile = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let p = deletingProfile { store.delete(p) }
                deletingProfile = nil
            }
        } message: {
            Text("The profile folder (\(Format.bytes(store.sizes[deletingProfile?.folderName ?? ""]))) will be moved to the Trash, including all its settings, extensions and chat history.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var cursorMissingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Cursor was not found. Install it from cursor.sh, or set a custom path in Settings (⌘,).")
                .font(.callout)
            Spacer()
            SettingsLink { Text("Open Settings") }
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("No profiles yet")
                .font(.title2.weight(.semibold))
            Text("Each profile is a fully isolated Cursor instance —\nits own settings, extensions, login and chat history.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showingAdd = true
            } label: {
                Label("Create your first profile", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}
