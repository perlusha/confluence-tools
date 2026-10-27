<#
.SYNOPSIS
    Поднимает статусы согласующих: «Черновик» / «Подготовка» -> «На согласовании».
.DESCRIPTION
    Обходит страницы (одну или поддерево) и меняет статус ТОЛЬКО у строк «NN. Согласующий N»,
    если у них стоит один из -From. Статус ищется по ИМЕНИ (id в пространствах разные),
    целевой id берётся из набора статусов этой же пилюли.
    Общий статус 08.01 не трогается.
    По умолчанию DRY RUN, для записи -Apply.
.PARAMETER Target
    ID/URL страницы или корня (с -Recurse).
.PARAMETER Exclude
    userkey'и, которых не трогаем (по умолчанию Ivanov I.).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [switch]$Apply,
    [switch]$Recurse,
    [int]$Limit = 0,
    [string[]]$From = @('Черновик', 'Подготовка'),
    [string]$To = 'На согласовании',
    [string]$Exclude = '',
    [string]$Log = "$env:TEMP\promote-approvers.log"
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
function Api-Raw([string]$u) {
    for ($i = 1; $i -le 5; $i++) {
        $w = New-Object System.Net.WebClient; $w.Encoding = [Text.Encoding]::UTF8
        $w.Headers.Add('Authorization', $auth); $w.Headers.Add('Accept', 'application/json')
        try { $r = $w.DownloadString($u); $w.Dispose(); return $r }
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
function Get-Status([string]$mid, [string]$cid) {
    try {
        $j = Api-Get "$HANDY/status-macro/$mid`?contentId=$cid"
        if ($j -and $j.status) { return [pscustomobject]@{ Id = [int]$j.status.id; Name = [string]$j.status.name } }
    } catch { }
    return $null
}
# id статуса по имени из набора статусов конкретной пилюли
function Resolve-StatusId([string]$mid, [string]$cid, [string]$name) {
    try {
        $opts = Api-Raw "$HANDY/status-macro/$mid/options/aui-dropdown?contentId=$cid"
        $oj = $opts | ConvertFrom-Json
        foreach ($sec0 in $oj) {
            foreach ($it in $sec0.items) {
                $c0 = [string]$it.content
                $sid0 = ([regex]::Match($c0, 'data-status="(\d+)"')).Groups[1].Value
                $nm0 = ([System.Net.WebUtility]::HtmlDecode(($c0 -replace '(?s)^.*?data-status="\d+"[^>]*>', '' -replace '</a>.*$', '' -replace '<[^>]+>', ' ' -replace '\s+', ' '))).Trim()
                if ($nm0 -eq $name) { return $sid0 }
            }
        }
    } catch { }
    return ''
}

$rowRx = [regex]'(?s)<tr[^>]*>([\s\S]*?)</tr>'
$cellRx = [regex]'(?s)<t[dh]([^>]*)>([\s\S]*?)</t[dh]>'
$excludeSet = @($Exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$out = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $out.Add($s); Write-Output $s }

# страницы
$ids = New-Object System.Collections.Generic.List[string]
$t = $Target
if ($t -match '^\d+$') { $ids.Add($t) } else {
    $m = [regex]::Match($t, '/pages/(\d+)'); if (-not $m.Success) { $m = [regex]::Match($t, '[?&]pageId=(\d+)') }
    if (-not $m.Success) { throw "Не удалось извлечь ID из '$Target'" }
    $ids.Add($m.Groups[1].Value)
}
if ($Recurse) {
    $root = $ids[0]
    $cql = [uri]::EscapeDataString("ancestor = $root and type = page")
    $seen = @{ $root = 1 }
    $st = 0
    while ($true) {
        $j = Api-Get ($CONTENT + "search?limit=200&start=$st&cql=$cql")
        if (-not $j -or $j.results.Count -eq 0) { break }
        foreach ($r in $j.results) { $rid = [string]$r.id; if (-not $seen.ContainsKey($rid)) { $seen[$rid] = 1; $ids.Add($rid) } }
        $st += 200
        if ($st -gt 20000) { break }
        Start-Sleep -Milliseconds 150
    }
}
if ($Limit -gt 0 -and $ids.Count -gt $Limit) { $ids = @($ids | Select-Object -First $Limit) }

W ("страниц: {0}; меняем «{1}» -> «{2}»; режим: {3}" -f $ids.Count, ($From -join '», «'), $To, $(if ($Apply) { 'ЗАПИСЬ' } else { 'DRY RUN' }))
if ($excludeSet.Count) { W ("не трогаем userkey: " + ($excludeSet -join ', ')) }
W ''

$changed = 0; $same = 0; $pagesTouched = 0; $errors = 0; $skipped = 0

foreach ($pageId in $ids) {
    $pg = $null
    $pg = $null
    try { $pg = Api-Get "$CONTENT$pageId`?expand=body.storage" }
    catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -eq 0 -and $_.Exception.Message -match '\((\d{3})\)') { $code = [int]$Matches[1] }
        if ($code -eq 404) { $skipped++; continue }   # не страница (вложение/удалено) — не наша
        $errors++; W ("$pageId : не прочитана (" + $code + ")")
        continue
    }
    $html = $pg.body.storage.value
    if ($html -notmatch 'Согласующ') { continue }

    $targetIdForPage = $null
    $touched = $false
    foreach ($rm in $rowRx.Matches($html)) {
        $cc = @($cellRx.Matches($rm.Groups[1].Value)); if ($cc.Count -lt 2) { continue }
        $lab = Norm $cc[0].Groups[2].Value
        if ($lab -notmatch '^\d+\.\s*Согласующ') { continue }
        $uk = ([regex]::Match($rm.Value, 'ri:userkey="([^"]+)"')).Groups[1].Value
        if ($uk -and ($excludeSet -contains $uk)) { continue }
        $mid = ([regex]::Match($rm.Value, 'ac:name="id">(\d+)<')).Groups[1].Value
        if (-not $mid) { continue }
        $cur = Get-Status $mid $pageId
        if (-not $cur) { continue }
        if ($From -notcontains $cur.Name) { $same++; continue }
        if (-not $targetIdForPage) { $targetIdForPage = Resolve-StatusId $mid $pageId $To }
        if (-not $targetIdForPage) { $errors++; W ("$pageId : в наборе нет статуса «$To»"); continue }
        $changed++
        if (-not $touched) { $touched = $true; $pagesTouched++ }
        W ("{0} : {1}  «{2}» -> «{3}»" -f $pageId, $lab, $cur.Name, $To)
        if ($Apply) {
            try { [void](Api-PutForm "$HANDY/status-macro/$mid/value" "contentId=$pageId&statusId=$targetIdForPage") }
            catch { $errors++; W ("   ошибка записи: " + $_.Exception.Message) }
        }
        Start-Sleep -Milliseconds 80
    }
    Start-Sleep -Milliseconds 100
}

W ''
W ("ИТОГО: изменено {0}, остальных согласующих без изменений {1}, страниц затронуто {2}, ошибок {3}, пропущено не-страниц {4}" -f $changed, $same, $pagesTouched, $errors, $skipped)
if (-not $Apply) { W 'DRY RUN: ничего не записано. Для записи добавьте -Apply.' }
[System.IO.File]::WriteAllLines($Log, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("лог: $Log")
