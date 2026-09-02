# Windows için pglogical

[![CI](https://github.com/semihkiroglu/pglogical-windows/actions/workflows/ci.yml/badge.svg)](https://github.com/semihkiroglu/pglogical-windows/actions/workflows/ci.yml)
[![Releases](https://img.shields.io/badge/releases-download-2f6f4f)](https://github.com/semihkiroglu/pglogical-windows/releases)
[![License](https://img.shields.io/badge/license-PostgreSQL%20License-2f6f4f)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64-0078d6)](BUILDING.md)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14--18-336791)](#uyumluluk)
[![pglogical](https://img.shields.io/badge/pglogical-2.4.8-2f6f4f)](https://github.com/2ndQuadrant/pglogical)

[pglogical](https://github.com/2ndQuadrant/pglogical) PostgreSQL logical
replication eklentisinin, resmi EnterpriseDB Windows kurulumlarına karşı
CMake + MSVC ile üretilen gayriresmî Windows x64 paketleri.

Bu proje bağımsız bir out-of-tree paketleme projesidir. Upstream kaynak bu
repository'ye vendored veya fork edilmiş olarak eklenmez; her release exact
upstream tag'inden üretilir ve gerekiyorsa Windows patch'leri yalnızca geçici
build checkout'unda uygulanır. Paketler EnterpriseDB, 2ndQuadrant, PostgreSQL
Global Development Group veya upstream pglogical maintainer'ları tarafından
resmî olarak desteklenmez.

## Neden bu repository var?

Upstream pglogical Windows binary paketi yayımlamaz. Bu repository, kalıcı bir
upstream fork'u tutmadan CMake, Visual Studio toolchain (clang-cl/MSVC) ve
PowerShell ile bağımsız Windows x64 paketleri üretir. MSYS2/MinGW, Meson,
kaynak derlemeli PostgreSQL veya Docker kullanılmaz.

GitHub Actions workflow'ları:

- `ci.yml`: doğrulama, gerçek Windows build ve smoke test;
- `upstream-watch.yml`: yeni upstream release ve eksik major coverage keşfi;
- `release.yml`: pinned build matrix ve release yayını;
- `pg-versions-sync.yml`: pg.org + EDB + upstream compat koşullarına göre major
  matrisi senkronizasyonu;
- `compatibility-smoke.yml`: yayımlanmış paketlerin güncel EDB artifact'ı ile
  derlemesiz uyumluluk testi ve güvenli targeted rebuild kararı.

## Hızlı kurulum

1. [GitHub Releases](https://github.com/semihkiroglu/pglogical-windows/releases)
   sayfasından PostgreSQL build hattınıza uyan ZIP'i indirin. Örnek:
   `pglogical-2.4.8-pg18.4-edb2-windows-x64.zip`.
2. ZIP checksum'ını `SHA256SUMS.txt` ile doğrulayın.
3. ZIP'i PostgreSQL kurulumunun köküne çıkarın. Standart EDB kurulumu için
   örnek yol `C:\Program Files\PostgreSQL\<major>`; `lib\`,
   `share\extension\` ve `bin\` dizinleri mevcut yerleşimle birleşmelidir.
4. En az şu PostgreSQL ayarlarını yapın:

   ```conf
   shared_preload_libraries = 'pglogical'
   wal_level = logical
   ```

   PostgreSQL 14.24, 15.19, 16.15, 17.11 ve 18.6 ile başlayan sürümlerde
   `output_plugin_libraries` whitelist'ine provider üzerinde
   `pglogical_output` ekleyin:

   ```conf
   output_plugin_libraries = 'pgoutput, test_decoding, pglogical_output'
   ```

   Var olan güvenilir whitelist girdilerini koruyun; listeyi körlemesine
   değiştirmeyin. Bu ayarı sunucu yeniden başlatılmadan değiştirmeyin.
5. PostgreSQL'i yeniden başlatın.
6. Gereken her veritabanında `CREATE EXTENSION pglogical;` çalıştırın.

Paket, provider ve subscriber düğümlerine aynı PostgreSQL major için kurulmalıdır.
Düğüm/subscription ayarları için [upstream pglogical
belgelerine](https://github.com/2ndQuadrant/pglogical) bakın.

## Uyumluluk

| PostgreSQL | pglogical | Platform |
| --- | --- | --- |
| 14 | 2.4.8 | Windows x64 |
| 15 | 2.4.8 | Windows x64 |
| 16 | 2.4.8 | Windows x64 |
| 17 | 2.4.8 | Windows x64 |
| 18 | 2.4.8 | Windows x64 |

Matrix [.github/pg-versions.json](.github/pg-versions.json) tarafından yönetilir.
Bir upstream release için derlenecek major kümesi, yapılandırılmış major'ların
upstream kaynağındaki `compat<major>` dizinleriyle kesişimidir. PostgreSQL 19
prerelease olduğu için matriste değildir; eklenmesi bilinçli bir config ve
upstream compatibility değişikliği gerektirir.

ZIP dosya adındaki PostgreSQL minor ve EDB revision, build input provenance'ıdır;
major içi binary compatibility iddiası değildir. PostgreSQL aynı major içinde
module magic kontrolünü major düzeyinde yaptığı için paket, build edildiği
major'ın diğer minor'larında da kullanılabilir. Üretim mimarisi yalnızca x64,
configuration yalnızca `Release`'dir.

## Release ve asset adlandırması

Her upstream sürümü ve PostgreSQL major için bir release/tag vardır:

```text
pglogical-2.4.8-pg18-windows.1
```

- `2.4.8`: upstream pglogical sürümü;
- `pg18`: PostgreSQL compatibility major;
- `windows.1`: Windows packaging revision;
- yeni upstream sürümü her major için `windows.1` ile başlar;
- targeted compatibility rebuild yalnızca etkilenen major için en yüksek
  mevcut revision'ın bir üstünü kullanır.

ZIP adı exact build input'ını içerir:

```text
pglogical-2.4.8-pg18.4-edb2-windows-x64.zip
```

Her ZIP'te `BUILD-INFO.json` bulunur. Bu dosya upstream tag/SHA, PostgreSQL
major/build version, EDB artifact adı/URL/revision ve download sonrası hesaplanan
SHA-256 ile Windows packaging revision'ını kaydeder. PostgreSQL/EDB binary,
header veya library'leri bu ZIP'e bundling edilmez.

## Release karar modeli

- `upstream-watch.yml`, yeni upstream release için eksik major'ları bulur ve
  exact EDB identity taşıyan tek pinned `release.yml` çalışması başlatır.
- Aynı pglogical sürümü + major için published release varsa normal watcher bunu
  coverage sayar. Minor veya EDB revision drift'i normal release üretmez.
- `compatibility-smoke.yml`, yayımlanmış paketi güncel exact EDB artifact'ı ile
  gerçek PostgreSQL smoke testinden geçirir. Upstream source checkout'u ve
  source build bu workflow'da yoktur.
- Smoke uyumluluk hatası eski artifact ile ilişkiliyse targeted
  `windows.N+1` dispatch edilir. Aynı artifact ile hata olursa duplicate-safe
  issue açılır; rebuild loop başlatılmaz.
- Download, metadata ve runner/environment hataları otomatik rebuild'e
  dönüştürülmez.

Ayrıntılı kararlar için [RELEASING.md](RELEASING.md) dosyasına bakın.

## Güvenlik ve provenance

- Upstream kaynak exact release tag ve commit SHA ile sabitlenir; build öncesi
  checkout SHA'sı doğrulanır.
- EDB artifact'ı pg.org minor verisi ve kontrollü EDB host probe'u ile seçilir;
  EDB manifestosu varsayılmaz ve revision `-1` tahmin edilmez.
- Release planı build başlamadan doğrulanır; pinned URL yerine başka artifact
  seçilmez.
- Her release `SHA256SUMS.txt` taşır; ZIP içinde `BUILD-INFO.json` vardır.
- Her release major başına gerçek PostgreSQL kurulumu, extension, logical slot
  ve provider→subscriber replication smoke testi çalıştırır.
- Publish job'ı GitHub artifact attestation üretir.
- Published release ve asset'ler immutable kabul edilir; overwrite edilmez.

## Kaynaktan build

Ön koşullar:

- Windows x64;
- PowerShell 7.x;
- Visual Studio 2022 veya üstü, Desktop development with C++ ve C++ Clang
  tools for Windows;
- CMake >= 3.24;
- eşleşen resmi PostgreSQL Windows kurulumu veya
  `scripts/Install-PostgreSql.ps1`.

```powershell
.\scripts\Build-PgLogical.ps1 `
  -PgRoot "C:\Program Files\PostgreSQL\18" `
  -UpstreamTag "REL2_4_8" `
  -Configuration Release
```

Ayrıntılı yerel build, test ve paketleme adımları [BUILDING.md](BUILDING.md)
içindedir.

## Belgeler

- [BUILDING.md](BUILDING.md): yerel build, test ve paketleme;
- [RELEASING.md](RELEASING.md): release keşfi, smoke ve otomasyon;
- [SECURITY.md](SECURITY.md): güvenlik ve paket özellikleri;
- [CONTRIBUTING.md](CONTRIBUTING.md): repository/upstream sınırı;
- [SUPPORT.md](SUPPORT.md): destek kanalları;
- [upstream pglogical](https://github.com/2ndQuadrant/pglogical).

## Lisans

Repository build tooling PostgreSQL License altındadır ([LICENSE](LICENSE)).
Paketlenen pglogical upstream yazarlarının telif ve PostgreSQL License koşullarına,
PostgreSQL binary'leri ise kendi lisanslarına tabidir. Ayrıntı için
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) dosyasına bakın.
