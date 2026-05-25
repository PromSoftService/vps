# Xray + VLESS + REALITY + RAW + fallback -> Nginx on Ubuntu 22.04

Этот toolkit разворачивает связку:

- **Xray** слушает `443/tcp`
- inbound: **VLESS + REALITY + RAW**
- fallback: **Nginx** на `127.0.0.1:8080`
- статическая decoy-страница для fallback
- автогенерация **REALITY private/public key** и **shortId**, если оставить `AUTO`
- генерация готового **client-config.json**

---

## Что важно понимать заранее

### 1. На одном и том же `443` здесь первым стоит именно Xray

Это соответствует документации Xray по Fallback/SNI fallback: Xray слушает `443`, а сайт или decoy-сервис уводится на внутренний порт через fallback.

### 2. Fallback работает только в связке TCP/RAW + TLS/REALITY

В документации Xray fallback разрешен только для VLESS/Trojan и только в TCP+TLS-комбинации; transport `tcp` в новых версиях переименован в `raw`.

### 3. Внутренний Nginx здесь обычный HTTP

Он слушает **только локальный порт** `127.0.0.1:8080`, потому что TLS/REALITY завершается на стороне Xray. Никакой отдельный сертификат для Nginx в этой схеме не нужен.

---

## Состав проекта

```text
xray-stack-reality-raw-fallback-nginx/
  .env.example
  docker-compose.yml
  init.sh
  check-reality.sh
  generate_client_config.py
  README.md
  nginx/
    conf.d/
      default.conf.template
  xray/
    config.json.template
  site/
    index.html
  generated/
```

---

## 1. Подготовка VPS

Нужен сервер с:

- **Ubuntu 22.04**
- публичным IPv4
- root или sudo
- доменом, указывающим на этот VPS

Открытый порт:

- `443/tcp`

Если хочешь отдельно открыть обычный HTTP-доступ к другой странице/сервису, это уже отдельная история. Для этого toolkit это не требуется.

### Docker

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg lsb-release openssl jq python3
```

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Проверка:

```bash
docker --version
docker compose version
```

---

## 2. Подготовка каталога проекта

Установи Git:

```bash
sudo apt update
sudo apt install -y git
```

Клонируй репозиторий:

```bash
git clone https://github.com/PromSoftService/xray-stack-reality-raw-fallback-endpoint.git ~/xray-stack-reality-raw-fallback-endpoint
cd ~/xray-stack-reality-raw-fallback-endpoint
```

Создай каталоги:

```bash
mkdir -p xray nginx/conf.d site
```

---

## 3. Подготовка `.env`

Сгенерируй UUID:

```bash
cat /proc/sys/kernel/random/uuid
```

```bash
cp .env.example .env
nano .env
```

Минимально заполни:

```env
DOMAIN=example.com
XRAY_UUID=11111111-2222-3333-4444-555555555555
REALITY_TARGET=www.cloudflare.com:443
REALITY_SERVER_NAMES=www.cloudflare.com
REALITY_PRIVATE_KEY=AUTO
REALITY_SHORT_ID=AUTO
```

### Что значат ключевые поля

- `DOMAIN` — домен твоего сервера, к которому будет подключаться клиент
- `XRAY_UUID` — UUID пользователя VLESS
- `REALITY_TARGET` — внешний HTTPS target для REALITY в формате `host:443`
- `REALITY_SERVER_NAMES` — `serverNames`, которые будет использовать клиент
- `REALITY_PRIVATE_KEY=AUTO` — `init.sh` сам сгенерирует x25519 key pair
- `REALITY_SHORT_ID=AUTO` — `init.sh` сам создаст shortId
- `NGINX_FALLBACK_PORT=8080` — локальный HTTP-порт fallback Nginx

---

## 4. Запуск

Сделай скрипты исполняемыми:

```bash
chmod +x init.sh check-reality.sh
```

Первичная инициализация:

```bash
./init.sh
```

Скрипт:

- читает `.env`
- генерирует REALITY key pair, если указан `AUTO`
- генерирует `shortId`, если указан `AUTO`
- собирает `xray/config.json`
- собирает `nginx/conf.d/default.conf`
- валидирует конфиг Xray
- запускает контейнеры
- генерирует:
  - `generated/client.env`
  - `generated/client-config.json`

---

## 5. Проверка

```bash
./check-reality.sh
```

---

## 6. Получение клиентского конфига

После `./init.sh` смотри файл:

```bash
generated/client-config.json
```

Или значения по отдельности:

```bash
cat generated/client.env
```

Если хочешь вручную пересобрать клиентский JSON:

```bash
python3 generate_client_config.py \
  example.com \
  11111111-2222-3333-4444-555555555555 \
  www.cloudflare.com \
  REALITY_PUBLIC_KEY \
  SHORT_ID \
  --fingerprint chrome \
  --spiderx / \
  -o client-config.json
```

---

## 7. Полезные команды

Логи:

```bash
docker compose logs -f xray nginx
```

Перезапуск:

```bash
docker compose restart xray nginx
```

Полная пересборка конфигов и перезапуск:

```bash
./init.sh
```

Остановка:

```bash
docker compose down
```

---

## 8. Важные замечания

### О fallback и REALITY

- fallback в Xray допускается именно для **VLESS/Trojan** и только в **TCP/RAW + TLS-like** схеме
- в новых версиях Xray `tcp` переименован в `raw`
- REALITY сейчас описывается как самый защищенный транспортный режим Xray

### О сайте за fallback

Этот Nginx — не полноценный публичный HTTPS origin для браузера на том же домене. Это **внутренний HTTP backend**, который получает трафик от Xray fallback.

Если тебе нужен **настоящий сайт с валидным HTTPS сертификатом на этом же домене и том же 443**, это уже другая архитектура: например, **Nginx/HAProxy first** c L4/SNI routing, либо отдельный домен/порт.

---

## 9. Типовой рабочий сценарий

- **VPS-1**: `XHTTP + Nginx`
- **VPS-2**: `REALITY + RAW + fallback -> Nginx`

Это хороший вариант для двух разных стеков с разным профилем отказа.
