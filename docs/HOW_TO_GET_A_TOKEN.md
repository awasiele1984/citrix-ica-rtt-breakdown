# How to connect the script to Citrix Cloud (the wizard)

English edition of `JAK_POBRAC_TOKEN.md`. One small structural change: finding your **Customer ID** (needed by every option) now comes first, as step 0.

The script `Get-IcaRttBreakdown.ps1` starts a wizard. It asks for your **Customer ID** and then for a sign-in method:

| Option | What you do | When to use it |
|---|---|---|
| **[3] Client ID + Secret** (**default**, just press Enter) | You type the Client ID and Secret of an API client at two console prompts; the script obtains and renews the token itself | Recommended. Works in every host, needs no SDK, best for `-Loop` |
| **[1] Sign in through a window** | You sign in to Citrix Cloud in a window; the script takes the token by itself | Optional. Needs the [Citrix Remote PowerShell SDK](https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html) installed once; the sign-in can fail depending on the account type (SSO/MFA, environment) |
| **[2] Paste a token** | You paste a ready-made access token (valid about 1 h) | When you already have a token |

None of this is saved anywhere.

> Do not use a token taken out of the browser. Option 1 is Citrix's official route: the SDK signs you in, and the script only reads the token from that session's memory.

---

## 0. Find your Customer ID (all options)

1. Sign in at <https://citrix.cloud.com>.
2. Menu (☰ top left) → **Identity and Access Management** → the **API Access** tab.
3. The Customer ID is the **Citrix Cloud account ID (CCID)**: about 12 lowercase letters/digits. It is shown:
   - at citrix.cloud.com, top right under your name, and on the **Identity and Access Management → API Access** page (also in the console address as `customerId=...`),
   - at citrix.com → **My Organization** → **Citrix Cloud accounts** → column **CCID**.

> **Three different identifiers, do not mix them up:**
>
> | Name | Looks like | Use it as |
> |---|---|---|
> | **CCID / Customer ID** | about 12 letters and digits | the **Customer ID** (wizard step 1/2) |
> | **Org ID** | digits only (for example 8 digits) | **never**: it identifies your company at citrix.com, not the Citrix Cloud account |
> | **Client ID** | a GUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) | the **Client ID** prompt (option 3), never the Customer ID |
>
> Copy the CCID from the page instead of retyping it: `l`/`1` and `O`/`0` are easy to confuse. The script warns when you enter a GUID or digits only.

Copy it: you will paste it at step 1/2 of the wizard.

---

## Option 1: sign in through a window (simplest)

1. Download and install the **Citrix Virtual Apps and Desktops Remote PowerShell SDK**:
   <https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html>
   (a Citrix account is required; the installer file is typically called `CitrixPoshSdk.exe`). You do this once. Requirements from the Citrix documentation:
   - install **Microsoft Edge WebView2** first (the sign-in window uses it),
   - if "Citrix Virtual Apps and Desktops SDK" is installed, remove it first in Programs and Features,
   - the installer adds .NET Framework 4.8 by itself if it is missing,
   - install on a machine that is **domain-joined and in the same resource location**, and **not** on a Cloud Connector or on a server with a Delivery Controller / Citrix Studio,
   - using the SDK does not need administrator rights; check the rights the installer itself needs in your environment. Installation log: `%TEMP%\CitrixLogs\CitrixPoshSdk`.
2. Open **Windows PowerShell 5.1** (`powershell.exe`): this is the safest choice. Per Citrix, newer SDK versions also work in PowerShell up to 7.3; the script checks by itself whether the SDK commands are available.
3. Run the script, type your Customer ID (see step 0 above) and choose **1**.
4. A Citrix Cloud sign-in window appears. Sign in. The script never sees your password; it only reads the token that the SDK keeps in the session's memory.

Notes:
- This is the token of **your own administrator account** in Citrix Cloud, so it carries your permissions (it is not limited to read-only like the API client in option 3). The script still sends read requests only (verified).
- According to the SDK documentation the token is renewed within the session for up to 12 hours, so `-Loop` should also work with this option. This was not verified in a real environment.
- The name of the cmdlet and of the token variable differs between versions of the Citrix documentation (`Get-XDAuthentication` / `Get-XDAuthenticationEx`, variable `XDAuthToken` / `XDSerializedNonPersistentMetadata`). The script checks both. If, despite signing in, you see "no bearer token was found", use option 2 or 3 and report which SDK version you have.
- If you sign in through SSO/MFA: the documentation does not clearly confirm how the SDK's sign-in window handles it. If it does not work, use option 3.

---

## Options 2 and 3: an API client is needed

The steps below apply only to options 2 and 3.

### A. Prerequisites

- In Citrix Cloud you must be an **administrator with full access (Full access)**. Only such an administrator can create API clients (service principals).
- An API client's permissions cannot exceed those of the administrator who created it. If that administrator loses some permissions, the API client loses them too.

### B. Create a read-only API client

1. **Identity and Access Management → API Access → Service principals → Create service principal**
   (in older console versions: the **Secure clients → Create Client** tab; names may differ).
2. Enter a name, for example `ica-rtt-readonly`.
3. In the **Set access** step choose **Custom access**, expand the **DaaS** group and set the **Read Only Administrator** role to **All scopes**. Leave every other role as **No scopes**.
   The Read Only Administrator role lets you view objects (including the Monitor/Director views and the trends export) but change nothing.
4. Click **Create**. Citrix Cloud shows the **Client ID** and the **Secret**.
   - **The Secret is shown only once.** Copy both and keep them in a password manager, or download the credentials file. After you close the window it cannot be read again.
   - Never paste them into the script, a chat or a screenshot.

