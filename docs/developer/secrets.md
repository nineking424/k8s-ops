# 시크릿 처리

본 프로젝트의 시크릿 보관/적용 정책. 단일 운영자 환경 — 가장 단순한 분리부터 시작해 필요해지면 위로 옮긴다.

## 기본: template ↔ values 분리

```
<component>/
├── values.template.yaml   # placeholder만 박힌 Git 추적 템플릿
├── values.yaml            # 실제 값 (시크릿이 박히면 .gitignore)
└── install.sh             # values.yaml을 -f로 helm에 전달
```

`values.template.yaml`은 Git에 커밋, `values.yaml`은 시크릿이 들어가면 `.gitignore`. placeholder는 꺾쇠 표기로 — `<DOCKERHUB_TOKEN>`, `<CLOUDFLARE_API_TOKEN>` 등 — 운영자가 본 사본을 만들 때 어떤 값을 넣어야 하는지 즉시 알 수 있게.

## .gitignore 패턴

본 프로젝트의 `.gitignore`(루트에 위치)에 컴포넌트별로 `values.yaml`을 명시:

```
<component-1>/values.yaml
<component-2>/values.yaml
```

또는 와일드카드로 `*/values.yaml`을 추가하고, 시크릿이 없는 컴포넌트는 명시적으로 `!<component>/values.yaml`로 화이트리스트.

> 현재 6개 컴포넌트 중 어떤 곳에 시크릿이 들어 있는지는 각 폴더의 `values.yaml`을 확인. 시크릿이 없는 컴포넌트의 `values.yaml`은 Git에 커밋해도 무방.

## 클러스터 측 Secret 관리

helm 차트가 자동으로 만드는 Secret(예: kube-prometheus-stack의 `kube-prometheus-stack-grafana`의 `admin-password`)은 **클러스터 안에서만** 존재한다. 운영자가 값을 알아야 하면 `kubectl get secret ... -o jsonpath` 로 출력.

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

차트가 자동 생성하지 않는 Secret(예: 외부 API 토큰을 클러스터 워크로드에 주입)은 별도 매니페스트로 작성하고 `kubectl apply`로 박는다. 그 매니페스트는 Git 커밋 금지 — `values.yaml`과 동일한 .gitignore 정책.

## 클러스터 전체 권한 인증 파일

| 파일 | 위치 | 권한 | 처리 |
|---|---|---|---|
| `talosconfig` | `pve:~/talos-cluster/_out/talosconfig` | Talos 클러스터 전체 권한 | **Git 커밋 절대 금지**. 1Password / Vault / 백업 디스크 등 별도 보관소 |
| `kubeconfig` | `~/.kube/config` (로컬) | k8s 클러스터 전체 권한 | Git 커밋 금지. 클라이언트 인증서가 박혀 있다 |
| etcd 백업 (`etcd-*.db`) | `pve:~/talos-backups/` | 클러스터 상태 전체 | Git 커밋 금지. 백업 정책에 따라 별도 보관 |

이 셋은 컴포넌트 시크릿보다 더 민감 — 잃거나 유출되면 클러스터 자체를 다시 만들어야 한다. 본 디렉토리에 들어올 일 없도록 `.gitignore`와 별개로 운영자 머릿속에 박아둔다.

## 향후 옵션

운영자가 늘거나 GitOps를 도입할 때, 다음 도구 중 하나로 일원화 검토:

| 도구 | 모델 | 적합한 상황 |
|---|---|---|
| **sealed-secrets** | Bitnami sealed-secrets controller가 클러스터 안에서 복호화 | Secret 자체를 Git에 (암호화된 형태로) 커밋하고 싶을 때 |
| **external-secrets** | 외부 시크릿 저장소(Vault, AWS SM, 1Password 등)를 클러스터에 주입 | 이미 시크릿 저장소를 별도로 운영할 때 |
| **SOPS** | 파일 암호화 (KMS 또는 age 키) | values.yaml 같은 파일을 암호화된 채 Git 커밋. helm-secrets와 결합. |

현재는 단일 운영자 + 컴포넌트 6개라 template/values 분리만으로 충분. 도입 시점은 [컴포넌트 추가 컨벤션 § GitOps 도입](contributing.md#gitops-도입-현재-안-함)과 같이 본다 — GitOps 도입과 시크릿 도구 일원화는 보통 같은 시점에 일어난다.

## 알려진 한계

- **현재는 시크릿 회전 정책 없음** — 차트가 자동 생성한 Grafana admin-password 등은 helm uninstall/install 사이에서만 회전된다. 정기 회전이 필요해지면 별도 절차를 만든다.
- **values.yaml의 우발적 커밋 방지 기제는 .gitignore뿐** — pre-commit hook 등 추가 가드는 없음. 단일 운영자 환경에서 충분하다는 가정. `git status`로 커밋 직전 확인 습관이 마지막 방어선.
