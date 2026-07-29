# Playbook: Install Clickhouse & Vector

## Описание

Playbook устанавливает и настраивает ClickHouse и Vector на хосты с CentOS 7.

### Play 1: Install Clickhouse
- Скачивает RPM-пакеты ClickHouse указанной версии
- Устанавливает clickhouse-common-static, clickhouse-client, clickhouse-server
- Запускает сервис clickhouse-server
- Создаёт базу данных logs

### Play 2: Install Vector
- Скачивает RPM-пакет Vector указанной версии
- Устанавливает Vector
- Деплоит конфигурацию через Jinja2-шаблон
- Перезапускает сервис vector при изменении конфига

## Параметры

### Clickhouse (group_vars/clickhouse/vars.yml)
- clickhouse_version — версия ClickHouse (по умолчанию 22.3.3.44)
- clickhouse_packages — список пакетов для установки

### Vector (group_vars/vector/vars.yml)
- vector_version — версия Vector (по умолчанию 0.33.0)
- vector_arch — архитектура (по умолчанию x86_64)

## Теги

Плейбук не использует теги.

## Запуск

ansible-playbook -i inventory/prod.yml site.yml
