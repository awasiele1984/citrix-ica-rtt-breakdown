# Jak połączyć skrypt z Citrix Cloud (kreator)

Skrypt `Get-IcaRttBreakdown.ps1` uruchamia kreator. Pyta o **Customer ID**, a potem o sposób logowania:

| Opcja | Co robisz | Kiedy |
|---|---|---|
| **[3] Client ID + Secret** (**domyślna**, wystarczy Enter) | Wpisujesz Client ID i Secret klienta API w dwóch pytaniach w konsoli; skrypt sam pobiera i odnawia token | Zalecana. Działa w każdej powłoce, nie wymaga SDK, najlepsza dla `-Loop` |
| **[1] Logowanie w oknie** | Logujesz się do Citrix Cloud w oknie, skrypt sam bierze token | Opcjonalna. Wymaga jednorazowo zainstalowanego [Citrix Remote PowerShell SDK](https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html); logowanie może zawieść zależnie od typu konta (SSO/MFA, środowisko) |
| **[2] Wklej token** | Wklejasz gotowy token dostępu (ważny ok. 1 h) | Gdy masz już token |

Nic z tego nie jest nigdzie zapisywane.

> Nie używaj tokena wyciągniętego z przeglądarki. Opcja 1 to oficjalna droga Citrix: SDK samo loguje Ciebie, a skrypt tylko odczytuje token z pamięci tej sesji.

## 0. Znajdź swój Customer ID (wszystkie opcje)

1. Zaloguj się na <https://citrix.cloud.com>.
2. Menu (☰ w lewym górnym rogu) → **Identity and Access Management** → zakładka **API Access**.
3. Customer ID to **identyfikator konta Citrix Cloud (CCID)**: ok. 12 małych liter i cyfr. Znajdziesz go:
   - na citrix.cloud.com, w prawym górnym rogu pod Twoją nazwą oraz na stronie **Identity and Access Management → API Access** (także w adresie konsoli jako `customerId=...`),
   - na citrix.com → **My Organization** → **Citrix Cloud accounts** → kolumna **CCID**.

> **Trzy różne identyfikatory, nie myl ich:**
>
> | Nazwa | Jak wygląda | Do czego służy |
> |---|---|---|
> | **CCID / Customer ID** | ok. 12 liter i cyfr | jako **Customer ID** (kreator, krok 1/2) |
> | **Org ID** | same cyfry (np. 8 cyfr) | **nigdy**: identyfikuje firmę na citrix.com, a nie konto Citrix Cloud |
> | **Client ID** | GUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) | pole **Client ID** (opcja 3), nigdy Customer ID |
>
> Skopiuj CCID ze strony zamiast przepisywać: `l`/`1` oraz `O`/`0` łatwo pomylić. Skrypt ostrzega, gdy wpiszesz GUID albo same cyfry.

Skopiuj go — wkleisz go w kroku 1/2 kreatora.

---

## Opcja 1: logowanie w oknie (najprościej)

1. Pobierz i zainstaluj **Citrix Virtual Apps and Desktops Remote PowerShell SDK**:
   <https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html>
   (wymaga konta Citrix; plik instalatora zwykle nazywa się `CitrixPoshSdk.exe`). Robisz to raz. Wymagania z dokumentacji Citrix:
   - najpierw zainstaluj **Microsoft Edge WebView2** (okno logowania z niego korzysta),
   - jeśli masz zainstalowane „Citrix Virtual Apps and Desktops SDK”, usuń je wcześniej w Programy i funkcje,
   - instalator sam doinstaluje .NET Framework 4.8, jeśli go brakuje,
   - instaluj na maszynie **dołączonej do domeny, w tej samej lokalizacji zasobów**, **nie** na Cloud Connectorze ani na serwerze z Delivery Controllerem / Citrix Studio,
   - do SDK nie są potrzebne uprawnienia administratora; uprawnienia samego instalatora sprawdź u siebie. Log instalacji: `%TEMP%\CitrixLogs\CitrixPoshSdk`.
2. Otwórz **Windows PowerShell 5.1** (`powershell.exe`) — to najpewniejsza opcja. Nowsze wersje SDK według Citrix działają też w PowerShell do 7.3; skrypt sam sprawdza, czy komendy SDK są dostępne.
3. Uruchom skrypt, wpisz Customer ID (gdzie go znaleźć: krok 0 wyżej) i wybierz **1**.
4. Pojawi się okno logowania Citrix Cloud. Zaloguj się. Skrypt nie widzi hasła; odczytuje tylko token, który SDK trzyma w pamięci sesji.

