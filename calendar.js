// ============================================================================
// Shared calendar logic for family.html (the phone) and wall.html (the screen).
//
// Load AFTER supabase-js and auth.js, BEFORE the page's own script:
//   <script src="calendar.js"></script>
//
// This exists for one reason: recurrence. Expanding an RRULE, deciding which
// day an occurrence falls on, and knowing that Sunday belongs to the pay week
// that is ending are the fiddliest things in the app and the only ones with a
// real test suite behind them. Two copies would be two bug surfaces, and they
// would drift — the wall would keep a bug the phone had already lost.
//
// Everything here is pure: no globals, no DOM, no Supabase. Callers pass their
// own data in. That's what lets the test harness exercise it without a browser.
// ============================================================================

// ── Dates ───────────────────────────────────────────────────────────────────
// All handled as local calendar days. A household lives in one timezone, which
// is what households.time_zone records; a date means that day where the family
// is, not UTC.
function pad2(n) { return String(n).padStart(2, '0'); }
// Every date string in either page comes from here, which is why the guard
// belongs here and not at the call sites.
//
// An Invalid Date formats to "NaN-NaN-NaN" without complaint, and that string
// then travels: into a query parameter, into a window bound, into a row about
// to be inserted. It is compared as text, and "N" outranks every digit, so it
// wins every > comparison it meets and sticks. The failure surfaces wherever
// it is finally used — Postgres reports the date type and never the caller —
// so it reads as a fault in some unrelated feature, arbitrarily far from
// whatever actually produced the bad Date.
//
// Failing here costs one thrown error at the source, with the caller on the
// stack. That is the whole point: the value must not be allowed to exist.
function ymd(d) {
  if (!(d instanceof Date) || isNaN(d.getTime())) {
    throw new Error('ymd(): not a valid Date — ' + String(d));
  }
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}
function parseYmd(s) { const p = String(s).split('-').map(Number); return new Date(p[0], p[1] - 1, p[2]); }
function todayYmd() { return ymd(new Date()); }
function minYmd(a, b) { return a < b ? a : b; }
function addDays(d, n) { const x = new Date(d); x.setDate(x.getDate() + n); return x; }

// Sunday-start: the month grid's columns and the meal planner's week.
function startOfWeek(d) { const x = new Date(d); x.setHours(0, 0, 0, 0); return addDays(x, -x.getDay()); }
// Monday-start: the ALLOWANCE week, deliberately not the same, so a Sunday
// evening push counts toward the week it belongs to rather than the next one.
function startOfPayWeek(d) {
  const x = new Date(d); x.setHours(0, 0, 0, 0);
  return addDays(x, -((x.getDay() + 6) % 7));      // Mon→0 … Sun→6
}

function fmtDayHead(dateStr) {
  const t = todayYmd();
  if (dateStr === t) return 'Today';
  if (dateStr === ymd(addDays(new Date(), 1))) return 'Tomorrow';
  return parseYmd(dateStr).toLocaleDateString(undefined,
    { weekday: 'long', month: 'short', day: 'numeric' });
}
function fmtTime(iso) {
  return new Date(iso).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}
// "5p" / "5:30p" — a month cell has no room for "5:00 PM", and the minutes
// only matter when they aren't zero.
function shortTime(iso) {
  const d = new Date(iso);
  let h = d.getHours();
  const m = d.getMinutes(), ap = h < 12 ? 'a' : 'p';
  h = h % 12 || 12;
  return h + (m ? ':' + pad2(m) : '') + ap;
}

// ── Recurrence ──────────────────────────────────────────────────────────────
// Deliberately a small hand-rolled reader, NOT a general RRULE engine. It only
// ever sees rules the app's own picker produced:
//
//   FREQ=DAILY|WEEKLY|MONTHLY[;BYDAY=MO,WE][;UNTIL=YYYYMMDD]
//
// When iCloud sync lands this starts receiving arbitrary rules from the wild —
// nested BYSETPOS, BYMONTHDAY lists, EXDATE runs — and it should be swapped
// for rrule.js rather than extended. Parsing what you generated yourself is a
// different problem from parsing what Apple sends.
const DOW = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
const DOW_LABEL = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function parseRule(rrule) {
  const out = {};
  String(rrule || '').split(';').forEach(function (p) {
    const kv = p.split('=');
    if (kv[0]) out[kv[0].toUpperCase()] = kv[1];
  });
  return out;
}

