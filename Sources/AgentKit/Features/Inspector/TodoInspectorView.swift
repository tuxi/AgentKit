//
//  TodoInspectorView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import SwiftUI

struct TodoInspectorView: View {

    let todoName: String

    var body: some View {

        VStack(alignment: .leading, spacing: 12) {

            Text(todoName)
                .font(.title2)

            Text("Running")

            ProgressView()

            Spacer()
        }
        .padding()
    }
}
