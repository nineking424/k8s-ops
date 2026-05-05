# 새 컴포넌트 도입

새 클러스터-레벨 컴포넌트(StorageClass, Operator, 차트)를 본 프로젝트에 올릴 때의 표준 흐름. 폴더 컨벤션의 깊은 컨텍스트는 [컴포넌트 추가 컨벤션](../developer/contributing.md), 시크릿 처리는 [시크릿 처리](../developer/secrets.md) 참고.

## 폴더 컨벤션

본 프로젝트는 컴포넌트별로 평면 폴더를 둔다.

```
<component>/
├── README.md           # 무엇 / 왜 / 의존 / 설치 / 검증 / 트러블슈팅 / 제거
├── install.sh          # helm upgrade --install 또는 kubectl apply 단일 진입점
├── values.template.yaml # (Helm) 시크릿 placeholder만 박혀 있는 Git 추적 템플릿
├── values.yaml         # (Helm) 실제 값. 시크릿 들어가면 .gitignore
└── *.yaml              # 추가 매니페스트 (IPAddressPool, Issuer, Secret 등)
```

폴더 이름은 **Helm 차트 이름** 또는 일반 통용 명을 따른다 — `metrics-server`, `nfs-subdir-external-provisioner`, `metallb`, `ingress-nginx`, `kube-prometheus-stack` 식.

## Helm vs raw manifest

| 방식 | 언제 | 진입점 |
|---|---|---|
| **Helm (권장)** | 차트가 있는 모든 컴포넌트 | `install.sh`에 `helm repo add` → `helm upgrade --install <release> <chart> -n <ns> --create-namespace -f values.yaml --version <X>` |
| **Raw manifest** | 차트가 없거나 컴포넌트가 매우 작을 때 | `install.sh`에 `kubectl apply -f`. CRD가 있으면 적용 순서 명시. |

차트 버전은 `install.sh` 상단에 `CHART_VERSION` 변수로 박는다. 바꿀 때 그 한 줄만 수정하면 되도록.

## 단계별 흐름

### 1. 폴더 만들고 README 골격부터

```
<component>/README.md     # 빈 파일에 아래 절 골격을 넣는다
<component>/install.sh    # chmod +x
```

README 절 순서: **무엇 / 왜** → **설치** → **핵심 설정** → **검증 체크리스트** → **트러블슈팅** → **제거**. 기존 6개 컴포넌트 README가 모두 이 순서를 따른다.

### 2. install.sh 작성

`install.sh`는 idempotent해야 한다 — 두 번 돌려도 안전. helm 차트라면 `helm upgrade --install`이 그 역할. PSA 라벨이나 namespace 사전 작업이 필요하면 helm 호출 직전에 `kubectl label ns ... --overwrite` 식으로 박는다.

기존 `metallb/install.sh`와 `kube-prometheus-stack/install.sh`가 PSA `privileged` 라벨을 자동으로 박는 패턴을 참고.

### 3. values.template.yaml ↔ values.yaml 분리

시크릿이 들어가면 `values.yaml`을 `.gitignore`하고 `values.template.yaml`에 placeholder(`<DOCKERHUB_TOKEN>`, `<CLOUDFLARE_API_TOKEN>` 등)만 두고 커밋. 자세한 정책은 [시크릿 처리](../developer/secrets.md).

### 4. README의 검증 체크리스트

설치 후 운영자가 무엇을 어떻게 확인하는지 체크박스로 적는다 — `kubectl get pods -n <ns>` Running 확인 + 컴포넌트 고유 검증(예: ingress면 시험 Ingress curl, metrics-server면 `kubectl top nodes`).

기존 6개 컴포넌트 README의 "검증 체크리스트" 절을 그대로 본받는다.

### 5. docs/components/ 페이지 추가

본 컴포넌트의 운영 컨텍스트(역할 / 의존 / 한계 / 연결된 런북)를 한 페이지 짧게 요약해 [`docs/components/<name>.md`](../components/index.md)에 둔다. 깊은 설치/검증은 README가 권위 있는 사본 — 페이지에서는 README를 가리킨다.

### 6. mkdocs.yml `nav:` 갱신

`mkdocs.yml`의 `nav: → 컴포넌트:` 블록에 새 페이지를 추가. `mkdocs build --strict`로 깨진 anchor가 없는지 확인.

### 7. 도입 순서 표 갱신

[루트 `CLAUDE.md`의 권장 도입 순서 표](https://github.com/nineking424/k8s-ops/blob/main/CLAUDE.md)에서 해당 컴포넌트를 "✓ 도입 완료"로 마크.

## 충돌 회피

- **CRD가 있는 차트**(cert-manager, prometheus-operator 등)는 helm uninstall 시 CRD가 자동 삭제되지 않을 수 있다. 의존 CR이 다른 컴포넌트에 있으면 통째로 사라지므로 `helm uninstall` 전에 의존 목록 확인.
- **네임스페이스 공유 금지** — 컴포넌트당 자체 namespace. 코어 네임스페이스(`kube-system`, `ingress-nginx`, `metallb-system`, `monitoring`, `nfs-subdir-external-provisioner`)는 그 컴포넌트 전용.
- **클러스터 스코프 자원**(ClusterRole, ClusterRoleBinding, ValidatingWebhookConfiguration)은 이름이 겹치면 다른 컴포넌트가 깨진다. 차트 기본값을 그대로 쓰고 임의 변경 자제.

## 설치 후 확인 한 줄

도입한 컴포넌트의 README 검증 체크리스트를 모두 통과하면, 의존하는 다른 컴포넌트(이전 단계 도입분)가 여전히 정상인지도 한 번 확인한다 — 새 PSA 라벨 / IngressClass 변경이 옆 컴포넌트의 admission을 깨는 경우가 가장 흔한 회귀 패턴.
