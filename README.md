# Zadanie 2: Wielopoziomowy potok CI/CD 
### Integracja rejestrów zewnętrznych oraz bramka bezpieczeństwa CVE

##  1. Architektura i przebieg potoku CI/CD

Wdrożony potok automatyzacji w pliku `.github/workflows/ci-package.yml` został zaprojektowany z zachowaniem najwyższych standardów bezpieczeństwa chmurowego. Proces opiera się na architekturze zdarzeniowej platformy **GitHub Actions** i realizuje następujące etapy przetwarzania (krok po kroku):

### Schemat przepływu danych
```text
[ Kod źródłowy ]
      │
      ▼
[ 1. Checkout ] ──► [ 2. QEMU ] ──► [ 3. Buildx ]
      │
      ▼
[ 4. Logowanie ] (GHCR & DockerHub)
      │
      ▼
[ 5. Metadane ] (SemVer / SHA)
      │
      ▼
[ 6. Test Build (Local) ]
      │
      ▼
[ 7. Skaner Trivy ] ──► (Wykryto HIGH/CRITICAL?) ──► [ STOP / Exit 1 ]
      │
    [ NIE ]
      │
      ▼
[ 8. Multi-arch Build ] (AMD64/ARM64 + Cache MAX)
      │
      ▼
[ 9. Push GHCR ]
```

### Szczegółowy opis kroków:

*   **Pobranie kodu źródłowego (`actions/checkout@v4`)**: Klonowanie zawartości repozytorium do tymczasowego katalogu roboczego runnera.
*   **Emulacja sprzętowa QEMU (`docker/setup-qemu-action@v3`)**: Instalacja emulatorów pozwalających na bezproblemowe budowanie obrazów dla architektur nie-natywnych (ARM64) na maszynach wirtualnych x86_64.
*   **Konfiguracja środowiska Buildx (`docker/setup-buildx-action@v3`)**: Aktywacja silnika BuildKit, obsługującego zaawansowane mechanizmy cache-owania.
*   **Logowanie do rejestrów (`docker/login-action@v3`)**: Autoryzacja w GHCR (używając `GITHUB_TOKEN`) oraz w DockerHubie (używając bezpiecznych sekretów).
*   **Ekstrakcja metadanych (`docker/metadata-action@v5`)**: Automatyczne generowanie etykiet i tagów. 
    *    Krok ten wymusza małe litery w nazwie repozytorium, zapobiegając błędom rejestru `ghcr.io`.
*   **Lokalne budowanie testowe**: Kompilacja obrazu pod tagiem `test-cve:latest` bez wypychania do sieci w celu weryfikacji bezpieczeństwa. Wykorzystanie flagi load: true oraz push: false pozwala na przeskanowanie kontenera bez obciążania sieci transferem niesprawdzonego obrazu.
*   **Skanowanie podatności (Trivy)**: Statyczna analiza kodu i warstw OS w poszukiwaniu luk bezpieczeństwa (CVE).
*   **Kompilacja wieloarchitekturowa i dystrybucja**: Silnik BuildKit kompiluje obrazy dla `linux/amd64` oraz `linux/arm64`, łączy je w jeden manifest i przesyła do GHCR.

---

##  2. Strategia tagowania i zasada Immutability

Wdrożony potok realizuje rygorystyczną, dwupoziomową strategię tagowania z przypisanymi priorytetami:

1.  **Znakowanie deweloperskie (Priorytet 100)**: Generuje tag oparty o skrócony hasz SHA (np. `sha-a4058d2`) przy ręcznym uruchomieniu.
2.  **Znakowanie produkcyjne (Priorytet 200)**: Przesłanie tagu Git zgodnego z maską `v*` (np. `v1.0.0`) nadaje oficjalną sygnaturę SemVer.

