# Windows x64 build rehberi

Bu repository'de pglogical paketleri CMake + Visual Studio/MSVC toolchain'i ile
Windows x64 için derlenir. PostgreSQL kaynak koddan derlenmez; build, resmi EDB
Windows binaries dağıtımının header ve import library'lerine karşı yapılır.

## Üretilen dosyalar

- `pglogical.dll`: ana extension modülü;
- `pglogical_output.dll`: output-plugin uyumluluk modülü;
- `pglogical_create_subscriber.exe`: subscriber kurulum aracı;
- `pglogical.control` ve `pglogical--*.sql` dosyaları;
- `pglogical_origin.control` ve `pglogical_origin--1.0.0.sql`.

Kaynak dosya ve export listesi `CMakeLists.txt` ile `cmake/exports.json` içinde
sabitlenir. Extension SQL dosyaları exact upstream checkout'undan staging'e
alınır.

## Ön koşullar

- Windows x64, Windows 10 veya üstü;
- PowerShell 7.x (`pwsh`);
- Visual Studio 2022 veya üstü;
- Visual Studio'da **Desktop development with C++** ve **C++ Clang tools for
  Windows** bileşenleri;
- `PATH` üzerinde CMake >= 3.24 ve Git;
- derlenecek major ile eşleşen resmi PostgreSQL Windows binaries kurulumu.

clang-cl, upstream pglogical'ın bazı C ön işlemci kalıplarını MSVC uyumlu
seçeneklerle kabul eder. Link işlemi MSVC linker ve PostgreSQL import
library'leriyle yapılır.

Script'ler makineye global kurulum yapmaz; geçici işler `.build/` altında,
PostgreSQL kurulumu `.pg/installs/` altında tutulur.

## PG_ROOT hazırlama

Build için şu dosyalar gerekir:

```text
include\pg_config.h
include\libpq-fe.h
include\server\postgres.h
include\server\port\win32_msvc\
include\server\port\win32\
lib\postgres.lib
lib\libpq.lib
lib\libintl.lib
```

### Mevcut kurulum

`-PgRoot` ile resmi kurulumun `C:\Program Files\PostgreSQL\18` gibi kökünü
verin.

### İzole EDB indirme

`scripts/Install-PostgreSql.ps1`,
`postgresql-<major>.<minor>-<revision>-windows-x64-binaries.zip` arşivini resmi
EDB host'undan indirir, exact major/minor/revision kimliğini doğrular ve
`<DestinationDir>\pgsql` içine açar:

```powershell
.\scripts\Install-PostgreSql.ps1 -Major 18
# => .pg\installs\pg18\pgsql
```

Minor `https://www.postgresql.org/versions.json` içinden, EDB revision ise
resmi host üzerinde bounded availability probe'u ile bulunur. Revision `-1`
varsayılmaz. Cache anahtarı tam artifact dosya adını taşır. Kurulum sonunda
`EDB-INSTALL-INFO.json` yazılır; mevcut kurulum ancak major, minor, build version,
EDB revision, dosya adı/URL ve cache SHA-256 birlikte eşleşiyorsa yeniden
kullanılır.

Deterministik yerel deneme için minor ve URL açıkça verilebilir:

```powershell
.\scripts\Install-PostgreSql.ps1 `
  -Major 18 `
  -Minor 6 `
  -BinariesUrl "https://get.enterprisedb.com/postgresql/postgresql-18.6-2-windows-x64-binaries.zip"
```

EDB binaries ZIP'leri için vendor checksum yayımlanmıyorsa script proje içi
post-download SHA-256 hesaplar; bunu vendor checksum gibi yorumlamaz.

## Tek seferlik build

Repository kökünden:

```powershell
.\scripts\Build-PgLogical.ps1 `
  -PgRoot "C:\Program Files\PostgreSQL\18" `
  -UpstreamTag "REL2_4_8" `
  -Configuration Release
```

Akış:

1. `PG_ROOT` header/import library bütünlüğünü doğrular;
2. `2ndQuadrant/pglogical` exact upstream tag'ini shallow clone eder;
3. `compat<major>` dizininin bulunduğunu kontrol eder;
4. exact upstream commit SHA'sını doğrular (SHA verilmişse);
5. `Visual Studio 17 2022`, x64 ve clang-cl ile CMake configure/build yapar;
6. DLL export yüzeyini `dumpbin` ile kontrol eder;
7. package staging dizinini döndürür.

Mevcut upstream checkout kullanılacaksa:

```powershell
.\scripts\Build-PgLogical.ps1 `
  -PgRoot "C:\Program Files\PostgreSQL\18" `
  -SourceDir "C:\src\pglogical" `
  -SkipClone `
  -ExpectedCommitSha "<40-hex-upstream-commit>"
```

## Staged build testi

`scripts/Test-PgLogical.ps1` staging'i izole PostgreSQL ağacına kurar, `initdb`,
`pg_ctl`, `CREATE EXTENSION`, `pglogical_output` logical slot, subscriber utility
ve gerçek provider→subscriber replication akışını çalıştırır:

```powershell
.\scripts\Test-PgLogical.ps1 `
  -PgRoot ".pg\installs\pg18\pgsql" `
  -StagingDir ".build\REL2_4_8\stage" `
  -UpstreamVersion "2.4.8"
```

PostgreSQL postmaster elevated administrator token altında çalışmaz. CI için
`-AllowTemporaryLocalUser` açıkça verilerek geçici düşük yetkili kullanıcı
kullanılır. Yerel elevated çalıştırmada bu izin switch'i verilmeden hesap
oluşturulmaz.

## Paketleme

Paketleme doğrulanmış bir plan girdisi ve EDB arşivinin proje tarafından
hesaplanan SHA-256 değerini alır:

```powershell
$entry = [pscustomobject]@{
  pglogicalVersion = '2.4.8'
  upstreamTag = 'REL2_4_8'
  upstreamCommitSha = '<40-hex-upstream-commit>'
  postgresqlMajor = '18'
  postgresqlMinor = '6'
  postgresqlBuildVersion = '18.6'
  windowsPackagingRevision = 1
  edbPackagingRevision = 2
  edbArtifactFilename = 'postgresql-18.6-2-windows-x64-binaries.zip'
  edbArtifactUrl = 'https://get.enterprisedb.com/postgresql/postgresql-18.6-2-windows-x64-binaries.zip'
}
.\scripts\Package-PgLogical.ps1 `
  -StagingDir ".build\REL2_4_8\stage" `
  -SourceDir ".build\REL2_4_8\upstream" `
  -PlanEntry $entry `
  -EdbArtifactCalculatedSha256 ('a' * 64) `
  -OutputDir ".build\packages"
```

Üretilen ad:

```text
pglogical-2.4.8-pg18.6-edb2-windows-x64.zip
```

ZIP kökünde `BUILD-INFO.json`, `lib/`, `share/extension/` ve `bin/` bulunur.
`BUILD-INFO.json` plan girdisinden üretilir; package aşamasında sürüm yeniden
keşfedilmez. Checksum satırı `SHA256SUMS.txt` dosyasına eklenir.

## Doğrudan CMake kullanımı

Script wrapper'ları yerine CMake doğrudan da çalıştırılabilir:

```powershell
cmake -S . -B .build\cmake `
  -G "Visual Studio 17 2022" -A x64 -T ClangCL `
  -DPG_ROOT="C:\Program Files\PostgreSQL\18" `
  -DPG_MAJOR=18 `
  -DPGLOGICAL_SOURCE_DIR=".build\REL2_4_8\upstream" `
  -DPGLOGICAL_VERSION="2.4.8"
cmake --build .build\cmake --config Release
cmake --install .build\cmake --config Release --prefix .build\stage
```

## CI davranışı

- `ci.yml`: PowerShell/static analiz, YAML/JSON kontrolleri ve PostgreSQL 18
  üzerinde gerçek Windows build + smoke testi;
- `release.yml`: pinned plan girdileriyle configured major matrix'ini derler,
  test eder, exact-name ZIP/checksum üretir ve yayımlar;
- `compatibility-smoke.yml`: yayımlanmış ZIP'i tag ile indirir, checksum ve
  provenance doğrular, güncel EDB artifact'ı üzerinde derlemesiz smoke çalıştırır;
- `upstream-watch.yml`: yalnızca yeni upstream sürümü veya eksik major coverage
  için release dispatch eder;
- `pg-versions-sync.yml`: pg.org desteği, EDB erişilebilirliği ve upstream
  `compat<major>` koşullarını izleyerek config PR'ı açar.

Compatibility workflow'unda upstream source checkout'u, `Build-PgLogical.ps1`
ve source compilation bulunmaz. Smoke sonuçları `download`, `metadata`,
`compatibility` veya `environment` sınıfıyla raporlanır. Yalnızca eski artifact
ile ilişkili gerçek compatibility hatası targeted `windows.N+1` rebuild'e
adaydır; aynı artifact hatası issue üretir, loop başlatmaz.

Ayrıntılı release kararları için [RELEASING.md](RELEASING.md) dosyasına bakın.
