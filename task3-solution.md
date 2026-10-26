## Задача 3: API Gateway (практика)

Шлюз собран на **nginx** — он запускается сервисом `gateway` из готового `docker-compose.yaml`, конфиг подкладывается томом в `/etc/nginx/nginx.conf`.

Проверка токена реализована директивой **`auth_request`**. Схема работы:

```
curl → nginx: POST /upload с заголовком Authorization
         │
         ├─ (1) подзапрос на внутренний /_auth → security GET /v1/token/validation
         │         └─ 2xx → продолжаем,  401 → отдаём 401 клиенту, дальше не идём
         │
         └─ (2) proxy_pass → uploader POST /v1/upload
```

Ключевое: сервис `security` остаётся единственным местом, где живёт логика проверки JWT. Шлюз про устройство токена ничего не знает — он только спрашивает «этот запрос пускать?» и действует по ответу.

### Карта маршрутов

| Внешний запрос | Токен | Куда проксируется |
|---|---|---|
| `POST /v1/register`, `POST /register` | не нужен | security `POST /v1/user` |
| `POST /v1/token`, `POST /token` | не нужен | security `POST /v1/token` |
| `GET /v1/user`, `GET /user` | нужен | security `GET /v1/user` |
| `POST /v1/upload`, `POST /upload` | нужен | uploader `POST /v1/upload` |
| `GET /v1/user/{image}` | нужен | storage `GET /data/{image}` |
| `GET /images/{image}` | не нужен | storage `GET /data/{image}` |
| `GET /status` | не нужен | отвечает сам шлюз |

Короткие пути (`/token`, `/upload`, `/images/…`) заведены потому, что проверочные команды в `readme.md` задания идут именно по ним, а описание задачи оперирует путями с префиксом `/v1`. Поддержаны оба набора.

### Три места, где конфиг легко сломать

**1. Порт.** В `docker-compose.yaml` проброс задан как `"80:8080"`, то есть внутри контейнера nginx обязан слушать **8080**, а не 80. При `listen 80;` шлюз поднимется, но снаружи не ответит.

**2. Имя бакета.** В задании написано «бакет images», но в `.env` лежит `Storage_Bucket=data`, и `createbuckets` создаёт бакет `data`. Поэтому во внутренний путь подставляется `/data/`, а не `/images/`:

```nginx
location /images/ {
    rewrite ^/images/(.*)$ /data/$1 break;
    proxy_pass http://storage_backend;
}
```

**3. Тело запроса в подзапросе проверки.** Без двух строк ниже nginx отправит в `security` весь загружаемый файл — сервису проверки токена он не нужен, а на больших картинках это лишний трафик и задержка:

```nginx
proxy_pass_request_body off;
proxy_set_header Content-Length "";
```

### Конфигурация

`gateway/nginx.conf`:

```nginx
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_user_agent" rt=$request_time';
    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    keepalive_timeout  65;

    # Заголовки, нужные всем маршрутам. Заданные на уровне http,
    # они наследуются каждым location.
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    upstream security_backend { server security:3000; }
    upstream uploader_backend { server uploader:3000; }
    upstream storage_backend  { server storage:9000;  }

    server {
        # В docker-compose.yaml проброс "80:8080" — внутри слушаем 8080.
        listen 8080;
        server_name _;

        client_max_body_size 50m;

        # Внутренняя точка проверки токена: сюда nginx ходит сам
        # по auth_request. Снаружи недоступна.
        location = /_auth {
            internal;

            proxy_pass http://security_backend/v1/token/validation;

            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header Authorization $http_authorization;
        }

        # ---------- анонимные ----------
        location = /v1/register { proxy_pass http://security_backend/v1/user;  }
        location = /v1/token    { proxy_pass http://security_backend/v1/token; }

        # ---------- требуют токена ----------
        location = /v1/user {
            auth_request /_auth;
            proxy_pass http://security_backend/v1/user;
        }

        location = /v1/upload {
            auth_request /_auth;
            proxy_pass http://uploader_backend/v1/upload;
            proxy_request_buffering off;
        }

        location ~ ^/v1/user/(.+)$ {
            auth_request /_auth;
            rewrite ^/v1/user/(.*)$ /data/$1 break;
            proxy_pass http://storage_backend;
        }

        # ---------- короткие пути под проверочные команды ----------
        location = /register { proxy_pass http://security_backend/v1/user;  }
        location = /token    { proxy_pass http://security_backend/v1/token; }

        location = /user {
            auth_request /_auth;
            proxy_pass http://security_backend/v1/user;
        }

        location = /upload {
            auth_request /_auth;
            proxy_pass http://uploader_backend/v1/upload;
            proxy_request_buffering off;
        }

        location /images/ {
            rewrite ^/images/(.*)$ /data/$1 break;
            proxy_pass http://storage_backend;
        }

        location = /status {
            default_type application/json;
            return 200 '{"status":"OK"}';
        }
    }
}
```

