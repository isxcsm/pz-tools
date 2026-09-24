<p align="center">
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

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**Anda fokus bertahan hidup. PZ Tools menyimpan titik untuk kembali.** Pencadangan otomatis, riwayat save, dan pemulihan karakter untuk Project Zomboid.

## Fitur

- Mendeteksi save yang sedang dimainkan; secara bawaan mencadangkan setiap **5 menit** dan menyimpan **20 cadangan otomatis**.
- Cadangan manual dapat diganti namanya dan tidak dihapus oleh batas jumlah cadangan otomatis.
- Panggilan opsional `save(true)` melalui agen JVM sebelum pencadangan, dengan hitung mundur 5 detik di dalam game, tanpa mod Workshop.
- Gambar mini, nama karakter, waktu bertahan hidup, dan penanda kematian.
- Pelacakan inkremental USN, kompresi, dan deduplikasi opsional; jika USN tidak tersedia, pemindaian menyeluruh dengan perbandingan hash aktif secara bawaan.
- Pemeriksaan, impor, dan ekspor ZIP, indikator kemajuan, serta log operasi.
- Penyembuhan dan kebangkitan saat tidak bermain, tanpa menghapus sifat positif maupun negatif, keterampilan, atau pengalaman.

## Mulai menggunakan

Memerlukan **Windows x64 dan runtime .NET 10**. Jalankan `PzTools.App.exe` lalu periksa folder save dan cadangan. Buat cadangan manual atau gunakan cadangan otomatis saat bermain. Interval `0` menonaktifkannya. Keluar dari save tersebut sebelum memulihkan cadangan atau karakter.

## Batasan

Pemulihan hanya mengubah save saat ini, bukan cadangan lama. Mendukung **Build 42.20.4, format dunia 249, dan satu pemain lokal (ID 1)**. Barang dapat diambil dari satu rekaman zombi milik karakter yang cocok secara unik berdasarkan posisi tersimpan dan nama pada kartu identitas. Zombi yang berpindah, target tanpa identitas, dan mayat dalam chunk peta tidak didukung. Sifat negatif tetap ada; efek khusus mod mungkin tidak terhapus.

Jembatan penyimpanan bersifat eksperimental untuk pemain tunggal Build 42 / Java 25 dan dapat dinonaktifkan. Pesan selesai menyimpan di game bukan tanda cadangan selesai dan tidak menjamin snapshot atomik seluruh dunia.

Cadangan manual tetap dapat dihapus secara langsung atau oleh pembersihan cadangan tanpa sumber jika save asal hilang. Ekspor cadangan penting ke perangkat penyimpanan lain.

[Panduan build (bahasa Inggris)](../../README.md#building) · [Dokumentasi teknis (bahasa asli)](../../README.md#technical-documentation)

Alat tidak resmi; bukan produk The Indie Stone.
