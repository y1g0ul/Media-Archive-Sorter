# Media Archive Sorter

Небольшой PowerShell-скрипт для сборки фото и видеоархива с нескольких дисков. Использует **ExifTool** для чтения дат, копирует файлы в структуру `тип / год / месяц`, отдельно складывает DVD (`VOB`) и файлы с ненадёжной датой.

Исходники **не перемещаются и не удаляются**. Системные каталоги Windows (`$RECYCLE.BIN`, `System Volume Information`) игнорируются, а каждый запуск сохраняет аудит и лог копирования.

## Что нужно

- Windows + PowerShell 5.1+
- [ExifTool](https://exiftool.org/)
- достаточно места на диске назначения

## Запуск

1. Скопируй `config.example.json` в `config.json`.
2. Укажи в нём путь к ExifTool, источники, папку назначения и логов.
3. Запусти:

```powershell
powershell -ExecutionPolicy Bypass -File .\Sort-Media.ps1
```

Другой конфиг можно передать так:

```powershell
.\Sort-Media.ps1 -Config .\my-config.json
```

Основные пути можно передать и напрямую:

```powershell
.\Sort-Media.ps1 `
  -ExifTool "C:\Tools\exiftool.exe" `
  -Sources "D:\Media","F:\" `
  -DestinationRoot "G:\Archive\Sorted" `
  -LogDir "G:\Archive\logs"
```

Расширения и исключаемые каталоги настраиваются в `config.json`.
