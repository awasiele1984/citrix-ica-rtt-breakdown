# Get-IcaRttBreakdown.ps1: full documentation (English edition)

| | |
|---|---|
| **Documented file** | `Get-IcaRttBreakdown.ps1` (1043 lines, 61,078 bytes, 35 functions) |
| **SHA-256** | `e0b0f1c967388c9017f5bda082e239a636935dd52dd8cd01fc28ddc4305c31d0` |
| **Document date** | 2026-10-09 (revised for the ICA RTT vs latency comparison) |
| **Target platform** | Windows PowerShell 5.1 (PowerShell 7 partially, see section 3) |
| **Status** | Tested on synthetic data and mocked requests. **Sign-in and field discovery were confirmed on a real tenant (2026-10-09)**; the first samples query failed there with HTTP 400 (`$expand` too deep) and was fixed afterwards, but the fixed query has **not yet been confirmed live** (section 15) |

Companion documents (in Polish): `UZYCIE_SKRYPTU.md` (step-by-step usage guide) and `JAK_POBRAC_TOKEN.md` (sign-in and API client). This document describes **how the script is built and why it behaves the way it does**. It is a translation of `DOKUMENTACJA.md`; if the two ever differ, check the script itself. If the checksum above does not match your copy, this documentation may describe a different version of the script.

---

## Table of contents

1. Purpose and scope
2. Architecture and flow
3. Requirements and environment
4. Authentication
5. Communication with the Monitor Service API
6. Field discovery (`$metadata` and the query plan)
7. Data model (CSV files)
8. Analysis algorithms
9. Helper functions (subnet, address type, geolocation, name hash)
10. Operating modes
11. Parameter reference
12. Function reference
13. Security and privacy
14. Messages and error handling
15. Verification: what was tested and what was not
16. Known limitations
17. Maintenance and extension
18. Design decisions
19. Glossary
20. Sources

---

## 1. Purpose and scope

**The problem the script addresses.** In a Citrix DaaS environment, part of the user base can see very high ICA RTT (for example an average above 200 ms) regardless of Delivery Group and machine generation. The task is to determine **what the sessions with high RTT have in common**: transport (EDT/UDP or TCP), Gateway Service PoP, country, client subnet, Workspace app version, time of day.

**What the script does:**
- signs in to Citrix Cloud (three ways, section 4),
- reads the Monitor Service data model description (`$metadata`) and **selects the fields itself** based on what the tenant exposes (section 6),
- downloads ICA RTT samples together with session, machine and connection data (section 5),
- stores them in a CSV file with de-duplication (section 7),
- computes the share of "bad" sessions per dimension, prints tables and writes them to a second CSV (section 8),
- **compares ICA RTT with the latency fields the tenant exposes** ("network latency"): per-group latency, the RTT-minus-latency gap, the correlation and a 2×2 table that shows whether a high RTT is matched by a high latency (section 8.9).

**What the script does not do:**
- it does not change anything in Citrix Cloud, Azure or on VDAs (read requests only, section 13),
- it does not diagnose the root cause, it only points to correlations (section 16),
- it does not remember credentials (section 18),
- it does not send IP addresses or any other data to external services.

---

## 2. Architecture and flow

```
                    ┌──────────────────────────────────────────────────────────┐
                    │ Get-IcaRttBreakdown.ps1  (single file, no modules)       │
                    └──────────────────────────────────────────────────────────┘
 [1] Sign-in wizard ──► token (memory)          options: SDK | pasted token | Client ID+Secret
        │
 [2] GET /monitorodata/$metadata ──► Resolve-QueryPlan ──► plan (which fields, which navigations)
        │                                  │
        │                       -Discover: print and exit
        ▼
 [3] GET /monitorodata/SessionMetrics?$filter=...&$expand=... (pages of 100, @odata.nextLink)
        │      ConvertTo-FlatRow  (flattens 1 sample into 1 row)
        ▼
 [4] Add-ToStore  ──►  rtt_samples[_anon].csv   (append, de-duplicate)
        │                (with -Loop: repeat [3]–[4] every N minutes, renewing the token)
        ▼
 [5] Import-Csv (whole file) ► ConvertTo-SessionSummaries ► Get-Breakdown / Get-HourBreakdown
        ▼
 [6] Tables in the console  +  rtt_breakdown[_anon].csv
```

**Overriding principle:** the script is a single file with no module dependencies (apart from the optional Citrix SDK used for sign-in). All state lives in memory and in two CSV files.

**Layers in the code:**

| Layer | Functions |
|---|---|
| Helpers | `Get-HttpStatus`, `ConvertTo-UtcDate`, `Get-Prop` |
| Authentication | `Update-Token`, `Set-BearerHeaders`, `Read-ConnectionWizard`, `Get-TokenFromCitrixSdk`, `Read-SdkToken`, `Read-PastedToken`, `ConvertTo-CleanToken`, `ConvertFrom-SecureToPlain` |
| HTTP transport | `Invoke-ODataGet`, `Get-MonitorModel` |
| Model and plan | `ConvertFrom-ODataMetadata`, `Show-Discovery`, `Resolve-QueryPlan`, `Get-SamplesUrl` |
| Flattening | `ConvertTo-FlatRow`, `Get-ClientSubnet`, `Get-AddrType`, `Get-UserLabel`, geolocation (`ConvertTo-IPv4Number`, `Import-GeoTable`, `Get-GeoFromTable`) |
| Collection and storage | `Get-DeliveryGroupMap`, `Resolve-DeliveryGroup`, `Get-FlatSamples`, `Get-KeyProp`, `Add-ToStore` |
| Analysis | `Get-Percentile`, `Get-Correlation`, `ConvertTo-SessionSummaries`, `Get-Breakdown`, `Get-HourBreakdown`, `Show-Analysis` |
| Main program | the `# --- main` block at the end of the file |

---

## 3. Requirements and environment

| Requirement | Details |
|---|---|
| Operating system | Windows. The script was developed and tested on PowerShell 7.6 under macOS. The syntax is compatible with PowerShell 5.1, but **running it on 5.1 was not tested**. |
| PowerShell | Windows PowerShell 5.1 (`powershell.exe`) recommended. The script sets TLS 1.2 (`[Net.ServicePointManager]::SecurityProtocol`). |
| Network | HTTPS (443) to the host given in `-ApiHost` (default `api.cloud.com`). |
| Sign-in, option 1 | Citrix DaaS Remote PowerShell SDK (`Citrix*` modules or snap-ins). It also requires Microsoft Edge WebView2, and per Citrix documentation the SDK must not be installed on a Cloud Connector or on a server with a Delivery Controller/Studio. |
| Sign-in, options 2/3 | An access token or an API client (Client ID + Secret). |
| Permissions | Read access to Monitor/Director (the Read Only Administrator role is sufficient). |
| Disk | Writing two CSV files in the current directory. |

Global script settings: `$ErrorActionPreference = 'Stop'` (any error stops the run), `$ProgressPreference = 'SilentlyContinue'` (speeds up `Invoke-WebRequest`).

