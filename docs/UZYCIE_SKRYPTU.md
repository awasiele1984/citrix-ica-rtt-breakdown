# Get-IcaRttBreakdown.ps1: dokładna instrukcja użycia

Skrypt odpowiada na pytanie: **co mają wspólnego sesje Citrix z wysokim ICA RTT?** (Delivery Group, PoP Gateway Service, transport EDT/TCP, kraj, podsieć klienta, wersja Workspace app, godzina…). Pobiera dane z Citrix Cloud (Monitor Service OData), zapisuje je do CSV i pokazuje, w której grupie odsetek „złych” sesji odbiega od reszty.

Pliki w komplecie:

| Plik | Zawartość |
|---|---|
| `Get-IcaRttBreakdown.ps1` | skrypt |
| `JAK_POBRAC_TOKEN.md` | logowanie: Customer ID, SDK Citrix, klient API, token |
| `UZYCIE_SKRYPTU.md` | ten plik |

---

## 1. Co skrypt robi, a czego nie robi

- **Tylko odczyt.** Jedyne żądanie niebędące odczytem to pobranie tokena (POST po token). Cała reszta to GET do `api.cloud.com`. Skrypt niczego nie tworzy, nie zmienia i nie usuwa w Citrix Cloud ani w Azure.
- **Lokalnie zapisuje wyłącznie pliki CSV** (patrz sekcja 6). Niczego nie kasuje, nie instaluje, nie uruchamia.
- **Nie zapamiętuje** Customer ID, tokena ani haseł. Kreator pyta za każdym razem, a dane żyją tylko w pamięci na czas uruchomienia.
- **Nic nie wysyła poza Citrix Cloud.** Adresy IP klientów nie są sprawdzane w żadnych zewnętrznych serwisach.
- Skrypt nie był jeszcze uruchamiany na prawdziwym tenancie. Testowałem logikę na danych syntetycznych i na atrapach zapytań. Dlatego **zawsze zaczynaj od `-Discover`** (sekcja 4).

## 2. Wymagania

1. **Windows z PowerShell 5.1** (`powershell.exe`). Najpewniejsza opcja. Nowsze wersje SDK Citrix działają według dokumentacji także w PowerShell do 7.3.
2. **Do logowania opcją 1** (okno): zainstalowany Citrix Remote PowerShell SDK. Instrukcja, link i ograniczenia: `JAK_POBRAC_TOKEN.md`.
   Albo klient API (opcje 2 i 3), też opisany w `JAK_POBRAC_TOKEN.md`.
3. **Dostęp do `api.cloud.com` po HTTPS** (port 443) z maszyny, na której uruchamiasz skrypt.
4. Konto z dostępem do Monitor/Director (odczyt wystarcza).

Jeśli Windows blokuje pobrany skrypt:

