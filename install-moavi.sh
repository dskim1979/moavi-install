#!/bin/bash
set -e

# ============================================
# MOAVI 설치 스크립트 (Enterprise)
# ============================================
# 신규 설치:
#   sudo bash install-moavi.sh --token <MOAVI 설치 토큰> [--license <키>]
# 업그레이드 (.env·데이터 유지, 이미지/compose 갱신):
#   sudo bash install-moavi.sh --upgrade [--version 1.0.1]
#
# - frontend / orchestrator / weasyprint : MOAVI 레지스트리(MOAVI_REGISTRY) — MOAVI 설치 토큰((주)매커스시스템즈 발급)으로 받음
# - postgres / nginx                     : 공개 이미지
# - compose 파일                          : MOAVI 설치 저장소(MOAVI_INSTALL_BASE)
# ============================================

# ---- 릴리스마다 갱신하는 값 ----
MOAVI_VERSION_DEFAULT="latest"      # moavi-frontend 이미지 태그
UPSTREAM_TAG_DEFAULT="v1.4.11"      # moavi-orchestrator 버전 (weasyprint 는 MOAVI 버전을 따름)
MOAVI_REGISTRY="ghcr.io/dskim1979"
MOAVI_REGISTRY_USER="dskim1979"
MOAVI_INSTALL_BASE="https://raw.githubusercontent.com/dskim1979/moavi-install/main"
# --------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INSTALL_DIR="/opt/moavi"
DOCKER_DROPIN_DIR="/etc/systemd/system/docker.service.d"
LOG_FILE="/var/log/moavi-install.log"   # docker 출력은 화면 대신 로그로

TOTAL_STEPS=6
START_TIME=$(date +%s)

step()        { echo ""; echo -e "${BOLD}${BLUE}[$1/$TOTAL_STEPS]${NC} ${BOLD}$2${NC}"; }
log_info()    { echo -e "    ${DIM}$1${NC}"; }
log_success() { echo -e "    ${GREEN}✓${NC} $1"; }
log_warning() { echo -e "    ${YELLOW}!${NC} $1"; }
log_error()   { echo -e "\n    ${RED}✗ $1${NC}"; exit 1; }

spinner() {
    local pid=$1 msg=${2:-"잠시 기다려 주세요"} chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r    ${DIM}%s %s${NC}" "${chars:i++%${#chars}:1}" "$msg"
        sleep 0.1
    done
    printf "\r\033[K"
    tput cnorm 2>/dev/null || true
}

format_duration() {
    local secs=$1
    if [ "$secs" -lt 60 ]; then echo "${secs}초"; else echo "$((secs / 60))분 $((secs % 60))초"; fi
}

cleanup_on_error() {
    echo ""
    echo -e "${RED}${BOLD}설치에 실패했습니다.${NC}"
    [ -s "$LOG_FILE" ] && tail -n 10 "$LOG_FILE" | sed "s/^/    | /"
    echo -e "${DIM}    - 설치 로그: $LOG_FILE${NC}"
    echo -e "${DIM}    - 서비스 로그: cd $INSTALL_DIR && docker compose logs${NC}"
    echo -e "${DIM}    - 원인을 해결한 뒤 이 스크립트를 다시 실행하세요${NC}"
    echo ""
    tput cnorm 2>/dev/null || true
    exit 1
}
trap cleanup_on_error ERR

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
    __  __   ___      _    __     __ ___
   |  \/  | / _ \    / \   \ \   / /|_ _|
   | |\/| || | | |  / _ \   \ \ / /  | |
   | |  | || |_| | / ___ \   \ V /   | |
   |_|  |_| \___/ /_/   \_\   \_/   |___|
EOF
    echo -e "${NC}"
    echo -e "    ${GREEN}${BOLD}MOAVI Enterprise${NC}  ${DIM}— (주)매커스시스템즈${NC}"
    echo ""
}

show_usage() {
    cat << EOF
사용법: $0 --token <MOAVI 설치 토큰> [옵션]
        $0 --upgrade [옵션]

필수 (신규 설치):
  --token <token>        MOAVI 설치 토큰 ((주)매커스시스템즈 발급 — 업그레이드 때는 생략 가능, 설치 때 저장됨)

옵션:
  --license <key>        라이선스 키 (설치 후 설정 > 라이선스에서 입력해도 됨)
  --version <tag>        MOAVI 버전 (기본: $MOAVI_VERSION_DEFAULT)
  --upgrade              기존 설치 업그레이드 (.env·데이터 유지)
  --domain <이름>        접속 주소로 쓸 도메인 (기본: 서버 IP)
  --cert <파일> --key <파일>  HTTPS 인증서·개인키 (기본: 자체 서명 인증서 자동 생성)
  --no-https             HTTPS 없이 3000 포트(HTTP)로 운영
  --https                (업그레이드) HTTP 로 운영하던 설치를 HTTPS 로 전환
  --offline <번들>       격리망(인터넷 없음) 설치 — make-offline-bundle.sh 로 만든 번들(.tar 또는 풀어 둔 폴더)
                         토큰 불필요. 예: sudo bash install-moavi.sh --offline moavi-offline-1.0.1.tar
  --help                 도움말
EOF
    exit 1
}

# ============================================
# 인자
# ============================================
LICENSE_KEY=""
MOAVI_TOKEN=""
MOAVI_VERSION="$MOAVI_VERSION_DEFAULT"
VERSION_GIVEN=false           # 업그레이드에서 --version 이 없으면 설치된 버전(.env) 유지
UPSTREAM_TAG="$UPSTREAM_TAG_DEFAULT"
UPGRADE_MODE=false
HTTPS=""                      # 비우면: 신규 설치는 HTTPS, 업그레이드는 기존 설정 유지
DOMAIN=""
CERT_FILE=""
KEY_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --token|--moavi-token) MOAVI_TOKEN="$2"; shift 2 ;;
        --license)     LICENSE_KEY="$2"; shift 2 ;;
        --version)     MOAVI_VERSION="$2"; VERSION_GIVEN=true; shift 2 ;;
        --upstream)    UPSTREAM_TAG="$2"; shift 2 ;;
        --upgrade)     UPGRADE_MODE=true; shift ;;
        --https)       HTTPS=true; shift ;;
        --no-https)    HTTPS=false; shift ;;
        --domain)      DOMAIN="$2"; shift 2 ;;
        --cert)        CERT_FILE="$2"; shift 2 ;;
        --key)         KEY_FILE="$2"; shift 2 ;;
        --offline)     OFFLINE_SRC="$2"; shift 2 ;;
        --help|-h)     show_usage ;;
        *)             log_error "알 수 없는 옵션: $1" ;;
    esac
