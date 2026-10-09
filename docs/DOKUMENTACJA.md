# Get-IcaRttBreakdown.ps1: pełna dokumentacja

| | |
|---|---|
| **Dokumentowany plik** | `Get-IcaRttBreakdown.ps1` (1043 linii, 61 078 bajtów, 35 funkcji) |
| **SHA-256** | `e0b0f1c967388c9017f5bda082e239a636935dd52dd8cd01fc28ddc4305c31d0` |
| **Data dokumentu** | 2026-10-09 (po dodaniu porównania ICA RTT z opóźnieniem) |
| **Platforma docelowa** | Windows PowerShell 5.1 (PowerShell 7 częściowo, patrz sekcja 3) |
| **Status** | Przetestowany na danych syntetycznych i atrapach zapytań. **Logowanie i odkrywanie pól potwierdzone na prawdziwym tenancie (2026-10-09)**; pierwsze zapytanie o próbki zakończyło się tam HTTP 400 (zbyt głębokie `$expand`) i zostało naprawione, ale naprawione zapytanie **nie zostało jeszcze potwierdzone na żywo** (sekcja 15) |

Dokumenty uzupełniające: `UZYCIE_SKRYPTU.md` (instrukcja krok po kroku), `JAK_POBRAC_TOKEN.md` (logowanie i klient API). Ten dokument opisuje, **jak skrypt jest zbudowany i dlaczego działa tak, jak działa**. Jeśli sprawdzasz sumę kontrolną, a ona się nie zgadza, dokumentacja może opisywać inną wersję skryptu.

---

## Spis treści

1. Cel i zakres
2. Architektura i przepływ
3. Wymagania i środowisko
4. Uwierzytelnianie
5. Komunikacja z API Monitor Service
6. Odkrywanie pól (`$metadata` i plan zapytania)
7. Model danych (pliki CSV)
8. Algorytmy analizy
9. Funkcje pomocnicze (podsieć, typ adresu, geolokalizacja, skrót nazwy)
10. Tryby pracy
11. Referencja parametrów
12. Referencja funkcji
13. Bezpieczeństwo i prywatność
14. Komunikaty i obsługa błędów
15. Weryfikacja: co przetestowano, a co nie
16. Znane ograniczenia
17. Utrzymanie i rozszerzanie
18. Decyzje projektowe
19. Słownik pojęć
20. Źródła

---

## 1. Cel i zakres

**Problem, który skrypt rozwiązuje.** W środowisku Citrix DaaS część użytkowników może mieć bardzo wysokie ICA RTT (np. średnio ponad 200 ms), niezależnie od Delivery Group i generacji maszyn. Trzeba ustalić, **co mają wspólnego sesje z wysokim RTT**: transport (EDT/UDP czy TCP), PoP Gateway Service, kraj, podsieć klienta, wersja Workspace app, godzina.

**Co skrypt robi:**
- loguje się do Citrix Cloud (trzy sposoby, sekcja 4),
- odczytuje opis modelu danych Monitor Service (`$metadata`) i **sam dobiera pola**, które tenant udostępnia (sekcja 6),
- pobiera próbki ICA RTT wraz z danymi o sesji, maszynie i połączeniu (sekcja 5),
- zapisuje je do pliku CSV z deduplikacją (sekcja 7),
- liczy odsetek „złych” sesji w podziale na wymiary i wypisuje tabele oraz zapisuje je do drugiego CSV (sekcja 8),
- **porównuje ICA RTT z polami opóźnienia, które udostępnia tenant** („Network Latency”): opóźnienie per grupa, różnica RTT − opóźnienie, korelacja oraz tabela 2×2 pokazująca, czy wysokiemu RTT towarzyszy wysokie opóźnienie (sekcja 8.9).

**Czego skrypt nie robi:**
- nie zmienia niczego w Citrix Cloud, Azure ani na VDA (tylko żądania odczytu, sekcja 13),
- nie diagnozuje przyczyny, tylko wskazuje korelacje (sekcja 16),
- nie zapamiętuje poświadczeń (sekcja 18),
- nie wysyła adresów IP ani innych danych do usług zewnętrznych.

---

## 2. Architektura i przepływ

```
                    ┌──────────────────────────────────────────────────────────┐
                    │ Get-IcaRttBreakdown.ps1  (jeden plik, bez modułów)       │
                    └──────────────────────────────────────────────────────────┘
 [1] Kreator logowania ──► token (pamięć)             opcje: SDK | wklejony token | Client ID+Secret
        │
 [2] GET /monitorodata/$metadata ──► Resolve-QueryPlan ──► plan (które pola, jakie nawigacje)
        │                                  │
        │                       -Discover: wypisz i zakończ
        ▼
 [3] GET /monitorodata/SessionMetrics?$filter=...&$expand=... (strony po 100, @odata.nextLink)
        │      ConvertTo-FlatRow  (spłaszczenie 1 próbki do 1 wiersza)
        ▼
 [4] Add-ToStore  ──►  rtt_samples[_anon].csv   (dopisywanie, deduplikacja)
        │                (w -Loop: powtarzaj [3]–[4] co N minut, odświeżając token)
        ▼
 [5] Import-Csv (cały plik) ► ConvertTo-SessionSummaries ► Get-Breakdown / Get-HourBreakdown
        ▼
 [6] Tabele w konsoli  +  rtt_breakdown[_anon].csv
```

**Zasada nadrzędna:** skrypt jest jednym plikiem, bez zależności od modułów (poza opcjonalnym SDK Citrix do logowania). Cały stan żyje w pamięci i w dwóch plikach CSV.

**Podział na warstwy w kodzie:**

| Warstwa | Funkcje |
|---|---|
| Pomocnicze | `Get-HttpStatus`, `ConvertTo-UtcDate`, `Get-Prop` |
| Uwierzytelnianie | `Update-Token`, `Set-BearerHeaders`, `Read-ConnectionWizard`, `Get-TokenFromCitrixSdk`, `Read-SdkToken`, `Read-PastedToken`, `ConvertTo-CleanToken`, `ConvertFrom-SecureToPlain` |
| Transport HTTP | `Invoke-ODataGet`, `Get-MonitorModel` |
| Model i plan | `ConvertFrom-ODataMetadata`, `Show-Discovery`, `Resolve-QueryPlan`, `Get-SamplesUrl` |
| Spłaszczanie | `ConvertTo-FlatRow`, `Get-ClientSubnet`, `Get-AddrType`, `Get-UserLabel`, geolokalizacja (`ConvertTo-IPv4Number`, `Import-GeoTable`, `Get-GeoFromTable`) |
| Pobieranie i zapis | `Get-DeliveryGroupMap`, `Resolve-DeliveryGroup`, `Get-FlatSamples`, `Get-KeyProp`, `Add-ToStore` |
| Analiza | `Get-Percentile`, `Get-Correlation`, `ConvertTo-SessionSummaries`, `Get-Breakdown`, `Get-HourBreakdown`, `Show-Analysis` |
| Program główny | blok `# --- main` na końcu pliku |

---

## 3. Wymagania i środowisko

| Wymaganie | Szczegóły |
|---|---|
| System | Windows. Skrypt był rozwijany i testowany na PowerShell 7.6 pod macOS. Składnia jest zgodna z PowerShell 5.1, ale **uruchomienie na 5.1 nie było testowane**. |
| PowerShell | Zalecany Windows PowerShell 5.1 (`powershell.exe`). Skrypt ustawia TLS 1.2 (`[Net.ServicePointManager]::SecurityProtocol`). |
| Sieć | HTTPS (443) do hosta z `-ApiHost` (domyślnie `api.cloud.com`). |
| Logowanie, opcja 1 | Citrix DaaS Remote PowerShell SDK (moduły lub snap-iny `Citrix*`). Wymaga też Microsoft Edge WebView2, a SDK nie wolno instalować na Cloud Connectorze ani na serwerze z Delivery Controllerem/Studio (wg dokumentacji Citrix). |
| Logowanie, opcja 2/3 | Token dostępu albo klient API (Client ID + Secret). |
| Uprawnienia | Odczyt Monitor/Director (rola Read Only Administrator wystarcza). |
| Dysk | Zapis dwóch plików CSV w bieżącym katalogu. |

Ustawienia globalne skryptu: `$ErrorActionPreference = 'Stop'` (każdy błąd przerywa działanie), `$ProgressPreference = 'SilentlyContinue'` (przyspiesza `Invoke-WebRequest`).

---

## 4. Uwierzytelnianie

Skrypt zawsze kończy uwierzytelnianie ustawieniem dwóch nagłówków (zmienna `$script:Headers`):

```
Authorization:      CWSAuth bearer=<token>
Citrix-CustomerId:  <Customer ID>
Accept:             application/json
```

### 4.1 Kreator (`Read-ConnectionWizard`)

