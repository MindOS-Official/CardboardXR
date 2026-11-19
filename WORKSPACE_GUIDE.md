# CardboardXR Spatial Desktop (Parsec + WebKit + 3D Air Keyboard)

Bu klasor `brenpoly/CardboardXR` uzerine eklenen **Desktop** demosunu icerir. Windows bilgisayarda gelistirilip GitHub Actions uzerinden imzasiz `.ipa` ciktisi almak ve Sideloadly / SideStore ile iPhone 14 Pro'ya yuklemek icin hazirlanmistir.

## Eklenen Ozellikler

1. **Parsec Remote Desktop (`DesktopDemo.cs`, `CardboardXRParsec.mm`, `ParsecSDK.framework`):**
   - Parsec hesabina 2FA destekli giris (`POST https://kessel-api.parsec.app/v1/auth`) ve iOS Keychain oturum saklama.
   - Cevrimici bilgisayar listesini cekme ve `ParsecSDK` ile 60 fps Metal `RenderTexture` uzerine aktarim.
   - `AudioToolbox` `AudioQueue` ile 48 kHz dusuk gecikmeli ses.
   - Bakis (Gaze) veya el isaretiyle fare imlecini hareket ettirme, sol/sag tiklama ve surukleme.

2. **WebKit 3D Tarayici (`CardboardXRWebView.mm`):**
   - Arka planda `WKWebView` calistirip goruntuyu sanal 2. monitore aktarir (`1280x800`).
   - Geri, ileri, yenile, adres cubugu, hizli yer imleri (DuckDuckGo, YouTube, GitHub) ve dikey kaydirma butonlari.

3. **3D Hava Klavyesi (`SpatialAirKeyboard.cs`):**
   - Hem **Bakis + Pinch** ile hem de **isaret parmagi ucuyla 3D tuslara dokunarak** yazma destegi.
   - Giris odaklama: Parsec E-posta/Sifre/2FA alanlari, WebKit adres cubugu, aktif WebKit form alanlari veya bagli Parsec PC'ye canli klavye tuslari (`Shift`, `Ctrl`, `Alt`, `Win`, oklar, `Esc`, `Tab`, `Enter`, `Backspace`).

---

## GitHub Actions ile Mac Olmadan `.ipa` Alma

`.github/workflows/build-ios-ipa.yml` iki calisma modunu destekler:

### Yol 1: Tam Bulut Derleme (Bilgisayarda Unity Gerekmez)
1. Bu klasoru kendi GitHub reponuza yukleyin.
2. GitHub Repo Settings -> Secrets and variables -> Actions altina `UNITY_LICENSE`, `UNITY_EMAIL`, `UNITY_PASSWORD` secret'larini ekleyin (`game-ci` Unity Personal lisansi ucretsiz alinabilir).
3. Actions sekmesinden **Build CardboardXR Desktop IPA** workflow'unu calistirin.
4. Cikan `CardboardXR-Desktop-IPA` artifact'ini indirip Windows'ta **Sideloadly** veya **SideStore** ile iPhone 14 Pro'ya kurun.

### Yol 2: Windows'tan Xcode Projesi Export Edip GitHub'da Derleme (Unity Secret Gerekmez)
1. Windows PC'de Unity `6000.6.8f1` + **iOS Build Support** kurun.
2. PowerShell'de repo kokunden calistirin:
   ```powershell
   .\Tools\export_ios_windows.ps1
   ```
3. Olusan `Builds/iOS` klasorunu GitHub'a zorlayarak ekleyin (`.gitignore` varsayilan olarak `Builds/` klasorunu haric tutar):
   ```powershell
   git add -f Builds/iOS
   git commit -m "Export iOS Xcode project"
   git push
   ```
4. GitHub Actions `Builds/iOS/Unity-iPhone.xcodeproj` gordugunde Unity kurmadan dogrudan Xcode ile `.ipa` uretir.

---

## VR Box ve iPhone 14 Pro Kullanim Notlari

* **Kamera Acikligi:** VR Box'in arka kamera ve LiDAR onundeki kapak mutlaka acik olmalidir; 6DoF konum takibi (ARKit) ve el takibi (MediaPipe) arka kamerayi kullanir.
* **Ekran Yonu:** Goruntu ters gorunurse ust kontrol cubugundaki **Flip Y** dugmesine basin.
* **Sag Tik:** Parsec'te sag tik gondermek icin **Right Click** dugmesini aktif edin, bir sonraki pinch sag tik olarak gider.
