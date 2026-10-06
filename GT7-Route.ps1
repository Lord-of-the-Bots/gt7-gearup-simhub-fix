#requires -Version 5.1
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'

function Assert-ConsoleIP {
    param([string]$Value)
    if ($Value -notmatch '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$') {
        throw 'Enter the full IPv4 address from the PS5 network settings.'
    }
    $octets = @($Value.Split('.') | ForEach-Object { [int]$_ })
    if (@($octets | Where-Object { $_ -gt 255 }).Count -gt 0) {
        throw 'Each address octet must be between 0 and 255.'
    }
    $private = $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    if (-not $private) {
        throw 'Enter the private LAN address of the PS5: 10.x.x.x, 172.16-31.x.x or 192.168.x.x.'
    }
}

function Read-RouteState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Version = 1; LastConsoleIP = ''; Routes = @() }
    }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $state -or $state.Version -ne 1 -or
            $null -eq $state.PSObject.Properties['Routes'] -or
            $null -eq $state.PSObject.Properties['LastConsoleIP']) { throw 'Invalid state format.' }
        if (-not [string]::IsNullOrWhiteSpace($state.LastConsoleIP)) {
            Assert-ConsoleIP $state.LastConsoleIP
        }
        foreach ($record in @($state.Routes)) {
            if ($record.DestinationPrefix -notmatch '^(.+)/32$') { throw 'Expected a /32 route.' }
            Assert-ConsoleIP $Matches[1]
            $parsedGuid = [guid]::Empty
            if (-not [guid]::TryParse([string]$record.InterfaceGuid, [ref]$parsedGuid)) {
                throw 'Invalid adapter identifier.'
            }
        }
        $state.Routes = @($state.Routes)
        return $state
    } catch {
        throw "Cannot read route state at $Path. No settings changed. $($_.Exception.Message)"
    }
}

function Save-RouteState {
    param($State, [string]$Path)
    $folder = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $temporary = Join-Path $folder ([guid]::NewGuid().ToString() + '.tmp')
    try {
        $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-RecordKey {
    param($Record)
    return ([string]$Record.InterfaceGuid).ToLowerInvariant() + '|' + $Record.DestinationPrefix
}

function Resolve-RecordIndex {
    param($Record)
    $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object {
        ([string]$_.InterfaceGuid) -eq ([string]$Record.InterfaceGuid)
    })
    if ($adapters.Count -ne 1) {
        throw "Adapter '$($Record.InterfaceAlias)' not found. Route $($Record.DestinationPrefix) was not changed."
    }
    return [int]$adapters[0].ifIndex
}

function Get-ExactRoute {
    param([string]$Prefix, [int]$Index, [string]$Store)
    # Filtering AddressFamily in the cmdlet throws on an empty PersistentStore.
    Get-NetRoute -PolicyStore $Store -ErrorAction Stop |
        Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.DestinationPrefix -eq $Prefix -and
            $_.InterfaceIndex -eq $Index -and $_.NextHop -eq '0.0.0.0' -and $_.Protocol -eq 'NetMgmt' }
}

function Remove-RecordRoutes {
    param($Record)
    $index = Resolve-RecordIndex $Record
    foreach ($store in @('PersistentStore', 'ActiveStore')) {
        if (@(Get-ExactRoute $Record.DestinationPrefix $index $store).Count -gt 0) {
            Remove-NetRoute -DestinationPrefix $Record.DestinationPrefix -InterfaceIndex $index `
                -NextHop '0.0.0.0' -Protocol NetMgmt -PolicyStore $store -Confirm:$false -ErrorAction Stop
        }
    }
    foreach ($store in @('PersistentStore', 'ActiveStore')) {
        if (@(Get-ExactRoute $Record.DestinationPrefix $index $store).Count -gt 0) {
            throw "Could not remove $($Record.DestinationPrefix) from $store."
        }
    }
}

function Ensure-PermanentRoute {
    param($Record)
    $index = Resolve-RecordIndex $Record
    $active = @(Get-ExactRoute $Record.DestinationPrefix $index 'ActiveStore').Count -gt 0
    $persistent = @(Get-ExactRoute $Record.DestinationPrefix $index 'PersistentStore').Count -gt 0
    if ($active -and $persistent) { return }
    try {
        if ($persistent) {
            New-NetRoute -DestinationPrefix $Record.DestinationPrefix -InterfaceIndex $index `
                -NextHop '0.0.0.0' -Protocol NetMgmt -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        } else {
            # Replace a temporary route before creating its persistent equivalent.
            if ($active) { Remove-RecordRoutes $Record }
            New-NetRoute -DestinationPrefix $Record.DestinationPrefix -InterfaceIndex $index `
                -NextHop '0.0.0.0' -Protocol NetMgmt -ErrorAction Stop | Out-Null
        }
        foreach ($store in @('ActiveStore', 'PersistentStore')) {
            if (@(Get-ExactRoute $Record.DestinationPrefix $index $store).Count -eq 0) {
                throw "Route is missing from $store."
            }
        }
    } catch {
        $originalError = $_
        if ($active -and @(Get-ExactRoute $Record.DestinationPrefix $index 'ActiveStore').Count -eq 0) {
            try {
                New-NetRoute -DestinationPrefix $Record.DestinationPrefix -InterfaceIndex $index `
                    -NextHop '0.0.0.0' -Protocol NetMgmt -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                Write-Warning 'Temporary route restored; could not make it persistent.'
            } catch { Write-Warning "Could not restore route: $($_.Exception.Message)" }
        }
        throw $originalError
    }
}