Kreator pyta o **Customer ID** (identyfikator konta Citrix Cloud, „CCID”; walidacja: `^[A-Za-z0-9_-]+$`), a potem o sposób logowania. Wychwytywane są dwie typowe pomyłki: **GUID** (Client ID) i **wartość z samych cyfr** (Org ID) wywołują ostrzeżenie i pytanie „Use it anyway? (y/N)” (domyślnie: zapytaj ponownie). Pytania są pomijane, jeśli odpowiednie dane podano parametrami (`-CustomerId`, `-Credential`).

| Opcja | Mechanizm | Odnawianie tokena |
|---|---|---|
| **1. Okno logowania (SDK)** | `Get-TokenFromCitrixSdk`: wykrywa komendy SDK (`Get-XDAuthentication` lub `Get-XDAuthenticationEx`), w razie potrzeby importuje moduły `Citrix*` lub ładuje snap-iny, wywołuje komendę (otwiera się okno logowania Citrix), następnie czyta token z globalnej zmiennej sesji (`Read-SdkToken`). | W `-Loop`: po 45 min skrypt ponownie czyta zmienną sesji. Według dokumentacji Citrix SDK odnawia token do 12 godzin. |
| **2. Wklejony token** | `Read-PastedToken`: pole ukryte (`-AsSecureString`), zawartość czyszczona przez `ConvertTo-CleanToken`. | Brak. Token wygasa po ok. 1 godzinie. W `-Loop` skrypt zatrzymuje się z komunikatem. |
| **3. Client ID + Secret** (**domyślna**, Enter) | Dwa pytania w konsoli (`Read-Host`): Client ID (widoczne) i Secret (ukryte, `-AsSecureString`); obie wartości są przycinane i budowany jest `PSCredential`. Nie używa okna dialogowego (`Get-Credential` otwiera okno, które w niektórych powłokach jest niewidoczne lub się nie pojawia). `Update-Token` wysyła `POST https://<ApiHost>/cctrustoauth2/<CustomerId>/tokens/clients` (`grant_type=client_credentials`) i ustawia nagłówki. | Skrypt sam żąda nowego tokena po 45 min w `-Loop`. |

### 4.2 Czyszczenie tokena (`ConvertTo-CleanToken`)

Przyjmuje: czysty token, `Bearer xxx`, `CWSAuth bearer=xxx`, tekst w cudzysłowie lub słownik nagłówka (klucz `Authorization`). Procedura: przytnij spacje i cudzysłowy, usuń prefiks `^(cwsauth\s+)?bearer[\s=]+` (bez względu na wielkość liter), sprawdź, czy wynik pasuje do `^[A-Za-z0-9._~+/=-]{20,}$`. Jeśli nie, zwraca `$null`. Ta walidacja jest też zabezpieczeniem przed wstrzyknięciem znaków specjalnych (np. nowej linii) do nagłówka HTTP.

### 4.3 Odczyt tokena z SDK (`Read-SdkToken`)

Citrix opisuje token w globalnej zmiennej sesji, ale **nazwa różni się między stronami dokumentacji**. Skrypt sprawdza po kolei:

1. `$Global:XDAuthToken` (strona `Get-XDAuthentication`),
2. `$Global:XDSerializedNonPersistentMetadata` (strona „Accessing Monitor Service Data”, cmdlet `Get-XDAuthenticationEx`).

Wartość może być czystym tokenem albo całym nagłówkiem (`CWSAuth bearer=...`). `ConvertTo-CleanToken` obsługuje oba przypadki.

### 4.4 Gdzie token trafia

- Wyłącznie do nagłówka `Authorization` w żądaniach do hosta z `-ApiHost`.
- `Invoke-ODataGet` sprawdza host każdego adresu (także `@odata.nextLink`); inny host powoduje przerwanie: `Refusing to send the token to unexpected host`.
- Po zakończeniu pracy: `$script:Headers = $null; $Credential = $null`.

---

## 5. Komunikacja z API Monitor Service

Skrypt wykonuje **dokładnie cztery rodzaje żądań** (jedno POST po token, reszta to GET):

| # | Metoda | Adres | Cel | Gdzie w kodzie |
|---|---|---|---|---|
| 1 | **POST** | `https://<ApiHost>/cctrustoauth2/<CustomerId>/tokens/clients` | Pobranie tokena (tylko opcja 3) | `Update-Token` |
| 2 | GET | `https://<ApiHost>/monitorodata/$metadata` | Opis modelu danych (XML) | `Get-MonitorModel` |
| 3 | GET | `https://<ApiHost>/monitorodata/DesktopGroups?$select=Id,Name&$top=…` | Nazwy Delivery Group (mała tabela pomocnicza; nazwa zbioru encji pochodzi z `$metadata`) | `Get-DeliveryGroupMap` |
| 4 | GET | `https://<ApiHost>/monitorodata/SessionMetrics?...` | Próbki RTT (JSON), strony po `-PageSize` | `Get-FlatSamples` |

Hosty dozwolone w `-ApiHost`: `api.cloud.com` (domyślnie), `api-eu.cloud.com` (niepotwierdzony w dokumentacji Citrix), `api.citrixcloud.jp`, `api.cloud.us`.

### 5.1 Zapytanie o próbki (`Get-SamplesUrl`)

Przykład (tryb `-Anonymous`, połączenie przez `Connections`):

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

Zasady budowy:
- **Filtr czasu:** `CollectedDate ge <teraz - okno>` (UTC, format `yyyy-MM-ddTHH:mm:ssZ`). Okno to `-Hours` (w `-Loop`: większa z wartości `-Hours` i `2 × -IntervalMinutes / 60`).
- **Wszystkie próbki**, nie tylko złe: potrzebny jest mianownik do liczenia odsetków.
- **`$select`/`$expand` zawierają wyłącznie pola z planu** (sekcja 6), więc nie ma żądań o pola, których tenant nie ma. `$select` dla `SessionMetrics` zawiera `CollectedDate`, `IcaRttMS` oraz **każde pole `*Latency*`, które ma tenant** (bez opóźnienia dysku).
- **Głębokość `$expand` jest ograniczona przez API do 2.** Prawdziwy tenant odpowiedział na pierwszą wersję tego zapytania (zagnieżdżającą `Session → Machine → DesktopGroup`) błędem HTTP 400: *„The request includes a $expand path which is too deep. The maximum depth allowed is 2.”* Zapytanie rozwija więc tylko `Session` i wewnątrz niego `User`, `Machine` oraz połączenie. **Nazwa** Delivery Group nie jest rozwijana: wybierane jest `Machine.DesktopGroupId` i rozwiązywane osobnym zapytaniem `DesktopGroups` (żądanie nr 3).
- **Tryb zwykły** dodaje `User($select=UserName)`. **Tryb `-Anonymous` nie żąda nazwy użytkownika w ogóle.**
- **Stronicowanie:** pętla idzie za `@odata.nextLink`, do `-MaxPages` stron (domyślnie 300 × 100 = 30 000 próbek na jedno pobranie). Po przekroczeniu: ostrzeżenie `Stopped after N pages - incomplete`.
- `@odata.count` (`$count=true`) jest tylko wypisywane informacyjnie.

### 5.2 Odpowiedzi błędów (`Invoke-ODataGet`)

| HTTP | Komunikat skryptu |
|---|---|
| 401 | Token wygasł lub jest nieprawidłowy; uruchom kreator ponownie. |
| inny (np. 400, 403) | Treść błędu (do 400 znaków) + wskazówka: przy 400 nazwa pola różni się w tenancie, użyj `-Discover`, `-ConnectionNav`, `-TransportFields`. |

---

## 6. Odkrywanie pól (`$metadata` i plan zapytania)

Skrypt **nie zakłada**, że tenant ma jakiekolwiek konkretne pole poza dwoma wymaganymi. Zamiast tego:

1. `Get-MonitorModel` pobiera `$metadata` (XML) i usuwa ewentualny BOM.
2. `ConvertFrom-ODataMetadata` buduje słownik: nazwa typu → `{ Props: lista właściwości, Nav: słownik nawigacji (nazwa → typ docelowy, czy kolekcja) }`. Użyto XPath `local-name()`, więc działa niezależnie od przestrzeni nazw.
3. `Resolve-QueryPlan` składa **plan zapytania**.

### 6.1 Pola wymagane (brak = błąd)

Typy `SessionMetrics`, `Session`, `User`, `Machine`; w `SessionMetrics`: `CollectedDate`, `IcaRttMS` oraz nawigacja `Session`. Jeśli czegoś brakuje, skrypt przerywa z komunikatem „Run -Discover”.

### 6.2 Reguły doboru pól

