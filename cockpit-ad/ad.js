/* AD Users & Groups - Cockpit page for a Samba AD DC.
 * Reads the directory with ldbsearch and changes it with samba-tool, both run as root
 * through Cockpit's "Administrative access" (superuser). */
"use strict";

const SAM = "/var/lib/samba/private/sam.ldb";
const $ = (s) => document.querySelector(s);
const state = { users: [], groups: [], computers: [] };

/* ---------------------------------------------------------------- helpers */
function run(args) {
  return cockpit.spawn(args, { superuser: "require", err: "message" });
}
function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function notify(msg, kind) {
  const el = $("#status");
  el.textContent = msg || "";
  el.className = msg ? kind : "";
}
const cn = (dn) => { const m = /^CN=((?:\\,|[^,])+)/i.exec(dn || ""); return m ? m[1].replace(/\\,/g, ",") : dn; };
const first = (e, k) => (e[k] || [])[0] || "";
const isTrue = (e, k) => first(e, k).toUpperCase() === "TRUE";

function parseLdif(text) {
  const out = [];
  const lines = [];
  for (const l of text.replace(/\r/g, "").split("\n")) {
    if (l.startsWith(" ") && lines.length) lines[lines.length - 1] += l.slice(1);
    else lines.push(l);
  }
  let cur = null;
  for (const l of lines) {
    if (l === "") { if (cur) out.push(cur); cur = null; continue; }
    if (l.startsWith("#")) continue;
    const m = /^([A-Za-z0-9;-]+)(::?) ?(.*)$/.exec(l);
    if (!m) continue;
    let v = m[3];
    if (m[2] === "::") {
      try { v = new TextDecoder().decode(Uint8Array.from(atob(v), (c) => c.charCodeAt(0))); } catch (e) { /* keep raw */ }
    }
    cur = cur || {};
    const k = m[1].toLowerCase();
    (cur[k] = cur[k] || []).push(v);
  }
  if (cur) out.push(cur);
  return out.filter((e) => e.dn);
}

async function ldb(filter, attrs) {
  return parseLdif(await run(["ldbsearch", "-H", SAM, filter, ...attrs]));
}

function fmtFiletime(v) {
  if (!v || v === "0") return "never";
  const ms = Number(v) / 1e4 - 11644473600000;
  return new Date(ms).toLocaleString();
}
function fmtGeneralized(v) {
  const m = /^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)/.exec(v || "");
  return m ? new Date(Date.UTC(m[1], m[2] - 1, m[3], m[4], m[5], m[6])).toLocaleDateString() : "";
}

/* ---------------------------------------------------------------- dialog */
function ask(title, msg, fields, okLabel) {
  return new Promise((resolve) => {
    const dlg = $("#dlg"), box = $("#dlg-fields"), form = $("#dlg-form");
    $("#dlg-title").textContent = title;
    $("#dlg-msg").textContent = msg || "";
    $("#dlg-ok").textContent = okLabel || "OK";
    $("#dlg-ok").className = /delete|remove/i.test(okLabel || "") ? "danger" : "primary";
    box.innerHTML = "";
    for (const f of fields || []) {
      const lab = document.createElement("label");
      let input;
      if (f.type === "select") {
        input = document.createElement("select");
        for (const o of f.options) {
          const op = document.createElement("option");
          op.value = o; op.textContent = o;
          input.appendChild(op);
        }
      } else {
        input = document.createElement("input");
        input.type = f.type || "text";
        if (f.type === "checkbox") input.checked = !!f.value;
        if (f.type === "password") input.autocomplete = "new-password";
        if (f.required) input.required = true;
      }
      input.name = f.name;
      if (f.type === "checkbox") { lab.className = "check"; lab.append(input, " " + f.label); }
      else lab.append(f.label, input);
      box.appendChild(lab);
    }
    const done = (val) => {
      form.onsubmit = null; dlg.onclose = null; $("#dlg-cancel").onclick = null;
      if (dlg.open) dlg.close();
      resolve(val);
    };
    form.onsubmit = (ev) => {
      ev.preventDefault();
      const v = {};
      for (const f of fields || []) {
        const el = form.elements[f.name];
        v[f.name] = f.type === "checkbox" ? el.checked : el.value;
      }
      done(v);
    };
    $("#dlg-cancel").onclick = () => done(null);
    dlg.onclose = () => done(null);
    dlg.showModal();
  });
}

/* ---------------------------------------------------------------- load */
async function loadUsers() {
  const es = await ldb("(&(objectClass=user)(!(objectClass=computer)))",
    ["sAMAccountName", "displayName", "givenName", "sn", "mail", "userAccountControl", "memberOf", "isCriticalSystemObject"]);
  state.users = es.map((e) => ({
    name: first(e, "samaccountname"),
    display: first(e, "displayname") || [first(e, "givenname"), first(e, "sn")].join(" ").trim(),
    mail: first(e, "mail"),
    disabled: (parseInt(first(e, "useraccountcontrol") || "0", 10) & 2) !== 0,
    groups: (e.memberof || []).map(cn).sort(),
    builtin: isTrue(e, "iscriticalsystemobject"),
  })).filter((u) => u.name && u.name !== "krbtgt").sort((a, b) => a.name.localeCompare(b.name));
}