function Add-OwnedRecord {
    param($State, $Record, [string]$Path)
    $key = Get-RecordKey $Record
    if (@($State.Routes | Where-Object { (Get-RecordKey $_) -eq $key }).Count -eq 0) {
        $State.Routes = @($State.Routes) + @($Record)
        Save-RouteState $State $Path
    }
}

function Update-ConsoleRoute {
    param($State, [string]$ConsoleIP, $Adapter, [string]$Path)
    Assert-ConsoleIP $ConsoleIP
    $record = [pscustomobject]@{
        DestinationPrefix = "$ConsoleIP/32"
        InterfaceGuid = [string]$Adapter.InterfaceGuid
        InterfaceAlias = [string]$Adapter.Name
    }
    $key = Get-RecordKey $record
    $index = Resolve-RecordIndex $record
    $owned = @($State.Routes | Where-Object { (Get-RecordKey $_) -eq $key }).Count -gt 0
    $active = @(Get-ExactRoute $record.DestinationPrefix $index 'ActiveStore').Count -gt 0
    $persistent = @(Get-ExactRoute $record.DestinationPrefix $index 'PersistentStore').Count -gt 0
    if (-not $owned -and ($active -or $persistent)) {
        throw 'This route already exists and is not managed by the script. It was left unchanged.'
    }
    # Record ownership first so a partially created route can still be removed.
    Add-OwnedRecord $State $record $Path
    Ensure-PermanentRoute $record
    $State.LastConsoleIP = $ConsoleIP
    Save-RouteState $State $Path
    foreach ($old in @($State.Routes)) {
        if ((Get-RecordKey $old) -ne $key) {
            try {
                Remove-RecordRoutes $old
                $oldKey = Get-RecordKey $old
                $State.Routes = @($State.Routes | Where-Object { (Get-RecordKey $_) -ne $oldKey })
                Save-RouteState $State $Path
            } catch {
                Write-Warning "New route is ready; old route remains in the state file: $($_.Exception.Message)"
            }
        }
    }
}

function Select-LanAdapter {
    $candidates = @(foreach ($adapter in @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' })) {
        $config = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
        if ($null -ne $config.IPv4Address -and $null -ne $config.IPv4DefaultGateway) {
            [pscustomobject]@{ Adapter = $adapter; Config = $config }
        }
    })
    if ($candidates.Count -eq 0) {
        throw 'No active physical adapter with IPv4 and a gateway. Connect the PC to the same LAN as the PS5.'
    }
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $item = $candidates[$i]
        Write-Host ("{0}. {1} | IP: {2} | gateway: {3}" -f ($i + 1), $item.Adapter.Name,
            ($item.Config.IPv4Address.IPAddress -join ', '), ($item.Config.IPv4DefaultGateway.NextHop -join ', '))
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    while ($true) {
        $choice = Read-Host 'Select the adapter connected to the same LAN as the PS5'
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
            return $candidates[$number - 1]
        }
        Write-Host 'Enter a number from the list.'
    }
}

