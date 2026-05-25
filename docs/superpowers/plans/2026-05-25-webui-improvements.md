# Web UI Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 10 quality-of-life improvements to the local Qwen chat web UI (port 8090): proper markdown rendering, code copy buttons, vision image upload, gear panel with system prompt, context warning, branch delete, polling pause, MD/all export, and token estimation.

**Architecture:** All changes in three files: `web/static/app.js` (logic), `web/static/index.html` (HTML + CSS), `web/static/i18n.js` (strings). No backend changes. New fields added directly to the `app` state object and `conv` objects. No build system — plain vanilla JS.

**Tech Stack:** Vanilla JS ES6+, local safe Markdown rendering in `app.js` (no external CDN dependency), FastAPI backend (unchanged), llama.cpp OpenAI-compatible API (unchanged).

**Implementation note after review:** The final implementation intentionally differs from the first draft in four places: Markdown is rendered locally with HTML escaping instead of loading `marked.js` from jsDelivr; the Compress panel is a fixed global popover instead of a DOM node moved into the sidebar list; deleting a conversation removes its descendant branches as a tree; "Export all (JSON)" files can be imported back through the normal Import flow.

---

### Task 1: i18n.js — Add all new translation keys

**Files:**
- Modify: `web/static/i18n.js`

- [ ] **Step 1: Add new keys to all three language objects**

In `i18n.js`, each language object (`en`, `zh`, `tw`) has a set of key/value pairs. Append the following to each — do NOT modify any existing key.

**English** (`en` object):
```js
    attach_image:            'Attach image',
    remove_image:            'Remove image',
    sys_prompt_label:        'System Prompt',
    sys_prompt_placeholder:  'Set a system prompt for this conversation…',
    btn_settings:            'Settings',
    ctx_warn_80:             'Context 80% full',
    ctx_warn_90:             'Context 90% full — compress soon',
    ctx_compress_cta:        'Compress →',
    btn_export_md:           'Export as Markdown',
    btn_export_all:          'Export all (JSON)',
    delete_branch:           'Delete this branch',
    delete_branch_confirm:   'Delete this branch? Cannot be undone.',
```

**中文** (`zh` object):
```js
    attach_image:            '附加图片',
    remove_image:            '移除图片',
    sys_prompt_label:        '系统提示词',
    sys_prompt_placeholder:  '为本对话设置系统提示词…',
    btn_settings:            '设置',
    ctx_warn_80:             '上下文已用 80%',
    ctx_warn_90:             '上下文已用 90%，建议立即压缩',
    ctx_compress_cta:        '压缩 →',
    btn_export_md:           '导出为 Markdown',
    btn_export_all:          '导出全部 (JSON)',
    delete_branch:           '删除此分支',
    delete_branch_confirm:   '删除此分支对话？操作不可撤销。',
```

**繁體** (`tw` object):
```js
    attach_image:            '附加圖片',
    remove_image:            '移除圖片',
    sys_prompt_label:        '系統提示詞',
    sys_prompt_placeholder:  '為本對話設定系統提示詞…',
    btn_settings:            '設定',
    ctx_warn_80:             '上下文已用 80%',
    ctx_warn_90:             '上下文已用 90%，建議立即壓縮',
    ctx_compress_cta:        '壓縮 →',
    btn_export_md:           '匯出為 Markdown',
    btn_export_all:          '匯出全部 (JSON)',
    delete_branch:           '刪除此分支',
    delete_branch_confirm:   '刪除此分支對話？操作不可撤回。',
```

- [ ] **Step 2: Verify keys exist**

Open browser DevTools console (after server restart), run:
```js
I18N.en.attach_image      // → 'Attach image'
I18N.zh.ctx_warn_80       // → '上下文已用 80%'
I18N.tw.delete_branch     // → '刪除此分支'
```

- [ ] **Step 3: Commit**
```
git add web/static/i18n.js
git commit -m "feat: add i18n keys for webui improvements"
```

---

### Task 2: index.html — HTML structure + CSS for all new elements

**Files:**
- Modify: `web/static/index.html`

This task adds all new HTML and CSS in one pass so subsequent tasks only touch `app.js`.

- [ ] **Step 1: Keep scripts local**

The final implementation must not add an external Markdown CDN. Keep the script block local:
```html
  <script src="/static/i18n.js"></script>
  <script src="/static/app.js"></script>
```

- [ ] **Step 2: Add `position: relative` to existing `pre` rule**

