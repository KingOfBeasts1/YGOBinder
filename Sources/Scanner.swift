import SwiftUI
import SwiftData
import VisionKit

/// Live camera view that reports all recognized text, topmost first (a card's name is at its top).
struct ScannerView: UIViewControllerRepresentable {
    var onText: ([String]) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onText) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onText: ([String]) -> Void
        init(_ f: @escaping ([String]) -> Void) { onText = f }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) { emit(allItems) }
        func dataScanner(_ s: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) { emit(allItems) }

        private func emit(_ all: [RecognizedItem]) {
            let sorted = all.compactMap { item -> (String, CGFloat)? in
                if case .text(let t) = item { return (t.transcript, t.bounds.topLeft.y) }
                return nil
            }.sorted { $0.1 < $1.1 }
            onText(sorted.map(\.0))
        }
    }
}

struct ScanTab: View {
    @Environment(\.modelContext) private var ctx
    struct Entry: Identifiable { let id = UUID(); let cardID: Int; var printing: String? }
    @State private var log: [Entry] = []           // every copy scanned this session, oldest first
    @State private var lastID: Int?
    @State private var lastSeen = Date.distantPast
    private let db = CardDB.shared

    var body: some View {
        VStack(spacing: 0) {
            if db.isLoading || db.cards.isEmpty {
                VStack(spacing: 12) {
                    if let e = db.error { Text(e).foregroundStyle(.red) } else { ProgressView(); Text("Downloading card database (first launch only)…") }
                }
                .frame(maxWidth: .infinity, maxHeight: 320)
            } else if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ScannerView(onText: handle).frame(height: 320)
            } else {
                ContentUnavailableView("Scanner unavailable", systemImage: "camera.slash",
                                       description: Text("Allow camera access in Settings, and use a real iPhone (not the simulator)."))
                    .frame(height: 320)
            }

            List {
                Section("Scanned this session — hold each card steady, name and set code visible") {
                    ForEach(recent, id: \.self) { id in
                        if let card = db.cards[id] {
                            CardRow(card: card,
                                    trailing: "×\(log.filter { $0.cardID == id }.count)",
                                    note: printingsSummary(log.filter { $0.cardID == id }.compactMap(\.printing)))
                                .swipeActions {
                                    Button("Undo one", role: .destructive) { undo(id) }
                                }
                        }
                    }
                }
            }
        }
    }

    private var recent: [Int] {
        var seen = Set<Int>()
        return log.reversed().map(\.cardID).filter { seen.insert($0).inserted }
    }

    private func handle(_ texts: [String]) {
        // Identify by printed name first, then set code, then fuzzy name (top lines only).
        let code = texts.lazy.compactMap { db.setCodeMatch($0) }.first
        let named = texts.lazy.compactMap { db.match($0) }.first
        let found = named ?? code?.card ?? texts.prefix(3).lazy.compactMap { db.fuzzyMatch($0) }.first
        guard let card = found else { return }
        // Record the printing only if the code really belongs to the identified card.
        let printing = (code?.card.id == card.id) ? code?.code : nil

        let now = Date()
        defer { lastID = card.id; lastSeen = now }
        // Same card still in frame -> don't double count. Remove it for ~2s to scan another copy.
        if card.id == lastID && now.timeIntervalSince(lastSeen) < 2 {
            // The code often comes into focus after the name: attach it to the copy just added.
            if let p = printing, log.last?.cardID == card.id, log.last?.printing == nil {
                log[log.count - 1].printing = p
                owned(card.id)?.printings.append(p)
            }
            return
        }
        add(card, printing: printing)
    }

    private func owned(_ id: Int) -> OwnedCard? {
        try? ctx.fetch(FetchDescriptor<OwnedCard>(predicate: #Predicate { $0.cardID == id })).first
    }

    private func add(_ card: Card, printing: String?) {
        if let o = owned(card.id) {
            o.quantity += 1
            if let p = printing { o.printings.append(p) }
        } else {
            let o = OwnedCard(cardID: card.id)
            if let p = printing { o.printings = [p] }
            ctx.insert(o)
        }
        log.append(Entry(cardID: card.id, printing: printing))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func undo(_ id: Int) {
        guard let i = log.lastIndex(where: { $0.cardID == id }) else { return }
        let entry = log.remove(at: i)
        if let o = owned(id) {
            o.quantity -= 1
            if let p = entry.printing, let j = o.printings.lastIndex(of: p) { o.printings.remove(at: j) }
            if o.quantity <= 0 { ctx.delete(o) }
        }
    }
}