```powershell
Unblock-File .\Get-IcaRttBreakdown.ps1
# jeśli polityka wykonywania nadal blokuje, tylko dla tego okna:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 3. Przygotowanie (raz)

1. Skopiuj `Get-IcaRttBreakdown.ps1` do osobnego folderu, np. `C:\Citrix\rtt`. Pliki CSV powstaną w **katalogu, w którym jesteś** (bieżący katalog), więc wejdź do tego folderu:
   ```powershell
   cd C:\Citrix\rtt
   ```
2. Znajdź swój **Customer ID** (patrz `JAK_POBRAC_TOKEN.md`, krok „0. Znajdź swój Customer ID”).
3. (Zwykle niepotrzebne) Plik `geo.csv` dostarcza kraj klienta w trybie anonimowym **tylko wtedy, gdy tenant go nie podaje**. Wiele tenantów samo udostępnia `ClientLocationCountry` / `ClientLocationCity`; plan wypisany przy starcie mówi, jak jest u Ciebie („country from tenant fields …”). Sekcja 8.

## 4. Pierwsze uruchomienie: `-Discover`

```powershell
.\Get-IcaRttBreakdown.ps1 -Discover
```

Kreator zapyta o Customer ID i sposób logowania (sekcja 5). Potem skrypt **tylko pobierze opis pól** (`$metadata`) i wypisze, co Twój tenant udostępnia:

- pola połączenia i klienta (adres klienta, wersja Workspace app, host bramki…),
- czy jest **wskaźnik transportu EDT/UDP vs TCP** (pola o nazwach zawierających `Transport`, `Udp`, `Edt`, `Rendezvous`),
- czy jest **Transaction ID**,
- czy jest pole **kraju/lokalizacji**,
- jakie **pola opóźnienia** ma `SessionMetrics` (kandydaci na `-LatencyField`: `IcaLatency`, a przy danych z NetScaler / SD-WAN także `ClientL7Latency`, `ServerL7Latency`, `WanLatency`, `DcLatency`).

Nic nie zapisuje do CSV.

**Co z tego wynika:**

| Wynik `-Discover` | Konsekwencja |
|---|---|
| Jest wskaźnik transportu | Tabela `Transport` w wynikach powie wprost, czy złe sesje jadą po TCP. To najcenniejsza informacja. |
| Brak wskaźnika transportu | Skrypt tego nie pokaże. Sprawdź protokół w Director na próbce dobrych i złych sesji (Transaction ID z pliku pozwala je znaleźć). |
| Brak pola kraju | Użyj `-GeoCsv` (sekcja 8), inaczej `Country` = `unknown`. |
| Brak Transaction ID | Kluczem będzie GUID sesji. Skrypt poinformuje o tym przy starcie. |
| Brak pól opóźnienia | Porównanie ICA RTT z opóźnieniem zostanie pominięte (skrypt wypisze komunikat). |
| Kilka pól opóźnienia | Domyślnie użyje `IcaLatency`. Jeśli „Network Latency” z Director odpowiada innemu polu, wskaż je przez `-LatencyField`. |

## 5. Kreator logowania

Po uruchomieniu (bez parametrów logowania) skrypt prowadzi przez dwa kroki:

**1/2 Customer ID.** Wklej **CCID** swojego konta Citrix Cloud (ok. 12 liter i cyfr): **nie** Org ID (same cyfry) i **nie** Client ID (GUID). Skrypt ostrzega, gdy wpiszesz jedno z nich. Gdzie go znaleźć: `JAK_POBRAC_TOKEN.md`, krok 0.

**2/2 Sposób logowania:**

| Wybór | Co robi | Kiedy |
|---|---|---|
| **3** (Enter) | Wpisujesz Client ID i (ukryty) Secret klienta API w dwóch pytaniach w konsoli. Skrypt sam pobiera i odnawia token. | **Domyślna i zalecana.** Działa w każdej powłoce, nie wymaga SDK, najlepsza dla `-Loop`. |
| **1** | Otwiera okno logowania Citrix Cloud (SDK). Skrypt odczytuje token z sesji SDK. | Opcjonalna. Wymaga SDK; może zawieść zależnie od typu konta. Token jest to token **Twojego konta admina**. |
| **2** | Wklejasz token dostępu (pole ukryte). | Gdy masz już token. Ważny ok. 1 godziny. |

Szczegóły i rozwiązywanie problemów: `JAK_POBRAC_TOKEN.md`.

## 6. Zwykłe uruchomienie

```powershell
.\Get-IcaRttBreakdown.ps1 -Anonymous
```

(`-GeoCsv .\geo.csv` dodaj tylko wtedy, gdy `Country` wychodzi jako `unknown`; brak pliku `geo.csv` daje tylko ostrzeżenie.)

Co się dzieje:

1. Kreator logowania.
2. Odczyt `$metadata` i wypisanie planu: z jakich pól skrypt skorzysta (czy ma transport, Transaction ID, kraj).
3. Pobranie próbek RTT **i wszystkich pól opóźnienia** z ostatniej godziny (`-Hours 1`). Dane per sesja Citrix trzyma tylko krótko, około godziny (według źródeł społecznościowych; nie potwierdzone w oficjalnej dokumentacji).
4. Dopisanie próbek do pliku i analiza całego pliku.
5. Wypisanie tabel w konsoli i zapis rozbicia do CSV.

### Pliki, które powstają (w bieżącym katalogu)

| Plik | Co zawiera |
|---|---|
| `rtt_samples_anon.csv` (bez `-Anonymous`: `rtt_samples.csv`) | Wszystkie zebrane próbki. Dopisywane między uruchomieniami, **bez duplikatów**. |
| `rtt_breakdown_anon.csv` (bez `-Anonymous`: `rtt_breakdown.csv`) | Pełna tabela rozbicia (wszystkie wymiary). **Nadpisywana** przy każdym uruchomieniu. |

Ścieżki zmienisz parametrami `-RawStore` i `-OutCsv`. Nie podawaj ścieżki do ważnego istniejącego pliku, bo `-OutCsv` go nadpisze.

### Kolumny w pliku próbek (tryb `-Anonymous`)

`CollectedUtc, TransactionId, Country, Location, Machine, DeliveryGroup, ClientAddress, ClientSubnet, AddrType, RttMs, LatencyMs, Protocol, Transport, ConnectedVia, LaunchedVia, WorkspaceAppVersion, ClientPlatform, Lat_<Pole>…`

- `RttMs` to ICA RTT. `LatencyMs` to **główne pole opóźnienia** („network latency”; domyślnie `IcaLatency`, zmieniane przez `-LatencyField`). Puste, gdy próbka nie ma wartości.
- `Lat_<Pole>` (np. `Lat_WanLatency`) to pozostałe pola opóźnienia, jeśli tenant je ma. Zapisywane do ręcznego porównania.

- `TransactionId` to identyfikator, po którym znajdziesz sesję w Director / Session Launch Diagnostics. (Jeśli tenant go nie udostępnia, kolumna nazywa się `SessionKey` i zawiera GUID sesji.)
- `ConnectedVia` to host bramki/PoP Gateway Service, przez który klient się łączył. `LaunchedVia` to host StoreFront/Workspace.
- `AddrType`: `public`, `private` (adres z sieci wewnętrznej, często VPN/LAN) lub `cgnat`.
- `ClientSubnet`: /24 dla IPv4, /48 dla IPv6.
- `Transport`: pokazuje wartość pola transportu, jeśli tenant je ma (np. `IsUdpTransport=False`). Puste, jeśli nie.

Bez `-Anonymous` pliki zawierają dodatkowo **nazwiska użytkowników** (kolumna `User`). Używaj trybu anonimowego.

## 7. Zbieranie przez cały dzień: `-Loop`

Dane per sesja są dostępne tylko około godziny, więc do rzetelnej analizy trzeba je zbierać cyklicznie:

```powershell
.\Get-IcaRttBreakdown.ps1 -Anonymous -Loop -DurationHours 10 -IntervalMinutes 30
```

- Co 30 minut pobiera próbki (okno pobierania to większa z wartości: `-Hours` lub dwukrotność interwału), dopisuje bez duplikatów, a po zakończeniu analizuje cały plik.
- Okno PowerShell musi pozostać otwarte, a komputer włączony (bez uśpienia).
- **Token:** opcja 1 (SDK): według dokumentacji Citrix SDK odnawia token do 12 godzin. Opcja 3: skrypt sam odnawia. Opcja 2 (wklejony token): wystarczy tylko na ok. godzinę, więc do `-Loop` jej nie używaj.
- Przerwanie: <kbd>Ctrl</kbd>+<kbd>C</kbd>. Dane zebrane do tej pory są w pliku.
- Dobry plan: jeden pełny dzień roboczy, w którym użytkownicy zgłaszają problemy.

### Analiza bez nowego zbierania

Plik próbek jest analizowany za każdym razem w całości. Chcąc tylko ponownie przeliczyć (np. z innym progiem), uruchom z minimalnym oknem pobierania:

```powershell
.\Get-IcaRttBreakdown.ps1 -Anonymous -Hours 0.01 -ThresholdMs 120
```

(To nadal wymaga logowania, bo skrypt i tak wykona jedno małe pobranie.)

## 8. Plik `geo.csv` (kraj klienta)

Potrzebny w trybie `-Anonymous`, jeśli tenant sam nie podaje kraju. Format: nagłówek i trzy kolumny, **zakresy IPv4 rozłączne**:

```csv
Network,Country,Location
85.10.0.0/16,DE,Frankfurt
91.200.0.0/16,PL,Warszawa
10.20.0.0/16,PL,Biuro Gdańsk (VPN)
```

- Działa wyłącznie offline. Adresy IPv6 dostają `unknown`.
- Zakresy nakładające się na siebie powodują ostrzeżenie. Adresy spoza węższego zakresu trafią wtedy do `unknown`.
- Najprostszy start: wpisz własne znane zakresy (biura, VPN, główne sieci użytkowników). Pełną bazę możesz zbudować z publicznych danych, np. GeoLite2 (wymaga konta MaxMind i licencji). Bez `-GeoCsv` kolumna `Country` ma wartość `unknown`, ale podsieci nadal są dostępne.

## 9. Parametry

| Parametr | Domyślnie | Opis |
|---|---|---|
| `-Discover` | – | Tylko opis pól tenanta, bez zapisu danych. |
| `-Anonymous` | wył. | Bez nazwisk użytkowników. Zostaje Transaction ID, kraj, maszyna, IP i dane techniczne. |
| `-GeoCsv <plik>` | – | Offline tabela CIDR→kraj (tylko z `-Anonymous`). |
| `-ThresholdMs` | 150 | Sesja jest „zła”, gdy jej **mediana** ICA RTT przekracza tę wartość. |
| `-Hours` | 1 | Okno pobierania (godziny wstecz). |
| `-Loop` | wył. | Powtarzaj pobieranie. |
| `-IntervalMinutes` | 30 | Odstęp w pętli. |
| `-DurationHours` | 24 | Czas trwania pętli. |
| `-RawStore <plik>` | `rtt_samples[_anon].csv` | Plik z próbkami. |
| `-OutCsv <plik>` | `rtt_breakdown[_anon].csv` | Plik z rozbiciem. |
| `-MinSessions` | 5 | Ukryj grupy mniejsze niż tyle sesji (filtr szumu). |
| `-LatencyField <pole>` | auto | Które pole opóźnienia `SessionMetrics` jest „network latency” w porównaniu z ICA RTT. Kandydatów pokaże `-Discover`. Domyślnie: pole `Network*Latency*`, w przeciwnym razie `IcaLatency`. |
| `-LatencyThresholdMs` | = `-ThresholdMs` | Sesja ma „wysokie opóźnienie”, gdy mediana opóźnienia przekracza tę wartość. Opóźnienie jest składnikiem RTT i zwykle niższe, więc wypróbuj też niższą wartość (np. 100). |
| `-AnonymizeUsers` | wył. | Bez `-Anonymous`: zamień nazwiska na skrót (`u_xxxxxxxx`). To tylko pseudonimizacja. |
| `-ApiHost` | `api.cloud.com` | Region: `api.citrixcloud.jp` (Japonia), `api.cloud.us` (US Gov), `api-eu.cloud.com` (spróbuj, jeśli UE odrzuca domyślny). |
| `-PageSize` / `-MaxPages` | 100 / 300 | Stronicowanie. Przy ostrzeżeniu „Stopped after N pages” zmniejsz `-Hours` lub zwiększ `-MaxPages`. |
| `-ConnectionNav` | auto | Awaryjnie: nazwa właściwości nawigacyjnej od sesji do połączenia (np. `CurrentConnection`). |
| `-TransportFields` | auto | Awaryjnie: nazwy pól niosących transport EDT/TCP, gdy autowykrywanie ich nie znajdzie. |
| `-Credential` | – | Tylko do uruchomień bez kreatora: `PSCredential` (Client ID jako użytkownik, Secret jako hasło). |
| `-CustomerId` | – | Pomija pytanie o Customer ID w kreatorze. |

## 10. Jak czytać wyniki

### Przegląd (Overview)

- **Sessions / Bad sessions**: liczba sesji i odsetek tych z medianą RTT powyżej progu. Porównuj z nim odsetki w grupach.
- **Anonimowy tryb nie pokazuje „powtarzających się użytkowników”**, bo nie zna nazwisk.

### ICA RTT a opóźnienie (Network Latency)

Gdy dane zawierają opóźnienie, przegląd ma blok **„ICA RTT vs <pole>”**:

- ile sesji ma dane o opóźnieniu, mediany RTT i opóźnienia oraz **różnicę** (RTT minus opóźnienie),
- **korelację** mediany RTT i opóźnienia sesji (1 = rosną razem, 0 = niezależne),
- **tabelę 2×2** (RTT wysokie/niskie × opóźnienie wysokie/niskie) z progami `-ThresholdMs` i `-LatencyThresholdMs`.

| Pole tabeli 2×2 | Znaczenie |
|---|---|
| RTT wysokie **i** opóźnienie wysokie | Opóźnienie leży głównie w ścieżce do klienta (strona sieci). |
| RTT wysokie, opóźnienie OK | RTT zawiera więcej niż zmierzone opóźnienie: sprawdź stronę VDA / sesji (CPU, grafika, profil/logowanie, input delay). |
| RTT OK, opóźnienie wysokie | Opóźnienie podwyższone, ale sesja działa; zwykle nie priorytet. |

W **tabelach wymiarów** obok kolumn RTT są: `MedianLatency` (mediana opóźnienia grupy), `LatBadPct` (odsetek sesji z wysokim opóźnieniem wśród sesji mających dane o opóźnieniu) i `MedianGap` (mediana różnicy RTT − opóźnienie). Grupa z wysokim `BadPct` **i** wysokim `LatBadPct` wskazuje na ścieżkę (sieć); wysoki `BadPct` przy niskim `LatBadPct` i dużej różnicy wskazuje na stronę VDA / sesji.

**Zastrzeżenia (ważne):**
- Model Monitor nie ma w `SessionMetrics` pola dosłownie zwanego „Network Latency”. Domyślne `IcaLatency` to „ICA session latency” i według źródeł społecznościowych może zawierać też opóźnienie po stronie hosta. Sprawdź `-Discover` i w razie potrzeby użyj `-LatencyField`.
- RTT i opóźnienie są próbkowane w różnych odstępach, więc pojedyncza para wartości może się nie zgadzać; skrypt porównuje mediany sesji.
- Jeśli prawie wszystkie próbki opóźnienia to 0, skrypt ostrzeże, że pole prawdopodobnie nie jest wypełniane (porównanie traci sens).
- Wynik jest wskazówką, nie pomiarem czystej sieci.

### Tabele wymiarów

Każda tabela pokazuje: `Value` (grupa), `Count` (liczba sesji), `Bad` (ile złych), `BadPct` (odsetek), `MedianRtt`, `P95Rtt` oraz (gdy są dane o opóźnieniu) `MedianLatency`, `LatBadPct`, `MedianGap`.
**Porównuj `BadPct` między grupami, nie liczby bezwzględne** (duża grupa zawsze ma więcej złych sesji w liczbach).

| Tabela | Na co patrzeć | Co to sugeruje |
|---|---|---|
| **Transport** | Czy złe sesje są głównie na TCP (np. `IsUdpTransport=False`) | EDT/UDP nie działa na tej ścieżce. Sprawdź UDP 443 do `*.nssvc.net` na Azure Firewall (inspekcja, blokada) oraz czy Session Reliability i polityka Adaptive Transport są włączone. |
| **ConnectedVia** | Jeden PoP z wyraźnie wyższym `BadPct` niż reszta | Problem w trasie do tego PoP albo u dostawców, którzy tam trafiają. Porównaj z `Country` i `ClientSubnet`. |
| **Country / Location** | Kraj lub lokalizacja z wysokim `BadPct` | Łącze, ISP lub VPN w tym miejscu. Zestaw z `ConnectedVia`, żeby sprawdzić, czy kraj trafia do „złego” PoP. |
| **ClientSubnet** | Kilka podsieci z `BadPct` znacznie ponad resztę | Konkretny ISP, biuro lub VPN. Sprawdź ręcznie, do kogo należy podsieć. |
| **AddrType** | `private` ma dużo wyższy `BadPct` niż `public` | Ruch przez sieć wewnętrzną/VPN. Citrix powinien iść poza tunelem VPN (split-tunnel). |
| **WorkspaceAppVersion** | Starsza wersja z wyższym `BadPct` | Stary klient gorzej negocjuje EDT lub ma znane błędy. Zaplanuj aktualizację. |
| **DeliveryGroup / Machine** | Wszystkie grupy podobne | Nie jest to problem maszyn ani obrazów (zgodnie z obserwacją, że problem dotyka różnych generacji). Jeśli jedna maszyna odstaje, sprawdź ją osobno. |
| **HourLocal** | Szczyty o stałych porach | Przeciążenie wspólnego zasobu. Płaski wykres sugeruje stałą przyczynę (konfiguracja, trasa). |

**Płaskie `BadPct` we wszystkich wymiarach** oznacza, że problem nie wiąże się z żadną cechą widoczną w danych. Wtedy zbieraj dłużej (`-Loop`) i przejdź do sprawdzenia ścieżki na Azure Firewall (logi UDP 443, SNAT, inspekcja TLS) oraz do testu A/B z maszyną omijającą firewall.

**Małe grupy są szumem.** Ignoruj grupy z kilkoma sesjami. Zwiększ `-MinSessions`, jeśli tabele są zaśmiecone.

### Weryfikacja pojedynczej sesji

Weź `TransactionId` z pliku i znajdź sesję w Citrix Monitor / Director (Session Launch Diagnostics). Tam zobaczysz protokół (UDP/TCP), etapy uruchomienia i użytkownika, jeśli potrzebujesz go zidentyfikować.

## 11. Dane osobowe i sprzątanie

- Pliki z `-Anonymous` nie zawierają nazwisk, ale **zawierają nazwy maszyn i adresy IP klientów**. Mogą wskazywać osobę (VDI przypisane do jednej osoby, domowy IP). Traktuj je jak dane osobowe: trzymaj w kontrolowanym miejscu, nie wysyłaj mailem.
- Po zakończeniu analizy:
  1. usuń pliki CSV z maszyny (`rtt_samples*.csv`, `rtt_breakdown*.csv`),
  2. jeśli używałeś klienta API (opcje 2 i 3), usuń go w Citrix Cloud (Identity and Access Management → API Access → Service principals) lub zrotuj Secret,
  3. wyczyść schowek, jeśli wklejałeś token (`Set-Clipboard -Value ' '`, a historię `Win`+`V` wyczyść ręcznie).

## 12. Problemy i rozwiązania

| Objaw | Co zrobić |
|---|---|
| `...cannot be loaded because running scripts is disabled` | `Unblock-File` i `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (sekcja 2). |
| Opcja 1: „SDK is not installed” / „commands were not found” | Zainstaluj SDK (`JAK_POBRAC_TOKEN.md`) i uruchom w `powershell.exe`, albo użyj opcji 2 / 3. |
| Opcja 1: „no bearer token was found” | Zaloguj się ponownie albo użyj opcji 2 / 3 i zgłoś wersję SDK. |
| Pobranie tokena: HTTP 400 / 401 | Najczęściej: jako Customer ID wpisano Org ID albo Client ID (ma być CCID). Poza tym zły Client ID lub Secret albo spacja z kopiowania. W razie potrzeby utwórz nowego klienta. |
| Dane: HTTP 401 | Token wygasł. Uruchom ponownie. |
| Dane: HTTP 403 | Konto/klient nie ma dostępu do Monitor/DaaS (rola Read Only Administrator). |
| Dane: HTTP 400, „`$expand` path which is too deep ... maximum depth allowed is 2” | Starsza wersja skryptu (zagnieżdżone `$expand`). Użyj bieżącej wersji; doraźnie w starym pliku zmień `{ $dgNav = $true }` na `{ $dgNav = $false }` (kolumna `DeliveryGroup` zostanie wtedy pusta). |
| Dane: HTTP 400 | Pole nazywa się inaczej w tym tenancie. Komunikat wskaże pole. Uruchom `-Discover` i użyj `-ConnectionNav` / `-TransportFields`. |
| Zero próbek | Okno za krótkie albo nikt nie jest zalogowany. Dane per sesja trzymane są ok. godzinę. Zbieraj w godzinach pracy. |
| „Stopped after N pages” | Za dużo danych na jedno pobranie: zmniejsz `-Hours` lub zwiększ `-MaxPages`. |
| `Country` = `unknown` | Brak pola kraju w tenancie i brak/niepasujący `-GeoCsv` (sekcja 8). |
| Błąd o istniejącym pliku z nazwiskami | Plik próbek z innego trybu: wskaż nowy `-RawStore` albo usuń stary. |
| `The columns of … differ from the columns this run produces` | Inny `-LatencyField` (zmienia kolumny `Lat_<Pole>`) albo starsza wersja skryptu: użyj nowego `-RawStore`. |
| `SessionMetrics has no latency field '…'` | Błędny `-LatencyField`: komunikat wypisze kandydatów (patrz też `-Discover`). |
| „Latency: no latency values in the data” | Tenant nie ma pola opóźnienia albo jest puste (np. starsze VDA): porównania nie będzie. |
| „N% of the latency samples are 0” | Pole opóźnienia prawdopodobnie nie jest wypełniane: porównanie nie ma sensu, spróbuj innego `-LatencyField`. |
| Ostrzeżenie o nakładających się zakresach w `geo.csv` | Popraw zakresy, aby były rozłączne. |
| „-GeoCsv file not found … continuing without it” | Tylko ostrzeżenie: zła ścieżka albo brak pliku. Niepotrzebne, jeśli tenant sam podaje kraj. |

