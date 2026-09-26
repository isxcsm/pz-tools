<p>
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
  <a href="../ja-JP/README.md">日本語</a> ·
  <a href="../ru-RU/README.md">Русский</a> ·
  <a href="../pt-BR/README.md">Português (Brasil)</a> ·
  <a href="../es-ES/README.md">Español (España)</a> ·
  <a href="../fr-FR/README.md">Français</a> ·
  <a href="../de-DE/README.md">Deutsch</a> ·
  <a href="../pl-PL/README.md">Polski</a> ·
  <a href="../tr-TR/README.md">Türkçe</a> ·
  <a href="../uk-UA/README.md">Українська</a> ·
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <strong>Bahasa Indonesia</strong> ·
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

# PZ Tools

PZ Tools adalah aplikasi Windows tidak resmi untuk mencadangkan dan memulihkan simpanan Project Zomboid. Aplikasi ini juga menyediakan pemulihan karakter untuk format yang didukung. Ini bukan produk The Indie Stone.

<a id="features"></a>
## Fitur

Cadangan manual dan terjadwal, riwayat yang dapat dinamai dengan gambar mini dan informasi karakter, impor/ekspor ZIP, serta penyembuhan atau kebangkitan saat tidak sedang bermain. Antarmuka, nama bawaan cadangan baru, dan pemberitahuan penyimpanan gim mendukung 18 bahasa. Tersedia tema, mode baki sistem opsional, indikator kemajuan, dan filter log.

<a id="getting-started"></a>
## Instalasi dan menjalankan aplikasi

