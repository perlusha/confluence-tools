<#
.SYNOPSIS
    Синхронизация статусов согласования из источников в сводную матрицу.
.DESCRIPTION
    Для каждой строки матрицы:
      * находит страницу-источник по ссылке (/pages/N, ?pageId=N, ri:page; короткая /x/T —
        по тексту ссылки, т.к. с PAT нереREST-URL уходит на страницу логина);
      * читает строки «NN. Согласующий N» и поля 03./04./08.01;
      * статус человека в матрице приводит к источнику (меняет / создаёт пилюлю);
      * если в источнике строки согласующего нет — ячейку матрицы ОЧИЩАЕТ.

    ВАЖНО про колонки: шапка разворачивается в сетку с учётом colspan/rowspan, и колонка
    берётся по НОМЕРУ КОЛОНКИ, а не по порядку ячеек. Иначе таблица, где у одной из
    колонок согласующего нет ri:userkey (или есть colspan), сдвигает всё на колонку.

    Тело страницы пишется ОДНИМ PUT (version + 1) только если были правки.
    По умолчанию DRY RUN, для записи -Apply.
.PARAMETER Target
    ID или URL целевой (сводной) страницы.
.PARAMETER Apply
    Записать изменения.
.PARAMETER Limit
    Обработать только первые N строк с найденным источником (для проверки).
.EXAMPLE
    .\Sync-ConfluenceApprovalStatus.ps1 -Target 123456793
    .\Sync-ConfluenceApprovalStatus.ps1 -Target 123456793 -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [switch]$Apply,
    [int]$Limit = 0,
    [string]$Log = "$env:TEMP\sync-approval.log"
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE }
        elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL }
        else { 'https://confluence.example.com' }
$base = $base.TrimEnd('/')

$token = if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT }
         elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN }
         else {
             $enc = Get-Content "$env:LOCALAPPDATA\confluence-mcp\creds.dat" -Raw | ConvertFrom-Json
             $sec = $enc.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
             [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
         }
if (-not $token) { throw 'Не задан токен (CONFLUENCE_PAT / CONFLUENCE_PERSONAL_TOKEN или creds.dat).' }

$auth = "Bearer $token"
$HANDY = "$base/rest/handy-macros/2.0"
$CONTENT = "$base/rest/api/content/"

function Api-Get([string]$Uri) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('Authorization', $auth)
    $wc.Headers.Add('Accept', 'application/json')
    try { return ($wc.DownloadString($Uri) | ConvertFrom-Json) } finally { $wc.Dispose() }
}
function Api-Form([string]$Method, [string]$Uri, [string]$Body, [int]$Retry = 3) {
    for ($i = 1; $i -le $Retry; $i++) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = $Method; $req.ContentType = 'application/x-www-form-urlencoded'
        $req.Headers.Add('Authorization', $auth)
        $req.Headers.Add('X-Atlassian-Token', 'no-check')
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        try {
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return $txt.Trim()
        } catch {
            if ($i -eq $Retry) { throw }
            Start-Sleep -Milliseconds (400 * $i)
        }
    }
}
function Api-PostForm([string]$Uri, [string]$Body) { return (Api-Form 'POST' $Uri $Body) }
function Api-PutForm([string]$Uri, [string]$Body) { return (Api-Form 'PUT' $Uri $Body) }
function Api-PutJson([string]$Uri, $Obj) {
    $json = $Obj | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'PUT'; $req.ContentType = 'application/json; charset=utf-8'
    $req.Headers.Add('Authorization', $auth); $req.ContentLength = $bytes.Length
    $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
    return ($txt | ConvertFrom-Json)
}

$rowRx  = [regex]'(?s)<tr[^>]*>([\s\S]*?)</tr>'
$cellRx = [regex]'(?s)<t[dh]([^>]*)>([\s\S]*?)</t[dh]>'

