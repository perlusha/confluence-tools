# Выгрузка таблиц Confluence в Excel — настройка доступа

Скрипт: `Export-ConfluenceTables.ps1`
Инструкция: как получить Personal Access Token (PAT) и положить его в переменную окружения.

---

## Почему нужен токен

Confluence REST API **не использует браузерную сессию**. Тот факт, что страница открывается
у вас в браузере (в т.ч. через SSO), скрипту не помогает: HTTP-запрос без токена получит
`401 Unauthorized`. Поэтому нужен PAT — он действует **в пределах ваших прав**: скрипт увидит
ровно те страницы, которые видите вы.

Ваш Confluence — **Server/DC**: `https://confluence.example.com`, авторизация `Bearer <PAT>`.

---

## Шаг 1. Получить PAT

1. Откройте `https://confluence.example.com` и войдите как обычно.
2. Аватар в правом верхнем углу → **Настройки** (Settings).
3. В левом меню — **Личные токены доступа** (Personal Access Tokens).
   Если пункта нет: адрес страницы обычно
   `https://confluence.example.com/plugins/personalaccesstokens/usertokens.action`
   (может отличаться в зависимости от версии).
4. **Создать токен** (Create token):
   - **Имя** — понятное, например `excel-export`.
   - **Срок действия** — поставьте конечный (месяц/полгода), не «бессрочно».
5. Нажмите создать и **скопируйте токен сразу** — он показывается один раз, потом невосстановим.

Если пункта «Личные токены доступа» нет вообще — PAT отключены администратором;
обратитесь к администратору Confluence.

---

## Шаг 2. Подготовить `creds.dat` (если его ещё нет)

`creds.dat` — файл с токеном, зашифрованным средствами Windows (DPAPI). Внутри — JSON
с одним ключом `CONFLUENCE_PERSONAL_TOKEN`, значение — строка из `ConvertFrom-SecureString`.
Путь: `%LOCALAPPDATA%\confluence-mcp\creds.dat`.

Проверить, есть ли он уже:

```powershell
Test-Path "$env:LOCALAPPDATA\confluence-mcp\creds.dat"
```

Если `True` — создавать ничего не нужно, переходите к шагу 3.

Если `False` — создайте. Токен вводится скрытно (`Read-Host -AsSecureString`) и на экран
не выводится, в историю команд тоже не попадает:

```powershell
$root = "$env:LOCALAPPDATA\confluence-mcp"
New-Item -ItemType Directory -Path $root -Force | Out-Null

$secure = Read-Host "Вставьте Confluence PAT (ввод скрыт)" -AsSecureString
@{ CONFLUENCE_PERSONAL_TOKEN = ($secure | ConvertFrom-SecureString) } |
    ConvertTo-Json | Set-Content "$root\creds.dat" -Encoding utf8
```

Заменить токен в уже существующем `creds.dat` (остальные ключи сохраняются):

```powershell
$root = "$env:LOCALAPPDATA\confluence-mcp"
$creds = Get-Content "$root\creds.dat" -Raw | ConvertFrom-Json
$creds.CONFLUENCE_PERSONAL_TOKEN =
    (Read-Host "Новый Confluence PAT (ввод скрыт)" -AsSecureString | ConvertFrom-SecureString)
$creds | ConvertTo-Json | Set-Content "$root\creds.dat" -Encoding utf8
```

Проверить, что файл читается и токен расшифровывается (сам токен не печатаем):

```powershell
$creds = Get-Content "$env:LOCALAPPDATA\confluence-mcp\creds.dat" -Raw | ConvertFrom-Json
"ключи: $($creds.PSObject.Properties.Name -join ', ')"
$sec = $creds.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
$tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
"длина токена: $($tok.Length)"
```

Ожидается `ключи: CONFLUENCE_PERSONAL_TOKEN` и непустая `длина токена:`.

Важно про `creds.dat`:

- Шифрование **DPAPI** привязано к пользователю **и** машине: файл, скопированный на другой
  ПК или под другую учётную запись, **не расшифруется**. Это не переносимый формат — токен
  на другой машине нужно вводить заново.
- Токен внутри не читается глазами, но файл всё равно не коммитьте в git и никуда не выкладывайте.
- После правки `creds.dat` **перезапустите opencode**, чтобы MCP-сервер Confluence перечитал токен.

---

## Шаг 3. Положить токен в переменную окружения

Используется переменная **`CONFLUENCE_PERSONAL_TOKEN`** (плюс `CONFLUENCE_URL`) —
те же имена, что у уже настроенного MCP-сервера Confluence.

### Вариант A (рекомендуется): взять токен из существующего `creds.dat`

На этой машине токен уже сохранён в `%LOCALAPPDATA%\confluence-mcp\creds.dat`
(см. шаг 2), зашифрованный DPAPI. Расшифровать его может только ваш пользователь на этой машине.
Выгрузить в текущую сессию, **не показывая токен на экране**:

```powershell
$enc = Get-Content "$env:LOCALAPPDATA\confluence-mcp\creds.dat" -Raw | ConvertFrom-Json
$sec = $enc.CONFLUENCE_PERSONAL_TOKEN | ConvertTo-SecureString
$env:CONFLUENCE_PERSONAL_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
$env:CONFLUENCE_URL = 'https://confluence.example.com'
```

Действует до закрытия окна PowerShell. Плюс: токен нигде не лежит открытым текстом.
Минус: нужно выполнять в каждом новом окне (либо положить эти строки в `$PROFILE`).

### Вариант B: постоянно, для текущего пользователя

```powershell
[Environment]::SetEnvironmentVariable('CONFLUENCE_PERSONAL_TOKEN', '<вставьте-токен>', 'User')
[Environment]::SetEnvironmentVariable('CONFLUENCE_URL', 'https://confluence.example.com', 'User')
```

**Перезапустите терминал** — переменные читаются при старте процесса.

Учтите: `User`-scope хранит значение **открытым текстом** в реестре
(`HKCU\Environment`). Если это неприемлемо — используйте вариант A.

### Вариант C: только на текущую сессию

```powershell
$env:CONFLUENCE_PERSONAL_TOKEN = '<вставьте-токен>'
$env:CONFLUENCE_URL = 'https://confluence.example.com'
```

### Вариант D: через GUI

`Win+R` → `sysdm.cpl` → **Дополнительно** → **Переменные среды…** →
в разделе «Переменные среды пользователя» → **Создать**:
- Имя: `CONFLUENCE_PERSONAL_TOKEN`, Значение: токен
- Имя: `CONFLUENCE_URL`, Значение: `https://confluence.example.com`

---

## Шаг 4. Проверить

Токен на экран не выводим — только факт успеха:

```powershell
$h = @{ Authorization = "Bearer $env:CONFLUENCE_PERSONAL_TOKEN" }
try {
    $me = Invoke-RestMethod -Uri "$env:CONFLUENCE_URL/rest/api/user/current" -Headers $h
    "OK: $($me.displayName) ($($me.name))"
} catch {
    "ОШИБКА: HTTP $($_.Exception.Response.StatusCode.value__)"
}
```

Ожидается `OK: <ваше имя> (<логин>)`.

---

## Шаг 5. Запуск скрипта

```powershell
cd "C:\Tools"
.\Export-ConfluenceTables.ps1 -Page 'https://confluence.example.com/pages/123456789/Название' -FirstRowHeader
```

Скрипт сам возьмёт `CONFLUENCE_URL` и `CONFLUENCE_PERSONAL_TOKEN` из окружения.
Полезные ключи: `-AsText` (сохранить ведущие нули: коды, ИНН, артикулы),
`-OutFile .\report.xlsx`, `-KeepHtml` (сохранить исходный HTML для отладки).

---

## Безопасность

- Токен = ваши права в Confluence. Не вставляйте его в чаты, письма, Confluence, Jira и
  в запросы к внешним сервисам.
- **Не передавайте токен ключом `-Token` из командной строки**: он попадёт в историю
  PowerShell (`Get-History`) и виден в списке процессов. Предпочитайте переменную окружения.
- Не коммитьте токен в git. Если папка под контролем версий — добавьте `.gitignore`
  и проверьте `git status` перед коммитом.
- `User`-scope переменные и `$PROFILE` хранят токен открытым текстом;
  `creds.dat` (DPAPI) — шифрованно и привязан к пользователю+машине.
- Срок действия ставьте конечным. При подозрении на утечку — **отзовите токен**
  на той же странице «Личные токены доступа» и создайте новый.

---

## Если не работает

| Симптом | Причина и что делать |
|---|---|
| `401 Unauthorized` | Токен неверный, просрочен или отозван. Перевыпустите (шаг 1) и обновите переменную. Проверьте, что не скопировали лишний пробел/перевод строки. |
| `403 Forbidden` | Токен валиден, но у вас нет прав на эту страницу. Проверьте доступ в браузере под своей учёткой. |
| `404 Not Found` | Неверный `CONFLUENCE_URL` или ID страницы. Проверьте URL: ID — число в `/pages/<ID>/`. |
| Переменная пустая после `SetEnvironmentVariable` | Не перезапущен терминал (для `User`-scope). Проверьте: `$env:CONFLUENCE_PERSONAL_TOKEN.Length` — должно быть > 0. |
| Ошибка TLS/сертификата | Если у вас внутренний CA — лучше добавить его в доверенные. В крайнем случае `-Insecure` (отключает проверку сертификата — не для постоянного использования). |
| `Не задан токен` от скрипта | Переменная не видна в этом процессе. Проверьте шаг 3, затем перезапустите терминал. |
