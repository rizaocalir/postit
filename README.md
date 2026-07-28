# 📌 PostIt

macOS için menü çubuğunda yaşayan, çeviri destekli yapışkan not (post-it) uygulaması. SwiftUI ile yazılmıştır.

## Özellikler

- **Zengin metin düzenleme** — seçili yazıyı kalın yapma (toolbar "B" veya ⌘B)
- **Listeler** — madde işareti (•) ve otomatik artan numaralandırma (1. 2. 3.); Enter ile liste kendiliğinden devam eder, boş maddede Enter listeyi bitirir
- **Anında İngilizce çeviri** — notun sonuna çizgi (`———` veya `---`) çekildiğinde üstteki metnin İngilizce çevirisi altta belirir (Apple Translation framework, cihaz üzerinde çalışır)
- **Alarm** — tarih/saat seç; alarm çaldığında **"Kapat" diyene kadar ekranda kalan** yüzen bir hatırlatma paneli açılır (uygulama kapalıyken de kalıcı "Alert" stili sistem bildirimi gelir)
- **Arşiv** — işi biten notu silmeden panodan kaldır; toolbar'daki **Notlar / Arşiv** anahtarıyla arşive geç, istediğinde notu geri al. Arşivlenen notun alarmı susar, geri alınınca yeniden kurulur
- **Menü çubuğu erişimi** — aktif notlara sağ üstteki menü çubuğu simgesinden hızlıca ulaş
- **Sürükle-bırak** — pano görünümünde notları sürükleyerek yeniden sırala
- **6 post-it rengi** — editörden veya sağ tık menüsünden değiştirilebilir
- **Kalıcı depolama** — notlar Application Support altında JSON dosyasına debounce'lu olarak otomatik kaydedilir; eski sürümün UserDefaults kayıtları ilk açılışta taşınır

## İndir

Hazır uygulamayı [Releases](https://github.com/rizaocalir/postit/releases/latest) sayfasından indirebilirsiniz.

Uygulama Apple Developer ID ile imzalanmadığı için ilk açılışta macOS uyarı verir. Açmak için:
`PostIt.app`'e **sağ tık → Aç** deyin, çıkan uyarıda tekrar **Aç**'ı seçin (yalnızca ilk seferde gerekir).

## Gereksinimler

- macOS 15 (Sequoia) veya üzeri — Apple Translation framework için gerekli
- Derlemek için: Xcode 16+

> Not: Çeviri özelliği ilk kullanımda dil paketini indirir (bir kez internet bağlantısı ister). Ek entitlement gerekmez.

## Kurulum

```bash
git clone https://github.com/rizaocalir/postit.git
cd postit
open PostIt.xcodeproj
```

Xcode'da `PostIt` şemasını seçip **⌘R** ile çalıştırın.

## Kullanım

| İşlem | Nasıl |
|---|---|
| Yeni not | Sağ üstteki kırmızı **+** butonu (ana pencere veya menü çubuğu) |
| Kalın yazı | Metni seç → **⌘B** |
| Çeviri | Toolbar'daki **—** butonu veya elle `———` çizgisi çek |
| Alarm | Toolbar'daki 🔔 zil simgesi |
| Renk değiştir | Editör toolbar'ındaki renk daireleri veya karta sağ tık |
| Arşive at | Editörde **Arşive At**, ya da karta / menü çubuğu satırına sağ tık → **Arşive Taşı** |
| Arşivi görüntüle | Toolbar'daki **Arşiv** sekmesi |
| Arşivden çıkar | Arşiv sekmesinde karta sağ tık → **Arşivden Çıkar** |
| Sil | Karta sağ tık → Sil |

## Mimari

Uygulama tek dosyada toplanmıştır: [PostIt/PostItApp.swift](PostIt/PostItApp.swift)

- `StickyNote` — Codable not modeli (başlık, düz metin, RTF verisi, renk, alarm)
- `NoteManager` — notların kalıcılığı, alarm planlama ve bildirim delegesi
- `RichTextEditor` — `NSTextView` sarmalayıcı (`NSViewRepresentable`); RTF tabanlı zengin metin
- `EditNoteView` — not editörü; debounce'lu otomatik çeviri (`translationTask`)
- `ContentView` — mantar pano görünümü, sürükle-bırak sıralama
- `MenuBarNotesView` — menü çubuğu paneli (`MenuBarExtra`)
