@echo off
chcp 65001 >nul
title Confluence tree export
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-ConfluenceTree.ps1"
echo.
pause >nul
