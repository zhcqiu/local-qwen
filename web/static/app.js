'use strict';

const LEGACY_CHAT_KEY = 'qwen-chat-history-v1';
const CONV_KEY = 'qwen-conversations-v1';
const ACTIVE_CONV_KEY = 'qwen-active-conversation-v1';

const app = {
  lang: localStorage.getItem('qwen-lang') || 'en',
  thinkingOn: localStorage.getItem('qwen-thinking') !== 'false',
  theme: localStorage.getItem('qwen-theme') || 'dark',
  serverState: null,
  isStreaming: false,
  healthRunning: false,
  activeTimings: null,
  activeOutputChars: 0,
  activeConversationId: localStorage.getItem(ACTIVE_CONV_KEY) || '',
  editBranch: null,
  convSearch: '',
  openConversationMenu: null,
  compressConvId: null,
  detailsOpen: localStorage.getItem('qwen-details-open') !== 'false',
};

let chatHistory = [];
let conversations = [];
let controlToken = '';
let abortController = null;
let _switchTimer = null;
let manualNoticeUntil = 0;

function $(id) {
  return document.getElementById(id);
}

function t(key) {
  return (I18N[app.lang] || I18N.en)[key] ?? (I18N.en[key] ?? key);
}

function fmtInt(v) {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return '-';
  return Number(v).toLocaleString();
}

function fmtPct(v) {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return '-';
  return `${Number(v).toFixed(1)}%`;
}

function fmtTps(v) {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return '-';
  return Number(v).toFixed(1);
}

function formatElapsed(seconds) {
  if (!seconds || seconds < 0) return '0s';
  if (seconds < 60) return `${Math.floor(seconds)}s`;
  return `${Math.floor(seconds / 60)}m ${Math.floor(seconds % 60)}s`;
}

function uid() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function cloneMessages(messages) {
  return messages.map(m => ({ ...m }));
}

function titleFromMessages(messages) {
  const first = messages.find(m => m.role === 'user' && m.content);
  const rawText = first
    ? (Array.isArray(first.content) ? (first.content.find(p => p.type === 'text')?.text || '') : first.content)
    : '';
  const title = rawText.trim().replace(/\s+/g, ' ') || t('untitled_chat');
  return title.length > 42 ? `${title.slice(0, 42)}...` : title;
}

function getBranchGroup(forkIndex) {
  const cur = conversations.find(c => c.id === app.activeConversationId);
  if (!cur) return null;

  let rootId;
  if (cur.fork_index === forkIndex) {
    rootId = cur.parent_id;
  } else {
    if (!conversations.some(c => c.parent_id === cur.id && c.fork_index === forkIndex)) return null;
    rootId = cur.id;
  }
  if (!rootId) return null;

  const rootConv = conversations.find(c => c.id === rootId);
  if (!rootConv) return null;

  const siblings = conversations
    .filter(c => c.parent_id === rootId && c.fork_index === forkIndex)
    .sort((a, b) => a.created_at - b.created_at);

  return { group: [rootConv, ...siblings], current: app.activeConversationId };
}

function appendBranchNav(container, forkIndex) {
  const info = getBranchGroup(forkIndex);
  if (!info || info.group.length <= 1) return;

  const nav = document.createElement('div');
  nav.className = 'branch-nav';

  info.group.forEach((conv, i) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = String(i + 1);
    btn.className = `branch-btn${conv.id === info.current ? ' active' : ''}`;
    btn.title = conv.title || t('untitled_chat');
    btn.addEventListener('click', () => setActiveConversation(conv.id));
    nav.appendChild(btn);
  });

  container.appendChild(nav);
}

function getActiveConversation() {
  let conv = conversations.find(c => c.id === app.activeConversationId);
  if (!conv) {
    conv = createConversation([], t('new_chat'));
  }
  return conv;
}

function createConversation(messages = [], title = null, parentId = null, forkIndex = null) {
  const conv = {
    id: uid(),
    title: title || titleFromMessages(messages),
    messages: cloneMessages(messages),
    parent_id: parentId,
    fork_index: forkIndex,
    created_at: Date.now(),
    updated_at: Date.now(),
  };
  conversations.unshift(conv);
  app.activeConversationId = conv.id;
  chatHistory = conv.messages;
  saveConversations();
  return conv;
}

function updateActiveConversation() {
  const conv = getActiveConversation();
  conv.messages = chatHistory;
  conv.title = titleFromMessages(chatHistory);
  conv.model = app.serverState?.current?.alias || conv.model || null;
  conv.updated_at = Date.now();
  saveConversations();
}

function saveConversations() {
  localStorage.setItem(CONV_KEY, JSON.stringify(conversations));
  localStorage.setItem(ACTIVE_CONV_KEY, app.activeConversationId);
}

