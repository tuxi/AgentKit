export const protocolVersion = 1;

export type BlockKind =
  | "markdown"
  | "toolGroup"
  | "artifact"
  | "system"
  | "childStream";

export interface ConversationWebTool {
  id: string;
  name: string;
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
  childStreamKind?: "task" | "job";
  actionID?: string;
  actionTooltip?: string;
  inlineActions: InlineAction[];
  codeCopyActionIDs: string[];
}

export interface ConversationWebTurn {
  id: string;
  userPrompt?: string;
  blocks: ConversationWebBlock[];
  todos: ConversationWebDocument["todos"];
  extensionNodes: ConversationWebExtensionNode[];
  footer?: {
    totalTokens: string;
    contextTokens?: string;
    usageUnits?: string;
    elapsed: string;
    invocationCount: number;
  };
  isLive: boolean;
  copyActionID?: string;
  assetsActionID?: string;
  assetCount: number;
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
    startedAtMilliseconds?: number;
  };
}

export interface ConversationWebOperation {
  kind:
    | "setTodos"
    | "replaceTurn"
    | "updateTurn"
    | "appendTurn"
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
      type: "viewport";
      protocolVersion: number;
      revision: number;
      conversationID: string;
      pinned: boolean;
      interacting: boolean;
      anchorID?: string;
      anchorTop?: number;
    };

declare global {
  interface Window {
    AgentKitWorkbench?: {
      applyUpdateBase64(payload: string): void;
      setSuspended(suspended: boolean): void;
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
