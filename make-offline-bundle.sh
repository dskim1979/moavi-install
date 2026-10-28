#!/usr/bin/env bash
# MOAVI 격리망(오프라인) 설치 번들 만들기 — 인터넷이 되는 서버(예: 빌드 서버 virtdev)에서 실행
#
#   sudo bash moavi/scripts/make-offline-bundle.sh --version 1.0.1 [--token <MOAVI 설치 토큰>] [--out /var/tmp] [--edition community]
#   공개 설치 저장소(moavi-install)에서도 같은 방법: git clone 후 sudo bash make-offline-bundle.sh --version … --token …
#     (그 저장소에는 compose 가 같은 폴더에, Fusion MCP 버전은 bundle-defaults.env 에 있음 — publish-installer.sh 가 만듦)
#
#   만드는 것: moavi-offline-<버전>.tar
#     install-moavi.sh      설치 스크립트 (격리망에서는 --offline 으로 실행)
#     bundle.env            번들 버전 정보
#     docker-compose.yml    MOAVI compose (moavi/installer/docker-compose.yml)
#     images.tar.gz         컨테이너 이미지 (MOAVI frontend, orchestrator, weasyprint, fusion-mcp, postgres, nginx)
#     docker/               Docker 정적 바이너리 + compose 플러그인 (격리망 서버에 Docker 가 없을 때)
#     SHA256SUMS            무결성 확인용 (설치 시 자동 검증)
#     README-OFFLINE.txt    반입·설치 안내
#
#   --edition community: 커뮤니티판 번들 moavi-community-offline-<버전>.tar (무료 배포용)
#     orchestrator(Enterprise 백엔드) 이미지와 compose 의 orchestrator 서비스를 뺌 → 화면이 커뮤니티 기능으로 동작
#     (DRS·보고서·RBAC·알림 등 Enterprise 기능은 꺼짐). Enterprise 로 바꿀 때는 Enterprise 번들로 --upgrade
#
#   MOAVI 이미지 받기:
#     --token <MOAVI 설치 토큰> 으로 MOAVI 레지스트리에 임시 로그인 (orchestrator·weasyprint 는 비공개 패키지)
#     생략하면 이 서버의 기존 docker 로그인(설치된 MOAVI 서버라면 이미 로그인되어 있음)을 사용
set -euo pipefail

MOAVI_VERSION="latest"
UPSTREAM_TAG=""                   # 비우면 frontend 이미지의 기반 버전(/app/package.json)으로 자동 — --upstream 으로 직접 지정 가능
MOAVI_REGISTRY="ghcr.io/dskim1979"
MOAVI_REGISTRY_USER="dskim1979"      # MOAVI 설치 토큰을 발급한 GitHub 계정 (install-moavi.sh 와 같게)
PROXY_IMAGE="nginx:1.27-alpine"   # install-moavi.sh 의 HTTPS 프록시 이미지와 같게
OUT_DIR="$(pwd)"
TOKEN=""
ARCH="x86_64"
EDITION="enterprise"              # enterprise | community

step() { echo -e "\n\033[1;34m==> $*\033[0m"; }
die()  { echo -e "\033[1;31m오류: $*\033[0m" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)  MOAVI_VERSION="$2"; shift 2 ;;
        --upstream) UPSTREAM_TAG="$2"; shift 2 ;;
        --token)    TOKEN="$2"; shift 2 ;;
        --out)      OUT_DIR="$2"; shift 2 ;;
        --edition)  EDITION="$2"; shift 2 ;;
        -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
        *)          die "알 수 없는 옵션: $1" ;;
    esac
done

case "$EDITION" in enterprise|community) ;; *) die "--edition 은 enterprise 또는 community" ;; esac
[ "$(uname -m)" = "x86_64" ] || die "x86_64 서버에서 만드세요 (격리망 서버와 같은 아키텍처)"
command -v docker > /dev/null || die "Docker 가 필요합니다"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/install-moavi.sh" ] || die "install-moavi.sh 를 찾을 수 없습니다 ($SCRIPT_DIR)"

