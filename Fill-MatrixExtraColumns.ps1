<#
.SYNOPSIS
    Дозаполняет в матрице согласования колонки из шапки страниц-источников.

.DESCRIPTION
    Берёт целевую матрицу, идёт по её строкам, по ссылке в столбце «Наименование раздела»
    находит страницу-источник и переносит оттуда значения в колонки.

    Колонки ищем по подписи в первой строке шапки матрицы, поэтому порядок столбцов не важен,
    а отсутствующая колонка просто пропускается. Что откуда берётся — в таблице $SPEC ниже.

    Пилюли переиспользуются: если в ячейке уже есть макрос, берётся его id
    (и статус правится через API, если отличается), новый создаётся только при отсутствии.

    По умолчанию — DRY RUN.

.PARAMETER Target
    Страница матрицы (ID или URL).

.PARAMETER Limit
    Обработать только первые N строк (для проверки).

.PARAMETER Apply
    Записать изменения. Без него — только план.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,

    [string]$BaseUrl = $(if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE }
                         elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { '' }),
    [string]$Token   = $(if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT }
                         elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN }
                         elseif ($env:CONFLUENCE_TOKEN) { $env:CONFLUENCE_TOKEN } else { '' }),
    [string]$User,
    [int]$Limit = 0,
    [string]$DumpPath,
    [switch]$Apply,
    [switch]$Insecure
)

$ErrorActionPreference = 'Stop'
if (-not $BaseUrl) { throw 'Не задан BaseUrl.' }
if (-not $Token)   { throw 'Не задан токен.' }
$BaseUrl = $BaseUrl.TrimEnd('/')
if ($User) { $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$User`:$Token")) }
else { $auth = "Bearer $Token" }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($Insecure) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
$HANDY = "$BaseUrl/rest/handy-macros/2.0"

# --------------------------------------------------------------- что заполняем
# Caption — подпись колонки в шапке матрицы (точное совпадение)
# Kind    — pill (пилюля status-handy) или user (ссылка на человека)
# Match   — регулярка (без учёта регистра) по подписи строки на странице-источнике
$SPEC = @(
    @{ Caption = 'Функциональный блок';       Kind = 'pill'; Match = '^03\.\s*Функциональный блок' }
    @{ Caption = 'Функциональная область';   Kind = 'pill'; Match = '^04\.\s*Функциональные области' }
    @{ Caption = 'Лид';                       Kind = 'user'; Match = 'лид' }
    @{ Caption = 'Аналитик';                  Kind = 'user'; Match = '^Аналитик$' }
    @{ Caption = 'Общий статус согласования'; Kind = 'pill'; Match = '^08\.01' }
)

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
        catch { if ($i -eq $Retry) { return $null }; Start-Sleep -Milliseconds (250 * $i) }
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
        catch {
            if ($i -eq $Retry) {
                $msg = $_.Exception.Message
                try {
                    $r = $_.Exception.Response
                    if ($r) { $sr2 = New-Object System.IO.StreamReader($r.GetResponseStream()); $msg += ' :: ' + $sr2.ReadToEnd(); $sr2.Close() }
                } catch { }
                throw $msg
            }
            Start-Sleep -Milliseconds (400 * $i)
        }
        finally { $wc.Dispose() }
    }
}
function Api-PostForm {
    param([string]$Uri, [string]$Body, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = 'POST'; $req.ContentType = 'application/x-www-form-urlencoded'
        $req.Headers.Add('Authorization', $auth); $req.Headers.Add('X-Atlassian-Token', 'no-check')
        $b = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $b.Length
        $st = $req.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close()
        try {
            $resp = $req.GetResponse(); $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $t = $sr.ReadToEnd().Trim(); $sr.Close(); $resp.Close()
            return $t
        } catch { if ($i -eq $Retry) { throw }; Start-Sleep -Milliseconds (250 * $i) }
    }
}
function Api-PutForm {
    param([string]$Uri, [string]$Body, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = 'PUT'; $req.ContentType = 'application/x-www-form-urlencoded'
        $req.Headers.Add('Authorization', $auth); $req.Headers.Add('X-Atlassian-Token', 'no-check')
        $b = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $b.Length
        $st = $req.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close()
        try {
            $resp = $req.GetResponse(); $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $t = $sr.ReadToEnd().Trim(); $sr.Close(); $resp.Close()
            return $t
        } catch { if ($i -eq $Retry) { throw }; Start-Sleep -Milliseconds (250 * $i) }
    }
}
function Get-StatusOfMacro {
    param([string]$MacroId, [string]$PageId)
    $j = Api-Get "$HANDY/status-macro/$MacroId`?contentId=$PageId"
    if ($j -and $j.status -and $null -ne $j.status.id) {
        return [pscustomobject]@{ Id = [int]$j.status.id; Name = [string]$j.status.name }
    }
    return $null
}