| Co | Reguła | Źródło |
|---|---|---|
| Klucz sesji | `SessionKey` w `Session`, w przeciwnym razie `Id` | `Session` |
| Nawigacja do połączenia | Pierwsza istniejąca z: `CurrentConnection`, `Connection`, `Connections` (lub wartość `-ConnectionNav`) | `Session.Nav` |
| Pola klienta | `ClientAddress`, `ClientVersion`, `ClientPlatform`, `ConnectedViaHostName`, `ConnectedViaIPAddress`, `LaunchedViaHostName`, `LaunchedViaIPAddress`, `Protocol`: najpierw szukane w `Session`, potem w typie połączenia | `Session` / połączenie |
| **Pola opóźnienia** | Każda właściwość `SessionMetrics`, której nazwa zawiera `Latency` (z uwzględnieniem wielkości liter), poza nazwami zawierającymi `Disk`. Zwykle `IcaLatency`, a przy danych z NetScaler / SD-WAN także `ClientL7Latency`, `ServerL7Latency`, `WanLatency`, `DcLatency` | `SessionMetrics` |
| **Główne opóźnienie** („network latency” do porównania) | Wartość `-LatencyField`; w przeciwnym razie pole o nazwie zaczynającej się od `Network` i zawierającej `Latency`; w przeciwnym razie `IcaLatency`; w przeciwnym razie pierwsze pole opóźnienia | `SessionMetrics` |
| **Wskaźnik transportu (EDT/TCP)** | Każda właściwość o nazwie pasującej **z uwzględnieniem wielkości liter** do `Transport\|Udp\|Edt\|Rendezvous` w `Session`, połączeniu lub `SessionMetrics` (lub nazwy z `-TransportFields`) | wszystkie trzy |
| **Transaction ID** | Pierwsza właściwość pasująca (bez uwzględniania wielkości liter) do `Transaction`; kolejność przeszukiwania: `Session`, połączenie, `SessionMetrics` | wszystkie trzy |
| **Kraj / lokalizacja** | Każda właściwość pasująca do `Country\|Location\|City\|Geo` | wszystkie trzy |
| **Delivery Group** | `Machine.DesktopGroupId`, rozwiązywane osobnym zapytaniem `DesktopGroups` (wymaga `Machine.DesktopGroupId`, typu `DesktopGroup` z `Id` i `Name` oraz zbioru encji dla niego w `$metadata`) | `Machine` + tabela pomocnicza |

Dlaczego dopasowanie transportu uwzględnia wielkość liter: bez tego wzorzec `Edt` pasowałby do przypadkowych nazw zawierających „edt” (np. `NeedTo…`).

### 6.3 Plan jako obiekt

`Resolve-QueryPlan` zwraca obiekt: `SessionKeyField`, `MetricsFields`, `SessionFields`, `ConnNav`, `ConnFields`, `DeliveryGroupNav`, `TransportFields` (wpisy `Źródło:Nazwa`), `TransactionField`, `GeoFields`, `MachineKey`, `DeliveryGroupSet`, `LatencyFields`, `LatencyPrimary`. Przy starcie skrypt wypisuje czytelne podsumowanie planu.

### 6.4 Tryb `-Discover`

`Show-Discovery` wypisuje właściwości i nawigacje typów `SessionMetrics`, `Session`, `Connection`, `Machine`, listę typów z `ClientAddress` kandydatów na `-LatencyField` oraz wszystkie właściwości pasujące do wzorców transportu, Transaction ID i kraju. Brak pola transportu jest zgłaszany jawnie (to znaczy, że tabeli `Transport` nie będzie). Potem skrypt kończy działanie, **niczego nie pobierając i nie zapisując**.

---

## 7. Model danych (pliki CSV)

### 7.1 Plik próbek (`-RawStore`)

Domyślnie `rtt_samples.csv` lub `rtt_samples_anon.csv` w bieżącym katalogu. Kodowanie UTF-8, dopisywanie (`Export-Csv -Append`).

**Tryb zwykły:**

`CollectedUtc, SessionKey, User, Machine, DeliveryGroup, RttMs, LatencyMs, Protocol, Transport, ClientAddress, ClientSubnet, AddrType, WorkspaceAppVersion, ClientPlatform, ConnectedVia, LaunchedVia, Lat_<Pole>…`

**Tryb `-Anonymous`:**

`CollectedUtc, TransactionId (lub SessionKey), Country, Location, Machine, DeliveryGroup, ClientAddress, ClientSubnet, AddrType, RttMs, LatencyMs, Protocol, Transport, ConnectedVia, LaunchedVia, WorkspaceAppVersion, ClientPlatform, Lat_<Pole>…`

Kolumny `Lat_<Pole>` istnieją dla każdego pola opóźnienia, które ma tenant, **poza głównym** (np. `Lat_WanLatency`). Zestaw kolumn zależy więc od tenanta i od `-LatencyField`.

### 7.2 Słownik kolumn

| Kolumna | Skąd / jak powstaje |
|---|---|
| `CollectedUtc` | `SessionMetrics.CollectedDate` w UTC, format `yyyy-MM-ddTHH:mm:ssZ` |
| `SessionKey` | Klucz sesji (GUID). W trybie anonimowym tylko gdy tenant nie ma Transaction ID |
| `TransactionId` | Pole wykryte w sekcji 6.2. Jeśli puste dla wiersza, wartość zastępcza to klucz sesji |
| `User` | `Session.User.UserName`; z `-AnonymizeUsers` zamieniony na skrót `u_` + 8 znaków hex |
| `Machine` | `Session.Machine.Name` |
| `DeliveryGroup` | Nazwa grupy, której Id równa się `Session.Machine.DesktopGroupId` (z tabeli `DesktopGroups`; dopasowanie bez względu na wielkość liter) |
| `RttMs` | `SessionMetrics.IcaRttMS` (liczba całkowita) |
| `LatencyMs` | **Główne pole opóźnienia** (`-LatencyField`; domyślnie `IcaLatency`) w ms; puste, gdy próbka nie ma wartości. **Używane w porównaniu RTT z opóźnieniem** (sekcja 8.9) |
| `Lat_<Pole>` | Wartość każdego pozostałego pola opóźnienia (zapisywana do ręcznego porównania, nieanalizowana) |
| `Protocol` | Pole `Protocol` sesji/połączenia (jeśli istnieje) |
| `Transport` | Wartości wykrytych pól transportu w formie `Nazwa=Wartość`, rozdzielone `; ` |
| `ClientAddress` | Adres klienta z połączenia/sesji |
| `ClientSubnet` | /24 dla IPv4 lub /48 dla IPv6 (sekcja 9.1) |
| `AddrType` | `public`, `private` lub `cgnat` (sekcja 9.2) |
| `Country`, `Location` | Z pól tenanta; w razie braku z `-GeoCsv`; w razie braku `unknown` / puste |
| `WorkspaceAppVersion` | Pole `ClientVersion` połączenia |
| `ClientPlatform` | Pole `ClientPlatform` połączenia |
| `ConnectedVia` | `ConnectedViaHostName`, a gdy puste `ConnectedViaIPAddress` (host bramki/PoP) |
| `LaunchedVia` | `LaunchedViaHostName`, a gdy puste `LaunchedViaIPAddress` |

Wartości pobierane są funkcją pomocniczą (`$get` w `ConvertTo-FlatRow`): najpierw z obiektu sesji, potem z połączenia, potem z wiersza metryk. Brak wartości daje pusty ciąg.

### 7.3 Klucz i deduplikacja (`Add-ToStore`)

- Klucz próbki: `<TransactionId lub SessionKey>|<CollectedUtc>` (dokładność do sekundy).
- Przy każdym zapisie skrypt wczytuje cały istniejący plik, buduje zbiór kluczy (`HashSet`) i dopisuje tylko nowe wiersze.
- **Straż trybu:** plik z kolumną `User` nie może być uzupełniany w trybie `-Anonymous` (i odwrotnie). Skrypt przerywa z komunikatem o wskazaniu nowego pliku. Chroni to przed zmieszaniem danych z nazwiskami i bez nich.
- **Straż kolumn:** jeśli kolumny istniejącego pliku różnią się od kolumn, które tworzy to uruchomienie (np. inny `-LatencyField`, który zmienia zestaw `Lat_<Pole>`, albo starsza wersja skryptu), skrypt przerywa i prosi o nowy plik `-RawStore`.

### 7.4 Plik rozbicia (`-OutCsv`)

Domyślnie `rtt_breakdown.csv` / `rtt_breakdown_anon.csv`. **Nadpisywany** przy każdym uruchomieniu. Kolumny:

`Dimension, Value, Unit, Count, Bad, BadPct, MedianRtt, P95Rtt, LatSessions, LatBad, LatBadPct, MedianLatency, P95Latency, MedianGap`

