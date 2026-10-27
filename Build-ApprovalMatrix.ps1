<#
.SYNOPSIS
    Собирает плоскую матрицу согласования из дерева страниц Confluence.

.DESCRIPTION
    Обходит дерево от -Root на любую глубину, берёт страницы, у которых в верхней
    таблице есть строки «NN. Согласующий N», и собирает из них матрицу:
    строки — документы, столбцы — согласующие (объединение по дереву, по частоте).

    Столбцы — ссылки на пользователей (ri:user), ячейки — пилюли status-handy,
    создаваемые через API приложения (POST /status-macro), чтобы матрицу потом
    можно было синхронизировать закладкой.

    По умолчанию — DRY RUN: ничего не создаёт и не пишет.

.PARAMETER Root
    Корневая страница дерева (ID или URL).

.PARAMETER Target
    Целевая страница, куда записать матрицу (ID или URL).

.PARAMETER Apply
    Создать пилюли и записать страницу. Без него — только план.

.PARAMETER MaxPages
    Ограничить число страниц (для проверки).

.EXAMPLE
    .\Build-ApprovalMatrix.ps1 -Root 467853802 -Target 123456789
    .\Build-ApprovalMatrix.ps1 -Root 467853802 -Target 123456789 -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Root,
    [Parameter(Mandatory, Position = 1)][string]$Target,

    [string]$BaseUrl = $(if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE }
                         elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { '' }),
    [string]$Token   = $(if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT }
                         elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN }
                         elseif ($env:CONFLUENCE_TOKEN) { $env:CONFLUENCE_TOKEN } else { '' }),
    [string]$User,
    [int]$MaxPages = 0,
    [switch]$Apply,
    [switch]$Force,
    [switch]$Insecure
)

$ErrorActionPreference = 'Stop'

if (-not $BaseUrl) { throw 'Не задан BaseUrl (CONFLUENCE_BASE / CONFLUENCE_URL).' }
if (-not $Token)   { throw 'Не задан токен (CONFLUENCE_PAT / CONFLUENCE_PERSONAL_TOKEN).' }
$BaseUrl = $BaseUrl.TrimEnd('/')

if ($User) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$User`:$Token")); $auth = "Basic $b64"
} else { $auth = "Bearer $Token" }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($Insecure) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }

$HANDY = "$BaseUrl/rest/handy-macros/2.0"

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
        $wc.Headers.Add('Authorization', $auth)
        $wc.Headers.Add('Accept', 'application/json')
        try { return ($wc.DownloadString($Uri) | ConvertFrom-Json) }
        catch { if ($i -eq $Retry) { throw }; Start-Sleep -Milliseconds (250 * $i) }
        finally { $wc.Dispose() }
    }
}

function Api-PostForm {
    param([string]$Uri, [string]$Body, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = 'POST'
        $req.ContentType = 'application/x-www-form-urlencoded'
        $req.Headers.Add('Authorization', $auth)
        $req.Headers.Add('X-Atlassian-Token', 'no-check')
        $b = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $b.Length
        $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Close()
        try {
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return $t.Trim()
        } catch { if ($i -eq $Retry) { throw }; Start-Sleep -Milliseconds (250 * $i) }
    }
}

function Api-PutJson {
    param([string]$Uri, [string]$Json, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add('Authorization', $auth)
        $wc.Headers.Add('Content-Type', 'application/json')
        try { return ([System.Text.Encoding]::UTF8.GetString($wc.UploadData($Uri, 'PUT', [System.Text.Encoding]::UTF8.GetBytes($Json))) | ConvertFrom-Json) }
        catch { if ($i -eq $Retry) { throw }; Start-Sleep -Milliseconds (400 * $i) }
        finally { $wc.Dispose() }
    }
}

function Get-StatusOfMacro {
    param([string]$MacroId, [string]$PageId)
    try { $j = Api-Get "$HANDY/status-macro/$MacroId`?contentId=$PageId" } catch { return $null }
    if ($j -and $j.status -and $null -ne $j.status.id) { return [pscustomobject]@{ Id = [int]$j.status.id; Name = [string]$j.status.name } }
    return $null
}

function New-StatusMacro {
    param([string]$PageId, [int]$StatusId)
    $t = Api-PostForm "$HANDY/status-macro" "contentId=$PageId&statusId=$StatusId"
    if ($t -match '^\d+$') { return $t }
    throw "Неожиданный ответ при создании пилюли: $t"
}

