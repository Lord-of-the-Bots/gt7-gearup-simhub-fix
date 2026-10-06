# GT7 / GearUP / SimHub telemetry route fix

[Русский](README.ru.md)

PowerShell script for missing Gran Turismo 7 telemetry in SimHub when a Windows PC running GearUP is used as the PlayStation 5 gateway.

The game can work online while Windows sends telemetry requests toward the router instead of the console. This can happen when GearUP places the PS5 in a different IP subnet. The script adds a persistent, direct `/32` route to the console through the selected local network adapter.

This fix requires the PC and PS5 to share the same local network (Layer 2). It does not fix every GearUP or SimHub connection problem.

## Usage

Requires Windows 11, Windows PowerShell 5.1 and administrator access. No additional software is required by the script.

1. [Download the ZIP](https://github.com/Lord-of-the-Bots/gt7-gearup-simhub-fix/archive/refs/heads/main.zip) and extract it.
2. Enable GearUP. Check the current PS5 IPv4 address in the console's network settings.
3. Run `Update-GT7-Route.cmd` and accept the administrator prompt.
4. Enter the PS5 address. If prompted, select the physical adapter connecting the PC to the local network. An existing exact route can be adopted only after confirmation.
5. In SimHub, select Gran Turismo 7, set **Console IP** to the same PS5 address and use UDP port **33740**. Restart SimHub and enter a race.

The route survives a reboot. Run the script again if the console address or PC network adapter changes.

## Removal

Run `Remove-GT7-Route.cmd`. It removes only routes recorded as created or adopted by this tool. State is stored in `C:\ProgramData\GT7-Telemetry-Route\state.json`; keep that file for updates and removal.

## Troubleshooting

The following error can occur in scripts that query an empty persistent route store with a server-side IPv4 filter:

```text
No MSFT_NetRoute objects found with property "AddressFamily" equal to "IPv4"
```

It does not mean the PS5 address was not found. This script enumerates the route store before filtering the results, so an empty store is handled normally.

If telemetry is still missing, check the console address, the selected local adapter, Windows Firewall rules for SimHub and UDP **33739/33740**, and other telemetry applications using the same ports.

## Support

You can support the project with a crypto donation:

BTC (Bitcoin):
1NbtPNkofnKZRjLpULRjhKuAtbh12DovC9

USDT, TRX (TRC20):
TUgM6hPokF1vPUW8CRp77CgvF3YroabwFP

TON:
UQBLdOWJeVeVg4b0-HkQGNVV8HG6-xWS7moZOUfNBz2-Jf3u

ETH (ERC20):
0x14bba7b8b76ea4743a202bdee2144e4d558ddf93

LTC (Litecoin):
LRRS5YBeqfkYpw2jC2bDAWgpcgm7Wpu6pM
