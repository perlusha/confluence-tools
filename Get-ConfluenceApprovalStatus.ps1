<#
.SYNOPSIS
    Read-only: собирает Confluence-задачи (ac:task) и статус-пилюли (status-handy) со страниц.

.DESCRIPTION
    НИЧЕГО НЕ ЗАПИСЫВАЕТ. Только читает storage страниц через REST API и печатает:
      - задачи: task-id, task-status (complete/incomplete), ответственный, текст пилюли внутри;
      - пилюли вне задач;
      - сводный словарь всех встреченных текстов статусов.

    Авторизация: PAT (см. Export-ConfluenceTables.md).
    Токен — из -Token или CONFLUENCE_PAT / CONFLUENCE_PERSONAL_TOKEN.
    База — из -BaseUrl или CONFLUENCE_BASE / CONFLUENCE_URL.

.PARAMETER Page
    Один или несколько URL/ID страниц.

.EXAMPLE
    $env:CONFLUENCE_URL = 'https://confluence.example.com'
    .\Get-ConfluenceApprovalStatus.ps1 -Page 528207762,495835925
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Page,

    [string]$BaseUrl = $(if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE }
                         elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { '' }),
    [string]$Token   = $(if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT }
                         elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN }
                         elseif ($env:CONFLUENCE_TOKEN) { $env:CONFLUENCE_TOKEN } else { '' }),
    [string]$User,
    [switch]$Insecure
)

$ErrorActionPreference = 'Stop'

$Page = @($Page | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() })

function Get-PageId {
    param([string]$Value)
    if ($Value -match '^\d+$')            { return $Value }
    if ($Value -match '/pages/(\d+)')     { return $Matches[1] }
    if ($Value -match '[?&]pageId=(\d+)') { return $Matches[1] }
    throw "Не удалось извлечь ID страницы из '$Value'."
}

if (-not $BaseUrl) { throw 'Не задан BaseUrl (CONFLUENCE_BASE / CONFLUENCE_URL).' }
if (-not $Token)   { throw 'Не задан токен (CONFLUENCE_PAT / CONFLUENCE_PERSONAL_TOKEN).' }
$BaseUrl = $BaseUrl.TrimEnd('/')

if ($User) {
    $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$User`:$Token"))
    $auth = "Basic $b64"
} else {
    $auth = "Bearer $Token"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($Insecure) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }

function Get-Storage {
    param([string]$PageId)
    $uri = "$BaseUrl/rest/api/content/$PageId`?expand=body.storage,version,space"
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('Authorization', $auth)
    $wc.Headers.Add('Accept', 'application/json')
    try   { return ($wc.DownloadString($uri) | ConvertFrom-Json) }
    catch [System.Net.WebException] {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Warning "Страница ${PageId}: HTTP $code — пропущена"
        return $null
    }
    finally { $wc.Dispose() }
}

function Get-PillStatus {
    param([string]$Xml)
    $s = ''
    if ($Xml -match '(?s)<ac:parameter ac:name="Status">(.*?)</ac:parameter>') { $s = $Matches[1] }
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    return ($s -replace '\s+', ' ').Trim()
}

$macroRx = [regex]'(?s)<ac:structured-macro[^>]*ac:name="status-handy".*?</ac:structured-macro>'
$taskRx  = [regex]'(?s)<ac:task>.*?</ac:task>'

$rows = New-Object System.Collections.Generic.List[object]
$pageInfo = New-Object System.Collections.Generic.List[object]

foreach ($p in $Page) {
    $pageId = Get-PageId $p
    $obj = Get-Storage -PageId $pageId
    if (-not $obj) { continue }

    $title   = $obj.title
    $version = $obj.version.number
    $html    = $obj.body.storage.value
    if (-not $html) { $html = '' }

    $taskMatches = $taskRx.Matches($html)
    $macroMatches = $macroRx.Matches($html)

    $insideTask = New-Object System.Collections.Generic.List[int]
    $taskCount = 0
    $pillCount = 0

    foreach ($t in $taskMatches) {
        $body = $t.Value
        $taskId = if ($body -match '<ac:task-id>(\d+)</ac:task-id>') { $Matches[1] } else { '' }
        $tStatus = if ($body -match '<ac:task-status>([^<]+)</ac:task-status>') { $Matches[1] } else { '' }
        $userKey = if ($body -match '<ri:user ri:userkey="([^"]+)"') { $Matches[1] } else { '' }
        $userName = if ($body -match '<ac:plain-text-link-body><!\[CDATA\[(.*?)\]\]></ac:plain-text-link-body>') { $Matches[1].Trim() } else { '' }

        $pillTexts = @()
        foreach ($m in $macroRx.Matches($body)) {
            $insideTask.Add($m.Index + $t.Index)
            $pillTexts += (Get-PillStatus $m.Value)
        }

        $taskCount++
        $pillCount += $pillTexts.Count
        $rows.Add([pscustomobject]@{
            PageId = $pageId; Title = $title; Kind = 'task'
            TaskId = $taskId; TaskStatus = $tStatus
            User = if ($userName) { $userName } else { $userKey }
            Status = ($pillTexts -join ' | ')
        })
    }

    foreach ($m in $macroMatches) {
        if ($insideTask.Contains($m.Index)) { continue }
        $pillCount++
        $rows.Add([pscustomobject]@{
            PageId = $pageId; Title = $title; Kind = 'pill'
            TaskId = ''; TaskStatus = ''
            User = ''
            Status = (Get-PillStatus $m.Value)
        })
    }

    $pageInfo.Add([pscustomobject]@{
        PageId = $pageId; Title = $title; Version = $version
        Tasks = $taskCount; Pills = $pillCount
    })
}

Write-Output ''
Write-Output '=== СТРАНИЦЫ ==='
foreach ($pi in $pageInfo) {
    Write-Output ("{0}  v{1}  «{2}»  задач: {3}, пилюль: {4}" -f $pi.PageId, $pi.Version, $pi.Title, $pi.Tasks, $pi.Pills)
}

Write-Output ''
Write-Output '=== ЗАДАЧИ И ПИЛЮЛИ ==='
foreach ($r in $rows) {
    if ($r.Kind -eq 'task') {
        Write-Output ("  [task {0,-4}] {1,-11} {2,-28} -> {3}" -f $r.TaskId, $r.TaskStatus, $r.User, $r.Status)
    } else {
        Write-Output ("  [pill      ] {0}" -f $r.Status)
    }
}

Write-Output ''
Write-Output '=== СЛОВАРЬ ТЕКСТОВ СТАТУСОВ ==='
$rows | Where-Object { $_.Status } |
    Group-Object Status |
    Sort-Object Count -Descending |
    ForEach-Object { Write-Output ("  {0,4} x  {1}" -f $_.Count, $_.Name) }

Write-Output ''
Write-Output '=== СОСТОЯНИЯ ЗАДАЧ ==='
$rows | Where-Object { $_.Kind -eq 'task' } |
    Group-Object TaskStatus |
    Sort-Object Count -Descending |
    ForEach-Object { Write-Output ("  {0,4} x  {1}" -f $_.Count, $_.Name) }
