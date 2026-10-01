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

  if (r.receiptNo) pair('Receipt no', r.receiptNo);
  if (r.date)      pair('Date',       r.date);
  if (r.flat)      pair('Flat',       r.flat);
  if (r.method)    pair('Method',     r.method);

  if (rows){
    y -= 4; rule(); y += 16;
    for (const l of r.lines) pair(l.label, l.value);
  }

  y -= 4; rule(); y += 20;

  pair('Received', r.amount || '', { big: true });

  if (r.advance){
    if (paint){
      g.textAlign = 'center'; g.font = font(11); g.fillStyle = MUTED;
      g.fillText(r.advance, W / 2, y);
    }
    y += 20;
  }

  y += 12;
  if (paint){
    g.textAlign = 'center'; g.font = font(10); g.fillStyle = MUTED;
    g.fillText(r.footer || 'Thank you.', W / 2, y);
  }
  y += 18;

  return y;
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
