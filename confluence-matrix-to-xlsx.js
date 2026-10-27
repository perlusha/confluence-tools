javascript:(async function () {
  /* ================= утилиты ================= */
  function toast(msg, bad) {
    var d = document.createElement('div');
    d.className = 'cf-matrix-xlsx-toast';
    d.textContent = msg;
    d.style.cssText = 'position:fixed;z-index:2147483647;left:50%;top:16px;max-width:70vw;' +
      'transform:translateX(-50%);padding:12px 18px;border-radius:6px;line-height:1.45;' +
      'font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:#fff;' +
      'background:' + (bad ? '#c0392b' : '#2c7a3f') + ';box-shadow:0 2px 12px rgba(0,0,0,.35)';
    document.body.appendChild(d);
    setTimeout(function () { d.remove(); }, bad ? 12000 : 6000);
  }
  function txt(el) {
    return (el.innerText || el.textContent || '')
      .replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  }
  function esc(s) {
    return String(s).replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '')
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function colLetter(n) {
    var s = '';
    while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = (n - m - 1) / 26; }
    return s;
  }

  /* ================= ZIP (без сжатия) ================= */
  var CRCT = (function () {
    var t = new Uint32Array(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(buf) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < buf.length; i++) c = CRCT[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
  function zip(files) {
    var enc = new TextEncoder(), parts = [], central = [], offset = 0;
    files.forEach(function (f) {
      var name = enc.encode(f.name), data = f.data, crc = crc32(data);
      var lh = new Uint8Array(30 + name.length), dv = new DataView(lh.buffer);
      dv.setUint32(0, 0x04034b50, true); dv.setUint16(4, 20, true); dv.setUint16(6, 0x0800, true);
      dv.setUint16(8, 0, true); dv.setUint16(10, 0, true); dv.setUint16(12, 0x21, true);
      dv.setUint32(14, crc, true); dv.setUint32(18, data.length, true); dv.setUint32(22, data.length, true);
      dv.setUint16(26, name.length, true); dv.setUint16(28, 0, true);
      lh.set(name, 30);
      parts.push(lh, data);
      var ch = new Uint8Array(46 + name.length), cv = new DataView(ch.buffer);
      cv.setUint32(0, 0x02014b50, true); cv.setUint16(4, 20, true); cv.setUint16(6, 20, true);
      cv.setUint16(8, 0x0800, true); cv.setUint16(10, 0, true); cv.setUint16(12, 0, true);
      cv.setUint16(14, 0x21, true); cv.setUint32(16, crc, true); cv.setUint32(20, data.length, true);
      cv.setUint32(24, data.length, true); cv.setUint16(28, name.length, true);
      cv.setUint32(42, offset, true);
      ch.set(name, 46);
      central.push(ch);
      offset += lh.length + data.length;
    });
    var cdSize = central.reduce(function (a, b) { return a + b.length; }, 0);
    var eocd = new Uint8Array(22), ev = new DataView(eocd.buffer);
    ev.setUint32(0, 0x06054b50, true); ev.setUint16(8, files.length, true);
    ev.setUint16(10, files.length, true); ev.setUint32(12, cdSize, true); ev.setUint32(16, offset, true);
    return new Blob(parts.concat(central, [eocd]),
      { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
  }

  /* ================= разбор таблицы страницы ================= */
  var STATUS_WORDS = ['на корректировке', 'на согласовании', 'отменен', 'черновик', 'согласован'];
  function isStatus(t) {
    var l = t.toLowerCase();
    for (var i = 0; i < STATUS_WORDS.length; i++) if (l.indexOf(STATUS_WORDS[i]) >= 0) return true;
    return false;
  }
  function expandGrid(table) {
    var grid = [], pend = {};
    for (var i = 0; i < table.rows.length; i++) {
      var tr = table.rows[i], line = [], col = 0;
      for (var j = 0; j < tr.cells.length; j++) {
        var td = tr.cells[j];
        while (pend[col]) { line[col] = pend[col].el; if (--pend[col].left <= 0) delete pend[col]; col++; }
        var cs = td.colSpan || 1, rs = td.rowSpan || 1;
        for (var k = 0; k < cs; k++) { line[col] = td; if (rs > 1) pend[col] = { el: td, left: rs - 1 }; col++; }
      }
      while (pend[col]) { line[col] = pend[col].el; if (--pend[col].left <= 0) delete pend[col]; col++; }
      grid.push({ row: tr.rowIndex, cells: line });
    }
    return grid;
  }
  function pickTable() {
    var best = null, bestScore = -1;
    [].slice.call(document.querySelectorAll('table')).forEach(function (t) {
      var first = t.rows[0];
      var score = t.rows.length * (first ? Math.max(first.cells.length, 1) : 1);
      if (score > bestScore) { bestScore = score; best = t; }
    });
    return best;
  }

  /* ================= сборка xlsx ================= */
  var PALETTE = [
    { word: 'на корректировке', rgb: 'FFB4C6E7' },
    { word: 'на согласовании',  rgb: 'FFFFEB9C' },
    { word: 'Отменен',          rgb: 'FFFFC7CE' },
    { word: 'Черновик',         rgb: 'FFD0CECE' },
    { word: 'Согласован',       rgb: 'FF70AD47' }
  ];
  var ROW_HEIGHT = 20;

  /* абсолютная ссылка ячейки: название раздела становится кликабельной ссылкой;
     ссылки на профили людей (/display/~...) пропускаем — в Excel они не нужны */
  function cellHref(el) {
    var a = el.querySelector('a[href]');
    if (!a) return '';
    var h = a.getAttribute('href') || '';
    if (h.indexOf('/display/') >= 0) return '';
    if (/^https?:\/\//i.test(h)) return h;
    if (h.charAt(0) === '/') return location.origin + h;
    return '';
  }

  function buildXlsx(grid, headerRow) {
    var lastCol = 0;
    grid.forEach(function (g) { if (g.cells.length > lastCol) lastCol = g.cells.length; });
    var lastRow = grid.length;
    var dataStart = headerRow + 2;   /* 1-based первая строка данных */

    /* строки и ячейки */
    var emitted = new Set(), sheetRows = '', links = [];
    for (var r = 0; r < grid.length; r++) {
      var cellsXml = '';
      for (var c = 0; c < grid[r].cells.length; c++) {
        var cell = grid[r].cells[c];
        if (!cell || emitted.has(cell)) continue;
        emitted.add(cell);
        var v = txt(cell);
        if (v === '') continue;
        var ref = colLetter(c + 1) + (r + 1);
        var url = cellHref(cell);
        if (url) { links.push({ ref: ref, url: url }); }
        if (/^-?\d+(\.\d+)?$/.test(v)) {
          cellsXml += '<c r="' + ref + '"><v>' + v + '</v></c>';
        } else {
          cellsXml += '<c r="' + ref + '" t="inlineStr"><is><t xml:space="preserve">' + esc(v) + '</t></is></c>';
        }
      }
      var isData = (r + 1) >= dataStart;
      sheetRows += '<row r="' + (r + 1) + '"' +
        (isData ? ' ht="' + ROW_HEIGHT + '" customHeight="1"' : '') + '>' + cellsXml + '</row>';
    }

    /* объединения — только в шапке */
    var seen = new Set(), merges = [];
    for (var r2 = 0; r2 < grid.length; r2++) {
      for (var c2 = 0; c2 < grid[r2].cells.length; c2++) {
        var el = grid[r2].cells[c2];
        if (!el || seen.has(el)) continue;
        seen.add(el);
        var cs2 = el.colSpan || 1, rs2 = el.rowSpan || 1;
        if ((cs2 > 1 || rs2 > 1) && (r2 + 1) <= headerRow + 1) {
          merges.push(colLetter(c2 + 1) + (r2 + 1) + ':' + colLetter(c2 + cs2) + (r2 + rs2));
        }
      }
    }

    var cols = '<col min="1" max="1" width="3" customWidth="1"/>' +
      '<col min="2" max="2" width="15" customWidth="1"/>' +
      (lastCol >= 3 ? '<col min="3" max="' + lastCol + '" width="11.1" customWidth="1"/>' : '');

    var cf = '';
    if (lastRow >= dataStart) {
      var refRange = 'A' + dataStart + ':' + colLetter(lastCol) + lastRow;
      cf = '<conditionalFormatting sqref="' + refRange + '">';
      for (var i = 0; i < PALETTE.length; i++) {
        cf += '<cfRule type="expression" dxfId="' + i + '" priority="' + (i + 1) + '">' +
          '<formula>NOT(ISERROR(SEARCH("' + PALETTE[i].word + '",A' + dataStart + ')))</formula></cfRule>';
      }
      cf += '</conditionalFormatting>';
    }

    var autoFilter = (lastRow >= dataStart)
      ? '<autoFilter ref="A' + (headerRow + 1) + ':' + colLetter(lastCol) + lastRow + '"/>' : '';
    var mergeXml = merges.length ? '<mergeCells count="' + merges.length + '">' +
      merges.map(function (m) { return '<mergeCell ref="' + m + '"/>'; }).join('') + '</mergeCells>' : '';

    var hyperXml = '', sheetRels = '';
    if (links.length) {
      hyperXml = '<hyperlinks>' + links.map(function (l, i) {
        return '<hyperlink ref="' + l.ref + '" r:id="rId' + (i + 1) + '"/>';
      }).join('') + '</hyperlinks>';
      sheetRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        links.map(function (l, i) {
          return '<Relationship Id="rId' + (i + 1) + '" ' +
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" ' +
            'Target="' + esc(l.url) + '" TargetMode="External"/>';
        }).join('') + '</Relationships>';
    }

    var sheet =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
      '<dimension ref="A1:' + colLetter(lastCol) + lastRow + '"/>' +
      '<sheetViews><sheetView workbookViewId="0"/></sheetViews>' +
      '<sheetFormatPr defaultRowHeight="15"/>' +
      '<cols>' + cols + '</cols>' +
      '<sheetData>' + sheetRows + '</sheetData>' +
      autoFilter + mergeXml + cf + hyperXml +
      '</worksheet>';

    var dxfs = PALETTE.map(function (p) {
      return '<dxf><fill><patternFill><bgColor rgb="' + p.rgb + '"/></patternFill></fill></dxf>';
    }).join('');

    var styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
      '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>' +
      '<fills count="2"><fill><patternFill patternType="none"/></fill>' +
      '<fill><patternFill patternType="gray125"/></fill></fills>' +
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
      '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>' +
      '<dxfs count="' + PALETTE.length + '">' + dxfs + '</dxfs>' +
      '</styleSheet>';

    var workbook =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
      '<sheets><sheet name="Лист1" sheetId="1" r:id="rId1"/></sheets>' +
      (autoFilter ? '<definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">' +
        'Лист1!$A$' + (headerRow + 1) + ':$' + colLetter(lastCol) + '$' + lastRow + '</definedName></definedNames>' : '') +
      '</workbook>';

    var enc = new TextEncoder();
    function part(name, text) { return { name: name, data: enc.encode(text) }; }

    return zip([
      part('[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
        '<Default Extension="xml" ContentType="application/xml"/>' +
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
        '</Types>'),
      part('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
        '</Relationships>'),
      part('xl/workbook.xml', workbook),
      part('xl/_rels/workbook.xml.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
        '</Relationships>'),
      part('xl/styles.xml', styles),
      part('xl/worksheets/sheet1.xml', sheet)
    ].concat(links.length ? [part('xl/worksheets/_rels/sheet1.xml.rels', sheetRels)] : []));
  }

  /* ================= основной поток ================= */
  try {
    var table = pickTable();
    if (!table) { toast('На странице не найдена таблица', true); return; }
    var grid = expandGrid(table);
    if (grid.length < 2) { toast('Таблица слишком мала', true); return; }

    /* строка шапки: больше всего «имён» — не пусто, не «-», не статус; считаем уникальные ячейки */
    var headerRow = 0, bestCount = -1;
    for (var r = 0; r < Math.min(12, grid.length); r++) {
      var seenRow = new Set(), cnt = 0;
      for (var c = 0; c < grid[r].cells.length; c++) {
        var el = grid[r].cells[c];
        if (!el || seenRow.has(el)) continue;
        seenRow.add(el);
        var t = txt(el);
        if (t === '' || t === '-' || isStatus(t)) continue;
        cnt++;
      }
      if (cnt > bestCount) { bestCount = cnt; headerRow = r; }
    }
    if (bestCount <= 0) { toast('Не удалось определить шапку', true); return; }

    var blob = buildXlsx(grid, headerRow);
    var title = (document.querySelector('meta[name="ajs-page-title"]') || {}).content || document.title || 'Матрица';
    var name = title.replace(/[\\/:*?"<>|]/g, '_').substring(0, 80) + '.xlsx';

    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = name;
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 10000);

    toast('Готово: ' + name + ' — строк ' + grid.length + ', столбцов ' + grid[0].cells.length +
      ', шапка в строке ' + (headerRow + 1) + '.');
  } catch (e) {
    toast('Ошибка: ' + e.message, true);
  }
})();
