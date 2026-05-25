'use strict';

// ── State ─────────────────────────────────────────────────────────────────────
let lang         = localStorage.getItem('qwen-lang') || 'en';
let thinkingOn   = localStorage.getItem('qwen-thinking') !== 'false';
let theme        = localStorage.getItem('qwen-theme') || 'dark';
let chatHistory    = [];
let isStreaming    = false;
let serverState    = null;
let _switchTimer   = null;
let controlToken = '';   // per-process token delivered via /api/state, sent as X-Control-Token

// ── i18n ──────────────────────────────────────────────────────────────────────
function t(key) {
  return (I18N[lang] || I18N.en)[key] ?? (I18N.en[key] ?? key);
}

function setLang(l) {
  if (!I18N[l]) return;
  lang = l;
  localStorage.setItem('qwen-lang', l);
  applyI18n();
}

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach(el => (el.textContent = t(el.dataset.i18n)));
  document.getElementById('inp').placeholder = t('inp_placeholder');
  document.querySelectorAll('.lang-btn').forEach(b =>
    b.classList.toggle('active', b.dataset.lang === lang)
  );
  updateThinkingBtn();
  applyTheme();
  if (serverState) applyStatus(serverState);
}

// ── Theme toggle ──────────────────────────────────────────────────────────────
function applyTheme() {
  document.documentElement.dataset.theme = theme;
  const btn = document.getElementById('btn-theme');
  // ☀ = sun (currently dark → click for light), ☾ = moon (currently light → click for dark)
  if (btn) btn.textContent = theme === 'dark' ? '☀' : '☾';
}

function toggleTheme() {
  theme = theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('qwen-theme', theme);
  applyTheme();
}

// ── Thinking toggle ───────────────────────────────────────────────────────────
function updateThinkingBtn() {
  const btn = document.getElementById('btn-thinking');
  btn.setAttribute('aria-pressed', thinkingOn);
  btn.textContent = t(thinkingOn ? 'thinking_on' : 'thinking_off');
}

function toggleThinking() {
  thinkingOn = !thinkingOn;
  localStorage.setItem('qwen-thinking', thinkingOn);
  updateThinkingBtn();
}

// ── Data loading ──────────────────────────────────────────────────────────────
async function loadModels() {
  const r    = await fetch('/api/models');
  const data = await r.json();
  const sel  = document.getElementById('sel-model');
  sel.innerHTML = '';
  (data.models || []).forEach(m => {
    const o = new Option(`${m.id}  (${m.size_gb} GB)`, m.id);
    o.title = m.notes || '';
    sel.appendChild(o);
  });
  if (serverState?.current?.model_id) sel.value = serverState.current.model_id;
}

async function loadProfiles() {
  const r    = await fetch('/api/profiles');
  const data = await r.json();
  const sel  = document.getElementById('sel-profile');
  sel.innerHTML = '';
  (data.profiles || []).forEach(p => {
    const o = new Option(`${p.id}  —  ctx ${p.ctx.toLocaleString()}`, p.id);
    o.title = p.note || '';
    sel.appendChild(o);
  });
  sel.value = serverState?.current?.profile || 'balanced';
}

// ── State polling ─────────────────────────────────────────────────────────────
async function pollState() {
  try {
    const r = await fetch('/api/state');
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const s = await r.json();
    if (s.control_token) controlToken = s.control_token;
    const wasSwitching = serverState?.server === 'switching';
    serverState = s;
    applyStatus(s);
    if (wasSwitching && s.server === 'running' && s.current) {
      const sm = document.getElementById('sel-model');
      const sp = document.getElementById('sel-profile');
      if (s.current.model_id) sm.value = s.current.model_id;
      if (s.current.profile)  sp.value = s.current.profile;
    }
  } catch {
    serverState = { server: 'down' };
    applyStatus(serverState);
  }
}

function formatElapsed(seconds) {
  if (seconds < 60) return `${Math.floor(seconds)}s`;
  return `${Math.floor(seconds / 60)}m ${Math.floor(seconds % 60)}s`;
}