> If the console does not let you choose a read-only role, create the client as narrowly as possible and delete it right after the analysis. The script's code would still only read data, but the client itself could do more than the script does.

### C. Use them in the wizard

#### Option 3: Client ID + Secret

In the wizard:

- **1/2 Customer ID** → paste the Customer ID from step 0.
- **2/2** → choose **3**. Two prompts appear in the console: **Client ID** (visible) and **Secret** (hidden; paste with right-click, nothing is displayed). Leading/trailing spaces are removed automatically. No dialog window is used, so it also works in VS Code, ISE and remote sessions.

The script obtains the token itself (an ordinary OAuth request to Citrix) and renews it when needed. **Only this route is suitable for `-Loop` mode**, because a token lives for about an hour.

#### Option 2: a token obtained by hand and pasted into the wizard

Use it when you do not want to give the Secret to the script. In PowerShell (on the same machine where you will run the script):

```powershell
$cid      = '<YOUR CUSTOMER ID>'
$clientId = (Read-Host 'Client ID').Trim()
$secret   = Read-Host 'Secret (input is hidden)' -AsSecureString
$plain    = (New-Object System.Net.NetworkCredential('', $secret)).Password.Trim()
$r = Invoke-RestMethod -Method Post `
        -Uri "https://api.cloud.com/cctrustoauth2/$cid/tokens/clients" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'; client_id = $clientId; client_secret = $plain }
Set-Clipboard -Value $r.access_token
Write-Host "Token is on the clipboard, valid about $($r.expires_in) s. Paste it into the wizard (step 2/2)."
$secret = $null; $plain = $null; $r = $null
```

Then run the script, choose **2** at step **2/2** and paste the token (<kbd>Ctrl</kbd>+<kbd>V</kbd> or right-click; the field is hidden and nothing is displayed, which is normal).

**Clear the clipboard after pasting:**

```powershell
Set-Clipboard -Value ' '
```

If Windows clipboard history is on (<kbd>Win</kbd>+<kbd>V</kbd>), delete the token from it (**Clear all**).

The script also accepts a token with the prefix `Bearer ` or `CWSAuth bearer=`, and in quotes.

**Region / host:** `api.cloud.com` by default. For an account in the Japan region use `api.citrixcloud.jp`, for US Government `api.cloud.us`. In the script: `-ApiHost api.citrixcloud.jp`. If an EU tenant rejects `api.cloud.com`, try `-ApiHost api-eu.cloud.com`.

---

## Typical errors

| Symptom | Cause / what to do |
|---|---|
| Getting the token: HTTP 400 or 401 | **Most common cause: the Org ID or the Client ID was typed as the Customer ID** (use the CCID, step 0). Otherwise a wrong Client ID or Secret; a space or newline came along with the copied Secret; the client was deleted. Create a new client. |
| Data request: HTTP 401 | The token expired (after about an hour). Run the wizard again. |
| Data request: HTTP 403 | The client has no access to DaaS/Monitor. Check in step B that the **Read Only Administrator** role has **All scopes**. |
| HTTP 400 on the data request | A field name differs in your tenant. Run `-Discover`: the message points to the field. |
| Zero rows | Per-session data is available for only about an hour. Collect while users are signed in (`-Loop`). |
| Option 3: nothing seems to happen | The wizard uses plain console prompts ("Client ID", then "Secret"). Make sure you chose **3** at the "Choice" prompt and look at the bottom of the console; there is no pop-up window. |
| Option 1: "SDK is not installed" / "commands were not found" | Install the SDK or run the script in `powershell.exe`; or use option 2/3. |
| The wizard rejects the pasted string | A token is one long string without spaces (at least 20 characters). Check that you copied `access_token` and not the whole response. |

## After the analysis

1. In Citrix Cloud: **Identity and Access Management → API Access → Service principals** → delete the client (or rotate the Secret).
2. Delete the CSV files from the machine (they contain machine names and IP addresses).
3. Clear the clipboard (option 2).

## Sources

- [Accessing Monitor Service Data (Citrix)](https://developer-docs.citrix.com/en-us/citrix-cloud/accessing-monitor-service-data-citrix-cloud-external/accessing-monitor-service-data-citrix-cloud-external.html): token from the Remote PowerShell SDK.
- [Remote PowerShell SDK download page](https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html) and [SDKs and APIs, Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/sdk-api): requirements and where not to install it.
- [Get-XDAuthentication (Citrix DaaS SDK)](https://developer-docs.citrix.com/en-us/citrix-daas-sdk/sdkproxy/get-xdauthentication): sign-in, the `$XDAuthToken` variable, token renewal for up to 12 hours.
- [Get started with Citrix Cloud APIs](https://developer-docs.citrix.com/en-us/citrix-cloud/citrix-cloud-api-overview/get-started-with-citrix-cloud-apis): creating a client, Customer ID, token request (`/cctrustoauth2/{customerid}/tokens/clients`, validity 3600 s).
- [Citrix Cloud API walkthrough](https://developer.cloud.com/citrix-cloud/citrix-cloud-api-overview/docs/citrix-cloud-api-walkthrough).
- [CTX560736, API with Custom/read-only access on Citrix DaaS](https://support.citrix.com/external/article/CTX560736/how-to-create-api-with-customsread-only.html): a client's permissions are capped by its creator.
- [Delegated administration, Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/manage-deployment/delegated-administration.html): the Read Only Administrator role.