function loadConversations() {
  let loaded = [];
  try {
    loaded = JSON.parse(localStorage.getItem(CONV_KEY) || '[]');
  } catch {
    loaded = [];
  }
  conversations = Array.isArray(loaded)
    ? loaded.map(c => ({
        id: String(c.id || uid()),
        title: String(c.title || t('untitled_chat')),
        messages: normalizeMessages(c.messages || []),
        parent_id: c.parent_id || null,
        created_at: Number(c.created_at || Date.now()),
        updated_at: Number(c.updated_at || Date.now()),
      })).filter(c => c.messages.length || c.title)
    : [];

  if (!conversations.length) {
    let legacy = [];
    try {
      legacy = normalizeMessages(JSON.parse(localStorage.getItem(LEGACY_CHAT_KEY) || '[]'));
    } catch {
      legacy = [];
    }
    createConversation(legacy, legacy.length ? titleFromMessages(legacy) : t('new_chat'));
  } else if (!conversations.some(c => c.id === app.activeConversationId)) {
    app.activeConversationId = conversations[0].id;
  }

  // Backfill fork_index for existing branches that were created before this feature
  conversations.forEach(c => {
    if (c.parent_id && (c.fork_index === null || c.fork_index === undefined)) {
      const parent = conversations.find(p => p.id === c.parent_id);
      if (parent) {
        const cm = c.messages, pm = parent.messages;
        let fi = Math.min(cm.length, pm.length);
        for (let i = 0; i < fi; i++) {
          if (cm[i].content !== pm[i].content || cm[i].role !== pm[i].role) { fi = i; break; }
        }
        c.fork_index = fi;
      }
    }
  });

  chatHistory = getActiveConversation().messages;
  saveConversations();
}

function setActiveConversation(id) {
  if (app.isStreaming) return;
  const conv = conversations.find(c => c.id === id);
  if (!conv) return;
  app.activeConversationId = id;
  chatHistory = conv.messages;
  app.editBranch = null;
  $('inp').value = '';
  autoResize($('inp'));
  saveConversations();
  renderHistory();
  renderSidebar();
  renderControls();
}

function newConversation() {
  if (app.isStreaming) return;
  createConversation([], t('new_chat'));
  app.editBranch = null;
  $('inp').value = '';
  autoResize($('inp'));
  renderHistory();
  renderSidebar();
  renderControls();
}

function deleteConversation(id) {
  if (app.isStreaming || conversations.length <= 1) return;
  if (!confirm(t('delete_confirm'))) return;
  conversations = conversations.filter(c => c.id !== id);
  if (app.activeConversationId === id) {
    app.activeConversationId = conversations[0].id;
    chatHistory = conversations[0].messages;
    renderHistory();
  }
  saveConversations();
  renderSidebar();
}

function renameConversation(id) {
  const conv = conversations.find(c => c.id === id);
  if (!conv) return;
  const next = prompt(t('rename_prompt'), conv.title || t('untitled_chat'));
  if (!next || !next.trim()) return;
  conv.title = next.trim();
  conv.updated_at = Date.now();
  saveConversations();
  renderSidebar();
}

function renderSidebar() {
  const list = $('conv-list');
  if (!list) return;

  // Rescue compress panel from inside the list before wiping it.
  // The panel's permanent home is .compress-wrap (display:none in header).
  const panel = $('compress-panel');
  const panelHome = document.querySelector('.compress-wrap');
  if (panel && panelHome && !panel.closest('.compress-wrap')) {
    panel.hidden = true;
    panelHome.appendChild(panel);
  }

  list.innerHTML = '';
  const q = app.convSearch.trim().toLowerCase();
  conversations
    .slice()
    .filter(conv => !conv.parent_id)
    .filter(conv => {
      if (!q) return true;
      const hay = `${conv.title || ''}\n${(conv.messages || []).map(m => m.content).join('\n')}`.toLowerCase();
      return hay.includes(q);
    })
    .sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0))
    .forEach(conv => {
      const row = document.createElement('div');
      row.tabIndex = 0;
      row.dataset.convId = conv.id;
      row.className = `conv-item ${conv.id === app.activeConversationId ? 'active' : ''}`;
      row.addEventListener('click', () => setActiveConversation(conv.id));
      row.addEventListener('keydown', e => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          setActiveConversation(conv.id);
        }
      });

      const title = document.createElement('span');
      title.className = 'conv-title';
      title.textContent = conv.title || t('untitled_chat');

      const more = document.createElement('button');
      more.type = 'button';
      more.className = `conv-more ${app.openConversationMenu === conv.id ? 'open' : ''}`;
      more.textContent = '...';
      more.title = t('btn_more');
      more.addEventListener('click', e => {
        e.stopPropagation();
        app.openConversationMenu = app.openConversationMenu === conv.id ? null : conv.id;
        renderSidebar();
      });

      const menu = document.createElement('span');
      menu.className = `conv-menu ${app.openConversationMenu === conv.id ? 'open' : ''}`;
      const rename = document.createElement('button');
      rename.type = 'button';
      rename.textContent = t('btn_rename');
      rename.addEventListener('click', e => {
        e.stopPropagation();
        app.openConversationMenu = null;
        renameConversation(conv.id);
      });
      const compress = document.createElement('button');
      compress.type = 'button';
      compress.textContent = t('btn_compress');
      compress.addEventListener('click', e => {
        e.stopPropagation();
        openCompressForConversation(conv.id);
      });
      const clear = document.createElement('button');
      clear.type = 'button';
      clear.textContent = t('btn_clear');
      clear.disabled = !(conv.messages || []).length;
      clear.addEventListener('click', e => {
        e.stopPropagation();
        app.openConversationMenu = null;
        clearConversation(conv.id);
      });
      const del = document.createElement('button');
      del.type = 'button';
      del.textContent = t('btn_delete');
      del.disabled = conversations.length <= 1;
      del.addEventListener('click', e => {
        e.stopPropagation();
        app.openConversationMenu = null;
        deleteConversation(conv.id);
      });
      menu.append(rename, compress, clear, del);

      const meta = document.createElement('span');
      meta.className = 'conv-meta';
      const model = conv.model ? ` - ${conv.model}` : '';
      const branchCount = conversations.filter(c => c.parent_id === conv.id).length;
      const branchSuffix = branchCount > 0 ? ` · ${branchCount} ${t('branch_prefix')}` : '';
      meta.textContent = `${Math.ceil((conv.messages || []).length / 2)} turns${model}${branchSuffix}`;

      row.append(title, more, meta, menu);
      list.appendChild(row);
    });

  // Re-place compress panel into the target conv-item if one is open.
  if (app.compressConvId && panel) {
    const targetRow = list.querySelector(`[data-conv-id="${CSS.escape(app.compressConvId)}"]`);
    if (targetRow) {
      targetRow.appendChild(panel);
      panel.hidden = false;
    } else {
      app.compressConvId = null;
    }
  }
}

