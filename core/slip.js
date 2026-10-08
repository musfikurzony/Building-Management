/* =====================================================================
   slip.js — look at a slip before it goes, then send it any way.

   One window for every slip the building sends — the PAID receipt, the
   month's bill, a flat's DUE slip: the picture exactly as the resident
   will receive it, and under it every way of sending it.

     Send picture   phone: the share sheet (WhatsApp, Messenger, email…)
                    laptop: saves the picture to attach in WhatsApp Web
     WhatsApp text  the same details as a message, to the payer's number
     SMS            the message as a text, on a phone
     Download       the picture, always saved, never shared
     PDF            an A4 page with the slip on it, for printing or filing
     Print          prints the slip alone, not the page behind it
   ===================================================================== */

import { el, modal, ok, err } from './ui.js';
import { receiptPdf, shareFile } from './receipt.js';
import { wireWhatsAppLink } from './whatsapp.js';

function download(blob, filename){
  const url = URL.createObjectURL(blob);
  const a = el('a', { href: url, download: filename });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1500);
}

/** Print just the picture: the page behind it is hidden for the print. */
function printImage(blob){
  const url = URL.createObjectURL(blob);
  const host = el('div', { id:'slipPrint' }, el('img', { src: url, alt:'' }));
  document.body.append(host);
  document.body.classList.add('printing-slip');
  const done = () => {
    document.body.classList.remove('printing-slip'); host.remove(); URL.revokeObjectURL(url);
    window.removeEventListener('afterprint', done);
  };
  window.addEventListener('afterprint', done);
  host.querySelector('img').onload = () => { window.print(); setTimeout(done, 2000); };   // some phones never fire afterprint
}

/**
 * @param {object} o
 *   title       window title
 *   draw        async () => PNG blob
 *   fileBase    file name without extension
 *   shareText   caption for the share sheet
 *   digits      payer's number for WhatsApp/SMS (international, digits only) or null
 *   text        message for WhatsApp/SMS, or null to leave those out
 *   onSent      (channel) => void   — WHATSAPP | SMS | IMAGE | PDF | PRINT | DOWNLOAD
 *   note        a line under the picture (who it goes to)
 */
export async function slipPreview(o){
  let blob;
  try { blob = await o.draw(); } catch (e){ return err('Could not draw the slip: ' + (e.message || e)); }
  const url = URL.createObjectURL(blob);
  const sent = (ch) => { try { o.onSent && o.onSent(ch); } catch {} };
  const busy = (btn, fn) => async (ev) => {
    if (btn.disabled) return;
    btn.disabled = true;
    try { await fn(ev); } catch (e){ err(e.message || String(e)); } finally { btn.disabled = false; }
  };

  const pic = el('button', { class:'btn primary', type:'button', text:'Send picture' });
  pic.onclick = busy(pic, async () => {
    const how = await shareFile(blob, `${o.fileBase}.png`, 'image/png', o.shareText || '');
    if (how === 'shared'){ ok('Sent.'); sent('IMAGE'); }
    if (how === 'downloaded'){ ok('Picture saved — attach it in WhatsApp.'); sent('IMAGE'); }
  });
  const btns = [pic];
  if (o.text){
    const wa = el('a', { class:'btn', text: o.digits ? 'WhatsApp message' : 'WhatsApp (choose contact)' });
    wireWhatsAppLink(wa, o.digits, o.text);
    wa.addEventListener('click', () => sent('WHATSAPP'));
    btns.push(wa);
    if (o.digits){
      const sms = el('a', { class:'btn', text:'SMS', href:`sms:+${o.digits}?&body=${encodeURIComponent(o.text)}` });
      sms.addEventListener('click', () => sent('SMS'));
      btns.push(sms);
    }
  }
  const dl = el('button', { class:'btn', type:'button', text:'Download picture' });
  dl.onclick = () => { download(blob, `${o.fileBase}.png`); ok('Picture downloaded.'); sent('DOWNLOAD'); };
  const pdf = el('button', { class:'btn', type:'button', text:'PDF' });
  pdf.onclick = busy(pdf, async () => {
    const how = await shareFile(await receiptPdf(blob), `${o.fileBase}.pdf`, 'application/pdf', o.shareText || '');
    if (how !== 'cancelled'){ ok(how === 'shared' ? 'PDF sent.' : 'PDF saved.'); sent('PDF'); }
  });
  const pr = el('button', { class:'btn', type:'button', text:'Print' });
  pr.onclick = () => { printImage(blob); sent('PRINT'); };
  btns.push(dl, pdf, pr);

  const body = el('div', { class:'slip-preview' },
    el('div', { class:'slip-frame' }, el('img', { src: url, alt: o.title || 'Slip', class:'slip-img' })),
    o.note ? el('p', { class:'small muted', text: o.note }) : null,
    el('div', { class:'btn-row slip-actions' }, btns));
  const res = await modal({ title: o.title || 'Preview', body, actions:[{ label:'Close', value:null }] });
  URL.revokeObjectURL(url);
  return res;
}
