(() => {
const sb = window.supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_KEY);
const $ = (s) => document.querySelector(s);
const DAG = ["maandag","dinsdag","woensdag","donderdag","vrijdag","zaterdag","zondag"];
const MND = ["januari","februari","maart","april","mei","juni","juli","augustus","september","oktober","november","december"];

// ---------- helpers
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const safeUrl = (u) => (/^https?:\/\//i.test(u || "") ? u : null);
const pc = (x) => (x == null ? "n.b." : Number(x).toFixed(2).replace(".", ","));
const bp = (x) => Math.round(x * 100);
const dm = (s) => (s ? `${+s.slice(8, 10)}/${+s.slice(5, 7)}` : "n.b.");
const dmy = (s) => (s ? `${+s.slice(8, 10)}/${+s.slice(5, 7)}/${s.slice(0, 4)}` : "n.b.");
const dObj = (s) => new Date(s + "T12:00:00");
const iso = (d) => d.toISOString().slice(0, 10);
const lang = (s) => { const d = dObj(s); return `${DAG[(d.getDay() + 6) % 7]} ${d.getDate()} ${MND[d.getMonth()]} ${d.getFullYear()}`; };
const weekNr = (s) => { const d = dObj(s); const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate())); const n = t.getUTCDay() || 7; t.setUTCDate(t.getUTCDate() + 4 - n); return Math.ceil(((t - new Date(Date.UTC(t.getUTCFullYear(), 0, 1))) / 864e5 + 1) / 7); };
const pills = (ls) => (ls || []).map((l) => `<span class="pill ${esc(l)}">${esc(l)}</span>`).join("");
const src = (name, url) => { const u = safeUrl(url); return u ? `<a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${esc(name || "bron")}</a>` : ""; };
const meta = (...a) => { const x = a.filter(Boolean).join(" · "); return x ? `<div class="meta">${x}</div>` : ""; };
const ARROW = { down: ["down", "▼"], up: ["up", "▲"], flat: ["flat", "▬"], mix: ["flat", "▼▲"], "?": ["flat", "?"] };
const ARROW_TXT = { down: "gedaald", up: "gestegen", flat: "gelijk", mix: "wisselend", "?": "onzeker" };
const arrow = (r, per) => { if (!r || !ARROW[r]) return ""; const [c, s] = ARROW[r]; return ` <span class="${c}"><span aria-hidden="true">${s}</span><span class="sr"> ${ARROW_TXT[r]}</span>${per ? " per " + esc(per) : ""}</span>`; };
const item = ({ head, lead, text, sub, m }) =>
  `<div class="item">${head ? `<div class="hd">${head}</div>` : ""}${lead ? `<b>${lead}</b> ` : ""}${esc(text)}${sub ? `<div class="why">${sub}</div>` : ""}${m || ""}</div>`;
const block = (title, rows, n) => (rows ? `<div class="block"><div class="bh">${title}${n != null ? `<span class="badge">${n}</span>` : ""}</div>${rows}</div>` : "");
const dl = (n) => n == null ? "vorige week n.b." : (n === 0 ? `<span aria-hidden="true">▬</span> gelijk` : `<span aria-hidden="true">${n > 0 ? "▲" : "▼"}</span> ${Math.abs(n)} bp<span class="sr"> ${n > 0 ? "hoger" : "lager"}</span>`) + " t.o.v. vorige week";
const sg = (n) => (n > 0 ? "+" : n < 0 ? "−" : "±") + Math.abs(n) + " bp";

// ---------- cache (alleen in het geheugen, wordt geleegd bij uitloggen)
const CACHE_MS = 5 * 60 * 1000;
const lists = {};
let catCache = null;
function editionList(soort) {
  const c = lists[soort];
  if (c && Date.now() - c.t < CACHE_MS) return c.p;
  const p = (async () => {
    const r = await sb.from("editions").select("id,datum").eq("soort", soort).order("datum", { ascending: false }).limit(400);
    if (r.error) delete lists[soort];
    return r;
  })();
  lists[soort] = { t: Date.now(), p };
  return p;
}