NAME="moavi-offline-$MOAVI_VERSION"
[ "$EDITION" = "community" ] && NAME="moavi-community-offline-$MOAVI_VERSION"
WORK=$(mktemp -d "${OUT_DIR%/}/.moavi-bundle.XXXXXX")
DOCKER_CFG=""
cleanup() { rm -rf "$WORK"; [ -z "$DOCKER_CFG" ] || rm -rf "$DOCKER_CFG"; }
trap cleanup EXIT
B="$WORK/$NAME"
mkdir -p "$B/docker"

# ---------- compose ----------
step "MOAVI compose 준비"
# moavi 저장소: ../installer/docker-compose.yml / 공개 설치 저장소(moavi-install): 같은 폴더
COMPOSE_SRC="$SCRIPT_DIR/../installer/docker-compose.yml"
[ -f "$COMPOSE_SRC" ] || COMPOSE_SRC="$SCRIPT_DIR/docker-compose.yml"
cp "$COMPOSE_SRC" "$B/docker-compose.yml" || die "compose 파일을 찾을 수 없습니다 (moavi/installer/docker-compose.yml 또는 같은 폴더의 docker-compose.yml)"
if [ "$EDITION" = "community" ]; then
    # 커뮤니티판: orchestrator 서비스 블록, frontend 의 orchestrator 연결(주소·키·데이터 볼륨), orchestrator_data 볼륨을 뺌
    #   ORCHESTRATOR_URL 이 없으면 화면은 커뮤니티 기능 목록을 씀 (원래 제품 설계)
    awk '
        /^  # ---------- Enterprise 백엔드/ { skip = 1; next }
        skip && /^  # ----------/          { skip = 0 }
        skip                                { next }
        /- ORCHESTRATOR_URL=|- ORCHESTRATOR_API_KEY=|orchestrator_data:\/app\/orchestrator_data/ { next }
        /^  orchestrator_data:$/            { vskip = 1; next }
        vskip && /^    /                    { next }
                                            { vskip = 0; sub(/MOAVI Enterprise/, "MOAVI Community"); print }
    ' "$COMPOSE_SRC" > "$B/docker-compose.yml"
    ! grep -v '^ *#' "$B/docker-compose.yml" | grep -qi orchestrator \
        || die "커뮤니티 compose 에 orchestrator 가 남아 있습니다 — compose 구조가 바뀌었는지 확인하세요"
fi

# 공개 이미지(postgres 등)는 compose 에서, MOAVI 이미지(frontend·orchestrator·weasyprint)는 MOAVI 레지스트리에서
mapfile -t PUBLIC_IMAGES < <(grep -E '^\s+image:' "$B/docker-compose.yml" | awk '{print $2}' | tr -d '"'"'" | grep -v 'moavi-' | sort -u)
if printf '%s\n' "${PUBLIC_IMAGES[@]}" | grep -q '\$'; then die "해석하지 못한 이미지 변수가 있습니다: ${PUBLIC_IMAGES[*]}"; fi
MOAVI_IMAGE="$MOAVI_REGISTRY/moavi-frontend:$MOAVI_VERSION"
# 레지스트리 로그인을 먼저 (frontend 이미지에서 기반 버전을 읽어야 orchestrator 버전이 정해짐)
if [ -n "$TOKEN" ]; then
    step "MOAVI 레지스트리 로그인"
    DOCKER_CFG=$(mktemp -d)
    echo "$TOKEN" | docker --config "$DOCKER_CFG" login "${MOAVI_REGISTRY%%/*}" -u "$MOAVI_REGISTRY_USER" --password-stdin > /dev/null \
        || die "MOAVI 레지스트리 로그인 실패 (토큰 확인)"