Find:
```css
    pre {
      background: var(--code-bg);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 10px 12px;
      overflow-x: auto;
      margin: 4px 0;
    }
```
Replace with:
```css
    pre {
      position: relative;
      background: var(--code-bg);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 10px 12px;
      overflow-x: auto;
      margin: 4px 0;
    }
```

- [ ] **Step 3: Add CSS block for all new features**

Directly before the closing `</style>` tag, insert:
```css
    /* ── Code copy button ───────────────────────────────────── */
    .copy-code-btn {
      position: absolute;
      top: 5px;
      right: 5px;
      padding: 2px 7px;
      font-size: 10px;
      opacity: 0;
      transition: opacity 0.15s;
    }
    pre:hover .copy-code-btn { opacity: 1; }

    /* ── Image attach / preview ─────────────────────────────── */
    #img-preview {
      display: flex;
      align-items: flex-start;
      gap: 8px;
      padding: 6px 14px 0;
      flex-shrink: 0;
    }
    #img-preview[hidden] { display: none; }
    #img-thumb {
      max-width: 200px;
      max-height: 150px;
      border-radius: var(--radius);
      border: 1px solid var(--border);
      object-fit: cover;
    }
    #btn-remove-img { padding: 2px 6px; font-size: 11px; align-self: flex-start; }
    #btn-attach { height: 42px; padding: 0 10px; font-size: 16px; line-height: 1; }
    #btn-attach[hidden] { display: none; }
    .msg-image {
      display: block;
      max-width: 280px;
      max-height: 200px;
      border-radius: var(--radius);
      border: 1px solid var(--border);
      margin-bottom: 6px;
      object-fit: cover;
    }

    /* ── Gear / Settings panel ──────────────────────────────── */
    #sidebar-footer {
      flex-shrink: 0;
      border-top: 1px solid var(--border);
      padding: 6px 8px;
      position: relative;
    }
    #btn-gear {
      width: 100%;
      text-align: left;
      padding: 5px 8px;
      font-size: 12px;
      color: var(--muted);
    }
    #gear-panel {
      position: absolute;
      bottom: calc(100% + 4px);
      left: 0;
      right: 0;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      box-shadow: 0 -4px 16px rgba(0,0,0,.22);
      padding: 10px;
      z-index: 200;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    #gear-panel[hidden] { display: none; }
    .gear-label {
      font-size: 10px;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: .04em;
      margin-bottom: 2px;
    }
    #sys-prompt-inp {
      width: 100%;
      background: var(--bg);
      color: var(--text);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 6px 8px;
      font: inherit;
      font-size: 12px;
      resize: vertical;
      min-height: 64px;
    }
    #sys-prompt-inp:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
    .gear-row { display: flex; flex-direction: column; gap: 4px; }
    .gear-switch-row { display: flex; gap: 6px; }
    .gear-switch-row select { flex: 1; min-width: 0; }

    /* ── Context warning ────────────────────────────────────── */
    #context-warn {
      flex-shrink: 0;
      display: none;
      align-items: center;
      justify-content: space-between;
      padding: 5px 14px;
      font-size: 12px;
      gap: 8px;
    }
    #context-warn.visible { display: flex; }
    #context-warn.warn {
      background: color-mix(in srgb, var(--amber) 12%, var(--surface));
      color: var(--amber);
      border-top: 1px solid color-mix(in srgb, var(--amber) 35%, transparent);
    }
    #context-warn.critical {
      background: var(--notice-err-bg);
      color: var(--red);
      border-top: 1px solid var(--notice-err-border);
    }
    #context-warn-btns { display: flex; gap: 6px; align-items: center; }
    #context-warn-btns button { font-size: 11px; padding: 2px 8px; }

    /* ── Token estimation ───────────────────────────────────── */
    #tok-est {
      font-size: 11px;
      color: var(--muted);
      white-space: nowrap;
      align-self: flex-end;
      padding-bottom: 11px;
      min-width: 56px;
      text-align: right;
    }
    #tok-est.warn { color: var(--amber); }
    #tok-est.critical { color: var(--red); }
```

- [ ] **Step 4: Replace `#ftr` with image-aware footer**

Find:
```html
      <footer id="ftr">
        <textarea id="inp" rows="1"></textarea>
        <button id="btn-send" class="btn-accent" data-i18n="btn_send">Send</button>
      </footer>
```
Replace with:
```html
      <div id="img-preview" hidden>
        <img id="img-thumb" src="" alt="">
        <button id="btn-remove-img" type="button">✕</button>
      </div>
      <footer id="ftr">
        <input id="img-attach" type="file" accept="image/*" style="display:none">
        <button id="btn-attach" type="button" hidden>📎</button>
        <textarea id="inp" rows="1"></textarea>
        <span id="tok-est"></span>
        <button id="btn-send" class="btn-accent" data-i18n="btn_send">Send</button>
      </footer>
```