function Import-ExistingRoute {
    param($State, [string]$ConsoleIP, $Adapter, [string]$Path)
    $record = [pscustomobject]@{
        DestinationPrefix = "$ConsoleIP/32"
        InterfaceGuid = [string]$Adapter.InterfaceGuid
        InterfaceAlias = [string]$Adapter.Name
    }
    $key = Get-RecordKey $record
    if (@($State.Routes | Where-Object { (Get-RecordKey $_) -eq $key }).Count -gt 0) { return }
    $index = Resolve-RecordIndex $record
    if (@(Get-ExactRoute $record.DestinationPrefix $index 'ActiveStore').Count -gt 0 -or
        @(Get-ExactRoute $record.DestinationPrefix $index 'PersistentStore').Count -gt 0) {
        Write-Host "An existing direct route to $ConsoleIP was found on $($Adapter.Name)."
        $answer = Read-Host 'Allow this script to manage and remove it? [Y/N]'
        if ($answer -match '^(y|yes)$') {
            Add-OwnedRecord $State $record $Path
        } else {
            throw 'Existing route left unchanged. Setup cancelled.'
        }
    }
}

function Remove-AllOwnedRoutes {
    param($State, [string]$Path)
    $failed = $false
    foreach ($record in @($State.Routes)) {
        try {
            Remove-RecordRoutes $record
            $key = Get-RecordKey $record
            $State.Routes = @($State.Routes | Where-Object { (Get-RecordKey $_) -ne $key })
            Save-RouteState $State $Path
        } catch {
            $failed = $true
            Write-Warning $_.Exception.Message
        }
    }
    if ($failed) { throw 'Some routes could not be removed. Their records were kept for another attempt.' }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        if ($Remove) { $arguments += ' -Remove' }
        $process = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs -WindowStyle Normal -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    } catch {
        Write-Host "Administrator launch cancelled or failed: $($_.Exception.Message)"
        Read-Host 'Press Enter to exit' | Out-Null
        exit 1
    }
}

$exitCode = 0
try {
    Write-Host 'GT7 / GearUP / SimHub - telemetry route' -ForegroundColor Cyan
    Write-Host ''
    $statePath = Join-Path $env:ProgramData 'GT7-Telemetry-Route\state.json'
    $state = Read-RouteState $statePath
    if ($Remove) {
        if (@($state.Routes).Count -eq 0) {
            Write-Host 'No managed routes in the state file.'
        } else {
            Remove-AllOwnedRoutes $state $statePath
            Write-Host 'All managed routes removed.' -ForegroundColor Green
        }
    } else {
        Write-Host 'Start GearUP and read the current IPv4 address from the PS5 network settings.'
        Write-Host 'Enter Q to cancel.'
        while ($true) {
            $prompt = 'PS5 IP'
            if (-not [string]::IsNullOrWhiteSpace($state.LastConsoleIP)) { $prompt += " [$($state.LastConsoleIP)]" }
            $consoleIP = (Read-Host $prompt).Trim()
            if ($consoleIP -eq 'q') { return }
            if ([string]::IsNullOrWhiteSpace($consoleIP)) { $consoleIP = $state.LastConsoleIP }
            try { Assert-ConsoleIP $consoleIP; break } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
        }
        $selected = Select-LanAdapter
        $localAddresses = @(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $_.IPAddress })
        $gateways = @(Get-NetRoute -AddressFamily IPv4 | Where-Object {
            $_.DestinationPrefix -eq '0.0.0.0/0'
        } | ForEach-Object { $_.NextHop })
        if ($localAddresses -contains $consoleIP -or $gateways -contains $consoleIP) {
            throw 'This is a PC or gateway address. Enter the PS5 address.'
        }
        Import-ExistingRoute $state $consoleIP $selected.Adapter $statePath
        Update-ConsoleRoute $state $consoleIP $selected.Adapter $statePath
        Write-Host ''
        Write-Host 'Persistent route saved.' -ForegroundColor Green
        Write-Host "SimHub -> Gran Turismo 7 -> Console IP: $consoleIP" -ForegroundColor Cyan
        Write-Host 'UDP port: 33740. Apply the settings in SimHub and check telemetry during a race.'
        Write-Host 'Run Update-GT7-Route.cmd again if the console IP or LAN adapter changes.'
    }
    Write-Host "Route state: $statePath"
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Write-Host ''
    Read-Host 'Press Enter to exit' | Out-Null
}
exit $exitCode
