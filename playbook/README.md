# Playbook: Install Clickhouse, Vector & Lighthouse

## Описание

Playbook устанавливает и настраивает три сервиса на хосты с CentOS 7:

### Play 1: Install Clickhouse
- Скачивает RPM-пакеты ClickHouse указанной версии
- Устанавливает clickhouse-common-static, clickhouse-client, clickhouse-server
- Запускает сервис clickhouse-server
- Создаёт базу данных logs

### Play 2: Install Vector
- Скачивает RPM-пакет Vector указанной версии
- Устанавливает Vector
- Деплоит конфигурацию через Jinja2-шаблон
- Перезапускает сервис при изменении конфига

### Play 3: Install Lighthouse
- Устанавливает EPEL, Nginx, Git
- Клонирует репозиторий Lighthouse
- Деплоит конфиг Nginx через Jinja2-шаблон
- Запускает и включает Nginx

## Параметры

### group_vars/clickhouse/vars.yml
- clickhouse_version — версия ClickHouse (22.3.3.44)
- clickhouse_packages — список пакетов

### group_vars/vector/vars.yml
- vector_version — версия Vector (0.33.0)
- vector_arch — архитектура (x86_64)

### group_vars/lighthouse/vars.yml
- lighthouse_vcs — URL репозитория LightHouse
- lighthouse_location_dir — каталог установки
- lighthouse_access_log_name — имя лога Nginx

## Теги

Плейбук не использует теги.

## Запуск

ansible-playbook -i inventory/prod.yml site.yml
