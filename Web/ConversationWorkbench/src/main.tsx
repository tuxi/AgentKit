import React, { memo, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import ReactMarkdown, { defaultUrlTransform } from "react-markdown";
import remarkGfm from "remark-gfm";
import type {
  ConversationWebBlock,
  ConversationWebDocument,
  ConversationWebExtensionNode,
  ConversationWebOperation,
  ConversationWebTool,
  ConversationWebTurn,
  ConversationWebUpdate,
  InlineAction,
  NativeBridgeMessage,
} from "./types";
import { protocolVersion } from "./types";
import "./workbench.css";

let currentRevision = 0;
let currentConversationID: string | undefined;
let currentUpdateStartedAt = 0;

function postToNative(message: NativeBridgeMessage): void {
  window.webkit?.messageHandlers?.agentkitWorkbench?.postMessage(message);
}

function dispatchAction(actionID: string): void {
  if (!currentConversationID) return;
  postToNative({
    type: "action",
    protocolVersion,
    actionID,
    revision: currentRevision,
    conversationID: currentConversationID,
  });
}

function decodeUpdate(payload: string): ConversationWebUpdate {
  const bytes = Uint8Array.from(atob(payload), (character) =>
    character.charCodeAt(0),
  );
  const update = JSON.parse(new TextDecoder().decode(bytes)) as ConversationWebUpdate;
  if (update.protocolVersion !== protocolVersion) {
    throw new Error(
      `Unsupported protocol ${update.protocolVersion}; expected ${protocolVersion}`,
    );
  }
  return update;
}

type MarkdownNode = {
  type: string;
  value?: string;
  url?: string;
  title?: string;
  children?: MarkdownNode[];
};

function inlineActionPlugin(actions: InlineAction[]) {
  return () => (tree: MarkdownNode) => {
    const consumed = new Set<number>();

    function transform(parent: MarkdownNode): void {
      if (!parent.children || parent.type === "link" || parent.type === "code") return;
      const nextChildren: MarkdownNode[] = [];
      for (const child of parent.children) {
        if ((child.type === "text" || child.type === "inlineCode") && child.value) {
          let remaining = child.value;
          while (remaining.length > 0) {
            let selectedIndex = -1;
            let selectedOffset = Number.POSITIVE_INFINITY;
            for (let index = 0; index < actions.length; index += 1) {
              if (consumed.has(index) || !actions[index].text) continue;
              const offset = remaining.indexOf(actions[index].text);
              if (offset >= 0 && offset < selectedOffset) {
                selectedIndex = index;
                selectedOffset = offset;
              }
            }
            if (selectedIndex < 0) {
              nextChildren.push({ type: child.type, value: remaining });
              break;
            }

            const action = actions[selectedIndex];
            if (selectedOffset > 0) {
              nextChildren.push({
                type: child.type,
                value: remaining.slice(0, selectedOffset),
              });
            }
            const actionText = remaining.slice(
              selectedOffset,
              selectedOffset + action.text.length,
            );
            nextChildren.push({
              type: "link",
              url: `agentkit-action:${action.actionID}`,
              title: action.tooltip,
              children: [{ type: child.type, value: actionText }],
            });
            consumed.add(selectedIndex);
            remaining = remaining.slice(selectedOffset + action.text.length);
          }
        } else {
          transform(child);
          nextChildren.push(child);
        }
      }
      parent.children = nextChildren;
    }

    transform(tree);
  };
}

type SelectionPoint = {
  selectionID: string;
  offset: number;
};

type SelectionSnapshot = {
  anchor: SelectionPoint;
  focus: SelectionPoint;
};

function selectionElement(node: Node | null): HTMLElement | null {
  const element = node instanceof HTMLElement ? node : node?.parentElement;
  return element?.closest<HTMLElement>("[data-selection-id]") ?? null;
}

function captureSelectionPoint(node: Node, offset: number): SelectionPoint | null {
  const element = selectionElement(node);
  const selectionID = element?.dataset.selectionId;
  if (!element || !selectionID) return null;
  const range = document.createRange();
  range.selectNodeContents(element);
  try {
    range.setEnd(node, offset);
  } catch {
    return null;
  }
  return { selectionID, offset: range.toString().length };
}

function captureSelection(): SelectionSnapshot | null {
  const selection = window.getSelection();
  if (
    !selection ||
    selection.isCollapsed ||
    !selection.anchorNode ||
    !selection.focusNode
  ) {
    return null;
  }
  const anchor = captureSelectionPoint(selection.anchorNode, selection.anchorOffset);
  const focus = captureSelectionPoint(selection.focusNode, selection.focusOffset);
  return anchor && focus ? { anchor, focus } : null;
}

function resolveSelectionPoint(point: SelectionPoint): { node: Node; offset: number } | null {
  const element = document.querySelector<HTMLElement>(
    `[data-selection-id="${CSS.escape(point.selectionID)}"]`,
  );
  if (!element) return null;
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let remaining = Math.max(0, point.offset);
  let lastTextNode: Node | null = null;
  while (walker.nextNode()) {
    const node = walker.currentNode;
    lastTextNode = node;
    const length = node.textContent?.length ?? 0;
    if (remaining <= length) return { node, offset: remaining };
    remaining -= length;
  }
  if (lastTextNode) {
    return { node: lastTextNode, offset: lastTextNode.textContent?.length ?? 0 };
  }
  return { node: element, offset: 0 };
}

function restoreSelection(snapshot: SelectionSnapshot | null): void {
  if (!snapshot) return;
  const anchor = resolveSelectionPoint(snapshot.anchor);
  const focus = resolveSelectionPoint(snapshot.focus);
  if (!anchor || !focus) return;
  const selection = window.getSelection();
  if (!selection) return;
  selection.removeAllRanges();
  selection.setBaseAndExtent(
    anchor.node,
    anchor.offset,
    focus.node,
    focus.offset,
  );
}

function captureHorizontalOffsets(): Map<string, number> {
  const offsets = new Map<string, number>();
  document.querySelectorAll<HTMLElement>("[data-scroll-id]").forEach((element) => {
    const id = element.dataset.scrollId;
    if (id && element.scrollLeft > 0) offsets.set(id, element.scrollLeft);
  });
  return offsets;
}

function restoreHorizontalOffsets(offsets: Map<string, number>): void {
  for (const [id, offset] of offsets) {
    const element = document.querySelector<HTMLElement>(
      `[data-scroll-id="${CSS.escape(id)}"]`,
    );
    if (element) element.scrollLeft = offset;
  }
}

function captureExpandedDisclosures(): Set<string> {
  return new Set(
    Array.from(document.querySelectorAll<HTMLDetailsElement>("details[open][data-disclosure-id]"))
      .map((element) => element.dataset.disclosureId)
      .filter((id): id is string => Boolean(id)),
  );
}

function restoreExpandedDisclosures(ids: Set<string>): void {
  for (const id of ids) {
    const details = document.querySelector<HTMLDetailsElement>(
      `details[data-disclosure-id="${CSS.escape(id)}"]`,
    );
    if (details) details.open = true;
  }
}

function captureFocusedElement(): string | null {
  return document.activeElement instanceof HTMLElement
    ? document.activeElement.dataset.focusId ?? null
    : null;
}

function restoreFocusedElement(focusID: string | null): void {
  if (!focusID) return;
  if (window.getSelection() && !window.getSelection()!.isCollapsed) return;
  document.querySelector<HTMLElement>(
    `[data-focus-id="${CSS.escape(focusID)}"]`,
  )?.focus({ preventScroll: true });
}

type ViewportAnchor = { id: string; top: number };
type ViewportSnapshot = { pinned: boolean; anchor: ViewportAnchor | null };

class ViewportController {
  private pinned = true;
  private programmatic = false;
  private userIntentUntil = 0;
  private lastAnchor: ViewportAnchor | null = null;
  private onPinChange: (pinned: boolean) => void = () => {};

  start(onPinChange: (pinned: boolean) => void): () => void {
    this.onPinChange = onPinChange;
    const markUserIntent = () => {
      this.userIntentUntil = performance.now() + 600;
    };
    const markKeyboardIntent = (event: KeyboardEvent) => {
      if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "].includes(event.key)) {
        markUserIntent();
      }
    };
    const handleScroll = () => {
      if (this.programmatic || performance.now() > this.userIntentUntil) return;
      this.setPinned(this.distanceFromBottom() <= 36);
      this.lastAnchor = this.captureAnchor();
    };
    const handleResize = () => {
      const snapshot: ViewportSnapshot = {
        pinned: this.pinned,
        anchor: this.lastAnchor ?? this.captureAnchor(),
      };
      window.setTimeout(() => this.restore(snapshot, false), 0);
    };
    window.addEventListener("wheel", markUserIntent, { passive: true });
    window.addEventListener("touchstart", markUserIntent, { passive: true });
    window.addEventListener("pointerdown", markUserIntent, { passive: true });
    window.addEventListener("keydown", markKeyboardIntent);
    window.addEventListener("scroll", handleScroll, { passive: true });
    window.addEventListener("resize", handleResize);
    return () => {
      window.removeEventListener("wheel", markUserIntent);
      window.removeEventListener("touchstart", markUserIntent);
      window.removeEventListener("pointerdown", markUserIntent);
      window.removeEventListener("keydown", markKeyboardIntent);
      window.removeEventListener("scroll", handleScroll);
      window.removeEventListener("resize", handleResize);
    };
  }

  capture(): ViewportSnapshot {
    return {
      pinned: this.pinned,
      anchor: this.lastAnchor ?? this.captureAnchor(),
    };
  }

  restore(snapshot: ViewportSnapshot, forcePinToBottom: boolean): void {
    if (forcePinToBottom || snapshot.pinned) {
      this.setPinned(true);
      this.scrollToBottom();
      return;
    }
    this.setPinned(false);
    if (snapshot.anchor) {
      const element = document.querySelector<HTMLElement>(
        `[data-anchor-id="${CSS.escape(snapshot.anchor.id)}"]`,
      );
      if (element) {
        this.performProgrammaticScroll(() => {
          window.scrollBy(0, element.getBoundingClientRect().top - snapshot.anchor!.top);
        });
      }
    }
    this.lastAnchor = this.captureAnchor();
  }

  jumpToLatest(): void {
    this.setPinned(true);
    this.scrollToBottom();
  }

  private scrollToBottom(): void {
    this.performProgrammaticScroll(() => {
      window.scrollTo(0, document.documentElement.scrollHeight);
    });
    this.lastAnchor = this.captureAnchor();
  }

  private performProgrammaticScroll(operation: () => void): void {
    this.programmatic = true;
    operation();
    window.setTimeout(() => {
      this.programmatic = false;
    }, 0);
  }

  private setPinned(next: boolean): void {
    if (this.pinned === next) return;
    this.pinned = next;
    this.onPinChange(next);
  }

  private distanceFromBottom(): number {
    const viewport = document.documentElement;
    return viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
  }

  private captureAnchor(): ViewportAnchor | null {
    const elements = document.querySelectorAll<HTMLElement>("[data-anchor-id]");
    for (const element of elements) {
      const rect = element.getBoundingClientRect();
      if (rect.bottom > 0 && rect.top < window.innerHeight) {
        const id = element.dataset.anchorId;
        if (id) return { id, top: rect.top };
      }
    }
    return null;
  }
}

