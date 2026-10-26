# Домашнее задание к занятию «Микросервисы: подходы»

## Задача 1. Обеспечить разработку

Нужно предложить решение для хранения исходного кода, непрерывной интеграции и непрерывной поставки. Требований много, поэтому сначала выбор, а потом проход по списку: чем закрывается каждый пункт.

### Выбор — GitLab (SaaS, gitlab.com) со своими раннерами

Брал по простому принципу: одна система вместо трёх. Классическая связка «Git-хостинг + отдельный CI + отдельный реестр образов» — это три учётные системы, три места, где хранятся права, и склейка между ними, которую надо поддерживать. GitLab даёт репозитории, конвейеры, реестр Docker-образов, хранилище артефактов и секреты в одном продукте, с общей моделью доступа. Для десятков сервисов разница в поддержке ощутимая.

Второй довод — конвейер описывается файлом `.gitlab-ci.yml` в самом репозитории. История изменений сборки лежит рядом с историей кода, ревьюится в тех же merge request и откатывается тем же способом. Настройки, которые живут только в веб-интерфейсе, я не люблю: их никто не ревьюит, и при переезде они теряются.

Облачная версия снимает с команды обслуживание самого GitLab — по условию это требование, и оно разумное. При этом формат конфигурации тот же, что у self-hosted, так что переезд потом не означает переписывание конвейеров.

### Как закрываются требования

| Требование | Чем закрывается |
|---|---|
| Облачная система | gitlab.com, SaaS |
| Git | родная система, ничего дополнительно |
| Репозиторий на каждый сервис | группа проектов, отдельный репозиторий на сервис; общие вещи — в отдельный репозиторий с шаблонами |
| Сборка по событию из VCS | триггеры на push, merge request, тег; условия через `rules:` |
| Сборка по кнопке с параметрами | ручной запуск конвейера с вводом переменных; шаги с `when: manual` внутри конвейера |
| Настройки на каждую сборку | переменные на уровне проекта, группы, окружения и конкретного запуска |
| Шаблоны конфигураций | `include:` из общего репозитория, `extends:`, якоря YAML |
| Безопасное хранение секретов | маскируемые и защищённые переменные CI/CD; для чувствительного — интеграция с HashiCorp Vault |
| Несколько конфигураций из одного репозитория | несколько задач в одном конвейере, `parallel: matrix`, дочерние конвейеры |
| Кастомные шаги | любой скрипт в `script:`, свои этапы в `stages:` |
| Свои Docker-образы для сборки | образ на задачу через `image:`, хранится в реестре самого GitLab |
| Агенты на своих серверах | self-hosted GitLab Runner на своём железе, executor docker или shell |
| Параллельные сборки | задачи одного этапа идут параллельно, конвейеры разных сервисов независимы; предел — число раннеров |
| Параллельные тесты | `parallel: N` делит прогон на части, каждая на своём раннере |

### Как это работает вместе

```
разработчик ── push / MR ──► GitLab (репозиторий сервиса)
                                │  .gitlab-ci.yml  ──include──► репозиторий шаблонов
                                ▼
                         конвейер: build → test → publish → deploy
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
          свои раннеры (docker)     реестр образов GitLab
          доступ во внутреннюю сеть         │
                                            ▼
                                   окружения: stage → prod (ручное подтверждение)
```

**Свои раннеры нужны, даже когда GitLab облачный.** Общие раннеры удобны на старте, но своё железо даёт контроль над ресурсами, доступ во внутреннюю сеть (интеграционные тесты с базой, выкатка в закрытый контур) и предсказуемую цену при десятках конвейеров.

**Шаблоны — обязательны.** Десятки сервисов с независимо написанными конвейерами дают разнобой уже через пару месяцев: в одном тесты запускаются, в другом забыли, в третьем сборка на другой версии образа. Общий репозиторий шаблонов и `include:` в каждом сервисе решают вопрос: процесс правится в одном месте.

