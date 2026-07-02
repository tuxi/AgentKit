//
//  InspectorView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import SwiftUI

public struct InspectorView: View {

    public let selection: InspectorSelection?
    
    public init(selection: InspectorSelection?) {
        self.selection = selection
    }

    public var body: some View {

        Group {

            switch selection {

            case .file(let payload):

                FileInspectorView(payload: payload)

            case .directory(let payload):

                DirectoryArtifactView(payload: payload)
                    .padding()

            case .diff(let payload):

                DiffInspectorView(payload: payload)

            case .terminal(let payload):

                TerminalInspectorView(payload: payload)

            case .asset(let payload):

                AssetPreviewInspectorView(payload: payload)

            case .assets(let payload):

                AssetListInspectorView(payload: payload)

            case .todo(let todo):

                TodoInspectorView(
                    todoName: todo
                )

            case .tool(let tool):

                ToolInspectorView(
                    toolName: tool
                )

            case .childStream(let selection):

                ChildStreamInspectorView(selection: selection)

            default:

                ContentUnavailableView(
                    "Nothing Selected",
                    systemImage: "sidebar.right"
                )
            }

        }
    }
}