Uwagi:
- To jest token **Twojego konta administratora** w Citrix Cloud, więc ma Twoje uprawnienia (nie jest ograniczony do odczytu jak klient API z opcji 3). Skrypt nadal wysyła wyłącznie żądania odczytu (sprawdzone).
- Według dokumentacji SDK token jest w sesji odnawiany do 12 godzin, więc `-Loop` powinien działać także z tą opcją. Nie sprawdzałem tego na prawdziwym środowisku.
- Nazwa cmdletu i zmiennej z tokenem różni się między wersjami dokumentacji Citrix (`Get-XDAuthentication` / `Get-XDAuthenticationEx`, zmienna `XDAuthToken` / `XDSerializedNonPersistentMetadata`). Skrypt sprawdza obie. Jeśli mimo logowania zobaczysz „no bearer token was found”, użyj opcji 2 lub 3 i daj znać, jaką wersję SDK masz.
- Jeśli logujesz się przez SSO/MFA: dokumentacja nie potwierdza jednoznacznie, jak okno logowania SDK to obsługuje. Gdyby nie działało, użyj opcji 3.

---

## Opcje 2 i 3: potrzebny klient API

Poniższe kroki dotyczą tylko opcji 2 i 3.


### A. Warunki wstępne

- Musisz być w Citrix Cloud **administratorem z pełnym dostępem (Full access)**. Tylko taki administrator może tworzyć klientów API (service principals).
- Uprawnienia klienta API nie mogą przekraczać uprawnień administratora, który go utworzył. Jeśli ten administrator straci część uprawnień, klient API straci je także.

### B. Utwórz klienta API tylko do odczytu

1. **Identity and Access Management → API Access → Service principals → Create service principal**
   (w starszych wersjach konsoli: zakładka **Secure clients → Create Client**; nazwy mogą się różnić).
2. Podaj nazwę, np. `ica-rtt-odczyt`.
3. W kroku **Set access** wybierz **Custom access**, rozwiń grupę **DaaS** i ustaw rolę **Read Only Administrator** na **All scopes**. Wszystkie pozostałe role zostaw jako **No scopes**.
   Rola Read Only Administrator pozwala oglądać obiekty (także widoki Monitor/Director i eksport trendów), ale niczego nie zmieniać.
4. Kliknij **Create**. Citrix Cloud pokaże **Client ID** i **Secret**.
   - **Secret jest pokazany tylko raz.** Skopiuj oba i zapisz w menedżerze haseł lub pobierz plik z danymi. Po zamknięciu okna nie da się go odczytać ponownie.
   - Nigdy nie wklejaj ich do skryptu, czatu ani zrzutów ekranu.

> Jeśli konsola nie pozwala wybrać roli tylko do odczytu, utwórz klienta możliwie wąsko i usuń go zaraz po analizie. Wtedy skrypt (kod) nadal tylko czyta dane, ale sam klient mógłby więcej niż skrypt.

### C. Użyj ich w kreatorze

#### Opcja 3: Client ID + Secret

W kreatorze:

- **1/2 Customer ID** → wklej Customer ID z kroku 0.
- **2/2** → wybierz **3**. W konsoli pojawią się dwa pytania: **Client ID** (widoczne) i **Secret** (ukryte; wklejasz prawym przyciskiem myszy, nic się nie wyświetla). Spacje na początku i końcu są usuwane automatycznie. Skrypt nie używa okna dialogowego, więc działa też w VS Code, ISE i sesjach zdalnych.

Skrypt sam pobierze token (zwykłe żądanie OAuth do Citrix) i odnowi go w razie potrzeby. **Tylko ta droga nadaje się do trybu `-Loop`**, bo token żyje około godziny.

#### Opcja 2: ręcznie pobrany token, wklejony do kreatora

Użyj, gdy nie chcesz podawać Secretu skryptowi. W PowerShell (na tej samej maszynie, na której uruchomisz skrypt):

```powershell
$cid      = '<TWÓJ CUSTOMER ID>'
$clientId = (Read-Host 'Client ID').Trim()
$secret   = Read-Host 'Secret (pole ukryte)' -AsSecureString
$plain    = (New-Object System.Net.NetworkCredential('', $secret)).Password.Trim()
$r = Invoke-RestMethod -Method Post `
        -Uri "https://api.cloud.com/cctrustoauth2/$cid/tokens/clients" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'; client_id = $clientId; client_secret = $plain }
