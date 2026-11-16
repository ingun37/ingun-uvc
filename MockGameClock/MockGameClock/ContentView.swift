import SwiftUI
import Foundation

struct ContentView: View {
    @State private var code = """
    start at 1ST 11:59.00
    pause at 1ST 10:30.00 for 3.5 seconds
    hide at 1ST 09:45.00 for 2.0 seconds
    end at 1ST 09:30.00
    """
    @State private var outputWidth = "1280"
    @State private var outputHeight = "720"
    @State private var running = false
    @State private var status = ""
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Game Clock Video").font(.title.bold())
            Text("Write one statement per line. Times use PERIOD mm:ss.ff; durations are seconds.")
                .foregroundStyle(.secondary)
            TextEditor(text: $code)
                .font(.system(size: 15, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                Text("Video size")
                TextField("Width", text: $outputWidth).frame(width: 70)
                Text("×")
                TextField("Height", text: $outputHeight).frame(width: 70)
                Text("pixels").foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("Run") { run() }.disabled(running)
                    .keyboardShortcut(.defaultAction)
                if running { ProgressView(value: progress).frame(width: 180) }
                Text(status).lineLimit(2).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 440)
    }

    private func run() {
        let script: Script
        do { script = try Script.parse(code) }
        catch { status = error.localizedDescription; return }
        guard let width = Int(outputWidth), let height = Int(outputHeight),
              (160...4096).contains(width), (160...4096).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            status = "Width and height must be even numbers from 160 to 4096 pixels."
            return
        }
        let size = CGSize(width: width, height: height)
        let movies = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        do { try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true) }
        catch { status = error.localizedDescription; return }
        let name = "GameClock-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")).mov"
        let url = movies.appendingPathComponent(name)
        running = true
        progress = 0
        status = "Rendering…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            do {
                try VideoRenderer.render(script, to: url, size: size) { value in
                    DispatchQueue.main.async { progress = value }
                }
                result = .success(url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                result = .failure(error)
            }
            DispatchQueue.main.async {
                running = false
                switch result {
                case .success(let output): status = "Saved: \(output.path)"
                case .failure(let error): status = error.localizedDescription
                }
            }
        }
    }
}
