# YT Cutter

Çalışanlar için, YouTube videosunun tamamını indirmeden seçilen zaman aralığını 720p sesli MP4 olarak kaydeden Windows ve Android uygulaması.

## Kullanım

1. YouTube video bağlantısını yapıştırın.
2. Başlangıç ve bitiş zamanını `00.00` veya `0000` biçiminde girin.
3. **720p MP4 indir** düğmesine basın.

Kesit süresiyle birlikte internet ve işlem payını hesaba katan tahmini işlem süresi arayüzde gösterilir.

Uygulama 720p MP4 görüntü ve sesi ayrı akışlardan alır; FFmpeg ile yeniden kodlamadan birleştirir. HTTP zaman/range araması sayesinde tüm video yerine istenen bölümü çevreleyen medya verileri alınır.

## GitHub üzerinden paketleme

Her `main` gönderiminde GitHub Actions Android APK ve Windows ZIP üretir. Actions sayfasındaki ilgili çalışmanın **Artifacts** bölümünden indirilebilir.

GitHub Release oluşturmak için bir sürüm etiketi gönderin:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

Etiketle tetiklenen derlemede APK ve Windows ZIP dosyaları otomatik olarak GitHub Releases sayfasına eklenir.
