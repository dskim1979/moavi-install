#!/bin/bash
set -e

# ============================================
# MOAVI 설치 스크립트 (Enterprise)
# ============================================
# 신규 설치:
#   sudo bash install-moavi.sh --token <발급 토큰> [--license <키>]
# 업그레이드 (.env·데이터 유지, 이미지/compose 갱신):
#   sudo bash install-moavi.sh --upgrade [--version 1.0.1]
#
# - orchestrator / weasyprint / postgres : 공급사 공식 이미지 (공급사 토큰으로 pull)
# - frontend                             : MOAVI 이미지 (MOAVI_REGISTRY)
# - 기존 /opt/proxcenter 설치가 있으면 /opt/moavi 로 옮겨 MOAVI로 전환합니다 (데이터 유지).
# ============================================

# ---- 릴리스마다 갱신하는 값 ----
MOAVI_VERSION_DEFAULT="latest"      # moavi-frontend 이미지 태그
UPSTREAM_TAG_DEFAULT="v1.4.10"      # Enterprise 구성요소(orchestrator/weasyprint) 버전 — MOAVI 릴리스와 짝을 맞춤
MOAVI_REGISTRY="ghcr.io/dskim1979"
MOAVI_REGISTRY_USER="dskim1979"
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
LEGACY_DIR="/opt/proxcenter"
REGISTRY="ghcr.io"
API_URL="https://proxcenter.io/api/v1/install/validate"   # 설치 토큰 → 레지스트리 계정 발급
DOCKER_DROPIN_DIR="/etc/systemd/system/docker.service.d"
LOG_FILE="/var/log/moavi-install.log"   # docker 출력은 화면 대신 로그로
COMPOSE_URL_BASE="https://raw.githubusercontent.com/adminsyspro/proxcenter-ui"

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
사용법: $0 --token <발급 토큰> [옵션]
        $0 --upgrade [옵션]

필수 (신규 설치):
  --token <token>        Enterprise 설치 토큰 (OEM 계약으로 발급, 업그레이드 때는 생략 가능)

옵션:
  --license <key>        라이선스 키 (설치 후 설정 > 라이선스에서 입력해도 됨)
  --moavi-token <token>  (선택) MOAVI 이미지를 비공개로 운영할 때만 필요
  --version <tag>        MOAVI 버전 (기본: $MOAVI_VERSION_DEFAULT)
  --upgrade              기존 설치 업그레이드 (.env·데이터 유지)
  --help                 도움말
EOF
    exit 1
}

# ============================================
# 인자
# ============================================
INSTALL_TOKEN=""
REGISTRY_USER=""
REGISTRY_PASS=""
LICENSE_KEY=""
MOAVI_TOKEN=""
MOAVI_VERSION="$MOAVI_VERSION_DEFAULT"
UPSTREAM_TAG="$UPSTREAM_TAG_DEFAULT"
UPGRADE_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --token)       INSTALL_TOKEN="$2"; shift 2 ;;
        --license)     LICENSE_KEY="$2"; shift 2 ;;
        --moavi-token) MOAVI_TOKEN="$2"; shift 2 ;;
        --version)     MOAVI_VERSION="$2"; shift 2 ;;
        --upstream)    UPSTREAM_TAG="$2"; shift 2 ;;
        --upgrade)     UPGRADE_MODE=true; shift ;;
        --help|-h)     show_usage ;;
        *)             log_error "알 수 없는 옵션: $1" ;;
    esac
done

