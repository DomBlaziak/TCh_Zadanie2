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

Stosowanie :latest to zła praktyka na produkcji, ponieważ nie wiemy, która dokładnie wersja kodu jest aktualnie uruchomiona, a serwery mogą mieć problem z pobraniem nowych zmian przez lokalną pamięć podręczną. Warto dodać, że taka dwupoziomowa polityka (SHA dla deweloperów, SemVer dla produkcji) to bezpośrednia realizacja oficjalnego standardu OCI (Open Container Initiative) oraz metodologii 12-Factor App (zasada rozdzielania etapów budowania i wydań). Dzięki temu cały cykl życia aplikacji staje się w pełni bezpieczny, a każda zmiana w kodzie ma swój unikalny, łatwy do namierzenia ślad.

---

##  3. Optymalizacja pamięci podręcznej (Cache MAX)

Żeby maksymalnie skrócić czas budowania obrazów na różne architektury (co normalnie trwa długo przez emulacja sprzętową), 
potok używa DockerHuba (dblaziak/repozytorium_1) jako miejsca do przechowywania pamięci podręcznej.

*   **Format:** `type=registry`
*   **Lokalizacja:** Dedykowany tag `:cache` na DockerHub.
*   **Tryb:** `mode=max` – BuildKit zapisuje pliki tymczasowe i warstwy pośrednie dla wszystkich etapów z Dockerfile (w tym pobrane paczki `node_modules`).

Dzięki temu krok instalacji pakietów i kompilacji jest pomijany przy kolejnych uruchomieniach potoku. Skraca to czas budowania 
z kilku minut do zaledwie kilkudziesięciu sekund, a rejestr produkcyjny GHCR pozostaje czysty.

W przeciwieństwie do obrazu aplikacji, tag :cache celowo nie jest niezmienny. Każdy kolejny udany build nadpisuje ten tag nowym stanem warstw. Gdybyśmy robili unikalne tagi dla cache, szybko skończyłoby się miejsce na DockerHubie, a potok nie potrafiłby automatycznie odnaleźć bazy do pobrania warstw. Stały tag :cache gwarantuje, że potok zawsze odpytuje o najświeższy, skumulowany stan projektu. Taki ruch pozwala na ciągłe aktualizowanie bazy plików tymczasowych (np. przy dodaniu nowej paczki w package.json) bez generowania śmieciowych, archiwalnych plików na koncie DockerHub.

---

##  4. Bramka bezpieczeństwa CVE (Wdrożenie skanera Trivy)

W roli automatycznej bramki bezpieczeństwa wdrożono skaner **Trivy** od firmy Aqua Security.

### Konfiguracja Bramki:
*   **exit-code: 1** – Wykrycie błędów o statusie HIGH lub CRITICAL natychmiast przerywa działanie potoku i blokuje wrzucenie obrazu do sieci.
*   **ignore-unfixed: true** – Ta opcja pomija luki, dla których twórcy oprogramowania nie wydali jeszcze oficjalnych poprawek.
*   **format: 'table'** – Wyniki skanowania są wyświetlane w czytelnej tabeli bezpośrednio w logach potoku na GitHubie.

### Uzasadnienie wykorzystania:
1.  **Unikanie fałszywych alarmów:** Skanowanie małych systemów (jak Alpine) często wykrywa błędy systemowe, na które deweloper nie ma wpływu. Ignorowanie podatności bez gotowych poprawek chroni potok przed bezsensownym blokowaniem pracy.
2.  **Skupienie na działaniu:** Bramka koncentruje się tylko na tych lukach, które możemy sami naprawić (np. przez aktualizację bibliotek w pliku `package.json` albo zmianę obrazu bazowego).
3.  **Niezawodność:** Trivy jest prosty w konfiguracji i działa stabilniej w GitHub Actions niż Docker Scout.

---

## 5. Podsumowanie wdrożenia i weryfikacja działania

Poprawność działania całego potoku CI/CD została w pełni potwierdzona testami.

### Etapy weryfikacji:

1. **Ręczne uruchomienie potoku z poziomu terminala za pomocą GitHub CLI:**
   ``` bash 
   gh workflow run ci-package.yml --ref master 
   ```
   Potok zakończył się sukcesem (status: success), co potwierdza, że obraz pomyślnie przeszedł przez skaner Trivy.

   Uwaga: Aby ta komenda oraz kolejne kroki zadziałały, należy najpierw wejść w terminalu do głównego folderu z plikami naszego projektu.

2. **Automatyczne uruchomienie potoku przez nadanie tagu wersji (SemVer):**
  ``` bash
  git tag v1.0.0
  git push origin v1.0.0
  ```
  Wypchnięcie tagu do repozytorium automatycznie uruchomiło proces budowania i nadało oficjalną sygnaturę produkcyjną v1.0.0 z priorytetem ważności 200.
  
3. **Oficjalna publikacja:**
   System poprawnie rozdzielił zadania. Pamięć podręczna (cache) trafiła na DockerHuba, a sprawdzony i bezpieczny obraz aplikacji został wysłany do GitHub Container Registry (ghcr.io).

4. **Ostateczny test pobrania obrazu:**
   Pomyślnie sprawdzono pobieranie gotowego kontenera z chmury na lokalny komputer za pomocą unikalnego tagu SHA:
   ``` bash
   docker pull ghcr.io/domblaziak/tch_zadanie2:sha-a4058d2
   ```

Wdrożone rozwiązanie w pełni realizuje zasady DevSecOps – gwarantuje automatyzację, szybkie budowanie, bezpieczne wersjonowanie kodu oraz stałą kontrolę bezpieczeństwa aplikacji.