<#
.SYNOPSIS
    Выгружает все таблицы со страницы Confluence в один .xlsx (по листу на таблицу).

.DESCRIPTION
    Confluence REST API НЕ использует браузерную сессию, поэтому «доступа к странице
    в браузере» недостаточно: нужен Personal Access Token (Bearer) либо логин+пароль (Basic).

    Токен берётся из -Token или переменных окружения CONFLUENCE_PAT /
    CONFLUENCE_PERSONAL_TOKEN / CONFLUENCE_TOKEN.
    Базовый URL — из -BaseUrl или CONFLUENCE_BASE / CONFLUENCE_URL.

    Парсинг HTML-таблиц — через MSHTML (htmlfile), запись .xlsx — через Excel COM.
    Внешние модули (ImportExcel) не требуются.

.PARAMETER Page
    URL страницы (https://host/pages/123456789/Title) или числовой ID.

.PARAMETER OutFile
    Путь к .xlsx. По умолчанию: .\confluence_<ID>_tables.xlsx

.PARAMETER FirstRowHeader
    Считать первую строку каждой таблицы заголовком (жирный шрифт + закрепление).

.PARAMETER AsText
    Записать все ячейки как текст (сохраняет ведущие нули: коды, ИНН, артикулы).

.EXAMPLE
    $env:CONFLUENCE_URL = 'https://confluence.example.com'
    $env:CONFLUENCE_PERSONAL_TOKEN = '<personal-access-token>'
    .\Export-ConfluenceTables.ps1 -Page 'https://confluence.example.com/pages/123456789/Report'

.EXAMPLE
    .\Export-ConfluenceTables.ps1 -Page 123456789 -OutFile .\report.xlsx -FirstRowHeader -AsText
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Page,

    [string]$OutFile,

    [string]$BaseUrl = $(if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE }
                         elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { '' }),
    [string]$Token   = $(if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT }
                         elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN }
                         elseif ($env:CONFLUENCE_TOKEN) { $env:CONFLUENCE_TOKEN } else { '' }),
    [string]$User,

    [switch]$FirstRowHeader,
    [switch]$AsText,
    [switch]$KeepHtml,
    [switch]$Insecure
)

$ErrorActionPreference = 'Stop'

function Get-PageId {
    param([string]$Value)
    if ($Value -match '^\d+$')                 { return $Value }
    if ($Value -match '/pages/(\d+)')          { return $Matches[1] }
    if ($Value -match '[?&]pageId=(\d+)')      { return $Matches[1] }
    throw "Не удалось извлечь ID страницы из '$Value'. Укажите URL с /pages/<ID> или числовой ID."
}

function Get-SafeSheetName {
    param([string]$Name, [System.Collections.Generic.HashSet[string]]$Used)
    $n = ($Name -replace '[\[\]:*?/\\]', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($n) -or $n -eq 'History') { $n = 'Table' }
    if ($n.Length -gt 31) { $n = $n.Substring(0, 31).Trim() }
    $base = $n
    $i = 1
    while ($Used.Contains($n)) {
        $i++
        $suffix = " ($i)"
        $n = $base.Substring(0, [Math]::Min($base.Length, 31 - $suffix.Length)).Trim() + $suffix
    }
    [void]$Used.Add($n)
    return $n
}

function Convert-TableToGrid {
    param($Table)
    $grid  = New-Object System.Collections.Generic.List[object]
    $pend  = @{}
    foreach ($row in $Table.rows) {
        $line = New-Object System.Collections.Generic.List[string]
        $col  = 0
        foreach ($cell in $row.cells) {
            while ($pend.ContainsKey($col)) {
                $line.Add($pend[$col].Text)
                $pend[$col].Left--
                if ($pend[$col].Left -le 0) { $pend.Remove($col) }
                $col++
            }
            $text = ($cell.innerText -replace '\s+', ' ').Trim()
            $cs = 1; if ($cell.colSpan) { $cs = [int]$cell.colSpan }
            $rs = 1; if ($cell.rowSpan) { $rs = [int]$cell.rowSpan }
            for ($i = 0; $i -lt $cs; $i++) {
                $line.Add($text)
                if ($rs -gt 1) { $pend[$col] = @{ Text = $text; Left = $rs - 1 } }
                $col++
            }
        }
        while ($pend.ContainsKey($col)) {
            $line.Add($pend[$col].Text)
            $pend[$col].Left--
            if ($pend[$col].Left -le 0) { $pend.Remove($col) }
            $col++
        }
        if ($line.Count -gt 0) { $grid.Add($line.ToArray()) }
    }
    return $grid
}

# --- 1. Входные данные ---------------------------------------------------
$pageId = Get-PageId $Page

if (-not $BaseUrl) { throw 'Не задан BaseUrl. Укажите -BaseUrl или переменную окружения CONFLUENCE_BASE / CONFLUENCE_URL. См. Export-ConfluenceTables.md.' }
if (-not $Token)   { throw 'Не задан токен. Укажите -Token или переменную окружения CONFLUENCE_PAT / CONFLUENCE_PERSONAL_TOKEN. См. Export-ConfluenceTables.md.' }
$BaseUrl = $BaseUrl.TrimEnd('/')

