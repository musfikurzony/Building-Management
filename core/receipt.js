/* =====================================================================
   receipt.js — draws a payment receipt as a picture.

   WHY A PICTURE
   -------------
   A receipt shared to WhatsApp as text arrives as text: no building name
   in any recognisable form, nothing an owner can keep, and nothing that
   looks like a document six months later when they are asked whether
   they paid. A picture is what people actually forward, save and show.

   WHY IT IS DRAWN BY HAND
   -----------------------
   The obvious route is a screenshot library, but the Content Security
   Policy admits no third-party script and vendoring one for a page of
   text would be a lot of code to carry. A receipt is a title, a rule,
   some label/value pairs and a total — Canvas draws that in a hundred
   lines, at whatever pixel density we ask for, with no dependency and
   nothing to keep up to date.

   Everything is laid out in CSS-like units and multiplied by SCALE at
   draw time, so the output is crisp on a phone screen rather than the
   soft 1x image a naive canvas produces.
   ===================================================================== */

const SCALE = 3;                  // 3x for a sharp image on a phone
const W     = 380;                // logical width; height grows with content

const INK    = '#12211d';
const MUTED  = '#6d7f79';
const ACCENT = '#0d6b4f';
const PAPER  = '#ffffff';
const LINE   = '#d3ddd8';

/**
 * Draw the receipt and return a PNG blob.
 *
 * @param {object} r
 *   building, address, title, receiptNo, date, flat, amount, method,
 *   advance, lines[{label,value}], footer
 */
export async function receiptImage(r){
  // Two passes. The first draws nothing and only reports how tall the
  // content came out; the second draws it on a canvas of exactly that
  // height. Guessing the height from a formula left a band of empty
  // paper under the total whenever the address happened to fit on one
  // line — visible the moment you actually look at the image, and
  // invisible to any check that only asks whether a PNG came back.
  const probe = document.createElement('canvas').getContext('2d');
  const H = layout(probe, r, false);

  const c = document.createElement('canvas');
  c.width  = W * SCALE;
  c.height = H * SCALE;
  const g = c.getContext('2d');
  g.scale(SCALE, SCALE);
  layout(g, r, true, H);

  return new Promise((resolve) => c.toBlob(resolve, 'image/png'));
}

/**
 * Lays the receipt out, and draws it only when `paint` is true.
 * Returns the total height the content needs.
 */
