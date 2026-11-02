import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - iMessage lookup via private IDS.framework (same service Messages.app uses)

enum Availability {
    case idle, checking, yes, no, error(String)
}

struct LookupError: Error {
    let message: String
}

final class IDSLookup {
    static let shared = IDSLookup()
    private let controller: AnyObject?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/IDS.framework/IDS", RTLD_NOW)
        guard let cls = NSClassFromString("IDSIDQueryController") as? NSObject.Type else {
            controller = nil
            return
        }
        controller = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue()
    }

    /// Queries up to `RateLimiter.batchSize` destinations at once.
    /// Returns IDS status codes: 1 = registered for iMessage, 2 = not registered, 0 = unknown.
    /// Uses the non-forced refresh, so still-valid results come from the system cache and don't spend quota.
    @MainActor
    func query(_ destinations: [String]) async -> Result<[String: Int], LookupError> {
        let sel = NSSelectorFromString("refreshIDStatusForDestinations:service:listenerID:queue:errorCompletionBlock:")
        guard let controller, let method = class_getInstanceMethod(type(of: controller), sel) else {
            return .failure(LookupError(message: "IDS недоступен"))
        }
        typealias Fn = @convention(c) (AnyObject, Selector, NSArray, NSString, NSString, DispatchQueue, @escaping @convention(block) (NSObject) -> Void) -> Bool
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)

        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Result<[String: Int], LookupError>) -> Void = { result in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            // The block receives a CUTResult: state 0 = success (inValue), otherwise inError.
            let sent = fn(controller, sel, destinations as NSArray, "com.apple.madrid", "imessage-checker", .main) { result in
                if let values = result.value(forKey: "inValue") as? [String: NSNumber] {
                    finish(.success(values.mapValues(\.intValue)))
                } else {
                    let error = result.value(forKey: "inError") as? NSError
                    finish(.failure(LookupError(message: error?.localizedDescription ?? "Ошибка IDS")))
                }
            }
            if !sent { finish(.failure(LookupError(message: "Запрос отклонён"))) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(.failure(LookupError(message: "Нет ответа"))) }
        }
    }

    /// Turns user input into an IDS URI: "mailto:…" or "tel:+…".
    static func destination(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("@") {
            return s.count > 3 ? "mailto:" + s.lowercased() : nil
        }
        var digits = s.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        if !s.hasPrefix("+") && digits.count == 11 && digits.hasPrefix("8") {
            digits = "7" + digits.dropFirst()   // 8XXXXXXXXXX → +7XXXXXXXXXX
        }
        return "tel:+" + digits
    }
}

// MARK: - Limits

/// Keeps lookups well inside Apple's limits:
/// - IDS server bag allows at most 35 URIs per multi-query (`max-uri-multi-query`), we send 20;
/// - a pause between requests;
/// - a rolling hourly cap, persisted across launches so restarting the app doesn't reset it.
struct RateLimiter {
    static let batchSize = 20
    static let hourlyCap = 500
    static let spacing: Duration = .seconds(3)
    static let backoff: Duration = .seconds(15 * 60)

    private static let key = "lookupTimestamps"