**Секреты.** Переменных CI/CD хватает на старте, но ключи платёжных систем и пароли продовых баз я бы сразу держал в Vault, а в GitLab оставил только доступ к нему. У Vault есть ротация, аудит обращений и короткоживущие токены; переменная в интерфейсе — просто строка, которую видит каждый мейнтейнер проекта.

---

## Задача 2. Логи

### Выбор — Vector → Elasticsearch → Kibana

Три части, каждая делает свою работу:

```
хост 1..N                                   центральная часть
┌──────────────────────┐
│ контейнеры → stdout  │
│        │             │
│   Docker Engine      │
│        │             │
│   Vector (агент)     │── HTTP bulk ──►  Elasticsearch  ◄── Kibana ◄── разработчики
│   дисковый буфер     │                  (хранение, поиск)   (UI, доступы, ссылки)
└──────────────────────┘
```

**Vector** — агент на каждом хосте. Читает stdout контейнеров через Docker API, разбирает строки, добавляет метки (сервис, контейнер, хост) и отправляет дальше. От приложения не требуется ничего: пишет в stdout — достаточно. Выбрал его, а не Filebeat или Fluentd, потому что он заметно экономнее по памяти (а агент стоит на каждом узле), у него внятный язык преобразований VRL и встроенный дисковый буфер.

**Elasticsearch** — хранилище и поиск: полнотекстовый поиск, фильтрация по полям, кластеризация, управление жизненным циклом индексов (старые логи автоматически уезжают на медленные диски и удаляются). Политика хранения важнее, чем кажется: логи десятков сервисов растут быстро, и без неё место кончается ровно в момент инцидента, когда логи нужнее всего.

**Kibana** — интерфейс: поиск, фильтры, дашборды, разграничение доступа (разработчикам — только чтение своих индексов). Сохранённый поиск получает постоянную ссылку, которую можно отправить в тикет или чат.

### Как закрываются требования

| Требование | Чем закрывается |
|---|---|
| Сбор со всех хостов в центральное хранилище | Vector на каждом хосте, общий кластер Elasticsearch |
| Минимальные требования к приложениям, stdout | источник `docker_logs`: Vector сам читает вывод контейнеров |
| Гарантированная доставка | дисковый буфер Vector; при росте — Kafka между сбором и хранением |
| Поиск и фильтрация | Elasticsearch, язык запросов KQL в Kibana |
| UI с доступом для разработчиков | Kibana, роли и пространства с правами на чтение |
| Ссылка на сохранённый поиск | Saved Search в Kibana, Share → ссылка |

### Про гарантию доставки

«Отправили и надеемся» — не гарантия, поэтому два уровня.

Первый — **дисковый буфер Vector**. Если хранилище недоступно или тормозит, агент складывает события на диск и досылает их, а не выбрасывает. Это переживает и перезапуск самого агента.

Второй — **очередь между сбором и хранением**, когда объёмы вырастут. Vector пишет в Kafka, из Kafka читает то, что кладёт в Elasticsearch. Тогда всплеск логов — а он всегда совпадает с инцидентом, когда все сервисы разом начинают писать ошибки — упирается в Kafka, а не роняет хранилище. На старте хватит дискового буфера, но место под Kafka стоит заложить в схему сразу.

### Что требует договорённости с разработкой

- **логи в stdout, а не в файлы внутри контейнера** — файл исчезает вместе с контейнером;
- **структурированные логи в JSON** — свободный текст придётся разбирать регулярками, которые ломаются при каждом изменении формата;
- **correlation ID в каждой строке** — без него поиск «покажи всё по этому запросу» невозможен;
- **разумные уровни логирования** — debug в проде означает счёт за диски и утонувший в шуме поиск.

---

## Задача 3. Мониторинг

### Выбор — Prometheus + экспортёры + Grafana

**Prometheus** сам опрашивает сервисы (модель pull). Для микросервисов это удобнее push-модели: цели подхватываются через service discovery из Docker, Consul или Kubernetes, и новый сервис попадает под мониторинг самим фактом своего появления. Плюс язык запросов PromQL с агрегациями и Alertmanager для оповещений.

