export const protocolVersion = 1;

export type BlockKind =
  | "markdown"
  | "thinking"
  | "toolGroup"
  | "artifact"
  | "system"
  | "childStream";

export interface ConversationWebTool {
  backgroundJobID?: string;
  id: string;
  name: string;
  rawName?: string;
  icon?: string;
  labels?: Record<string, string>;
  command?: string;
  input?: string;
  inputContext?: string;
  hasResult?: boolean;
  copyInputActionID?: string;
  fullOutputActionID?: string;
  inputIsPreview?: boolean;
  inputIsRedacted?: boolean;
  commandActions?: InlineAction[];
  resultKind?: "terminal" | "search" | "file" | "generic";
  outcomeText?: string;
  outcomeTone?: string;
  status: string;
  statusText?: string;
  detail?: string;
  elapsed?: string;
  changeSummary?: string;
  arguments?: string;
  output?: string;
  artifactActionID?: string;
  assetActions: ActionItem[];
  copyOutputActionID?: string;
  argumentActions: InlineAction[];
  outputActions: InlineAction[];
  /// Non-nil when tool output contains a DAG definition.
  dagNodes?: number;
  /// Number of edges in the DAG (when dagNodes is non-nil).
  dagEdges?: number;
  /// Action to open the workflow DAG detail.
  dagOpenActionID?: string;
  /// Generic `view_image_result.v1` semantic. Absent for malformed or
  /// incomplete metadata; callers then fall back to the normal tool card.
  imageView?: ConversationWebImageView;
  /// Generic `ui_evidence.v1` semantic selected by output schema only.
  uiEvidence?: ConversationWebUIEvidence;
  /// Generic `ui_layout_result.v1` semantic selected by output schema only.
  uiLayout?: ConversationWebUILayout;
  /// Generic `ui_preview_result.v1` semantic selected by output schema only.
  /// Present only with a correlated preview artifact and valid lineage.
  uiPreview?: ConversationWebUIPreview;
}

export interface ConversationWebImageView {
  title: string;
  displayName: string;
  sourceAssetID: string;
  cropAssetID?: string;
  detailRequested: "high" | "original";
  detailEffective: "high" | "original";
  sourceRegion?: ConversationWebImageRegion;
  assets: ConversationWebImageViewAsset[];
}

export interface ConversationWebImageViewAsset {
  assetID: string;
  role: "source" | "crop";
  displayName: string;
  width: number;
  height: number;
  sourceAssetID?: string;
  sourceRegion?: ConversationWebImageRegion;
  viewActionID?: string;
}

export interface ConversationWebImageRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ConversationWebUIEvidence {
  title: string;
  displayName: string;
  sourceAssetID: string;
  sourceTreeKind: "accessibility" | "dom" | "none";
  sourceTreeNote?: string;
  producer: string;
  summary: {
    textElements: number;
    containers: number;
    repeatedGroups: number;
    crops: number;
    observed: number;
    inferred: number;
    uncertain: number;
    uncertainties: number;
    warnings: number;
  };
  assets: ConversationWebUIEvidenceAsset[];
  ocrPreview: Array<{
    id: string;
    text: string;
    bbox: ConversationWebImageRegion;
    confidence: number;
    evidence: "observed" | "inferred" | "uncertain";
  }>;
  repeatedGroups: Array<{
    id: string;
    axis: "vertical" | "horizontal" | "grid" | "unknown";
    memberIDs: string[];
    bbox: ConversationWebImageRegion;
    confidence: number;
    evidence: "observed" | "inferred" | "uncertain";
  }>;
  uncertainties: Array<{
    id: string;
    text: string;
    reason?: string;
  }>;
  warnings: string[];
  limits: string[];
  rawActionID?: string;
}

export interface ConversationWebUIEvidenceAsset {
  assetID: string;
  role: "source" | "crop";
  displayName: string;
  width: number;
  height: number;
  sourceAssetID?: string;
  sourceBBox?: ConversationWebImageRegion;
  purpose?: string;
  viewActionID?: string;
}