## 13. Zalecany plan działania

1. `-Discover` (sekcja 4). Zapisz, czego brakuje (transport, kraj, Transaction ID).
2. Pojedyncze uruchomienie w godzinach pracy (sekcja 6). Sprawdź, czy dane wyglądają sensownie.
3. `-Loop` przez jeden dzień roboczy (sekcja 7).
4. Przejrzyj wyniki (sekcja 10). Najpierw blok **ICA RTT a opóźnienie** (czy wysokie RTT idzie w parze z wysokim opóźnieniem), potem tabele: **Transport**, **ConnectedVia**, **Country**, **ClientSubnet**, **AddrType**.
5. Potwierdź hipotezę na pojedynczych sesjach w Director (Transaction ID).
6. Sprzątanie (sekcja 11).

## 14. Ograniczenia, o których warto pamiętać

- Skrypt nie był jeszcze uruchomiony na prawdziwym tenancie. Nazwy pól odczytuje z `$metadata`, więc powinien się dopasować, ale pierwszy przebieg traktuj jako próbę.
- Czy tenant udostępnia wskaźnik EDT/TCP, nie jest pewne. Rozstrzygnie `-Discover`.
- Logowanie oknem (opcja 1) zależy od zachowania SDK Citrix (nazwy cmdletu i zmiennej z tokenem różnią się między wersjami dokumentacji). Skrypt sprawdza obie. Obsługa SSO/MFA w tym oknie nie jest potwierdzona w dokumentacji.
- Dane per sesja są dostępne krótko. Bez `-Loop` zobaczysz tylko ostatnią godzinę.
- **„Network Latency” z Director nie musi być tym samym co `IcaLatency`.** Model danych ma kilka pól opóźnienia o różnym znaczeniu (sesja ICA, WAN/DC z NetScaler lub SD-WAN). Skrypt zbiera wszystkie i porównuje z RTT to, które wskażesz (`-LatencyField`).
- Skrypt wskazuje korelacje, a nie dowody przyczyny. Wynik „TCP vs RTT” potwierdza objaw, a przyczynę (np. blokada UDP 443 na firewallu) trzeba sprawdzić osobno w logach Azure Firewall i konfiguracji.