// ---------- auth
let signedIn = null; // null = nog onbekend, true/false = laatst getoonde scherm
async function boot() {
  const { data } = await sb.auth.getSession();
  data.session ? showApp() : showLogin();
  // Token-verversingen en terugkeren naar de tab sturen ook events; alleen reageren op echte wissel.
  sb.auth.onAuthStateChange((_e, s) => { if (s && signedIn !== true) showApp(); else if (!s && signedIn !== false) showLogin(); });
}
function showLogin() {
  signedIn = false;
  rid++;
  Object.keys(lists).forEach((k) => delete lists[k]); catCache = null;
  $("#main").innerHTML = ""; $("#sub").innerHTML = ""; $("#password").value = "";
  $("#app").hidden = true; $("#login").hidden = false;
}
let started = false;
function showApp() { signedIn = true; $("#login").hidden = true; $("#app").hidden = false; if (!started) { started = true; window.addEventListener("hashchange", route); } route(); }
$("#loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("#loginErr").textContent = "";
  const { error } = await sb.auth.signInWithPassword({ email: $("#email").value, password: $("#password").value });
  if (error) $("#loginErr").textContent = "Inloggen mislukt: controleer e-mailadres en wachtwoord.";
});
$("#logout").addEventListener("click", () => sb.auth.signOut());

