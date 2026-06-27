//
//  AgentSheetDestination.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import SwiftUI

public enum AgentSheetDestination: Identifiable, Equatable {
    case pickerCategory
    
    public var id: String {
        switch self {
        case .pickerCategory:
            return "pickerCategory"
        }
    }

    public static func == (lhs: AgentSheetDestination, rhs: AgentSheetDestination) -> Bool {
        lhs.id == rhs.id
    }
}