### Запуск и проверка

```bash
docker compose up --build
```

**Получение токена (анонимно):**

```bash
curl -X POST -H 'Content-Type: application/json' \
     -d '{"login":"bob", "password":"qwe123"}' \
     http://localhost/token
```

**Загрузка файла с токеном:**

```bash
TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
        -d '{"login":"bob", "password":"qwe123"}' http://localhost/token)

curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: octet/stream' \
     --data-binary @1.jpg \
     http://localhost/upload
```

Ответ: `{"filename":"c31e9789-3fab-4689-aa67-e7ac2684fb0e.jpg"}`

**Получение файла:**

```bash
curl http://localhost/images/c31e9789-3fab-4689-aa67-e7ac2684fb0e.jpg > out.jpg
```

**Негативные проверки — того, что шлюз действительно закрывает доступ:**

```bash
# без токена
curl -s -o /dev/null -w "%{http_code}\n" -X POST --data-binary @1.jpg http://localhost/upload
# 401

# с неверным токеном
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Authorization: Bearer wrong" \
     --data-binary @1.jpg http://localhost/upload
# 401

# внутренний эндпоинт проверки недоступен снаружи
curl -s -o /dev/null -w "%{http_code}\n" http://localhost/_auth
# 404
```

### Две ошибки в выданных сервисах, без исправления которых стенд не работает

**1. `security` падает при старте.** В `requirements.txt` закреплён `Flask==1.1.1`, но не закреплены его зависимости. Сейчас pip ставит Jinja2 3.1, Werkzeug 3 и itsdangerous 2.2, и Flask 1.1.1 с ними не запускается:

```
ImportError: cannot import name 'escape' from 'jinja2'
```

Шлюз при этом поднимается, но на `/token` отдаёт `502 Bad Gateway`. Исправление — закрепить совместимые версии в `security/requirements.txt`:

```text
Jinja2==2.11.3
MarkupSafe==2.0.1
itsdangerous==1.1.0
Werkzeug==1.0.1
```

**2. `security` считает валидным любой токен.** На битый или просроченный JWT `GET /v1/token/validation` отвечает текстом `Invalid token. Please log in again.`, но **с кодом 200**. Для `auth_request` код ответа — единственный сигнал, поэтому шлюз пропускал запрос с заголовком `Authorization: Bearer что-угодно`. Исправление в `security/src/server.py` — отвечать 401:

```python
except jwt.ExpiredSignatureError:
    return make_response(jsonify({'error':'Signature expired. Please log in again.'})), 401
except jwt.InvalidTokenError:
    return make_response(jsonify({'error':'Invalid token. Please log in again.'})), 401
```

Вывод на будущее: шлюз с внешней проверкой авторизации надёжен ровно настолько, насколько корректны коды ответа сервиса проверки. Негативный тест «мусорный токен → 401» обязателен, и прогонять его надо на настоящем сервисе, а не на заглушке.

### Результаты проверки

nginx с этим конфигом запущен перед настоящими `security` и `uploader` (minio в тестовой среде недоступен):

| Проверка | Ожидалось | Получено |
|---|---|---|
| `POST /token` с bob/qwe123 | 200 + JWT | 200, токен выдан |
| `POST /upload` без заголовка Authorization | 401 | 401 |
| `POST /upload` с мусорным токеном — до исправления security | 401 | **200, запрос пропущен** |
| `POST /upload` с мусорным токеном — после исправления | 401 | 401 |
| `POST /upload` с валидным токеном и PNG | запрос доходит до uploader | дошёл: uploader распознал картинку и попытался сохранить её в minio |
| `GET /v1/user` с токеном | проксируется в security | 404 от security — этот эндпоинт в выданном сервисе не реализован |
| `GET /_auth` снаружи | 404 | 404 |

Связка с minio (сохранение и отдача файла по `/images/…`) проверяется командами из readme на полном стенде.