`Unit` to `sessions` dla wszystkich wymiarów poza `HourLocal` (tam `samples`). Kolumny opóźnienia są puste, gdy brak danych o opóźnieniu (znaczenie kolumn: sekcje 8.4 i 8.9).

---

## 8. Algorytmy analizy

### 8.1 Definicja sesji

Sesja to grupa wierszy o tym samym kluczu (`TransactionId` albo `SessionKey`). `ConvertTo-SessionSummaries` dla każdej grupy:
- sortuje próbki po `CollectedUtc`,
- liczy **medianę RTT** (`MedianRtt`) ze wszystkich próbek sesji oraz **medianę opóźnienia** (`MedianLat`) z próbek, które mają wartość opóźnienia (`$null`, gdy żadna nie ma), i **różnicę** `MedianRtt − MedianLat`,
- przepisuje atrybuty (użytkownik, maszyna, DG, protokół, transport, PoP, podsieć, kraj…) z **ostatniej niepustej** wartości w sesji,
- zachowuje wektor próbek (`Rtts`) do późniejszych percentyli.

### 8.2 „Zła sesja”

Sesja jest **zła**, gdy `MedianRtt > -ThresholdMs` (domyślnie 150 ms). Mediana, a nie maksimum, żeby pojedynczy skok nie kwalifikował całej sesji.

### 8.3 Percentyle

`Get-Percentile` używa metody najbliższej pozycji (nearest-rank): `indeks = ceil(p/100 × n) − 1`, z dolnym ograniczeniem do 0. P50 to mediana, P95 to 95. percentyl.

### 8.4 Rozbicie po wymiarze (`Get-Breakdown`)

Dla wymiaru D: grupuj sesje po wartości D (puste jako `(n/a)`); dla każdej grupy:

| Pole | Znaczenie |
|---|---|
| `Count` | liczba sesji w grupie |
| `Bad` | ile z nich jest złych |
| `BadPct` | `100 × Bad / Count`, 1 miejsce po przecinku |
| `MedianRtt` | mediana ze **wszystkich próbek** wszystkich sesji grupy |
| `P95Rtt` | 95. percentyl ze wszystkich próbek grupy |
| `LatSessions` | sesje w grupie, które mają dane o opóźnieniu |
| `LatBad` / `LatBadPct` | sesje, których mediana opóźnienia przekracza `-LatencyThresholdMs`, i ich odsetek **wśród sesji z danymi o opóźnieniu** |
| `MedianLatency` / `P95Latency` | mediana / 95. percentyl ze wszystkich próbek opóźnienia w grupie |
| `MedianGap` | mediana, po sesjach z danymi o opóźnieniu, z `MedianRtt − MedianLat` |

Grupy mniejsze niż `-MinSessions` są odrzucane (filtr szumu). Wynik sortowany malejąco po `BadPct`, potem po `Count`; w konsoli pokazywane jest 12 pierwszych wierszy, w CSV wszystkie.

### 8.5 Wymiary

Analizowane tylko te, których kolumna istnieje w danych: `Country`, `Location`, `DeliveryGroup`, `Protocol`, `Transport`, `ConnectedVia`, `LaunchedVia`, `AddrType`, `ClientSubnet`, `WorkspaceAppVersion`, `ClientPlatform`, `Machine`. Wymiar bez żadnej wartości jest raportowany jako „not available”.

### 8.6 Godzina (`Get-HourBreakdown`)

Jedyny wymiar liczony **na próbkach**, nie na sesjach: grupowanie po godzinie czasu lokalnego **maszyny, na której uruchomiono skrypt** (`ToLocalTime()`), `Bad` = próbki z `RttMs > próg`. Kolumny opóźnienia też liczone są na próbkach (`LatBadPct` = odsetek próbek z opóźnieniem powyżej `-LatencyThresholdMs`; `MedianGap` nie jest liczone).

### 8.7 Przegląd (Overview)

Liczba próbek, sesji, złych sesji i odsetek. W trybie zwykłym dodatkowo: liczba użytkowników, ilu ma złą sesję, 5 najczęściej powtarzających się oraz stosunek „złych sesji na złego użytkownika” (bliski 1,0 oznacza wielu różnych użytkowników). W trybie anonimowym ten fragment jest pomijany. Jeśli w trybie anonimowym `Country` to `unknown` dla wszystkich sesji, wyświetlane jest ostrzeżenie.

### 8.8 Uwagi statystyczne

- Małe grupy dają niestabilne odsetki. `-MinSessions` je ukrywa, ale nie zastępuje testu istotności.
- Wynik jest korelacją. Nie dowodzi przyczyny (sekcja 16).
- Przy kilku wymiarach jednocześnie (np. PoP i kraj) wymiary są wzajemnie skorelowane; skrypt nie robi tabel krzyżowych.

### 8.9 Porównanie ICA RTT z opóźnieniem

Wypisywane w przeglądzie, gdy przynajmniej jedna sesja ma dane o opóźnieniu (`LatencyMs` niepuste).

**Co jest porównywane.** ICA RTT (`IcaRttMS`) to raportowany czas odpowiedzi sesji „od końca do końca”. Opóźnienie to pole wybrane jako główne (`LatencyMs`, domyślnie `IcaLatency`). Oba pochodzą z tego samego wiersza `SessionMetrics`, więc są sparowane w próbce; analiza działa potem na **medianach per sesja**.

**Co jest wypisywane:**
- ile sesji ma dane o opóźnieniu,
- mediana po sesjach: RTT, opóźnienia i **różnicy** (RTT minus opóźnienie),
- **korelacja Pearsona** między medianą RTT sesji a medianą opóźnienia (`n/a` przy mniej niż 3 sesjach lub braku zmienności),
- **tabela 2×2** z progami `-ThresholdMs` (RTT) i `-LatencyThresholdMs` (opóźnienie; domyślnie ta sama wartość):

| | opóźnienie > próg | opóźnienie ≤ próg |
|---|---|---|
| **RTT > próg (zła)** | *oba wysokie*: opóźnienie leży głównie w ścieżce (strona sieci) | *RTT wysokie, opóźnienie OK*: RTT zawiera więcej niż zmierzone opóźnienie; sprawdź stronę VDA/sesji (CPU, grafika, profil/logowanie, input delay) |
| **RTT ≤ próg** | opóźnienie podwyższone, ale sesja działa; zwykle nie priorytet | oba w normie |

**W tabelach wymiarów** `MedianLatency`, `LatBadPct` i `MedianGap` pojawiają się obok kolumn RTT. Grupa z wysokim `BadPct` **i** wysokim `LatBadPct` wskazuje na ścieżkę; wysoki `BadPct` przy niskim `LatBadPct` i dużej różnicy wskazuje na stronę VDA/sesji.

**Straż wartości zerowych.** Jeśli co najmniej 90% próbek opóźnienia to 0, ostrzeżenie mówi, że pole prawdopodobnie nie jest wypełniane na tej ścieżce (artykuł Citrix CTX616926 opisuje ICA Latency pokazywane jako 0 w niektórych układach; nie udało mi się otworzyć tego artykułu, widziałem tylko tytuł), więc porównanie nie ma sensu.

**Ważne zastrzeżenia** (szczegóły w sekcji 16): model Monitor nie ma w `SessionMetrics` pola dosłownie zwanego „Network Latency”; które pole opóźnienia odpowiada „Network Latency” z Director w Twoim tenancie, musisz ustalić sam (`-Discover`, `-LatencyField`). Metryki są próbkowane w różnych odstępach, a `IcaLatency` może zawierać opóźnienie po stronie hosta, więc porównanie jest wskazówką, a nie pomiarem samej sieci.

---

## 9. Funkcje pomocnicze

### 9.1 `Get-ClientSubnet`

IPv4: pierwsze trzy oktety + `.0/24`. IPv6: pierwsze trzy segmenty (6 bajtów) + `::/48`. Nieprawidłowy adres daje pusty ciąg.

### 9.2 `Get-AddrType`

| Zakres | Wynik |
|---|---|
| 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, IPv6 `fc00::/7` | `private` |
| 100.64.0.0/10 | `cgnat` |
| pozostałe | `public` |

### 9.3 Geolokalizacja offline (`-GeoCsv`)

`Import-GeoTable` wczytuje CSV z kolumnami `Network` (CIDR IPv4), `Country`, opcjonalnie `Location`. Każdy zakres zamieniany jest na parę liczb (początek, koniec), tablice sortowane po początku. `Get-GeoFromTable` wyszukuje adres **binarnie** (O(log n)), więc wielkie tabele nie spowalniają analizy. Zasady i ograniczenia:

- tylko IPv4 (IPv6 daje `unknown`),
- zakresy muszą być rozłączne; nakładanie powoduje ostrzeżenie, a adresy w szerszym zakresie poza węższym trafiają do `unknown`,
- wiersze o błędnym formacie są pomijane; brak użytecznych wierszy przerywa działanie,
- żadnych zapytań do internetu.

