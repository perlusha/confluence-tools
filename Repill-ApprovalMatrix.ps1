<#
.SYNOPSIS
    Чистит «призраки» пилюль в матрице согласования: заменяет ячейки на актуальные
    экземпляры со страниц-источников (ФТТ).
.DESCRIPTION
    Причина: macroid пилюли на странице ФТТ могли пересоздать. Матрица при этом продолжает
    ссылаться на старые экземпляры — они не отображаются, статус перенести некуда.
    Скрипт по каждой строке берёт ФТТ по ссылке и сверяет macroid ячеек:
      блок (03), область (04), общий статус (08.01), согласующие (по userkey).
    Где macroid другой — ячейка заменяется на актуальную; где пилюли в источнике нет — очищается.
    По умолчанию DRY RUN, для записи -Apply.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [switch]$Apply,
    [int]$Limit = 0,
    [string]$Log = "$env:TEMP\repill-matrix.log"
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
function PillId([string]$s) { $m = [regex]::Match($s, 'ac:name="id">(\d+)<'); if ($m.Success) { return $m.Groups[1].Value } return '' }
function PillCell([string]$mid) {
    '<td><ac:structured-macro ac:name="status-handy" ac:schema-version="1"><ac:parameter ac:name="id">' + $mid + '</ac:parameter></ac:structured-macro></td>'
}

$rowRx = [regex]'(?s)<tr[^>]*>[\s\S]*?</tr>'
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
W ("матрица {0} v{1} «{2}»; режим: {3}" -f $targetId, $pg.version.number, $pg.title, $(if ($Apply) { 'ЗАПИСЬ' } else { 'DRY RUN' }))
W ''

$srcRows = @($rowRx.Matches($html))

