# Кнопка «Пересобрать Матрицу ФТТ» (букмарклет)

Закладка для страницы **«Матрица ФТТ»** (дерево ФТТ → Схема). Пересобирает её содержимое
из источника **в твоей сессии Confluence** (токен не нужен).

Не путать с `confluence-approval-sync.js` — та синхронизирует **статусы** в матрице согласования,
эта — **пересобирает дерево**. Правила разные, закладки независимы.

---

## Что делает

Источник строк — **123456789 «Матрица согласования ФТТ»**. Для каждой строки источника:

1. Строка ФТТ копируется как есть: номер, ссылка, «Функциональный блок», «Функциональная область»,
   «Лид», «Аналитик», «Общий статус согласования», все колонки согласующих.
2. Ищется поле **«Схема ФТТ»** на странице ФТТ (подпись должна быть ровно `Схема ФТТ`).
   Ссылки из него (короткие `/x/…` и обычные `/pages/N`) раскрываются в id страниц.
3. Под строкой ФТТ добавляется по строке на каждую схему.
4. **Переносятся статусы.** Статус пилюли в Handy Macros хранится по паре
   **(macroid + страница)**: при первой вставке на новой странице значение копируется из источника,
   но дальше не обновляется само. Поэтому после записи страницы закладка для каждой пилюли
   читает статус в источнике (для строки схемы — страница из «Схема ФТТ», для строки ФТТ — матрица)
   и пишет его в дерево тем же `PUT /status-macro/{macroid}/value` с `contentId` дерева.
   Пишутся только расходящиеся значения. Переносятся все пилюли строки: блок, область,
   общий статус 08.01 и согласующие.

   Статусы читаются из отрендеренного вида страницы (`data-status` у `span.handy-status-view`) —
   поэтому на страницу нужен один запрос, а не по запросу на каждую пилюлю.

## Как выглядит результат

```
№ | Наименование раздела | Схема ФТТ | Функциональный блок | … | Согласующие
3 | ABC-ОПР-01.01.01 …   |           | пилюля              |   | …
3.1 | ABC-ОПР-01.01.01 … | схема …   | пилюля схемы        |   | …
```

- **Строка ФТТ**: «Схема ФТТ» пустая.
- **Строка схемы**: «Наименование раздела» = ссылка на вышестоящее ФТТ, «Схема ФТТ» = ссылка на схему.
- «Функциональный блок», «Функциональная область», «Общий статус», согласующие у схемы берутся
  **со страницы самой схемы**; «Лид» и «Аналитик» у схем — прочерк.
- Пилюли **переиспользуются по macroid**: статус в Handy Macros привязан к macroid, поэтому
  дерево показывает те же живые статусы, что и источники (пересоздавать ничего не нужно).

## Установка

1. `Ctrl+Shift+B` — панель закладок, `Ctrl+Shift+O` — диспетчер закладок → новая:
   - **Название:** `Пересобрать Матрицу ФТТ`
   - **URL:** строка ниже целиком.
2. Открыть страницу **123456790** и нажать закладку. Появится подтверждение с количеством
   строк и схем — после «ОК» страница перезаписывается (версия +1).
3. `F5` — обновить страницу.

