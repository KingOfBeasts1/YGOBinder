import SwiftUI
import SwiftData

@main
struct YGOBinderApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(for: [OwnedCard.self, Deck.self])
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            ScanTab().tabItem { Label("Scan", systemImage: "camera.viewfinder") }
            CollectionView().tabItem { Label("Collection", systemImage: "rectangle.stack") }
            DecksView().tabItem { Label("Decks", systemImage: "square.stack.3d.up") }
        }
        .task { await CardDB.shared.load() }
    }
}

// MARK: - Shared pieces

struct CardRow: View {
    let card: Card
    var trailing: String = ""
    var note: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: card.smallURL) { $0.resizable().scaledToFit() } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 44, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.headline)
                Text(card.type).font(.caption).foregroundStyle(.secondary)
                if let note, !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.tint) }
            }
            Spacer()
            Text(trailing).foregroundStyle(.secondary)
        }
    }
}

struct CardDetailView: View {
    let card: Card
    var printings: [String] = []

    private var groups: [(key: String, value: [String])] {
        Dictionary(grouping: printings, by: { $0 }).sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AsyncImage(url: card.imageURL) { $0.resizable().scaledToFit() } placeholder: { ProgressView().frame(height: 320) }
                    .frame(maxWidth: .infinity)
                Text(card.name).font(.title.bold())
                Group {
                    LabeledContent("Type", value: card.type)
                    if let a = card.attribute { LabeledContent("Attribute", value: a) }
                    if let r = card.race { LabeledContent("Race / Type", value: r) }
                    if let l = card.level { LabeledContent("Level / Rank", value: "\(l)") }
                    if let l = card.linkval { LabeledContent("Link rating", value: "\(l)") }
                    if let a = card.atk { LabeledContent("ATK", value: "\(a)") }
                    if let d = card.def { LabeledContent("DEF", value: "\(d)") }
                }
                Divider()
                Text(card.desc)
                if !groups.isEmpty {
                    Divider()
                    Text("Your printings").font(.headline)
                    ForEach(groups, id: \.key) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(g.key).bold(); Spacer(); Text("×\(g.value.count)") }
                            if let label = card.setLabel(for: g.key) {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Collection

struct CollectionView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \OwnedCard.added, order: .reverse) private var owned: [OwnedCard]
    @State private var search = ""
    private let db = CardDB.shared

    private struct Row: Identifiable { let owned: OwnedCard; let card: Card; var id: Int { card.id } }

    private var rows: [Row] {
        owned.compactMap { o in db.cards[o.cardID].map { Row(owned: o, card: $0) } }
            .filter { search.isEmpty || $0.card.name.localizedCaseInsensitiveContains(search) || $0.card.desc.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                NavigationLink { CardDetailView(card: row.card, printings: row.owned.printings) } label: {
                    CardRow(card: row.card, trailing: "×\(row.owned.quantity)",
                            note: printingsSummary(row.owned.printings))
                }
                .swipeActions { Button("Delete", role: .destructive) { ctx.delete(row.owned) } }
            }
            .overlay {
                if owned.isEmpty {
                    ContentUnavailableView("No cards yet", systemImage: "rectangle.stack", description: Text("Use the Scan tab to add cards."))
                }
            }
            .searchable(text: $search, prompt: "Search name or effect")
            .navigationTitle("Collection (\(owned.reduce(0) { $0 + $1.quantity }))")
        }
    }
}

// MARK: - Decks

