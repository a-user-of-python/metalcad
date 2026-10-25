import SwiftUI
import UIKit

/// Diagnostics: the MCLog ring buffer, the last error code big and
/// copyable, and a JSONL log export for support bundles.
/// (Design: LOGGING.md — no document content is ever logged.)
struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var lastCode: String?
    @State private var logFileURL: URL?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Last error") {
                    if let code = lastCode {
                        Text(code)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                        Button {
                            UIPasteboard.general.string = code
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy last error code",
                                  systemImage: "doc.on.doc")
                                .font(.system(size: 20, weight: .semibold))
                        }
                    } else {
                        Text("No errors yet")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }

                Section("Log actions") {
                    if let url = logFileURL {
                        ShareLink(item: url) {
                            Label("Export log", systemImage: "square.and.arrow.up")
                                .font(.system(size: 20, weight: .semibold))
                        }
                    }
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Text("\(entries.count) recent entries · \(MCLog.shared.entryCount) total in buffer")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }

                Section("Recent log") {
                    if entries.isEmpty {
                        Text("Nothing logged yet.")
                            .font(.system(size: 19))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(entries.reversed().enumerated()), id: \.offset) { _, entry in
                        entryRow(entry)
                    }
                }

                Section("App") {
                    HStack {
                        Text("Version")
                            .font(.system(size: 20))
                        Spacer()
                        Text(appVersion)
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Error codes in catalog")
                            .font(.system(size: 20))
                        Spacer()
                        Text("\(CADErrorCatalog.allCodes.count)")
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .onAppear { refresh() }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func entryRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.level.name)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(size: 18))
                HStack(spacing: 10) {
                    Text(entry.category.rawValue)
                        .foregroundStyle(.secondary)
                    if let code = entry.code {
                        Text(code)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
            }
        }
        .padding(.vertical, 2)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .trace, .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        case .error, .fatal: return .red
        }
    }

    /// Reload the ring buffer and (re)write the JSONL export file so the
    /// ShareLink always hands over the current log.
    private func refresh() {
        entries = MCLog.shared.recentEntries(limit: 200)
        lastCode = MCLog.shared.lastErrorCode()
        copied = false
        let text = entries.map { $0.jsonLine() }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcad-log.jsonl")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            logFileURL = url
        } catch {
            MCLog.shared.log(error: .exportWriteFailed("\(error)"), category: .io)
            logFileURL = nil
        }
    }
}
