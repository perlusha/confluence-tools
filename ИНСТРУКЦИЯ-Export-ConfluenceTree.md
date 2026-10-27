# Инструкция агенту: скрипт выгрузки дерева Confluence (ФТТ + вложения)

> Задача: у пользователя есть Confluence (Server/DC) и настроенный `confluence-mcp`.
> Нужен **простой** скрипт: по заданной странице рекурсивно выгрузить её и все дочерние
> страницы вместе с вложениями. Пользователь не должен возиться с `Win+R` и параметрами
> командной строки.

---

## 1. Что должно получиться

Два файла в одной папке (например, `Документы\confluence-export\`):

| файл | зачем |
|---|---|
| `Export-ConfluenceTree.ps1` | сам скрипт; все настройки — в блоке `НАСТРОЙКИ` в начале |
| `Export-ConfluenceTree.bat` | запуск двойным щелчком (без `Win+R`, без параметров) |

**Сценарий пользователя:**

1. Открывает `Export-ConfluenceTree.ps1` в Блокноте, меняет **одну строку** — `$RootPage` (ID страницы или полную ссылку), сохраняет.
2. Дважды щёлкает `Export-ConfluenceTree.bat`.
3. Видит в консоли прогресс: `[1] Название страницы`, `+ файл (25 КБ)`, `- пропущен (большой)`.
4. В конце — итог и вопрос: `Enter — закрыть, O — открыть папку`.

Результат: папки по иерархии, `page.html` в каждой, подпапка `attachments`, `index.csv` и `export-log.txt` в корне.

```
FTT-export\
  ABC-ОПР-01.03.01 ФТТ _Подготовка и загрузка..._ (123456794)\
      page.html
      attachments\  (скачанные файлы)
      ABC-ОПР-01.03.01 Схема ... (123456800)\
          page.html
  index.csv
  export-log.txt
```

---

## 2. Проверенные факты по API (не перепроверять наугад)

Всё ниже проверено на живом Confluence Server/DC (Server/DC, PAT):

| что | как | статус |
|---|---|---|
| авторизация | `Authorization: Bearer <PAT>` для REST | ✅ |
| страница | `GET /rest/api/content/{id}?expand=body.view,body.storage,version` | ✅ |
| дочерние | `GET /rest/api/content/{id}/child/page?limit=200` | ✅ |
| вложения | `GET /rest/api/content/{id}/child/attachment?limit=200` | ✅ |
| **скачивание** | `GET <base> + <attachment._links.download>` (вид `/download/attachments/{pageId}/{file}?version=N&api=v2`), **с Bearer** | ✅ |
| скачивание через REST | `/rest/api/content/{pageId}/child/attachment/{attId}/download` | ❌ **404** |
| `_links.download` — это не REST-URL | но Bearer на `/download/` **работает** (проверено) | ✅ |
| прочие не-REST URL (`/x/…`, `/pages/viewpage.action`) | Bearer **игнорируют** → редирект на логин | ❌ |

Дополнительно:

- JSON приходит в UTF-8, русский текст корректный.
- `attachment.extensions.fileSize` — размер в байтах; бывают файлы по 100+ МБ (видео) и «мусорные» с именем `~имя.tmp`.
- `attachment._links.download` уже содержит `version=` и `api=v2` — трансформировать не нужно.
- Токен у пользователя уже есть: `confluence-mcp` хранит его в `%LOCALAPPDATA%\confluence-mcp\creds.dat`, **но файл зашифрован DPAPI** и читается только тем же пользователем на той же машине. У другого сотрудника — спросить токен (PAT) через `Read-Host -AsSecureString`.

---

## 3. Требования к UX (обязательные)

- [ ] **Никаких параметров командной строки.** Всё настраивается в блоке `НАСТРОЙКИ` в начале `.ps1`.
- [ ] **Запуск двойным щелчком** по `.bat` (в нём `chcp 65001` для русского).
- [ ] **Ошибка не закрывает окно**: `trap` печатает текст ошибки, файл и номер строки, затем ждёт Enter.
- [ ] В конце — пауза, чтобы прочитать итог.
- [ ] Русский текст в консоли читается (`[Console]::OutputEncoding = UTF8`).
- [ ] Прогресс виден: номер страницы, имя, `+ файл (размер)`, `- пропущен`.
- [ ] Итог: сколько страниц, сколько файлов, сколько ошибок, куда сохранилось, где `index.csv`.
- [ ] Файл `.ps1` — **UTF-8 с BOM** (иначе PowerShell 5.1 прочитает русский как мусор).

---

## 4. Алгоритм

```
1. Настройки из блока НАСТРОЙКИ ($RootPage, $OutDir, флаги).
2. Токен: $env:CONFLUENCE_PAT → creds.dat → запрос вводом.
3. $RootPage → ID (регулярка /pages/(\d+) или pageId=(\d+)); ошибка с подсказкой, если не нашли.
4. Рекурсия от корня:
     GET страницу (view + storage + version)
     создать папку «<Безопасное имя> (<id>)» в папке родителя
     сохранить page.html (из body.view) и/или page.storage.xml (из body.storage)
     GET child/attachment → для каждого:
         пропустить имена на «~», если SkipTempFiles
         пропустить, если размер > MinFileSizeMb
         скачать по _links.download в attachments/ (проверять, что файл появился)
     GET child/page → рекурсивно
     записать строку в index.csv
5. Итог + пауза.
```

Важные детали реализации:

- **Имена файлов и папок санитизировать**: `[IO.Path]::GetInvalidFileNameChars()` → `_`, обрезать до ~90 символов, добавить `(id)` — иначе коллизии одинаковых названий.
- **Ретраи**: 5 попыток на GET с паузой, 3 на скачивание. Confluence периодически отдаёт `ERR`/429 при массовых запросах — пауза 40–60 с лечит.
- **Не считать ошибкой 404** на страницу (в поддереве могут быть вложения/удалённые объекты в индексе) — пропускать.
- **`MaxPages`** — предохранитель (0 = без ограничения), полезен при проверке на большом дереве.
- **Пути > 260 символов**: имена уже обрезаны; не вкладывать `$OutDir` слишком глубоко.

---

## 5. Ключевые фрагменты (если файлов нет — воссоздать по ним)

Блок настроек:

```powershell
$RootPage = '123456792'                              # ID или ссылка — ЕДИНСТВЕННОЕ, что правит пользователь
$OutDir   = "$env:USERPROFILE\Documents\FTT-export"
$SavePageHtml        = $true
$SaveStorageXml      = $false
$DownloadAttachments = $true
$MinFileSizeMb       = 0      # 0 = всё; 50 = не качать больше 50 МБ
$SkipTempFiles       = $true
$MaxPages            = 0
```

Токен:

```powershell
$token = if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT } else {
    $credPath = "$env:LOCALAPPDATA\confluence-mcp\creds.dat"
    if (Test-Path -LiteralPath $credPath) {
        $e = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
        $s = $e.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
        [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    }
}
if (-not $token) { $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString))) }
```

Скачивание вложения (рабочий способ):

```powershell
$w = New-Object System.Net.WebClient
$w.Headers.Add('Authorization', "Bearer $token")
$w.Headers.Add('User-Agent','Mozilla/5.0')
$w.DownloadFile($base + $att._links.download, $dest)
```

Рекурсия по детям:

```powershell
$ch = Api-Get "$base/rest/api/content/$pageId/child/page?limit=200"
foreach ($c in $ch.results) { Export-Page ([string]$c.id) $folder ($depth + 1) }
```

Максимально полная версия — в файле `Export-ConfluenceTree.ps1` рядом с этой инструкцией.

---

## 6. Подводные камни

1. **DPAPI.** `creds.dat` нельзя передать другому человеку — он не расшифруется. Для чужих машин: `CONFLUENCE_PAT` или ввод токена.
2. **Кодировка `.ps1`** — только UTF-8 **с BOM**.
3. **Кодировка консоли** — `[Console]::OutputEncoding = UTF8` + `chcp 65001` в `.bat`.
4. **Имена файлов** — Confluence разрешает `: * ? " < > |` и очень длинные имена; на Windows это ломает сохранение.
5. **Большие файлы** — в дереве встречаются видео по 100+ МБ; для пробного прогона ставить `MinFileSizeMb = 50`.
6. **Мусор `~*.tmp`** — служебные версии вложений; пропускать.
7. **Скорость** — дерево на 500+ страниц с вложениями качается долго; это нормально, прогресс в консоли.
8. **Права** — если пользователь не видит часть страниц, скрипт их просто не получит (404/403), это не ошибка формата.

