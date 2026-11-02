# AGENTS.md

Инструкции для ИИ-агентов (и людей), которые меняют этот репозиторий. Что это за репозиторий и зачем он так
устроен — `README.md`. Здесь — правила, без которых изменение сломает кластер или шаблон.

## Модель репозитория

- Flux применяет `clusters/<кластер>` (`flux-system/gotk-sync.yaml`): Kustomization `crds` (`./crds`), затем `software`
  (`clusters/<кластер>/namespaces`, `dependsOn: crds`).
- `clusters/<кластер>/namespaces/<namespace>/` — всё, что есть в этом namespace: оператор (HelmRelease, values,
  источник чарта), его CR, NetworkPolicy, Secret'ы из Vault и scrape-конфиг. Конфиги и операторы не разносятся
  по разным каталогам и слоям — каталог namespace должен читаться как то, что стоит в кластере.
- Кластер самодостаточен: баз, бандлов, патчей и `postBuild.substitute` нет. Отличие кластера — прямо в его файлах.
  Общий компонент лежит копией в каждом кластере: меняете его — меняйте во всех кластерах одним изменением.
- В `namespaces/` нет `kustomization.yaml` — Flux собирает все каталоги сам. Внутри каталога namespace
  `kustomization.yaml` обязателен и задаёт `namespace:`.
- **Никакой вложенности.** В каталоге namespace — только файлы, без подкаталогов (`upstream/`, `generated/`, по
  компонентам или приложениям). Upstream-манифест кладётся рядом под понятным именем (`metrics-server.yaml`,
  `operator.yaml`), одноимённые файлы разных частей сливаются в один (`network-policy.yaml`, `image-automation.yaml`).
  То же в `crds/<оператор>-<версия>/`.

## Правила

1. **Никаких секретов в git.** Ни значений, ни сертификатов, ни ключей, ни kubeconfig. Secret приходит из Vault через
   `VaultStaticSecret` (VSO) с `includes` и путём `kv/<namespace>/…`. В комментарии к `VaultStaticSecret` — путь,
   ключи и откуда значение берётся, но не само значение.
2. **Никакой организационной специфики.** Это шаблон: домены — только `example.com`, адреса — из документационных
   или приватных диапазонов, никаких id чатов, имён команд и учётных записей (такие значения — в Vault). Перед завершением проверьте grep-ом, что не появились реальные домены, IP, токены, `PRIVATE KEY`.
3. **Версии закреплены.** Чарт — точная `version` (или `tag` + `digest` у OCIRepository); сторонний образ — точный
   тег, для образов с доступом к секретам (Vault, VSO, Grafana) — `tag@sha256:…`. Никаких `latest` и диапазонов
   у компонентов платформы. Диапазон semver допустим только у ImagePolicy
   и OCIRepository приложения.
4. **CRD — только в `crds/`.** У HelmRelease `install.crds: Skip` и `upgrade.crds: Skip`, в values подчарт/хук CRD
   выключен. Новая версия CRD — новый каталог `crds/<оператор>-<версия>` из релизного манифеста той же версии,
   что и чарт; sha256 манифеста — в комментарии `kustomization.yaml`.
5. **Данные не удаляются prune'ом.** Объекты с данными (CNPG `Cluster`, `Redis`, PVC, namespace Vault) — с аннотацией
   `kustomize.toolkit.fluxcd.io/prune: disabled` и на StorageClass `local-path-retain` (или другом с `Retain`).
6. **Values — через ConfigMap с хэшем.** `configMapGenerator` + `kustomizeconfig.yaml` (`nameReference` на
   `spec/valuesFrom/name`): правка values меняет имя ConfigMap, и HelmRelease обновляется.
7. **Безопасность пода.** Новый namespace — с метками Pod Security (`restricted`, если компонент это позволяет;
   исключение объяснить комментарием). Контейнеры — `runAsNonRoot`, `allowPrivilegeEscalation: false`, drop ALL,
   seccomp `RuntimeDefault`. К БД, кэшу и внутренним API — NetworkPolicy.
8. **Сбор метрик рядом с компонентом.** Новый компонент приносит scrape-конфиг (`VMPodScrape`/`VMServiceScrape`).
   ServiceMonitor не использовать: CRD prometheus-operator в кластере нет. VMRule в шаблон не добавлять: правила
   алертов у каждой команды свои, а скопированные из рабочей инфраструктуры выдают её устройство.
9. **Маршруты.** HTTPRoute ссылается на Gateway `internal` или `public` в `envoy-gateway-system`; namespace маршрута
    должен иметь метку `gateway.platform/internal: "true"` или `gateway.platform/public: "true"`.
10. **Образы приложений меняет Flux.** Тег в `values.yaml` приложения правит ImageUpdateAutomation его namespace
    по маркеру `# {"$imagepolicy": "<namespace>:<policy>:tag"}`. Маркер не удалять; namespace в маркере должен
    совпадать с namespace каталога.

## Комментарии и язык

- Язык комментариев и документации — русский.
- Комментарий объясняет **почему**: какое ограничение или поломка за решением стоит, что сломается, если его убрать.
  Пересказывать YAML не нужно.
- Ссылки на файлы — путём от корня репозитория или относительно (`../image-automation.yaml`).

## Проверка

После любого изменения манифестов:

```bash
./scripts/validate.sh
```

Нужны `kustomize` (или `kubectl`), `kubeconform`, `yq`, `python3`. Скрипт должен завершиться без `Invalid` и `Errors`.
Новый namespace или кластер подхватывается сам (`clusters/*/namespaces/*`). Новый CRD — только через `crds/kustomization.yaml`,
иначе для его CR не найдётся схемы.

## Git

- Коммиты — короткие, по-русски, с префиксом области: `workload/vault: …`, `management/vm-operator: …`, `crds: …`.
- В сообщениях коммитов и описаниях PR не упоминать ИИ-агентов и инструменты генерации: никаких `Co-Authored-By`
  ассистентов и подписей «Generated with …».
- Не коммитить в `flux/image-updates-*`: эти ветки пересоздаёт Flux.
