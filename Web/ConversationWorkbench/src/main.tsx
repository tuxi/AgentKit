import React, { memo, useEffect, useLayoutEffect, useRef, useState } from "react";
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
let workbenchSuspended = false;
let suspendedFocusID: string | undefined;
const workbenchSuspensionEvent = "agentkit-workbench-suspension";

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

function captureHorizontalOffsets(roots: ParentNode[] = [document]): Map<string, number> {
  const offsets = new Map<string, number>();
  for (const root of roots) {
    root.querySelectorAll<HTMLElement>("[data-scroll-id]").forEach((element) => {
      const id = element.dataset.scrollId;
      if (id && element.scrollLeft > 0) offsets.set(id, element.scrollLeft);
    });
  }
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

function captureExpandedDisclosures(roots: ParentNode[] = [document]): Set<string> {
  const ids = new Set<string>();
  for (const root of roots) {
    root.querySelectorAll<HTMLDetailsElement>("details[open][data-disclosure-id]")
      .forEach((element) => {
        const id = element.dataset.disclosureId;
        if (id) ids.add(id);
      });
  }
  return ids;
}

/// Only nodes replaced by an update can lose browser-owned state. Streaming
/// normally replaces one tail block, so avoid querying every code frame and
/// disclosure in a long conversation on every token batch.
function replacedDOMRoots(update: ConversationWebUpdate): ParentNode[] {
  if (update.kind === "reset" || !update.patch) return [];
  const selectors = new Set<string>();
  for (const operation of update.patch.operations) {
    if (operation.kind === "replaceBlock" && operation.block?.id) {
      selectors.add(`[data-block-id="${CSS.escape(operation.block.id)}"]`);
    } else if (operation.kind === "replaceTurn" && operation.turn?.id) {
      selectors.add(`[data-turn-id="${CSS.escape(operation.turn.id)}"]`);
    }
  }
  return Array.from(selectors)
    .map((selector) => document.querySelector<HTMLElement>(selector))
    .filter((element): element is HTMLElement => Boolean(element));
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
type ViewportSnapshot = {
  pinned: boolean;
  anchor: ViewportAnchor | null;
  interactionEpoch: number;
};

class ViewportController {
  private static readonly bottomThreshold = 36;

  private pinned = true;
  private programmaticUntil = 0;
  private interacting = false;
  private interactionEpoch = 0;
  private lastAnchor: ViewportAnchor | null = null;
  private interactionTimer: number | undefined;
  private followFrame: number | undefined;
  private followTimer: number | undefined;
  private reportTimer: number | undefined;
  private reportDueAt: number | undefined;
  private resizeObserver: ResizeObserver | undefined;
  private lastEvent = "start";
  private onPinChange: (pinned: boolean) => void = () => {};
  private onViewportChange: (snapshot: ViewportSnapshot) => void = () => {};

  start(
    onPinChange: (pinned: boolean) => void,
    onViewportChange: (snapshot: ViewportSnapshot) => void,
  ): () => void {
    this.onPinChange = onPinChange;
    this.onViewportChange = onViewportChange;

    const beginInteraction = (leavesBottom: boolean) => {
      // A real gesture always wins, even if it starts during the short lease
      // used to identify scroll events caused by our own correction.
      this.programmaticUntil = 0;
      this.interactionEpoch += 1;
      this.interacting = true;
      this.lastEvent = leavesBottom ? "interaction-away" : "interaction";
      if (leavesBottom) this.setPinned(false);
      this.cancelScheduledFollow();
      this.scheduleViewportReport(24);
      this.scheduleInteractionEnd();
    };
    const handleWheel = (event: WheelEvent) => {
      beginInteraction(event.deltaY < 0);
    };
    const handlePointerDown = () => {
      beginInteraction(false);
    };
    const handlePointerEnd = () => {
      this.scheduleInteractionEnd(80);
    };
    const handleTouchStart = () => {
      beginInteraction(false);
    };
    const handleTouchEnd = () => {
      this.scheduleInteractionEnd(100);
    };
    const markKeyboardIntent = (event: KeyboardEvent) => {
      if (!["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "].includes(event.key)) return;
      const target = event.target instanceof HTMLElement ? event.target : null;
      if (target?.closest("button, summary, a, input, textarea, select, [contenteditable='true']")) return;
      beginInteraction(["ArrowUp", "PageUp", "Home"].includes(event.key));
    };
    const handleScroll = () => {
      if (performance.now() < this.programmaticUntil) return;
      if (!this.interacting) beginInteraction(false);
      this.lastEvent = "user-scroll";
      this.setPinned(this.isAtBottom());
      // Do not walk the conversation on every scroll event. The throttled
      // viewport report or interaction-end checkpoint captures it once.
      this.lastAnchor = null;
      this.scheduleViewportReport();
    };
    const handleResize = () => {
      if (this.interacting) return;
      if (this.pinned && !this.isExactlyAtBottom()) {
        this.scheduleFollow();
      } else if (this.lastAnchor) {
        this.restoreAnchor(this.lastAnchor);
      }
      this.scheduleViewportReport();
    };

    window.addEventListener("wheel", handleWheel, { passive: true });
    window.addEventListener("touchstart", handleTouchStart, { passive: true });
    window.addEventListener("touchend", handleTouchEnd, { passive: true });
    window.addEventListener("pointerdown", handlePointerDown, { passive: true });
    window.addEventListener("pointerup", handlePointerEnd, { passive: true });
    window.addEventListener("pointercancel", handlePointerEnd, { passive: true });
    window.addEventListener("keydown", markKeyboardIntent);
    window.addEventListener("scroll", handleScroll, { passive: true });
    window.addEventListener("resize", handleResize);
    this.resizeObserver = new ResizeObserver(() => {
      // Height growth follows only while the viewport was already following.
      // User interaction or a reading position cancels this path immediately.
      if (this.pinned && !this.interacting && !this.isExactlyAtBottom()) {
        this.lastEvent = "resize-follow";
        this.scheduleFollow();
      }
    });
    this.resizeObserver.observe(document.body);
    const root = document.getElementById("root");
    if (root) this.resizeObserver.observe(root);

    return () => {
      window.removeEventListener("wheel", handleWheel);
      window.removeEventListener("touchstart", handleTouchStart);
      window.removeEventListener("touchend", handleTouchEnd);
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("pointerup", handlePointerEnd);
      window.removeEventListener("pointercancel", handlePointerEnd);
      window.removeEventListener("keydown", markKeyboardIntent);
      window.removeEventListener("scroll", handleScroll);
      window.removeEventListener("resize", handleResize);
      this.resizeObserver?.disconnect();
      this.resizeObserver = undefined;
      if (this.interactionTimer !== undefined) window.clearTimeout(this.interactionTimer);
      if (this.followFrame !== undefined) window.cancelAnimationFrame(this.followFrame);
      if (this.followTimer !== undefined) window.clearTimeout(this.followTimer);
      if (this.reportTimer !== undefined) window.clearTimeout(this.reportTimer);
      this.reportDueAt = undefined;
    };
  }

  capture(): ViewportSnapshot {
    if (!this.interacting && this.pinned && !this.isAtBottom()) {
      // Geometry is authoritative. A stale boolean must never pull a reader
      // back to the tail when the content was already away from the bottom.
      this.setPinned(false);
    }
    return {
      pinned: this.pinned && !this.interacting && this.isAtBottom(),
      anchor: this.lastAnchor ?? this.captureAnchor(),
      interactionEpoch: this.interactionEpoch,
    };
  }

  diagnostics(): {
    pinned: boolean;
    interacting: boolean;
    distanceFromBottom: number;
    interactionEpoch: number;
    lastEvent: string;
  } {
    return {
      pinned: this.pinned,
      interacting: this.interacting,
      distanceFromBottom: this.distanceFromBottom(),
      interactionEpoch: this.interactionEpoch,
      lastEvent: this.lastEvent,
    };
  }

  isInteractionActive(): boolean {
    return this.interacting;
  }

  /// Called from React layout effects after local typewriter growth. Keeping
  /// the scroll correction in the same pre-paint transaction prevents the
  /// one-frame bottom gap produced by ResizeObserver -> rAF correction.
  contentDidChangeBeforePaint(): void {
    if (!this.pinned || this.interacting || this.isExactlyAtBottom()) return;
    this.cancelScheduledFollow();
    this.lastEvent = "layout-follow";
    this.performProgrammaticScroll(() => {
      window.scrollTo(0, document.documentElement.scrollHeight);
    });
    this.scheduleViewportReport();
  }

  restore(snapshot: ViewportSnapshot, forcePinToBottom: boolean): void {
    if (this.interacting || snapshot.interactionEpoch !== this.interactionEpoch) {
      // A gesture that started after capture owns the viewport. Never correct
      // underneath wheel/scrollbar/selection interaction.
      this.lastAnchor = this.captureAnchor();
      this.lastEvent = "restore-yielded-to-user";
      this.scheduleViewportReport();
      return;
    }
    if (forcePinToBottom || snapshot.pinned) {
      this.lastEvent = forcePinToBottom ? "restore-forced" : "restore-following";
      this.setPinned(true);
      this.scrollToBottom();
      return;
    }
    this.setPinned(false);
    this.lastEvent = "restore-anchor";
    if (snapshot.anchor) this.restoreAnchor(snapshot.anchor);
    this.lastAnchor = this.captureAnchor();
    this.scheduleViewportReport();
  }

  jumpToLatest(): void {
    this.interactionEpoch += 1;
    this.interacting = false;
    this.setPinned(true);
    this.scrollToBottom();
  }

  private scheduleInteractionEnd(delay = 160): void {
    if (this.interactionTimer !== undefined) window.clearTimeout(this.interactionTimer);
    this.interactionTimer = window.setTimeout(() => {
      this.interactionTimer = undefined;
      this.interacting = false;
      this.setPinned(this.isAtBottom());
      this.lastEvent = this.pinned ? "interaction-ended-at-bottom" : "interaction-ended-reading";
      this.lastAnchor = this.captureAnchor();
      this.scheduleViewportReport(0);
    }, delay);
  }

  private scheduleFollow(): void {
    if (!this.pinned || this.interacting
        || this.followFrame !== undefined || this.followTimer !== undefined) return;
    const perform = () => {
      if (this.followFrame !== undefined) window.cancelAnimationFrame(this.followFrame);
      if (this.followTimer !== undefined) window.clearTimeout(this.followTimer);
      this.followFrame = undefined;
      this.followTimer = undefined;
      if (this.pinned && !this.interacting) this.scrollToBottom();
    };
    this.followFrame = window.requestAnimationFrame(perform);
    // Detached/background WKWebViews may throttle rAF. The timeout preserves
    // the same coalescing contract and guarantees eventual bottom alignment.
    this.followTimer = window.setTimeout(perform, 24);
  }

  private cancelScheduledFollow(): void {
    if (this.followFrame !== undefined) window.cancelAnimationFrame(this.followFrame);
    if (this.followTimer !== undefined) window.clearTimeout(this.followTimer);
    this.followFrame = undefined;
    this.followTimer = undefined;
  }

  private scrollToBottom(): void {
    this.performProgrammaticScroll(() => {
      window.scrollTo(0, document.documentElement.scrollHeight);
    });
    this.lastAnchor = this.captureAnchor();
    this.scheduleViewportReport();
  }

  private restoreAnchor(anchor: ViewportAnchor): void {
    const element = document.querySelector<HTMLElement>(
      `[data-anchor-id="${CSS.escape(anchor.id)}"]`,
    );
    if (!element) return;
    this.performProgrammaticScroll(() => {
      window.scrollBy(0, element.getBoundingClientRect().top - anchor.top);
    });
  }

  private performProgrammaticScroll(operation: () => void): void {
    this.programmaticUntil = performance.now() + 120;
    operation();
  }

  private setPinned(next: boolean): void {
    if (this.pinned === next) return;
    this.pinned = next;
    this.onPinChange(next);
    this.scheduleViewportReport();
  }

  private distanceFromBottom(): number {
    const viewport = document.documentElement;
    return viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
  }

  private isAtBottom(): boolean {
    return this.distanceFromBottom() <= ViewportController.bottomThreshold;
  }

  private isExactlyAtBottom(): boolean {
    return this.distanceFromBottom() <= 0.5;
  }

  private scheduleViewportReport(delay = 120): void {
    const dueAt = performance.now() + delay;
    if (this.reportTimer !== undefined && this.reportDueAt !== undefined) {
      // A user-intent report must not be postponed by the subsequent scroll
      // event's ordinary debounce.
      if (this.reportDueAt <= dueAt) return;
      window.clearTimeout(this.reportTimer);
    }
    this.reportDueAt = dueAt;
    this.reportTimer = window.setTimeout(() => {
      this.reportTimer = undefined;
      this.reportDueAt = undefined;
      const anchor = this.lastAnchor ?? this.captureAnchor();
      this.onViewportChange({
        pinned: this.pinned && !this.interacting && this.isAtBottom(),
        anchor,
        interactionEpoch: this.interactionEpoch,
      });
    }, delay);
  }

  private captureAnchor(): ViewportAnchor | null {
    const sampleX = Math.max(1, Math.min(window.innerWidth - 1, window.innerWidth / 2));
    const sampleYs = [1, 16, 64, Math.min(window.innerHeight - 1, 160)];
    for (const y of sampleYs) {
      for (const hit of document.elementsFromPoint(sampleX, Math.max(1, y))) {
        const element = hit.closest<HTMLElement>("[data-anchor-id]");
        const id = element?.dataset.anchorId;
        if (element && id) return { id, top: element.getBoundingClientRect().top };
      }
    }

    // Unusual layouts can leave the sampled points over fixed chrome. Keep a
    // correctness fallback, but normal scrolling never needs this full scan.
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
  revision: number;
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
      case "updateTurn": {
        if (operation.index === undefined || !operation.turn) break;
        const currentTurn = next.turns[operation.index];
        if (!currentTurn) break;
        const turns = next.turns.slice();
        turns[operation.index] = {
          ...operation.turn,
          blocks: currentTurn.blocks,
        };
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
      case "replaceBlock": {
        if (
          operation.index === undefined
          || operation.blockIndex === undefined
          || !operation.block
        ) break;
        const currentTurn = next.turns[operation.index];
        if (!currentTurn) break;
        const blocks = currentTurn.blocks.slice();
        blocks[operation.blockIndex] = operation.block;
        const turns = next.turns.slice();
        turns[operation.index] = { ...currentTurn, blocks };
        next = { ...next, turns };
        break;
      }
      case "appendBlock": {
        if (operation.index === undefined || !operation.block) break;
        const currentTurn = next.turns[operation.index];
        if (!currentTurn) break;
        const turns = next.turns.slice();
        turns[operation.index] = {
          ...currentTurn,
          blocks: [...currentTurn.blocks, operation.block],
        };
        next = { ...next, turns };
        break;
      }
      case "removeBlocks": {
        if (operation.index === undefined || operation.blockIndex === undefined) break;
        const currentTurn = next.turns[operation.index];
        if (!currentTurn) break;
        const turns = next.turns.slice();
        turns[operation.index] = {
          ...currentTurn,
          blocks: currentTurn.blocks.slice(0, operation.blockIndex),
        };
        next = { ...next, turns };
        break;
      }
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

function fencedCodeLanguage(children: React.ReactNode): string {
  const code = React.Children.toArray(children).find(React.isValidElement);
  if (!code) return "text";
  const className = (code.props as { className?: string }).className ?? "";
  return className.match(/(?:^|\s)language-([^\s]+)/)?.[1] ?? "text";
}

const MarkdownBody = memo(function MarkdownBody({
  block,
}: {
  block: ConversationWebBlock;
}): React.JSX.Element {
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
          const language = fencedCodeLanguage(children);
          const copyActionID = block.codeCopyActionIDs[codeBlockIndex];
          const scrollID = `code:${block.id}:${codeBlockIndex}`;
          codeBlockIndex += 1;
          return (
            <div className="overflow-frame code-frame" data-scroll-id={scrollID}>
              <div className="block-frame-header">
                <span className="block-frame-label" aria-hidden="true">{language}</span>
                {copyActionID ? (
                  <ActionButton
                    actionID={copyActionID}
                    focusID={`code-copy:${scrollID}`}
                    tooltip="Copy code"
                  >Copy</ActionButton>
                ) : null}
              </div>
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
            <div className="block-frame-header" aria-hidden="true">
              <span className="block-frame-label">table</span>
            </div>
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
});

const streamingFrameMilliseconds = 33;
const streamingFallbackMilliseconds = 50;

function hasActiveTextSelection(): boolean {
  const selection = window.getSelection();
  return Boolean(selection && !selection.isCollapsed);
}

function commonPrefixLength(lhs: string, rhs: string): number {
  const limit = Math.min(lhs.length, rhs.length);
  let index = 0;
  while (index < limit && lhs[index] === rhs[index]) index += 1;
  return index;
}

type StableMarkdownScanner = {
  scannedOffset: number;
  stableOffset: number;
  openFence: "```" | "~~~" | null;
};

function newStableMarkdownScanner(): StableMarkdownScanner {
  return { scannedOffset: 0, stableOffset: 0, openFence: null };
}

/// Advances only across newly completed lines and returns a prefix ending at a
/// complete Markdown block separator. A blank line inside an open fenced code
/// block is content, not a commit boundary.
function advanceStableMarkdownPrefix(
  text: string,
  scanner: StableMarkdownScanner,
): number {
  while (scanner.scannedOffset < text.length) {
    const newline = text.indexOf("\n", scanner.scannedOffset);
    if (newline < 0) break;
    const lineEnd = newline + 1;
    const value = text.slice(scanner.scannedOffset, lineEnd);
    const trimmed = value.trimStart();
    if (scanner.openFence) {
      if (trimmed.startsWith(scanner.openFence)) scanner.openFence = null;
    } else if (trimmed.startsWith("```")) {
      scanner.openFence = "```";
    } else if (trimmed.startsWith("~~~")) {
      scanner.openFence = "~~~";
    }
    scanner.scannedOffset = lineEnd;
    if (!scanner.openFence && value.trim().length === 0) {
      scanner.stableOffset = lineEnd;
    }
  }
  return scanner.stableOffset;
}

function streamingPresentationBlock(
  block: ConversationWebBlock,
  text: string,
): ConversationWebBlock {
  return {
    ...block,
    text,
    // These actions encode exact text and can change on every target revision.
    // Expose them only on the final Markdown tree so a low-frequency parsed
    // frame never sends a token from an older acknowledged revision.
    inlineActions: [],
    codeCopyActionIDs: [],
  };
}

/// The renderer acknowledges the latest target immediately, while this local
/// player reveals one lightweight active block at a stable cadence. Completed
/// Markdown blocks are committed once; the growing tail never reparses on a
/// timer. Playback and parsing both pause during scrolling or text selection.
function StreamingMarkdown({
  block,
}: {
  block: ConversationWebBlock;
}): React.JSX.Element {
  const targetBlock = useRef(block);
  targetBlock.current = block;
  const visibleText = useRef("");
  const committedText = useRef("");
  const markdownScanner = useRef(newStableMarkdownScanner());
  const [visibleVersion, setVisibleVersion] = useState(0);
  const [committedBlock, setCommittedBlock] = useState<ConversationWebBlock>(() =>
    streamingPresentationBlock(block, ""));

  useEffect(() => {
    let frame: number | undefined;
    let fallback: number | undefined;
    let lastAdvanceAt = performance.now();

    const cancelScheduledTick = () => {
      if (frame !== undefined) window.cancelAnimationFrame(frame);
      if (fallback !== undefined) window.clearTimeout(fallback);
      frame = undefined;
      fallback = undefined;
    };
    const scheduleTick = () => {
      if (workbenchSuspended) return;
      frame = window.requestAnimationFrame(tick);
      // Detached/background WKWebViews may throttle rAF. Keep playback
      // eventual without using this timer in the foreground render path.
      fallback = window.setTimeout(
        () => tick(performance.now()),
        streamingFallbackMilliseconds,
      );
    };
    const tick = (now: number) => {
      cancelScheduledTick();
      const target = targetBlock.current.text ?? "";
      let current = visibleText.current;

      if (!target.startsWith(current)) {
        const retainedLength = commonPrefixLength(current, target);
        current = target.slice(0, retainedLength);
        visibleText.current = current;
        if (retainedLength < markdownScanner.current.scannedOffset) {
          markdownScanner.current = newStableMarkdownScanner();
          advanceStableMarkdownPrefix(current, markdownScanner.current);
        }
        if (!current.startsWith(committedText.current)) {
          committedText.current = "";
          setCommittedBlock(streamingPresentationBlock(targetBlock.current, ""));
        }
        setVisibleVersion((version) => version + 1);
      }

      const userOwnsViewport = viewportController.isInteractionActive()
        || hasActiveTextSelection();
      if (!userOwnsViewport
          && now - lastAdvanceAt >= streamingFrameMilliseconds
          && current.length < target.length) {
        const backlog = target.length - current.length;
        // Small backlogs read like typing; large batches catch up quickly
        // without making the UI wait seconds behind the model.
        const step = Math.min(backlog, Math.max(2, Math.ceil(backlog * 0.22)));
        current = target.slice(0, current.length + step);
        visibleText.current = current;
        lastAdvanceAt = now;
        setVisibleVersion((version) => version + 1);
      }

      const stableLength = advanceStableMarkdownPrefix(
        visibleText.current,
        markdownScanner.current,
      );
      const nextCommittedText = visibleText.current.slice(0, stableLength);
      if (!userOwnsViewport && committedText.current !== nextCommittedText) {
        committedText.current = nextCommittedText;
        setCommittedBlock(streamingPresentationBlock(
          targetBlock.current,
          nextCommittedText,
        ));
      }

      scheduleTick();
    };
    const handleSuspensionChange = () => {
      if (workbenchSuspended) {
        cancelScheduledTick();
      } else if (frame === undefined && fallback === undefined) {
        scheduleTick();
      }
    };
    window.addEventListener(workbenchSuspensionEvent, handleSuspensionChange);
    scheduleTick();
    return () => {
      window.removeEventListener(workbenchSuspensionEvent, handleSuspensionChange);
      cancelScheduledTick();
    };
  }, []);

  useLayoutEffect(() => {
    viewportController.contentDidChangeBeforePaint();
  }, [visibleVersion, committedBlock]);

  const committed = committedText.current;
  const visible = visibleText.current;
  const tail = visible.startsWith(committed) ? visible.slice(committed.length) : visible;
  void visibleVersion;
  return (
    <div className="streaming-markdown" aria-busy="true">
      <MarkdownBody block={committedBlock} />
      {tail ? <span className="streaming-text-tail">{tail}</span> : null}
    </div>
  );
}

function Markdown({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  return block.status === "streaming"
    ? <StreamingMarkdown block={block} />
    : <MarkdownBody block={block} />;
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

function TodoPanel({
  todos,
  turnID,
  isLive,
}: {
  todos: ConversationWebDocument["todos"];
  turnID: string;
  isLive: boolean;
}): React.JSX.Element {
  const completed = todos.filter((todo) => todo.status === "completed").length;
  const active = todos.filter((todo) => todo.status === "in_progress").length;
  const isComplete = completed === todos.length;
  const [isExpanded, setIsExpanded] = useState(isLive && !isComplete);
  const activeTodo = todos.find((todo) => todo.status === "in_progress");
  const progress = todos.length ? (completed / todos.length) * 100 : 0;

  useEffect(() => {
    if (isLive && !isComplete) setIsExpanded(true);
    if (!isLive && isComplete) setIsExpanded(false);
  }, [isComplete, isLive]);

  return (
    <details
      className="todo-panel"
      data-anchor-id={`todo:${turnID}`}
      data-disclosure-id={`todo:${turnID}`}
      open={isExpanded}
      onToggle={(event) => setIsExpanded(event.currentTarget.open)}
    >
      <summary
        className="interactive todo-panel-summary"
        data-focus-id={`todo:${turnID}`}
        onClick={(event) => {
          if (!window.getSelection()?.isCollapsed) event.preventDefault();
        }}
      >
        <span className="todo-panel-title">Tasks</span>
        <span className="todo-count">{completed}/{todos.length}</span>
        {active ? <span className="todo-active">{active} active</span> : null}
        <span className="todo-panel-current">
          {activeTodo ? (activeTodo.activeForm || activeTodo.content) : null}
        </span>
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      <div
        className="todo-progress"
        role="progressbar"
        aria-label="Task progress"
        aria-valuemin={0}
        aria-valuemax={todos.length}
        aria-valuenow={completed}
      >
        <span style={{ width: `${progress}%` }} />
      </div>
      <div className="todo-list">
        {todos.map((todo, index) => {
          const text = todo.status === "in_progress" && todo.activeForm
            ? todo.activeForm
            : todo.content;
          return (
            <div className="todo-row" data-status={todo.status} key={`${index}-${todo.content}`}>
              <span className="todo-status-marker" aria-hidden="true">
                {todo.status === "completed" ? "✓" : ""}
              </span>
              <span className="todo-row-text">{text}</span>
              <span className="visually-hidden">{todo.status}</span>
            </div>
          );
        })}
      </div>
    </details>
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

const Block = memo(function Block({
  block,
}: {
  block: ConversationWebBlock;
}): React.JSX.Element {
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
});

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

function CollapsibleUserPrompt({
  turnID,
  text,
}: {
  turnID: string;
  text: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const [canToggle, setCanToggle] = useState(false);
  const contentRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    const element = contentRef.current;
    if (!element) return;

    const measure = () => {
      if (!expanded) {
        setCanToggle(element.scrollHeight > element.clientHeight + 1);
      }
    };
    measure();

    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [text, expanded]);

  return (
    <div className="user-prompt">
      <div
        ref={contentRef}
        className={`user-prompt-content ${expanded ? "is-expanded" : ""}`}
        data-selection-id={`turn:${turnID}:user`}
      >
        {text}
      </div>

      {canToggle ? (
        <button
          type="button"
          className="user-prompt-toggle"
          data-focus-id={`user-prompt-toggle:${turnID}`}
          aria-expanded={expanded}
          onClick={() => setExpanded((value) => !value)}
        >
          {expanded ? "收起" : "显示更多"}
        </button>
      ) : null}
    </div>
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
        <CollapsibleUserPrompt turnID={turn.id} text={turn.userPrompt} />
      ) : null}
      <div className="assistant-lane">
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
        {turn.todos.length ? (
          <TodoPanel todos={turn.todos} turnID={turn.id} isLive={turn.isLive} />
        ) : null}
        {footer ? (
          <footer className="turn-footer" data-selection-id={`turn:${turn.id}:footer`}>
            <span>{footer.totalTokens} tokens</span>
            {footer.usageUnits ? <span>{footer.usageUnits} units</span> : null}
            <span>{footer.elapsed}</span>
            {footer.invocationCount ? <span>{footer.invocationCount}x</span> : null}
            {footer.contextTokens ? <span>ctx {footer.contextTokens}</span> : null}
          </footer>
        ) : null}
        {!turn.isLive && (turn.copyActionID || turn.assetsActionID) ? (
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
    const stopViewportController = viewportController.start(
      setIsPinned,
      (snapshot) => {
        if (!currentConversationID) return;
        postToNative({
          type: "viewport",
          protocolVersion,
          revision: currentRevision,
          conversationID: currentConversationID,
          pinned: snapshot.pinned,
          interacting: viewportController.diagnostics().interacting,
          anchorID: snapshot.anchor?.id,
          anchorTop: snapshot.anchor?.top,
        });
      },
    );
    window.AgentKitWorkbench = {
      setSuspended(suspended: boolean) {
        if (workbenchSuspended === suspended) return;
        workbenchSuspended = suspended;
        if (suspended) {
          if (document.activeElement instanceof HTMLElement) {
            suspendedFocusID = document.activeElement.dataset.focusId;
            document.activeElement.blur();
          }
        } else if (suspendedFocusID && !hasActiveTextSelection()) {
          document.querySelector<HTMLElement>(
            `[data-focus-id="${CSS.escape(suspendedFocusID)}"]`,
          )?.focus({ preventScroll: true });
          suspendedFocusID = undefined;
        }
        window.dispatchEvent(new Event(workbenchSuspensionEvent));
      },
      viewportDiagnostics() {
        return viewportController.diagnostics();
      },
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

          const capturedViewport = viewportController.capture();
          const replacedRoots = replacedDOMRoots(update);
          const recoveredViewport = isReset && update.recoveryViewport
            ? {
                pinned: update.recoveryViewport.pinned,
                anchor: update.recoveryViewport.anchorID
                  ? {
                      id: update.recoveryViewport.anchorID,
                      top: update.recoveryViewport.anchorTop ?? 0,
                    }
                  : null,
                interactionEpoch: capturedViewport.interactionEpoch,
              }
            : null;
          pendingRestoration.current = {
            revision: update.revision,
            selection: isReset ? null : captureSelection(),
            horizontalOffsets: isReset
              ? new Map()
              : captureHorizontalOffsets(replacedRoots),
            expandedDisclosures: isReset
              ? new Set()
              : captureExpandedDisclosures(replacedRoots),
            focusID: isReset ? null : captureFocusedElement(),
            viewport: isReset
              ? recoveredViewport ?? {
                  pinned: true,
                  anchor: null,
                  interactionEpoch: capturedViewport.interactionEpoch,
                }
              : capturedViewport,
            forcePinToBottom: isReset
              ? recoveredViewport === null
              : Boolean(update.patch?.forcePinToBottom),
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
      revision: conversation.revision,
      selection: null,
      horizontalOffsets: new Map<string, number>(),
      expandedDisclosures: new Set<string>(),
      focusID: null,
      viewport: {
        pinned: true,
        anchor: null,
        interactionEpoch: viewportController.capture().interactionEpoch,
      },
      forcePinToBottom: true,
    };
    const revealTask = window.setTimeout(() => {
      // A newer update may arrive before this post-layout task runs. Never let
      // an older task restore stale pin state or clear the newer snapshot.
      if (conversation.revision !== currentRevision
          || restoration.revision !== conversation.revision) return;
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
      if (pendingRestoration.current === restoration) {
        pendingRestoration.current = undefined;
      }
    }, 0);
    return () => window.clearTimeout(revealTask);
  }, [conversation]);

  if (!conversation) {
    return <main className="conversation-shell" aria-label="Conversation" aria-busy="true" />;
  }

  return (
    <main className="conversation-shell" aria-label="Conversation">
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