const viewportController = new ViewportController();

type RestorationSnapshot = {
  selection: SelectionSnapshot | null;
  horizontalOffsets: Map<string, number>;
  expandedDisclosures: Set<string>;
  focusID: string | null;
  viewport: ViewportSnapshot;
  forcePinToBottom: boolean;
};

function applyOperations(
  document: ConversationWebDocument,
  operations: ConversationWebOperation[],
  revision: number,
): ConversationWebDocument {
  let next = document;
  for (const operation of operations) {
    switch (operation.kind) {
      case "setTodos":
        next = { ...next, todos: operation.todos ?? [] };
        break;
      case "replaceTurn": {
        if (operation.index === undefined || !operation.turn) break;
        const turns = next.turns.slice();
        turns[operation.index] = operation.turn;
        next = { ...next, turns };
        break;
      }
      case "appendTurn":
        if (operation.turn) next = { ...next, turns: [...next.turns, operation.turn] };
        break;
      case "removeTurns":
        if (operation.index !== undefined) {
          next = { ...next, turns: next.turns.slice(0, operation.index) };
        }
        break;
      case "setLive":
        next = { ...next, live: operation.live };
        break;
    }
  }
  return { ...next, revision };
}

function ActionButton({
  actionID,
  focusID,
  tooltip,
  children,
}: {
  actionID: string;
  focusID?: string;
  tooltip?: string;
  children: React.ReactNode;
}): React.JSX.Element {
  return (
    <button
      className="action-button"
      type="button"
      data-tooltip={tooltip}
      data-focus-id={focusID ?? `action:${actionID}`}
      aria-label={tooltip}
      onClick={() => dispatchAction(actionID)}
    >
      {children}
    </button>
  );
}