function setLang(l) {
  if (!I18N[l]) return;
  app.lang = l;
  localStorage.setItem('qwen-lang', l);
  applyI18n();
}

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach(el => (el.textContent = t(el.dataset.i18n)));
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    el.placeholder = t(el.dataset.i18nPlaceholder);
  });
  [
    ['btn-new-chat', 'btn_new_chat'],
    ['btn-compress', 'btn_compress'],
    ['btn-import', 'btn_import'],
    ['btn-export', 'btn_export'],
    ['btn-details', 'btn_details'],
  ].forEach(([id, key]) => {
    const el = $(id);
    if (el) el.title = t(key);
  });
  $('inp').placeholder = t('inp_placeholder');
  document.querySelectorAll('.lang-btn').forEach(b =>
    b.classList.toggle('active', b.dataset.lang === app.lang)
  );
  updateThinkingBtn();
  applyTheme();
  renderSidebar();
  render();
}

function applyTheme() {
  document.documentElement.dataset.theme = app.theme;
  const btn = $('btn-theme');
  if (btn) btn.textContent = app.theme === 'dark' ? '☀' : '☾';
}

function toggleTheme() {
  app.theme = app.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('qwen-theme', app.theme);
  applyTheme();
}

function updateThinkingBtn() {
  const btn = $('btn-thinking');
  btn.setAttribute('aria-pressed', app.thinkingOn);
  btn.textContent = t(app.thinkingOn ? 'thinking_on' : 'thinking_off');
}

function toggleThinking() {
  app.thinkingOn = !app.thinkingOn;
  localStorage.setItem('qwen-thinking', app.thinkingOn);
  updateThinkingBtn();
}

async function loadModels() {
  const r = await fetch('/api/models');
  const data = await r.json();
  const sel = $('sel-model');
  sel.innerHTML = '';
  (data.models || []).forEach(m => {
    const o = new Option(`${m.id}  (${m.size_gb} GB)`, m.id);
    o.title = m.notes || '';
    sel.appendChild(o);
  });
  if (app.serverState?.current?.model_id) sel.value = app.serverState.current.model_id;
}

async function loadProfiles() {
  const r = await fetch('/api/profiles');
  const data = await r.json();
  const sel = $('sel-profile');
  sel.innerHTML = '';
  (data.profiles || []).forEach(p => {
    const o = new Option(`${p.id}  -  ctx ${p.ctx.toLocaleString()}`, p.id);
    o.title = p.note || '';
    sel.appendChild(o);
  });
  sel.value = app.serverState?.current?.profile || 'balanced';
}

async function pollState() {
  try {
    const r = await fetch('/api/state');
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const s = await r.json();
    if (s.control_token) controlToken = s.control_token;
    const wasSwitching = app.serverState?.server === 'switching';
    app.serverState = s;
    if (wasSwitching && s.server === 'running' && s.current) {
      if (s.current.model_id) $('sel-model').value = s.current.model_id;
      if (s.current.profile) $('sel-profile').value = s.current.profile;
    }
  } catch (e) {
    app.serverState = {
      ui_backend: 'unreachable',
      server: 'down',
      upstream_error: e.message,
      llama_upstream: { reachable: false, error: e.message, base: '-' },
    };
  }
  render();
}

function sendBlockReason() {
  const s = app.serverState;
  if (!s) return t('reason_loading');
  if (s.server === 'switching') return t('reason_switching');
  if (s.server !== 'running') return s.upstream_error || s.llama_upstream?.error || t('reason_offline');
  return '';
}

function render() {
  renderStatus();
  renderRuntime();
  renderDetailsPane();
  renderControls();
  renderNoticeFromState();
  renderSidebar();
}

function renderStatus() {
  const s = app.serverState || {};
  const sw = s.server === 'switching';
  const up = s.server === 'running';
  $('status-dot').className = `dot ${sw ? 'amber' : up ? 'green' : 'red'}`;

  if (sw) {
    const elapsed = s.switch_started_at ? (Date.now() / 1000 - s.switch_started_at) : 0;
    const phase = s.switch?.phase ? ` ${s.switch.phase}` : '';
    $('status-txt').textContent = `${t('status_switching')} ${formatElapsed(elapsed)}${phase}`;
    $('switch-progress').classList.add('active');
    if (!_switchTimer) {
      _switchTimer = setInterval(renderStatus, 1000);
    }
  } else {
    $('status-txt').textContent = t(up ? 'status_running' : 'status_down');
    $('switch-progress').classList.remove('active');
    if (_switchTimer) { clearInterval(_switchTimer); _switchTimer = null; }
  }
}

