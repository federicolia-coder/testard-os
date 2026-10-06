// Testard OS installer: collects the answers and hands them to
// testard-install through the small CGI backend in cgi-bin/.
"use strict";

const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const ORDER = ["welcome", "mode", "system", "account", "apps", "disk", "review"];

const KEYBOARDS = [
  ["us", "English (US)"], ["gb", "English (UK)"], ["it", "Italiano"], ["de", "Deutsch"],
  ["fr", "Français"], ["es", "Español"], ["pt", "Português"], ["ch", "Schweiz"],
  ["be", "Belgique"], ["nl", "Nederlands"], ["se", "Svenska"], ["no", "Norsk"],
  ["dk", "Dansk"], ["fi", "Suomi"], ["pl", "Polski"], ["cz", "Čeština"],
  ["hu", "Magyar"], ["gr", "Ελληνικά"], ["tr", "Türkçe"], ["ru", "Русский"],
];

const valid = {
  host: (v) => /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(v),
  user: (v) => /^[a-z_][a-z0-9_-]{0,31}$/.test(v) && v !== "root",
  github: (v) => v === "" || /^[A-Za-z0-9-]{1,39}$/.test(v),
  sshkey: (v) => v === "" || /^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+( [^ ]*)*$/.test(v),
  ports: (v) => v === "" || /^[0-9]{1,5}(-[0-9]{1,5})?(\/(tcp|udp))?(,[0-9]{1,5}(-[0-9]{1,5})?(\/(tcp|udp))?)*$/.test(v)
    && v.split(/[,-]/).every((p) => { const n = parseInt(p, 10); return n >= 1 && n <= 65535; }),
  agent: (v) => v === "" || /^tsk_[A-Za-z0-9_-]{43}$/.test(v),
};

let info = { disks: [], timezones: [], keyboard: "us" };
let current = "welcome";
let hostTouched = false;

