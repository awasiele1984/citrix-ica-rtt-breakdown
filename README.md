# citrix-ica-rtt-breakdown

A single PowerShell script that answers one question: **what do Citrix sessions with a high ICA RTT have in common?**

It reads the Citrix Cloud **Monitor Service OData API** (read-only), stores the samples in a CSV file and shows, per dimension, which share of sessions is "bad":

- Delivery Group, machine, protocol, **EDT/TCP transport** (if your tenant exposes it)
- **Gateway Service PoP** (`ConnectedVia`), StoreFront/Workspace host
- client **country / location**, client subnet, public vs. private address
- Citrix Workspace app version and platform
- hour of day

It also **compares ICA RTT with the latency fields** of the tenant (`IcaLatency`, WAN/DC latency where available): per-group latency, the RTT-minus-latency gap, the correlation and a 2×2 table (RTT high/low × latency high/low) that helps to tell *network-side* from *VDA/session-side* delay.

## Status

Early version. Sign-in and field discovery were confirmed on one real Citrix Cloud tenant. The data-collection and analysis path has been verified on synthetic data and mocked API responses; the first real-tenant run exposed an API limit (`$expand` depth 2) that is fixed in the current version but not yet confirmed live. Treat your first run as a trial, start with `-Discover`, and please open an issue with the (sanitised) error text if something fails.

## Quick start

```powershell
# 1. Create a read-only API client in Citrix Cloud and note your Customer ID (CCID):
#    see docs/HOW_TO_GET_A_TOKEN.md

# 2. See which fields your tenant exposes (writes nothing)
.\Get-IcaRttBreakdown.ps1 -Discover

# 3. Collect the last hour and analyse (answer the wizard: Customer ID, Enter, Client ID, Secret)
.\Get-IcaRttBreakdown.ps1 -Anonymous

# 4. A whole working day, one collection every 30 minutes
.\Get-IcaRttBreakdown.ps1 -Anonymous -Loop -DurationHours 10
```

Per-session data is only kept by Citrix for about an hour, so `-Loop` is how you build a meaningful data set.

## Requirements

- Windows PowerShell 5.1 (developed and tested on PowerShell 7; 5.1 not yet tested), HTTPS access to `api.cloud.com`
- A Citrix Cloud **Customer ID (CCID)** and an **API client** (Client ID + Secret) with *Read Only Administrator*; alternatively the Citrix Remote PowerShell SDK or a pasted token (see the guides)

## Safety and privacy

- **Read-only.** Apart from the token request (one `POST`), the script only sends `GET` requests. It changes nothing in Citrix Cloud or Azure and deletes nothing.
- **Nothing is stored:** Customer ID, token and secret live in memory for the run. No credential is written to disk.
- **Nothing leaves Citrix Cloud:** client IP addresses are not looked up anywhere. Country comes from the tenant or from an optional offline `geo.csv`.
- `-Anonymous` never requests user names. The CSV files still contain **machine names and client IP addresses**, which can identify a person: treat them as personal data and do not commit or share them (`.gitignore` excludes them).

## Documentation

| English | Polski |
|---|---|
| [How to get a token / connect](docs/HOW_TO_GET_A_TOKEN.md) | [Jak połączyć skrypt z Citrix Cloud](docs/JAK_POBRAC_TOKEN.md) |
| [Usage guide](docs/USAGE_GUIDE.md) | [Instrukcja użycia](docs/UZYCIE_SKRYPTU.md) |
| [Full technical documentation](docs/DOCUMENTATION.md) | [Pełna dokumentacja techniczna](docs/DOKUMENTACJA.md) |

## License

[MIT](LICENSE)

## Disclaimer

This is an independent project. It is not affiliated with, endorsed by or supported by Citrix or Cloud Software Group. Citrix, NetScaler and related names are trademarks of their respective owners. Use at your own risk and only on environments you are authorised to analyse.