```javascript
javascript:(async function () { var HANDY = '/rest/handy-macros/2.0'; var CONTENT = '/rest/api/content/'; var SOURCE = '123456789';          /* Матрица согласования ФТТ — источник строк */ function meta(n) { var m = document.querySelector('meta[name="' + n + '"]'); return m ? m.content : null; } var pageId = meta('ajs-page-id'); if (!pageId) { alert('Не удалось определить ID страницы (meta ajs-page-id)'); return; } function toast(msg, bad) { var d = document.createElement('div'); d.className = 'cf-ftt-tree-toast'; d.textContent = msg; d.style.cssText = 'position:fixed;z-index:2147483647;left:50%;top:16px;max-width:70vw;' + 'transform:translateX(-50%);padding:12px 18px;border-radius:6px;line-height:1.45;' + 'font:14px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;color:#fff;' + 'background:' + (bad ? '#c0392b' : '#2c7a3f') + ';box-shadow:0 2px 12px rgba(0,0,0,.35)'; document.body.appendChild(d); setTimeout(function () { d.remove(); }, bad ? 18000 : 12000); } async function api(url, opts) { var o = Object.assign({ credentials: 'same-origin', headers: { 'Accept': 'application/json', 'X-Atlassian-Token': 'no-check' } }, opts || {}); var r = await fetch(url, o); if (!r.ok) throw new Error('HTTP ' + r.status + ' — ' + url); return r.json(); } async function putJson(url, obj) { var r = await fetch(url, { method: 'PUT', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Atlassian-Token': 'no-check', 'Accept': 'application/json' }, body: JSON.stringify(obj) }); if (!r.ok) throw new Error('PUT HTTP ' + r.status); return r.json(); } function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); } function norm(s) { return (s || '').replace(/\u00a0/g, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(); } function rowsOf(html) { var out = [], re = /<tr[^>]*>([\s\S]*?)<\/tr>/g, m; while ((m = re.exec(html))) out.push({ inner: m[1], full: m[0] }); return out; } function cellsOf(rowInner) { var out = [], re = /<t[dh]([^>]*)>([\s\S]*?)<\/t[dh]>/g, m; while ((m = re.exec(rowInner))) out.push({ attrs: m[1], inner: m[2] }); return out; } function userkey(s) { var m = s.match(/ri:userkey="([^"]+)"/); return m ? m[1] : ''; } function pillId(s) { var m = s.match(/ac:name="id">(\d+)</); return m ? m[1] : ''; } function pageRef(s) { var m = s.match(/\/pages\/(\d+)/) || s.match(/[?&]pageId=(\d+)/); return m ? m[1] : ''; } function pillCell(mid) { return '<td><ac:structured-macro ac:name="status-handy" ac:schema-version="1"><ac:parameter ac:name="id">' + mid + '</ac:parameter></ac:structured-macro></td>'; } /* общий статус по id статусов согласующих (space DEMO: 648 Согласован, 649 На корректировке, 1787 Комментарии даны) */ function computeOverallById(ids) { var OK = '648', CORR = ['1787', '649']; if (!ids.length) return ''; var allOk = true, allCorr = true, onlyOkOrCorr = true, hasCorr = false; for (var i = 0; i < ids.length; i++) { var x = ids[i]; if (x !== OK) allOk = false; if (x !== '649') allCorr = false; if (x !== OK && CORR.indexOf(x) < 0) onlyOkOrCorr = false; if (CORR.indexOf(x) >= 0) hasCorr = true; } if (allOk) return '648'; if (allCorr) return '649'; if (onlyOkOrCorr && hasCorr) return '649'; return '646'; } async function overallForSchema(sid, map) { try { var sv = await api(CONTENT + sid + '?expand=body.view'); var smap = statusMap(sv.body.view.value); var ids = []; for (var uk in map.users) { var m = smap[map.users[uk]]; if (m) ids.push(m); } return computeOverallById(ids); } catch (e) { return ''; } } async function createStatus(pid, sid) { try { var r = await fetch(HANDY + '/status-macro', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Atlassian-Token': 'no-check' }, body: 'contentId=' + pid + '&statusId=' + sid }); if (!r.ok) return ''; var t = (await r.text()).trim(); return /^\d+$/.test(t) ? t : ''; } catch (e) { return ''; } } function midsIn(html) { var out = [], re = /ac:name="id">(\d+)</g, m; while ((m = re.exec(html))) out.push(m[1]); return out; } function statusMap(viewHtml) { var m = {}, re = /<span id="(\d+)"[^>]*?data-status="(\d+)"/g, x; while ((x = re.exec(viewHtml))) m[x[1]] = x[2]; return m; } /* перенос статусов: в дереве статус хранится по паре (macroid + страница) */ async function syncStatuses(plans) { if (!plans.length) return 0; var treeView = await api(CONTENT + pageId + '?expand=body.view'); var treeMap = statusMap(treeView.body.view.value); var srcMaps = {}, changed = 0; for (var i = 0; i < plans.length; i++) { var p = plans[i], sm = srcMaps[p.cid]; if (!sm) { try { var sv = await api(CONTENT + p.cid + '?expand=body.view'); sm = statusMap(sv.body.view.value); } catch (e) { sm = {}; } srcMaps[p.cid] = sm; } for (var j = 0; j < p.mids.length; j++) { var mid = p.mids[j], want = sm[mid]; if (!want) continue;                       /* в источнике этой пилюли нет — не трогаем */ if (treeMap[mid] === want) continue; try { await putForm(HANDY + '/status-macro/' + mid + '/value', 'contentId=' + pageId + '&statusId=' + want); treeMap[mid] = want; changed++; } catch (e) { } } } return changed; } /* вставить html после n-й закрывающей ячейки строки */ function insertAfterCell(rowHtml, nth, html, closeTag) { var re = new RegExp(closeTag || '</td>', 'g'), m, c = 0; while ((m = re.exec(rowHtml))) { c++; if (c === nth) { var i = m.index + m[0].length; return rowHtml.slice(0, i) + html + rowHtml.slice(i); } } return rowHtml; } /* короткая ссылка -> id страницы (в браузере редирект отрабатывает в сессии) */ async function resolveShort(tok) { try { var r = await fetch('/x/' + tok, { credentials: 'same-origin', redirect: 'follow' }); var m = (r.url || '').match(/\/pages\/(\d+)/); if (m) return m[1]; } catch (e) { } return ''; } /* поля страницы: пилюли 03/04/08 + согласующие (userkey -> macroid) */ function sourceMap(html) { var res = { users: {}, block: '', area: '', overall: '' }; rowsOf(html).forEach(function (rr) { var cs = cellsOf(rr.inner); if (cs.length < 2) return; var lab = norm(cs[0].inner), val = cs[1].inner; if (/^\d+\.\s*Согласующ/i.test(lab)) { var uk = userkey(rr.inner), mid = pillId(rr.inner); if (uk && mid && !res.users[uk]) res.users[uk] = mid; return; } if (/^03\./.test(lab)) { if (!res.block) res.block = pillId(val); return; } if (/^04\./.test(lab)) { if (!res.area) res.area = pillId(val); return; } if (/^08/.test(lab)) { if (!res.overall) res.overall = pillId(val); return; } }); return res; } try { var pg = await api(CONTENT + pageId + '?expand=body.storage,version,space'); var src = await api(CONTENT + SOURCE + '?expand=body.storage'); var spaceKey = (pg.space && pg.space.key) || ''; var srcRows = rowsOf(src.body.storage.value); /* шапка источника: строка с максимумом userkey = ключи согласующих */ var hdrIdx = -1, colKeys = [], best = 0; for (var i = 0; i < srcRows.length; i++) { var cs0 = cellsOf(srcRows[i].inner), ks = []; for (var c = 0; c < cs0.length; c++) { var u = userkey(cs0[c].inner); if (u) ks.push(u); } if (ks.length > best) { best = ks.length; hdrIdx = i; colKeys = ks; } } if (hdrIdx < 0) { toast('В источнике не найдена шапка с согласующими', true); return; } var btn = document.createElement('div'); btn.textContent = 'Собираю… 0'; btn.style.cssText = 'position:fixed;z-index:2147483647;left:50%;bottom:20px;transform:translateX(-50%);' + 'padding:10px 16px;border-radius:6px;background:#333;color:#fff;font:13px system-ui;opacity:.92'; document.body.appendChild(btn); var parts = ['<table class="wrapped"><tbody>']; parts.push(insertAfterCell(srcRows[0].full, 1, '<th rowspan="3"><p>Схема ФТТ</p></th>', '</th>')); for (var h = 1; h <= hdrIdx; h++) parts.push(srcRows[h].full); var nRows = 0, nSchemes = 0, failed = 0; var plans = []; for (var r = hdrIdx + 1; r < srcRows.length; r++) { var tr = srcRows[r].full; var cs = cellsOf(srcRows[r].inner); if (cs.length < 15) continue; var num = norm(cs[0].inner); if (!/^\d+$/.test(num)) continue; var srcId = pageRef(cs[1].inner); if (!srcId) continue; if (srcId === SOURCE) continue; nRows++; btn.textContent = 'Собираю… ' + nRows + ' (схем ' + nSchemes + ')'; var fttNameCell = cs[1].inner;      /* ячейка с названием ФТТ (используется в строках схем) */ var schemeTokens = [], schemaRows = []; var fttPage = null; try { fttPage = await api(CONTENT + srcId + '?expand=body.storage'); } catch (e) { failed++; } if (fttPage) { var schemeCells = []; rowsOf(fttPage.body.storage.value).forEach(function (rr) { var cc = cellsOf(rr.inner); if (cc.length < 2) return; if (/^Схема\s+ФТТ$/.test(norm(cc[0].inner))) schemeCells.push(cc[1].inner); }); var all = schemeCells.join(' '); var tokRe = /\/x\/([A-Za-z0-9_-]{4,})/g, tm; while ((tm = tokRe.exec(all))) { if (schemeTokens.indexOf(tm[1]) < 0) schemeTokens.push(tm[1]); } var plRe = /(?:pageId=|\/pages\/)(\d+)/g, pm; while ((pm = plRe.exec(all))) { if (schemeTokens.indexOf('id:' + pm[1]) < 0) schemeTokens.push('id:' + pm[1]); } } var k = 0; for (var t = 0; t < schemeTokens.length; t++) { var tok = schemeTokens[t], sid = ''; if (tok.indexOf('id:') === 0) sid = tok.slice(3); else { sid = await resolveShort(tok); if (!sid) { failed++; continue; } } var sp = null; try { sp = await api(CONTENT + sid + '?expand=body.storage'); } catch (e) { failed++; continue; } if (!sp) { failed++; continue; } k++; nSchemes++; var map = sourceMap(sp.body.storage.value); var row = ['<tr>']; row.push('<td>' + esc(num) + '.' + k + '</td>'); row.push('<td>' + fttNameCell + '</td>'); row.push('<td><a href="/spaces/' + spaceKey + '/pages/' + sid + '">' + esc(sp.title) + '</a></td>'); row.push(map.block ? pillCell(map.block) : '<td>-</td>'); row.push(map.area ? pillCell(map.area) : '<td>-</td>'); row.push('<td>-</td>'); row.push('<td>-</td>'); var overallCell = ''; if (map.overall) { overallCell = pillCell(map.overall); } else { var ost = await overallForSchema(sid, map); var omid = ost ? await createStatus(pageId, ost) : ''; overallCell = omid ? pillCell(omid) : '<td>-</td>'; } row.push(overallCell); for (var q = 0; q < colKeys.length; q++) { var mUk = map.users[colKeys[q]]; row.push(mUk ? pillCell(mUk) : '<td>-</td>'); } row.push('</tr>'); schemaRows.push(row.join('')); var sMids = midsIn(row.join('')); plans.push({ cid: sid, mids: sMids.filter(function (_, i) { return i !== 2; }) }); } var fttRowHtml = insertAfterCell(tr, 2, '<td><br /></td>'); parts.push(fttRowHtml); var fttMids = midsIn(fttRowHtml); plans.push({ cid: SOURCE, mids: fttMids.length > 2 ? [fttMids[2]] : [] }); plans.push({ cid: srcId, mids: fttMids.filter(function (_, i) { return i !== 2; }) }); for (var s = 0; s < schemaRows.length; s++) parts.push(schemaRows[s]); } parts.push('</tbody></table>'); var html = parts.join(''); btn.remove(); if (!confirm('Пересобрать «Матрицу ФТТ»?\n\nСтрок ФТТ: ' + nRows + '\nСхем: ' + nSchemes + (failed ? '\nНе прочитано/не раскрыто: ' + failed : '') + '\n\nТекущее содержимое страницы будет заменено (версия +1).')) return; var btn2 = document.createElement('div'); btn2.textContent = 'Записываю страницу…'; btn2.style.cssText = 'position:fixed;z-index:2147483647;left:50%;bottom:20px;transform:translateX(-50%);padding:10px 16px;border-radius:6px;background:#333;color:#fff;font:13px system-ui;opacity:.92'; document.body.appendChild(btn2); var fresh = await api(CONTENT + pageId + '?expand=version'); await putJson(CONTENT + pageId, { id: pageId, type: 'page', title: fresh.title, version: { number: fresh.version.number + 1, message: 'rebuild FTT tree (bookmarklet)', minorEdit: true }, body: { storage: { representation: 'storage', value: html } } }); btn2.textContent = 'Переношу статусы…'; var changed = await syncStatuses(plans); btn2.remove(); toast('Готово: строк ФТТ ' + nRows + ', схем ' + nSchemes + (changed ? ', обновлено статусов: ' + changed : '') + '. Обновите страницу (F5).'); } catch (e) { toast('Ошибка: ' + e.message, true); } })();
```

