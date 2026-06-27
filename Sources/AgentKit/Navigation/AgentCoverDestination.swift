//
//  AgentCoverDestination.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

public enum AgentCoverDestination: Identifiable, Equatable {
    
    case imagePreview

  
    public var id: String {
        switch self {
        case .imagePreview:
            return "imagePreview"
        }
    }

   public static func == (lhs: AgentCoverDestination, rhs: AgentCoverDestination) -> Bool {
        lhs.id == rhs.id
    }
}

