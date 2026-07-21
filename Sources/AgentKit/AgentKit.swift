// AgentKit — re-exports ClientToolProtocol so that `import AgentKit` gives access to
// ClientTool, ToolRegistry, JSONValue, AgentAssetRef, and related types.
// @_exported is the standard Swift mechanism for module re-export — used broadly
// across the ecosystem (SwiftUI, etc.). Explicit typealiases are not sufficient
// because Swift does not re-export constructors through aliases in all contexts
// (e.g. default argument values).
@_exported import ClientToolProtocol
