//
//  InspectorSelection.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import Foundation

public enum InspectorSelection: Hashable {
    case file(FilePayload)
    case diff(DiffPayload)
    case terminal(TerminalPayload)
    case todo(String)
    case tool(String)
    case plan(String)
}
