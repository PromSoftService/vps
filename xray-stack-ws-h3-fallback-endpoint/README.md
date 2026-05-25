# xray-stack-ws-h3-fallback-endpoint

Минимально-практичный endpoint для Happ/Xray:

- **VLESS + WebSocket + TLS** для proxy-трафика;
- **Nginx** как TLS reverse proxy;
- **HTML fallback** на `/`;
- **WebSocket endpoint** по умолчанию на `/ws`;
- **DoH** в Xray и в generated client config;
- **Let's Encrypt** через Certbot;
- **Docker Compose**;
- **HTTP/3 для HTML fallback-страницы** как опциональный режим, если выбранный nginx image реально поддерживает HTTP/3.

Ключевая схема:

```text
Happ / client
  -> VLESS WS TLS
  -> nginx:443
  -> /ws proxy_pass xray:10000
  -> xray VLESS WS
  -> freedom/direct
  -> internet

Browser обычный
  -> https://DOMAIN/
  -> nginx
  -> site/index.html
```

Важно: proxy-транспорт WS использует HTTP/1.1 Upgrade. HTTP/3, если включён, нужен только для обычной fallback-страницы, не для VLESS WS.

---

## 1. Требования

VPS:

- Ubuntu 22.04 / 24.04;
- публичный IPv4;
- пользователь с sudo;
- домен, указывающий на этот VPS;
- открытые порты:
  - `80/tcp` для Let's Encrypt HTTP-01;
  - `443/tcp` для HTTPS/WS;
  - `443/udp` только если включаешь HTTP/3 для fallback-страницы.

Проверка домена:

```bash
ping your-domain.example
```

---

## 2. Установка Docker

В toolkit есть готовый скрипт:

```bash
chmod +x install-docker.sh
./install-docker.sh
```

Проверка:

```bash
docker --version
docker compose version
```

Если после установки Docker права группы ещё не применились, выйди из SSH и зайди заново, либо временно используй `newgrp docker`.

---

## 3. Подготовка `.env`

```bash
cp .env.example .env
nano .env
```

Обязательно поменять:

```env
DOMAIN=your-domain.example
EMAIL=you@example.com
XRAY_UUID=11111111-2222-3333-4444-555555555555
XRAY_PATH=/ws
```

UUID можно сгенерировать так:

```bash
cat /proc/sys/kernel/random/uuid
```

Рекомендуемые значения для стабильности через проблемных провайдеров:

```env
CLIENT_SOCKS_UDP=false
CLIENT_SNIFF_QUIC=false
CLIENT_ALPN=http/1.1
CLIENT_MUX_ENABLED=false
NGINX_HTTP3=off
```

---

## 4. Первый запуск

```bash
chmod +x init.sh renew.sh check-stack.sh check-h3.sh
./init.sh
```

Что делает `init.sh`:

1. проверяет `.env`;
2. генерирует `xray/config.json`;
3. генерирует `generated/client-config.json` для Happ/Xray client;
4. если сертификата нет — поднимает bootstrap nginx на `80/tcp`;
5. вызывает `./renew.sh issue`;
6. получает сертификат Let's Encrypt;
7. рендерит финальный nginx TLS config;
8. запускает `nginx + xray`.

Сертификаты лежат здесь:

```text
certbot/conf/live/<DOMAIN>/fullchain.pem
certbot/conf/live/<DOMAIN>/privkey.pem
```

Ручной выпуск сертификата обычно не нужен: `init.sh` делает это сам.

---

## 5. Импорт клиента в Happ

После успешного `./init.sh` импортируй файл:

```text
generated/client-config.json
```

Проверка на Windows через локальный HTTP proxy Happ:

```powershell
curl.exe -v --proxy http://127.0.0.1:10809 https://ifconfig.me/ip
```

Ожидаемый результат — внешний IP твоего VPS.

---

## 6. Проверка сервера

```bash
./check-stack.sh
```

`check-h3.sh` оставлен как совместимый wrapper:

```bash
./check-h3.sh
```

Он запускает `check-stack.sh`.

Быстрые ручные проверки:

```bash
docker compose ps
docker compose logs --tail=100 nginx xray
curl -I http://$DOMAIN
curl -I https://$DOMAIN
```

Логи только Xray:

```bash
docker compose logs -f xray
```

Логи nginx + Xray:

```bash
docker compose logs -f nginx xray
```

---

## 7. HTML fallback

Обычная страница отдаётся nginx из:

```text
site/index.html
```

Открытие в браузере:

```text
https://DOMAIN/
```

должно показать HTML fallback.

Proxy endpoint:

```text
https://DOMAIN/ws
```

Обычным браузером `/ws` открывать не нужно — это WebSocket endpoint для VLESS client.

---

## 8. Продление сертификатов

Ручное продление:

```bash
./renew.sh renew
./init.sh
```

Ручной выпуск, если сертификата ещё нет:

```bash
./renew.sh issue
./init.sh
```

Для cron:

```bash
crontab -e
```

Пример:

```cron
0 4 * * * cd /home/user1/xray-stack-ws-h3-fallback-endpoint && ./renew.sh renew && ./init.sh >> /var/log/xray-stack-ws-renew.log 2>&1
```

---

## 9. HTTP/3 для fallback-страницы

По умолчанию HTTP/3 выключен:

```env
NGINX_HTTP3=off
```

Причина: VLESS WS не должен идти через HTTP/3; он использует HTTP/1.1 WebSocket Upgrade. HTTP/3 имеет смысл только для обычной HTML fallback-страницы.

Чтобы включить HTTP/3, нужен nginx image, собранный с `--with-http_v3_module`.

Пример настроек:

```env
NGINX_HTTP3=on
VERIFY_HTTP3_IMAGE=yes
NGINX_HTTP3_STRICT=yes
```

Если `NGINX_HTTP3=on`, но image не поддерживает HTTP/3:

- при `NGINX_HTTP3_STRICT=yes` запуск остановится с ошибкой;
- при `NGINX_HTTP3_STRICT=no` toolkit сам отключит HTTP/3 на этот запуск и продолжит запускать рабочий WS+TLS stack.

Для HTTP/3 нужно открыть UDP 443:

```bash
sudo ufw allow 443/udp
```

---

## 10. Основные файлы

```text
.env.example                         шаблон настроек
install-docker.sh                    установка Docker
docker-compose.yml                   nginx + xray + certbot
init.sh                              первый запуск / регенерация / запуск stack
renew.sh                             issue/renew Let's Encrypt
check-stack.sh                       диагностика
check-h3.sh                          совместимый wrapper на check-stack.sh
generate_client_config.py            генерация client-config.json
nginx/conf.d/bootstrap.conf.template HTTP bootstrap для ACME
nginx/conf.d/default.conf.template   финальный nginx TLS/WS/fallback config
xray/config.json.template            Xray VLESS WS inbound
site/index.html                      HTML fallback
```

---

## 11. Сброс и переустановка

Полный останов stack:

```bash
docker compose down --remove-orphans
```

Полный сброс runtime-файлов без удаления исходников:

```bash
rm -rf generated xray/config.json nginx/conf.d/default.conf certbot/www
```

Если хочешь удалить сертификаты тоже:

```bash
rm -rf certbot/conf
```

После этого:

```bash
./init.sh
```