# шапка: строка с максимумом userkey + подписи колонок
$hdrIdx = -1; $best = 0; $colKeys = @()
for ($i = 0; $i -lt $srcRows.Count; $i++) {
    $keys = @([regex]::Matches($srcRows[$i].Value, 'ri:userkey="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($keys.Count -gt $best) { $best = $keys.Count; $hdrIdx = $i; $colKeys = $keys }
}
if ($hdrIdx -lt 0) { throw 'Не найдена шапка с согласующими' }

$capCol = @{}
$col = 0
foreach ($c in $cellRx.Matches([regex]::Match($srcRows[0].Value, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value)) {
    $cs = [regex]::Match($c.Groups[1].Value, 'colspan="(\d+)"'); $span = if ($cs.Success) { [int]$cs.Groups[1].Value } else { 1 }
    $capCol[(Norm $c.Groups[2].Value)] = $col
    $col += $span
}
$cBlock = $capCol['Функциональный блок']
$cArea = $capCol['Функциональная область']
$cOverall = $capCol['Общий статус согласования']
W ("колонки: блок={0}, область={1}, общий={2}, согласующих {3}" -f $cBlock, $cArea, $cOverall, $colKeys.Count)
W ''

$srcCache = @{}
$rowsChecked = 0; $rowsChanged = 0; $cellsChanged = 0; $errors = 0

for ($r = $hdrIdx + 1; $r -lt $srcRows.Count; $r++) {
    $tr = $srcRows[$r].Value
    $innerM = [regex]::Match($tr, '(?s)<tr[^>]*>([\s\S]*?)</tr>')
    $cells = @([regex]::Matches($innerM.Groups[1].Value, '(?s)<t[dh]([^>]*)>([\s\S]*?)</t[dh]>'))
    if ($cells.Count -lt 15) { continue }
    $num = Norm $cells[0].Groups[2].Value
    if ($num -notmatch '^\d+$') { continue }
    $rowsChecked++
    if ($Limit -gt 0 -and $rowsChecked -gt $Limit) { break }

    $m1 = [regex]::Match($cells[1].Groups[2].Value, '(?:pageId=|/pages/)(\d+)')
    if (-not $m1.Success) { continue }
    $srcId = $m1.Groups[1].Value
    if ($srcId -eq $targetId) { continue }

    if (-not $srcCache.ContainsKey($srcId)) {
        $sp = $null
        try { $sp = Api-Get "$CONTENT$srcId`?expand=body.storage" } catch { $sp = $null }
        $map = $null
        if ($sp) {
            $map = @{ block = ''; area = ''; overall = ''; users = @{} }
            foreach ($rm in $rowRx.Matches($sp.body.storage.value)) {
                $cc = @($cellRx.Matches([regex]::Match($rm.Value, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value))
                if ($cc.Count -lt 2) { continue }
                $lab = Norm $cc[0].Groups[2].Value
                if ($lab -match '^\d+\.\s*Согласующ') {
                    $uk = ([regex]::Match($rm.Value, 'ri:userkey="([^"]+)"')).Groups[1].Value
                    $mid = PillId $cc[1].Groups[2].Value
                    if ($uk -and $mid -and -not $map.users.ContainsKey($uk)) { $map.users[$uk] = $mid }
                    continue
                }
                if ($lab -match '^03\.' -and -not $map.block) { $map.block = PillId $cc[1].Groups[2].Value; continue }
                if ($lab -match '^04\.' -and -not $map.area) { $map.area = PillId $cc[1].Groups[2].Value; continue }
                if ($lab -match '^08\.01' -and -not $map.overall) { $map.overall = PillId $cc[1].Groups[2].Value; continue }
            }
        }
        $srcCache[$srcId] = $map
        Start-Sleep -Milliseconds 80
    }
    $srcMap = $srcCache[$srcId]
    if (-not $srcMap) { $errors++; W ("стр.{0}: источник {1} не прочитан" -f $num, $srcId); continue }

    # желаемое содержимое ячеек: (индекс ячейки) -> mid или '' (очистить)
    $want = @{}
    if ($null -ne $cBlock -and $cBlock -lt $cells.Count) { $want[$cBlock] = $srcMap.block }
    if ($null -ne $cArea -and $cArea -lt $cells.Count) { $want[$cArea] = $srcMap.area }
    for ($k = 0; $k -lt $colKeys.Count; $k++) {
        $ci = $cells.Count - $colKeys.Count + $k
        if ($ci -lt 1 -or $ci -ge $cells.Count) { continue }
        $want[$ci] = $srcMap.users[$colKeys[$k]]
    }

    $changedCells = New-Object System.Collections.Generic.List[string]
    $newTr = $tr
    $innerStart = $innerM.Index + $innerM.Value.IndexOf('>') + 1
    foreach ($ci in ($want.Keys | Sort-Object -Descending)) {
        $cm = $cells[$ci]
        $curMid = PillId $cm.Groups[2].Value
        $wantMid = [string]$want[$ci]
        if ($curMid -eq $wantMid) { continue }
        $newCell = if ($wantMid) { PillCell $wantMid } else { '<td>-</td>' }
        $absStart = $innerStart + $cm.Index
        $absEnd = $absStart + $cm.Value.Length
        $newTr = $newTr.Substring(0, $absStart) + $newCell + $newTr.Substring($absEnd)
        $cellsChanged++
        $changedCells.Add(("[{0}] {1} -> {2}" -f $ci, $(if ($curMid) { $curMid } else { '—' }), $(if ($wantMid) { $wantMid } else { 'пусто' })))
    }

    if ($changedCells.Count) {
        $rowsChanged++
        W ("стр.{0} (источник {1}): {2}" -f $num, $srcId, ($changedCells -join '; '))
        if (-not $Apply) { continue }
        # заменяем строку в общем html
        $html = $html.Replace($tr, $newTr)
    }
    Start-Sleep -Milliseconds 60
}

W ''
W ("ИТОГО: строк проверено {0}, изменено строк {1}, ячеек {2}, ошибок {3}" -f $rowsChecked, $rowsChanged, $cellsChanged, $errors)

if (-not $Apply) { W 'DRY RUN: ничего не записано. Для записи добавьте -Apply.' }
elseif ($rowsChanged -gt 0) {
    $fresh = Api-Get "$CONTENT$targetId`?expand=version"
    $res = Api-PutJson "$CONTENT$targetId" @{
        id = $targetId; type = 'page'; title = $fresh.title
        version = @{ number = [int]$fresh.version.number + 1; message = 'repill matrix cells from sources'; minorEdit = $true }
        body = @{ storage = @{ representation = 'storage'; value = $html } }
    }
    W ("ЗАПИСАНО: v{0}" -f $res.version.number)
}

[System.IO.File]::WriteAllLines($Log, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("лог: $Log")