function layout(g, r, paint, H){

  const font = (size, weight = 400) =>
    `${weight} ${size}px "Segoe UI", Roboto, system-ui, -apple-system, "Noto Sans Bengali", sans-serif`;

  if (paint){
    g.fillStyle = PAPER;
    g.fillRect(0, 0, W, H);
    // A hairline border so the image reads as a document on a white chat
    // background rather than as floating text.
    g.strokeStyle = LINE; g.lineWidth = 1;
    g.strokeRect(0.5, 0.5, W - 1, H - 1);
  }

  const PAD  = 24;
  const rows = (r.lines || []).length;
  let y = 38;

  const centre = (text, f, colour) => {
    g.font = f;
    if (!paint) return;
    g.fillStyle = colour; g.textAlign = 'center';
    g.fillText(text, W / 2, y);
  };
  const rule = () => {
    if (!paint) return;
    g.strokeStyle = LINE; g.beginPath();
    g.moveTo(PAD, y); g.lineTo(W - PAD, y); g.stroke();
  };

  centre(r.building || 'Building', font(19, 700), INK);
  y += 19;

  if (r.address){
    // Address can be long; wrap it rather than letting it run off the edge.
    g.font = font(11); g.textAlign = 'center';
    for (const line of wrap(g, r.address, W - PAD * 2).slice(0, 2)){
      if (paint){ g.fillStyle = MUTED; g.fillText(line, W / 2, y); }
      y += 14;
    }
  }

  y += 6;
  centre(r.title || 'Service charge receipt', font(11, 600), ACCENT);
  y += 16;

  rule();
  y += 24;

  // Label / value pairs, values right-aligned so the numbers line up.
  const pair = (label, value, opts = {}) => {
    if (paint){
      g.textAlign = 'left';
      g.font = font(12); g.fillStyle = MUTED;
      g.fillText(label, PAD, y);
      g.textAlign = 'right';
      g.font = font(opts.big ? 15 : 12, opts.big ? 700 : 500);
      g.fillStyle = opts.big ? ACCENT : INK;
      g.fillText(value, W - PAD, y);
    }
    y += opts.big ? 26 : 21;
  };

  if (r.receiptNo) pair(r.noLabel || 'Receipt no', r.receiptNo);
  if (r.date)      pair('Date',       r.date);
  if (r.flat)      pair('Flat',       r.flat);
  if (r.from){
    // A long name is cut rather than allowed to run over its label.
    g.font = font(12, 500);
    let name = String(r.from);
    while (name.length > 4 && g.measureText(name).width > W - PAD * 2 - 100) name = name.slice(0, -2);
    pair(r.fromLabel || 'Received from', name === String(r.from) ? name : name.trim() + '…');
  }
  if (r.method)    pair('Method',     r.method);
  if (r.reference) pair('Reference',  String(r.reference).slice(0, 28));

  if (rows){
    y -= 4; rule(); y += 16;
    for (const l of r.lines) pair(l.label, l.value);
  }

  y -= 4; rule(); y += 20;

  pair(r.amountLabel || 'Received', r.amount || '', { big: true });

  // A line under the total in the ink colour — the bill's "Please pay by …".
  if (r.note){
    if (paint){
      g.textAlign = 'center'; g.font = font(13, 600); g.fillStyle = INK;
      g.fillText(r.note, W / 2, y);
    }
    y += 22;
  }

  if (r.advance){
    if (paint){
      g.textAlign = 'center'; g.font = font(11); g.fillStyle = MUTED;
      g.fillText(r.advance, W / 2, y);
    }
    y += 20;
  }

  // The seal: a rubber stamp pressed under the total — PAID on a receipt,
  // DUE on a bill. Its own space, so it never hides a figure.
  if (r.seal){
    y += 4;
    if (paint) drawSeal(g, r.seal, W / 2, y + 40, font);
    y += 88;
  }

  y += 12;
  if (paint){
    g.textAlign = 'center'; g.font = font(10); g.fillStyle = MUTED;
    g.fillText(r.footer || 'Thank you.', W / 2, y);
  }
  y += 18;

  // A reversed payment's receipt can still be looked at, but must never be
  // mistaken for proof of payment: it is stamped across the middle.
  if (r.stamp && paint){
    g.save();
    g.translate(W / 2, H / 2);
    g.rotate(-Math.PI / 9);
    g.font = font(34, 800); g.textAlign = 'center';
    g.fillStyle = 'rgba(156,51,34,.22)';
    g.fillText(r.stamp, 0, 12);
    g.strokeStyle = 'rgba(156,51,34,.45)'; g.lineWidth = 2;
    const w = g.measureText(r.stamp).width + 24;
    g.strokeRect(-w / 2, -26, w, 50);
    g.restore();
  }

  // The seal: a rubber stamp pressed beside the total — PAID on a receipt,
  // DUE on a bill. Drawn, not an image, so it is as sharp as the text.
  return y;
}

const SEAL = { green:'#0b7a4b', red:'#b3261e', amber:'#a15c00' };

/** A double-ringed oval stamp, tilted, with a word and a line under it. */
function drawSeal(g, seal, cx, cy, font){
  const col = SEAL[seal.color] || seal.color || SEAL.green;
  g.save();
  g.translate(cx, cy);
  g.rotate(-0.24);
  g.globalAlpha = 0.86;
  g.strokeStyle = col; g.fillStyle = col;
  const rx = 66, ry = 38;
  g.lineWidth = 3;   g.beginPath(); g.ellipse(0, 0, rx, ry, 0, 0, Math.PI * 2); g.stroke();
  g.lineWidth = 1.2; g.beginPath(); g.ellipse(0, 0, rx - 6, ry - 6, 0, 0, Math.PI * 2); g.stroke();
  g.textAlign = 'center';
  // Small lines shrink to sit inside the inner ring, never across it.
  const fit = (text, size, yy) => {
    const half = (rx - 8) * Math.sqrt(Math.max(0, 1 - (Math.abs(yy) + 3) ** 2 / (ry - 6) ** 2));
    let sz = size; g.font = font(sz, 700);
    while (sz > 5.5 && g.measureText(text).width > half * 2 - 6){ sz -= 0.5; g.font = font(sz, 700); }
    g.fillText(text, 0, yy);
  };
  if (seal.top) fit(String(seal.top).toUpperCase().slice(0, 26), 7.5, -17);
  g.font = font(seal.text.length > 5 ? 20 : 25, 900);
  g.fillText(seal.text, 0, 8);
  if (seal.sub) fit(String(seal.sub).toUpperCase(), 8.5, 21);
  // A little wear, like ink that did not take everywhere.
  g.globalCompositeOperation = 'destination-out';
  g.globalAlpha = 0.18;
  for (let i = 0; i < 26; i++){
    const a = (i * 137.5) % 360 * Math.PI / 180, d = (i * 7.3) % rx;
    g.beginPath(); g.arc(Math.cos(a) * d, Math.sin(a) * d * ry / rx, 1.1 + (i % 3) * 0.5, 0, Math.PI * 2); g.fill();
  }
  g.restore();
}