function renderRuntime() {
  const s = app.serverState || {};
  const upstream = s.llama_upstream || {};
  const current = s.current || {};
  const props = upstream.props || {};
  const context = s.runtime?.context || upstream.context || {};
  const last = app.activeTimings
    ? { prompt_tokens: app.activeTimings.prompt_n, completion_tokens: app.activeTimings.predicted_n,
        prompt_tps: app.activeTimings.prompt_per_second, generation_tps: app.activeTimings.predicted_per_second }
    : (s.runtime?.last_completion || upstream.last_completion || {});
  const health = s.runtime?.last_health || upstream.last_health;
  const logs = upstream.logs?.files || [];

  setMetric('m-upstream',
    upstream.reachable ? `${t('status_running')} ${upstream.base || ''}` : (upstream.error || t('status_down')),
    upstream.reachable ? 'ok' : 'err'
  );
  setMetric('m-model',
    current.alias || props.model_alias || (upstream.served_aliases || [])[0] || t('status_unknown')
  );
  setMetric('m-profile', current.profile || t('external_profile'), current.profile ? '' : 'warn');

  const nCtx = context.n_ctx || props.n_ctx;
  const used = context.used_tokens;
  const pct = context.used_pct;
  setMetric('m-context', nCtx ? `${fmtInt(used || 0)} / ${fmtInt(nCtx)} (${fmtPct(pct || 0)})` : '-',
    pct >= 90 ? 'err' : pct >= 75 ? 'warn' : ''
  );
  $('m-context-bar').style.width = `${Math.max(0, Math.min(100, pct || 0))}%`;

  const inputTokens = last.prompt_tokens ?? context.input_tokens;
  const outputTokens = last.completion_tokens ?? context.output_tokens;
  setMetric('m-tokens', `in ${fmtInt(inputTokens)} / out ${fmtInt(outputTokens)}`);
  setMetric('m-tps', `prompt ${fmtTps(last.prompt_tps)} / gen ${fmtTps(last.generation_tps)}`);
  setMetric('m-slot', context.active ? t('status_busy') : t('status_ready'), context.active ? 'warn' : 'ok');
  const compact = [
    current.alias || props.model_alias || (upstream.served_aliases || [])[0] || t('status_unknown'),
    nCtx ? `ctx ${fmtInt(used || 0)}/${fmtInt(nCtx)} ${fmtPct(pct || 0)}` : 'ctx -',
    `gen ${fmtTps(last.generation_tps)} tok/s`,
    context.active ? t('status_busy') : t('status_ready'),
    upstream.reachable ? 'upstream ok' : 'upstream down',
  ];
  const compactEl = $('m-compact');
  if (compactEl) compactEl.textContent = compact.join('  |  ');
  setMetric('m-health',
    app.healthRunning ? t('health_running')
      : health ? `${health.ok ? t('health_ok') : t('health_failed')} ${health.wall_ms || '-'}ms`
      : '-',
    app.healthRunning ? 'warn' : health ? (health.ok ? 'ok' : 'err') : ''
  );

  const logText = logs.length ? logs.slice(0, 2).map(f => f.name).join(', ') : '-';
  setMetric('m-logs', logText);
  $('m-logs').title = logs.map(f => f.path).join('\n');
}

function renderDetailsPane() {
  const pane = $('details-pane');
  const body = $('details-body');
  if (!pane || !body) return;
  pane.classList.toggle('collapsed', !app.detailsOpen);
  if (!app.detailsOpen) return;

  const s = app.serverState || {};
  const upstream = s.llama_upstream || {};
  const current = s.current || {};
  const context = s.runtime?.context || upstream.context || {};
  const last = s.runtime?.last_completion || upstream.last_completion || {};
  const health = s.runtime?.last_health || upstream.last_health || {};
  const conv = conversations.find(c => c.id === app.activeConversationId) || {};
  const logs = upstream.logs?.files || [];

  const rows = [
    [t('chat_info'), [
      [t('status_model'), conv.model || current.alias || '-'],
      [t('conversations'), conv.title || t('untitled_chat')],
      [t('status_tokens'), `${fmtInt((conv.messages || []).length)} messages`],
      [t('branch_prefix'), conv.parent_id || '-'],
    ]],
    [t('runtime_info'), [
      [t('status_upstream'), upstream.reachable ? upstream.base : (upstream.error || '-')],
      [t('status_model'), current.alias || upstream.props?.model_alias || '-'],
      [t('status_profile'), current.profile || t('external_profile')],
      [t('status_context'), context.n_ctx ? `${fmtInt(context.used_tokens || 0)} / ${fmtInt(context.n_ctx)} (${fmtPct(context.used_pct || 0)})` : '-'],
      [t('status_tokens'), `in ${fmtInt(last.prompt_tokens ?? context.input_tokens)} / out ${fmtInt(last.completion_tokens ?? context.output_tokens)}`],
      [t('status_tps'), `prompt ${fmtTps(last.prompt_tps)} / gen ${fmtTps(last.generation_tps)}`],
      [t('status_slot'), context.active ? t('status_busy') : t('status_ready')],
      [t('status_health'), health.ok === undefined ? '-' : `${health.ok ? t('health_ok') : t('health_failed')} ${health.wall_ms || '-'}ms`],
      [t('status_logs'), logs.map(f => f.name).slice(0, 4).join('\n') || '-'],
    ]],
  ];

  body.innerHTML = '';
  rows.forEach(([title, items]) => {
    const sec = document.createElement('section');
    sec.className = 'detail-section';
    const h = document.createElement('span');
    h.className = 'detail-k';
    h.textContent = title;
    sec.appendChild(h);
    items.forEach(([k, v]) => {
      const val = document.createElement('div');
      val.className = 'detail-v';
      val.textContent = `${k}: ${v}`;
      sec.appendChild(val);
    });
    body.appendChild(sec);
  });
}

