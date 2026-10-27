<#
.SYNOPSIS
    Рекурсивная выгрузка страниц Confluence и их вложений в папку на диск.

.DESCRIPTION
    Все настройки — в блоке «НАСТРОЙКИ» сразу под этим блоком. Правятся в Блокноте,
    запускать — двойным щелчком по Export-ConfluenceTree.bat.

    Токен берётся по порядку:
      1) переменная окружения CONFLUENCE_PAT (или CONFLUENCE_PERSONAL_TOKEN);
      2) %LOCALAPPDATA%\confluence-mcp\creds.dat (DPAPI, читается только своим пользователем);
      3) если нет ни того, ни другого — спросит и не покажет ввод.

    Выгружает: дерево страниц (страница + все дочерние), текст каждой страницы и вложения.
    Итог: папки по иерархии + index.csv + export-log.txt.
#>

# ============================ НАСТРОЙКИ ============================
# ID страницы или полная ссылка на неё. Меняется только эта строка.
$RootPage = '123456792'

# Куда сохранять (папка создастся сама)
$OutDir = "$env:USERPROFILE\Documents\FTT-export"

# Что сохранять
$SavePageHtml    = $true     # текст страницы как HTML (открывается в браузере)
$SaveStorageXml  = $false    # исходная разметка страницы (XML) — для разбора программно

# Вложения
$DownloadAttachments = $true
$MinFileSizeMb   = 0         # не качать файлы больше N МБ (0 = качать всё)
$SkipTempFiles   = $true     # пропускать вложения вида ~имя.tmp (мусор Confluence)

# Ограничения обхода (0 = без ограничений)
$MaxPages        = 0
# ===================================================================

# чтобы русский текст в консоли не превращался в кракозябры
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host ('  файл: ' + $_.InvocationInfo.ScriptName) -ForegroundColor Red
        Write-Host ('  строка ' + $_.InvocationInfo.ScriptLineNumber + ': ' + (($_.InvocationInfo.Line) -replace '^\s+', '').Trim()) -ForegroundColor DarkGray
    }
    if ($_.Exception.Response) {
        try { $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); Write-Host ('  ответ сервера: ' + $sr.ReadToEnd()) -ForegroundColor DarkYellow; $sr.Close() } catch { }
    }
    Write-Host ''
    Write-Host ('Лог (если успел создаться): ' + $LogFile) -ForegroundColor DarkGray
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Enter — закрыть' }
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = if ($env:CONFLUENCE_BASE) { $env:CONFLUENCE_BASE } elseif ($env:CONFLUENCE_URL) { $env:CONFLUENCE_URL } else { 'https://confluence.example.com' }
$base = $base.TrimEnd('/')

$token = if ($env:CONFLUENCE_PAT) { $env:CONFLUENCE_PAT } elseif ($env:CONFLUENCE_PERSONAL_TOKEN) { $env:CONFLUENCE_PERSONAL_TOKEN } else {
    $credPath = "$env:LOCALAPPDATA\confluence-mcp\creds.dat"
    if (Test-Path -LiteralPath $credPath) {
        try {
            $e = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
            $s = $e.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
            [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
        } catch {
            Write-Host ('Не удалось расшифровать ' + $credPath + ' (файл привязан к другому пользователю/машине).') -ForegroundColor Yellow
            $null
        }
    } else { $null }
}
if (-not $token) {
    Write-Host 'Нужен токен Confluence (PAT).' -ForegroundColor Yellow
    Write-Host 'Вставьте токен и нажмите Enter (ввод не отображается):'
    $secIn = Read-Host -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secIn))
}
if (-not $token) { throw 'Пустой токен.' }
$auth = "Bearer $token"

if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$LogFile = Join-Path $OutDir 'export-log.txt'
$Manifest = Join-Path $OutDir 'index.csv'

$log = New-Object System.Collections.Generic.List[string]
function L([string]$s) { $log.Add($s); Write-Host $s }

function Api-Get([string]$url) {
    for ($i = 1; $i -le 5; $i++) {
        $w = New-Object System.Net.WebClient; $w.Encoding = [Text.Encoding]::UTF8
        $w.Headers.Add('Authorization', $auth); $w.Headers.Add('Accept', 'application/json')
        try { $r = $w.DownloadString($url); $w.Dispose(); return ($r | ConvertFrom-Json) }
        catch { $w.Dispose(); if ($i -eq 5) { throw }; Start-Sleep -Milliseconds (600 * $i) }
    }
}
function Download-File([string]$relUrl, [string]$dest) {
    for ($i = 1; $i -le 3; $i++) {
        $w = New-Object System.Net.WebClient; $w.Encoding = [Text.Encoding]::UTF8
        $w.Headers.Add('Authorization', $auth)
        $w.Headers.Add('User-Agent', 'Mozilla/5.0')
        try { $w.DownloadFile("$base$relUrl", $dest); return $true }
        catch { if ($i -eq 3) { return $false }; Start-Sleep -Milliseconds (700 * $i) }
        finally { $w.Dispose() }
    }
}
function SafeName([string]$s) {
    $bad = [IO.Path]::GetInvalidFileNameChars()
    $t = $s
    foreach ($c in $bad) { $t = $t.Replace([string]$c, '_') }
    $t = ($t -replace '\s+', ' ').Trim().TrimEnd('.')
    if ($t.Length -gt 90) { $t = $t.Substring(0, 90).Trim() }
    if (-not $t) { $t = 'page' }
    return $t
}

