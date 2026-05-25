# Web UI Improvements — Design Spec
Date: 2026-05-25  
Scope: `web/static/app.js`, `web/static/index.html`, `web/static/i18n.js`

---

## Overview

Ten improvements to the local Qwen chat UI (port 8090), split into high / medium / low priority. All changes are confined to the three frontend files; no backend changes required except for vision (which uses the existing llama.cpp OpenAI-compatible pass-through proxy).

---

## A. Markdown Rendering — Local Safe Renderer + Code Copy Button

**Problem:** Markdown rendering needs to support the common chat output shapes without depending on external network availability or allowing untrusted HTML into the DOM.

**Solution:**
- Do not load Markdown code from a CDN. The UI must work offline and must not depend on `cdn.jsdelivr`.
- Keep rendering local in `app.js`.
- Escape raw HTML before inserting rendered output into `innerHTML`.
- Support the common subset used in chat: fenced code blocks, inline code, headings, horizontal rules, unordered lists, blockquotes, emphasis, bold, and safe `http(s)` / `mailto` links.
- After every `bubble.innerHTML = renderMd(...)` call, run `injectCodeCopyButtons(bubble)` — a helper that finds all `<pre><code>` elements and prepends an absolutely-positioned "Copy" button (reusing `copyText()`).

**CSS:** `.copy-code-btn` — small pill button, absolute top-right of `<pre>`, initially opacity 0, shown on `pre:hover`.

---

## B. Vision Image Upload

**Trigger:** Only shown (and enabled) when `app.serverState?.server === 'running' && app.serverState?.current?.profile === 'vision'`.

**UI:** A 📎 button to the left of `#inp` textarea. Hidden by default via `display:none`; toggled in `renderControls()`.

**Flow:**
1. Click 📎 → hidden `<input id="img-attach" type="file" accept="image/*">` fires.
2. Non-image files are rejected. Images larger than 3 MB are rejected before reading to avoid localStorage quota failures.
3. Selected file read as base64 data URL (`FileReader.readAsDataURL`).
4. Preview thumbnail + ✕ clear button appears above `#inp` in a `#img-preview` div.
5. `app.pendingImage = { dataUrl, mimeType }` stored in app state.
6. On send: if `app.pendingImage` is set, replace the `content` string with an array:
   ```json
   [
     { "type": "image_url", "image_url": { "url": "<dataUrl>" } },
     { "type": "text", "text": "<user text>" }
   ]
   ```
6. `chatHistory` stores `{ role:"user", content:[...] }` with the array format.
7. `renderHistory` checks if `m.content` is an array; if so, renders the image inline (max-width 280px) above the text bubble.
8. Image cleared (`app.pendingImage = null`, preview hidden) after send.

**i18n keys added:** `attach_image`, `remove_image`.

---

## C. Gear Panel — System Prompt + Settings

**UI:** ⚙ button pinned to the bottom of `#sidebar` (below `#conv-list`), above the sidebar's bottom edge.

**Panel:** Absolute-positioned popover anchored to the gear button, expanding upward. Same pattern as `#compress-panel`.

**Contents:**
1. **System Prompt** — `<textarea id="sys-prompt-inp" rows="4">`, placeholder from i18n. Saves on blur into `conv.system_prompt`.
2. **Model selector** — independent `<select id="gear-sel-model">`, populated from same `loadModels()` data. On each `pollState()` / `render()`, its value is set to match `sel-model` (header). Changing it does NOT auto-update the header; the Switch button does.
3. **Profile selector** — same pattern, `<select id="gear-sel-profile">`, kept in sync with `sel-profile` on each render.
4. **Switch button** — calls `handleSwitch()`.

**Data model:** `conv.system_prompt: string | null` added to conversation object. Loaded into textarea when switching conversations (`setActiveConversation`).

**Request injection:** In `sendMessage()`, when building the `messages` array for the API body, if `conv.system_prompt` is non-empty prepend `{ role:"system", content: conv.system_prompt }`. This is **not** stored in `chatHistory`.

**i18n keys added:** `sys_prompt_label`, `sys_prompt_placeholder`, `btn_settings`.