struct DecksView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Deck.name) private var decks: [Deck]
    @State private var importing = false
    @State private var pasting = false
    @State private var report: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(decks) { d in
                    NavigationLink { DeckEditor(deck: d) } label: {
                        VStack(alignment: .leading) {
                            Text(d.name).font(.headline)
                            Text("\(d.cardIDs.count) cards").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { for i in $0 { ctx.delete(decks[i]) } }
            }
            .overlay {
                if decks.isEmpty {
                    ContentUnavailableView("No decks", systemImage: "square.stack.3d.up", description: Text("Tap + to build one."))
                }
            }
            .navigationTitle("Decks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu("Import", systemImage: "square.and.arrow.down") {
                        Button("From file (.ydk / .txt)", systemImage: "doc") { importing = true }
                        Button("Paste a list", systemImage: "doc.on.clipboard") { pasting = true }
                    }
                    Button("New Deck", systemImage: "plus") { ctx.insert(Deck(name: "New Deck")) }
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [DeckIO.ydkType, .plainText, .data],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                var reports: [String] = []
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let name = url.deletingPathExtension().lastPathComponent
                    if let text = (try? String(contentsOf: url, encoding: .utf8))
                        ?? (try? String(contentsOf: url, encoding: .isoLatin1)) {
                        reports.append(DeckIO.importDeck(name: name, text: text, into: ctx))
                    } else {
                        reports.append("Couldn't read “\(name)”.")
                    }
                }
                report = reports.joined(separator: "\n\n")
            }
            .sheet(isPresented: $pasting) {
                PasteImportSheet { name, text in
                    report = DeckIO.importDeck(name: name, text: text, into: ctx)
                }
            }
            .alert("Import", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
                Button("OK") {}
            } message: {
                Text(report ?? "")
            }
        }
    }
}

struct DeckEditor: View {
    @Bindable var deck: Deck
    @Query private var owned: [OwnedCard]
    @State private var picking = false
    private let db = CardDB.shared

    /// e.g. "Missing 2" when the deck uses more copies than you own (common after importing a list).
    private func missingNote(_ id: Int, needs n: Int) -> String? {
        let have = owned.first { $0.cardID == id }?.quantity ?? 0
        return have < n ? "Missing \(n - have) (own \(have))" : nil
    }

    private func items(extra: Bool) -> [(Card, Int)] {
        Dictionary(grouping: deck.cardIDs, by: { $0 }).compactMap { id, ids -> (Card, Int)? in
            guard let c = db.cards[id], c.isExtraDeck == extra else { return nil }
            return (c, ids.count)
        }.sorted { $0.0.name < $1.0.name }
    }

    private func removeOne(_ id: Int) {
        if let i = deck.cardIDs.firstIndex(of: id) { deck.cardIDs.remove(at: i) }
    }

    @ViewBuilder
    private func block(_ title: String, _ list: [(Card, Int)], range: String) -> some View {
        Section("\(title) — \(list.reduce(0) { $0 + $1.1 }) cards (\(range))") {
            ForEach(list, id: \.0.id) { item in
                NavigationLink { CardDetailView(card: item.0) } label: {
                    CardRow(card: item.0, trailing: "×\(item.1)", note: missingNote(item.0.id, needs: item.1))
                }
                .swipeActions { Button("Remove one", role: .destructive) { removeOne(item.0.id) } }
            }
        }
    }

    var body: some View {
        List {
            Section { TextField("Deck name", text: $deck.name) }
            block("Main Deck", items(extra: false), range: "40–60")
            block("Extra Deck", items(extra: true), range: "0–15")
        }
        .navigationTitle(deck.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("Export", systemImage: "square.and.arrow.up") {
                    ShareLink("Share .ydk file", item: DeckFile(name: deck.name, ydk: DeckIO.ydk(deck)),
                              preview: SharePreview("\(deck.name).ydk"))
                    ShareLink("Share as text", item: DeckIO.text(deck))
                    Button("Copy as text list", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = DeckIO.text(deck)
                    }
                }
                Button("Add Cards", systemImage: "plus") { picking = true }
            }
        }
        .sheet(isPresented: $picking) { CardPicker(deck: deck) }
    }
}

/// Pick from owned cards only; limited to 3 copies and to how many you own.
struct CardPicker: View {
    @Bindable var deck: Deck
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \OwnedCard.added, order: .reverse) private var owned: [OwnedCard]
    @State private var search = ""
    private let db = CardDB.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(owned) { o in
                    if let c = db.cards[o.cardID],
                       search.isEmpty || c.name.localizedCaseInsensitiveContains(search) {
                        let n = deck.cardIDs.filter { $0 == c.id }.count
                        let limit = min(3, o.quantity)
                        Button { deck.cardIDs.append(c.id) } label: {
                            CardRow(card: c, trailing: "\(n)/\(limit)")
                        }
                        .buttonStyle(.plain)
                        .disabled(n >= limit)
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Add from Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