fi
DC=(docker); [ -z "$DOCKER_CFG" ] || DC=(docker --config "$DOCKER_CFG")
if [ -z "$UPSTREAM_TAG" ]; then
    "${DC[@]}" pull -q "$MOAVI_IMAGE" > /dev/null || die "이미지를 받지 못했습니다: $MOAVI_IMAGE"
    _v=$(docker run --rm --entrypoint cat "$MOAVI_IMAGE" /app/package.json 2>/dev/null | sed -n 's/^ *"version": *"\([0-9][0-9.]*\)".*/\1/p' | head -1)
    [ -n "$_v" ] || die "frontend 이미지에서 기반 버전을 읽지 못했습니다 — --upstream v1.4.x 로 지정하세요"
    UPSTREAM_TAG="v$_v"
    echo "   기반 버전: $UPSTREAM_TAG (frontend 이미지 기준)"
fi
# Pure Storage Fusion MCP: 태그 = Fusion 버전-MOAVI 수정 번호 (moavi/fusion-mcp/Dockerfile)
FUSION_DF="$SCRIPT_DIR/../fusion-mcp/Dockerfile"
if [ -f "$FUSION_DF" ]; then
    FUSION_TAG="$(sed -n 's/^ARG FUSION_VERSION=v\{0,1\}\([0-9][0-9.]*\).*/\1/p' "$FUSION_DF")-$(sed -n 's/^ARG MOAVI_REV=\([0-9][0-9]*\).*/\1/p' "$FUSION_DF")"
elif [ -f "$SCRIPT_DIR/bundle-defaults.env" ]; then
    FUSION_TAG="$(sed -n 's/^FUSION_TAG=\([0-9A-Za-z.-]*\)$/\1/p' "$SCRIPT_DIR/bundle-defaults.env")"   # 공개 설치 저장소
else
    FUSION_TAG=""
fi
case "$FUSION_TAG" in ""|-*|*-) die "Fusion MCP 이미지 버전을 알 수 없습니다 (fusion-mcp/Dockerfile 또는 bundle-defaults.env)" ;; esac
ORCH_IMAGE=("$MOAVI_REGISTRY/moavi-orchestrator:$UPSTREAM_TAG")
[ "$EDITION" = "community" ] && ORCH_IMAGE=()   # 커뮤니티판에는 Enterprise 백엔드를 넣지 않음
IMAGES=("$MOAVI_IMAGE" "${ORCH_IMAGE[@]}" "$MOAVI_REGISTRY/moavi-weasyprint:$MOAVI_VERSION" "$MOAVI_REGISTRY/moavi-fusion-mcp:$FUSION_TAG" "${PUBLIC_IMAGES[@]}" "$PROXY_IMAGE")
printf '   %s\n' "${IMAGES[@]}"
if [ "$EDITION" = "community" ] && printf '%s\n' "${IMAGES[@]}" | grep -q 'moavi-orchestrator'; then
    die "커뮤니티판 이미지 목록에 orchestrator 가 있습니다"
fi

# (레지스트리 로그인은 위 — 기반 버전을 읽기 전에 함)

# ---------- 이미지 ----------
step "이미지 받기"
for img in "${IMAGES[@]}"; do
    echo "   pull $img"
    # 일시 오류(예: 같은 때 CI 정리 작업과 겹쳐 'unable to lease content')는 잠시 뒤 다시 시도 — 최대 3번
    ok=""
    for try_no in 1 2 3; do
        if "${DC[@]}" pull -q "$img" > /dev/null; then ok=1; break; fi
        [ "$try_no" -lt 3 ] && { echo "   다시 시도 ($try_no/3)…"; sleep $((try_no * 5)); }
    done
    [ -n "$ok" ] || die "이미지를 받지 못했습니다: $img (MOAVI 이미지는 --token <MOAVI 설치 토큰> 또는 기존 docker 로그인 필요, 빌드 서버라면 CI 정리 작업과 겹치지 않을 때 다시 실행)"
done
step "이미지 파일 만들기 (images.tar.gz)"
docker save "${IMAGES[@]}" | gzip -1 > "$B/images.tar.gz"
du -h "$B/images.tar.gz" | awk '{print "   "$1}'