function toggleDetailsPane(force) {
  app.detailsOpen = typeof force === 'boolean' ? force : !app.detailsOpen;
  localStorage.setItem('qwen-details-open', String(app.detailsOpen));
  renderDetailsPane();
}

function setMetric(id, text, cls = '') {
  const el = $(id);
  el.textContent = text || '-';
  el.className = `metric-v ${cls}`;
}

function renderControls() {
  const sw = app.serverState?.server === 'switching';
  const reason = sendBlockReason();
  const sendBtn = $('btn-send');
  sendBtn.textContent = app.isStreaming ? t('btn_stop') : t('btn_send');
  sendBtn.classList.toggle('stop', app.isStreaming);
  sendBtn.disabled = app.isStreaming ? false : !!reason;
  sendBtn.title = app.isStreaming ? t('btn_stop') : reason;

  $('btn-switch').disabled = sw || app.isStreaming;
  $('sel-model').disabled = sw || app.isStreaming;
  $('sel-profile').disabled = sw || app.isStreaming;
  $('btn-health').disabled = !controlToken || app.healthRunning || app.isStreaming;
  const detailsBtn = $('btn-details');
  if (detailsBtn) detailsBtn.classList.toggle('active', app.detailsOpen);
  const banner = $('edit-banner');
  if (banner) {
    banner.classList.toggle('visible', !!app.editBranch);
    $('edit-banner-text').textContent = app.editBranch ? t('edit_branch_notice') : '';
  }
}

function renderNoticeFromState() {
  if (Date.now() < manualNoticeUntil) return;
  const s = app.serverState || {};
  const notice = $('notice');
  if (s.switch_error) {
    notice.textContent = s.switch_error;
    notice.className = 'notice visible error';
  } else if (s.server !== 'running' && (s.upstream_error || s.llama_upstream?.error)) {
    notice.textContent = `${t('status_down')}: ${s.upstream_error || s.llama_upstream.error}`;
    notice.className = 'notice visible error';
  } else {
    notice.className = 'notice';
  }
}

function showNotice(msg, cls, ms = 3000) {
  const el = $('notice');
  if (!msg) {
    manualNoticeUntil = 0;
    el.className = 'notice';
    return;
  }
  manualNoticeUntil = Date.now() + ms;
  el.textContent = msg;
  el.className = `notice visible ${cls || ''}`;
}

async function handleSwitch() {
  const model = $('sel-model').value;
  const profile = $('sel-profile').value;
  if (!model || !profile) return;
  try {
    const r = await fetch('/api/switch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Control-Token': controlToken },
      body: JSON.stringify({ model, profile }),
    });
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      showNotice(j.detail || `HTTP ${r.status}`, 'error');
    } else {
      await pollState();
    }
  } catch (e) {
    showNotice(e.message, 'error');
  }
}

async function runHealth() {
  app.healthRunning = true;
  render();
  showNotice(t('health_running'), '');
  try {
    const r = await fetch('/api/health', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Control-Token': controlToken },
      body: '{}',
    });
    const j = await r.json().catch(() => ({}));
    await pollState();
    if (r.ok && j.ok) {
      showNotice(`${t('health_ok')}: ${j.wall_ms}ms, gen ${fmtTps(j.generation_tps)} tok/s`, 'ok');
    } else {
      showNotice(`${t('health_failed')}: ${j.error?.message || j.error || `HTTP ${r.status}`}`, 'error', 6000);
    }
  } catch (e) {
    showNotice(`${t('health_failed')}: ${e.message}`, 'error', 6000);
  } finally {
    app.healthRunning = false;
    render();
  }
}

function renderMd(raw) {
  return marked.parse(raw || '');
}

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

