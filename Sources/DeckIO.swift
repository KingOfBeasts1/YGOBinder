import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreTransferable

enum DeckIO {
    static let ydkType = UTType(filenameExtension: "ydk") ?? .plainText

    struct Parsed {
        var ids: [Int] = []          // one entry per copy (main + extra)
        var unmatched: [String] = [] // lines that couldn't be matched to a card
        var sideSkipped = 0          // side deck cards (decks here have no side deck)
    }

    // "3x Dark Magician", "3 x Dark Magician", "3 Dark Magician", "Dark Magician x3"
    private static let leadX = try! NSRegularExpression(pattern: "^(\\d+)\\s*[xX×]\\s+(.+)$")
    private static let leadPlain = try! NSRegularExpression(pattern: "^(\\d+)\\s+(.+)$")
    private static let trail = try! NSRegularExpression(pattern: "^(.+?)\\s+[xX×]\\s*(\\d+)$")

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    // MARK: Import

    /// Understands .ydk files (#main / #extra / !side with passcodes) and plain-text lists of card names.
    static func parse(_ text: String) -> Parsed {
        let db = CardDB.shared
        var out = Parsed()
        var inSide = false

        func add(_ card: Card, _ n: Int) {
            if inSide { out.sideSkipped += n } else { out.ids += Array(repeating: card.id, count: n) }
        }
        func resolve(_ s: String) -> Card? { db.match(s) ?? db.fuzzyMatch(s) }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let key = CardDB.normalize(line)

            // YDK section markers and comments
            if line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("//") {
                switch key {
                case "side": inSide = true
                case "main", "extra": inSide = false
                default: break
                }
                continue
            }
            // Plain-text section headers ("Main Deck", "Extra Deck (15)", "Side Deck:", "Monsters (12)")
            if key.hasPrefix("sidedeck") || key == "side" { inSide = true; continue }
            if key.hasPrefix("maindeck") || key.hasPrefix("extradeck") || key == "main" || key == "extra" { inSide = false; continue }
            if ["monster", "monsters", "spell", "spells", "trap", "traps"].contains(where: {
                key.hasPrefix($0) && key.dropFirst($0.count).allSatisfy(\.isNumber)
            }) { continue }

            // YDK passcode line
            if line.allSatisfy(\.isNumber) {
                if let id = Int(line), let c = db.cards[id] { add(c, 1) } else { out.unmatched.append(line) }
                continue
            }
            // Whole line is a card name (handles names that start with a number, e.g. "7 Colored Fish")
            if let c = db.match(line) { add(c, 1); continue }

            var done = false
            for re in [leadX, leadPlain] where !done {
                if let g = groups(re, line), let n = Int(g[0]), let c = resolve(g[1]) {
                    add(c, min(n, 60)); done = true
                }
            }
            if done { continue }
            if let g = groups(trail, line), let n = Int(g[1]), let c = resolve(g[0]) { add(c, min(n, 60)); continue }
            if let c = db.fuzzyMatch(line) { add(c, 1); continue }
            out.unmatched.append(line)
        }
        return out
    }

    /// Creates a deck from text and returns a human-readable result message.
    static func importDeck(name: String, text: String, into ctx: ModelContext) -> String {
        guard !CardDB.shared.cards.isEmpty else { return "The card database is still loading — try again in a moment." }
        let p = parse(text)
        guard !p.ids.isEmpty else { return "No cards were recognized in “\(name)”." }
        let deck = Deck(name: name)
        deck.cardIDs = p.ids
        ctx.insert(deck)
        var msg = "Imported “\(name)”: \(p.ids.count) cards."
        if !p.unmatched.isEmpty {
            msg += " Not recognized (\(p.unmatched.count)): " + p.unmatched.prefix(5).joined(separator: ", ")
            if p.unmatched.count > 5 { msg += "…" }
            msg += "."
        }
        if p.sideSkipped > 0 { msg += " Skipped \(p.sideSkipped) side deck cards." }
        return msg
    }

    // MARK: Export

    /// Standard .ydk format used by EDOPro, YGOPro, Master Duel deck tools, etc.
    static func ydk(_ deck: Deck) -> String {
        let db = CardDB.shared
        let extra = deck.cardIDs.filter { db.cards[$0]?.isExtraDeck == true }.sorted()
        let main = deck.cardIDs.filter { db.cards[$0]?.isExtraDeck != true }.sorted()
        let lines = ["#created by YGOBinder", "#main"] + main.map(String.init)
            + ["#extra"] + extra.map(String.init) + ["!side", ""]
        return lines.joined(separator: "\n")
    }

    /// Readable list: "3x Dark Magician", grouped into Main / Extra.
    static func text(_ deck: Deck) -> String {
        let db = CardDB.shared
        func lines(extra: Bool) -> [String] {
            Dictionary(grouping: deck.cardIDs, by: { $0 })
                .compactMap { id, ids -> (String, Int)? in
                    guard let c = db.cards[id], c.isExtraDeck == extra else { return nil }
                    return (c.name, ids.count)
                }
                .sorted { $0.0 < $1.0 }
                .map { "\($0.1)x \($0.0)" }
        }
        var out = ["Main Deck"] + lines(extra: false)
        let extra = lines(extra: true)
        if !extra.isEmpty { out += ["", "Extra Deck"] + extra }
        return out.joined(separator: "\n")
    }
}

/// Lets ShareLink hand the deck to Files, AirDrop, Messages, etc. as a real `.ydk` file.
struct DeckFile: Transferable {
    let name: String
    let ydk: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: DeckIO.ydkType) { f in
            let safe = f.name.replacingOccurrences(of: "/", with: "-")
            let url = URL.temporaryDirectory.appending(path: "\(safe).ydk")
            try f.ydk.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

struct PasteImportSheet: View {
    var onImport: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Imported Deck"
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Deck name") { TextField("Name", text: $name) }
                Section("Deck list — .ydk contents, or lines like “3x Dark Magician”") {
                    Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                        text = UIPasteboard.general.string ?? ""
                    }
                    TextEditor(text: $text).frame(minHeight: 260).font(.callout.monospaced())
                }
            }
            .navigationTitle("Paste Deck List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onImport(name, text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
