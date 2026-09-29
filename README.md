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
설치가 끝나면 `http://<서버 주소>:3000` 에 접속해 첫 관리자 계정을 만듭니다.

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

## 요구 사항

- Linux (Ubuntu, Debian, Rocky, AlmaLinux, RHEL), root 권한
- 메모리 2 GB, 디스크 10 GB 이상
- 포트: 3000 인바운드 / Proxmox VE 8006, PBS 8007 아웃바운드
- Proxmox VE 8.x / 9.x

Docker가 없으면 설치 스크립트가 함께 설치합니다.

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