function ruleMatches(rule, day, anchor) {
  const r = parseRule(rule);
  if (r.UNTIL) {
    const u = String(r.UNTIL).slice(0, 8);
    const until = new Date(+u.slice(0, 4), +u.slice(4, 6) - 1, +u.slice(6, 8));
    if (day > until) return false;
  }
  if (day < anchor) return false;
  const freq = (r.FREQ || '').toUpperCase();
  if (freq === 'DAILY') return true;
  if (freq === 'WEEKLY') {
    const days = r.BYDAY ? r.BYDAY.split(',') : [DOW[anchor.getDay()]];
    return days.indexOf(DOW[day.getDay()]) !== -1;
  }
  if (freq === 'MONTHLY') return day.getDate() === anchor.getDate();
  return false;
}

// UNTIL as a plain YYYY-MM-DD, or null. RFC 5545 allows a trailing time on it;
// only the date half is ever used here, and only the date half is written.
function untilOf(rrule) {
  const u = parseRule(rrule).UNTIL;
  if (!u) return null;
  const s = String(u).slice(0, 8);
  if (s.length !== 8) return null;
  return s.slice(0, 4) + '-' + s.slice(4, 6) + '-' + s.slice(6, 8);
}

function ruleLabel(rrule) {
  if (!rrule) return '';
  const r = parseRule(rrule);
  const f = (r.FREQ || '').toUpperCase();
  let base;
  if (f === 'DAILY') base = 'Every day';
  else if (f === 'MONTHLY') base = 'Monthly';
  else if (f === 'WEEKLY') {
    if (!r.BYDAY) base = 'Weekly';
    else {
      const names = r.BYDAY.split(',').map(function (d) { return DOW_LABEL[DOW.indexOf(d)]; })
        .filter(Boolean);
      base = names.length === 7 ? 'Every day' : names.join(', ');
    }
  } else base = 'Repeats';

  const u = untilOf(rrule);
  // Worth saying out loud: a series that stops is easy to forget you set up,
  // and "Every day" reading the same whether or not it ends in a fortnight is
  // how you end up wondering where a chore went.
  if (u) base += ' until ' + parseYmd(u).toLocaleDateString(undefined,
    { month: 'short', day: 'numeric' });
  return base;
}

// A full week entirely on or after the start date. Using the current week when
// something starts midway through it undercounts: a daily chore added on a
// Sunday scores 1, because ruleMatches quite correctly refuses the six days
// before it existed. Right for "what's due this week", wrong for "how often
// does this happen".
function representativeWeek(anchor) {
  const thisWeek = startOfPayWeek(new Date());
  if (anchor <= thisWeek) return thisWeek;
  return startOfPayWeek(addDays(anchor, 6));
}

function occurrencesPerWeek(c) {
  if (isExtra(c)) return 0;                  // standing offers aren't scheduled
  if (!c.rrule) return 1;                    // a one-off counts once
  const anchor = parseYmd(c.starts_on);
  const start = representativeWeek(anchor);
  let n = 0;
  for (let i = 0; i < 7; i++) if (ruleMatches(c.rrule, addDays(start, i), anchor)) n++;
  return n;
}

