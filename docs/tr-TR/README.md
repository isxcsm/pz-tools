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
  <strong>Türkçe</strong> ·
  <a href="../uk-UA/README.md">Українська</a> ·
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**Siz hayatta kalın. PZ Tools geri dönebileceğiniz bir nokta saklasın.** Project Zomboid için otomatik yedekler, kayıt geçmişi ve karakter iyileştirme.

## Özellikler

- Oynanan kaydı algılar; varsayılan olarak **5 dakikada bir** yedek alır ve **20 otomatik yedek** tutar.
- Elle alınan yedekler yeniden adlandırılabilir; otomatik yedek sayısı sınırı bunları silmez.
- Yedeklemeden önce JVM aracısı üzerinden isteğe bağlı `save(true)` çağrısı ve oyun içinde 5 saniyelik geri sayım; Workshop modu gerekmez.
- Küçük resimler, karakter adı, hayatta kalma süresi ve ölüm bilgisi.
- USN ile artımlı izleme, sıkıştırma ve isteğe bağlı tekilleştirme; USN yoksa varsayılan özet karşılaştırmasıyla tam tarama.
- ZIP inceleme, içe/dışa aktarma, ilerleme göstergeleri ve işlem günlükleri.
- Oyun dışında iyileştirme ve diriltme; olumlu ve olumsuz özellikler, beceriler ve deneyim korunur.

## Başlangıç

**Windows x64 ve .NET 10 çalışma zamanı** gerekir. `PzTools.App.exe` uygulamasını açıp kayıt ve yedek klasörlerini kontrol edin. Elle yedek alın veya oynarken otomatik yedekleri kullanın. Aralığı `0` yapmak otomatik yedeklemeyi kapatır. Kaydı geri yüklemeden ya da karakteri iyileştirmeden önce o kayıttaki oyundan çıkın.

## Sınırlar

Karakter iyileştirme yalnızca mevcut kaydı değiştirir; geçmiş yedekleri düzenlemez. **Build 42.20.4, dünya biçimi 249 ve tek yerel oyuncu (ID 1)** desteklenir. Eşyalar, kayıtlı konum ve kimlikteki ad ile benzersiz eşleşen kendi zombi kaydınızdan geri alınabilir. Yer değiştirmiş zombiler, kimliği olmayan hedefler ve harita parçalarındaki cesetler desteklenmez. Olumsuz özellikler silinmez; modlara özgü etkilerin tümü giderilemeyebilir.

Kayıt köprüsü Build 42 / Java 25 tek oyunculu oyunlar için deneyseldir ve kapatılabilir. Oyundaki kayıt tamamlandı bildirimi, yedeklemenin bittiğini veya tüm dünyanın atomik anlık görüntüsünün alındığını göstermez.

Elle alınan yedekler de açıkça silinebilir veya asıl kayıt kaybolursa sahipsiz yedek temizliğiyle kaldırılabilir. Önemli yedekleri başka bir depolama aygıtına aktarın.

[Derleme (İngilizce)](../../README.md#building) · [Teknik belgeler (özgün diller)](../../README.md#technical-documentation)

The Indie Stone'un resmî ürünü değildir.