---

## Ограничения

- **«Призраки» старых пилюль.** Если в источнике пилюлю пересоздали (новый macroid), в дереве
  остаётся ссылка на старую — её нет ни в одном отрендеренном виде, и статус перенести некуда.
  Лечится **пересборкой**: закладка вставит актуальные пилюли источника. Если после пересборки
  строка всё ещё показывает старое — пересборка не выполнялась (закрыли подтверждение / ошибка).
- **Полная замена содержимого страницы.** Ручные правки на 123456790 будут стёрты — страница
  всегда собирается заново из источника и полей «Схема ФТТ».
- **Источник не меняется.** Закладка только читает 123456789 и ФТТ-страницы.
- **Подпись поля ищется точно** `Схема ФТТ`. Другие написания (`Схема к ФТТ`, `Схема ФТТ: …`,
  `12. Ссылка на схему…`) игнорируются — считаются не приведёнными к шаблону.
- **Короткие ссылки** `/x/…` раскрываются браузером (сессия); с PAT этот путь не работает —
  для серверной версии используйте `Build-FttTree.ps1` (там резолв по названию).
- **Отдельный инкрементальный догон** статусов без пересборки — `Sync-FttTreeStatuses.ps1`
  (быстрее: не собирает страницу заново, правит только расходящиеся пилюли).

## Как отредактировать

Исходник: `confluence-ftt-tree-sync.js` (UTF-8 с BOM).

```powershell
$p = ".\confluence-ftt-tree-sync.js"
$src = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($true)))
$one = (($src -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ')
$one | Set-Clipboard
"В буфере одна строка, $($one.Length) символов — вставьте в URL закладки"
```
---

## Общий статус согласования — считается, а не копируется

Поле «08.01. Общий статус согласования» со страниц ФТТ/схем убирается: статус хранится
и рассчитывается только в матрицах.

- Пилюльные колонки из источника: только «Функциональный блок» и «Функциональная область».
- **Матрица согласования**: общий статус **вычисляется** по согласующим строки и проставляется
  в пилюлю матрицы: все «Согласован» → «Согласован»; все «На корректировке» → «На корректировке»;
  у кого-то «Комментарии даны»/«На корректировке» при остальных «Согласован» → «На корректировке»;
  иначе «На согласовании». Статус Ivanov I. (`<userkey>`) не учитывается.
- **Дерево ФТТ**: у строки ФТТ общий статус берётся из матрицы; у строки схемы — **считается**
  по согласующим схемы и хранится в дереве (для схемы заводится собственная пилюля в дереве).