Метрики собираются тремя слоями — ровно по трём пунктам задания:

| Требование | Чем собирается | Примеры метрик |
|---|---|---|
| Ресурсы хостов: CPU, RAM, HDD, Network | node_exporter на каждом хосте | загрузка CPU, память, заполнение и нагрузка дисков, трафик |
| Ресурсы каждого сервиса: CPU, RAM, HDD, Network | cAdvisor (в Kubernetes — kubelet/cAdvisor) | CPU и память по контейнеру, дисковый ввод-вывод, сетевой трафик |
| Специфичные метрики сервиса | клиентская библиотека Prometheus в приложении, эндпоинт `/metrics` | запросов в секунду, доля ошибок, время ответа, длина очереди |

**Grafana** — интерфейс: запросы к Prometheus, агрегации, настраиваемые панели, готовые дашборды для node_exporter и cAdvisor, разграничение доступа.

| Требование | Чем закрывается |
|---|---|
| UI с запросами и агрегацией | Grafana Explore и PromQL: `sum by`, `rate`, `histogram_quantile` |
| UI с настраиваемыми панелями | дашборды Grafana, провижининг из файлов в git |

### Что я бы добавил сверх задания

- **Alertmanager.** Мониторинг, на который надо смотреть глазами, — это красивые графики, а не мониторинг.
- **Метрики RED на каждый сервис** — частота запросов, доля ошибок, время ответа. Метрики хостов не отвечают на вопрос «что сломалось»: все узлы могут быть зелёными, пока заказы не оформляются.
- **Долговременное хранение** — Prometheus не рассчитан на историю за год; для этого VictoriaMetrics или Thanos.

### Как это стыкуется с логами

Метрики говорят, **что** сломалось и когда. Логи — **почему**. Связывает их correlation ID и общая разметка по имени сервиса, поэтому в Grafana стоит сразу настроить переход из панели со всплеском ошибок в поиск по логам за тот же интервал.

---

## Задачи 4 и 5. Практика

Обе задачи достраивают стенд из ДЗ «Микросервисы: принципы» (API Gateway на nginx перед `security`, `uploader` и `storage`). Стенд целиком лежит в каталоге [`11-microservices-02-principles/`](./11-microservices-02-principles/).

Обе задачи требуют свой сервис на порту **8081**, поэтому каждая оформлена отдельным файлом-дополнением к основному `docker-compose.yaml` и запускается независимо:

```text
11-microservices-02-principles/
├── docker-compose.yaml            # базовый стенд: gateway, security, uploader, storage
├── docker-compose.logs.yaml       # задача 4: Vector + Elasticsearch + Kibana
├── docker-compose.metrics.yaml    # задача 5: Prometheus + Grafana
├── .env                           # учётные данные стенда
├── logging/
│   ├── vector/vector.yaml
│   └── setup/
│       ├── es-setup.sh            # пользователи и роли в Elasticsearch
│       └── kibana-setup.sh        # data view api-logs-* в Kibana
└── monitoring/
    ├── prometheus/prometheus.yml
    └── grafana/
        ├── provisioning/          # источник данных и подключение дашбордов
        └── dashboards/api-requests.json
```

### Перед запуском: две ошибки в выданном сервисе security

Без этих исправлений стенд не работает ни в одной из задач.

**`security` падает при старте.** В `requirements.txt` закреплён `Flask==1.1.1`, но не его зависимости, и pip ставит свежие версии, с которыми Flask 1.1.1 не запускается (`ImportError: cannot import name 'escape' from 'jinja2'`). Исправлено закреплением совместимых версий в `security/requirements.txt`:

```text
Jinja2==2.11.3
MarkupSafe==2.0.1
itsdangerous==1.1.0
Werkzeug==1.0.1
```

**`security` принимает любой токен.** На битый JWT эндпоинт проверки отвечал текстом с кодом 200, и шлюз с `auth_request` пропускал запрос. Исправлено в `security/src/server.py` — теперь 401.

---

## Задача 4. Логи: Vector + Elasticsearch + Kibana