// Expand events into { 'YYYY-MM-DD': [occurrence] } across an inclusive range.
// Recurring series have no rows of their own, so every render walks them.
function expandRange(startDate, endDate, list) {
  const byDay = {};
  for (let d = new Date(startDate); d <= endDate; d = addDays(d, 1)) byDay[ymd(d)] = [];
  (list || []).forEach(function (ev) {
    const anchorStr = ev.all_day ? ev.start_date : ymd(new Date(ev.starts_at));
    const anchor = parseYmd(anchorStr);
    const ex = (ev.exdates || []).map(function (x) { return ymd(new Date(x)); });
    if (!ev.rrule) {
      if (byDay[anchorStr]) byDay[anchorStr].push({ ev: ev, dateStr: anchorStr });
      // Multi-day all-day events fill the days between, including when the
      // event began before the window opened.
      if (ev.all_day && ev.end_date && ev.end_date !== ev.start_date) {
        let d = addDays(parseYmd(ev.start_date), 1);
        const end = parseYmd(ev.end_date);
        while (d <= end) {
          const k = ymd(d);
          if (byDay[k]) byDay[k].push({ ev: ev, dateStr: k, cont: true });
          d = addDays(d, 1);
        }
      }
      return;
    }
    Object.keys(byDay).forEach(function (k) {
      if (ex.indexOf(k) !== -1) return;
      if (ruleMatches(ev.rrule, parseYmd(k), anchor)) byDay[k].push({ ev: ev, dateStr: k });
    });
  });
  Object.keys(byDay).forEach(function (k) {
    byDay[k].sort(function (a, b) {
      if (a.ev.all_day !== b.ev.all_day) return a.ev.all_day ? -1 : 1;
      if (a.ev.all_day) return 0;
      const at = new Date(a.ev.starts_at), bt = new Date(b.ev.starts_at);
      return (at.getHours() * 60 + at.getMinutes()) - (bt.getHours() * 60 + bt.getMinutes());
    });
  });
  return byDay;
}

// ── Vocabularies both pages share ───────────────────────────────────────────
// Unrecognised values map back to the safe default in every case. A row that
// belongs to no section is invisible rather than merely mislabelled, which is
// the worse failure for a list of things somebody is meant to do.
const KINDS = [
  { key: 'chore', label: 'Chore', plural: 'Chores' },
  { key: 'todo',  label: 'To-do', plural: 'To-dos' },
  { key: 'extra', label: 'Extra', plural: 'Extras' }
];
function kindOf(c) {
  const k = (c && c.kind) || 'chore';
  return KINDS.some(function (x) { return x.key === k; }) ? k : 'chore';
}
function isExtra(c) { return kindOf(c) === 'extra'; }

// Same three values and the same nullable shape as runs.time_of_day. Null is a
// real answer — no particular time — which is why Anytime sorts last.
const SLOTS = [
  { key: 'morning',   label: 'Morning' },
  { key: 'afternoon', label: 'Afternoon' },
  { key: 'evening',   label: 'Evening' },
  { key: null,        label: 'Anytime' }
];
function slotOf(c) {
  const k = (c && c.time_of_day) || null;
  return SLOTS.some(function (s) { return s.key === k; }) ? k : null;
}

const MEAL_SLOTS = [
  { key: 'breakfast', label: 'Breakfast' },
  { key: 'lunch',     label: 'Lunch' },
  { key: 'dinner',    label: 'Dinner' }
];
const VENUES = [
  { key: 'eat_in',     label: 'Eat in' },
  { key: 'eat_out',    label: 'Eat out' },
  { key: 'at_friends', label: 'At friends' }
];
function labelOf(list, key) {
  const hit = list.filter(function (x) { return x.key === key; })[0];
  return hit ? hit.label : '';
}

// Which chores are due on a given day. Extras are excluded: they're standing
// offers rather than scheduled work.
function choresDueOn(chores, dateStr) {
  const day = parseYmd(dateStr);
  return (chores || []).filter(function (c) {
    if (c.active === false || isExtra(c)) return false;
    const anchor = parseYmd(c.starts_on);
    if (!c.rrule) return c.starts_on === dateStr;
    return ruleMatches(c.rrule, day, anchor);
  });
}

// Escaping lives here too, because both pages build HTML as strings and one of
// them renders text typed by other people.
function escHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}
