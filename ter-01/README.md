# Домашнее задание к занятию «Введение в Terraform»

## Чек-лист готовности

Terraform v1.12.2 установлен с зеркала Яндекс Клауд `hashicorp-releases.yandexcloud.net`
(прямой доступ к releases.hashicorp.com заблокирован из РФ):

```
Terraform v1.12.2
on linux_amd64
```

---

## Задание 1

### Шаг 2 — в каком файле допустимо хранить секреты

Согласно `.gitignore` в репозитории:

```
personal.auto.tfvars
```

Этот файл явно исключён из git. Terraform автоматически подхватывает любой файл `*.auto.tfvars`
при выполнении `plan`/`apply`, поэтому это штатное место для хранения секретов (логинов, паролей,
ключей, токенов), которые не должны попасть в репозиторий.

---

### Шаг 3 — секретное содержимое ресурса random_password в state-файле

После выполнения `terraform apply` в файле `terraform.tfstate` в блоке
`resources` → `instances[0].attributes` найден ключ и его значение:

```
"result": "Gcqg5D06w5zpEoC1"
```

Важно: хотя `result` помечен как `sensitive_attributes`, в самом `.tfstate` он хранится
в открытом виде. Именно поэтому `.gitignore` исключает `*.tfstate` —
коммитить state-файлы в репозиторий нельзя.

---

### Шаг 4 — намеренные ошибки в закомментированном блоке

После раскомментирования блока `terraform validate` выявил следующие ошибки:

**Ошибка 1** — отсутствует имя ресурса:
```hcl
# Было:
resource "docker_image" {
# Стало:
resource "docker_image" "nginx" {
```
Блок `resource` требует два лейбла: тип и имя. Без имени Terraform не может создать
ресурс и ссылаться на него.

**Ошибка 2** — имя ресурса начинается с цифры:
```hcl
# Было:
resource "docker_container" "1nginx" {
# Стало:
resource "docker_container" "nginx" {
```
Идентификаторы в HCL обязаны начинаться с буквы или символа `_`.

**Ошибка 3** — обращение к несуществующему ресурсу:
```hcl
# Было:
name = "example_${random_password.random_string_FAKE.result}"
# Стало:
name = "example_${random_password.random_string.result}"
```
Ресурс `random_string_FAKE` не объявлен — объявлен только `random_string`.

**Ошибка 4** — неверный регистр атрибута:
```hcl
# Было:
name = "example_${random_password.random_string.resulT}"
# Стало:
name = "example_${random_password.random_string.result}"
```
HCL регистрозависим, атрибут называется `result`, а не `resulT`.

---

### Шаг 5 — исправленный фрагмент кода и вывод docker ps

Исправленный `main.tf`:

```hcl
resource "docker_image" "nginx" {
  name         = "nginx:latest"
  keep_locally = true
}

resource "docker_container" "nginx" {
  image = docker_image.nginx.image_id
  name  = "example_${random_password.random_string.result}"

  ports {
    internal = 80
    external = 9090
  }
}
```

Вывод `docker ps` после `terraform apply`:

```
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS                    NAMES
24906e4e2f2c   eaf6f386053e   "/docker-entrypoint.…"   9 seconds ago   Up 8 seconds   0.0.0.0:9090->80/tcp     example_Gcqg5D06w5zpEoC1
```

---

### Шаг 6 — переименование контейнера и флаг -auto-approve

Имя контейнера изменено на `hello_world` (изменён только атрибут `name` у `docker_container`,
атрибут `name = "nginx:latest"` у `docker_image` не трогался — это имя образа, а не контейнера):

```hcl
resource "docker_container" "nginx" {
  image = docker_image.nginx.image_id
  name  = "hello_world"
  ...
}
```

Вывод `docker ps` после `terraform apply -auto-approve`:

```
CONTAINER ID   IMAGE          COMMAND                  CREATED                  STATUS                  PORTS                    NAMES
84e5aefe18b4   eaf6f386053e   "/docker-entrypoint.…"   Less than a second ago   Up Less than a second   0.0.0.0:9090->80/tcp     hello_world
```

