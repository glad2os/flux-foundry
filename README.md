# flux-foundry

Шаблон GitOps-репозитория на [Flux](https://fluxcd.io) для команды, которая ведёт несколько Kubernetes-кластеров
и свои приложения в них. Это не каталог аддонов «на выбор», а собранная и проверенная платформа:
вход (Gateway API, Envoy Gateway), TLS (cert-manager, внутренний CA и Let's Encrypt), секреты (Vault и Vault Secrets
Operator), операторы БД (CloudNativePG, redis-operator), наблюдаемость (VictoriaMetrics, VictoriaLogs, Grafana) —
и пример приложения, которое всем этим пользуется.

В репозитории два примера кластеров:

| Кластер | Роль | Что на нём |
|---|---|---|
| `management` | хаб | Vault, хранилища метрик и логов всех кластеров, Grafana, корень внутреннего CA, dev-окружение приложения (только VPN) |
| `workload` | прод, spoke | приложение, публичный вход и Let's Encrypt, свой Vault, локальные алерты; метрики и логи уходят в хаб |

Все имена — `example.com`, все секреты и адреса получателей алертов — в Vault, в git нет ни одного ключа и сертификата.

## Принципы

1. **Один namespace — один каталог.** В `clusters/<кластер>/namespaces/<namespace>` лежит всё, что есть в этом
   namespace: оператор (HelmRelease, values, источник чарта), его CR (Issuer, Gateway, хранилища метрик, Grafana),
   NetworkPolicy, Secret'ы из Vault и scrape-конфиг. Хотите узнать, что и как стоит в `vault` на проде —
   откройте `clusters/workload/namespaces/vault`.
2. **Кластер самодостаточен.** Каталог кластера — это и есть кластер: никаких баз, бандлов, патчей и подстановок.
   Отличия кластеров (реплики, хосты, адреса) записаны прямо в файлах их namespace. Цена — общий компонент лежит
   копией в каждом кластере; обновление версии Renovate делает одним PR во всех кластерах сразу.
3. **CRD отдельно и под замком.** CRD всех операторов вендорятся в `crds/<оператор>-<версия>` из релизных манифестов
   (sha256 — в комментарии) и применяются Kustomization `crds` раньше `software`. Чарты ставятся с `crds: Skip`.
   На CRD стоит `prune: disabled`: удаление каталога из git не уничтожит все CR в кластере.
4. **Секретов в git нет.** VSO синхронизирует Secret'ы из Vault, политика пускает namespace только в `kv/<namespace>/*`,
   в Secret попадают только ключи из `includes`. Даже конфиг Alertmanager (куда слать алерты) собирается из Vault по шаблону.
5. **Компонент приносит свой сбор метрик.** VMPodScrape/VMServiceScrape лежат в каталоге namespace.
   Дашбордов в шаблоне нет, только образец `grafana-operator/dashboard-example.yaml`. VMAlert и Alertmanager развёрнуты, но правил (VMRule) в шаблоне нет:
   пороги и алерты у каждой команды свои — кладите VMRule в каталог namespace, который они описывают.
6. **Dev обновляется сам, прод — через ревью.** ImageUpdateAutomation в `example-dev` коммитит новый тег прямо в `main`.
   В `example` (прод) она пушит в ветку `flux/image-updates-workload`, CI открывает PR, и образ попадает в прод
   только после merge.
7. **Безопасно по умолчанию.** Pod Security `restricted` везде, где это возможно; `securityContext` с drop ALL,
   read-only rootfs и seccomp; NetworkPolicy к БД, Redis, Vault и Grafana; версии точные, а образы с доступом
   к секретам (Vault, VSO, Grafana) и чарт Envoy Gateway закреплены по digest; данные (Postgres, Redis, Vault, Grafana) —
   на StorageClass с `reclaimPolicy: Retain` и с `prune: disabled`.
8. **Комментарий объясняет «почему».** Неочевидное решение описано одной-двумя строками рядом с кодом.

## Структура

```
crds/                                   CRD операторов, по каталогу на версию (общие для всех кластеров)
clusters/<кластер>/
  flux-system/                          Flux (пишет flux bootstrap)
  crds.yaml                             Kustomization crds → ./crds
  software.yaml                         Kustomization software → ./clusters/<кластер>/namespaces, после crds
  namespaces/
    cert-manager/                       чарт + ClusterIssuer'ы и CA кластера
    envoy-gateway-system/               чарт + EnvoyProxy, Gateway, сертификаты, редирект
    vault/  vault-secrets-operator/     Vault на Raft и VSO
    vm-operator/                        оператор + хранилища, VMAgent, VMAlert, Alertmanager, ingest
    vlagent/                            сбор логов подов
    grafana-operator/                   оператор + инстанс Grafana, источники данных, образец дашборда (только хаб)
    cnpg-system/  redis-operator/       операторы БД
    kube-state-metrics/  node-exporter/  local-path-storage/  flux-system/ (мониторинг Flux)
    kube-system/                        metrics-server: upstream components.yaml + патч, как задумано upstream
    example-dev/ | example/             namespace приложения example-app вместе с его ImageUpdateAutomation
scripts/validate.sh                     сборка и проверка схем каждого namespace (то же в CI)
.github/workflows/                      validate (сборка + diff в PR), image-updates (PR с новыми образами для прода)
renovate.json                           обновления чартов и образов через PR
```

В `namespaces/` нет `kustomization.yaml`: Flux сам собирает все каталоги внутри. Новый namespace — новый каталог,
больше ничего прописывать не нужно.

## Почему не awesome-flux-infra

[brainfair/awesome-flux-infra](https://github.com/brainfair/awesome-flux-infra) — хороший каталог: 43 аддона,
Renovate и промоушен flex → stable. Но для команды, которая ведёт свои приложения на нескольких кластерах,
его структура неудобна: чтобы понять, что стоит в кластере, нужно собрать в голове три уровня (база → бандл → кластер).

| | awesome-flux-infra | flux-foundry |
|---|---|---|
| Где версия и настройки компонента | в базе версии нет; она в патчах бандла (`docker-flex.yaml`, `docker-stable.yaml` — 30+ HelmRelease в одном файле). Что стоит в кластере, видно только после `kustomize build` | в `clusters/<кластер>/namespaces/<ns>/`: release, values, CR — рядом, как есть в кластере |
| Как убрать ненужное | база толстая, бандл вычитает лишнее через `$patch: delete`, по отдельному файлу на объект (обход бага kustomize) | удалить каталог namespace |
| Промоушен | flex → stable: Flux Alert → `repository_dispatch` → workflow ищет HelmRelease через `yq` и правит версию в stable; нужен PAT, список namespace в Alert ведётся вручную. При этом stable отстаёт от flex на минорные версии и подключён только к тестовому кластеру | версии платформы — PR от Renovate; образы приложений — ImageUpdateAutomation: dev сразу в `main`, прод — PR из ветки обновлений |
| Переменные кластера | глобальный `postBuild.substitute` на весь бандл: каждый дашборд Grafana приходится помечать `substitute: disabled`, иначе Flux портит `${…}` в JSON | подстановок нет: имена хостов и адреса записаны в файлах namespace, их видно в diff PR |
| Репозитории | три: bootstrap (head), CRD, аддоны | один: Flux, CRD и всё содержимое кластеров |
| Секреты | ESO, пример — генератор пароля | Vault + VSO, политика по namespace, `includes` вместо всех ключей |
| Безопасность | values чартов по умолчанию; NetworkPolicy и меток Pod Security нет | PSS restricted, NetworkPolicy, `securityContext`, digest у критичных образов |
| Приложения | только инфраструктурные аддоны | пример приложения с БД, кэшем, секретами, метриками, маршрутами и автовыкаткой |
| Несколько кластеров | бандл на тип окружения | хаб и spoke: метрики и логи spoke — в хабе, в своих tenant'ах; у spoke свои локальные алерты |

Где awesome-flux-infra сильнее: каталог шире (Istio, KEDA, Kyverno, Loki, Airflow и др.), и общий компонент описан
один раз, а не копией в каждом кластере. Здесь копия — сознательная цена за то, что кластер читается без сборки.

## Быстрый старт

1. Создайте репозиторий из шаблона и замените имена:
   - `example.com`, `internal.example.com`, `mgmt.internal.example.com`, `prod.internal.example.com`, `app.example.com` — на свои зоны;
   - `ssh://git@github.com/your-org/flux-foundry.git` в `clusters/*/flux-system/gotk-sync.yaml` — на адрес своего репозитория;
   - `10.8.0.0/16` в `clusters/*/namespaces/envoy-gateway-system/envoyproxy-internal.yaml` — на сеть своего VPN;
   - `id.example.com` и группы в `clusters/management/namespaces/grafana-operator/grafana.yaml` — на свой OIDC-провайдер.
2. Переименуйте кластеры под себя: каталог `clusters/<имя>`, путь в `software.yaml` и `gotk-sync.yaml`, имена CR и метки
   `cluster` в `namespaces/vm-operator` и `namespaces/vlagent`.
3. Bootstrap Flux на каждом кластере. Ключ нужен с правом записи — им ImageUpdateAutomation пушит новые теги:

   ```bash
   flux bootstrap git --url=ssh://git@github.com/your-org/flux-foundry.git --branch=main --path=clusters/management --read-write-key
   ```

4. Инициализируйте и распечатайте Vault (`vault operator init`, затем `vault operator unseal` на каждом поде), заведите
   KV v2 на пути `kv`, auth-метод `kubernetes`, политику и роль `vault-auth`: роль привязана к ServiceAccount `vault-auth`
   в любом namespace, политика пускает namespace только в `kv/<namespace>/*`.
5. Положите секреты в Vault каждого кластера. Пути и ключи — в комментариях `vault-secrets.yaml`:

   | Кластер | Путь в `kv` | Ключи |
   |---|---|---|
   | оба | `vm-operator/alertmanager/telegram` | `chat_id`, `bot_token` |
   | management | `vm-operator/vmauth/workload-metrics`, `vm-operator/vmauth/workload-logs` | `token` |
   | management | `grafana-operator/grafana/oidc` | `client_secret` |
   | management | `example-dev/example-app/postgres` | `username`, `password` |
   | workload | `vm-operator/remote-write-management`, `vlagent/remote-write-management` | `token` (те же, что `workload-metrics`/`workload-logs` на хабе) |
   | workload | `vm-operator/internal-ca`, `vlagent/internal-ca` | `ca.crt` — корень внутреннего CA |
   | workload | `cert-manager/intermediate-ca` | `tls.crt`, `tls.key`, `ca.crt` — промежуточный CA |
   | workload | `example/example-app/postgres` | `username`, `password` |

6. Проверьте:

   ```bash
   flux get kustomizations
   ```

   На первом запуске `software` может пройти не с первой попытки: CR, пришедший раньше webhook'а своего оператора
   (cert-manager, vm-operator), Flux применит на следующем цикле (`retryInterval: 2m`).

### Промежуточный CA для spoke

Корень внутреннего CA живёт только на хабе (`clusters/management/namespaces/cert-manager`). Для `workload` хаб выпускает
промежуточный CA с `nameConstraints` на `prod.internal.example.com`. Его ключ кладут в Vault workload, а оттуда VSO
синхронизирует его в cert-manager. После выпуска и после каждого продления (раз в 5 лет) перенесите Secret
из хаба в Vault workload, не сохраняя на диск (`vault kv put … -` читает JSON со stdin):

```bash
kubectl --context management -n cert-manager get secret workload-intermediate-ca -o json | jq '.data | map_values(@base64d)' | VAULT_ADDR=https://vault.prod.internal.example.com vault kv put kv/cert-manager/intermediate-ca -
```

Корень внутреннего CA (`ca.crt` того же Secret) положите в `kv/vm-operator/internal-ca` и `kv/vlagent/internal-ca`
Vault workload: по нему агенты проверяют сертификат ingest хаба.

### Подключить spoke к хабу

Spoke пишет в хаб через VMAuth ingest (`https://vm-ingest.mgmt.internal.example.com`) по Bearer-токену. Пользователь =
кластер: у метрик свой tenant VMCluster, у логов — свой AccountID VictoriaLogs.

1. На хабе, в `clusters/management/namespaces/vm-operator`: пара VMUser в `vm-ingest.yaml` (следующий
   свободный tenant) и их токены в `vault-secrets.yaml`;
   источники данных — в `grafana-operator/datasources-<spoke>.yaml`.
2. Сгенерируйте токены (`openssl rand -hex 32`) и положите их в Vault хаба (`kv/vm-operator/vmauth/<spoke>-*`)
   и в Vault spoke (`kv/vm-operator/remote-write-management`, `kv/vlagent/remote-write-management`).
3. На spoke: адрес ingest и метка `cluster` — в `vm-operator/vmagent.yaml` и `vlagent/vlagent.yaml`.

Что spoke перестал присылать данные, видно по счётчикам VMAuth на хабе (`vmauth_user_requests_total` по `username`),
а проблемы отправки на самом spoke — по `vmagent_remotewrite_pending_data_bytes` и `vlagent_remotewrite_*`.
На них стоит завести свои VMRule: это и dead man's switch для spoke.

## Как пользоваться

### Новое приложение

1. Скопируйте `clusters/<кластер>/namespaces/example-dev` в `namespaces/<namespace>`. Замените чарт (`oci-repository.yaml`), values, хост в `http-route.yaml`, путь в Vault
   (`kv/<namespace>/…`), маркер `$imagepolicy` (`<namespace>:<policy>:tag`) и путь в `image-automation.yaml`.
   Не нужна БД или кэш — уберите `postgres.yaml` или `redis.yaml` вместе с их NetworkPolicy.
2. То же — в каждом кластере, где приложение должно жить (dev — на management, прод — на workload).
3. Добавьте образ приложения в правило Renovate «тег ведёт Flux» (`renovate.json`), иначе Renovate и Flux будут править тег наперебой.


### Новый компонент платформы

Каталог `namespaces/<namespace>` в каждом кластере, где он нужен: namespace с Pod Security, источник чарта,
HelmRelease с `crds: Skip`, values в ConfigMap через `configMapGenerator`, его CR и scrape-конфиг.
CRD — в `crds/<имя>-<версия>` и строкой в `crds/kustomization.yaml`.

### Новый кластер

Скопируйте `clusters/workload` (spoke) или `clusters/management` (хаб), поправьте пути в `software.yaml` и
`flux-system/gotk-sync.yaml`, имена хостов, имена CR и метки `cluster`, затем bootstrap. Spoke подключите к хабу (см. выше).

### Обновления

- **Чарты и образы компонентов** — PR от Renovate (`renovate.json`): одна зависимость обновляется во всех кластерах
  одним PR. У операторов с CRD в `crds/` (метка `crds` в PR) перед merge перегенерируйте CRD: новый каталог
  `crds/<оператор>-<версия>` из релизного манифеста той же версии, строка в `crds/kustomization.yaml`, старый каталог —
  удалить. CRD обновляются до контроллера: Kustomization `crds` применяется первой.
- **Образы приложений** — Flux image automation (см. «Принципы», п. 6). Renovate тег приложения не трогает.
- **Flux** — `flux install --export > clusters/<кластер>/flux-system/gotk-components.yaml` новой версией CLI
  (или повторный `flux bootstrap`).

### Проверка до merge

```bash
./scripts/validate.sh
```

Скрипт собирает каждый namespace каждого кластера так же, как Flux (`kustomize build`), и проверяет результат
kubeconform по схемам Kubernetes, Flux и CRD из `crds/`. Схемы строгие, поэтому опечатка в поле CR — тоже ошибка.
То же делает CI на каждый PR и прикладывает diff собранных манифестов с `main`.

PR, который открывает `image-updates.yaml` с `GITHUB_TOKEN`, не запускает другие workflow — это ограничение GitHub.
Чтобы на нём тоже работал `validate`, создавайте PR токеном GitHub App или PAT.

## Чего здесь нет

Это стоит добавить до настоящего прода, но в шаблоне пока нет:

- **Бэкапов Postgres.** CNPG без `backup` и `ScheduledBackup`: потеря ноды или диска = потеря данных. Нужен
  barman-cloud plugin и объектное хранилище, плюс проверочное восстановление.
- **Бэкапов и auto-unseal Vault.** Каждый рестарт пода требует ручного unseal, снапшотов Raft нет.
- **HA у хранилищ наблюдаемости.** VMCluster, VLSingle и Alertmanager — по одной реплике.
- **Policy engine** (Kyverno, Gatekeeper) и проверки подписей образов (cosign `verify` у OCIRepository).
- **Правил алертов (VMRule).** VMAlert и Alertmanager есть, правил нет. Метрики для них уже собираются: состояние
  объектов Flux (`gotk_resource_info`), kube-state-metrics, node-exporter, Envoy, Vault, CNPG, Redis, отправка в хаб.
- **Дашбордов.** Только образец `example-dashboard/example.yaml`; свои — JSON из Grafana (Share → Export) в такие же файлы.
- **Уведомлений Flux** (Provider/Alert).
