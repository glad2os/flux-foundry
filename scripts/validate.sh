#!/usr/bin/env bash
# Проверка репозитория так, как его соберёт Flux: kustomize build каждого namespace каждого кластера и kubeconform
# по схемам Kubernetes, Flux и CRD из crds/ (а не по внешнему каталогу — версии схем совпадают с кластером).
#   ./scripts/validate.sh            # все кластеры
#   ./scripts/validate.sh workload   # один кластер
# Нужны: kustomize (или kubectl), kubeconform, yq, python3. CI — .github/workflows/validate.yaml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

k8s_version="${K8S_VERSION:-1.34.0}"
schemas="$(mktemp -d)"
trap 'rm -rf "$schemas"' EXIT

build() {
  if command -v kustomize >/dev/null; then
    kustomize build --load-restrictor=LoadRestrictionsNone "$1"
  else
    kubectl kustomize --load-restrictor=LoadRestrictionsNone "$1"
  fi
}

# Схемы CRD: openapi из crds/ и из gotk-components (Flux) → JSON Schema в раскладке kubeconform
# ({group}/{kind}_{version}.json, имена в нижнем регистре). Строго, как openapi2jsonschema --strict: у объекта с
# properties лишние поля запрещены (кроме x-kubernetes-preserve-unknown-fields) — опечатка в поле CR даёт ошибку.
echo "INFO схемы CRD"
{ build crds; yq 'select(.kind == "CustomResourceDefinition")' clusters/*/flux-system/gotk-components.yaml; } |
  yq -o=json -I=0 'select(.kind == "CustomResourceDefinition")' |
  python3 -I -c '
import json, os, sys
out = sys.argv[1]

def strict(node):
    if isinstance(node, dict):
        if ("properties" in node and "additionalProperties" not in node
                and not node.get("x-kubernetes-preserve-unknown-fields")):
            node["additionalProperties"] = False
        for value in node.values():
            strict(value)
    elif isinstance(node, list):
        for value in node:
            strict(value)

for line in sys.stdin:
    line = line.strip()
    if not line or line == "---":
        continue
    crd = json.loads(line)
    group = crd["spec"]["group"]
    kind = crd["spec"]["names"]["kind"].lower()
    for v in crd["spec"]["versions"]:
        schema = (v.get("schema") or {}).get("openAPIV3Schema")
        if not schema:
            continue
        os.makedirs(os.path.join(out, group), exist_ok=True)
        with open(os.path.join(out, group, f"{kind}_{v['"'"'name'"'"']}.json"), "w") as f:
            strict(schema)
            json.dump(schema, f)
' "$schemas"

# Сами CRD не проверяем: схемы apiextensions в каталоге kubeconform нет, а их содержимое и так стало схемами выше.
kubeconform_args=(
  -strict
  -skip CustomResourceDefinition
  -summary
  -kubernetes-version "$k8s_version"
  -schema-location default
  -schema-location "$schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
)

clusters=("$@")
if [[ ${#clusters[@]} -eq 0 ]]; then
  clusters=()
  for d in clusters/*/; do clusters+=("$(basename "$d")"); done
fi

status=0
echo "INFO crds"
build crds | kubeconform "${kubeconform_args[@]}" - || status=1
for cluster in "${clusters[@]}"; do
  for dir in "clusters/$cluster" "clusters/$cluster"/namespaces/*/; do
    dir="${dir%/}"
    echo "INFO $dir"
    build "$dir" | kubeconform "${kubeconform_args[@]}" - || status=1
  done
done
exit "$status"
