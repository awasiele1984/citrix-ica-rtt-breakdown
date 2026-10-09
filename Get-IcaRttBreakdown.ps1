<#
.SYNOPSIS
  Finds the common denominator of high-ICA-RTT sessions in Citrix Cloud (Monitor Service OData).

.DESCRIPTION
  This script answers WHAT slow sessions (high ICA RTT) have in common. It pulls ALL RttMS samples in the window (not only the bad ones, so it can
  compute a percentage), flattens them with the session's connection details, and prints a breakdown
  of "% of sessions whose median ICA RTT is over the threshold" per:

     DeliveryGroup, Machine, Protocol, Transport (EDT/TCP - only if the tenant exposes it),
     ConnectedVia (Gateway/PoP host), LaunchedVia (StoreFront/Workspace host),
     ClientSubnet (/24 IPv4, /48 IPv6), AddrType (public / private / cgnat),
     WorkspaceAppVersion (Citrix Workspace app version as reported by the connection), ClientPlatform,
     and hour of day (local time).

  It also shows whether the bad sessions belong to many different users or to a few repeat ones.

  LATENCY COMPARISON: besides ICA RTT the script also collects every latency field the tenant exposes on
  SessionMetrics (IcaLatency, and where available ClientL7Latency / ServerL7Latency / WanLatency / DcLatency).
  One of them (see -LatencyField) is used as "network latency" next to the RTT: per-group median latency, share
  of sessions whose latency is over -LatencyThresholdMs, the RTT-minus-latency gap, the correlation between the
  two, and a 2x2 table (RTT high/low x latency high/low) that shows whether a high RTT is matched by a high latency.

  Field names are DISCOVERED at run time from  <base>/$metadata  - nothing is hard-coded that the
  tenant does not have. Dimensions the tenant does not expose are listed as "not available" and skipped.
  Run with -Discover first to see exactly what your tenant exposes.

  Safety:
    - Use -Anonymous to keep user names out of the output entirely (machines and IPs stay, see below).
    - Read-only: one POST to the token endpoint, then GET requests only.
    - Client ID / Secret are asked for at run time (console prompts), never written to disk, never on the
      command line, never printed. Token is kept in memory only.
    - The token is only ever sent to the host chosen in -ApiHost; a nextLink to any other host aborts.
    - NO data is sent anywhere else (client IPs are NOT looked up on third-party services).
    - Output (-RawStore, -OutCsv) contains client IP addresses, machine names and (unless
      -AnonymizeUsers) user names: personal data. Store it accordingly, delete it when done.

.PARAMETER CustomerId       Citrix Cloud customer ID.
.PARAMETER ThresholdMs      A session is "bad" when its MEDIAN ICA RTT is above this. Default 150.
.PARAMETER Hours            Look-back window per collection. Default 1 (per-session samples are only kept
                            for a short time - roughly an hour - so use -Loop + -RawStore for a longer view).
.PARAMETER Discover         Print the entities/fields the tenant exposes (connection, transport, client
                            fields) and exit. Do this first on a new tenant.
.PARAMETER RawStore         CSV that accumulates ALL collected samples between runs (deduplicated); the analysis
                            covers the whole store. Default: .\rtt_samples.csv (.\rtt_samples_anon.csv with
                            -Anonymous) in the current directory. Without -Anonymous it contains user names.
.PARAMETER Loop             Repeat the collection every -IntervalMinutes for -DurationHours (then analyse).
                            Keeps the credential in memory for the duration and refreshes the token itself.
.PARAMETER AnonymizeUsers   Replace user names with a stable short hash (u_xxxxxxxx). Pseudonymisation only:
                            low-entropy names can be brute-forced, so still treat the output as personal data.
.PARAMETER Anonymous        USER-ANONYMOUS MODE. The user NAME is never requested from the API and never written.
                            Kept per sample: Transaction ID (falls back to the session GUID if the tenant does not
                            expose one; look it up in Director / Session Launch Diagnostics if a case needs the person),
                            Country / Location, machine name, client IP address and its /24 subnet, ICA RTT / latency,
                            and technical attributes (delivery group, PoP/gateway host, transport, Citrix Workspace app
                            version, platform, public/private address type). Machine names and IP addresses can still
                            point to a person (single-user VDI, home IP): treat the output as personal data. The
                            repeat-user check is unavailable in this mode.
.PARAMETER GeoCsv           Offline CIDR -> country table used in -Anonymous mode when the tenant itself exposes no
                            country/location field. CSV with a header and columns  Network,Country[,Location]
                            (e.g. 85.10.0.0/16,DE,Frankfurt). IPv4 only, non-overlapping ranges. Nothing is sent to
                            any online geo-IP service. Without it (and without a tenant field) Country is 'unknown'.
.PARAMETER MinSessions      Hide groups with fewer sessions than this (noise filter). Default 5.
.PARAMETER LatencyField     The SessionMetrics latency field used as "network latency" for the comparison with ICA RTT.
                            Default: a field named Network*Latency* if the tenant has one, otherwise IcaLatency,
                            otherwise the first *Latency* field. Run -Discover to see the candidates. All other latency
                            fields are still written to the CSV as Lat_<FieldName> columns.
.PARAMETER LatencyThresholdMs A session counts as "latency high" when its median latency is over this value. Default: the
                            same value as -ThresholdMs (latency is a component of RTT, so also try a lower value, e.g. 100).
.PARAMETER OutCsv           The full breakdown table. Default: .\rtt_breakdown.csv (.\rtt_breakdown_anon.csv).
.PARAMETER CustomerId       Optional. Citrix Cloud customer ID; if omitted the wizard asks for it.
.PARAMETER Credential       Optional (non-interactive use): PSCredential with User = Client ID, Password = Secret.
                            If omitted the wizard asks.
.PARAMETER ConnectionNav    Override: navigation property from Session to the connection (e.g. CurrentConnection).
.PARAMETER TransportFields  Override: property names that carry the EDT/TCP transport, if auto-detection misses them.

.EXAMPLE
  # starts the wizard: paste the Customer ID, then the token (nothing is saved)
  .\Get-IcaRttBreakdown.ps1 -Discover
.EXAMPLE
  # collects into rtt_samples_anon.csv and writes rtt_breakdown_anon.csv
  .\Get-IcaRttBreakdown.ps1 -Anonymous -GeoCsv .\geo.csv
.EXAMPLE
  # one working day of data, collected every 30 min, then analysed
  .\Get-IcaRttBreakdown.ps1 -Anonymous -GeoCsv .\geo.csv -Loop -DurationHours 10
.EXAMPLE
  # analyse what was already collected (adds almost nothing new)
  .\Get-IcaRttBreakdown.ps1 -Anonymous -Hours 0.01