function addMsg(role, opts = {}) {
  if (role === 'system') {
    const sysEl = document.createElement('div');
    sysEl.className = 'msg-system';
    sysEl.textContent = `${t('role_system')}: ${opts.text || ''}`;
    $('msgs').appendChild(sysEl);
    scrollBottom();
    return { bubble: sysEl, thinkEl: null, wrap: sysEl };
  }

  const wrap = document.createElement('div');
  wrap.className = `msg ${role}`;

  const head = document.createElement('div');
  head.className = 'msg-head';

  const lbl = document.createElement('span');
  lbl.className = 'msg-label';
  lbl.textContent = t(role === 'user' ? 'role_user' : 'role_assistant');
  head.append(lbl);

  const tools = document.createElement('span');
  tools.className = 'msg-tools';
  const copy = document.createElement('button');
  copy.type = 'button';
  copy.textContent = t('btn_copy');
  copy.title = t('btn_copy');
  copy.addEventListener('click', () => copyText(opts.text || opts.raw || ''));
  tools.append(copy);

  if (role === 'user' && Number.isInteger(opts.index)) {
    const edit = document.createElement('button');
    edit.type = 'button';
    edit.textContent = t('btn_edit');
    edit.title = t('edit_branch_notice');
    edit.addEventListener('click', () => editUserMessage(opts.index));
    tools.append(edit);
  }

  if (role === 'assistant' && Number.isInteger(opts.index)) {
    const retry = document.createElement('button');
    retry.type = 'button';
    retry.textContent = t('btn_retry');
    retry.title = t('retry_notice');
    retry.addEventListener('click', () => retryAssistant(opts.index));
    tools.append(retry);
    const cont = document.createElement('button');
    cont.type = 'button';
    cont.textContent = t('btn_continue');
    cont.title = t('btn_continue');
    cont.addEventListener('click', () => continueAssistant(opts.index));
    tools.append(cont);
  }
  head.append(tools);

  let thinkEl = null;
  if (role === 'assistant') {
    thinkEl = document.createElement('details');
    thinkEl.className = 'thinking-block';
    thinkEl.hidden = true;
    const sum = document.createElement('summary');
    sum.textContent = t('thinking_label');
    const tc = document.createElement('div');
    tc.className = 'thinking-content';
    thinkEl.append(sum, tc);
  }

  const bubble = document.createElement('div');
  bubble.className = 'bubble' + (opts.error ? ' error' : '');
  if (opts.text) bubble.textContent = opts.text;
  if (opts.html) bubble.innerHTML = opts.html;

  if (thinkEl && opts.reasoning) {
    thinkEl.hidden = false;
    thinkEl.querySelector('.thinking-content').textContent = opts.reasoning;
  }

  wrap.append(head);
  if (thinkEl) wrap.append(thinkEl);
  wrap.append(bubble);
  $('msgs').appendChild(wrap);
  scrollBottom();
  return { bubble, thinkEl, wrap };
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text || '');
    showNotice(t('copied'), 'ok', 1500);
  } catch {
    const ta = document.createElement('textarea');
    ta.value = text || '';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
    showNotice(t('copied'), 'ok', 1500);
  }
}

function scrollBottom() {
  const msgs = $('msgs');
  msgs.scrollTop = msgs.scrollHeight;
}

function autoResize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 160) + 'px';
}

function stopGeneration() {
  if (abortController) abortController.abort();
}

function editUserMessage(index) {
  if (app.isStreaming || chatHistory[index]?.role !== 'user') return;
  app.editBranch = {
    sourceId: app.activeConversationId,
    index,
  };
  const inp = $('inp');
  inp.value = chatHistory[index].content;
  autoResize(inp);
  inp.focus();
  showNotice(t('edit_branch_notice'), 'ok', 8000);
  renderControls();
}

function cancelEdit() {
  app.editBranch = null;
  $('inp').value = '';
  autoResize($('inp'));
  renderControls();
}

function retryAssistant(index) {
  if (app.isStreaming || chatHistory[index]?.role !== 'assistant') return;
  for (let i = index - 1; i >= 0; i--) {
    if (chatHistory[i]?.role === 'user') {
      app.editBranch = { sourceId: app.activeConversationId, index: i };
      $('inp').value = chatHistory[i].content;
      autoResize($('inp'));
      showNotice(t('retry_notice'), 'ok', 2500);
      sendMessage();
      return;
    }
  }
}

function continueAssistant(index) {
  if (app.isStreaming || chatHistory[index]?.role !== 'assistant') return;
  const base = cloneMessages(chatHistory.slice(0, index + 1));
  const conv = createConversation(base, `${t('branch_prefix')}: ${titleFromMessages(base)}`, app.activeConversationId, index + 1);
  app.activeConversationId = conv.id;
  chatHistory = conv.messages;
  app.editBranch = null;
  renderHistory();
  renderSidebar();
  $('inp').value = app.lang === 'en' ? 'Continue.' : '继续。';
  autoResize($('inp'));
  sendMessage();
}