function linkifiedActionText(
  text: string,
  actions: InlineAction[],
): React.ReactNode[] {
  const nodes: React.ReactNode[] = [];
  let remaining = text;
  const consumed = new Set<number>();
  while (remaining.length > 0) {
    let selectedIndex = -1;
    let selectedOffset = Number.POSITIVE_INFINITY;
    for (let index = 0; index < actions.length; index += 1) {
      if (consumed.has(index) || !actions[index].text) continue;
      const offset = remaining.indexOf(actions[index].text);
      if (offset >= 0 && offset < selectedOffset) {
        selectedIndex = index;
        selectedOffset = offset;
      }
    }
    if (selectedIndex < 0) {
      nodes.push(remaining);
      break;
    }
    const action = actions[selectedIndex];
    if (selectedOffset > 0) nodes.push(remaining.slice(0, selectedOffset));
    nodes.push(
      <a
        href={`agentkit-action:${action.actionID}`}
        data-action-id={action.actionID}
        data-focus-id={`action:${action.actionID}`}
        data-tooltip={action.tooltip}
        key={`${action.actionID}:${nodes.length}`}
        onClick={(event) => {
          event.preventDefault();
          if (window.getSelection()?.isCollapsed) dispatchAction(action.actionID);
        }}
      >
        {remaining.slice(selectedOffset, selectedOffset + action.text.length)}
      </a>,
    );
    consumed.add(selectedIndex);
    remaining = remaining.slice(selectedOffset + action.text.length);
  }
  return nodes;
}

