//
//  AgentRouterViewModifiers.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import SwiftUI

@MainActor
extension View {
   
    public func withAgentNavigationDestinations(
            router: AgentRouter,
            dependencies: AgentDependencies
    ) -> some View {
        navigationDestination(for: AgentNavigationDestination.self) { destination in
            switch destination {
            case .conversationDetail(let conversation):
                ConversationDetailView(conversation: conversation)
            }
        }
    }
    
   public func withAgentSheetDestinations(
        sheetDestinations: Binding<AgentSheetDestination?>,
        dependencies: AgentDependencies
    ) -> some View {
        return sheet(item: sheetDestinations) { destination in
            switch destination {
            case .pickerCategory:
                Color.red
            }
        }
    }
    
   public func withAgentCoverDestinations(
        coverDestinations: Binding<AgentCoverDestination?>,
        dependencies: AgentDependencies
    ) -> some View {
        // 使用一个统一的辅助方法来渲染内容
        let sheetContent = { (destination: AgentCoverDestination) -> AnyView in
            let view: AnyView
            switch destination {
            case .imagePreview:
                view = AnyView(Color.blue)
            }
            return view
        }
        
#if os(macOS)
        return sheet(item: coverDestinations) {
            sheetContent($0)
                .frame(minWidth: 600, minHeight: 450) // macOS 需要给个默认大小
        }
#else
        return fullScreenCover(item: coverDestinations, content: sheetContent)
#endif
    }
}
