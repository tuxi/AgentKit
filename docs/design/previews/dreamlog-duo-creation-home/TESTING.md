# DreamLog Duo Preview Manual Test

Status: accepted test plan for packaged CodeAgent + Talkify integration.

Use the canonical file:

`docs/design/previews/dreamlog-duo-creation-home/current.html`

Do not modify it during the first integration test.

## 1. Direct HTML smoke test

Open `current.html` in a desktop browser first. This isolates the preview document
from the CodeAgent/AgentKit integration.

1. Confirm the three controls work: `外屏`, `内屏竖向`, `内屏横向`.
2. Resize the browser content area to roughly 500px wide.
3. In `内屏横向`, confirm hero and workspace remain side by side.
4. Resize to roughly 900px wide and repeat.
5. Confirm there is no large empty gap below the device stage.
6. Click the recent-project and tool entries; the local feedback banner should
   appear without network activity.

Expected: all controls work, wide remains two-column at 500px, and the stage
height follows the scaled device.

## 2. Talkify integration test

1. Start the newly packaged `codeagentd`.
2. Launch the newly packaged Talkify app and connect it to that runtime.
3. Open a conversation whose workspace is the AgentKit repository.
4. Send this prompt:

```text
不要修改任何文件。请使用 interactive HTML preview 能力，把
docs/design/previews/dreamlog-duo-creation-home/current.html
作为一个 conversation_inline 预览展示出来。

标题：DreamLog Duo Creation Home
preferred_aspect_ratio: 1.78
min_height: 420
```

5. Confirm a generic `DreamLog Duo Creation Home` preview card appears in the
   conversation.
6. Open the card and verify the three forms work inside Talkify.
7. Resize the Talkify conversation pane to approximately 500px and 900px.
8. Confirm `内屏横向` stays two-column at both widths.
9. Close and reopen the conversation. Confirm the preview is restored from
   replay.
10. Restart Talkify and reopen the same conversation once to test cold replay.

## 3. Security checks

During the preview test, confirm:

- No remote resource or navigation is permitted.
- No preview action mutates the conversation or triggers an approval.
- The preview cannot access local files or the host bridge.
- Closing or failing the preview does not execute content in the main
  ConversationWorkbench document.

## 4. Failure classification

Record the first failing boundary:

| Symptom | Likely boundary | Capture |
| --- | --- | --- |
| No preview card | runtime capability or artifact emission | prompt, runtime logs, negotiated capabilities |
| Card exists but never becomes ready | viewer resolution/HTTP route | card state, runtime request log, HTTP status |
| Viewer is blank | viewer bytes, CSP, or isolated WebKit load | screenshot, Talkify console/log, viewer SHA |
| Buttons do not work | preview iframe scripts or sandbox policy | screenshot, console error, tested button |
| Wide collapses to one column | wrong/stale HTML document | viewer SHA-256, screenshot at 500px |
| Preview disappears after reopen | replay/persistence | conversation ID, runtime event log, reopen screenshot |
| Host UI freezes or crashes | bridge isolation or WebKit lifecycle | crash log, reproduction steps, elapsed time |

## 5. Feedback template

```text
Build/version:
Runtime version:
Talkify version:
Conversation ID:
Prompt used:
Preview card appeared: yes/no
Preview opened: yes/no
Outer / portrait / landscape: pass/fail
500px wide two-column: pass/fail
900px wide two-column: pass/fail
Close/reopen replay: pass/fail
Cold replay after restart: pass/fail
Console/runtime errors:
Screenshots:
Notes:
```

Technical HTML validation is not product acceptance. Product status changes only
after this test and review.