---

## D. Context Warning

**Logic in `renderRuntime()`:**
- `pct >= 90` → set `app.contextWarnLevel = 'critical'`
- `pct >= 80` → set `app.contextWarnLevel = 'warn'`
- `pct < 80` → clear `app.contextWarnLevel`

**UI:** A dismissible banner `#context-warn` between the messages area and the edit-banner. Shows amber (warn) or red (critical) with text and a "Compress →" button that opens the compress panel. A small ✕ button sets `app.contextWarnDismissed = true` until `contextWarnLevel` drops back below 80 (auto-reset).

**i18n keys added:** `ctx_warn_80`, `ctx_warn_90`, `ctx_compress_cta`.

---

## E. Delete Branch / Conversation Tree

**UI:** A `✕` button appended to the `.branch-nav` div, shown only when `conv.parent_id !== null` (i.e., current conversation is a branch, not the root).

**Logic:**
1. `confirm()` dialog.
2. Delete the selected conversation and all descendants by walking `parent_id`.
3. If the active conversation was removed, switch to the preferred parent, otherwise the current active conversation, otherwise another root conversation. If none exists, create an empty chat.
4. `saveConversations()` + `renderSidebar()` + `renderDetailsPane()`.

Root conversations can be deleted. When a root is deleted, its hidden branch conversations are deleted too so no orphaned conversations remain in localStorage.

---

## F. Pause Polling When Tab Hidden

In `init()`, after the initial `setInterval(pollState, 2000)`:

```js
let pollTimer = setInterval(pollState, 2000);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { clearInterval(pollTimer); pollTimer = null; }
  else { pollState(); pollTimer = setInterval(pollState, 2000); }
});
```

The existing global `setInterval` call is replaced by this managed version.

---

## G. Markdown Export + Export All

Both options added to the existing `#side-menu` dropdown.

**Export MD (current conversation):**
- Format: `# {title}\n\n---\n\n## User\n\n{content}\n\n## Assistant\n\n{content}\n\n---\n\n...`
- Thinking blocks included as `> *Thinking:* ...` blockquote.
- Download as `chat-{date}.md`.

**Export All:**
- Wraps `{ conversations, exported_at: Date.now() }` as JSON.
- Download as `qwen-all-{date}.json`.
- The same file can be imported back through the normal Import flow. Imported conversation IDs are remapped to avoid collisions; parent-child branch links are preserved inside the imported set.
- Existing single-conversation export remains llama.cpp WebUI-compatible.

**i18n keys added:** `btn_export_md`, `btn_export_all`.

---

## H. Token Estimation

**UI:** Small muted text `#tok-est` right-aligned inside `#ftr`, between textarea and send button — or below textarea on its own line.

**Logic:**
- On every `input` event on `#inp`: `estimate = Math.ceil((historyCharCount + inp.value.length) / 4)`.
- `historyCharCount` = sum of all `m.content` string lengths in `chatHistory` (recomputed when `chatHistory` changes, cached in `app.historyCharCount`).
- Display: `~{N} tok` if N < 1000, else `~{N/1000 toFixed(1)}k tok`.
- Colored amber if > 16000, red if > 20000 (rough ctx-limit signal).

**i18n keys added:** `tok_est_label` (optional, may just be unitless `~{N} tok`).

---

## Files Changed

| File | Changes |
|------|---------|
| `index.html` | Add CSS for copy-code-btn, img-preview, gear panel, context-warn banner, fixed compress panel, tok-est; add HTML for img-attach input, img-preview div, gear button + panel, context-warn banner, tok-est span |
| `app.js` | Replace `renderMd` with a local safe renderer; add `injectCodeCopyButtons`; vision upload logic with size/type guard; gear panel show/hide + system prompt save/load; context warn logic; recursive conversation-tree deletion; visibility API polling; MD/all export + import-all support; token estimation; i18n updates |
| `i18n.js` | New keys for all three languages (EN/ZH/ZH-Hant) |

---

## Out of Scope

- Backend changes (app.py) — no modifications needed
- PWA / service worker
- Conversation folders / pinning
- Per-message temperature override