**Опасность `-auto-approve`:** флаг применяет план немедленно, без вывода diff'а и без запроса
подтверждения `yes`. В обычном `terraform apply` пользователь видит что именно
изменится/удалится/пересоздастся и может отменить операцию. С `-auto-approve` этой страховки нет —
ошибка в коде (например, случайное удаление продакшн-ресурса) применится мгновенно и необратимо.

**Зачем нужен:** в неинтерактивных сценариях — CI/CD пайплайнах, скриптах автоматизации —
где нет возможности вручную ввести `yes`.

---

### Шаг 8 — содержимое terraform.tfstate после destroy

```json
{
  "version": 4,
  "terraform_version": "1.12.2",
  "serial": 11,
  "lineage": "bf2b5c92-ba7c-00d9-d145-779cd38760bd",
  "outputs": {},
  "resources": [],
  "check_results": null
}
```

Массив `resources` пустой — все ресурсы удалены из state.

---

### Шаг 9 — почему не был удалён docker-образ nginx:latest

В файле `main.tf` у ресурса `docker_image` явно указан параметр:

```hcl
resource "docker_image" "nginx" {
  name         = "nginx:latest"
  keep_locally = true
}
```

Согласно документации провайдера `kreuzwerker/docker`, ресурс `docker_image`,
параметр `keep_locally`:

> If true, then the Docker image won't be deleted on destroy operation.

Источник: https://library.tf/providers/kreuzwerker/docker/latest/docs/resources/image#keep_locally

Таким образом, `terraform destroy` удалил контейнер и запись об образе из state,
но физически образ `nginx:latest` остался на диске хоста — именно потому что `keep_locally = true`.

Проверка после `terraform destroy`:
```
$ docker images | grep nginx
nginx   latest   eaf6f386053e   7 days ago   161MB
```

---

## Задание 2* — Remote Docker Context + MySQL

### Шаг 1 — создание ВМ

ВМ `terraform-vm` создана через web-консоль Yandex Cloud (Ubuntu 22.04, 2 CPU, 2 GB RAM,
публичный IP).

### Шаг 2 — установка Docker

Docker 29.6.0 установлен на `terraform-vm` через официальный скрипт `get.docker.com`.

### Шаг 3-4 — remote docker context и запуск MySQL

Terraform запущен с `docker-vm`, управляет Docker на `terraform-vm` через SSH.
Переменная `DOCKER_HOST` передаётся при запуске:

```bash
DOCKER_HOST="ssh://ubuntu@62.84.124.66" terraform apply -auto-approve
```

Итоговый `main.tf`:

```hcl
terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
    random = {
      source = "hashicorp/random"
    }
  }
  required_version = "~>1.12.0"
}

provider "docker" {
  host     = "ssh://ubuntu@62.84.124.66"
  ssh_opts = ["-o", "StrictHostKeyChecking=no", "-i", "/home/zolotkoff/.ssh/id_ed25519"]
}

resource "random_password" "mysql_root" {
  length  = 16
  special = false
}

resource "random_password" "mysql_user" {
  length  = 16
  special = false
}

resource "docker_image" "mysql" {
  name         = "mysql:8"
  keep_locally = true
}

resource "docker_container" "mysql" {
  image = docker_image.mysql.image_id
  name  = "mysql_${random_password.mysql_root.result}"

  ports {
    internal = 3306
    external = 3306
    ip       = "127.0.0.1"
  }

  env = [
    "MYSQL_ROOT_PASSWORD=${random_password.mysql_root.result}",
    "MYSQL_DATABASE=wordpress",
    "MYSQL_USER=wordpress",
    "MYSQL_PASSWORD=${random_password.mysql_user.result}",
    "MYSQL_ROOT_HOST=%",
  ]
}
```

Вывод `docker ps` на `terraform-vm`:

```
CONTAINER ID   IMAGE          COMMAND                  CREATED          STATUS          PORTS                                 NAMES
089d1f144bf4   d36d39a64cd1   "docker-entrypoint.s…"   31 seconds ago   Up 24 seconds   127.0.0.1:3306->3306/tcp, 33060/tcp   mysql_6Cz76CQmiH1Bgvlu
```

Проверка ENV-переменных внутри контейнера (`docker exec ... env`):

```
MYSQL_ROOT_HOST=%
MYSQL_ROOT_PASSWORD=6Cz76CQmiH1Bgvlu
MYSQL_PASSWORD=qVC4gb3vNEMYzWiQ
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
```