export interface ConversationWebUILayout {
  title: string;
  artifactID: string;
  revision: number;
  revisionSHA256: string;
  sourceAssetID: string;
  sourceAssetSHA256: string;
  evidenceSHA256?: string;
  canvasWidth: number;
  canvasHeight: number;
  nodeCount: number;
  assumptionCount: number;
  targets: string[];
  created: boolean;
  overlay: ConversationWebUILayoutAsset;
  layoutJSON: ConversationWebUILayoutAsset;
  rawActionID?: string;
}

export interface ConversationWebUILayoutAsset {
  assetID: string;
  role: "layout_overlay" | "layout_json";
  displayName: string;
  width?: number;
  height?: number;
  viewActionID?: string;
}

export interface ConversationWebUIPreview {
  title: string;
  mode: "adaptation" | "explore";
  modeLabel: "Adaptation Preview" | "Explore Preview";
  artifactKey: string;
  artifactID: string;
  revision: number;
  revisionSHA256: string;
  kind: "interactive_html" | "static_image";
  presentationState: PreviewPresentationState;
  runtimeStatus: string;
  statusLabel: string;
  tone: "neutral" | "info" | "success" | "warning" | "danger";
  fallbackText?: string;
  minHeight?: number;
  preferredAspectRatio?: number;
  fallback: ConversationWebUIPreviewAsset;
  lineage?: ConversationWebUIPreviewLineage;
  layoutJSON?: ConversationWebUIPreviewRelatedAsset;
  evidenceJSON?: ConversationWebUIPreviewRelatedAsset;
  rawActionID?: string;
}

export interface ConversationWebUIPreviewAsset {
  assetID: string;
  role: "fallback";
  displayName: string;
  mimeType?: string;
  width?: number;
  height?: number;
  sha256?: string;
  viewActionID?: string;
}

export interface ConversationWebUIPreviewRelatedAsset {
  assetID: string;
  displayName: string;
  viewActionID?: string;
}

export interface ConversationWebUIPreviewLineage {
  layoutArtifactID: string;
  layoutRevision: number;
  layoutRevisionSHA256: string;
  sourceAssetID: string;
  sourceAssetSHA256: string;
  evidenceSHA256?: string;
  target: string;
  state: string;
  targetMatrixID: string;
  targetMatrixTargets: string[];
  approvalState: "user_confirmed" | "not_required" | "unconfirmed";
  approvalEvidenceRef?: string;
}

export interface InlineAction {
  text: string;
  actionID: string;
  tooltip: string;
}

export interface ActionItem {
  title: string;
  actionID: string;
  tooltip?: string;
  focusID?: string;
}

export interface ConversationWebBlock {
  id: string;
  kind: BlockKind;
  text?: string;
  title?: string;
  status?: string;
  elapsed?: string;
  tools: ConversationWebTool[];
  statusText?: string;
  isCollecting?: boolean;
  activityOrder?: string[];
  activityThinking?: ConversationWebBlock[];
  activityJobs?: ConversationWebBlock[];
  outcome?: { kind: string; title: string; message?: string; facts: { label: string; value: string }[]; diagnostic: string; canManageContext: boolean; detailsLabel: string; rawLabel: string; copyLabel: string; contextLabel: string };
  contextMaintenance?: { title: string; summary: string; status: string; steps: { label: string; value: string }[]; note?: string };
  /// State-based summary for expanded live groups and completed groups.
  activitySummary?: string;
  failureText?: string;
  startedAtMilliseconds?: number;
  finishedAtMilliseconds?: number;
  childStreamKind?: "task" | "job";
  actionID?: string;
  actionTooltip?: string;
  inlineActions: InlineAction[];
  codeCopyActionIDs: string[];
  /// Present only for system blocks: the raw SystemNodeKind (e.g.
  /// "contextCompact", "preMutation", "verified").
  systemKind?: string;
  /// Present only for system blocks: kind-specific flags/values from the graph
  /// node payload (e.g. "ineffective": "true").
  metadata?: Record<string, string>;
}