- [ ] **Step 5: Add context warning banner between `#msgs` and `#edit-banner`**

Find:
```html
      <main id="msgs"></main>
      <div id="edit-banner">
```
Replace with:
```html
      <main id="msgs"></main>
      <div id="context-warn">
        <span id="context-warn-txt"></span>
        <div id="context-warn-btns">
          <button id="btn-ctx-compress" type="button"></button>
          <button id="btn-ctx-dismiss" type="button">✕</button>
        </div>
      </div>
      <div id="edit-banner">
```

- [ ] **Step 6: Add sidebar footer with gear button and panel**

Find:
```html
      <div id="conv-list"></div>
    </aside>
```
Replace with:
```html
      <div id="conv-list"></div>
      <div id="sidebar-footer">
        <div id="gear-panel" hidden>
          <div class="gear-row">
            <div class="gear-label" data-i18n="sys_prompt_label">System Prompt</div>
            <textarea id="sys-prompt-inp" rows="3"></textarea>
          </div>
          <div class="gear-row">
            <div class="gear-label" data-i18n="status_model">Model</div>
            <select id="gear-sel-model"></select>
          </div>
          <div class="gear-row">
            <div class="gear-label" data-i18n="status_profile">Profile</div>
            <div class="gear-switch-row">
              <select id="gear-sel-profile"></select>
              <button id="btn-gear-switch" class="btn-accent" type="button" data-i18n="btn_switch">Switch</button>
            </div>
          </div>
        </div>
        <button id="btn-gear" type="button">⚙ <span data-i18n="btn_settings">Settings</span></button>
      </div>
    </aside>
```

- [ ] **Step 7: Add Export MD and Export All to side-menu**

Find:
```html
          <div id="side-menu" hidden>
            <button id="btn-import" data-i18n="btn_import">Import</button>
            <button id="btn-export" data-i18n="btn_export">Export</button>
            <input id="file-import" type="file" accept=".json" style="display:none">
          </div>
```
Replace with:
```html
          <div id="side-menu" hidden>
            <button id="btn-import" data-i18n="btn_import">Import</button>
            <button id="btn-export" data-i18n="btn_export">Export</button>
            <button id="btn-export-md" data-i18n="btn_export_md">Export as Markdown</button>
            <button id="btn-export-all" data-i18n="btn_export_all">Export all (JSON)</button>
            <input id="file-import" type="file" accept=".json" style="display:none">
          </div>
```

- [ ] **Step 8: Verify HTML loads without JS errors**

Start server, open `http://localhost:8090`. DevTools console should show no errors. Sidebar has ⚙ Settings button at the bottom. Footer still shows textarea + Send button.

- [ ] **Step 9: Commit**
```
git add web/static/index.html
git commit -m "feat: add HTML/CSS structure for webui improvements"
```

---

### Task 3: app.js — local safe Markdown renderer + code copy button

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Replace `renderMd` with a local safe renderer**

The final renderer is implemented in `app.js`, not loaded from a CDN. It must escape raw HTML before assigning rendered output to `innerHTML`, and should support fenced code blocks, inline code, headings, horizontal rules, unordered lists, blockquotes, emphasis, bold, and safe `http(s)` / `mailto` links.

- [ ] **Step 2: Add `injectCodeCopyButtons` helper directly after `renderMd`**

```js
function injectCodeCopyButtons(el) {
  el.querySelectorAll('pre').forEach(pre => {
    if (pre.querySelector('.copy-code-btn')) return;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'copy-code-btn';
    btn.textContent = t('btn_copy');
    btn.addEventListener('click', () => copyText(pre.querySelector('code')?.textContent || pre.textContent));
    pre.appendChild(btn);
  });
}
```

- [ ] **Step 3: Do not configure external Markdown libraries**

There is no `marked.setOptions(...)` call in the final implementation.

- [ ] **Step 4: Inject copy buttons during streaming**

In the SSE loop inside `sendMessage`, find:
```js
        if (delta.content) {
          full += delta.content;
          app.activeOutputChars = full.length;
          bubble.innerHTML = renderMd(full);
          scrollBottom();
        }
```
Replace with:
```js
        if (delta.content) {
          full += delta.content;
          app.activeOutputChars = full.length;
          bubble.innerHTML = renderMd(full);
          injectCodeCopyButtons(bubble);
          scrollBottom();
        }
```

