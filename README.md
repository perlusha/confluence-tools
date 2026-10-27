# Инструменты для Confluence

Скрипты и браузерные закладки для работы с **матрицей согласования** в Confluence
(пространство `DEMO`): выгрузка таблиц, сборка матриц, синхронизация статусов,
простановка дат.

**Как устроена матрица.** Строки — документы, столбцы — согласующие, в ячейках — статусы.
Статусы это **пилюли приложения Handy Macros** (`status-handy`): текст и цвет берутся из
реестра приложения по `id`, а не из тела страницы. На каждой странице-документе есть
свой лист согласования — строки «NN. Согласующий N».

---

## Браузерные закладки (JavaScript)

Работают **в вашей сессии**, токен не нужен. Ставятся как закладка: `Ctrl+Shift+B`,
`Ctrl+Shift+O`, в URL — содержимое `.js` (одна строка).

| файл | что делает | где нажимать |
|---|---|---|
| `confluence-table-to-clipboard.js` | копирует таблицу со страницы в буфер (HTML + TSV) | на странице с таблицей → `Ctrl+V` в Excel |
| `confluence-matrix-to-xlsx.js` | собирает со страницы готовый `.xlsx`: высота строк 20, без лишних объединений, цвета статусов, автофильтр | на странице матрицы |
| `confluence-approval-sync.js` | переносит статусы со страниц-источников в сводную матрицу (согласующие + «Функциональный блок», «Функциональная область», «Общий статус согласования»); недостающие пилюли создаёт | на сводной матрице |

Инструкция к каждой — в одноимённом `.md`.

---

## PowerShell

Нужен токен (см. «Настройка»). Все скрипты по умолчанию **ничего не пишут** там,
где это возможно; запись включается ключом `-Apply`.

| файл | что делает | пишет |
|---|---|---|
| `Export-ConfluenceTables.ps1` | выгружает таблицы со страниц в `.xlsx` | файл |
| `Get-ConfluenceApprovalStatus.ps1` | read-only сканер: словарь статусов, задачи, пилюли | ничего |
| `Format-ApprovalMatrix.ps1` | оформляет выгруженный `.xlsx` (объединения, высоты, УФ, фильтр) | файл |
| `Sync-ConfluenceApprovalStatus.ps1` | серверная версия синхронизации статусов матрицы: меняет, создаёт и очищает ячейки согласующих (нет статуса в источнике — ячейка пустеет) | страницу (`-Apply`) |
| `Build-ApprovalMatrix.ps1` | собирает плоскую матрицу из дерева страниц на целевую страницу | страницу (`-Apply`) |
| `Fill-MatrixExtraColumns.ps1` | дозаполняет колонки «Функциональный блок», «Функциональная область», «Лид», «Аналитик», «Общий статус согласования» | страницу (`-Apply`) |
| `Set-ApprovalDates.ps1` | проставляет плановую дату (07.01) в строки согласующих | страницы (`-Apply`) |

Инструкция к каждому — в одноимённом `.md`.

---

## Что выбрать

| задача | инструмент |
|---|---|
| одну таблицу со страницы — в Excel | закладка `table-to-clipboard` |
| матрицу со страницы — в оформленный Excel | закладка `matrix-to-xlsx` |
| обновить статусы в готовой матрице, разово | закладка `approval-sync` |
| то же по расписанию | `Sync-ConfluenceApprovalStatus.ps1` |
| собрать матрицу из дерева страниц | `Build-ApprovalMatrix.ps1` |
| дозаполнить колонки блока/лида/аналитика | `Fill-MatrixExtraColumns.ps1` |
| проставить плановые даты согласующим | `Set-ApprovalDates.ps1` |
| посмотреть, какие вообще бывают статусы | `Get-ConfluenceApprovalStatus.ps1` |

---

## Настройка

### Токен

PowerShell-скриптам нужен **Personal Access Token**. Подробно — в
`Export-ConfluenceTables.md`; кратко:

```powershell
$root = "$env:LOCALAPPDATA\confluence-mcp"
$creds = Get-Content "$root\creds.dat" -Raw | ConvertFrom-Json
$creds.CONFLUENCE_PERSONAL_TOKEN =
    (Read-Host "Confluence PAT (ввод скрыт)" -AsSecureString | ConvertFrom-SecureString)
$creds | ConvertTo-Json | Set-Content "$root\creds.dat" -Encoding utf8
```

Перед запуском удобно один раз выставить окружение:

```powershell
$enc = Get-Content "$env:LOCALAPPDATA\confluence-mcp\creds.dat" -Raw | ConvertFrom-Json
$env:CONFLUENCE_PERSONAL_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($enc.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString))
$env:CONFLUENCE_URL = 'https://confluence.example.com'
```

Доступ к странице в браузере **не заменяет** токен: REST API авторизуется отдельно.

### Закладка

1. `Ctrl+Shift+B` — панель закладок, `Ctrl+Shift+O` — диспетчер.
2. Новая закладка, в URL — строка из соответствующего `.md`.
3. После **любого изменения** скрипта строку нужно взять заново — в `.md` она всегда
   актуальная.

---

## Технические заметки

- **Статусы — в реестре приложения, а не в теле страницы.** Тело содержит только
  `id` экземпляра макроса. API: `/rest/handy-macros/2.0/…` (описание — по
  `application.wadl`).
  - чтение: `GET /status-macro/{id}?contentId={page}`
  - смена: `PUT /status-macro/{id}/value` (`contentId`, `statusId`)
  - создание: `POST /status-macro` (`contentId`, `statusId`) — возвращает новый `id`
- **Ориентироваться на живой статус из API**, а не на параметр `Status` в теле:
  снимок бывает устаревшим.
- **Реестр статусов — на пространство** (`statusSet`, owner `space:DEMO`).
- **Пилюли нельзя вписать в разметку вручную** — приложение должно создать экземпляр
  (`POST`), иначе не отрендерится. API удаления нет, поэтому повторное создание
  оставляет «сироты».
- **Повторные запуски.** `Build-ApprovalMatrix.ps1` переиспользует существующие пилюли;
  `Set-ApprovalDates.ps1` идемпотентен. Перед записью полезно прогнать без `-Apply`.
- **R1C1.** Выгрузки из Confluence бывают в стиле R1C1 — тогда формулы условного
  форматирования с A1-ссылками не работают. `Format-ApprovalMatrix.ps1` определяет стиль
  и строит формулу как `RC`.
- **Excel-цвета — BGR.** При чтении `Interior.Color` легко перепутать R и B.
- **PowerShell и `?` в строке:** `"$id?expand=…"` разбирается как переменная
  `id?expand`. Экранировать: `` `? ``.
- **Скрипты с кириллицей сохранять в UTF-8 с BOM**, иначе PowerShell 5.1 читает их как
  ANSI и портит строки.