.NOTES
  How to get the Customer ID and the token: see docs/HOW_TO_GET_A_TOKEN.md (English) or docs/JAK_POBRAC_TOKEN.md (Polish).
  Nothing about the connection is stored: the wizard runs every time and everything lives in memory only.
  Wizard options: [3] Client ID + Secret of an API client (DEFAULT, renewable, works in any host), [1] sign in to
  Citrix Cloud in a window (needs Citrix's Remote PowerShell SDK + Windows PowerShell 5.1; the token is read from
  the SDK session, which renews it), [2] paste an access token (lasts about 1 h). Delete / rotate any service principal in
  Citrix Cloud when the investigation is over.
  STATUS: parse-checked and logic-tested on synthetic data only; never run against a live tenant. If a query
  returns HTTP 400 the message names the offending field - run -Discover and use -ConnectionNav /
  -TransportFields to adapt.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$CustomerId,
    [int]$ThresholdMs = 150,
    [double]$Hours = 1,
    [ValidateSet('api.cloud.com', 'api-eu.cloud.com', 'api.citrixcloud.jp', 'api.cloud.us')][string]$ApiHost = 'api.cloud.com',
    [ValidateRange(1, 100)][int]$PageSize = 100,
    [int]$MaxPages = 300,
    [int]$MinSessions = 5,
    [string]$LatencyField,
    [int]$LatencyThresholdMs,
    [switch]$Discover,
    [string]$RawStore,
    [switch]$Loop,
    [int]$IntervalMinutes = 30,
    [double]$DurationHours = 24,
    [switch]$AnonymizeUsers,
    [switch]$Anonymous,
    [string]$GeoCsv,
    [string]$OutCsv,
    [string]$ConnectionNav,
    [string[]]$TransportFields,
    [System.Management.Automation.PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Headers = $null
$script:TokenAcquired = [datetime]::MinValue
$InvariantCulture = [Globalization.CultureInfo]::InvariantCulture

# --- helpers -----------------------------------------------------------------
function Get-HttpStatus($err) {
    $p = $err.Exception.PSObject.Properties['Response']
    if ($p -and $p.Value) { return [int]$p.Value.StatusCode }
    return $null
}

function ConvertTo-UtcDate($v) {
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    [datetime]::Parse([string]$v, $InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj -or -not $name) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

function Update-Token([pscredential]$Cred) {
    $secret = $Cred.GetNetworkCredential().Password
    try {
        $r = Invoke-RestMethod -Method Post `
            -Uri "https://$ApiHost/cctrustoauth2/$CustomerId/tokens/clients" `
            -Headers @{ Accept = 'application/json' } `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ grant_type = 'client_credentials'; client_id = $Cred.UserName; client_secret = $secret }
    }
    catch {
        $st = Get-HttpStatus $_
        $detail = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = ' ' + $_.ErrorDetails.Message; if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) } }
        $hint = ''
        if ($st -eq 400 -or $st -eq 401 -or "$($_.Exception.Message)" -match '\((400|401)\)') { $hint = "`nCheck: the Customer ID must be the Citrix Cloud account ID (CCID), NOT the Org ID and NOT the Client ID; the Client ID and Secret must belong to an API client of that same account; no stray spaces; the right -ApiHost region." }
        throw "Token request failed (HTTP $st): $($_.Exception.Message)$detail$hint"
    }
    finally { $secret = $null }
    $script:Headers = @{
        Authorization       = "CWSAuth bearer=$($r.access_token)"
        'Citrix-CustomerId' = $CustomerId
        Accept              = 'application/json'
    }
    $script:TokenAcquired = Get-Date
    $r = $null
}

function Invoke-ODataGet([string]$Url) {
    if (([uri]$Url).Host -ne $ApiHost) { throw "Refusing to send the token to unexpected host: $(([uri]$Url).Host)" }
    try { return Invoke-RestMethod -Method Get -Uri $Url -Headers $script:Headers }
    catch {
        $detail = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
            if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
        }
        $status = Get-HttpStatus $_
        if ($status -eq 401) { throw 'OData request failed (HTTP 401): the token is expired or invalid. A token lasts about 1 hour - run the wizard again.' }
        throw "OData request failed (HTTP $status): $($_.Exception.Message) $detail`nIf this is HTTP 400 a field name probably differs in your tenant: run with -Discover, then use -ConnectionNav / -TransportFields."
    }
}

# --- metadata ----------------------------------------------------------------
function ConvertFrom-ODataMetadata($Xml) {
    $types = @{}
    foreach ($et in $Xml.SelectNodes("//*[local-name()='EntityType']")) {
        $props = New-Object System.Collections.Generic.List[string]
        $nav = @{}
        foreach ($c in $et.ChildNodes) {
            if ($c.NodeType -ne 'Element') { continue }
            if ($c.LocalName -eq 'Property') { $props.Add($c.GetAttribute('Name')) }
            elseif ($c.LocalName -eq 'NavigationProperty') {
                $t = $c.GetAttribute('Type')
                $isColl = $t -match '^Collection\('
                $t = $t -replace '^Collection\((.*)\)$', '$1'
                $nav[$c.GetAttribute('Name')] = [pscustomobject]@{ Type = ($t -split '\.')[-1]; IsCollection = $isColl }
            }
        }
        $types[$et.GetAttribute('Name')] = [pscustomobject]@{ Props = @($props); Nav = $nav }
    }
    # entity sets (type name -> set name), needed for the separate delivery-group lookup
    $sets = @{}
    foreach ($es in $Xml.SelectNodes("//*[local-name()='EntitySet']")) {
        $tn = ($es.GetAttribute('EntityType') -split '\.')[-1]
        if ($tn -and -not $sets.ContainsKey($tn)) { $sets[$tn] = $es.GetAttribute('Name') }
    }
    $types['__EntitySets'] = [pscustomobject]@{ Props = @(); Nav = @{}; Sets = $sets }
    return $types
}

function Get-MonitorModel {
    $h = @{} + $script:Headers
    $h['Accept'] = 'application/xml'
    $resp = Invoke-WebRequest -Method Get -Uri ('https://{0}/monitorodata/$metadata' -f $ApiHost) -Headers $h -UseBasicParsing
    $text = $resp.Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    $text = ([string]$text).TrimStart([char]0xFEFF)
    return ConvertFrom-ODataMetadata ([xml]$text)
}

function Show-Discovery($Model) {
    $rx = 'Transport|Udp|Edt|Rendezvous|Protocol|Client|ConnectedVia|LaunchedVia|Gateway|Address|Rtt|Latency'
    foreach ($t in 'SessionMetrics', 'Session', 'Connection', 'Machine') {
        if (-not $Model.ContainsKey($t)) { Write-Host ("[{0}] entity type not found" -f $t) -ForegroundColor Yellow; continue }
        $m = $Model[$t]
        Write-Host ("`n[{0}]" -f $t) -ForegroundColor Cyan
        Write-Host ("  properties of interest: " + ((@($m.Props | Where-Object { $_ -match $rx })) -join ', '))
        Write-Host ("  all properties ({0}): " -f $m.Props.Count + ($m.Props -join ', '))
        Write-Host ("  navigation: " + ((@($m.Nav.Keys | ForEach-Object { "$_ -> $($m.Nav[$_].Type)$(if ($m.Nav[$_].IsCollection) { '[]' })" })) -join ', '))
    }
    Write-Host "`nEntity types that carry ClientAddress:" -ForegroundColor Cyan
    foreach ($k in $Model.Keys) { if ($Model[$k].Props -contains 'ClientAddress') { Write-Host "  $k" } }
    Write-Host "`nProperties anywhere that look like a transport indicator (Transport|Udp|Edt|Rendezvous):" -ForegroundColor Cyan
    $any = $false
    foreach ($k in $Model.Keys) {
        foreach ($p in $Model[$k].Props) { if ($p -cmatch 'Transport|Udp|Edt|Rendezvous') { Write-Host "  $k.$p"; $any = $true } }
    }
    if (-not $any) { Write-Host "  (none) - the Monitor OData model of this tenant does not expose EDT/TCP. Read the protocol in Director for a sample of good vs bad sessions instead." -ForegroundColor Yellow }

    Write-Host "`nLatency fields on SessionMetrics (candidates for -LatencyField; Disk* excluded):" -ForegroundColor Cyan
    if ($Model.ContainsKey('SessionMetrics')) {
        $lf = @($Model['SessionMetrics'].Props | Where-Object { $_ -cmatch 'Latency' -and $_ -notmatch 'Disk' })
        if ($lf.Count) { $lf | ForEach-Object { Write-Host "  SessionMetrics.$_" } }
        else { Write-Host '  (none) - the latency comparison will be skipped.' -ForegroundColor Yellow }
    }
    foreach ($pair in @(@('Transaction ID', 'Transaction'), @('country / location', 'Country|Location|City|Geo'))) {
        Write-Host ("`nProperties anywhere that look like a {0} ({1}) - used by -Anonymous:" -f $pair[0], $pair[1]) -ForegroundColor Cyan
        $any = $false
        foreach ($k in $Model.Keys) {
            foreach ($p in $Model[$k].Props) { if ($p -match $pair[1]) { Write-Host "  $k.$p"; $any = $true } }
        }
        if (-not $any) { Write-Host '  (none)' -ForegroundColor Yellow }
    }
}

function Resolve-QueryPlan($Model, [string]$ConnNavOverride, [string[]]$TransportOverride, [string]$LatencyOverride) {
    foreach ($need in 'SessionMetrics', 'Session', 'User', 'Machine') {
        if (-not $Model.ContainsKey($need)) { throw "Entity type '$need' not found in `$metadata. Run -Discover." }
    }
    $sm = $Model['SessionMetrics']
    foreach ($p in 'CollectedDate', 'IcaRttMS') {
        if ($sm.Props -notcontains $p) { throw "SessionMetrics has no '$p' property in this tenant. Run -Discover." }
    }
    if (-not $sm.Nav.ContainsKey('Session')) { throw "SessionMetrics has no 'Session' navigation property. Run -Discover." }
    $sess = $Model['Session']
    $sessKey = if ($sess.Props -contains 'SessionKey') { 'SessionKey' } else { 'Id' }

    # which connection entity (if any) hangs off Session
    $connNav = $null; $connType = $null; $connIsColl = $false
    $cands = if ($ConnNavOverride) { @($ConnNavOverride) } else { @('CurrentConnection', 'Connection', 'Connections') }
    foreach ($c in $cands) {
        if ($sess.Nav.ContainsKey($c)) { $connNav = $c; $connType = $sess.Nav[$c].Type; $connIsColl = $sess.Nav[$c].IsCollection; break }
    }
    if ($ConnNavOverride -and -not $connNav) { throw "Session has no navigation property '$ConnNavOverride'. Run -Discover." }
    $conn = if ($connType -and $Model.ContainsKey($connType)) { $Model[$connType] } else { $null }

    $wanted = 'ClientAddress', 'ClientVersion', 'ClientPlatform', 'ConnectedViaHostName', 'ConnectedViaIPAddress',
              'LaunchedViaHostName', 'LaunchedViaIPAddress', 'Protocol'
    $sessFields = New-Object System.Collections.Generic.List[string]
    $connFields = New-Object System.Collections.Generic.List[string]
    $sessFields.Add($sessKey)
    foreach ($w in $wanted) {
        if ($sess.Props -contains $w) { $sessFields.Add($w) }
        elseif ($conn -and ($conn.Props -contains $w)) { $connFields.Add($w) }
    }

    # transport indicator(s): by regex over Session / Connection / SessionMetrics, or explicit override
    $rx = 'Transport|Udp|Edt|Rendezvous'
    $metFields = New-Object System.Collections.Generic.List[string]
    $metFields.Add('CollectedDate'); $metFields.Add('IcaRttMS')
    # latency fields: every *Latency* property of SessionMetrics (disk latency excluded); one is the primary "network latency"
    $latFields = @($sm.Props | Where-Object { $_ -cmatch 'Latency' -and $_ -notmatch 'Disk' })
    foreach ($lf in $latFields) { if ($metFields -notcontains $lf) { $metFields.Add($lf) } }
    $latPrimary = $null
    if ($LatencyOverride) {
        if ($latFields -notcontains $LatencyOverride) { throw "SessionMetrics has no latency field '$LatencyOverride'. Candidates: $($latFields -join ', '). Run -Discover." }
        $latPrimary = $LatencyOverride
    } elseif ($latFields.Count -gt 0) {
        $net = @($latFields | Where-Object { $_ -cmatch '^Network.*Latency|^NetworkLatency' })
        if ($net.Count) { $latPrimary = $net[0] }
        elseif ($latFields -contains 'IcaLatency') { $latPrimary = 'IcaLatency' }
        else { $latPrimary = $latFields[0] }
    }
    $transport = New-Object System.Collections.Generic.List[string]   # entries "Source:Name"
    $pick = { param($name) ($TransportOverride -contains $name) -or (-not $TransportOverride -and $name -cmatch $rx) }
    foreach ($p in $sess.Props) { if (& $pick $p) { if ($sessFields -notcontains $p) { $sessFields.Add($p) }; $transport.Add("Session:$p") } }
    if ($conn) { foreach ($p in $conn.Props) { if (& $pick $p) { if ($connFields -notcontains $p) { $connFields.Add($p) }; $transport.Add("Conn:$p") } } }
    foreach ($p in $sm.Props) { if (& $pick $p) { if ($metFields -notcontains $p) { $metFields.Add($p) }; $transport.Add("Metrics:$p") } }

    # Transaction ID (session-launch diagnostics key) and tenant-provided country/location fields
    $txRx = 'Transaction'; $geoRx = 'Country|Location|City|Geo'
    $txField = $null
    $geo = New-Object System.Collections.Generic.List[string]
    $scan = @(@('Session', $sess), @('Conn', $conn), @('Metrics', $sm))
    foreach ($e in $scan) {
        if (-not $e[1]) { continue }
        foreach ($p in $e[1].Props) {
            $list = $metFields
            if ($e[0] -eq 'Session') { $list = $sessFields } elseif ($e[0] -eq 'Conn') { $list = $connFields }
            if (-not $txField -and $p -match $txRx) { $txField = "$($e[0]):$p"; if ($list -notcontains $p) { $list.Add($p) } }
            elseif ($p -match $geoRx) { $geo.Add("$($e[0]):$p"); if ($list -notcontains $p) { $list.Add($p) } }
        }
    }

    # Delivery group: the API allows $expand paths at most 2 levels deep (SessionMetrics > Session > Machine is already 2),
    # so the group name is NOT expanded; Machine.DesktopGroupId is selected and resolved through a separate DesktopGroups lookup.
    $dgNav = $false
    $dgSet = $null
    $mach = $Model['Machine']
    $machKey = if ($mach.Props -contains 'Id') { 'Id' } else { 'Name' }
    $setMap = $Model['__EntitySets']
    if ($mach.Props -contains 'DesktopGroupId' -and $Model.ContainsKey('DesktopGroup') -and
        ($Model['DesktopGroup'].Props -contains 'Id') -and ($Model['DesktopGroup'].Props -contains 'Name') -and
        $setMap -and $setMap.Sets.ContainsKey('DesktopGroup')) { $dgNav = $true; $dgSet = $setMap.Sets['DesktopGroup'] }

    [pscustomobject]@{
        SessionKeyField  = $sessKey
        MetricsFields    = @($metFields)
        SessionFields    = @($sessFields)
        ConnNav          = $connNav
        ConnFields       = @($connFields)
        DeliveryGroupNav = $dgNav
        TransportFields  = @($transport)
        TransactionField = $txField
        GeoFields        = @($geo)
        MachineKey       = $machKey
        DeliveryGroupSet = $dgSet
        LatencyFields    = @($latFields)
        LatencyPrimary   = $latPrimary
    }
}

function Get-SamplesUrl($Plan, [string]$ApiHost, [string]$SinceIso, [int]$PageSize, [bool]$AnonymousMode = $false) {
    # -Anonymous: the user NAME is not requested at all.
    $machExpand = if ($Plan.DeliveryGroupNav) { 'Machine($select=Name,DesktopGroupId)' } else { 'Machine($select=Name)' }
    [string[]]$inner = if ($AnonymousMode) { $machExpand } else { 'User($select=UserName)'; $machExpand }
    if ($Plan.ConnNav -and $Plan.ConnFields.Count -gt 0) { $inner += ('{0}($select={1})' -f $Plan.ConnNav, ($Plan.ConnFields -join ',')) }
    $expand = 'Session($select=' + ($Plan.SessionFields -join ',') + ';$expand=' + ($inner -join ',') + ')'
    $q = '$filter=CollectedDate%20ge%20' + $SinceIso +
         '&$select=' + ($Plan.MetricsFields -join ',') +
         '&$expand=' + $expand +
         '&$orderby=CollectedDate%20desc' +
         '&$top=' + $PageSize +
         '&$count=true'
    return "https://$ApiHost/monitorodata/SessionMetrics?$q"
}

# --- flattening --------------------------------------------------------------
function Get-ClientSubnet([string]$ip) {
    if (-not $ip) { return '' }
    $a = $null
    if (-not [Net.IPAddress]::TryParse($ip, [ref]$a)) { return '' }
    $b = $a.GetAddressBytes()
    if ($a.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return ('{0}.{1}.{2}.0/24' -f $b[0], $b[1], $b[2]) }
    return ('{0:x2}{1:x2}:{2:x2}{3:x2}:{4:x2}{5:x2}::/48' -f $b[0], $b[1], $b[2], $b[3], $b[4], $b[5])
}

function Get-AddrType([string]$ip) {
    if (-not $ip) { return '' }
    $a = $null
    if (-not [Net.IPAddress]::TryParse($ip, [ref]$a)) { return '' }
    $b = $a.GetAddressBytes()
    if ($a.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        if ($b[0] -eq 10) { return 'private' }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return 'private' }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return 'private' }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return 'private' }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return 'cgnat' }
        return 'public'
    }
    if (($b[0] -band 0xFE) -eq 0xFC) { return 'private' }
    return 'public'
}