function Get-Rows([string]$html) {
    $out = @()
    foreach ($m in $rowRx.Matches($html)) {
        $out += [pscustomobject]@{ InnerStart = $m.Index + $m.Value.IndexOf('>') + 1; Inner = $m.Groups[1].Value }
    }
    return $out
}
function Get-RawCells([string]$rowInner, [int]$base) {
    $out = @()
    foreach ($m in $cellRx.Matches($rowInner)) {
        $cs = 1; $a = [regex]::Match($m.Groups[1].Value, 'colspan="(\d+)"'); if ($a.Success) { $cs = [int]$a.Groups[1].Value }
        $rs = 1; $a2 = [regex]::Match($m.Groups[1].Value, 'rowspan="(\d+)"'); if ($a2.Success) { $rs = [int]$a2.Groups[1].Value }
        $out += [pscustomobject]@{
            Inner = $m.Groups[2].Value
            Start = $base + $m.Index
            End   = $base + $m.Index + $m.Value.Length
            ColSpan = $cs; RowSpan = $rs; Own = $true
        }
    }
    return $out
}
# разворачивает строки в сетку: для каждой строки — массив ячеек ПО КОЛОНКАМ (с учётом span)
function Expand-Grid($rows) {
    $pend = @{}
    $grid = @()
    foreach ($rr in $rows) {
        $raw = @(Get-RawCells $rr.Inner $rr.InnerStart)
        $line = New-Object System.Collections.Generic.List[object]
        $col = 0
        foreach ($c in $raw) {
            while ($pend.ContainsKey($col)) {
                $line.Add($pend[$col].Cell); $pend[$col].Left--
                if ($pend[$col].Left -le 0) { $pend.Remove($col) }
                $col++
            }
            for ($i = 0; $i -lt $c.ColSpan; $i++) {
                $line.Add($c)
                if ($c.RowSpan -gt 1) { $pend[$col] = @{ Cell = $c; Left = $c.RowSpan - 1 } }
                $col++
            }
        }
        while ($pend.ContainsKey($col)) {
            $line.Add($pend[$col].Cell); $pend[$col].Left--
            if ($pend[$col].Left -le 0) { $pend.Remove($col) }
            $col++
        }
        $grid += , ($line.ToArray())
    }
    return $grid
}
function Norm([string]$s) {
    $t = [System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ' '))
    $t = ($t -replace [string][char]0x00A0, ' ') -replace '\s+', ' '
    return $t.Trim()
}
function Userkey([string]$s) { $m = [regex]::Match($s, 'ri:userkey="([^"]+)"'); if ($m.Success) { return $m.Groups[1].Value } return '' }
function PillId([string]$s) { $m = [regex]::Match($s, 'ac:name="id">(\d+)<'); if ($m.Success) { return $m.Groups[1].Value } return '' }
function Esc([string]$s) { return ([string]$s).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }
function PillCell([string]$name, [string]$mid) {
    return '<td><ac:structured-macro ac:name="status-handy" ac:schema-version="1">' +
           '<ac:parameter ac:name="Status">' + (Esc $name) + '</ac:parameter>' +
           '<ac:parameter ac:name="id">' + $mid + '</ac:parameter></ac:structured-macro></td>'
}
# колонки пилюль по подписям (учитывает colspan в первой строке шапки)
function CaptionCols($firstRowCells) {
    $cols = @{}; $col = 0
    foreach ($c in $firstRowCells) {
        $cap = Norm $c.Inner
        if ($cap) { $cols[$cap] = $col }
        $col += $c.ColSpan
    }
    return $cols
}

$script:statusCache = @{}
function Get-Status([string]$mid, [string]$cid) {
    if (-not $mid) { return $null }
    $k = "$mid|$cid"
    if ($script:statusCache.ContainsKey($k)) { return $script:statusCache[$k] }
    $r = $null
    try {
        $j = Api-Get "$HANDY/status-macro/$mid`?contentId=$cid"
        if ($j -and $j.status -and $null -ne $j.status.id) { $r = [pscustomobject]@{ Id = [int]$j.status.id; Name = [string]$j.status.name } }
    } catch { $r = $null }
    $script:statusCache[$k] = $r
    return $r
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
    $m = [regex]::Match($cellHtml, '/pages/(\d+)'); if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($cellHtml, '[?&]pageId=(\d+)'); if ($m.Success) { return $m.Groups[1].Value }
    if ([regex]::IsMatch($cellHtml, '/x/[A-Za-z0-9_-]+')) { return '' }   # короткую ссылку разбираем по тексту
    $ti = [regex]::Match($cellHtml, 'ri:content-title="([^"]+)"')
    if ($ti.Success) { return (Resolve-ByTitle ([System.Net.WebUtility]::HtmlDecode($ti.Groups[1].Value)) $spaceKey) }
    return ''
}
function Get-SourceMap([string]$html) {
    $res = @{ Users = @{}; Block = ''; Area = ''; Overall = '' }
    $g = Expand-Grid (Get-Rows $html)
    foreach ($line in $g) {
        if ($line.Count -lt 2) { continue }
        $lab = Norm $line[0].Inner
        $val = $line[1].Inner
        if ($lab -match '^\d+\.\s*Согласующ') {
            $uk = Userkey (($line | ForEach-Object { $_.Inner }) -join ' ')
            $mid = PillId (($line | ForEach-Object { $_.Inner }) -join ' ')
            if ($uk -and $mid -and -not $res.Users.ContainsKey($uk)) { $res.Users[$uk] = $mid }
            continue
        }
        if ($lab -match '^03\.\s*Функциональный блок') { if (-not $res.Block) { $res.Block = PillId $val }; continue }
        if ($lab -match '^04\.') { if (-not $res.Area) { $res.Area = PillId $val }; continue }
        if ($lab -match '^08\.01') { if (-not $res.Overall) { $res.Overall = PillId $val }; continue }
    }
    return $res
}