Kolejność ustalania kraju w `-Anonymous`: pole tenanta → tabela `-GeoCsv` → `unknown`.

### 9.4 `Get-UserLabel` (`-AnonymizeUsers`)

`u_` + pierwsze 4 bajty SHA-256 z nazwy użytkownika (małe litery), w zapisie szesnastkowym. Stały (ta sama osoba daje ten sam skrót), więc można badać powtarzalność. **To pseudonimizacja, nie anonimizacja:** nazwy o małej entropii można odtworzyć słownikiem.

---

## 10. Tryby pracy

| Tryb | Co zmienia |
|---|---|
| **Domyślny** | Żąda `User`; plik próbek z kolumną `User`; przegląd z użytkownikami. |
| **`-Anonymous`** | Nie żąda nazwy użytkownika w ogóle. Zapisuje Transaction ID, kraj, maszynę, IP i dane techniczne. Osobne domyślne pliki `_anon`. |
| **`-AnonymizeUsers`** | Tylko w trybie domyślnym: skrót zamiast nazwy. |
| **`-Discover`** | Odkrywanie pól, bez zapisu. |
| **`-Loop`** | Powtarza pobieranie co `-IntervalMinutes` przez `-DurationHours`, z odnawianiem tokena. Analiza na końcu obejmuje cały plik. |

### 10.1 Przebieg `-Loop`

```
deadline = teraz + DurationHours ; okno = max(Hours, 2 × Interval/60)
powtarzaj:
    jeśli token starszy niż 45 min: odnów (Client ID+Secret) | odczytaj z SDK | błąd (wklejony token)
    pobierz próbki z okna  →  dopisz do pliku bez duplikatów
    jeśli teraz + Interval ≥ deadline: koniec
    Start-Sleep Interval
analiza całego pliku
```

Przerwanie przez <kbd>Ctrl</kbd>+<kbd>C</kbd> zachowuje dane zapisane do tej pory (zapis następuje po każdej iteracji).

### 10.2 Analiza istniejących danych

Analiza zawsze obejmuje cały plik próbek, a nie tylko świeże pobranie. Pozwala to na ponowne przeliczenie z innym progiem (`-Hours 0.01 -ThresholdMs 120`), ale skrypt nadal się loguje i wykonuje jedno małe pobranie.

---

## 11. Referencja parametrów

| Parametr | Typ | Domyślnie | Walidacja / uwagi |
|---|---|---|---|
| `-CustomerId` | string | – | `^[A-Za-z0-9_-]+$`. Jeśli brak, pyta kreator. |
| `-ThresholdMs` | int | 150 | Próg „złej” sesji (mediana RTT). |
| `-Hours` | double | 1 | Okno pobierania. |
| `-ApiHost` | string | `api.cloud.com` | `ValidateSet`: `api.cloud.com`, `api-eu.cloud.com`, `api.citrixcloud.jp`, `api.cloud.us`. |
| `-PageSize` | int | 100 | 1–100. |
| `-MaxPages` | int | 300 | Limit stron na jedno pobranie. |
| `-MinSessions` | int | 5 | Minimalna liczba sesji w grupie. |
| `-LatencyField` | string | auto | Pole opóźnienia `SessionMetrics` używane jako „network latency”. Musi należeć do kandydatów wypisanych przez `-Discover`, inaczej skrypt przerywa. |
| `-LatencyThresholdMs` | int | = `-ThresholdMs` | Mediana opóźnienia powyżej tej wartości czyni sesję „opóźnienie wysokie”. |
| `-Discover` | switch | wył. | Odkrywanie pól i koniec. |
| `-RawStore` | string | `rtt_samples[_anon].csv` | Plik próbek. |
| `-Loop` | switch | wył. | Powtarzanie pobierania. |
| `-IntervalMinutes` | int | 30 | Odstęp w pętli. |
| `-DurationHours` | double | 24 | Czas trwania pętli. |
| `-AnonymizeUsers` | switch | wył. | Skrót zamiast nazwy (tryb domyślny). |
| `-Anonymous` | switch | wył. | Brak nazw użytkowników. |
| `-GeoCsv` | string | – | Tabela CIDR→kraj; używana tylko z `-Anonymous`. |
| `-OutCsv` | string | `rtt_breakdown[_anon].csv` | Plik rozbicia (nadpisywany). W `-Discover` nieużywany. |
| `-ConnectionNav` | string | auto | Wymusza nawigację do połączenia. |
| `-TransportFields` | string[] | auto | Wymusza nazwy pól transportu. |
| `-Credential` | PSCredential | – | Tryb nieinteraktywny (Client ID jako użytkownik, Secret jako hasło). |

---

## 12. Referencja funkcji

| Funkcja | Rola |
|---|---|
| `Get-HttpStatus` | Wyciąga kod HTTP z wyjątku |
| `ConvertTo-UtcDate` | Parsuje datę (string z PS 5.1 lub `datetime` z PS 7) do UTC |
| `Get-Prop` | Bezpieczny odczyt właściwości (null-safe) |
| `Update-Token` | POST po token (Client ID + Secret), ustawia nagłówki |
| `Set-BearerHeaders` | Ustawia nagłówki dla gotowego tokena |
| `Invoke-ODataGet` | GET z kontrolą hosta i czytelnymi błędami |
| `ConvertFrom-ODataMetadata` | XML `$metadata` → słownik typów |
| `Get-MonitorModel` | Pobiera i parsuje `$metadata` |
| `Show-Discovery` | Wypisuje pola tenanta (`-Discover`) |
| `Resolve-QueryPlan` | Buduje plan zapytania z odkrytych pól (w tym pola opóźnienia i główne opóźnienie) |
| `Get-SamplesUrl` | Składa URL zapytania o próbki |
| `Get-ClientSubnet` | /24 lub /48 z adresu |
| `Get-AddrType` | `public` / `private` / `cgnat` |
| `Get-UserLabel` | Skrót nazwy użytkownika |
| `ConvertTo-IPv4Number` | Adres IPv4 → liczba |
| `Import-GeoTable` | Wczytuje tabelę CIDR→kraj |
| `Get-GeoFromTable` | Wyszukiwanie binarne kraju dla adresu |
| `ConvertTo-FlatRow` | Jedna próbka JSON → jeden wiersz CSV (oba tryby) |
| `Get-DeliveryGroupMap` | Jedno małe stronicowane GET: Id grupy → nazwa |
| `Resolve-DeliveryGroup` | `DesktopGroupId` maszyny → nazwa grupy przez tę tabelę |
| `Get-FlatSamples` | Stronicowane pobranie i spłaszczenie |
| `Get-KeyProp` | Nazwa kolumny klucza (`TransactionId` lub `SessionKey`) |
| `Add-ToStore` | Dopisanie do pliku z deduplikacją i strażą trybu |
| `Get-Percentile` | Percentyl metodą najbliższej pozycji |
| `Get-Correlation` | Korelacja Pearsona dwóch serii (2 miejsca po przecinku; `$null`, gdy nieokreślona) |
| `ConvertTo-SessionSummaries` | Próbki → podsumowania sesji (mediana RTT, mediana opóźnienia, różnica) |
| `Get-Breakdown` | Rozbicie po wymiarze (sesje), statystyki RTT i opóźnienia |
| `Get-HourBreakdown` | Rozbicie po godzinie (próbki), statystyki RTT i opóźnienia |
| `Show-Analysis` | Przegląd, blok RTT-vs-opóźnienie, tabele i zapis CSV |
| `ConvertFrom-SecureToPlain` | SecureString → tekst (BSTR czyszczony po użyciu) |
| `ConvertTo-CleanToken` | Normalizacja i walidacja tokena |
| `Read-SdkToken` | Odczyt tokena ze zmiennej sesji SDK |
| `Get-TokenFromCitrixSdk` | Logowanie oknem przez SDK |
| `Read-PastedToken` | Wklejanie tokena (pole ukryte) |
| `Read-ConnectionWizard` | Kreator Customer ID + sposób logowania |

---

## 13. Bezpieczeństwo i prywatność

### 13.1 Operacje na środowisku

- **Wyłącznie odczyt.** Jedyne żądanie niebędące GET-em to `POST` po token. W kodzie nie ma PUT, PATCH ani DELETE, `Invoke-Expression`, `Start-Process` ani ładowania bibliotek.
- **Weryfikacja:** audyt kodu (wyszukiwanie wywołań sieciowych i poleceń zapisujących) oraz uruchomienie całego skryptu z atrapami `Invoke-RestMethod` / `Invoke-WebRequest` rejestrującymi każde żądanie. Wynik: `POST` po token (tylko opcja 3) + `GET $metadata` + `GET DesktopGroups` + `GET SessionMetrics`. Zestaw plików po przebiegu: dwa pliki CSV.
- **Zastrzeżenie:** gwarancja „tylko odczyt” wynika z kodu skryptu, nie z uprawnień poświadczeń. Klient API tworzony w Citrix Cloud może mieć szerokie uprawnienia (dokumentacja Citrix opisuje go jako „full-access admin”, o ile nie wybierzesz Custom access z rolą Read Only Administrator). Token z opcji 1 to token Twojego konta administratora.