### Как устроено

```
gateway ─┐
security ├─ stdout ─► Docker Engine ─► Vector ─► Elasticsearch ◄── Kibana :8081
uploader │             (docker.sock)    фильтр     api-logs-YYYY.MM.DD
storage ─┘                              + буфер
```

- **Vector** читает логи контейнеров через `/var/run/docker.sock` (только чтение), пропускает дальше только сервисы API и пишет в Elasticsearch в индекс на каждый день.
- **Elasticsearch** работает с включённой безопасностью. Одноразовый контейнер `es-setup` при первом запуске создаёт три учётки: `kibana_system` (служебная для Kibana), `vector` с ролью, разрешающей только запись в `api-logs-*`, и `admin` с ролью `superuser` для входа в Kibana.
- **Kibana** опубликована на `localhost:8081`. Одноразовый контейнер `kibana-setup` создаёт data view `api-logs-*` и делает его представлением по умолчанию — логи видны в Discover сразу после входа, без ручной настройки.

Почему не логиниться в Kibana встроенным `elastic`: задание требует логин `admin`, а встроенного пользователя с таким именем в Elasticsearch нет. Заодно получается правильная схема: у каждого компонента своя учётка с минимально нужными правами, а суперпользователь `elastic` используется только для первичной настройки.

### Фильтр от петли

Vector собирает логи всех контейнеров на хосте, включая собственные и логи Elasticsearch с Kibana. Если их не отсечь, получается петля: запись в Elasticsearch порождает строку в логе Elasticsearch, которая снова уходит в Elasticsearch. Поэтому первым шагом стоит фильтр по имени сервиса из меток docker compose:

```yaml
transforms:
  api_only:
    type: filter
    inputs: [docker]
    condition: |
      includes(["gateway", "security", "uploader", "storage"], .label."com.docker.compose.service")
```

### Конфигурация Vector

`logging/vector/vector.yaml`:

```yaml
api:
  enabled: true
  address: 0.0.0.0:8686

data_dir: /var/lib/vector

sources:
  docker:
    type: docker_logs

transforms:
  api_only:
    type: filter
    inputs: [docker]
    condition: |
      includes(["gateway", "security", "uploader", "storage"], .label."com.docker.compose.service")

  normalize:
    type: remap
    inputs: [api_only]
    source: |
      .service = .label."com.docker.compose.service"
      .container = .container_name

      parsed, err = parse_json(.message)
      if err == null && is_object(parsed) {
        . = merge!(., parsed)
      }

      del(.label)
      del(.container_created_at)
      del(.container_id)
      del(.image)
      del(.source_type)

sinks:
  elasticsearch:
    type: elasticsearch
    inputs: [normalize]
    endpoints: ["http://elasticsearch:9200"]
    api_version: v8
    mode: bulk
    bulk:
      index: "api-logs-%Y.%m.%d"
    auth:
      strategy: basic
      user: vector
      password: "${VECTOR_ES_PASSWORD}"
    buffer:
      type: disk
      max_size: 268435488
      when_full: block
```

Дисковый буфер с `when_full: block` — та самая гарантированная доставка из задачи 2: пока Elasticsearch недоступен, события копятся на диске и досылаются.

### Запуск

```bash
docker compose -f docker-compose.yaml -f docker-compose.logs.yaml up --build -d
```

Первый старт занимает 1–2 минуты: Elasticsearch и Kibana поднимаются небыстро, а `es-setup` и `kibana-setup` дожидаются их готовности. Прогресс:

```bash
docker compose -f docker-compose.yaml -f docker-compose.logs.yaml logs -f es-setup kibana-setup
```

### Проверка

1. Создать трафик через шлюз:

```bash
TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"login":"bob", "password":"qwe123"}' http://localhost/token)
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: octet/stream' --data-binary @1.jpg http://localhost/upload
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Authorization: Bearer wrong" --data-binary @1.jpg http://localhost/upload
```

2. Открыть http://localhost:8081, войти как `admin` / `qwerty123456`.
3. Discover → data view **API logs** → фильтр `service : "gateway"` — видны строки access-лога nginx, включая запрос с кодом 401.

