// Shared by index.html and docs.html. No tracking; the only network calls are
// the public GitHub releases API (index) and same-origin files.
const REPO = "shaaaaawn/pier";
// Vendored (marked 12.0.2, MIT — see marked.LICENSE.md): no third-party requests.
const MARKED = "marked.umd.js";

// Theme: follow the OS unless the visitor toggled; remembered per browser.
(function theme() {
  try {
    const saved = localStorage.getItem("pier-theme");
    if (saved) document.documentElement.dataset.theme = saved;
  } catch (_) {}
  document.addEventListener("DOMContentLoaded", () => {
    const btn = document.getElementById("theme");
    if (!btn) return;
    btn.addEventListener("click", () => {
      const dark = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim() === "#0c1a26";
      const next = dark ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      try { localStorage.setItem("pier-theme", next); } catch (_) {}
    });
  });
})();

function loadMarked() {
  return new Promise((resolve, reject) => {
    if (window.marked) return resolve(window.marked);
    const s = document.createElement("script");
    s.src = MARKED;
    s.onload = () => resolve(window.marked);
    s.onerror = reject;
    document.head.appendChild(s);
  });
}

const esc = (t) =>
  String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// marked passes raw HTML straight through. Release notes come from an API and
// innerHTML runs whatever it's given, so show raw HTML as text and drop any
// link/image URL that isn't http(s), mailto or a fragment.
function render(marked, md) {
  const html = marked.parse(md, { renderer: Object.assign(new marked.Renderer(), { html: (h) => esc(h.text ?? h) }) });
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("[href],[src]").forEach((n) => {
    for (const attr of ["href", "src"]) {
      const v = n.getAttribute(attr);
      if (v !== null && /^\s*[a-z][a-z0-9+.-]*:/i.test(v) && !/^\s*(https?|mailto):/i.test(v)) n.removeAttribute(attr);
    }
  });
  return doc.body.innerHTML;
}

// ---- Release card (index) ------------------------------------------------
async function showRelease() {
  const el = document.getElementById("latest");
  if (!el) return;
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`);
    if (!res.ok) throw new Error(res.status);
    const r = await res.json();
    const marked = await loadMarked();
    const assets = (r.assets || [])
      .map((a) => `<a class="btn solid" href="${esc(a.browser_download_url)}">Download ${esc(a.name)}</a>`)
      .join("");
    el.innerHTML = `<span class="tag">Latest · ${esc(r.tag_name)}</span>
      <h3>${esc(r.name || r.tag_name)}</h3>
      <p class="muted">${new Date(r.published_at).toLocaleDateString(undefined, { dateStyle: "long" })}</p>
      <div class="notes">${render(marked, r.body || "")}</div>
      <p>${assets}<a href="${esc(r.html_url)}">Release page →</a></p>`;
  } catch (_) {
    el.innerHTML = `<span class="tag">Source build</span>
      <h3>No downloadable release yet</h3>
      <p class="muted">Pier is built locally for now. Binary releases need Developer ID
      signing and notarization first. Tagged releases will appear here automatically.</p>
      <p><a href="https://github.com/${REPO}/releases">All releases →</a></p>`;
  }
}

// ---- Docs viewer (docs.html) --------------------------------------------
const PAGES = [
  ["Use Pier", [
    ["getting-started", "Getting started"],
    ["features", "Features & limits"],
    ["configuration", "Configuration"],
    ["privacy-and-security", "Privacy & security"],
    ["troubleshooting", "Troubleshooting"],
  ]],
  ["Build & contribute", [
    ["development", "Development"],
    ["architecture", "Architecture"],
  ]],
];

async function showDoc() {
  const body = document.getElementById("doc");
  const side = document.getElementById("side");
  if (!body) return;
  const page = (location.hash.slice(1) || "getting-started").replace(/[^a-z0-9-]/g, "");
  side.innerHTML = PAGES.map(([group, items]) =>
    `<h4>${group}</h4>` + items.map(([id, t]) =>
      `<a href="#${id}"${id === page ? " aria-current=page" : ""}>${t}</a>`).join("")).join("");
  try {
    const [marked, res] = await Promise.all([loadMarked(), fetch(`docs/${page}.md`)]);
    if (!res.ok) throw new Error(res.status);
    body.innerHTML = render(marked, await res.text());
    const known = new Set(PAGES.flatMap(([, i]) => i.map(([id]) => id)));
    body.querySelectorAll("a[href]").forEach((a) => {
      const h = a.getAttribute("href");
      const m = h.match(/^(?:\.\/)?([a-z0-9-]+)\.md(#.*)?$/);
      if (m && known.has(m[1])) a.setAttribute("href", `#${m[1]}`);
      else if (!/^(https?:|#|mailto:)/.test(h)) {
        a.setAttribute("href", new URL(h, `https://github.com/${REPO}/blob/main/docs/`).href);
      }
    });
    document.title = `${(body.querySelector("h1") || {}).textContent || page} · Pier docs`;
    window.scrollTo(0, 0);
  } catch (_) {
    body.innerHTML = `<h1>Not found</h1><p>Couldn't load <code>${page}</code>.
      <a href="https://github.com/${REPO}/tree/main/docs">Browse the docs on GitHub →</a></p>`;
  }
}

showRelease();
if (document.getElementById("doc")) {
  showDoc();
  window.addEventListener("hashchange", showDoc);
}
