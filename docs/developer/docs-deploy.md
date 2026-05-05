# 문서 배포

본 사이트는 mkdocs로 빌드되고 GitHub Actions가 `gh-pages` 브랜치에 자동 푸시한다. GitHub Pages가 그 브랜치를 서빙.

## 구성요소

| 파일 | 역할 |
|---|---|
| `mkdocs.yml` | 사이트 메타 + nav + 테마(`readthedocs`) + 마크다운 확장. `strict: true`라 깨진 링크/anchor가 빌드를 실패시킨다. |
| `requirements-docs.txt` | mkdocs / mermaid2 / pymdown-extensions 핀. 로컬과 CI가 같은 버전을 본다. |
| `.github/workflows/docs.yml` | `main` 푸시(또는 수동 dispatch) → 빌드 → `gh-pages` 브랜치에 publish. |

## 트리거

`docs.yml`이 트리거되는 경로:

- `docs/**` — 본문 변경
- `mkdocs.yml` — nav / 테마 / 확장 변경
- `requirements-docs.txt` — 의존 버전 갱신
- `.github/workflows/docs.yml` — 워크플로 자체 변경

그 외 변경(컴포넌트 README, install.sh 등)은 사이트에 영향이 없으므로 트리거에서 제외 — 빌드 분당량을 아낀다.

수동 실행은 GitHub UI의 Actions → docs → Run workflow.

## 첫 활성화 (운영자 1회)

GitHub Actions가 처음 성공하면 `gh-pages` 브랜치가 만들어진다. 그 시점에 GitHub UI에서:

1. **Settings → Pages**
2. **Source**: `Deploy from a branch`
3. **Branch**: `gh-pages` / `(root)` 선택 → Save
4. 1~2분 후 `https://nineking424.github.io/k8s-ops/`에 접근 가능

이후 `main`에 docs 변경을 푸시할 때마다 자동 갱신.

## 로컬 미리보기

```bash
pip install -r requirements-docs.txt
mkdocs serve
# http://127.0.0.1:8000 에서 라이브 리로드
```

`--strict` 빌드를 미리 돌려 CI가 떨어질 변경을 사전에 잡는다:

```bash
mkdocs build --strict
```

## 제외 규칙

`mkdocs.yml`의 `exclude_docs:`가 다음을 빌드에서 빼낸다:

```
README.md     # 컴포넌트별 권위 있는 사본은 git에 그대로, 사이트에는 docs/components/* 진입점만
CLAUDE.md     # LLM/사람 공통 컨텍스트, 사이트 페이지 아님
PLAN.md       # 작업 노트
.serena/      # serena 도구 캐시
superpowers/  # 안전 가드 (해당 디렉토리가 docs 트리에 들어오면 제외)
```

## 배포 동작 모델

1. `peaceiris/actions-gh-pages@v4`가 빌드 산출물(`./site/`)을 `gh-pages` 브랜치에 **orphan commit**으로 덮어쓴다 (`force_orphan: true`) — 히스토리가 누적되지 않아 브랜치가 가벼움.
2. 커밋 author는 `github-actions[bot]`. 커밋 메시지는 `docs: deploy <sha>`로 어느 main 커밋에서 빌드됐는지 추적 가능.
3. `gh-pages` 브랜치에는 사람이 직접 커밋하지 않는다 — 다음 빌드가 통째로 덮어쓴다.

## 알려진 한계

- **버전 분기 없음** — 한 번에 하나의 사이트(=`main` 최신). 과거 릴리스의 문서를 따로 보관할 필요가 생기면 mike(mkdocs versioning) 도입 검토.
- **PR 프리뷰 없음** — main 머지 후에만 갱신. PR에서 변경을 미리 보려면 로컬 `mkdocs serve`.
- **인증/접근 제어 없음** — GitHub Pages는 공개. 시크릿이 본문에 들어가면 그대로 인터넷에 노출. `values.yaml`처럼 시크릿이 들어가는 파일은 docs 트리에 두지 말 것.