# ------------------------------------------------------------------ прогон
$out = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $out.Add($s); Write-Output $s }

$targetId = $Target
if ($targetId -notmatch '^\d+$') {
    $m = [regex]::Match($Target, '/pages/(\d+)'); if (-not $m.Success) { $m = [regex]::Match($Target, '[?&]pageId=(\d+)') }
    if (-not $m.Success) { throw "Не удалось извлечь ID из '$Target'." }
    $targetId = $m.Groups[1].Value
}

$pg = Api-Get "$CONTENT$targetId`?expand=body.storage,version,space"
$html = $pg.body.storage.value
$spaceKey = $pg.space.key
W ("ЦЕЛЬ: {0} v{1} «{2}» (space {3})" -f $targetId, $pg.version.number, $pg.title, $spaceKey)
W ("РЕЖИМ: {0}{1}" -f $(if ($Apply) { 'ЗАПИСЬ' } else { 'DRY RUN' }), $(if ($Limit) { " (первые $Limit строк)" } else { '' }))
W ''

$rows = Get-Rows $html
$grid = Expand-Grid $rows

# шапка — строка, где больше всего userkey и нет пилюль; берём НОМЕРА КОЛОНОК
$hdr = $null
for ($i = 0; $i -lt $grid.Count; $i++) {
    $line = $grid[$i]
    $keyCol = @{}; $cnt = 0; $hasPill = $false
    for ($c = 0; $c -lt $line.Count; $c++) {
        $uk = Userkey $line[$c].Inner
        if ($uk) { $keyCol[$c] = $uk; $cnt++ }
        if ($line[$c].Inner.Contains('status-handy')) { $hasPill = $true }
    }
    if (-not $hasPill -and $cnt -ge 2 -and (-not $hdr -or $cnt -gt $hdr.Count)) {
        $hdr = [pscustomobject]@{ RowIndex = $i; KeyCol = $keyCol; Count = $cnt }
    }
}
if (-not $hdr) { throw 'Не найдена шапка с согласующими.' }
$firstCol = ($hdr.KeyCol.Keys | Measure-Object -Minimum).Minimum
$lastCol = ($hdr.KeyCol.Keys | Measure-Object -Maximum).Maximum
W ("шапка: строка {0}; колонок согласующих {1} (колонки {2}..{3}); ячеек в строке данных {4}" -f `
        ($hdr.RowIndex + 1), $hdr.Count, $firstCol, $lastCol, $grid[$hdr.RowIndex + 1].Count)
$anonymous = @($firstCol..$lastCol | Where-Object { -not $hdr.KeyCol.ContainsKey($_) })
if ($anonymous.Count) { W ("  колонки без userkey внутри блока: " + ($anonymous -join ', ')) }
W ''

$cols = CaptionCols $grid[0]
$srcCache = @{}
$edits = New-Object System.Collections.Generic.List[object]
$created = 0; $updated = 0; $cleared = 0; $rowsDone = 0

for ($r = $hdr.RowIndex + 1; $r -lt $grid.Count; $r++) {
    $line = $grid[$r]
    if ($line.Count -le $lastCol) { continue }
    $num = Norm $line[0].Inner
    if ($num -notmatch '^\d+$') { continue }
    $srcId = Resolve-Source $line[1].Inner $spaceKey
    if (-not $srcId) {
        $guess = Norm $line[1].Inner
        if ($guess) { $srcId = Resolve-ByTitle $guess $spaceKey }
    }
    if (-not $srcId) { W ("стр.{0}: источник не найден — пропуск" -f $num); continue }
    $rowsDone++
    if ($Limit -and $rowsDone -gt $Limit) { break }

    if (-not $srcCache.ContainsKey($srcId)) {
        $sPg = Api-Get "$CONTENT$srcId`?expand=body.storage"
        $srcCache[$srcId] = Get-SourceMap $sPg.body.storage.value
    }
    $map = $srcCache[$srcId]
    $rowLog = New-Object System.Collections.Generic.List[string]

    foreach ($c in ($hdr.KeyCol.Keys | Sort-Object)) {
        if ($c -ge $line.Count) { continue }
        $cell = $line[$c]
        if (-not $cell.Own) { continue }          # ячейка пришла из rowspan выше — не наша
        $uk = $hdr.KeyCol[$c]
        $smid = $map.Users[$uk]
        $tmid = PillId $cell.Inner
        if (-not $smid) {
            if ($tmid) {
                $have = Get-Status $tmid $targetId
                $edits.Add([pscustomobject]@{ Start = $cell.Start; End = $cell.End; Html = '<td><br /></td>' })
                $cleared++
                $rowLog.Add(("     колонка {0}: «{1}» -> пусто" -f $c, $(if ($have) { $have.Name } else { '?' })))
            }
            continue
        }
        $want = Get-Status $smid $srcId
        if (-not $want) { continue }
        if ($tmid) {
            $have = Get-Status $tmid $targetId
            if ($have -and $have.Id -ne $want.Id) {
                if ($Apply) { [void](Api-PutForm "$HANDY/status-macro/$tmid/value" "contentId=$targetId&statusId=$($want.Id)") }
                $updated++
                $rowLog.Add(("     колонка {0}: «{1}» -> «{2}»{3}" -f $c, $have.Name, $want.Name, $(if ($Apply) { '' } else { '  [план]' })))
            }
        } else {
            $mid = if ($Apply) { Api-PostForm "$HANDY/status-macro" "contentId=$targetId&statusId=$($want.Id)" } else { 'new' }
            if ($mid -match '^\d+$' -or $mid -eq 'new') {
                $edits.Add([pscustomobject]@{ Start = $cell.Start; End = $cell.End; Html = (PillCell $want.Name $mid) })
                $created++
                $rowLog.Add(("     колонка {0}: создана → «{1}»{2}" -f $c, $want.Name, $(if ($Apply) { '' } else { '  [план]' })))
            }
        }
    }

    $pillCols = @(
        @('Функциональный блок', 'Block', 'блок'),
        @('Функциональная область', 'Area', 'область'),
        @('Общий статус согласования', 'Overall', 'общий статус')
    )
    foreach ($pc in $pillCols) {
        if (-not $cols.ContainsKey($pc[0])) { continue }
        $c2 = $cols[$pc[0]]
        if ($c2 -ge $line.Count) { continue }
        $cell2 = $line[$c2]
        if (-not $cell2.Own) { continue }
        $smid2 = $map[$pc[1]]
        $tmid2 = PillId $cell2.Inner
        if (-not $smid2) {
            if ($tmid2) {
                $have = Get-Status $tmid2 $targetId
                $edits.Add([pscustomobject]@{ Start = $cell2.Start; End = $cell2.End; Html = '<td><br /></td>' })
                $cleared++
                $rowLog.Add(("     {0}: «{1}» -> пусто" -f $pc[2], $(if ($have) { $have.Name } else { '?' })))
            }
            continue
        }
        $want2 = Get-Status $smid2 $srcId
        if (-not $want2) { continue }
        if ($tmid2) {
            $have = Get-Status $tmid2 $targetId
            if ($have -and $have.Id -ne $want2.Id) {
                if ($Apply) { [void](Api-PutForm "$HANDY/status-macro/$tmid2/value" "contentId=$targetId&statusId=$($want2.Id)") }
                $updated++
                $rowLog.Add(("     {0}: «{1}» -> «{2}»{3}" -f $pc[2], $have.Name, $want2.Name, $(if ($Apply) { '' } else { '  [план]' })))
            }
        } else {
            $mid = if ($Apply) { Api-PostForm "$HANDY/status-macro" "contentId=$targetId&statusId=$($want2.Id)" } else { 'new' }
            if ($mid -match '^\d+$' -or $mid -eq 'new') {
                $edits.Add([pscustomobject]@{ Start = $cell2.Start; End = $cell2.End; Html = (PillCell $want2.Name $mid) })
                $created++
                $rowLog.Add(("     {0}: создана → «{1}»{2}" -f $pc[2], $want2.Name, $(if ($Apply) { '' } else { '  [план]' })))
            }
        }
    }

    if ($rowLog.Count) {
        W ("стр.{0} (источник {1}), правок {2}:" -f $num, $srcId, $rowLog.Count)
        foreach ($l in $rowLog) { W $l }
    }
}

W ''
W ("ИТОГО: обновлено $updated, создано $created, очищено $cleared, строк $rowsDone")

if ($edits.Count -gt 0) {
    if (-not $Apply) {
        W ("DRY RUN: правок разметки {0} — ничего не записано." -f $edits.Count)
    } else {
        foreach ($e in ($edits | Sort-Object -Property Start -Descending)) {
            $html = $html.Substring(0, $e.Start) + $e.Html + $html.Substring($e.End)
        }
        $fresh = Api-Get "$CONTENT$targetId`?expand=version"
        $payload = @{
            id = $targetId; type = 'page'; title = $fresh.title
            version = @{ number = [int]$fresh.version.number + 1; message = 'approval sync: add/clear statuses'; minorEdit = $true }
            body = @{ storage = @{ representation = 'storage'; value = $html } }
        }
        $res = Api-PutJson "$CONTENT$targetId" $payload
        W ("ЗАПИСАНО: страница {0}, версия v{1}" -f $targetId, $res.version.number)
    }
} else {
    W 'разметку менять не требуется (созданий/очисток нет)'
}

[System.IO.File]::WriteAllLines($Log, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("лог: $Log")