function applyStatus(s) {
  const dot      = document.getElementById('status-dot');
  const txt      = document.getElementById('status-txt');
  const sendBtn  = document.getElementById('btn-send');
  const swBtn    = document.getElementById('btn-switch');
  const sm       = document.getElementById('sel-model');
  const sp       = document.getElementById('sel-profile');
  const progress = document.getElementById('switch-progress');

  const sw = s.server === 'switching';
  const up = s.server === 'running';

  dot.className = `dot ${sw ? 'amber' : up ? 'green' : 'red'}`;

  if (sw) {
    const elapsed = s.switch_started_at ? (Date.now() / 1000 - s.switch_started_at) : 0;
    txt.textContent = `${t('status_switching')} ${formatElapsed(elapsed)}`;
    progress.classList.add('active');
    if (!_switchTimer) {
      _switchTimer = setInterval(() => {
        if (!serverState || serverState.server !== 'switching') {
          clearInterval(_switchTimer); _switchTimer = null; return;
        }
        const e = serverState.switch_started_at
          ? (Date.now() / 1000 - serverState.switch_started_at) : 0;
        document.getElementById('status-txt').textContent =
          `${t('status_switching')} ${formatElapsed(e)}`;
      }, 1000);
    }
  } else {
    txt.textContent = t(up ? 'status_running' : 'status_down');
    progress.classList.remove('active');
    if (_switchTimer) { clearInterval(_switchTimer); _switchTimer = null; }
  }

  sendBtn.disabled = !up || isStreaming;
  sendBtn.title = !up && s.upstream_error ? s.upstream_error : '';
  swBtn.disabled   = sw;
  sm.disabled      = sw;
  sp.disabled      = sw;

  const notice = document.getElementById('notice');
  if (s.switch_error) {
    notice.textContent = s.switch_error;
    notice.className   = 'notice visible error';
  } else if (!up && s.upstream_error) {
    notice.textContent = `${t('status_down')}: ${s.upstream_error}`;
    notice.className   = 'notice visible error';
  } else if (notice.classList.contains('visible') && !s.switch_error) {
    notice.className = 'notice';
  }
}

// ── Switch ────────────────────────────────────────────────────────────────────
async function handleSwitch() {
  const model   = document.getElementById('sel-model').value;
  const profile = document.getElementById('sel-profile').value;
  if (!model || !profile) return;
  try {
    const r = await fetch('/api/switch', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json', 'X-Control-Token': controlToken },
      body:    JSON.stringify({ model, profile }),
    });
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      showNotice(j.detail || `HTTP ${r.status}`, 'error');
    }
  } catch (e) {
    showNotice(e.message, 'error');
  }
}

function showNotice(msg, cls) {
  const el = document.getElementById('notice');
  if (!msg) { el.className = 'notice'; return; }
  el.textContent = msg;
  el.className   = `notice visible ${cls || ''}`;
}

