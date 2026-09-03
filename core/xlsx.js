/* =====================================================================
   xlsx.js — writes a real Excel workbook, with no library.

   Why not a library: this application deliberately loads nothing from a
   CDN, and the smallest capable spreadsheet library is larger than the
   entire rest of the portal. An .xlsx file is a ZIP of small XML parts,
   and a ZIP with no compression is a well-defined byte layout, so the
   whole writer fits in this file.

   Why not just CSV: a CSV cannot carry more than one sheet, loses the
   distinction between 5000 and "5000", and shows the reader a wall of
   undifferentiated text. A committee reading a yearly statement should
   get a bold header row, real numbers they can sum, and one tab per
   section.

   Limits, stated plainly: no formulas, no charts, no merged cells, and
   no compression (the files are a few hundred KB at worst, which is not
   worth a DEFLATE implementation). Numbers, dates and text, formatted.
   ===================================================================== */

/* ---------------------------------------------------------------------
   ZIP, stored (method 0).
   --------------------------------------------------------------------- */
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++){
    let c = i;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[i] = c >>> 0;
  }
  return t;
})();

function crc32(bytes){
  let c = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

const enc = new TextEncoder();

function zip(files){
  // files: [{ name, data: Uint8Array }]
  const chunks = [], central = [];
  let offset = 0;

  const u16 = (n) => [n & 0xFF, (n >>> 8) & 0xFF];
  const u32 = (n) => [n & 0xFF, (n >>> 8) & 0xFF, (n >>> 16) & 0xFF, (n >>> 24) & 0xFF];

  for (const f of files){
    const nameBytes = enc.encode(f.name);
    const crc = crc32(f.data);
    const size = f.data.length;

    const local = new Uint8Array([
      0x50,0x4B,0x03,0x04,            // local file header signature
      20,0,                            // version needed
      0,0,                             // flags
      0,0,                             // method 0 = stored
      0,0, 0,0,                        // mod time / date (zeroed: reproducible)
      ...u32(crc), ...u32(size), ...u32(size),
      ...u16(nameBytes.length), ...u16(0)
    ]);
    chunks.push(local, nameBytes, f.data);

    central.push(new Uint8Array([
      0x50,0x4B,0x01,0x02,
      20,0, 20,0, 0,0, 0,0,
      0,0, 0,0,
      ...u32(crc), ...u32(size), ...u32(size),
      ...u16(nameBytes.length), ...u16(0), ...u16(0),
      ...u16(0), ...u16(0), ...u32(0),
      ...u32(offset)
    ]), nameBytes);

    offset += local.length + nameBytes.length + size;
  }

  const centralStart = offset;
  let centralSize = 0;
  for (const c of central) centralSize += c.length;

  const end = new Uint8Array([
    0x50,0x4B,0x05,0x06,
    ...u16(0), ...u16(0),
    ...u16(files.length), ...u16(files.length),
    ...u32(centralSize), ...u32(centralStart),
    ...u16(0)
  ]);

  let total = 0;
  for (const c of chunks) total += c.length;
  total += centralSize + end.length;

  const out = new Uint8Array(total);
  let pos = 0;
  for (const c of chunks){ out.set(c, pos); pos += c.length; }
  for (const c of central){ out.set(c, pos); pos += c.length; }
  out.set(end, pos);
  return out;
}

/* ---------------------------------------------------------------------
   XML helpers.
   --------------------------------------------------------------------- */
const xmlEsc = (v) => String(v ?? '')
  .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
  .replace(/"/g,'&quot;').replace(/'/g,'&apos;')
  // Excel refuses a file containing control characters.
  .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g,'');

const colName = (n) => {           // 0 -> A, 25 -> Z, 26 -> AA
  let s = '';
  n += 1;
  while (n > 0){ const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = (n - r - 1) / 26; }
  return s;
};

/* Style indexes, matching the cellXfs order written in STYLES below. */
const S = { PLAIN: 0, HEADER: 1, MONEY: 2, DATE: 3, TITLE: 4, BOLD: 5, MONEY_BOLD: 6 };

const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="2">
<numFmt numFmtId="164" formatCode="#,##0.00"/>
<numFmt numFmtId="165" formatCode="dd\\ mmm\\ yyyy"/>
</numFmts>
<fonts count="4">
<font><sz val="11"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
<font><b/><sz val="14"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><name val="Calibri"/></font>
</fonts>
<fills count="3">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF12332A"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="7">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="164" fontId="3" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

/** One cell. Numbers stay numbers so Excel can add them up. */
function cell(ref, value, style){
  if (value === null || value === undefined || value === '')
    return `<c r="${ref}" s="${style}"/>`;
  if (typeof value === 'number' && Number.isFinite(value))
    return `<c r="${ref}" s="${style}"><v>${value}</v></c>`;
  return `<c r="${ref}" s="${style}" t="inlineStr"><is><t xml:space="preserve">${xmlEsc(value)}</t></is></c>`;
}

/**
 * Build one worksheet.
 * sheet = { name, title?, subtitle?, columns:[{label, key?, get?, money?, width?}], rows:[] }
 */
function sheetXml(sheet){
  const cols = sheet.columns;
  const lines = [];
  let r = 0;

  const row = (cells) => { r += 1; lines.push(`<row r="${r}">${cells.join('')}</row>`); };

  if (sheet.title)    row([cell('A' + (r + 1), sheet.title, S.TITLE)]);
  if (sheet.subtitle) row([cell('A' + (r + 1), sheet.subtitle, S.PLAIN)]);
  if (sheet.title || sheet.subtitle) row([]);              // a blank spacer row

  const headerRow = r + 1;
  row(cols.map((c, i) => cell(colName(i) + headerRow, c.label, S.HEADER)));

  for (const item of sheet.rows){
    const rowNo = r + 1;
    row(cols.map((c, i) => {
      let v = c.get ? c.get(item) : item[c.key];
      if (c.money){
        const n = Number(v);
        return cell(colName(i) + rowNo, Number.isFinite(n) ? n : null, S.MONEY);
      }
      if (v instanceof Date) v = v.toISOString().slice(0,10);
      return cell(colName(i) + rowNo, v ?? '', S.PLAIN);
    }));
  }

  if (sheet.total){
    const rowNo = r + 1;
    row(cols.map((c, i) => {
      const v = sheet.total[c.key ?? c.label];
      if (v === undefined) return cell(colName(i) + rowNo, i === 0 ? 'Total' : '', S.BOLD);
      return cell(colName(i) + rowNo, Number(v), S.MONEY_BOLD);
    }));
  }

  const widths = cols.map((c, i) =>
    `<col min="${i+1}" max="${i+1}" width="${c.width || Math.max(12, Math.min(42, c.label.length + 6))}" customWidth="1"/>`
  ).join('');

  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<cols>${widths}</cols>
<sheetData>${lines.join('')}</sheetData>
</worksheet>`;
}

/** Excel forbids these in a sheet name, and caps it at 31 characters. */
const safeSheetName = (n, i) =>
  (String(n || ('Sheet' + (i + 1))).replace(/[\\\/\?\*\[\]:]/g, ' ').slice(0, 31)) || ('Sheet' + (i + 1));

/**
 * Build and download an .xlsx.
 * @param {string} filename
 * @param {Array}  sheets   one or more sheet definitions (see sheetXml)
 */
export function downloadXLSX(filename, sheets){
  const list = (Array.isArray(sheets) ? sheets : [sheets]).filter(Boolean);
  if (!list.length) return;

  const names = list.map((s, i) => safeSheetName(s.name, i));

  const files = [
    { name: '[Content_Types].xml', data: enc.encode(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
${list.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}
</Types>`) },

    { name: '_rels/.rels', data: enc.encode(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>`) },

    { name: 'xl/workbook.xml', data: enc.encode(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>${names.map((n, i) => `<sheet name="${xmlEsc(n)}" sheetId="${i+1}" r:id="rId${i+1}"/>`).join('')}</sheets>
</workbook>`) },

    { name: 'xl/_rels/workbook.xml.rels', data: enc.encode(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${list.map((_, i) => `<Relationship Id="rId${i+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i+1}.xml"/>`).join('')}
<Relationship Id="rId${list.length+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>`) },

    { name: 'xl/styles.xml', data: enc.encode(STYLES) },

    ...list.map((s, i) => ({ name: `xl/worksheets/sheet${i+1}.xml`, data: enc.encode(sheetXml(s)) }))
  ];

  const blob = new Blob([zip(files)], {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename.endsWith('.xlsx') ? filename : filename + '.xlsx';
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