Проверка без браузера — количество документов в индексах:

```bash
docker compose -f docker-compose.yaml -f docker-compose.logs.yaml exec elasticsearch \
  curl -s -u admin:qwerty123456 'http://localhost:9200/api-logs-*/_count'
```

---

## Задача 5. Мониторинг: Prometheus + Grafana

### Как устроено

```
security :3000/metrics ─────────────┐
uploader :3000/metrics ─────────────┼──► Prometheus ◄── Grafana :8081
storage  :9000/minio/v2/metrics/cluster ┘   (pull, 15s)    дашборд из файла
```

Grafana при старте сама подключает источник данных и загружает дашборд из файлов (provisioning), а после входа сразу открывает его — настраивать ничего не нужно.

### Какие метрики отдают сервисы

Названия я проверил на запущенных сервисах, а не по документации, — они у всех трёх разные:

| Сервис | Библиотека | Счётчик запросов | Метки |
|---|---|---|---|
| security | prometheus_flask_exporter | `http_request_total` | `method`, `status` |
| uploader | express-prometheus-middleware | `http_requests_total` | `route`, `method`, `status` |
| storage | MinIO metrics v2 | `minio_s3_requests_total` | `api` |

Чтобы свести три разных счётчика в один график, запрос выбирает метрики по регулярному выражению на имя и группирует по `job` — имени задания опроса в Prometheus:

```promql
sum by (job) (
  rate({__name__=~"http_requests?_total|minio_s3_requests_total",
        job=~"security|uploader|storage"}[$__rate_interval])
)
```

`http_requests?_total` — это `http_request_total` и `http_requests_total` одним выражением.

### Конфигурация Prometheus

`monitoring/prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: security
    metrics_path: /metrics
    static_configs:
      - targets: ["security:3000"]

  - job_name: uploader
    metrics_path: /metrics
    static_configs:
      - targets: ["uploader:3000"]

  - job_name: storage
    metrics_path: /minio/v2/metrics/cluster
    static_configs:
      - targets: ["storage:9000"]

  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
```

Эндпоинт метрик MinIO доступен без токена благодаря `MINIO_PROMETHEUS_AUTH_TYPE: public`, который уже задан в базовом `docker-compose.yaml`.

### Дашборд «API: распределение запросов по сервисам»

| Панель | Что показывает | Запрос |
|---|---|---|
| Состояние сервисов | UP/DOWN по каждому сервису | `up{job=~"security\|uploader\|storage"}` |
| Распределение запросов по сервисам | доля каждого сервиса за период, кольцевая диаграмма | `sum by (job) (increase(...[$__range]))` |
| Запросов в секунду по сервисам | интенсивность во времени | `sum by (job) (rate(...[$__rate_interval]))` |
| Всего запросов за период | абсолютные числа по сервисам | `sum by (job) (increase(...[$__range]))` |
| Ошибки 4xx/5xx по сервисам | запросы, завершившиеся ошибкой | фильтр `status=~"[45].."`, для MinIO `minio_s3_requests_errors_total` |
| Запросы по эндпоинтам | детализация: маршруты uploader, методы S3 API, коды ответа security | разбивка по `route`, `api`, `status` |

### Запуск

```bash
docker compose -f docker-compose.yaml -f docker-compose.metrics.yaml up --build -d
```

### Проверка

1. Создать трафик — десяток успешных и неуспешных запросов через шлюз:

```bash
for i in $(seq 1 20); do
  curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"login":"bob", "password":"qwe123"}' http://localhost/token
  curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"login":"bob", "password":"bad"}' http://localhost/token
done
```

2. Открыть http://localhost:8081, войти как `admin` / `qwerty123456` — сразу открывается дашборд.
3. Статус целей опроса в самом Prometheus:

```bash
docker compose -f docker-compose.yaml -f docker-compose.metrics.yaml exec prometheus \
  wget -qO- http://localhost:9090/api/v1/targets
```