async function api(path, body) {
  const opts = body
    ? { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(body) }
    : {};
  const res = await fetch(`cgi-bin/${path}`, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

function show(step) {
  current = step;
  $$(".step").forEach((s) => s.classList.toggle("active", s.dataset.step === step));
  const idx = ORDER.indexOf(step);
  $$("#steps li").forEach((li) => {
    const i = ORDER.indexOf(li.dataset.step);
    li.classList.toggle("current", li.dataset.step === step);
    li.classList.toggle("done", (idx > i && idx !== -1) || ["installing", "done"].includes(step));
  });
  if (step === "review") fillReview();
  const first = $(`.step[data-step="${step}"] input:not([type=radio]):not([type=checkbox]), .step[data-step="${step}"] select`);
  if (first && step !== "welcome") first.focus();
  window.scrollTo(0, 0);
}

function setError(id, message) {
  const el = $(`#${id}-error`);
  const input = $(`#${id}`);
  if (el) el.textContent = message || "";
  if (input) input.setAttribute("aria-invalid", message ? "true" : "false");
  return !message;
}

const mode = () => $('input[name="mode"]:checked').value;

function check(step) {
  switch (step) {
    case "system":
      return setError("host", valid.host($("#host").value) ? "" : "Use lower case letters, digits and dashes, e.g. homelab-1.");
    case "account": {
      const pw = $("#pw").value;
      let ok = setError("user", valid.user($("#user").value) ? "" : "Lower case letters, digits, - or _, e.g. mario. Not root.");
      ok = setError("pw", pw.length >= 8 ? "" : "At least 8 characters, please.") && ok;
      ok = setError("pw2", pw === $("#pw2").value ? "" : "The two passwords don't match.") && ok;
      ok = setError("github", valid.github($("#github").value.trim()) ? "" : "That isn't a GitHub username.") && ok;
      ok = setError("sshkey", valid.sshkey($("#sshkey").value.trim()) ? "" : "That doesn't look like a public key. It starts with ssh-ed25519 or ssh-rsa.") && ok;
      return ok;
    }
    case "apps": {
      const ports = $("#ports").value.replace(/\s+/g, "");
      let ok = setError("ports", valid.ports(ports) ? "" : "Use ports like 80,443,8000-8100,51820/udp.");
      ok = setError("agent", valid.agent($("#agent").value.trim()) ? "" : "An agent key starts with tsk_ and is 47 characters long.") && ok;
      return ok;
    }
    case "disk":
      return !!$('input[name="disk"]:checked');
    default:
      return true;
  }
}

function applyModeDefaults() {
  const m = mode();
  if (!hostTouched) $("#host").value = m === "homelab" ? "homelab" : "server";
  $("#docker").checked = m === "homelab";
  $("#ports-hint").textContent = m === "homelab"
    ? "Reachable only from devices on your network."
    : "Reachable from the internet.";
}

function answers() {
  const ports = $("#ports").value.replace(/\s+/g, "");
  return {
    KB: $("#kb").value,
    MODE: mode(),
    HOST: $("#host").value,
    TZ: $("#tz").value,
    ADMIN: $("#user").value,
    PASSWORD: $("#pw").value,
    GITHUB: $("#github").value.trim(),
    SSH_KEY: $("#sshkey").value.trim().replace(/\s+/g, " "),
    CONTAINERS: $("#docker").checked ? "docker" : "none",
    OPEN_PORTS: ports,
    AGENT_KEY: $("#agent").value.trim(),
    DISK: $('input[name="disk"]:checked')?.value || "",
  };
}

function fillReview() {
  const a = answers();
  const disk = info.disks.find((d) => d.name === a.DISK);
  const ssh = a.GITHUB ? `Keys from github.com/${a.GITHUB}` : a.SSH_KEY ? "The key you pasted" : "None yet: password login stays on";
  const rows = [
    ["Use", a.MODE === "homelab" ? "Homelab" : "Server"],
    ["Name", a.HOST + (a.MODE === "homelab" ? ` (${a.HOST}.local)` : ""), true],
    ["Time zone", a.TZ],
    ["User", a.ADMIN, true],
    ["SSH", ssh],
    ["Docker", a.CONTAINERS === "docker" ? "Yes, with Compose" : "No"],
    ["Open ports", (a.OPEN_PORTS ? `SSH, ${a.OPEN_PORTS}` : "SSH only") + (a.MODE === "homelab" ? ", from your network" : ""), true],
    ["Testard", a.AGENT_KEY ? "Connected with the agent" : "Not connected"],
    ["Disk", disk ? `${disk.name}, ${disk.gb} GB${disk.model ? ` (${disk.model})` : ""}` : a.DISK, true],
  ];
  const dl = $("#summary");
  dl.replaceChildren(...rows.map(([k, v, mono]) => {
    const div = document.createElement("div");
    const dt = document.createElement("dt"); dt.textContent = k;
    const dd = document.createElement("dd"); dd.textContent = v; if (mono) dd.className = "mono";
    div.append(dt, dd);
    return div;
  }));
  $("#erase-disk").textContent = a.DISK;
  $("#confirm").checked = false;
  $("#install").disabled = true;
  $("#install-error").textContent = "";
}

function renderDisks() {
  const box = $("#disks");
  box.replaceChildren(...info.disks.map((d, i) => {
    const label = document.createElement("label");
    label.className = "choice";
    label.innerHTML = '<input type="radio" name="disk"><span class="title"></span><span class="meta"></span>';
    const input = label.querySelector("input");
    input.value = d.name;
    input.checked = i === 0;
    label.querySelector(".title").textContent = d.model || d.name;
    label.querySelector(".meta").textContent = `/dev/${d.name} · ${d.gb} GB`;
    return label;
  }));
  $("#no-disks").hidden = info.disks.length > 0;
}

async function pollProgress() {
  try {
    const p = await api("progress");
    if (p.state === "done") {
      $("#done-user").textContent = $("#user").value;
      $("#done-local").textContent = mode() === "homelab" ? `, or connect to ${$("#host").value}.local from your computer` : "";
      show("done");
      return;
    }
    if (p.state === "failed") {
      $("#fail-text").textContent = p.text || "Something went wrong.";
      show("failed");
      return;
    }
    const pct = Math.max(2, Math.min(100, p.percent || 0));
    $("#bar span").style.width = `${pct}%`;
    $("#bar").setAttribute("aria-valuenow", String(pct));
    $("#now").textContent = p.text || "Working";
    $("#pct").textContent = `${pct}%`;
  } catch {
    // The backend is busy for a moment; try again.
  }
  setTimeout(pollProgress, 1000);
}

async function init() {
  $("#kb").replaceChildren(...KEYBOARDS.map(([v, l]) => new Option(l, v)));
  show("welcome");
  const start = $('.step[data-step="welcome"] [data-next]');
  start.disabled = true; // until the disks and time zones are in
  try {
    info = await api("info");
  } catch {
    $("#net").textContent = "The installer backend isn't answering.";
    $("#net").classList.add("off");
  }
  $("#version").textContent = info.version || "";
  $("#kb").value = info.keyboard || "us";
  const tz = $("#tz");
  tz.replaceChildren(...(info.timezones || ["UTC"]).map((z) => new Option(z.replace(/_/g, " "), z)));
  tz.value = (info.timezones || []).includes("Europe/Rome") ? "Europe/Rome" : "UTC";
  renderDisks();
  if (info.ip) {
    $("#net").textContent = `Connected to the network (${info.ip})`;
  } else if (info.timezones) {
    $("#net").textContent = "No network: connect a cable for SSH keys from GitHub and updates. Installing works without it.";
    $("#net").classList.add("off");
  }
  applyModeDefaults();
  start.disabled = false;
}

document.addEventListener("click", async (e) => {
  const t = e.target.closest("button");
  if (!t) return;
  if (t.hasAttribute("data-next")) {
    if (!check(current)) return;
    show(ORDER[ORDER.indexOf(current) + 1]);
  } else if (t.hasAttribute("data-back")) {
    show(ORDER[Math.max(0, ORDER.indexOf(current) - 1)]);
  } else if (t.dataset.goto) {
    show(t.dataset.goto);
  } else if (t.id === "install") {
    t.disabled = true;
    try {
      await api("install", answers());
      $("#pw").value = ""; $("#pw2").value = "";
      show("installing");
      pollProgress();
    } catch (err) {
      $("#install-error").textContent = err.message;
      t.disabled = false;
    }
  } else if (t.id === "reboot") {
    t.disabled = true;
    t.textContent = "Restarting…";
    api("reboot", { now: "1" }).catch(() => {});
  }
});

$$('input[name="mode"]').forEach((r) => r.addEventListener("change", applyModeDefaults));
$("#host").addEventListener("input", () => { hostTouched = true; });
$("#confirm").addEventListener("change", (e) => { $("#install").disabled = !e.target.checked; });
$("#kb").addEventListener("change", async (e) => {
  // The screen's keyboard layout is fixed when it starts, so it restarts.
  try { await api("keyboard", { layout: e.target.value }); } catch { /* keep going */ }
});
document.addEventListener("keydown", (e) => {
  if (e.key !== "Enter" || e.target.tagName === "TEXTAREA" || e.target.tagName === "BUTTON") return;
  const next = $(`.step.active [data-next]`);
  if (next) { e.preventDefault(); next.click(); }
});

init();