export interface ConversationWebUserAsset {
  assetID: number;
  filename: string;
  mimeType: string;
  previewURL?: string;
}

export interface ConversationWebLocalAsset {
  id: string;
  relativePath: string;
  filename: string;
  mimeType: string;
  kind: string;
  sizeBytes?: number;
  previewURL?: string;
  transferPolicy: "local_only";
}

export type PreviewPresentationState =
  | "loading"
  | "interactiveReady"
  | "staticFallback"
  | "unavailable"
  | "renderFailed"
  | "expired";

export interface ConversationWebPreview {
  id: string;
  artifactID: string;
  revision: number;
  kind: "interactive_html" | "static_image";
  title: string;
  summary?: string;
  presentationState: PreviewPresentationState;
  runtimeStatus: "pending" | "ready" | "failed" | "unavailable";
  statusLabel: string;
  tone: "neutral" | "info" | "success" | "warning" | "danger";
  capability: string;
  fallbackText?: string;
  fallbackAssetID?: string;
  fallbackAlt?: string;
  degradedReason?: string;
  errorCode?: string;
  initialState: "collapsed" | "expanded";
  expiresAtMilliseconds?: number;
  minHeight?: number;
  preferredAspectRatio?: number;
}

export interface ConversationWebTurn {
  id: string;
  presentationID?: string;
  deliveryStatus?: string;
  retrySubmissionActionID?: string;
  userPrompt?: string;
  userCopyActionID?: string;
  fileReferences?: { id: string; path: string; relativePath?: string; isDirectory: boolean }[];
  userAssets: ConversationWebUserAsset[];
  localAssets?: ConversationWebLocalAsset[];
  blocks: ConversationWebBlock[];
  previews?: ConversationWebPreview[];
  todos: ConversationWebDocument["todos"];
  extensionNodes: ConversationWebExtensionNode[];
  footer?: {
    totalTokens: string;
    contextTokens?: string;
    usageUnits?: string;
    elapsed: string;
    invocationCount: number;
    cachedTokens?: string;
  };
  isLive: boolean;
  copyActionID?: string;
  shareActionID?: string;
  assetsActionID?: string;
  assetCount: number;
  /// Wall-clock duration of the turn ("24分40秒"). Absent while live.
  elapsedText?: string;
  processFailureText?: string;
  /// `HH:mm` the turn ended, rendered next to the turn actions.
  finishedAtClock?: string;
  /// Epoch milliseconds the turn started. The live turn ticks
  /// "已处理 8分15秒" from this anchor; ignored once the turn finished.
  startedAtMilliseconds?: number;
  /// What this turn wrote (Runtime `diffstat`). Absent when the Runtime
  /// reported nothing — absence means "unknown", never "edited 0 files".
  changes?: {
    /// Capped by the Runtime (200); may be shorter than `filesChanged`.
    files: { path: string; added: number; removed: number; status: string }[];
    filesChanged: number;
    addedLines: number;
    removedLines: number;
    /// "编辑 3 个文件" — built in Swift so iOS and Web cannot drift apart.
    summary?: string;
  };
  /// The model that produced the final answer (`model_request`, v1.4).
  /// Absent for streams that predate the event — the badge is omitted.
  model?: string;
  modelRoute?: string;
}

export interface ConversationWebExtensionNode {
  id: string;
  title: string;
  summary?: string;
  status?: string;
  tone: "neutral" | "info" | "success" | "warning" | "danger";
  badges: Array<{
    id: string;
    text: string;
    tone: "neutral" | "info" | "success" | "warning" | "danger";
  }>;
  sections: Array<{
    id: string;
    title: string;
    summary?: string;
    status?: string;
    rows: Array<{ id: string; label: string; value: string }>;
    initiallyExpanded: boolean;
  }>;
  actions: ActionItem[];
  footer?: string;
}

