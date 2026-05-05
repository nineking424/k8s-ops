# 컴포넌트 추가 컨벤션

새 클러스터-레벨 컴포넌트를 도입할 때 따라야 하는 폴더 골격과 규약. 표준 진입점은 [새 컴포넌트 도입](../getting-started/adding-a-component.md), 본 페이지는 그 깊은 배경.

## 폴더 골격

```
<component>/
├── README.md            # 무엇 / 왜 / 의존 / 설치 / 검증 / 트러블슈팅 / 제거
├── install.sh           # 단일 진입점. helm upgrade --install 또는 kubectl apply 한 번에 끝나야 함
├── values.template.yaml # (Helm) 시크릿 placeholder만 박힌 Git 추적 템플릿
├── values.yaml          # (Helm) 실제 값. 시크릿이 들어가면 .gitignore
└── *.yaml               # 추가 매니페스트 (Issuer, IPAddressPool, StorageClass, Secret 등)
```

폴더 이름은 **Helm 차트 이름** 또는 일반 통용 명. 상위 워크스페이스(`/Users/nineking/workspace/k8s/`)에 동명 디렉토리(`../prometheus/`, `../ingress-nginx/` 등)가 있어도 무관 — 그쪽은 과거 클러스터용 사본이라 본 프로젝트로 옮길 때는 [현재 클러스터 기준으로 검증한 뒤](#상위-워크스페이스-사본-처리) 옮긴다.

## install.sh의 책임

- **idempotent** — 두 번 돌려도 동일 상태에 도달. helm 차트라면 `helm upgrade --install`이 그 역할.
- **사전 namespace / PSA 라벨** — 차트가 만든 ns를 그대로 쓰면 라벨이 안 박혀 PSA 거부될 수 있다. helm 호출 직전에 `kubectl label ns ... --overwrite`로 박는다 — `metallb/install.sh`, `kube-prometheus-stack/install.sh`가 표준 패턴.
- **차트 버전 변수화** — 상단에 `CHART_VERSION` 변수로 박아 변경 시 한 줄 수정.
- **rollout 대기** — helm install 직후 `kubectl rollout status` 또는 helm `--wait` 옵션으로 검증 가능 상태까지 대기.

`install.sh`가 너무 복잡해지면 차라리 raw manifest로 분리하거나 별도 단계로 쪼갠다 — 단일 진입점이 흐려지면 운영자가 "그 다음 무엇을 해야 하지"를 잃는다.

## Helm vs raw manifest

| 방식 | 언제 |
|---|---|
| **Helm (권장)** | 공식 차트가 있는 모든 컴포넌트. 업그레이드/롤백/diff가 표준화된다. |
| **Raw manifest** | 차트가 없거나(예: 작은 Operator), 차트가 있어도 본 클러스터 합의에 맞추기 위해 통째로 다시 적어야 할 만큼 작은 컴포넌트. CRD가 있으면 적용 순서를 명시. |

## 시크릿 처리

기본 원칙은 [시크릿 처리](secrets.md)에 있다. 핵심:

- `values.template.yaml` (placeholder만, Git 추적) ↔ `values.yaml` (실제, `.gitignore`).
- `install.sh` 상단에서 두 파일이 어긋날 때 경고하면 좋다 (현재 6개 중 일부만 그렇게 함 — 새로 추가하는 컴포넌트에서는 권장).

## 네임스페이스 / CRD / 충돌

- **컴포넌트당 자체 namespace**. 코어(`kube-system`, `ingress-nginx`, `metallb-system`, `monitoring`, `nfs-subdir-external-provisioner`)는 그 컴포넌트 전용. 같은 ns를 두 컴포넌트가 공유하지 않는다.
- **CRD가 있는 차트**(cert-manager, prometheus-operator, metallb 등)는 helm uninstall 시 CRD가 자동 삭제되지 않을 수 있다. 의존하는 다른 컴포넌트의 CR을 통째로 잃지 않도록 `helm uninstall` 전에 의존 CR 목록 확인 — 자세한 절차는 [업그레이드와 롤백](../operating/upgrades-and-rollback.md).
- **클러스터 스코프 자원**(ClusterRole, ClusterRoleBinding, ValidatingWebhookConfiguration)은 이름이 겹치면 다른 컴포넌트가 깨진다. 차트 기본값을 그대로 쓰고 임의 변경 자제.

## README 골격

기존 6개 컴포넌트 README가 같은 절 순서를 따른다 — **무엇 / 왜 → 설치 → Talos 특이사항(있다면) → 핵심 설정 → 검증 체크리스트 → 트러블슈팅 → 제거**. 새 컴포넌트도 이 순서를 그대로 본받는다. "한계 / non-goals" 절도 가급적 적어두면 미래의 운영자가 "왜 X가 없냐"를 다시 묻지 않게 됨.

## docs/ 페이지 추가

본 컴포넌트의 운영 컨텍스트(역할 / 의존 / 한계 / 연결된 런북)를 [`docs/components/<name>.md`](../components/index.md)에 한 페이지 짧게 둔다. 권위 있는 설치/검증 절차는 컴포넌트 폴더의 `README.md` — docs 페이지는 README를 가리키는 진입점.

`mkdocs.yml`의 `nav: → 컴포넌트:` 블록에 새 페이지를 추가. 빌드 검증:

```bash
mkdocs build --strict
```

깨진 anchor / 잘못된 링크가 있으면 `--strict`가 빌드를 실패시킨다.

## 도입 순서 표 갱신

[루트 `CLAUDE.md`의 권장 도입 순서 표](../../CLAUDE.md)에서 해당 컴포넌트를 "✓ 도입 완료"로 마크. CLAUDE.md는 LLM/사람 모두의 공통 컨텍스트라 누락되면 "현재 무엇이 도입돼 있는지"가 흐려진다.

## 상위 워크스페이스 사본 처리

상위 git 루트(`/Users/nineking/workspace/k8s/`)에 `../prometheus/`, `../grafana/`, `../cert-manager/`, `../ingress-nginx/`, `../metallb/`, `../minio/`, `../nfs-provisioner/` 등 컴포넌트별 사본이 있다. 이들은 **과거 클러스터**(현 talos-homelab이 아닌 이전 환경)에서 사용한 매니페스트라 차트/CRD/values 버전이 어긋날 가능성이 높다.

새 컴포넌트를 본 프로젝트로 가져올 때:

1. 차트 버전을 현재 운영 가능한 최신으로 갱신.
2. values를 본 클러스터의 합의(NFS SC `nfs-client`, MetalLB `home-pool`, ingress `nginx`, 외부 NPM HTTP-only 등)에 맞춰 다시 적는다.
3. `install.sh`를 본 프로젝트 컨벤션으로 새로 작성.
4. README도 본 컨벤션으로 새로 적음 — 그대로 복사하면 옛 클러스터 합의가 섞여 들어온다.

상위 사본을 통째로 복사하지 않는다.

## GitOps 도입 (현재 안 함)

지금은 수동 `helm/kubectl` 흐름이고, 변경은 git 커밋으로 추적. 컴포넌트가 5~6개 넘어가면 ArgoCD 또는 Flux 도입 검토 — 그 시점에 본 폴더 구조가 그대로 `Application` / `Kustomization` 매니페스트로 매핑되도록 컨벤션을 잡아두었다.
