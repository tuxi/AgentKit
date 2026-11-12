import React, {
  memo,
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
  ConversationWebImageViewAsset,
  ConversationWebOperation,
  ConversationWebPreview,
  ConversationWebUIEvidence,
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

function compactActivityText(value: string | undefined, limit = 120): string {
  const compact = (value ?? "")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/^[#>*_\s~-]+/gm, "")
    .replace(/\s+/g, " ")
    .trim();
  return compact.length > limit ? `${compact.slice(0, limit - 1)}…` : compact;
}

function streamingThought(block: ConversationWebBlock): ConversationWebBlock | undefined {
  return [...(block.activityThinking ?? [])]
    .reverse()
    .find((item) => item.status === "streaming");
}

function activityIcon(block: ConversationWebBlock): string {
  if (block.status === "failed" || block.tools.some((tool) => tool.status === "failed")) return "×";
  const icons = new Set(block.tools.map((tool) => tool.icon).filter(Boolean));
  for (const glyph of ["$", "±", "+", "□", "≡", "⌕"]) {
    if (icons.has(glyph)) return glyph;
  }
  const running = block.tools.find((tool) => tool.status === "running");
  if (running?.icon) return running.icon;
  if (streamingThought(block)) return "◇";
  if (block.isCollecting) return "◇";
  return "✓";
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
// Keep disclosure preferences on the turn, so moving its process blocks under
// the elapsed-time fold at completion does not discard their user state.
const TurnDisclosureContext = React.createContext<{
  scope: string;
  expanded: Record<string, boolean>;
  setExpanded: React.Dispatch<React.SetStateAction<Record<string, boolean>>>;
} | null>(null);

function useActivityDisclosure(
  disclosureID: string,
  defaultOpen = false,
): { open: boolean; onSummaryClick: (event: React.MouseEvent<HTMLElement>) => void } {
  const [localExpanded, setLocalExpanded] = useState<boolean | undefined>(undefined);
  const context = React.useContext(TurnDisclosureContext);
  const key = `${context?.scope}:${disclosureID}`;
  const preference = context ? context.expanded[key] : localExpanded;
  const open = preference ?? defaultOpen;
  const onSummaryClick = (event: React.MouseEvent<HTMLElement>) => {
    if (!window.getSelection()?.isCollapsed) {
      event.preventDefault();
      return;
    }
    event.preventDefault();
    if (context) context.setExpanded((values) => ({ ...values, [key]: !open }));
    else setLocalExpanded(!open);
  };
  return { open, onSummaryClick };
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
    let followTail = true;
    let lastScrollTop = container.scrollTop;
    const pinToBottom = () => {
      if (!followTail) return;
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

function ToolResultCard({ tool, outputRef }: {
  tool: ConversationWebTool;
  outputRef: (element: HTMLDivElement | null) => void;
}): React.JSX.Element | null {
  if (!tool.command && !tool.output && !tool.outcomeText) return null;
  return (
    <div className="tool-result-card" data-kind={tool.resultKind}>
      {tool.command || tool.output ? (
        <div ref={outputRef} className="overflow-frame tool-output-frame" data-scroll-id={`tool-output:${tool.id}`}>
          <div className="tool-result-content-body">
            {tool.command ? <>
              <div className="tool-card-caption">{tool.labels?.command}</div>
              <pre className="tool-command-text" data-scroll-id={`tool-command:${tool.id}`}>
                <code>{linkifiedActionText(tool.command, tool.commandActions ?? [])}</code>
              </pre>
            </> : null}
            {tool.output ? <pre><code>{linkifiedActionText(tool.output, tool.outputActions)}</code></pre> : null}
          </div>
        </div>
      ) : null}
      {tool.outcomeText || tool.copyOutputActionID ? (
        <div className="tool-result-footer">
          {tool.outcomeText ? <span className="tool-result-outcome" data-tone={tool.outcomeTone}>
            <span aria-hidden="true">{tool.outcomeTone === "completed" ? "✓" : tool.outcomeTone === "failed" ? "!" : "◷"}</span>
            {tool.outcomeText}
          </span> : null}
          {tool.copyOutputActionID ? <ActionButton actionID={tool.copyOutputActionID}
            focusID={`tool-output-copy:${tool.id}`} tooltip={tool.labels?.copyOutput}>
            {tool.labels?.copy}
          </ActionButton> : null}
        </div>
      ) : null}
    </div>
  );
}

function RawToolDetails({ tool }: { tool: ConversationWebTool }): React.JSX.Element {
  const { open, onSummaryClick } = useActivityDisclosure(`raw:${tool.id}`);
  return (
    <details className="tool-raw-details" open={open} data-disclosure-id={`tool-raw:${tool.id}`}>
      <summary onClick={onSummaryClick} data-focus-id={`tool-raw:${tool.id}`}>
        {tool.labels?.rawDetails ?? tool.rawName}
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      {open ? <>
        {tool.rawName ? <section><h4>{tool.labels?.tool}</h4><code>{tool.rawName}</code></section> : null}
        {tool.arguments ? <section>
          <h4>{tool.labels?.input}</h4>
          <div className="overflow-frame code-frame" data-scroll-id={`tool-input:${tool.id}`}>
            <pre><code>{linkifiedActionText(tool.arguments, tool.argumentActions)}</code></pre>
          </div>
        </section> : null}
      </> : null}
    </details>
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
  image: ConversationWebImageViewAsset;
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

function Tool({
  tool,
  conversationID,
  turnID,
}: {
  tool: ConversationWebTool;
  conversationID: string;
  turnID: string;
}): React.JSX.Element {
  const statusText = visibleExecutionStatus(tool.status, tool.statusText);
  const imageViewSource = tool.imageView?.assets.find((asset) => asset.role === "source");
  const evidenceSource = tool.uiEvidence?.assets.find((asset) => asset.role === "source");
  const structuredImageSource = imageViewSource ?? evidenceSource;
  // Tool rows stay compact by default, including while they run. The parent
  // group header communicates the current action without expanding detail.
  const { open, onSummaryClick } = useActivityDisclosure(`tool:${tool.id}`);
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
        onClick={onSummaryClick}
      >
        {structuredImageSource ? (
          <ImageViewPreview
            conversationID={conversationID}
            turnID={turnID}
            toolID={tool.id}
            image={structuredImageSource}
            variant="thumbnail"
          />
        ) : <ToolActionIcon glyph={tool.icon ?? "◇"} />}
        <span className="tool-title">{tool.name}</span>
        {tool.changeSummary ? <ChangeSummary value={tool.changeSummary} /> : null}
        {tool.detail ? <span className="tool-detail-summary">{tool.detail}</span> : null}
        {statusText ? (
          <span className="tool-status" data-tone={tool.status}>{statusText}</span>
        ) : null}
        {tool.elapsed ? <span className="tool-elapsed">{tool.elapsed}</span> : null}
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      {open ? <div className="tool-detail">
        {tool.imageView ? (
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
        ) : <>
          <ToolResultCard tool={tool} outputRef={setOutputFrame} />
          <RawToolDetails tool={tool} />
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
        {tool.imageView || tool.uiEvidence ? null : tool.assetActions.map((asset) => (
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

// ── Context-management chips & verification blocks (system blocks) ──

/** Doc emoji per context event; compacted must not reuse the prune icon. */
function contextChipIcon(kind: string | undefined): string {
  switch (kind) {
    case "contextEdited": return "🧹";
    case "contextPruned": return "✂️";
    case "contextCompact": return "📄";
    default: return "";
  }
}

/** Lightweight inline chip for context_edited / context_pruned / compacted. */
function ContextChip({ block }: { block: ConversationWebBlock }): React.JSX.Element {
  const ineffective = block.metadata?.ineffective === "true";
  return (
    <span
      className="context-chip"
      data-tone={ineffective ? "warning" : undefined}
      title={block.text}
    >
      <span aria-hidden="true">{contextChipIcon(block.systemKind)}</span>{" "}
      {block.text}
      {ineffective ? <span className="context-chip-flag">压缩无效</span> : null}
    </span>
  );
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
  const { open, onSummaryClick } = useActivityDisclosure(`thinking:${block.id}`);
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
        className="thinking-summary"
        data-focus-id={`thinking:${block.id}`}
        onClick={onSummaryClick}
      >
        <ToolActionIcon glyph="◇" />
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

function ToolGroupBlock({
  block,
  conversationID,
  turnID,
}: {
  block: ConversationWebBlock;
  conversationID: string;
  turnID: string;
}): React.JSX.Element {
  // Expanded live groups describe the whole activity. Collapsed live groups
  // mirror the current action, including a one-line thinking preview.
  const { open, onSummaryClick } = useActivityDisclosure(`group:${block.id}`);
  const [groupScroll, setGroupScroll] = useState<HTMLDivElement | null>(null);
  useTailFollow(groupScroll, !!block.isCollecting && open);
  const tools = new Map(block.tools.map((tool) => [`tool:${tool.id}`, tool]));
  const thinking = new Map((block.activityThinking ?? []).map((item) => [`thinking:${item.id}`, item]));
  const activeThought = streamingThought(block);
  const thoughtPreview = compactActivityText(activeThought?.text);
  const currentTitle = activeThought
    ? [activeThought.title, thoughtPreview].filter(Boolean).join(" · ")
    : block.title;
  const stateTitle = block.activitySummary?.trim() || block.title;
  const headerTitle = block.isCollecting && !open ? currentTitle : stateTitle;
  const statusText = block.activityOrder ? undefined : visibleExecutionStatus(block.status, block.statusText);
  // Collapse only adjacent waits for the same explicit job_id. Narration,
  // thinking, other tools and activity boundaries keep their original order.
  const rows: Array<{ ids: string[]; jobID?: string }> = [];
  for (const id of block.activityOrder ?? block.tools.map((tool) => `tool:${tool.id}`)) {
    const tool = tools.get(id);
    const jobID = tool?.rawName === "job_wait" ? tool.backgroundJobID : undefined;
    const previous = rows.at(-1);
    if (jobID && previous?.jobID === jobID) previous.ids.push(id);
    else rows.push({ ids: [id], jobID });
  }
  const renderEntry = (id: string) => {
    const tool = tools.get(id);
    if (tool) return <Tool key={id} tool={tool} conversationID={conversationID} turnID={turnID} />;
    const thought = thinking.get(id);
    return thought ? <ThinkingBlock key={id} block={thought} /> : null;
  };
  return (
    <details
      className="tool-group"
      data-status={block.status}
      open={open}
    >
      <summary
        className="interactive tool-group-summary"
        data-focus-id={`tool-group:${block.id}`}
        onClick={onSummaryClick}
      >
        <ToolActionIcon glyph={activityIcon(block)} />
        <span className="tool-group-title" title={headerTitle}>{headerTitle}</span>
        {statusText ? (
          <span className="tool-status" data-tone={block.status}>{statusText}</span>
        ) : null}
        <span className="disclosure-chevron" aria-hidden="true">›</span>
      </summary>
      <div ref={setGroupScroll} className="tool-group-tools" tabIndex={open ? 0 : undefined} data-scroll-id={`tool-group:${block.id}`}>
        {open ? rows.map(({ ids }) => {
          if (ids.length === 1) return renderEntry(ids[0]);
          if (rows.length === 1) return <div key={ids[0]}>{ids.map(renderEntry)}</div>;
          const first = tools.get(ids[0])!;
          const waits = ids.map((id) => tools.get(id)!);
          const status = waits.some((tool) => tool.status === "failed") ? "failed"
            : waits.some((tool) => tool.status === "running") ? "running" : "completed";
          return <details className="job-wait-group" key={ids[0]}
            data-disclosure-id={`job-waits:${first.id}`} data-status={status}>
            <summary className="interactive tool-group-summary" data-focus-id={`job-waits:${first.id}`}>
              <ToolActionIcon glyph={first.icon ?? "◇"} />
              <span className="tool-group-title">{first.labels?.waitGroup?.replace("{count}", String(ids.length)) ?? `${first.name} · ${ids.length}`}</span>
              {first.detail ? <span className="tool-detail-summary">{first.detail}</span> : null}
              {status !== "completed" ? <span className="tool-status" data-tone={status}>{visibleExecutionStatus(status)}</span> : null}
              <span className="disclosure-chevron" aria-hidden="true">›</span>
            </summary>
            {ids.map(renderEntry)}
          </details>;
        }) : null}
      </div>
    </details>
  );
}

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

/// Standalone legacy errors stay outside the fold. Activity failures are
/// counted on the always-visible process header while the activity is folded.
function isFailureBlock(block: ConversationWebBlock): boolean {
  // Activity failures stay inside the group and are counted in the outer
  // process header, which remains visible while the whole process is folded.
  return !block.activityOrder && (block.status === "failed" || block.status === "cancelled");
}

/// L1 split: everything before the last non-empty answer block is "process",
/// the answer itself (plus trailing artifacts and any failures pulled forward)
/// stays visible. Live turns never split — Codex shows the work while it runs.
function splitTurnForDisplay(turn: ConversationWebTurn): {
  process: ConversationWebBlock[];
  answer: ConversationWebBlock[];
} {
  if (turn.isLive) {
    return { process: [], answer: turn.blocks };
  }

  let answerIndex = -1;
  for (let index = turn.blocks.length - 1; index >= 0; index -= 1) {
    const block = turn.blocks[index];
    if (block.kind === "markdown" && (block.text ?? "").trim().length > 0) {
      answerIndex = index;
      break;
    }
  }

  // Tool-only turn: fold the work, surfacing activity failures in the header
  // and keeping standalone legacy errors outside as before.
  if (answerIndex < 0) {
    return {
      process: turn.blocks.filter((block) => !isFailureBlock(block)),
      answer: turn.blocks.filter(isFailureBlock),
    };
  }

  const failures = turn.blocks.slice(0, answerIndex).filter(isFailureBlock);
  return {
    process: turn.blocks.slice(0, answerIndex).filter((block) => !isFailureBlock(block)),
    answer: [...failures, ...turn.blocks.slice(answerIndex)],
  };
}

/// The collapsed header: "用时 24分40秒". Once the server reports a turn
/// diffstat this becomes "用时 24分40秒 · 编辑 3 个文件".
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
  if (turn.trajectoryActionID) {
    menuItems.push({
      key: "trajectory",
      label: "查看轨迹",
      value: "›",
      actionID: turn.trajectoryActionID,
      focusID: `turn-trajectory:${turn.id}`,
    });
  }
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
  const [expandedDisclosures, setExpandedDisclosures] = useState<Record<string, boolean>>({});
  const disclosureContext = React.useMemo(() => ({
    scope: conversationID,
    expanded: expandedDisclosures,
    setExpanded: setExpandedDisclosures,
  }), [conversationID, expandedDisclosures]);
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

  // L1 (Codex-aligned): a finished turn shows its final answer; the work that
  // produced it folds into one "用时 …" disclosure. Nothing is ever hidden
  // while the turn is still streaming.
  const { process, answer } = splitTurnForDisplay(turn);
  const failedProcessCalls = process.reduce((count, block) =>
    count + block.tools.filter((tool) => tool.status === "failed").length, 0);
  const previews = turn.previews ?? [];

  const renderBlocks = (blocks: ConversationWebBlock[]) =>
    blocks.map((block) => (
      <div
        className="turn-block"
        data-block-id={block.id}
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
      {turn.userAssets.length > 0 ? (
        <div
          className="user-asset-strip"
          data-scroll-id={`user-assets:${turn.id}`}
        >
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
        </div>
      ) : null}
      {localAssets.length > 0 ? (
        <div className="local-asset-group">
          <div className="local-asset-privacy-label">
            <span aria-hidden="true">🔒</span>
            <span>本地处理 · 文件不会自动上传</span>
          </div>
          <div className="user-asset-strip" data-scroll-id={`local-assets:${turn.id}`}>
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
          </div>
        </div>
      ) : null}
      {turn.userPrompt ? (
        <CollapsibleUserPrompt turnID={turn.id} text={turn.userPrompt} />
      ) : null}
      <TurnDisclosureContext.Provider value={disclosureContext}>
      <div className="assistant-lane">
        {turn.isLive ? (
          <>
            <LiveTurnHeader startedAtMilliseconds={turn.startedAtMilliseconds} />
            {renderBlocks(turn.blocks)}
            {previewNodes}
            {todoNode}
          </>
        ) : (
          <>
            {process.length || todoNode ? (
              <details
                className="turn-process"
                data-disclosure-id={`turn-process:${turn.id}`}
              >
                <summary
                  className="interactive turn-process-summary"
                  data-focus-id={`turn-process:${turn.id}`}
                >
                  <span className="turn-process-label">{processSummaryLabel(turn)}</span>
                  {failedProcessCalls > 0 ? <span className="tool-status" data-tone="failed">{turn.processFailureText ?? String(failedProcessCalls)}</span> : null}
                  <span className="disclosure-chevron" aria-hidden="true">›</span>
                </summary>
                <div className="turn-process-body">
                  {renderBlocks(process)}
                  {todoNode}
                </div>
              </details>
            ) : (turn.elapsedText || turn.changes?.summary || (turn.changes?.filesChanged ?? 0) > 0) ? (
              <div className="turn-process-summary">
                <span className="turn-process-label">{processSummaryLabel(turn)}</span>
              </div>
            ) : null}
            {renderBlocks(answer)}
            {turn.changes ? (
              <TurnChangesCard turnID={turn.id} changes={turn.changes} />
            ) : null}
            {previewNodes}
            <TurnActionsBar turn={turn} />
          </>
        )}
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