done

# ---- 격리망 설치: 번들 풀기·검증, 번들에 적힌 버전 사용 ----
OFFLINE=false
OFFLINE_DIR=""
if [ -n "${OFFLINE_SRC:-}" ]; then
    OFFLINE=true
    [ "$EUID" -eq 0 ] || log_error "root 권한이 필요합니다 (sudo)"
    if [ -d "$OFFLINE_SRC" ]; then
        OFFLINE_DIR=$(cd "$OFFLINE_SRC" && pwd)
    elif [ -f "$OFFLINE_SRC" ]; then
        OFFLINE_TMP=$(mktemp -d /var/tmp/moavi-offline.XXXXXX)
        trap 'rm -rf "$OFFLINE_TMP"' EXIT
        echo -e "    ${DIM}번들 푸는 중: $OFFLINE_SRC (이미지 포함이라 1~2분 걸릴 수 있음)${NC}"
        tar -xf "$OFFLINE_SRC" -C "$OFFLINE_TMP" || log_error "번들을 풀지 못했습니다 (디스크 여유 공간 확인: /var/tmp): $OFFLINE_SRC"
        # 번들은 moavi-offline-<버전>/ 폴더 하나로 되어 있음
        OFFLINE_DIR=$(dirname "$(find "$OFFLINE_TMP" -maxdepth 2 -name bundle.env | head -1)")
    else
        log_error "번들을 찾을 수 없습니다: $OFFLINE_SRC"
    fi
    [ -f "$OFFLINE_DIR/bundle.env" ] || log_error "MOAVI 오프라인 번들이 아닙니다 (bundle.env 없음): $OFFLINE_SRC"
    echo -e "    ${DIM}번들 무결성 확인 중 (SHA256)...${NC}"
    (cd "$OFFLINE_DIR" && sha256sum -c --quiet SHA256SUMS) || log_error "번들 파일이 손상되었거나 변경되었습니다 (SHA256 불일치) — 번들을 다시 반입하세요"
    # shellcheck disable=SC1091
    . "$OFFLINE_DIR/bundle.env"
    MOAVI_VERSION="$BUNDLE_MOAVI_VERSION"
    UPSTREAM_TAG="$BUNDLE_UPSTREAM_TAG"
    MOAVI_REGISTRY="$BUNDLE_MOAVI_REGISTRY"
fi