    private var timestamps: [Double] {
        get {
            let hourAgo = Date().timeIntervalSince1970 - 3600
            return (UserDefaults.standard.array(forKey: Self.key) as? [Double] ?? []).filter { $0 > hourAgo }
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    var available: Int { max(0, Self.hourlyCap - timestamps.count) }

    /// When the oldest lookup leaves the one-hour window.
    var nextSlot: Date {
        Date(timeIntervalSince1970: (timestamps.min() ?? Date().timeIntervalSince1970) + 3600)
    }

    func record(_ count: Int) {
        let now = Date().timeIntervalSince1970
        timestamps = timestamps + Array(repeating: now, count: count)
    }
}

// MARK: - File parsing

enum ContactParser {
    private static let email = try! NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
    private static let phone = try! NSRegularExpression(pattern: #"\+?\d[\d\s().\-]{5,}\d"#)

    /// Extracts unique emails and phone numbers in the order they appear.
    static func contacts(in text: String) -> [(contact: String, destination: String)] {
        var found: [(location: Int, contact: String)] = []
        var rest = text as NSString

        for match in email.matches(in: text, range: NSRange(location: 0, length: rest.length)) {
            found.append((match.range.location, rest.substring(with: match.range)))
            // Blank out emails so digits inside them aren't picked up as phones.
            rest = rest.replacingCharacters(in: match.range, with: String(repeating: " ", count: match.range.length)) as NSString
        }
        let blanked = rest as String
        for match in phone.matches(in: blanked, range: NSRange(location: 0, length: rest.length)) {
            for line in rest.substring(with: match.range).components(separatedBy: .newlines) {
                let candidate = line.trimmingCharacters(in: .whitespaces)
                // Without a country code a number can't be looked up; this also skips dates and ids.
                let digits = candidate.filter(\.isNumber).count
                guard candidate.hasPrefix("+") ? digits >= 8 : digits >= 10 else { continue }
                found.append((match.range.location, candidate))
            }
        }

        var seen = Set<String>()
        return found.sorted { $0.location < $1.location }.compactMap { item in
            guard let destination = IDSLookup.destination(from: item.contact), seen.insert(destination).inserted else { return nil }
            return (item.contact, destination)
        }
    }

    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1251)
            ?? String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Batch checking

@MainActor
final class BatchChecker: ObservableObject {
    enum Status {
        case pending, yes, no, failed

        var title: String {
            switch self {
            case .pending: "…"
            case .yes: "iMessage"
            case .no: "Нет"
            case .failed: "Не удалось"
            }
        }
    }

    struct Row: Identifiable {
        let id: String          // IDS destination, unique
        let contact: String
        var status: Status = .pending
    }

    @Published var rows: [Row] = []
    @Published var fileName = ""
    @Published var isRunning = false
    @Published var note: String?

    private var task: Task<Void, Never>?
    private let limiter = RateLimiter()

    var done: Int { rows.filter { $0.status != .pending }.count }
    var found: Int { rows.filter { $0.status == .yes }.count }

    func load(_ url: URL) {
        stop()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            rows = ContactParser.contacts(in: try ContactParser.read(url)).map { Row(id: $0.destination, contact: $0.contact) }
            fileName = url.lastPathComponent
            note = rows.isEmpty ? "В файле не найдено контактов" : nil
            if !rows.isEmpty { start() }
        } catch {
            note = "Не удалось открыть файл"
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        note = nil
    }

    func clear() {
        stop()
        rows = []
        fileName = ""
    }

    private func run() async {
        var attempts = 0
        while !Task.isCancelled {
            let pending = rows.filter { $0.status == .pending }.map(\.id)
            guard !pending.isEmpty else { break }

            let available = limiter.available
            if available == 0 {
                note = "Лимит \(RateLimiter.hourlyCap) проверок в час. Продолжу в \(limiter.nextSlot.formatted(date: .omitted, time: .shortened))"
                try? await Task.sleep(until: .now + .seconds(max(1, limiter.nextSlot.timeIntervalSinceNow)), clock: .continuous)
                continue
            }
            note = nil

            let batch = Array(pending.prefix(min(RateLimiter.batchSize, available)))
            limiter.record(batch.count)

            switch await IDSLookup.shared.query(batch) {
            case .success(let statuses):
                attempts = 0
                for id in batch {
                    let status: Status = switch statuses[id] {
                        case 1: .yes
                        case 2: .no
                        default: .failed
                    }
                    update(id, to: status)
                }
            case .failure(let error):
                // Most likely Apple throttling: back off for a while, then retry the same batch.
                attempts += 1
                if attempts >= 3 {
                    batch.forEach { update($0, to: .failed) }
                    attempts = 0
                } else {
                    let resume = Date().addingTimeInterval(15 * 60).formatted(date: .omitted, time: .shortened)
                    note = "\(error.message). Пауза до \(resume)"
                    try? await Task.sleep(for: RateLimiter.backoff)
                    continue
                }
            }
            try? await Task.sleep(for: RateLimiter.spacing)
        }
        if !Task.isCancelled {
            isRunning = false
            note = nil
        }
    }

    private func update(_ id: String, to status: Status) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].status = status }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = (fileName as NSString).deletingPathExtension + " — iMessage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        func field(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ["Контакт,Адрес,iMessage"] + rows.map { row in
            [row.contact, row.id.replacingOccurrences(of: "mailto:", with: "").replacingOccurrences(of: "tel:", with: ""), row.status == .pending ? "" : row.status.title]
                .map(field).joined(separator: ",")
        }
        // BOM so Excel detects UTF-8 (Cyrillic).
        try? ("\u{FEFF}" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var batch = BatchChecker()
    @State private var input = ""
    @State private var state: Availability = .idle
    @State private var importing = false
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                TextField("Email или телефон", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(check)
                    .onChange(of: input) { _, _ in state = .idle }

                Button { importing = true } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("Проверить файл (CSV, TXT, MD)")
            }

            status
                .frame(height: 18)

            if !batch.rows.isEmpty || batch.note != nil {
                results
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: batch.rows.isEmpty ? 340 : 480)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.blue, lineWidth: 2).padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            batch.load(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text, UTType(filenameExtension: "md") ?? .text]) { result in
            if case .success(let url) = result { batch.load(url) }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .idle:
            Text("↩︎ чтобы проверить · или перетащите файл").foregroundStyle(.tertiary)
        case .checking:
            ProgressView().controlSize(.small)
        case .yes:
            label("iMessage доступен", color: .blue)
        case .no:
            label("Нет iMessage", color: .secondary)
        case .error(let message):
            label(message, color: .orange)
        }
    }

    private var results: some View {
        VStack(spacing: 10) {
            Divider()

            HStack {
                Text(batch.fileName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(batch.done)/\(batch.rows.count) · iMessage: \(batch.found)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))

            if !batch.rows.isEmpty {
                Table(batch.rows) {
                    TableColumn("Контакт", value: \.contact)
                    TableColumn("Результат") { row in
                        HStack(spacing: 6) {
                            Circle().fill(color(for: row.status)).frame(width: 7, height: 7)
                            Text(row.status.title)
                        }
                    }
                    .width(110)
                }
                .frame(height: 260)
            }

            if let note = batch.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
            }

            HStack {
                Button(batch.isRunning ? "Стоп" : "Продолжить") {
                    batch.isRunning ? batch.stop() : batch.start()
                }
                .disabled(!batch.isRunning && batch.done == batch.rows.count)
                Button("Очистить", action: batch.clear)
                Spacer()
                Button("Экспорт CSV", action: batch.exportCSV)
                    .disabled(batch.rows.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func color(for status: BatchChecker.Status) -> Color {
        switch status {
        case .pending: .clear
        case .yes: .blue
        case .no: .secondary
        case .failed: .orange
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.system(size: 13, weight: .medium))
    }

    private func check() {
        guard let destination = IDSLookup.destination(from: input) else {
            state = .error("Неверный формат")
            return
        }
        let limiter = RateLimiter()
        guard limiter.available > 0 else {
            state = .error("Лимит в час исчерпан")
            return
        }
        limiter.record(1)
        state = .checking
        Task {
            switch await IDSLookup.shared.query([destination]) {
            case .success(let statuses) where statuses[destination] == 1: state = .yes
            case .success(let statuses) where statuses[destination] == 2: state = .no
            case .success: state = .error("Не удалось проверить")
            case .failure(let error): state = .error(error.message)
            }
        }
    }
}

@main
struct IMessageCheckerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("iMessage Checker", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
