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
  <strong>Türkçe</strong> ·
  <a href="../uk-UA/README.md">Українська</a> ·
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

# PZ Tools

PZ Tools, Project Zomboid kayıtlarını yedeklemek ve geri yüklemek için resmî olmayan bir Windows uygulamasıdır. Desteklenen kayıt biçiminde karakter iyileştirme de sunar. The Indie Stone'un ürünü değildir.

<a id="features"></a>
## Özellikler

Elle ve zamanlanmış yedekler, yeniden adlandırılabilir geçmiş, küçük resimler ve karakter bilgileri, ZIP içe/dışa aktarma, oyun dışındayken iyileştirme ve diriltme. Arayüz, yeni yedeklerin varsayılan adları ve oyun kayıt bildirimleri 18 dili destekler. Temalar, isteğe bağlı sistem tepsisi modu, ilerleme göstergeleri ve günlük filtreleri bulunur.

<a id="getting-started"></a>
## Kurulum ve çalıştırma

**Windows x64** ve Windows x64 için **[.NET 10 çalışma zamanı](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** gerekir. Uygulama şu anda USN dosya değişikliği takibi için yönetici izni ister. Yayımlanan paket, WinUI bileşenlerini ve oyuna bağlanmak için küçük bir Java çalışma zamanını içerir; oyun JAR dosyalarını içermez.

Çalıştırılabilir paket için [Releases](https://github.com/isxcsm/pz-tools/releases) bölümüne bakın. Henüz paket yoksa aşağıdaki derleme adımlarını kullanın. GitHub'ın **Source code ZIP dosyası çalışmaya hazır uygulama değildir**.

1. Paketin **tamamını** bir klasöre çıkarıp `PzTools.App.exe` dosyasını çalıştırın. Yalnızca EXE'yi taşımayın ve farklı derlemelerin dosyalarını karıştırmayın.
2. Ayarlarda kayıt klasörünü kontrol edip ayrı bir yedek klasörü seçin. Oyun kayıt klasörünü yedek hedefi olarak kullanmayın.
3. Bir kayıt seçip elle yedek alın ve uygulamadaki tamamlanma durumunu kontrol edin. Otomatik yedek aralığını ve tutulacak sayıyı ayarlayın.
4. Güncellemeden önce PZ Tools'u kapatıp yeni paketin tamamını başka bir klasöre hazırlayın. Kayıtları ve yedekleri uygulama dosyalarından ayrı tutun.

Ayarlar ve yönetim verileri `%LOCALAPPDATA%\PzTools` altında, yedekler seçtiğiniz klasördedir. [Dağıtım ve veri yolları (Korece)](../deployment-layout.md) belgesine bakın.

<a id="backups-and-retention"></a>
## Saklama ve silme

Başlangıç değerleri **5 dakika** ve **20 otomatik yedek**tir. Otomatik yedeklemeyi ayrı anahtarla açıp kapatın. 1–60 dakikalık aralık, yedekleme kapatıldığında korunur. Otomatik yedekler etkin kaydı izler; uygulamanın yeniden başlatılması yeni bir aralık başlatır. Mevcut ayarlar korunur.

Elle alınan yedekler yeniden adlandırılabilir ve otomatik yedek sayısı sınırından etkilenmez. Ancak **süresiz saklanmazlar**: açık silme işlemleri veya asıl kayıt kaybolduktan sonraki temizlik bunları da kaldırabilir. Asıl kaydı silmeden ya da taşımadan önce önemli yedekleri ZIP olarak başka bir sürücüye aktarın.

Yalnızca bir yedeği silmek geçerli kaydı korur; silinen yedek artık geri yüklenemez veya dışa aktarılamaz. Uygulamadan kayıt silmek o kaydın yedeklerini de siler. Alan daha sonra geri kazanılabilir; dosya boyutu hemen küçülmeyebilir. [Ayarlar (Korece)](../configuration.md) ve [temizlik ilkesi (İngilizce)](../repository-housekeeping.md) belgelerine bakın.

<a id="game-saving"></a>
## Yedekten önce oyunu kaydetme

İsteğe bağlı bağlantı, dosya kopyalamadan önce etkin oyundan kayıt ister. JVM aracısı yükleyip oyun iş parçacığında `GameWindow.save(true)` çağırır; Workshop modu ya da oyun kurulumunda değişiklik gerekmez. İncelenen **Build 42 / Java 25 tek oyunculu** yapısı için deneysel bir işlevdir; çok oyunculu oyun desteklenmez.

Kayıt ve beş saniyelik geri sayım ayrı ayrı açılıp kapatılır. **“Oyun kaydedildi”, “Yedek tamamlandı” demek değildir**: dosya toplama ve sıkıştırma sonradan sürer. Bağlantı kapalıysa veya kayıt etkin değilse yalnızca diske yazılmış veriler yedeklenir. Başarısız ya da belirsiz kayıt isteği başarılı gösterilmez. [Oyun kaydı bağlantısı (İngilizce)](../save-bridge.md) belgesine bakın.

<a id="restore-and-archives"></a>
## Geri yükleme ve ZIP arşivleri

Geri yüklemeden önce seçili kayıttaki oyundan çıkın. Yedeği seçip onayı kontrol edin: **geçerli dosyalar değiştirilir ve o yedekten sonraki ilerleme kaybolur**. İşlem kesilirse kaydı oyunda açmadan önce PZ Tools'u yeniden açıp durumu inceleyin. Önceki duruma otomatik dönüşün başarılı olduğunu varsaymayın.

Geçerli kaydı veya yedeği ZIP olarak dışa aktarabilir, ZIP'i içe almadan önce inceleyebilirsiniz. Uzun süre saklanacak arşivleri uygulamanın yedek klasörü dışında tutun. Aynı sürücüdeki yedek, sürücü arızasına karşı korumaz. Eşdeğer işlemler [CLI komutlarında (Korece)](../cli.md) açıklanır.

<a id="character-recovery"></a>
## Karakter iyileştirme

Önce elle yedek alın veya ZIP dışa aktarın: **karakter iyileştirme asıl dosyaların ek yedeğini oluşturmaz**. Yalnızca oynanmayan geçerli kaydı değiştirir; geçmiş yedekleri düzenlemez. **Build 42.20.4, dünya biçimi 249 ve tek yerel oyuncu (ID 1)** desteklenir.

İyileştirme veya diriltme sağlığı düzeltir, desteklenen yaraları ve geçici durumları kaldırır. Olumlu ve olumsuz özellikler, deneyim, beceriler, tarifler ve mevcut envanter korunur. Kalıcı bağışıklık vermez ve modlara özgü tüm etkileri kaldırmaz.

Ölüm envanteri boşalttıysa eşyalar karakterin zombisinden veya cesedinden alınır ve bu kaynak kaldırılır. Kimlik kartı gerekmez. Eşya durumu, çanta içeriği, giyim ve takılı eşya verileri korunur. Kayıtlı eşya kimlikleri varsa ellerdeki ekipman geri yüklenir; yoksa yeniden kuşanmanız gerekir. Kayıp eşyalar üretilmez. Kimlik belirsizse değişiklik yapılmaz. [İyileştirme ve sınırları (İngilizce)](../character-recovery.md)

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Depolama ve uyumluluk

Motor her seferinde tüm kaydı kopyalamak yerine değişen veriyi saklar. Mümkünse NTFS USN, değilse içerik karşılaştırmalı tam tarama kullanır. Kopya doğrulama ve Brotli sıkıştırma varsayılan olarak açık, içerik tekilleştirme isteğe bağlıdır. Oyun yanıtı ve dosya başına kontroller **bütün dosyaların tam olarak aynı anı temsil ettiğini garanti etmez**.

Proje yayımlanma öncesi geliştirme aşamasındadır. Uyumsuz depolar `repository-reset-required` ile reddedilir; otomatik dönüştürme veya silme yapılmaz. **Yeni ve boş bir yedek klasörü** seçip gerekiyorsa eskisini koruyun. **Hatayı aşmak için `Zomboid/Saves` klasörünü veya yalnızca `repository.db` dosyasını silmeyin.** [Depo biçimi (Korece)](../repository-format.md) ve [gelişmiş yapılandırma (İngilizce)](../runtime-configuration.md) belgelerine bakın.

<a id="troubleshooting"></a>
## Sorun giderme ve bildirim

Uygulama açılmazsa çalışma zamanını ve paket bütünlüğünü kontrol edin. Dosya kullanılıyorsa veya sürekli değişiyorsa yeniden yedeklemeden önce oyun kaydının bitmesini bekleyin. Otomatik yedekler çalışmıyorsa aralığı, etkin kaydı ve PZ Tools'un hâlâ çalıştığını kontrol edin; tepsiye kapatmak uygulamadan çıkmak değildir.

Başarısız veya kısmen tamamlanan işlemi yinelemeden önce günlüğü okuyun. Kesilen geri yükleme ya da karakter düzenlemesi, oyun yüklenmeden önce incelenmelidir. [Sorun bildirirken](https://github.com/isxcsm/pz-tools/issues) uygulama sürümünü veya commit'ini, oyun sürümünü, adımları ve ilgili günlükleri ekleyin. Kişisel yolları ve özel verileri çıkarın; gerekmedikçe tüm kaydı yüklemeyin.

<a id="building"></a>
## Kaynaktan derleme

Windows, `global.json` dosyasının seçtiği .NET SDK, PowerShell 7, Windows x64 Java 25 JDK ve Visual Studio C++/WinUI derleme araçları gerekir. Depo kökünde çalıştırın ve örnek JDK yolunu değiştirin:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Yayımlama betiği uygulamayı ve işçi süreçlerini birlikte **yeni veya boş bir çıktı klasörüne** hazırlar. Yeniden yayımlarken başka bir yol seçin. [Geliştirme ve doğrulama (İngilizce)](../development.md), bağımlılıkları, dağıtım testlerini, CLI'yi ve açıkça etkinleştirilmesi gereken testleri açıklar.

<a id="technical-documentation"></a>
## Belgeler

[Belge dizini (İngilizce/Korece)](../README.md) tüm başvuruları ve özgün dillerini listeler. [Yerelleştirme (İngilizce)](../localization.md) çeviri kapsamını açıklar. [Doğrulama raporları (Korece)](../verification-report.md) tarihli sonuçlardır; sonraki her commit veya oyun sürümü için garanti değildir. [Üçüncü taraf bildirimlerine (İngilizce)](../../THIRD_PARTY_NOTICES.md) de bakın.