$rootId = $RootPage
if ($rootId -notmatch '^\d+$') {
    $m = [regex]::Match($RootPage, '/pages/(\d+)'); if (-not $m.Success) { $m = [regex]::Match($RootPage, '[?&]pageId=(\d+)') }
    if (-not $m.Success) { throw "Не удалось найти ID страницы в «$RootPage». Впишите число или полную ссылку." }
    $rootId = $m.Groups[1].Value
}

$root = Api-Get "$base/rest/api/content/$rootId`?expand=version"
L ("Корень: «" + $root.title + "» (id " + $rootId + ")")
L ("Папка: " + $OutDir)
L ("Вложения: " + $(if ($DownloadAttachments) { 'да' } else { 'нет' }) + "; текст страниц: " + $(if ($SavePageHtml -or $SaveStorageXml) { 'да' } else { 'нет' }))
L ''

$rows = New-Object System.Collections.Generic.List[object]
$errors = 0
$pagesDone = 0
$filesDone = 0

function Export-Page([string]$pageId, [string]$parentFolder, [int]$depth) {
    if ($MaxPages -gt 0 -and $pagesDone -ge $MaxPages) { return }
    $script:pagesDone++

    $pg = Api-Get "$base/rest/api/content/$pageId`?expand=body.view,body.storage,version"
    $folderName = SafeName $pg.title
    $folder = Join-Path $parentFolder ($folderName + ' (' + $pageId + ')')
    [void](New-Item -ItemType Directory -Path $folder -Force)

    $pad = '  ' * $depth
    L ($pad + '[' + $pagesDone + '] ' + $pg.title)

    $rec = [pscustomobject]@{ Page = $pg.title; Id = $pageId; Folder = $folder; Attachments = 0; Bytes = 0; Error = '' }

    try {
        if ($SavePageHtml -and $pg.body.view) {
            $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + [System.Net.WebUtility]::HtmlEncode($pg.title) + '</title></head><body>' +
                    '<div style="font:14px/1.5 system-ui;max-width:1000px;margin:20px auto">' +
                    '<p style="color:#666">' + [System.Net.WebUtility]::HtmlEncode($base + '/pages/viewpage.action?pageId=' + $pageId) + '</p>' +
                    $pg.body.view.value + '</div></body></html>'
            [System.IO.File]::WriteAllText((Join-Path $folder 'page.html'), $html, (New-Object System.Text.UTF8Encoding($true)))
        }
        if ($SaveStorageXml -and $pg.body.storage) {
            [System.IO.File]::WriteAllText((Join-Path $folder 'page.storage.xml'), $pg.body.storage.value, (New-Object System.Text.UTF8Encoding($true)))
        }
    } catch { L ($pad + '   ! текст не сохранён: ' + $_.Exception.Message); $script:errors++ }

    if ($DownloadAttachments) {
        $attDir = Join-Path $folder 'attachments'
        try {
            $att = Api-Get "$base/rest/api/content/$pageId/child/attachment?limit=200"
            if ($att -and $att.results.Count) {
                [void](New-Item -ItemType Directory -Path $attDir -Force)
                foreach ($a in $att.results) {
                    $name = [string]$a.title
                    if ($SkipTempFiles -and $name.StartsWith('~')) { continue }
                    $size = 0; if ($a.extensions) { $size = [int64]$a.extensions.fileSize }
                    if ($MinFileSizeMb -gt 0 -and $size -gt ($MinFileSizeMb * 1MB)) { L ($pad + '   - пропущен (большой): ' + $name); continue }
                    $dest = Join-Path $attDir (SafeName $name)
                    if (Download-File ([string]$a._links.download) $dest) {
                        $script:filesDone++
                        $rec.Attachments++
                        $rec.Bytes += $size
                        L ($pad + '   + ' + $name + ' (' + [math]::Round($size / 1KB) + ' КБ)')
                    } else { L ($pad + '   ! не скачался: ' + $name); $script:errors++ }
                    Start-Sleep -Milliseconds 60
                }
            }
        } catch { L ($pad + '   ! вложения: ' + $_.Exception.Message); $script:errors++ }
    }

    $rec.Error = ''
    $script:rows.Add($rec)

    # дочерние страницы
    try {
        $ch = Api-Get "$base/rest/api/content/$pageId/child/page?limit=200"
        foreach ($c in $ch.results) { Export-Page ([string]$c.id) $folder ($depth + 1) }
    } catch { L ($pad + '   ! дочерние страницы: ' + $_.Exception.Message); $script:errors++ }
}

L 'Начинаю выгрузку...'
Export-Page $rootId $OutDir 0

$rows | Export-Csv -LiteralPath $Manifest -NoTypeInformation -Encoding UTF8
L ''
L ('Готово. Страниц: ' + $pagesDone + ', файлов: ' + $filesDone + ', ошибок: ' + $errors)
L ('Папка: ' + $OutDir)
L ('Список страниц: ' + $Manifest)
[System.IO.File]::WriteAllLines($LogFile, $log, (New-Object System.Text.UTF8Encoding($true)))
Write-Host ''
Write-Host 'Открыть папку результата? (Enter — закрыть, O — открыть)' -ForegroundColor Cyan
$k = Read-Host
if ($k -eq 'O' -or $k -eq 'o' -or $k -eq 'О' -or $k -eq 'о') { Start-Process explorer.exe $OutDir }
