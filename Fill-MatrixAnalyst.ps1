<#
.SYNOPSIS
    Заполняет колонку «Аналитик» в матрице из поля «Аналитик» страницы-источника.
.DESCRIPTION
    Колонка «Аналитик» должна быть в шапке матрицы. Скрипт:
      * находит источник строки (ссылка /pages/N или ?pageId=N; короткая /x/...; ri:page по названию);
      * читает на источнике первую строку с подписью «Аналитик» и берёт оттуда userkey;
      * вставляет в строку матрицы ячейку со ссылкой на пользователя (или пустую, если поля нет).
    Нужно из-за того, что после добавления колонки в шапку в строках данных ячейки не появились
    (строки и шапка разъехались по колонкам).
    По умолчанию DRY RUN, для записи -Apply.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [string]$Column = 'Аналитик',
    [string]$Field = 'Аналитик',
    [switch]$Apply,
    [string]$Log = "$env:TEMP\fill-analyst.log"
)

$ErrorActionPreference = 'Stop'
trap {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host ('  строка ' + $_.InvocationInfo.ScriptLineNumber + ': ' + (($_.InvocationInfo.Line) -replace '^\s+', '').Trim()) -ForegroundColor DarkGray }
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
function Api-PutJson([string]$Uri, $Obj) {
    $json = $Obj | ConvertTo-Json -Depth 20 -Compress
    $b = [Text.Encoding]::UTF8.GetBytes($json)
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'PUT'; $req.ContentType = 'application/json; charset=utf-8'
    $req.Headers.Add('Authorization', $auth); $req.ContentLength = $b.Length
    $st = $req.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close()
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
    return ($t | ConvertFrom-Json)
}
function Norm([string]$s) {
    $t = [System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ' '))
    $t = ($t -replace [string][char]0x00A0, ' ') -replace '\s+', ' '
    return $t.Trim()
}
function PageRef([string]$s) {
    $m = [regex]::Match($s, '/pages/(\d+)'); if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($s, '[?&]pageId=(\d+)'); if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Resolve-Tiny([string]$tok) {
    $req = [System.Net.HttpWebRequest]::Create("$base/pages/tinyurl.action?urlIdentifier=$tok")
    $req.Method = 'GET'; $req.AllowAutoRedirect = $false
    $req.Headers.Add('Authorization', $auth)
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120'
    $loc = ''
    try { $r = $req.GetResponse(); $loc = $r.Headers['Location']; $r.Close() }
    catch { if ($_.Exception.Response) { $loc = $_.Exception.Response.Headers['Location'] } }
    if ($loc -match '/pages/(\d+)') { return $Matches[1] }
    return ''
}
function Resolve-ByTitle([string]$title, [string]$spaceKey) {
    try {
        $cql = 'title = "' + ($title -replace '\\', '\\\\' -replace '"', '\"') + '"' + $(if ($spaceKey) { ' AND space = "' + $spaceKey + '"' } else { '' })
        $j = Api-Get ($CONTENT + 'search?limit=2&cql=' + [uri]::EscapeDataString($cql))
        if ($j -and $j.results -and $j.results.Count -gt 0) { return [string]$j.results[0].id }
    } catch { }
    return ''
}
function Resolve-Source([string]$cellHtml, [string]$spaceKey) {
    $id = PageRef $cellHtml
    if ($id) { return $id }
    $sh = [regex]::Match($cellHtml, '/x/([A-Za-z0-9_-]{4,})')
    if ($sh.Success) { return (Resolve-Tiny $sh.Groups[1].Value) }
    $ti = [regex]::Match($cellHtml, 'ri:content-title="([^"]+)"')
    if ($ti.Success) { return (Resolve-ByTitle ([System.Net.WebUtility]::HtmlDecode($ti.Groups[1].Value)) $spaceKey) }
    return ''
}

$rowRx  = [regex]'(?s)<tr[^>]*>[\s\S]*?</tr>'
$cellRx = [regex]'(?s)<t[dh]([^>]*)>([\s\S]*?)</t[dh]>'

$out = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $out.Add($s); Write-Output $s }

$targetId = $Target
if ($targetId -notmatch '^\d+$') {
    $m = [regex]::Match($Target, '/pages/(\d+)'); if (-not $m.Success) { $m = [regex]::Match($Target, '[?&]pageId=(\d+)') }
    if (-not $m.Success) { throw "Не удалось извлечь ID из '$Target'" }
    $targetId = $m.Groups[1].Value
}

$pg = Api-Get "$CONTENT$targetId`?expand=body.storage,version,space"
$html = $pg.body.storage.value
$spaceKey = $pg.space.key
W ("матрица {0} v{1} «{2}»" -f $targetId, $pg.version.number, $pg.title)
W ("колонка «{0}», поле источника «{1}»; режим: {2}" -f $Column, $Field, $(if ($Apply) { 'ЗАПИСЬ' } else { 'DRY RUN' }))
W ''

$srcRows = @($rowRx.Matches($html))
$hdrIdx = -1; $best = 0
for ($i = 0; $i -lt $srcRows.Count; $i++) {
    $keys = @([regex]::Matches($srcRows[$i].Value, 'ri:userkey="([^"]+)"'))
    if ($keys.Count -gt $best) { $best = $keys.Count; $hdrIdx = $i }
}
if ($hdrIdx -lt 0) { throw 'Не найдена шапка с согласующими' }