# .env 의 KEY=VALUE 를 추가하거나 교체
set_env() {
    local key=$1 val=$2 file="$INSTALL_DIR/.env"
    if grep -q "^$key=" "$file"; then
        sed -i "s|^$key=.*|$key=$val|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}
ENV_FILE="$INSTALL_DIR/.env"
get_env() { grep "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }

# ============================================
# 사전 점검
# ============================================
preflight_checks() {
    [ "$EUID" -eq 0 ] || log_error "root 권한이 필요합니다. 사용법: sudo bash install-moavi.sh --token <토큰>"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    else
        log_error "지원하지 않는 운영체제입니다"
    fi

    case $OS in
        ubuntu|debian)                      PKG_INSTALL="apt-get install -y" ;;
        centos|rhel|rocky|almalinux|fedora) PKG_INSTALL="dnf install -y" ;;
        *)                                  log_error "지원하지 않는 운영체제입니다: $OS" ;;
    esac
    log_info "OS: $OS $VERSION_ID"

    if [ "$UPGRADE_MODE" = "true" ]; then
        [ -f "$ENV_FILE" ] || log_error "$INSTALL_DIR 에 기존 설치가 없습니다. --upgrade 없이 신규 설치하세요."
        [ -n "$MOAVI_TOKEN" ] || MOAVI_TOKEN=$(get_env MOAVI_GHCR_TOKEN)
        # --version 없이 업그레이드하면 설치된 버전 채널(latest·main·1.0.1 등)을 유지하고 그 최신 이미지를 받음
        if [ "$VERSION_GIVEN" != "true" ] && [ "$OFFLINE" != "true" ] && [ -n "$(get_env MOAVI_VERSION)" ]; then
            MOAVI_VERSION=$(get_env MOAVI_VERSION)
        fi
    fi

    if [ "$OFFLINE" = "true" ]; then
        log_info "격리망 설치 — 번들: MOAVI $MOAVI_VERSION (만든 날짜 ${BUNDLE_CREATED:-?})"
        return 0
    fi

    if [ -z "$MOAVI_TOKEN" ] && [ "$UPGRADE_MODE" != "true" ]; then
        echo -e "${RED}오류: 신규 설치에는 --token 이 필요합니다${NC}"; echo ""; show_usage
    fi
}

# ============================================
# 1. 토큰 확인
# ============================================
# MOAVI 설치 토큰((주)매커스시스템즈 발급, 레지스트리 읽기 전용)으로 MOAVI 레지스트리 접근을 확인
validate_token() {
    step 1 "설치 토큰 확인"

    if [ "$OFFLINE" = "true" ]; then
        log_info "격리망 설치 — 토큰 확인 생략 (번들을 만들 때 확인함)"
        return 0
    fi
    if [ -z "$MOAVI_TOKEN" ]; then
        log_info "토큰 생략 — 이 서버의 기존 레지스트리 로그인을 사용합니다"
        return 0
    fi

    [[ "$MOAVI_TOKEN" =~ ^(ghp_|github_pat_) ]] \
        || log_error "MOAVI 설치 토큰 형식이 아닙니다 (ghp_ 로 시작) — 이전 방식의 설치 토큰은 더 이상 쓰지 않습니다. (주)매커스시스템즈에 MOAVI 설치 토큰을 요청하세요"

    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 -u "$MOAVI_REGISTRY_USER:$MOAVI_TOKEN" \
        "https://${MOAVI_REGISTRY%%/*}/token?scope=repository:${MOAVI_REGISTRY#*/}/moavi-orchestrator:pull" || true)
    case "$code" in
        200) log_success "MOAVI 설치 토큰 확인" ;;
        000) log_error "MOAVI 레지스트리(${MOAVI_REGISTRY%%/*})에 접속할 수 없습니다 — 네트워크·프록시 확인 (격리망은 --offline)" ;;
        *)   log_error "MOAVI 설치 토큰이 올바르지 않거나 만료되었습니다 (HTTP $code) — (주)매커스시스템즈에 재발급을 요청하세요" ;;
    esac
}

# ============================================
# 2. Docker 설치
# ============================================
# 격리망: 번들의 Docker 정적 바이너리 설치 (dockerd 가 containerd 를 직접 띄움)
install_compose_offline() {
    [ -f "$OFFLINE_DIR/docker/docker-compose" ] || log_error "번들에 docker compose 플러그인이 없습니다"
    install -d -m 0755 /usr/local/lib/docker/cli-plugins
    install -m 0755 "$OFFLINE_DIR/docker/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
    log_success "docker compose 플러그인 설치 (번들)"
}

