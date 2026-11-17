import React, {
  memo,
  useCallback,
  useDeferredValue,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { createRoot } from "react-dom/client";
import ReactMarkdown, { defaultUrlTransform } from "react-markdown";
import remarkGfm from "remark-gfm";
import type {
  ConversationWebBlock,
  ConversationWebDocument,
  ConversationWebExtensionNode,
  ConversationWebImageView,
  ConversationWebOperation,
  ConversationWebPreview,
  ConversationWebUIEvidence,
  ConversationWebUILayout,
  ConversationWebUIPreview,
  ConversationWebTool,
  ConversationWebTurn,
  ConversationWebUpdate,
  InlineAction,
  NativeBridgeMessage,
} from "./types";
import { protocolVersion } from "./types";
import "./workbench.css";
import "./conversation-appearance.css";

let currentRevision = 0;
let currentConversationID: string | undefined;
let currentUpdateStartedAt = 0;
let workbenchSuspended = false;
let suspendedFocusID: string | undefined;
const workbenchSuspensionEvent = "agentkit-workbench-suspension";

// -- User asset URL resolution ------------------------------------------------
// Assets arrive without signed URLs. The native side resolves them
// asynchronously and fires a `userAssetURLResolved` CustomEvent.
//
// We use three complementary mechanisms so that timing cannot break the
// pipeline: (1) the CustomEvent listener catches the native response and
// updates the DOM immediately, (2) a MutationObserver catches <img> elements
// that appear *after* the URL was already cached, and (3) the Turn component
// reads the cache on every render so a React update after resolution uses the
// real URL directly.

const userAssetPlaceholderSrc =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='104' height='76' viewBox='0 0 104 76'%3E%3Crect width='104' height='76' fill='%23f0f0f0'/%3E%3C/svg%3E";
const pendingAssetURLs = new Map<number, string>(); // "" = pending, url = resolved
interface PendingLocalAssetURL {
  conversationID: string;
  localAssetID: string;
  requestID: string;
  url?: string;
  expires: number;
}

const pendingLocalAssetURLs = new Map<string, PendingLocalAssetURL>();
let localAssetURLRevision = 0;
const localAssetURLSubscribers = new Set<() => void>();
const localAssetRequestTimeoutMilliseconds = 10_000;

function subscribeLocalAssetURLs(callback: () => void): () => void {
  localAssetURLSubscribers.add(callback);
  return () => localAssetURLSubscribers.delete(callback);
}

function localAssetURLSnapshot(): number {
  return localAssetURLRevision;
}

function notifyLocalAssetURLChange(): void {
  localAssetURLRevision += 1;
  for (const callback of localAssetURLSubscribers) callback();
}

function localAssetCacheKey(conversationID: string, localAssetID: string): string {
  return `${conversationID}\u0000${localAssetID}`;
}

function clearLocalAssetURLs(): void {
  if (pendingLocalAssetURLs.size === 0) return;
  pendingLocalAssetURLs.clear();
  notifyLocalAssetURLChange();
}

function resolveUserAssetURL(assetID: number): void {
  if (pendingAssetURLs.has(assetID)) return;
  pendingAssetURLs.set(assetID, ""); // mark pending
  window.webkit?.messageHandlers?.agentkitWorkbench?.postMessage({
    type: "resolveUserAssetURL",
    assetID,
    requestID: crypto.randomUUID(),
  });
}

function applyResolvedAssetURL(assetID: number, url: string): void {
  pendingAssetURLs.set(assetID, url);
  const img = document.querySelector<HTMLImageElement>(
    `img[data-asset-id="${assetID}"]`,
  );
  if (img) img.src = url;
}

function resolveLocalAssetURL(localAssetID: string, conversationID: string): void {
  const key = localAssetCacheKey(conversationID, localAssetID);
  const existing = pendingLocalAssetURLs.get(key);
  if (existing?.url) return;
  if (existing && existing.expires > Date.now()) return;
  const requestID = crypto.randomUUID();
  pendingLocalAssetURLs.set(key, {
    conversationID,
    localAssetID,
    requestID,
    expires: Date.now() + localAssetRequestTimeoutMilliseconds,
  });
  window.webkit?.messageHandlers?.agentkitWorkbench?.postMessage({
    type: "resolveLocalAssetURL",
    localAssetID,
    conversationID,
    requestID,
  });
  window.setTimeout(() => {
    const pending = pendingLocalAssetURLs.get(key);
    if (pending?.requestID === requestID && !pending.url) {
      pendingLocalAssetURLs.delete(key);
    }
  }, localAssetRequestTimeoutMilliseconds);
}

function applyResolvedLocalAssetURL(
  conversationID: string,
  localAssetID: string,
  requestID: string,
  url?: string,
): void {
  const key = localAssetCacheKey(conversationID, localAssetID);
  const pending = pendingLocalAssetURLs.get(key);
  if (
    !pending ||
    pending.requestID !== requestID ||
    conversationID !== currentConversationID
  ) return;
  if (!url) {
    pendingLocalAssetURLs.delete(key);
    notifyLocalAssetURLChange();
    return;
  }
  pendingLocalAssetURLs.set(key, { ...pending, url });
  notifyLocalAssetURLChange();
}

interface PendingImageViewAssetURL {
  conversationID: string;
  turnID: string;
  toolID: string;
  assetID: string;
  requestID: string;
  url?: string;
  expires: number;
}

const pendingImageViewAssetURLs = new Map<string, PendingImageViewAssetURL>();
let imageViewAssetURLRevision = 0;
const imageViewAssetURLSubscribers = new Set<() => void>();

function subscribeImageViewAssetURLs(callback: () => void): () => void {
  imageViewAssetURLSubscribers.add(callback);
  return () => imageViewAssetURLSubscribers.delete(callback);
}

function imageViewAssetURLSnapshot(): number {
  return imageViewAssetURLRevision;
}

function notifyImageViewAssetURLChange(): void {
  imageViewAssetURLRevision += 1;
  for (const callback of imageViewAssetURLSubscribers) callback();
}

function imageViewAssetCacheKey(
  conversationID: string,
  turnID: string,
  toolID: string,
  assetID: string,
): string {
  return [conversationID, turnID, toolID, assetID].join("\u0000");
}

function clearImageViewAssetURLs(): void {
  if (pendingImageViewAssetURLs.size === 0) return;
  pendingImageViewAssetURLs.clear();
  notifyImageViewAssetURLChange();
}

function resolveImageViewAssetURL(
  conversationID: string,
  turnID: string,
  toolID: string,
  assetID: string,
): void {
  const key = imageViewAssetCacheKey(conversationID, turnID, toolID, assetID);
  const existing = pendingImageViewAssetURLs.get(key);
  if (existing?.url) return;
  if (existing && existing.expires > Date.now()) return;
  const requestID = crypto.randomUUID();
  pendingImageViewAssetURLs.set(key, {
    conversationID,
    turnID,
    toolID,
    assetID,
    requestID,
    expires: Date.now() + localAssetRequestTimeoutMilliseconds,
  });
  window.webkit?.messageHandlers?.agentkitWorkbench?.postMessage({
    type: "resolveImageViewAssetURL",
    conversationID,
    turnID,
    toolID,
    assetID,
    requestID,
  });
  window.setTimeout(() => {
    const pending = pendingImageViewAssetURLs.get(key);
    if (pending?.requestID === requestID && !pending.url) {
      pendingImageViewAssetURLs.delete(key);
      notifyImageViewAssetURLChange();
    }
  }, localAssetRequestTimeoutMilliseconds);
}

function applyResolvedImageViewAssetURL(
  conversationID: string,
  turnID: string,
  toolID: string,
  assetID: string,
  requestID: string,
  url?: string,
): void {
  const key = imageViewAssetCacheKey(conversationID, turnID, toolID, assetID);
  const pending = pendingImageViewAssetURLs.get(key);
  if (
    !pending ||
    pending.requestID !== requestID ||
    conversationID !== currentConversationID
  ) return;
  if (!url) {
    pendingImageViewAssetURLs.delete(key);
    notifyImageViewAssetURLChange();
    return;
  }
  pendingImageViewAssetURLs.set(key, { ...pending, url });
  notifyImageViewAssetURLChange();
}

function useImageViewAssetURL(
  conversationID: string,
  turnID: string,
  toolID: string,
  assetID: string,
): string | undefined {
  useSyncExternalStore(
    subscribeImageViewAssetURLs,
    imageViewAssetURLSnapshot,
    imageViewAssetURLSnapshot,
  );
  const key = imageViewAssetCacheKey(conversationID, turnID, toolID, assetID);
  const url = pendingImageViewAssetURLs.get(key)?.url;
  useEffect(() => {
    if (!url) resolveImageViewAssetURL(conversationID, turnID, toolID, assetID);
  }, [assetID, conversationID, toolID, turnID, url]);
  return url;
}

const imageViewPlaceholderSrc =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='240' height='160' viewBox='0 0 240 160'%3E%3Crect width='240' height='160' fill='%23ececec'/%3E%3Cpath d='M72 108l34-36 25 25 16-16 25 27z' fill='%23a0a0a0'/%3E%3Ccircle cx='168' cy='61' r='11' fill='%23a0a0a0'/%3E%3C/svg%3E";

function localAssetIcon(mimeType: string, kind: string): string {
  if (mimeType === "application/pdf") return "PDF";
  if (mimeType.startsWith("image/")) return "IMG";
  if (kind === "document" || mimeType.startsWith("text/")) return "DOC";
  return "FILE";
}

function postToNative(message: NativeBridgeMessage): void {
  window.webkit?.messageHandlers?.agentkitWorkbench?.postMessage(message);
}

/**
 * Ask the host to open the shared native image previewer for one thumbnail.
 * Only identities travel across the bridge; the host rebuilds the turn's
 * mixed image list (remote first, then local) and resolves display URLs
 * natively, so the pager order matches the strip layout.
 */
function requestAssetPreview(
  conversationID: string,
  turnID: string,
  assetKind: "user" | "local",
  assetID: string,
): void {
  postToNative({
    type: "previewTurnAssets",
    conversationID,
    turnID,
    assetKind,
    assetID,
  });
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
  private readingActivity = false;
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
  private lastReachedTopAt = 0;
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
      if (event.deltaY > 0 && !(event.target as HTMLElement)?.closest?.(".tool-output-frame")) this.readingActivity = false;
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
      this.setPinned(!this.readingActivity && this.isAtBottom());
      if (!this.pinned && window.scrollY < 160 && currentConversationID
          && performance.now() - this.lastReachedTopAt > 600) {
        this.lastReachedTopAt = performance.now();
        postToNative({ type: "reachedTop", conversationID: currentConversationID });
      }
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
      this.readingActivity = false;
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

  beginReadingActivity(): void {
    this.readingActivity = true;
    this.interactionEpoch += 1;
    this.lastAnchor = null;
    this.setPinned(false);
    this.cancelScheduledFollow();
  }

  preserveReadingAnchor(element: HTMLElement, top: number): void {
    const delta = element.getBoundingClientRect().top - top;
    if (Math.abs(delta) > 0.5) this.performProgrammaticScroll(() => window.scrollBy(0, delta));
    const target = element.closest<HTMLElement>("[data-anchor-id]");
    if (target?.dataset.anchorId) this.lastAnchor = { id: target.dataset.anchorId, top: target.getBoundingClientRect().top };
    this.scheduleViewportReport();
  }

  jumpToLatest(): void {
    this.readingActivity = false;
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
      this.setPinned(!this.readingActivity && this.isAtBottom());
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
      case "prependTurns":
        if (operation.turn) next = { ...next, turns: [operation.turn, ...next.turns] };
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
/// timer. Each snapshot advances synchronously, without depending on either
/// clock. Playback and parsing both pause during scrolling or text selection.
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

  const lastAdvanceAt = useRef(performance.now());
  const advancePlayback = useRef<(now: number, ensureProgress: boolean) => void>(() => {});
  advancePlayback.current = (now, ensureProgress) => {
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
        && (ensureProgress || now - lastAdvanceAt.current >= streamingFrameMilliseconds)
        && current.length < target.length) {
      const backlog = target.length - current.length;
      // Small backlogs read like typing; large batches catch up quickly
      // without making the UI wait seconds behind the model.
      const step = Math.min(backlog, Math.max(2, Math.ceil(backlog * 0.22)));
      current = target.slice(0, current.length + step);
      visibleText.current = current;
      lastAdvanceAt.current = now;
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
  };

  // A received snapshot must paint content even if an inactive WKWebView is
  // delaying both animation frames and playback timers. Advance in the data
  // commit itself; the local clock only smooths the remaining backlog.
  useLayoutEffect(() => {
    if (!workbenchSuspended) advancePlayback.current(performance.now(), true);
  }, [block.text]);

  useEffect(() => {
    let frame: number | undefined;
    let fallback: number | undefined;

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
      advancePlayback.current(now, false);
      scheduleTick();
    };
    const handleSuspensionChange = () => {
      if (workbenchSuspended) {
        cancelScheduledTick();
      } else if (frame === undefined && fallback === undefined) {
        advancePlayback.current(performance.now(), true);
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

/**
 * Disclosure state for activity rows (thinking / tool / tool-group).
 *
 * Live activity now starts collapsed so the conversation stays compact; the
 * group header carries the current action while streaming. User toggles are
 * allowed at any time and stored by stable disclosure ID, so content growth or
 * turn completion never overwrites an explicit choice.
 *
 * The returned `open` value is fully controlled: the summary click handler
 * preventDefaults the native toggle so the browser never fights React.
 */
// Scope disclosure preferences to the conversation and turn, independently of
// streaming status and whether the parent group is currently visible.
/** Stable keyed subscriptions keep a click local to its disclosure. The store
 * belongs to the turn, so unmounting a collapsed group preserves child choices. */
class DisclosureStore {
  private values = new Map<string, boolean>();
  private listeners = new Map<string, Set<() => void>>();
  get(key: string, fallback: boolean): boolean { return this.values.get(key) ?? fallback; }
  subscribe(key: string, listener: () => void): () => void {
    const listeners = this.listeners.get(key) ?? new Set<() => void>();
    listeners.add(listener);
    this.listeners.set(key, listeners);
    return () => { listeners.delete(listener); if (!listeners.size) this.listeners.delete(key); };
  }
  toggle(key: string, fallback: boolean): void {
    this.values.set(key, !this.get(key, fallback));
    this.listeners.get(key)?.forEach(listener => listener());
  }
}
const TurnDisclosureContext = React.createContext<{ scope: string; store: DisclosureStore } | null>(null);

function useActivityDisclosure(disclosureID: string, defaultOpen = false) {
  const context = React.useContext(TurnDisclosureContext);
  const [localStore] = useState(() => new DisclosureStore());
  const store = context?.store ?? localStore;
  const key = `${context?.scope}:${disclosureID}`;
  const subscribe = useCallback((listener: () => void) => store.subscribe(key, listener), [store, key]);
  const snapshot = useCallback(() => store.get(key, defaultOpen), [store, key, defaultOpen]);
  const open = useSyncExternalStore(subscribe, snapshot, snapshot);
  const anchor = useRef<{ element: HTMLElement; top: number } | null>(null);
  const gesture = useRef<{ x: number; y: number } | null>(null);
  useLayoutEffect(() => {
    const saved = anchor.current;
    anchor.current = null;
    if (saved?.element.isConnected) viewportController.preserveReadingAnchor(saved.element, saved.top);
  }, [open]);
  const onPointerDown = (event: React.PointerEvent<HTMLElement>) => {
    gesture.current = { x: event.clientX, y: event.clientY };
  };
  const onSummaryClick = (event: React.MouseEvent<HTMLElement>) => {
    const selection = window.getSelection();
    const down = gesture.current;
    gesture.current = null;
    // Preserve drag-to-select, but an old selection elsewhere must never make
    // a mouse/keyboard activation silently stop working.
    if (event.detail > 0 && down && selection && !selection.isCollapsed
        && Math.hypot(event.clientX - down.x, event.clientY - down.y) > 4) {
      event.preventDefault();
      return;
    }
    event.preventDefault();
    anchor.current = { element: event.currentTarget, top: event.currentTarget.getBoundingClientRect().top };
    viewportController.beginReadingActivity();
    store.toggle(key, defaultOpen);
  };
  return { open, onSummaryClick, onPointerDown };
}

/**
 * Follows the newest content inside a bounded scroll container while `active`.
 * The container is pinned to the bottom on activation and whenever its content
 * grows (ResizeObserver on the first element child), so a streaming stream
 * never inflates the surrounding layout: older lines scroll out of the fixed
 * viewport. Scrolling away from the bottom (beyond `followThreshold`) pauses
 * the follow so new content never yanks the reading position, and scrolling
 * back to the bottom resumes it.
 *
 * The container is passed as a value (from a callback ref backed by state),
 * not a `useRef`, so the effect re-runs if the frame mounts later — a running
 * tool's output frame can appear only once its first output batch arrives.
 */
function useTailFollow(
  container: HTMLDivElement | null,
  active: boolean,
): void {
  useLayoutEffect(() => {
    if (!active || !container) return;
    const content = container.firstElementChild as HTMLElement | null;
    if (!content) return;

    const followThreshold = 8;
    let followTail = false;
    let lastScrollTop = container.scrollTop;
    const pinToBottom = () => {
      if (!followTail || window.getSelection()?.isCollapsed === false) return;
      container.scrollTop = container.scrollHeight;
      lastScrollTop = container.scrollTop;
    };
    const handleScroll = () => {
      const top = container.scrollTop;
      const distanceFromBottom = container.scrollHeight - top - container.clientHeight;
      if (distanceFromBottom <= followThreshold) followTail = true;
      // Appending output can enlarge the distance before ResizeObserver runs.
      // Only an actual move upward pauses follow, not that layout-only gap.
      else if (top < lastScrollTop - 1) followTail = false;
      lastScrollTop = top;
    };

    pinToBottom();
    container.addEventListener("scroll", handleScroll, { passive: true });
    const observer = new ResizeObserver(pinToBottom);
    const observeChildren = () => {
      for (const child of container.children) observer.observe(child);
      pinToBottom();
    };
    observeChildren();
    const mutations = new MutationObserver(observeChildren);
    mutations.observe(container, { childList: true, subtree: true, characterData: true });
    return () => {
      container.removeEventListener("scroll", handleScroll);
      observer.disconnect();
      mutations.disconnect();
    };
  }, [active, container]);
}

/** Decorative bars never announce each animation frame or imply progress. */
function ActivitySkeleton({ label, className = "" }: { label?: string; className?: string }): React.JSX.Element {
  return <div className={`activity-skeleton ${className}`} role="status" aria-label={label}>
    <span aria-hidden="true" /><span aria-hidden="true" />
  </div>;
}

function ToolResultCard({ tool, outputRef }: {
  tool: ConversationWebTool;
  outputRef: (element: HTMLDivElement | null) => void;
}): React.JSX.Element | null {
  const input = tool.input ?? tool.command ?? tool.detail;
  const failed = tool.status === "failed";
  return (
    <div className="tool-result-card" data-kind={tool.resultKind}>
      {input ? <div className="tool-input-panel">
        <div className="tool-input-header">
          {tool.command ? <span className="tool-command-prompt" aria-hidden="true">$</span> : null}
          <div className="tool-input-scroll" data-scroll-id={`tool-command:${tool.id}`} role="region" aria-label={tool.command ? tool.labels?.command : tool.labels?.input} tabIndex={0}>
            <pre className="tool-command-text"><code>{linkifiedActionText(input, tool.commandActions ?? [])}</code></pre>
            {tool.inputContext ? <div className="tool-input-context">{tool.inputContext}</div> : null}
          </div>
          {tool.copyInputActionID ? <ActionButton actionID={tool.copyInputActionID} focusID={`tool-input-copy:${tool.id}`}>
            {tool.command ? tool.labels?.copyCommand : tool.labels?.copyInput}
          </ActionButton> : null}
        </div>
        {tool.inputIsPreview ? <span className="tool-input-preview-label">{tool.labels?.preview}</span> : null}
        {tool.inputIsRedacted ? <span className="tool-input-preview-label">{tool.labels?.sensitiveValuesHidden}</span> : null}
      </div> : null}
      {tool.output ? <div ref={outputRef} className="overflow-frame tool-output-frame" data-scroll-id={`tool-output:${tool.id}`} role="region" aria-label={tool.labels?.output} tabIndex={0}>
        <pre><code>{linkifiedActionText(tool.output, tool.outputActions)}</code></pre>
      </div> : tool.status === "running" && !tool.dagNodes && !tool.hasResult ? <ActivitySkeleton className="tool-output-skeleton" label={tool.labels?.output} />
        : tool.status !== "running" && !tool.dagNodes && !tool.hasResult ? <div className="tool-empty-output">
        {failed ? tool.labels?.failedNoOutput : tool.labels?.noOutput}
      </div> : null}
      <div className="tool-result-footer">
        <span className="tool-result-meta">
          {failed ? <span className="tool-result-outcome" data-tone="failed">{tool.outcomeText}</span> : null}
          {tool.elapsed ? <span>{tool.elapsed}</span> : null}
        </span>
        <span className="tool-result-actions">
          {tool.copyOutputActionID ? <ActionButton actionID={tool.copyOutputActionID} focusID={`tool-output-copy:${tool.id}`}>{tool.labels?.copyOutput}</ActionButton> : null}
          {tool.output && tool.fullOutputActionID ? <ActionButton actionID={tool.fullOutputActionID} focusID={`tool-output-full:${tool.id}`}>{tool.labels?.viewFullOutput}</ActionButton> : null}
        </span>
      </div>
    </div>
  );
}

// Draw known tool glyphs at a consistent optical size instead of relying on
// platform font metrics (the search character is especially small on macOS).
function ToolActionIcon({ glyph }: { glyph: string }): React.JSX.Element {
  const paths: Record<string, React.ReactNode> = {
    "⌕": <><circle cx="10.5" cy="10.5" r="6.5" /><path d="m15.5 15.5 5 5" /></>,
    "□": <><path d="M14 3H5v18h14V8zM14 3v5h5" /><path d="M8 12h8M8 16h6" /></>,
    "≡": <><path d="M3 6h7l2 2h9v12H3z" /></>,
    "+": <><path d="M12 4v16M4 12h16" /></>,
    "±": <><path d="m4 16-1 5 5-1L20 8l-4-4zM13 7l4 4" /></>,
    "$": <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="m7 9 3 3-3 3M13 15h4" /></>,
    "◇": <><path d="m12 3 9 9-9 9-9-9z" /></>,
  };
  return <span className="tool-action-icon" aria-hidden="true">
    <span className="visually-hidden">{glyph}</span>
    {paths[glyph] ? <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">{paths[glyph]}</svg> : glyph}
  </span>;
}

function ImageViewPreview({
  conversationID,
  turnID,
  toolID,
  image,
  variant,
}: {
  conversationID: string;
  turnID: string;
  toolID: string;
  image: {
    assetID: string;
    role: string;
    displayName: string;
    sourceAssetID?: string;
  };
  variant: "thumbnail" | "source" | "crop";
}): React.JSX.Element {
  const url = useImageViewAssetURL(conversationID, turnID, toolID, image.assetID);
  return (
    <span
      className={`image-view-preview image-view-${variant}`}
      data-image-view-role={image.role}
      data-image-view-asset-id={image.assetID}
      data-parent-asset-id={image.sourceAssetID ?? undefined}
    >
      <img
        src={url ?? imageViewPlaceholderSrc}
        alt={image.displayName}
        loading={variant === "thumbnail" ? "lazy" : "eager"}
        draggable={false}
        onLoad={(event) => {
          if (url) event.currentTarget.dataset.loaded = "true";
        }}
      />
    </span>
  );
}

function ImageViewActivity({
  imageView,
  conversationID,
  turnID,
  toolID,
}: {
  imageView: ConversationWebImageView;
  conversationID: string;
  turnID: string;
  toolID: string;
}): React.JSX.Element {
  const source = imageView.assets.find((asset) => asset.role === "source");
  const crops = imageView.assets.filter((asset) => asset.role === "crop");
  if (!source) return <></>;
  return (
    <section
      className="image-view-activity"
      data-image-view-source-asset-id={imageView.sourceAssetID}
      data-image-view-asset-order={imageView.assets.map((asset) => asset.assetID).join(",")}
    >
      <figure
        className="image-view-source"
        data-image-view-node="source"
        aria-label={source.displayName}
      >
        <ImageViewPreview
          conversationID={conversationID}
          turnID={turnID}
          toolID={toolID}
          image={source}
          variant="source"
        />
      </figure>
      {crops.map((crop) => (
        <section
          className="image-view-crop"
          data-image-view-node="crop"
          data-image-view-crop-asset-id={crop.assetID}
          data-parent-asset-id={crop.sourceAssetID}
          aria-label={`Crop of ${source.displayName}`}
          key={crop.assetID}
        >
          <ImageViewPreview
            conversationID={conversationID}
            turnID={turnID}
            toolID={toolID}
            image={crop}
            variant="crop"
          />
        </section>
      ))}
    </section>
  );
}

function evidenceLabel(value: "observed" | "inferred" | "uncertain"): string {
  switch (value) {
    case "observed": return "Observed";
    case "inferred": return "Inferred";
    case "uncertain": return "Uncertain";
  }
}

function EvidenceBadge({
  evidence,
}: {
  evidence: "observed" | "inferred" | "uncertain";
}): React.JSX.Element {
  return (
    <span className="ui-evidence-badge" data-evidence={evidence}>
      {evidenceLabel(evidence)}
    </span>
  );
}

function UIEvidenceMetric({
  value,
  label,
}: {
  value: number;
  label: string;
}): React.JSX.Element {
  return (
    <span className="ui-evidence-metric">
      <strong>{value}</strong>
      <span>{label}</span>
    </span>
  );
}

function UIEvidenceActivity({
  evidence,
  conversationID,
  turnID,
  toolID,
}: {
  evidence: ConversationWebUIEvidence;
  conversationID: string;
  turnID: string;
  toolID: string;
}): React.JSX.Element {
  const source = evidence.assets.find((asset) => asset.role === "source");
  const crops = evidence.assets.filter((asset) => asset.role === "crop");
  if (!source) return <></>;
  const warnings = evidence.warnings;
  return (
    <section
      className="ui-evidence-activity"
      data-ui-evidence-source-asset-id={evidence.sourceAssetID}
      data-ui-evidence-source-tree={evidence.sourceTreeKind}
    >
      <figure className="ui-evidence-source" data-ui-evidence-node="source">
        <ImageViewPreview
          conversationID={conversationID}
          turnID={turnID}
          toolID={toolID}
          image={source}
          variant="source"
        />
        <figcaption>
          <span>{source.displayName}</span>
          {source.viewActionID ? (
            <ActionButton
              actionID={source.viewActionID}
              focusID={`ui-evidence:${toolID}:source`}
              tooltip={source.displayName}
            >
              View source
            </ActionButton>
          ) : null}
        </figcaption>
      </figure>

      <div className="ui-evidence-summary" aria-label="UI evidence summary">
        <UIEvidenceMetric value={evidence.summary.textElements} label="text" />
        <UIEvidenceMetric value={evidence.summary.containers} label="containers" />
        <UIEvidenceMetric value={evidence.summary.repeatedGroups} label="repeated groups" />
        <UIEvidenceMetric value={evidence.summary.crops} label="crops" />
        <UIEvidenceMetric value={evidence.summary.uncertainties} label="uncertainties" />
        <UIEvidenceMetric value={evidence.summary.warnings} label="warnings" />
      </div>

      <div className="ui-evidence-levels" aria-label="Evidence levels">
        <span><EvidenceBadge evidence="observed" /> {evidence.summary.observed}</span>
        <span><EvidenceBadge evidence="inferred" /> {evidence.summary.inferred}</span>
        <span><EvidenceBadge evidence="uncertain" /> {evidence.summary.uncertain}</span>
      </div>

      {evidence.sourceTreeNote ? (
        <p className="ui-evidence-source-tree-note" data-ui-evidence-source-tree-note="none">
          {evidence.sourceTreeNote}
        </p>
      ) : null}

      {evidence.ocrPreview.length ? (
        <section className="ui-evidence-section" aria-label="Compact OCR preview">
          <h4>OCR preview</h4>
          <ol className="ui-evidence-ocr-list">
            {evidence.ocrPreview.map((item) => (
              <li key={item.id} data-evidence={item.evidence}>
                <EvidenceBadge evidence={item.evidence} />
                <span className="ui-evidence-ocr-text">{item.text}</span>
                <span className="ui-evidence-geometry">
                  bbox {item.bbox.x.toFixed(3)}, {item.bbox.y.toFixed(3)}, {item.bbox.width.toFixed(3)}, {item.bbox.height.toFixed(3)}
                  {" · "}
                  confidence {item.confidence.toFixed(3)}
                </span>
              </li>
            ))}
          </ol>
        </section>
      ) : null}

      {evidence.repeatedGroups.length ? (
        <section className="ui-evidence-section" aria-label="Repeated groups">
          <h4>Repeated groups</h4>
          <ul className="ui-evidence-notes">
            {evidence.repeatedGroups.map((group) => (
              <li key={group.id}>
                <span className="ui-evidence-mono">{group.id}</span>
                {" · "}
                {group.axis}
                {" · "}
                {group.memberIDs.length} members
                {" · "}
                <EvidenceBadge evidence={group.evidence} />
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {crops.length ? (
        <section className="ui-evidence-section" aria-label="Evidence crops">
          <h4>Crops</h4>
          <div className="ui-evidence-crops">
            {crops.map((crop) => (
              <figure
                className="ui-evidence-crop"
                data-ui-evidence-node="crop"
                data-ui-evidence-crop-asset-id={crop.assetID}
                data-parent-asset-id={crop.sourceAssetID}
                key={crop.assetID}
              >
                <ImageViewPreview
                  conversationID={conversationID}
                  turnID={turnID}
                  toolID={toolID}
                  image={crop}
                  variant="crop"
                />
                <figcaption>
                  <span>{crop.purpose ?? "crop"}</span>
                  {crop.viewActionID ? (
                    <ActionButton
                      actionID={crop.viewActionID}
                      focusID={`ui-evidence:${toolID}:crop:${crop.assetID}`}
                      tooltip={crop.displayName}
                    >
                      View crop
                    </ActionButton>
                  ) : null}
                </figcaption>
              </figure>
            ))}
          </div>
        </section>
      ) : null}

      {evidence.uncertainties.length ? (
        <section className="ui-evidence-section" aria-label="Uncertainties">
          <h4>Uncertainties</h4>
          <ul className="ui-evidence-notes">
            {evidence.uncertainties.map((uncertainty) => (
              <li key={uncertainty.id}>
                {uncertainty.text}
                {uncertainty.reason ? <span className="ui-evidence-mono"> · {uncertainty.reason}</span> : null}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {warnings.length ? (
        <section className="ui-evidence-section" aria-label="Warnings">
          <h4>Warnings</h4>
          <ul className="ui-evidence-notes">
            {warnings.map((warning, index) => <li key={`${index}:${warning}`}>{warning}</li>)}
          </ul>
        </section>
      ) : null}

      <details className="ui-evidence-limits">
        <summary>Limits and producer</summary>
        <ul className="ui-evidence-notes">
          {evidence.limits.map((limit) => <li key={limit}>{limit}</li>)}
          <li>Producer: {evidence.producer}</li>
        </ul>
      </details>

      {evidence.rawActionID ? (
        <ActionButton
          actionID={evidence.rawActionID}
          focusID={`ui-evidence:${toolID}:raw`}
          tooltip="Open raw ui_evidence.v1 in Inspector"
        >
          Inspect raw evidence
        </ActionButton>
      ) : null}
    </section>
  );
}

function UILayoutActivity({
  layout,
  conversationID,
  turnID,
  toolID,
}: {
  layout: ConversationWebUILayout;
  conversationID: string;
  turnID: string;
  toolID: string;
}): React.JSX.Element {
  return (
    <section
      className="ui-layout-activity"
      data-ui-layout-artifact-id={layout.artifactID}
      data-ui-layout-revision={layout.revision}
      data-ui-layout-created={layout.created ? "true" : "false"}
      data-ui-layout-overlay-asset-id={layout.overlay.assetID}
      data-ui-layout-json-asset-id={layout.layoutJSON.assetID}
    >
      <figure className="ui-layout-overlay" data-ui-layout-node="overlay">
        <ImageViewPreview
          conversationID={conversationID}
          turnID={turnID}
          toolID={toolID}
          image={layout.overlay}
          variant="source"
        />
        <figcaption>
          <span>{layout.overlay.displayName}</span>
          {layout.overlay.viewActionID ? (
            <ActionButton
              actionID={layout.overlay.viewActionID}
              focusID={`ui-layout:${toolID}:overlay`}
              tooltip={layout.overlay.displayName}
            >
              Open overlay
            </ActionButton>
          ) : null}
        </figcaption>
      </figure>

      <div className="ui-layout-summary" aria-label="UI layout summary">
        <UIEvidenceMetric value={layout.revision} label="revision" />
        <UIEvidenceMetric value={layout.nodeCount} label="nodes" />
        <UIEvidenceMetric value={layout.assumptionCount} label="assumptions" />
        <span
          className="ui-layout-state"
          data-created={layout.created ? "true" : "false"}
        >
          {layout.created ? "Created" : "Reused"}
        </span>
      </div>

      <dl className="ui-layout-facts">
        <div>
          <dt>Canvas</dt>
          <dd>{layout.canvasWidth} × {layout.canvasHeight}</dd>
        </div>
        <div>
          <dt>Targets</dt>
          <dd className="ui-layout-targets">
            {layout.targets.map((target) => (
              <span className="ui-layout-target" key={target}>{target}</span>
            ))}
          </dd>
        </div>
        <div>
          <dt>Evidence SHA-256</dt>
          <dd className="ui-evidence-mono">{layout.evidenceSHA256 ?? "none"}</dd>
        </div>
        <div>
          <dt>Revision SHA-256</dt>
          <dd className="ui-evidence-mono">{layout.revisionSHA256}</dd>
        </div>
        <div>
          <dt>Source SHA-256</dt>
          <dd className="ui-evidence-mono">{layout.sourceAssetSHA256}</dd>
        </div>
      </dl>

      <div className="ui-layout-actions">
        {layout.rawActionID ? (
          <ActionButton
            actionID={layout.rawActionID}
            focusID={`ui-layout:${toolID}:metadata`}
            tooltip="Open ui_layout_result.v1 metadata in Inspector"
          >
            Inspect metadata
          </ActionButton>
        ) : null}
        {layout.layoutJSON.viewActionID ? (
          <ActionButton
            actionID={layout.layoutJSON.viewActionID}
            focusID={`ui-layout:${toolID}:json`}
            tooltip={layout.layoutJSON.displayName}
          >
            Open layout JSON
          </ActionButton>
        ) : null}
      </div>
    </section>
  );
}

function UIPreviewActivity({
  preview,
  conversationID,
  turnID,
  toolID,
}: {
  preview: ConversationWebUIPreview;
  conversationID: string;
  turnID: string;
  toolID: string;
}): React.JSX.Element {
  const [viewer, setViewer] = useState<{
    status: "idle" | "loading" | "ready" | "failed";
    url?: string;
    errorCode?: string;
  }>({ status: "idle" });
  const viewerRequestID = useRef<string | undefined>(undefined);
  const wantsViewer = preview.presentationState === "interactiveReady";
  const degraded = preview.presentationState !== "interactiveReady";
  const lineage = preview.lineage;
  const viewerStyle = {
    minHeight: preview.minHeight ?? 320,
    aspectRatio: preview.preferredAspectRatio
      ? String(preview.preferredAspectRatio)
      : "16 / 9",
  };

  useEffect(() => {
    const handleResolved = (event: Event) => {
      const detail = (event as CustomEvent<{
        requestID?: string;
        artifactID?: string;
        revision?: number;
        url?: string;
        errorCode?: string;
      }>).detail;
      if (
        detail?.artifactID !== preview.artifactID
        || detail.revision !== preview.revision
        || detail.requestID !== viewerRequestID.current
      ) return;
      setViewer(detail.url
        ? { status: "ready", url: detail.url }
        : { status: "failed", errorCode: detail.errorCode });
    };
    window.addEventListener("previewViewerURLResolved", handleResolved);
    return () => window.removeEventListener("previewViewerURLResolved", handleResolved);
  }, [preview.artifactID, preview.revision]);

  useEffect(() => {
    if (!wantsViewer || viewer.status !== "idle") return;
    const requestID = crypto.randomUUID();
    viewerRequestID.current = requestID;
    setViewer({ status: "loading" });
    postToNative({
      type: "resolvePreviewViewerURL",
      conversationID,
      artifactID: preview.artifactID,
      revision: preview.revision,
      requestID,
    });
  }, [
    wantsViewer,
    viewer.status,
    conversationID,
    preview.artifactID,
    preview.revision,
  ]);

  return (
    <section
      className="ui-preview-activity"
      data-ui-preview-mode={preview.mode}
      data-ui-preview-artifact-id={preview.artifactID}
      data-ui-preview-revision={preview.revision}
      data-ui-preview-kind={preview.kind}
      data-ui-preview-fallback-asset-id={preview.fallback.assetID}
      data-ui-preview-presentation-state={preview.presentationState}
      aria-label={`${preview.modeLabel}: ${preview.title}`}
    >
      <header className="ui-preview-header">
        <span className="ui-preview-mode" data-mode={preview.mode}>
          {preview.modeLabel}
        </span>
        <span className="ui-preview-title">{preview.title}</span>
        <span className="ui-preview-status" data-tone={preview.tone}>
          {preview.statusLabel}
        </span>
      </header>

      {preview.mode === "explore" ? (
        <p className="ui-preview-mode-note">
          Explore Preview — standalone, with no layout lineage.
        </p>
      ) : null}

      {wantsViewer ? (
        <div
          className="ui-preview-viewer-shell"
          data-ui-preview-node="viewer"
          style={viewerStyle}
        >
          {viewer.status === "ready" && viewer.url ? (
            <iframe
              className="ui-preview-frame"
              data-ui-preview-frame={preview.artifactID}
              data-ui-preview-revision={preview.revision}
              src={viewer.url}
              title={preview.title}
              sandbox="allow-scripts"
              referrerPolicy="no-referrer"
            />
          ) : (
            <div className="ui-preview-viewer-placeholder">
              {viewer.status === "failed"
                ? `Preview render failed${viewer.errorCode ? ` (${viewer.errorCode})` : ""}. Showing the fallback below.`
                : "Preparing interactive preview…"}
            </div>
          )}
        </div>
      ) : null}

      {degraded && preview.fallbackText ? (
        <p className="ui-preview-degraded">{preview.fallbackText}</p>
      ) : null}

      <figure className="ui-preview-fallback" data-ui-preview-node="fallback">
        <ImageViewPreview
          conversationID={conversationID}
          turnID={turnID}
          toolID={toolID}
          image={{
            assetID: preview.fallback.assetID,
            role: "fallback",
            displayName: preview.fallback.displayName,
          }}
          variant="source"
        />
        <figcaption>
          <span>{preview.fallback.displayName}</span>
          {preview.fallback.viewActionID ? (
            <ActionButton
              actionID={preview.fallback.viewActionID}
              focusID={`ui-preview:${toolID}:fallback`}
              tooltip={preview.fallback.displayName}
            >
              Open fallback PNG
            </ActionButton>
          ) : null}
        </figcaption>
      </figure>

      <dl className="ui-preview-facts" data-ui-preview-node="facts">
        <div>
          <dt>Artifact</dt>
          <dd className="ui-preview-mono">
            {preview.artifactID} · r{preview.revision}
          </dd>
        </div>
        <div>
          <dt>Kind</dt>
          <dd>{preview.kind}</dd>
        </div>
        {lineage ? (
          <>
            <div>
              <dt>Layout revision</dt>
              <dd className="ui-preview-mono">
                {lineage.layoutArtifactID} · r{lineage.layoutRevision}
              </dd>
            </div>
            <div>
              <dt>Layout SHA-256</dt>
              <dd className="ui-preview-mono">{lineage.layoutRevisionSHA256}</dd>
            </div>
            <div>
              <dt>Source asset</dt>
              <dd className="ui-preview-mono">{lineage.sourceAssetID}</dd>
            </div>
            <div>
              <dt>Source SHA-256</dt>
              <dd className="ui-preview-mono">{lineage.sourceAssetSHA256}</dd>
            </div>
            <div>
              <dt>Evidence SHA-256</dt>
              <dd className="ui-preview-mono">{lineage.evidenceSHA256 ?? "none"}</dd>
            </div>
            <div>
              <dt>Target</dt>
              <dd>{lineage.target}</dd>
            </div>
            <div>
              <dt>State</dt>
              <dd>{lineage.state}</dd>
            </div>
            <div>
              <dt>Approval</dt>
              <dd>
                {lineage.approvalState}
                {lineage.approvalEvidenceRef
                  ? ` · ${lineage.approvalEvidenceRef}`
                  : ""}
              </dd>
            </div>
            <div>
              <dt>Target matrix</dt>
              <dd className="ui-preview-targets">
                <span className="ui-preview-matrix-id">
                  {lineage.targetMatrixID}
                </span>
                {lineage.targetMatrixTargets.map((target) => (
                  <span
                    className="ui-preview-target"
                    data-selected={target === lineage.target ? "true" : "false"}
                    key={target}
                  >
                    {target}
                  </span>
                ))}
              </dd>
            </div>
          </>
        ) : null}
      </dl>

      <div className="ui-preview-actions">
        {preview.layoutJSON?.viewActionID ? (
          <ActionButton
            actionID={preview.layoutJSON.viewActionID}
            focusID={`ui-preview:${toolID}:layout-json`}
            tooltip={preview.layoutJSON.displayName}
          >
            Open layout JSON
          </ActionButton>
        ) : null}
        {preview.evidenceJSON?.viewActionID ? (
          <ActionButton
            actionID={preview.evidenceJSON.viewActionID}
            focusID={`ui-preview:${toolID}:evidence-json`}
            tooltip={preview.evidenceJSON.displayName}
          >
            Open evidence JSON
          </ActionButton>
        ) : null}
        {preview.rawActionID ? (
          <ActionButton
            actionID={preview.rawActionID}
            focusID={`ui-preview:${toolID}:lineage`}
            tooltip="Open ui_preview_result.v1 lineage in Inspector"
          >
            Inspect lineage
          </ActionButton>
        ) : null}
      </div>
    </section>
  );
}

const Tool = memo(function Tool({
  tool,
  conversationID,
  turnID,
  waitRecords,
}: {
  tool: ConversationWebTool;
  waitRecords?: ConversationWebTool[];
  conversationID: string;
  turnID: string;
}): React.JSX.Element {
  const statusText = visibleExecutionStatus(tool.status, tool.statusText);
  const imageViewSource = tool.imageView?.assets.find((asset) => asset.role === "source");
  const evidenceSource = tool.uiEvidence?.assets.find((asset) => asset.role === "source");
  const structuredImageSource = imageViewSource ?? evidenceSource
    ?? tool.uiLayout?.overlay ?? tool.uiPreview?.fallback;
  // Tool rows stay compact by default, including while they run. The parent
  // group header communicates the current action without expanding detail.
  const { open, onSummaryClick, onPointerDown } = useActivityDisclosure(`tool:${tool.id}`);
  // While the tool runs, follow the newest log lines inside the bounded output
  // frame; scrolling up to read pauses the follow until the user returns to
  // the bottom (see useTailFollow).
  const [outputFrame, setOutputFrame] = useState<HTMLDivElement | null>(null);
  useTailFollow(outputFrame, tool.status === "running");
  return (
    <details
      className="tool"
      data-status={tool.status}
      data-tool-id={tool.id}
      open={open}
    >
      <summary
        className="interactive tool-summary"
        data-focus-id={`tool:${tool.id}`}
        onClick={onSummaryClick} onPointerDown={onPointerDown}
      >
        {structuredImageSource ? (
          <ImageViewPreview
            conversationID={conversationID}
            turnID={turnID}
            toolID={tool.id}
            image={structuredImageSource}
            variant="thumbnail"
          />
        ) : null}
        <span className="tool-title">{tool.name}</span>
        {tool.changeSummary ? <ChangeSummary value={tool.changeSummary} /> : null}
        {statusText ? (
          <span className="tool-status" data-tone={tool.status}>{statusText}</span>
        ) : null}
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      {open ? <div className="tool-detail">
        {tool.uiPreview ? (
          <UIPreviewActivity
            preview={tool.uiPreview}
            conversationID={conversationID}
            turnID={turnID}
            toolID={tool.id}
          />
        ) : tool.imageView ? (
          <ImageViewActivity
            imageView={tool.imageView}
            conversationID={conversationID}
            turnID={turnID}
            toolID={tool.id}
          />
        ) : tool.uiEvidence ? (
          <UIEvidenceActivity
            evidence={tool.uiEvidence}
            conversationID={conversationID}
            turnID={turnID}
            toolID={tool.id}
          />
        ) : tool.uiLayout ? (
          <UILayoutActivity
            layout={tool.uiLayout}
            conversationID={conversationID}
            turnID={turnID}
            toolID={tool.id}
          />
        ) : <>
          <ToolResultCard tool={tool} outputRef={setOutputFrame} />
          {waitRecords ? <div className="tool-wait-outputs">
            {waitRecords.map((record, index) => record.fullOutputActionID ? (
              <ActionButton key={record.id} actionID={record.fullOutputActionID}>{record.labels?.viewFullOutput} {index + 1}</ActionButton>
            ) : null)}
          </div> : null}
        </>}
        {tool.dagNodes ? (
          <section className="dag-summary-card">
            <div className="dag-summary-header">
              <span className="dag-summary-icon" aria-hidden="true">⚡</span>
              <span className="dag-summary-title">Workflow DAG</span>
              {tool.status === "completed" ? (
                <span className="dag-summary-badge">✓</span>
              ) : null}
            </div>
            <div className="dag-summary-body">
              <span className="dag-summary-count">
                📊 {tool.dagNodes} node{tool.dagNodes !== 1 ? "s" : ""}
                {tool.dagEdges != null ? `, ${tool.dagEdges} edge${tool.dagEdges !== 1 ? "s" : ""}` : ""}
              </span>
              {tool.dagOpenActionID ? (
                <ActionButton
                  actionID={tool.dagOpenActionID}
                  focusID={`tool-dag:${tool.id}`}
                  tooltip="Open workflow DAG detail"
                >
                  View Workflow DAG →
                </ActionButton>
              ) : null}
            </div>
          </section>
        ) : null}
        {tool.artifactActionID ? (
          <ActionButton actionID={tool.artifactActionID} focusID={`tool-artifact:${tool.id}`}>
            Open artifact
          </ActionButton>
        ) : null}
        {tool.imageView || tool.uiEvidence || tool.uiLayout || tool.uiPreview
          ? null
          : tool.assetActions.map((asset) => (
          <ActionButton
            key={asset.actionID}
            actionID={asset.actionID}
            focusID={asset.focusID}
            tooltip={asset.tooltip}
          >
            {asset.title}
          </ActionButton>
        ))}
      </div> : null}
    </details>
  );
});

function activateSelectableAction(
  event: React.MouseEvent | React.KeyboardEvent,
  actionID?: string,
): void {
  if (!actionID || !window.getSelection()?.isCollapsed) return;
  if ("key" in event && !["Enter", " "].includes(event.key)) return;
  event.preventDefault();
  dispatchAction(actionID);
}

// ── Context-management chips & verification blocks (system blocks) ──

/** Context transactions stay one quiet row, with explicit result provenance. */
function TurnOutcome({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  const { open, onSummaryClick, onPointerDown } = useActivityDisclosure(`outcome:${block.id}`);
  const value = block.outcome!;
  if (value.kind === "cancelled") return <aside className="turn-cancelled">{value.title}</aside>;
  return <aside className="turn-outcome" role="note">
    <div className="turn-outcome-title">{value.title}</div>
    {value.message ? <p>{value.message}</p> : null}
    {block.actionID ? <button className="interactive turn-outcome-context" onClick={() => dispatchAction(block.actionID!)}>{value.contextLabel}</button> : null}
    <details open={open} className="turn-outcome-details">
      <summary className="interactive" onClick={onSummaryClick} onPointerDown={onPointerDown} data-focus-id={`outcome:${block.id}`}>{value.detailsLabel}<span className="disclosure-chevron" aria-hidden="true">›</span></summary>
      {open ? <div>
        <dl>{value.facts.map((fact, i) => <div key={i}><dt>{fact.label}</dt><dd>{fact.value}</dd></div>)}</dl>
        <details className="turn-outcome-raw"><summary className="interactive">{value.rawLabel}<span className="disclosure-chevron" aria-hidden="true">›</span></summary><pre>{value.diagnostic}</pre></details>
        {block.codeCopyActionIDs[0] ? <button className="interactive" onClick={() => dispatchAction(block.codeCopyActionIDs[0])}>{value.copyLabel}</button> : null}
      </div> : null}
    </details>
  </aside>;
}

function ContextChip({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  const { open, onSummaryClick, onPointerDown } = useActivityDisclosure(`context:${block.id}`);
  const value = block.contextMaintenance;
  if (!value) return <aside className="system-block">{block.text}</aside>;
  return <details className="context-maintenance" data-status={value.status} open={open}>
    <summary className="interactive context-maintenance-summary" onClick={onSummaryClick} onPointerDown={onPointerDown} data-focus-id={`context:${block.id}`}>
      <span className="context-maintenance-title">{value.title}</span>
      <span aria-hidden="true">·</span>
      <span className="context-maintenance-result">{value.summary}</span>
      <span className="disclosure-chevron" aria-hidden="true">›</span>
    </summary>
    {open ? <div className="context-maintenance-body">
      <dl>{value.steps.map((step, index) => <div className="context-maintenance-step" key={index}><dt>{step.label}</dt><dd>{step.value}</dd></div>)}</dl>
      {value.note ? <p className="context-maintenance-note">{value.note}</p> : null}
    </div> : null}
  </details>;
}

/** pre_mutation renders as a thinking-style self-check disclosure. */
function PreMutationBlock({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  return (
    <details className="thinking-block pre-mutation-block" data-status={block.status}>
      <summary className="thinking-summary">
        <span className="thinking-label">
          <span aria-hidden="true">💭</span> 编辑前自检
        </span>
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      <div className="thinking-body">
        {block.text ? <Markdown block={{ ...block, kind: "markdown" }} /> : null}
      </div>
    </details>
  );
}

/** Tone heuristic for verified output text ("<command>: <result>"). */
function verifiedTone(text: string): "success" | "danger" | "warning" | "neutral" {
  const lower = text.toLowerCase();
  if (lower.includes("could not run") || lower.includes("cannot run")) return "warning";
  if (lower.includes("exit status") || lower.includes("error") || lower.includes("failed")) return "danger";
  if (lower.includes("passed") || lower.includes("ok") || lower.includes("success")) return "success";
  return "neutral";
}

const verifiedLabel: Record<ReturnType<typeof verifiedTone>, string> = {
  success: "✓ 验证通过",
  danger: "✗ 验证失败",
  warning: "⚠ 未能运行",
  neutral: "≡ 验证输出",
};

/** verified renders as a terminal-output style card; failures auto-expand. */
function VerifiedBlock({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  const text = block.text ?? "";
  const tone = verifiedTone(text);
  return (
    <details
      className="verified-block"
      data-tone={tone}
      open={tone === "danger" || tone === "warning"}
    >
      <summary className="verified-summary interactive">
        <span className="verified-label">{verifiedLabel[tone]}</span>
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      {text ? (
        <div className="overflow-frame code-frame verified-output" data-scroll-id={`verified:${block.id}`}>
          <pre><code>{text}</code></pre>
        </div>
      ) : null}
    </details>
  );
}

function ThinkingBlock({ block }: { block: ConversationWebBlock }): React.JSX.Element | null {
  const { open, onSummaryClick, onPointerDown } = useActivityDisclosure(`thinking:${block.id}`);
  const streaming = block.status === "streaming";
  const [scrollPanel, setScrollPanel] = useState<HTMLDivElement | null>(null);

  // While streaming, keep the newest tokens visible inside the fixed-height
  // panel: follow the tail as the player reveals text, but only while the
  // panel is at the bottom. Scrolling up to read pauses the follow — new
  // tokens grow below the reading position instead of yanking the viewport —
  // and scrolling back to the bottom resumes it. StreamingMarkdown owns its
  // own render clock (rAF per frame), so the parent only re-renders on
  // protocol batches — a ResizeObserver on the content catches every reveal
  // step and pins the container without re-rendering React.
  useTailFollow(scrollPanel, streaming);

  // Keep the compact thinking row mounted before the first token arrives so
  // the user can see that the model is actively thinking. Completed empty
  // thoughts carry no information and remain hidden.
  if ((!block.text || !block.text.trim()) && block.status !== "streaming") return null;

  return (
    <details
      className="thinking-block"
      data-status={block.status}
      open={open}
    >
      <summary
        className="interactive tool-summary thinking-summary"
        data-focus-id={`thinking:${block.id}`}
        onClick={onSummaryClick} onPointerDown={onPointerDown}
      >
        <span className="thinking-label">{block.title}</span>
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      {open && block.text ? (
        <div className="thinking-body">
          <div ref={setScrollPanel} className="thinking-scroll">
            <div className="thinking-scroll-content">
              <Markdown block={{ ...block, kind: "markdown" }} />
            </div>
          </div>
        </div>
      ) : null}
    </details>
  );
}

function GroupElapsed({ block }: { block: ConversationWebBlock }): React.JSX.Element | null {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (block.startedAtMilliseconds === undefined || block.finishedAtMilliseconds !== undefined || block.status !== "running") return;
    const timer = window.setInterval(() => { if (!workbenchSuspended) setNow(Date.now()); }, 1000);
    return () => window.clearInterval(timer);
  }, [block.startedAtMilliseconds, block.finishedAtMilliseconds, block.status]);
  if (block.startedAtMilliseconds === undefined) return null;
  const end = block.finishedAtMilliseconds ?? now;
  return <span className="tool-group-elapsed">{formatDuration(Math.max(0, (end - block.startedAtMilliseconds) / 1000))}</span>;
}

function BackgroundJobRow({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  return <section className="interactive tool-summary background-job-row" data-job-id={block.actionTooltip}
    data-status={block.status} role="button" tabIndex={0} data-focus-id={`background-job:${block.id}`}
    onClick={event => activateSelectableAction(event, block.actionID)}
    onKeyDown={event => activateSelectableAction(event, block.actionID)}>
    <span className="tool-title">{block.title}</span>
    {block.statusText ? <span className="tool-status" data-tone={block.status}>{block.statusText}</span> : null}
    <span className="disclosure-chevron" aria-hidden="true">›</span>
  </section>;
}

function ToolGroupBlock({ block, conversationID, turnID }: {
  block: ConversationWebBlock;
  conversationID: string;
  turnID: string;
}): React.JSX.Element {
  const { open, onSummaryClick, onPointerDown } = useActivityDisclosure(`group:${block.id}`);
  const deferredOpen = useDeferredValue(open);
  const large = (block.activityOrder?.length ?? block.tools.length) > 80;
  const ready = !large || deferredOpen;
  const headerTitle = block.title;
  const hasActive = block.status === "running" && (block.tools.some(tool => tool.status === "running") || (block.activityJobs ?? []).some(job => job.status === "running"));
  return <details className="tool-group" data-status={block.status} data-collecting={block.isCollecting} data-active={hasActive} open={open} data-anchor-id={`group:${turnID}:${block.id}`}>
    <summary className="interactive tool-group-summary" data-focus-id={`tool-group:${block.id}`} onClick={onSummaryClick} onPointerDown={onPointerDown}>
      {block.status === "running" ? <span className="tool-group-running" role="img" aria-label={block.statusText}>
        <span aria-hidden="true" /><span aria-hidden="true" /><span aria-hidden="true" /><span aria-hidden="true" />
      </span> : null}
      <span className="tool-group-title" title={headerTitle}>{headerTitle}</span>
      {block.failureText ? <span className="tool-status" data-tone="failed">{block.failureText}</span> : null}
      <GroupElapsed block={block} />
      <span className="disclosure-chevron" aria-hidden="true">›</span>
    </summary>
    {open ? ready ? <ToolGroupContents block={block} conversationID={conversationID} turnID={turnID} />
      : <div className="tool-group-tools" aria-busy="true"><ActivitySkeleton label={block.title} /></div> : null}
  </details>;
}

const ToolGroupContents = memo(function ToolGroupContents({ block, conversationID, turnID }: {
  block: ConversationWebBlock; conversationID: string; turnID: string;
}): React.JSX.Element {
  const tools = new Map(block.tools.map((tool) => [`tool:${tool.id}`, tool]));
  const thinking = new Map((block.activityThinking ?? []).map((item) => [`${item.systemKind === "preMutation" ? "preMutation" : "thinking"}:${item.id}`, item]));
  const jobs = new Map((block.activityJobs ?? []).map(item => [`job:${item.actionTooltip}`, item]));
  const runningTools = block.tools.filter(tool => tool.status === "running");
  // Empty output is pending; streaming output already supplies its own visible
  // activity. The group tail also covers gaps and independent background jobs.
  const runningJobs = (block.activityJobs ?? []).filter(job => job.status === "running");
  const pending = block.status === "running" && (runningJobs.length > 0 || runningTools.length === 0 || runningTools.some(tool => !tool.output && !tool.hasResult && !tool.dagNodes));
  const rows: string[][] = [];
  for (const id of block.activityOrder ?? block.tools.map(tool => `tool:${tool.id}`)) {
    const current = tools.get(id);
    const previous = rows.at(-1);
    const last = previous ? tools.get(previous[0]) : undefined;
    if (current?.rawName === "job_wait" && current.backgroundJobID && last?.rawName === "job_wait" && last.backgroundJobID === current.backgroundJobID) previous!.push(id);
    else rows.push([id]);
  }
  return <div className="tool-group-tools">{rows.map(ids => {
      const first = tools.get(ids[0]);
      if (!first) {
        const job = jobs.get(ids[0]);
        if (job) return <BackgroundJobRow key={ids[0]} block={job} />;
        const thought = thinking.get(ids[0]); return thought ? <ThinkingBlock key={ids[0]} block={thought} /> : null;
      }
      if (ids.length === 1) return <Tool key={ids[0]} tool={first} conversationID={conversationID} turnID={turnID} />;
      const waits = ids.map(id => tools.get(id)!);
      const last = waits.at(-1)!;
      const failed = waits.find(tool => tool.status === "failed");
      const status = waits.some(tool => tool.status === "running") ? "running" : failed ? "failed" : "completed";
      const combined: ConversationWebTool = { ...last, id: first.id,
        name: `${first.name} · ${first.labels?.waitingChecks?.replace("{count}", String(ids.length)) ?? ids.length}`,
        status, statusText: status === "failed" ? failed?.statusText : status === "running" ? waits.find(tool => tool.status === "running")?.statusText : undefined,
        output: waits.map((tool, i) => tool.output ? `${i + 1}. ${tool.output}` : "").filter(Boolean).join("\n\n"),
        copyOutputActionID: undefined, fullOutputActionID: undefined, outputActions: [] };
      return <Tool key={ids[0]} tool={combined} waitRecords={waits} conversationID={conversationID} turnID={turnID} />;
    })}
      {pending ? <ActivitySkeleton className="tool-group-pending" label={block.statusText} /> : null}
    </div>;
});

const Block = memo(function Block({
  block,
  conversationID,
  turnID,
}: {
  block: ConversationWebBlock;
  conversationID: string;
  turnID: string;
}): React.JSX.Element {
  switch (block.kind) {
    case "markdown":
      return <Markdown block={block} />;
    case "thinking":
      return <ThinkingBlock block={block} />;
    case "toolGroup":
      if (block.activityOrder || block.tools.length > 1) {
        return <ToolGroupBlock block={block} conversationID={conversationID} turnID={turnID} />;
      }
      return <section className="tool-group" data-status={block.status}>
        {block.tools.map((tool) => (
          <Tool key={tool.id} tool={tool} conversationID={conversationID} turnID={turnID} />
        ))}
      </section>;
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
      if (block.outcome) return <TurnOutcome block={block} />;
      if (block.systemKind === "contextEdited"
        || block.systemKind === "contextPruned"
        || block.systemKind === "contextCompact") {
        return <ContextChip block={block} />;
      }
      if (block.systemKind === "preMutation") {
        return <PreMutationBlock block={block} />;
      }
      if (block.systemKind === "verified") {
        return <VerifiedBlock block={block} />;
      }
      return (
        <aside className="system-block" data-status={block.status}>
          <span>{block.title}</span> {block.text}
        </aside>
      );
    case "childStream":
      const childStatus = block.statusText ?? visibleExecutionStatus(block.status);
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
          <ToolActionIcon glyph={block.childStreamKind === "job" ? "$" : "◇"} />
          {block.childStreamKind !== "job" ? <span className="child-stream-kind">Subagent</span> : null}
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

const CollapsibleUserPrompt = memo(function CollapsibleUserPrompt({
  turnID,
  text,
  copyActionID,
  startedAtMilliseconds,
}: {
  turnID: string;
  text: string;
  copyActionID?: string;
  startedAtMilliseconds?: number;
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
    <div className="user-message">
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
      <div className="user-message-actions">
        {startedAtMilliseconds != null ? (
          <time dateTime={new Date(startedAtMilliseconds).toISOString()}>
            {new Date(startedAtMilliseconds).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
          </time>
        ) : null}
        {copyActionID ? (
          <button type="button" className="turn-actions-icon interactive"
            aria-label="拷贝消息" title="拷贝消息" data-focus-id={`user-copy:${turnID}`}
            onClick={() => dispatchAction(copyActionID)}>
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" aria-hidden="true">
              <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />
              <path d="M10.5 5.5v-2A1.5 1.5 0 0 0 9 2H4A1.5 1.5 0 0 0 2.5 3.5v5A1.5 1.5 0 0 0 4 10h1.5" />
            </svg>
          </button>
        ) : null}
      </div>
    </div>
  );
});

/// How many files the change card shows before "再显示 N 个文件" (Codex shows 3).
const CHANGE_PREVIEW_LIMIT = 3;

function statusWord(status: string): string {
  if (status === "added") return "新增";
  if (status === "deleted") return "删除";
  return "修改";
}

/// Codex-parity card under the answer: "已编辑 4 个文件 +416 -0" plus the file
/// list. The counts come from the Runtime, not from counting tool calls, so
/// writes made inside workflow nodes are included. `files` may be truncated
/// (200) — the header therefore uses `filesChanged`, never `files.length`.
function TurnChangesCard({
  turnID,
  changes,
}: {
  turnID: string;
  changes: NonNullable<ConversationWebTurn["changes"]>;
}) {
  const [expanded, setExpanded] = useState(false);
  // Largest change first, so a long tail collapses behind the fold. Stable for
  // equal sizes, which keeps the order from jumping between renders.
  const sorted = [...changes.files].sort(
    (a, b) => b.added + b.removed - (a.added + a.removed),
  );
  const previewCount = Math.min(sorted.length, CHANGE_PREVIEW_LIMIT);
  const visible = expanded ? sorted : sorted.slice(0, previewCount);
  // `filesChanged` is the full-turn count; `files` may have been clipped by the
  // Runtime (200). Fold math therefore runs on the list we actually hold, and the
  // files the Runtime never sent get their own note — otherwise a 250-file turn
  // reads "已编辑 250 个文件" above "再显示 197 个文件" and the numbers stop adding
  // up (3 + 197 ≠ 250).
  const hiddenCount = sorted.length - previewCount;
  const withheldCount = Math.max(0, changes.filesChanged - sorted.length);

  return (
    <section
      className="turn-changes"
      data-selection-id={`turn:${turnID}:changes`}
      aria-label="本轮编辑的文件"
    >
      <header className="turn-changes-head">
        <span className="turn-changes-icon" aria-hidden="true">±</span>
        <div className="turn-changes-heading">
          <span className="turn-changes-title">已编辑 {changes.filesChanged} 个文件</span>
          <span className="turn-changes-totals">
            <span className="diff-add">+{changes.addedLines}</span>
            <span className="diff-del">-{changes.removedLines}</span>
          </span>
        </div>
      </header>
      {visible.length ? (
        <ul className="turn-changes-list">
          {visible.map((file) => (
            <li className="turn-changes-row" key={file.path}>
              <span className="turn-changes-path" title={file.path}>{file.path}</span>
              <span className="turn-changes-delta">
                {file.added ? <span className="diff-add">+{file.added}</span> : null}
                {file.removed ? <span className="diff-del">-{file.removed}</span> : null}
                {!file.added && !file.removed ? (
                  <span className="diff-none">{statusWord(file.status)}</span>
                ) : null}
              </span>
            </li>
          ))}
        </ul>
      ) : null}
      {hiddenCount > 0 ? (
        <button
          type="button"
          className="turn-changes-more interactive"
          data-focus-id={`turn-changes-more:${turnID}`}
          onClick={() => setExpanded((value) => !value)}
        >
          {expanded ? "收起" : `再显示 ${hiddenCount} 个文件`}
          <span className="turn-changes-more-chevron" aria-hidden="true">
            {expanded ? "›" : "⌄"}
          </span>
        </button>
      ) : null}
      {withheldCount > 0 && (expanded || hiddenCount <= 0) ? (
        <p className="turn-changes-note">
          另有 {withheldCount} 个文件未列出
        </p>
      ) : null}
    </section>
  );
}

function processSummaryLabel(turn: ConversationWebTurn): string {
  const parts: string[] = [];
  if (turn.elapsedText) parts.push(`用时 ${turn.elapsedText}`);
  // "编辑 3 个文件" comes from the Runtime's per-turn diffstat. No qualifier:
  // the Runtime already folds writes made inside workflow nodes into its own
  // count, so this number covers the whole turn.
  const changed = turn.changes?.summary
    ?? (turn.changes && turn.changes.filesChanged > 0
      ? `编辑 ${turn.changes.filesChanged} 个文件`
      : null);
  if (changed) parts.push(changed);
  return parts.length ? parts.join(" · ") : "查看执行过程";
}

/// First-class generic preview card. Interactive viewer bytes and fallback
/// raster bytes are fetched by the authenticated native host and exposed only
/// through opaque, memory-backed scheme tokens.
function PreviewBlock({
  preview,
  conversationID,
}: {
  preview: ConversationWebPreview;
  conversationID: string;
}) {
  const [expanded, setExpanded] = useState(preview.initialState === "expanded");
  const [viewer, setViewer] = useState<{
    status: "idle" | "loading" | "ready" | "failed";
    url?: string;
    errorCode?: string;
  }>({ status: "idle" });
  const [fallback, setFallback] = useState<{
    status: "idle" | "loading" | "ready" | "failed";
    url?: string;
    errorCode?: string;
  }>({ status: "idle" });
  const viewerRequestID = useRef<string | undefined>(undefined);
  const fallbackRequestID = useRef<string | undefined>(undefined);
  const kindLabel = preview.kind === "interactive_html"
    ? "Interactive HTML"
    : "Static image";
  const wantsViewer = preview.presentationState === "interactiveReady";
  const isDegradedPreview = preview.presentationState === "staticFallback"
    || preview.presentationState === "expired"
    || preview.presentationState === "unavailable"
    || preview.presentationState === "renderFailed";
  const wantsFallbackImage = Boolean(preview.fallbackAssetID) && isDegradedPreview;

  useEffect(() => {
    const handleResolved = (event: Event) => {
      const detail = (event as CustomEvent<{
        requestID?: string;
        artifactID?: string;
        revision?: number;
        url?: string;
        errorCode?: string;
      }>).detail;
      if (
        detail?.artifactID !== preview.artifactID
        || detail.revision !== preview.revision
        || detail.requestID !== viewerRequestID.current
      ) return;
      setViewer(detail.url
        ? { status: "ready", url: detail.url }
        : { status: "failed", errorCode: detail.errorCode });
    };
    window.addEventListener("previewViewerURLResolved", handleResolved);
    return () => window.removeEventListener("previewViewerURLResolved", handleResolved);
  }, [preview.artifactID, preview.revision]);

  useEffect(() => {
    if (!expanded || !wantsViewer || viewer.status !== "idle") return;
    const requestID = crypto.randomUUID();
    viewerRequestID.current = requestID;
    setViewer({ status: "loading" });
    postToNative({
      type: "resolvePreviewViewerURL",
      conversationID,
      artifactID: preview.artifactID,
      revision: preview.revision,
      requestID,
    });
  }, [
    expanded,
    wantsViewer,
    viewer.status,
    conversationID,
    preview.artifactID,
    preview.revision,
  ]);

  useEffect(() => {
    const handleResolved = (event: Event) => {
      const detail = (event as CustomEvent<{
        requestID?: string;
        artifactID?: string;
        revision?: number;
        assetID?: string;
        url?: string;
        errorCode?: string;
      }>).detail;
      if (
        detail?.artifactID !== preview.artifactID
        || detail.revision !== preview.revision
        || detail.assetID !== preview.fallbackAssetID
        || detail.requestID !== fallbackRequestID.current
      ) return;
      setFallback(detail.url
        ? { status: "ready", url: detail.url }
        : { status: "failed", errorCode: detail.errorCode });
    };
    window.addEventListener("previewAssetURLResolved", handleResolved);
    return () => window.removeEventListener("previewAssetURLResolved", handleResolved);
  }, [preview.artifactID, preview.revision, preview.fallbackAssetID]);

  useEffect(() => {
    if (!expanded || !wantsFallbackImage || !preview.fallbackAssetID
      || fallback.status !== "idle") return;
    const requestID = crypto.randomUUID();
    fallbackRequestID.current = requestID;
    setFallback({ status: "loading" });
    postToNative({
      type: "resolvePreviewAssetURL",
      conversationID,
      artifactID: preview.artifactID,
      revision: preview.revision,
      assetID: preview.fallbackAssetID,
      requestID,
    });
  }, [
    expanded,
    wantsFallbackImage,
    fallback.status,
    conversationID,
    preview.artifactID,
    preview.revision,
    preview.fallbackAssetID,
  ]);

  const viewerStyle = {
    minHeight: preview.minHeight ?? 420,
    aspectRatio: preview.preferredAspectRatio
      ? String(preview.preferredAspectRatio)
      : "16 / 9",
  };

  return (
    <section
      className="preview-block"
      data-preview-id={preview.id}
      data-preview-revision={preview.revision}
      data-status={preview.presentationState}
      data-selection-id={`preview:${preview.id}:${preview.revision}`}
      aria-label={`Preview: ${preview.title}`}
    >
      <details
        className="preview-disclosure"
        data-disclosure-id={`preview:${preview.id}`}
        open={expanded}
      >
        <summary
          className="interactive preview-summary"
          data-focus-id={`preview:${preview.id}`}
          onClick={(event) => {
            event.preventDefault();
            setExpanded((value) => !value);
          }}
        >
          <span className="preview-kind" aria-hidden="true">Preview</span>
          <span className="preview-title">{preview.title}</span>
          <span className="preview-status" data-tone={preview.tone}>
            {preview.statusLabel}
          </span>
          <span className="disclosure-chevron" aria-hidden="true">›</span>
        </summary>
        <div className="preview-body">
          {preview.summary ? (
            <p className="preview-description">{preview.summary}</p>
          ) : null}
          {wantsViewer ? (
            <div className="preview-viewer-shell" style={viewerStyle}>
              {viewer.status === "ready" && viewer.url ? (
                <iframe
                  className="preview-frame"
                  data-preview-frame={preview.artifactID}
                  data-preview-revision={preview.revision}
                  src={viewer.url}
                  title={preview.title}
                  sandbox="allow-scripts"
                  referrerPolicy="no-referrer"
                  loading="lazy"
                  onLoad={(event) => {
                    event.currentTarget.dataset.loaded = "true";
                  }}
                />
              ) : (
                <div className="preview-viewer-placeholder" role="status">
                  {viewer.status === "failed"
                    ? `Interactive preview unavailable${viewer.errorCode ? ` · ${viewer.errorCode}` : ""}`
                    : "Loading interactive preview…"}
                </div>
              )}
            </div>
          ) : null}
          {preview.degradedReason ? (
            <p className="preview-degraded" role="status">
              {preview.degradedReason}
            </p>
          ) : null}
          {wantsFallbackImage ? (
            <div className="preview-fallback">
              {fallback.status === "ready" && fallback.url ? (
                <img
                  className="preview-fallback-image"
                  data-preview-fallback-asset-id={preview.fallbackAssetID}
                  src={fallback.url}
                  alt={preview.fallbackAlt ?? "Static preview evidence"}
                  loading="lazy"
                  onLoad={(event) => {
                    event.currentTarget.dataset.loaded = "true";
                  }}
                />
              ) : (
                <div className="preview-fallback-placeholder" role="status">
                  {fallback.status === "failed"
                    ? `Static evidence unavailable${fallback.errorCode ? ` · ${fallback.errorCode}` : ""}`
                    : "Loading static evidence…"}
                </div>
              )}
            </div>
          ) : null}
          {isDegradedPreview && preview.fallbackText ? (
            <div className="preview-evidence">
              <span className="preview-evidence-label">静态证据</span>
              <span>{preview.fallbackText}</span>
              {preview.fallbackAssetID ? (
                <span className="preview-evidence-id">
                  {preview.fallbackAssetID}
                </span>
              ) : null}
            </div>
          ) : null}
          <div className="preview-meta">
            <span>{kindLabel}</span>
            <span>revision {preview.revision}</span>
            {preview.capability ? <span>{preview.capability}</span> : null}
            {preview.errorCode ? <span>{preview.errorCode}</span> : null}
          </div>
        </div>
      </details>
    </section>
  );
}

/// Compact duration, mirroring `ConversationTurn.formattedDuration` so the live
/// counter and the final "用时 …" never disagree in shape: 48秒 / 24分40秒 / 1小时5分.
function formatDuration(totalSeconds: number): string {
  const seconds = Math.max(0, Math.floor(totalSeconds));
  if (seconds < 60) return `${seconds}秒`;
  if (seconds < 3600) {
    const minutes = Math.floor(seconds / 60);
    const rest = seconds % 60;
    return rest === 0 ? `${minutes}分` : `${minutes}分${rest}秒`;
  }
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return minutes === 0 ? `${hours}小时` : `${hours}小时${minutes}分`;
}

/// Codex keeps a running turn flat, with one live clock on top: "已处理 8分15秒".
/// The counter ticks locally from the turn's start stamp — asking the Runtime
/// for a snapshot every second would repaint the whole transcript.
function LiveTurnHeader({
  startedAtMilliseconds,
}: {
  startedAtMilliseconds?: number;
}) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (startedAtMilliseconds === undefined) return;
    setNow(Date.now());
    const id = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(id);
  }, [startedAtMilliseconds]);

  if (startedAtMilliseconds === undefined) return null;
  const elapsedSeconds = (now - startedAtMilliseconds) / 1_000;
  return (
    <div className="turn-live-header">
      <span className="turn-live-elapsed">
        已处理 {formatDuration(elapsedSeconds)}
      </span>
    </div>
  );
}

/// Codex-style completed-turn actions bar: [copy] [share] [···] on the left,
/// token totals / model badge / timestamp on the right. Rendered only after
/// the turn finishes — a streaming turn shows nothing here.
function TurnActionsBar({ turn }: { turn: ConversationWebTurn }) {
  const [menuOpen, setMenuOpen] = useState(false);
  const footer = turn.footer;
  const modelTitle = turn.modelRoute || turn.model;

  useEffect(() => {
    if (!menuOpen) return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setMenuOpen(false);
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [menuOpen]);

  const menuItems: Array<{
    key: string;
    label: string;
    value?: string;
    actionID?: string;
    focusID?: string;
  }> = [];
  if (footer?.contextTokens) {
    menuItems.push({ key: "context", label: "上下文", value: footer.contextTokens });
  }
  if (footer && footer.invocationCount > 1) {
    menuItems.push({
      key: "invocations",
      label: "模型调用",
      value: `${footer.invocationCount} 次 · ${footer.elapsed}`,
    });
  }
  if (turn.assetsActionID) {
    menuItems.push({
      key: "assets",
      label: "附件",
      value: `${turn.assetCount} 个`,
      actionID: turn.assetsActionID,
      focusID: `turn-assets:${turn.id}`,
    });
  }
  const hasMenu = menuItems.length > 0;

  const hasTokens = Boolean(footer?.totalTokens);
  if (
    !turn.copyActionID && !turn.shareActionID && !hasMenu
    && !hasTokens && !turn.model && !turn.finishedAtClock
  ) {
    return null;
  }

  const tokenTitle = footer
    ? `${footer.totalTokens}${footer.cachedTokens ? `\n（缓存 ${footer.cachedTokens}）` : ""}`
    : undefined;

  return (
    <div className="turn-actions" aria-label="Turn actions">
      {turn.copyActionID ? (
        <button
          type="button"
          className="turn-actions-icon interactive"
          data-focus-id={`turn-copy:${turn.id}`}
          aria-label="拷贝本轮"
          title="拷贝本轮"
          onClick={() => dispatchAction(turn.copyActionID!)}
        >
          <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" aria-hidden="true">
            <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />
            <path d="M10.5 5.5v-2a1.5 1.5 0 0 0-1.5-1.5H4A1.5 1.5 0 0 0 2.5 3.5v5A1.5 1.5 0 0 0 4 10h1.5" />
          </svg>
        </button>
      ) : null}
      {turn.shareActionID ? (
        <button
          type="button"
          className="turn-actions-icon interactive"
          data-focus-id={`turn-share:${turn.id}`}
          aria-label="分享本轮"
          title="分享本轮"
          onClick={() => dispatchAction(turn.shareActionID!)}
        >
          <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" aria-hidden="true">
            <path d="M9.5 3.5 14 7.5l-4.5 4v-2.6C6 8.9 3.8 10 2.5 12.5c0-4 2.5-6.6 7-7V3.5Z" />
          </svg>
        </button>
      ) : null}
      {hasMenu ? (
        <div className="turn-actions-menu-anchor">
          <button
            type="button"
            className="turn-actions-icon interactive"
            data-focus-id={`turn-more:${turn.id}`}
            aria-label="更多操作"
            aria-expanded={menuOpen}
            title="更多操作"
            onClick={() => setMenuOpen((open) => !open)}
          >
            <svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
              <circle cx="3" cy="8" r="1.2" />
              <circle cx="8" cy="8" r="1.2" />
              <circle cx="13" cy="8" r="1.2" />
            </svg>
          </button>
          {menuOpen ? (
            <>
              <div
                className="turn-actions-menu-backdrop"
                onClick={() => setMenuOpen(false)}
              />
              <div className="turn-actions-menu" role="menu" aria-label="更多操作">
                {menuItems.map((item) =>
                  item.actionID ? (
                    <button
                      key={item.key}
                      type="button"
                      role="menuitem"
                      className="turn-actions-menu-item interactive"
                      data-focus-id={item.focusID}
                      onClick={() => {
                        setMenuOpen(false);
                        dispatchAction(item.actionID!);
                      }}
                    >
                      <span>{item.label}</span>
                      <span className="turn-actions-menu-value">{item.value}</span>
                    </button>
                  ) : (
                    <div key={item.key} role="menuitem" className="turn-actions-menu-item">
                      <span>{item.label}</span>
                      <span className="turn-actions-menu-value">{item.value}</span>
                    </div>
                  ),
                )}
              </div>
            </>
          ) : null}
        </div>
      ) : null}

      <div className="turn-actions-metadata">
        {hasTokens ? (
          <span className="turn-actions-stat" title={tokenTitle}>
            <svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.3" aria-hidden="true" className="turn-actions-stat-gem">
              <path d="M6 1.2 10.8 6 6 10.8 1.2 6Z" />
            </svg>
            <span className="turn-actions-stat-value">{footer!.totalTokens}</span>
          </span>
        ) : null}
        {turn.model ? (
          <span
            className="turn-actions-model"
            title={modelTitle}
          >
            <svg width="13" height="13" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.3" aria-hidden="true">
              <circle cx="7" cy="7" r="5.6" />
              <path d="m4.6 7.2 1.7 1.7 3.1-3.6" />
            </svg>
            <span>{turn.model}</span>
          </span>
        ) : null}
        {turn.finishedAtClock ? (
          <span className="turn-timestamp">{turn.finishedAtClock}</span>
        ) : null}
      </div>
    </div>
  );
}

const Turn = memo(function Turn({
  turn,
  conversationID,
}: {
  turn: ConversationWebTurn;
  conversationID: string;
}) {
  const headingID = `turn-heading-${turn.id}`;
  const disclosureContext = React.useMemo(() => ({
    scope: `${conversationID}:${turn.id}`,
    store: new DisclosureStore(),
  }), [conversationID, turn.id]);
  const localAssets = turn.localAssets ?? [];
  useSyncExternalStore(
    subscribeLocalAssetURLs,
    localAssetURLSnapshot,
    localAssetURLSnapshot,
  );

  // Request signed URLs for user assets that arrived without one.
  useEffect(() => {
    for (const asset of turn.userAssets) {
      if (!asset.previewURL) resolveUserAssetURL(asset.assetID);
    }
  }, [turn.userAssets]);

  useEffect(() => {
    for (const asset of localAssets) {
      if (asset.mimeType.startsWith("image/") && !asset.previewURL) {
        resolveLocalAssetURL(asset.id, conversationID);
      }
    }
  }, [turn.localAssets, conversationID]);

  // Keep narration and activity mounted in arrival order across completion.
  const previews = turn.previews ?? [];

  const renderBlocks = (blocks: ConversationWebBlock[]) =>
    blocks.map((block) => (
      <div
        className="turn-block"
        data-block-id={block.id}
        data-block-kind={block.kind}
        data-selection-id={`block:${block.id}`}
        key={block.id}
      >
        <Block block={block} conversationID={conversationID} turnID={turn.id} />
      </div>
    ));

  // Token/context accounting moved out of the folded process body: it is a
  // property of the turn's result, so the completed-turn actions bar carries
  // the totals and the "···" menu holds the details.

  const todoNode = turn.todos.length ? (
    <TodoPanel todos={turn.todos} turnID={turn.id} isLive={turn.isLive} />
  ) : null;
  const previewNodes = previews.length ? (
    <div className="turn-previews">
      {previews.map((preview) => (
        <PreviewBlock
          preview={preview}
          conversationID={conversationID}
          key={`${preview.id}:${preview.revision}`}
        />
      ))}
    </div>
  ) : null;

  return (
    <article
      className="turn"
      data-turn-id={turn.id}
      data-anchor-id={`turn:${turn.id}`}
      aria-labelledby={headingID}
    >
      <h2 className="visually-hidden" id={headingID}>Conversation turn</h2>
      {turn.userAssets.length > 0 || localAssets.length > 0 || turn.fileReferences?.length ? (
        <div className="local-asset-group">
          <div className="user-asset-strip user-attachment-strip" data-scroll-id={`local-assets:${turn.id}`} aria-label="附件与文件引用">
          {turn.userAssets.map((asset) => {
            const resolvedURL = pendingAssetURLs.get(asset.assetID);
            const src = asset.previewURL || (resolvedURL || undefined);
            return (
              <button
                type="button"
                className="user-asset-thumbnail"
                key={asset.assetID}
                title={asset.filename}
                aria-label={`预览图片 ${asset.filename}`}
                onClick={() =>
                  requestAssetPreview(
                    conversationID,
                    turn.id,
                    "user",
                    String(asset.assetID),
                  )
                }
              >
                {src ? (
                  <img
                    src={src}
                    data-asset-id={asset.assetID}
                    alt={asset.filename}
                    loading="lazy"
                  />
                ) : (
                  <img
                    src={userAssetPlaceholderSrc}
                    data-asset-id={asset.assetID}
                    alt={asset.filename}
                    loading="lazy"
                  />
                )}
              </button>
            );
          })}
            {localAssets.map((asset) => {
              const resolved = pendingLocalAssetURLs.get(
                localAssetCacheKey(conversationID, asset.id),
              );
              const src = asset.previewURL || resolved?.url;
              const isImage = asset.mimeType.startsWith("image/");
              const title = `${asset.filename} · 本地处理，文件不会自动上传`;
              const content = isImage && src ? (
                <img
                  src={src}
                  data-local-asset-id={asset.id}
                  alt={asset.filename}
                  loading="lazy"
                />
              ) : (
                <div className="user-asset-placeholder">
                  <span className="local-asset-kind" aria-hidden="true">
                    {localAssetIcon(asset.mimeType, asset.kind)}
                  </span>
                  <span className="user-asset-filename">{asset.filename}</span>
                </div>
              );
              return isImage ? (
                <button
                  type="button"
                  className="user-asset-thumbnail local-asset-thumbnail"
                  key={asset.id}
                  title={title}
                  aria-label={`预览图片 ${asset.filename}`}
                  onClick={() =>
                    requestAssetPreview(conversationID, turn.id, "local", asset.id)
                  }
                >
                  {content}
                </button>
              ) : (
                <div
                  className="user-asset-thumbnail local-asset-thumbnail"
                  key={asset.id}
                  title={title}
                >
                  {content}
                </div>
              );
            })}
          {turn.fileReferences?.map((file) => {
            const path = file.relativePath ?? file.path;
            const name = path.split("/").filter(Boolean).at(-1) ?? path;
            const kind = file.isDirectory ? "目录" : (name.includes(".") ? name.split(".").at(-1)!.toUpperCase() : "文件");
            return <div className="user-file-reference" key={file.id} title={path}>
              <span className="user-file-reference-name">{name}</span>
              <span className="user-file-reference-kind">{kind}</span>
              <span className="user-file-reference-path">{path}</span>
            </div>;
          })}
          </div>
        </div>
      ) : null}
      {turn.userPrompt ? (
        <CollapsibleUserPrompt turnID={turn.id} text={turn.userPrompt}
          copyActionID={turn.userCopyActionID} startedAtMilliseconds={turn.startedAtMilliseconds} />
      ) : null}
      <TurnDisclosureContext.Provider value={disclosureContext}>
      <div className="assistant-lane">
        {turn.isLive ? <LiveTurnHeader startedAtMilliseconds={turn.startedAtMilliseconds} /> : turn.elapsedText ? (
          <div className="turn-process-summary"><span className="turn-process-label">{processSummaryLabel(turn)}</span></div>
        ) : null}
        {renderBlocks(turn.blocks)}
        {previewNodes}
        {todoNode}
        {!turn.isLive && turn.changes ? <TurnChangesCard turnID={turn.id} changes={turn.changes} /> : null}
        {!turn.isLive ? <TurnActionsBar turn={turn} /> : null}
      </div>
      </TurnDisclosureContext.Provider>
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

// RetryBanner â compact inline view showing model retry progress.
// Click to expand for error details.
function RetryBanner({ retry }: { retry: {
  attempt: number;
  maxAttempts: number;
  retryDelayMs: number;
  retryFallback: boolean;
  err?: string;
  startedAtMilliseconds?: number;
} }) {
  const [isExpanded, setIsExpanded] = useState(false);
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    if (!retry.startedAtMilliseconds) return;
    const update = () => setElapsed(Date.now() - retry.startedAtMilliseconds!);
    update();
    const id = setInterval(update, 1000);
    return () => clearInterval(id);
  }, [retry.startedAtMilliseconds]);

  const formatElapsed = (ms: number) => {
    const s = Math.floor(ms / 1000);
    if (s < 60) return s + "s";
    if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s";
    return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
  };

  const hasError = retry.err && retry.err.length > 0;
  const progress = retry.maxAttempts > 0 ? retry.attempt / retry.maxAttempts : 0;

  return (
    <div
      className="retry-banner"
      role="status"
      aria-live="polite"
      aria-atomic="true"
      onClick={() => hasError && setIsExpanded(!isExpanded)}
      style={{ cursor: hasError ? 'pointer' : 'default' }}
    >
      <span className="retry-spinner" aria-hidden="true" />
      <span className="retry-text">
        {"Retrying... (" + retry.attempt + "/" + retry.maxAttempts + ")"}
        {" | " + formatElapsed(elapsed)}
        {retry.retryFallback ? " | Switching to non-stream" : ""}
      </span>
      <div className="retry-progress" style={{ width: (progress * 100) + "%" }} />
      {hasError && isExpanded && (
        <div className="retry-error-detail">
          {retry.err}
        </div>
      )}
    </div>
  );
}

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
        document.documentElement.classList.toggle("workbench-suspended", suspended);
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
      /**
       * Height (pt) of the floating native bottom bar. Mirrored as bottom
       * padding on the shell via a CSS variable on <html>, which React never
       * re-renders, so it survives every revision. Re-pins through the scroll
       * controller: the document just grew, so a pinned viewport must move to
       * the new bottom for newest content to land exactly above the bar.
       */
      setBottomInset(inset: number) {
        const clamped = Math.max(0, Math.round(inset));
        document.documentElement.style.setProperty(
          "--workbench-bottom-inset",
          `${clamped}px`,
        );
        viewportController.contentDidChangeBeforePaint();
      },
      /**
       * Resolved background color of the native detail page, sampled from its
       * .bar material and injected by the host. Set as a CSS variable on
       * <html> so the opaque canvas matches the surrounding native chrome;
       * re-injected whenever the effective appearance changes.
       */
      setHostBackground(hex: string) {
        if (!/^#[0-9a-f]{6}$/i.test(hex)) return;
        document.documentElement.style.setProperty(
          "--workbench-background",
          hex,
        );
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

          // A rapid successor can arrive after React laid out the previous
          // update but before its deferred restoration/ack task. Complete that
          // viewport transaction first: otherwise content growth is mistaken
          // for a reader leaving the bottom. restore() still yields to any
          // gesture that happened after the pending snapshot was captured.
          const pendingViewport = pendingRestoration.current;
          if (pendingViewport?.revision === currentRevision) {
            viewportController.restore(pendingViewport.viewport, pendingViewport.forcePinToBottom);
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
            clearLocalAssetURLs();
            clearImageViewAssetURLs();
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
    const handleAssetURLResolved = (event: Event) => {
      const detail = (event as CustomEvent).detail;
      if (detail && typeof detail.url === "string" && typeof detail.assetID === "number") {
        applyResolvedAssetURL(detail.assetID, detail.url);
      }
    };
    const handleLocalAssetURLResolved = (event: Event) => {
      const detail = (event as CustomEvent).detail;
      if (
        detail &&
        typeof detail.localAssetID === "string" &&
        typeof detail.conversationID === "string" &&
        typeof detail.requestID === "string" &&
        (typeof detail.url === "string" || detail.url == null)
      ) {
        applyResolvedLocalAssetURL(
          detail.conversationID,
          detail.localAssetID,
          detail.requestID,
          detail.url ?? undefined,
        );
      }
    };
    const handleImageViewAssetURLResolved = (event: Event) => {
      const detail = (event as CustomEvent).detail;
      if (
        detail &&
        typeof detail.conversationID === "string" &&
        typeof detail.turnID === "string" &&
        typeof detail.toolID === "string" &&
        typeof detail.assetID === "string" &&
        typeof detail.requestID === "string" &&
        (typeof detail.url === "string" || detail.url == null)
      ) {
        applyResolvedImageViewAssetURL(
          detail.conversationID,
          detail.turnID,
          detail.toolID,
          detail.assetID,
          detail.requestID,
          detail.url ?? undefined,
        );
      }
    };
    window.addEventListener("userAssetURLResolved", handleAssetURLResolved);
    window.addEventListener("localAssetURLResolved", handleLocalAssetURLResolved);
    window.addEventListener("imageViewAssetURLResolved", handleImageViewAssetURLResolved);
    postToNative({ type: "ready", protocolVersion });
    return () => {
      window.removeEventListener("userAssetURLResolved", handleAssetURLResolved);
      window.removeEventListener("localAssetURLResolved", handleLocalAssetURLResolved);
      window.removeEventListener("imageViewAssetURLResolved", handleImageViewAssetURLResolved);
      stopViewportController();
      clearLocalAssetURLs();
      clearImageViewAssetURLs();
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
      // An activation after capture owns focus/selection as well as scroll.
      // Never restore the previous group's focus over a newer user choice.
      if (restoration.viewport.interactionEpoch === viewportController.diagnostics().interactionEpoch) {
        restoreSelection(restoration.selection);
        restoreFocusedElement(restoration.focusID);
      }
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

  useEffect(() => {
    // Apply any already-resolved asset URLs to <img> elements that appear
    // after the CustomEvent has already fired (e.g. React re-rendering).
    const assetObserver = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (!(node instanceof HTMLElement)) continue;
          const imgs = node.tagName === "IMG" && node.dataset.assetId
            ? [node as HTMLImageElement]
            : node.querySelectorAll<HTMLImageElement>("img[data-asset-id]");
          for (const img of imgs) {
            const id = Number(img.dataset.assetId);
            const url = pendingAssetURLs.get(id);
            if (url && url !== "") {
              console.log("[AgentKit] MutationObserver: applying cached URL for assetID =", id);
              img.src = url;
            }
          }
        }
      }
    });
    assetObserver.observe(document.body, { childList: true, subtree: true });

    const hideTasks = new Map<HTMLElement, number>();
    const revealHorizontalScrollbar = (event: Event) => {
      const target = event.target instanceof HTMLElement
        ? event.target.closest<HTMLElement>(".overflow-frame")
        : null;
      if (!target || target.scrollWidth <= target.clientWidth + 1) return;
      target.classList.add("is-horizontal-scrolling");
      const previous = hideTasks.get(target);
      if (previous !== undefined) window.clearTimeout(previous);
      hideTasks.set(target, window.setTimeout(() => {
        target.classList.remove("is-horizontal-scrolling");
        hideTasks.delete(target);
      }, 650));
    };
    document.addEventListener("scroll", revealHorizontalScrollbar, true);
    return () => {
      assetObserver.disconnect();
      document.removeEventListener("scroll", revealHorizontalScrollbar, true);
      hideTasks.forEach((task) => window.clearTimeout(task));
    };
  }, []);

  if (!conversation) {
    return <main className="conversation-shell" aria-label="Conversation" aria-busy="true" />;
  }

  return (
    <main className="conversation-shell" aria-label="Conversation">
      {conversation.turns.map((turn) => (
        <Turn
          key={turn.id}
          turn={turn}
          conversationID={conversation.conversationID}
        />
      ))}
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
      {conversation.live?.modelRetrying ? (
        <RetryBanner retry={conversation.live.modelRetrying} />
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
