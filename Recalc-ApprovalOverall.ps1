<#
.SYNOPSIS
    Пересчитывает «08.01. Общий статус согласования» по статусам согласующих.
.DESCRIPTION
    Правило (подтверждено заказчиком):
      * у всех «Согласован»        -> «Согласован»
      * у всех «На корректировке»  -> «На корректировке»
      * иначе                      -> «На согласовании»
    Статус указанного пользователя (по умолчанию Ivanov I.) не учитывается.
    Статусы ищутся по ИМЕНИ в наборе статусов страницы (id в пространствах разные).

    По умолчанию DRY RUN, для записи -Apply.
.PARAMETER Target
    ID/URL страницы ФТТ или корневой страницы (с -Recurse).
.PARAMETER Recurse
    Обойти дочерние страницы.
.PARAMETER Exclude
    userkey'и, чьи статусы не учитывать (через запятую).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\confluence-tools\Recalc-ApprovalOverall.ps1" -Target 123456791 -Recurse -Apply -Log "$env:TEMP\opencode\recalc-tree-apply.log"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [switch]$Apply,
    [switch]$Recurse,
    [int]$Limit = 0,
    [string]$Exclude = '',
    [string]$CredsPath = "$env:LOCALAPPDATA\confluence-mcp\creds.dat",
    [string]$Log = "$env:TEMP\recalc-overall.log"
)

$ErrorActionPreference = 'Stop'

# при запуске через -File окно закрывается на любой ошибке — показываем причину и ждём Enter
trap {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host ('  файл: ' + $_.InvocationInfo.ScriptName) -ForegroundColor Red
        Write-Host ('  строка ' + $_.InvocationInfo.ScriptLineNumber + ': ' + (($_.InvocationInfo.Line) -replace '^\s+', '').Trim()) -ForegroundColor DarkGray
    }
    if ($_.Exception.Response) {
        try {
            $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            Write-Host ('  ответ сервера: ' + $sr.ReadToEnd()) -ForegroundColor DarkYellow
            $sr.Close()
        } catch { }
    }
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Enter — закрыть' }
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE } elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { 'https://confluence.example.com' }
$base = $base.TrimEnd('/')
$token = if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT } elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN } else {
    $credPath = $CredsPath
    if (-not (Test-Path -LiteralPath $credPath)) {
        Write-Host ("  LOCALAPPDATA = " + $env:LOCALAPPDATA) -ForegroundColor DarkGray; Write-Host ("  пользователь  = " + [System.Environment]::UserName) -ForegroundColor DarkGray; throw "Нет файла $credPath. Для другого пользователя задайте переменную окружения CONFLUENCE_PAT (PAT-токен): creds.dat зашифрован DPAPI под исходного пользователя и чужим не читается."
    }
    try {
        $e = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
        $s = $e.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
        [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    } catch {
        throw "Не удалось расшифровать $credPath (DPAPI привязан к пользователю и машине). Задайте переменную CONFLUENCE_PAT с PAT-токеном."
    }
}
if (-not $token) { throw 'Пустой токен: задайте CONFLUENCE_PAT.' }

# папка для лога может отсутствовать у другого пользователя
$logDir = Split-Path -Parent $Log
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
$auth = "Bearer $token"
$HANDY = "$base/rest/handy-macros/2.0"
$CONTENT = "$base/rest/api/content/"

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
    # плоский список потомков через CQL (быстрее, чем обход детей по одному)
    $root = $ids[0]
    $cql = [uri]::EscapeDataString("ancestor = $root and type = page")
    $seen = @{ $root = 1 }
    $st = 0
    while ($true) {
        $j = Api-Get ($CONTENT + "search?limit=200&start=$st&cql=$cql")
        if (-not $j -or $j.results.Count -eq 0) { break }
        foreach ($r in $j.results) {
            $rid = [string]$r.id
            if (-not $seen.ContainsKey($rid)) { $seen[$rid] = 1; $ids.Add($rid) }
        }
        $st += 200
        if ($st -gt 20000) { break }
        Start-Sleep -Milliseconds 150
    }
}
if ($Limit -gt 0 -and $ids.Count -gt $Limit) { $ids = @($ids | Select-Object -First $Limit) }

W ("страниц к обработке: " + $ids.Count + "; режим: " + $(if ($Apply) { 'ЗАПИСЬ' } else { 'DRY RUN' }))
W ("исключаются userkey: " + ($excludeSet -join ', '))
W ''

$changed = 0; $same = 0; $skipped = 0; $errors = 0