Set-Clipboard -Value $r.access_token
Write-Host "Token w schowku, ważny ok. $($r.expires_in) s. Wklej go w kreatorze (krok 2/2)."
$secret = $null; $plain = $null; $r = $null
```

Następnie uruchom skrypt, w kroku **2/2** wybierz **2** i wklej token (<kbd>Ctrl</kbd>+<kbd>V</kbd> lub prawy przycisk myszy; pole jest ukryte, nic nie widać — to normalne).

**Po wklejeniu wyczyść schowek:**

```powershell
Set-Clipboard -Value ' '
```

Jeśli masz włączoną historię schowka Windows (<kbd>Win</kbd>+<kbd>V</kbd>), usuń z niej token (**Wyczyść wszystko**).

Skrypt akceptuje token także z prefiksem `Bearer ` lub `CWSAuth bearer=` oraz w cudzysłowie.

**Region / host:** domyślnie `api.cloud.com`. Dla konta w regionie Japonia użyj `api.citrixcloud.jp`, dla US Gov `api.cloud.us`. W skrypcie: `-ApiHost api.citrixcloud.jp`. Jeśli tenant w UE odrzuca `api.cloud.com`, spróbuj `-ApiHost api-eu.cloud.com`.

## Typowe błędy

| Objaw | Przyczyna / co zrobić |
|---|---|
| Pobranie tokena: HTTP 400 lub 401 | **Najczęstsza przyczyna: jako Customer ID wpisano Org ID albo Client ID** (użyj CCID, krok 0). Poza tym zły Client ID lub Secret; w Secrecie została spacja lub nowa linia z kopiowania; klient został usunięty. Utwórz nowego klienta. |
| Zapytanie do danych: HTTP 401 | Token wygasł (po ok. godzinie). Uruchom kreator ponownie. |
| Zapytanie do danych: HTTP 403 | Klient nie ma dostępu do DaaS/Monitor. Sprawdź w kroku B, że rola **Read Only Administrator** ma **All scopes**. |
| HTTP 400 przy zapytaniu o dane | Nazwa pola różni się w Twoim tenancie. Uruchom `-Discover` — komunikat wskaże pole. |
| Zero wierszy | Dane per sesja są dostępne tylko przez około godzinę. Zbieraj w czasie, gdy użytkownicy są zalogowani (`-Loop`). |
| Opcja 3: „nic się nie dzieje” | Kreator używa zwykłych pytań w konsoli („Client ID”, potem „Secret”). Upewnij się, że przy pytaniu „Choice” wpisano **3**, i spójrz na dół konsoli; nie ma okna pop-up. |
| Opcja 1: „SDK is not installed” / „commands were not found” | Zainstaluj SDK albo uruchom skrypt w `powershell.exe`; ewentualnie użyj opcji 2/3. |
| Kreator odrzuca wklejony ciąg | Token to jeden długi ciąg bez spacji (min. 20 znaków). Sprawdź, czy skopiowałeś `access_token`, a nie całą odpowiedź. |

## Po zakończeniu analizy

1. W Citrix Cloud: **Identity and Access Management → API Access → Service principals** → usuń klienta (lub zrotuj Secret).
2. Usuń z maszyny pliki CSV z danymi (zawierają nazwy maszyn i adresy IP).
3. Wyczyść schowek (opcja 2).

## Źródła

- [Accessing Monitor Service Data (Citrix)](https://developer-docs.citrix.com/en-us/citrix-cloud/accessing-monitor-service-data-citrix-cloud-external/accessing-monitor-service-data-citrix-cloud-external.html) — token z Remote PowerShell SDK.
- [Strona pobierania Remote PowerShell SDK](https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html) oraz [SDKs and APIs — Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/sdk-api) — wymagania i miejsca, gdzie nie instalować.
- [Get-XDAuthentication (Citrix DaaS SDK)](https://developer-docs.citrix.com/en-us/citrix-daas-sdk/sdkproxy/get-xdauthentication) — logowanie, zmienna `$XDAuthToken`, odnawianie tokena do 12 godzin.
- [Get started with Citrix Cloud APIs](https://developer-docs.citrix.com/en-us/citrix-cloud/citrix-cloud-api-overview/get-started-with-citrix-cloud-apis) — tworzenie klienta, Customer ID, żądanie tokena (`/cctrustoauth2/{customerid}/tokens/clients`, ważność 3600 s).
- [Citrix Cloud API walkthrough](https://developer.cloud.com/citrix-cloud/citrix-cloud-api-overview/docs/citrix-cloud-api-walkthrough).
- [CTX560736 — API z uprawnieniami Custom/read-only w Citrix DaaS](https://support.citrix.com/external/article/CTX560736/how-to-create-api-with-customsread-only.html) — uprawnienia klienta ograniczone przez twórcę.
- [Delegated administration — Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/manage-deployment/delegated-administration.html) — rola Read Only Administrator.