### 13.2 Operacje lokalne

| Operacja | Kiedy | Plik |
|---|---|---|
| `Export-Csv -Append` | po każdym pobraniu | `-RawStore` |
| `Export-Csv` (nadpisanie) | po analizie | `-OutCsv` |
| `Import-Csv` | analiza, deduplikacja, `-GeoCsv` | `-RawStore`, `-GeoCsv` |

Skrypt niczego nie kasuje. Nie zapisuje poświadczeń ani Customer ID.

### 13.3 Obsługa poświadczeń

- Customer ID i token żyją tylko w pamięci; na końcu zmienne są czyszczone (`$script:Headers = $null`, `$Credential = $null`). Skrypt nie nadpisuje pamięci procesu, więc po zakończeniu działania powłoki nie zostaje nic na dysku, ale wartości mogą chwilowo pozostać w pamięci procesu.
- Secret z `PSCredential` jest używany lokalnie w `Update-Token`, a zmienna z nim jest czyszczona w bloku `finally`.
- Wklejany token jest odczytywany jako `SecureString`; konwersja do tekstu jest krótkotrwała (BSTR zerowany po użyciu).
- Skrypt **nie pobiera tokena z przeglądarki** (ani z ciasteczek, ani z magazynów Chrome).

### 13.4 Dane osobowe

| Plik | Zawartość wrażliwa |
|---|---|
| Tryb zwykły | nazwiska użytkowników, maszyny, adresy IP |
| `-Anonymous` | maszyny i adresy IP (mogą wskazywać osobę: VDI przypisane do osoby, domowy IP); Transaction ID umożliwia ustalenie osoby w Director |
| `-Anonymous` + `-AnonymizeUsers` | jak wyżej (skrót nie jest anonimizacją) |

Traktuj pliki jako dane osobowe: ogranicz dostęp, nie wysyłaj mailem, usuń po analizie. Ocenę zgodności z przepisami (np. RODO) i zgodą pracowników wykonuje właściwa osoba w organizacji. Ta dokumentacja nie jest poradą prawną.

### 13.5 Sprzątanie

Po analizie: usuń `rtt_samples*.csv`, `rtt_breakdown*.csv`, ewentualnie `geo.csv` z danymi o sieciach; usuń lub zrotuj klienta API w Citrix Cloud; wyczyść schowek po wklejeniu tokena.

---

## 14. Komunikaty i obsługa błędów

| Komunikat (skrót) | Źródło | Znaczenie / działanie |
|---|---|---|
| `Token request failed (HTTP …)` | `Update-Token` | HTTP 400/401: najczęściej Org ID lub Client ID wpisane jako Customer ID; poza tym zły Client ID/Secret albo usunięty klient. Komunikat dołącza treść odpowiedzi serwera i podpowiedź „Check: …” |
| `OData request failed (HTTP 401)` | `Invoke-ODataGet` | Token wygasł, uruchom ponownie |
| `OData request failed (HTTP …) … -Discover` | `Invoke-ODataGet` | Pole nazywa się inaczej; użyj `-Discover` |
| `Refusing to send the token to unexpected host` | `Invoke-ODataGet` | `@odata.nextLink` wskazuje inny host; przerwano |
| `Entity type '…' not found in $metadata` | `Resolve-QueryPlan` | Nietypowy model danych tenanta; `-Discover` |
| `SessionMetrics has no 'IcaRttMS' …` | `Resolve-QueryPlan` | Brak wymaganego pola |
| `Session has no navigation property '…'` | `Resolve-QueryPlan` | Błędna wartość `-ConnectionNav` |
| `SessionMetrics has no latency field '…'` | `Resolve-QueryPlan` | Błędny `-LatencyField`; komunikat wypisuje kandydatów |
| `The columns of … differ from the columns this run produces` | `Add-ToStore` | Inny `-LatencyField` lub starsza wersja skryptu; użyj nowego `-RawStore` |
| `N% of the latency samples are 0 …` | `Show-Analysis` | Pole opóźnienia prawdopodobnie nie jest wypełniane; porównanie nie ma sensu |
| `Latency: no latency values in the data` | `Show-Analysis` | Tenant nie ma pola opóźnienia albo jest puste na tych VDA; brak porównania |
| `Stopped after N pages - incomplete` | `Get-FlatSamples` | Zmniejsz `-Hours` lub zwiększ `-MaxPages` |
| `… already holds user names …` / `… is an anonymous store …` | `Add-ToStore` | Mieszanie trybów; wskaż inny plik |
| `N overlapping ranges in …` | `Import-GeoTable` | Zakresy w `-GeoCsv` nie są rozłączne |
| `No usable 'Network,Country' IPv4 CIDR rows` | `Import-GeoTable` | Zły format `-GeoCsv` |
| `-GeoCsv is only used together with -Anonymous` | main | Ostrzeżenie; tabela ignorowana |
| `-GeoCsv file not found: … continuing without it` | main | Tylko ostrzeżenie: przebieg trwa dalej (tenant może sam podawać kraj) |
| `OData request failed (HTTP 400) … $expand path which is too deep` | `Invoke-ODataGet` | Starsza wersja skryptu (zagnieżdżone `$expand`); użyj bieżącej wersji |
| `Country is 'unknown' for every session` | `Show-Analysis` | Brak pola kraju i brak działającego `-GeoCsv` |
| `The Citrix SDK commands were not found …` / `… not installed …` | `Get-TokenFromCitrixSdk` | Zainstaluj SDK lub wybierz opcję 2/3 |
| `Signed in, but no bearer token was found …` | `Get-TokenFromCitrixSdk` | Nazwa zmiennej tokena inna niż obsługiwane |
| `The pasted token has expired …` | main (`-Loop`) | Użyj opcji 1 lub 3 w pętli |
| `The Citrix SDK session no longer holds a token` | main (`-Loop`) | Uruchom skrypt ponownie |

Błędy krytyczne przerywają skrypt (`$ErrorActionPreference = 'Stop'`). Zebrane wcześniej dane pozostają w pliku próbek.

---

## 15. Weryfikacja: co przetestowano, a co nie

### Przetestowano (PowerShell 7.6, macOS)

| Obszar | Metoda | Wynik |
|---|---|---|
| Składnia | Parser PowerShell (AST) | brak błędów |
| Odkrywanie pól | Syntetyczny `$metadata` (połączenie jako kolekcja, Transaction ID, DG, wskaźnik transportu) | plan poprawny, URL poprawny (znaleziony i naprawiony błąd brakującego przecinka w trybie anonimowym) |
| Analiza | 120 sesji z wstawionym wzorcem (sesje bez UDP, jeden PoP) | wzorzec wykryty w tabelach Transport i ConnectedVia |
| Tryb anonimowy | Wiersze syntetyczne | brak nazwisk w wierszach; kolumny zgodne ze schematem |
| Geolokalizacja | Tabela CIDR, wyszukiwanie binarne | poprawne kraje; ostrzeżenie o nakładaniu |
| Plik próbek | Dwukrotny zapis, wczytanie z CSV | deduplikacja poprawna; analiza z danych tekstowych działa |
| Straż trybu | Plik z innym trybem | przerwanie z komunikatem |
| Żądania HTTP | Cały skrypt z atrapami sieci | tylko POST po token (opcja 3) + 3 GET (`$metadata`, `DesktopGroups`, `SessionMetrics`) |
| Limit głębokości `$expand` | Atrapa odpowiadająca HTTP 400, gdy adres ma więcej niż 2 zagnieżdżone `$expand=`, z metadanymi wzorowanymi na prawdziwym tenancie (`CurrentConnection`, `ClientLocationCountry/City`, pięć pól opóźnienia, `DesktopGroupId`) | zapytanie przyjęte; nazwy Delivery Group rozwiązane; kraj z pól tenanta; brak `geo.csv` tylko ostrzega |
| Zmiany na dysku | Migawka katalogu przed/po | tylko dwa pliki CSV |
| Porównanie z opóźnieniem | 150 sesji syntetycznych z dwiema wstawionymi przyczynami (po stronie sieci: RTT 230 / opóźnienie 190; po stronie hosta: RTT 210 / opóźnienie 35) | PoP z przyczyną sieciową: `MedianLatency` 189, `LatBadPct` 100; PoP z przyczyną po stronie hosta: `MedianLatency` 35, `LatBadPct` 0, `MedianGap` 172; tabela 2×2: 50/50/0/50; korelacja 0,63 |
| Wybór pola opóźnienia | Syntetyczny `$metadata` z `IcaLatency`, `WanLatency`, `ClientL7Latency`, `DiskLatency` | opóźnienie dysku pominięte; główne `IcaLatency`; nadpisanie `WanLatency` działa; nieznane nadpisanie przerywa z listą kandydatów; kolumny `Lat_<Pole>` zapisane |
| Straż kolumn | Drugie uruchomienie z innym `-LatencyField` na tym samym pliku | odmawia dopisania, prosi o nowy plik |
| Kreator | Atrapy `Read-Host`: SDK jako komenda, SDK jako snap-in, brak SDK, wklejony token (z prefiksem, z błędnym wpisem), Client ID+Secret (domyślnie po Enter; wartości ze spacjami; pusty Client ID / pusty Secret powtarzane do skutku), błędny wybór; `Get-Credential` zamockowane tak, by test padł przy jego wywołaniu | wszystkie ścieżki działają; wysłane Client ID i Secret to wartości po przycięciu |