function Get-UserLabel([string]$u) {
    if (-not $AnonymizeUsers -or -not $u) { return $u }
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($u.ToLowerInvariant()))
    return 'u_' + ((($h[0..3]) | ForEach-Object { $_.ToString('x2') }) -join '')
}

$script:GeoStarts = $null; $script:GeoEnds = $null; $script:GeoCountry = $null; $script:GeoLoc = $null

function ConvertTo-IPv4Number([string]$ip) {
    $a = $null
    if (-not [Net.IPAddress]::TryParse($ip, [ref]$a)) { return $null }
    if ($a.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $b = $a.GetAddressBytes()
    return ([long]$b[0] * 16777216 + [long]$b[1] * 65536 + [long]$b[2] * 256 + [long]$b[3])
}

function Import-GeoTable([string]$Path) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($r in (Import-Csv -LiteralPath $Path)) {
        $net = [string]$r.Network
        if ($net -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') { continue }
        $parts = $net.Split('/'); $pre = [int]$parts[1]
        $n = ConvertTo-IPv4Number $parts[0]
        if ($null -eq $n -or $pre -gt 32) { continue }
        $size = [long][math]::Pow(2, 32 - $pre)
        $start = [long]([math]::Floor($n / $size) * $size)
        $items.Add([pscustomobject]@{ S = $start; E = $start + $size - 1; C = [string]$r.Country; L = [string]$r.Location })
    }
    $sorted = @($items | Sort-Object S)
    if ($sorted.Count -eq 0) { throw "No usable 'Network,Country' IPv4 CIDR rows in $Path" }
    $overlaps = 0
    for ($i = 1; $i -lt $sorted.Count; $i++) { if ($sorted[$i].S -le $sorted[$i - 1].E) { $overlaps++ } }
    if ($overlaps -gt 0) { Write-Warning "$overlaps overlapping ranges in $Path - addresses inside the broader range but outside the nested one will resolve to 'unknown'. Use non-overlapping ranges." }
    $script:GeoStarts = [long[]]@($sorted | ForEach-Object { $_.S })
    $script:GeoEnds = [long[]]@($sorted | ForEach-Object { $_.E })
    $script:GeoCountry = @($sorted | ForEach-Object { $_.C })
    $script:GeoLoc = @($sorted | ForEach-Object { $_.L })
    Write-Host ("Geo table: {0} IPv4 ranges loaded from {1} (offline, nothing is sent anywhere)." -f $sorted.Count, $Path)
}

function Get-GeoFromTable([string]$ip) {
    if (-not $script:GeoStarts) { return $null }
    $n = ConvertTo-IPv4Number $ip
    if ($null -eq $n) { return $null }
    $lo = 0; $hi = $script:GeoStarts.Length - 1; $found = -1
    while ($lo -le $hi) {
        $mid = [int][math]::Floor(($lo + $hi) / 2)
        if ($script:GeoStarts[$mid] -le $n) { $found = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    if ($found -ge 0 -and $n -le $script:GeoEnds[$found]) { return $found }
    return $null
}

function Resolve-DeliveryGroup($Mach) {
    if (-not $Mach) { return '' }
    $gid = Get-Prop $Mach 'DesktopGroupId'
    if ($gid -and $script:DgMap) {
        $k = ([string]$gid).ToLowerInvariant()
        if ($script:DgMap.ContainsKey($k)) { return [string]$script:DgMap[$k] }
    }
    return ''
}

function ConvertTo-FlatRow($v, $Plan) {
    $s = Get-Prop $v 'Session'
    $conn = $null
    if ($Plan.ConnNav -and $s) {
        $c = @(Get-Prop $s $Plan.ConnNav | Where-Object { $null -ne $_ })
        if ($c.Count -gt 0) { $conn = $c[-1] }
    }
    $get = {
        param($name)
        $x = Get-Prop $s $name
        if ($null -eq $x) { $x = Get-Prop $conn $name }
        if ($null -eq $x) { $x = Get-Prop $v $name }
        if ($null -eq $x) { '' } else { [string]$x }
    }
    $tr = @()
    foreach ($t in $Plan.TransportFields) {
        $name = ($t -split ':', 2)[1]
        $val = & $get $name
        if ($val -ne '') { $tr += "$name=$val" }
    }
    $mach = Get-Prop $s 'Machine'

    if ($Anonymous) {
        # No user name. Transaction ID, country / location, machine, client IP and the rest are kept.
        $machA = if ($mach) { [string](Get-Prop $mach 'Name') } else { '' }
        $dgA = Resolve-DeliveryGroup $mach
        $ip = & $get 'ClientAddress'
        $country = ''; $loc = ''
        foreach ($g in $Plan.GeoFields) {
            $gn = ($g -split ':', 2)[1]; $gv = & $get $gn
            if ($gv -eq '') { continue }
            if ($gn -match 'Country' -and -not $country) { $country = $gv } elseif (-not $loc) { $loc = $gv }
        }
        if ($ip -and $script:GeoStarts) {
            $gi = Get-GeoFromTable $ip
            if ($null -ne $gi) {
                if (-not $country) { $country = $script:GeoCountry[$gi] }
                if (-not $loc) { $loc = $script:GeoLoc[$gi] }
            }
        }
        if (-not $country) { $country = 'unknown' }
        $txv = ''
        if ($Plan.TransactionField) { $txv = & $get (($Plan.TransactionField -split ':', 2)[1]) }
        if (-not $txv) { $txv = & $get $Plan.SessionKeyField }
        $keyCol = if ($Plan.TransactionField) { 'TransactionId' } else { 'SessionKey' }
        $viaA = & $get 'ConnectedViaHostName'; if (-not $viaA) { $viaA = & $get 'ConnectedViaIPAddress' }
        $lviaA = & $get 'LaunchedViaHostName'; if (-not $lviaA) { $lviaA = & $get 'LaunchedViaIPAddress' }
        $row = [ordered]@{}
        $row['CollectedUtc'] = (ConvertTo-UtcDate (Get-Prop $v 'CollectedDate')).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $InvariantCulture)
        $row[$keyCol] = $txv
        $row['Country'] = $country
        $row['Location'] = $loc
        $row['Machine'] = $machA
        $row['DeliveryGroup'] = $dgA
        $row['ClientAddress'] = $ip
        $row['ClientSubnet'] = Get-ClientSubnet $ip
        $row['AddrType'] = Get-AddrType $ip
        $row['RttMs'] = [int](Get-Prop $v 'IcaRttMS')
        $row['LatencyMs'] = if ($Plan.LatencyPrimary) { & $get $Plan.LatencyPrimary } else { '' }
        $row['Protocol'] = & $get 'Protocol'
        $row['Transport'] = ($tr -join '; ')
        $row['ConnectedVia'] = $viaA
        $row['LaunchedVia'] = $lviaA
        $row['WorkspaceAppVersion'] = & $get 'ClientVersion'
        $row['ClientPlatform'] = & $get 'ClientPlatform'
        foreach ($lf in $Plan.LatencyFields) { if ($lf -ne $Plan.LatencyPrimary) { $row["Lat_$lf"] = & $get $lf } }
        return [pscustomobject]$row
    }

    $user = ''
    $u = Get-Prop $s 'User'; if ($u) { $user = [string](Get-Prop $u 'UserName') }
    $machName = if ($mach) { [string](Get-Prop $mach 'Name') } else { '' }
    $dg = Resolve-DeliveryGroup $mach
    $addr = & $get 'ClientAddress'
    $cvia = & $get 'ConnectedViaHostName'; if (-not $cvia) { $cvia = & $get 'ConnectedViaIPAddress' }
    $lvia = & $get 'LaunchedViaHostName'; if (-not $lvia) { $lvia = & $get 'LaunchedViaIPAddress' }
    $lat = if ($Plan.LatencyPrimary) { & $get $Plan.LatencyPrimary } else { '' }
    $out = [ordered]@{
        CollectedUtc  = (ConvertTo-UtcDate (Get-Prop $v 'CollectedDate')).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $InvariantCulture)
        SessionKey    = & $get $Plan.SessionKeyField
        User          = Get-UserLabel $user
        Machine       = $machName
        DeliveryGroup = $dg
        RttMs         = [int](Get-Prop $v 'IcaRttMS')
        LatencyMs     = $lat
        Protocol      = & $get 'Protocol'
        Transport     = ($tr -join '; ')
        ClientAddress = $addr
        ClientSubnet  = Get-ClientSubnet $addr
        AddrType      = Get-AddrType $addr
        WorkspaceAppVersion = & $get 'ClientVersion'
        ClientPlatform = & $get 'ClientPlatform'
        ConnectedVia  = $cvia
        LaunchedVia   = $lvia
    }
    foreach ($lf in $Plan.LatencyFields) { if ($lf -ne $Plan.LatencyPrimary) { $out["Lat_$lf"] = & $get $lf } }
    [pscustomobject]$out
}

# --- collection ----------------------------------------------------------------
$script:DgMap = $null
function Get-DeliveryGroupMap($Plan) {
    # one small paged GET: Id -> Name of every delivery group (read-only)
    $map = @{}
    if (-not $Plan.DeliveryGroupSet) { return $map }
    $url = "https://$ApiHost/monitorodata/$($Plan.DeliveryGroupSet)?`$select=Id,Name&`$top=$PageSize"
    $pages = 0
    while ($url -and $pages -lt 50) {
        $r = Invoke-ODataGet $url
        foreach ($g in $r.value) { if ($g.Id) { $map[([string]$g.Id).ToLowerInvariant()] = [string]$g.Name } }
        $url = $null
        if ($r.PSObject.Properties['@odata.nextLink']) { $url = $r.'@odata.nextLink' }
        $pages++
    }
    return $map
}

function Get-FlatSamples($Plan, [double]$WindowHours) {
    $since = (Get-Date).ToUniversalTime().AddHours(-$WindowHours).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $InvariantCulture)
    $url = Get-SamplesUrl -Plan $Plan -ApiHost $ApiHost -SinceIso $since -PageSize $PageSize -AnonymousMode ([bool]$Anonymous)
    $rows = New-Object System.Collections.Generic.List[object]
    $total = $null; $page = 0
    while ($url -and $page -lt $MaxPages) {
        $r = Invoke-ODataGet $url
        if ($null -eq $total -and $r.PSObject.Properties['@odata.count']) { $total = $r.'@odata.count' }
        foreach ($v in $r.value) { $rows.Add((ConvertTo-FlatRow $v $Plan)) }
        $url = $null
        if ($r.PSObject.Properties['@odata.nextLink']) { $url = $r.'@odata.nextLink' }
        $page++
    }
    Write-Host ("  fetched {0} samples since {1}{2}" -f $rows.Count, $since, $(if ($null -ne $total) { " (server count: $total)" } else { '' }))
    if ($url) { Write-Warning "Stopped after $MaxPages pages - incomplete. Raise -MaxPages or lower -Hours." }
    return , $rows
}

