// main.swift — the window UI for Shrink Design Zip.
//
// Three states in one window:
//   idle     drop zone + "Choose File…" button
//   running  phase list, live size readout, progress bar
//   done     before/after summary, "Save…" and "Shrink Another"
//
// The optimizer itself is shrink-design-zip.sh, launched detached with a
// PROGRESS file that this UI polls. Nothing about the shrinking logic lives
// here.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Model

enum Stage: Equatable { case idle, running, finished }

struct Phase: Identifiable, Equatable {
    let id: Int
    var label: String
    var state: State = .pending
    enum State { case pending, active, complete }
}

@MainActor
final class Model: ObservableObject {
    @Published var stage: Stage = .idle
    @Published var fileName = ""
    @Published var originalBytes: Int64 = 0
    @Published var currentBytes: Int64 = 0      // zipped only; disk sizes are not comparable
    @Published var phases: [Phase] = Model.freshPhases
    @Published var detail = ""
    @Published var fraction: Double = 0
    @Published var producedPath: String?
    @Published var succeeded = false
    @Published var errorText: String?
    @Published var isDropTarget = false

    static var freshPhases: [Phase] {
        [.init(id: 1, label: "Removing unused images"),
         .init(id: 2, label: "Removing duplicates"),
         .init(id: 3, label: "Shrinking images"),
         .init(id: 4, label: "Verifying")]
    }

    private var timer: Timer?
    private var progressURL: URL?
    private var consumed = 0
    private var sourceURL: URL?

    var savedBytes: Int64 { max(0, originalBytes - currentBytes) }
    var percentSaved: Int {
        guard originalBytes > 0 else { return 0 }
        return Int((Double(savedBytes) / Double(originalBytes) * 100).rounded())
    }

    func reset() {
        timer?.invalidate(); timer = nil
        stage = .idle; fileName = ""; originalBytes = 0; currentBytes = 0
        phases = Model.freshPhases; detail = ""; fraction = 0
        producedPath = nil; succeeded = false; errorText = nil; consumed = 0
    }

    func start(_ url: URL) {
        guard url.pathExtension.lowercased() == "zip" else {
            errorText = "That is not a .zip file. Drop the .zip you downloaded from Claude Design."
            stage = .finished; succeeded = false
            return
        }
        reset()
        sourceURL = url
        fileName = url.lastPathComponent
        originalBytes = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        stage = .running
        phases[0].state = .active

        // Progress file lives outside the script's work dir, which it deletes.
        let pf = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrink-progress-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: pf.path, contents: nil)
        progressURL = pf

        guard let script = Bundle.main.path(forResource: "shrink-design-zip", ofType: "sh") else {
            fail("Could not find the shrink script inside the app bundle.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script, url.path]
        var env = ProcessInfo.processInfo.environment
        env["PROGRESS"] = pf.path
        // A stripped PATH would hide md5 (in /sbin) and silently disable dedup.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        task.environment = env
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { fail("Could not start the shrink script."); return }

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func fail(_ msg: String) {
        errorText = msg; stage = .finished; succeeded = false
        timer?.invalidate(); timer = nil
    }

    private func poll() {
        guard let pf = progressURL,
              let text = try? String(contentsOf: pf, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > consumed else { return }
        for line in lines[consumed...] { apply(String(line)) }
        consumed = lines.count
    }

    private func apply(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
        guard let kind = parts.first else { return }
        switch kind {
        case "total":
            if parts.count > 1, let n = Int64(parts[1]) { originalBytes = n }

        case "phase":
            guard parts.count > 3, let n = Int(parts[1]) else { return }
            for i in phases.indices {
                if phases[i].id < n { phases[i].state = .complete }
                else if phases[i].id == n { phases[i].state = .active; phases[i].label = parts[3] }
            }
            // Coarse floor per phase so the bar always advances between ticks.
            fraction = max(fraction, Double(n - 1) / 4.0)

        case "size":
            // Only zipped sizes are shown. On-disk sizes are much larger and
            // would make the number jump backward between phases.
            if parts.count > 2, parts[2] == "zip", let n = Int64(parts[1]) { currentBytes = n }

        case "tier":
            if parts.count > 2 { detail = "Quality pass — \(parts[1])px" }

        case "image":
            if parts.count > 2, let i = Double(parts[1]), let n = Double(parts[2]), n > 0 {
                detail = "Image \(Int(i)) of \(Int(n))"
                fraction = max(fraction, 0.5 + (i / n) * 0.4)   // phase 3 spans 50–90%
            }

        case "note":
            if parts.count > 1 { detail = parts.dropFirst().joined(separator: " ") }

        case "done":
            timer?.invalidate(); timer = nil
            let code = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            let path = parts.count > 2 ? parts[2...].joined(separator: " ") : ""
            fraction = 1
            for i in phases.indices { phases[i].state = .complete }
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                producedPath = path
                if let n = try? FileManager.default
                    .attributesOfItem(atPath: path)[.size] as? Int64 { currentBytes = n }
                // Exit 2 means "could not reach target" but a file was still
                // produced, so it is a warning rather than a failure.
                succeeded = (code == 0 || code == 2)
                if code == 2 {
                    errorText = "Shrunk as far as possible, but it is still over the limit. You can still try uploading it."
                }
            } else {
                succeeded = false
                errorText = errorText ?? "Could not shrink that file. It may not be a Claude Design export."
            }
            stage = .finished

        default: break
        }
    }

    /// Copy the produced file wherever the user chooses, defaulting beside the original.
    func save() {
        guard let produced = producedPath else { return }
        let panel = NSSavePanel()
        panel.title = "Save shrunk file"
        panel.nameFieldStringValue = URL(fileURLWithPath: produced).lastPathComponent
        if let src = sourceURL { panel.directoryURL = src.deletingLastPathComponent() }
        panel.canCreateDirectories = true
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.zip] }

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if dest.path != produced {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: URL(fileURLWithPath: produced), to: dest)
                producedPath = dest.path
            }
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            errorText = "Could not save there: \(error.localizedDescription)"
        }
    }
}