---

## 7. Чек-лист приёмки

- [ ] Скрипт запускается **двойным щелчком** `.bat`, параметров не просит.
- [ ] Достаточно поменять `$RootPage` в Блокноте — и всё.
- [ ] На тестовой странице с вложениями: создались папки по иерархии, `page.html` открывается в браузере, `attachments` заполнена, `index.csv` и `export-log.txt` на месте.
- [ ] Русские названия папок корректны (проверять в Проводнике, а не в консоли).
- [ ] Ошибка (например, неверный ID) показывает понятное сообщение и окно не закрывается.
- [ ] Повторный запуск не падает и перезаписывает результат.
- [ ] Дерево в 3+ уровня вложенности обходится полностью.
- [ ] Страница без вложений обрабатывается без ошибок.

---

## 8. Как проверить, что всё работает (быстрый прогон)

В настройках временно поставить:

```powershell
$RootPage = '<id страницы с вложениями>'
$OutDir   = "$env:TEMP\export-check"
$MinFileSizeMb = 50
$MaxPages = 3
```

Ожидаемо: 1–3 страницы, несколько файлов, `0 ошибок`, папки с русскими именами.
После проверки вернуть `$MinFileSizeMb = 0` и `$MaxPages = 0`.

---

## 9. Если нужно иначе

- **Только вложения, без текста страниц** → `$SavePageHtml = $false`, `$SaveStorageXml = $false`.
- **Только текст, без файлов** → `$DownloadAttachments = $false`.
- **Одна страница без детей** → поставить `$MaxPages = 1`.
- **Несколько корней** → запустить скрипт несколько раз, меняя `$RootPage` (или сделать `$RootPage` массивом и цикл — но пользователю проще менять одну строку).
