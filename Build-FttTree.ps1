<#
.SYNOPSIS
    Строит «Матрицу ФТТ» (группировка ФТТ -> Схема) из «Матрицы согласования ФТТ».
.DESCRIPTION
    Источник (не меняется): 123456789. Цель: -Target (по умолчанию 123456790).
    Для каждой строки источника:
      * строка ФТТ копируется как есть (ссылка, пилюли, согласующие);
      * если на странице ФТТ есть поле «Схема ФТТ» — по каждой короткой ссылке /x/… из него
        добавляется вложенная строка схемы: название ссылкой + её 03./04./08 + её согласующие
        (пилюли переиспользуются по macroid — статус у Handy Macros привязан к macroid).
    По умолчанию DRY RUN, для записи -Apply.
#>
[CmdletBinding()]
param(
    [string]$Source = '123456789',
    [string]$Target = '123456790',
    [switch]$Apply,
    [int]$Limit = 0,
    [string]$DumpPath = '',
    [string]$Log = "$env:TEMP\build-tree.log"
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE } elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { 'https://confluence.example.com' }
$base = $base.TrimEnd('/')
$token = if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT } elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN } else {
    $e = Get-Content "$env:LOCALAPPDATA\confluence-mcp\creds.dat" -Raw | ConvertFrom-Json
    $s = $e.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
    [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
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
function Api-PutJson([string]$Uri, $Obj) {
    $json = $Obj | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'PUT'; $req.ContentType = 'application/json; charset=utf-8'
    $req.Headers.Add('Authorization', $auth); $req.ContentLength = $bytes.Length
    $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    $resp = $req.GetResponse()
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
    return ($t | ConvertFrom-Json)
}

$rowRx  = [regex]'(?s)<tr[^>]*>[\s\S]*?</tr>'
$cellRx = [regex]'(?s)<t[dh]([^>]*)>([\s\S]*?)</t[dh]>'

function Norm([string]$s) {
    $t = [System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ' '))
    $t = ($t -replace [string][char]0x00A0, ' ') -replace '\s+', ' '
    return $t.Trim()
}
function Esc([string]$s) { ([string]$s).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }
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
function PillOf([string]$cellHtml) { $m = [regex]::Match($cellHtml, 'ac:name="id">(\d+)<'); if ($m.Success) { return $m.Groups[1].Value } return '' }
function PillCell([string]$mid) {
    '<td><ac:structured-macro ac:name="status-handy" ac:schema-version="1"><ac:parameter ac:name="id">' + $mid + '</ac:parameter></ac:structured-macro></td>'
}
# вставить html после n-й закрывающей ячейки строки
function Insert-AfterCell([string]$rowHtml, [int]$nth, [string]$html, [string]$closeTag = '</td>') {
    $idx = -1; $c = 0
    foreach ($m in [regex]::Matches($rowHtml, [regex]::Escape($closeTag))) {
        $c++
        if ($c -eq $nth) { $idx = $m.Index + $m.Length; break }
    }
    if ($idx -lt 0) { return $rowHtml }
    return $rowHtml.Substring(0, $idx) + $html + $rowHtml.Substring($idx)
}

$out = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $out.Add($s); Write-Output $s }

$src = Api-Get "$CONTENT$Source`?expand=body.storage,version,space"
$dst = Api-Get "$CONTENT$Target`?expand=body.storage,version,space"
$spaceKey = $src.space.key
W ("ИСТОЧНИК {0} v{1} «{2}»" -f $Source, $src.version.number, $src.title)
W ("ЦЕЛЬ     {0} v{1} «{2}»" -f $Target, $dst.version.number, $dst.title)
W ("РЕЖИМ: " + $(if ($Apply) { 'ЗАПИСЬ' } else { 'DRY RUN' }))
W ''

$srcRows = @($rowRx.Matches($src.body.storage.value))
W ("строк в источнике: " + $srcRows.Count)

