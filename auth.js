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

function goToSignIn() { window.location.href = 'index.html'; }

// ---------------------------------------------------------------------------
// Profile lookup. The app is individual-use: every signed-in user is a single
// runner with their own row in `athletes`. There is no coach role or roster.
// The row is auto-created on first sign-in (self-provisioning).
//   { user, row }   — signed in (row created if it didn't exist)
//   null            — not signed in
// ---------------------------------------------------------------------------
async function getProfile() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const uid = session.user.id;

  let { data: row } = await sb
    .from('athletes')
    .select('id, first_name, last_name, grade')
    .eq('auth_user_id', uid)
    .maybeSingle();

  if (!row) {
    const email = session.user.email || '';
    const first = email.split('@')[0] || 'Runner';
    const { data: created } = await sb
      .from('athletes')
      .insert({ auth_user_id: uid, email: email, first_name: first, last_name: '' })
      .select('id, first_name, last_name, grade')
      .single();
    row = created;
  }
  return { user: session.user, row: row };
}

// Page gate: requires a signed-in user and returns their profile (creating it
// on first visit), or null after redirecting to sign-in.
async function requireProfile() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { goToSignIn(); return null; }
  return await getProfile();
}

// Personal-app gate (nutrition + future personal-health pages). Unlike the
// roster gates above, this requires only a signed-in auth user — no athlete/
// coach lookup. Used by the individual-use side of the app (see the
// personal-health pivot). Returns { user } or null after redirecting.
async function requireUser() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { goToSignIn(); return null; }
  return { user: session.user };
}

// "Switch user" / sign out everywhere.
async function signOut() {
  try { await sb.auth.signOut(); } catch (_) { /* clear local state regardless */ }
  window.location.href = 'index.html';
}

// Runner display convention: "Porter Smith" -> "Porter S." Used wherever a
// runner's name is shown (the menu, run lists).
function shortName(first, last) {
  const f = (first || '').trim();
  const l = (last || '').trim();
  return f + (l ? ' ' + l.charAt(0) + '.' : '');
}

// Convenience for the signed-in user: "Jeff S."
function displayName(profile) {
  if (!profile || !profile.row) return '';
  return shortName(profile.row.first_name, profile.row.last_name);
}