// MARK: - Formatting

func humanMB(_ bytes: Int64) -> String {
    if bytes <= 0 { return "—" }
    let mb = Double(bytes) / 1_000_000
    return mb >= 1000 ? String(format: "%.2f GB", mb / 1000) : String(format: "%.1f MB", mb)
}

// MARK: - Views

struct RootView: View {
    @StateObject private var m = Model()

    var body: some View {
        ZStack {
            switch m.stage {
            case .idle:     IdleView(m: m)
            case .running:  RunningView(m: m)
            case .finished: DoneView(m: m)
            }
        }
        .frame(width: 460, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        // Lets files opened from Finder reach this model, including one that
        // arrived before the window was created.
        .onAppear { AppDelegate.attach(m) }
        // Accept drops anywhere in the window, in every state.
        .onDrop(of: [.fileURL], isTargeted: $m.isDropTarget) { providers in
            guard m.stage != .running, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in m.start(url) } }
            }
            return true
        }
    }
}

struct IdleView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(m.isDropTarget ? Color.accentColor : Color.secondary.opacity(0.4))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(m.isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(m.isDropTarget ? Color.accentColor : Color.secondary)
                    Text("Drop your design .zip here")
                        .font(.title3.weight(.medium))
                    Text("or")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Choose File…") { chooseFile() }
                        .controlSize(.large)
                }
                .padding()
            }
            .frame(height: 250)
            .padding(.horizontal, 28)

            Text("Makes Claude Design exports small enough to upload.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .animation(.easeInOut(duration: 0.15), value: m.isDropTarget)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Shrink"
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.zip] }
        if panel.runModal() == .OK, let url = panel.url { m.start(url) }
    }
}

struct RunningView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("Shrinking…").font(.subheadline).foregroundStyle(.secondary)
            }

            // Live size readout: original on the left, current on the right.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original").font(.caption).foregroundStyle(.secondary)
                    Text(humanMB(m.originalBytes)).font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Now").font(.caption).foregroundStyle(.secondary)
                    Text(m.currentBytes > 0 ? humanMB(m.currentBytes) : "…")
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .animation(.easeOut(duration: 0.4), value: m.currentBytes)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            ProgressView(value: m.fraction)
                .animation(.easeOut(duration: 0.3), value: m.fraction)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(m.phases) { p in
                    HStack(spacing: 9) {
                        switch p.state {
                        case .complete:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .active:
                            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16)
                        case .pending:
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                        Text(p.label)
                            .font(.callout)
                            .foregroundStyle(p.state == .pending ? .secondary : .primary)
                        Spacer()
                    }
                }
            }

            if !m.detail.isEmpty {
                Text(m.detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct DoneView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: m.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(m.succeeded ? Color.green : Color.orange)

            Text(m.succeeded ? "Done" : "Could not shrink")
                .font(.title2.weight(.semibold))

            if m.succeeded {
                HStack(spacing: 14) {
                    Text(humanMB(m.originalBytes)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(humanMB(m.currentBytes))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                Text("\(m.percentSaved)% smaller")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if let e = m.errorText {
                Text(e).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            }

            Spacer()
            HStack(spacing: 12) {
                Button("Shrink Another") { m.reset() }
                    .controlSize(.large)
                if m.succeeded {
                    Button("Save…") { m.save() }
                        .controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.bottom, 26)
        }
        .padding(20)
    }
}

// MARK: - App

/// Files opened from Finder (double-click, "Open With", or a drop on the Dock
/// icon) arrive as Apple events, which SwiftUI does not surface on its own.
/// The delegate forwards them to the shared model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI instantiates the delegate itself, so state is held statically
    /// rather than on the instance: `.shared` and the adaptor's instance are
    /// not the same object.
    @MainActor static weak var model: Model?
    @MainActor static var pending: URL?

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "zip" })
                ?? urls.first else { return }
        Task { @MainActor in
            if let m = AppDelegate.model { m.start(url) }
            else { AppDelegate.pending = url }   // opened before the window existed
        }
    }

    /// Called once the model is alive, to pick up a file that arrived first.
    @MainActor static func attach(_ m: Model) {
        model = m
        if let u = pending { pending = nil; m.start(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct ShrinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { RootView() }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
