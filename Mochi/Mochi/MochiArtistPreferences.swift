import Combine
import Foundation
import SwiftUI

/// First-party choices stay on this Mac. Only names accompany a listening request.
@MainActor
final class MochiArtistPreferencesModel: ObservableObject {
    @Published private(set) var names: [String]
    @Published var isPresented: Bool
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            generation = UUID()
            suggestions = []; message = nil; isSearching = false
            completedQuery = nil; isAddingFromQuery = false
            searchID = generation
        }
    }
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var message: String?
    @Published private(set) var isSearching = false
    @Published private(set) var isAddingFromQuery = false
    @Published private(set) var searchID = UUID()
    @Published private(set) var lastAdded: UUID?
    private let backend: MochiBackendClient
    private let defaults: UserDefaults?
    private var generation = UUID()
    private var completedQuery: String?
    private static let namesKey = "mochi.taste.favorite-artists"
    private static let setupKey = "mochi.taste.artist-setup-complete"

    init(backend: MochiBackendClient? = nil, defaults: UserDefaults? = nil) {
        self.backend = backend ?? MochiBackendClient()
        self.defaults = defaults
        var seen = Set<String>()
        let savedNames = Array((defaults?.stringArray(forKey: Self.namesKey) ?? [])
            .filter { MochiArtistName.valid($0) && seen.insert(MochiArtistName.key($0)).inserted }.prefix(3))
        names = savedNames
        isPresented = defaults != nil && !(defaults?.bool(forKey: Self.setupKey) ?? false) && savedNames.isEmpty
    }

    func present() { query = ""; isPresented = true }

    func finish() {
        cancelSearch()
        query = ""; isPresented = false
        defaults?.set(true, forKey: Self.setupKey)
    }

    func add(_ name: String) {
        guard names.count < 3, suggestions.contains(name), MochiArtistName.valid(name),
              !names.contains(where: { MochiArtistName.key($0) == MochiArtistName.key(name) }) else { return }
        names.append(name)
        defaults?.set(names, forKey: Self.namesKey)
        lastAdded = UUID()
        query = ""
        message = "Added \(name)."
    }

    func remove(_ name: String) {
        names.removeAll { $0 == name }
        defaults?.set(names, forKey: Self.namesKey)
        query = ""
    }

    func clear() {
        names = []
        defaults?.removeObject(forKey: Self.namesKey)
        query = ""
    }

    var canSubmitQuery: Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.count < 3 && text.unicodeScalars.count <= 100 && MochiArtistName.valid(text)
    }

    /// Return and Add accept an exact result, or wait for the current lookup.
    func submitQuery() {
        guard canSubmitQuery else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MochiArtistName.key(text)
        if names.contains(where: { MochiArtistName.key($0) == key }) {
            message = "That artist is already added."
            return
        }
        if let match = suggestions.first(where: { MochiArtistName.key($0) == key }) {
            add(match)
            return
        }
        if completedQuery == text {
            isAddingFromQuery = false
            message = suggestions.isEmpty ? "No artists found. Try another name." : "Choose an artist from the results below."
            return
        }
        isAddingFromQuery = true
        message = nil
        if !isSearching {
            generation = UUID()
            searchID = generation // Also allows retrying unchanged text after an error.
        }
    }

    func cancelSearch() {
        generation = UUID(); isSearching = false; isAddingFromQuery = false
    }

    /// SwiftUI owns/cancels this task when the query changes or the editor closes.
    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmitQuery else { return }
        let current = generation
        isSearching = true
        defer { if current == generation { isSearching = false; isAddingFromQuery = false } }
        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            guard current == generation else { return }
            let found = try await backend.searchArtists(query: text)
            try Task.checkCancellation()
            guard current == generation else { return }
            suggestions = found.filter { name in !names.contains { MochiArtistName.key($0) == MochiArtistName.key(name) } }
            completedQuery = text
            message = suggestions.isEmpty ? "No new artists found. Try another name." : nil
            if isAddingFromQuery { submitQuery() }
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            if case MochiBackendError.unavailable = error {
                message = "Start the backend, then press Return or Add to try again."
            } else {
                message = error.localizedDescription
            }
        }
    }
}

struct MochiArtistPreferencesView: View {
    @ObservedObject var artists: MochiArtistPreferencesModel
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One artist is enough. Add up to three.")
                .font(.system(size: 11)).foregroundStyle(Color.mochiMuted)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(artists.names, id: \.self) { name in
                    HStack(spacing: 6) {
                        Text(name).lineLimit(1).help(name)
                        Button { artists.remove(name) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(name)")
                    }
                    .font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color(hex: 0xDCE8D9).opacity(0.65), in: Capsule())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: artists.names)
            if artists.names.count < 3 {
                HStack(spacing: 8) {
                    TextField("Artist name…", text: $artists.query)
                        .font(.system(size: 11)).textFieldStyle(.plain)
                        .focused($focused).accessibilityLabel("Find a favorite artist")
                        .onSubmit { artists.submitQuery() }
                        .onChange(of: artists.query) { _, text in
                            if text.unicodeScalars.count > 100 { artists.query = String(String.UnicodeScalarView(text.unicodeScalars.prefix(100))) }
                        }
                    Button("Add") { artists.submitQuery() }
                        .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                        .disabled(!artists.canSubmitQuery || artists.isAddingFromQuery)
                        .accessibilityLabel("Add typed artist")
                }
                .padding(10).background(Color.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 11))
                Text("Press Return or choose a result to add.")
                    .font(.system(size: 10)).foregroundStyle(Color.mochiMuted)
                if artists.isSearching { ProgressView().controlSize(.mini).accessibilityLabel("Finding artists") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(artists.suggestions, id: \.self) { name in
                            Button { artists.add(name); focused = true } label: {
                                HStack { Text(name).lineLimit(1); Spacer(); Image(systemName: "plus") }
                                    .font(.system(size: 11)).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Add \(name)")
                        }
                    }
                }
            }
            if let message = artists.message {
                Text(message).font(.system(size: 10)).foregroundStyle(Color.mochiMuted).lineLimit(3).help(message)
            }
            Spacer(minLength: 0)
            HStack {
                Text("You can change these anytime.").font(.system(size: 10)).foregroundStyle(Color.mochiMuted)
                Spacer(minLength: 0)
                Button(artists.names.isEmpty ? "Skip for now" : "Done") { artists.finish() }
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
            }
        }
        .task(id: artists.searchID) { await artists.search() }
        .onChange(of: artists.names.count) { _, count in focused = count < 3 }
        .onDisappear { artists.cancelSearch() }
        .task { await Task.yield(); focused = true }
    }
}