---

## 4. Authentication

Whatever the method, authentication always ends with two headers being set (variable `$script:Headers`):

```
Authorization:      CWSAuth bearer=<token>
Citrix-CustomerId:  <Customer ID>
Accept:             application/json
```

### 4.1 The wizard (`Read-ConnectionWizard`)

The wizard asks for the **Customer ID** (the Citrix Cloud account ID, "CCID"; validation: `^[A-Za-z0-9_-]+$`) and then for the sign-in method. Two common mix-ups are caught: a **GUID** (a Client ID) and an **all-digit value** (an Org ID) trigger a warning and a "Use it anyway? (y/N)" question (default: ask again). A question is skipped when the corresponding data was supplied by parameter (`-CustomerId`, `-Credential`).

| Option | Mechanism | Token renewal |
|---|---|---|
| **1. Sign-in window (SDK)** | `Get-TokenFromCitrixSdk`: detects the SDK commands (`Get-XDAuthentication` or `Get-XDAuthenticationEx`), imports `Citrix*` modules or loads snap-ins if needed, calls the command (a Citrix sign-in window opens), then reads the token from a global session variable (`Read-SdkToken`). | In `-Loop`: after 45 minutes the script re-reads the session variable. Per Citrix documentation the SDK renews the token for up to 12 hours. |
| **2. Pasted token** | `Read-PastedToken`: hidden input (`-AsSecureString`), content normalised by `ConvertTo-CleanToken`. | None. The token expires after about 1 hour. In `-Loop` the script stops with a message. |
| **3. Client ID + Secret** (**default**, Enter) | Two console prompts (`Read-Host`): Client ID (visible) and Secret (hidden, `-AsSecureString`); both are trimmed and a `PSCredential` is built. No GUI dialog is used (`Get-Credential` opens a dialog that is invisible or missing in some hosts). `Update-Token` sends `POST https://<ApiHost>/cctrustoauth2/<CustomerId>/tokens/clients` (`grant_type=client_credentials`) and sets the headers. | The script requests a new token itself after 45 minutes in `-Loop`. |

### 4.2 Token cleaning (`ConvertTo-CleanToken`)

Accepts: a bare token, `Bearer xxx`, `CWSAuth bearer=xxx`, a quoted string, or a header dictionary (key `Authorization`). Procedure: trim whitespace and quotes, strip the prefix `^(cwsauth\s+)?bearer[\s=]+` (case-insensitive), check that the result matches `^[A-Za-z0-9._~+/=-]{20,}$`. If not, return `$null`. This validation also protects against injecting special characters (for example a newline) into the HTTP header.

### 4.3 Reading the token from the SDK (`Read-SdkToken`)

Citrix describes the token as living in a global session variable, but **the variable name differs between documentation pages**. The script checks, in order:

1. `$Global:XDAuthToken` (the `Get-XDAuthentication` page),
2. `$Global:XDSerializedNonPersistentMetadata` (the "Accessing Monitor Service Data" page, cmdlet `Get-XDAuthenticationEx`).

The value can be a bare token or a whole header (`CWSAuth bearer=...`). `ConvertTo-CleanToken` handles both.

### 4.4 Where the token goes

- Only into the `Authorization` header of requests to the host given in `-ApiHost`.
- `Invoke-ODataGet` checks the host of every address (including `@odata.nextLink`); a different host aborts the run: `Refusing to send the token to unexpected host`.
- On completion: `$script:Headers = $null; $Credential = $null`.

---

## 5. Communication with the Monitor Service API

The script makes **exactly four kinds of request** (one POST for a token, everything else GET):

| # | Method | Address | Purpose | Where in code |
|---|---|---|---|---|
| 1 | **POST** | `https://<ApiHost>/cctrustoauth2/<CustomerId>/tokens/clients` | Obtain a token (option 3 only) | `Update-Token` |
| 2 | GET | `https://<ApiHost>/monitorodata/$metadata` | Data model description (XML) | `Get-MonitorModel` |
| 3 | GET | `https://<ApiHost>/monitorodata/DesktopGroups?$select=Id,Name&$top=…` | Delivery-group names (small lookup; the entity-set name comes from `$metadata`) | `Get-DeliveryGroupMap` |
| 4 | GET | `https://<ApiHost>/monitorodata/SessionMetrics?...` | RTT samples (JSON), pages of `-PageSize` | `Get-FlatSamples` |

Hosts allowed in `-ApiHost`: `api.cloud.com` (default), `api-eu.cloud.com` (not confirmed in Citrix documentation), `api.citrixcloud.jp`, `api.cloud.us`.

### 5.1 The samples query (`Get-SamplesUrl`)

Example (`-Anonymous` mode, connection via `Connections`):

```
https://api.cloud.com/monitorodata/SessionMetrics
  ?$filter=CollectedDate%20ge%202026-10-09T08:00:00Z
  &$select=CollectedDate,IcaRttMS,IcaLatency
  &$expand=Session($select=SessionKey,Protocol;
            $expand=Machine($select=Name,DesktopGroupId),
                    Connections($select=ClientAddress,ClientVersion,ClientPlatform,
                                 ConnectedViaHostName,IsUdpTransport,TransactionId))
  &$orderby=CollectedDate%20desc
  &$top=100
  &$count=true
```

