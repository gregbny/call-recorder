import SwiftUI
import AppKit
import CallRecorderKit

@available(macOS 26.0, *)
@main
struct CallRecorderMenuBarApp: App {
    @StateObject private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Label {
                Text("Call Recorder")
            } icon: {
                Image(systemName: controller.state == .recording
                      ? "record.circle.fill"
                      : "record.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@available(macOS 26.0, *)
struct MenuContent: View {
    @ObservedObject var controller: RecordingController

    private let languages: [(String, String)] = [
        ("fr-FR", "Français"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Español"),
        ("de-DE", "Deutsch"),
        ("it-IT", "Italiano"),
        ("pt-BR", "Português (BR)"),
        ("nl-NL", "Nederlands")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            Text("Nom du call")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("ex: point-hebdo", text: $controller.callName)
                .textFieldStyle(.roundedBorder)

            Text("Langue")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $controller.language) {
                ForEach(languages, id: \.0) { code, label in
                    Text("\(label) (\(code))").tag(code)
                }
            }
            .labelsHidden()
            .disabled(controller.state != .idle)

            Toggle("Distinguer les interlocuteurs", isOn: $controller.diarize)
                .disabled(!controller.diarizeModelsAvailable)
            if !controller.diarizeModelsAvailable {
                Text("Modèles absents — lancez scripts/download-models.sh")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            actionButton

            if controller.state == .recording {
                liveTranscriptView
            }

            if let url = controller.lastOutputURL {
                Divider()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("Ouvrir le dernier transcript")
                    }
                }
                .buttonStyle(.plain)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text("Révéler dans le Finder")
                    }
                }
                .buttonStyle(.plain)
            }

            if let err = controller.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            Divider()
            Button("Quitter") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 380)
    }

    private var liveTranscriptView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transcription live")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(controller.liveSegments.count) segments")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if controller.liveSegments.isEmpty && controller.volatileBySpeaker.isEmpty {
                            Text("En attente d'audio…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                        }
                        ForEach(Array(controller.liveSegments.enumerated()), id: \.offset) { idx, seg in
                            HStack(alignment: .top, spacing: 6) {
                                Text(formatTimestamp(seg.start))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 56, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(seg.speaker)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(seg.speaker == "Moi" ? .blue : .orange)
                                    Text(seg.text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .id(idx)
                        }
                        ForEach(controller.volatileBySpeaker.sorted(by: { $0.key < $1.key }), id: \.key) { spk, txt in
                            HStack(alignment: .top, spacing: 6) {
                                Text("…")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 56, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(spk)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(spk == "Moi" ? .blue : .orange)
                                    Text(txt)
                                        .font(.caption)
                                        .italic()
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: 220)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(6)
                .onChange(of: controller.liveSegments.count) { _, newCount in
                    guard newCount > 0 else { return }
                    withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 9, height: 9)
            Text(stateLabel)
                .font(.headline)
            Spacer()
            if controller.state == .recording {
                Text(formatTimestamp(controller.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch controller.state {
        case .idle:
            Button {
                controller.start()
            } label: {
                HStack {
                    Image(systemName: "record.circle.fill")
                    Text("Démarrer l'enregistrement")
                }
                .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
        case .recording:
            Button {
                controller.stop()
            } label: {
                HStack {
                    Image(systemName: "stop.circle.fill")
                    Text("Arrêter & transcrire")
                }
                .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
            .tint(.red)
        case .processing:
            HStack {
                ProgressView().controlSize(.small)
                Text(controller.processingMessage)
                    .foregroundColor(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var stateColor: Color {
        switch controller.state {
        case .idle: return .gray
        case .recording: return .red
        case .processing: return .orange
        }
    }

    private var stateLabel: String {
        switch controller.state {
        case .idle: return "Prêt"
        case .recording: return "Enregistrement"
        case .processing: return "Traitement"
        }
    }
}
