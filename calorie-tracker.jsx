import React, { useState, useEffect, useRef, useCallback } from "react";

// ── Theme ───────────────────────────────────────────────────────────────────
const T = {
  paper: "#F4F1E9",
  surface: "#FFFFFF",
  surfaceWarm: "#FBF9F3",
  ink: "#1E241C",
  muted: "#71776B",
  green: "#3A5A40",
  greenDeep: "#2C4530",
  amber: "#BE722A",
  amberSoft: "#F1E6D2",
  border: "#E2DCCF",
  greenTint: "#EBF0E8",
  danger: "#A8443A",
};
const F = {
  display: "'Space Grotesk', system-ui, sans-serif",
  body: "'Inter', system-ui, sans-serif",
  mono: "'JetBrains Mono', ui-monospace, monospace",
};

// ── Storage helpers (artifact persistent KV, with in-memory fallback) ─────────
const mem = {};
async function kvGet(key) {
  try {
    const r = await window.storage.get(key);
    return r ? JSON.parse(r.value) : null;
  } catch {
    return mem[key] ?? null;
  }
}
async function kvSet(key, value) {
  try {
    await window.storage.set(key, JSON.stringify(value));
  } catch {
    mem[key] = value;
  }
}
async function kvList(prefix) {
  try {
    const r = await window.storage.list(prefix);
    return r?.keys ?? [];
  } catch {
    return Object.keys(mem).filter((k) => k.startsWith(prefix));
  }
}

