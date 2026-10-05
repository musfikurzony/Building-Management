/* =====================================================================
   whatsapp.js — handing a message to WhatsApp, on a laptop and a phone.

   WHY NOT JUST wa.me
   ------------------
   https://wa.me/... works on a laptop: the page it opens offers to hand
   over to WhatsApp Desktop. On a phone it often does not. When the portal
   is installed as an app, a link it opens in a new tab lands in an
   in-app browser tab, and that tab shows WhatsApp's web page — "Download
   WhatsApp" — instead of opening the WhatsApp already on the phone. That
   is what was reported from the building.

   whatsapp://send?... is the app's own address. A phone with WhatsApp
   (or WhatsApp Business) installed opens it straight away, chat and text
   filled in. If nothing opens it within a moment — WhatsApp is not
   installed — we fall back to wa.me so the person still gets somewhere.
   ===================================================================== */

/** A phone or tablet, where whatsapp:// is the reliable way in. */
export function isPhone(){
  const ua = navigator.userAgent || '';
  return /Android|iPhone|iPad|iPod|Mobile/i.test(ua)
      || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);   // iPadOS reports as a Mac
}

/** wa.me link: works everywhere, best on a laptop. */
export function webLink(digits, text){
  const t = encodeURIComponent(text || '');
  return digits ? `https://wa.me/${digits}?text=${t}` : `https://wa.me/?text=${t}`;
}

/** The installed app's own link. Without a number WhatsApp asks whom to send to. */
export function appLink(digits, text){
  const t = encodeURIComponent(text || '');
  return digits ? `whatsapp://send?phone=${digits}&text=${t}` : `whatsapp://send?text=${t}`;
}

/** The link to put on a button for this device. */
export function whatsappHref(digits, text){
  return isPhone() ? appLink(digits, text) : webLink(digits, text);
}

/**
 * Make an <a> open WhatsApp properly on this device.
 *
 * On a laptop: wa.me in a new tab. On a phone: whatsapp:// in the same
 * tab (a custom scheme never navigates the page away), and if the page is
 * still in front 1.6 seconds later — nothing took the link — wa.me
 * instead. Call it again whenever the text changes.
 */
export function wireWhatsAppLink(a, digits, text){
  const phone = isPhone();
  a.href = phone ? appLink(digits, text) : webLink(digits, text);
  if (phone){ a.removeAttribute('target'); a.removeAttribute('rel'); }
  else { a.target = '_blank'; a.rel = 'noopener'; }
  a.dataset.waFallback = webLink(digits, text);
  if (!a.dataset.waWired){
    a.dataset.waWired = '1';
    a.addEventListener('click', (ev) => {
      if (!isPhone() || ev.defaultPrevented) return;
      armFallback(a.dataset.waFallback);
    });
  }
}

/** Open WhatsApp from code (a button rather than a link). */
export function openWhatsApp(digits, text){
  if (isPhone()){
    armFallback(webLink(digits, text));
    location.href = appLink(digits, text);
  } else {
    window.open(webLink(digits, text), '_blank', 'noopener');
  }
}

function armFallback(url){
  let left = false;
  const away = () => { if (document.visibilityState === 'hidden') left = true; };
  document.addEventListener('visibilitychange', away);
  window.addEventListener('pagehide', away);
  setTimeout(() => {
    document.removeEventListener('visibilitychange', away);
    window.removeEventListener('pagehide', away);
    if (!left && document.visibilityState === 'visible') window.open(url, '_blank', 'noopener');
  }, 1600);
}
