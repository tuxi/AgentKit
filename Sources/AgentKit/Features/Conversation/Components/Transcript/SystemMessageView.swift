//
//  SystemMessageView.swift
//  AgentKit
//
//  iOS: renders system-level messages (errors, observations, reflections)
//  with appropriate color and icon per SystemNodeKind.
//

import SwiftUI

/// Renders a system node message with kind-specific styling.
struct SystemMessageView: View {
    let payload: SystemNodePayload

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(tintColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(kindLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tintColor)
                if !payload.text.isEmpty {
                    Text(payload.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(tintColor.opacity(0.08))
        )
    }

    // MARK: - Style mapping

    private var kindLabel: String {
        switch payload.kind {
        case .error: return "错误"
        case .observation: return "观测"
        case .reflection: return "反思"
        case .modelActivity: return "模型活动"
        case .contextCompact: return "上下文压缩"
        case .skillLoaded: return "技能加载"
        }
    }

    private var iconName: String {
        switch payload.kind {
        case .error: return "exclamationmark.triangle.fill"
        case .observation: return "eye"
        case .reflection: return "lightbulb"
        case .modelActivity: return "cpu"
        case .contextCompact: return "rectangle.compress.vertical"
        case .skillLoaded: return "sparkles"
        }
    }

    private var tintColor: Color {
        switch payload.kind {
        case .error: return .red
        case .observation: return .secondary
        case .reflection: return .purple
        case .modelActivity: return .blue
        case .contextCompact: return .orange
        case .skillLoaded: return .green
        }
    }
}
