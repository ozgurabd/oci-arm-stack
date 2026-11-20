# Değişiklik günlüğü

Önemli değişiklikler bu dosyada tutulur. Sürüm numaraları [Semantic Versioning](https://semver.org/) kurallarına uyar.

## [1.0.0] - 2026-10-29

İlk sürüm.

- Ubuntu 26.04 (arm64) için tek komutla kurulum: sistem güncellemesi, UTC saat dilimi, otomatik güvenlik güncellemeleri, SSH sertleştirme, fail2ban, iptables'ta 80/443, swap ve BBR
- Docker Compose stack: nginx 1.30 + Let's Encrypt, PostgreSQL 18, Valkey 9.1 ve SILO (S3 uyumlu nesne depolama)
- Deno 2.9, .NET 10 ve Go 1.27 için Dockerfile'lar ve `/health` uç noktası olan örnek uygulamalar
- Gecelik PostgreSQL yedeği ve günde iki kez sertifika yenileme (systemd timer)
- Tekrar çalıştırılabilir kurulum; DNS hazır değilse sertifika adımını atlar
- `curl | bash` ile çalıştırma, `--help` ve `--version`

[1.0.0]: https://github.com/KULLANICI_ADI/oci-arm-stack/releases/tag/v1.0.0
