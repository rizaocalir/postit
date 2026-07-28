//
//  PostItApp.swift
//  macOS Post-it Uygulaması
//
//  GEREKSİNİMLER:
//  - Xcode 16+, hedef: macOS 15.0 (Sequoia) — Apple Translation framework için gerekli.
//  - Proje > Target > General > Minimum Deployments: macOS 15.0 yapın.
//  - Ek entitlement gerekmez. Çeviri ilk kullanımda dil paketini indirir (bir kez internet ister).
//
//  ÖZELLİKLER:
//  ✓ Gerçek zengin metin: seçili yazıyı Bold yapma (toolbar "B" veya ⌘B)
//  ✓ Bullet (•) ve otomatik artan numaralandırma (1. 2. 3.)
//  ✓ Alarm: tarih/saat seç → "Kapat" denene kadar ekranda kalan hatırlatma paneli
//  ✓ Not sonuna çizgi (———) çekilince üstteki metnin İngilizce çevirisi altta belirir
//  ✓ Toplu görünümde notları sürükleyip yer değiştirme
//  ✓ Not rengi değiştirme (editörde ve sağ tık menüsünde)
//  ✓ Kırmızı, belirgin "+" yeni not butonu
//

import SwiftUI
import AppKit
import Combine
import Translation
import UserNotifications
import UniformTypeIdentifiers

// MARK: - 1. Model

struct StickyNote: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""           // bold başlık
    var text: String = ""            // düz metin (çeviri ve önizleme için)
    var rtfData: Data? = nil         // zengin metin (bold vb.)
    var englishTranslation: String = ""
    var colorHex: String = "#FFF59D"
    var alarmDate: Date? = nil
    var createdAt: Date = Date()
    var archivedAt: Date? = nil      // doluysa not arşivde

    var isArchived: Bool { archivedAt != nil }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "Yeni Not" : first
    }

    init() {}

    // Eski kayıtlarda "title" alanı olmadığı için güvenli çözümleme
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        englishTranslation = try c.decodeIfPresent(String.self, forKey: .englishTranslation) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFF59D"
        alarmDate = try c.decodeIfPresent(Date.self, forKey: .alarmDate)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}

let postItColors: [(name: String, hex: String)] = [
    ("Sarı",    "#FFF59D"),
    ("Pembe",   "#F8BBD0"),
    ("Mavi",    "#B3E5FC"),
    ("Yeşil",   "#C8E6C9"),
    ("Turuncu", "#FFE0B2"),
    ("Mor",     "#E1BEE7"),
]

// MARK: - 2. Not Yöneticisi

