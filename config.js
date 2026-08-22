/* Public configuration for the Building Management & Finance Portal.
 *
 * This application is entirely self-contained: its own Supabase project,
 * its own database, its own authentication, its own storage. It is not
 * connected to any other system.
 *
 * BOTH VALUES BELOW ARE PUBLIC BY DESIGN.
 *
 * The anon key is a JWT whose only claim is `role: anon`. It identifies
 * the project; it grants nothing. Every table in the `bms` schema has Row
 * Level Security switched on, the `anon` role holds no grant on any of
 * them, and every rule that matters — who may approve, what may be
 * edited, which month is closed — is enforced inside PostgreSQL. Someone
 * who copies this file out of the browser can do exactly what a stranger
 * standing at the sign-in page can do: nothing.
 *
 * A SERVICE-ROLE KEY MUST NEVER APPEAR HERE, or in any other file the
 * browser downloads. It bypasses Row Level Security completely and would
 * hand every reader of this page full control of the building's finances.
 * The same goes for the database password. Neither is needed: the portal
 * has never used either one.
 *
 * If you ever rotate the anon key, change it here and redeploy. Nothing
 * else in the application refers to it.
 */
window.BMS_CONFIG = {
  SUPABASE_URL: 'https://ebjkajgaardrlretiifk.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImViamthamdhYXJkcmxyZXRpaWZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODczNzE5NzcsImV4cCI6MjEwMjk0Nzk3N30.sxLA-DYJ5e_S-FU5U1cqVTbl5Dh1Hmr33XjX2VgPxp4'
};
