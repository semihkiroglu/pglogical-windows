# Sürümleme ve otomasyon

Bu dosya, Windows x64 pglogical paketlerinin nasıl keşfedildiğini, üretildiğini,
yayınlandığını ve uyumluluk hatalarının nasıl ele alındığını tanımlar. Kaynak
kodun derlenmesi yalnızca yeni pglogical upstream sürümü veya açıkça gerekçeli
hedefli uyumluluk yeniden derlemesi için yapılır.

## Sürüm kaynakları ve karar sınırları

- pglogical upstream sürümü ve tag'i `2ndQuadrant/pglogical` içindeki yayımlanmış
  sürümden gelir.
- PostgreSQL güncel minor sürümü `https://www.postgresql.org/versions.json`
  içindeki `latestMinor` alanından gelir.
- EDB Windows x64 binaries arşivinin packaging revision değeri, resmi EDB
  indirme host'unda kontrollü erişilebilirlik yoklamasıyla bulunur. Bu bir EDB
  manifestosu değil, heuristik bir erişilebilirlik keşfidir.
- `.github/pg-versions.json` yalnızca yapılandırılmış PostgreSQL major kümesini
  ve minimum pglogical sürümünü tutar.
- Upstream kaynak tag'indeki `compat<major>` dizini, o major için derleme
  yapılabilirliğinin ön koşuludur.

Üç karar birbirinden ayrıdır:

1. **Normal upstream yayınlama:** Yeni pglogical sürümünde eksik major paketleri
   `windows.1` olarak üretir.
2. **Uyumluluk smoke:** Yayınlanmış paketi, aynı major'ın güncel EDB artifact'ı
   üzerinde çalıştırır. Bu yol kaynak checkout'u veya derleme yapmaz.
3. **Hedefli yeniden derleme:** Smoke yalnızca paket eski EDB artifact'ı ile
   derlenmiş ve hata uyumluluk sınıfındaysa, etkilenen major için en yüksek
   mevcut `windows.N + 1` planını üretir.

PostgreSQL minor veya EDB revision değişimi tek başına normal yayınlama nedeni
 değildir. Aynı major için yayımlanmış paket varsa normal watcher bunu kapsanmış
sayarak EDB artifact çözümlemesini o major için hiç yapmaz.

## PostgreSQL major matrisi

`pg-versions-sync.yml` her gün 03:00 UTC'de ve elle çalıştırılabilir olarak
çalışır:

1. pg.org `versions.json` verisini doğrular.
2. `supported=false` olan yapılandırılmış major'ları çıkarır.
3. Yeni major için resmi EDB artifact'ının erişilebilirliğini doğrular.
4. Güncel upstream release kaynağını shallow clone ederek `compat<major>` dizinini
   doğrular.
5. Yalnızca pg.org tarafından desteklenen, EDB artifact'ı bulunan ve upstream'de
   compat dizini bulunan yeni major'ı matrise eklemeye aday yapar.
6. Gerçek config değişikliği varsa PR açar; boş veya belirsiz matrisi yazmaz.

`.github/pg-versions.json` değişikliği merge edildiğinde
`upstream-watch.yml` ayrıca `push.paths` tetikleyicisiyle çalışır. Böylece yeni
major için bir sonraki günlük bekleme gerekmez.

## EDB artifact çözümleme

Aday adı şu biçimdedir:

```text
postgresql-<major>.<minor>-<revision>-windows-x64-binaries.zip
```

Resolver:

- her aday URL'sini HTTPS, `get.enterprisedb.com`, `/postgresql/` yolu ve dosya
  adı kimliğiyle doğrular;
- HEAD kullanır, yalnızca HEAD açıkça desteklenmiyorsa `Range: bytes=0-0` GET'e
  düşer;
- tüm `1..MaxRevision` aralığını yoklar; aradaki boşluklar geçerlidir;
- 404/410 veya EDB S3 `AccessDenied` imzasını kesin yokluk sayar;
- timeout, DNS/TLS/socket, 408/425/429/5xx ve belirsiz 403 yanıtlarını retry
  sonrası fail-closed olarak bırakır;
- yönlendirmeleri kabul etmez;
- en yüksek bulunan revision probe sınırına eşitse daha yüksek revision
  olabileceği için yine fail-closed davranır;
- hiçbir durumda revision `-1` varsaymaz veya daha eski artifact'a sessizce
  düşmez.

CI cache anahtarı tam artifact dosya adını içerir. İndirme sonrası hesaplanan
SHA-256 release provenance'a yazılır; EDB tarafından yayımlanmış checksum gibi
sunulmaz.

## Normal upstream watcher