final class NoteManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var notes: [StickyNote] = [] { didSet { scheduleSave() } }
    @Published var noteToEdit: StickyNote? = nil   // menü çubuğundan seçilen not
    @Published var notificationsDenied = false     // bildirim izni reddedildi mi

    private let legacyStorageKey = "SavedStickyNotes.v2"
    private var saveTask: Task<Void, Never>?

    /// Notların kaydedildiği dosya: Application Support/PostIt/notes.json
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PostIt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }()

    override init() {
        super.init()
        load()
        UNUserNotificationCenter.current().delegate = self

        // Kayıt debounce'lu olduğu için çıkışta bekleyen değişiklikleri hemen yaz
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveTask?.cancel()
            self?.save()
        }
    }

    /// Bildirim iznini ilk alarm kurulurken sorar (açılışta değil).
    func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    DispatchQueue.main.async { self.notificationsDenied = !granted }
                }
            case .denied:
                DispatchQueue.main.async { self.notificationsDenied = true }
            default:
                DispatchQueue.main.async { self.notificationsDenied = false }
            }
        }
    }

    /// Alarm, uygulama çalışırken tetiklenirse banner yerine "Kapat" denene
    /// kadar ekranda kalan yüzen bir panel gösterilir; ses yine sistemden çalar.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        DispatchQueue.main.async {
            guard let id = UUID(uuidString: identifier),
                  let note = self.notes.first(where: { $0.id == id }), !note.isArchived else { return }
            AlarmPanelManager.shared.show(note: note) { [weak self] in
                self?.openNote(note)
            }
        }
        completionHandler([.sound])
    }

    /// Sistem bildirimine tıklanınca (uygulama arka plandayken) ilgili notu açar.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        DispatchQueue.main.async {
            if let id = UUID(uuidString: identifier),
               let note = self.notes.first(where: { $0.id == id }) {
                self.openNote(note)
            }
        }
        completionHandler()
    }

    func openNote(_ note: StickyNote) {
        noteToEdit = note
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?
            .makeKeyAndOrderFront(nil)
    }

    /// Panoda görünen (arşivlenmemiş) notlar
    var activeNotes: [StickyNote] { notes.filter { !$0.isArchived } }

    /// Arşivdekiler — en son arşivlenen en üstte
    var archivedNotes: [StickyNote] {
        notes.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    @discardableResult
    func addNote() -> StickyNote {
        let note = StickyNote()
        notes.insert(note, at: 0)   // yeni not en başa
        return note
    }

    func deleteNote(id: UUID) {
        cancelAlarm(for: id)
        notes.removeAll { $0.id == id }
    }

    // MARK: Arşiv

    /// Notu arşive taşır. Arşivdeki not çalmasın diye bekleyen alarmı iptal edilir
    /// (alarm tarihi saklı kalır, arşivden çıkarılınca yeniden kurulur).
    func archive(id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        cancelAlarm(for: id)
        withAnimation(.spring(duration: 0.3)) {
            notes[i].archivedAt = Date()
        }
    }

    func unarchive(id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(duration: 0.3)) {
            notes[i].archivedAt = nil
        }
        scheduleAlarm(for: notes[i])   // geçmiş tarihliyse kendiliğinden atlanır
    }

    func emptyArchive() {
        let ids = archivedNotes.map(\.id)
        ids.forEach { cancelAlarm(for: $0) }
        withAnimation { notes.removeAll(where: \.isArchived) }
    }

    func move(from source: UUID, to destination: UUID) {
        guard let fromIdx = notes.firstIndex(where: { $0.id == source }),
              let toIdx = notes.firstIndex(where: { $0.id == destination }),
              fromIdx != toIdx else { return }
        withAnimation(.spring(duration: 0.3)) {
            let item = notes.remove(at: fromIdx)
            notes.insert(item, at: toIdx)
        }
    }

    // MARK: Alarm

    func scheduleAlarm(for note: StickyNote) {
        cancelAlarm(for: note.id)
        guard !note.isArchived, let date = note.alarmDate, date > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "📌 Post-it Hatırlatması"
        content.body = note.displayTitle
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: note.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelAlarm(for id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    // MARK: Kalıcılık

    /// Her tuş vuruşunda diske yazmamak için kayıt 1 sn debounce'lanır.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([StickyNote].self, from: data) {
            notes = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyStorageKey),
                  let decoded = try? JSONDecoder().decode([StickyNote].self, from: data) {
            // Eski sürümün UserDefaults kaydını dosyaya taşı.
            // Eski kayıt bilerek SİLİNMİYOR: eski bir sürüm çalıştırılırsa
            // notları hâlâ görebilsin (dosya varken zaten okunmuyor).
            notes = decoded
            save()
        }
    }
}

// MARK: - 2b. Kalıcı Alarm Paneli

/// Alarm tetiklendiğinde "Kapat" denene kadar ekranda kalan yüzen panel.
final class AlarmPanelManager {
    static let shared = AlarmPanelManager()
    private var panels: [UUID: NSPanel] = [:]

    func show(note: StickyNote, onOpen: @escaping () -> Void) {
        panels[note.id]?.close()

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Post-it Hatırlatması"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(
            rootView: AlarmPanelView(
                note: note,
                onOpen: { [weak self] in self?.close(note.id); onOpen() },
                onClose: { [weak self] in self?.close(note.id) }
            )
        )
        panel.center()
        panel.orderFrontRegardless()
        panels[note.id] = panel
    }

    private func close(_ id: UUID) {
        panels[id]?.close()
        panels[id] = nil
    }
}

struct AlarmPanelView: View {
    let note: StickyNote
    var onOpen: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Post-it Hatırlatması")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.6))
                    Text(note.displayTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .lineLimit(2)
                }
            }

            if let alarm = note.alarmDate {
                Text(alarm.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.black.opacity(0.5))
            }

            HStack {
                Button("Notu Aç") { onOpen() }
                Spacer()
                Button("Kapat") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(Color(hex: note.colorHex))
    }
}

// MARK: - 3. Zengin Metin Editörü (NSTextView sarmalayıcı)

final class EditorController: ObservableObject {
    weak var textView: NSTextView?