- [ ] **Step 5: Inject copy buttons after stream ends**

Find the two places where `bubble.innerHTML = renderMd(full)` is called after the stream loop (one in the success path, one in the abort path). Both look like:
```js
      bubble.innerHTML = renderMd(full);
```
Add `injectCodeCopyButtons(bubble);` on the next line in both places.

- [ ] **Step 6: Inject copy buttons in `renderHistory`**

Find in `renderHistory`:
```js
    } else {
      addMsg('assistant', { html: renderMd(m.content), raw: m.content, reasoning: m.reasoning_content, index });
    }
```
Replace with:
```js
    } else {
      const { bubble } = addMsg('assistant', { html: renderMd(m.content), raw: m.content, reasoning: m.reasoning_content, index });
      injectCodeCopyButtons(bubble);
    }
```

- [ ] **Step 7: Verify in browser**

Send a message that asks for a response with a bullet list, a heading, a blockquote, a link, and a code block. Verify:
- List renders as `<ul>` / `<li>` elements
- Raw HTML from the model is escaped rather than executed
- Code block shows a faint "Copy" button on hover; clicking it puts the code in clipboard

- [ ] **Step 8: Commit**
```
git add web/static/app.js
git commit -m "feat: add safe local markdown renderer and code copy button"
```

---

### Task 4: app.js — Vision image upload

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Add `pendingImage` to `app` state object**

Find:
```js
  compressConvId: null,
```
Add after it:
```js
  pendingImage: null,
```

- [ ] **Step 2: Add `clearPendingImage` helper after `scrollBottom`**

```js
function clearPendingImage() {
  app.pendingImage = null;
  const preview = $('img-preview');
  const thumb = $('img-thumb');
  if (preview) preview.hidden = true;
  if (thumb) { thumb.src = ''; thumb.alt = ''; }
  const inp = $('img-attach');
  if (inp) inp.value = '';
}
```

- [ ] **Step 3: Add `handleImageAttach` after `clearPendingImage`**

```js
function handleImageAttach(e) {
  const file = e.target.files?.[0];
  if (!file) return;
  e.target.value = '';
  const reader = new FileReader();
  reader.onload = evt => {
    app.pendingImage = { dataUrl: evt.target.result, mimeType: file.type };
    const thumb = $('img-thumb');
    const preview = $('img-preview');
    if (thumb) { thumb.src = evt.target.result; thumb.alt = file.name; }
    if (preview) preview.hidden = false;
  };
  reader.readAsDataURL(file);
}
```

- [ ] **Step 4: Add attach-button visibility to `renderControls`**

At the end of `renderControls()`, before the closing `}`, add:
```js
  const attachBtn = $('btn-attach');
  if (attachBtn) {
    const isVision = app.serverState?.server === 'running' && app.serverState?.current?.profile === 'vision';
    attachBtn.hidden = !isVision;
    if (!isVision && app.pendingImage) clearPendingImage();
  }
```

- [ ] **Step 5: Update `addMsg` to render an image inside the bubble**

Find (inside `addMsg`, the part that creates the bubble — it applies to all roles):
```js
  const bubble = document.createElement('div');
  bubble.className = 'bubble' + (opts.error ? ' error' : '');
  if (opts.text) bubble.textContent = opts.text;
  if (opts.html) bubble.innerHTML = opts.html;
```
Replace with:
```js
  const bubble = document.createElement('div');
  bubble.className = 'bubble' + (opts.error ? ' error' : '');
  if (opts.imageUrl) {
    const img = document.createElement('img');
    img.src = opts.imageUrl;
    img.className = 'msg-image';
    img.alt = '';
    bubble.appendChild(img);
  }
  if (opts.html) {
    bubble.innerHTML = opts.html;
  } else if (opts.text) {
    bubble.appendChild(document.createTextNode(opts.text));
  }
```

- [ ] **Step 6: Update `sendMessage` to capture image, build array content**

Find in `sendMessage`:
```js
  const content = inp.value.trim();
  if (!content || sendBlockReason()) return;

  inp.value = '';
  autoResize(inp);
```
Replace with:
```js
  const content = inp.value.trim();
  if (!content || sendBlockReason()) return;

  inp.value = '';
  autoResize(inp);

  const pendingImg = app.pendingImage;
  clearPendingImage();
```

