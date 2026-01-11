variable "yc_token" {}
variable "yc_cloud_id" {}
variable "yc_folder_id" {}
variable "db_password" {}

data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
}

# Настройки подключения 
provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = "ru-central1-a"
}

# Настройка Виртуальной сети 
resource "yandex_vpc_network" "project-net" {
  name = "media-network"
}

# Создаем подсеть в зоне А 
resource "yandex_vpc_subnet" "subnet-a" {
  name           = "subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.project-net.id
  v4_cidr_blocks = ["10.0.1.0/24"]
}

# Создаем подсеть в зоне B 
resource "yandex_vpc_subnet" "subnet-b" {
  name           = "subnet-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.project-net.id
  v4_cidr_blocks = ["10.0.2.0/24"]
}

resource "yandex_vpc_security_group" "db-sg" {
  name       = "database-sg"
  network_id = yandex_vpc_network.project-net.id

  # 1. SSH для управления
  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # 2. Входной HTTP трафик для балансировщика
  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # 3. Порт нашего приложения Python (для балансировщика и тестов)
  ingress {
    protocol       = "TCP"
    port           = 8000
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # 4. База данных Postgres
  ingress {
    protocol       = "TCP"
    port           = 5432
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # 5. КРИТИЧЕСКОЕ ПРАВИЛО: Разрешаем проверки здоровья (Health Checks) от балансировщика
  # Это те самые "well-known IP ranges", о которых просила ошибка
  ingress {
    protocol       = "TCP"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["198.18.235.0/24", "198.18.248.0/24"]
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Создаем сервисный аккаунт для работы приложения
resource "yandex_iam_service_account" "sa-backender" {
  name        = "sa-backender"
  description = "Аккаунт для управления S3 и БД"
}

# Назначаем ему роль 'editor' в нашем каталоге
resource "yandex_resourcemanager_folder_iam_member" "sa-editor" {
  folder_id = "b1gh8peu11vhj3r0fjko"
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa-backender.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.sa-backender.id
  description        = "static access key for object storage"
}

# Создаем бакет
resource "yandex_storage_bucket" "media-bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = "krokhalev-unique-media-bucket-2026" # Имя должно быть уникальным во всем мире
}

# Создаем отдельный диск для данных БД 
resource "yandex_compute_disk" "db-data" {
  name     = "db-persistence-disk"
  type     = "network-hdd"
  zone     = "ru-central1-a"
  size     = 10 # 10 ГБ хватит для начала
}

# Создаем Виртуальную Машину 
resource "yandex_compute_instance" "db-server" {
  name        = "db-server"
  platform_id = "standard-v3" # Тип процессора
  zone        = "ru-central1-a"

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20 # Экономим: ВМ будет использовать 20% мощности процессора (дешевле)
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id 
    }
  }

  # Подключаем наш созданный диск для данных как второй диск
  secondary_disk {
    disk_id     = yandex_compute_disk.db-data.id
    device_name = "data-disk"
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-a.id
    nat       = true 
    security_group_ids = [yandex_vpc_security_group.db-sg.id]
  }

  metadata = {
    
        user-data = <<EOF
#!/bin/bash
# 1. Установка Docker
apt-get update
apt-get install -y docker.io
systemctl start docker
systemctl enable docker

# Подготовка диска 
while [ ! -b /dev/vdb ]; do sleep 2; done
if ! blkid /dev/vdb; then
  mkfs.ext4 /dev/vdb
fi

# Монтирование
mkdir -p /mnt/postgres_data
mount /dev/vdb /mnt/postgres_data
echo '/dev/vdb /mnt/postgres_data ext4 defaults 0 2' >> /etc/fstab

# Настройка прав для Postgres
mkdir -p /mnt/postgres_data/data
chown -R 999:999 /mnt/postgres_data/data

# Запуск базы
docker run -d --name postgres-db \
  -e POSTGRES_PASSWORD=${var.db_password} \
  -e POSTGRES_DB=media_db \
  -p 5432:5432 \
  -v /mnt/postgres_data/data:/var/lib/postgresql/data \
  --restart always \
  postgres:15
EOF
    ssh-keys = "ubuntu:${file("~/.ssh/id_ed25519.pub")}"
  }
}

# Ресурс самой облачной функции
resource "yandex_function" "image-resizer" {
  name               = "image-resizer"
  description        = "Функция для создания превью"
  user_hash          = "v1"
  runtime            = "python311" # Версия Python в облаке
  entrypoint         = "index.handler" # Файл.функция
  memory             = 128
  execution_timeout  = "10"
  service_account_id = yandex_iam_service_account.sa-backender.id

  # Передаем ключи доступа внутрь функции
  environment = {
    ACCESS_KEY = yandex_iam_service_account_static_access_key.sa-static-key.access_key
    SECRET_KEY = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  }

  # Указываем, где лежит код функции 
  content {
    zip_filename = "function.zip"
  }
}

# Триггер: запускать функцию при создании объекта в бакете
resource "yandex_function_trigger" "s3-trigger" {
  name        = "s3-trigger"
  function {
    id = yandex_function.image-resizer.id
    service_account_id = yandex_iam_service_account.sa-backender.id
  }
  object_storage {
    bucket_id = yandex_storage_bucket.media-bucket.id
    create    = true # Реагировать на создание файла
    batch_cutoff = "10" # Максимальное время ожидания в секундах
    batch_size   = "1"  # Сколько событий обрабатывать за один раз
  }
}

# 1. Группа целевых ресурсов (наша ВМ с приложением)
resource "yandex_alb_target_group" "app-tg" {
  name = "app-target-group"

  target {
    subnet_id = yandex_vpc_subnet.subnet-a.id
    ip_address = yandex_compute_instance.db-server.network_interface.0.ip_address
  }
}

# 2. Группа бэкендов (настройки протокола)
resource "yandex_alb_backend_group" "app-bg" {
  name = "app-backend-group"

  http_backend {
    name             = "backend-1"
    weight           = 1
    port             = 8000 # Порт нашего FastAPI
    target_group_ids = [yandex_alb_target_group.app-tg.id]
    
    load_balancing_config {
      panic_threshold = 90
    }    
    healthcheck {
      timeout  = "1s"
      interval = "1s"
      http_healthcheck {
        path = "/"
      }
    }
  }
}

# 3. HTTP Роутер (правила путей)
resource "yandex_alb_http_router" "app-router" {
  name = "app-http-router"
}

resource "yandex_alb_virtual_host" "app-host" {
  name           = "app-host"
  http_router_id = yandex_alb_http_router.app-router.id
  route {
    name = "route-all"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.app-bg.id
        timeout          = "3s"
      }
    }
  }
}