    func toggleBold() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else {
            // Seçim yoksa yazım modunu değiştir
            let font = (tv.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 14)
            tv.typingAttributes[.font] = toggled(font)
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: 14)
            storage.addAttribute(.font, value: toggled(font), range: subRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    private func toggled(_ font: NSFont) -> NSFont {
        let isBold = font.fontDescriptor.symbolicTraits.contains(.bold)
        let fm = NSFontManager.shared
        return isBold
            ? fm.convert(font, toNotHaveTrait: .boldFontMask)
            : fm.convert(font, toHaveTrait: .boldFontMask)
    }

    func insertBullet() { insertAtLineStart("•  ") }

    func insertNumber() {
        guard let tv = textView else { return }
        // Bir önceki satırda numara varsa devam ettir
        let text = tv.string as NSString
        let cursor = tv.selectedRange().location
        var number = 1
        let upToCursor = text.substring(to: min(cursor, text.length))
        if let lastLine = upToCursor.split(separator: "\n").last {
            let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
            if let dot = trimmed.firstIndex(of: "."),
               let n = Int(trimmed[trimmed.startIndex..<dot]) {
                number = n + 1
            }
        }
        insertAtLineStart("\(number). ")
    }

    func insertDivider() {
        guard let tv = textView else { return }
        let needsNewline = !(tv.string.isEmpty || tv.string.hasSuffix("\n"))
        let divider = (needsNewline ? "\n" : "") + "———————————\n"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText(divider, replacementRange: tv.selectedRange())
    }

    private func insertAtLineStart(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let cursor = tv.selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: min(cursor, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tv.insertText(prefix, replacementRange: tv.selectedRange())
        } else {
            tv.insertText("\n" + prefix, replacementRange: NSRange(location: ns.length, length: 0))
        }
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var rtfData: Data?
    @Binding var plainText: String
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = NSColor.black
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.usesFontPanel = true   // ⌘B ile bold çalışsın

        if let data = rtfData,
           let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
            tv.textStorage?.setAttributedString(attr)
        } else if !plainText.isEmpty {
            tv.string = plainText
        }
        controller.textView = tv
        context.coordinator.lastData = rtfData
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        controller.textView = tv
        context.coordinator.parent = self
        // Dışarıdan veri değiştiyse (ve kullanıcı yazmıyorsa) güncelle
        if rtfData != context.coordinator.lastData, !context.coordinator.isEditing,
           let data = rtfData,
           let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
            tv.textStorage?.setAttributedString(attr)
            context.coordinator.lastData = rtfData
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastData: Data?
        var isEditing = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        /// Enter'a basıldığında bullet/numaralandırmayı otomatik sürdürür.
        /// Boş bir maddede Enter'a basılırsa liste iptal edilir.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }

            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            guard sel.location <= ns.length else { return false }
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }
            let lineLen = (line as NSString).length

            // ── Bullet devamı: "•  madde" ──
            if line.hasPrefix("•") {
                let content = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    // Boş madde → listeyi iptal et (işareti sil)
                    textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: lineLen))
                } else {
                    textView.insertText("\n•  ", replacementRange: sel)
                }
                return true
            }

            // ── Numara devamı: "3. madde" ──
            if let match = line.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
                let numberPart = line[line.startIndex..<match.upperBound]
                let n = Int(numberPart.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) ?? 0
                let content = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: lineLen))
                } else {
                    textView.insertText("\n\(n + 1). ", replacementRange: sel)
                }
                return true
            }

            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let storage = tv.textStorage else { return }
            isEditing = true
            let data = storage.rtf(from: NSRange(location: 0, length: storage.length),
                                   documentAttributes: [:])
            lastData = data
            parent.rtfData = data
            parent.plainText = storage.string
            DispatchQueue.main.async { self.isEditing = false }
        }
    }
}

// MARK: - 4. Not Editörü Ekranı

struct EditNoteView: View {
    @Binding var note: StickyNote
    @ObservedObject var manager: NoteManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var editor = EditorController()
    @State private var showAlarmPopover = false
    @State private var tempAlarmDate = Date().addingTimeInterval(3600)

    // Çeviri
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var textToTranslate = ""
    @State private var debounceTask: Task<Void, Never>?

    private var noteColor: Color { Color(hex: note.colorHex) }

    /// "———" veya "---" çizgisinden önceki metni döndürür; çizgi yoksa nil
    private var textAboveDivider: String? {
        let lines = note.text.components(separatedBy: "\n")
        guard let idx = lines.lastIndex(where: { isDividerLine($0) }), idx > 0 else { return nil }
        let above = lines[0..<idx].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return above.isEmpty ? nil : above
    }