async function sendMessage() {
  if (app.isStreaming) {
    stopGeneration();
    return;
  }

  const inp = $('inp');
  const content = inp.value.trim();
  if (!content || sendBlockReason()) return;

  inp.value = '';
  autoResize(inp);

  const branch = app.editBranch;
  if (branch && branch.sourceId === app.activeConversationId && chatHistory[branch.index]?.role === 'user') {
    const base = cloneMessages(chatHistory.slice(0, branch.index));
    const title = `${t('branch_prefix')}: ${content.slice(0, 38) || t('untitled_chat')}`;
    const conv = createConversation(base, title, branch.sourceId, branch.index);
    app.activeConversationId = conv.id;
    chatHistory = conv.messages;
    app.editBranch = null;
    renderHistory();
    renderSidebar();
    showNotice(t('branch_created'), 'ok', 3000);
  } else {
    app.editBranch = null;
  }

  chatHistory.push({ role: 'user', content });
  updateActiveConversation();
  addMsg('user', { text: content, index: chatHistory.length - 1 });

  const { bubble, thinkEl } = addMsg('assistant');
  bubble.classList.add('streaming');
  app.isStreaming = true;
  app.activeTimings = null;
  app.activeOutputChars = 0;
  abortController = new AbortController();
  render();

  let full = '';
  let think = '';
  let savedAssistant = false;

  try {
    const body = {
      model: app.serverState?.current?.alias || app.serverState?.served_aliases?.[0] || 'default',
      messages: chatHistory.map(m => ({ role: m.role, content: m.content })),
      stream: true,
      max_tokens: 4096,
      timings_per_token: true,
    };
    if (!app.thinkingOn) body.chat_template_kwargs = { enable_thinking: false };

    const resp = await fetch('/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: abortController.signal,
    });

    if (!resp.ok) {
      let msg = `HTTP ${resp.status}`;
      try { const j = await resp.json(); msg = j.detail || j.error?.message || msg; } catch {}
      bubble.classList.remove('streaming');
      bubble.classList.add('error');
      bubble.textContent = t('err_prefix') + msg;
      chatHistory.pop();
      updateActiveConversation();
      return;
    }

    const reader = resp.body.getReader();
    const dec = new TextDecoder();
    let buf = '';

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
        if (parsed.timings) {
          app.activeTimings = parsed.timings;
          renderRuntime();
        }
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
          app.activeOutputChars = full.length;
          bubble.innerHTML = renderMd(full);
          injectCodeCopyButtons(bubble);
          scrollBottom();
        }
      }
    }

    bubble.classList.remove('streaming');
    if (full) {
      bubble.innerHTML = renderMd(full);
      injectCodeCopyButtons(bubble);
      chatHistory.push({ role: 'assistant', content: full, reasoning_content: think || undefined });
      savedAssistant = true;
      updateActiveConversation();
    } else if (!think) {
      bubble.classList.add('error');
      bubble.textContent = t('err_empty');
      chatHistory.pop();
      updateActiveConversation();
      return;
    }
  } catch (e) {
    bubble.classList.remove('streaming');
    if (e.name === 'AbortError') {
      showNotice(t('stopped'), 'ok');
      if (full) {
        bubble.innerHTML = renderMd(full);
        injectCodeCopyButtons(bubble);
        chatHistory.push({ role: 'assistant', content: full, reasoning_content: think || undefined });
        savedAssistant = true;
        updateActiveConversation();
      } else {
        bubble.classList.add('error');
        bubble.textContent = t('stopped');
        chatHistory.pop();
      }
    } else {
      bubble.classList.add('error');
      bubble.textContent = t('err_prefix') + e.message;
      chatHistory.pop();
    }
    if (!savedAssistant) updateActiveConversation();
  } finally {
    app.isStreaming = false;
    abortController = null;
    render();
    scrollBottom();
    setTimeout(pollState, 500);
  }
}

function toggleCompressPanel() {
  const p = $('compress-panel');
  p.hidden = !p.hidden;
}

function openCompressForConversation(id) {
  app.compressConvId = id;
  app.openConversationMenu = null;
  setActiveConversation(id);  // triggers renderSidebar which places the panel
}

async function clearServerContext() {
  if (!controlToken) return;
  try {
    await fetch('/api/clear-context', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Control-Token': controlToken },
      body: '{}',
    });
  } catch { /* best-effort — cosmetic only */ }
  await pollState();
}

function stripThinking() {
  app.compressConvId = null;
  $('compress-panel').hidden = true;
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
  document.querySelectorAll('.thinking-block').forEach(el => el.remove());
  updateActiveConversation();
  showNotice(n > 0 ? t('cp_strip_done').replace('{n}', n) : t('cp_strip_none'), n > 0 ? 'ok' : '');
  clearServerContext();
}

function trimHistory() {
  app.compressConvId = null;
  $('compress-panel').hidden = true;
  const turns = Math.max(1, parseInt($('trim-n').value, 10) || 10);
  const keepN = turns * 2;
  if (chatHistory.length <= keepN) {
    showNotice(t('cp_trim_none'), '');
    return;
  }
  const removed = Math.floor((chatHistory.length - keepN) / 2);
  chatHistory = chatHistory.slice(-keepN);
  updateActiveConversation();
  renderHistory();
  showNotice(t('cp_trim_done').replace('{n}', removed), 'ok');
  clearServerContext();
}

function exportChat() {
  if (!chatHistory.length) {
    showNotice(t('export_empty'), 'error');
    return;
  }
  const conv = getActiveConversation();
  const ids = chatHistory.map(() => uid());
  const root = uid();
  const messages = chatHistory.map((m, i) => ({
    convId: conv.id,
    role: m.role,
    content: m.content,
    type: 'text',
    timestamp: conv.created_at + i,
    toolCalls: '',
    children: i + 1 < ids.length ? [ids[i + 1]] : [],
    extra: [],
    id: ids[i],
    parent: i === 0 ? root : ids[i - 1],
    reasoningContent: m.reasoning_content || '',
    timings: m.timings || undefined,
    model: m.model || conv.model || app.serverState?.current?.alias || undefined,
  }));
  const json = JSON.stringify({
    conv: {
      id: conv.id,
      name: conv.title || titleFromMessages(chatHistory),
      lastModified: Date.now(),
      currNode: ids[ids.length - 1],
    },
    messages,
  }, null, 2);
  const blob = new Blob([json], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `chat-${new Date().toISOString().slice(0, 19).replace(/:/g, '-')}.json`;
  a.click();
  URL.revokeObjectURL(url);
}

function importChat() {
  $('file-import').click();
}

function handleImport(e) {
  const file = e.target.files?.[0];
  if (!file) return;
  e.target.value = '';

  const reader = new FileReader();
  reader.onload = evt => {
    let data;
    try { data = JSON.parse(evt.target.result); } catch {
      showNotice(t('import_err'), 'error');
      return;
    }
    const imported = normalizeImportedChat(data);
    const messages = imported.messages;
    if (!messages.length) {
      showNotice(t('import_err'), 'error');
      return;
    }
    createConversation(messages, imported.title || titleFromMessages(messages));
    renderHistory();
    renderSidebar();
    showNotice(t('import_ok').replace('{n}', chatHistory.length), 'ok');
  };
  reader.readAsText(file);
}

function normalizeImportedChat(data) {
  if (Array.isArray(data)) {
    return { title: null, messages: normalizeMessages(data) };
  }

  if (data && typeof data === 'object' && Array.isArray(data.messages)) {
    const messages = normalizeLlamaWebuiMessages(data);
    return {
      title: typeof data.conv?.name === 'string' ? data.conv.name : null,
      messages,
    };
  }

  return { title: null, messages: [] };
}

function normalizeLlamaWebuiMessages(data) {
  const raw = data.messages.filter(m =>
    m && typeof m.role === 'string' && typeof m.content === 'string'
      && ['user', 'assistant', 'system'].includes(m.role)
  );
  if (!raw.length) return [];

  const byId = new Map(raw.filter(m => m.id).map(m => [m.id, m]));
  const currNode = data.conv?.currNode;
  if (currNode && byId.has(currNode)) {
    const chain = [];
    const seen = new Set();
    let cur = byId.get(currNode);
    while (cur && !seen.has(cur.id)) {
      seen.add(cur.id);
      chain.push(cur);
      cur = byId.get(cur.parent);
    }
    const ordered = chain.reverse();
    if (ordered.length) return normalizeMessages(ordered);
  }

  return normalizeMessages(raw.slice().sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0)));
}

