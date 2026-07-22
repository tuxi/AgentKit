//
//  FinderHelper.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/22.
//

#if os(macOS)
import AppKit

/// 在访达中高亮选中指定路径（文件或文件夹）
public func revealInFinder(path: String) {
    let url = URL(fileURLWithPath: path)
    
    // 防御校验：检查路径是否存在
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("路径不存在: \(path)")
        return
    }
    
    // 在 Finder 中高亮选中该路径
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// 直接打开并进入文件夹内部
public func openFolderInFinder(path: String) {
    let url = URL(fileURLWithPath: path)
    
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("路径不存在: \(path)")
        return
    }
    
    // 打开文件夹
    NSWorkspace.shared.open(url)
}

#endif