    private func isDividerLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return false }
        return t.allSatisfy { "-—–―_".contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)

            // Bold başlık alanı — önce başlık, sonra not
            TextField("Başlık", text: $note.title)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider().opacity(0.15).padding(.horizontal, 12)

            RichTextEditor(rtfData: $note.rtfData, plainText: $note.text, controller: editor)
                .background(Color.black.opacity(0.03))

            if !note.englishTranslation.isEmpty {
                translationPanel
            }

            footer
        }
        .background(noteColor)
        .frame(width: 440, height: 540)
        .onChange(of: note.text) { _, _ in
            scheduleTranslation()
        }
        .onChange(of: note.title) { _, _ in
            scheduleTranslation()
        }
        .onAppear {
            if textAboveDivider != nil { scheduleTranslation() }
        }
        .translationTask(translationConfig) { session in
            let source = textToTranslate
            guard !source.isEmpty else { return }
            do {
                let response = try await session.translate(source)
                note.englishTranslation = response.targetText
            } catch {
                note.englishTranslation = "⚠️ Çeviri yapılamadı: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Çeviri tetikleme (debounce'lu)

    private func scheduleTranslation() {
        debounceTask?.cancel()
        guard let above = textAboveDivider else {
            note.englishTranslation = ""
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            textToTranslate = note.title.isEmpty ? above : note.title + "\n" + above
            if translationConfig == nil {
                translationConfig = TranslationSession.Configuration(
                    source: nil,  // dili otomatik algıla
                    target: Locale.Language(identifier: "en")
                )
            } else {
                translationConfig?.invalidate()
            }
        }
    }

    // MARK: Alt görünümler

    private var toolbar: some View {
        HStack(spacing: 14) {
            Group {
                Button(action: { editor.toggleBold() }) {
                    Image(systemName: "bold").fontWeight(.bold)
                }
                .help("Seçili metni kalın yap (⌘B)")
                .keyboardShortcut("b", modifiers: .command)

                Button(action: { editor.insertBullet() }) {
                    Image(systemName: "list.bullet")
                }
                .help("Madde işareti ekle")

                Button(action: { editor.insertNumber() }) {
                    Image(systemName: "list.number")
                }
                .help("Numaralı madde ekle")

                Button(action: { editor.insertDivider() }) {
                    Image(systemName: "minus")
                }
                .help("Çizgi çek → üstteki metin İngilizce'ye çevrilir")
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.black.opacity(0.65))

            Spacer()

            // Renk seçici
            HStack(spacing: 6) {
                ForEach(postItColors, id: \.hex) { c in
                    Circle()
                        .fill(Color(hex: c.hex))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(
                            note.colorHex == c.hex ? Color.black.opacity(0.6) : Color.black.opacity(0.15),
                            lineWidth: note.colorHex == c.hex ? 2 : 1))
                        .onTapGesture { note.colorHex = c.hex }
                        .help(c.name)
                }
            }

            // Alarm
            Button(action: {
                manager.requestNotificationPermissionIfNeeded()
                tempAlarmDate = note.alarmDate ?? Date().addingTimeInterval(3600)
                showAlarmPopover = true
            }) {
                Image(systemName: note.alarmDate == nil ? "bell" : "bell.badge.fill")
                    .foregroundStyle(note.alarmDate == nil ? Color.black.opacity(0.65) : .red)
            }
            .buttonStyle(.plain)
            .help("Alarm kur")
            .popover(isPresented: $showAlarmPopover) {
                VStack(spacing: 12) {
                    Text("Alarm Zamanı").font(.headline)
                    if manager.notificationsDenied {
                        Text("⚠️ Bildirim izni kapalı! Sistem Ayarları > Bildirimler > PostIt'ten izin ver, yoksa alarm görünmez.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DatePicker("", selection: $tempAlarmDate, in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .labelsHidden()
                    HStack {
                        if note.alarmDate != nil {
                            Button("Alarmı Kaldır", role: .destructive) {
                                note.alarmDate = nil
                                manager.cancelAlarm(for: note.id)
                                showAlarmPopover = false
                            }
                        }
                        Spacer()
                        Button("Kur") {
                            note.alarmDate = tempAlarmDate
                            manager.scheduleAlarm(for: note)
                            showAlarmPopover = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .frame(width: 260)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.05))
    }

    private var translationPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("English", systemImage: "globe")
                .font(.caption.bold())
                .foregroundStyle(.blue)
            ScrollView {
                Text(note.englishTranslation)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(.black.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 90)
        }
        .padding(10)
        .background(Color.white.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack {
            if let alarm = note.alarmDate {
                Label(alarm.formatted(date: .abbreviated, time: .shortened), systemImage: "alarm")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            }
            Spacer()

            // İşi bitince: notu arşive gönderip editörü kapat
            if note.isArchived {
                Button("Arşivden Çıkar", systemImage: "tray.and.arrow.up") {
                    manager.unarchive(id: note.id)
                    dismiss()
                }
                .help("Notu tekrar panoya al")
            } else {
                Button("Arşive At", systemImage: "archivebox") {
                    manager.archive(id: note.id)
                    dismiss()
                }
                .help("İşi biten notu panodan kaldır, arşivde sakla")
            }

            Button("Tamam") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.7))
        }
        .padding(12)
    }
}

// MARK: - 5. Not Kartı

struct NoteCardView: View {
    let note: StickyNote

    private var attributedPreview: AttributedString {
        if let data = note.rtfData,
           let ns = NSAttributedString(rtf: data, documentAttributes: nil) {
            var attr = AttributedString(ns)
            attr.foregroundColor = .black.opacity(0.8)
            return attr
        }
        return AttributedString(note.text.isEmpty ? "Boş not" : note.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !note.title.isEmpty {
                Text(note.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .lineLimit(1)
            }

            Text(attributedPreview)
                .font(.system(size: 12))
                .lineLimit(note.title.isEmpty ? 7 : 5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if !note.englishTranslation.isEmpty && !note.englishTranslation.hasPrefix("⚠️") {
                Text("EN: " + note.englishTranslation)
                    .font(.system(size: 9))
                    .italic()
                    .lineLimit(2)
                    .foregroundStyle(.blue.opacity(0.7))
            }

            if let archived = note.archivedAt {
                Label("Arşiv · " + archived.formatted(date: .numeric, time: .omitted),
                      systemImage: "archivebox.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.45))
            } else if let alarm = note.alarmDate {
                Label(alarm.formatted(date: .numeric, time: .shortened), systemImage: "alarm.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
        .padding(12)
        .frame(width: 170, height: 170, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: note.colorHex))
                .shadow(color: .black.opacity(note.isArchived ? 0.12 : 0.25),
                        radius: 5, x: 1, y: 3)
        )
        .saturation(note.isArchived ? 0.35 : 1)      // arşivdekiler soluk görünsün
        .opacity(note.isArchived ? 0.75 : 1)
        .rotationEffect(.degrees(Double(note.id.uuid.0 % 5) - 2.0)) // hafif, açılışlar arası sabit post-it eğimi
    }
}

// MARK: - 6. Sürükle-Bırak Delegesi

struct NoteDropDelegate: DropDelegate {
    let targetNote: StickyNote
    let manager: NoteManager
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != targetNote.id else { return }
        manager.move(from: dragging, to: targetNote.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

// MARK: - 7. Ana Görünüm

struct ContentView: View {
    @EnvironmentObject var manager: NoteManager
    @State private var selectedNote: StickyNote?
    @State private var draggingID: UUID?
    @State private var showingArchive = false

    private var visibleNotes: [StickyNote] {
        showingArchive ? manager.archivedNotes : manager.activeNotes
    }

    private func openPendingNote() {
        if let pending = manager.noteToEdit {
            // Arşivdeki bir not açılıyorsa arşiv sekmesine geç
            showingArchive = pending.isArchived
            selectedNote = pending
            manager.noteToEdit = nil
        }
    }

    var body: some View {
        ZStack {
            // Mantar pano hissi veren arka plan
            LinearGradient(colors: [Color(hex: "#F5EFE0"), Color(hex: "#EDE4CE")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if visibleNotes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: showingArchive ? "archivebox" : "note.text")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(showingArchive ? "Arşiv boş" : "Henüz not yok")
                        .font(.title3).foregroundStyle(.secondary)
                    Text(showingArchive
                         ? "İşi biten notları sağ tık → Arşive Taşı ile buraya gönder"
                         : "Sağ üstteki kırmızı + ile ilk notunu ekle")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 20)], spacing: 24) {
                        ForEach(visibleNotes) { note in
                            NoteCardView(note: note)
                                .opacity(draggingID == note.id ? 0.4 : 1)
                                .onTapGesture { selectedNote = note }
                                .if(!showingArchive) { view in
                                    view
                                        .onDrag {
                                            draggingID = note.id
                                            return NSItemProvider(object: note.id.uuidString as NSString)
                                        }
                                        .onDrop(of: [UTType.text],
                                                delegate: NoteDropDelegate(targetNote: note,
                                                                           manager: manager,
                                                                           draggingID: $draggingID))
                                }
                                .contextMenu {
                                    Menu("Rengi Değiştir") {
                                        ForEach(postItColors, id: \.hex) { c in
                                            Button(c.name) {
                                                if let i = manager.notes.firstIndex(where: { $0.id == note.id }) {
                                                    manager.notes[i].colorHex = c.hex
                                                }
                                            }
                                        }
                                    }
                                    if note.isArchived {
                                        Button("Arşivden Çıkar", systemImage: "tray.and.arrow.up") {
                                            manager.unarchive(id: note.id)
                                        }
                                    } else {
                                        Button("Arşive Taşı", systemImage: "archivebox") {
                                            manager.archive(id: note.id)
                                        }
                                    }
                                    Divider()
                                    Button("Sil", role: .destructive) {
                                        manager.deleteNote(id: note.id)
                                    }
                                }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(showingArchive ? "Arşiv" : "Post-it Notlarım")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("", selection: $showingArchive) {
                    Label("Notlar", systemImage: "note.text").tag(false)
                    Label("Arşiv (\(manager.archivedNotes.count))", systemImage: "archivebox").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            ToolbarItem(placement: .primaryAction) {
                if showingArchive {
                    Button("Arşivi Boşalt", systemImage: "trash") { manager.emptyArchive() }
                        .disabled(manager.archivedNotes.isEmpty)
                        .help("Arşivdeki tüm notları kalıcı olarak sil")
                } else {
                    Button(action: { selectedNote = manager.addNote() }) {
                        ZStack {
                            Circle().fill(Color.red).frame(width: 30, height: 30)
                                .shadow(color: .red.opacity(0.4), radius: 3, y: 1)
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Yeni not ekle")
                }
            }
        }
        .sheet(item: $selectedNote) { note in
            if let index = manager.notes.firstIndex(where: { $0.id == note.id }) {
                EditNoteView(note: $manager.notes[index], manager: manager)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { openPendingNote() }
        .onChange(of: manager.noteToEdit) { _, _ in openPendingNote() }
    }
}

// MARK: - 7b. Menü Çubuğu Görünümü

struct MenuBarNotesView: View {
    @EnvironmentObject var manager: NoteManager
    @Environment(\.openWindow) private var openWindow

    private func openEditor(for note: StickyNote?) {
        manager.noteToEdit = note
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Başlık + kırmızı yeni not butonu
            HStack {
                Text("Post-it Notlarım").font(.headline)
                Spacer()
                Button(action: { openEditor(for: manager.addNote()) }) {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help("Yeni not ekle")
            }
            .padding(12)

            Divider()

            if manager.activeNotes.isEmpty {
                Text(manager.archivedNotes.isEmpty ? "Henüz not yok" : "Panoda not yok — hepsi arşivde")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.activeNotes) { note in
                            Button(action: { openEditor(for: note) }) {
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(hex: note.colorHex))
                                        .frame(width: 14, height: 14)
                                        .overlay(RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(.black.opacity(0.15)))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(note.displayTitle)
                                            .font(.system(size: 12, weight: .bold))
                                            .lineLimit(1)
                                        if !note.text.isEmpty {
                                            Text(note.text.replacingOccurrences(of: "\n", with: " "))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if note.alarmDate != nil {
                                        Image(systemName: "alarm.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Arşive Taşı", systemImage: "archivebox") {
                                    manager.archive(id: note.id)
                                }
                                Button("Sil", role: .destructive) {
                                    manager.deleteNote(id: note.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            HStack {
                Button("Tümünü Aç") { openEditor(for: nil) }
                Spacer()
                Button("Çıkış") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .frame(width: 280)
    }
}

// MARK: - 8. Yardımcılar

extension View {
    /// Koşul sağlanıyorsa verilen değişiklikleri uygular (ör. yalnızca panoda sürükle-bırak)
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        self.init(.sRGB,
                  red: Double((int >> 16) & 0xFF) / 255,
                  green: Double((int >> 8) & 0xFF) / 255,
                  blue: Double(int & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - 9. Uygulama

@main
struct PostItApp: App {
    @StateObject private var manager = NoteManager()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(manager)
        }
        .windowResizability(.contentMinSize)

        // Sağ üst menü çubuğu simgesi
        MenuBarExtra("Post-it Notlarım", systemImage: "note.text") {
            MenuBarNotesView()
                .environmentObject(manager)
        }
        .menuBarExtraStyle(.window)
    }
}