// ── Markdown renderer ─────────────────────────────────────────────────────────
function renderMd(raw) {
  // HTML-escape first for XSS safety, then apply markdown patterns.
  let s = raw.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  // Extract fenced code blocks before other patterns touch them.
  const blocks = [];
  s = s.replace(/```(?:\w*\n?)([\s\S]*?)```/g, (_, c) => {
    blocks.push(`<pre><code>${c.replace(/\n$/, '')}</code></pre>`);
    return `\x00B${blocks.length - 1}\x00`;
  });

  s = s.replace(/`([^`\n]+)`/g,           '<code>$1</code>');
  s = s.replace(/\*\*\*([^*\n]+)\*\*\*/g, '<strong><em>$1</em></strong>');
  s = s.replace(/\*\*([^*\n]+)\*\*/g,     '<strong>$1</strong>');
  s = s.replace(/\*([^*\n]+)\*/g,         '<em>$1</em>');

  // Convert newlines outside code blocks, then restore blocks.
  s = s.replace(/\n/g, '<br>');
  s = s.replace(/\x00B(\d+)\x00/g, (_, i) => blocks[+i]);

  return s;
}

// ── Message rendering ─────────────────────────────────────────────────────────
function addMsg(role, opts = {}) {
  if (role === 'system') {
    const sysEl = document.createElement('div');
    sysEl.className = 'msg-system';
    sysEl.textContent = `${t('role_system')}: ${opts.text || ''}`;
    document.getElementById('msgs').appendChild(sysEl);
    scrollBottom();
    return { bubble: sysEl, thinkEl: null };
  }

  const wrap    = document.createElement('div');
  wrap.className = `msg ${role}`;

  const lbl = document.createElement('span');
  lbl.className   = 'msg-label';
  lbl.textContent = t(role === 'user' ? 'role_user' : 'role_assistant');

  let thinkEl = null;
  if (role === 'assistant') {
    thinkEl = document.createElement('details');
    thinkEl.className = 'thinking-block';
    thinkEl.hidden    = true;
    const sum    = document.createElement('summary');
    sum.textContent  = t('thinking_label');
    const tc = document.createElement('div');
    tc.className = 'thinking-content';
    thinkEl.append(sum, tc);
  }

  const bubble    = document.createElement('div');
  bubble.className = 'bubble' + (opts.error ? ' error' : '');
  if (opts.text)  bubble.textContent = opts.text;
  if (opts.html)  bubble.innerHTML   = opts.html;

  wrap.append(lbl);
  if (thinkEl) wrap.append(thinkEl);
  wrap.append(bubble);
  document.getElementById('msgs').appendChild(wrap);
  scrollBottom();

  return { bubble, thinkEl };
}

function scrollBottom() {
  const msgs = document.getElementById('msgs');
  msgs.scrollTop = msgs.scrollHeight;
}

// ── Input auto-resize ─────────────────────────────────────────────────────────
function autoResize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 160) + 'px';
}

// ── Send / Stream ─────────────────────────────────────────────────────────────
async function sendMessage() {
  const inp     = document.getElementById('inp');
  const content = inp.value.trim();
  if (!content || isStreaming || serverState?.server !== 'running') return;

  inp.value = '';
  autoResize(inp);

  chatHistory.push({ role: 'user', content });
  addMsg('user', { text: content });

  const { bubble, thinkEl } = addMsg('assistant');
  bubble.classList.add('streaming');
  isStreaming = true;
  document.getElementById('btn-send').disabled = true;

  let full  = '';
  let think = '';

  try {
    const body = {
      model:      serverState?.current?.alias || 'default',
      messages:   chatHistory,
      stream:     true,
      max_tokens: 4096,
    };
    if (!thinkingOn) body.chat_template_kwargs = { enable_thinking: false };

    const resp = await fetch('/v1/chat/completions', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
    });

    if (!resp.ok) {
      let msg = `HTTP ${resp.status}`;
      try { const j = await resp.json(); msg = j.detail || j.error?.message || msg; } catch {}
      bubble.classList.remove('streaming');
      bubble.classList.add('error');
      bubble.textContent = t('err_prefix') + msg;
      chatHistory.pop();
      return;
    }

    const reader = resp.body.getReader();
    const dec    = new TextDecoder();
    let   buf    = '';

    outer: while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop();
      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        const raw = line.slice(6).trim();
        if (raw === '[DONE]') break outer;
        let parsed;
        try { parsed = JSON.parse(raw); } catch { continue; }
        const delta = parsed.choices?.[0]?.delta;
        if (!delta) continue;
        if (delta.reasoning_content) {
          think += delta.reasoning_content;
          if (thinkEl) {
            thinkEl.hidden = false;
            thinkEl.querySelector('.thinking-content').textContent = think;
          }
        }
        if (delta.content) {
          full += delta.content;
          bubble.textContent = full;
          scrollBottom();
        }
      }
    }

    bubble.classList.remove('streaming');
    if (full) {
      bubble.innerHTML = renderMd(full);
    } else if (!think) {
      bubble.classList.add('error');
      bubble.textContent = t('err_empty');
      chatHistory.pop();
      return;
    }
    chatHistory.push({ role: 'assistant', content: full });

  } catch (e) {
    bubble.classList.remove('streaming');
    bubble.classList.add('error');
    bubble.textContent = t('err_prefix') + e.message;
    chatHistory.pop();
  } finally {
    isStreaming = false;
    document.getElementById('btn-send').disabled = serverState?.server !== 'running';
    scrollBottom();
  }
}

// ── Compress panel ────────────────────────────────────────────────────────────
function toggleCompressPanel() {
  const p = document.getElementById('compress-panel');
  p.hidden = !p.hidden;
}

function stripThinking() {
  document.getElementById('compress-panel').hidden = true;
  // Strip <think>…</think> blocks (including trailing whitespace) from stored history.
  // In normal operation these don't appear in chatHistory (reasoning_content is separate),
  // but imported histories or non-standard model output might include them.
  const re = /<think>[\s\S]*?<\/think>\s*/gi;
  let n = 0;
  chatHistory = chatHistory.map(m => {
    if (m.role !== 'assistant') return m;
    const cleaned = m.content.replace(re, '').trimStart();
    if (cleaned.length < m.content.length) {
      n++;
      return { role: m.role, content: cleaned };
    }
    return m;
  });
  // Remove all displayed thinking blocks from the DOM.
  document.querySelectorAll('.thinking-block').forEach(el => el.remove());
  const msg = n > 0
    ? t('cp_strip_done').replace('{n}', n)
    : t('cp_strip_none');
  showNotice(msg, n > 0 ? 'ok' : '');
  setTimeout(() => showNotice('', ''), 3000);
}

function trimHistory() {
  document.getElementById('compress-panel').hidden = true;
  const turns  = Math.max(1, parseInt(document.getElementById('trim-n').value, 10) || 10);
  const keepN  = turns * 2;  // each turn = 1 user + 1 assistant message
  if (chatHistory.length <= keepN) {
    showNotice(t('cp_trim_none'), '');
    setTimeout(() => showNotice('', ''), 3000);
    return;
  }
  const removed = Math.floor((chatHistory.length - keepN) / 2);
  chatHistory = chatHistory.slice(-keepN);
  // Re-render only the kept messages (no thinking blocks — they weren't stored).
  document.getElementById('msgs').innerHTML = '';
  chatHistory.forEach(m => {
    if (m.role === 'user')        addMsg('user',      { text: m.content });
    else if (m.role === 'system') addMsg('system',    { text: m.content });
    else                          addMsg('assistant', { html: renderMd(m.content) });
  });
  scrollBottom();
  showNotice(t('cp_trim_done').replace('{n}', removed), 'ok');
  setTimeout(() => showNotice('', ''), 3000);
}

// ── Export / Import ───────────────────────────────────────────────────────────
function exportChat() {
  if (!chatHistory.length) {
    showNotice(t('export_empty'), 'error');
    return;
  }
  const json = JSON.stringify(chatHistory, null, 2);
  const blob = new Blob([json], { type: 'application/json' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href     = url;
  a.download = `chat-${new Date().toISOString().slice(0, 19).replace(/:/g, '-')}.json`;
  a.click();
  URL.revokeObjectURL(url);
}

function importChat() {
  document.getElementById('file-import').click();
}

function handleImport(e) {
  const file = e.target.files?.[0];
  if (!file) return;
  e.target.value = '';   // reset so the same file can be re-imported later

  const reader = new FileReader();
  reader.onload = evt => {
    let data;
    try { data = JSON.parse(evt.target.result); } catch {
      showNotice(t('import_err'), 'error');
      return;
    }
    const KNOWN_ROLES = new Set(['user', 'assistant', 'system']);
    if (!Array.isArray(data)) {
      showNotice(t('import_err'), 'error');
      return;
    }
    const messages = data
      .filter(m => m && typeof m.role === 'string' && KNOWN_ROLES.has(m.role))
      .map(m => ({
        role:    m.role,
        content: typeof m.content === 'string' ? m.content : String(m.content ?? ''),
      }));
    if (messages.length === 0) {
      showNotice(t('import_err'), 'error');
      return;
    }

    chatHistory = messages;
    document.getElementById('msgs').innerHTML = '';
    chatHistory.forEach(m => {
      if (m.role === 'user')      addMsg('user',      { text: m.content });
      else if (m.role === 'system') addMsg('system',  { text: m.content });
      else                          addMsg('assistant', { html: renderMd(m.content) });
    });
    const msg = t('import_ok').replace('{n}', chatHistory.length);
    showNotice(msg, 'ok');
    setTimeout(() => {
      if (!document.getElementById('notice').classList.contains('error')) {
        showNotice('', '');
      }
    }, 3000);
  };
  reader.readAsText(file);
}

// ── Clear chat ────────────────────────────────────────────────────────────────
function clearChat() {
  chatHistory = [];
  document.getElementById('msgs').innerHTML = '';
}

// ── Init ──────────────────────────────────────────────────────────────────────
async function init() {
  applyTheme();
  applyI18n();

  document.getElementById('btn-send').addEventListener('click', sendMessage);
  document.getElementById('btn-switch').addEventListener('click', handleSwitch);
  document.getElementById('btn-thinking').addEventListener('click', toggleThinking);
  document.getElementById('btn-theme').addEventListener('click', toggleTheme);
  document.getElementById('btn-compress').addEventListener('click', toggleCompressPanel);
  document.getElementById('btn-strip').addEventListener('click', stripThinking);
  document.getElementById('btn-trim').addEventListener('click', trimHistory);
  document.getElementById('btn-export').addEventListener('click', exportChat);
  document.getElementById('btn-import').addEventListener('click', importChat);
  document.getElementById('file-import').addEventListener('change', handleImport);
  document.getElementById('btn-clear').addEventListener('click', clearChat);

  // Close compress panel when clicking outside it.
  document.addEventListener('click', e => {
    const panel = document.getElementById('compress-panel');
    if (!panel.hidden && !e.target.closest('.compress-wrap')) panel.hidden = true;
  });

  const inp = document.getElementById('inp');
  inp.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
  });
  inp.addEventListener('input', () => autoResize(inp));

  await pollState();
  await Promise.all([loadModels(), loadProfiles()]);
  setInterval(pollState, 2000);
}

document.addEventListener('DOMContentLoaded', init);
