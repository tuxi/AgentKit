//
//  URL+CanonicalPath.swift
//  AgentKit
//
//  Canonical path helpers for workspace-grouping dedup.
//
//  Two independent iOS sandbox realities break `URL.standardizedFileURL`-based
//  dedup and cause the same project to appear as multiple sidebar groups:
//
//  1. `/var` is a symlink to `/private/var`, but the iOS sandbox prevents
//     `standardizedFileURL` from resolving it.  Paths from FileManager arrive
//     as `/var/mobile/…` while bookmark-resolved paths carry the canonical
//     `/private/var/mobile/…` form.
//
//  2. Every app installation gets a new sandbox container UUID, so the
//     absolute path changes from `/…/<UUID-A>/Documents/My Project` to
//     `/…/<UUID-B>/Documents/My Project`.  The runtime persists conversation
//     records keyed by the path that was current at creation time, so old
//     conversations never share a group with the current workspace.
//
//  This helper normalises both forms so that anywhere a file path is used as a
//  grouping identity it collapses to the same stable string.
//

import Foundation

extension URL {

    /// A canonical file-system path suitable for **grouping identity**.
    ///
    /// - Resolves the `/var` → `/private/var` symlink (iOS sandbox stops
    ///   `standardizedFileURL` from doing this at the VFS level).
    /// - Replaces the per-installation sandbox container UUID with a stable
    ///   placeholder so that conversations created under different installations
    ///   still land in the same workspace group.
    ///
    /// > Important: this is **not** a general-purpose path normaliser.  It is
    /// > deliberately lossy — the returned string no longer points to a real
    /// > file — so it must only be used for identity comparison and group-key
    /// > construction, never for I/O.
    var canonicalPathForGrouping: String {
        var path = self.standardizedFileURL.path

        #if os(iOS)
        // 1. Resolve well-known Apple root symlinks that standardizedFileURL
        //    cannot touch inside the sandbox.
        let appleSymlinkPrefixes = ["/var/", "/tmp/", "/etc/"]
        for prefix in appleSymlinkPrefixes {
            if path.hasPrefix(prefix) {
                path = "/private" + path
                break
            }
        }

        // 2. Normalise the per-installation sandbox container UUID so that
        //    reinstalling the app does not fragment the same project.
        //
        //    Pattern:
        //      …/Containers/Data/Application/<UUID>/Documents/<project>
        //
        //    The <UUID> is replaced with a stable sentinel; everything after
        //    "Documents/" (the project-relative portion) is preserved as-is.
        //    Paths that fall outside a sandbox container (e.g. document-picker
        //    selections) are left untouched.
        if let containerRange = path.range(of: "/Containers/Data/Application/") {
            let afterAppPrefix = path[containerRange.upperBound...]
            if let uuidEnd = afterAppPrefix.firstIndex(of: "/") {
                // Build: …/Containers/Data/Application/current/<rest>
                let prefix = path[..<containerRange.upperBound]
                let relative = afterAppPrefix[uuidEnd...]  // e.g. /Documents/New Project
                path = "\(prefix)current\(relative)"
            }
        }
        #endif

        return path
    }
}
