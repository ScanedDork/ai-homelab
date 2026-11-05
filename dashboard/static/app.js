// Homelab dashboard client. Vanilla JS, no dependencies.
// All upstream data is rendered with textContent (never innerHTML).
"use strict";

const TOKEN_KEY = "homelab-dashboard-token";
const state = {
  config: null,
  refreshTimer: null,
  lastUpdated: null,
  conversation: [],
  abort: null,
};

// ---------------------------------------------------------------- helpers
const $ = (sel) => document.querySelector(sel);

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") node.className = v;
    else if (k === "text") node.textContent = v;
    else node.setAttribute(k, v === true ? "" : String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

function storage(fn) {
  try { return fn(window.localStorage); } catch { return null; }
}
const getToken = () => storage((s) => s.getItem(TOKEN_KEY)) || "";
const setToken = (t) => storage((s) => s.setItem(TOKEN_KEY, t));
const clearToken = () => storage((s) => s.removeItem(TOKEN_KEY));

function formatBytes(n) {
  if (typeof n !== "number" || !isFinite(n)) return "–";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
  return `${n.toFixed(i >= 3 ? 1 : 0)} ${units[i]}`;
}

function timeAgo(date) {
  const s = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  return `${Math.round(s / 3600)} h ago`;
}

class AuthError extends Error {}

async function api(path, options = {}) {
  const headers = { ...(options.headers || {}), Authorization: `Bearer ${getToken()}` };
  const res = await fetch(path, { ...options, headers });
  if (res.status === 401) {
    askForToken("That token was not accepted.");
    throw new AuthError("unauthorized");
  }
  return res;
}

async function apiJson(path) {
  const res = await api(path);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

// ---------------------------------------------------------------- token
function askForToken(message) {
  const dialog = $("#token-dialog");
  const err = $("#token-error");
  err.hidden = !message || !getToken();
  err.textContent = message || "";
  if (!dialog.open) dialog.showModal();
  $("#token-input").focus();
}

function initTokenDialog() {
  $("#token-form").addEventListener("submit", () => {
    const value = $("#token-input").value.trim();
    if (value) {
      setToken(value);
      $("#token-input").value = "";
      boot();
    }
  });
  $("#forget-token").addEventListener("click", () => {
    clearToken();
    askForToken("");
  });
}

// ---------------------------------------------------------------- tabs
function showTab(name) {
  const valid = ["overview", "models", "playground"];
  const tab = valid.includes(name) ? name : "overview";
  for (const v of valid) {
    $(`#view-${v}`).hidden = v !== tab;
    const link = document.querySelector(`.tab[data-tab="${v}"]`);
    if (v === tab) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  if (tab === "models") loadModels();
  if (tab === "playground") loadGroups();
}

// ---------------------------------------------------------------- overview
const SERVICE_LABELS = {
  n8n: "n8n",
  litellm: "LiteLLM proxy",
  openclaw: "OpenClaw gateway",
  backups: "n8n backups",
  ollama: "Ollama",
  "ollama-models": "Required models",
};

function renderStatus(data) {
  const overall = $("#overall");
  const labels = { OK: "All systems OK", WARN: "Needs attention", FAIL: "Problems detected" };
  overall.className = `pill pill-${data.overall}`;
  overall.textContent = labels[data.overall] || data.overall;

  const counts = $("#counts");
  counts.replaceChildren(...["OK", "WARN", "FAIL", "SKIP"].map((s) =>
    el("div", { class: "count" },
      el("span", { class: `pill pill-${s}`, text: s }),
      el("strong", { text: data.counts[s] ?? 0 }))));

  const devices = $("#devices");
  devices.replaceChildren(...data.devices.map((device) => {
    const checks = data.checks.filter((c) => c.device === device);
    return el("div", { class: "panel device" },
      el("div", { class: "panel-head" },
        el("h2", {}, device,
          el("span", { class: "muted small", text: device === data.devices[0] ? "Raspberry Pi" : "Mac Mini" }))),
      checks.map((c) => el("div", { class: "service" },
        el("div", { class: "service-name" },
          el("span", { class: `pill pill-${c.status}`, text: c.status }),
          SERVICE_LABELS[c.name] || c.name,
          c.link ? el("a", { href: c.link, target: "_blank", rel: "noopener noreferrer", class: "small" }, "open ↗") : null),
        el("div", { class: "service-meta", text: c.latency_ms !== undefined ? `${c.latency_ms} ms` : "" }),
        el("div", { class: "service-detail", text: c.detail }))));
  }));
}

function renderBackups(b) {
  const dl = $("#backups");
  if (!b.available) {
    dl.replaceChildren(el("dt", { text: "Status" }), el("dd", {}, el("span", { class: "pill pill-WARN", text: "UNKNOWN" }), " ", b.error));
    return;
  }
  const status = b.result !== "ok" ? "FAIL" : b.stale ? "WARN" : "OK";
  const rows = [
    ["Status", el("span", {}, el("span", { class: `pill pill-${status}`, text: b.result }), " ", b.message || "")],
    ["Last run", `${b.last_run} (${b.age_hours ?? "?"} h ago${b.stale ? `, older than ${b.max_age_hours} h` : ""})`],
    ["Latest archive", b.archive ? `${b.archive} · ${formatBytes(b.size_bytes)}` : "–"],
    ["Archives kept", `${b.archive_count ?? "?"} of ${b.retention ?? "?"}`],
    ["SHA-256", b.sha256 ? el("code", { text: b.sha256.slice(0, 16) + "…", title: b.sha256 }) : "–"],
  ];
  dl.replaceChildren(...rows.flatMap(([k, v]) => [el("dt", { text: k }), el("dd", {}, v)]));
}

async function refresh() {
  const btn = $("#refresh");
  btn.disabled = true;
  try {
    const [status, backups] = await Promise.all([apiJson("/api/status"), apiJson("/api/backups")]);
    renderStatus(status);
    renderBackups(backups);
    state.lastUpdated = new Date();
    if (!$("#view-models").hidden) loadModels();
  } catch (e) {
    if (!(e instanceof AuthError)) {
      $("#overall").className = "pill pill-FAIL";
      $("#overall").textContent = `Dashboard API error: ${e.message}`;
    }
  } finally {
    btn.disabled = false;
    tickUpdated();
  }
}

function tickUpdated() {
  $("#updated").textContent = state.lastUpdated ? `Updated ${timeAgo(state.lastUpdated)}` : "";
}

// ---------------------------------------------------------------- models
async function loadModels() {
  let data;
  try { data = await apiJson("/api/models"); } catch (e) {
    if (!(e instanceof AuthError)) $("#ollama-alert").replaceChildren(el("div", { class: "alert alert-FAIL", text: e.message }));
    return;
  }
  const o = data.ollama || {};
  $("#ollama-url").textContent = o.url || "";
  const alert = $("#ollama-alert");
  const tbody = $("#models-table tbody");
  if (o.error) {
    alert.replaceChildren(el("div", { class: "alert alert-FAIL", text: `Ollama unreachable: ${o.error}` }));
    tbody.replaceChildren();
  } else {
    alert.replaceChildren(...(o.missing_required?.length
      ? [el("div", { class: "alert alert-WARN" }, "Missing required models: ",
          el("code", { text: o.missing_required.join(", ") }), " — run ", el("code", { text: "./mac/pull-models.sh" }))]
      : []));
    tbody.replaceChildren(...(o.installed.length ? o.installed.map((m) => el("tr", {},
      el("td", {}, el("code", { text: m.name })),
      el("td", { text: m.parameter_size || "–" }),
      el("td", { text: m.quantization || "–" }),
      el("td", { class: "num", text: formatBytes(m.size_bytes) }),
      el("td", {},
        m.loaded ? el("span", { class: "badge badge-loaded", text: "loaded" }) : null,
        m.required ? el("span", { class: "badge badge-required", text: "required" }) : null)))
      : [el("tr", {}, el("td", { colspan: 5, class: "muted", text: "No models installed." }))]));
  }
  renderGroups(data.litellm || {});
}

function renderGroups(l) {
  const box = $("#groups");
  if (l.error) {
    box.replaceChildren(el("div", { class: "alert alert-FAIL", text: `LiteLLM: ${l.error}` }));
    return;
  }
  box.replaceChildren(...(l.groups || []).map((g) => el("div", { class: "chip" },
    el("code", { text: g.id }),
    el("span", { class: g.local ? "badge badge-loaded" : "badge badge-cloud", text: g.local ? "local" : "cloud" }))));
}

// ---------------------------------------------------------------- playground
async function loadGroups() {
  const select = $("#model");
  if (select.options.length) return;
  try {
    const data = await apiJson("/api/models");
    const groups = (data.litellm && data.litellm.groups) || [];
    select.replaceChildren(...groups.map((g) => el("option", { value: g.id, text: g.local ? `${g.id} (local first)` : g.id })));
    const preferred = groups.find((g) => g.id === "local-chat");
    if (preferred) select.value = preferred.id;
    if (!groups.length) select.append(el("option", { value: "", text: "LiteLLM unavailable" }));
  } catch (e) {
    if (!(e instanceof AuthError)) select.replaceChildren(el("option", { value: "", text: `Error: ${e.message}` }));
  }
}

function addMessage(role, text, extraClass = "") {
  const transcript = $("#transcript");
  transcript.querySelector(".empty")?.remove();
  const body = el("div", { class: "msg-body", text });
  const msg = el("div", { class: `msg msg-${role} ${extraClass}`.trim() }, body);
  transcript.append(msg);
  transcript.scrollTop = transcript.scrollHeight;
  return { msg, body };
}

function setBusy(busy) {
  $("#send").hidden = busy;
  $("#stop").hidden = !busy;
  $("#prompt").disabled = busy;
}

async function sendPrompt(text) {
  const model = $("#model").value;
  if (!model) { addMessage("error", "No model group available; is LiteLLM running?"); return; }
  const system = $("#system").value.trim();
  state.conversation.push({ role: "user", content: text });
  addMessage("user", text);
  const messages = system ? [{ role: "system", content: system }, ...state.conversation] : [...state.conversation];

  const { msg, body } = addMessage("assistant", "", "streaming");
  const started = performance.now();
  state.abort = new AbortController();
  setBusy(true);
  let answer = "";
  try {
    const res = await api("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model, messages, stream: true, temperature: Number($("#temperature").value) }),
      signal: state.abort.signal,
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || `HTTP ${res.status}`);
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop();
      for (const line of lines) {
        if (!line.startsWith("data:")) continue;
        const data = line.slice(5).trim();
        if (!data || data === "[DONE]") continue;
        try {
          const delta = JSON.parse(data).choices?.[0]?.delta?.content;
          if (delta) {
            answer += delta;
            body.textContent = answer;
            $("#transcript").scrollTop = $("#transcript").scrollHeight;
          }
        } catch { /* ignore keep-alive or partial lines */ }
      }
    }
    state.conversation.push({ role: "assistant", content: answer });
    const group = res.headers.get("X-Model-Group") || model;
    const fallbacks = Number(res.headers.get("X-Attempted-Fallbacks") || 0);
    const secs = ((performance.now() - started) / 1000).toFixed(1);
    msg.append(el("div", { class: "msg-meta",
      text: `via ${group}${fallbacks ? ` · ${fallbacks} fallback${fallbacks > 1 ? "s" : ""} (local unavailable)` : ""} · ${secs}s` }));
    if (!answer) body.textContent = "(empty response)";
  } catch (e) {
    state.conversation.pop();
    if (e.name === "AbortError") {
      msg.append(el("div", { class: "msg-meta", text: "stopped" }));
    } else if (!(e instanceof AuthError)) {
      msg.remove();
      addMessage("error", e.message);
    } else {
      msg.remove();
    }
  } finally {
    msg.classList.remove("streaming");
    state.abort = null;
    setBusy(false);
    $("#prompt").focus();
  }
}

function initPlayground() {
  const temp = $("#temperature");
  temp.addEventListener("input", () => { $("#temp-out").textContent = temp.value; });
  $("#composer").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const prompt = $("#prompt");
    const text = prompt.value.trim();
    if (!text || state.abort) return;
    prompt.value = "";
    sendPrompt(text);
  });
  $("#prompt").addEventListener("keydown", (ev) => {
    if (ev.key === "Enter" && !ev.shiftKey && !ev.isComposing) {
      ev.preventDefault();
      $("#composer").requestSubmit();
    }
  });
  $("#stop").addEventListener("click", () => state.abort?.abort());
  $("#clear").addEventListener("click", () => {
    state.conversation = [];
    $("#transcript").replaceChildren(el("p", { class: "empty muted", text: "Conversation cleared." }));
  });
}

// ---------------------------------------------------------------- boot
async function boot() {
  if (!getToken()) { askForToken(""); return; }
  try {
    state.config = await apiJson("/api/config");
  } catch (e) {
    if (!(e instanceof AuthError)) {
      $("#overall").className = "pill pill-FAIL";
      $("#overall").textContent = `Dashboard API error: ${e.message}`;
    }
    return;
  }
  $("#version").textContent = `dashboard v${state.config.version}`;
  $("#link-n8n").href = state.config.links.n8n;
  if (state.config.links.openclaw) {
    $("#link-openclaw").href = state.config.links.openclaw;
    $("#link-openclaw-wrap").hidden = false;
  }
  clearInterval(state.refreshTimer);
  state.refreshTimer = setInterval(refresh, Math.max(10, state.config.refresh_seconds) * 1000);
  showTab(location.hash.slice(1));
  refresh();
}

document.addEventListener("DOMContentLoaded", () => {
  initTokenDialog();
  initPlayground();
  $("#refresh").addEventListener("click", refresh);
  window.addEventListener("hashchange", () => showTab(location.hash.slice(1)));
  setInterval(tickUpdated, 5000);
  boot();
});
