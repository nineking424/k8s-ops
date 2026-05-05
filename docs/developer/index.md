# 개발

컴포넌트를 추가/수정하는 사람이 본다. 운영자용 페이지는 [운영](../operating/index.md), 클러스터 그림은 [개념](../concepts/index.md)에 있다.

- [컴포넌트 추가 컨벤션](contributing.md) — 폴더 골격, Helm vs raw manifest, 네임스페이스/CRD 충돌 회피.
- [시크릿 처리](secrets.md) — `values.template.yaml` ↔ `values.yaml` 분리, Git 추적 정책, 향후 sealed-secrets/SOPS 도입 시점.
- [릴리스/업그레이드 절차](release-process.md) — helm 차트 버전 올릴 때, CRD가 따라오는 차트(kube-prometheus-stack)에서 주의할 것, 롤백 가능 여부.
- [문서 배포](docs-deploy.md) — mkdocs + GitHub Actions로 GitHub Pages(gh-pages 브랜치) 자동 배포.

본 클러스터는 GitOps 없음. 모든 변경은 사람 손으로 `helm upgrade --install` / `kubectl apply` → git 커밋으로 추적한다. 컴포넌트가 5~6개를 넘으면 ArgoCD/Flux 도입을 검토 — 그 시점에 폴더 구조가 그대로 매핑되도록 컨벤션을 잡아둠.
