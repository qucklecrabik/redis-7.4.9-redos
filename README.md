# Сборка и установка Redis 7.4.9 в виде RPM-пакета на RED OS 8

В этом руководстве описано, как собрать Redis **7.4.9** из исходного кода в
нативный RPM-пакет для **RED OS 8** (дистрибутив RHEL-семейства,
`platform:red80`), установить его и запустить как службу `systemd`.

Всё описанное ниже было выполнено и проверено «от и до» на локальной виртуальной машине RED OS 8.0.2: сборка RPM, установка пакета и запуск
29 функциональных автотестов на работающей службе — см. раздел
[Приложение: журнал проверки эталонной сборки](#приложение-журнал-проверки-эталонной-сборки).

Артефакты эталонной сборки (spec-файл, unit-файл systemd, конфигурация,
скрипт автотестов и итоговые `.rpm`/`.src.rpm`) приложены рядом с этим
документом в каталогах `SPECS/`, `SOURCES/`, `RPMS/` и `tests/`.

---

## 1. Требования

- Хост с RED OS 8 (проверено на RED OS 8.0.2, ядро `6.12.92-1.red80`).
- Исходящий доступ по HTTPS для загрузки архива с исходным кодом Redis.
- Не менее ~1 ГБ свободного места на диске и 1 ГБ+ ОЗУ для сборки.

## 2. Установка инструментов сборки

В RED OS 8 нет пакета `redhat-rpm-config` под этим именем — его аналог
называется **`redos-rpm-config`**. Всё остальное — стандартный набор
инструментов RPM плюс зависимости сборки самого Redis (OpenSSL для
поддержки TLS, `systemd-devel` для поддержки `sd_notify`, `jemalloc-devel`
для аллокатора jemalloc).

```bash
sudo dnf -y install \
    gcc gcc-c++ \
    rpm-build rpmdevtools redos-rpm-config \
    openssl-devel systemd-devel jemalloc-devel tcl-devel \
    wget
```

Создайте стандартное дерево каталогов `rpmbuild` в домашней директории:

```bash
rpmdev-setuptree
# создаёт ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
```

## 3. Загрузка исходного кода Redis 7.4.9

Во время сборки `download.redis.io` отвечал `403 Forbidden` на прямые
запросы `wget` (заблокировано из Российской Федерации); тот же исходный
код загружается по тегу релиза на GitHub:

```bash
cd ~/rpmbuild/SOURCES
wget --user-agent="Mozilla/5.0" -O redis-7.4.9.tar.gz \
    https://github.com/redis/redis/archive/refs/tags/7.4.9.tar.gz
```

Проверьте, что версия правильная:

```bash
tar xzf redis-7.4.9.tar.gz -C /tmp && \
    grep REDIS_VERSION /tmp/redis-7.4.9/src/version.h
# #define REDIS_VERSION "7.4.9"
rm -rf /tmp/redis-7.4.9
```

## 4. Вспомогательные файлы для сборки пакета

Три файла, размещённые в каталоге `SOURCES/` рядом с этим документом,
нужно скопировать в `~/rpmbuild/SOURCES/`:

| Файл | Назначение |
|---|---|
| `redis.conf` | Стандартный `redis.conf`, адаптированный для промышленной эксплуатации в виде службы: `supervised systemd`, `pidfile /var/run/redis/redis.pid`, `logfile /var/log/redis/redis.log`, `dir /var/lib/redis`. |
| `redis.service` | Unit-файл `systemd`, запускающий Redis от имени непривилегированного пользователя `redis`. |
| — | Скриптлет `%pre` RPM-пакета (в spec-файле) создаёт системного пользователя/группу `redis`. |

**Важная особенность RED OS:** в RED OS 8 уже есть встроенная политика
SELinux для Redis (домены/типы `redis_t`, `redis_exec_t`, `redis_conf_t`,
`redis_log_t` уже существуют, и файлы, установленные из RPM, автоматически
получают правильные метки). Директивы усиления защиты systemd, такие как
`NoNewPrivileges=yes`, **ломают эту схему**, так как блокируют переход
домена SELinux из `init_t` в `redis_t` (отказ `nnp_transition` в AVC), из-за чего Redis не может даже открыть собственный лог-файл. **Не указывайте
`NoNewPrivileges=yes`** (и другие опции, подразумевающие это поведение) в
unit-файле на хостах RED OS с включённым режимом enforcing для SELinux —
полагайтесь на штатную политику SELinux дистрибутива вместо повторной
реализации песочницы в unit-файле.

Предоставленный `redis.service`:

```ini
[Unit]
Description=Redis persistent key-value database
Documentation=https://redis.io/documentation
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/redis-server /etc/redis/redis.conf --supervised systemd
TimeoutStartSec=infinity
TimeoutStopSec=infinity
Restart=on-failure

User=redis
Group=redis
RuntimeDirectory=redis
RuntimeDirectoryMode=0750
UMask=0077
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Скопируйте оба файла на место:

```bash
cp redis.conf redis.service ~/rpmbuild/SOURCES/
```

## 5. Spec-файл RPM

Поместите `redis.spec` (находится в `SPECS/`) в `~/rpmbuild/SPECS/`.
Ключевые моменты — на случай, если потребуется адаптация:

- **`PREFIX=%{buildroot}%{_prefix}` вместо `DESTDIR=`.** Верхнеуровневый
  `Makefile` / `src/Makefile` Redis **не поддерживает** привычную
  переменную `DESTDIR` — только `PREFIX`. Если передать только
  `DESTDIR=%{buildroot}` (как это обычно принято в RPM), установка молча
  пойдёт прямиком в настоящий `/usr/bin` и завершится ошибкой `Permission
  denied` на шаге `%install`, выполняемом не от root. Решение — направить
  саму переменную `PREFIX` в buildroot:
  ```
  make install PREFIX=%{buildroot}%{_prefix} BUILD_TLS=yes USE_SYSTEMD=yes MALLOC=jemalloc
  ```
- Использованные флаги сборки: `BUILD_TLS=yes` (поддержка TLS через
  `openssl-devel`), `USE_SYSTEMD=yes` (нативная поддержка `sd_notify` через
  `systemd-devel`), `MALLOC=jemalloc` (через `jemalloc-devel`).
- `%pre` создаёт отдельного системного пользователя/группу `redis` (домашний
  каталог `/var/lib/redis`, оболочка `/sbin/nologin`) через `shadow-utils`.
- `%post`/`%preun`/`%postun` используют стандартные макросы `%systemd_*` для
  корректной регистрации/отмены регистрации unit-файла при установке,
  обновлении и удалении пакета.
- Пакет включает бинарники: `redis-server`, `redis-cli`, `redis-benchmark`,
  `redis-check-aof`, `redis-check-rdb`, `redis-sentinel` (последние три —
  символические ссылки на `redis-server`, созданные собственным `make
  install` Redis).
- Каталоги `/var/lib/redis` и `/var/log/redis` принадлежат `redis:redis`,
  права `0750`; `/etc/redis/redis.conf` имеет права `0640 redis:redis` и
  помечен `%config(noreplace)`, чтобы локальные изменения сохранялись при
  обновлении пакета.

## 6. Сборка RPM

```bash
cd ~/rpmbuild
rpmbuild -bb SPECS/redis.spec
```

В результате будут созданы:

```
~/rpmbuild/RPMS/x86_64/redis-7.4.9-1.red80.x86_64.rpm
~/rpmbuild/RPMS/x86_64/redis-debuginfo-7.4.9-1.red80.x86_64.rpm
```

(Сборка `-bs` для получения только source RPM, использовавшаяся во время
разработки для быстрой проверки корректности spec-файла, создаёт
`~/rpmbuild/SRPMS/redis-7.4.9-1.red80.src.rpm`.)

## 7. Установка и запуск службы

```bash
sudo dnf -y install ~/rpmbuild/RPMS/x86_64/redis-7.4.9-1.red80.x86_64.rpm

# Рекомендовано самим Redis для стабильного фонового сохранения при нехватке памяти:
echo "vm.overcommit_memory = 1" | sudo tee /etc/sysctl.d/99-redis.conf
sudo sysctl -p /etc/sysctl.d/99-redis.conf

sudo systemctl enable --now redis
sudo systemctl status redis
```

Ожидаемый результат: `Active: active (running)`, служба слушает
`127.0.0.1:6379` по умолчанию (для развёртываний с доступом из сети
отредактируйте `bind`/`requirepass`/`protected-mode` в
`/etc/redis/redis.conf` и выполните `systemctl restart redis`).

Быстрая проверка работоспособности:

```bash
redis-cli ping
# PONG
```

## 8. Удаление / пересборка

```bash
sudo systemctl disable --now redis
sudo dnf -y remove redis
```

После удаления пакета системный пользователь `redis`, каталоги
`/etc/redis`, `/var/lib/redis` и `/var/log/redis` остаются на месте
(стандартное поведение RPM для учётных записей служб и каталогов с
данными) — при необходимости полной очистки удалите их вручную.

---

## Приложение: журнал проверки эталонной сборки

Ниже описано, что было выполнено на локальной вирутальной машине (RED OS 8.0.2, 2 vCPU / 2 ГБ ОЗУ) для проверки каждого шага выше, с
использованием тех же самых spec- и unit-файлов, что приложены к этому
репозиторию:

1. Установлены инструменты сборки, загружены исходники, собраны сначала
   SRPM, а затем бинарный RPM — сборка прошла успешно после исправления
   проблемы `DESTDIR` → `PREFIX`, описанной в разделе 5.
2. Первая попытка установки/запуска **завершилась неудачей**: `systemctl
   status redis` показывал `Can't open the log file: Permission denied`,
   несмотря на то что пользователь `redis` явно имел право записи в
   `/var/log/redis` при ручной проверке (`sudo -u redis touch
   /var/log/redis/test.log` выполнялась успешно). Анализ через `sudo
   ausearch`/`journalctl` показал отказ SELinux (AVC):
   `avc: denied { nnp_transition } ... scontext=init_t tcontext=redis_t`,
   вызванный директивой `NoNewPrivileges=yes` в unit-файле — после удаления
   этой директивы (а также избыточных `ProtectSystem=full`/
   `ReadWritePaths=`, зависевших от неё) переход домена стал возможен, и
   служба запустилась без ошибок.
3. RPM пересобран с исправленным unit-файлом, пакет заново установлен
   через `dnf`, служба включена и запущена, а также установлен параметр
   `vm.overcommit_memory = 1`, как рекомендовано самим Redis в
   предупреждении при старте.
4. Запущен скрипт автотестов (`tests/redis_autotest.sh`, приложен) на
   работающей службе. Результат:

   ```
   ================= SUMMARY =================
   PASS: 29   FAIL: 0
   All Redis functionality checks passed.
   ```

   Покрытие тестами: состояние пакета/службы, `PING`, строка версии,
   строковые операции (`SET`/`GET`/`APPEND`/`INCRBY`/`EXPIRE`), списки
   (lists), хеши (hashes), множества (sets), упорядоченные множества
   (sorted sets), истечение срока действия ключей (TTL), транзакции
   `MULTI`/`EXEC`, `PUBLISH`/`SUBSCRIBE`, скрипты Lua (`EVAL`),
   `SAVE`/наличие RDB-файла на диске, проверка целостности через
   `redis-check-rdb`, **сохранность данных после `systemctl restart
   redis`** (проверка персистентности), а также подтверждение того, что
   запущенный сервер действительно читает `/etc/redis/redis.conf`
   (значение `CONFIG GET port` совпадает с заданным).

Вы можете запустить эти проверки самостоятельно в любой момент после
установки пакета:

```bash
bash tests/redis_autotest.sh
```