### Zaobserwowano na prawdziwym tenancie (2026-10-09)

| Element | Obserwacja |
|---|---|
| Logowanie | Client ID + Secret (opcja 3) zadziałało, gdy Customer ID było CCID. Org ID lub Client ID wpisane jako Customer ID dawało HTTP 400 przy żądaniu tokena |
| Połączenie | Dostępne przez nawigację `CurrentConnection` |
| Kraj | Tenant udostępnia `ClientLocationCountry` i `ClientLocationCity`, więc `-GeoCsv` nie jest potrzebny |
| Pola opóźnienia | `IcaLatency`, `ClientL7Latency`, `ServerL7Latency`, `WanLatency`, `DcLatency` (główne: `IcaLatency`) |
| Wskaźnik transportu | **Brak** (Monitor OData nie udostępnia pola EDT/TCP) |
| Zapytanie o próbki | HTTP 400, głębokość `$expand` (naprawione, jeszcze niepotwierdzone na żywo) |

### Nie przetestowano

- **Naprawione zapytanie o próbki na prawdziwym tenancie** (treść odpowiedzi, limity, retencja danych per sesja, a przede wszystkim **które pole opóźnienia odpowiada „Network Latency” z Director** i jak jest wypełniane).
- **Prawdziwe SDK Citrix** (okno logowania, SSO/MFA, nazwa zmiennej tokena, odnawianie w `-Loop`).
- **Windows PowerShell 5.1** (zachowanie `Invoke-WebRequest`, `Export-Csv -Append`, typów dat).
- **Wydajność** przy dużych plikach (dziesiątki/setki tysięcy wierszy): analiza wczytuje cały plik i grupuje w pamięci; można się spodziewać spowolnienia, ale nie zostało zmierzone.

---

## 16. Znane ograniczenia

1. **Nazwy pól nie są potwierdzone na żywym tenancie.** Skrypt je odkrywa, ale np. wskaźnik EDT/TCP może w ogóle nie istnieć w Monitor OData. Wtedy tabela `Transport` jest pusta i protokół trzeba sprawdzić w Director.
2. **Retencja danych per sesja** to według źródeł społecznościowych ok. 1 godziny (niepotwierdzone w oficjalnej dokumentacji). Bez `-Loop` analiza dotyczy tylko ostatniej godziny.
3. **Połączenie jako kolekcja:** gdy `Session` ma wiele połączeń, skrypt bierze **ostatni element** kolekcji z odpowiedzi, nie połączenie aktywne w chwili próbki. Dla sesji z ponownymi połączeniami atrybuty klienta mogą nie odpowiadać próbce.
4. **Transaction ID może być per uruchomienie (połączenie), nie per sesja.** Sesja z ponownym połączeniem może zostać policzona jako kilka „sesji”.
5. **Klucz deduplikacji ma dokładność do sekundy.** Dwie próbki tej samej sesji w tej samej sekundzie zostaną zlane (praktycznie nie występuje).
6. **Geolokalizacja:** tylko IPv4, zakresy rozłączne. IPv6 zawsze `unknown`.
7. **„Network latency” nie jest jednym, jednoznacznym polem.** Według referencji modelu Monitor `SessionMetrics` ma `IcaLatency` („ICA session latency”, null na starszych VDA) oraz, przy danych z NetScaler / SD-WAN, `ClientL7Latency` („WAN latency”), `ServerL7Latency` („DC latency”), `WanLatency` i `DcLatency`. Osobne „end-to-end network latency” istnieje w modelu tylko jako metryka alertów (`NetworkLatencyMs`), a `ApplicationPerformanceMetrics.NetworkLatency` to opóźnienie wysyłania na poziomie aplikacji w innej encji, której skrypt nie czyta. Dlatego skrypt domyślnie używa `IcaLatency` i pozwala wybrać inne pole; nie może wiedzieć, które odpowiada „Network Latency”, które widzisz w Director.
7a. **`IcaLatency` nie jest czystym opóźnieniem sieci.** Źródła społecznościowe opisują je jako czas od wejścia użytkownika do jego przetworzenia na hoście sesji, czyli opóźnienie sieci plus opóźnienie po stronie hosta. Duża różnica między RTT a `IcaLatency` może więc oznaczać również „RTT ma składnik aplikacji/interfejsu”, a nie tylko „problem po stronie serwera”.
7b. **Metryki są próbkowane w różnych odstępach** (źródła podają różne interwały dla RTT, opóźnienia i liczników opartych na Perfmon), więc pojedyncza para wartości może się nie zgadzać; skrypt pracuje na medianach sesji, aby to złagodzić.
7c. **Brak lub zero opóźnienia.** Próbki bez wartości opóźnienia są pomijane w statystykach opóźnienia (sesja nadal liczy się dla RTT). Opóźnienie raportowane jako 0 może ukrywać brak pomiaru (straż: ostrzeżenie, gdy ≥ 90% to 0).
7d. **Domyślny próg opóźnienia równa się progowi RTT.** Opóźnienie jest składnikiem RTT i zwykle niższe, więc przy tej samej liczbie mniej sesji jest „opóźnienie wysokie”; wypróbuj niższy `-LatencyThresholdMs` (np. 100). Progi są opisowe, nie są limitami zdefiniowanymi przez Citrix.
7e. **Korelacja jest opisowa** (Pearson, mediany sesji) i nic nie mówi o przyczynowości.
8. **Godzina w `HourLocal`** to czas lokalny maszyny uruchamiającej skrypt, nie strefa użytkowników.
9. **Brak tabel krzyżowych** (np. PoP × kraj) i testów istotności statystycznej.
10. **Korelacja, nie przyczyna.** Wynik „złe sesje na TCP” potwierdza objaw; przyczynę (np. UDP 443 blokowane na Azure Firewall) trzeba sprawdzić osobno w logach firewalla i konfiguracji.
11. **Token SDK jest tokenem konta administratora** (szerokie uprawnienia), w odróżnieniu od ograniczonego klienta API.
12. **Plik próbek rośnie** bez ograniczeń i jest wczytywany w całości przy każdym uruchomieniu.
13. **`-ApiHost api-eu.cloud.com`** nie jest wymieniony w dokumentacji Citrix; to wartość do wypróbowania.
14. Skrypt zawiera komunikaty po angielsku; dokumentacja jest po polsku.

---

## 17. Utrzymanie i rozszerzanie

### Dodanie nowego wymiaru analizy (np. nowa kolumna z tenanta)

1. W `Resolve-QueryPlan` dodaj nazwę pola do listy `$wanted` (albo regex do wykrywania).
2. W `ConvertTo-FlatRow` dodaj kolumnę do obu schematów (zwykłego i `-Anonymous`) przez `& $get 'NazwaPola'`.
3. W `ConvertTo-SessionSummaries` dodaj `NowaKolumna = & $latest 'NowaKolumna'`.
4. W `Show-Analysis` dopisz nazwę do listy `$dims`.

Pamiętaj, że zmiana schematu kolumn wymaga nowego pliku próbek (stary będzie niespójny).

### Zmiana definicji „złej” sesji

Zmień warunek w `Get-Breakdown` (`$_.MedianRtt -gt $Threshold`), np. na P95 zamiast mediany. Parametr `-ThresholdMs` zmienia tylko próg.

### Dostosowanie do innej wersji API

Jeśli HTTP 400 wskazuje na nieznane pole: uruchom `-Discover`, ustaw `-ConnectionNav` / `-TransportFields`, w razie potrzeby dopisz alternatywne nazwy w `Resolve-QueryPlan`.

### Testowanie po zmianach

