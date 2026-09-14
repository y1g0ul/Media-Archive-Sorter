# Media Archive Sorter

Небольшой PowerShell-скрипт для сборки фото- и видеоархива с нескольких дисков.

Скрипт использует **ExifTool** для чтения дат файлов, копирует медиа в структуру `тип / год / месяц`, отдельно складывает DVD (`VOB`) и файлы с ненадёжной датой.

Исходники **не перемещаются и не удаляются**. Системные каталоги Windows вроде `$RECYCLE.BIN` и `System Volume Information` игнорируются. Каждый запуск создаёт аудит и лог копирования.

## Что нужно

- Windows + PowerShell 5.1+
- [ExifTool](https://exiftool.org/)
- достаточно места на диске назначения

## Конфиг

Скопируй:

```text
config.example.json
```

в:

```text
config.json
```

и замени шаблонные пути на свои.

Пример:

```json
{
  "exifTool": "C:\\PATH\\TO\\exiftool.exe",
  "sources": [
    "D:\\PATH\\TO\\SOURCE_1",
    "E:\\PATH\\TO\\SOURCE_2"
  ],
  "destinationRoot": "F:\\PATH\\TO\\ARCHIVE\\Sorted",
  "logDir": "F:\\PATH\\TO\\ARCHIVE\\logs",
  "verifyHashAfterCopy": false
}
```

Кратко о параметрах:

- `exifTool` — путь к `exiftool.exe`.
- `sources` — одна или несколько папок/дисков с исходными файлами.
- `destinationRoot` — куда складывать отсортированный архив.
- `logDir` — куда сохранять аудит и логи.
- `verifyHashAfterCopy` — проверка целостности после копирования:
  - `false` — проверяется размер файла; быстрее.
  - `true` — дополнительно сравнивается **SHA-256** исходника и копии; надёжнее, но заметно медленнее.
- `ignoredDirectories` — папки, которые нужно пропускать.
- `extensions` — списки поддерживаемых фото, видео, DVD и аудиоформатов.

## Запуск

```powershell
powershell -ExecutionPolicy Bypass -File .\Sort-Media.ps1
```

Другой конфиг можно указать так:

```powershell
.\Sort-Media.ps1 -Config .\my-config.json
```

Проверку SHA-256 можно включить и прямо при запуске:

```powershell
.\Sort-Media.ps1 -VerifyHashAfterCopy
```
