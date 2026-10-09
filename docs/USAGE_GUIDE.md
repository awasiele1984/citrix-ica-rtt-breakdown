# Get-IcaRttBreakdown.ps1: detailed usage guide

English edition of `UZYCIE_SKRYPTU.md`.

The script answers one question: **what do Citrix sessions with a high ICA RTT have in common?** (Delivery Group, Gateway Service PoP, EDT/TCP transport, country, client subnet, Workspace app version, hour of day…). It pulls data from Citrix Cloud (Monitor Service OData), stores it in a CSV file and shows in which group the share of "bad" sessions differs from the rest.

Files in the set:

| File | Contents |
|---|---|
| `Get-IcaRttBreakdown.ps1` | the script |
| `HOW_TO_GET_A_TOKEN.md` (Polish: `JAK_POBRAC_TOKEN.md`) | signing in: Customer ID, Citrix SDK, API client, token |
| `USAGE_GUIDE.md` (Polish: `UZYCIE_SKRYPTU.md`) | this file |
| `DOCUMENTATION.md` (Polish: `DOKUMENTACJA.md`) | full technical documentation |

---

## 1. What the script does and does not do

- **Read-only.** The only request that is not a read is the token request (a POST for a token). Everything else is a GET to `api.cloud.com`. The script creates, changes and deletes nothing in Citrix Cloud or in Azure.
- **Locally it writes only CSV files** (see section 6). It deletes nothing, installs nothing, launches nothing.
- **It remembers nothing**: not the Customer ID, not the token, not passwords. The wizard asks every time, and the data lives in memory only for the duration of the run.
- **It sends nothing outside Citrix Cloud.** Client IP addresses are not looked up in any external service.
- The script has not yet been run against a real tenant. I tested the logic on synthetic data and on mocked requests. That is why you should **always start with `-Discover`** (section 4).

## 2. Requirements

1. **Windows with PowerShell 5.1** (`powershell.exe`). The safest choice. Per the documentation, newer Citrix SDK versions also work in PowerShell up to 7.3.
2. **For sign-in option 1** (window): the Citrix Remote PowerShell SDK installed. Instructions, link and restrictions: `HOW_TO_GET_A_TOKEN.md`.
   Or an API client (options 2 and 3), also described in `HOW_TO_GET_A_TOKEN.md`.
3. **HTTPS access to `api.cloud.com`** (port 443) from the machine where you run the script.
4. An account with access to Monitor/Director (read access is enough).

If Windows blocks the downloaded script:

```powershell
Unblock-File .\Get-IcaRttBreakdown.ps1
# if the execution policy still blocks it, for this window only:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 3. Preparation (once)

1. Copy `Get-IcaRttBreakdown.ps1` to a separate folder, for example `C:\Citrix\rtt`. The CSV files are created in the **directory you are in** (the current directory), so go to that folder:
   ```powershell
   cd C:\Citrix\rtt
   ```
2. Find your **Customer ID** (see `HOW_TO_GET_A_TOKEN.md`, step "0. Find your Customer ID").
3. (Usually not needed) A `geo.csv` file supplies the client's country in anonymous mode **only when the tenant does not provide it**. Many tenants expose `ClientLocationCountry` / `ClientLocationCity` themselves; the plan printed at startup tells you ("country from tenant fields …"). Section 8.

## 4. First run: `-Discover`

```powershell
.\Get-IcaRttBreakdown.ps1 -Discover
```

The wizard asks for the Customer ID and a sign-in method (section 5). Then the script **only fetches the field description** (`$metadata`) and prints what your tenant exposes:

- connection and client fields (client address, Workspace app version, gateway host…),
- whether there is a **transport indicator EDT/UDP vs TCP** (fields whose names contain `Transport`, `Udp`, `Edt`, `Rendezvous`),
- whether there is a **Transaction ID**,
- whether there is a **country/location** field,
- which **latency fields** `SessionMetrics` has (candidates for `-LatencyField`: `IcaLatency` and, with NetScaler / SD-WAN data, `ClientL7Latency`, `ServerL7Latency`, `WanLatency`, `DcLatency`).

It writes nothing to CSV.

**What follows from the result:**

| `-Discover` result | Consequence |
|---|---|
| A transport indicator exists | The `Transport` table in the results will say outright whether bad sessions run over TCP. This is the most valuable piece of information. |
| No transport indicator | The script will not show it. Check the protocol in Director on a sample of good and bad sessions (the Transaction ID from the file lets you find them). |
| No country field | Use `-GeoCsv` (section 8), otherwise `Country` = `unknown`. |
| No Transaction ID | The key will be the session GUID. The script says so at startup. |
| No latency fields | The ICA RTT vs latency comparison is skipped (the script prints a message). |
| Several latency fields | By default `IcaLatency` is used. If the "Network Latency" in Director corresponds to another field, select it with `-LatencyField`. |

## 5. The sign-in wizard

After launch (without sign-in parameters) the script walks you through two steps:

**1/2 Customer ID.** Paste the **CCID** of your Citrix Cloud account (about 12 letters/digits): **not** the Org ID (digits only) and **not** the Client ID (a GUID). The script warns if you enter one of those. Where to find it: `HOW_TO_GET_A_TOKEN.md`, step 0.

**2/2 Sign-in method:**

| Choice | What it does | When |
|---|---|---|
| **3** (Enter) | You type the Client ID and (hidden) Secret of an API client at two console prompts. The script obtains and renews the token itself. | **Default and recommended.** Works in every host, no SDK needed, best for `-Loop`. |
| **1** | Opens the Citrix Cloud sign-in window (SDK). The script reads the token from the SDK session. | Optional. Needs the SDK; may fail depending on the account type. The token is the token of **your own admin account**. |
| **2** | You paste an access token (hidden input). | When you already have a token. Valid about 1 hour. |

Details and troubleshooting: `HOW_TO_GET_A_TOKEN.md`.

## 6. A normal run

```powershell
.\Get-IcaRttBreakdown.ps1 -Anonymous
```

(Add `-GeoCsv .\geo.csv` only if `Country` comes out as `unknown`; a missing `geo.csv` file only produces a warning.)

What happens:

1. The sign-in wizard.
2. `$metadata` is read and the plan is printed: which fields the script will use (whether it has transport, Transaction ID, country).
3. RTT samples **and all latency fields** from the last hour are downloaded (`-Hours 1`). Citrix keeps per-session data only briefly, about an hour (per community sources; not confirmed in the official documentation).
4. The samples are appended to the file and the whole file is analysed.
5. Tables are printed in the console and the breakdown is written to CSV.

### Files that are created (in the current directory)

| File | Contents |
|---|---|
| `rtt_samples_anon.csv` (without `-Anonymous`: `rtt_samples.csv`) | All collected samples. Appended between runs, **without duplicates**. |
| `rtt_breakdown_anon.csv` (without `-Anonymous`: `rtt_breakdown.csv`) | The full breakdown table (all dimensions). **Overwritten** on every run. |

You can change the paths with `-RawStore` and `-OutCsv`. Do not point `-OutCsv` at an important existing file, because it will overwrite it.

### Columns in the samples file (`-Anonymous` mode)

`CollectedUtc, TransactionId, Country, Location, Machine, DeliveryGroup, ClientAddress, ClientSubnet, AddrType, RttMs, LatencyMs, Protocol, Transport, ConnectedVia, LaunchedVia, WorkspaceAppVersion, ClientPlatform, Lat_<Field>…`

- `RttMs` is the ICA RTT. `LatencyMs` is the **primary latency field** ("network latency"; `IcaLatency` by default, changed with `-LatencyField`). Empty when the sample has no value.
- `Lat_<Field>` (for example `Lat_WanLatency`) are the other latency fields, if the tenant has them. Stored for manual comparison.

- `TransactionId` is the identifier with which you can find the session in Director / Session Launch Diagnostics. (If the tenant does not expose it, the column is called `SessionKey` and holds the session GUID.)
- `ConnectedVia` is the Gateway Service gateway/PoP host through which the client connected. `LaunchedVia` is the StoreFront/Workspace host.
- `AddrType`: `public`, `private` (an internal-network address, often VPN/LAN) or `cgnat`.
- `ClientSubnet`: /24 for IPv4, /48 for IPv6.
- `Transport`: shows the value of the transport field, if the tenant has one (for example `IsUdpTransport=False`). Empty if not.

Without `-Anonymous` the files additionally contain **user names** (column `User`). Use anonymous mode.

## 7. Collecting through the whole day: `-Loop`

Per-session data is available for only about an hour, so a reliable analysis needs it collected cyclically:

```powershell
.\Get-IcaRttBreakdown.ps1 -Anonymous -Loop -DurationHours 10 -IntervalMinutes 30
```

- Every 30 minutes it downloads samples (the download window is the larger of `-Hours` and twice the interval), appends them without duplicates, and when it finishes it analyses the whole file.
- The PowerShell window must stay open and the computer must stay on (no sleep).
- **Token:** option 1 (SDK): per Citrix documentation the SDK renews the token for up to 12 hours. Option 3: the script renews it itself. Option 2 (pasted token): lasts only about an hour, so do not use it with `-Loop`.
- To stop: <kbd>Ctrl</kbd>+<kbd>C</kbd>. The data collected so far is in the file.
- A good plan: one full working day on which users report problems.

### Analysis without new collection

The samples file is analysed in full every time. If you only want to recalculate (for example with a different threshold), run with a minimal download window:

```powershell
.\Get-IcaRttBreakdown.ps1 -Anonymous -Hours 0.01 -ThresholdMs 120
```

(This still requires signing in, because the script performs one small download anyway.)

## 8. The `geo.csv` file (client country)

Needed in `-Anonymous` mode if the tenant itself does not provide the country. Format: a header and three columns, **IPv4 ranges must be disjoint**:

```csv
Network,Country,Location
85.10.0.0/16,DE,Frankfurt
91.200.0.0/16,PL,Warsaw
10.20.0.0/16,PL,Gdansk office (VPN)
```

- Works offline only. IPv6 addresses get `unknown`.
- Overlapping ranges raise a warning. Addresses outside the narrower range then fall to `unknown`.
- The simplest start: enter your own known ranges (offices, VPN, the main user networks). You can build a full database from public data, for example GeoLite2 (needs a MaxMind account and licence). Without `-GeoCsv` the `Country` column is `unknown`, but subnets are still available.

## 9. Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Discover` | – | Only the tenant's field description, no data written. |
| `-Anonymous` | off | No user names. Transaction ID, country, machine, IP and technical data remain. |
| `-GeoCsv <file>` | – | Offline CIDR→country table (only with `-Anonymous`). |
| `-ThresholdMs` | 150 | A session is "bad" when its **median** ICA RTT exceeds this value. |
| `-Hours` | 1 | Download window (hours back). |
| `-Loop` | off | Repeat the download. |
| `-IntervalMinutes` | 30 | Interval in the loop. |
| `-DurationHours` | 24 | Loop duration. |
| `-RawStore <file>` | `rtt_samples[_anon].csv` | The samples file. |
| `-OutCsv <file>` | `rtt_breakdown[_anon].csv` | The breakdown file. |
| `-MinSessions` | 5 | Hide groups smaller than this many sessions (noise filter). |
| `-LatencyField <field>` | auto | Which `SessionMetrics` latency field is the "network latency" in the comparison with ICA RTT. `-Discover` lists the candidates. Default: a `Network*Latency*` field, otherwise `IcaLatency`. |
| `-LatencyThresholdMs` | = `-ThresholdMs` | A session has "high latency" when its median latency exceeds this value. Latency is a component of RTT and usually lower, so also try a lower value (for example 100). |
| `-AnonymizeUsers` | off | Without `-Anonymous`: replace names with a hash (`u_xxxxxxxx`). Pseudonymisation only. |
| `-ApiHost` | `api.cloud.com` | Region: `api.citrixcloud.jp` (Japan), `api.cloud.us` (US Gov), `api-eu.cloud.com` (try it if an EU tenant rejects the default). |
| `-PageSize` / `-MaxPages` | 100 / 300 | Paging. On the warning "Stopped after N pages" reduce `-Hours` or raise `-MaxPages`. |
| `-ConnectionNav` | auto | Fallback: name of the navigation property from the session to the connection (for example `CurrentConnection`). |
| `-TransportFields` | auto | Fallback: names of the fields carrying EDT/TCP transport, if auto-detection misses them. |
| `-Credential` | – | Only for runs without the wizard: a `PSCredential` (Client ID as user name, Secret as password). |
| `-CustomerId` | – | Skips the Customer ID question in the wizard. |