Wprowadzenie **zasady niezmienności obrazów** gwarantuje, że raz opublikowany tag jednoznacznie identyfikuje konkretną migawkę kodu źródłowego i nigdy nie ulegnie nadpisaniu. Celowo zrezygnowano z automatycznego generowania tagu :latest przy każdym wdrożeniu. Stosowanie :latest jest uznawane za antywzorzec w środowiskach produkcyjnych, ponieważ uniemożliwia deterministyczne wdrażanie aplikacji (nie wiemy, która dokładnie rewizja kodu jest uruchomiona) oraz prowadzi do problemów z buforowaniem warstw na węzłach uruchomieniowych.

##  3. Optymalizacja pamięci podręcznej (Cache MAX)

W celu drastycznego skrócenia czasu kompilacji obrazów wieloarchitekturowych (które z natury wymagają emulacji sprzętowej 
i zużywają znacznie więcej zasobów), potok integruje zewnętrzny rejestr DockerHub (dblaziak/repozytorium_1) jako dedykowany, scentralizowany backend pamięci podręcznej.

*   **Format:** `type=registry`
*   **Lokalizacja:** Dedykowany tag `:cache` na DockerHub.
*   **Tryb:** `mode=max` – BuildKit zapisuje metadane i warstwy pośrednie dla wszystkich etapów zdefiniowanych w Dockerfile 
(w tym `node_modules`).

Dzięki temu etap instalacji pakietów i kompilacji jest pomijany przy kolejnych buildach, co skraca czas wykonania potoku z kilku minut do kilkudziesięciu sekund, a rejestr produkcyjny GHCR pozostaje wolny od technicznych plików tymczasowych

---

##  4. Bramka bezpieczeństwa CVE (Wdrożenie skanera Trivy)

W roli automatycznej bramki bezpieczeństwa wdrożono skaner **Trivy** od firmy Aqua Security.

### Konfiguracja Bramki:
*   Wykrycie błędów **HIGH** lub **CRITICAL** przerywa potok (`exit-code: 1`).
*   Zastosowano flagę `ignore-unfixed: true`.
*   Czytelność logów zapewnia format tabelaryczny (format: 'table') generowany bezpośrednio w konsoli runnera

### Uzasadnienie wykorzystania:
1.  **Unikanie fałszywych alarmów:** Ignorowanie podatności, dla których nie wydano oficjalnych poprawek, zapobiega paraliżowi procesu CI/CD.
2.  **Skupienie na działaniu:** Bramka koncentruje się na lukach, które deweloper może realnie wyeliminować (np. poprzez aktualizację zależności w `package.json`).
3.  **Niezawodność:** Trivy zapewnia stabilną i prostą integrację z GitHub Actions.


## 5. Podsumowanie wdrożenia i weryfikacja działania

Poprawność operacyjna zaimplementowanego łańcucha CI/CD została w pełni potwierdzona testami.

### Etapy weryfikacji:

1. **Ręczne wyzwolenie potoku z poziomu terminala za pomocą narzędzia GitHub CLI:**
   ``` bash 
   gh workflow run ci-package.yml --ref master 
   ```
   Operacja zakończyła się pełnym sukcesem systemowym (status: success), potwierdzając bezbłędne przejście przez bramkę jakościową Trivy.

2. **Oficjalna publikacja i dystrybucja:**
   System poprawnie rozdzielił role rejestrów zewnętrznych. Dane pamięci podręcznej (cache backend) zostały pomyślnie odłożone na DockerHubie, natomiast zweryfikowany, wieloarchitekturowy obraz produkcyjny trafił do rejestru GitHub Container Registry.

3. **Ostateczny test integralności:**
   Pomyślne pobranie gotowego kontenera z chmury na lokalną stację roboczą za pomocą wygenerowanego unikalnego tagu SHA:
   ``` bash
   docker pull ghcr.io/domblaziak/tch_zadanie2:sha-a4058d2
   ```
Wdrożony potok w pełni realizuje założenia paradygmatu DevSecOps, gwarantując automatyzację, powtarzalność kompilacji, niezmienność wydań oraz ciągłe monitorowanie podatności kodu.