Zalecany minimalny zestaw: parser (AST), uruchomienie na syntetycznym `$metadata` i danych, ponowny audyt żądań HTTP z atrapami (powinny pozostać tylko POST po token + GET) oraz test wycieku (brak nazwisk w trybie `-Anonymous`).

---

## 18. Decyzje projektowe

| Decyzja | Powód |
|---|---|
| Pola odkrywane z `$metadata`, nie na sztywno | Modelu danych nie dało się zweryfikować na żywym tenancie; zapobiega błędom HTTP 400 |
| Pobieranie **wszystkich** próbek | Potrzebny mianownik, aby porównywać odsetki grup |
| Mediana sesji jako kryterium | Odporność na pojedyncze skoki |
| Zapis do CSV z deduplikacją | Dane per sesja są dostępne krótko; pozwala zbierać w czasie |
| `-Anonymous` | Wymóg ograniczenia danych osobowych: brak nazwisk, zostaje Transaction ID i kraj (maszyny i IP świadomie zachowane: są potrzebne do zlokalizowania problemu) |
| Geolokalizacja tylko offline | Wysyłanie adresów IP do usług zewnętrznych podważałoby anonimizację |
| **Brak zapamiętywania poświadczeń** | Decyzja projektowa: zapis Customer ID/tokena uznano za niebezpieczny. Wcześniejsza wersja z szyfrowaniem DPAPI została usunięta |
| **Brak pobierania tokena z przeglądarki** | Chrome chroni ciasteczka i blokuje zdalne debugowanie profilu domyślnego; token konsoli to pełne uprawnienia administratora; brak udokumentowanego użycia z Monitor OData |
| Logowanie przez SDK Citrix | Oficjalna, udokumentowana droga uzyskania tokena po zalogowaniu użytkownika; skrypt tylko czyta token z pamięci sesji |
| Kontrola hosta przy stronicowaniu | Token nie może trafić do innego hosta, nawet gdy odpowiedź wskaże inny `nextLink` |
| Zbieranie **wszystkich** pól opóźnienia, jedno główne | Nie dało się zweryfikować, czym jest „Network Latency” w tenancie; zachowanie wszystkich kandydatów w CSV pozwala porównywać bez ponownego zbierania |
| Tabela 2×2 z jawnymi progami + różnica + korelacja | Przejrzyste i łatwe do wyjaśnienia; unika arbitralnego progu „udziału sieci” |
| Kontrola poprawności Customer ID (ostrzeżenie dla GUID / samych cyfr) | Pierwszy prawdziwy przebieg kończył się HTTP 400, bo jako Customer ID wpisano najpierw Client ID, a potem Org ID; miękkie ostrzeżenie (nie twarda blokada) wychwytuje błąd wcześnie, nie odrzucając nietypowych, ale poprawnych identyfikatorów |
| Client ID + Secret jako domyślne logowanie, przez pytania w konsoli | Oczekiwana konfiguracja to klient API (Client ID + Secret); w testach logowanie SDK kończyło się „authentication failed” mimo udanego logowania na jednym tenancie, a okno `Get-Credential` nie pojawiało się w jednej powłoce. Zwykłe pytania `Read-Host` działają w każdej powłoce |
| Delivery Group przez osobne zapytanie, a nie trzeci poziom `$expand` | API odrzuca `$expand` głębsze niż 2 (widziane na prawdziwym tenancie); jedno dodatkowe małe GET jest tańsze i bezpieczniejsze niż rezygnacja z kolumny |
| Brakujący plik `-GeoCsv` tylko ostrzega | Tenant może sam podawać kraj; przerywanie pracy z powodu opcjonalnego pliku nikomu nie pomaga |
| Jeden plik bez modułów | Łatwe przenoszenie na maszynę roboczą i przegląd |

---

## 19. Słownik pojęć

| Pojęcie | Znaczenie |
|---|---|
| **ICA RTT** | Czas odpowiedzi sesji HDX/ICA raportowany przez Citrix (obejmuje sieć oraz przetwarzanie po stronie serwera). Pole `IcaRttMS`. |
| **IcaLatency** | Pole `SessionMetrics`: opóźnienie sesji ICA w ms (null na starszych VDA). Źródła społecznościowe: zawiera też opóźnienie po stronie hosta, nie tylko sieć. Domyślne „network latency” w tym skrypcie. |
| **Network latency** | W tym skrypcie: wybrane pole opóźnienia (`-LatencyField`). Nie jest jednym polem w modelu Monitor. |
| **ClientL7Latency / ServerL7Latency** | Opóźnienie warstwy 7 po stronie klienta („WAN latency”) i serwera („DC latency”), dostępne z danymi NetScaler HDX Insight. |
| **WanLatency / DcLatency** | Opóźnienie segmentu WAN i segmentu centrum danych wyliczane z SD-WAN; null bez SD-WAN. |
| **Różnica (gap)** | `MedianRtt − MedianLat` per sesja: część RTT niewyjaśniona zmierzonym opóźnieniem. |
| **EDT** | Enlightened Data Transport: transport HDX oparty na UDP, lepszy przy stratach i dużych opóźnieniach. |
| **Adaptive Transport** | Mechanizm wyboru EDT (UDP) z powrotem do TCP, gdy UDP jest niedostępne. |
| **Session Reliability / CGP** | Warstwa podtrzymująca sesję przy krótkich przerwach (porty 1494/2598, w EDT wymagana). |
| **Gateway Service** | Zarządzana przez Citrix brama HDX (chmurowa); użytkownik łączy się z najbliższym PoP. |
| **PoP** | Point of Presence: punkt wejścia Gateway Service. Kolumna `ConnectedVia`. |
| **Rendezvous** | Protokół, w którym VDA łączy się z Gateway Service bezpośrednio, z pominięciem Cloud Connectorów (HDX; w V2 także ruch kontrolny). |
| **Cloud Connector** | Komponent w lokalizacji zasobów łączący ją z Citrix Cloud. |
| **Transaction ID** | Identyfikator uruchomienia sesji używany w Session Launch Diagnostics (Monitor/Director). |
| **Monitor Service OData** | Interfejs OData v4 do danych Monitor/Director w Citrix Cloud. |
| **Service principal / klient API** | Tożsamość aplikacyjna w Citrix Cloud (Client ID + Secret) do wywołań API. |
| **Delivery Group** | Zbiór maszyn i uprawnień udostępnianych użytkownikom. |
| **Zła sesja** | W tym skrypcie: sesja, której mediana ICA RTT przekracza `-ThresholdMs`. |

---

## 20. Źródła

- [Referencja modelu Monitor Service OData (Citrix)](https://developer-docs.citrix.com/en-us/monitor-service-odata-api/api-reference/monitor-model): pola opóźnienia w `SessionMetrics`.
- [CTX201968, Accessing ICA RTT Metrics (Citrix)](https://support.citrix.com/external/article/CTX201968/accessing-ica-rtt-metrics-for-citrix-hdx.html): czym jest ICA RTT.
- [Goliath: wysokie ICA/Network Latency i niskie ICA RTT](https://support.goliathtechnologies.com/hc/en-us/articles/4808951320983-Why-do-I-see-high-ICA-Network-Latency-and-Low-ICA-RTT): zależności między metrykami i ich próbkowanie (źródło zewnętrzne).
- [CTX616926, Director pokazuje ICA Latency jako 0](https://support.citrix.com/s/article/CTX616926-citrix-director-reports-ica-latency-value-as-0): widziałem tylko tytuł; strony nie udało się otworzyć.
- [Accessing Monitor Service Data (Citrix)](https://developer-docs.citrix.com/en-us/citrix-cloud/accessing-monitor-service-data-citrix-cloud-external/accessing-monitor-service-data-citrix-cloud-external.html)
- [Get-XDAuthentication (Citrix DaaS SDK)](https://developer-docs.citrix.com/en-us/citrix-daas-sdk/sdkproxy/get-xdauthentication)
- [Get started with Citrix Cloud APIs](https://developer-docs.citrix.com/en-us/citrix-cloud/citrix-cloud-api-overview/get-started-with-citrix-cloud-apis)
- [SDKs and APIs, Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/sdk-api)
- [Pobranie Remote PowerShell SDK](https://www.citrix.com/downloads/citrix-cloud/product-software/xenapp-and-xendesktop-service.html)
- [Rendezvous V2](https://docs.citrix.com/en-us/citrix-daas/hdx-transport/rendezvous-protocol/rendezvous-v2.html)
- [Delegated administration, Citrix DaaS](https://docs.citrix.com/en-us/citrix-daas/manage-deployment/delegated-administration.html)
- [CTX560736, API z uprawnieniami Custom/read-only](https://support.citrix.com/external/article/CTX560736/how-to-create-api-with-customsread-only.html)
- [Azure Firewall monitoring data reference](https://learn.microsoft.com/en-us/azure/firewall/monitor-firewall-reference)