## 10. How to read the results

### Overview

- **Sessions / Bad sessions**: the number of sessions and the share of those whose median RTT is above the threshold. Compare the group percentages with it.
- **Anonymous mode does not show "repeating users"**, because it does not know the names.

### ICA RTT vs latency (Network Latency)

When the data contains latency, the overview has an **"ICA RTT vs <field>"** block:

- how many sessions have latency data, the medians of RTT and latency, and the **gap** (RTT minus latency),
- the **correlation** of session median RTT and latency (1 = they rise together, 0 = unrelated),
- a **2×2 table** (RTT high/low × latency high/low) using `-ThresholdMs` and `-LatencyThresholdMs`.

| 2×2 cell | Meaning |
|---|---|
| RTT high **and** latency high | The delay is mostly in the path to the client (network side). |
| RTT high, latency OK | The RTT contains more than the measured latency: look at the VDA / session side (CPU, graphics, profile/logon, input delay). |
| RTT OK, latency high | Latency is elevated but the session performs; usually not the priority. |

In the **dimension tables** the RTT columns are accompanied by `MedianLatency` (the group's median latency), `LatBadPct` (share of sessions with high latency among those that have latency data) and `MedianGap` (median of RTT minus latency). A group with a high `BadPct` **and** a high `LatBadPct` points to the path (network); a high `BadPct` with a low `LatBadPct` and a large gap points to the VDA / session side.

**Caveats (important):**
- The Monitor model has no field literally called "Network Latency" on `SessionMetrics`. The default `IcaLatency` is "ICA session latency" and, per community sources, may also include host-side delay. Check `-Discover` and, if needed, use `-LatencyField`.
- RTT and latency are sampled on different schedules, so a single pair of values may not match; the script compares session medians.
- If almost all latency samples are 0, the script warns that the field is probably not populated (the comparison loses its meaning).
- The result is an indication, not a measurement of pure network delay.

### Dimension tables

Each table shows: `Value` (the group), `Count` (number of sessions), `Bad` (how many are bad), `BadPct` (the share), `MedianRtt`, `P95Rtt` and, when latency data exists, `MedianLatency`, `LatBadPct`, `MedianGap`.
**Compare `BadPct` between groups, not absolute numbers** (a large group always has more bad sessions in absolute terms).

| Table | What to look at | What it suggests |
|---|---|---|
| **Transport** | Whether bad sessions are mostly on TCP (for example `IsUdpTransport=False`) | EDT/UDP does not work on this path. Check UDP 443 to `*.nssvc.net` on Azure Firewall (inspection, blocking) and whether Session Reliability and the Adaptive Transport policy are enabled. |
| **ConnectedVia** | One PoP with a clearly higher `BadPct` than the rest | A problem on the route to that PoP, or at the providers that land there. Compare with `Country` and `ClientSubnet`. |
| **Country / Location** | A country or location with a high `BadPct` | The link, ISP or VPN in that place. Compare with `ConnectedVia` to see whether the country lands on a "bad" PoP. |
| **ClientSubnet** | A few subnets with a `BadPct` well above the rest | A specific ISP, office or VPN. Check manually who owns the subnet. |
| **AddrType** | `private` has a much higher `BadPct` than `public` | Traffic over the internal network/VPN. Citrix should go outside the VPN tunnel (split tunnel). |
| **WorkspaceAppVersion** | An older version with a higher `BadPct` | An old client negotiates EDT worse or has known bugs. Plan an update. |
| **DeliveryGroup / Machine** | All groups similar | Not a machine or image problem (consistent with the observation that the problem affects different generations). If one machine stands out, check it separately. |
| **HourLocal** | Peaks at fixed times | Overload of a shared resource. A flat curve suggests a constant cause (configuration, route). |

**A flat `BadPct` across all dimensions** means the problem is not tied to any feature visible in the data. In that case collect for longer (`-Loop`) and move on to checking the path through Azure Firewall (UDP 443 logs, SNAT, TLS inspection) and to an A/B test with a machine that bypasses the firewall.

**Small groups are noise.** Ignore groups with a handful of sessions. Raise `-MinSessions` if the tables are cluttered.

### Verifying a single session

Take the `TransactionId` from the file and find the session in Citrix Monitor / Director (Session Launch Diagnostics). There you will see the protocol (UDP/TCP), the launch stages and, if you need to identify them, the user.

## 11. Personal data and clean-up

- Files from `-Anonymous` contain no user names, but they **do contain machine names and client IP addresses**. They may identify a person (VDI assigned to one person, a home IP). Treat them as personal data: keep them in a controlled place, do not send them by email.
- After the analysis:
  1. delete the CSV files from the machine (`rtt_samples*.csv`, `rtt_breakdown*.csv`),
  2. if you used an API client (options 2 and 3), delete it in Citrix Cloud (Identity and Access Management → API Access → Service principals) or rotate the Secret,
  3. clear the clipboard if you pasted a token (`Set-Clipboard -Value ' '`, and clear the `Win`+`V` history manually).

## 12. Problems and solutions

| Symptom | What to do |
|---|---|
| `...cannot be loaded because running scripts is disabled` | `Unblock-File` and `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (section 2). |
| Option 1: "SDK is not installed" / "commands were not found" | Install the SDK (`HOW_TO_GET_A_TOKEN.md`) and run in `powershell.exe`, or use option 2 / 3. |
| Option 1: "no bearer token was found" | Sign in again, or use option 2 / 3 and report the SDK version. |
| Getting the token: HTTP 400 / 401 | Most common: the Org ID or the Client ID was typed as the Customer ID (it must be the CCID). Otherwise a wrong Client ID or Secret, or a stray space. Create a new client if needed. |
| Data: HTTP 401 | The token expired. Run again. |
| Data: HTTP 403 | The account/client has no access to Monitor/DaaS (Read Only Administrator role). |
| Data: HTTP 400, "`$expand` path which is too deep ... maximum depth allowed is 2" | An older script version (nested expand). Use the current version; as a stop-gap in the old file, change `{ $dgNav = $true }` to `{ $dgNav = $false }` (the `DeliveryGroup` column then stays empty). |
| Data: HTTP 400 | A field is named differently in this tenant. The message points to the field. Run `-Discover` and use `-ConnectionNav` / `-TransportFields`. |
| Zero samples | The window is too short or nobody is signed in. Per-session data is kept for about an hour. Collect during working hours. |
| "Stopped after N pages" | Too much data for one download: reduce `-Hours` or raise `-MaxPages`. |
| `Country` = `unknown` | No country field in the tenant and no/non-matching `-GeoCsv` (section 8). |
| An error about an existing file with user names | A samples file from the other mode: point to a new `-RawStore` or delete the old one. |
| `The columns of … differ from the columns this run produces` | Another `-LatencyField` (it changes the `Lat_<Field>` columns) or an older script version: use a new `-RawStore`. |
| `SessionMetrics has no latency field '…'` | Wrong `-LatencyField`: the message lists the candidates (see also `-Discover`). |
| "Latency: no latency values in the data" | The tenant has no latency field, or it is empty (for example older VDAs): there will be no comparison. |
| "N% of the latency samples are 0" | The latency field is probably not populated: the comparison is meaningless, try another `-LatencyField`. |
| A warning about overlapping ranges in `geo.csv` | Fix the ranges so they are disjoint. |
| "-GeoCsv file not found … continuing without it" | Only a warning: the file path is wrong or the file does not exist. Not needed if the tenant provides the country. |

## 13. Recommended plan

1. `-Discover` (section 4). Note what is missing (transport, country, Transaction ID).
2. A single run during working hours (section 6). Check that the data looks sensible.
3. `-Loop` for one working day (section 7).
4. Review the results (section 10). First the **ICA RTT vs latency** block (does a high RTT come with a high latency), then the tables: **Transport**, **ConnectedVia**, **Country**, **ClientSubnet**, **AddrType**.
5. Confirm the hypothesis on individual sessions in Director (Transaction ID).
6. Clean-up (section 11).

## 14. Limitations worth remembering

- The script has not yet been run against a real tenant. It reads field names from `$metadata`, so it should adapt, but treat the first run as a trial.
- Whether the tenant exposes an EDT/TCP indicator is uncertain. `-Discover` will settle it.
- Window sign-in (option 1) depends on how the Citrix SDK behaves (the cmdlet and token-variable names differ between versions of the documentation). The script checks both. SSO/MFA handling in that window is not confirmed in the documentation.
- Per-session data is available only briefly. Without `-Loop` you see only the last hour.
- **The "Network Latency" in Director is not necessarily the same as `IcaLatency`.** The data model has several latency fields with different meanings (ICA session, WAN/DC from NetScaler or SD-WAN). The script collects all of them and compares with the RTT the one you choose (`-LatencyField`).
- The script points to correlations, not proof of cause. A "TCP vs RTT" result confirms the symptom; the cause (for example UDP 443 blocked on the firewall) must be checked separately in the Azure Firewall logs and configuration.
