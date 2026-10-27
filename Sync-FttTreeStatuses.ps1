<#
.SYNOPSIS
    Переносит статусы пилюль из источников в дерево «Матрица ФТТ» (страница-дерево).
.DESCRIPTION
    Для каждой строки дерева:
      * источник — ссылка в колонке «Схема ФТТ» (для строки схемы) или «Наименование раздела» (для строки ФТТ);
      * у пилюль (блок, область, общий статус, согласующие) macroid тот же, что в источнике,
        но статус хранится по паре (macroid + страница) — поэтому значения в дереве надо ПЕРЕЗАПИСЫВАТЬ;
      * сравниваем статус в дереве и в источнике и пишем только расходящиеся.

    Статусы читаются из отрендеренного вида страницы (data-status) — один запрос на страницу.
    По умолчанию DRY RUN, для записи -Apply.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [switch]$Apply,
    [int]$Limit = 0,
    [string]$Log = "$env:TEMP\sync-tree-statuses.log"
)

$ErrorActionPreference = 'Stop'
trap {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host ('  строка ' + $_.InvocationInfo.ScriptLineNumber + ': ' + (($_.InvocationInfo.Line) -replace '^\s+', '').Trim()) -ForegroundColor DarkGray }
    if ($_.Exception.Response) {
        try { $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); Write-Host ('  ответ: ' + $sr.ReadToEnd()) -ForegroundColor DarkYellow; $sr.Close() } catch { }
    }
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Enter — закрыть' }
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$base = if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE } elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { 'https://confluence.example.com' }
$base = $base.TrimEnd('/')
$token = if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT } elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN } else {
    $credPath = "$env:LOCALAPPDATA\confluence-mcp\creds.dat"
    if (-not (Test-Path -LiteralPath $credPath)) { throw "Нет файла $credPath. Задайте CONFLUENCE_PAT." }
    $e = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
    $s = $e.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
    [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
$auth = "Bearer $token"
$HANDY = "$base/rest/handy-macros/2.0"
$CONTENT = "$base/rest/api/content/"
$logDir = Split-Path -Parent $Log
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }

function Api-Get([string]$u) {
    for ($i = 1; $i -le 5; $i++) {
        $w = New-Object System.Net.WebClient; $w.Encoding = [Text.Encoding]::UTF8
        $w.Headers.Add('Authorization', $auth); $w.Headers.Add('Accept', 'application/json')
        try { $r = $w.DownloadString($u); $w.Dispose(); return ($r | ConvertFrom-Json) }
        catch { $w.Dispose(); if ($i -eq 5) { throw }; Start-Sleep -Milliseconds (600 * $i) }
    }
}
function Api-PutForm([string]$Uri, [string]$Body) {
    for ($i = 1; $i -le 3; $i++) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = 'PUT'; $req.ContentType = 'application/x-www-form-urlencoded'
        $req.Headers.Add('Authorization', $auth); $req.Headers.Add('X-Atlassian-Token', 'no-check')
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        try {
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close(); return $t.Trim()
        } catch { if ($i -eq 3) { throw }; Start-Sleep -Milliseconds (400 * $i) }
    }
}
function Norm([string]$s) {
    $t = [System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ' '))
    $t = ($t -replace [string][char]0x00A0, ' ') -replace '\s+', ' '
    return $t.Trim()
}
# macroid -> statusId из отрендеренного вида
function Get-StatusMap([string]$viewHtml) {
    $map = @{}
    foreach ($m in [regex]::Matches($viewHtml, '<span id="(\d+)"[^>]*?data-status="(\d+)"')) {
        $map[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $map
}

$rowRx = [regex]'(?s)<tr[^>]*>[\s\S]*?</tr>'
$cellRx = [regex]'(?s)<t[dh]([^>]*)>([\s\S]*?)</t[dh]>'

$out = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $out.Add($s); Write-Output $s }

$treeId = $Target
if ($treeId -notmatch '^\d+$') {
    $m = [regex]::Match($Target, '/pages/(\d+)'); if (-not $m.Success) { $m = [regex]::Match($Target, '[?&]pageId=(\d+)') }
    if (-not $m.Success) { throw "Не удалось извлечь ID из '$Target'" }
    $treeId = $m.Groups[1].Value
}

$tree = Api-Get "$CONTENT$treeId`?expand=body.storage,body.view,version"
$treeMap = Get-StatusMap $tree.body.view.value
W ("дерево {0} v{1} «{2}»: пилюль на странице {3}" -f $treeId, $tree.version.number, $tree.title, $treeMap.Count)
W ("режим: " + $(if ($Apply) { 'ЗАПИСЬ' } else { 'DRY RUN' }))
W ''

$srcCache = @{}
$checked = 0; $same = 0; $changed = 0; $errors = 0; $rowsDone = 0

foreach ($rm in $rowRx.Matches($tree.body.storage.value)) {
    $cc = @($cellRx.Matches($rm.Value))
    if ($cc.Count -lt 60) { continue }
    $num = Norm $cc[0].Groups[2].Value
    if ($num -notmatch '^\d') { continue }
    $rowsDone++
    if ($Limit -gt 0 -and $rowsDone -gt $Limit) { break }

    $srcId = ''
    $m2 = [regex]::Match($cc[2].Groups[2].Value, '(?:pageId=|/pages/)(\d+)')
    if ($m2.Success) { $srcId = $m2.Groups[1].Value }
    else {
        $m1 = [regex]::Match($cc[1].Groups[2].Value, '(?:pageId=|/pages/)(\d+)')
        if ($m1.Success) { $srcId = $m1.Groups[1].Value }
    }
    if (-not $srcId) { W ("стр.{0}: источник не найден — пропуск" -f $num); $errors++; continue }

    if (-not $srcCache.ContainsKey($srcId)) {
        $sp = $null
        try { $sp = Api-Get "$CONTENT$srcId`?expand=body.view" } catch { $sp = $null }
        if ($sp) { $srcCache[$srcId] = Get-StatusMap $sp.body.view.value } else { $srcCache[$srcId] = $null }
        Start-Sleep -Milliseconds 80
    }
    $srcMap = $srcCache[$srcId]
    if (-not $srcMap) { W ("стр.{0}: источник {1} не прочитан — пропуск" -f $num, $srcId); $errors++; continue }

    $rowChanges = New-Object System.Collections.Generic.List[string]
    for ($ci = 3; $ci -lt $cc.Count; $ci++) {
        $mid = ([regex]::Match($cc[$ci].Groups[2].Value, 'ac:name="id">(\d+)<')).Groups[1].Value
        if (-not $mid) { continue }
        $checked++
        $treeSt = $treeMap[$mid]
        $srcSt = $srcMap[$mid]
        if (-not $srcSt) { $same++; continue }          # в источнике этой пилюли нет — не трогаем
        if ($treeSt -eq $srcSt) { $same++; continue }
        $changed++
        $rowChanges.Add(("[{0}] {1}: {2} -> {3}" -f $ci, $mid, $(if ($treeSt) { $treeSt } else { 'нет' }), $srcSt))
        if ($Apply) {
            try { [void](Api-PutForm "$HANDY/status-macro/$mid/value" "contentId=$treeId&statusId=$srcSt") }
            catch { $errors++; W ("стр.{0}: ошибка записи {1}: {2}" -f $num, $mid, $_.Exception.Message) }
            Start-Sleep -Milliseconds 50
        }
    }
    if ($rowChanges.Count) {
        W ("стр.{0} (источник {1}):" -f $num, $srcId)
        foreach ($r in $rowChanges) { W ("   " + $r) }
    }
}

W ''
W ("ИТОГО: строк {0}, пилюль проверено {1}, совпало {2}, изменено {3}, ошибок {4}" -f $rowsDone, $checked, $same, $changed, $errors)
if (-not $Apply) { W 'DRY RUN: ничего не записано. Для записи добавьте -Apply.' }
[System.IO.File]::WriteAllLines($Log, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("лог: $Log")