MOAVI_IMAGE="$MOAVI_REGISTRY/moavi-frontend:$MOAVI_VERSION"

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
MIGRATE_LEGACY=false
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

    # 기존 설치(/opt/proxcenter)가 있으면 토큰·레지스트리 확인 후 migrate_legacy 에서 옮김
    if [ ! -f "$INSTALL_DIR/.env" ] && [ -f "$LEGACY_DIR/.env" ]; then
        log_warning "기존 설치($LEGACY_DIR)를 발견했습니다. 데이터를 유지한 채 $INSTALL_DIR 로 전환합니다."
        MIGRATE_LEGACY=true
        UPGRADE_MODE=true
        ENV_FILE="$LEGACY_DIR/.env"
    fi

    if [ "$UPGRADE_MODE" = "true" ]; then
        [ -f "$ENV_FILE" ] || log_error "$INSTALL_DIR 에 기존 설치가 없습니다. --upgrade 없이 신규 설치하세요."
        [ -n "$MOAVI_TOKEN" ] || MOAVI_TOKEN=$(get_env MOAVI_GHCR_TOKEN)
    fi

    if [ -z "$INSTALL_TOKEN" ] && [ "$UPGRADE_MODE" != "true" ]; then
        echo -e "${RED}오류: 신규 설치에는 --token 이 필요합니다${NC}"; echo ""; show_usage
    fi
}

# ============================================
# 1. 토큰 확인
# ============================================
# JSON 최상위 키 값 출력 (jq 불필요, 실패해도 빈 값)
parse_json() {
    local json="$1" key="$2"
    if command -v python3 &> /dev/null; then
        echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''))" 2>/dev/null || true
    else
        echo "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
    fi
}

# 설치 토큰을 공급사 API에 확인하고 레지스트리 계정을 받음 (공급사 설치 스크립트와 동일한 방식)
validate_token() {
    step 1 "설치 토큰 확인"

    if [ -z "$INSTALL_TOKEN" ]; then
        log_info "토큰 생략 — 기존 레지스트리 로그인을 사용합니다"
        return 0
    fi

    local response body code valid msg
    if ! response=$(curl -sS --connect-timeout 15 --max-time 60 -w "\n%{http_code}" -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"token\": \"$INSTALL_TOKEN\", \"hostname\": \"$(hostname 2>/dev/null || echo unknown)\", \"os\": \"$OS $VERSION_ID\"}" 2>&1); then
        log_error "토큰 확인 서버에 접속할 수 없습니다: $(echo "$response" | grep -vE '^[0-9]{3}$' | tail -1)"
    fi
    code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$code" != "200" ]; then
        msg=$(parse_json "$body" "message")
        log_error "설치 토큰 확인 실패: ${msg:-HTTP $code}"
    fi
    valid=$(parse_json "$body" "valid")
    if [ "$valid" != "True" ] && [ "$valid" != "true" ] && [ "$valid" != "1" ]; then
        log_error "설치 토큰이 올바르지 않습니다: $(parse_json "$body" "message")"
    fi

    REGISTRY=$(parse_json "$body" "registry")
    REGISTRY_USER=$(parse_json "$body" "username")
    REGISTRY_PASS=$(parse_json "$body" "password")
    if [ -z "$REGISTRY" ] || [ -z "$REGISTRY_USER" ] || [ -z "$REGISTRY_PASS" ]; then
        log_error "레지스트리 계정을 받지 못했습니다"
    fi
    log_success "설치 토큰 확인"
}