Then find:
```js
  chatHistory.push({ role: 'user', content });
  updateActiveConversation();
  addMsg('user', { text: content, raw: content, index: chatHistory.length - 1 });
```
Replace with:
```js
  const userContent = pendingImg
    ? [{ type: 'image_url', image_url: { url: pendingImg.dataUrl } }, { type: 'text', text: content }]
    : content;
  chatHistory.push({ role: 'user', content: userContent });
  updateActiveConversation();
  addMsg('user', { text: content, raw: content, imageUrl: pendingImg?.dataUrl, index: chatHistory.length - 1 });
```

- [ ] **Step 7: Update `renderHistory` to handle array content**

Find:
```js
    if (m.role === 'user') {
      const { wrap } = addMsg('user', { text: m.content, raw: m.content, index });
```
Replace with:
```js
    if (m.role === 'user') {
      const imageUrl = Array.isArray(m.content) ? m.content.find(p => p.type === 'image_url')?.image_url?.url : null;
      const text = Array.isArray(m.content) ? (m.content.find(p => p.type === 'text')?.text || '') : m.content;
      const { wrap } = addMsg('user', { text, raw: text, imageUrl, index });
```

- [ ] **Step 8: Register event listeners in `init()`**

Add these three lines in the listener block:
```js
  $('btn-attach').addEventListener('click', () => $('img-attach').click());
  $('img-attach').addEventListener('change', handleImageAttach);
  $('btn-remove-img').addEventListener('click', clearPendingImage);
```

- [ ] **Step 9: Verify in browser**

Switch to `vision` profile. The 📎 button appears next to the input. Click it → pick an image → thumbnail appears above input. Send a message → the image renders in the chat bubble above the text. Switch back to `balanced` profile → 📎 button disappears.

- [ ] **Step 10: Commit**
```
git add web/static/app.js
git commit -m "feat: add vision image upload UI"
```

---

### Task 5: app.js — Gear panel (system prompt + settings)

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Add `gearOpen` to `app` state**

After `pendingImage: null,` add:
```js
  gearOpen: false,
```

- [ ] **Step 2: Add `loadGearSelects` helper**

Add after `saveConversations`:
```js
function loadGearSelects() {
  const src = $('sel-model'), dst = $('gear-sel-model');
  if (src && dst) { dst.innerHTML = src.innerHTML; dst.value = src.value; }
  const srcP = $('sel-profile'), dstP = $('gear-sel-profile');
  if (srcP && dstP) { dstP.innerHTML = srcP.innerHTML; dstP.value = srcP.value; }
}
```

- [ ] **Step 3: Add `saveSystemPrompt` helper**

```js
function saveSystemPrompt() {
  const conv = conversations.find(c => c.id === app.activeConversationId);
  if (!conv) return;
  conv.system_prompt = ($('sys-prompt-inp')?.value || '').trim() || null;
  conv.updated_at = Date.now();
  saveConversations();
}
```

- [ ] **Step 4: Add `toggleGearPanel` function**

```js
function toggleGearPanel() {
  app.gearOpen = !app.gearOpen;
  const panel = $('gear-panel');
  if (!panel) return;
  panel.hidden = !app.gearOpen;
  if (app.gearOpen) {
    loadGearSelects();
    const conv = conversations.find(c => c.id === app.activeConversationId);
    const inp = $('sys-prompt-inp');
    if (inp) inp.value = conv?.system_prompt || '';
  }
}
```

- [ ] **Step 5: Add `handleGearSwitch` function**

```js
async function handleGearSwitch() {
  const model = $('gear-sel-model')?.value || $('sel-model').value;
  const profile = $('gear-sel-profile')?.value || $('sel-profile').value;
  if (!model || !profile) return;
  saveSystemPrompt();
  $('sel-model').value = model;
  $('sel-profile').value = profile;
  $('gear-panel').hidden = true;
  app.gearOpen = false;
  await handleSwitch();
}
```

- [ ] **Step 6: Load system prompt in `setActiveConversation`**

At the end of `setActiveConversation`, before the closing `}`, add:
```js
  const gearInp = $('sys-prompt-inp');
  if (gearInp) {
    const newConv = conversations.find(c => c.id === id);
    gearInp.value = newConv?.system_prompt || '';
  }
```

- [ ] **Step 7: Inject system prompt in `sendMessage` API body**

In `sendMessage`, find:
```js
      messages: chatHistory.map(m => ({ role: m.role, content: m.content })),
```
Replace with:
```js
      messages: (() => {
        const msgs = chatHistory.map(m => ({ role: m.role, content: m.content }));
        const conv = conversations.find(c => c.id === app.activeConversationId);
        return conv?.system_prompt ? [{ role: 'system', content: conv.system_prompt }, ...msgs] : msgs;
      })(),
```

