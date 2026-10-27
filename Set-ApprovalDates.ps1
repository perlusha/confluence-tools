<#
.SYNOPSIS
    Проставляет плановую дату согласования (07.01) в строки согласующих.

.DESCRIPTION
    Обходит дерево от -Root. Берёт страницы, у которых поле
    «01. Наименование отчетного документа» равно «ФТТ».
    Для них:
      - дата берётся из поля «07.01. Плановая дата согласования»;
      - если дата не заполнена — страница не трогается;
      - в строках «NN. Согласующий N» с ЖИВЫМ статусом вне списка
        {Согласован, Отменен} дата проставляется после пилюли;
      - если дата в строке уже есть — она заменяется на дату из 07.01;
      - у строк со статусом Согласован/Отменен ничего не меняется.

    По умолчанию — DRY RUN.

.PARAMETER Root
    Корневая страница дерева (ID или URL).

.PARAMETER Only
    Обработать только одну страницу (для проверки).

.PARAMETER Apply
    Записать изменения. Без него — только план.

.EXAMPLE
    .\Set-ApprovalDates.ps1 -Root 467853802
    .\Set-ApprovalDates.ps1 -Root 467853802 -Only 505158626 -Apply
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$Only,

    [string]$BaseUrl = $(if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE }
                         elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { '' }),
    [string]$Token   = $(if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT }
                         elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN }
                         elseif ($env:CONFLUENCE_TOKEN) { $env:CONFLUENCE_TOKEN } else { '' }),
    [string]$User,
    [int]$MaxPages = 0,
    [switch]$Apply,
    [switch]$Insecure
)

$ErrorActionPreference = 'Stop'
if (-not $BaseUrl) { throw 'Не задан BaseUrl (CONFLUENCE_BASE / CONFLUENCE_URL).' }
if (-not $Token)   { throw 'Не задан токен (CONFLUENCE_PAT / CONFLUENCE_PERSONAL_TOKEN).' }
$BaseUrl = $BaseUrl.TrimEnd('/')
if ($User) { $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$User`:$Token")) }
else { $auth = "Bearer $Token" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($Insecure) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }

$HANDY = "$BaseUrl/rest/handy-macros/2.0"
$APPROVED = @('согласован', 'отменен')      # этим статусам дата не проставляется

function Get-PageId {
    param([string]$Value)
    if ($Value -match '^\d+$')            { return $Value }
    if ($Value -match '/pages/(\d+)')     { return $Matches[1] }
    if ($Value -match '[?&]pageId=(\d+)') { return $Matches[1] }
    throw "Не удалось извлечь ID страницы из '$Value'."
}
function Api-Get {
    param([string]$Uri, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add('Authorization', $auth); $wc.Headers.Add('Accept', 'application/json')
        try { return ($wc.DownloadString($Uri) | ConvertFrom-Json) }
        catch { if ($i -eq $Retry) { throw }; Start-Sleep -Milliseconds (250 * $i) }
        finally { $wc.Dispose() }
    }
}
function Api-PutJson {
    param([string]$Uri, [string]$Json, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add('Authorization', $auth); $wc.Headers.Add('Content-Type', 'application/json')
        try { return ([System.Text.Encoding]::UTF8.GetString($wc.UploadData($Uri, 'PUT', [System.Text.Encoding]::UTF8.GetBytes($Json))) | ConvertFrom-Json) }
        catch { if ($i -eq $Retry) { throw }; Start-Sleep -Milliseconds (400 * $i) }
        finally { $wc.Dispose() }
    }
}
function Get-LiveStatus {
    param([string]$MacroId, [string]$PageId)
    try { $j = Api-Get "$HANDY/status-macro/$MacroId`?contentId=$PageId" } catch { return $null }
    if ($j -and $j.status -and $null -ne $j.status.id) { return [string]$j.status.name }
    return $null
}
function Test-Approved {
    param([string]$Name)
    $n = ($Name -replace '\s+', ' ').Trim().ToLower()
    return ($APPROVED -contains $n)
}

# проставляет/заменяет дату в одной строке таблицы
function Set-RowDate {
    param([string]$Row, [string]$Date)
    $mx = [regex]::Match($Row, '(?s)<ac:structured-macro[^>]*ac:name="status-handy".*?</ac:structured-macro>')
    if (-not $mx.Success) { return $Row }
    $after = $mx.Index + $mx.Length
    $tail = $Row.Substring($after)
    $tm = [regex]::Match($tail, '<time[^>]*datetime="([^"]*)"[^>]*>')
    if ($tm.Success) {
        if ($tm.Groups[1].Value -eq $Date) { return $Row }
        $newTail = [regex]::Replace($tail, '(<time[^>]*datetime=")[^"]*(")', ('${1}' + $Date + '${2}'), 1)
        return $Row.Substring(0, $after) + $newTail
    }
    return $Row.Substring(0, $after) + '<br /><time datetime="' + $Date + '" /> ' + $Row.Substring($after)
}