# ---------- Docker 정적 바이너리 ----------
step "Docker 정적 바이너리·compose 플러그인 받기"
DOCKER_TGZ=$(curl -fsSL "https://download.docker.com/linux/static/stable/$ARCH/" | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | sort -uV | tail -1)
[ -n "$DOCKER_TGZ" ] || die "Docker 정적 바이너리 목록을 받지 못했습니다"
curl -fsSL "https://download.docker.com/linux/static/stable/$ARCH/$DOCKER_TGZ" -o "$B/docker/$DOCKER_TGZ"
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$ARCH" -o "$B/docker/docker-compose"
chmod 755 "$B/docker/docker-compose"
echo "   $DOCKER_TGZ, compose $("$B/docker/docker-compose" version --short 2>/dev/null || echo '?')"

# ---------- 설치 스크립트·정보 ----------
cp "$SCRIPT_DIR/install-moavi.sh" "$B/install-moavi.sh"
chmod 755 "$B/install-moavi.sh"
cat > "$B/bundle.env" << EOF
BUNDLE_MOAVI_VERSION="$MOAVI_VERSION"
BUNDLE_EDITION="$EDITION"
BUNDLE_UPSTREAM_TAG="$UPSTREAM_TAG"
BUNDLE_MOAVI_REGISTRY="$MOAVI_REGISTRY"
BUNDLE_IMAGES="${IMAGES[*]}"
BUNDLE_CREATED="$(date +%Y-%m-%d)"
EOF
if [ "$EDITION" = "community" ]; then EDITION_LABEL="Community"; else EDITION_LABEL="Enterprise"; fi
cat > "$B/README-OFFLINE.txt" << EOF
MOAVI $EDITION_LABEL $MOAVI_VERSION 격리망 설치 번들 ($(date +%Y-%m-%d))
(주)매커스시스템즈 — support@makussystems.co.kr
Based on ProxCenter Technology · Proxmox VE 기반

1) 이 파일($NAME.tar)과 SHA256 값을 기관 반입 절차(망연계 자료전송·백신 검사)로 반입
2) 설치 서버에서 (디스크 여유 15GB 이상, root):
     tar -xf moavi-offline-$MOAVI_VERSION.tar
     sudo bash $NAME/install-moavi.sh --offline $NAME [--license <라이선스 키>] [--cert 인증서 --key 개인키]
3) 업그레이드: 새 번들을 풀고
     sudo bash $NAME/install-moavi.sh --offline $NAME --upgrade
4) 설치 후 https://<서버 주소> 접속 → 첫 관리자 계정 생성

포함 구성요소: MOAVI 이미지 ${#IMAGES[@]}종 (PDF 보고서 한글 글꼴 포함), Docker $DOCKER_TGZ
EOF
if [ "$EDITION" = "community" ]; then
    cat >> "$B/README-OFFLINE.txt" << EOF

[커뮤니티판]
- 무료 배포판입니다. Enterprise 백엔드(orchestrator)가 없어 DRS·보고서·RBAC·알림·작업 센터 등
  Enterprise 기능은 꺼져 있고, 라이선스 키를 넣을 수 없습니다.
- Enterprise 로 바꾸기: (주)매커스시스템즈에서 Enterprise 번들·라이선스를 받아
     sudo bash <Enterprise 번들 폴더>/install-moavi.sh --offline <Enterprise 번들> --upgrade --license <키>
  (설정·데이터는 그대로 유지)
- 화면 소스는 GNU AGPLv3 입니다. 소스 코드 요청: support@makussystems.co.kr
- Proxmox® 는 Proxmox Server Solutions GmbH 의 등록 상표입니다.
EOF
fi
(cd "$B" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum > SHA256SUMS)

# ---------- 묶기 ----------
step "번들 묶기"
mkdir -p "$OUT_DIR"
tar -C "$WORK" -cf "${OUT_DIR%/}/$NAME.tar" "$NAME"
(cd "$OUT_DIR" && sha256sum "$NAME.tar" > "$NAME.tar.sha256")
echo -e "\n\033[1;32m완료\033[0m"
ls -lh "${OUT_DIR%/}/$NAME.tar" | awk '{print "   "$9"  "$5}'
echo "   SHA256: $(cut -d' ' -f1 "${OUT_DIR%/}/$NAME.tar.sha256")  (반입 신청서에 기재)"
