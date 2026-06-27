//
//  TodoCard.swift
//  AgentKit
//
//  Renders the current todo list with status indicators.
//

import SwiftUI

struct TodoCard: View {
    let todos: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Tasks", systemImage: "checklist")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(todos, id: \.content) { todo in
                HStack(spacing: 6) {
                    Image(systemName: statusIcon(for: todo.status))
                        .font(.caption2)
                        .foregroundStyle(statusColor(for: todo.status))

                    Text(todo.activeForm ?? todo.content)
                        .font(.caption2)
                        .foregroundStyle(todo.status == .completed ? .tertiary : .secondary)
                        .strikethrough(todo.status == .completed)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusIcon(for status: TodoStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func statusColor(for status: TodoStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}