function Get-KeyProp($Row) {
    if ($Row.PSObject.Properties['TransactionId']) { return 'TransactionId' }
    return 'SessionKey'
}

function Add-ToStore($Rows, [string]$Path) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path -LiteralPath $Path) {
        $existing = @(Import-Csv -LiteralPath $Path)
        if ($existing.Count -gt 0) {
            $hasPersonal = [bool]$existing[0].PSObject.Properties['User']
            if ($Anonymous -and $hasPersonal) { throw "$Path already holds user names. Use a new file for -Anonymous, and delete the old one." }
            if (-not $Anonymous -and -not $hasPersonal) { throw "$Path is an anonymous store; run with -Anonymous to keep adding to it." }
            if ($Rows.Count -gt 0) {
                $oldCols = @($existing[0].PSObject.Properties.Name)
                $newCols = @($Rows[0].PSObject.Properties.Name)
                if (@(Compare-Object $oldCols $newCols).Count -gt 0) {
                    throw "The columns of $Path ($($oldCols -join ',')) differ from the columns this run produces ($($newCols -join ',')) - for example a different -LatencyField or an older script version. Use a new -RawStore file."
                }
            }
            $kp = Get-KeyProp $existing[0]
            foreach ($o in $existing) { [void]$seen.Add("$($o.$kp)|$($o.CollectedUtc)") }
        }
    }
    $nkp = if ($Rows.Count -gt 0) { Get-KeyProp $Rows[0] } else { 'SessionKey' }
    $new = @($Rows | Where-Object { $seen.Add("$($_.$nkp)|$($_.CollectedUtc)") })
    if ($new.Count -gt 0) { $new | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Append }
    Write-Host ("  store: +{0} new samples ({1} already known)" -f $new.Count, ($Rows.Count - $new.Count))
}