$rowRx  = [regex]'(?s)<tr[^>]*>(.*?)</tr>'
$cellRx = [regex]'(?s)<t([dh])([^>]*)>(.*?)</t\1>'
$tdRx   = [regex]'(?s)<td[^>]*>.*?</td>'

$targetId = Get-PageId $Target
$page = Api-Get "$BaseUrl/rest/api/content/$targetId`?expand=body.storage,version"
$html = $page.body.storage.value
Write-Output ("матрица $targetId v$($page.version.number), {0} символов" -f $html.Length)

# --------------------------------------------------------------- какие колонки есть в матрице
function Get-HeaderCol {
    param([string]$Html, [string]$Caption)
    $m = $rowRx.Match($Html)
    if (-not $m.Success) { return -1 }
    $col = 0
    foreach ($cm in $cellRx.Matches($m.Groups[1].Value)) {
        $txt = [System.Net.WebUtility]::HtmlDecode(($cm.Groups[3].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ')).Trim()
        $cs = 1
        if ($cm.Groups[2].Value -match 'colspan="(\d+)"') { $cs = [int]$Matches[1] }
        if ($txt -eq $Caption) { return $col }
        $col += $cs
    }
    return -1
}

$cols = New-Object System.Collections.Generic.List[object]
foreach ($sp in $SPEC) {
    $ci = Get-HeaderCol $html $sp.Caption
    if ($ci -ge 0) { $cols.Add([pscustomobject]@{ Caption = $sp.Caption; Kind = $sp.Kind; Match = $sp.Match; Col = $ci }) }
}
if ($cols.Count -eq 0) { throw 'В шапке матрицы не найдено ни одной из ожидаемых колонок.' }
Write-Output ("колонок к заполнению: " + $cols.Count)
foreach ($c in $cols) { Write-Output ("  «{0}» — столбец {1} ({2})" -f $c.Caption, $c.Col, $c.Kind) }

# --------------------------------------------------------------- план
$plan = New-Object System.Collections.Generic.List[object]
$n = 0
foreach ($rm in $rowRx.Matches($html)) {
    $cells = @($cellRx.Matches($rm.Groups[1].Value))
    if ($cells.Count -lt 3) { continue }
    if ($cells[0].Groups[3].Value -notmatch '^\s*\d+\s*$') { continue }
    $href = [regex]::Match($cells[1].Groups[3].Value, 'pageId=(\d+)')
    if (-not $href.Success) { $href = [regex]::Match($cells[1].Groups[3].Value, '/pages/(\d+)') }
    if (-not $href.Success) { continue }
    $plan.Add([pscustomobject]@{ RowIndex = $rm.Index; Row = $rm.Value; Num = $cells[0].Groups[3].Value.Trim(); SrcId = $href.Groups[1].Value })
    $n++
    if ($Limit -gt 0 -and $n -ge $Limit) { break }
}
Write-Output ("строк данных: " + $plan.Count)

# --------------------------------------------------------------- сбор данных и правка
$stats = @{}; foreach ($c in $cols) { $stats[$c.Caption] = @{ set = 0; empty = 0 } }
$i = 0; $changed = 0; $createdPills = 0; $newPills = 0; $statusUpdates = 0
$rowRepls = New-Object System.Collections.Generic.List[object]
foreach ($p in $plan) {
    $i++
    if ($i % 25 -eq 0) { Write-Output "  ... $i / $($plan.Count)" }
    $src = Api-Get "$BaseUrl/rest/api/content/$($p.SrcId)?expand=body.storage"
    if (-not $src) { Write-Warning ("источник $($p.SrcId) не прочитан — пропуск"); continue }
    $sh = $src.body.storage.value

    # значения из источника: пилюльные поля и люди по ролям
    $pillStatus = @{}; $userKey = @{}
    foreach ($rm2 in $rowRx.Matches($sh)) {
        $cells2 = @($cellRx.Matches($rm2.Groups[1].Value))
        if ($cells2.Count -lt 2) { continue }
        $lab = [System.Net.WebUtility]::HtmlDecode(($cells2[0].Groups[3].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ')).Trim()
        $val = $cells2[1].Groups[3].Value
        foreach ($c in $cols) {
            if ($c.Kind -eq 'pill') {
                if ($pillStatus.ContainsKey($c.Caption) -or $lab -notmatch $c.Match) { continue }
                $mid = [regex]::Match($val, '(?s)ac:name="status-handy".*?ac:name="id">(\d+)<')
                if ($mid.Success) { $pillStatus[$c.Caption] = Get-StatusOfMacro -MacroId $mid.Groups[1].Value -PageId $p.SrcId }
            } else {
                if ($userKey.ContainsKey($c.Caption) -or $lab -notmatch $c.Match) { continue }
                $uk = [regex]::Match($val, 'ri:userkey="([^"]+)"')
                if ($uk.Success) { $userKey[$c.Caption] = $uk.Groups[1].Value }
            }
        }
    }

    # собрать новые ячейки по колонкам
    $tds = @($tdRx.Matches($p.Row))
    $repls = @()
    foreach ($c in $cols) {
        if ($c.Col -ge $tds.Count) { continue }
        $cur = $tds[$c.Col].Value
        $curInner = ([regex]::Match($cur, '(?s)<td[^>]*>(.*)</td>')).Groups[1].Value
        if ($c.Kind -eq 'pill') {
            $want = $pillStatus[$c.Caption]
            if ($null -eq $want) { $stats[$c.Caption].empty++; continue }
            $stats[$c.Caption].set++
            $ex = [regex]::Match($curInner, 'ac:name="id">(\d+)<')
            if ($ex.Success) {
                $have = Get-StatusOfMacro -MacroId $ex.Groups[1].Value -PageId $targetId
                if ($have -and $have.Id -ne $want.Id) {
                    $statusUpdates++
                    if ($Apply) { [void](Api-PutForm "$HANDY/status-macro/$($ex.Groups[1].Value)/value" "contentId=$targetId&statusId=$($want.Id)") }
                }
            } else {
                $newPills++
                if ($Apply) {
                    $mid = Api-PostForm "$HANDY/status-macro" "contentId=$targetId&statusId=$($want.Id)"
                    if ($mid -match '^\d+$') {
                        $createdPills++
                        $repls += ,@($c.Col, ('<td><ac:structured-macro ac:name="status-handy" ac:schema-version="1"><ac:parameter ac:name="Status">{0}</ac:parameter><ac:parameter ac:name="id">{1}</ac:parameter></ac:structured-macro></td>' -f [System.Security.SecurityElement]::Escape($want.Name), $mid))
                    }
                } else {
                    $repls += ,@($c.Col, ('<td>ПИЛЮЛЯ_{0}</td>' -f $want.Id))
                }
            }
        } else {
            $want = $userKey[$c.Caption]
            $have = [regex]::Match($curInner, 'ri:userkey="([^"]+)"')
            $haveKey = if ($have.Success) { $have.Groups[1].Value } else { '' }
            if ($want) { $stats[$c.Caption].set++ } else { $stats[$c.Caption].empty++ }
            if ($haveKey -eq $want) { continue }
            $repls += ,@($c.Col, $(if ($want) { ('<td><ac:link><ri:user ri:userkey="{0}" /></ac:link></td>' -f $want) } else { '<td><br /></td>' }))
        }
    }
    if ($repls.Count -eq 0) { continue }

    # строка собирается заново из ячеек — без арифметики смещений
    $openTag = [regex]::Match($p.Row, '^<tr[^>]*>').Value
    $chg = $false
    $parts = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $tds.Count; $k++) {
        $cur = $tds[$k].Value
        $repl = $cur
        foreach ($pair in $repls) { if ([int]$pair[0] -eq $k) { $repl = [string]$pair[1]; break } }
        if ($repl -ne $cur) { $chg = $true }
        $parts.Add($repl)
    }
    if (-not $chg) { continue }
    $newRow = $openTag + ($parts -join '') + '</tr>'
    $changed++
    $rowRepls.Add([pscustomobject]@{ Index = $p.RowIndex; Len = $p.Row.Length; Html = $newRow })
    if ($i -le 3) {
        $parts2 = $cols | ForEach-Object {
            if ($_.Kind -eq 'pill') { "$($_.Caption)=$(if ($pillStatus[$_.Caption]) { $pillStatus[$_.Caption].Id } else { '—' })" }
            else { "$($_.Caption)=$(if ($userKey[$_.Caption]) { 'да' } else { '—' })" }
        }
        Write-Output ("  стр.{0} ({1}): {2}" -f $p.Num, $p.SrcId, ($parts2 -join ' '))
    }
}

# правки строк применяем справа налево
foreach ($rr in ($rowRepls | Sort-Object { -1 * $_.Index })) {
    $html = $html.Substring(0, $rr.Index) + $rr.Html + $html.Substring($rr.Index + $rr.Len)
}

Write-Output ''
Write-Output ("Строк изменено: {0}   новых пилюль: {1}   смена статуса пилюли: {2}" -f $changed, $(if ($Apply) { $createdPills } else { $newPills }), $statusUpdates)
foreach ($c in $cols) { Write-Output ("  «{0}»: заполнено {1}, нет данных {2}" -f $c.Caption, $stats[$c.Caption].set, $stats[$c.Caption].empty) }

# проверка корректности разметки и дамп (полезно и в dry-run)
try {
    $decl = '<?xml version="1.0" encoding="UTF-8"?><r xmlns:ac="http://atlassian.com/content" xmlns:ri="http://atlassian.com/ri">' + $html + '</r>'
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($decl)
    Write-Output 'разметка: XML корректен'
} catch {
    Write-Warning ('разметка: НЕКОРРЕКТНА — ' + $_.Exception.Message)
}
if ($DumpPath) {
    [System.IO.File]::WriteAllText($DumpPath, $html, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ("разметка сохранена: " + $DumpPath)
}

if ($changed -eq 0) { Write-Output 'Изменений нет.'; return }
if (-not $Apply) { Write-Output 'DRY RUN: ничего не записано. Для записи добавьте -Apply.'; return }

$fresh = Api-Get "$BaseUrl/rest/api/content/$targetId`?expand=version"
$payload = @{
    id = $targetId; type = 'page'; title = $page.title
    version = @{ number = [int]$fresh.version.number + 1; message = 'fill matrix columns' }
    body = @{ storage = @{ representation = 'storage'; value = $html } }
} | ConvertTo-Json -Depth 20 -Compress
$r = Api-PutJson "$BaseUrl/rest/api/content/$targetId" $payload
Write-Output ("ЗАПИСАНО: матрица $targetId, версия v" + $r.version.number)
