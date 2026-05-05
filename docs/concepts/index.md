# 개념

운영자가 머리에 들고 있어야 하는 클러스터의 모양. 컴포넌트별 세부는 [컴포넌트](../components/index.md), 일상 명령은 [시작하기](../getting-started/index.md)에 있고 여기서는 "왜 이런 구조인지"를 다룬다.

- [아키텍처](architecture.md) — Talos 노드 토폴로지(cp 3 / wk 2), 도입 컴포넌트 6개와 서로의 의존 관계, 의도적으로 하지 않은 것.
- [네트워크 토폴로지](network-topology.md) — 단일 `192.168.0.0/16` 서브넷에서 노드 대역(`192.168.2.x`) / cp VIP(`192.168.2.100`) / LB 풀(`192.168.3.0/24`) / DHCP 풀(`192.168.1.x`)을 어떻게 분리하는지.
- [외부 노출 모델](external-exposure.md) — 외부 NPM이 `*.k8s.stjeong.com` 와일드카드 + edge TLS를 담당하고 클러스터는 HTTP Ingress만 정의하는 책임 분리. cert-manager가 왜 현재 단계에서 불필요한가.
- [용어집](glossary.md) — `cluster endpoint`, `VIP`, `IPAddressPool`, `IngressClass`, `nocloud`, `snippet` 등 본 문서에서 영어 그대로 쓰는 용어 정의.
