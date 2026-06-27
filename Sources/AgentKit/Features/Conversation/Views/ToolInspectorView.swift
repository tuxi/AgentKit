//
//  ToolInspectorView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import SwiftUI

struct ToolInspectorView: View {

    let toolName: String

    var body: some View {

        VStack(alignment: .leading, spacing: 16) {

            Text(toolName)
                .font(.title2)

            Text("Args")

            Text("""
{
  "query":"AI热点"
}
""")
            .font(.system(.body, design: .monospaced))

            Divider()

            Text("Result")

            Text("返回 5 条结果")

            Spacer()
        }
        .padding()
    }
}