# --- analysis ------------------------------------------------------------------
function Get-Percentile($Values, [double]$P) {
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    $i = [int][math]::Ceiling($P / 100 * $s.Count) - 1
    if ($i -lt 0) { $i = 0 }
    return $s[$i]
}

function Get-Correlation($X, $Y) {
    $x = @($X | ForEach-Object { [double]$_ }); $y = @($Y | ForEach-Object { [double]$_ })
    $n = $x.Count
    if ($n -lt 3 -or $y.Count -ne $n) { return $null }
    $mx = ($x | Measure-Object -Average).Average; $my = ($y | Measure-Object -Average).Average
    $sxy = 0.0; $sxx = 0.0; $syy = 0.0
    for ($i = 0; $i -lt $n; $i++) { $dx = $x[$i] - $mx; $dy = $y[$i] - $my; $sxy += $dx * $dy; $sxx += $dx * $dx; $syy += $dy * $dy }
    if ($sxx -le 0 -or $syy -le 0) { return $null }
    return [math]::Round($sxy / [math]::Sqrt($sxx * $syy), 2)
}

function ConvertTo-SessionSummaries($Rows) {
    $kp = Get-KeyProp @($Rows)[0]
    $Rows | Group-Object { $k = $_.$kp; if ($k) { $k } else { '(unknown)' } } | ForEach-Object {
        $g = @($_.Group | Sort-Object CollectedUtc)
        $rtts = @($g | ForEach-Object { [double]$_.RttMs })
        $lats = @($g | Where-Object { "$($_.LatencyMs)" -ne '' } | ForEach-Object { [double]$_.LatencyMs })
        $medRtt = Get-Percentile $rtts 50
        $medLat = if ($lats.Count) { Get-Percentile $lats 50 } else { $null }
        $latest = { param($prop) $x = @($g | Where-Object { $_.$prop } | Select-Object -Last 1); if ($x.Count) { $x[0].$prop } else { '' } }
        [pscustomobject]@{
            SessionKey     = $_.Name
            User           = & $latest 'User'
            Machine        = & $latest 'Machine'
            DeliveryGroup  = & $latest 'DeliveryGroup'
            Protocol       = & $latest 'Protocol'
            Transport      = & $latest 'Transport'
            ConnectedVia   = & $latest 'ConnectedVia'
            LaunchedVia    = & $latest 'LaunchedVia'
            ClientSubnet   = & $latest 'ClientSubnet'
            Country        = & $latest 'Country'
            Location       = & $latest 'Location'
            AddrType       = & $latest 'AddrType'
            WorkspaceAppVersion = & $latest 'WorkspaceAppVersion'
            ClientPlatform = & $latest 'ClientPlatform'
            MedianRtt      = $medRtt
            MedianLat      = $medLat
            Gap            = if ($null -ne $medLat) { $medRtt - $medLat } else { $null }
            Samples        = $g.Count
            Rtts           = $rtts
            Lats           = $lats
        }
    }
}