# шапка: строка с максимумом userkey = строка ключей; предыдущая = подписи
$hdrIdx = -1; $hdrKeys = @(); $best = 0
for ($i = 0; $i -lt $srcRows.Count; $i++) {
    $keys = @([regex]::Matches($srcRows[$i].Value, '<ri:user ri:userkey="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($keys.Count -gt $best) { $best = $keys.Count; $hdrIdx = $i; $hdrKeys = $keys }
}
W ("шапка: строка $($hdrIdx + 1), согласующих $($hdrKeys.Count)")
$capIdx = 0
$capRow = $srcRows[$capIdx].Value
$keyRow = $srcRows[$hdrIdx].Value

# колонки согласующих = порядок userkey в строке ключей (ширина совпадает со строкой данных)
$colKeys = @{}
$j = 0
foreach ($c in $cellRx.Matches([regex]::Match($keyRow, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value)) {
    $uk = [regex]::Match($c.Groups[2].Value, 'ri:userkey="([^"]+)"')
    if ($uk.Success) { $colKeys[$j] = $uk.Groups[1].Value }
    $j++
}
# первые 5 «подписных» колонок: block, area, lead, analyst, overall -> найдём по подписям
$capCells = @($cellRx.Matches([regex]::Match($capRow, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value))
$capCol = @{}; $col = 0
foreach ($c in $capCells) {
    $cs = [regex]::Match($c.Groups[1].Value, 'colspan="(\d+)"'); $span = if ($cs.Success) { [int]$cs.Groups[1].Value } else { 1 }
    $capCol[(Norm $c.Groups[2].Value)] = $col
    $col += $span
}
W ("колонки: " + (($capCol.Keys | Sort-Object { $capCol[$_] }) | ForEach-Object { "$_=" + $capCol[$_] }) -join '; ')
W ''

$body = New-Object System.Collections.Generic.List[string]
$body.Add('<table class="wrapped"><tbody>')
$body.Add((Insert-AfterCell $srcRows[0].Value 1 '<th rowspan="3"><p>Схема ФТТ</p></th>' '</th>'))
for ($hi = 1; $hi -le $hdrIdx; $hi++) { $body.Add($srcRows[$hi].Value) }

$firstApproverCol = ($colKeys.Keys | Measure-Object -Minimum).Minimum
$nRows = 0; $nSchemes = 0; $nNoSrc = 0; $nTinyFail = 0

for ($i = $hdrIdx + 1; $i -lt $srcRows.Count; $i++) {
    $tr = $srcRows[$i].Value
    $cells = @($cellRx.Matches([regex]::Match($tr, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value))
    if ($cells.Count -lt 15) { continue }
    $num = Norm $cells[0].Groups[2].Value
    if ($num -notmatch '^\d+$') { continue }
    $srcPageId = [regex]::Match($cells[1].Groups[2].Value, '(?:pageId=|/pages/)(\d+)')
    if (-not $srcPageId.Success) { continue }
    if ($srcPageId.Groups[1].Value -eq $Source) { W ("  стр.$num — ссылка на саму матрицу, пропуск"); continue }

    $nRows++
    $fttNameHtml = $cells[1].Groups[2].Value
    $schemeLinks = New-Object System.Collections.Generic.List[string]
    $schemaRows = New-Object System.Collections.Generic.List[string]

    # «Схема ФТТ» на странице ФТТ
    $page = $null
    try { $page = Api-Get "$CONTENT$($srcPageId.Groups[1].Value)`?expand=body.storage,version" } catch { $page = $null }
    if (-not $page) { $nNoSrc++ }

    $schemeCells = New-Object System.Collections.Generic.List[string]
    $otherLabels = New-Object System.Collections.Generic.List[string]
    if ($page) {
        foreach ($rm in $rowRx.Matches($page.body.storage.value)) {
            $cc = @($cellRx.Matches([regex]::Match($rm.Value, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value))
            if ($cc.Count -lt 2) { continue }
            $labF = Norm $cc[0].Groups[2].Value
            if ($labF -match '^Схема\s+ФТТ$') { $schemeCells.Add($cc[1].Groups[2].Value) }
            elseif ($labF -match '(?i)схем') { $otherLabels.Add($labF) }
        }
    }
    if ($otherLabels.Count) { W ("    стр.${num}: НЕ использованы подписи: " + (($otherLabels | Select-Object -Unique) -join ' | ')) }
    if ($schemeCells.Count -gt 1) { W ("    стр.${num}: ячеек «Схема ФТТ» — $($schemeCells.Count), ссылки объединены") }

    $tinyToks = @([regex]::Matches(($schemeCells -join ' '), '/x/([A-Za-z0-9_-]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $pageIds = @([regex]::Matches(($schemeCells -join ' '), '(?:pageId=|/pages/)(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($t2 in $tinyToks) {
        $rid = Resolve-Tiny $t2
        if (-not $rid) { $nTinyFail++; W ("    стр.${num}: не раскрыта короткая ссылка $t2"); continue }
        if (-not $ids.Contains($rid)) { $ids.Add($rid) }
    }
    foreach ($pid2 in $pageIds) { if (-not $ids.Contains($pid2)) { $ids.Add($pid2) } }

    $k = 0
    foreach ($sid in $ids) {
        $sp = $null
        try { $sp = Api-Get "$CONTENT$sid`?expand=body.storage,version" } catch { $sp = $null }
        if (-not $sp) { $nNoSrc++; continue }
        $k++; $nSchemes++
        # разбор полей схемы
        $sBlock = ''; $sArea = ''; $sOverall = ''; $sUsers = @{}
        foreach ($rm in $rowRx.Matches($sp.body.storage.value)) {
            $cc = @($cellRx.Matches([regex]::Match($rm.Value, '(?s)<tr[^>]*>([\s\S]*?)</tr>').Groups[1].Value))
            if ($cc.Count -lt 2) { continue }
            $lab = Norm $cc[0].Groups[2].Value
            $val = $cc[1].Groups[2].Value
            $rowAll = $rm.Value
            if ($lab -match '^\d+\.\s*Согласующ') {
                $uk = [regex]::Match($rowAll, 'ri:userkey="([^"]+)"'); $pm = [regex]::Match($rowAll, 'ac:name="id">(\d+)<')
                if ($uk.Success -and $pm.Success -and -not $sUsers.ContainsKey($uk.Groups[1].Value)) { $sUsers[$uk.Groups[1].Value] = $pm.Groups[1].Value }
                continue
            }
            if ($lab -match '^03\.' -and -not $sBlock) { $sBlock = PillOf $val; continue }
            if ($lab -match '^04\.' -and -not $sArea) { $sArea = PillOf $val; continue }
            if ($lab -match '^08' -and -not $sOverall) { $sOverall = PillOf $val; continue }
        }
        $normWidth = $colKeys.Count
        $row = New-Object System.Collections.Generic.List[string]
        $row.Add('<tr>')
        $row.Add('<td>' + (Esc $num) + '.' + $k + '</td>')
        $row.Add('<td>' + $fttNameHtml + '</td>')
        $row.Add('<td><a href="' + $base + '/spaces/' + $spaceKey + '/pages/' + $sid + '">' + (Esc $sp.title) + '</a></td>')
        $row.Add($(if ($sBlock) { PillCell $sBlock } else { '<td>-</td>' }))
        $row.Add($(if ($sArea) { PillCell $sArea } else { '<td>-</td>' }))
        $row.Add('<td>-</td>')
        $row.Add('<td>-</td>')
        $row.Add($(if ($sOverall) { PillCell $sOverall } else { '<td>-</td>' }))
        foreach ($c in ($colKeys.Keys | Sort-Object)) {
            $uk = $colKeys[$c]
            if ($sUsers.ContainsKey($uk)) { $row.Add((PillCell $sUsers[$uk])) } else { $row.Add('<td>-</td>') }
        }
        $row.Add('</tr>')
        $schemaRows.Add(($row -join ''))
        $schemeLinks.Add('<a href="' + $base + '/spaces/' + $spaceKey + '/pages/' + $sid + '">' + (Esc $sp.title) + '</a>')
        W ("    стр.$num.$k  схема $sid «" + $sp.title.Substring(0, [Math]::Min(70, $sp.title.Length)) + "»")
    }

    $body.Add((Insert-AfterCell $tr 2 '<td><br /></td>'))
    foreach ($sr in $schemaRows) { $body.Add($sr) }
    if ($Limit -and $nRows -ge $Limit) { break }
    Start-Sleep -Milliseconds 120
}

$body.Add('</tbody></table>')
$html = $body -join ''
if ($DumpPath) { [System.IO.File]::WriteAllText($DumpPath, $html, (New-Object System.Text.UTF8Encoding($true))) }

W ''
W ("ИТОГО: строк ФТТ $nRows, вложенных схем $nSchemes, страниц не прочитано $nNoSrc, ссылок не раскрыто $nTinyFail")
W ("разметка: " + $html.Length + " символов")

if (-not $Apply) {
    W 'DRY RUN: ничего не записано. Для записи добавьте -Apply.'
} else {
    $fresh = Api-Get "$CONTENT$Target`?expand=version"
    $payload = @{
        id = $Target; type = 'page'; title = $fresh.title
        version = @{ number = [int]$fresh.version.number + 1; message = 'build FTТ tree (ФТТ -> Схема)'; minorEdit = $true }
        body = @{ storage = @{ representation = 'storage'; value = $html } }
    }
    $res = Api-PutJson "$CONTENT$Target" $payload
    W ("ЗАПИСАНО: страница {0}, версия v{1}" -f $Target, $res.version.number)
}

[System.IO.File]::WriteAllLines($Log, $out, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("лог: $Log")