`upstream-watch.yml` her gün 03:30 UTC'de ve elle çalıştırılabilir olarak
çalışır. Ayrıca `.github/pg-versions.json` merge edildiğinde tetiklenir.

Watcher:

1. `GET /repos/2ndQuadrant/pglogical/releases/latest` ile tek yayımlanmış
   upstream release'i alır. Draft veya prerelease yoksa 404 sonucu sessiz no-op'tur.
2. Tag'i `^REL[0-9]+_[0-9]+_[0-9]+$` ile doğrular ve baseline altındaki sürümü
   reddeder.
3. Exact upstream commit SHA'sını çözer ve kaynak checkout'unda doğrular.
4. Configured major ile upstream `compat<major>` kesişimini hesaplar.
5. Yerel stable release'leri listeler ve her compatible major için coverage'ı
   tag kimliğiyle (`pglogical-<version>-pg<major>-windows.<revision>`) arar.
6. Yerel coverage yoksa yalnızca o major için `windows.1` planlar.
7. Coverage bulunan major için güncel minor/revision farklı olsa bile yeni plan
   üretmez ve EDB çözümlemez.
8. Eksik major'ların exact EDB artifact'larını bir kez çözer ve tek pinned
   `release.yml` dispatch'i gönderir.

Plan girdisi; pglogical sürümü, upstream tag/SHA, PostgreSQL major/minor/build
version, Windows packaging revision, EDB packaging revision, dosya adı ve URL'yi
birlikte taşır. `release.yml` bu planı doğrulamadan hiçbir Windows build'i
başlatmaz ve pinned URL yerine başka artifact seçmez.

## Tag ve asset biçimi

Her upstream sürümü ve PostgreSQL major için ayrı GitHub release/tag vardır:

```text
pglogical-2.4.8-pg14-windows.1
pglogical-2.4.8-pg18-windows.1
```

- `2.4.8`: upstream pglogical sürümü;
- `pg18`: PostgreSQL compatibility major;
- `windows.1`: Windows packaging revision;
- yeni upstream sürümü her major için `windows.1` ile başlar;
- targeted compatibility rebuild aynı sürüm ve major için en yüksek mevcut
  revision'ın bir üstünü kullanır; eski tag veya release üzerine yazılmaz.

ZIP asset'i exact build input'ını taşır:

```text
pglogical-<version>-pg<major>.<minor>-edb<revision>-windows-x64.zip
```

Her yayımlanmış release'te tam olarak bir package ZIP ve bir `SHA256SUMS.txt`
bulunur. ZIP içinde `BUILD-INFO.json`, `lib/`, `share/extension/` ve `bin/`
gerekli dosyaları vardır.

## Release build akışı

`release.yml` reusable ve elle dispatch edilebilir bir workflow'dur.

### Resolve

- `planJson` verilmişse bütün plan girdilerini doğrular;
- upstream tag/SHA, major/minor/build version, revision ve EDB URL/dosya adı
  tutarlılığını kontrol eder;
- pinned EDB URL'nin hâlâ erişilebilir olduğunu doğrular, fakat yeni artifact
  keşfetmez;
- `planJson` yoksa elle verilen upstream tag için configured major ∩ upstream
  compat kümesini ve exact EDB artifact'larını çözer.

### Windows build ve smoke

Her plan girdisi için:

1. exact EDB binaries ZIP'i indirir veya tam kimlik eşleşiyorsa cache'ten kullanır;
2. upstream tag'ini shallow clone eder ve commit SHA'sını doğrular;
3. CMake + MSVC/clang-cl ile derler;
4. export yüzeyini ve bağımsız subscriber utility'yi doğrular;
5. gerçek PostgreSQL cluster'ında extension, logical slot ve provider→subscriber
   smoke testini çalıştırır;
6. exact-name package ZIP'i ve checksum satırını üretir;
7. `BUILD-INFO.json` içine kaynak ve artifact provenance'ını yazar.

### Publish

Tüm Windows matrix işleri başarılı olmadan publish başlamaz. Publish job'ı:

- ZIP sayısını/adını ve checksum'ı yeniden doğrular;
- release'i doğrudan yayımlanmış olarak, immutable asset'lerle oluşturur;
- upstream tag/SHA, compatibility major, exact build version, EDB artifact ve
  hesaplanan checksum provenance'ını release body'ye koyar;
- publish sonrası release ve asset'leri okuyarak doğrular;
- GitHub Latest değerini configured major'lar arasından deterministik olarak
  seçer.

Mevcut release veya asset hiçbir zaman overwrite edilmez.

## Compatibility smoke

`compatibility-smoke.yml` her gün 04:30 UTC'de veya elle çalıştırılabilir.
`force=true` verilirse coverage bulunan paketleri de test eder; rebuild kuralını
değiştirmez.