if ($User) {
    $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$User`:$Token"))
    $auth = "Basic $b64"
} else {
    $auth = "Bearer $Token"
}

if (-not $OutFile) { $OutFile = ".\confluence_${pageId}_tables.xlsx" }
if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
    $OutFile = Join-Path (Get-Location).Path $OutFile
}
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { throw "Папка не найдена: $outDir" }

# --- 2. Загрузка страницы ------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($Insecure) {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$uri = "$BaseUrl/rest/api/content/$pageId`?expand=body.view,body.storage,version"
Write-Host "GET $uri" -ForegroundColor DarkGray

$wc = New-Object System.Net.WebClient
$wc.Encoding = [System.Text.Encoding]::UTF8
$wc.Headers.Add('Authorization', $auth)
$wc.Headers.Add('Accept', 'application/json')
try {
    $json = $wc.DownloadString($uri)
} catch [System.Net.WebException] {
    $code = $_.Exception.Response.StatusCode.value__
    throw "Confluence вернул HTTP $code. Проверьте BaseUrl, токен и права на страницу $pageId. $($_.Exception.Message)"
} finally {
    $wc.Dispose()
}

$pageObj = $json | ConvertFrom-Json
$title   = $pageObj.title
$html    = $null
if ($pageObj.body.view.value)    { $html = $pageObj.body.view.value }
elseif ($pageObj.body.storage.value) { $html = $pageObj.body.storage.value }
if (-not $html) { throw "У страницы $pageId нет тела (body.view/body.storage)." }

if ($KeepHtml) {
    $htmlPath = [System.IO.Path]::ChangeExtension($OutFile, '.html')
    [System.IO.File]::WriteAllText($htmlPath, $html, [System.Text.UTF8Encoding]::new($true))
    Write-Host "HTML сохранён: $htmlPath" -ForegroundColor DarkGray
}

# --- 3. Разбор таблиц ----------------------------------------------------
$doc = New-Object -ComObject 'HTMLFile'
try {
    $doc.IHTMLDocument2_write($html)
} catch {
    throw "Не удалось разобрать HTML страницы: $($_.Exception.Message). Запустите с -KeepHtml и проверьте файл."
}

$allTables = @($doc.getElementsByTagName('table'))

$topTables = foreach ($t in $allTables) {
    $p = $t.parentElement
    $nested = $false
    while ($p) {
        if ($p.tagName -eq 'TABLE') { $nested = $true; break }
        $p = $p.parentElement
    }
    if (-not $nested) { $t }
}
$topTables = @($topTables)

if ($topTables.Count -eq 0) { throw "На странице '$title' ($pageId) таблиц не найдено." }

$headings = @()
foreach ($tag in 'h1', 'h2', 'h3', 'h4', 'h5', 'h6') {
    $headings += @($doc.getElementsByTagName($tag))
}

$tables = @()
foreach ($t in $topTables) {
    $grid = Convert-TableToGrid -Table $t
    if ($grid.Count -eq 0) { continue }

    $caption = ($t.caption | ForEach-Object { $_.innerText }) -replace '\s+', ' '
    if ([string]::IsNullOrWhiteSpace($caption)) {
        $idx = [int]$t.sourceIndex
        $near = $headings |
            Where-Object { [int]$_.sourceIndex -lt $idx } |
            Sort-Object { [int]$_.sourceIndex } |
            Select-Object -Last 1
        if ($near) { $caption = ($near.innerText -replace '\s+', ' ').Trim() }
    }

    $tables += [pscustomobject]@{
        Name = if ([string]::IsNullOrWhiteSpace($caption)) { '' } else { $caption }
        Grid = $grid
    }
}

if ($tables.Count -eq 0) { throw "На странице '$title' ($pageId) нет непустых таблиц." }

# --- 4. Запись в Excel ---------------------------------------------------
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
$excel.ScreenUpdating = $false

$wb = $null
try {
    $wb = $excel.Workbooks.Add()
    $defaultCount = $wb.Sheets.Count

    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]'
    $i = 0
    foreach ($tbl in $tables) {
        $i++
        $grid  = $tbl.Grid
        $rows  = $grid.Count
        $cols  = ($grid | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
        if ($rows -eq 0 -or $cols -eq 0) { continue }

        $after = $wb.Sheets.Item($wb.Sheets.Count)
        $ws = $wb.Sheets.Add([System.Reflection.Missing]::Value, $after)
        $ws.Name = Get-SafeSheetName -Name $(if ($tbl.Name) { $tbl.Name } else { "Table$i" }) -Used $usedNames

        $arr = New-Object 'object[,]' $rows, $cols
        for ($r = 0; $r -lt $rows; $r++) {
            $line = $grid[$r]
            for ($c = 0; $c -lt $cols; $c++) {
                $arr[$r, $c] = if ($c -lt $line.Count) { $line[$c] } else { '' }
            }
        }

        $range = $ws.Range($ws.Cells(1, 1), $ws.Cells($rows, $cols))
        if ($AsText) { $range.NumberFormat = '@' }
        $range.Value2 = $arr

        if ($FirstRowHeader) {
            $ws.Rows.Item(1).Font.Bold = $true
            $ws.Activate()
            $excel.ActiveWindow.FreezePanes = $false
            $ws.Range('A2').Select() | Out-Null
            $excel.ActiveWindow.FreezePanes = $true
        }

        try { $ws.Columns.AutoFit() | Out-Null } catch { }

        Write-Host ("  [{0}] {1}: {2} строк x {3} столбцов" -f $i, $ws.Name, $rows, $cols) -ForegroundColor Gray
    }

    for ($d = 1; $d -le $defaultCount; $d++) { $wb.Sheets.Item(1).Delete() }

    if ($wb.Sheets.Count -eq 0) { throw 'Нечего записывать: все таблицы пустые.' }

    $wb.SaveAs($OutFile, 51)
}
finally {
    if ($wb) { $wb.Close($false) }
    $excel.Quit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

Write-Host ''
Write-Host "Готово: $OutFile" -ForegroundColor Green
Write-Host ("Страница: {0} (id {1})" -f $title, $pageId)
Write-Host ("Таблиц выгружено: {0}" -f $tables.Count)