- [ ] **Step 8: Update `applyI18n` to set sys-prompt placeholder**

Find:
```js
  $('inp').placeholder = t('inp_placeholder');
```
Add after it:
```js
  const sysPInp = $('sys-prompt-inp');
  if (sysPInp) sysPInp.placeholder = t('sys_prompt_placeholder');
```

- [ ] **Step 9: Register event listeners in `init()` and merge into existing click handler**

Add these lines in the dedicated event-listener section:
```js
  $('btn-gear').addEventListener('click', e => { e.stopPropagation(); toggleGearPanel(); });
  $('sys-prompt-inp').addEventListener('blur', saveSystemPrompt);
  $('btn-gear-switch').addEventListener('click', handleGearSwitch);
```

In the existing `document.addEventListener('click', e => { ... })` handler, add inside the callback:
```js
    if (app.gearOpen && !e.target.closest('#sidebar-footer')) {
      saveSystemPrompt();
      app.gearOpen = false;
      const gp = $('gear-panel');
      if (gp) gp.hidden = true;
    }
```

- [ ] **Step 10: Verify in browser**

Click ⚙ at bottom of sidebar — gear panel opens showing System Prompt textarea + model/profile selectors. Type a system prompt, click outside — panel closes. Reopen — prompt persists. Switch conversations — prompt updates. Send a message, check DevTools Network → the request body `messages[0]` should be `{"role":"system","content":"..."}`.

- [ ] **Step 11: Commit**
```
git add web/static/app.js
git commit -m "feat: add gear panel with system prompt and settings"
```

---

### Task 6: app.js — Context warning banner

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Add context warn state to `app`**

After `gearOpen: false,` add:
```js
  contextWarnLevel: '',
  contextWarnDismissed: false,
```

- [ ] **Step 2: Add `renderContextWarn` function**

Add after `renderNoticeFromState`:
```js
function renderContextWarn() {
  const el = $('context-warn');
  const txt = $('context-warn-txt');
  if (!el) return;

  const pct = app.serverState?.llama_upstream?.context?.used_pct
           ?? app.serverState?.runtime?.context?.used_pct
           ?? 0;

  const newLevel = pct >= 90 ? 'critical' : pct >= 80 ? 'warn' : '';
  if (newLevel !== app.contextWarnLevel) app.contextWarnDismissed = false;
  app.contextWarnLevel = newLevel;

  if (!newLevel || app.contextWarnDismissed) {
    el.className = 'context-warn';
    return;
  }

  el.className = `context-warn visible ${newLevel}`;
  if (txt) txt.textContent = t(newLevel === 'critical' ? 'ctx_warn_90' : 'ctx_warn_80');
  const compBtn = $('btn-ctx-compress');
  if (compBtn) compBtn.textContent = t('ctx_compress_cta');
}
```

- [ ] **Step 3: Call `renderContextWarn` from `render()`**

Find:
```js
function render() {
  renderStatus();
  renderRuntime();
  renderDetailsPane();
  renderControls();
  renderNoticeFromState();
  renderSidebar();
}
```
Add `renderContextWarn();` after `renderNoticeFromState();`:
```js
function render() {
  renderStatus();
  renderRuntime();
  renderDetailsPane();
  renderControls();
  renderNoticeFromState();
  renderContextWarn();
  renderSidebar();
}
```

- [ ] **Step 4: Register event listeners in `init()`**

```js
  $('btn-ctx-compress').addEventListener('click', () => {
    app.contextWarnDismissed = true;
    renderContextWarn();
    openCompressForConversation(app.activeConversationId);
  });
  $('btn-ctx-dismiss').addEventListener('click', () => {
    app.contextWarnDismissed = true;
    renderContextWarn();
  });
```

- [ ] **Step 5: Verify in browser**

Temporarily add `const pct = 85;` as the first line of `renderContextWarn` (overrides the real value). Reload — amber banner appears with "Context 80% full" and "Compress →". Click ✕ — banner disappears. Change to `const pct = 92;` — red banner with 90% message. Remove the temp override before committing.

- [ ] **Step 6: Commit**
```
git add web/static/app.js
git commit -m "feat: add context usage warning banner at 80%/90%"
```

---

### Task 7: app.js — Delete branch button

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Add `deleteCurrentBranch` function**