async function loadGroups() {
  const es = await ldb("(objectClass=group)", ["sAMAccountName", "description", "member", "isCriticalSystemObject"]);
  state.groups = es.map((e) => ({
    name: first(e, "samaccountname"),
    desc: first(e, "description"),
    members: (e.member || []).map(cn).sort(),
    builtin: isTrue(e, "iscriticalsystemobject"),
  })).filter((g) => g.name).sort((a, b) => a.name.localeCompare(b.name));
}

async function loadComputers() {
  const es = await ldb("(objectClass=computer)",
    ["sAMAccountName", "dNSHostName", "operatingSystem", "operatingSystemVersion", "lastLogonTimestamp", "whenCreated", "userAccountControl"]);
  state.computers = es.map((e) => ({
    name: first(e, "samaccountname"),
    dns: first(e, "dnshostname"),
    os: [first(e, "operatingsystem"), first(e, "operatingsystemversion")].join(" ").trim(),
    last: fmtFiletime(first(e, "lastlogontimestamp")),
    created: fmtGeneralized(first(e, "whencreated")),
    isDC: (parseInt(first(e, "useraccountcontrol") || "0", 10) & 8192) !== 0,
  })).sort((a, b) => a.name.localeCompare(b.name));
}

async function loadAll() {
  try {
    await Promise.all([loadUsers(), loadGroups(), loadComputers()]);
    render();
  } catch (e) {
    const m = String(e.message || e);
    notify(/access-denied|not-authorized|superuser/i.test(m)
      ? "Administrative access is required. Click \"Limited access\" in the top bar and enter your password."
      : "Could not read the directory:\n" + m, "err");
  }
}

/* ---------------------------------------------------------------- render */
function render() {
  const q = $("#user-filter").value.trim().toLowerCase();
  $("#user-rows").innerHTML = state.users
    .filter((u) => !q || (u.name + " " + u.display + " " + u.mail).toLowerCase().includes(q))
    .map((u) => `<tr>
      <td><strong>${esc(u.name)}</strong></td>
      <td>${esc(u.display)}</td>
      <td>${esc(u.mail)}</td>
      <td>${u.groups.map((g) => `<span class="pill">${esc(g)}</span>`).join("")}</td>
      <td class="${u.disabled ? "off" : "on"}">${u.disabled ? "Disabled" : "Enabled"}</td>
      <td class="actions" data-user="${esc(u.name)}">
        <button type="button" data-act="pw">Reset password</button>
        <button type="button" data-act="toggle">${u.disabled ? "Enable" : "Disable"}</button>
        <button type="button" data-act="groups">Groups</button>
        ${u.builtin ? "" : '<button type="button" class="danger" data-act="del">Delete</button>'}
      </td></tr>`).join("") || '<tr><td colspan="6" class="hint">No users</td></tr>';

  const showBuiltin = $("#show-builtin").checked;
  $("#group-rows").innerHTML = state.groups
    .filter((g) => showBuiltin || !g.builtin)
    .map((g) => `<tr>
      <td><strong>${esc(g.name)}</strong></td>
      <td>${esc(g.desc)}</td>
      <td>${g.members.map((m) => `<span class="pill">${esc(m)}</span>`).join("") || '<span class="hint">-</span>'}</td>
      <td class="actions" data-group="${esc(g.name)}">
        <button type="button" data-act="add">Add member</button>
        ${g.members.length ? '<button type="button" data-act="remove">Remove member</button>' : ""}
        ${g.builtin ? "" : '<button type="button" class="danger" data-act="del">Delete</button>'}
      </td></tr>`).join("") || '<tr><td colspan="4" class="hint">No groups</td></tr>';

  $("#computer-rows").innerHTML = state.computers.map((c) => `<tr>
      <td><strong>${esc(c.name.replace(/\$$/, ""))}</strong>${c.isDC ? ' <span class="pill">DC</span>' : ""}</td>
      <td>${esc(c.dns)}</td><td>${esc(c.os)}</td><td>${esc(c.last)}</td><td>${esc(c.created)}</td>
      <td class="actions" data-computer="${esc(c.name)}">
        ${c.isDC ? "" : '<button type="button" class="danger" data-act="del">Remove from domain</button>'}
      </td></tr>`).join("") || '<tr><td colspan="6" class="hint">No computers joined yet</td></tr>';
}

/* ---------------------------------------------------------------- actions */
async function act(label, steps) {
  notify(label + "...", "busy");
  try {
    for (const args of steps) await run(args);
    notify(label + " - done", "ok");
  } catch (e) {
    notify(label + " failed:\n" + (e.message || e), "err");
  }
  await loadAll();
}

const customGroups = () => state.groups.filter((g) => !g.builtin).map((g) => g.name);