Construction rules:
- **Time filter:** `CollectedDate ge <now - window>` (UTC, format `yyyy-MM-ddTHH:mm:ssZ`). The window is `-Hours` (in `-Loop`: the larger of `-Hours` and `2 × -IntervalMinutes / 60`).
- **All samples**, not only the bad ones: the denominator is needed to compute percentages.
- **`$select`/`$expand` contain only fields from the plan** (section 6), so the script never asks for fields the tenant does not have. The `SessionMetrics` `$select` lists `CollectedDate`, `IcaRttMS` and **every `*Latency*` field the tenant has** (disk latency excluded).
- **`$expand` depth is limited to 2 by the API.** A real tenant answered the first version of this query (which nested `Session → Machine → DesktopGroup`) with HTTP 400: *"The request includes a $expand path which is too deep. The maximum depth allowed is 2."* The query therefore expands only `Session` and, inside it, `User`, `Machine` and the connection. The delivery-group **name** is not expanded: `Machine.DesktopGroupId` is selected and resolved against a separate `DesktopGroups` lookup (request #3).
- **Default mode** adds `User($select=UserName)`. **`-Anonymous` mode does not request the user name at all.**
- **Paging:** the loop follows `@odata.nextLink`, up to `-MaxPages` pages (default 300 × 100 = 30,000 samples per collection). When exceeded: warning `Stopped after N pages - incomplete`.
- `@odata.count` (`$count=true`) is only printed for information.

### 5.2 Error responses (`Invoke-ODataGet`)

| HTTP | Script message |
|---|---|
| 401 | The token is expired or invalid; run the wizard again. |
| other (for example 400, 403) | The error body (up to 400 characters) plus a hint: for 400 a field name differs in the tenant, use `-Discover`, `-ConnectionNav`, `-TransportFields`. |

---

## 6. Field discovery (`$metadata` and the query plan)

The script **does not assume** that the tenant has any particular field besides two required ones. Instead:

1. `Get-MonitorModel` downloads `$metadata` (XML) and strips any BOM.
2. `ConvertFrom-ODataMetadata` builds a dictionary: type name → `{ Props: list of properties, Nav: dictionary of navigations (name → target type, whether a collection) }`. XPath `local-name()` is used, so it works regardless of XML namespaces.
3. `Resolve-QueryPlan` assembles the **query plan**.

### 6.1 Required fields (missing = error)

Types `SessionMetrics`, `Session`, `User`, `Machine`; in `SessionMetrics`: `CollectedDate`, `IcaRttMS` and the `Session` navigation. If anything is missing, the script stops with a "Run -Discover" message.

### 6.2 Field selection rules

| What | Rule | Source |
|---|---|---|
| Session key | `SessionKey` on `Session`, otherwise `Id` | `Session` |
| Navigation to the connection | First existing of: `CurrentConnection`, `Connection`, `Connections` (or the value of `-ConnectionNav`) | `Session.Nav` |
| Client fields | `ClientAddress`, `ClientVersion`, `ClientPlatform`, `ConnectedViaHostName`, `ConnectedViaIPAddress`, `LaunchedViaHostName`, `LaunchedViaIPAddress`, `Protocol`: first looked up on `Session`, then on the connection type | `Session` / connection |
| **Latency fields** | Every `SessionMetrics` property whose name contains `Latency` (case-sensitive), except names containing `Disk`. Typically `IcaLatency` and, where the tenant has NetScaler / SD-WAN data, `ClientL7Latency`, `ServerL7Latency`, `WanLatency`, `DcLatency` | `SessionMetrics` |
| **Primary latency** ("network latency" for the comparison) | The value of `-LatencyField`; otherwise a field whose name starts with `Network` and contains `Latency`; otherwise `IcaLatency`; otherwise the first latency field | `SessionMetrics` |
| **Transport indicator (EDT/TCP)** | Every property whose name matches, **case-sensitively**, `Transport\|Udp\|Edt\|Rendezvous` on `Session`, the connection or `SessionMetrics` (or the names from `-TransportFields`) | all three |
| **Transaction ID** | First property matching (case-insensitive) `Transaction`; search order: `Session`, connection, `SessionMetrics` | all three |
| **Country / location** | Every property matching `Country\|Location\|City\|Geo` | all three |
| **Delivery Group** | `Machine.DesktopGroupId`, resolved through a separate `DesktopGroups` lookup (requires `Machine.DesktopGroupId`, a `DesktopGroup` type with `Id` and `Name`, and an entity set for it in `$metadata`) | `Machine` + lookup |

Why transport matching is case-sensitive: otherwise the pattern `Edt` would match arbitrary names that merely contain "edt" (for example `NeedTo…`).

### 6.3 The plan as an object

`Resolve-QueryPlan` returns an object: `SessionKeyField`, `MetricsFields`, `SessionFields`, `ConnNav`, `ConnFields`, `DeliveryGroupNav`, `TransportFields` (entries `Source:Name`), `TransactionField`, `GeoFields`, `MachineKey`, `DeliveryGroupSet`, `LatencyFields`, `LatencyPrimary`. At startup the script prints a readable summary of the plan.

### 6.4 `-Discover` mode

`Show-Discovery` prints properties and navigations of the types `SessionMetrics`, `Session`, `Connection`, `Machine`, the list of types that carry `ClientAddress`, and the latency candidates for `-LatencyField`, and all properties matching the transport, Transaction ID and country patterns. A missing transport field is reported explicitly (meaning there will be no `Transport` table). Then the script exits, **having downloaded and written nothing**.

---

## 7. Data model (CSV files)

### 7.1 The samples file (`-RawStore`)

Default `rtt_samples.csv` or `rtt_samples_anon.csv` in the current directory. UTF-8, appended (`Export-Csv -Append`).

**Default mode:**

`CollectedUtc, SessionKey, User, Machine, DeliveryGroup, RttMs, LatencyMs, Protocol, Transport, ClientAddress, ClientSubnet, AddrType, WorkspaceAppVersion, ClientPlatform, ConnectedVia, LaunchedVia, Lat_<Field>…`

**`-Anonymous` mode:**

`CollectedUtc, TransactionId (or SessionKey), Country, Location, Machine, DeliveryGroup, ClientAddress, ClientSubnet, AddrType, RttMs, LatencyMs, Protocol, Transport, ConnectedVia, LaunchedVia, WorkspaceAppVersion, ClientPlatform, Lat_<Field>…`

`Lat_<Field>` columns exist for every latency field the tenant has **other than the primary one** (for example `Lat_WanLatency`). The set of columns therefore depends on the tenant and on `-LatencyField`.

### 7.2 Column dictionary

| Column | Origin / how it is produced |
|---|---|
| `CollectedUtc` | `SessionMetrics.CollectedDate` in UTC, format `yyyy-MM-ddTHH:mm:ssZ` |
| `SessionKey` | Session key (GUID). In anonymous mode only when the tenant has no Transaction ID |
| `TransactionId` | The field found in section 6.2. If empty for a row, the session key is used instead |
| `User` | `Session.User.UserName`; with `-AnonymizeUsers` replaced by the hash `u_` + 8 hex characters |
| `Machine` | `Session.Machine.Name` |
| `DeliveryGroup` | Name of the delivery group whose Id equals `Session.Machine.DesktopGroupId` (from the `DesktopGroups` lookup; matched case-insensitively) |
| `RttMs` | `SessionMetrics.IcaRttMS` (integer) |
| `LatencyMs` | The **primary latency field** (`-LatencyField`; default `IcaLatency`) in ms; empty when the sample has no value. **Used in the RTT-vs-latency comparison** (section 8.9) |
| `Lat_<Field>` | The value of each other latency field (stored for manual comparison, not analysed) |
| `Protocol` | The `Protocol` field of the session/connection (if present) |
| `Transport` | Values of the detected transport fields as `Name=Value`, separated by `; ` |
| `ClientAddress` | Client address from the connection/session |
| `ClientSubnet` | /24 for IPv4 or /48 for IPv6 (section 9.1) |
| `AddrType` | `public`, `private` or `cgnat` (section 9.2) |
| `Country`, `Location` | From tenant fields; otherwise from `-GeoCsv`; otherwise `unknown` / empty |
| `WorkspaceAppVersion` | The connection's `ClientVersion` field |
| `ClientPlatform` | The connection's `ClientPlatform` field |
| `ConnectedVia` | `ConnectedViaHostName`, or `ConnectedViaIPAddress` when empty (gateway/PoP host) |
| `LaunchedVia` | `LaunchedViaHostName`, or `LaunchedViaIPAddress` when empty |

Values are fetched with a helper (`$get` in `ConvertTo-FlatRow`): first from the session object, then from the connection, then from the metrics row. A missing value yields an empty string.

### 7.3 Key and de-duplication (`Add-ToStore`)

- Sample key: `<TransactionId or SessionKey>|<CollectedUtc>` (one-second resolution).
- On every write the script reads the whole existing file, builds a set of keys (`HashSet`) and appends only new rows.
- **Mode guard:** a file that has a `User` column cannot be extended in `-Anonymous` mode (and vice versa). The script stops and asks for a new file. This prevents mixing data with and without names.
- **Column guard:** if the columns of the existing file differ from the columns this run produces (for example another `-LatencyField`, which changes the `Lat_<Field>` set, or an older script version), the script stops and asks for a new `-RawStore` file.

### 7.4 The breakdown file (`-OutCsv`)

Default `rtt_breakdown.csv` / `rtt_breakdown_anon.csv`. **Overwritten** on every run. Columns:

`Dimension, Value, Unit, Count, Bad, BadPct, MedianRtt, P95Rtt, LatSessions, LatBad, LatBadPct, MedianLatency, P95Latency, MedianGap`

`Unit` is `sessions` for every dimension except `HourLocal` (where it is `samples`). The latency columns are empty when no latency data exists (meaning of the columns: section 8.4 and 8.9).

---

## 8. Analysis algorithms

### 8.1 Definition of a session

A session is a group of rows sharing the same key (`TransactionId` or `SessionKey`). For each group `ConvertTo-SessionSummaries`:
- sorts the samples by `CollectedUtc`,
- computes the **median RTT** (`MedianRtt`) over all samples of the session, and the **median latency** (`MedianLat`) over the samples that have a latency value (`$null` when none), and the **gap** `MedianRtt − MedianLat`,
- copies attributes (user, machine, DG, protocol, transport, PoP, subnet, country…) from the **last non-empty** value in the session,
- keeps the sample vector (`Rtts`) for later percentiles.

### 8.2 "Bad session"

A session is **bad** when `MedianRtt > -ThresholdMs` (default 150 ms). The median is used rather than the maximum so that a single spike does not classify a whole session.

### 8.3 Percentiles

`Get-Percentile` uses the nearest-rank method: `index = ceil(p/100 × n) − 1`, with a lower bound of 0. P50 is the median, P95 the 95th percentile.

### 8.4 Breakdown per dimension (`Get-Breakdown`)

For dimension D: group sessions by the value of D (empty values become `(n/a)`); for each group:

| Field | Meaning |
|---|---|
| `Count` | number of sessions in the group |
| `Bad` | how many of them are bad |
| `BadPct` | `100 × Bad / Count`, 1 decimal place |
| `MedianRtt` | median over **all samples** of all sessions in the group |
| `P95Rtt` | 95th percentile over all samples of the group |
| `LatSessions` | sessions in the group that have latency data |
| `LatBad` / `LatBadPct` | sessions whose median latency exceeds `-LatencyThresholdMs`, and their share **among sessions with latency data** |
| `MedianLatency` / `P95Latency` | median / 95th percentile over all latency samples of the group |
| `MedianGap` | median, over sessions with latency data, of `MedianRtt − MedianLat` |

Groups smaller than `-MinSessions` are dropped (noise filter). Results are sorted descending by `BadPct`, then by `Count`; the console shows the first 12 rows, the CSV contains all.

### 8.5 Dimensions

Only those whose column exists in the data are analysed: `Country`, `Location`, `DeliveryGroup`, `Protocol`, `Transport`, `ConnectedVia`, `LaunchedVia`, `AddrType`, `ClientSubnet`, `WorkspaceAppVersion`, `ClientPlatform`, `Machine`. A dimension with no value at all is reported as "not available".

### 8.6 Hour (`Get-HourBreakdown`)

The only dimension computed **on samples**, not on sessions: grouped by hour of the **local time of the machine running the script** (`ToLocalTime()`), `Bad` = samples with `RttMs > threshold`. Latency columns are computed on samples too (`LatBadPct` = share of samples with latency above `-LatencyThresholdMs`; `MedianGap` is not computed).

### 8.7 Overview

Number of samples, sessions, bad sessions and the percentage. In default mode additionally: number of users, how many have a bad session, the 5 most frequently repeated, and the ratio "bad sessions per bad user" (close to 1.0 means many different users). This part is skipped in anonymous mode. If in anonymous mode `Country` is `unknown` for all sessions, a warning is printed.

### 8.8 Statistical notes

- Small groups give unstable percentages. `-MinSessions` hides them but does not replace a significance test.
- The result is a correlation. It does not prove a cause (section 16).
- With several dimensions at once (for example PoP and country) the dimensions are correlated with each other; the script does not produce cross-tabulations.

### 8.9 ICA RTT vs latency comparison

Printed in the overview when at least one session has latency data (`LatencyMs` not empty).

**What is compared.** ICA RTT (`IcaRttMS`) is the end-to-end response time reported for the session. The latency is the field selected as primary (`LatencyMs`, default `IcaLatency`). Both come from the same `SessionMetrics` row, so they are paired per sample; the analysis then works on **per-session medians**.

**What is printed:**
- how many sessions have latency data,
- the median over sessions of RTT, latency and the **gap** (RTT minus latency),
- the **Pearson correlation** between session median RTT and median latency (`n/a` with fewer than 3 sessions or no variance),
- a **2×2 table** using `-ThresholdMs` for RTT and `-LatencyThresholdMs` for latency (default: the same value):

| | latency > threshold | latency ≤ threshold |
|---|---|---|
| **RTT > threshold (bad)** | *both high*: the delay is mostly in the path (network side) | *RTT high, latency OK*: the RTT contains more than the measured latency; look at the VDA/session side (CPU, graphics, profile/logon, input delay) |
| **RTT ≤ threshold** | latency elevated but the session still performs; usually not the priority | both fine |

**In the dimension tables** `MedianLatency`, `LatBadPct` and `MedianGap` appear next to the RTT columns. A group with a high `BadPct` **and** a high `LatBadPct` points to the path; a high `BadPct` with a low `LatBadPct` and a large gap points to the VDA/session side.

**Zero-value guard.** If at least 90% of the latency samples equal 0, a warning says the field is probably not populated on this path (Citrix article CTX616926 reports ICA Latency shown as 0 in some setups; I could not open that article, only its title was seen) and that the comparison is not meaningful.

**Important caveats** (details in section 16): the Monitor model has no field literally called "Network Latency" on `SessionMetrics`; which latency field matches the "Network Latency" shown in Director for your tenant must be decided by you (`-Discover`, `-LatencyField`). The two metrics are sampled on different schedules, and `IcaLatency` may include host-side processing, so the comparison is an indication, not a measurement of pure network delay.

---

## 9. Helper functions

### 9.1 `Get-ClientSubnet`

IPv4: the first three octets + `.0/24`. IPv6: the first three groups (6 bytes) + `::/48`. An invalid address yields an empty string.

### 9.2 `Get-AddrType`

| Range | Result |
|---|---|
| 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, IPv6 `fc00::/7` | `private` |
| 100.64.0.0/10 | `cgnat` |
| everything else | `public` |

### 9.3 Offline geolocation (`-GeoCsv`)

`Import-GeoTable` reads a CSV with columns `Network` (IPv4 CIDR), `Country` and optionally `Location`. Each range is converted into a pair of numbers (start, end); the arrays are sorted by start. `Get-GeoFromTable` looks an address up by **binary search** (O(log n)), so large tables do not slow the analysis. Rules and limits:

- IPv4 only (IPv6 yields `unknown`),
- ranges must be disjoint; overlap raises a warning, and addresses inside the broader range but outside the nested one fall to `unknown`,
- rows with a malformed format are skipped; no usable rows aborts the run,
- no internet requests whatsoever.

Order for determining the country in `-Anonymous`: tenant field → `-GeoCsv` table → `unknown`.

### 9.4 `Get-UserLabel` (`-AnonymizeUsers`)

`u_` + the first 4 bytes of the SHA-256 of the user name (lowercase), in hexadecimal. Stable (the same person gives the same hash), so repetition can be studied. **This is pseudonymisation, not anonymisation:** low-entropy names can be recovered with a dictionary.

---

## 10. Operating modes

| Mode | What changes |
|---|---|
| **Default** | Requests `User`; the samples file has a `User` column; the overview includes users. |
| **`-Anonymous`** | Does not request the user name at all. Stores Transaction ID, country, machine, IP and technical data. Separate default `_anon` files. |
| **`-AnonymizeUsers`** | Default mode only: a hash instead of the name. |
| **`-Discover`** | Field discovery, nothing written. |
| **`-Loop`** | Repeats collection every `-IntervalMinutes` for `-DurationHours`, renewing the token. The final analysis covers the whole file. |

### 10.1 The `-Loop` run

```
deadline = now + DurationHours ; window = max(Hours, 2 × Interval/60)
repeat:
    if token older than 45 min: renew (Client ID+Secret) | re-read from SDK | error (pasted token)
    download samples from the window  →  append to file without duplicates
    if now + Interval ≥ deadline: stop
    Start-Sleep Interval
analyse the whole file
```

Interrupting with <kbd>Ctrl</kbd>+<kbd>C</kbd> keeps the data written so far (writing happens after each iteration).

### 10.2 Analysing existing data

The analysis always covers the whole samples file, not only the fresh download. This allows recalculating with a different threshold (`-Hours 0.01 -ThresholdMs 120`), but the script still signs in and performs one small download.

---

## 11. Parameter reference

| Parameter | Type | Default | Validation / notes |
|---|---|---|---|
| `-CustomerId` | string | – | `^[A-Za-z0-9_-]+$`. If absent, the wizard asks. |
| `-ThresholdMs` | int | 150 | Threshold of a "bad" session (median RTT). |
| `-Hours` | double | 1 | Download window. |
| `-ApiHost` | string | `api.cloud.com` | `ValidateSet`: `api.cloud.com`, `api-eu.cloud.com`, `api.citrixcloud.jp`, `api.cloud.us`. |
| `-PageSize` | int | 100 | 1–100. |
| `-MaxPages` | int | 300 | Page limit per download. |
| `-MinSessions` | int | 5 | Minimum sessions in a group. |
| `-LatencyField` | string | auto | The `SessionMetrics` latency field used as "network latency". Must be one of the candidates listed by `-Discover`, otherwise the script stops. |
| `-LatencyThresholdMs` | int | = `-ThresholdMs` | Median latency above this makes a session "latency high". |
| `-Discover` | switch | off | Field discovery and exit. |
| `-RawStore` | string | `rtt_samples[_anon].csv` | Samples file. |
| `-Loop` | switch | off | Repeat collection. |
| `-IntervalMinutes` | int | 30 | Interval in the loop. |
| `-DurationHours` | double | 24 | Loop duration. |
| `-AnonymizeUsers` | switch | off | Hash instead of name (default mode). |
| `-Anonymous` | switch | off | No user names. |
| `-GeoCsv` | string | – | CIDR→country table; used only with `-Anonymous`. |
| `-OutCsv` | string | `rtt_breakdown[_anon].csv` | Breakdown file (overwritten). Unused in `-Discover`. |
| `-ConnectionNav` | string | auto | Forces the navigation to the connection. |
| `-TransportFields` | string[] | auto | Forces the transport field names. |
| `-Credential` | PSCredential | – | Non-interactive use (Client ID as user name, Secret as password). |

---

## 12. Function reference

| Function | Role |
|---|---|
| `Get-HttpStatus` | Extracts the HTTP code from an exception |
| `ConvertTo-UtcDate` | Parses a date (string on PS 5.1 or `datetime` on PS 7) to UTC |
| `Get-Prop` | Null-safe property read |
| `Update-Token` | POST for a token (Client ID + Secret), sets the headers |
| `Set-BearerHeaders` | Sets the headers for a ready-made token |
| `Invoke-ODataGet` | GET with host check and readable errors |
| `ConvertFrom-ODataMetadata` | `$metadata` XML → type dictionary |
| `Get-MonitorModel` | Downloads and parses `$metadata` |
| `Show-Discovery` | Prints the tenant's fields (`-Discover`) |
| `Resolve-QueryPlan` | Builds the query plan from the discovered fields (including the latency fields and the primary latency) |
| `Get-SamplesUrl` | Assembles the samples query URL |
| `Get-ClientSubnet` | /24 or /48 from an address |
| `Get-AddrType` | `public` / `private` / `cgnat` |
| `Get-UserLabel` | Hash of the user name |
| `ConvertTo-IPv4Number` | IPv4 address → number |
| `Import-GeoTable` | Loads the CIDR→country table |
| `Get-GeoFromTable` | Binary search of the country for an address |
| `ConvertTo-FlatRow` | One JSON sample → one CSV row (both modes) |
| `Get-DeliveryGroupMap` | One small paged GET: delivery-group Id → Name |
| `Resolve-DeliveryGroup` | Machine's `DesktopGroupId` → delivery-group name via that map |
| `Get-FlatSamples` | Paged download and flattening |
| `Get-KeyProp` | Name of the key column (`TransactionId` or `SessionKey`) |
| `Add-ToStore` | Append to the file with de-duplication and mode guard |
| `Get-Percentile` | Nearest-rank percentile |
| `Get-Correlation` | Pearson correlation of two series (rounded to 2 decimals; `$null` if undefined) |
| `ConvertTo-SessionSummaries` | Samples → session summaries (median RTT, median latency, gap) |
| `Get-Breakdown` | Breakdown per dimension (sessions), RTT and latency statistics |
| `Get-HourBreakdown` | Breakdown per hour (samples), RTT and latency statistics |
| `Show-Analysis` | Overview, RTT-vs-latency block, tables and CSV output |
| `ConvertFrom-SecureToPlain` | SecureString → text (BSTR cleared after use) |
| `ConvertTo-CleanToken` | Token normalisation and validation |
| `Read-SdkToken` | Reads the token from the SDK session variable |
| `Get-TokenFromCitrixSdk` | Sign-in window through the SDK |
| `Read-PastedToken` | Token pasting (hidden input) |
| `Read-ConnectionWizard` | Wizard: Customer ID + sign-in method |

---

## 13. Security and privacy

### 13.1 Operations on the environment

- **Read-only.** The only non-GET request is the `POST` for a token. The code contains no PUT, PATCH or DELETE, no `Invoke-Expression`, no `Start-Process` and no library loading.
- **Verification:** a code audit (searching for network calls and write commands) and a run of the entire script with mocked `Invoke-RestMethod` / `Invoke-WebRequest` that record every request. Result: `POST` for a token (option 3 only) + `GET $metadata` + `GET DesktopGroups` + `GET SessionMetrics`. Files after the run: two CSV files.
- **Caveat:** the "read-only" guarantee comes from the script's code, not from the permissions of the credentials. An API client created in Citrix Cloud may have broad permissions (Citrix documentation describes it as "full-access admin" unless you choose Custom access with the Read Only Administrator role). The option 1 token is the token of your own administrator account.

### 13.2 Local operations

| Operation | When | File |
|---|---|---|
| `Export-Csv -Append` | after each collection | `-RawStore` |
| `Export-Csv` (overwrite) | after the analysis | `-OutCsv` |
| `Import-Csv` | analysis, de-duplication, `-GeoCsv` | `-RawStore`, `-GeoCsv` |

The script deletes nothing. It does not save credentials or the Customer ID.

### 13.3 Credential handling

- The Customer ID and the token live in memory only; at the end the variables are cleared (`$script:Headers = $null`, `$Credential = $null`). The script does not overwrite process memory, so nothing remains on disk after the shell ends, but values may briefly remain in process memory.
- The Secret from a `PSCredential` is used locally in `Update-Token`, and the variable holding it is cleared in a `finally` block.
- A pasted token is read as a `SecureString`; conversion to text is short-lived (the BSTR is zeroed after use).
- The script **does not take tokens from the browser** (neither from cookies nor from Chrome stores).

### 13.4 Personal data

| File | Sensitive content |
|---|---|
| Default mode | user names, machines, IP addresses |
| `-Anonymous` | machines and IP addresses (may identify a person: single-user VDI, home IP); the Transaction ID makes it possible to identify the person in Director |
| `-Anonymous` + `-AnonymizeUsers` | as above (a hash is not anonymisation) |

Treat the files as personal data: restrict access, do not send them by email, delete them after the analysis. Assessing compliance with regulations (for example GDPR) and employee notification is the responsibility of the appropriate person in your organisation. This documentation is not legal advice.

### 13.5 Clean-up

After the analysis: delete `rtt_samples*.csv`, `rtt_breakdown*.csv` and, if applicable, `geo.csv` containing network data; delete or rotate the API client in Citrix Cloud; clear the clipboard after pasting a token.

---

## 14. Messages and error handling

| Message (abbreviated) | Source | Meaning / action |
|---|---|---|
| `Token request failed (HTTP …)` | `Update-Token` | HTTP 400/401: most often an Org ID or Client ID typed as the Customer ID; otherwise a wrong Client ID/Secret, or the client was deleted. The message appends the server's response text and a "Check: …" hint |
| `OData request failed (HTTP 401)` | `Invoke-ODataGet` | Token expired, run again |
| `OData request failed (HTTP …) … -Discover` | `Invoke-ODataGet` | A field is named differently; use `-Discover` |
| `Refusing to send the token to unexpected host` | `Invoke-ODataGet` | `@odata.nextLink` points to another host; aborted |
| `Entity type '…' not found in $metadata` | `Resolve-QueryPlan` | Unusual tenant data model; `-Discover` |
| `SessionMetrics has no 'IcaRttMS' …` | `Resolve-QueryPlan` | Required field missing |
| `Session has no navigation property '…'` | `Resolve-QueryPlan` | Wrong `-ConnectionNav` value |
| `SessionMetrics has no latency field '…'` | `Resolve-QueryPlan` | Wrong `-LatencyField`; the message lists the candidates |
| `The columns of … differ from the columns this run produces` | `Add-ToStore` | Another `-LatencyField` or an older script version; use a new `-RawStore` |
| `N% of the latency samples are 0 …` | `Show-Analysis` | The latency field is probably not populated; the comparison is not meaningful |
| `Latency: no latency values in the data` | `Show-Analysis` | The tenant has no latency field, or it is empty on these VDAs; no comparison |
| `Stopped after N pages - incomplete` | `Get-FlatSamples` | Reduce `-Hours` or raise `-MaxPages` |
| `… already holds user names …` / `… is an anonymous store …` | `Add-ToStore` | Modes mixed; point to another file |
| `N overlapping ranges in …` | `Import-GeoTable` | Ranges in `-GeoCsv` are not disjoint |
| `No usable 'Network,Country' IPv4 CIDR rows` | `Import-GeoTable` | Wrong `-GeoCsv` format |
| `-GeoCsv is only used together with -Anonymous` | main | Warning; table ignored |
| `-GeoCsv file not found: … continuing without it` | main | Warning only: the run continues (the tenant may supply the country itself) |
| `OData request failed (HTTP 400) … $expand path which is too deep` | `Invoke-ODataGet` | Older script version (nested expand); use the current version |
| `Country is 'unknown' for every session` | `Show-Analysis` | No country field and no working `-GeoCsv` |
| `The Citrix SDK commands were not found …` / `… not installed …` | `Get-TokenFromCitrixSdk` | Install the SDK or choose option 2/3 |
| `Signed in, but no bearer token was found …` | `Get-TokenFromCitrixSdk` | The token variable has a name the script does not handle |
| `The pasted token has expired …` | main (`-Loop`) | Use option 1 or 3 in a loop |
| `The Citrix SDK session no longer holds a token` | main (`-Loop`) | Run the script again |

Critical errors stop the script (`$ErrorActionPreference = 'Stop'`). Data collected earlier remains in the samples file.

---

## 15. Verification: what was tested and what was not

### Tested (PowerShell 7.6, macOS)

| Area | Method | Result |
|---|---|---|
| Syntax | PowerShell parser (AST) | no errors |
| Field discovery | Synthetic `$metadata` (connection as a collection, Transaction ID, DG, transport indicator) | plan correct, URL correct (a missing-comma bug in anonymous mode was found and fixed) |
| Analysis | 120 sessions with a planted pattern (sessions without UDP, one PoP) | pattern found in the Transport and ConnectedVia tables |
| Anonymous mode | Synthetic rows | no names in rows; columns match the schema |
| Geolocation | CIDR table, binary search | correct countries; overlap warning |
| Samples file | Written twice, read back from CSV | de-duplication correct; analysis from text data works |
| Mode guard | File from the other mode | aborts with a message |
| HTTP requests | Whole script with mocked network | only POST for a token (option 3) + 3 GETs (`$metadata`, `DesktopGroups`, `SessionMetrics`) |
| `$expand` depth limit | Mock that answers HTTP 400 when the URL has more than 2 nested `$expand=`, with metadata modelled on the real tenant (`CurrentConnection`, `ClientLocationCountry/City`, five latency fields, `DesktopGroupId`) | query accepted; delivery-group names resolved; country from the tenant fields; missing `geo.csv` only warns |
| Disk changes | Directory snapshot before/after | only two CSV files |
| Latency comparison | 150 synthetic sessions with two planted causes (network-side: RTT 230 / latency 190; host-side: RTT 210 / latency 35) | PoP with the network cause: `MedianLatency` 189, `LatBadPct` 100; PoP with the host cause: `MedianLatency` 35, `LatBadPct` 0, `MedianGap` 172; 2×2 table 50/50/0/50; correlation 0.63 |
| Latency field selection | Synthetic `$metadata` with `IcaLatency`, `WanLatency`, `ClientL7Latency`, `DiskLatency` | disk latency excluded; primary `IcaLatency`; override `WanLatency` works; unknown override stops with the candidate list; `Lat_<Field>` columns written |
| Column guard | Second run with another `-LatencyField` against the same file | refuses to append, asks for a new file |
| Wizard | Mocked `Read-Host`: SDK as command, SDK as snap-in, no SDK, pasted token (with prefix, with an invalid entry), Client ID+Secret (default on Enter; values with surrounding spaces; empty Client ID / empty Secret repeated until valid), invalid choice; `Get-Credential` mocked to fail the test if called | all paths work; the sent Client ID and Secret are the trimmed values |

### Observed on a real tenant (2026-10-09)

| Item | Observation |
|---|---|
| Sign-in | Client ID + Secret (option 3) worked once the Customer ID was the CCID. An Org ID or a Client ID typed as Customer ID gave HTTP 400 on the token request |
| Connection | Reached through the `CurrentConnection` navigation |
| Country | The tenant exposes `ClientLocationCountry` and `ClientLocationCity`, so `-GeoCsv` is not needed |
| Latency fields | `IcaLatency`, `ClientL7Latency`, `ServerL7Latency`, `WanLatency`, `DcLatency` (primary: `IcaLatency`) |
| Transport indicator | **None exposed** (no EDT/TCP field in Monitor OData) |
| Samples query | HTTP 400, `$expand` depth (fixed, not yet confirmed live) |

### Not tested

- **The fixed samples query on the real tenant** (the contents of the responses, limits, per-session data retention and, above all, **which latency field matches the "Network Latency" shown in Director** and how it is populated).
- **The real Citrix SDK** (sign-in window, SSO/MFA, token variable name, renewal in `-Loop`).
- **Windows PowerShell 5.1** (behaviour of `Invoke-WebRequest`, `Export-Csv -Append`, date types).
- **Performance** with large files (tens/hundreds of thousands of rows): the analysis loads the whole file and groups it in memory; slowdown can be expected but was not measured.

---

## 16. Known limitations

1. **Field names are not confirmed on a live tenant.** The script discovers them, but for example the EDT/TCP indicator may not exist in Monitor OData at all. In that case the `Transport` table is empty and the protocol must be checked in Director.
2. **Per-session data retention** is, per community sources, about 1 hour (not confirmed in official documentation). Without `-Loop` the analysis covers only the last hour.
3. **Connection as a collection:** when a `Session` has several connections, the script takes the **last element** of the collection in the response, not the connection active at the sample time. For sessions with reconnects the client attributes may not match the sample.
4. **The Transaction ID may be per launch (connection), not per session.** A session with a reconnect may be counted as several "sessions".
5. **The de-duplication key has one-second resolution.** Two samples of the same session within the same second are merged (practically never happens).
6. **Geolocation:** IPv4 only, disjoint ranges. IPv6 is always `unknown`.
7. **"Network latency" is not one well-defined field.** According to the Monitor model reference, `SessionMetrics` has `IcaLatency` ("ICA session latency", null on older VDAs) and, with NetScaler / SD-WAN data, `ClientL7Latency` ("WAN latency"), `ServerL7Latency` ("DC latency"), `WanLatency` and `DcLatency`. A separate "end-to-end network latency" exists in the model only as an alerting metric (`NetworkLatencyMs`), and `ApplicationPerformanceMetrics.NetworkLatency` is an application-level send latency in another entity that this script does not read. The script therefore uses `IcaLatency` by default and lets you pick another field; it cannot know which one equals the "Network Latency" you see in Director.
7a. **`IcaLatency` is not pure network delay.** Community sources describe it as the time from user input until it is processed on the session host, i.e. network latency plus host-side delay. A large gap between RTT and `IcaLatency` can therefore also mean "RTT has an application/UI component", not only "server-side problem".
7b. **The metrics are sampled on different schedules** (sources quote different intervals for RTT, latency and the Perfmon-based counters), so a single pair of values may not match; the script works on session medians to soften this.
7c. **Missing or zero latency.** Samples without a latency value are ignored for latency statistics (the session still counts for RTT). Latency reported as 0 can hide a missing measurement (guard: warning when ≥ 90% are 0).
7d. **Default latency threshold equals the RTT threshold.** Latency is a component of RTT and usually lower, so with the same number fewer sessions are "latency high"; try a lower `-LatencyThresholdMs` (for example 100). The thresholds are descriptive, not Citrix-defined limits.
7e. **The correlation is descriptive** (Pearson, session medians) and says nothing about causation.
8. **The hour in `HourLocal`** is the local time of the machine running the script, not the users' time zone.
9. **No cross-tabulations** (for example PoP × country) and no significance tests.
10. **Correlation, not cause.** A result such as "bad sessions are on TCP" confirms the symptom; the cause (for example UDP 443 blocked on Azure Firewall) must be checked separately in the firewall logs and configuration.
11. **The SDK token is an administrator-account token** (broad permissions), unlike a restricted API client.
12. **The samples file grows** without limit and is read in full on every run.
13. **`-ApiHost api-eu.cloud.com`** is not mentioned in Citrix documentation; it is a value to try.
14. Script messages are in English; the companion guides `UZYCIE_SKRYPTU.md` and `JAK_POBRAC_TOKEN.md` are in Polish.

---

## 17. Maintenance and extension

### Adding a new analysis dimension (for example a new column from the tenant)

1. In `Resolve-QueryPlan`, add the field name to the `$wanted` list (or add a regex for detection).
2. In `ConvertTo-FlatRow`, add the column to both schemas (default and `-Anonymous`) using `& $get 'FieldName'`.
3. In `ConvertTo-SessionSummaries`, add `NewColumn = & $latest 'NewColumn'`.
4. In `Show-Analysis`, add the name to the `$dims` list.

Remember that changing the column schema requires a new samples file (the old one would be inconsistent).

### Changing the definition of a "bad" session

Change the condition in `Get-Breakdown` (`$_.MedianRtt -gt $Threshold`), for example to P95 instead of the median. The `-ThresholdMs` parameter changes the threshold only.

### Adapting to a different API version

If HTTP 400 points to an unknown field: run `-Discover`, set `-ConnectionNav` / `-TransportFields`, and if necessary add alternative names in `Resolve-QueryPlan`.

### Testing after changes

Recommended minimum: the parser (AST), a run on synthetic `$metadata` and data, a repeated audit of HTTP requests with mocks (only POST for a token + GET should remain), and a leak test (no user names in `-Anonymous` mode).

---

## 18. Design decisions

| Decision | Reason |
|---|---|
| Fields discovered from `$metadata`, not hard-coded | The data model could not be verified on a live tenant; avoids HTTP 400 errors |
| Downloading **all** samples | The denominator is needed to compare group percentages |
| Session median as the criterion | Robust against single spikes |
| Writing to CSV with de-duplication | Per-session data is available only briefly; allows collecting over time |
| `-Anonymous` | Requirement to limit personal data: no names, Transaction ID and country remain (machines and IPs deliberately kept: they are needed to locate the problem) |
| Geolocation offline only | Sending IP addresses to external services would undermine anonymisation |
| **No credential storage** | Design decision: saving the Customer ID/token was judged unsafe. An earlier version with DPAPI encryption was removed |
| **No token taken from the browser** | Chrome protects cookies and blocks remote debugging of the default profile; the console token carries full administrator rights; no documented use with Monitor OData |
| Sign-in through the Citrix SDK | The official, documented way to obtain a token after a user signs in; the script only reads the token from the session's memory |
| Host check while paging | The token must not reach another host even if a response points to a different `nextLink` |
| Collect **all** latency fields, one primary | The tenant's meaning of "Network Latency" could not be verified; keeping every candidate in the CSV lets the user compare without re-collecting |
| 2×2 table with explicit thresholds + gap + correlation | Transparent and easy to explain; avoids an arbitrary "network share" cut-off |
| Customer ID sanity check (GUID / digits-only warning) | The first real run failed with HTTP 400 because a Client ID and then an Org ID were typed as the Customer ID; a soft warning (not a hard block) stops the mistake early without rejecting unusual but valid IDs |
| Client ID + Secret as the default sign-in, via console prompts | The expected setup is an API client (Client ID + Secret); in testing, the SDK sign-in failed with "authentication failed" after a successful login on one tenant, and the `Get-Credential` dialog did not appear in one host. Plain `Read-Host` prompts work in every host |
| Delivery group through a separate lookup, not a third `$expand` level | The API rejects `$expand` deeper than 2 (seen on a real tenant); one extra small GET is cheaper and safer than dropping the column |
| Missing `-GeoCsv` file only warns | The tenant can supply the country itself; aborting the run for an optional file helps nobody |
| Single file, no modules | Easy to move to a work machine and to review |

---

## 19. Glossary

| Term | Meaning |
|---|---|
| **ICA RTT** | Session response time of an HDX/ICA session as reported by Citrix (includes the network and server-side processing). Field `IcaRttMS`. |
| **IcaLatency** | `SessionMetrics` field: ICA session latency in ms (null on older VDAs). Community sources: includes host-side delay, not only the network. Default "network latency" in this script. |
| **Network latency** | In this script: whichever latency field is selected (`-LatencyField`). Not a single field in the Monitor model. |
| **ClientL7Latency / ServerL7Latency** | Layer-7 latency on the client side ("WAN latency") and server side ("DC latency"), available with NetScaler HDX Insight data. |
| **WanLatency / DcLatency** | WAN-segment and datacenter-segment latency derived from SD-WAN; null without SD-WAN. |
| **Gap** | `MedianRtt − MedianLat` per session: the part of the RTT not explained by the measured latency. |
| **EDT** | Enlightened Data Transport: a UDP-based HDX transport, better under packet loss and high latency. |
| **Adaptive Transport** | Mechanism that selects EDT (UDP) and falls back to TCP when UDP is unavailable. |
| **Session Reliability / CGP** | Layer that keeps the session alive through short interruptions (ports 1494/2598; required for EDT). |
| **Gateway Service** | Citrix-managed cloud HDX gateway; the user connects to the nearest PoP. |
| **PoP** | Point of Presence: an entry point of Gateway Service. Column `ConnectedVia`. |
| **Rendezvous** | Protocol in which the VDA connects to Gateway Service directly, bypassing Cloud Connectors (HDX; in V2 also control traffic). |
| **Cloud Connector** | Component in the resource location linking it to Citrix Cloud. |
| **Transaction ID** | Session-launch identifier used in Session Launch Diagnostics (Monitor/Director). |
| **Monitor Service OData** | OData v4 interface to Monitor/Director data in Citrix Cloud. |
| **Service principal / API client** | Application identity in Citrix Cloud (Client ID + Secret) for API calls. |
| **Delivery Group** | A set of machines and entitlements made available to users. |
| **Bad session** | In this script: a session whose median ICA RTT exceeds `-ThresholdMs`. |

---

## 20. Sources

- [Monitor Service OData model reference (Citrix)](https://developer-docs.citrix.com/en-us/monitor-service-odata-api/api-reference/monitor-model): `SessionMetrics` latency fields.
- [CTX201968, Accessing ICA RTT Metrics (Citrix)](https://support.citrix.com/external/article/CTX201968/accessing-ica-rtt-metrics-for-citrix-hdx.html): what ICA RTT is.
- [Goliath: high ICA/Network Latency and low ICA RTT](https://support.goliathtechnologies.com/hc/en-us/articles/4808951320983-Why-do-I-see-high-ICA-Network-Latency-and-Low-ICA-RTT): relation between the metrics and their sampling (third-party).
- [CTX616926, Director reports ICA Latency as 0](https://support.citrix.com/s/article/CTX616926-citrix-director-reports-ica-latency-value-as-0): only the title was seen; the page could not be opened.
- [Accessing Monitor Service Data (Citrix)](https://developer-docs.citrix.com/en-us/citrix-cloud/accessing-monitor-service-data-citrix-cloud-external/accessing-monitor-service-data-citrix-cloud-external.html)
- [Get-XDAuthentication (Citrix DaaS SDK)](https://developer-docs.citrix.com/en-us/citrix-daas-sdk/sdkproxy/get-xdauthentication)
- [Get started with Citrix Cloud APIs](https://developer-docs.citrix.com/en-us/citrix-cloud/citrix-cloud-api-overview/get-started-with-citrix-cloud-apis)
- [SDKs and APIs, Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/sdk-api)
- [Remote PowerShell SDK download](https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html)
- [Rendezvous V2](https://docs.citrix.com/en-us/citrix-daas/hdx-transport/rendezvous-protocol/rendezvous-v2.html)
- [Delegated administration, Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/manage-deployment/delegated-administration.html)
- [CTX560736, API with Custom/read-only access](https://support.citrix.com/external/article/CTX560736/how-to-create-api-with-customsread-only.html)
- [Azure Firewall monitoring data reference](https://learn.microsoft.com/en-us/azure/firewall/monitor-firewall-reference)
