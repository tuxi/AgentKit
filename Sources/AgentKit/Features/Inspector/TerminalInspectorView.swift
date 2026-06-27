//
//  TerminalInspectorView.swift
//  CodeAgent
//
//  P5.0: Full-panel terminal inspector — header (command + exit code) + scrollable terminal output body.
//

import SwiftUI

struct TerminalInspectorView: View {

    let payload: TerminalPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            VStack(alignment: .leading, spacing: 4) {
                Text("$ \(payload.command)")
                    .font(.title2.monospaced())

                if let code = payload.exitCode {
                    HStack(spacing: 6) {
                        Text("Exit code: \(code)")
                            .font(.caption)
                        Text(code == 0 ? "Success" : "Failed")
                            .font(.caption)
                            .foregroundStyle(code == 0 ? .green : .red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(code == 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding()

            Divider()

            // MARK: - Body (full-panel, no height cap)
            TerminalArtifactBody(
                command: payload.command,
                output: payload.output,
                exitCode: payload.exitCode,
                maxHeight: nil
            )
        }
    }
}
