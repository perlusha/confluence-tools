<#
.SYNOPSIS
    Приводит выгрузку «Матрица согласования» к виду листа согласования.

.DESCRIPTION
    Делает с копией файла:
      1) снимает объединения ниже шапки;
      2) удаляет строки, которые после этого стали полностью пустыми;
      3) ставит высоту строк данных (по умолчанию 20);
      4) навешивает условное форматирование по значениям статусов (5 правил);
      5) ставит автофильтр на строку шапки.

    Исходный файл не изменяется: работа идёт с копией.

.PARAMETER In
    Исходная выгрузка (.xlsx).

.PARAMETER Out
    Куда сохранить результат. По умолчанию: <In>_formatted.xlsx

.PARAMETER HeaderRow
    Номер строки шапки. 0 (по умолчанию) — определить автоматически.

.PARAMETER RowHeight
    Высота строк данных. По умолчанию 20.

.PARAMETER NoFilter
    Не ставить автофильтр.

.PARAMETER AdjustWidths
    Подогнать ширины: столбец 1 = 3, столбец 2 = 15, остальные = 11.1.

.EXAMPLE
    .\Format-ApprovalMatrix.ps1 -In "C:\Work\Example\Книга1.xlsx"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$In,

    [string]$Out,

    [int]$HeaderRow = 0,
    [double]$RowHeight = 20,
    [switch]$NoFilter,
    [switch]$AdjustWidths,
    [string]$Sheet
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $In)) { throw "Файл не найден: $In" }
$In = (Resolve-Path -LiteralPath $In).Path
if (-not $Out) {
    $dir = Split-Path -Parent $In
    $name = [System.IO.Path]::GetFileNameWithoutExtension($In)
    $Out = Join-Path $dir "$name`_formatted.xlsx"
}
$Out = [System.IO.Path]::GetFullPath($Out)

$statusWords = @('на корректировке', 'на согласовании', 'отменен', 'черновик', 'согласован')

function Get-ColumnLetter([int]$n) {
    $s = ''
    while ($n -gt 0) {
        $m = ($n - 1) % 26
        $s = [char](65 + $m) + $s
        $n = [int](($n - $m) / 26)
    }
    return $s
}
function Get-OleColor([string]$hex) {
    $h = $hex.TrimStart('#')
    $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
    return [int]($r + $g * 256 + $b * 65536)
}
function Test-StatusWord([string]$text) {
    $low = $text.ToLower()
    foreach ($w in $statusWords) { if ($low.Contains($w)) { return $true } }
    return $false
}

Copy-Item -LiteralPath $In -Destination $Out -Force
Write-Output "копия: $Out"

$xl = New-Object -ComObject Excel.Application
$xl.Visible = $false
$xl.DisplayAlerts = $false
$xl.ScreenUpdating = $false

