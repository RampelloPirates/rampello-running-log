// ============================================================================
// Shared auth + Supabase client for the Tampa Bay Pirates running log.
//
// Load this AFTER the supabase-js CDN and BEFORE each page's inline script:
//   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
//   <script src="auth.js"></script>
//   <script> ...page code, which uses `sb` and the require* gates... </script>
//
// Real sessions: once a kid signs in (magic link / 6-digit code on index.html),
// supabase-js persists the session in localStorage and auto-refreshes it, so
// they stay signed in. Every page gates on getSession() and looks the user up
// on the roster by auth_user_id.
// ============================================================================

const SUPABASE_URL = 'https://dprmpgjgjppvdlyxlubr.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRwcm1wZ2pnanBwdmRseXhsdWJyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg5NTI5MTgsImV4cCI6MjA5NDUyODkxOH0.lyhPhWYE8EqSRAIzwn0yQ36d6Ue2TZjZodZlQqfnDfI';

// Single shared client. Pages reference `sb` directly.
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

// ---------------------------------------------------------------------------
// Profile lookup. Returns the signed-in user's roster identity:
//   { user, kind: 'coach' | 'athlete', row }   — row is the coach/athlete record
//   { user, kind: null, row: null }             — signed in but NOT on the roster
//   null                                         — not signed in
// Coaches are checked first so a person listed as both reads as a coach.
// ---------------------------------------------------------------------------
async function getProfile() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const uid = session.user.id;

  const { data: coach } = await sb
    .from('coaches')
    .select('id, first_name, last_name, role')
    .eq('auth_user_id', uid)
    .eq('active', true)
    .maybeSingle();
  if (coach) return { user: session.user, kind: 'coach', row: coach };

  const { data: athlete } = await sb
    .from('athletes')
    .select('id, first_name, last_name, grade')
    .eq('auth_user_id', uid)
    .eq('active', true)
    .maybeSingle();
  if (athlete) return { user: session.user, kind: 'athlete', row: athlete };

  return { user: session.user, kind: null, row: null };
}

function goToSignIn() { window.location.href = 'index.html'; }

// Require any signed-in roster member. A signed-in user who isn't on the roster
// (or whose account was deactivated) is signed out and bounced to the picker.
// Returns the profile, or null after redirecting.
async function requireSession() {
  const p = await getProfile();
  if (!p) { goToSignIn(); return null; }
  if (!p.kind) { await sb.auth.signOut(); goToSignIn(); return null; }
  return p;
}

// Athlete-only pages. Coaches are sent to their dashboard.
async function requireAthlete(coachDest = 'team_dashboard.html') {
  const p = await requireSession();
  if (!p) return null;
  if (p.kind === 'coach') { window.location.href = coachDest; return null; }
  return p; // { user, kind:'athlete', row }
}

// Coach-only pages. Athletes are sent to their own runs.
async function requireCoach(athleteDest = 'my_runs.html') {
  const p = await requireSession();
  if (!p) return null;
  if (p.kind !== 'coach') { window.location.href = athleteDest; return null; }
  return p; // { user, kind:'coach', row }
}

// "Switch user" / sign out everywhere.
async function signOut() {
  try { await sb.auth.signOut(); } catch (_) { /* clear local state regardless */ }
  window.location.href = 'index.html';
}

// Convenience: a short display name like "Jeff S." or "Coach Sowell".
function displayName(profile) {
  if (!profile || !profile.row) return '';
  const f = profile.row.first_name || '';
  const l = profile.row.last_name || '';
  const short = f + (l ? ' ' + l.charAt(0) + '.' : '');
  return profile.kind === 'coach' ? 'Coach ' + short : short;
}
