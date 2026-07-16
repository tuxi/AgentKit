//
//  TodoPanel.swift
//  AgentKit
//
//  Turn-owned todo progress panel — rendered at the bottom of its turn.
//  Shows agent's current task plan with progress indicators.
//  Auto-hides when empty. Collapsible. Never blocks execution (informational only).
//

import SwiftUI

// MARK: - TodoPanel

struct TodoPanel: View {
    let todos: [TodoItem]

    @State private var isExpanded: Bool

    init(todos: [TodoItem], isLive: Bool = false) {
        self.todos = todos
        let isComplete = !todos.isEmpty && todos.allSatisfy { $0.status == .completed }
        _isExpanded = State(initialValue: isLive && !isComplete)
    }

    var body: some View {
        if todos.isEmpty { EmptyView() }

        VStack(alignment: .leading, spacing: 6) {
            // Header
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.caption)
                        .foregroundStyle(.blue)

                    Text("Tasks")
                        .font(.caption.weight(.semibold))

                    // Progress: "2/5"
                    let completed = todos.filter { $0.status == .completed }.count
                    let inProgress = todos.filter { $0.status == .inProgress }.count
                    Text("\(completed)/\(todos.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.1))
                        .clipShape(Capsule())

                    if inProgress > 0 {
                        Text("\(inProgress) active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            // Progress bar
            ProgressView(value: todoProgress)
                .tint(.blue)
                .scaleEffect(x: 1, y: 0.8, anchor: .center)

            // Expanded list
            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(todos, id: \.content) { todo in
                        TodoRow(todo: todo)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.blue.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var todoProgress: Double {
        guard !todos.isEmpty else { return 0 }
        let completed = Double(todos.filter { $0.status == .completed }.count)
        return completed / Double(todos.count)
    }
}

// MARK: - TodoRow

private struct TodoRow: View {
    let todo: TodoItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.caption2)
                .foregroundStyle(statusColor)

            Text(todo.status == .inProgress
                 ? (todo.activeForm ?? todo.content)
                 : todo.content)
                .font(.caption2)
                .foregroundStyle(todo.status == .completed ? .tertiary : .primary)
                .strikethrough(todo.status == .completed)

            if todo.status == .inProgress {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 10, height: 10)
                    .tint(.blue)
            }
        }
    }

    private var statusIcon: String {
        switch todo.status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch todo.status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}