Discover job'ı her configured major için güncel exact EDB artifact'ını bulur ve
en yeni published local release'i seçer:

- local release yoksa `pending`;
- release body'deki EDB artifact dosya adı güncel artifact ile aynıysa `covered`;
- farklıysa `test`;
- body/asset provenance eksikse `test` + `metadata` failure class.

Windows smoke job'ı yalnızca `test` girdilerinde çalışır. Published release'i
tag ile bulur, tam bir ZIP ve `SHA256SUMS.txt` indirir, ZIP checksum'ını
kontrol eder, path traversal'ı reddeder, izole staging'e çıkarır ve
`BUILD-INFO.json` kimliğini tag/major/asset ile karşılaştırır. Sonra mevcut EDB
kurulumu üzerinde `Test-PgLogical.ps1` çalışır. Bu workflow'da upstream source
checkout'u, `Build-PgLogical.ps1` veya herhangi bir source compilation yoktur.

Sonuçlar şu sınıflardan biriyle raporlanır:

- `download`: release/API/EDB/package indirme problemi;
- `metadata`: ZIP, checksum, asset veya provenance problemi;
- `compatibility`: aynı kurulumda extension/smoke davranışı problemi;
- `environment`: runner, PostgreSQL başlatma veya izin problemi.

## Targeted rebuild ve loop guard

Yalnızca `status=failed` ve `failureClass=compatibility` sonucu targeted rebuild'e
adaydır. Karar wrapper'ı:

- eski package artifact'ı ile current server artifact'ını karşılaştırır;
- current artifact daha yeniyse yalnızca etkilenen major için en yüksek mevcut
  `windows.N + 1` planını oluşturur;
- aynı artifact ile smoke başarısızsa otomatik rebuild oluşturmaz;
- aynı deterministic marker'a sahip GitHub issue zaten varsa yeni issue açmaz;
- aynı target tag release listesinde veya çalışan/queued release workflow'unda
  varsa yeni dispatch yapmaz;
- başka failure class'larını rebuild'e dönüştürmez;
- artifact kimliği geriye gidiyorsa fail-closed olur.

Targeted dispatch `release.yml`'e tam pinned `planJson` ve
`rebuildMarker` input'uyla yapılır. Dispatch sonrası run adı marker ile okunarak
etkinin gerçekten oluştuğu doğrulanır. Aynı artifact smoke hatası issue body'sine
şu tür deterministic marker koyar:

```text
<!-- pglogical-compatibility-failure: pg18/<package-tag>/<artifact-filename> -->
```

## Manuel komutlar

Normal release planını görmek için:

```powershell
pwsh ./scripts/Get-UpstreamReleases.ps1 -OutputFile .build/release-plan.json
```

Published release paketini doğrulamak için:

```powershell
pwsh ./scripts/Install-PgLogicalReleasePackage.ps1 `
  -ReleaseTag pglogical-2.4.8-pg18-windows.1 `
  -PostgresqlMajor 18 `
  -Repository semihkiroglu/pglogical-windows `
  -OutputDir .build/compat-package
```

Release workflow'u elle tetiklemek için:

```bash
gh workflow run release.yml -f upstreamTag=REL2_4_8 -f dryRun=true
gh workflow run release.yml -f planJson='[{"pglogicalVersion":"2.4.8", "...":"pinned entry"}]'
```

Compatibility smoke'u zorlamak için:

```bash
gh workflow run compatibility-smoke.yml -f force=true
```

## Arıza davranışı

- API, EDB veya checksum belirsizliği: fail-closed; daha eski artifact'a düşülmez.
- Windows smoke environment/download hatası: targeted rebuild dispatch edilmez.
- Aynı artifact compatibility hatası: duplicate-safe issue açılır, rebuild yoktur.
- Daha yeni artifact compatibility hatası: yalnızca etkilenen major için
  `windows.N+1` pinned dispatch yapılır.
- Release build/publish hatası: başarısız run issue raporlar; yayımlanmış
  release ve asset mutasyonu yapılmaz.
- Config PR'si mevcutsa ikinci otomatik config PR'si açılmaz.

## Değişmezlik ve provenance

Published release'ler ve asset'ler immutable kabul edilir. Her package'ın
`BUILD-INFO.json` dosyası şunları kaydeder:

- pglogical sürümü ve upstream repository/tag/commit SHA'sı;
- PostgreSQL compatibility major ve exact build version;
- EDB packaging revision, artifact dosya adı/URL'si ve proje tarafından
  download sonrası hesaplanan SHA-256;
- Windows packaging revision, mimari ve configuration.

Bu proje resmi PostgreSQL, EDB veya upstream pglogical dağıtımı değildir.