function Markdown({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  let codeBlockIndex = 0;
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm, inlineActionPlugin(block.inlineActions)]}
      urlTransform={(url) =>
        url.startsWith("agentkit-action:") ? url : defaultUrlTransform(url)
      }
      components={{
        a: ({ children, href, title, ...props }) => (
          <a
            {...props}
            href={href}
            data-tooltip={title ?? href}
            data-action-id={href?.startsWith("agentkit-action:") ? href.slice(16) : undefined}
            data-focus-id={href?.startsWith("agentkit-action:")
              ? `action:${href.slice(16)}`
              : href ? `url:${href}` : undefined}
            onClick={(event) => {
              event.preventDefault();
              if (!window.getSelection()?.isCollapsed) return;
              if (href?.startsWith("agentkit-action:")) {
                dispatchAction(href.slice(16));
              } else if (href) {
                if (!currentConversationID) return;
                postToNative({
                  type: "action",
                  protocolVersion,
                  action: "openURL",
                  value: href,
                  revision: currentRevision,
                  conversationID: currentConversationID,
                });
              }
            }}
          >
            {children}
          </a>
        ),
        pre: ({ children, node: _node }) => {
          const copyActionID = block.codeCopyActionIDs[codeBlockIndex];
          const scrollID = `code:${block.id}:${codeBlockIndex}`;
          codeBlockIndex += 1;
          return (
            <div className="overflow-frame code-frame" data-scroll-id={scrollID}>
              {copyActionID ? (
                <div className="code-actions">
                  <ActionButton
                    actionID={copyActionID}
                    focusID={`code-copy:${scrollID}`}
                    tooltip="Copy code"
                  >Copy</ActionButton>
                </div>
              ) : null}
              <pre>{children}</pre>
            </div>
          );
        },
        code: ({ children, className, node: _node, ...props }) => {
          const text = String(children);
          return (
            <code {...props} className={className}>
              {text.includes("\n")
                ? linkifiedActionText(text, block.inlineActions)
                : children}
            </code>
          );
        },
        table: ({ children, node: _node, ...props }) => (
          <div
            className="overflow-frame table-frame"
            data-scroll-id={`table:${block.id}`}
          >
            <table {...props}>{children}</table>
          </div>
        ),
        th: ({ children, node: _node, ...props }) => (
          <th {...props} scope="col">{children}</th>
        ),
      }}
    >
      {block.text ?? ""}
    </ReactMarkdown>
  );
}