export interface ConversationWebDocument {
  protocolVersion: number;
  revision: number;
  conversationID: string;
  todos: Array<{
    content: string;
    activeForm?: string;
    status: string;
  }>;
  turns: ConversationWebTurn[];
  live?: {
    isThinking: boolean;
    waitingReason?: "approval" | "plan" | "question" | "background" | "background_attention";
    startedAtMilliseconds?: number;
    modelRetrying?: {
      attempt: number;
      maxAttempts: number;
      retryDelayMs: number;
      retryFallback: boolean;
      err?: string;
      startedAtMilliseconds?: number;
    };
  };
}

export interface ConversationWebOperation {
  kind:
    | "setTodos"
    | "replaceTurn"
    | "updateTurn"
    | "appendTurn"
    | "prependTurns"
    | "removeTurns"
    | "replaceBlock"
    | "appendBlock"
    | "removeBlocks"
    | "setLive";
  index?: number;
  blockIndex?: number;
  turn?: ConversationWebTurn;
  block?: ConversationWebBlock;
  todos?: ConversationWebDocument["todos"];
  live?: ConversationWebDocument["live"];
}

export interface ConversationWebUpdate {
  protocolVersion: number;
  kind: "reset" | "patch";
  conversationID: string;
  revision: number;
  document?: ConversationWebDocument;
  recoveryViewport?: {
    pinned: boolean;
    anchorID?: string;
    anchorTop?: number;
  };
  patch?: {
    baseRevision: number;
    forcePinToBottom: boolean;
    operations: ConversationWebOperation[];
  };
}

export type NativeBridgeMessage =
  | {
      type: "ready";
      protocolVersion: number;
    }
  | {
      type: "ack";
      protocolVersion: number;
      revision: number;
      conversationID: string;
      applyDurationMilliseconds?: number;
    }
  | {
      type: "action";
      protocolVersion: number;
      action?: "openURL";
      value?: string;
      actionID?: string;
      revision: number;
      conversationID: string;
    }
  | {
      type: "resync";
      protocolVersion: number;
      currentRevision: number;
      receivedBaseRevision: number;
    }
  | {
      type: "reachedTop";
      conversationID: string;
    }
  | {
      type: "viewport";
      protocolVersion: number;
      revision: number;
      conversationID: string;
      pinned: boolean;
      interacting: boolean;
      anchorID?: string;
      anchorTop?: number;
    }
  | {
      type: "resolveUserAssetURL";
      assetID: number;
      requestID: string;
    }
  | {
      type: "resolveLocalAssetURL";
      localAssetID: string;
      conversationID: string;
      requestID: string;
    }
  | {
      type: "resolveImageViewAssetURL";
      conversationID: string;
      turnID: string;
      toolID: string;
      assetID: string;
      requestID: string;
    }
  | {
      type: "resolvePreviewViewerURL";
      conversationID: string;
      artifactID: string;
      revision: number;
      requestID: string;
    }
  | {
      type: "resolvePreviewAssetURL";
      conversationID: string;
      artifactID: string;
      revision: number;
      assetID: string;
      requestID: string;
    }
  | {
      type: "previewTurnAssets";
      conversationID: string;
      turnID: string;
      assetKind: "user" | "local";
      assetID: string;
    };

declare global {
  interface Window {
    AgentKitWorkbench?: {
      applyUpdateBase64(payload: string): void;
      setSuspended(suspended: boolean): void;
      setHostBackground(hex: string): void;
      setBottomInset(inset: number): void;
      viewportDiagnostics(): {
        pinned: boolean;
        interacting: boolean;
        distanceFromBottom: number;
        interactionEpoch: number;
        lastEvent: string;
      };
    };
    webkit?: {
      messageHandlers?: {
        agentkitWorkbench?: {
          postMessage(message: NativeBridgeMessage): void;
        };
      };
    };
  }
}
