// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import SwiftUI

/// The About window: icon, name, version (build, branch and commit), logs.
struct AboutView: View {
    @ObservedObject var model: SettingsModel

    private var versionLine: String { String(localized: "Version \(model.version) (build \(model.build))") }
    private var version: String { "\(versionLine)\n\(model.commit)" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                Text(verbatim: "Pavé").font(.system(size: 24, weight: .bold)).padding(.top, 6)
                Text("Windows habits on macOS: switcher, snap, taskbar, workspaces and tiling.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: versionLine).font(.callout.monospacedDigit())
                        Text(model.commit).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(version, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 10)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text("MIT License · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Logs") { model.perform(.showLogs) }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