function visibleExecutionStatus(
  status?: string,
  presentation?: string,
): string | undefined {
  switch (status) {
    case "running":
      return presentation ?? "running";
    case "failed":
      return presentation ?? "failed";
    case "canceled":
      return "canceled";
    default:
      return undefined;
  }
}

function ChangeSummary({ value }: { value: string }): React.JSX.Element {
  const counts = /^\+(\d+)\s+-(\d+)$/.exec(value);
  if (!counts) return <span className="tool-change-summary">{value}</span>;
  return (
    <span className="tool-change-summary" aria-label={value}>
      <span className="tool-lines-added" aria-hidden="true">+{counts[1]}</span>
      {" "}
      <span className="tool-lines-removed" aria-hidden="true">-{counts[2]}</span>
    </span>
  );
}

function Tool({ tool }: { tool: ConversationWebTool }): React.JSX.Element {
  const statusText = visibleExecutionStatus(tool.status, tool.statusText);
  return (
    <details
      className="tool"
      data-status={tool.status}
      data-tool-id={tool.id}
      data-disclosure-id={`tool:${tool.id}`}
    >
      <summary
        className="interactive tool-summary"
        data-focus-id={`tool:${tool.id}`}
        onClick={(event) => {
          if (!window.getSelection()?.isCollapsed) event.preventDefault();
        }}
      >
        <span className="tool-title">{tool.name}</span>
        {tool.changeSummary ? <ChangeSummary value={tool.changeSummary} /> : null}
        {tool.detail ? <span className="tool-detail-summary">{tool.detail}</span> : null}
        {statusText ? (
          <span className="tool-status" data-tone={tool.status}>{statusText}</span>
        ) : null}
        {tool.elapsed ? <span className="tool-elapsed">{tool.elapsed}</span> : null}
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      <div className="tool-detail">
        {tool.arguments ? (
          <section>
            <h4>Input</h4>
            <div className="overflow-frame code-frame" data-scroll-id={`tool-input:${tool.id}`}>
              <pre><code>{linkifiedActionText(tool.arguments, tool.argumentActions)}</code></pre>
            </div>
          </section>
        ) : null}
        {tool.output ? (
          <section>
            <div className="detail-heading">
              <h4>Output</h4>
              {tool.copyOutputActionID ? (
                <ActionButton
                  actionID={tool.copyOutputActionID}
                  focusID={`tool-output-copy:${tool.id}`}
                  tooltip="Copy output"
                >Copy</ActionButton>
              ) : null}
            </div>
            <div className="overflow-frame code-frame" data-scroll-id={`tool-output:${tool.id}`}>
              <pre><code>{linkifiedActionText(tool.output, tool.outputActions)}</code></pre>
            </div>
          </section>
        ) : null}
        {tool.artifactActionID ? (
          <ActionButton actionID={tool.artifactActionID} focusID={`tool-artifact:${tool.id}`}>
            Open artifact
          </ActionButton>
        ) : null}
        {tool.assetActions.map((asset) => (
          <ActionButton
            key={asset.actionID}
            actionID={asset.actionID}
            focusID={asset.focusID}
            tooltip={asset.tooltip}
          >
            {asset.title}
          </ActionButton>
        ))}
      </div>
    </details>
  );
}

function activateSelectableAction(
  event: React.MouseEvent | React.KeyboardEvent,
  actionID?: string,
): void {
  if (!actionID || !window.getSelection()?.isCollapsed) return;
  if ("key" in event && !["Enter", " "].includes(event.key)) return;
  event.preventDefault();
  dispatchAction(actionID);
}

