javascript:(async function () {
  var HANDY = '/rest/handy-macros/2.0';
  var CONTENT = '/rest/api/content/';

  function meta(n) { var m = document.querySelector('meta[name="' + n + '"]'); return m ? m.content : null; }
  var pageId = meta('ajs-page-id');
  if (!pageId) { alert('Не удалось определить ID страницы (meta ajs-page-id)'); return; }

  function toast(msg, bad) {
    var d = document.createElement('div');
    d.className = 'cf-approval-sync-toast';
    d.textContent = msg;
    d.style.cssText = 'position:fixed;z-index:2147483647;left:50%;top:16px;max-width:70vw;' +
      'transform:translateX(-50%);padding:12px 18px;border-radius:6px;line-height:1.45;' +
      'font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:#fff;' +
      'background:' + (bad ? '#c0392b' : '#2c7a3f') + ';box-shadow:0 2px 12px rgba(0,0,0,.35)';
    document.body.appendChild(d);
    setTimeout(function () { d.remove(); }, bad ? 14000 : 9000);
  }

  async function api(url, opts) {
    var o = Object.assign({ credentials: 'same-origin', headers: { 'Accept': 'application/json', 'X-Atlassian-Token': 'no-check' } }, opts || {});
    var r = await fetch(url, o);
    if (!r.ok) throw new Error('HTTP ' + r.status + ' — ' + url);
    return r.json();
  }
  async function postForm(url, body) {
    var r = await fetch(url, {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Atlassian-Token': 'no-check', 'Accept': 'application/json' },
      body: body
    });
    if (!r.ok) throw new Error('POST HTTP ' + r.status);
    return (await r.text()).trim();
  }
  async function putForm(url, body) {
    var r = await fetch(url, {
      method: 'PUT', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Atlassian-Token': 'no-check', 'Accept': 'application/json' },
      body: body
    });
    if (!r.ok) throw new Error('PUT HTTP ' + r.status);
    return (await r.text()).trim();
  }
  async function putJson(url, obj) {
    var r = await fetch(url, {
      method: 'PUT', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-Atlassian-Token': 'no-check', 'Accept': 'application/json' },
      body: JSON.stringify(obj)
    });
    if (!r.ok) throw new Error('PUT HTTP ' + r.status);
    return r.json();
  }

  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function norm(s) { return (s || '').replace(/\u00a0/g, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(); }

  /* --- разбор тела страницы с сохранением координат --- */
  function rowsOf(html) {
    var out = [], re = /<tr[^>]*>([\s\S]*?)<\/tr>/g, m;
    while ((m = re.exec(html))) {
      var innerStart = m.index + m[0].indexOf('>') + 1;
      out.push({ index: m.index, innerStart: innerStart, inner: m[1] });
    }
    return out;
  }
  function cellsOf(html, base) {
    var out = [], re = /<t[dh]([^>]*)>([\s\S]*?)<\/t[dh]>/g, m;
    while ((m = re.exec(html))) {
      var cs = (m[1].match(/colspan="(\d+)"/) || [])[1];
      var rs = (m[1].match(/rowspan="(\d+)"/) || [])[1];
      out.push({
        start: base + m.index, end: base + re.lastIndex, inner: m[2],
        colspan: cs ? parseInt(cs, 10) : 1, rowspan: rs ? parseInt(rs, 10) : 1, own: true
      });
    }
    return out;
  }
  /* раскладка строк по колонкам с учётом colspan/rowspan: grid[row][col] = ячейка */
  function gridOf(rows) {
    var pend = {}, grid = [];
    rows.forEach(function (rr) {
      var line = [], col = 0;
      cellsOf(rr.inner, rr.innerStart).forEach(function (c) {
        while (pend[col]) { line.push(pend[col].cell); if (--pend[col].left <= 0) delete pend[col]; col++; }
        for (var i = 0; i < c.colspan; i++) {
          line.push(c);
          if (c.rowspan > 1) pend[col] = { cell: c, left: c.rowspan - 1 };
          col++;
        }
      });
      while (pend[col]) { line.push(pend[col].cell); if (--pend[col].left <= 0) delete pend[col]; col++; }
      grid.push(line);
    });
    return grid;
  }
  /* колонки по подписям в первой строке шапки (с учётом colspan) */
  function captionCols(html) {
    var rows = rowsOf(html);
    if (!rows.length) return {};
    var re = /<t[dh]([^>]*)>([\s\S]*?)<\/t[dh]>/g, m, col = 0, cols = {};
    while ((m = re.exec(rows[0].inner))) {
      var cap = norm(m[2]);
      var cs = (m[1].match(/colspan="(\d+)"/) || [])[1];
      if (cap) cols[cap] = col;
      col += cs ? parseInt(cs, 10) : 1;
    }
    return cols;
  }
  function userkey(s) { var m = s.match(/ri:userkey="([^"]+)"/); return m ? m[1] : ''; }
  function pillId(s) { var m = s.match(/ac:name="id">(\d+)</); return m ? m[1] : ''; }
  function pageRef(s) {
    var m = s.match(/\/pages\/(\d+)/) || s.match(/[?&]pageId=(\d+)/);
    return m ? m[1] : '';
  }
  /* ссылка на источник бывает трёх видов: /pages/N, ?pageId=N, короткая /x/Token, ri:page */
  async function resolveSource(html) {
    var id = pageRef(html);
    if (id) return id;
    var sh = html.match(/\/x\/([A-Za-z0-9_-]+)/);
    if (sh) {
      try {
        var r = await fetch('/x/' + sh[1], { credentials: 'same-origin', redirect: 'follow' });
        var mm = (r.url || '').match(/\/pages\/(\d+)/);
        if (mm) return mm[1];
      } catch (e) { }
      return '';
    }
    var tit = html.match(/ri:content-title="([^"]+)"/);
    if (tit) {
      try {
        var ttl = tit[1].replace(/\\/g, '\\\\').replace(/"/g, '\\"');
        var q = 'title = "' + ttl + '"' + (spaceKey ? ' AND space = "' + spaceKey + '"' : '');
        var j = await api('/rest/api/content/search?limit=2&cql=' + encodeURIComponent(q));
        if (j && j.results && j.results.length) return String(j.results[0].id);
      } catch (e) { }
    }
    return '';
  }

  async function storageOf(id) {
    var j = await api(CONTENT + id + '?expand=body.storage');
    return j.body.storage.value || '';
  }
  async function getStatus(mid, pid) {
    var j = await api(HANDY + '/status-macro/' + mid + '?contentId=' + pid);
    return (j && j.status && j.status.id != null) ? { id: j.status.id, name: j.status.name } : null;
  }
  async function setStatus(mid, pid, sid) {
    return putForm(HANDY + '/status-macro/' + mid + '/value', 'contentId=' + pid + '&statusId=' + sid);
  }
  async function createStatus(pid, sid) {
    var t = await postForm(HANDY + '/status-macro', 'contentId=' + pid + '&statusId=' + sid);
    return /^\d+$/.test(t) ? t : '';
  }
  /* id статуса по имени из набора статусов конкретной пилюли */
  async function resolveStatusId(mid, cid, name) {
    try {
      var r = await fetch(HANDY + '/status-macro/' + mid + '/options/aui-dropdown?contentId=' + cid,
        { credentials: 'same-origin', headers: { 'Accept': 'application/json' } });
      if (!r.ok) return '';
      var j = await r.json();
      for (var i = 0; i < j.length; i++) {
        var items = j[i].items || [];
        for (var q = 0; q < items.length; q++) {
          var c0 = String(items[q].content || '');
          var sid = (c0.match(/data-status="(\d+)"/) || [])[1];
          var nm = c0.replace(/^[\s\S]*?data-status="\d+"[^>]*>/, '').replace(/<\/a>[\s\S]*$/, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
          if (nm === name) return sid || '';
        }
      }
    } catch (e) { }
    return '';
  }
  /* общий статус по статусам согласующих (правило согласовано с заказчиком) */
  var OVERALL_SKIP = '';   /* Ivanov I. не учитывается */
  function computeOverall(names) {
    var corr = ['Комментарии даны', 'На корректировке'];
    if (!names.length) return '';
    var allOk = true, allCorr = true, onlyOkOrCorr = true, hasCorr = false;
    for (var i = 0; i < names.length; i++) {
      var n = names[i];
      if (n !== 'Согласован') allOk = false;
      if (n !== 'На корректировке') allCorr = false;
      if (n !== 'Согласован' && corr.indexOf(n) < 0) onlyOkOrCorr = false;
      if (corr.indexOf(n) >= 0) hasCorr = true;
    }
    if (allOk) return 'Согласован';
    if (allCorr) return 'На корректировке';
    if (onlyOkOrCorr && hasCorr) return 'На корректировке';
    return 'На согласовании';
  }

  /* страница-источник: люди по строкам «Согласующий N» + пилюльные поля шапки */
  function sourceMap(html) {
    var res = { users: {}, overall: '', block: '', area: '' };
    rowsOf(html).forEach(function (rr) {
      var cs = cellsOf(rr.inner, 0);
      if (cs.length < 2) return;
      var lab = norm(cs[0].inner);
      var val = cs[1].inner;
      if (/^\d+\.\s*Согласующ/i.test(lab)) {
        var uk = userkey(rr.inner), mid = pillId(rr.inner);
        if (uk && mid && !res.users[uk]) res.users[uk] = mid;
        return;
      }
      if (/^03\.\s*Функциональный блок/i.test(lab)) { if (!res.block) res.block = pillId(val); return; }
      if (/^04\./.test(lab)) { if (!res.area) res.area = pillId(val); return; }
      if (/^08\.01/.test(lab)) { if (!res.overall) res.overall = pillId(val); return; }
    });
    return res;
  }
  function pillCell(name, mid) {
    return '<td><ac:structured-macro ac:name="status-handy" ac:schema-version="1">' +
      '<ac:parameter ac:name="Status">' + esc(name) + '</ac:parameter>' +
      '<ac:parameter ac:name="id">' + mid + '</ac:parameter></ac:structured-macro></td>';
  }

  try {
    var pg = await api(CONTENT + pageId + '?expand=body.storage,version,space');
    var html = pg.body.storage.value;
    var title = pg.title;
    var spaceKey = (pg.space && pg.space.key) || '';
    var rows = rowsOf(html);

    /* раскладка по колонкам: важно, что у колонки берётся НОМЕР, а не порядок ячейки
       (в шапке бывает ячейка согласующего без userkey — тогда всё «уезжает» на колонку) */
    var grid = gridOf(rows);

    /* шапка — строка с наибольшим числом ссылок на людей и без пилюль */
    var hdr = null;
    for (var i = 0; i < grid.length; i++) {
      var line = grid[i], keyCol = {}, cnt = 0, hasPill = false;
      for (var j = 0; j < line.length; j++) {
        var uk = userkey(line[j].inner);
        if (uk) { keyCol[j] = uk; cnt++; }
        if (line[j].inner.indexOf('status-handy') >= 0) hasPill = true;
      }
      if (!hasPill && cnt >= 2 && (!hdr || cnt > hdr.count)) {
        hdr = { rowIndex: i, keyCol: keyCol, count: cnt };
      }
    }
    if (!hdr) { toast('Не найдена шапка с согласующими', true); return; }

    var cache = {}, updated = [], created = [], cleared = [], errors = [], edits = [];
    var cols = captionCols(html);

    async function syncCell(cell, want, tag) {
      var tmid = pillId(cell.inner);
      if (tmid) {
        var have = await getStatus(tmid, pageId);
        if (have && have.id !== want.id) {
          await setStatus(tmid, pageId, want.id);
          updated.push(tag + ' «' + have.name + '» → «' + want.name + '»');
        }
      } else {
        var mid = await createStatus(pageId, want.id);
        if (mid) {
          edits.push({ start: cell.start, end: cell.end, html: pillCell(want.name, mid) });
          created.push(tag + ' → «' + want.name + '»');
        }
      }
    }

    /* в источнике для этого человека статуса нет — ячейку матрицы очищаем */
    async function clearCell(cell, tag) {
      var tmid = pillId(cell.inner);
      if (!tmid) return;
      var have = await getStatus(tmid, pageId);
      edits.push({ start: cell.start, end: cell.end, html: '<td><br /></td>' });
      cleared.push(tag + ' «' + (have ? have.name : '?') + '» → пусто');
    }

    for (var r = hdr.rowIndex + 1; r < grid.length; r++) {
      var line2 = grid[r];
      var num = norm(line2[0] ? line2[0].inner : '');
      if (!/^\d+$/.test(num)) continue;
      var srcId = await resolveSource(line2[1].inner);
      if (!srcId) srcId = await resolveSource(line2[0].inner);
      if (!srcId) continue;

      if (cache[srcId] === undefined) cache[srcId] = sourceMap(await storageOf(srcId));
      var map = cache[srcId];

      var rowStatuses = [], refMid = '';
      for (var k in hdr.keyCol) {
        var ck = parseInt(k, 10);
        if (ck >= line2.length) continue;
        var cell = line2[ck];
        if (!cell.own) continue;
        if (hdr.keyCol[k] === OVERALL_SKIP) continue;
        var smid = map.users[hdr.keyCol[k]];
        if (!smid) { await clearCell(cell, 'стр.' + num); continue; }
        var want = await getStatus(smid, srcId);
        if (want) { if (!refMid) refMid = smid; rowStatuses.push(want.name); await syncCell(cell, want, 'стр.' + num); }
      }

      /* пилюльные колонки из шапки: блок и область берём из источника */
      var pillCols = [
        ['Функциональный блок', 'block', 'блок'],
        ['Функциональная область', 'area', 'область']
      ];
      for (var q = 0; q < pillCols.length; q++) {
        var ci = cols[pillCols[q][0]], smid2 = map[pillCols[q][1]];
        if (ci === undefined || ci >= line2.length) continue;
        var cell2 = line2[ci];
        if (!cell2.own) continue;
        if (!smid2) { await clearCell(cell2, 'стр.' + num + ' ' + pillCols[q][2]); continue; }
        var want2 = await getStatus(smid2, srcId);
        if (want2) await syncCell(cell2, want2, 'стр.' + num + ' ' + pillCols[q][2]);
      }

      /* «Общий статус согласования» больше не хранится на источниках — считаем здесь */
      var cOverall = cols['Общий статус согласования'];
      if (cOverall !== undefined && cOverall < line2.length) {
        var oc = line2[cOverall];
        if (oc && oc.own) {
          var wantOverall = computeOverall(rowStatuses);
          if (wantOverall) {
            var omid = pillId(oc.inner);
            var oHave = omid ? await getStatus(omid, pageId) : null;
            if (!oHave || oHave.name !== wantOverall) {
              var oTarget = await resolveStatusId(omid || refMid, pageId, wantOverall);
              if (oTarget) {
                if (omid) {
                  await setStatus(omid, pageId, oTarget);
                  updated.push('стр.' + num + ' общий «' + (oHave ? oHave.name : '?') + '» → «' + wantOverall + '»');
                } else {
                  var nm = await createStatus(pageId, oTarget);
                  if (nm) {
                    edits.push({ start: oc.start, end: oc.end, html: pillCell(wantOverall, nm) });
                    created.push('стр.' + num + ' общий → «' + wantOverall + '»');
                  }
                }
              }
            }
          }
        }
      }
    }

    /* правка тела страницы: вставка созданных пилюль и очистка лишних */
    if (edits.length) {
      edits.sort(function (a, b) { return b.start - a.start; });
      edits.forEach(function (p) { html = html.slice(0, p.start) + p.html + html.slice(p.end); });
      var fresh = await api(CONTENT + pageId + '?expand=version');
      await putJson(CONTENT + pageId, {
        id: pageId, type: 'page', title: fresh.title,
        version: { number: fresh.version.number + 1, message: 'approval sync: add/clear statuses' },
        body: { storage: { representation: 'storage', value: html } }
      });
    }

    var msg = [];
    if (updated.length) msg.push('обновлено: ' + updated.length);
    if (created.length) msg.push('создано пилюль: ' + created.length);
    if (cleared.length) msg.push('очищено: ' + cleared.length);
    var head = updated.concat(created, cleared).slice(0, 4).join('; ');
    if (!msg.length) { toast('Изменений нет — всё синхронно.'); return; }
    if (errors.length) msg.push('ошибок: ' + errors.length);
    toast(msg.join(', ') + '. ' + head + (updated.length + created.length + cleared.length > 4 ? '; …' : '') + ' Обновите страницу (F5).');
  } catch (e) {
    toast('Ошибка: ' + e.message, true);
  }
})();