function Get-Breakdown($Sessions, [string]$Dimension, [int]$Threshold, [int]$Min, [int]$LatThreshold) {
    $Sessions | Group-Object { $v = $_.$Dimension; if ($v) { $v } else { '(n/a)' } } | ForEach-Object {
        $grp = @($_.Group)
        $bad = @($grp | Where-Object { $_.MedianRtt -gt $Threshold }).Count
        $all = @($grp | ForEach-Object { $_.Rtts })
        $withLat = @($grp | Where-Object { $null -ne $_.MedianLat })
        $latBad = @($withLat | Where-Object { $_.MedianLat -gt $LatThreshold }).Count
        $allLat = @($grp | ForEach-Object { $_.Lats })
        $gaps = @($withLat | ForEach-Object { $_.Gap })
        [pscustomobject]@{
            Dimension = $Dimension; Value = $_.Name; Unit = 'sessions'; Count = $grp.Count; Bad = $bad
            BadPct = [math]::Round(100.0 * $bad / $grp.Count, 1)
            MedianRtt = Get-Percentile $all 50; P95Rtt = Get-Percentile $all 95
            LatSessions = $withLat.Count; LatBad = $latBad
            LatBadPct = $(if ($withLat.Count) { [math]::Round(100.0 * $latBad / $withLat.Count, 1) } else { $null })
            MedianLatency = $(if ($allLat.Count) { Get-Percentile $allLat 50 } else { $null })
            P95Latency = $(if ($allLat.Count) { Get-Percentile $allLat 95 } else { $null })
            MedianGap = $(if ($gaps.Count) { Get-Percentile $gaps 50 } else { $null })
        }
    } | Where-Object { $_.Count -ge $Min }
}

function Get-HourBreakdown($Rows, [int]$Threshold, [int]$LatThreshold) {
    $Rows | Group-Object { (ConvertTo-UtcDate $_.CollectedUtc).ToLocalTime().ToString('HH') + ':00' } | ForEach-Object {
        $grp = @($_.Group)
        $bad = @($grp | Where-Object { [int]$_.RttMs -gt $Threshold }).Count
        $all = @($grp | ForEach-Object { [double]$_.RttMs })
        $lat = @($grp | Where-Object { "$($_.LatencyMs)" -ne '' } | ForEach-Object { [double]$_.LatencyMs })
        $latBad = @($lat | Where-Object { $_ -gt $LatThreshold }).Count
        [pscustomobject]@{
            Dimension = 'HourLocal'; Value = $_.Name; Unit = 'samples'; Count = $grp.Count; Bad = $bad
            BadPct = [math]::Round(100.0 * $bad / $grp.Count, 1)
            MedianRtt = Get-Percentile $all 50; P95Rtt = Get-Percentile $all 95
            LatSessions = $lat.Count; LatBad = $latBad
            LatBadPct = $(if ($lat.Count) { [math]::Round(100.0 * $latBad / $lat.Count, 1) } else { $null })
            MedianLatency = $(if ($lat.Count) { Get-Percentile $lat 50 } else { $null })
            P95Latency = $(if ($lat.Count) { Get-Percentile $lat 95 } else { $null })
            MedianGap = $null
        }
    } | Sort-Object Value
}