function normalizeMessages(data) {
  const known = new Set(['user', 'assistant', 'system']);
  if (!Array.isArray(data)) return [];
  return data
    .filter(m => m && typeof m.role === 'string' && known.has(m.role))
    .map(m => ({
      role: m.role,
      content: typeof m.content === 'string' ? m.content : String(m.content ?? ''),
      reasoning_content: typeof m.reasoning_content === 'string' ? m.reasoning_content
        : typeof m.reasoningContent === 'string' ? m.reasoningContent : undefined,
      timings: m.timings || undefined,
      model: m.model || undefined,
    }))
    .filter(m => m.content.length > 0);
}

function renderHistory() {
  $('msgs').innerHTML = '';
  chatHistory.forEach((m, index) => {
    if (m.role === 'user') {
      const { wrap } = addMsg('user', { text: m.content, raw: m.content, index });
      appendBranchNav(wrap, index);
    } else if (m.role === 'system') {
      addMsg('system', { text: m.content });
    } else {
      const { bubble } = addMsg('assistant', { html: renderMd(m.content), raw: m.content, reasoning: m.reasoning_content, index });
      injectCodeCopyButtons(bubble);
    }
  });
  // Continuation branches (continue-assistant) attach after the last message
  const lastChild = $('msgs').lastElementChild;
  if (lastChild) appendBranchNav(lastChild, chatHistory.length);
  scrollBottom();
}

function clearConversation(id = app.activeConversationId) {
  const conv = conversations.find(c => c.id === id);
  if (!conv || !(conv.messages || []).length) return;
  if (!confirm(t('clear_confirm'))) return;
  conv.messages = [];
  conv.updated_at = Date.now();
  if (app.activeConversationId === id) {
    chatHistory = conv.messages;
    $('msgs').innerHTML = '';
  }
  saveConversations();
  renderSidebar();
  renderDetailsPane();
}

async function init() {
  marked.setOptions({ gfm: true, breaks: true });
  applyTheme();
  applyI18n();
  loadConversations();
  renderHistory();
  renderSidebar();

  $('btn-send').addEventListener('click', sendMessage);
  $('btn-switch').addEventListener('click', handleSwitch);
  $('btn-thinking').addEventListener('click', toggleThinking);
  $('btn-theme').addEventListener('click', toggleTheme);
  $('btn-health').addEventListener('click', runHealth);
  $('btn-compress').addEventListener('click', toggleCompressPanel);
  $('btn-strip').addEventListener('click', stripThinking);
  $('btn-trim').addEventListener('click', trimHistory);
  $('btn-export').addEventListener('click', exportChat);
  $('btn-import').addEventListener('click', importChat);
  $('file-import').addEventListener('change', handleImport);
  $('btn-new-chat').addEventListener('click', newConversation);
  $('btn-side-menu').addEventListener('click', e => {
    e.stopPropagation();
    $('side-menu').hidden = !$('side-menu').hidden;
  });
  $('btn-details').addEventListener('click', () => toggleDetailsPane());
  $('btn-close-details').addEventListener('click', () => toggleDetailsPane(false));

  document.addEventListener('click', e => {
    const panel = $('compress-panel');
    if (panel && !panel.hidden && !e.target.closest('#compress-panel')) {
      panel.hidden = true;
      app.compressConvId = null;
    }
    const sideMenu = $('side-menu');
    if (sideMenu && !sideMenu.hidden && !e.target.closest('.side-menu-wrap')) sideMenu.hidden = true;
    if (!e.target.closest('.conv-item')) {
      if (app.openConversationMenu) {
        app.openConversationMenu = null;
        renderSidebar();
      }
    }
  });

  const inp = $('inp');
  inp.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
  });
  inp.addEventListener('input', () => autoResize(inp));
  $('conv-search').addEventListener('input', e => {
    app.convSearch = e.target.value;
    renderSidebar();
  });
  $('btn-cancel-edit').addEventListener('click', cancelEdit);

  await pollState();
  await Promise.all([loadModels(), loadProfiles()]);
  render();
  setInterval(pollState, 2000);
}

document.addEventListener('DOMContentLoaded', init);