# ============================================
# 2. Docker 설치
# ============================================
install_docker() {
    step 2 "Docker 설치"

    if command -v docker &> /dev/null; then
        log_success "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1) 설치되어 있음"
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
# 3. 레지스트리 인증 (공급사 이미지)
# ============================================
authenticate_registry() {
    step 3 "컨테이너 레지스트리 인증"
    if [ -z "$REGISTRY_PASS" ]; then
        log_info "기존 로그인 정보를 사용합니다"
        return 0
    fi
    local out
    if ! out=$(echo "$REGISTRY_PASS" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin 2>&1); then
        log_error "레지스트리 인증 실패: $(echo "$out" | grep -viE '^WARNING|^$' | tail -1)"
    fi
    log_success "$REGISTRY 인증 완료"
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

migrate_legacy() {
    [ "$MIGRATE_LEGACY" = "true" ] || return 0
    (cd "$LEGACY_DIR" && docker compose down) > /dev/null 2>&1 || true
    mv "$LEGACY_DIR" "$INSTALL_DIR"
    ENV_FILE="$INSTALL_DIR/.env"
    log_success "$LEGACY_DIR → $INSTALL_DIR 이동 완료"
}

# ============================================
# 4. 구성
# ============================================
write_compose() {
    cd "$INSTALL_DIR"
    local url="$COMPOSE_URL_BASE/$UPSTREAM_TAG/docker-compose.enterprise.yml"
    if ! curl -fsSL "$url" -o docker-compose.yml.new 2>/dev/null; then
        rm -f docker-compose.yml.new
        log_error "compose 파일을 받지 못했습니다"
    fi
    if [ -f docker-compose.yml ] && ! diff -q docker-compose.yml docker-compose.yml.new > /dev/null 2>&1; then
        cp -p docker-compose.yml "docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    mv docker-compose.yml.new docker-compose.yml

    # frontend 만 MOAVI 이미지로, 컨테이너 이름은 moavi-* 로
    cat > docker-compose.moavi.yml << 'EOF'
# MOAVI override (install-moavi.sh 가 생성 — 직접 수정하지 마세요)
services:
  frontend:
    image: ${MOAVI_REGISTRY}/moavi-frontend:${MOAVI_VERSION:-latest}
    container_name: moavi-frontend
  postgres:
    container_name: moavi-postgres
  orchestrator:
    container_name: moavi-orchestrator
  weasyprint:
    container_name: moavi-weasyprint
EOF
    log_success "compose 구성 저장"
}

setup_moavi() {
    step 4 "MOAVI 구성"

    mkdir -p "$INSTALL_DIR/config"
    cd "$INSTALL_DIR"
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

# 레지스트리 (GHCR_TOKEN 은 제품이 warm migration 노드에 VDDK 설치할 때 사용)
GHCR_TOKEN=$REGISTRY_PASS
MOAVI_GHCR_TOKEN=$MOAVI_TOKEN

# 버전 (MOAVI_VERSION 과 VERSION 은 함께 올립니다)
MOAVI_REGISTRY=$MOAVI_REGISTRY
MOAVI_VERSION=$MOAVI_VERSION
VERSION=$UPSTREAM_TAG

# 보안 키
APP_SECRET=$APP_SECRET
NEXTAUTH_SECRET=$NEXTAUTH_SECRET
NEXTAUTH_URL=http://$SERVER_IP:3000

# 라이선스 (설치 후 화면에서 입력해도 됨)
LICENSE_KEY=${LICENSE_KEY:-}

# Orchestrator
ORCHESTRATOR_URL=http://orchestrator:8080
ORCHESTRATOR_API_KEY=$ORCHESTRATOR_API_KEY

# Postgres
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF

    # compose 가 PROXCENTER_DATABASE_* 환경변수로 덮어씀. 아래 값은 참고용 기본값.
    cat > "$INSTALL_DIR/config/orchestrator.yaml" << EOF
api:
  address: ":8080"
  read_timeout: 30s
  write_timeout: 30s

database:
  driver: postgres
  dsn: "postgres://proxcenter:${POSTGRES_PASSWORD}@postgres:5432/proxcenter?sslmode=disable"

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
    log_success "보안 키 생성 및 설정 저장"
}

upgrade_moavi() {
    step 4 "구성 갱신 (업그레이드)"
    cd "$INSTALL_DIR"
    cp -p .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
    write_compose

    set_env COMPOSE_FILE "docker-compose.yml:docker-compose.moavi.yml"
    set_env MOAVI_REGISTRY "$MOAVI_REGISTRY"
    set_env MOAVI_VERSION "$MOAVI_VERSION"
    set_env VERSION "$UPSTREAM_TAG"
    [ -z "$REGISTRY_PASS" ] || set_env GHCR_TOKEN "$REGISTRY_PASS"
    set_env MOAVI_GHCR_TOKEN "$MOAVI_TOKEN"
    [ -z "$LICENSE_KEY" ] || set_env LICENSE_KEY "$LICENSE_KEY"

    # 구버전 설치에 없던 필수 값 보충
    grep -q '^POSTGRES_PASSWORD=' .env || set_env POSTGRES_PASSWORD "$(openssl rand -hex 24)"
    if ! grep -q '^ORCHESTRATOR_API_KEY=' .env || grep -q '^ORCHESTRATOR_API_KEY=your-orchestrator-api-key-change-me' .env; then
        set_env ORCHESTRATOR_API_KEY "$(openssl rand -hex 32)"
    fi
    chmod 600 .env
    log_success "MOAVI $MOAVI_VERSION 로 설정"
}

# ============================================
# 5. 이미지 받기 & 초기화
# ============================================
pull_and_init() {
    step 5 "이미지 받기 및 초기화"
    cd "$INSTALL_DIR"

    # 공급사 이미지 (frontend 제외)
    log_info "이미지 받는 중 (몇 분 걸릴 수 있습니다)..."
    if ! docker compose pull $(docker compose config --services | grep -vx frontend) >> "$LOG_FILE" 2>&1; then
        log_error "공급사 이미지를 받지 못했습니다 ($REGISTRY)"
    fi

    # MOAVI 이미지: ghcr.io 로그인은 공급사 계정이 쓰고 있으므로 별도 인증 설정으로 받음
    #  - 공개 이미지(기본): 빈 설정으로 익명 pull → 공급사 설치 토큰 하나로 설치 완료
    #  - 비공개 이미지: --moavi-token (GHCR read:packages) 로 로그인 후 pull
    local cfg
    cfg=$(mktemp -d)
    if [ -n "$MOAVI_TOKEN" ] && \
       ! echo "$MOAVI_TOKEN" | docker --config "$cfg" login "${MOAVI_REGISTRY%%/*}" -u "$MOAVI_REGISTRY_USER" --password-stdin > /dev/null 2>&1; then
        rm -rf "$cfg"
        log_error "MOAVI 레지스트리 인증 실패 (--moavi-token 확인)"
    fi
    if ! docker --config "$cfg" pull "$MOAVI_IMAGE" >> "$LOG_FILE" 2>&1; then
        rm -rf "$cfg"
        log_error "MOAVI 이미지를 받지 못했습니다: $MOAVI_IMAGE (버전 확인, 비공개 이미지면 --moavi-token 필요)"
    fi
    rm -rf "$cfg"
    log_success "이미지 받기 완료"

    docker volume create proxcenter_data > /dev/null 2>&1 || true
    docker volume create orchestrator_data > /dev/null 2>&1 || true
    docker volume create postgres_data > /dev/null 2>&1 || true

    docker run --rm --user root --entrypoint "" \
        -v proxcenter_data:/app/data \
        "$MOAVI_IMAGE" \
        sh -c "mkdir -p /app/data && chown -R 1001:1001 /app/data" > /dev/null 2>&1
    log_success "볼륨 초기화 완료"
}

# ============================================
# 6. 기동
# ============================================
start_and_wait() {
    step 6 "MOAVI 기동"
    cd "$INSTALL_DIR"
    docker compose up -d --remove-orphans >> "$LOG_FILE" 2>&1 || log_error "컨테이너 기동 실패 (로그: $LOG_FILE)"
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
    echo -e "    ${BOLD}접속 주소${NC}   ${CYAN}http://$SERVER_IP:3000${NC}"
    echo -e "    ${BOLD}설치 위치${NC}   $INSTALL_DIR"
    echo -e "    ${BOLD}버전${NC}        MOAVI $MOAVI_VERSION"
    echo -e "    ${BOLD}소요 시간${NC}   $(format_duration $duration)"
    echo -e "    ${BOLD}설치 로그${NC}   $LOG_FILE"
    echo ""

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
    echo -e "    ${DIM}업그레이드: sudo bash install-moavi.sh --upgrade --version <MOAVI 버전>${NC}"
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
    migrate_legacy
    if [ "$UPGRADE_MODE" = "true" ]; then upgrade_moavi; else setup_moavi; fi
    pull_and_init
    start_and_wait
    print_summary
}

main "$@"