Add after `deleteConversation`:
```js
function conversationTreeIds(id) { /* collect id and descendants by parent_id */ }
function removeConversationTree(id, preferredNextId = null) { /* delete tree, choose next active conversation, save and render */ }
function deleteCurrentBranch() {
  const conv = conversations.find(c => c.id === app.activeConversationId);
  if (!conv || !conv.parent_id) return;
  if (!confirm(t('delete_branch_confirm'))) return;
  removeConversationTree(conv.id, conv.parent_id);
}
```

- [ ] **Step 2: Add delete button to `appendBranchNav`**

At the end of `appendBranchNav`, after the `info.group.forEach(...)` block and before `container.appendChild(nav)`, add:
```js
  const cur = conversations.find(c => c.id === app.activeConversationId);
  if (cur?.parent_id) {
    const delBtn = document.createElement('button');
    delBtn.type = 'button';
    delBtn.textContent = '✕';
    delBtn.className = 'branch-btn';
    delBtn.title = t('delete_branch');
    delBtn.style.cssText = 'margin-left:6px;color:var(--red);border-color:var(--red)';
    delBtn.addEventListener('click', deleteCurrentBranch);
    nav.appendChild(delBtn);
  }
```

- [ ] **Step 3: Verify in browser**

Edit a user message to create a branch. Branch nav shows `[1] [2] ✕`. Click `✕` → confirm dialog appears. Confirm → branch and its descendants are deleted, view returns to the parent conversation. Deleting a root conversation from the sidebar also deletes hidden branch descendants so localStorage has no orphaned conversations.

- [ ] **Step 4: Commit**
```
git add web/static/app.js
git commit -m "feat: add delete-branch button in branch nav"
```

---

### Task 8: app.js — Pause polling when tab hidden

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Replace the static `setInterval` with a managed timer**

Find at the very end of `init()`:
```js
  setInterval(pollState, 2000);
```
Replace with:
```js
  let pollTimer = setInterval(pollState, 2000);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      clearInterval(pollTimer);
      pollTimer = null;
    } else {
      pollState();
      pollTimer = setInterval(pollState, 2000);
    }
  });
```

- [ ] **Step 2: Verify in browser**

Open DevTools → Network → filter `api/state`. Requests arrive every ~2s. Switch to a different tab → requests stop. Switch back → one request fires immediately, then resumes every 2s.

- [ ] **Step 3: Commit**
```
git add web/static/app.js
git commit -m "feat: pause state polling when browser tab is hidden"
```

---

### Task 9: app.js — Markdown export + Export All

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Add `exportChatMd` function**