# проверяем, что колонка есть в шапке
$capCol = -1; $col = 0
foreach ($c in $cellRx.Matches([regex]::Match($srcRows[0].Value, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value)) {
    $cs = [regex]::Match($c.Groups[1].Value, 'colspan="(\d+)"'); $span = if ($cs.Success) { [int]$cs.Groups[1].Value } else { 1 }
    if ((Norm $c.Groups[2].Value) -eq $Column) { $capCol = $col }
    $col += $span
}
if ($capCol -lt 0) { throw "В шапке нет колонки «$Column»" }
W ("колонка «{0}» в шапке на позиции {1}" -f $Column, $capCol)
W ''

$edits = New-Object System.Collections.Generic.List[object]
$filled = 0; $empty = 0; $noSrc = 0; $sameCount = 0

for ($r = $hdrIdx + 1; $r -lt $srcRows.Count; $r++) {
    $tr = $srcRows[$r].Value
    $cc = @($cellRx.Matches([regex]::Match($tr, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value))
    if ($cc.Count -lt 15) { continue }
    $num = Norm $cc[0].Groups[2].Value
    if ($num -notmatch '^\d+$') { continue }

    $srcId = Resolve-Source $cc[1].Groups[2].Value $spaceKey
    if (-not $srcId) { $srcId = Resolve-ByTitle (Norm $cc[1].Groups[2].Value) $spaceKey }
    if (-not $srcId) { $noSrc++; W ("стр.{0}: источник не найден — пустая" -f $num) }

    $uks = @()
    if ($srcId) {
        $sp = $null
        try { $sp = Api-Get "$CONTENT$srcId`?expand=body.storage" } catch { $sp = $null }
        if ($sp) {
            foreach ($rm in $rowRx.Matches($sp.body.storage.value)) {
                $c2 = @($cellRx.Matches([regex]::Match($rm.Value, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value))
                if ($c2.Count -lt 2) { continue }
                if ((Norm $c2[0].Groups[2].Value) -eq $Field) {
                    $uks = @([regex]::Matches($c2[1].Groups[2].Value, 'ri:userkey="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
                    break
                }
            }
        } else { $noSrc++ }
    }

    if ($uks.Count) {
        $cellHtml = '<td>' + (($uks | ForEach-Object { '<ac:link><ri:user ri:userkey="' + $_ + '" /></ac:link>' }) -join ', ') + '</td>'
    } else {
        $cellHtml = '<td><br /></td>'
    }
    # ячейка колонки: если её нет — вставляем после 2-й (номер + наименование), если есть — заменяем
    $innerM = [regex]::Match($tr, '(?s)<tr[^>]*>([\s\S]*?)</tr>')
    $cellMatches = @([regex]::Matches($innerM.Groups[1].Value, '(?s)<t[dh]([^>]*)>([\s\S]*?)</t[dh]>'))

    if ($cellMatches.Count -gt $capCol) {
        $cm = $cellMatches[$capCol]
        $curInner = $cm.Groups[2].Value
        $curKeys = @([regex]::Matches($curInner, 'ri:userkey="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ((($curKeys -join ',') -eq ($uks -join ','))) {
            $sameCount++
            W ("стр.{0}: уже «{1}»" -f $num, (($uks | ForEach-Object { $_ }) -join ','))
            continue
        }
        $innerStart = $innerM.Index + $innerM.Value.IndexOf('>') + 1
        $absStart = $innerStart + $cm.Index
        $absEnd = $absStart + $cm.Value.Length
        $newTr = $tr.Substring(0, $absStart) + $cellHtml + $tr.Substring($absEnd)
    } else {
        $re = [regex]'</td>'; $c3 = 0; $pos = -1
        foreach ($mm in $re.Matches($tr)) { $c3++; if ($c3 -eq 2) { $pos = $mm.Index + $mm.Length; break } }
        if ($pos -lt 0) { continue }
        $newTr = $tr.Substring(0, $pos) + $cellHtml + $tr.Substring($pos)
    }
    $edits.Add([pscustomobject]@{ Old = $tr; New = $newTr })

    if ($uks.Count) {
        $filled++
        $names = @($uks | ForEach-Object { try { (Api-Get "$base/rest/api/user?key=$_").displayName } catch { $_ } })
        W ("стр.{0}: «{1}»" -f $num, ($names -join ', '))
        Start-Sleep -Milliseconds 100
    }
    else { $empty++; W ("стр.{0}: (пусто — поля «{1}» нет)" -f $num, $Field) }
    Start-Sleep -Milliseconds 150
}

W ''
W ("ИТОГО: заполнено {0}, уже было {3}, пустых {1}, источник не найден {2}; правок строк {4}" -f $filled, $empty, $noSrc, $sameCount, $edits.Count)

if (-not $Apply) { W 'DRY RUN: ничего не записано. Для записи добавьте -Apply.' }
elseif ($edits.Count -gt 0) {
    foreach ($e in $edits) { $html = $html.Replace($e.Old, $e.New) }
    $fresh = Api-Get "$CONTENT$targetId`?expand=version"
    $res = Api-PutJson "$CONTENT$targetId" @{
        id = $targetId; type = 'page'; title = $fresh.title
        version = @{ number = [int]$fresh.version.number + 1; message = 'fill analyst column'; minorEdit = $true }
        body = @{ storage = @{ representation = 'storage'; value = $html } }
    }
    W ("ЗАПИСАНО: v{0}" -f $res.version.number)
}

[System.IO.File]::WriteAllLines($Log, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("лог: $Log")
