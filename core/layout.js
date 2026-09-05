/* =====================================================================
   layout.js — decides whether this is the phone layout or the desktop one.

   Why this is not just a CSS media query
   -------------------------------------
   It used to be. `@media (max-width:860px)` answers "how wide is the
   viewport", and for most of the world that is the same question as "is
   this a phone". It comes apart in one case that is common enough to
   matter here: Chrome on Android with "Desktop site" ticked lays the page
   out at roughly 980px on a 360px screen. Every width query goes false,
   the phone renders the laptop layout, and the only way to read anything
   is to pinch and pan. Worse, the setting is sticky per site and an
   installed home-screen app inherits it, so it looks permanent and looks
   like the app's fault.

   So the switch lives here instead, as a class on <html>:

     .is-narrow   drawer navigation + bottom tab bar
     .is-phone    tables become stacked cards, dialogs become sheets

   Three inputs decide it, in order of authority:

     1. An explicit choice by the person using it. Always wins. This is
        the part that is guaranteed to work, whatever a browser reports.
     2. The physical screen plus touch, which survives desktop-site mode
        on the devices where it is reported honestly.
     3. The viewport width, which is right whenever nothing is lying.

   (2) is best-effort by nature — a browser that misreports its screen
   defeats it — which is exactly why (1) exists and is offered in the
   menu rather than buried.
   ===================================================================== */

const KEY = 'bms.layout';          // 'auto' | 'mobile' | 'desktop'

export function layoutPref(){
  try { return localStorage.getItem(KEY) || 'auto'; } catch { return 'auto'; }
}

export function setLayoutPref(v){
  try {
    if (v === 'auto') localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, v);
  } catch { /* private mode: the session still works, it just won't persist */ }
  applyLayout();
}

/**
 * Does this look like a phone held in a hand, regardless of the width
 * the browser claims to be laying out at?
 *
 * `screen.width/height` is the device's own screen, not the viewport, so
 * it is unaffected by a page-level zoom or a desktop-mode override on the
 * browsers that report it faithfully. Requiring touch as well keeps a
 * small laptop window on the desktop layout, which is what someone
 * resizing a window on a desktop expects.
 */
function looksLikeHandheld(){
  const touch = (navigator.maxTouchPoints || 0) > 0 || 'ontouchstart' in window;
  const w = Number(screen?.width) || 0;
  const h = Number(screen?.height) || 0;
  if (!touch || !w || !h) return false;
  return Math.min(w, h) <= 820;
}

export function computeLayout(){
  const pref = layoutPref();
  if (pref === 'mobile')  return { narrow: true,  phone: true  };
  if (pref === 'desktop') return { narrow: false, phone: false };
  const handheld = looksLikeHandheld();
  return {
    narrow: handheld || window.innerWidth <= 860,
    phone:  handheld || window.innerWidth <= 640,
  };
}

export function applyLayout(){
  const { narrow, phone } = computeLayout();
  const root = document.documentElement;
  root.classList.toggle('is-narrow', narrow);
  root.classList.toggle('is-phone',  phone);
  root.dataset.layoutPref = layoutPref();
}

let wired = false;
export function watchLayout(){
  if (wired) return;
  wired = true;
  applyLayout();
  // Rotating a phone or resizing a window changes the answer.
  addEventListener('resize', applyLayout, { passive: true });
  addEventListener('orientationchange', applyLayout, { passive: true });
}

/** Label for the menu item, so the menu says what tapping it will do. */
export function layoutMenuLabel(){
  const pref = layoutPref();
  if (pref === 'mobile')  return 'View: Mobile (forced)';
  if (pref === 'desktop') return 'View: Desktop (forced)';
  return 'View: Automatic';
}

/** Cycles auto -> mobile -> desktop -> auto. */
export function cycleLayoutPref(){
  const next = { auto: 'mobile', mobile: 'desktop', desktop: 'auto' }[layoutPref()] || 'mobile';
  setLayoutPref(next);
  return next;
}