function Block({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  switch (block.kind) {
    case "markdown":
      return <Markdown block={block} />;
    case "toolGroup":
      if (block.tools.length > 1) {
        const statusText = visibleExecutionStatus(block.status);
        return (
          <details
            className="tool-group"
            data-status={block.status}
            data-disclosure-id={`tool-group:${block.id}`}
          >
            <summary
              className="interactive tool-group-summary"
              data-focus-id={`tool-group:${block.id}`}
              onClick={(event) => {
                if (!window.getSelection()?.isCollapsed) event.preventDefault();
              }}
            >
              <span className="tool-group-title">{block.title}</span>
              {statusText ? (
                <span className="tool-status" data-tone={block.status}>{statusText}</span>
              ) : null}
              <span className="disclosure-chevron" aria-hidden="true">›</span>
            </summary>
            <div className="tool-group-tools">
              {block.tools.map((tool) => <Tool key={tool.id} tool={tool} />)}
            </div>
          </details>
        );
      }
      return (
        <section className="tool-group" data-status={block.status}>
          {block.tools.map((tool) => <Tool key={tool.id} tool={tool} />)}
        </section>
      );
    case "artifact":
      return (
        <section className="artifact-block">
          <div
            className={block.actionID ? "interactive artifact-title" : "artifact-title"}
            role={block.actionID ? "button" : undefined}
            tabIndex={block.actionID ? 0 : undefined}
            data-focus-id={block.actionID ? `action:${block.actionID}` : undefined}
            data-tooltip={block.actionTooltip}
            onClick={(event) => activateSelectableAction(event, block.actionID)}
            onKeyDown={(event) => activateSelectableAction(event, block.actionID)}
          >
            {block.title}
          </div>
          {block.text ? (
            <div className="overflow-frame code-frame" data-scroll-id={`artifact:${block.id}`}>
              <pre><code>{block.text}</code></pre>
            </div>
          ) : null}
        </section>
      );
    case "system":
      return (
        <aside className="system-block" data-status={block.status}>
          <span>{block.title}</span> {block.text}
        </aside>
      );
    case "childStream":
      const childStatus = visibleExecutionStatus(block.status);
      return (
        <section
          className={block.actionID ? "interactive child-stream" : "child-stream"}
          data-status={block.status}
          role={block.actionID ? "button" : undefined}
          tabIndex={block.actionID ? 0 : undefined}
          data-focus-id={block.actionID ? `action:${block.actionID}` : undefined}
          data-tooltip={block.actionTooltip}
          onClick={(event) => activateSelectableAction(event, block.actionID)}
          onKeyDown={(event) => activateSelectableAction(event, block.actionID)}
        >
          <span className="child-stream-kind">
            {block.childStreamKind === "job" ? "Job" : "Subagent"}
          </span>
          <span className="child-stream-title">{block.title}</span>
          {childStatus ? (
            <span className="tool-status" data-tone={block.status}>{childStatus}</span>
          ) : null}
          {block.elapsed ? <span className="tool-elapsed">{block.elapsed}</span> : null}
          <span className="disclosure-chevron" aria-hidden="true">›</span>
        </section>
      );
  }
}

function ExtensionSection({
  nodeID,
  section,
}: {
  nodeID: string;
  section: ConversationWebExtensionNode["sections"][number];
}): React.JSX.Element {
  const [isOpen, setIsOpen] = useState(section.initiallyExpanded);
  return (
    <details
      className="extension-section"
      data-disclosure-id={`extension:${nodeID}:section:${section.id}`}
      data-status={section.status}
      open={isOpen}
      onToggle={(event) => setIsOpen(event.currentTarget.open)}
    >
      <summary
        className="interactive extension-section-summary"
        data-focus-id={`extension:${nodeID}:section:${section.id}`}
      >
        <span>{section.title}</span>
        {section.summary ? <span className="extension-section-description">{section.summary}</span> : null}
        {section.status ? <span className="extension-status">{section.status}</span> : null}
      </summary>
      {section.rows.length ? (
        <dl className="extension-rows">
          {section.rows.map((row) => (
            <div className="extension-row" key={row.id}>
              <dt>{row.label}</dt>
              <dd>{row.value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
    </details>
  );
}

function ExtensionNode({ node }: { node: ConversationWebExtensionNode }): React.JSX.Element {
  return (
    <section
      className="extension-node"
      data-tone={node.tone}
      data-status={node.status}
      data-anchor-id={`extension:${node.id}`}
    >
      <header className="extension-header">
        <div>
          <h3>{node.title}</h3>
          {node.summary ? <p>{node.summary}</p> : null}
        </div>
        {node.status ? <span className="extension-status">{node.status}</span> : null}
      </header>
      {node.badges.length ? (
        <ul className="extension-badges" aria-label="Attributes">
          {node.badges.map((badge) => (
            <li data-tone={badge.tone} key={badge.id}>{badge.text}</li>
          ))}
        </ul>
      ) : null}
      {node.sections.map((section) => (
        <ExtensionSection key={section.id} nodeID={node.id} section={section} />
      ))}
      {node.actions.length ? (
        <div className="extension-actions" aria-label="Extension actions">
          {node.actions.map((action) => (
            <ActionButton
              key={action.actionID}
              actionID={action.actionID}
              focusID={action.focusID}
              tooltip={action.tooltip}
            >
              {action.title}
            </ActionButton>
          ))}
        </div>
      ) : null}
      {node.footer ? <footer className="extension-footer">{node.footer}</footer> : null}
    </section>
  );
}

const Turn = memo(function Turn({ turn }: { turn: ConversationWebTurn }) {
  const footer = turn.footer;
  const headingID = `turn-heading-${turn.id}`;
  return (
    <article
      className="turn"
      data-turn-id={turn.id}
      data-anchor-id={`turn:${turn.id}`}
      aria-labelledby={headingID}
    >
      <h2 className="visually-hidden" id={headingID}>Conversation turn</h2>
      {turn.userPrompt ? (
        <div className="user-prompt" data-selection-id={`turn:${turn.id}:user`}>
          {turn.userPrompt}
        </div>
      ) : null}
      <div className="assistant-lane">
        <div className="assistant-label" aria-hidden="true">Agent</div>
        {turn.blocks.map((block) => (
          <div
            className="turn-block"
            data-block-id={block.id}
            data-selection-id={`block:${block.id}`}
            key={block.id}
          >
            <Block block={block} />
          </div>
        ))}
        {footer ? (
          <footer className="turn-footer" data-selection-id={`turn:${turn.id}:footer`}>
            <span>{footer.totalTokens} tokens</span>
            {footer.usageUnits ? <span>{footer.usageUnits} units</span> : null}
            <span>{footer.elapsed}</span>
            {footer.invocationCount ? <span>{footer.invocationCount}x</span> : null}
            {footer.contextTokens ? <span>ctx {footer.contextTokens}</span> : null}
          </footer>
        ) : null}
        {turn.copyActionID || turn.assetsActionID ? (
          <div className="turn-actions" aria-label="Turn actions">
            {turn.copyActionID ? (
              <ActionButton
                actionID={turn.copyActionID}
                focusID={`turn-copy:${turn.id}`}
                tooltip="Copy turn"
              >Copy</ActionButton>
            ) : null}
            {turn.assetsActionID ? (
              <ActionButton
                actionID={turn.assetsActionID}
                focusID={`turn-assets:${turn.id}`}
                tooltip="Show turn assets"
              >
                Assets {turn.assetCount}
              </ActionButton>
            ) : null}
          </div>
        ) : null}
      </div>
      {turn.extensionNodes.map((node) => (
        <div
          className="turn-extension"
          data-selection-id={`extension:${node.id}`}
          key={node.id}
        >
          <ExtensionNode node={node} />
        </div>
      ))}
    </article>
  );
});

function App(): React.JSX.Element {
  const [conversation, setConversation] = useState<ConversationWebDocument>();
  const [isPinned, setIsPinned] = useState(true);
  const pendingRestoration = useRef<RestorationSnapshot | undefined>(undefined);
  const conversationID = useRef<string | undefined>(undefined);

  useLayoutEffect(() => {
    const stopViewportController = viewportController.start(setIsPinned);
    window.AgentKitWorkbench = {
      applyUpdateBase64(payload: string) {
        try {
          currentUpdateStartedAt = performance.now();
          const update = decodeUpdate(payload);
          const isReset = update.kind === "reset";
          if (
            !isReset &&
            (!update.patch ||
              update.patch.baseRevision !== currentRevision ||
              update.conversationID !== conversationID.current)
          ) {
            postToNative({
              type: "resync",
              protocolVersion,
              currentRevision,
              receivedBaseRevision: update.patch?.baseRevision ?? -1,
            });
            return;
          }

          pendingRestoration.current = {
            selection: isReset ? null : captureSelection(),
            horizontalOffsets: isReset ? new Map() : captureHorizontalOffsets(),
            expandedDisclosures: isReset ? new Set() : captureExpandedDisclosures(),
            focusID: isReset ? null : captureFocusedElement(),
            viewport: isReset
              ? { pinned: true, anchor: null }
              : viewportController.capture(),
            forcePinToBottom: isReset || Boolean(update.patch?.forcePinToBottom),
          };
          currentRevision = update.revision;
          if (isReset) {
            if (!update.document) throw new Error("Reset is missing document");
            conversationID.current = update.document.conversationID;
            currentConversationID = update.document.conversationID;
            setConversation(update.document);
          } else {
            setConversation((current) => {
              if (!current || !update.patch) return current;
              return applyOperations(
                current,
                update.patch.operations,
                update.revision,
              );
            });
          }
        } catch (error) {
          console.error("AgentKit workbench rejected an update", error);
        }
      },
    };
    postToNative({ type: "ready", protocolVersion });
    return () => {
      stopViewportController();
      currentConversationID = undefined;
      delete window.AgentKitWorkbench;
    };
  }, []);

  useLayoutEffect(() => {
    if (!conversation) return;
    const restoration = pendingRestoration.current ?? {
      selection: null,
      horizontalOffsets: new Map<string, number>(),
      expandedDisclosures: new Set<string>(),
      focusID: null,
      viewport: { pinned: true, anchor: null },
      forcePinToBottom: true,
    };
    const revealTask = window.setTimeout(() => {
      restoreExpandedDisclosures(restoration.expandedDisclosures);
      restoreHorizontalOffsets(restoration.horizontalOffsets);
      restoreSelection(restoration.selection);
      restoreFocusedElement(restoration.focusID);
      viewportController.restore(restoration.viewport, restoration.forcePinToBottom);
      document.documentElement.classList.add("workbench-ready");
      postToNative({
        type: "ack",
        protocolVersion,
        revision: conversation.revision,
        conversationID: conversation.conversationID,
        applyDurationMilliseconds: Math.max(0, performance.now() - currentUpdateStartedAt),
      });
      pendingRestoration.current = undefined;
    }, 0);
    return () => window.clearTimeout(revealTask);
  }, [conversation]);

  if (!conversation) {
    return <main className="conversation-shell" aria-label="Conversation" aria-busy="true" />;
  }

  return (
    <main className="conversation-shell" aria-label="Conversation">
      {conversation.todos.length ? (
        <section className="todo-panel" aria-label="Plan" data-anchor-id="todo-panel">
          {conversation.todos.map((todo, index) => (
            <div className="todo-row" data-status={todo.status} key={`${index}-${todo.content}`}>
              <span className="status-dot" aria-hidden="true" />
              <span>{todo.activeForm && todo.status === "in_progress" ? todo.activeForm : todo.content}</span>
              <span className="visually-hidden">{todo.status}</span>
            </div>
          ))}
        </section>
      ) : null}
      {conversation.turns.map((turn) => <Turn key={turn.id} turn={turn} />)}
      {conversation.live ? (
        <div
          className="live-indicator"
          role="status"
          aria-live="polite"
          aria-atomic="true"
          data-anchor-id="live-indicator"
        >
          <span className="status-dot" aria-hidden="true" />
          {conversation.live.isThinking ? "Thinking" : "Working"}
        </div>
      ) : null}
      {!isPinned ? (
        <button
          className="jump-to-latest"
          type="button"
          data-focus-id="jump-to-latest"
          aria-label="Jump to latest message"
          onClick={() => viewportController.jumpToLatest()}
        >
          ↓ Latest
        </button>
      ) : null}
    </main>
  );
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root");
createRoot(root).render(<App />);
