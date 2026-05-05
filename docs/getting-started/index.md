# 시작하기

`talos-homelab`을 매일 다루기 위한 진입점. kubectl/talosctl/ssh pve 어디로 들어가야 하는지, 새 컴포넌트를 어떻게 폴더로 정리하는지 두 페이지에 정리했다.

- [일상 접근 패턴](daily-access.md) — kubectl 컨텍스트, `ssh pve` 호출 위치, `talosctl` 실행 호스트, 자주 쓰는 검증 명령.
- [새 컴포넌트 도입](adding-a-component.md) — 폴더 컨벤션, Helm vs raw manifest, 시크릿 처리, 설치 후 체크리스트.

처음 클러스터에 접속한다면 [일상 접근 패턴](daily-access.md)부터 본다. 부트스트랩 자체가 궁금하면 [node-management 컴포넌트 페이지](../components/node-management.md) → 거기서 `node-management/node-management-guide.md` 원문으로 점프.