// ---------- router
let rid = 0; // groeit bij elke navigatie; trage antwoorden van een vorige pagina worden genegeerd
function route() {
  rid++;
  const [v = "dag", arg] = (location.hash.slice(1) || "dag").split("/");
  document.querySelectorAll(".tabs a").forEach((a) => { const on = a.dataset.v === v; a.classList.toggle("on", on); if (on) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
  if (v === "dag" || v === "week") return editionView(v, arg);
  if (v === "archief") return archiefView();
  if (v === "grafieken") return grafiekenView();
  location.hash = "#dag";
}
const main = $("#main");
const loading = () => (main.innerHTML = `<div class="empty" role="status">Laden…</div>`);
const fail = (e) => (main.innerHTML = `<div class="empty" role="alert">Er ging iets mis bij het laden: ${esc(e.message || e)}</div>`);

// ---------- dag / week
async function editionView(soort, datum) {
  const my = rid;
  loading();
  $("#kicker").textContent = soort === "week" ? "Weekoverzicht" : "Ochtendoverzicht";
  const { data: list, error } = await editionList(soort);
  if (my !== rid) return;
  if (error) return fail(error);
  if (!list.length) { main.innerHTML = `<div class="empty">Nog geen ${soort === "week" ? "weekoverzichten" : "dagoverzichten"} in de database.</div>`; $("#sub").innerHTML = ""; return; }
  const cur = list.find((x) => x.datum === datum) || list[0];
  const idx = list.indexOf(cur);
  const [{ data: ed, error: e1 }, { data: items, error: e2 }, { data: k, error: e3 }, { data: prev }] = await Promise.all([
    sb.from("editions").select("*").eq("id", cur.id).single(),
    sb.from("items").select("*").eq("edition_id", cur.id).order("positie"),
    sb.from("kerncijfers").select("*").eq("datum", cur.datum).maybeSingle(),
    sb.from("kerncijfers").select("*").lte("datum", iso(new Date(dObj(cur.datum).getTime() - 7 * 864e5))).order("datum", { ascending: false }).limit(1),
  ]);
  if (my !== rid) return;
  if (e1 || e2 || e3) return fail(e1 || e2 || e3);
  $("#sub").innerHTML = soort === "week" ? `Week ${weekNr(ed.datum)}<br>${esc(ed.periode || lang(ed.datum))}` : `${esc(lang(ed.datum))}<br>nieuws ${esc(ed.periode || "")}`;
  const sel = `<div class="bar"><button class="btn ghost" id="nw" ${idx + 1 >= list.length ? "disabled" : ""}>← Eerder</button>
    <select id="pick" aria-label="Kies uitgave">${list.map((x) => `<option value="${x.datum}" ${x.id === cur.id ? "selected" : ""}>${esc(lang(x.datum))}</option>`).join("")}</select>
    <button class="btn ghost" id="nx" ${idx === 0 ? "disabled" : ""}>Later →</button></div>`;
  main.innerHTML = sel + `<div class="layout"><aside class="side" aria-label="Kerncijfers">${sidebar(k, prev && prev[0])}</aside><section class="mainp">${mainPanel(soort, ed, items)}</section></div>`;
  $("#pick").onchange = (e) => (location.hash = `#${soort}/${e.target.value}`);
  $("#nw").onclick = () => (location.hash = `#${soort}/${list[idx + 1].datum}`);
  $("#nx").onclick = () => (location.hash = `#${soort}/${list[idx - 1].datum}`);
}

function sidebar(k, p) {
  if (!k) return `<div class="sh">Rente</div><div class="small">Geen kerncijfers voor deze dag.</div>`;
  const rD = p && p.rente10_ltv100 != null && k.rente10_ltv100 != null ? bp(k.rente10_ltv100 - p.rente10_ltv100) : null;
  const sD = p && p.swap10 != null && k.swap10 != null ? bp(k.swap10 - p.swap10) : null;
  const marge = k.marge_bp;
  const mD = p && p.marge_bp != null && marge != null ? marge - p.marge_bp : null;
  const kpi = (t, v, d, x) => `<div class="kpi"><div class="t">${t}</div><div class="v">${v}</div><div class="d">${d}</div>${x ? `<div class="x">${x}</div>` : ""}</div>`;
  const t5 = (title, list) => {
    list = (list || []).slice(0, 5);
    const spr = list.length > 1 ? bp(list[list.length - 1][1] - list[0][1]) : 0;
    const rows = list.map(([n, v], i) => `<tr><td class="n">${i + 1}</td><td class="${["Argenta", "Vista"].includes(n) ? "hl" : ["Centraal Beheer", "CB", "Syntrus", "Syntrus Achmea", "Attens"].includes(n) ? "pref" : ""}">${esc(n)}</td><td class="r">${pc(v)}%</td></tr>`).join("");
    return `<h4>${title}</h4><table>${rows}<tr class="sp"><td colspan="3">Gemiddelde 1–5: <b>${pc(list.reduce((t, x) => t + +x[1], 0) / (list.length || 1))}%</b> · spreiding <b>${spr} bp</b></td></tr></table>`;
  };
  // Op mobiel: de drie kerncijfers naast elkaar, de rest inklapbaar onder de samenvatting.
  const mobiel = window.matchMedia("(max-width:760px)").matches;
  let h = `<div class="sh">Rente</div><div class="kpis">`
    + kpi("Hypotheekrente 10j (100% LTV)", pc(k.rente10_ltv100) + "%", dl(rD), "gemiddelde van de top 5 laagste tarieven")
    + kpi("Swaprente 10j", pc(k.swap10) + "%", dl(sD))
    + kpi("Rentemarge", marge != null ? marge + " bp" : "n.b.", dl(mD), marge != null ? `norm 125 bp · ${sg(marge - 125)}` : "")
    + `</div><details class="more"${mobiel ? "" : " open"}><summary>Top 5, rentecurve en toelichting</summary>`
    + `<div class="sh">Top 5 laagste tarieven · 10j</div><div class="t5">${t5("Met NHG", k.top5_nhg)}${t5("100% LTV", k.top5_ltv)}</div>`;
  const c = k.curve;
  if (c && c.nu) {
    const cell = (a, i) => (a ? pc(a[i]) : "n.b.");
    const st = (a) => (a ? bp(a[2] - a[0]) + " bp" : "n.b.");
    h += `<div class="sh">Rentecurve NHG</div><div class="curve"><table><tr><th></th><th>nu</th><th>week</th><th>maand</th></tr>`
      + ["5j", "10j", "20j"].map((j, i) => `<tr><td>${j}</td><td>${cell(c.nu, i)}</td><td>${cell(c.week, i)}</td><td>${cell(c.maand, i)}</td></tr>`).join("")
      + `<tr class="st"><td>steil</td><td>${st(c.nu)}</td><td>${st(c.week)}</td><td>${st(c.maand)}</td></tr></table>
      <div class="small">Steilheid = 20j min 5j. Peildata: nu ${dm(c.peil)} · week ${dm(c.week_peil)} · maand ${dm(c.maand_peil)}</div></div>`;
  }
  h += `<div class="sh">Toelichting</div><div class="small">Rente: gemiddelde van de 5 laagste tarieven 10 jaar vast bij 100% LTV (Moneywise, ${dm(k.rente_peil)}). Swap: slot ${dm(k.swap_slot)} (BlueGamma). Marge: rente − swap, norm 125 bp. Rentecurve: gemiddelde van de 5 laagste NHG-tarieven per looptijd (5, 10 en 20 jaar), zelfde methode en bron als de top 5, dus de 10j-waarde is gelijk aan het gemiddelde van de top 5 met NHG. Top 5: laagste reguliere tarief per aanbieder, zonder groene producten (Moneywise, ${dm(k.top5_stand)}); Argenta en Vista blauw, Centraal Beheer, Syntrus en Attens groen.${k.bronnoot ? " " + esc(k.bronnoot) : ""}</div></details>`;
  return h;
}

function groupBy(arr, key) {
  const m = new Map();
  arr.forEach((x) => { const g = x[key] || ""; if (!m.has(g)) m.set(g, []); m.get(g).push(x); });
  return [...m.entries()];
}

function mainPanel(soort, ed, items) {
  const by = (s) => items.filter((i) => i.sectie === s);
  const top = by("top"), nws = by("nieuws"), toez = by("toezicht"), bed = by("bedrijf");
  const dui = ed.duiding || [];
  const duiBlk = block(soort === "week" ? "Weekduiding" : "Duiding van de week", dui.map((x) => item({ text: x.tekst, m: meta(pills(x.labels)) })).join(""), dui.length || null);
  const out = [];
  if (soort === "week") out.push(duiBlk);
  out.push(block(soort === "week" ? "Top 5 van de week" : "Belangrijkst vandaag",
    top.map((t, i) => item({ head: `<span class="num">${i + 1}</span>${esc(t.kop)}`, text: t.zin, sub: t.waarom ? `<b>Waarom relevant:</b> ${esc(t.waarom)}` : "", m: meta(pills(t.labels), src(t.bron_naam, t.bron_url)) })).join("") || item({ text: "Geen nieuws van betekenis in deze periode." }), top.length));
  const wt = ed.watch || [];
  out.push(block("Watchlist", wt.map((w) => item({ lead: esc(w.naam) + arrow(w.richting, w.per), text: w.tekst, m: meta(w.bron ? src(w.bron[0], w.bron[1]) : "") })).join(""), wt.length));
  out.push(block("Bedrijven in beeld", bed.map((b) => item({ lead: esc(b.categorie), text: b.zin, m: meta(pills(b.labels), src(b.bron_naam, b.bron_url)) })).join(""), bed.length));
  out.push(block("Nieuws per categorie", groupBy(nws, "categorie").map(([c, its]) => `<div class="sg">${esc(c)}</div>` + its.map((i) => item({ text: i.zin, m: meta(pills(i.labels), src(i.bron_naam, i.bron_url)) })).join("")).join(""), nws.length));
  let tr = groupBy(toez, "categorie").map(([c, its]) => `<div class="sg">${esc(c)}</div>` + its.map((i) => item({ text: i.zin, sub: i.impact ? `<b>Impact:</b> ${esc(i.impact)}` : "", m: meta(pills(i.labels), src(i.bron_naam, i.bron_url)) })).join("")).join("");
  const ag = ed.agenda || [];
  if (ag.length) tr += `<div class="sg">Komende data</div>` + ag.map((x) => item({ lead: `${esc(x.datum)} · ${esc(x.instantie)}`, text: x.tekst, m: meta(pills(x.labels)) })).join("");
  if (!tr && soort === "week") tr = item({ text: "Geen relevante toezicht- of beleidsberichten in deze periode." });
  out.push(block("Toezicht &amp; beleid", tr, toez.length || null));
  const rw = ed.rente_wijzigingen || [];
  let rr = rw.map((x) => item({ lead: esc(x.verstrekker) + arrow(x.richting), text: x.tekst, m: meta(esc(x.datum)) })).join("") || item({ text: "Geen rentewijzigingen gevonden." });
  const vz = ed.vooruitzicht;
  if (vz && vz.tekst) rr += item({ text: vz.tekst, m: meta(vz.bron ? src(vz.bron[0], vz.bron[1]) : "") });
  out.push(block(soort === "week" ? "Rente deze week" : "Rentewijzigingen", rr, rw.length));
  const vb = ed.vooruitblik || [];
  out.push(block("Vooruitblik volgende week", vb.map((x) => item({ lead: esc(x.datum), text: x.tekst, m: meta(pills(x.labels)) })).join(""), vb.length));
  out.push(`<div class="foot">${ed.niet_gevonden ? `<b>Niet gevonden of achter betaalmuur:</b> ${esc(ed.niet_gevonden)}<br>` : ""}${ed.basis ? `<b>Basis:</b> ${esc(ed.basis)}<br>` : ""}Samengesteld door Claude op basis van openbare bronnen. Labels: ${pills(["Hypo"])} hypotheekexpert · ${pills(["Digi"])} digitalisering · ${pills(["Board"])} directie.</div>`);
  return out.join("");
}

// ---------- archief
async function archiefView() {
  const my = rid;
  $("#kicker").textContent = "Archief"; $("#sub").innerHTML = "";
  if (!catCache) {
    loading();
    const { data: cats } = await sb.from("items").select("categorie").not("categorie", "is", null).limit(2000);
    if (cats) catCache = [...new Set(cats.map((c) => c.categorie))].sort();
  }
  if (my !== rid) return;
  const catList = catCache || [];
  main.innerHTML = `<div class="bar">
    <input type="search" id="q" aria-label="Zoeken in nieuws" placeholder="Zoeken in nieuws…" style="flex:1;min-width:160px">
    <select id="lab" aria-label="Label"><option value="">Alle labels</option><option>Hypo</option><option>Digi</option><option>Board</option></select>
    <select id="sec" aria-label="Soort"><option value="">Alle soorten</option><option value="top">Top</option><option value="nieuws">Nieuws</option><option value="toezicht">Toezicht</option><option value="bedrijf">Bedrijven</option></select>
    <select id="cat" aria-label="Categorie"><option value="">Alle categorieën</option>${catList.map((c) => `<option>${esc(c)}</option>`).join("")}</select>
    <input type="date" id="van" title="Nieuws vanaf" aria-label="Nieuws vanaf"><input type="date" id="tot" title="Nieuws tot en met" aria-label="Nieuws tot en met">
    <button class="btn" id="go">Zoek</button></div><div class="wrap" id="res" aria-live="polite"></div>`;
  let rq = 0;
  const run = async () => {
    const mine = ++rq;
    $("#res").innerHTML = `<div class="empty">Laden…</div>`;
    let q = sb.from("items").select("id,sectie,categorie,kop,zin,waarom,impact,labels,bron_naam,bron_url,nieuws_datum,editions!inner(datum,soort)").order("nieuws_datum", { ascending: false }).order("created_at", { ascending: false }).limit(300);
    // Elk woord moet voorkomen (in zin, kop of categorie); speciale tekens worden gestript voor de .or()-filter.
    const terms = $("#q").value.replace(/[%,()\\]/g, " ").split(/\s+/).filter(Boolean).slice(0, 6);
    terms.forEach((w) => { q = q.or(`zin.ilike.%${w}%,kop.ilike.%${w}%,categorie.ilike.%${w}%`); });
    if ($("#lab").value) q = q.contains("labels", [$("#lab").value]);
    if ($("#sec").value) q = q.eq("sectie", $("#sec").value);
    if ($("#cat").value) q = q.eq("categorie", $("#cat").value);
    if ($("#van").value) q = q.gte("nieuws_datum", $("#van").value);
    if ($("#tot").value) q = q.lte("nieuws_datum", $("#tot").value);
    const { data, error } = await q;
    if (mine !== rq || my !== rid) return;
    if (error) return ($("#res").innerHTML = `<div class="empty">Fout: ${esc(error.message)}</div>`);
    if (!data.length) return ($("#res").innerHTML = `<div class="empty">Niets gevonden.</div>`);
    data.sort((a, b) => b.editions.datum.localeCompare(a.editions.datum));
    const seen = new Set();
    $("#res").innerHTML = `<div class="small">${data.length} resultaten${data.length === 300 ? " (eerste 300; verfijn je zoekopdracht)" : ""}</div>` + data.map((i) => {
      const key = i.editions.soort + i.editions.datum; let head = "";
      if (!seen.has(key)) { seen.add(key); head = `<div class="hit-date"><a href="#${i.editions.soort}/${i.editions.datum}">${esc(lang(i.editions.datum))} · ${i.editions.soort === "week" ? "weekoverzicht" : "dagoverzicht"}</a></div>`; }
      return head + `<div class="block" style="margin-bottom:8px">${item({ head: i.kop ? esc(i.kop) : "", text: i.zin, sub: i.waarom ? `<b>Waarom relevant:</b> ${esc(i.waarom)}` : i.impact ? `<b>Impact:</b> ${esc(i.impact)}` : "", m: meta(esc(i.categorie || i.sectie), pills(i.labels), `nieuws ${esc(dmy(i.nieuws_datum))}`, src(i.bron_naam, i.bron_url)) }).replace('class="item"', 'class="item" style="border-top:0"')}</div>`;
    }).join("");
  };
  $("#go").onclick = run; $("#q").onkeydown = (e) => e.key === "Enter" && run();
  ["lab", "sec", "cat", "van", "tot"].forEach((id) => ($("#" + id).onchange = run));
  run();
}

// ---------- grafieken
const CH = {}; let chSeq = 0; // per grafiek: schaalfuncties en data voor de hover
async function grafiekenView() {
  const my = rid;
  $("#kicker").textContent = "Grafieken"; $("#sub").innerHTML = ""; loading();
  const { data, error } = await sb.from("kerncijfers").select("datum,rente10_ltv100,swap10,marge_bp,top5_nhg").order("datum");
  if (my !== rid) return;
  if (error) return fail(error);
  if (!data.length) { main.innerHTML = `<div class="empty">Nog geen kerncijfers in de database.</div>`; return; }
  main.innerHTML = `<div class="bar"><select id="rng" aria-label="Periode"><option value="30">Laatste 30 dagen</option><option value="90" selected>Laatste 90 dagen</option><option value="365">Laatste jaar</option><option value="0">Alles</option></select></div><div class="wrap"><div class="charts" id="ch"></div></div>`;
  const ch = $("#ch");
  const draw = () => {
    for (const k in CH) delete CH[k];
    chSeq = 0;
    const n = +$("#rng").value;
    const cut = n ? iso(new Date(Date.now() - n * 864e5)) : "";
    const rows = data.filter((r) => r.datum >= cut);
    const avg5 = (l) => (Array.isArray(l) && l.length ? l.reduce((a, x) => a + +x[1], 0) / l.length : null);
    const pts = (f) => rows.filter((r) => f(r) != null).map((r) => ({ x: r.datum, y: +f(r) }));
    ch.innerHTML = [
      chart("Hypotheekrente 10j (100% LTV) en swaprente 10j, %", [["Hypotheekrente", pts((r) => r.rente10_ltv100), "#4F46E5"], ["Swaprente", pts((r) => r.swap10), "#0EA5E9"]], 2),
      chart("Rentemarge (bp), norm 125", [["Marge", pts((r) => r.marge_bp), "#D97706"]], 0, 125),
      chart("Gemiddelde 5 laagste tarieven met NHG, 10j (%)", [["Top 5 NHG", pts((r) => avg5(r.top5_nhg)), "#16A34A"]], 2),
    ].join("");
  };
  // Hover/aanraken: cursorlijn, punten en een tekstballon met de waarden op die datum.
  const hide = (c) => { c.querySelectorAll(".cur,.dot").forEach((o) => o.setAttribute("visibility", "hidden")); c.querySelector(".tip").hidden = true; };
  const move = (e) => {
    const c = e.target.closest && e.target.closest(".chart[data-c]");
    ch.querySelectorAll(".chart").forEach((o) => o !== c && hide(o));
    const m = c && CH[c.dataset.c]; if (!m) return;
    const svg = c.querySelector("svg"), r = svg.getBoundingClientRect();
    const t = m.x0 + (((e.clientX - r.left) * (m.W / r.width) - m.L) / (m.W - m.L - m.R)) * (m.x1 - m.x0);
    let best = null, bd = Infinity;
    m.series.forEach(([, p]) => p.forEach((q) => { const d = Math.abs(dObj(q.x).getTime() - t); if (d < bd) { bd = d; best = q.x; } }));
    if (!best) return hide(c);
    const bx = m.X(dObj(best).getTime());
    const cur = c.querySelector(".cur"); cur.setAttribute("x1", bx); cur.setAttribute("x2", bx); cur.setAttribute("visibility", "visible");
    const dots = c.querySelectorAll(".dot"); let lines = "";
    m.series.forEach(([n, p, col], i) => {
      const q = p.find((z) => z.x === best);
      if (!q) return dots[i].setAttribute("visibility", "hidden");
      dots[i].setAttribute("cx", bx); dots[i].setAttribute("cy", m.Y(q.y)); dots[i].setAttribute("visibility", "visible");
      lines += `<div><span style="color:${col}">●</span> ${esc(n)}: <b>${m.fmt(q.y)}</b></div>`;
    });
    const tip = c.querySelector(".tip");
    tip.innerHTML = `<div class="small">${esc(lang(best))}</div>${lines}`; tip.hidden = false;
    const w = tip.offsetWidth;
    tip.style.left = Math.max(4, Math.min(svg.offsetLeft + bx * (r.width / m.W) - w / 2, c.clientWidth - w - 4)) + "px";
    tip.style.top = svg.offsetTop + 4 + "px";
  };
  ch.onpointermove = move; ch.onpointerdown = move;
  ch.onpointerleave = () => ch.querySelectorAll(".chart").forEach(hide);
  $("#rng").onchange = draw; draw();
}
function chart(title, series, dec, ref) {
  const all = series.flatMap((s) => s[1]);
  if (all.length < 2) return `<div class="chart"><h3>${esc(title)}</h3><div class="small">Te weinig datapunten voor een grafiek.</div></div>`;
  const W = 640, H = 240, L = 46, R = 12, T = 12, B = 28;
  const xs = all.map((p) => dObj(p.x).getTime()); const x0 = Math.min(...xs), x1 = Math.max(...xs);
  let ys = all.map((p) => p.y); if (ref != null) ys.push(ref);
  let y0 = Math.min(...ys), y1 = Math.max(...ys); const pad = (y1 - y0) * 0.1 || 1; y0 -= pad; y1 += pad;
  const X = (t) => L + ((t - x0) / (x1 - x0 || 1)) * (W - L - R), Y = (v) => T + (1 - (v - y0) / (y1 - y0)) * (H - T - B);
  const fmt = (v) => (dec ? v.toFixed(dec).replace(".", ",") : Math.round(v));
  const id = "c" + chSeq++;
  CH[id] = { series, X, Y, x0, x1, W, L, R, fmt };
  let g = "";
  for (let i = 0; i <= 4; i++) { const v = y0 + ((y1 - y0) * i) / 4, y = Y(v); g += `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}" stroke="#E2E8F0"/><text x="${L - 6}" y="${y + 4}" text-anchor="end" font-size="11" fill="#64748B">${fmt(v)}</text>`; }
  for (let i = 0; i <= 3; i++) { const t = x0 + ((x1 - x0) * i) / 3; g += `<text x="${X(t)}" y="${H - 8}" text-anchor="middle" font-size="11" fill="#64748B">${dm(iso(new Date(t)))}</text>`; }
  if (ref != null) g += `<line x1="${L}" x2="${W - R}" y1="${Y(ref)}" y2="${Y(ref)}" stroke="#D97706" stroke-dasharray="4 4"/>`;
  const lines = series.map(([n, p, c]) => p.length ? `<polyline fill="none" stroke="${c}" stroke-width="2" points="${p.map((q) => `${X(dObj(q.x).getTime())},${Y(q.y)}`).join(" ")}"/>` : "").join("");
  const hover = `<line class="cur" x1="0" x2="0" y1="${T}" y2="${H - B}" stroke="#94A3B8" visibility="hidden"/>` + series.map(([, , c]) => `<circle class="dot" r="4" fill="${c}" stroke="#fff" stroke-width="1.5" visibility="hidden"/>`).join("");
  const legend = series.map(([n, , c]) => `<span style="color:${c};font-weight:bold;margin-right:12px">● ${esc(n)}</span>`).join("");
  return `<div class="chart" data-c="${id}"><h3>${esc(title)}</h3><div class="small">${legend}</div><svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(title)}">${g}${lines}${hover}</svg><div class="tip" hidden></div></div>`;
}

boot();
})();