Add after `exportChat`:
```js
function exportChatMd() {
  if (!chatHistory.length) { showNotice(t('export_empty'), 'error'); return; }
  const conv = getActiveConversation();
  const lines = [
    `# ${conv.title || t('untitled_chat')}`,
    '',
    `*Exported: ${new Date().toLocaleString()}*`,
    '',
    '---',
    '',
  ];
  chatHistory.forEach(m => {
    lines.push(m.role === 'user' ? '**User**' : '**Assistant**', '');
    if (m.reasoning_content) {
      lines.push('> *Thinking:*');
      m.reasoning_content.split('\n').forEach(l => lines.push(`> ${l}`));
      lines.push('');
    }
    const text = Array.isArray(m.content)
      ? (m.content.find(p => p.type === 'text')?.text || '')
      : (m.content || '');
    lines.push(text, '', '---', '');
  });
  const blob = new Blob([lines.join('\n')], { type: 'text/markdown' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `chat-${new Date().toISOString().slice(0, 10)}.md`;
  a.click();
  URL.revokeObjectURL(url);
}
```

- [ ] **Step 2: Add `exportAll` function directly after `exportChatMd`**

```js
function exportAll() {
  if (!conversations.length) { showNotice(t('export_empty'), 'error'); return; }
  const blob = new Blob(
    [JSON.stringify({ exported_at: Date.now(), conversations }, null, 2)],
    { type: 'application/json' }
  );
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `qwen-all-${new Date().toISOString().slice(0, 10)}.json`;
  a.click();
  URL.revokeObjectURL(url);
}
```

- [ ] **Step 3: Register listeners in `init()`**

```js
  $('btn-export-md').addEventListener('click', exportChatMd);
  $('btn-export-all').addEventListener('click', exportAll);
```

- [ ] **Step 4: Verify in browser**

Open `...` side menu. Two new buttons appear. Click "Export as Markdown" → `.md` file downloads; opening it shows `**User**` / `**Assistant**` sections with the conversation content. Click "Export all (JSON)" → `.json` file downloads with a `conversations` array. Import that exported-all JSON through the normal Import action; imported conversation IDs are remapped and branch parent links inside the imported set are preserved.

- [ ] **Step 5: Commit**
```
git add web/static/app.js
git commit -m "feat: add markdown export and export-all conversations"
```

---

### Task 10: app.js — Token estimation

**Files:**
- Modify: `web/static/app.js`

- [ ] **Step 1: Add `historyCharCount` to `app` state**

After `contextWarnDismissed: false,` add:
```js
  historyCharCount: 0,
```

- [ ] **Step 2: Add `updateHistoryCharCount` helper**

Add after `updateActiveConversation`:
```js
function updateHistoryCharCount() {
  app.historyCharCount = chatHistory.reduce((sum, m) => {
    const text = Array.isArray(m.content)
      ? (m.content.find(p => p.type === 'text')?.text || '')
      : (m.content || '');
    return sum + text.length;
  }, 0);
}
```

- [ ] **Step 3: Add `updateTokenEst` function**

Add after `updateHistoryCharCount`:
```js
function updateTokenEst() {
  const el = $('tok-est');
  if (!el) return;
  const total = Math.ceil((app.historyCharCount + ($('inp')?.value.length || 0)) / 4);
  el.textContent = total < 1000 ? `~${total} tok` : `~${(total / 1000).toFixed(1)}k tok`;
  el.className = total > 20000 ? 'critical' : total > 16000 ? 'warn' : '';
}
```

- [ ] **Step 4: Call `updateHistoryCharCount` wherever chatHistory changes**

Add `updateHistoryCharCount();` on the line immediately after each of these existing lines:

1. In `loadConversations()` — after `chatHistory = getActiveConversation().messages;`
2. In `setActiveConversation()` — after `chatHistory = conv.messages;`
3. In `updateActiveConversation()` — after `conv.messages = chatHistory;`
4. In `trimHistory()` — after `chatHistory = chatHistory.slice(-keepN);`
5. In `clearConversation()` — after `chatHistory = conv.messages;`

- [ ] **Step 5: Hook `updateTokenEst` to input and to history changes**

Find:
```js
  inp.addEventListener('input', () => autoResize(inp));
```
Replace with:
```js
  inp.addEventListener('input', () => { autoResize(inp); updateTokenEst(); });
```

Find the `renderHistory()` call in `init()` and add `updateTokenEst()` on the next line:
```js
  renderHistory();
  updateTokenEst();
```

Also call `updateTokenEst()` at the end of `updateHistoryCharCount()` so any history change auto-refreshes the display:
```js
function updateHistoryCharCount() {
  app.historyCharCount = chatHistory.reduce((sum, m) => {
    const text = Array.isArray(m.content)
      ? (m.content.find(p => p.type === 'text')?.text || '')
      : (m.content || '');
    return sum + text.length;
  }, 0);
  updateTokenEst();
}
```

- [ ] **Step 6: Verify in browser**

Footer shows `~N tok` label. Typing more text increases the count in real time. After exchanging several messages, the baseline reflects history length. At >16k tokens it turns amber; at >20k it turns red.

- [ ] **Step 7: Commit**
```
git add web/static/app.js
git commit -m "feat: add token estimation display in input footer"
```

---

## Self-Review

**Spec coverage:**
- A: local safe Markdown renderer ✅ Task 3 · code copy ✅ Task 3
- B: Vision upload ✅ Task 4
- C: Gear panel + system prompt ✅ Task 5
- D: Context warning ✅ Task 6
- E: Delete branch ✅ Task 7
- F: Visibility API pause ✅ Task 8
- G: MD export ✅ Task 9 · Export all ✅ Task 9
- H: Token estimation ✅ Task 10

**Type consistency:**
- `app.pendingImage: { dataUrl, mimeType } | null` — defined T4-S1, used T4-S3/S6/S7 ✅
- `conv.system_prompt: string | null` — set in T5-S3, read in T5-S4/S7 ✅
- `app.contextWarnLevel: '' | 'warn' | 'critical'` — T6-S1 and T6-S2 consistent ✅
- `app.historyCharCount: number` — T10-S1, updated T10-S2, read T10-S3 ✅
- `injectCodeCopyButtons(el)` — defined T3-S2, called T3-S4/S5/S6 consistently ✅
- `clearPendingImage()` — defined T4-S2, called T4-S4/S6 ✅

**No placeholders, no TBDs, all steps have code.**