foreach ($pageId in $ids) {
    $pg = $null
    $pg = $null
    try { $pg = Api-Get "$CONTENT$pageId`?expand=body.storage,version" }
    catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -eq 404) { $skipped++; continue }
        $errors++; W ("$pageId : не прочитана"); continue
    }
    $html = $pg.body.storage.value

    # собираем 08.01 и согласующих
    $overallMid = ''; $overallCell = $null; $approvers = @()
    foreach ($rm in $rowRx.Matches($html)) {
        $cc = @($cellRx.Matches($rm.Groups[1].Value)); if ($cc.Count -lt 2) { continue }
        $lab = Norm $cc[0].Groups[2].Value
        if ($lab -match '^08\.01') { $overallCell = $cc[1]; $overallMid = ([regex]::Match($cc[1].Groups[2].Value, 'ac:name="id">(\d+)<')).Groups[1].Value; continue }
        if ($lab -match '^\d+\.\s*Согласующ') {
            $uk = ([regex]::Match($rm.Groups[1].Value, 'ri:userkey="([^"]+)"')).Groups[1].Value
            $mid = ([regex]::Match($rm.Groups[1].Value, 'ac:name="id">(\d+)<')).Groups[1].Value
            if ($uk -and $mid) { $approvers += [pscustomobject]@{ Uk = $uk; Mid = $mid } }
        }
    }
    if (-not $overallMid) { $skipped++; continue }

    # статусы согласующих (по имени), исключая заданных
    $sts = @()
    foreach ($a in $approvers) {
        if ($excludeSet -contains $a.Uk) { continue }
        try { $j = Api-Get "$HANDY/status-macro/$($a.Mid)`?contentId=$pageId" } catch { continue }
        if ($j -and $j.status) { $sts += [string]$j.status.name }
        Start-Sleep -Milliseconds 40
    }
    if (-not $sts.Count) { $skipped++; W ("$pageId : нет согласующих (кроме исключённых) — пропуск"); continue }

    # правило (подтверждено заказчиком):
    #   все «Согласован»                                     -> «Согласован»
    #   все «На корректировке»                               -> «На корректировке»
    #   у кого-то «Комментарии даны»/«На корректировке»,
    #     а остальные «Согласован»                           -> «На корректировке»
    #   иначе                                                -> «На согласовании»
    $corrNames = @('Комментарии даны', 'На корректировке')
    $allApproved = @($sts | Where-Object { $_ -ne 'Согласован' }).Count -eq 0
    $allCorr     = @($sts | Where-Object { $_ -ne 'На корректировке' }).Count -eq 0
    $onlyApprovedOrCorr = @($sts | Where-Object { $_ -ne 'Согласован' -and $corrNames -notcontains $_ }).Count -eq 0
    $hasCorr     = @($sts | Where-Object { $corrNames -contains $_ }).Count -gt 0
    $wantName = if ($allApproved) { 'Согласован' }
                elseif ($allCorr) { 'На корректировке' }
                elseif ($hasCorr -and $onlyApprovedOrCorr) { 'На корректировке' }
                else { 'На согласовании' }

    $cur = $null
    try { $cj = Api-Get "$HANDY/status-macro/$overallMid`?contentId=$pageId" } catch { }
    if ($cj -and $cj.status) { $cur = [pscustomobject]@{ Id = [int]$cj.status.id; Name = [string]$cj.status.name } }

    # отменённый документ не переводим в «На согласовании»
    if ($cur -and $cur.Name -eq 'Отменен') { $skipped++; W ("$pageId : текущий статус «Отменен» — не трогаем"); continue }

    $mark = ''
    if ($cur -and $cur.Name -eq $wantName) { $same++; $mark = ' = (уже ' + $cur.Name + ')' }
    else {
        # id нужного статуса берём из набора статусов этой пилюли (по имени)
        $wantId = $null
        try {
            $opts = Api-Raw "$HANDY/status-macro/$overallMid/options/aui-dropdown?contentId=$pageId"
            $oj = $opts | ConvertFrom-Json
            foreach ($sec0 in $oj) {
                foreach ($it in $sec0.items) {
                    $c0 = [string]$it.content
                    $sid0 = ([regex]::Match($c0, 'data-status="(\d+)"')).Groups[1].Value
                    $nm0 = ([System.Net.WebUtility]::HtmlDecode(($c0 -replace '(?s)^.*?data-status="\d+"[^>]*>', '' -replace '</a>.*$', '' -replace '<[^>]+>', ' ' -replace '\s+', ' '))).Trim()
                    if ($nm0 -eq $wantName) { $wantId = $sid0; break }
                }
                if ($wantId) { break }
            }
        } catch { }
        if (-not $wantId) { $errors++; W ("$pageId : в наборе нет статуса «$wantName» — пропуск"); continue }
        $changed++
        W ("{0} : «{1}» -> «{2}»  [согласующих {3}: {4}]" -f $pageId, $(if ($cur) { $cur.Name } else { '?' }), $wantName, $sts.Count, (($sts | Group-Object | ForEach-Object { $_.Name + '×' + $_.Count }) -join ', '))
        if ($Apply) {
            try { [void](Api-PutForm "$HANDY/status-macro/$overallMid/value" "contentId=$pageId&statusId=$wantId") }
            catch { $errors++; W ("     ошибка записи: " + $_.Exception.Message) }
        }
    }
    Start-Sleep -Milliseconds 120
}

W ''
W ("ИТОГО: изменено $changed, без изменений $same, пропущено $skipped, ошибок $errors")
if (-not $Apply) { W 'DRY RUN: ничего не записано. Для записи добавьте -Apply.' }
[System.IO.File]::WriteAllLines($Log, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("лог: $Log")
