javascript:(function () {
  var TB = '\t', NL = '\n';

  function cellText(c) {
    return (c.innerText || '')
      .replace(/\u00a0/g, ' ')
      .replace(/[\t\r\n]+/g, ' ')
      .trim();
  }

  function toTSV(table) {
    var lines = [], pending = {};
    for (var i = 0; i < table.rows.length; i++) {
      var row = table.rows[i], line = [], col = 0;
      for (var j = 0; j < row.cells.length; j++) {
        var cell = row.cells[j];
        while (pending[col]) {
          line.push(pending[col].text);
          if (--pending[col].left <= 0) delete pending[col];
          col++;
        }
        var cs = cell.colSpan || 1, rs = cell.rowSpan || 1, v = cellText(cell);
        for (var k = 0; k < cs; k++) {
          line.push(v);
          if (rs > 1) pending[col] = { text: v, left: rs - 1 };
          col++;
        }
      }
      while (pending[col]) {
        line.push(pending[col].text);
        if (--pending[col].left <= 0) delete pending[col];
        col++;
      }
      lines.push(line.join(TB));
    }
    return lines.join(NL);
  }

  function topTables() {
    return [].slice.call(document.querySelectorAll('table')).filter(function (t) {
      return !(t.parentElement && t.parentElement.closest('table'));
    });
  }

  function headingOf(t) {
    var p = t.previousElementSibling;
    while (p && !/^H[1-6]$/.test(p.tagName)) p = p.previousElementSibling;
    return p ? p.innerText.replace(/\s+/g, ' ').trim() : '';
  }

  function pickTable() {
    var all = topTables();
    if (!all.length) return null;
    var sel = window.getSelection(), node = sel && sel.anchorNode;
    if (node) {
      node = node.nodeType === 1 ? node : node.parentElement;
      var cur = node && node.closest && node.closest('table');
      if (cur) return cur;
    }
    if (all.length === 1) return all[0];
    var list = all.map(function (t, i) {
      return (i + 1) + ') ' + (headingOf(t) || ('таблица ' + (i + 1))) +
        ' [' + t.rows.length + 'x' + (t.rows[0] ? t.rows[0].cells.length : 0) + ']';
    }).join('\n');
    var ans = prompt('На странице несколько таблиц. Введите номер:\n' + list, '1');
    var idx = parseInt(ans, 10);
    return all[idx - 1] || all.slice().sort(function (a, b) {
      var sa = a.rows.length * (a.rows[0] ? a.rows[0].cells.length : 0);
      var sb = b.rows.length * (b.rows[0] ? b.rows[0].cells.length : 0);
      return sb - sa;
    })[0];
  }

  function copyRich(html, text) {
    var done = false;
    function onCopy(e) {
      e.clipboardData.setData('text/plain', text);
      e.clipboardData.setData('text/html', html);
      e.preventDefault();
      done = true;
    }
    document.addEventListener('copy', onCopy, true);
    try { done = document.execCommand('copy') || done; } catch (err) { }
    document.removeEventListener('copy', onCopy, true);
    return done;
  }

  function toast(msg, bad) {
    var d = document.createElement('div');
    d.className = 'cf-table-toast';
    d.textContent = msg;
    d.style.cssText = 'position:fixed;z-index:2147483647;left:50%;top:16px;' +
      'transform:translateX(-50%);padding:10px 16px;border-radius:6px;' +
      'font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:#fff;' +
      'background:' + (bad ? '#c0392b' : '#2c7a3f') + ';' +
      'box-shadow:0 2px 12px rgba(0,0,0,.35)';
    document.body.appendChild(d);
    setTimeout(function () { d.remove(); }, bad ? 7000 : 2500);
  }

  var table = pickTable();
  if (!table) { toast('На странице не найдено таблиц', true); return; }
  var html = '<table border="1">' + table.innerHTML + '</table>';
  if (copyRich(html, toTSV(table))) {
    toast('Таблица скопирована (строк: ' + table.rows.length + '). Вставьте в Excel: Ctrl+V');
  } else {
    toast('Не удалось скопировать. Разрешите доступ к буферу обмена и повторите', true);
  }
})();