function Esc([string]$s) {
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

$rootId   = Get-PageId $Root
$targetId = Get-PageId $Target

# ---------------------------------------------------------------- 1. дерево
Write-Output "Обход дерева от $rootId ..."
$pages = New-Object System.Collections.Generic.List[object]
function Walk([string]$id, [int]$depth) {
    if ($depth -gt 10) { return }
    $u = "$BaseUrl/rest/api/content/$id/child/page?limit=100"
    do {
        $r = Api-Get $u
        foreach ($c in $r.results) {
            $script:pages.Add([pscustomobject]@{ Id = [string]$c.id; Title = $c.title; Depth = $depth })
            Walk $c.id ($depth + 1)
        }
        $u = if ($r._links.next) { $BaseUrl + $r._links.next } else { $null }
    } while ($u)
}
Walk $rootId 1
if ($MaxPages -gt 0 -and $pages.Count -gt $MaxPages) { $pages = $pages.GetRange(0, $MaxPages) }
Write-Output ("  страниц: " + $pages.Count)

# ---------------------------------------------------------------- 2. разбор листов
$rowRx = [regex]'(?s)<tr[^>]*>(.*?)</tr>'
$userFreq = [ordered]@{}
$firstSeen = [ordered]@{}
$docs = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($p in $pages) {
    $i++
    if ($i % 25 -eq 0) { Write-Output "  разбор $i / $($pages.Count)" }
    try { $pg = Api-Get "$BaseUrl/rest/api/content/$($p.Id)?expand=body.storage" } catch { continue }
    $html = $pg.body.storage.value
    if (-not $html) { $html = '' }
    $approvers = [ordered]@{}
    foreach ($rm in $rowRx.Matches($html)) {
        $row = $rm.Groups[1].Value
        $lab = [regex]::Match($row, '(?s)^\s*<t[hd][^>]*>(.*?)</t[hd]>')
        if (-not $lab.Success) { continue }
        $labTxt = ($lab.Groups[1].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
        if ($labTxt -notmatch '^\d+\.\s*Согласующ') { continue }
        $uk = [regex]::Match($row, 'ri:userkey="([^"]+)"')
        $mid = [regex]::Match($row, '(?s)ac:name="status-handy".*?ac:name="id">(\d+)<')
        if ($uk.Success -and $mid.Success) {
            $key = $uk.Groups[1].Value
            if (-not $approvers.Contains($key)) { $approvers[$key] = $mid.Groups[1].Value }
        }
    }
    $hasTable = ($html -match '(?i)согласующ')
    if (-not $hasTable) { continue }
    $docs.Add([pscustomobject]@{ Id = $p.Id; Title = $p.Title; Approvers = $approvers })
    foreach ($k in $approvers.Keys) {
        if (-not $userFreq.Contains($k)) { $userFreq[$k] = 0; $firstSeen[$k] = $userFreq.Count }
        $userFreq[$k]++
    }
}
Write-Output ("  страниц с таблицей согласования: " + $docs.Count)

# ---------------------------------------------------------------- 3. столбцы
$columns = $userFreq.Keys | Sort-Object -Property @{ Expression = { -$userFreq[$_] } }, @{ Expression = { $firstSeen[$_] } }
Write-Output ("  столбцов (согласующих): " + $columns.Count)

$names = @{}
foreach ($k in $columns) {
    $u = $null
    try { $u = Api-Get "$BaseUrl/rest/api/user?key=$k" } catch { }
    $names[$k] = if ($u -and $u.displayName) { $u.displayName } else { $k }
}

# ---------------------------------------------------------------- 4. план
$plan = New-Object System.Collections.Generic.List[object]
foreach ($d in $docs) {
    $cells = [ordered]@{}
    foreach ($k in $columns) { $cells[$k] = $null }
    foreach ($k in $d.Approvers.Keys) {
        $st = Get-StatusOfMacro -MacroId $d.Approvers[$k] -PageId $d.Id
        if ($st) { $cells[$k] = $st }
    }
    $plan.Add([pscustomobject]@{ Doc = $d; Cells = $cells })
}
$filled = 0; foreach ($r in $plan) { foreach ($k in $columns) { if ($r.Cells[$k]) { $filled++ } } }

Write-Output ''
Write-Output ("СТРОК: {0}   СТОЛБЦОВ: {1}   заполненных ячеек: {2}" -f $plan.Count, $columns.Count, $filled)
Write-Output "Топ-10 столбцов:"
$columns | Select-Object -First 10 | ForEach-Object { Write-Output ("   {0,4} x  {1}" -f $userFreq[$_], $names[$_]) }
Write-Output "Первые 5 строк:"
$plan | Select-Object -First 5 | ForEach-Object {
    $cnt = 0; foreach ($k in $columns) { if ($_.Cells[$k]) { $cnt++ } }
    Write-Output ("   «{0}» — согласующих {1}" -f $_.Doc.Title, $cnt)
}

if (-not $Apply) {
    Write-Output ''
    Write-Output 'DRY RUN: ничего не создано и не записано. Для записи добавьте -Apply.'
    return
}

# ---------------------------------------------------------------- 5. создание пилюль
# уже существующие пилюли переиспользуем: ключ (название документа | userkey)
$reuse = @{}
if ($Apply -and -not $Force) {
    $cur = Api-Get "$BaseUrl/rest/api/content/$targetId`?expand=body.storage"
    $curHtml = $cur.body.storage.value
    if ($curHtml -match 'status-handy') {
        $rxs = [regex]'(?s)<tr[^>]*>(.*?)</tr>'
        $cxs = [regex]'(?s)<t[hd][^>]*>(.*?)</t[hd]>'
        $crows = @($rxs.Matches($curHtml))
        if ($crows.Count -ge 4) {
            $hdrCells = @($cxs.Matches($crows[2].Groups[1].Value))
            $hdrCols = @()
            foreach ($hc in $hdrCells) {
                $uk = [regex]::Match($hc.Groups[1].Value, 'ri:userkey="([^"]+)"')
                if ($uk.Success) { $hdrCols += $uk.Groups[1].Value }
            }
            for ($ri = 3; $ri -lt $crows.Count; $ri++) {
                $dc = @($cxs.Matches($crows[$ri].Groups[1].Value))
                if ($dc.Count -lt 3) { continue }
                $title = [System.Net.WebUtility]::HtmlDecode(($dc[1].Groups[1].Value -replace '<[^>]+>', '')).Trim()
                for ($j = 0; $j -lt $hdrCols.Count; $j++) {
                    if ((2 + $j) -ge $dc.Count) { break }
                    $mid = [regex]::Match($dc[2 + $j].Groups[1].Value, 'ac:name="id">(\d+)<')
                    if ($mid.Success) { $reuse["$title|$($hdrCols[$j])"] = $mid.Groups[1].Value }
                }
            }
        }
        Write-Output ("  найдено существующих пилюль для переиспользования: " + $reuse.Count)
    }
}
Write-Output ''
Write-Output "Пилюли на странице $targetId ..."
$pillIds = @{}
$created = 0; $reused = 0
foreach ($row in $plan) {
    foreach ($k in $columns) {
        $st = $row.Cells[$k]
        if (-not $st) { continue }
        $key = "$($row.Doc.Id)|$k"
        $rkey = "$($row.Doc.Title)|$k"
        if ($reuse.ContainsKey($rkey)) { $pillIds[$key] = $reuse[$rkey]; $reused++; continue }
        try {
            $mid = New-StatusMacro -PageId $targetId -StatusId $st.Id
            $pillIds[$key] = $mid
            $created++
        } catch { Write-Warning "не создалась пилюля для $key : $($_.Exception.Message)" }
        if ($created % 50 -eq 0 -and $created -gt 0) { Write-Output "  создано: $created" }
        Start-Sleep -Milliseconds 60
    }
}
Write-Output ("  переиспользовано: $reused, создано новых: $created")

# ---------------------------------------------------------------- 6. сборка страницы
$colCount = $columns.Count
$lastCol = 2 + $colCount
function ColLetter([int]$n) { $s=''; while ($n -gt 0) { $m=($n-1)%26; $s=[char](65+$m)+$s; $n=[int](($n-$m-1)/26) }; return $s }
$lastL = ColLetter $lastCol

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('<table class="wrapped relative-table"><colgroup><col style="width: 3%;"/><col style="width: 20%;"/>')
for ($c = 1; $c -le $colCount; $c++) { [void]$sb.Append('<col style="width: 1.4%;"/>') }
[void]$sb.Append('</colgroup><tbody>')

# шапка
[void]$sb.Append('<tr><th colspan="2" rowspan="3"><p>Наименование раздела</p></th>')
[void]$sb.Append(('<th colspan="{0}"><p>Согласующие</p></th></tr>' -f $colCount))
[void]$sb.Append(('<tr><th colspan="{0}"><p><br/></p></th></tr>' -f $colCount))
[void]$sb.Append('<tr>')
foreach ($k in $columns) { [void]$sb.Append(('<th><ac:link><ri:user ri:userkey="{0}"></ri:user></ac:link></th>' -f $k)) }
[void]$sb.Append('</tr>')

# данные
$num = 0
foreach ($row in $plan) {
    $num++
    [void]$sb.Append(('<tr><td>{0}</td><td><a href="{1}/pages/viewpage.action?pageId={2}">{3}</a></td>' -f $num, $BaseUrl, $row.Doc.Id, (Esc $row.Doc.Title)))
    foreach ($k in $columns) {
        $st = $row.Cells[$k]
        if (-not $st) { [void]$sb.Append('<td>-</td>'); continue }
        $mid = $pillIds["$($row.Doc.Id)|$k"]
        if (-not $mid) { [void]$sb.Append('<td>-</td>'); continue }
        [void]$sb.Append(('<td><ac:structured-macro ac:name="status-handy" ac:schema-version="1"><ac:parameter ac:name="Status">{0}</ac:parameter><ac:parameter ac:name="id">{1}</ac:parameter></ac:structured-macro></td>' -f (Esc $st.Name), $mid))
    }
    [void]$sb.Append('</tr>')
}
[void]$sb.Append('</tbody></table>')

$html = $sb.ToString()
Write-Output ("  размер разметки: " + $html.Length + " символов")

$ver = Api-Get "$BaseUrl/rest/api/content/$targetId`?expand=version"
$payload = @{
    id = $targetId; type = 'page'; title = $ver.title
    version = @{ number = [int]$ver.version.number + 1; message = 'build approval matrix' }
    body = @{ storage = @{ representation = 'storage'; value = $html } }
} | ConvertTo-Json -Depth 20 -Compress
$res = Api-PutJson "$BaseUrl/rest/api/content/$targetId" $payload
Write-Output ("ЗАПИСАНО: страница $targetId, версия v" + $res.version.number)