$wb = $null
try {
    $wb = $xl.Workbooks.Open($Out)
    $ws = if ($Sheet) { $wb.Worksheets.Item($Sheet) } else { $wb.Worksheets.Item(1) }
    Write-Output "лист: $($ws.Name)"

    $ur = $ws.UsedRange
    $lastRow = $ur.Row + $ur.Rows.Count - 1
    $lastCol = $ur.Column + $ur.Columns.Count - 1

    # --- шапка ---
    if ($HeaderRow -le 0) {
        $best = 0; $bestCount = -1
        for ($r = 1; $r -le [Math]::Min(20, $lastRow); $r++) {
            $cnt = 0
            for ($c = 1; $c -le $lastCol; $c++) {
                $t = ([string]$ws.Cells($r, $c).Text).Trim()
                if ($t -eq '' -or $t -eq '-') { continue }
                if (Test-StatusWord $t) { continue }
                $cnt++
            }
            if ($cnt -gt $bestCount) { $bestCount = $cnt; $best = $r }
        }
        $HeaderRow = $best
    }
    Write-Output "шапка: строка $HeaderRow (столбцов: $lastCol, последняя строка: $lastRow)"
    if ($HeaderRow -ge $lastRow) { throw "Не удалось определить шапку: строка $HeaderRow >= $lastRow" }

    # --- 1. снять объединения ниже шапки ---
    $unmerged = 0
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($r = $HeaderRow + 1; $r -le $lastRow; $r++) {
        for ($c = 1; $c -le $lastCol; $c++) {
            $cell = $ws.Cells($r, $c)
            if ($cell.MergeCells) {
                $addr = $cell.MergeArea.Address($false, $false)
                $isNew = $seen.Add($addr)
                if ($isNew) { $cell.MergeArea.UnMerge(); $unmerged++ }
            }
        }
    }
    Write-Output "снято объединений: $unmerged"

    # --- 2. удалить полностью пустые строки ---
    $deleted = 0
    for ($r = $lastRow; $r -ge $HeaderRow + 1; $r--) {
        $filled = 0
        for ($c = 1; $c -le $lastCol; $c++) {
            if (([string]$ws.Cells($r, $c).Text).Trim() -ne '') { $filled++ }
        }
        if ($filled -eq 0) { [void]$ws.Rows($r).Delete(); $deleted++ }
    }
    Write-Output "удалено пустых строк: $deleted"

    # пересчёт последней строки
    $lastRow = $HeaderRow
    for ($r = $HeaderRow + 1; $r -le $HeaderRow + 500; $r++) {
        $filled = 0
        for ($c = 1; $c -le $lastCol; $c++) {
            if (([string]$ws.Cells($r, $c).Text).Trim() -ne '') { $filled++ }
        }
        if ($filled -gt 0) { $lastRow = $r } else { if ($r -gt $lastRow + 5) { break } }
    }
    Write-Output "строк данных: $($lastRow - $HeaderRow)"

    # --- 3. высота строк ---
    $ws.Rows("$($HeaderRow + 1):$lastRow").RowHeight = $RowHeight
    Write-Output "высота строк данных: $RowHeight"

    # --- 4. условное форматирование ---
    $colLetter = Get-ColumnLetter $lastCol
    $rangeRef = "A$($HeaderRow + 1):$colLetter$lastRow"
    $rng = $ws.Range($rangeRef)
    $rng.FormatConditions.Delete()

    $rules = @(
        @{ Word = 'на корректировке'; Hex = '#B4C6E7' },
        @{ Word = 'на согласовании';  Hex = '#FFEB9C' },
        @{ Word = 'Отменен';          Hex = '#FFC7CE' },
        @{ Word = 'Черновик';         Hex = '#D0CECE' },
        @{ Word = 'Согласован';       Hex = '#70AD47' }
    )
    # выгрузка бывает в стиле R1C1 — тогда A1-ссылка не распознаётся и Excel берёт её в кавычки
    $refStyle = $xl.ReferenceStyle
    $topLeft = 'A' + ($HeaderRow + 1)
    Write-Output ("стиль ссылок книги: " + $(if ($refStyle -eq -4150) { 'R1C1' } else { 'A1' }))
    foreach ($rule in $rules) {
        $cellRef = if ($refStyle -eq -4150) { 'RC' } else { $topLeft }
        $formula = '=NOT(ISERROR(SEARCH("' + $rule.Word + '",' + $cellRef + ')))'
        $fc = $rng.FormatConditions.Add(2, [System.Type]::Missing, $formula)
        $fc.Interior.Color = (Get-OleColor $rule.Hex)
        $fc.StopIfTrue = $false
    }
    Write-Output "правил УФ: $($rules.Count) на диапазон $rangeRef"

    # --- 5. автофильтр ---
    if (-not $NoFilter) {
        if ($ws.AutoFilterMode) { $ws.AutoFilterMode = $false }
        [void]$ws.Range("A$HeaderRow`:$colLetter$lastRow").AutoFilter()
        Write-Output "автофильтр: A$HeaderRow`:$colLetter$lastRow"
    }

    # --- ширины ---
    if ($AdjustWidths) {
        $ws.Columns(1).ColumnWidth = 3
        if ($lastCol -ge 2) { $ws.Columns(2).ColumnWidth = 15 }
        if ($lastCol -ge 3) { $ws.Range("C1:$($colLetter)1").EntireColumn.ColumnWidth = 11.1 }
        Write-Output "ширины столбцов подогнаны"
    }

    $wb.Save()
    Write-Output "сохранено: $Out"
}
finally {
    if ($wb) { $wb.Close($false) }
    $xl.Quit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xl)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