# разбор одной страницы -> хэш { Changed, NewHtml, Log }
function Process-Page {
    param([string]$PageId)
    $pg = Api-Get "$BaseUrl/rest/api/content/$PageId`?expand=body.storage,version"
    $html = $pg.body.storage.value
    if (-not $html) { return $null }
    $rowRx = [regex]'(?s)<tr[^>]*>(.*?)</tr>'
    $cellRx = [regex]'(?s)<t([dh])([^>]*)>(.*?)</t\1>'

    $v01 = ''; $date = ''
    foreach ($rm in $rowRx.Matches($html)) {
        $cells = @($cellRx.Matches($rm.Groups[1].Value))
        if ($cells.Count -lt 2) { continue }
        $lab = ($cells[0].Groups[3].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
        $val = $cells[1].Groups[3].Value
        if ($lab -match '^01\.') { $v01 = [System.Net.WebUtility]::HtmlDecode(($val -replace '<[^>]+>', ' ' -replace '\s+', ' ')).Trim() }
        if ($lab -match '^07\.01') { $t = [regex]::Match($val, 'datetime="([^"]*)"'); if ($t.Success) { $date = $t.Groups[1].Value } }
    }
    if ($v01 -ne 'ФТТ') { return [pscustomobject]@{ Kind = 'skip01'; Value = $v01 } }
    if (-not $date)     { return [pscustomobject]@{ Kind = 'skipdate' } }

    $new = $html; $offset = 0; $log = @(); $changed = 0; $statuses = @{}; $skipNoUser = 0
    foreach ($rm in $rowRx.Matches($html)) {
        $row = $rm.Value
        $cells = @($cellRx.Matches($rm.Groups[1].Value))
        if ($cells.Count -lt 2) { continue }
        $lab = ($cells[0].Groups[3].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
        if ($lab -notmatch '^\d+\.\s*Согласующ') { continue }
        if ($row -notmatch 'ri:userkey=') { $skipNoUser++; continue }   # согласующий не заполнен
        $mid = [regex]::Match($row, 'ac:name="id">(\d+)<')
        if (-not $mid.Success) { continue }
        $st = Get-LiveStatus -MacroId $mid.Groups[1].Value -PageId $PageId
        if (-not $st) { $log += ("  {0}: статус не прочитан — пропуск" -f $lab); continue }
        $statuses[$st] = $true
        if (Test-Approved $st) { continue }
        $newRow = Set-RowDate -Row $row -Date $date
        if ($newRow -eq $row) { continue }
        $idx = $rm.Index + $offset
        $new = $new.Substring(0, $idx) + $newRow + $new.Substring($idx + $row.Length)
        $offset += $newRow.Length - $row.Length
        $changed++
        $log += ("  {0}: «{1}» → дата {2}" -f $lab, $st, $date)
    }
    return [pscustomobject]@{ Kind = 'ok'; Title = $pg.title; Version = [int]$pg.version.number; Date = $date; Changed = $changed; SkipNoUser = $skipNoUser; NewHtml = $new; Log = $log }
}

# ---------------------------------------------------------------- страницы
$ids = New-Object System.Collections.Generic.List[string]
$titles = @{}
if ($Only) {
    $ids.Add((Get-PageId $Only))
} else {
    if (-not $Root) { throw 'Укажите -Root (дерево) или -Only (одна страница).' }
    $rootId = Get-PageId $Root
    Write-Output "Обход дерева от $rootId ..."
    function Walk([string]$id, [int]$depth) {
        if ($depth -gt 10) { return }
        $u = "$BaseUrl/rest/api/content/$id/child/page?limit=100"
        do {
            $r = Api-Get $u
            foreach ($c in $r.results) { $script:ids.Add([string]$c.id); $script:titles[[string]$c.id] = $c.title; Walk $c.id ($depth + 1) }
            $u = if ($r._links.next) { $BaseUrl + $r._links.next } else { $null }
        } while ($u)
    }
    Walk $rootId 1
    if ($MaxPages -gt 0 -and $ids.Count -gt $MaxPages) { $ids = $ids.GetRange(0, $MaxPages) }
    Write-Output ("  страниц: " + $ids.Count)
}

Write-Output ''
$totPages = 0; $totChanged = 0; $totSkips = 0; $applied = 0; $totSkipUser = 0
$i = 0
foreach ($id in $ids) {
    $i++
    if ($i % 25 -eq 0) { Write-Output "  ... $i / $($ids.Count)" }
    $res = Process-Page -PageId $id
    if (-not $res) { continue }
    if ($res.Kind -eq 'skip01') { $totSkips++; continue }
    if ($res.Kind -eq 'skipdate') { $totSkips++; Write-Output ("{0}: 01=ФТТ, но 07.01 пусто — пропуск" -f $id); continue }
    $totPages++
    $totSkipUser += $res.SkipNoUser
    if ($res.Changed -eq 0) {
        if ($res.SkipNoUser -gt 0) { Write-Output ("{0}  «{1}»  дата {2}: согласующие не заполнены ({3} строк) — пропуск" -f $id, $res.Title, $res.Date, $res.SkipNoUser) }
        continue
    }
    $totChanged += $res.Changed
    Write-Output ("{0}  «{1}»  дата 07.01 = {2}, строк изменено: {3}" -f $id, $res.Title, $res.Date, $res.Changed)
    foreach ($l in $res.Log) { Write-Output $l }
    if ($Apply) {
        $payload = @{
            id = $id; type = 'page'; title = $res.Title
            version = @{ number = $res.Version + 1; message = 'set planned approval date' }
            body = @{ storage = @{ representation = 'storage'; value = $res.NewHtml } }
        } | ConvertTo-Json -Depth 20 -Compress
        try { $r = Api-PutJson "$BaseUrl/rest/api/content/$id" $payload; $applied++; Write-Output ("   → записано, v{0}" -f $r.version.number) }
        catch { Write-Warning ("   запись не удалась: " + $_.Exception.Message) }
    }
}
Write-Output ''
Write-Output ("Страниц «ФТТ» с датой: {0}   пропущено: {1}" -f $totPages, $totSkips)
Write-Output ("Строк согласующих к изменению: {0}   строк с незаполненным согласующим: {1}" -f $totChanged, $totSkipUser)
if (-not $Apply) { Write-Output 'DRY RUN: ничего не записано. Для записи добавьте -Apply.' }
else { Write-Output ("Записано страниц: {0}" -f $applied) }