/** Greedy word wrap against a measured width. */
function wrap(g, text, maxWidth){
  const words = String(text).split(/\s+/);
  const out = [];
  let line = '';
  for (const w of words){
    const next = line ? line + ' ' + w : w;
    if (g.measureText(next).width > maxWidth && line){ out.push(line); line = w; }
    else line = next;
  }
  if (line) out.push(line);
  return out;
}

/**
 * Hand the picture to the phone's share sheet — which is what puts it
 * into WhatsApp — falling back to a download where that does not exist.
 *
 * navigator.share with files is Android Chrome and iOS Safari; a desktop
 * browser usually cannot, so it saves the file instead and the person
 * attaches it themselves. Either way they end up with the image.
 */
export async function shareReceipt(blob, filename, text){
  const file = new File([blob], filename, { type: 'image/png' });

  if (navigator.canShare && navigator.canShare({ files: [file] })){
    try {
      await navigator.share({ files: [file], text });
      return 'shared';
    } catch (e){
      // AbortError means they closed the sheet — not a failure, and not
      // something to follow with a download they did not ask for.
      if (e && e.name === 'AbortError') return 'cancelled';
    }
  }

  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename;
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return 'downloaded';
}

/* =====================================================================
   The receipt as a PDF.

   An A4 page with the receipt picture on it, made here rather than by a
   PDF library (the Content Security Policy admits none, and one image on
   one page is a few hundred bytes of PDF structure). A4 because a PDF is
   what gets printed and filed; WhatsApp sends it as a document, which
   keeps its full quality, where a photo would be recompressed.
   ===================================================================== */
export async function receiptPdf(pngBlob){
  const img = await blobToImage(pngBlob);
  const c = document.createElement('canvas');
  c.width = img.naturalWidth; c.height = img.naturalHeight;
  const g = c.getContext('2d');
  g.fillStyle = '#ffffff'; g.fillRect(0, 0, c.width, c.height);   // JPEG has no transparency
  g.drawImage(img, 0, 0);
  const jpeg = new Uint8Array(await (await new Promise(res => c.toBlob(res, 'image/jpeg', 0.92))).arrayBuffer());
  return new Blob([pdfWithImage(jpeg, c.width, c.height)], { type:'application/pdf' });
}

function blobToImage(blob){
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('Could not read the receipt image')); };
    img.src = url;
  });
}

/** One A4 page, one JPEG, centred near the top with a margin. */
export function pdfWithImage(jpeg, pw, ph){
  const A4W = 595.28, A4H = 841.89, M = 56;
  // The receipt is narrow; drawn at its natural 3x size it would be tiny,
  // stretched to the full width it would be huge. 300pt wide prints at
  // about the size of a paper receipt and stays sharp.
  let w = Math.min(300, A4W - 2 * M);
  let h = w * ph / pw;
  if (h > A4H - 2 * M){ h = A4H - 2 * M; w = h * pw / ph; }
  const x = (A4W - w) / 2, y = A4H - M - h;
  const f = (n) => n.toFixed(2);

  const enc = new TextEncoder();
  const parts = []; const offsets = []; let len = 0;
  const push = (chunk) => { const b = typeof chunk === 'string' ? enc.encode(chunk) : chunk; parts.push(b); len += b.length; };
  const obj = (n, body) => { offsets[n] = len; push(`${n} 0 obj\n`); for (const b of [].concat(body)) push(b); push('\nendobj\n'); };

  push('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  obj(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  obj(3, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${f(A4W)} ${f(A4H)}] ` +
         '/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>');
  obj(4, [`<< /Type /XObject /Subtype /Image /Width ${pw} /Height ${ph} /ColorSpace /DeviceRGB ` +
          `/BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`, jpeg, '\nendstream']);
  const content = `q ${f(w)} 0 0 ${f(h)} ${f(x)} ${f(y)} cm /Im0 Do Q`;
  obj(5, `<< /Length ${content.length} >>\nstream\n${content}\nendstream`);

  const xref = len;
  let table = 'xref\n0 6\n0000000000 65535 f \n';
  for (let i = 1; i <= 5; i++) table += String(offsets[i]).padStart(10, '0') + ' 00000 n \n';
  push(table + `trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);

  const out = new Uint8Array(len); let o = 0;
  for (const b of parts){ out.set(b, o); o += b.length; }
  return out;
}

/** Share a file through the phone's share sheet, or save it on a laptop. */
export async function shareFile(blob, filename, type, text){
  const file = new File([blob], filename, { type });
  if (navigator.canShare && navigator.canShare({ files: [file] })){
    try { await navigator.share({ files: [file], text }); return 'shared'; }
    catch (e){ if (e && e.name === 'AbortError') return 'cancelled'; }
  }
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename;
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1500);
  return 'downloaded';
}
