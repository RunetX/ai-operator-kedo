<#
.SYNOPSIS
  Загружает надстройку «ИИОператор_КЭДО» из исходников в файловую базу ЗУП.

.DESCRIPTION
  Исходники хранятся в UTF-8 без BOM с LF. Скрипт копирует их в build/, приводит к формату выгрузки
  конфигуратора (UTF-8 с BOM, CRLF), загружает расширение через ibcmd и выключает для него безопасный
  режим и защиту от опасных действий, как у ядра ИИ-оператора. С -Tests загружает ещё расширение тестов.

  ibcmd требует монопольного доступа: клиент 1С на этой базе должен быть закрыт.

.EXAMPLE
  ./build.ps1 -InfoBase 'C:\Bases\ZUP' -User 'Администратор'
  ./build.ps1 -InfoBase 'C:\Bases\ZUP' -User 'Администратор' -Tests
#>
param(
	[Parameter(Mandatory)]
	[string]$InfoBase,
	[string]$User = '',
	[string]$Password = '',
	[switch]$Tests,
	# Версия платформы, например 8.3.27.2214. По умолчанию — самая новая 8.3: платформа 8.5 может
	# перевести файловую базу в свой формат, её указывают только явно.
	[string]$Platform = ''
)

$ErrorActionPreference = 'Stop'

function Find-PlatformFile([string]$Name) {
	if ($Platform) { return "C:\Program Files\1cv8\$Platform\bin\$Name" }
	$found = Get-ChildItem "C:\Program Files\1cv8\*\bin\$Name" -ErrorAction SilentlyContinue |
		Where-Object { $_.Directory.Parent.Name -match '^8\.3\.\d+\.\d+$' } |
		Sort-Object { [version]$_.Directory.Parent.Name } -Descending
	if (-not $found) { throw "Не найдена платформа 8.3 в C:\Program Files\1cv8. Укажите версию платформы: -Platform 8.3.27.2214" }
	return $found[0].FullName
}

$ibcmd = Find-PlatformFile 'ibcmd.exe'
if (-not (Test-Path $ibcmd)) { throw "Не найден ibcmd: $ibcmd" }
if (-not (Test-Path $InfoBase)) { throw "Не найден каталог базы: $InfoBase" }

$projects = [ordered]@{ 'ai-operator-kedo' = 'ИИОператор_КЭДО' }
if ($Tests) { $projects['ai-operator-kedo-tests'] = 'ИИОператор_КЭДО_Тесты' }

$build = Join-Path $PSScriptRoot 'build'
$common = @("--db-path=$InfoBase", "--data=$(Join-Path $build 'ibcmd-data')")
if ($User) { $common += "--user=$User" }
$common += "--password=$Password"

function Invoke-Ibcmd([string[]]$Arguments) {
	# Пустой ввод: ibcmd не должен ждать логин или пароль с клавиатуры.
	$output = '' | & $ibcmd @Arguments @common 2>&1
	$output | ForEach-Object { "  $_" }
	if ($LASTEXITCODE -ne 0) { throw "ibcmd $($Arguments[0..1] -join ' ') завершился с кодом $LASTEXITCODE" }
}

# Конфигуратор ждёт ChildObjects в порядке видов метаданных.
$typeOrder = @('Language', 'Subsystem', 'StyleItem', 'CommonPicture', 'SessionParameter', 'Role', 'CommonTemplate',
	'FilterCriterion', 'CommonModule', 'CommonAttribute', 'ExchangePlan', 'XDTOPackage', 'WebService', 'HTTPService',
	'WSReference', 'EventSubscription', 'ScheduledJob', 'SettingsStorage', 'FunctionalOption',
	'FunctionalOptionsParameter', 'DefinedType', 'CommonCommand', 'CommandGroup', 'Constant', 'CommonForm', 'Catalog',
	'Document', 'DocumentNumerator', 'Sequence', 'DocumentJournal', 'Enum', 'Report', 'DataProcessor',
	'InformationRegister', 'AccumulationRegister', 'ChartOfCharacteristicTypes', 'ChartOfAccounts', 'AccountingRegister',
	'ChartOfCalculationTypes', 'BusinessProcess', 'Task')
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

foreach ($project in $projects.GetEnumerator()) {
	$src = Join-Path $PSScriptRoot "src\$($project.Key)"
	$out = Join-Path $build $project.Key
	$extension = $project.Value

	if (Test-Path $out) { [IO.Directory]::Delete($out, $true) }
	New-Item -ItemType Directory -Force $out | Out-Null
	Get-ChildItem $src -Recurse -File | ForEach-Object {
		$target = Join-Path $out $_.FullName.Substring($src.Length + 1)
		New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
		if ($_.Extension -in '.xml', '.bsl', '.txt') {
			$text = [IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n" -replace "`n", "`r`n"
			[IO.File]::WriteAllText($target, $text, $utf8Bom)
		} else {
			Copy-Item $_.FullName $target
		}
	}
	$configPath = Join-Path $out 'Configuration.xml'
	$config = [IO.File]::ReadAllText($configPath)
	$config = [regex]::Replace($config, '(?s)(<ChildObjects>\r\n)(.*?)(\r\n\t\t</ChildObjects>)', {
		param($m)
		$items = $m.Groups[2].Value -split "`r`n" | Where-Object { $_.Trim() }
		$sorted = $items | Sort-Object -Stable { $typeOrder.IndexOf(([regex]::Match($_, '<(\w+)>')).Groups[1].Value) }
		$m.Groups[1].Value + ($sorted -join "`r`n") + $m.Groups[3].Value
	})
	[IO.File]::WriteAllText($configPath, $config, $utf8Bom)

	Write-Host ">> $extension -> $InfoBase"
	Invoke-Ibcmd @('config', 'import', "--extension=$extension", $out)
	Invoke-Ibcmd @('config', 'apply', "--extension=$extension", '--force')
	Invoke-Ibcmd @('config', 'extension', 'update', "--name=$extension", '--safe-mode=no', '--unsafe-action-protection=no')
}
Write-Host 'Готово.'
