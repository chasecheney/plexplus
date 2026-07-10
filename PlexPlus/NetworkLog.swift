import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Model

struct NetworkLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let label: String
    let url: String
    let status: Int?
    let durationMs: Int?
    let bytes: Int?
    let error: String?
    let detail: String?
}

/// In-memory log of every HTTP request the app makes (tokens redacted),
/// shown in the Network Log sheet and exportable as a text file.
@MainActor
final class NetworkLog: ObservableObject {
    static let shared = NetworkLog()

    @Published private(set) var entries: [NetworkLogEntry] = []

    nonisolated init() {}

    func add(_ entry: NetworkLogEntry) {
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    func clear() { entries = [] }

    nonisolated static func redact(_ s: String) -> String {
        s.replacingOccurrences(of: #"X-Plex-Token=[^&\s"']+"#,
                               with: "X-Plex-Token=REDACTED",
                               options: .regularExpression)
    }

    /// Records an entry from any context (hops to the main actor).
    nonisolated static func record(method: String = "GET", url: URL, start: Date,
                                   status: Int? = nil, bytes: Int? = nil,
                                   error: String? = nil, detail: String? = nil,
                                   label: String? = nil) {
        let entry = NetworkLogEntry(
            date: start,
            label: label ?? "\(method) \(url.path)",
            url: redact(url.absoluteString),
            status: status,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            bytes: bytes,
            error: error,
            detail: detail.map { redact($0) })
        Task { @MainActor in NetworkLog.shared.add(entry) }
    }

    var exportText: String {
        let formatter = ISO8601DateFormatter()
        let header = "Network log exported \(formatter.string(from: Date()))  (\(entries.count) entries, tokens redacted)"
        let body = entries.map { e in
            var line = "\(formatter.string(from: e.date))  \(e.label)"
            line += "\n  \(e.url)"
            var stats: [String] = []
            if let s = e.status { stats.append("status \(s)") }
            if let d = e.durationMs { stats.append("\(d) ms") }
            if let b = e.bytes { stats.append("\(b) bytes") }
            if !stats.isEmpty { line += "\n  " + stats.joined(separator: ", ") }
            if let err = e.error { line += "\n  error: \(err)" }
            if let det = e.detail, !det.isEmpty { line += "\n  detail: \(det)" }
            return line
        }.joined(separator: "\n\n")
        return header + "\n\n" + body
    }
}

// MARK: - Export document

struct NetworkLogDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Sheet

struct NetworkLogView: View {
    @ObservedObject private var log = NetworkLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var failuresOnly = false

    private var shown: [NetworkLogEntry] {
        let all = failuresOnly
            ? log.entries.filter { $0.error != nil || ($0.status.map { !(200..<300).contains($0) } ?? false) }
            : log.entries
        return all.reversed()
    }

    var body: some View {
        NavigationStack {
            Group {
                if shown.isEmpty {
                    Text(failuresOnly ? "No failures logged." : "No requests logged yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown) { entry in
                        row(entry)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Network Log")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Toggle("Failures only", isOn: $failuresOnly)
                }
                ToolbarItemGroup(placement: .topBarTrailing) { actions }
                #else
                ToolbarItemGroup {
                    Toggle("Failures only", isOn: $failuresOnly)
                    actions
                }
                #endif
            }
            .fileExporter(isPresented: $exporting,
                          document: NetworkLogDocument(text: log.exportText),
                          contentType: .plainText,
                          defaultFilename: "plex-network-log") { _ in }
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Clear") { log.clear() }
        Button("Copy All") {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(log.exportText, forType: .string)
            #else
            UIPasteboard.general.string = log.exportText
            #endif
        }
        Button("Save\u{2026}") { exporting = true }
        Button("Done") { dismiss() }
    }

    @ViewBuilder
    private func row(_ entry: NetworkLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.label).font(.caption.bold()).lineLimit(1)
                Spacer()
                if let status = entry.status {
                    Text("HTTP \(status)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle((200..<300).contains(status) ? Color.green : Color.red)
                } else if entry.error != nil {
                    Text("failed").font(.caption).foregroundStyle(.red)
                }
            }
            Text(entry.url)
                .font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Text(entry.date, format: .dateTime.hour().minute().second(.twoDigits))
                if let ms = entry.durationMs { Text("\(ms) ms") }
                if let bytes = entry.bytes { Text("\(bytes) B") }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if let error = entry.error {
                Text(error).font(.caption2).foregroundStyle(.red).textSelection(.enabled)
            }
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
