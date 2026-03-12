[CmdletBinding()]
param(
  [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

function Get-JsonValue {
  param(
    [object]$Object,
    [string[]]$PathParts
  )

  $current = $Object
  foreach ($part in $PathParts) {
    if ($null -eq $current) { return $null }
    $prop = $current.PSObject.Properties[$part]
    if ($null -eq $prop) { return $null }
    $current = $prop.Value
  }
  return $current
}

function Read-SettingsSummary {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{
      path = $Path
      exists = $false
    }
  }

  try {
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return [pscustomobject]@{
      path = $Path
      exists = $true
      schema_version = Get-JsonValue $json @('schema_version')
      mode_manual_override = Get-JsonValue $json @('mode', 'manual_override')
      mode_last_detected = Get-JsonValue $json @('mode', 'last_detected')
      windows_project_dir = Get-JsonValue $json @('profiles', 'wsl_docker', 'windows_project_dir')
      wsl_project_dir = Get-JsonValue $json @('profiles', 'wsl_docker', 'wsl_project_dir')
      wsl_native_project_dir = Get-JsonValue $json @('profiles', 'wsl_native', 'wsl_native_project_dir')
      win_native_project_dir = Get-JsonValue $json @('profiles', 'win_native', 'win_native_project_dir')
      win_native_openclaw_command = Get-JsonValue $json @('profiles', 'win_native', 'win_native_openclaw_command')
      win_native_install_command = Get-JsonValue $json @('profiles', 'win_native', 'win_native_install_command')
      dashboard_gateway_root_url = Get-JsonValue $json @('dashboard', 'gateway_root_url')
      legacy_docker_gateway_root_url = Get-JsonValue $json @('docker', 'gateway_root_url')
    }
  } catch {
    return [pscustomobject]@{
      path = $Path
      exists = $true
      parse_error = $_.Exception.Message
    }
  }
}

function Get-DiffKeys {
  param(
    [object]$Left,
    [object]$Right
  )

  $keys = @(
    'mode_manual_override',
    'mode_last_detected',
    'windows_project_dir',
    'wsl_project_dir',
    'wsl_native_project_dir',
    'win_native_project_dir',
    'win_native_openclaw_command',
    'win_native_install_command',
    'dashboard_gateway_root_url',
    'legacy_docker_gateway_root_url'
  )

  $diff = @()
  foreach ($key in $keys) {
    $leftProp = $Left.PSObject.Properties[$key]
    $rightProp = $Right.PSObject.Properties[$key]
    $leftValue = if ($null -ne $leftProp) { $leftProp.Value } else { $null }
    $rightValue = if ($null -ne $rightProp) { $rightProp.Value } else { $null }
    if ("$leftValue" -ne "$rightValue") {
      $diff += $key
    }
  }
  return $diff
}

$packageDir = $PSScriptRoot
$packageExe = Join-Path $packageDir 'openclaw-control-panel.exe'
$packageSettings = Join-Path $packageDir 'openclaw-control-panel-settings.json'

$observedActiveCandidates = @(
  'E:\OPC\panel\openclaw-control-panel-settings.json'
)

$foundPanelExes = @()
if (Test-Path -LiteralPath $packageExe) {
  $foundPanelExes += $packageExe
}

$settingsCandidates = @($packageSettings) + $observedActiveCandidates | Select-Object -Unique
$settingsSummaries = @($settingsCandidates | ForEach-Object { Read-SettingsSummary $_ })
$activeSettings = $settingsSummaries | Where-Object { $_.exists -and $_.path -ne $packageSettings } | Select-Object -First 1
$packageSettingsSummary = $settingsSummaries | Where-Object { $_.path -eq $packageSettings } | Select-Object -First 1

$notes = New-Object System.Collections.Generic.List[string]

if ($activeSettings) {
  $notes.Add("Observed active settings file: $($activeSettings.path)")
  if ($activeSettings.path -ne $packageSettings) {
    $notes.Add('Do not assume the EXE-directory settings file is the one currently in use.')
  }
} else {
  $notes.Add('No observed active settings file was found in the known runtime location list.')
}

if ($packageSettingsSummary.exists -and $activeSettings) {
  $diffKeys = Get-DiffKeys $packageSettingsSummary $activeSettings
  if ($diffKeys.Count -gt 0) {
    $notes.Add('Package settings and active settings differ: ' + ($diffKeys -join ', '))
  }
}

if ($activeSettings -and -not [string]::IsNullOrWhiteSpace($activeSettings.win_native_project_dir)) {
  $notes.Add('In current panel builds, the startup banner "项目目录 / Project dir" may still be driven by profiles.wsl_docker.windows_project_dir rather than profiles.win_native.win_native_project_dir.')
}

if ($activeSettings) {
  if (-not [string]::IsNullOrWhiteSpace($activeSettings.legacy_docker_gateway_root_url) -and [string]::IsNullOrWhiteSpace($activeSettings.dashboard_gateway_root_url)) {
    $notes.Add('gateway_root_url appears only under docker.*; current builds expect dashboard.gateway_root_url.')
  }
}

$report = [pscustomobject]@{
  package_dir = $packageDir
  panel_exe_exists = Test-Path -LiteralPath $packageExe
  panel_exe = $packageExe
  package_settings = $packageSettingsSummary
  observed_active_settings = $activeSettings
  all_settings_candidates = $settingsSummaries
  notes = @($notes)
}

if ($AsJson) {
  $report | ConvertTo-Json -Depth 8
  exit 0
}

Write-Host ('Package dir: ' + $report.package_dir)
Write-Host ('Panel EXE:   ' + $report.panel_exe)
Write-Host ('EXE exists:  ' + ($(if ($report.panel_exe_exists) { 'yes' } else { 'no' })))
Write-Host ''

foreach ($summary in $settingsSummaries) {
  Write-Host ('Settings:    ' + $summary.path)
  Write-Host ('Exists:      ' + ($(if ($summary.exists) { 'yes' } else { 'no' })))
  if ($summary.PSObject.Properties['parse_error']) {
    Write-Host ('Parse error: ' + $summary.parse_error)
  } elseif ($summary.exists) {
    Write-Host ('Mode:        ' + $summary.mode_manual_override)
    Write-Host ('Banner dir:  ' + $summary.windows_project_dir)
    Write-Host ('WSL native:  ' + $summary.wsl_native_project_dir)
    Write-Host ('Win native:  ' + $summary.win_native_project_dir)
    Write-Host ('Gateway URL: ' + $summary.dashboard_gateway_root_url)
  }
  Write-Host ''
}

Write-Host 'Notes:'
foreach ($note in $notes) {
  Write-Host ('- ' + $note)
}