Diperlukan **Windows x64** dan **[runtime .NET 10](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** untuk Windows x64. Saat ini aplikasi meminta izin administrator untuk melacak perubahan berkas melalui USN. Paket terbitan menyertakan komponen WinUI dan runtime Java kecil untuk terhubung ke gim, tetapi tidak menyertakan JAR gim.

Periksa [Releases](https://github.com/isxcsm/pz-tools/releases) untuk paket yang dapat dijalankan. Jika belum ada, gunakan petunjuk build di bawah. **ZIP “Source code” dari GitHub bukan aplikasi siap pakai**.

1. Ekstrak **seluruh** paket ke satu folder dan jalankan `PzTools.App.exe`. Jangan memindahkan EXE saja atau mencampur berkas dari build yang berbeda.
2. Periksa folder simpanan di Pengaturan lalu pilih folder cadangan terpisah. Jangan gunakan folder simpanan gim sebagai tujuan cadangan.
3. Pilih simpanan, buat cadangan manual, dan pastikan aplikasi menyatakan selesai. Atur interval dan jumlah cadangan otomatis yang disimpan.
4. Untuk memperbarui, tutup PZ Tools lalu siapkan paket baru lengkap di folder lain. Pisahkan simpanan dan cadangan dari berkas aplikasi.

Pengaturan dan data pengelolaan berada di `%LOCALAPPDATA%\PzTools`; cadangan berada di folder pilihan. Lihat [lokasi instalasi dan data (Korea)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Penyimpanan dan penghapusan cadangan

Nilai awalnya **5 menit** dan **20 cadangan otomatis**. Gunakan sakelar pencadangan otomatis untuk mengaktifkan atau menonaktifkannya. Interval 1–60 menit tetap disimpan saat dinonaktifkan. Cadangan mengikuti simpanan yang aktif; memulai ulang aplikasi memulai interval baru. Pengaturan yang sudah ada dipertahankan.

Cadangan manual dapat diganti namanya dan tidak dihitung dalam batas cadangan otomatis. **Namun, cadangan ini tidak disimpan selamanya:** penghapusan langsung atau pembersihan setelah simpanan asli hilang juga dapat menghapusnya. Sebelum menghapus atau memindahkan simpanan asli, ekspor cadangan penting sebagai ZIP ke drive lain.

Menghapus cadangan saja tidak mengubah simpanan saat ini, tetapi cadangan tersebut tidak dapat dipulihkan atau diekspor lagi. Menghapus simpanan melalui aplikasi juga menghapus cadangannya. Ruang dapat dikembalikan belakangan; ukuran berkas tidak selalu langsung mengecil. Lihat [pengaturan (Korea)](../configuration.md) dan [kebijakan pembersihan (Inggris)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Menyimpan gim sebelum pencadangan

Koneksi opsional meminta gim aktif menyimpan sebelum berkas disalin. Fitur ini memuat agen JVM dan memanggil `GameWindow.save(true)` pada thread gim, tanpa mod Workshop atau perubahan instalasi gim. Fitur ini eksperimental untuk struktur **Build 42 / Java 25 pemain tunggal** yang telah diperiksa; multipemain tidak didukung.

Penyimpanan gim dan hitung mundur lima detik memiliki sakelar terpisah. **“Gim tersimpan” tidak berarti “Cadangan selesai”:** pengambilan dan kompresi berkas berlangsung sesudahnya. Tanpa koneksi, atau untuk simpanan tidak aktif, hanya data yang sudah ditulis ke disk yang dicadangkan. Permintaan gagal atau tidak pasti tidak dinyatakan berhasil. Lihat [integrasi penyimpanan gim (Inggris)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Pemulihan dan arsip ZIP

Berhentilah memainkan simpanan yang dipilih sebelum memulihkannya. Pilih cadangan dan periksa konfirmasi: **pemulihan mengganti berkas saat ini, sehingga kemajuan setelah cadangan itu akan hilang**. Jika terhenti, buka kembali PZ Tools dan periksa status sebelum memuat simpanan dalam gim. Jangan menganggap pengembalian otomatis ke keadaan sebelumnya berhasil.

Ekspor simpanan saat ini atau cadangan ke ZIP dan periksa ZIP sebelum mengimpornya. Simpan arsip jangka panjang di luar folder cadangan aplikasi. Cadangan di drive yang sama tidak melindungi dari kerusakan drive tersebut. Operasi setara tersedia dalam [perintah CLI (Korea)](../cli.md).

<a id="character-recovery"></a>
## Pemulihan karakter

Buat cadangan manual atau ekspor ZIP terlebih dahulu: **pemulihan karakter tidak membuat cadangan tambahan berkas asli**. Fitur ini hanya mengubah simpanan saat ini yang tidak sedang dimainkan, bukan cadangan lama. Dukungan terbatas pada **Build 42.20.4, format dunia 249, satu pemain lokal (ID 1)**.

Penyembuhan atau kebangkitan memulihkan kesehatan dan menghapus luka serta kondisi sementara yang didukung. Sifat positif dan negatif, pengalaman, keterampilan, resep, serta inventaris yang ada tetap dipertahankan. Ini bukan kekebalan permanen dan tidak menghapus seluruh efek khusus mod.

Jika kematian mengosongkan inventaris, ambil barang dari zombi atau jasad karakter lalu hapus sumber itu. Kartu identitas tidak diperlukan. Kondisi barang, isi tas, pakaian, dan data pemasangan dipertahankan. ID barang tersimpan memulihkan perlengkapan tangan jika tersedia; jika tidak, pasang kembali secara manual. Barang yang hilang tidak dibuat. Identitas yang tidak pasti menghentikan perubahan. [pemulihan dan batasannya (Inggris)](../character-recovery.md)

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Penyimpanan dan kompatibilitas

Mesin menyimpan data yang berubah, bukan menyalin seluruh simpanan setiap kali. NTFS USN digunakan bila tersedia; jika tidak, dilakukan pemindaian lengkap dengan perbandingan isi. Verifikasi salinan dan kompresi Brotli aktif secara bawaan; deduplikasi bersifat opsional. Respons penyimpanan gim dan pemeriksaan setiap berkas **tidak menjamin semua berkas mewakili saat yang persis sama**.

Proyek masih dalam pengembangan sebelum rilis. Repositori cadangan yang tidak kompatibel ditolak dengan `repository-reset-required`, tanpa konversi atau penghapusan otomatis. Pilih **folder cadangan baru yang kosong** dan pertahankan folder lama jika diperlukan. **Jangan menghapus `Zomboid/Saves` atau hanya `repository.db` untuk mengatasi kesalahan ini.** Lihat [format repositori (Korea)](../repository-format.md) dan [pengaturan lanjutan (Inggris)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Pemecahan masalah dan laporan

Jika aplikasi tidak berjalan, periksa runtime dan kelengkapan paket. Jika berkas sedang digunakan atau terus berubah, biarkan gim selesai menyimpan sebelum mencoba cadangan lagi. Jika cadangan otomatis tidak berjalan, periksa interval, simpanan aktif, dan apakah PZ Tools masih berjalan; menutup ke baki sistem bukan keluar dari aplikasi.

Setelah gagal atau selesai sebagian, baca log sebelum mengulang operasi. Pemulihan atau pengeditan karakter yang terhenti harus diperiksa sebelum simpanan dimuat kembali. Saat membuka [issue](https://github.com/isxcsm/pz-tools/issues), sertakan versi atau commit aplikasi, versi gim, langkah-langkah, dan log terkait. Hapus jalur pribadi dan data rahasia; jangan unggah seluruh simpanan tanpa kebutuhan.

<a id="building"></a>
## Build dari kode sumber

Diperlukan Windows, .NET SDK yang ditetapkan `global.json`, PowerShell 7, JDK Java 25 Windows x64, serta alat build C++/WinUI Visual Studio. Jalankan dari akar repositori dan ganti contoh jalur JDK:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Skrip publikasi menyiapkan aplikasi dan proses pekerja bersama-sama dalam folder keluaran **baru atau kosong**. Pilih jalur lain untuk publikasi berikutnya. [Pengembangan dan validasi (Inggris)](../development.md) menjelaskan dependensi, pengujian paket, CLI, dan pengujian yang harus diaktifkan secara eksplisit.

<a id="technical-documentation"></a>
## Dokumentasi

[Indeks dokumentasi (Inggris/Korea)](../README.md) mencantumkan semua referensi dan bahasa aslinya. [Lokalisasi (Inggris)](../localization.md) menjelaskan cakupan terjemahan. [Laporan verifikasi (Korea)](../verification-report.md) adalah hasil bertanggal, bukan jaminan untuk setiap commit atau versi gim berikutnya. Lihat juga [pemberitahuan pihak ketiga (Inggris)](../../THIRD_PARTY_NOTICES.md).
