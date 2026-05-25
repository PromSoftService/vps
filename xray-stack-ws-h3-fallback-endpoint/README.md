# Xray + VLESS WS + Nginx + HTTP/3 fallback endpoint

Стек для VPS:

- **Xray** как backend VLESS over WebSocket;
- **Nginx** как TLS reverse proxy;
- **WebSocket** transport для Happ/Xray-клиента;
- **HTML fallback** на `/`;
- **HTTP/3/QUIC + HTTP/2** для обычной fallback-страницы;
- **DNS-over-HTTPS** в Xray и генерируемом клиентском конфиге;
- **Let's Encrypt** через Certbot webroot;
- **Docker Compose**.

## Целевая схема

```text
Browser GET https://DOMAIN/
  -> nginx:443 TLS/H2/H3
  -> /usr/share/nginx/html/index.html

Happ / Xray client
  -> VLESS + WS + TLS
  -> nginx:443 TCP/TLS HTTP/1.1 Upgrade websocket
  -> xray:XRAY_PORT внутри docker-сети
  -> freedom/direct
```

По умолчанию WebSocket endpoint:

```text
wss://DOMAIN/ws
```

## Файлы

```text
.env.example
README.md
docker-compose.yml
init.sh
renew.sh
check-stack.sh
check-h3.sh
generate_client_config.py
install-docker.sh
nginx/conf.d/bootstrap.conf.template
nginx/conf.d/default.conf.template
xray/config.json.template
site/index.html
check_h3.py
```

## Быстрый запуск

```bash
cp .env.example .env
nano .env
./init.sh
```

После успешного запуска импортируй в Happ:

```text
generated/client-config.json
```

## Важные параметры `.env`

```bash
DOMAIN=example.com
EMAIL=you@example.com
XRAY_UUID=11111111-2222-3333-4444-555555555555
XRAY_PATH=/ws
XRAY_PORT=10000
DOH_URL=https://1.1.1.1/dns-query
```

Для WebSocket-клиента по умолчанию используется:

```bash
XRAY_CLIENT_ALPN=http/1.1
CLIENT_UDP_ENABLED=no
CLIENT_SNIFF_QUIC=no
```

Это сделано намеренно: WebSocket Upgrade работает через HTTP/1.1, а TCP-only клиентский профиль обычно стабильнее на проблемных провайдерах.

HTTP/3 относится к обычной fallback-странице nginx, а не к VLESS WS transport:

```bash
NGINX_HTTP2=on
NGINX_HTTP3=on
```

## Проверка

```bash
./check-stack.sh
```

`check-h3.sh` оставлен как совместимый wrapper и запускает тот же `check-stack.sh`.

## Проверка с Windows через Happ local proxy

```powershell
curl.exe -v --proxy http://127.0.0.1:10809 https://ifconfig.me/ip
```

Если всё работает, в ответе будет IP VPS.

## Как работает fallback

Обычный браузерный заход:

```text
https://DOMAIN/
```

получает `site/index.html`.

Xray/Happ-подключение идёт на тот же порт `443`, но на путь:

```text
https://DOMAIN/ws
```

и отличается заголовками WebSocket:

```text
Upgrade: websocket
Connection: upgrade
```

Nginx прокидывает только этот путь в Xray.

## Certificate renew

```bash
./renew.sh
```

Certbot использует webroot:

```text
certbot/www
```

Nginx должен быть доступен на `80/tcp`.

## Порты

Открыть на VPS:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
```

`443/udp` нужен только если включён `NGINX_HTTP3=on` для fallback-страницы.

## Отличие от старого H3/XHTTP toolkit

Было:

```text
VLESS + XHTTP + TLS/H3/H2 через nginx /api/v1/messages/
```

Стало:

```text
VLESS + WebSocket + TLS через nginx /ws
```

Nginx остаётся, DoH остаётся, certbot остаётся, HTTP/3 fallback для HTML остаётся. Меняется только транспорт Xray: `xhttp` заменён на `ws`.