$("#create-user").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const f = ev.target.elements;
  const name = f.name.value.trim();
  const args = ["samba-tool", "user", "create", name, f.pw.value];
  if (f.first.value.trim()) args.push("--given-name=" + f.first.value.trim());
  if (f.last.value.trim()) args.push("--surname=" + f.last.value.trim());
  if (f.mail.value.trim()) args.push("--mail-address=" + f.mail.value.trim());
  if (f.mustchange.checked) args.push("--must-change-at-next-login");
  const steps = [args];
  if (f.group.value) steps.push(["samba-tool", "group", "addmembers", f.group.value, name]);
  await act(`Create user ${name}`, steps);
  if ($("#status").className === "ok") ev.target.reset();
});

$("#create-group").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const f = ev.target.elements;
  const args = ["samba-tool", "group", "add", f.name.value.trim()];
  if (f.desc.value.trim()) args.push("--description=" + f.desc.value.trim());
  await act(`Create group ${f.name.value.trim()}`, [args]);
  if ($("#status").className === "ok") ev.target.reset();
});

$("#user-rows").addEventListener("click", async (ev) => {
  const btn = ev.target.closest("button[data-act]");
  if (!btn) return;
  const name = btn.parentElement.dataset.user;
  const u = state.users.find((x) => x.name === name);
  switch (btn.dataset.act) {
    case "pw": {
      const v = await ask(`Reset password: ${name}`, "", [
        { name: "pw", label: "New password", type: "password", required: true },
        { name: "must", label: "Must change at next login", type: "checkbox", value: true },
      ], "Set password");
      if (!v) return;
      const args = ["samba-tool", "user", "setpassword", name, "--newpassword=" + v.pw];
      if (v.must) args.push("--must-change-at-next-login");
      return act(`Reset password for ${name}`, [args]);
    }
    case "toggle":
      return act(`${u.disabled ? "Enable" : "Disable"} ${name}`,
        [["samba-tool", "user", u.disabled ? "enable" : "disable", name]]);
    case "groups": {
      const v = await ask(`Groups: ${name}`, "Member of: " + (u.groups.join(", ") || "(only Domain Users)"), [
        { name: "op", label: "Action", type: "select", options: ["add to", "remove from"] },
        { name: "group", label: "Group", type: "select", options: customGroups().concat(["Domain Admins"]) },
      ], "Apply");
      if (!v) return;
      return act(`${v.op === "add to" ? "Add" : "Remove"} ${name} ${v.op === "add to" ? "to" : "from"} ${v.group}`,
        [["samba-tool", "group", v.op === "add to" ? "addmembers" : "removemembers", v.group, name]]);
    }
    case "del": {
      const v = await ask(`Delete user ${name}?`, "This cannot be undone. Their files on devices are kept.", [], "Delete");
      if (v) return act(`Delete user ${name}`, [["samba-tool", "user", "delete", name]]);
    }
  }
});

$("#group-rows").addEventListener("click", async (ev) => {
  const btn = ev.target.closest("button[data-act]");
  if (!btn) return;
  const name = btn.parentElement.dataset.group;
  const g = state.groups.find((x) => x.name === name);
  switch (btn.dataset.act) {
    case "add": {
      const opts = state.users.map((u) => u.name).filter((n) => !g.members.includes(n));
      if (!opts.length) return notify("Every user is already a member.", "ok");
      const v = await ask(`Add member to ${name}`, "", [{ name: "user", label: "User", type: "select", options: opts }], "Add");
      if (v) return act(`Add ${v.user} to ${name}`, [["samba-tool", "group", "addmembers", name, v.user]]);
      return;
    }
    case "remove": {
      const v = await ask(`Remove member from ${name}`, "", [{ name: "user", label: "Member", type: "select", options: g.members }], "Remove");
      if (v) return act(`Remove ${v.user} from ${name}`, [["samba-tool", "group", "removemembers", name, v.user]]);
      return;
    }
    case "del": {
      const v = await ask(`Delete group ${name}?`, "Users are not deleted, only the group.", [], "Delete");
      if (v) return act(`Delete group ${name}`, [["samba-tool", "group", "delete", name]]);
    }
  }
});

$("#computer-rows").addEventListener("click", async (ev) => {
  const btn = ev.target.closest("button[data-act]");
  if (!btn) return;
  const name = btn.parentElement.dataset.computer;
  const v = await ask(`Remove ${name.replace(/\$$/, "")} from the domain?`,
    "AD logins on that device stop working until it is re-joined. It stays in Landscape until you remove it there.", [], "Remove");
  if (v) return act(`Remove computer ${name}`, [["samba-tool", "computer", "delete", name]]);
});

/* ---------------------------------------------------------------- wiring */
document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => {
  document.querySelectorAll(".tab").forEach((x) => x.classList.toggle("active", x === t));
  for (const id of ["users", "groups", "computers"]) $("#tab-" + id).hidden = id !== t.dataset.tab;
}));
$("#user-filter").addEventListener("input", render);
$("#show-builtin").addEventListener("change", render);
$("#refresh").addEventListener("click", () => { notify(""); loadAll(); });

cockpit.spawn(["hostname", "-d"]).then((d) => { $("#realm").textContent = "- " + d.trim(); }).catch(() => {});
loadAll();