# 4. Сам Балансировщик (публичная точка входа)
resource "yandex_alb_load_balancer" "app-balancer" {
  name               = "app-balancer"
  network_id         = yandex_vpc_network.project-net.id
  security_group_ids = [yandex_vpc_security_group.db-sg.id]

  allocation_policy {
    location {
      zone_id   = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.subnet-a.id
    }
  }

  listener {
    name = "http-listener"
    endpoint {
      address {
        external_ipv4_address {
        }
      }
      ports = [80] # Балансировщик будет слушать обычный 80 порт
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.app-router.id
      }
    }
  }
}

# Вывод IP-адреса балансировщика
output "balancer_ip" {
  value = yandex_alb_load_balancer.app-balancer.listener[0].endpoint[0].address[0].external_ipv4_address[0].address
}

# Бакет для статических файлов (фронтенда)
resource "yandex_storage_bucket" "frontend-bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = "my-unique-frontend-2026-v1" # Сделай имя УНИКАЛЬНЫМ

  # Вместо старого acl = "public-read" используем это:
  anonymous_access_flags {
    read = true
    list = false
  }

  website {
    index_document = "index.html"
  }
}

resource "yandex_resourcemanager_folder_iam_member" "sa-storage-admin" {
  folder_id = "b1gh8peu11vhj3r0fjko" 
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa-backender.id}"
}