function Show-Analysis($Rows, [int]$Threshold, [int]$Min, [string]$Csv, [int]$LatThreshold = 0) {
    if ($LatThreshold -le 0) { $LatThreshold = $Threshold }
    $rows = @($Rows | ForEach-Object { $_ })
    if ($rows.Count -eq 0) { Write-Host 'No samples to analyse.'; return }
    $sessions = @(ConvertTo-SessionSummaries $rows)
    $badSessions = @($sessions | Where-Object { $_.MedianRtt -gt $Threshold })
    $users = @($sessions | Where-Object { $_.User } | Select-Object -ExpandProperty User -Unique)
    $badUsers = @($badSessions | Where-Object { $_.User } | Select-Object -ExpandProperty User -Unique)

    Write-Host ("`n=== Overview (bad = session median ICA RTT > {0} ms) ===" -f $Threshold) -ForegroundColor Cyan
    Write-Host ("Samples: {0}   Sessions: {1}   Bad sessions: {2} ({3}%)" -f $rows.Count, $sessions.Count, $badSessions.Count,
        [math]::Round(100.0 * $badSessions.Count / [math]::Max(1, $sessions.Count), 1))
    $personal = [bool]$rows[0].PSObject.Properties['User']
    if ($personal) {
        Write-Host ("Users: {0}   Users with a bad session: {1}" -f $users.Count, $badUsers.Count)
        $rep = @($badSessions | Where-Object { $_.User } | Group-Object User | Sort-Object Count -Descending | Select-Object -First 5)
        if ($rep.Count) { Write-Host ("Most repeated users among bad sessions: " + (($rep | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')) }
        if ($badSessions.Count -gt 0 -and $badUsers.Count -gt 0) {
            Write-Host ("Bad sessions per bad user: {0:N1}  (close to 1.0 = many different users; much higher = few repeat users)" -f ($badSessions.Count / $badUsers.Count))
        }
    } else {
        Write-Host 'Anonymous data: no user names, so the repeat-user check is not available.'
        $unk = @($sessions | Where-Object { $_.Country -eq 'unknown' }).Count
        if ($unk -eq $sessions.Count) { Write-Warning "Country is 'unknown' for every session: the tenant exposes no country field and no usable -GeoCsv was given." }
    }

    # ---- ICA RTT vs latency ----
    $withLat = @($sessions | Where-Object { $null -ne $_.MedianLat })
    $hasLat = $withLat.Count -gt 0
    $latLabel = if ($script:LatencyLabel) { $script:LatencyLabel } else { 'latency' }
    if ($hasLat) {
        $medRttAll = Get-Percentile @($withLat | ForEach-Object { $_.MedianRtt }) 50
        $medLatAll = Get-Percentile @($withLat | ForEach-Object { $_.MedianLat }) 50
        $medGapAll = Get-Percentile @($withLat | ForEach-Object { $_.Gap }) 50
        $corr = Get-Correlation @($withLat | ForEach-Object { $_.MedianRtt }) @($withLat | ForEach-Object { $_.MedianLat })
        Write-Host ("`n=== ICA RTT vs {0} (latency threshold {1} ms) ===" -f $latLabel, $LatThreshold) -ForegroundColor Cyan
        Write-Host ("Sessions with latency data: {0} of {1} ({2}%)" -f $withLat.Count, $sessions.Count, [math]::Round(100.0 * $withLat.Count / $sessions.Count, 1))
        Write-Host ("Median over sessions: RTT {0} ms, latency {1} ms, RTT minus latency {2} ms" -f $medRttAll, $medLatAll, $medGapAll)
        Write-Host ("Correlation of session median RTT and latency: {0}   (1 = move together, 0 = unrelated)" -f $(if ($null -ne $corr) { $corr } else { 'n/a' }))
        $zeroShare = 0.0
        $allLatSamples = @($withLat | ForEach-Object { $_.Lats })
        if ($allLatSamples.Count) { $zeroShare = @($allLatSamples | Where-Object { $_ -eq 0 }).Count / $allLatSamples.Count }
        if ($zeroShare -ge 0.9) { Write-Warning ("{0}% of the latency samples are 0 - the field is probably not populated on this path (see Citrix article CTX616926 about ICA Latency reported as 0). The comparison is not meaningful." -f [math]::Round(100 * $zeroShare)) }
        $a = @($withLat | Where-Object { $_.MedianRtt -gt $Threshold -and $_.MedianLat -gt $LatThreshold }).Count
        $b = @($withLat | Where-Object { $_.MedianRtt -gt $Threshold -and $_.MedianLat -le $LatThreshold }).Count
        $c = @($withLat | Where-Object { $_.MedianRtt -le $Threshold -and $_.MedianLat -gt $LatThreshold }).Count
        $d = @($withLat | Where-Object { $_.MedianRtt -le $Threshold -and $_.MedianLat -le $LatThreshold }).Count
        Write-Host ''
        Write-Host ('                         latency > {0} ms   latency <= {0} ms' -f $LatThreshold)
        Write-Host ('  RTT > {0} ms (bad)      {1,9}          {2,9}' -f $Threshold, $a, $b)
        Write-Host ('  RTT <= {0} ms           {1,9}          {2,9}' -f $Threshold, $c, $d)
        Write-Host @"

 - RTT high AND latency high: the delay is mostly in the path to the client (network side).
 - RTT high, latency OK: the RTT contains more than the measured latency - look at the VDA/session side
   (CPU, graphics, profile/logon, input delay), and remember the two metrics are sampled on different schedules.
 - Latency high, RTT OK: latency is elevated but the session still feels fine; usually not the priority.
"@
    } else {
        Write-Host "`nLatency: no latency values in the data (the tenant exposes no latency field, or the field is empty on these VDAs) - no RTT-vs-latency comparison." -ForegroundColor DarkYellow
    }

    $schema = $rows[0].PSObject.Properties.Name
    $dims = @('Country', 'Location', 'DeliveryGroup', 'Protocol', 'Transport', 'ConnectedVia', 'LaunchedVia', 'AddrType',
              'ClientSubnet', 'WorkspaceAppVersion', 'ClientPlatform', 'Machine') | Where-Object { $schema -contains $_ }
    $cols = if ($hasLat) { @('Value', 'Count', 'Bad', 'BadPct', 'MedianRtt', 'P95Rtt', 'MedianLatency', 'LatBadPct', 'MedianGap') }
            else { @('Value', 'Count', 'Bad', 'BadPct', 'MedianRtt', 'P95Rtt') }
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($d in $dims) {
        $populated = @($sessions | Where-Object { $_.$d }).Count
        if ($populated -eq 0) { Write-Host ("`n--- {0}: not available (no values in the data) ---" -f $d) -ForegroundColor DarkYellow; continue }
        $b = @(Get-Breakdown $sessions $d $Threshold $Min $LatThreshold | Sort-Object @{ Expression = 'BadPct'; Descending = $true }, @{ Expression = 'Count'; Descending = $true })
        foreach ($x in $b) { $all.Add($x) }
        Write-Host ("`n--- {0} (groups with >= {1} sessions; top 12 by % bad) ---" -f $d, $Min) -ForegroundColor Cyan
        if ($b.Count -eq 0) { Write-Host '  (no group is large enough - lower -MinSessions or collect longer)' }
        else { $b | Select-Object -First 12 $cols | Format-Table -AutoSize | Out-Host }
    }
    $h = @(Get-HourBreakdown $rows $Threshold $LatThreshold)
    foreach ($x in $h) { $all.Add($x) }
    Write-Host "`n--- HourLocal (samples, local time of this machine) ---" -ForegroundColor Cyan
    $h | Select-Object $cols | Format-Table -AutoSize | Out-Host

    Write-Host @"

How to read this:
 - Compare BadPct between groups, not raw counts: a big group always has more bad sessions in absolute terms.
 - One group far above the overall bad % (e.g. one ConnectedVia/PoP, one ClientSubnet, AddrType=private) is your lead.
 - If Transport is available: bad sessions concentrated on TCP -> EDT/UDP is not working on that path.
 - LatBadPct / MedianLatency / MedianGap (RTT minus latency): a group with high BadPct AND high LatBadPct points to the path;
   high BadPct with a low LatBadPct and a large gap points to the VDA / session side.
 - Flat BadPct everywhere = not a grouping we can see; collect longer (-Loop) and check the Azure Firewall / PoP path.
 - Small groups are noisy: ignore anything with few sessions.
"@
    if ($Csv) {
        $all | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
        Write-Host "Saved: $Csv  (contains client subnets / machine names - handle as personal data)"
    }
}

# --- connection wizard ---------------------------------------------------------
function Set-BearerHeaders([string]$Token) {
    $script:Headers = @{
        Authorization       = "CWSAuth bearer=$Token"
        'Citrix-CustomerId' = $CustomerId
        Accept              = 'application/json'
    }
    $script:TokenAcquired = Get-Date
}

function ConvertFrom-SecureToPlain([securestring]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function ConvertTo-CleanToken($Value) {
    # Accepts a plain token, "Bearer xxx", "CWSAuth bearer=xxx", a quoted string or an Authorization header dictionary.
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { $Value = $Value['Authorization'] }
    $t = ([string]$Value).Trim().Trim('"', "'")
    $t = $t -replace '^(?i)(cwsauth\s+)?bearer[\s=]+', ''
    if ($t -match '^[A-Za-z0-9._~+/=-]{20,}$') { return $t }
    return $null
}

function Read-SdkToken {
    # Citrix docs: the token sits in a global session variable (name differs between SDK / doc versions).
    foreach ($n in 'XDAuthToken', 'XDSerializedNonPersistentMetadata') {
        $v = Get-Variable -Name $n -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $t = ConvertTo-CleanToken $v
        if ($t) { return $t }
    }
    return $null
}

function Get-TokenFromCitrixSdk([string]$Customer) {
    # Interactive Citrix Cloud sign-in through Citrix's own Remote PowerShell SDK; we only read the token it keeps in memory.
    $sdkUrl = 'https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html'
    $haveSdk = { [bool](Get-Command Get-XDAuthentication -ErrorAction SilentlyContinue) -or [bool](Get-Command Get-XDAuthenticationEx -ErrorAction SilentlyContinue) }
    if (-not (& $haveSdk)) {
        # newer SDK builds may ship PowerShell modules ...
        foreach ($m in @(Get-Module -ListAvailable -Name 'Citrix*' -ErrorAction SilentlyContinue)) { Import-Module -Name $m.Name -ErrorAction SilentlyContinue }
    }
    if (-not (& $haveSdk)) {
        # ... older ones are snap-ins (Windows PowerShell only)
        if (-not (Get-Command Get-PSSnapin -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ Token = $null; Error = "The Citrix SDK commands were not found in this PowerShell, and snap-ins cannot be loaded here. Run the script in Windows PowerShell 5.1 (powershell.exe) or install the SDK ($sdkUrl). Or choose 2 / 3." }
        }
        $reg = @(Get-PSSnapin -Registered -Name 'Citrix*' -ErrorAction SilentlyContinue)
        if ($reg.Count -eq 0) {
            return [pscustomobject]@{ Token = $null; Error = "The Citrix DaaS Remote PowerShell SDK is not installed on this machine. Download: $sdkUrl  (details in JAK_POBRAC_TOKEN.md). Or choose 2 / 3." }
        }
        foreach ($sn in $reg) { Add-PSSnapin -Name $sn.Name -ErrorAction SilentlyContinue }
    }
    try {
        if (Get-Command Get-XDAuthentication -ErrorAction SilentlyContinue) {
            Write-Host '     A Citrix Cloud sign-in window opens - sign in there (the script never sees your password).'
            Get-XDAuthentication -CustomerId $Customer | Out-Null
        } elseif (Get-Command Get-XDAuthenticationEx -ErrorAction SilentlyContinue) {
            Write-Host '     A Citrix Cloud sign-in window opens - sign in there (the script never sees your password).'
            Get-XDAuthenticationEx | Out-Null
        } else {
            return [pscustomobject]@{ Token = $null; Error = 'Citrix SDK loaded, but neither Get-XDAuthentication nor Get-XDAuthenticationEx exists.' }
        }
    } catch {
        return [pscustomobject]@{ Token = $null; Error = "Citrix sign-in failed: $($_.Exception.Message)" }
    }
    $t = Read-SdkToken
    if (-not $t) {
        return [pscustomobject]@{ Token = $null; Error = 'Signed in, but no bearer token was found in the session (checked XDAuthToken and XDSerializedNonPersistentMetadata). Choose 2 or 3.' }
    }
    return [pscustomobject]@{ Token = $t; Error = $null }
}

function Read-PastedToken {
    while ($true) {
        $sec = Read-Host '     Paste the access token (input is hidden; Enter alone = back to the menu)' -AsSecureString
        $plain = ConvertFrom-SecureToPlain $sec
        if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
        $t = ConvertTo-CleanToken $plain
        $plain = $null
        if ($t) { return $t }
        Write-Host '     That does not look like a token (expected one long string without spaces). Try again.' -ForegroundColor Yellow
    }
}

function Read-ConnectionWizard([string]$KnownCustomerId, [pscredential]$KnownCredential) {
    $needId = -not $KnownCustomerId
    $needSecret = -not $KnownCredential
    if ($needId -or $needSecret) {
        Write-Host "`n=== Citrix Cloud connection wizard ===" -ForegroundColor Cyan
        Write-Host 'Nothing is saved: what you enter lives in memory for this run only.'
    }
    $id = $KnownCustomerId
    while ($needId) {
        $id = ([string](Read-Host '1/2  Customer ID (the CCID of your Citrix Cloud account)')).Trim()
        if ($id -notmatch '^[A-Za-z0-9_-]+$') {
            Write-Host '     Customer ID may contain only letters, digits, "-" and "_". Try again.' -ForegroundColor Yellow
            continue
        }
        $why = $null
        if ($id -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { $why = 'This looks like a GUID, i.e. a Client ID, not a Customer ID.' }
        elseif ($id -match '^\d+$') { $why = 'This is digits only, which looks like an Org ID, not a Customer ID.' }
        if ($why) {
            Write-Host ('     ' + $why) -ForegroundColor Yellow
            Write-Host '     The Customer ID is the Citrix Cloud account ID (CCID: about 12 letters/digits). Find it at citrix.cloud.com (top right under your name; Identity and Access Management > API Access) or at citrix.com > My Organization > Citrix Cloud accounts > CCID. Copy it from the page instead of retyping.' -ForegroundColor Yellow
            $ans = ([string](Read-Host '     Use it anyway? (y/N)')).Trim()
            if ($ans -notmatch '^(?i)y') { continue }
        }
        break
    }
    $token = $null; $cred = $KnownCredential
    $mode = if ($cred) { 'client' } else { $null }
    while (-not $mode) {
        Write-Host '2/2  How do you want to sign in?'
        Write-Host '     [1] Sign in to Citrix Cloud in a window (Citrix Remote PowerShell SDK)'
        Write-Host '     [2] Paste an access token'
        Write-Host '     [3] Client ID + Secret of an API client   <- default'
        $c = ([string](Read-Host '     Choice (Enter = 3)')).Trim()
        if (-not $c) { $c = '3' }
        switch ($c) {
            '1' {
                $r = Get-TokenFromCitrixSdk $id
                if ($r.Token) { $token = $r.Token; $mode = 'sdk' } else { Write-Host ('     ' + $r.Error) -ForegroundColor Yellow }
            }
            '2' { $t = Read-PastedToken; if ($t) { $token = $t; $mode = 'paste' } }
            '3' {
                # plain console prompts (Get-Credential opens a GUI dialog that is invisible or missing in some hosts)
                $cidIn = ([string](Read-Host '     Client ID')).Trim()
                if (-not $cidIn) { Write-Host '     Nothing entered.' -ForegroundColor Yellow; continue }
                $secIn = Read-Host '     Secret (input is hidden)' -AsSecureString
                $secPlain = (ConvertFrom-SecureToPlain $secIn).Trim()
                if (-not $secPlain) { Write-Host '     Nothing entered.' -ForegroundColor Yellow; continue }
                $cred = New-Object System.Management.Automation.PSCredential($cidIn, (ConvertTo-SecureString $secPlain -AsPlainText -Force))
                $secPlain = $null
                $mode = 'client'
            }
            default { Write-Host '     Choose 1, 2 or 3.' -ForegroundColor Yellow }
        }
    }
    [pscustomobject]@{ CustomerId = $id; Credential = $cred; Token = $token; Mode = $mode }
}

# --- main ----------------------------------------------------------------------
# Collected samples always go to a CSV (appended and de-duplicated between runs); the breakdown goes to a second CSV.
$suffix = if ($Anonymous) { '_anon' } else { '' }
if (-not $RawStore) { $RawStore = Join-Path (Get-Location).Path "rtt_samples$suffix.csv" }
if (-not $OutCsv -and -not $Discover) { $OutCsv = Join-Path (Get-Location).Path "rtt_breakdown$suffix.csv" }

$w = Read-ConnectionWizard $CustomerId $Credential
$CustomerId = $w.CustomerId
$Credential = $w.Credential
$script:AuthMode = $w.Mode
if ($w.Token) { Set-BearerHeaders $w.Token } else { Update-Token $Credential }
$w = $null
if (-not $Loop) { $Credential = $null }
Write-Host ('Authenticated ({0}); the token is kept in memory only.' -f $script:AuthMode)

Write-Host 'Reading $metadata ...'
$model = Get-MonitorModel
if ($Discover) { Show-Discovery $model; return }

if ($GeoCsv) {
    if (-not $Anonymous) { Write-Warning '-GeoCsv is only used together with -Anonymous; ignoring it.' }
    elseif (-not (Test-Path -LiteralPath $GeoCsv -PathType Leaf)) { Write-Warning "-GeoCsv file not found: $GeoCsv - continuing without it (the tenant may provide the country itself; see the plan below)." }
    else { Import-GeoTable $GeoCsv }
}
if (-not $PSBoundParameters.ContainsKey('LatencyThresholdMs') -or $LatencyThresholdMs -le 0) { $LatencyThresholdMs = $ThresholdMs }
$plan = Resolve-QueryPlan $model $ConnectionNav $TransportFields $LatencyField
$script:LatencyLabel = $plan.LatencyPrimary
if ($Anonymous) {
    Write-Host ("ANONYMOUS mode (no user names): key = {0}; country from {1}. Machine names and IPs ARE written." -f
        $(if ($plan.TransactionField) { 'Transaction ID (' + $plan.TransactionField + ')' } else { 'session GUID (tenant exposes no Transaction ID)' }),
        $(if ($plan.GeoFields.Count) { 'tenant fields ' + ($plan.GeoFields -join ', ') } elseif ($script:GeoStarts) { '-GeoCsv table' } else { 'NOTHING (all Country = unknown)' }))
}
Write-Host ("Plan: connection via '{0}', client/session fields: {1}" -f $(if ($plan.ConnNav) { $plan.ConnNav } else { '(none - fields on Session)' }),
    (($plan.SessionFields + $plan.ConnFields) -join ', '))
Write-Host ("Latency for the RTT comparison: {0}   (all latency fields collected: {1})" -f $(if ($plan.LatencyPrimary) { $plan.LatencyPrimary } else { 'NONE exposed by this tenant' }),
    $(if ($plan.LatencyFields.Count) { $plan.LatencyFields -join ', ' } else { '-' }))
if ($plan.DeliveryGroupSet) { $script:DgMap = Get-DeliveryGroupMap $plan; Write-Host ("  delivery groups loaded: {0}" -f $script:DgMap.Count) }
Write-Host ("Delivery group: {0}   Transport indicator(s): {1}" -f $(if ($plan.DeliveryGroupNav) { 'yes (separate lookup)' } else { 'not exposed' }),
    $(if ($plan.TransportFields.Count) { $plan.TransportFields -join ', ' } else { 'NONE exposed by this tenant' }))

$collected = $null
$deadline = (Get-Date).AddHours($DurationHours)
$window = if ($Loop) { [math]::Max($Hours, 2.0 * $IntervalMinutes / 60.0) } else { $Hours }
do {
    if (((Get-Date) - $script:TokenAcquired).TotalMinutes -gt 45) {
        if ($Credential) { Update-Token $Credential }
        elseif ($script:AuthMode -eq 'sdk') {
            # the Citrix SDK renews its own token (up to 12 h per its docs); pick up the current one
            $fresh = Read-SdkToken
            if ($fresh) { Set-BearerHeaders $fresh } else { throw 'The Citrix SDK session no longer holds a token. Run the script again.' }
        }
        else { throw 'The pasted token has expired (about 1 h). For -Loop choose option 1 or 3 in the wizard so the token can be renewed.' }
    }
    Write-Host ("[{0}] collecting last {1} h ..." -f (Get-Date -Format 'HH:mm:ss'), $window)
    $collected = Get-FlatSamples $plan $window
    if ($RawStore) { Add-ToStore $collected $RawStore }
    if (-not $Loop) { break }
    if ((Get-Date).AddMinutes($IntervalMinutes) -ge $deadline) { break }
    Start-Sleep -Seconds ($IntervalMinutes * 60)
} while ((Get-Date) -lt $deadline)
$script:Headers = $null; $Credential = $null

if ($RawStore -and (Test-Path -LiteralPath $RawStore)) {
    Write-Host "Analysing the whole store: $RawStore"
    $data = Import-Csv -LiteralPath $RawStore
} else {
    $data = $collected
}
Show-Analysis $data $ThresholdMs $MinSessions $OutCsv $LatencyThresholdMs
