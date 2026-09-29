# MOAVI 설치

**MOAVI** — Proxmox VE 기반 서버 가상화 통합 운영·관리 플랫폼
(주)매커스시스템즈 MAKUS SYSTEMS

## 설치

발급받은 설치 토큰으로 아래 한 줄을 실행합니다.

```bash
curl -fsSL https://raw.githubusercontent.com/dskim1979/moavi-install/main/install-moavi.sh | sudo bash -s -- --token <설치 토큰>
```

라이선스 키를 함께 넣으려면:

```bash
curl -fsSL https://raw.githubusercontent.com/dskim1979/moavi-install/main/install-moavi.sh | sudo bash -s -- --token <설치 토큰> --license <라이선스 키>
```

라이선스 키는 설치 후 화면의 **설정 > 라이선스**에서 입력해도 됩니다.
설치가 끝나면 `https://<서버 주소>` 에 접속해 첫 관리자 계정을 만듭니다.

## HTTPS

기본으로 HTTPS(443)로 설치되고, HTTP(80) 접속은 HTTPS 로 넘어갑니다. 3000 포트는 서버 내부에서만 쓰입니다.

| 옵션 | 설명 |
|---|---|
| (기본) | 자체 서명 인증서를 자동 생성 — 브라우저에 보안 경고가 표시됩니다 |
| `--cert <인증서> --key <개인키>` | 기관 인증서 사용 (설치 후 교체도 `--upgrade --cert … --key …`) |
| `--domain <이름>` | 접속 주소로 쓸 도메인 (기본: 서버 IP) |
| `--no-https` | HTTPS 없이 `http://<서버>:3000` 으로 운영 |

```bash
curl -fsSL https://raw.githubusercontent.com/dskim1979/moavi-install/main/install-moavi.sh | sudo bash -s -- --token <설치 토큰> --domain moavi.example.go.kr --cert /root/moavi.crt --key /root/moavi.key
```

## 업그레이드

```bash
curl -fsSL https://raw.githubusercontent.com/dskim1979/moavi-install/main/install-moavi.sh | sudo bash -s -- --upgrade
```

설정과 데이터는 유지됩니다. 특정 버전으로 맞추려면 `--version 1.0.1` 처럼 지정합니다.

## 프록시 환경

프록시를 거쳐야 하는 서버는 `sudo -E` 로 실행하면 프록시 설정이 Docker에도 적용됩니다.

```bash
curl -fsSL https://raw.githubusercontent.com/dskim1979/moavi-install/main/install-moavi.sh | sudo -E bash -s -- --token <설치 토큰>
```

## 격리망(오프라인) 설치

인터넷이 되지 않는 망분리·폐쇄망 환경은 (주)매커스시스템즈가 제공하는 **오프라인 번들**(`moavi-offline-<버전>.tar`)로 설치합니다.
번들에는 설치 스크립트, 컨테이너 이미지, Docker, 한글 글꼴이 모두 들어 있어 설치 중 인터넷에 접속하지 않습니다.

1. 번들과 SHA256 값을 기관 반입 절차(망연계 자료전송·백신 검사)로 반입합니다.
2. 설치 서버(디스크 여유 15GB 이상)에서:

```bash
tar -xf moavi-offline-1.0.1.tar
sudo bash moavi-offline-1.0.1/install-moavi.sh --offline moavi-offline-1.0.1 --license <라이선스 키>
```

- 설치 스크립트가 번들의 SHA256 을 확인하고, Docker 가 없으면 번들의 Docker 를 설치합니다.
- HTTPS·인증서 옵션은 온라인 설치와 같습니다 (`--cert`, `--key`, `--domain`).
- 업그레이드: 새 번들을 풀고 `sudo bash moavi-offline-<새 버전>/install-moavi.sh --offline moavi-offline-<새 버전> --upgrade`

번들 요청: support@makussystems.co.kr

## 요구 사항

- Linux (Ubuntu, Debian, Rocky, AlmaLinux, RHEL), root 권한
- 메모리 2 GB, 디스크 10 GB 이상
- 포트: 443·80 인바운드 / Proxmox VE 8006, PBS 8007 아웃바운드
- Proxmox VE 8.x / 9.x

Docker가 없으면 설치 스크립트가 함께 설치합니다.
PDF 보고서용 한글 글꼴(나눔고딕·나눔명조)도 설치 중 받습니다 (raw.githubusercontent.com 접근 필요).

## 관리

```bash
cd /opt/moavi
docker compose ps          # 상태
docker compose logs -f     # 로그
docker compose down        # 중지
```

설치 로그: `/var/log/moavi-install.log`

## 문의

- 기술 지원: support@makussystems.co.kr