install_docker_offline() {
    local tgz
    tgz=$(ls "$OFFLINE_DIR"/docker/docker-*.tgz 2>/dev/null | head -1)
    [ -n "$tgz" ] || log_error "번들에 Docker 설치 파일이 없습니다. Docker 를 먼저 설치하거나 번들을 다시 만드세요."
    command -v iptables > /dev/null 2>&1 || log_warning "iptables 가 없습니다 — Docker 네트워크에 필요합니다 (OS 설치 매체에서 iptables 패키지 설치)"

    local tmp
    tmp=$(mktemp -d)
    tar -xzf "$tgz" -C "$tmp"
    install -m 0755 "$tmp"/docker/* /usr/bin/
    rm -rf "$tmp"
    install_compose_offline

    getent group docker > /dev/null || groupadd --system docker
    cat > /etc/systemd/system/docker.service << 'EOF'
# MOAVI 격리망 설치 — Docker 정적 바이너리용 서비스
[Unit]
Description=Docker Application Container Engine
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
Restart=always
RestartSec=2
LimitNOFILE=infinity
LimitNPROC=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now docker > /dev/null 2>&1 || log_error "Docker 서비스를 시작하지 못했습니다 (journalctl -u docker 확인)"
    for _ in $(seq 30); do docker info > /dev/null 2>&1 && break; sleep 1; done
    docker info > /dev/null 2>&1 || log_error "Docker 가 응답하지 않습니다 (journalctl -u docker 확인)"
    log_success "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1) 설치 완료 (번들)"
}

install_docker() {
    step 2 "Docker 설치"

    if command -v docker &> /dev/null; then
        log_success "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1) 설치되어 있음"
        docker compose version > /dev/null 2>&1 || [ "$OFFLINE" != "true" ] || install_compose_offline
        return
    fi

    if [ "$OFFLINE" = "true" ]; then
        install_docker_offline
        return
    fi

    log_info "의존 패키지 설치 중..."
    $PKG_INSTALL openssl curl ca-certificates > /dev/null 2>&1

    case $OS in
        ubuntu|debian)
            apt-get remove -y docker docker-engine docker.io containerd runc > /dev/null 2>&1 || true
            $PKG_INSTALL gnupg lsb-release > /dev/null 2>&1
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
            chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
            apt-get update > /dev/null 2>&1
            $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine > /dev/null 2>&1 || true
            $PKG_INSTALL dnf-plugins-core > /dev/null 2>&1
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null 2>&1
            $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
            ;;
    esac

    systemctl start docker
    systemctl enable docker > /dev/null 2>&1
    log_success "Docker 설치 완료"
}

# ============================================
# 3. 레지스트리 인증
# ============================================
# MOAVI 레지스트리: frontend·orchestrator·weasyprint 를 모두 여기서 받음
authenticate_registry() {
    step 3 "컨테이너 레지스트리 인증"
    if [ "$OFFLINE" = "true" ]; then
        log_info "격리망 설치 — 레지스트리를 쓰지 않습니다 (번들 이미지 사용)"
        return 0
    fi
    if [ -z "$MOAVI_TOKEN" ]; then
        log_info "기존 로그인 정보를 사용합니다"
        return 0
    fi
    local out
    if ! out=$(echo "$MOAVI_TOKEN" | docker login "${MOAVI_REGISTRY%%/*}" -u "$MOAVI_REGISTRY_USER" --password-stdin 2>&1); then
        log_error "MOAVI 레지스트리 인증 실패: $(echo "$out" | grep -viE '^WARNING|^$' | tail -1)"
    fi
    log_success "MOAVI 레지스트리 인증 완료"
}

# 셸에 프록시 변수가 있으면 Docker 데몬에도 적용 (sudo -E 로 실행한 경우)
configure_docker_proxy() {
    local http_val="${HTTP_PROXY:-${http_proxy:-}}"
    local https_val="${HTTPS_PROXY:-${https_proxy:-}}"
    local no_val="${NO_PROXY:-${no_proxy:-}}"
    [ -n "$http_val$https_val" ] || return 0
    [ -z "$(docker info --format '{{.HTTPProxy}}{{.HTTPSProxy}}' 2>/dev/null || true)" ] || return 0

    local no_list="localhost,127.0.0.1,::1${no_val:+,$no_val}"
    mkdir -p "$DOCKER_DROPIN_DIR"
    {
        echo "# MOAVI 설치 스크립트가 설치 셸의 프록시 설정으로 작성"
        echo "[Service]"
        [ -z "$http_val" ]  || echo "Environment=\"HTTP_PROXY=${http_val//%/%%}\""
        [ -z "$https_val" ] || echo "Environment=\"HTTPS_PROXY=${https_val//%/%%}\""
        echo "Environment=\"NO_PROXY=${no_list//%/%%}\""
    } > "$DOCKER_DROPIN_DIR/moavi-http-proxy.conf"
    systemctl daemon-reload
    systemctl restart docker
    log_success "Docker 데몬 프록시 설정: ${https_val:-$http_val}"
}

# ============================================
# 4. 구성
# ============================================
write_compose() {
    cd "$INSTALL_DIR"
    if [ "$OFFLINE" = "true" ]; then
        cp "$OFFLINE_DIR/docker-compose.yml" docker-compose.yml.new
    elif ! curl -fsSL "$MOAVI_INSTALL_BASE/docker-compose.yml" -o docker-compose.yml.new 2>/dev/null; then
        rm -f docker-compose.yml.new
        log_error "compose 파일을 받지 못했습니다"
    fi
    if [ -f docker-compose.yml ] && ! diff -q docker-compose.yml docker-compose.yml.new > /dev/null 2>&1; then
        cp -p docker-compose.yml "docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    mv docker-compose.yml.new docker-compose.yml

    # 설치별 추가 구성: (HTTPS 일 때) 프록시. 보고서 한글 글꼴은 moavi-weasyprint 이미지에 포함
    cat > docker-compose.moavi.yml << 'EOF'
# MOAVI 추가 구성 (install-moavi.sh 가 생성 — 직접 수정하지 마세요)
services:
EOF
    rm -rf "$INSTALL_DIR/fonts"   # 이전 버전이 받아 두던 글꼴 폴더 (이제 쓰지 않음)

    # HTTPS: nginx(moavi-proxy)가 443 으로 받아 frontend 로 전달, 3000 은 서버 내부(127.0.0.1)에서만
    if [ "$HTTPS" = "true" ]; then
        # frontend 의 3000 포트는 서버 내부(127.0.0.1)에서만
    cat >> docker-compose.moavi.yml << 'EOF'
  frontend:
    ports: !override
      - "127.0.0.1:3000:3000"
  proxy:
    image: nginx:1.27-alpine
    container_name: moavi-proxy
    restart: unless-stopped
    depends_on:
      frontend:
        condition: service_healthy
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./proxy/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./proxy/ssl:/etc/nginx/ssl:ro
    networks:
      - moavi
EOF
    fi
    [ "$HTTPS" = "true" ] || sed -i "s/^services:$/services: {}/" docker-compose.moavi.yml
    log_success "compose 구성 저장"
}

# HTTPS 사용 여부·접속 주소 결정 (신규: 기본 HTTPS / 업그레이드: .env 의 MOAVI_HTTPS, 없으면 HTTPS 로 전환)
resolve_access() {
    if [ -z "$HTTPS" ]; then
        HTTPS=$(get_env MOAVI_HTTPS)
        [ -n "$HTTPS" ] || HTTPS=true
    fi
    PUBLIC_HOST=${DOMAIN:-$(get_env MOAVI_PUBLIC_HOST)}
    [ -n "$PUBLIC_HOST" ] || PUBLIC_HOST=$(hostname -I | awk '{print $1}' | head -1)
    [ -n "$PUBLIC_HOST" ] || PUBLIC_HOST="localhost"
    if [ "$HTTPS" = "true" ]; then PUBLIC_URL="https://$PUBLIC_HOST"; else PUBLIC_URL="http://$PUBLIC_HOST:3000"; fi
}

# nginx 설정·인증서 (자체 서명 인증서는 없을 때만 생성, --cert/--key 를 주면 교체)
setup_https() {
    [ "$HTTPS" = "true" ] || return 0
    cd "$INSTALL_DIR"
    mkdir -p proxy/ssl

    if [ -z "$(docker ps -q -f name=^moavi-proxy$ 2>/dev/null)" ] && \
       ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)(80|443)$'; then
        log_error "80 또는 443 포트를 다른 프로그램이 쓰고 있습니다. 비우거나 --no-https 로 설치하세요."
    fi

    if [ -n "$CERT_FILE$KEY_FILE" ]; then
        [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] || log_error "인증서(--cert)와 개인키(--key) 파일을 모두 지정하세요"
        cp "$CERT_FILE" proxy/ssl/moavi.crt
        cp "$KEY_FILE" proxy/ssl/moavi.key
        log_success "지정한 인증서 적용"
    elif [ ! -s proxy/ssl/moavi.crt ]; then
        local ip san
        ip=$(hostname -I | awk '{print $1}' | head -1)
        san="DNS:$(hostname)${ip:+,IP:$ip}"
        [ -z "$DOMAIN" ] || san="DNS:$DOMAIN,$san"
        if ! openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
            -keyout proxy/ssl/moavi.key -out proxy/ssl/moavi.crt \
            -subj "/CN=$PUBLIC_HOST/O=MOAVI" -addext "subjectAltName=$san" >> "$LOG_FILE" 2>&1; then
            log_error "자체 서명 인증서를 만들지 못했습니다"
        fi
        log_success "자체 서명 인증서 생성 (RSA 3072, 10년)"
    fi
    chmod 600 proxy/ssl/moavi.key

    cat > proxy/nginx.conf << 'EOF'
# MOAVI HTTPS 프록시 (install-moavi.sh 가 생성 — 직접 수정하지 마세요)
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/moavi.crt;
    ssl_certificate_key /etc/nginx/ssl/moavi.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size 0;                 # ISO·이미지 업로드
    large_client_header_buffers 4 32k;

    # 콘솔(noVNC)·쉘(xterm) 웹소켓
    location /api/internal/ws/ {
        proxy_pass http://frontend:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    location / {
        proxy_pass http://frontend:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_request_buffering off;
    }
}
EOF
    log_success "HTTPS 프록시 구성"
}

# .env 의 접속 주소 (관리자가 직접 바꾼 주소는 유지)
apply_access_env() {
    local cur
    cur=$(get_env NEXTAUTH_URL)
    if [ -z "$cur" ] || [ -n "$DOMAIN" ] || echo "$cur" | grep -qE '^https?://[^/]+:3000/?$|^https://[^/:]+/?$'; then
        set_env NEXTAUTH_URL "$PUBLIC_URL"
        set_env APP_URL "$PUBLIC_URL"
    else
        PUBLIC_URL="$cur"
    fi
    set_env MOAVI_HTTPS "$HTTPS"
    set_env MOAVI_PUBLIC_HOST "$PUBLIC_HOST"
}

setup_moavi() {
    step 4 "MOAVI 구성"

    mkdir -p "$INSTALL_DIR/config"
    cd "$INSTALL_DIR"
    resolve_access
    write_compose

    APP_SECRET=$(openssl rand -hex 32)
    NEXTAUTH_SECRET=$(openssl rand -hex 32)
    ORCHESTRATOR_API_KEY=$(openssl rand -hex 32)
    POSTGRES_PASSWORD=$(openssl rand -hex 24)

    SERVER_IP=$(hostname -I | awk '{print $1}' | head -1)
    [ -n "$SERVER_IP" ] || SERVER_IP="localhost"

    cat > "$INSTALL_DIR/.env" << EOF
# MOAVI Enterprise
# 생성: $(date -Iseconds)

COMPOSE_FILE=docker-compose.yml:docker-compose.moavi.yml

# MOAVI 설치 토큰 (업그레이드 때 사용)
MOAVI_GHCR_TOKEN=$MOAVI_TOKEN

# 버전 (MOAVI_VERSION 과 VERSION 은 함께 올립니다)
MOAVI_REGISTRY=$MOAVI_REGISTRY
MOAVI_VERSION=$MOAVI_VERSION
VERSION=$UPSTREAM_TAG

# 격리망(인터넷 없음) 설치면 true — 버전 확인·카탈로그 갱신을 하지 않음
PROXCENTER_OFFLINE=$([ "$OFFLINE" = "true" ] && echo true)

# 보안 키
APP_SECRET=$APP_SECRET
NEXTAUTH_SECRET=$NEXTAUTH_SECRET
NEXTAUTH_URL=http://$SERVER_IP:3000

# 라이선스 (설치 후 화면에서 입력해도 됨)
LICENSE_KEY=${LICENSE_KEY:-}

# Orchestrator
ORCHESTRATOR_URL=http://orchestrator:8080
ORCHESTRATOR_API_KEY=$ORCHESTRATOR_API_KEY

# 데이터베이스·데이터 볼륨
POSTGRES_USER=moavi
POSTGRES_DB=moavi
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
APP_DATA_VOLUME=moavi_data
EOF

    # compose 의 DB 환경변수가 우선함. 아래 값은 참고용 기본값.
    cat > "$INSTALL_DIR/config/orchestrator.yaml" << EOF
api:
  address: ":8080"
  read_timeout: 30s
  write_timeout: 30s

database:
  driver: postgres
  dsn: "postgres://moavi:${POSTGRES_PASSWORD}@postgres:5432/moavi?sslmode=disable"

proxmox:
  # .env 의 APP_SECRET 과 같아야 합니다
  app_secret: "$APP_SECRET"
  shared_data_path: /app/shared_data

license:
  key: "${LICENSE_KEY:-}"

logging:
  level: info
  format: json
EOF

    chmod 600 "$INSTALL_DIR/.env"
    chmod 644 "$INSTALL_DIR/config/orchestrator.yaml"   # 컨테이너(비 root)가 읽음
    apply_access_env
    setup_https
    log_success "보안 키 생성 및 설정 저장"
}

upgrade_moavi() {
    step 4 "구성 갱신 (업그레이드)"
    cd "$INSTALL_DIR"
    cp -p .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
    # 백업은 최근 5개만 유지
    ls -1t .env.bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -1t docker-compose.yml.bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
    resolve_access
    write_compose

    set_env COMPOSE_FILE "docker-compose.yml:docker-compose.moavi.yml"
    set_env MOAVI_REGISTRY "$MOAVI_REGISTRY"
    set_env MOAVI_VERSION "$MOAVI_VERSION"
    set_env VERSION "$UPSTREAM_TAG"
    set_env MOAVI_GHCR_TOKEN "$MOAVI_TOKEN"
    [ -z "$LICENSE_KEY" ] || set_env LICENSE_KEY "$LICENSE_KEY"
    # 격리망 번들로 업그레이드하면 격리망 표시 (인터넷 업그레이드는 기존 값 유지)
    [ "$OFFLINE" != "true" ] || set_env PROXCENTER_OFFLINE true

    # 구버전 설치에 없던 필수 값 보충
    grep -q '^POSTGRES_PASSWORD=' .env || set_env POSTGRES_PASSWORD "$(openssl rand -hex 24)"
    if ! grep -q '^ORCHESTRATOR_API_KEY=' .env || grep -q '^ORCHESTRATOR_API_KEY=your-orchestrator-api-key-change-me' .env; then
        set_env ORCHESTRATOR_API_KEY "$(openssl rand -hex 32)"
    fi
    apply_access_env
    chmod 600 .env
    setup_https
    log_success "MOAVI $MOAVI_VERSION 로 설정"
}

# ============================================
# 5. 이미지 받기 & 초기화
# ============================================
pull_and_init() {
    step 5 "이미지 받기 및 초기화"
    cd "$INSTALL_DIR"

    if [ "$OFFLINE" = "true" ]; then
        load_images_offline
        init_volumes
        return 0
    fi

    # 모든 이미지를 MOAVI 레지스트리(frontend·orchestrator·weasyprint)와 공개 레지스트리(postgres·nginx)에서 받음
    log_info "이미지 받는 중 (몇 분 걸릴 수 있습니다)..."
    # 일시적 오류(네트워크 끊김, 같은 서버의 이미지 정리와 겹친 압축 해제 실패 등)는 한 번 다시 시도
    if ! docker compose pull --quiet >> "$LOG_FILE" 2>&1; then
        log_warning "이미지 받기 실패 — 10초 후 다시 시도합니다"
        sleep 10
        if ! docker compose pull --quiet >> "$LOG_FILE" 2>&1; then
            local reason
            reason=$(tail -n 20 "$LOG_FILE" | grep -iE 'error|denied|unauthorized|not found|unknown|failed|no space' | tail -n 2 | cut -c1-240)
            [ -z "$reason" ] || echo "$reason" | sed 's/^/    | /'
            if echo "$reason" | grep -qiE 'denied|unauthorized'; then
                log_error "MOAVI 이미지를 받을 권한이 없습니다 — --token <MOAVI 설치 토큰> 으로 다시 실행하세요"
            elif echo "$reason" | grep -qiE 'manifest unknown|not found'; then
                log_error "MOAVI $MOAVI_VERSION 이미지가 레지스트리에 없습니다 — 버전(--version)을 확인하세요"
            elif echo "$reason" | grep -qiE 'no space'; then
                log_error "디스크 공간이 부족합니다 — df -h / 확인 후 docker image prune -a 로 정리하세요"
            fi
            log_error "이미지를 받지 못했습니다 (로그: $LOG_FILE)"
        fi
    fi
    log_success "이미지 받기 완료"
    init_volumes
}

# compose 가 쓰는 볼륨(이름은 .env 기준)을 만들고 화면 데이터 폴더 권한을 맞춤
init_volumes() {
    local vol
    for vol in $(docker compose config 2>/dev/null | sed -n '/^volumes:/,/^[a-z]/ s/^    name: //p'); do
        docker volume create "$vol" > /dev/null 2>&1 || true
    done
    docker compose run --rm --no-deps --user root --entrypoint "" frontend \
        sh -c "mkdir -p /app/data && chown -R 1001:1001 /app/data" >> "$LOG_FILE" 2>&1 \
        || log_error "볼륨을 초기화하지 못했습니다 (로그: $LOG_FILE)"
    log_success "볼륨 초기화 완료"
}

# 격리망: 번들의 이미지 파일을 불러오고, compose 가 쓰는 이미지가 모두 있는지 확인
load_images_offline() {
    log_info "이미지 불러오는 중 (몇 분 걸릴 수 있습니다)..."
    (docker load -i "$OFFLINE_DIR/images.tar.gz" >> "$LOG_FILE" 2>&1) &
    local pid=$!
    spinner $pid "이미지 불러오는 중..."
    wait $pid || log_error "이미지를 불러오지 못했습니다 (디스크 여유 공간 확인, 로그: $LOG_FILE)"

    local missing="" img
    for img in $(docker compose config --images 2>/dev/null); do
        docker image inspect "$img" > /dev/null 2>&1 || missing="$missing $img"
    done
    [ -z "$missing" ] || log_error "번들에 없는 이미지가 있습니다:$missing — 같은 버전으로 번들을 다시 만드세요"
    log_success "이미지 불러오기 완료 ($(echo "$BUNDLE_IMAGES" | wc -w)개)"
}

# ============================================
# 6. 기동
# ============================================
start_and_wait() {
    step 6 "MOAVI 기동"
    cd "$INSTALL_DIR"
    local pull_opt=""
    [ "$OFFLINE" = "true" ] && pull_opt="--pull never"   # 격리망: 레지스트리 접속 시도 안 함
    docker compose up -d --remove-orphans $pull_opt >> "$LOG_FILE" 2>&1 || log_error "컨테이너 기동 실패 (로그: $LOG_FILE)"
    log_success "컨테이너 기동"

    log_info "서비스 준비를 기다리는 중..."
    (
        for _ in $(seq 60); do
            curl -s -f http://localhost:3000/api/health > /dev/null 2>&1 && exit 0
            sleep 2
        done
        exit 1
    ) &
    local wait_pid=$!
    spinner $wait_pid "frontend 기동 중..."
    wait $wait_pid || log_error "frontend가 2분 안에 기동하지 않았습니다. 확인: cd $INSTALL_DIR && docker compose logs frontend"

    (
        for _ in $(seq 60); do
            [ "$(docker inspect --format='{{.State.Health.Status}}' moavi-orchestrator 2>/dev/null)" = "healthy" ] && exit 0
            sleep 2
        done
        exit 1
    ) &
    wait_pid=$!
    spinner $wait_pid "orchestrator 기동 중..."
    wait $wait_pid || log_error "orchestrator가 2분 안에 기동하지 않았습니다. 확인: cd $INSTALL_DIR && docker compose logs orchestrator"

    if [ "$HTTPS" = "true" ]; then
        # nginx 는 시작할 때 찾은 frontend 주소를 계속 씀 → frontend 가 새로 만들어져 내부 주소가 바뀌면 502
        #   (예: 새 컨테이너가 추가돼 주소가 다시 배정될 때) → 업그레이드마다 프록시를 다시 시작해 새 주소를 찾게 함
        docker compose restart proxy >> "$LOG_FILE" 2>&1 || true
        (
            for _ in $(seq 30); do
                curl -sk -f https://localhost/api/health > /dev/null 2>&1 && exit 0
                sleep 2
            done
            exit 1
        ) &
        wait_pid=$!
        spinner $wait_pid "HTTPS 프록시 기동 중..."
        wait $wait_pid || log_error "HTTPS 프록시가 응답하지 않습니다. 확인: cd $INSTALL_DIR && docker compose logs proxy"
    fi

    log_success "모든 서비스 정상"
}

print_summary() {
    local duration=$(( $(date +%s) - START_TIME ))
    SERVER_IP=$(hostname -I | awk '{print $1}' | head -1)

    echo ""
    echo -e "${GREEN}${BOLD}  ┌─────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}${BOLD}  │        MOAVI 설치가 완료되었습니다          │${NC}"
    echo -e "${GREEN}${BOLD}  └─────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "    ${BOLD}접속 주소${NC}   ${CYAN}${PUBLIC_URL:-http://$SERVER_IP:3000}${NC}"
    echo -e "    ${BOLD}설치 위치${NC}   $INSTALL_DIR"
    echo -e "    ${BOLD}버전${NC}        MOAVI $MOAVI_VERSION"
    echo -e "    ${BOLD}소요 시간${NC}   $(format_duration $duration)"
    echo -e "    ${BOLD}설치 로그${NC}   $LOG_FILE"
    echo ""

    if [ "$HTTPS" = "true" ] && [ -z "$CERT_FILE" ] && openssl x509 -in "$INSTALL_DIR/proxy/ssl/moavi.crt" -noout -subject 2>/dev/null | grep -q "O = MOAVI"; then
        echo -e "    ${YELLOW}${BOLD}!${NC} ${YELLOW}자체 서명 인증서 사용 중 — 브라우저에 보안 경고가 표시됩니다${NC}"
        echo -e "      기관 인증서로 교체: ${DIM}--upgrade --cert <인증서> --key <개인키>${NC}"
        echo ""
    fi

    if [ -z "$LICENSE_KEY" ] && [ -z "$(get_env LICENSE_KEY)" ]; then
        echo -e "    ${YELLOW}${BOLD}!${NC} ${YELLOW}라이선스 키가 입력되지 않았습니다${NC}"
        echo -e "      화면의 ${BOLD}설정 > 라이선스${NC}에서 입력하거나 ${DIM}--license <키>${NC} 로 다시 실행하세요"
        echo ""
    fi

    echo -e "    ${DIM}관리 (cd $INSTALL_DIR 후):${NC}"
    echo -e "      ${DIM}docker compose ps          # 상태${NC}"
    echo -e "      ${DIM}docker compose logs -f     # 로그${NC}"
    echo -e "      ${DIM}docker compose down        # 중지${NC}"
    echo ""
    if [ "$OFFLINE" = "true" ]; then
        echo -e "    ${DIM}업그레이드: 새 번들을 반입한 뒤 sudo bash install-moavi.sh --offline <새 번들> --upgrade${NC}"
    else
        echo -e "    ${DIM}업그레이드: sudo bash install-moavi.sh --upgrade --version <MOAVI 버전>${NC}"
    fi
    echo ""
    echo -e "    ${DIM}기술 지원: support@makussystems.co.kr${NC}"
    echo ""
}

main() {
    print_banner
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/moavi-install.log"
    echo "===== MOAVI 설치 $(date -Iseconds) =====" >> "$LOG_FILE"; chmod 600 "$LOG_FILE" 2>/dev/null || true
    preflight_checks
    validate_token
    install_docker
    configure_docker_proxy
    authenticate_registry
    if [ "$UPGRADE_MODE" = "true" ]; then upgrade_moavi; else setup_moavi; fi
    pull_and_init
    start_and_wait
    print_summary
}

main "$@"