// ── Date helpers ──────────────────────────────────────────────────────────────
function localDateKey(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
    d.getDate()
  ).padStart(2, "0")}`;
}
function prettyDate(key) {
  const [y, m, d] = key.split("-").map(Number);
  const dt = new Date(y, m - 1, d);
  const today = localDateKey();
  if (key === today) return "Today";
  const yest = localDateKey(new Date(Date.now() - 86400000));
  if (key === yest) return "Yesterday";
  return dt.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

// ── Claude API ────────────────────────────────────────────────────────────────
async function callClaude(content) {
  let res;
  try {
    res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: "claude-sonnet-4-6", max_tokens: 1000, messages: [{ role: "user", content }] }),
    });
  } catch (e) {
    throw new Error("Couldn't reach the model service (network/CORS).");
  }
  if (!res.ok) {
    let detail = "";
    try { detail = (await res.text()).slice(0, 160); } catch {}
    throw new Error(`API ${res.status}${detail ? ` — ${detail}` : ""}`);
  }
  const data = await res.json();
  if (!data || !Array.isArray(data.content)) throw new Error("Empty/odd response from model.");
  return data.content.filter((b) => b.type === "text").map((b) => b.text).join("\n");
}
function parseJSON(text) {
  const clean = text.replace(/```json/gi, "").replace(/```/g, "").trim();
  return JSON.parse(clean);
}

const PARSE_PROMPT = `You are a nutrition estimator. Break the food description into individual line items.
For each item give: name, qty (number), unit (short string like "cup","oz","g","piece","slice","serving"), and totals for that quantity: calories (integer), protein (g), fat (g), carbs (g), fiber (g).
If a quantity isn't stated, assume one typical serving.
Return ONLY valid JSON, no markdown, no commentary, exactly:
{"items":[{"name":"...","qty":1,"unit":"...","calories":0,"protein":0,"fat":0,"carbs":0,"fiber":0}],"note":"one short sentence on any big assumption, or empty string"}`;

const LABEL_PROMPT = `Read this Nutrition Facts label image.
Return ONLY valid JSON, no markdown:
{"productName": string or null, "servingSize": string or null, "caloriesPerServing": number or null, "servingsPerContainer": number or null, "proteinPerServing": number or null, "fatPerServing": number or null, "carbsPerServing": number or null, "fiberPerServing": number or null}
Macros in grams. Use null for anything you cannot read clearly.`;

const RECIPE_PROMPT = `You are a recipe nutrition estimator. Given a recipe's ingredient list, return each ingredient with an estimated weight in grams and its nutrition totals (not per 100g).
Return ONLY valid JSON, no markdown:
{"ingredients":[{"name":"...","qty":1,"unit":"cup","grams":120,"calories":455,"protein":12,"fat":2,"carbs":95,"fiber":4}],"note":"one short sentence on any big assumption, or empty string"}
- grams = estimated weight of that quantity of that ingredient.
- calories/protein/fat/carbs/fiber = totals for the stated quantity. Macros in grams. Integers are fine.
Use realistic USDA-style values.`;

let _id = 0;
const uid = () => `${Date.now()}_${_id++}`;
const round1 = (n) => Math.round((n || 0) * 10) / 10;
const sumMacros = (items) => items.reduce((a, i) => ({ p: a.p + (i.protein || 0), f: a.f + (i.fat || 0), c: a.c + (i.carbs || 0), fib: a.fib + (i.fiber || 0) }), { p: 0, f: 0, c: 0, fib: 0 });

// ── Small UI atoms ────────────────────────────────────────────────────────────
function Btn({ children, onClick, kind = "primary", disabled, style }) {
  const base = {
    fontFamily: F.body, fontWeight: 600, fontSize: 14, borderRadius: 10, cursor: disabled ? "default" : "pointer",
    border: "1px solid transparent", padding: "11px 16px", transition: "opacity .15s, background .15s",
    opacity: disabled ? 0.45 : 1, width: "100%",
  };
  const kinds = {
    primary: { background: T.green, color: "#fff" },
    amber: { background: T.amber, color: "#fff" },
    ghost: { background: "transparent", color: T.green, border: `1px solid ${T.border}` },
    quiet: { background: T.greenTint, color: T.greenDeep },
  };
  return (
    <button onClick={disabled ? undefined : onClick} disabled={disabled} style={{ ...base, ...kinds[kind], ...style }}>
      {children}
    </button>
  );
}

function Ring({ value, target }) {
  const pct = target ? Math.min(value / target, 1) : 0;
  const over = target && value > target;
  return (
    <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
      <span style={{ fontFamily: F.mono, fontSize: 46, fontWeight: 600, color: T.ink, lineHeight: 1, letterSpacing: -1 }}>
        {value.toLocaleString()}
      </span>
      <span style={{ fontFamily: F.body, fontSize: 13, color: T.muted }}>
        cal{target ? ` of ${target.toLocaleString()}` : ""}
      </span>
      {target ? (
        <div style={{ flex: 1, height: 6, background: T.border, borderRadius: 99, overflow: "hidden", marginLeft: 6, alignSelf: "center" }}>
          <div style={{ width: `${pct * 100}%`, height: "100%", background: over ? T.danger : T.green, borderRadius: 99, transition: "width .4s" }} />
        </div>
      ) : null}
    </div>
  );
}

function MacroStrip({ p, f, c, fib, compact }) {
  const items = [
    { label: "Protein", val: Math.round(p || 0), col: T.green },
    { label: "Fat", val: Math.round(f || 0), col: T.amber },
    { label: "Carbs", val: Math.round(c || 0), col: T.greenDeep },
    { label: "Fiber", val: Math.round(fib || 0), col: "#5E8B86" },
  ];
  if (compact) {
    return (
      <span style={{ fontFamily: F.mono, fontSize: 11.5, color: T.muted }}>
        P{Math.round(p || 0)} · F{Math.round(f || 0)} · C{Math.round(c || 0)} · Fb{Math.round(fib || 0)}
      </span>
    );
  }
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(4, minmax(0, 1fr))", gap: 7, marginTop: 12 }}>
      {items.map((m) => (
        <div key={m.label} style={{ background: T.surfaceWarm, border: `1px solid ${T.border}`, borderRadius: 10, padding: "8px 9px", minWidth: 0 }}>
          <div style={{ fontFamily: F.mono, fontSize: 15, fontWeight: 600, color: m.col, lineHeight: 1.1 }}>
            {m.val}<span style={{ fontSize: 10, color: T.muted, marginLeft: 1 }}>g</span>
          </div>
          <div style={{ fontFamily: F.body, fontSize: 10.5, color: T.muted }}>{m.label}</div>
        </div>
      ))}
    </div>
  );
}

// ── Editable draft item row ───────────────────────────────────────────────────
function DraftRow({ item, onChange, onRemove }) {
  const setQty = (q) => {
    const qty = Math.max(0, parseFloat(q) || 0);
    onChange({
      ...item, qty,
      calories: Math.round(item.calPerUnit * qty),
      protein: round1(item.pPerUnit * qty),
      fat: round1(item.fPerUnit * qty),
      carbs: round1(item.cPerUnit * qty),
      fiber: round1(item.fibPerUnit * qty),
    });
  };
  const setCal = (c) => {
    const calories = Math.max(0, parseInt(c) || 0);
    onChange({ ...item, calories, calPerUnit: item.qty > 0 ? calories / item.qty : calories });
  };
  const inputStyle = {
    fontFamily: F.mono, fontSize: 13, color: T.ink, background: T.surface,
    border: `1px solid ${T.border}`, borderRadius: 7, padding: "5px 7px", width: "100%", textAlign: "center",
  };
  return (
    <div style={{ padding: "7px 0", borderBottom: `1px solid ${T.border}` }}>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 52px 60px 24px", gap: 7, alignItems: "center" }}>
        <input value={item.name} onChange={(e) => onChange({ ...item, name: e.target.value })}
          style={{ ...inputStyle, fontFamily: F.body, textAlign: "left" }} />
        <input value={item.qty} onChange={(e) => setQty(e.target.value)} inputMode="decimal" style={inputStyle} />
        <input value={item.calories} onChange={(e) => setCal(e.target.value)} inputMode="numeric"
          style={{ ...inputStyle, fontWeight: 600 }} />
        <button onClick={onRemove} style={{ background: "none", border: "none", color: T.muted, cursor: "pointer", fontSize: 18, lineHeight: 1, padding: 0 }}>×</button>
      </div>
      <div style={{ paddingTop: 4 }}>
        <MacroStrip p={item.protein} f={item.fat} c={item.carbs} fib={item.fiber} compact />
      </div>
    </div>
  );
}

// ── Editable recipe ingredient row ────────────────────────────────────────────
function RecipeRow({ item, onChange, onRemove }) {
  const setGrams = (g) => {
    const grams = Math.max(0, parseFloat(g) || 0);
    onChange({
      ...item, grams,
      calories: Math.round(item.calPerG * grams),
      protein: +(item.pPerG * grams).toFixed(1),
      fat: +(item.fPerG * grams).toFixed(1),
      carbs: +(item.cPerG * grams).toFixed(1),
      fiber: +((item.fibPerG || 0) * grams).toFixed(1),
    });
  };
  const setCal = (c) => {
    const calories = Math.max(0, parseInt(c) || 0);
    onChange({ ...item, calories, calPerG: item.grams > 0 ? calories / item.grams : calories });
  };
  const inp = { fontFamily: F.mono, fontSize: 13, color: T.ink, background: T.surface, border: `1px solid ${T.border}`, borderRadius: 7, padding: "5px 6px", width: 56, textAlign: "center" };
  return (
    <div style={{ padding: "9px 0", borderBottom: `1px solid ${T.border}` }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <input value={item.name} onChange={(e) => onChange({ ...item, name: e.target.value })}
          style={{ flex: 1, fontFamily: F.body, fontSize: 14, color: T.ink, border: "none", background: "transparent", fontWeight: 500, padding: 0 }} />
        <button onClick={onRemove} style={{ background: "none", border: "none", color: T.muted, cursor: "pointer", fontSize: 17, padding: 0 }}>×</button>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 5 }}>
        <span style={{ flex: 1, fontSize: 11.5, color: T.muted, fontFamily: F.mono }}>{item.qty} {item.unit}</span>
        <div style={{ display: "flex", alignItems: "center", gap: 3 }}>
          <input value={item.grams} onChange={(e) => setGrams(e.target.value)} inputMode="decimal" style={inp} />
          <span style={{ fontSize: 11, color: T.muted, width: 12 }}>g</span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 3 }}>
          <input value={item.calories} onChange={(e) => setCal(e.target.value)} inputMode="numeric" style={{ ...inp, fontWeight: 600 }} />
          <span style={{ fontSize: 11, color: T.muted, width: 20 }}>cal</span>
        </div>
      </div>
    </div>
  );
}

// ── Saved recipe card with portion logger ─────────────────────────────────────
function RecipeCard({ recipe, onLog, onDelete }) {
  const [grams, setGrams] = useState(100);
  return (
    <div style={{ padding: "13px 0", borderBottom: `1px dashed ${T.border}` }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
        <span style={{ flex: 1, fontFamily: F.display, fontWeight: 600, fontSize: 15 }}>{recipe.name}</span>
        <button onClick={onDelete} style={{ background: "none", border: "none", color: T.muted, cursor: "pointer", fontSize: 16 }}>×</button>
      </div>
      <div style={{ fontSize: 12, color: T.muted, fontFamily: F.mono, margin: "3px 0 9px" }}>
        {recipe.per100.cal} cal / 100g
        {recipe.per100.p ? ` · P${recipe.per100.p} F${recipe.per100.f} C${recipe.per100.c} Fb${recipe.per100.fib || 0}` : ""}
        {recipe.servings ? ` · ${Math.round(recipe.totals.cal / recipe.servings)} cal/serving` : ""}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 4, background: T.surfaceWarm, border: `1px solid ${T.border}`, borderRadius: 8, padding: "2px 8px" }}>
          <input value={grams} onChange={(e) => setGrams(Math.max(0, parseFloat(e.target.value) || 0))} inputMode="decimal"
            style={{ width: 46, fontFamily: F.mono, fontSize: 14, border: "none", background: "transparent", textAlign: "center", padding: "6px 0" }} />
          <span style={{ fontSize: 12, color: T.muted }}>g</span>
        </div>
        <span style={{ fontFamily: F.mono, fontSize: 13, color: T.ink, fontWeight: 600 }}>= {Math.round((recipe.per100.cal * grams) / 100)} cal</span>
        <div style={{ flex: 1 }} />
        <button onClick={() => onLog(recipe, grams)} style={{ background: T.greenTint, color: T.greenDeep, border: "none", borderRadius: 8, padding: "8px 13px", fontWeight: 600, fontSize: 13, cursor: "pointer", fontFamily: F.body }}>+ Log</button>
      </div>
    </div>
  );
}
function LoggedEntry({ entry, onDelete }) {
  const [open, setOpen] = useState(false);
  const time = new Date(entry.ts).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  const hasMacros = entry.macros && (entry.macros.p || entry.macros.f || entry.macros.c || entry.macros.fib);
  const canOpen = hasMacros || entry.items?.length > 1;
  return (
    <div style={{ borderBottom: `1px dashed ${T.border}`, padding: "12px 0" }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 8, cursor: canOpen ? "pointer" : "default" }} onClick={() => canOpen && setOpen(!open)}>
        <span style={{ fontSize: 11, fontFamily: F.mono, color: T.muted, width: 58, flexShrink: 0 }}>{time}</span>
        <span style={{ fontFamily: F.body, fontSize: 14, color: T.ink, flex: 1, fontWeight: 500 }}>
          {entry.title}
          {entry.source === "label" ? <span style={{ fontSize: 10, color: T.amber, marginLeft: 6, fontFamily: F.mono }}>LABEL</span> : null}
        </span>
        <span style={{ fontFamily: F.mono, fontSize: 15, fontWeight: 600, color: T.ink }}>{entry.total.toLocaleString()}</span>
        <button onClick={(e) => { e.stopPropagation(); onDelete(); }}
          style={{ background: "none", border: "none", color: T.muted, cursor: "pointer", fontSize: 16, padding: "0 0 0 4px" }}>×</button>
      </div>
      {hasMacros ? (
        <div style={{ paddingLeft: 66, paddingTop: 3 }}>
          <MacroStrip p={entry.macros.p} f={entry.macros.f} c={entry.macros.c} fib={entry.macros.fib} compact />
        </div>
      ) : null}
      {open && entry.items?.length > 1 ? (
        <div style={{ paddingLeft: 66, paddingTop: 6 }}>
          {entry.items.map((it, i) => (
            <div key={i} style={{ display: "flex", justifyContent: "space-between", fontSize: 12, color: T.muted, fontFamily: F.body, padding: "2px 0" }}>
              <span>{it.qty} {it.unit} {it.name}</span>
              <span style={{ fontFamily: F.mono }}>{it.calories}</span>
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
}

// ── Main app ──────────────────────────────────────────────────────────────────
export default function App() {
  const [view, setView] = useState("today");
  const [method, setMethod] = useState("type");
  const [dateKey, setDateKey] = useState(localDateKey());
  const [log, setLog] = useState([]);
  const [target, setTarget] = useState(null);
  const [usuals, setUsuals] = useState([]);
  const [recipes, setRecipes] = useState([]);
  const [history, setHistory] = useState([]);
  const [loaded, setLoaded] = useState(false);

  // recipe builder
  const [recipeText, setRecipeText] = useState("");
  const [recipeName, setRecipeName] = useState("");
  const [recipeServings, setRecipeServings] = useState("");
  const [recipeDraft, setRecipeDraft] = useState(null); // {ingredients, finalWeight, note}

  // text parsing
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [draft, setDraft] = useState(null); // {title, items, note}

  // manual entry (works with no model call)
  const [manualName, setManualName] = useState("");
  const [manualCal, setManualCal] = useState("");
  const [manualP, setManualP] = useState("");
  const [manualF, setManualF] = useState("");
  const [manualC, setManualC] = useState("");
  const [manualFib, setManualFib] = useState("");

  // label reading
  const [label, setLabel] = useState(null); // {productName, servingSize, caloriesPerServing, servingsPerContainer, servingsEaten}
  const fileRef = useRef(null);

  // target editing
  const [editTarget, setEditTarget] = useState(false);
  const [targetInput, setTargetInput] = useState("");

  const total = log.reduce((s, e) => s + e.total, 0);
  const dayMacros = log.reduce((a, e) => {
    const m = e.macros || sumMacros(e.items || []);
    return { p: a.p + (m.p || 0), f: a.f + (m.f || 0), c: a.c + (m.c || 0), fib: a.fib + (m.fib || 0) };
  }, { p: 0, f: 0, c: 0, fib: 0 });

  // initial load
  useEffect(() => {
    (async () => {
      const [l, t, u, r] = await Promise.all([kvGet(`log:${localDateKey()}`), kvGet("settings:target"), kvGet("usuals"), kvGet("recipes")]);
      setLog(l || []);
      setTarget(t ?? null);
      setUsuals(u || []);
      setRecipes(r || []);
      setLoaded(true);
    })();
  }, []);

  const persistLog = useCallback(async (next) => {
    setLog(next);
    await kvSet(`log:${dateKey}`, next);
  }, [dateKey]);

  // ── actions ──
  async function breakItDown() {
    if (!text.trim() || busy) return;
    setBusy(true); setErr("");
    try {
      const out = parseJSON(await callClaude(`${PARSE_PROMPT}\n\nFood description: ${text.trim()}`));
      const items = (out.items || []).map((it) => {
        const qty = it.qty || 1;
        const per = (v) => (qty ? (v || 0) / qty : v || 0);
        return {
          id: uid(), name: it.name, qty, unit: it.unit || "serving",
          calories: Math.round(it.calories || 0), protein: round1(it.protein), fat: round1(it.fat), carbs: round1(it.carbs), fiber: round1(it.fiber),
          calPerUnit: per(it.calories), pPerUnit: per(it.protein), fPerUnit: per(it.fat), cPerUnit: per(it.carbs), fibPerUnit: per(it.fiber),
        };
      });
      setDraft({ title: text.trim(), items, note: out.note || "", source: "text" });
    } catch (e) {
      setErr(e.message || "Couldn't parse that. Try rephrasing.");
    } finally {
      setBusy(false);
    }
  }

  async function readLabel(file) {
    if (!file || busy) return;
    setBusy(true); setErr("");
    try {
      const b64 = await new Promise((res, rej) => {
        const r = new FileReader();
        r.onload = () => res(r.result.split(",")[1]);
        r.onerror = rej;
        r.readAsDataURL(file);
      });
      const out = parseJSON(await callClaude([
        { type: "image", source: { type: "base64", media_type: file.type || "image/jpeg", data: b64 } },
        { type: "text", text: LABEL_PROMPT },
      ]));
      setLabel({ ...out, servingsEaten: 1 });
    } catch (e) {
      setErr(e.message || "Couldn't read that label. Try a clearer photo.");
    } finally {
      setBusy(false);
    }
  }

  function commitDraft() {
    const items = draft.items.map(({ id, calPerUnit, pPerUnit, fPerUnit, cPerUnit, fibPerUnit, ...rest }) => rest);
    const entry = { id: uid(), ts: Date.now(), title: draft.title, items, total: items.reduce((s, i) => s + i.calories, 0), macros: sumMacros(items), source: draft.source };
    persistLog([...log, entry]);
    setDraft(null); setText("");
  }

  function commitLabel() {
    const per = label.caloriesPerServing || 0;
    const eaten = label.servingsEaten || 1;
    const cal = Math.round(per * eaten);
    const title = label.productName || "Packaged item";
    const macros = {
      p: round1((label.proteinPerServing || 0) * eaten),
      f: round1((label.fatPerServing || 0) * eaten),
      c: round1((label.carbsPerServing || 0) * eaten),
      fib: round1((label.fiberPerServing || 0) * eaten),
    };
    const entry = {
      id: uid(), ts: Date.now(), title, source: "label", total: cal, macros,
      items: [{ name: title, qty: eaten, unit: "serving", calories: cal, protein: macros.p, fat: macros.f, carbs: macros.c, fiber: macros.fib }],
    };
    persistLog([...log, entry]);
    setLabel(null);
  }

  function deleteEntry(id) { persistLog(log.filter((e) => e.id !== id)); }

  function addManual() {
    const cal = parseInt(manualCal) || 0;
    if (!manualName.trim() || cal <= 0) return;
    const item = {
      name: manualName.trim(), qty: 1, unit: "serving", calories: cal,
      protein: parseFloat(manualP) || 0, fat: parseFloat(manualF) || 0, carbs: parseFloat(manualC) || 0, fiber: parseFloat(manualFib) || 0,
    };
    const entry = {
      id: uid(), ts: Date.now(), title: item.name, source: "manual", total: cal,
      macros: { p: item.protein, f: item.fat, c: item.carbs, fib: item.fiber }, items: [item],
    };
    persistLog([...log, entry]);
    setManualName(""); setManualCal(""); setManualP(""); setManualF(""); setManualC(""); setManualFib("");
  }

  async function saveUsual() {
    const items = draft.items.map(({ id, calPerUnit, pPerUnit, fPerUnit, cPerUnit, fibPerUnit, ...rest }) => rest);
    const u = { id: uid(), name: draft.title, items, total: items.reduce((s, i) => s + i.calories, 0), macros: sumMacros(items) };
    const next = [u, ...usuals].slice(0, 50);
    setUsuals(next); await kvSet("usuals", next);
  }

  function addUsual(u) {
    const entry = { id: uid(), ts: Date.now(), title: u.name, items: u.items, total: u.total, macros: u.macros || sumMacros(u.items), source: "usual" };
    persistLog([...log, entry]);
    setView("today");
  }

  async function removeUsual(id) {
    const next = usuals.filter((u) => u.id !== id);
    setUsuals(next); await kvSet("usuals", next);
  }

  async function saveTarget() {
    const v = parseInt(targetInput);
    const t = v > 0 ? v : null;
    setTarget(t); setEditTarget(false); await kvSet("settings:target", t);
  }

  async function parseRecipe() {
    if (!recipeText.trim() || busy) return;
    setBusy(true); setErr("");
    try {
      const out = parseJSON(await callClaude(`${RECIPE_PROMPT}\n\nRecipe ingredients:\n${recipeText.trim()}`));
      const ingredients = (out.ingredients || []).map((g) => {
        const grams = g.grams || 0;
        return {
          id: uid(), name: g.name, qty: g.qty ?? "", unit: g.unit ?? "", grams,
          calories: Math.round(g.calories || 0), protein: g.protein || 0, fat: g.fat || 0, carbs: g.carbs || 0, fiber: g.fiber || 0,
          calPerG: grams ? (g.calories || 0) / grams : 0, pPerG: grams ? (g.protein || 0) / grams : 0,
          fPerG: grams ? (g.fat || 0) / grams : 0, cPerG: grams ? (g.carbs || 0) / grams : 0, fibPerG: grams ? (g.fiber || 0) / grams : 0,
        };
      });
      const sumG = Math.round(ingredients.reduce((s, i) => s + i.grams, 0));
      setRecipeDraft({ ingredients, finalWeight: sumG, note: out.note || "" });
    } catch (e) {
      setErr(e.message || "Couldn't read that recipe. One ingredient per line.");
    } finally {
      setBusy(false);
    }
  }

  async function saveRecipe(totals) {
    const fw = recipeDraft.finalWeight || totals.g || 1;
    const recipe = {
      id: uid(),
      name: recipeName.trim() || "Untitled recipe",
      ingredients: recipeDraft.ingredients.map(({ id, calPerG, pPerG, fPerG, cPerG, ...rest }) => rest),
      finalWeight: fw,
      servings: parseFloat(recipeServings) || null,
      totals: { cal: totals.cal, g: totals.g, p: Math.round(totals.p), f: Math.round(totals.f), c: Math.round(totals.c), fib: Math.round(totals.fib || 0) },
      per100: {
        cal: Math.round((totals.cal / fw) * 100),
        p: Math.round((totals.p / fw) * 100),
        f: Math.round((totals.f / fw) * 100),
        c: Math.round((totals.c / fw) * 100),
        fib: Math.round(((totals.fib || 0) / fw) * 100),
      },
    };
    const next = [recipe, ...recipes].slice(0, 50);
    setRecipes(next); await kvSet("recipes", next);
    setRecipeDraft(null); setRecipeText(""); setRecipeName(""); setRecipeServings("");
  }

  function logRecipePortion(recipe, grams) {
    const cal = Math.round((recipe.per100.cal * grams) / 100);
    const macros = {
      p: round1((recipe.per100.p * grams) / 100),
      f: round1((recipe.per100.f * grams) / 100),
      c: round1((recipe.per100.c * grams) / 100),
      fib: round1(((recipe.per100.fib || 0) * grams) / 100),
    };
    const entry = {
      id: uid(), ts: Date.now(), title: `${grams}g ${recipe.name}`, source: "recipe", total: cal, macros,
      items: [{ name: recipe.name, qty: grams, unit: "g", calories: cal, protein: macros.p, fat: macros.f, carbs: macros.c, fiber: macros.fib }],
    };
    persistLog([...log, entry]);
    setView("today");
  }

  async function deleteRecipe(id) {
    const next = recipes.filter((r) => r.id !== id);
    setRecipes(next); await kvSet("recipes", next);
  }

  async function loadHistory() {
    const keys = await kvList("log:");
    const rows = await Promise.all(keys.map(async (k) => {
      const entries = (await kvGet(k)) || [];
      const m = entries.reduce((a, e) => { const em = e.macros || sumMacros(e.items || []); return { p: a.p + (em.p || 0), f: a.f + (em.f || 0), c: a.c + (em.c || 0), fib: a.fib + (em.fib || 0) }; }, { p: 0, f: 0, c: 0, fib: 0 });
      return { key: k.replace("log:", ""), total: entries.reduce((s, e) => s + e.total, 0), count: entries.length, macros: m };
    }));
    rows.sort((a, b) => (a.key < b.key ? 1 : -1));
    setHistory(rows);
  }
  useEffect(() => { if (view === "history") loadHistory(); }, [view]);

  const draftTotal = draft ? draft.items.reduce((s, i) => s + i.calories, 0) : 0;

  // ── render ──
  return (
    <div style={{ fontFamily: F.body, background: T.paper, minHeight: "100vh", color: T.ink }}>
      <style>{`@import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500;600&display=swap');
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        input:focus, textarea:focus, button:focus-visible { outline: 2px solid ${T.green}; outline-offset: 1px; }
        ::placeholder { color: ${T.muted}; opacity: .7; }`}</style>

      <div style={{ maxWidth: 520, margin: "0 auto", padding: "0 16px 40px" }}>
        {/* Header */}
        <header style={{ paddingTop: 22, paddingBottom: 14 }}>
          <h1 style={{ fontFamily: F.display, fontSize: 20, fontWeight: 700, margin: 0, letterSpacing: -0.3, color: T.greenDeep }}>
            Tally<span style={{ color: T.amber }}>.</span>
          </h1>
          <nav style={{ display: "flex", gap: 4, background: T.surface, padding: 3, borderRadius: 10, border: `1px solid ${T.border}`, marginTop: 12 }}>
            {["today", "recipes", "usuals", "history"].map((v) => (
              <button key={v} onClick={() => setView(v)}
                style={{ flex: 1, fontFamily: F.body, fontSize: 12.5, fontWeight: 600, textTransform: "capitalize", padding: "8px 4px",
                  borderRadius: 7, border: "none", cursor: "pointer",
                  background: view === v ? T.green : "transparent", color: view === v ? "#fff" : T.muted }}>
                {v}
              </button>
            ))}
          </nav>
        </header>

        {!loaded ? (
          <div style={{ padding: 40, textAlign: "center", color: T.muted, fontSize: 14 }}>Loading your log…</div>
        ) : view === "today" ? (
          <>
            {/* Today total */}
            <section style={{ background: T.surface, border: `1px solid ${T.border}`, borderRadius: 16, padding: 18, marginBottom: 14 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 10 }}>
                <span style={{ fontFamily: F.mono, fontSize: 11, color: T.muted, textTransform: "uppercase", letterSpacing: 1 }}>{prettyDate(dateKey)}</span>
                {!editTarget ? (
                  <button onClick={() => { setEditTarget(true); setTargetInput(target || ""); }}
                    style={{ background: "none", border: "none", color: T.green, fontSize: 12, fontFamily: F.body, fontWeight: 600, cursor: "pointer" }}>
                    {target ? "edit goal" : "set a goal"}
                  </button>
                ) : (
                  <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
                    <input autoFocus value={targetInput} onChange={(e) => setTargetInput(e.target.value)} inputMode="numeric" placeholder="—"
                      style={{ width: 70, fontFamily: F.mono, fontSize: 13, padding: "4px 6px", border: `1px solid ${T.border}`, borderRadius: 6, textAlign: "center" }} />
                    <button onClick={saveTarget} style={{ background: T.green, color: "#fff", border: "none", borderRadius: 6, padding: "5px 9px", fontSize: 12, fontWeight: 600, cursor: "pointer" }}>set</button>
                  </div>
                )}
              </div>
              <Ring value={total} target={target} />
              {(dayMacros.p || dayMacros.f || dayMacros.c || dayMacros.fib) ? <MacroStrip p={dayMacros.p} f={dayMacros.f} c={dayMacros.c} fib={dayMacros.fib} /> : null}
            </section>

            {/* Add methods */}
            <section style={{ background: T.surface, border: `1px solid ${T.border}`, borderRadius: 16, padding: 16, marginBottom: 14 }}>
              <div style={{ display: "flex", gap: 4, marginBottom: 14, background: T.paper, padding: 3, borderRadius: 9 }}>
                {[["type", "Type a meal"], ["label", "Photo label"], ["barcode", "Barcode"]].map(([m, lbl]) => (
                  <button key={m} onClick={() => { setMethod(m); setErr(""); }}
                    style={{ flex: 1, fontFamily: F.body, fontSize: 12.5, fontWeight: 600, padding: "7px 4px", borderRadius: 6, border: "none", cursor: "pointer",
                      background: method === m ? T.surface : "transparent", color: method === m ? T.ink : T.muted,
                      boxShadow: method === m ? "0 1px 2px rgba(0,0,0,.06)" : "none" }}>
                    {lbl}
                  </button>
                ))}
              </div>

              {method === "type" && !draft && (
                <>
                  <textarea value={text} onChange={(e) => setText(e.target.value)} rows={2}
                    placeholder="e.g. chicken burrito bowl with rice, black beans, guac and a handful of chips"
                    style={{ width: "100%", fontFamily: F.body, fontSize: 14, color: T.ink, border: `1px solid ${T.border}`,
                      borderRadius: 10, padding: 11, resize: "none", marginBottom: 10, background: T.surfaceWarm }} />
                  <Btn onClick={breakItDown} disabled={busy || !text.trim()}>{busy ? "Working…" : "Break it down"}</Btn>
                  <div style={{ marginTop: 14, paddingTop: 14, borderTop: `1px solid ${T.border}` }}>
                    <div style={{ fontFamily: F.mono, fontSize: 10, color: T.muted, textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>or add by hand</div>
                    <div style={{ display: "flex", gap: 7 }}>
                      <input value={manualName} onChange={(e) => setManualName(e.target.value)} placeholder="Food"
                        style={{ flex: 2, fontFamily: F.body, fontSize: 14, border: `1px solid ${T.border}`, borderRadius: 9, padding: "9px 10px", background: T.surfaceWarm, minWidth: 0 }} />
                      <input value={manualCal} onChange={(e) => setManualCal(e.target.value)} placeholder="cal" inputMode="numeric"
                        style={{ width: 64, fontFamily: F.mono, fontSize: 14, border: `1px solid ${T.border}`, borderRadius: 9, padding: "9px 8px", background: T.surfaceWarm, textAlign: "center" }} />
                      <button onClick={addManual} disabled={!manualName.trim() || !(parseInt(manualCal) > 0)}
                        style={{ fontFamily: F.body, fontWeight: 600, fontSize: 14, background: T.green, color: "#fff", border: "none", borderRadius: 9, padding: "0 16px", cursor: "pointer", opacity: !manualName.trim() || !(parseInt(manualCal) > 0) ? 0.45 : 1 }}>Add</button>
                    </div>
                    <div style={{ display: "grid", gridTemplateColumns: "repeat(4, minmax(0, 1fr))", gap: 7, marginTop: 7 }}>
                      {[["P", manualP, setManualP], ["F", manualF, setManualF], ["C", manualC, setManualC], ["Fb", manualFib, setManualFib]].map(([lbl, val, set]) => (
                        <div key={lbl} style={{ display: "flex", alignItems: "center", gap: 4, background: T.surfaceWarm, border: `1px solid ${T.border}`, borderRadius: 9, padding: "0 8px", minWidth: 0 }}>
                          <span style={{ fontFamily: F.mono, fontSize: 12, color: T.muted, fontWeight: 600 }}>{lbl}</span>
                          <input value={val} onChange={(e) => set(e.target.value)} inputMode="decimal" placeholder="0"
                            style={{ flex: 1, fontFamily: F.mono, fontSize: 13, border: "none", background: "transparent", padding: "8px 0", minWidth: 0, width: "100%" }} />
                          <span style={{ fontSize: 11, color: T.muted }}>g</span>
                        </div>
                      ))}
                    </div>
                    <div style={{ fontSize: 11, color: T.muted, marginTop: 6 }}>Macros optional — calories are all you need to log.</div>
                  </div>
                </>
              )}

              {method === "type" && draft && (
                <div>
                  <div style={{ display: "grid", gridTemplateColumns: "1fr 52px 60px 24px", gap: 7, paddingBottom: 4, borderBottom: `1px solid ${T.border}` }}>
                    {["Item", "Qty", "Cal", ""].map((h, i) => (
                      <span key={i} style={{ fontFamily: F.mono, fontSize: 10, color: T.muted, textTransform: "uppercase", letterSpacing: .5, textAlign: i === 0 ? "left" : "center" }}>{h}</span>
                    ))}
                  </div>
                  {draft.items.map((it) => (
                    <DraftRow key={it.id} item={it}
                      onChange={(n) => setDraft({ ...draft, items: draft.items.map((x) => (x.id === it.id ? n : x)) })}
                      onRemove={() => setDraft({ ...draft, items: draft.items.filter((x) => x.id !== it.id) })} />
                  ))}
                  <button onClick={() => setDraft({ ...draft, items: [...draft.items, { id: uid(), name: "", qty: 1, unit: "serving", calories: 0, protein: 0, fat: 0, carbs: 0, fiber: 0, calPerUnit: 0, pPerUnit: 0, fPerUnit: 0, cPerUnit: 0, fibPerUnit: 0 }] })}
                    style={{ background: "none", border: "none", color: T.green, fontFamily: F.body, fontWeight: 600, fontSize: 13, cursor: "pointer", padding: "8px 0" }}>
                    + add item
                  </button>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", padding: "10px 0", borderTop: `1px solid ${T.border}`, marginTop: 4 }}>
                    <span style={{ fontFamily: F.body, fontSize: 13, color: T.muted }}>Meal total</span>
                    <span style={{ fontFamily: F.mono, fontSize: 22, fontWeight: 600, color: T.ink }}>{draftTotal.toLocaleString()}</span>
                  </div>
                  {(() => { const dm = sumMacros(draft.items); return (dm.p || dm.f || dm.c || dm.fib) ? <div style={{ marginTop: -4, marginBottom: 4 }}><MacroStrip p={dm.p} f={dm.f} c={dm.c} fib={dm.fib} /></div> : null; })()}
                  {draft.note ? <p style={{ fontSize: 12, color: T.muted, fontStyle: "italic", margin: "0 0 12px" }}>{draft.note}</p> : null}
                  <div style={{ display: "flex", gap: 8 }}>
                    <Btn onClick={commitDraft}>Add to log</Btn>
                    <Btn kind="ghost" onClick={saveUsual} style={{ width: "auto", whiteSpace: "nowrap" }}>Save usual</Btn>
                  </div>
                  <button onClick={() => { setDraft(null); }} style={{ background: "none", border: "none", color: T.muted, fontSize: 12.5, cursor: "pointer", width: "100%", padding: "10px 0 0" }}>discard</button>
                </div>
              )}

              {method === "label" && !label && (
                <div style={{ textAlign: "center", padding: "8px 0" }}>
                  <p style={{ fontSize: 13, color: T.muted, margin: "0 0 12px", lineHeight: 1.5 }}>
                    Snap or upload the Nutrition Facts panel. I'll read the calories and serving size off it.
                  </p>
                  <input ref={fileRef} type="file" accept="image/*" capture="environment" style={{ display: "none" }}
                    onChange={(e) => readLabel(e.target.files?.[0])} />
                  <Btn kind="amber" onClick={() => fileRef.current?.click()} disabled={busy}>{busy ? "Reading…" : "Choose photo"}</Btn>
                </div>
              )}

              {method === "label" && label && (
                <div>
                  <div style={{ background: T.amberSoft, borderRadius: 10, padding: 12, marginBottom: 12 }}>
                    <div style={{ fontFamily: F.display, fontWeight: 600, fontSize: 15, marginBottom: 2 }}>{label.productName || "Packaged item"}</div>
                    <div style={{ fontSize: 12, color: T.muted, fontFamily: F.mono }}>
                      {label.caloriesPerServing ?? "?"} cal / serving{label.servingSize ? ` · ${label.servingSize}` : ""}
                    </div>
                    {(label.proteinPerServing || label.fatPerServing || label.carbsPerServing || label.fiberPerServing) ? (
                      <div style={{ fontSize: 11.5, color: T.muted, fontFamily: F.mono, marginTop: 3 }}>
                        per serving — P{label.proteinPerServing ?? "?"} · F{label.fatPerServing ?? "?"} · C{label.carbsPerServing ?? "?"} · Fb{label.fiberPerServing ?? "?"}
                      </div>
                    ) : null}
                  </div>
                  <label style={{ fontSize: 13, color: T.ink, fontWeight: 500, display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
                    Servings eaten
                    <input value={label.servingsEaten} onChange={(e) => setLabel({ ...label, servingsEaten: parseFloat(e.target.value) || 0 })} inputMode="decimal"
                      style={{ width: 80, fontFamily: F.mono, fontSize: 15, padding: "7px 9px", border: `1px solid ${T.border}`, borderRadius: 8, textAlign: "center" }} />
                  </label>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", padding: "14px 0", borderTop: `1px solid ${T.border}`, borderBottom: `1px solid ${T.border}`, margin: "12px 0" }}>
                    <span style={{ fontSize: 13, color: T.muted }}>Adds to log</span>
                    <span style={{ fontFamily: F.mono, fontSize: 22, fontWeight: 600 }}>{Math.round((label.caloriesPerServing || 0) * (label.servingsEaten || 0)).toLocaleString()}</span>
                  </div>
                  <div style={{ display: "flex", gap: 8 }}>
                    <Btn kind="amber" onClick={commitLabel}>Add to log</Btn>
                    <Btn kind="ghost" onClick={() => setLabel(null)} style={{ width: "auto" }}>Cancel</Btn>
                  </div>
                </div>
              )}

              {method === "barcode" && (
                <div style={{ textAlign: "center", padding: "14px 6px" }}>
                  <div style={{ fontSize: 30, marginBottom: 8, opacity: .35 }}>▌║▌║▌</div>
                  <p style={{ fontSize: 13, color: T.muted, lineHeight: 1.55, margin: 0 }}>
                    Barcode scanning lights up once this runs on your backend — it needs an on-device scanner plus an
                    Open Food Facts lookup proxied through your server. For packaged items right now, use{" "}
                    <button onClick={() => setMethod("label")} style={{ background: "none", border: "none", color: T.amber, fontWeight: 600, cursor: "pointer", padding: 0, fontSize: 13, fontFamily: F.body, textDecoration: "underline" }}>Photo label</button>.
                  </p>
                </div>
              )}

              {err ? <p style={{ color: T.danger, fontSize: 13, marginTop: 10, marginBottom: 0 }}>{err}</p> : null}
            </section>

            {/* Today's log */}
            <section style={{ background: T.surface, border: `1px solid ${T.border}`, borderRadius: 16, padding: "6px 16px 14px" }}>
              {log.length === 0 ? (
                <p style={{ textAlign: "center", color: T.muted, fontSize: 13.5, padding: "26px 10px", lineHeight: 1.5 }}>
                  Nothing logged yet. Describe your first meal above — tap any line afterward to see its breakdown.
                </p>
              ) : (
                <>
                  <div style={{ fontFamily: F.mono, fontSize: 10, color: T.muted, textTransform: "uppercase", letterSpacing: 1, padding: "10px 0 2px" }}>Logged</div>
                  {[...log].reverse().map((e) => <LoggedEntry key={e.id} entry={e} onDelete={() => deleteEntry(e.id)} />)}
                </>
              )}
            </section>

            <p style={{ fontSize: 11, color: T.muted, textAlign: "center", marginTop: 16, lineHeight: 1.5 }}>
              Calorie figures are estimates for general tracking, not medical or dietary advice.
            </p>
          </>
        ) : view === "usuals" ? (
          <section style={{ background: T.surface, border: `1px solid ${T.border}`, borderRadius: 16, padding: 16 }}>
            <h2 style={{ fontFamily: F.display, fontSize: 15, margin: "2px 0 12px" }}>Saved usuals</h2>
            {usuals.length === 0 ? (
              <p style={{ color: T.muted, fontSize: 13.5, lineHeight: 1.5 }}>
                No usuals yet. When you break down a meal on the Today tab, tap "Save usual" to keep it here for one-tap logging.
              </p>
            ) : usuals.map((u) => (
              <div key={u.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "11px 0", borderBottom: `1px dashed ${T.border}` }}>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14, fontWeight: 500 }}>{u.name}</div>
                  <div style={{ fontSize: 12, color: T.muted, fontFamily: F.mono }}>
                    {u.total.toLocaleString()} cal{u.macros && (u.macros.p || u.macros.f || u.macros.c || u.macros.fib) ? ` · P${Math.round(u.macros.p)} F${Math.round(u.macros.f)} C${Math.round(u.macros.c)} Fb${Math.round(u.macros.fib || 0)}` : ""}
                  </div>
                </div>
                <button onClick={() => addUsual(u)} style={{ background: T.greenTint, color: T.greenDeep, border: "none", borderRadius: 8, padding: "8px 12px", fontWeight: 600, fontSize: 13, cursor: "pointer", fontFamily: F.body }}>+ Log</button>
                <button onClick={() => removeUsual(u.id)} style={{ background: "none", border: "none", color: T.muted, cursor: "pointer", fontSize: 17 }}>×</button>
              </div>
            ))}
          </section>
        ) : view === "recipes" ? (
          (() => {
            const rt = recipeDraft
              ? recipeDraft.ingredients.reduce((a, i) => ({ cal: a.cal + i.calories, g: a.g + i.grams, p: a.p + i.protein, f: a.f + i.fat, c: a.c + i.carbs, fib: a.fib + (i.fiber || 0) }), { cal: 0, g: 0, p: 0, f: 0, c: 0, fib: 0 })
              : null;
            const fw = recipeDraft?.finalWeight || (rt ? rt.g : 0) || 1;
            const per100 = rt ? Math.round((rt.cal / fw) * 100) : 0;
            return (
              <>
                <section style={{ background: T.surface, border: `1px solid ${T.border}`, borderRadius: 16, padding: 16, marginBottom: 14 }}>
                  {!recipeDraft ? (
                    <>
                      <h2 style={{ fontFamily: F.display, fontSize: 15, margin: "2px 0 4px" }}>Build a recipe</h2>
                      <p style={{ fontSize: 13, color: T.muted, margin: "0 0 12px", lineHeight: 1.5 }}>
                        List the ingredients with amounts, one per line. I'll estimate the weight and nutrition of each, then give you calories per 100g — so you can log any portion later.
                      </p>
                      <input value={recipeName} onChange={(e) => setRecipeName(e.target.value)} placeholder="Recipe name (e.g. weeknight chili)"
                        style={{ width: "100%", fontFamily: F.body, fontSize: 14, border: `1px solid ${T.border}`, borderRadius: 10, padding: 11, marginBottom: 8, background: T.surfaceWarm }} />
                      <textarea value={recipeText} onChange={(e) => setRecipeText(e.target.value)} rows={5}
                        placeholder={"1 lb ground beef\n2 cans kidney beans\n1 onion, diced\n2 tbsp olive oil\n1 can crushed tomatoes"}
                        style={{ width: "100%", fontFamily: F.body, fontSize: 14, color: T.ink, border: `1px solid ${T.border}`, borderRadius: 10, padding: 11, resize: "none", marginBottom: 10, background: T.surfaceWarm, lineHeight: 1.5 }} />
                      <Btn onClick={parseRecipe} disabled={busy || !recipeText.trim()}>{busy ? "Calculating…" : "Calculate nutrition"}</Btn>
                      {err ? <p style={{ color: T.danger, fontSize: 13, marginTop: 10, marginBottom: 0 }}>{err}</p> : null}
                    </>
                  ) : (
                    <>
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 8 }}>
                        <h2 style={{ fontFamily: F.display, fontSize: 15, margin: 0 }}>{recipeName.trim() || "Untitled recipe"}</h2>
                        <button onClick={() => setRecipeDraft(null)} style={{ background: "none", border: "none", color: T.muted, fontSize: 12.5, cursor: "pointer" }}>start over</button>
                      </div>
                      {recipeDraft.ingredients.map((it) => (
                        <RecipeRow key={it.id} item={it}
                          onChange={(n) => setRecipeDraft({ ...recipeDraft, ingredients: recipeDraft.ingredients.map((x) => (x.id === it.id ? n : x)) })}
                          onRemove={() => setRecipeDraft({ ...recipeDraft, ingredients: recipeDraft.ingredients.filter((x) => x.id !== it.id) })} />
                      ))}
                      <button onClick={() => setRecipeDraft({ ...recipeDraft, ingredients: [...recipeDraft.ingredients, { id: uid(), name: "", qty: "", unit: "", grams: 0, calories: 0, protein: 0, fat: 0, carbs: 0, calPerG: 0, pPerG: 0, fPerG: 0, cPerG: 0 }] })}
                        style={{ background: "none", border: "none", color: T.green, fontFamily: F.body, fontWeight: 600, fontSize: 13, cursor: "pointer", padding: "9px 0" }}>+ add ingredient</button>

                      {/* Finished weight */}
                      <div style={{ background: T.surfaceWarm, border: `1px solid ${T.border}`, borderRadius: 10, padding: 12, margin: "8px 0 12px" }}>
                        <label style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
                          <span style={{ fontSize: 13, fontWeight: 500 }}>Finished dish weight</span>
                          <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
                            <input value={recipeDraft.finalWeight} onChange={(e) => setRecipeDraft({ ...recipeDraft, finalWeight: Math.max(0, parseFloat(e.target.value) || 0) })} inputMode="decimal"
                              style={{ width: 72, fontFamily: F.mono, fontSize: 14, padding: "6px 8px", border: `1px solid ${T.border}`, borderRadius: 8, textAlign: "center" }} />
                            <span style={{ fontSize: 12, color: T.muted }}>g</span>
                          </div>
                        </label>
                        <p style={{ fontSize: 11.5, color: T.muted, margin: "8px 0 0", lineHeight: 1.45 }}>
                          Defaults to the raw ingredient total. Weigh the cooked dish and enter it here for an accurate per-100g — cooking changes weight, calories stay the same.
                        </p>
                      </div>

                      {/* Summary */}
                      <div style={{ background: T.greenTint, borderRadius: 12, padding: 14, marginBottom: 12 }}>
                        <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginBottom: 6 }}>
                          <span style={{ fontFamily: F.mono, fontSize: 32, fontWeight: 600, color: T.greenDeep, lineHeight: 1 }}>{per100}</span>
                          <span style={{ fontSize: 13, color: T.greenDeep }}>cal / 100g</span>
                        </div>
                        <div style={{ fontSize: 12.5, color: T.greenDeep, fontFamily: F.mono, opacity: .85 }}>
                          Whole recipe {rt.cal.toLocaleString()} cal · {Math.round(rt.g)}g raw
                          {recipeServings && parseFloat(recipeServings) > 0 ? ` · ${Math.round(rt.cal / parseFloat(recipeServings))} cal/serving` : ""}
                        </div>
                        <div style={{ fontSize: 12, color: T.greenDeep, fontFamily: F.mono, opacity: .7, marginTop: 3 }}>
                          per 100g — P {Math.round((rt.p / fw) * 100)}g · F {Math.round((rt.f / fw) * 100)}g · C {Math.round((rt.c / fw) * 100)}g · Fb {Math.round((rt.fib / fw) * 100)}g
                        </div>
                      </div>

                      <label style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, marginBottom: 12 }}>
                        <span style={{ fontSize: 13, color: T.muted }}>Servings the recipe makes (optional)</span>
                        <input value={recipeServings} onChange={(e) => setRecipeServings(e.target.value)} inputMode="numeric" placeholder="—"
                          style={{ width: 64, fontFamily: F.mono, fontSize: 14, padding: "6px 8px", border: `1px solid ${T.border}`, borderRadius: 8, textAlign: "center" }} />
                      </label>

                      {recipeDraft.note ? <p style={{ fontSize: 12, color: T.muted, fontStyle: "italic", margin: "0 0 12px" }}>{recipeDraft.note}</p> : null}
                      <Btn onClick={() => saveRecipe(rt)}>Save recipe</Btn>
                    </>
                  )}
                </section>

                {recipes.length > 0 && (
                  <section style={{ background: T.surface, border: `1px solid ${T.border}`, borderRadius: 16, padding: "8px 16px 14px" }}>
                    <div style={{ fontFamily: F.mono, fontSize: 10, color: T.muted, textTransform: "uppercase", letterSpacing: 1, padding: "10px 0 2px" }}>Saved recipes</div>
                    {recipes.map((r) => <RecipeCard key={r.id} recipe={r} onLog={logRecipePortion} onDelete={() => deleteRecipe(r.id)} />)}
                  </section>
                )}
              </>
            );
          })()
        ) : view === "history" ? (
          <section style={{ background: T.surface, border: `1px solid ${T.border}`, borderRadius: 16, padding: 16 }}>
            <h2 style={{ fontFamily: F.display, fontSize: 15, margin: "2px 0 12px" }}>History</h2>
            {history.length === 0 ? (
              <p style={{ color: T.muted, fontSize: 13.5 }}>No days logged yet.</p>
            ) : history.map((h) => (
              <div key={h.key} style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", padding: "12px 0", borderBottom: `1px dashed ${T.border}` }}>
                <div>
                  <div style={{ fontSize: 14, fontWeight: 500 }}>{prettyDate(h.key)}</div>
                  <div style={{ fontSize: 11.5, color: T.muted, fontFamily: F.mono }}>
                    {h.count} entr{h.count === 1 ? "y" : "ies"}
                    {h.macros && (h.macros.p || h.macros.f || h.macros.c || h.macros.fib) ? ` · P${Math.round(h.macros.p)} F${Math.round(h.macros.f)} C${Math.round(h.macros.c)} Fb${Math.round(h.macros.fib || 0)}` : ""}
                    {target && h.total > target ? " · over goal" : ""}
                  </div>
                </div>
                <span style={{ fontFamily: F.mono, fontSize: 18, fontWeight: 600, color: target && h.total > target ? T.danger : T.ink }}>{h.total.toLocaleString()}</span>
              </div>
            ))}
          </section>
        ) : null}
      </div>
    </div>
  );
}
