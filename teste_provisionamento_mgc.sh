#!/usr/bin/env bash
# Teste de tempo de provisionamento de produtos da Magalu Cloud via MGC CLI.
#
# Produtos suportados:
#   - vm: Virtual Machine, uma por AZ
#   - volume: Block Storage Volume, um por AZ
#   - object-storage: bucket, um por região (Object Storage não usa AZ)
#   - k8s: cluster Kubernetes, um por AZ selecionada; a AZ é aplicada ao node pool
#   - dbaas: instância DBaaS, uma por AZ
#
# Pré-requisitos: Bash 4+, mgc CLI, jq, timeout e utilitários GNU básicos.
# Antes de executar: mgc auth login

set -Eeuo pipefail

readonly RUN_ID="$(date -u +'%Y%m%dT%H%M%S%3NZ')"
readonly RUN_TOKEN="$(date -u +'%Y%m%dt%H%M%Sz')"
readonly RUN_STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
readonly FALLBACK_ZONES="br-se1-a br-se1-b br-se1-c br-ne1-a br-ne1-b"

PRODUCT="${PRODUCT:-}"
TARGET_REGIONS="${TARGET_REGIONS:-}"
TARGET_AZS="${TARGET_AZS:-}"
TARGET_ZONES="${TARGET_ZONES:-}"
if [[ -n "${OWNER_TAG+x}" && -n "${OWNER_TAG}" ]]; then
  OWNER_TAG_EXPLICIT=true
else
  OWNER_TAG_EXPLICIT=false
fi
OWNER_TAG="${OWNER_TAG:-}"
INTERACTIVE="${INTERACTIVE:-auto}"
if [[ -n "${AUTO_DELETE+x}" ]]; then
  AUTO_DELETE_EXPLICIT=true
else
  AUTO_DELETE_EXPLICIT=false
fi
AUTO_DELETE="${AUTO_DELETE:-true}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
RESOURCE_REFERENCE_MODE="${RESOURCE_REFERENCE_MODE:-name}"

# Virtual Machine
SSH_KEY_NAME="${SSH_KEY_NAME:-}"
VM_IMAGE="${VM_IMAGE:-}"
VM_MACHINE_TYPE="${VM_MACHINE_TYPE:-}"
ASSOCIATE_PUBLIC_IP="${ASSOCIATE_PUBLIC_IP:-true}"
READINESS_CHECK="${READINESS_CHECK:-tcp22}"
READINESS_TIMEOUT_SECONDS="${READINESS_TIMEOUT_SECONDS:-300}"
TCP_CONNECT_TIMEOUT_SECONDS="${TCP_CONNECT_TIMEOUT_SECONDS:-3}"
VPC_ID="${VPC_ID:-}"
VPC_NAME="${VPC_NAME:-}"

# Block Storage
VOLUME_SIZE="${VOLUME_SIZE:-10}"
VOLUME_TYPE_NAME="${VOLUME_TYPE_NAME:-}"

# Kubernetes
K8S_MACHINE_TYPE="${K8S_MACHINE_TYPE:-${K8S_FLAVOR:-}}"
K8S_VERSION="${K8S_VERSION:-}"
K8S_REPLICAS="${K8S_REPLICAS:-1}"
K8S_MAX_PODS="${K8S_MAX_PODS:-32}"

# DBaaS
DBAAS_ENGINE="${DBAAS_ENGINE:-}"
DBAAS_INSTANCE_TYPE="${DBAAS_INSTANCE_TYPE:-}"
DBAAS_USER="${DBAAS_USER:-mgctest}"
DBAAS_PASSWORD="${DBAAS_PASSWORD:-}"
DBAAS_VOLUME_SIZE="${DBAAS_VOLUME_SIZE:-10}"
DBAAS_VOLUME_TYPE="${DBAAS_VOLUME_TYPE:-CLOUD_NVME15K}"
DBAAS_BACKUP_RETENTION_DAYS="${DBAAS_BACKUP_RETENTION_DAYS:-1}"

OUTPUT_PREFIX="${OUTPUT_PREFIX:-provisionamento-mgc-${RUN_ID}}"
CSV_FILE="${CSV_FILE:-${OUTPUT_PREFIX}.csv}"
REPORT_FILE="${REPORT_FILE:-${OUTPUT_PREFIX}.md}"
DIAGNOSTIC_FILE="${DIAGNOSTIC_FILE:-${OUTPUT_PREFIX}.log}"

TENANT_LABEL=""
TMP_DIR="$(mktemp -d)"
readonly MAIN_BASHPID="${BASHPID:-$$}"
SSH_KEYS_JSON='[]'

# ALL_ZONES: catálogo da conta; ZONES: seleção de AZ; TARGETS: unidades provisionadas.
declare -a ALL_ZONES=()
declare -a ZONES=()
declare -a REGIONS=()
declare -a TARGETS=()

# VM por AZ.
declare -A VM_IMAGE_ID_BY_TARGET=()
declare -A VM_IMAGE_NAME_BY_TARGET=()
declare -A VM_IMAGE_VERSION_BY_TARGET=()
declare -A VM_IMAGE_VCPU_BY_TARGET=()
declare -A VM_IMAGE_RAM_BY_TARGET=()
declare -A VM_IMAGE_DISK_BY_TARGET=()
declare -A VM_TYPE_ID_BY_TARGET=()
declare -A VM_TYPE_NAME_BY_TARGET=()
declare -A VM_TYPE_VCPU_BY_TARGET=()
declare -A VM_TYPE_RAM_BY_TARGET=()
declare -A VM_TYPE_DISK_BY_TARGET=()

# Volume por AZ.
declare -A VOL_TYPE_ID_BY_TARGET=()
declare -A VOL_TYPE_NAME_BY_TARGET=()
declare -A VOL_TYPE_DISK_BY_TARGET=()
declare -A VOL_TYPE_IOPS_BY_TARGET=()

# Kubernetes: versão/requisitos por região e tipo de máquina por AZ.
declare -A K8S_VERSION_BY_REGION=()
declare -A K8S_MIN_VCPU_BY_REGION=()
declare -A K8S_MIN_RAM_BY_REGION=()
declare -A K8S_MIN_DISK_BY_REGION=()
declare -A K8S_TYPE_NAME_BY_TARGET=()
declare -A K8S_TYPE_ID_BY_TARGET=()
declare -A K8S_TYPE_VCPU_BY_TARGET=()
declare -A K8S_TYPE_RAM_BY_TARGET=()
declare -A K8S_TYPE_DISK_BY_TARGET=()

# DBaaS por região.
declare -A DB_ENGINE_ID_BY_REGION=()
declare -A DB_ENGINE_NAME_BY_REGION=()
declare -A DB_ENGINE_VERSION_BY_REGION=()
declare -A DB_TYPE_ID_BY_REGION=()
declare -A DB_TYPE_NAME_BY_REGION=()
declare -A DB_TYPE_VCPU_BY_REGION=()
declare -A DB_TYPE_RAM_BY_REGION=()

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Uso:
  ./teste_provisionamento_mgc.sh [opções]

Produtos:
  --product vm|volume|object-storage|k8s|dbaas

Localização:
  --regions LISTA          Ex.: br-se1,br-ne1
  --azs LISTA              Ex.: a,b,c
  --zones LISTA            Ex.: br-se1-a,br-se1-c,br-ne1-b
                           Substitui --regions e --azs.
  Observação: Object Storage é testado por região; os demais produtos usam AZ.

Identificação e execução:
  --owner IDENTIFICADOR    Sobrescreve o identificador incluído no nome.
                           Para VM, o padrão é derivado da chave SSH escolhida.
  --interactive            Força menus interativos.
  --non-interactive        Não exibe perguntas.
  --keep                   Mantém os recursos.
  --auto-delete true|false Padrão: true
  --timeout SEGUNDOS       Timeout por recurso. Padrão: 1800

Virtual Machine:
  --ssh-key NOME           Chave SSH.
  --image NOME_OU_ID       Imagem. Sem isso, escolhe Ubuntu ativa de menor requisito.
  --machine-type NOME_OU_ID Tipo, por exemplo BV1-1-10. Sem isso, escolhe o menor compatível.
  --public-ip true|false    Padrão: true
  --readiness none|tcp22    Padrão: tcp22
  --vpc-name NOME          VPC explícita.
  --vpc-id UUID            VPC explícita.

Block Storage:
  --volume-size GIB        Mínimo: 10. Padrão: 10
  --volume-type NOME       Sem isso, seleciona automaticamente.

Kubernetes:
  --k8s-machine-type NOME  Tipo de máquina do node pool, por exemplo BV2-4-40.
                           Sem isso, escolhe o menor compatível com a versão.
  --k8s-flavor NOME        Alias legado de --k8s-machine-type.
  --k8s-version VERSAO     Ex.: v1.32.3. Sem isso, escolhe a mais recente.
  --k8s-replicas NUMERO    Padrão: 1
  --k8s-max-pods NUMERO    Padrão: 32

DBaaS:
  --dbaas-engine NOME|ID|NOME@VERSAO
  --dbaas-instance-type NOME|ID
  --dbaas-user USUARIO     Padrão: mgctest
  --dbaas-password SENHA   Opcional. Se omitida, gera uma senha temporária e não a registra.
  --dbaas-volume-size GIB  Mínimo: 10. Padrão: 10
  --dbaas-volume-type TIPO Padrão: CLOUD_NVME15K

Exemplos:
  mgc auth login
  ./teste_provisionamento_mgc.sh

  ./teste_provisionamento_mgc.sh --product vm --zones br-se1-a,br-ne1-b \
    --ssh-key minha-chave --image 'cloud-ubuntu-24.04 LTS' --machine-type BV1-1-10

  ./teste_provisionamento_mgc.sh --product object-storage --regions br-se1,br-ne1

  ./teste_provisionamento_mgc.sh --product k8s --regions br-se1 --azs a,b \
    --k8s-machine-type BV2-4-40 --k8s-replicas 1

  ./teste_provisionamento_mgc.sh --product dbaas --zones br-se1-a \
    --dbaas-engine PostgreSQL
USAGE
}

require_value() {
  [[ -n "${2:-}" ]] || fail "A opção $1 exige um valor."
}

parse_args() {
  while (($#)); do
    case "$1" in
      --product) require_value "$1" "${2:-}"; PRODUCT="$2"; shift 2 ;;
      --regions) require_value "$1" "${2:-}"; TARGET_REGIONS="$2"; shift 2 ;;
      --azs) require_value "$1" "${2:-}"; TARGET_AZS="$2"; shift 2 ;;
      --zones) require_value "$1" "${2:-}"; TARGET_ZONES="$2"; shift 2 ;;
      --owner) require_value "$1" "${2:-}"; OWNER_TAG="$2"; OWNER_TAG_EXPLICIT=true; shift 2 ;;
      --interactive) INTERACTIVE=true; shift ;;
      --non-interactive) INTERACTIVE=false; shift ;;
      --keep) AUTO_DELETE=false; AUTO_DELETE_EXPLICIT=true; shift ;;
      --auto-delete) require_value "$1" "${2:-}"; AUTO_DELETE="$2"; AUTO_DELETE_EXPLICIT=true; shift 2 ;;
      --timeout) require_value "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;

      --ssh-key) require_value "$1" "${2:-}"; SSH_KEY_NAME="$2"; shift 2 ;;
      --image) require_value "$1" "${2:-}"; VM_IMAGE="$2"; shift 2 ;;
      --machine-type) require_value "$1" "${2:-}"; VM_MACHINE_TYPE="$2"; shift 2 ;;
      --public-ip) require_value "$1" "${2:-}"; ASSOCIATE_PUBLIC_IP="$2"; shift 2 ;;
      --readiness) require_value "$1" "${2:-}"; READINESS_CHECK="$2"; shift 2 ;;
      --vpc-name) require_value "$1" "${2:-}"; VPC_NAME="$2"; shift 2 ;;
      --vpc-id) require_value "$1" "${2:-}"; VPC_ID="$2"; shift 2 ;;

      --volume-size) require_value "$1" "${2:-}"; VOLUME_SIZE="$2"; shift 2 ;;
      --volume-type) require_value "$1" "${2:-}"; VOLUME_TYPE_NAME="$2"; shift 2 ;;

      --k8s-machine-type) require_value "$1" "${2:-}"; K8S_MACHINE_TYPE="$2"; shift 2 ;;
      --k8s-flavor) require_value "$1" "${2:-}"; K8S_MACHINE_TYPE="$2"; shift 2 ;;
      --k8s-version) require_value "$1" "${2:-}"; K8S_VERSION="$2"; shift 2 ;;
      --k8s-replicas) require_value "$1" "${2:-}"; K8S_REPLICAS="$2"; shift 2 ;;
      --k8s-max-pods) require_value "$1" "${2:-}"; K8S_MAX_PODS="$2"; shift 2 ;;

      --dbaas-engine) require_value "$1" "${2:-}"; DBAAS_ENGINE="$2"; shift 2 ;;
      --dbaas-instance-type) require_value "$1" "${2:-}"; DBAAS_INSTANCE_TYPE="$2"; shift 2 ;;
      --dbaas-user) require_value "$1" "${2:-}"; DBAAS_USER="$2"; shift 2 ;;
      --dbaas-password) require_value "$1" "${2:-}"; DBAAS_PASSWORD="$2"; shift 2 ;;
      --dbaas-volume-size) require_value "$1" "${2:-}"; DBAAS_VOLUME_SIZE="$2"; shift 2 ;;
      --dbaas-volume-type) require_value "$1" "${2:-}"; DBAAS_VOLUME_TYPE="$2"; shift 2 ;;

      -h|--help) usage; exit 0 ;;
      *) fail "Opção desconhecida: $1. Use --help." ;;
    esac
  done
}

is_true() {
  case "${1,,}" in true|1|yes|sim) return 0 ;; *) return 1 ;; esac
}

should_interact() {
  case "${INTERACTIVE,,}" in
    true|1|yes|sim) return 0 ;;
    false|0|no|nao|não) return 1 ;;
    auto) [[ -t 0 && -t 1 ]] ;;
    *) fail "INTERACTIVE deve ser auto, true ou false." ;;
  esac
}

now_ms() { date +%s%3N; }
iso_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

list_to_words() {
  local value="$1"
  value="${value//,/ }"
  value="${value//;/ }"
  printf '%s\n' "$value"
}

array_contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

sanitize_tag() {
  local value="${1,,}"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  printf '%.10s\n' "$value"
}

derive_owner_from_ssh_key() {
  local key="$1" candidate
  # Usa a parte anterior ao primeiro hífen ou underscore.
  # Exemplo: usuario-chave -> usuario; joao.silva-notebook -> joao-silva.
  candidate="${key%%[-_]*}"
  candidate="$(sanitize_tag "$candidate")"
  [[ -n "$candidate" ]] || candidate="$(sanitize_tag "$key")"
  printf '%s\n' "$candidate"
}

resolve_owner_tag() {
  if [[ -z "$OWNER_TAG" ]]; then
    if [[ "$PRODUCT" == "vm" && -n "$SSH_KEY_NAME" ]]; then
      OWNER_TAG="$(derive_owner_from_ssh_key "$SSH_KEY_NAME")"
      log "Identificador do responsável derivado da chave SSH: $OWNER_TAG"
    else
      OWNER_TAG="$(sanitize_tag "${USER:-equipe}")"
      [[ -n "$OWNER_TAG" ]] || OWNER_TAG="equipe"
      log "Identificador do responsável definido pelo usuário local: $OWNER_TAG"
    fi
  else
    OWNER_TAG="$(sanitize_tag "$OWNER_TAG")"
  fi
  [[ -n "$OWNER_TAG" ]] || fail "O identificador do responsável ficou vazio. Use --owner para defini-lo."
}

normalize_product() {
  case "${1,,}" in
    vm|virtual-machine|virtual_machine) printf 'vm\n' ;;
    volume|vol|block-storage|block_storage) printf 'volume\n' ;;
    object|object-storage|object_storage|bucket) printf 'object-storage\n' ;;
    k8s|kubernetes|mke) printf 'k8s\n' ;;
    dbaas|database|db) printf 'dbaas\n' ;;
    *) return 1 ;;
  esac
}

normalize_region() {
  case "${1,,}" in
    se1) printf 'br-se1\n' ;;
    ne1) printf 'br-ne1\n' ;;
    *) printf '%s\n' "${1,,}" ;;
  esac
}

region_from_zone() { printf '%s\n' "${1%-*}"; }
az_from_zone() { printf '%s\n' "${1##*-}"; }

product_label() {
  case "$PRODUCT" in
    vm) printf 'Virtual Machine\n' ;;
    volume) printf 'Block Storage Volume\n' ;;
    object-storage) printf 'Object Storage Bucket\n' ;;
    k8s) printf 'Kubernetes Cluster\n' ;;
    dbaas) printf 'DBaaS Instance\n' ;;
  esac
}

product_tag() {
  case "$PRODUCT" in
    vm) printf 'vm\n' ;;
    volume) printf 'vol\n' ;;
    object-storage) printf 'obj\n' ;;
    k8s) printf 'k8s\n' ;;
    dbaas) printf 'db\n' ;;
  esac
}

product_is_regional() {
  [[ "$PRODUCT" == "object-storage" ]]
}

target_region() {
  if product_is_regional; then printf '%s\n' "$1"; else region_from_zone "$1"; fi
}

target_az() {
  if product_is_regional; then printf '\n'; else az_from_zone "$1"; fi
}

target_result_file() {
  local safe="${1//[^a-zA-Z0-9_-]/_}"
  printf '%s/result-%s.json\n' "$TMP_DIR" "$safe"
}

build_resource_name() {
  local target="$1"
  printf 'teste-prov-%s-%s-%s-%s\n' "$OWNER_TAG" "$(product_tag)" "$target" "${RUN_TOKEN,,}"
}

name_limit() {
  case "$PRODUCT" in
    vm|volume) printf '50\n' ;;
    object-storage|k8s) printf '63\n' ;;
    dbaas) printf '100\n' ;;
  esac
}

validate_resource_names() {
  local target name length limit
  limit="$(name_limit)"
  for target in "${TARGETS[@]}"; do
    name="$(build_resource_name "$target")"
    length=${#name}
    (( length >= 3 && length <= limit )) || fail "Nome inválido para $target ($length caracteres; limite 3-$limit): $name"
  done
}

require_commands() {
  local command_name
  for command_name in mgc jq date mktemp sed tr sleep timeout sort grep; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Comando obrigatório não encontrado: $command_name"
  done

  local var
  for var in TIMEOUT_SECONDS POLL_INTERVAL_SECONDS READINESS_TIMEOUT_SECONDS TCP_CONNECT_TIMEOUT_SECONDS VOLUME_SIZE K8S_REPLICAS K8S_MAX_PODS DBAAS_VOLUME_SIZE DBAAS_BACKUP_RETENTION_DAYS; do
    [[ "${!var}" =~ ^[0-9]+$ ]] || fail "$var deve ser um inteiro."
  done
  (( TIMEOUT_SECONDS > 0 )) || fail "TIMEOUT_SECONDS deve ser maior que zero."
  (( POLL_INTERVAL_SECONDS > 0 )) || fail "POLL_INTERVAL_SECONDS deve ser maior que zero."
  (( VOLUME_SIZE >= 10 )) || fail "VOLUME_SIZE deve ser de pelo menos 10 GiB."
  (( K8S_REPLICAS >= 1 )) || fail "K8S_REPLICAS deve ser pelo menos 1."
  (( K8S_MAX_PODS >= 8 && K8S_MAX_PODS <= 110 )) || fail "K8S_MAX_PODS deve estar entre 8 e 110."
  (( DBAAS_VOLUME_SIZE >= 10 )) || fail "DBAAS_VOLUME_SIZE deve ser de pelo menos 10 GiB."
  ((${#DBAAS_USER} <= 25)) || fail "DBAAS_USER deve ter no máximo 25 caracteres."
  [[ -z "$VPC_ID" || -z "$VPC_NAME" ]] || fail "Informe apenas VPC_ID ou VPC_NAME."
  case "$READINESS_CHECK" in none|tcp22) ;; *) fail "READINESS_CHECK deve ser none ou tcp22." ;; esac
  case "${AUTO_DELETE,,}" in true|1|yes|sim|false|0|no|nao|não) ;; *) fail "AUTO_DELETE deve ser true ou false." ;; esac
}

check_authentication() {
  local response
  log "Validando autenticação da MGC CLI..."
  if ! response="$(mgc auth tenant current --output json --raw 2>"$TMP_DIR/auth.log")"; then
    fail "A MGC CLI não está autenticada ou a sessão expirou. Execute 'mgc auth login'."
  fi
  TENANT_LABEL="$(jq -r 'if type=="object" then (.name // .legal_name // .tenant_name // .id // .tenant_id // empty) elif type=="string" then . else empty end' <<< "$response" 2>/dev/null || true)"
  [[ -n "$TENANT_LABEL" ]] || TENANT_LABEL="tenant ativo não identificado"
  log "Autenticação válida. Tenant ativo: $TENANT_LABEL"
}

discover_zones() {
  local response zones_text
  log "Consultando regiões e zonas disponíveis para a conta..."
  if response="$(mgc profile availability-zones list --output json --raw 2>"$TMP_DIR/availability-zones.log")"; then
    zones_text="$(jq -r '[.. | strings | select(test("^br-[a-z0-9]+-[a-z]$"))] | unique | sort | .[]' <<< "$response" 2>/dev/null || true)"
  else
    zones_text=""
  fi
  if [[ -z "$zones_text" ]]; then
    warn "Não foi possível interpretar as AZs; usando a lista conhecida como fallback."
    zones_text="$(list_to_words "$FALLBACK_ZONES" | tr ' ' '\n')"
  fi
  mapfile -t ALL_ZONES < <(printf '%s\n' "$zones_text" | sed '/^$/d' | sort -u)
  ((${#ALL_ZONES[@]})) || fail "Nenhuma zona foi encontrada."
}

available_regions_text() {
  local zone
  for zone in "${ALL_ZONES[@]}"; do region_from_zone "$zone"; done | sort -u | paste -sd, -
}

available_azs_text() {
  local zone
  for zone in "${ALL_ZONES[@]}"; do az_from_zone "$zone"; done | sort -u | paste -sd, -
}

prompt_product() {
  local answer
  printf '\nProduto para o teste:\n'
  printf '  1) Virtual Machine\n'
  printf '  2) Block Storage Volume\n'
  printf '  3) Object Storage Bucket\n'
  printf '  4) Kubernetes Cluster\n'
  printf '  5) DBaaS Cluster\n'
  read -r -p 'Selecione [1]: ' answer
  case "${answer:-1}" in
    1) PRODUCT=vm ;; 2) PRODUCT=volume ;; 3) PRODUCT=object-storage ;; 4) PRODUCT=k8s ;; 5) PRODUCT=dbaas ;;
    *) PRODUCT="${answer}" ;;
  esac
}

prompt_auto_delete() {
  local answer
  printf '\nLimpeza dos recursos:\n'
  printf '  Por padrão, os recursos criados pelo teste são removidos ao final.\n'
  read -r -p 'Remover automaticamente os recursos ao final? [S/n]: ' answer
  case "${answer:-s}" in
    s|S|sim|SIM|Sim|y|Y|yes|YES|Yes) AUTO_DELETE=true ;;
    n|N|nao|não|NAO|NÃO|Nao|Não|no|NO|No)
      AUTO_DELETE=false
      warn "Os recursos serão mantidos após o teste e poderão continuar gerando consumo."
      ;;
    *) fail "Resposta inválida para remoção automática. Use S ou N." ;;
  esac
}

resolve_general_inputs() {
  local interact=false default_regions default_azs
  should_interact && interact=true

  if [[ -z "$PRODUCT" ]]; then
    if is_true "$interact"; then prompt_product; else PRODUCT=vm; fi
  fi
  PRODUCT="$(normalize_product "$PRODUCT")" || fail "Produto inválido. Use vm, volume, object-storage, k8s ou dbaas."

  default_regions="$(available_regions_text)"
  default_azs="$(available_azs_text)"

  if [[ -z "$TARGET_ZONES" && -z "$TARGET_REGIONS" ]]; then
    if is_true "$interact"; then
      printf '\nRegiões disponíveis: %s\n' "$default_regions"
      read -r -p "Regiões separadas por vírgula [$default_regions]: " TARGET_REGIONS
      TARGET_REGIONS="${TARGET_REGIONS:-$default_regions}"
    else
      TARGET_REGIONS="$default_regions"
    fi
  fi

  if ! product_is_regional && [[ -z "$TARGET_ZONES" && -z "$TARGET_AZS" ]]; then
    if is_true "$interact"; then
      printf 'AZs disponíveis: %s\n' "$default_azs"
      read -r -p "AZs separadas por vírgula [$default_azs]: " TARGET_AZS
      TARGET_AZS="${TARGET_AZS:-$default_azs}"
    else
      TARGET_AZS="$default_azs"
    fi
  fi

  if is_true "$interact" && ! is_true "$AUTO_DELETE_EXPLICIT"; then
    prompt_auto_delete
  fi
}

build_targets() {
  local raw region az zone i
  local -a requested_regions=() requested_azs=() raw_zones=()
  local -A seen_regions=() seen_zones=()

  if [[ -n "$TARGET_ZONES" ]]; then
    raw="$(list_to_words "$TARGET_ZONES")"
    read -r -a raw_zones <<< "$raw"
    for zone in "${raw_zones[@]}"; do
      zone="${zone,,}"
      [[ "$zone" =~ ^br-[a-z0-9]+-[a-z]$ ]] || fail "Zona inválida: $zone"
      array_contains "$zone" "${ALL_ZONES[@]}" || fail "A zona $zone não está disponível."
      [[ -n "${seen_zones[$zone]:-}" ]] || { seen_zones[$zone]=1; ZONES+=("$zone"); }
      region="$(region_from_zone "$zone")"
      [[ -n "${seen_regions[$region]:-}" ]] || { seen_regions[$region]=1; REGIONS+=("$region"); }
    done
  else
    raw="$(list_to_words "$TARGET_REGIONS")"; read -r -a requested_regions <<< "$raw"
    for i in "${!requested_regions[@]}"; do requested_regions[$i]="$(normalize_region "${requested_regions[$i]}")"; done

    for region in "${requested_regions[@]}"; do
      [[ "$region" =~ ^br-[a-z0-9]+$ ]] || fail "Região inválida: $region"
      [[ -n "${seen_regions[$region]:-}" ]] || { seen_regions[$region]=1; REGIONS+=("$region"); }
    done

    if ! product_is_regional; then
      raw="$(list_to_words "$TARGET_AZS")"; read -r -a requested_azs <<< "$raw"
      for i in "${!requested_azs[@]}"; do
        requested_azs[$i]="${requested_azs[$i],,}"
        [[ "${requested_azs[$i]}" =~ ^[a-z]$ ]] || fail "AZ inválida: ${requested_azs[$i]}"
      done
      for region in "${REGIONS[@]}"; do
        for az in "${requested_azs[@]}"; do
          zone="${region}-${az}"
          if array_contains "$zone" "${ALL_ZONES[@]}"; then
            [[ -n "${seen_zones[$zone]:-}" ]] || { seen_zones[$zone]=1; ZONES+=("$zone"); }
          else
            warn "$zone não está disponível e será ignorada."
          fi
        done
      done
    fi
  fi

  ((${#REGIONS[@]})) || fail "Nenhuma região válida foi selecionada."
  if product_is_regional; then
    TARGETS=("${REGIONS[@]}")
    [[ -z "$TARGET_AZS" && -z "$TARGET_ZONES" ]] || warn "AZ não se aplica a $(product_label); será criado um recurso por região."
  else
    ((${#ZONES[@]})) || fail "Nenhuma AZ válida foi selecionada."
    TARGETS=("${ZONES[@]}")
  fi
}

load_ssh_keys() {
  local response
  response="$(mgc profile ssh-keys list --output json --raw 2>"$TMP_DIR/ssh-keys.log")" || fail "Não foi possível listar as chaves SSH."
  SSH_KEYS_JSON="$(jq -c '[.. | objects | select((.name?|type)=="string") | {name:.name,id:(.id//"")}] | unique_by(.name) | sort_by(.name)' <<< "$response")"
  [[ "$(jq 'length' <<< "$SSH_KEYS_JSON")" -gt 0 ]] || fail "Nenhuma chave SSH foi encontrada."
}

prompt_ssh_key() {
  local count i name default_index=1 answer
  count="$(jq 'length' <<< "$SSH_KEYS_JSON")"
  printf '\nChaves SSH disponíveis:\n'
  for ((i=0;i<count;i++)); do
    name="$(jq -r ".[$i].name" <<< "$SSH_KEYS_JSON")"
    printf '  %d) %s\n' "$((i+1))" "$name"
  done
  read -r -p "Selecione [$default_index]: " answer
  answer="${answer:-$default_index}"
  if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer>=1 && answer<=count )); then
    SSH_KEY_NAME="$(jq -r ".[$((answer-1))].name" <<< "$SSH_KEYS_JSON")"
  else
    SSH_KEY_NAME="$answer"
  fi
}

fetch_vm_images() {
  local zone="$1" region
  region="$(region_from_zone "$zone")"
  mgc virtual-machine images list --region "$region" --availability-zone "$zone" --output json --raw
}

vm_image_candidates() {
  jq -c --arg zone "$1" '
    def num: if type=="number" then . elif type=="string" then (tonumber? // 0) else 0 end;
    def ramgb($x): if $x>=128 then ($x/1024) else $x end;
    [..|objects
      | select(.id?!=null and (.name?|type)=="string")
      | select(((.status? // "active")|tostring|ascii_downcase)=="active")
      | select((.availability_zones?==null) or ((.availability_zones|type)=="array" and (.availability_zones|index($zone))!=null))
      | ((.minimum_requirements.vcpu? // .requirements.vcpu? // 0)|num) as $vcpu
      | ((.minimum_requirements.ram? // .requirements.ram? // 0)|num) as $ram
      | ((.minimum_requirements.disk? // .requirements.disk? // 0)|num) as $disk
      | {id:.id,name:.name,version:(.version//""|tostring),platform:(.platform//""|tostring),status:(.status//""|tostring),vcpu:$vcpu,ram:ramgb($ram),disk:$disk,release:(.release_at//"")}
    ] | unique_by(.id) | sort_by(.vcpu,.ram,.disk,.name,.version)'
}

prompt_vm_image() {
  local zone response candidates count i answer name version req
  zone="${TARGETS[0]}"
  response="$(fetch_vm_images "$zone" 2>"$TMP_DIR/prompt-images.log")" || fail "Não foi possível listar imagens em $zone."
  candidates="$(vm_image_candidates "$zone" <<< "$response")"
  count="$(jq 'length' <<< "$candidates")"
  ((count>0)) || fail "Nenhuma imagem ativa foi encontrada em $zone."
  printf '\nImagens ativas em %s (0 = seleção automática de Ubuntu):\n' "$zone"
  for ((i=0;i<count && i<40;i++)); do
    name="$(jq -r ".[$i].name" <<< "$candidates")"; version="$(jq -r ".[$i].version" <<< "$candidates")"
    req="$(jq -r ".[$i] | \"\(.vcpu)vCPU/\(.ram)GB/\(.disk)GB\"" <<< "$candidates")"
    printf '  %d) %s %s [%s]\n' "$((i+1))" "$name" "$version" "$req"
  done
  read -r -p 'Selecione [0]: ' answer
  answer="${answer:-0}"
  if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer==0)); then VM_IMAGE="";
  elif [[ "$answer" =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=count)); then VM_IMAGE="$(jq -r ".[$((answer-1))].name" <<< "$candidates")";
  else VM_IMAGE="$answer"; fi
}

resolve_vm_image() {
  local target="$1" response candidates selected
  response="$(fetch_vm_images "$target" 2>"$TMP_DIR/${target}-images.log")" || fail "Não foi possível consultar imagens em $target."
  candidates="$(vm_image_candidates "$target" <<< "$response")"
  if [[ -n "$VM_IMAGE" ]]; then
    selected="$(jq -c --arg q "$VM_IMAGE" '[.[]|select(.name==$q or .id==$q)]|first//empty' <<< "$candidates")"
    [[ -n "$selected" ]] || fail "A imagem '$VM_IMAGE' não está ativa/disponível em $target."
  else
    selected="$(jq -c '[.[]|select((.name|ascii_downcase|contains("ubuntu")))] | sort_by(.vcpu,.ram,.disk,.name,.version) | first//empty' <<< "$candidates")"
    [[ -n "$selected" ]] || fail "Nenhuma imagem Ubuntu ativa foi encontrada em $target."
  fi
  VM_IMAGE_ID_BY_TARGET[$target]="$(jq -r '.id' <<< "$selected")"
  VM_IMAGE_NAME_BY_TARGET[$target]="$(jq -r '.name' <<< "$selected")"
  VM_IMAGE_VERSION_BY_TARGET[$target]="$(jq -r '.version' <<< "$selected")"
  VM_IMAGE_VCPU_BY_TARGET[$target]="$(jq -r '.vcpu' <<< "$selected")"
  VM_IMAGE_RAM_BY_TARGET[$target]="$(jq -r '.ram' <<< "$selected")"
  VM_IMAGE_DISK_BY_TARGET[$target]="$(jq -r '.disk' <<< "$selected")"
  log "$target: imagem ${VM_IMAGE_NAME_BY_TARGET[$target]} ${VM_IMAGE_VERSION_BY_TARGET[$target]} (${VM_IMAGE_VCPU_BY_TARGET[$target]} vCPU, ${VM_IMAGE_RAM_BY_TARGET[$target]} GB, ${VM_IMAGE_DISK_BY_TARGET[$target]} GB)."
}

fetch_vm_types() {
  local zone="$1" region
  region="$(region_from_zone "$zone")"
  mgc virtual-machine machine-types list --region "$region" --availability-zone "$zone" --control.limit 1000 --output json --raw
}

vm_type_candidates() {
  jq -c --arg zone "$1" '
    def num: if type=="number" then . elif type=="string" then (tonumber? // 0) else 0 end;
    def ramgb($o):
      if $o.memory_mb? != null then (($o.memory_mb|num)/1024)
      elif $o.memory_gb? != null then ($o.memory_gb|num)
      elif $o.ram? != null then ($o.ram|num)
      elif $o.memory? != null then (($o.memory|num) as $m | if $m>=1024 then $m/1024 else $m end)
      else 0 end;
    [..|objects
      | select(.id?!=null and (.name?|type)=="string")
      | select(((.status? // "active")|tostring|ascii_downcase)=="active")
      | select((.availability_zones?==null) or ((.availability_zones|type)=="array" and (.availability_zones|index($zone))!=null))
      | ((.vcpus? // .vcpu? // .cpu? // 0)|num) as $vcpu
      | (ramgb(.)) as $ram
      | ((.disk? // .disk_size? // .root_disk? // 0)|num) as $disk
      | ((.gpu? // .gpus? // 0)|num) as $gpu
      | {id:.id,name:.name,vcpu:$vcpu,ram:$ram,disk:$disk,gpu:$gpu}
    ] | unique_by(.id) | sort_by(.vcpu,.ram,.disk,.name)'
}

prompt_vm_machine_type() {
  local target response candidates compatible count i answer
  target="${TARGETS[0]}"
  response="$(fetch_vm_types "$target" 2>"$TMP_DIR/prompt-machine-types.log")" || fail "Não foi possível listar tipos em $target."
  candidates="$(vm_type_candidates "$target" <<< "$response")"
  compatible="$(jq -c --argjson v "${VM_IMAGE_VCPU_BY_TARGET[$target]}" --argjson r "${VM_IMAGE_RAM_BY_TARGET[$target]}" --argjson d "${VM_IMAGE_DISK_BY_TARGET[$target]}" '[.[]|select(.vcpu>=$v and .ram>=$r and .disk>=$d)]' <<< "$candidates")"
  count="$(jq 'length' <<< "$compatible")"
  ((count>0)) || fail "Nenhum tipo compatível foi encontrado em $target."
  printf '\nTipos compatíveis em %s (0 = menor compatível):\n' "$target"
  for ((i=0;i<count && i<50;i++)); do
    printf '  %d) %s [%s vCPU / %s GB RAM / %s GB disco]\n' "$((i+1))" \
      "$(jq -r ".[$i].name" <<< "$compatible")" "$(jq -r ".[$i].vcpu" <<< "$compatible")" \
      "$(jq -r ".[$i].ram" <<< "$compatible")" "$(jq -r ".[$i].disk" <<< "$compatible")"
  done
  read -r -p 'Selecione [0]: ' answer
  answer="${answer:-0}"
  if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer==0)); then VM_MACHINE_TYPE="";
  elif [[ "$answer" =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=count)); then VM_MACHINE_TYPE="$(jq -r ".[$((answer-1))].name" <<< "$compatible")";
  else VM_MACHINE_TYPE="$answer"; fi
}

resolve_vm_type() {
  local target="$1" response candidates selected
  response="$(fetch_vm_types "$target" 2>"$TMP_DIR/${target}-machine-types.log")" || fail "Não foi possível consultar tipos em $target."
  candidates="$(vm_type_candidates "$target" <<< "$response")"
  selected="$(jq -c --arg q "$VM_MACHINE_TYPE" --argjson v "${VM_IMAGE_VCPU_BY_TARGET[$target]}" --argjson r "${VM_IMAGE_RAM_BY_TARGET[$target]}" --argjson d "${VM_IMAGE_DISK_BY_TARGET[$target]}" '
    [.[]|select(.vcpu>=$v and .ram>=$r and .disk>=$d)|select($q=="" or .name==$q or .id==$q)] | sort_by(.vcpu,.ram,.disk,.name) | first//empty' <<< "$candidates")"
  [[ -n "$selected" ]] || fail "O tipo '${VM_MACHINE_TYPE:-automático}' não está disponível ou não atende à imagem em $target."
  VM_TYPE_ID_BY_TARGET[$target]="$(jq -r '.id' <<< "$selected")"
  VM_TYPE_NAME_BY_TARGET[$target]="$(jq -r '.name' <<< "$selected")"
  VM_TYPE_VCPU_BY_TARGET[$target]="$(jq -r '.vcpu' <<< "$selected")"
  VM_TYPE_RAM_BY_TARGET[$target]="$(jq -r '.ram' <<< "$selected")"
  VM_TYPE_DISK_BY_TARGET[$target]="$(jq -r '.disk' <<< "$selected")"
  log "$target: tipo ${VM_TYPE_NAME_BY_TARGET[$target]} (${VM_TYPE_VCPU_BY_TARGET[$target]} vCPU, ${VM_TYPE_RAM_BY_TARGET[$target]} GB, ${VM_TYPE_DISK_BY_TARGET[$target]} GB)."
}

prepare_vm() {
  local target interact=false
  should_interact && interact=true
  load_ssh_keys
  if [[ -z "$SSH_KEY_NAME" ]]; then
    if is_true "$interact"; then
      prompt_ssh_key
    else
      SSH_KEY_NAME="$(jq -r '.[0].name' <<< "$SSH_KEYS_JSON")"
      warn "Nenhuma chave foi informada; usando a primeira disponível: $SSH_KEY_NAME. Para escolher explicitamente, use --ssh-key."
    fi
  fi
  jq -e --arg n "$SSH_KEY_NAME" 'any(.[];.name==$n)' >/dev/null <<< "$SSH_KEYS_JSON" || fail "Chave SSH '$SSH_KEY_NAME' não encontrada."
  log "Chave SSH selecionada: $SSH_KEY_NAME"

  [[ -n "$VM_IMAGE" ]] || { is_true "$interact" && prompt_vm_image; }
  for target in "${TARGETS[@]}"; do resolve_vm_image "$target"; done
  [[ -n "$VM_MACHINE_TYPE" ]] || { is_true "$interact" && prompt_vm_machine_type; }
  for target in "${TARGETS[@]}"; do resolve_vm_type "$target"; done

  if ! is_true "$ASSOCIATE_PUBLIC_IP" && [[ "$READINESS_CHECK" == "tcp22" ]]; then
    warn "IPv4 público está desativado; TCP/22 será desativado."
    READINESS_CHECK=none
  fi
}

resolve_volume_type() {
  local target="$1" region response selected
  region="$(region_from_zone "$target")"
  response="$(mgc block-storage volume-types list --region "$region" --availability-zone "$target" --output json --raw 2>"$TMP_DIR/${target}-volume-types.log")" || fail "Não foi possível consultar tipos de volume em $target."
  selected="$(jq -c --arg zone "$target" --arg letter "$(az_from_zone "$target")" --arg q "$VOLUME_TYPE_NAME" '
    [..|objects|select(.id?!=null and (.name?|type)=="string")
      | select(((.status? // "active")|tostring|ascii_downcase)=="active")
      | select((.availability_zones?==null) or ((.availability_zones|type)=="array" and ((.availability_zones|index($zone))!=null or (.availability_zones|index($letter))!=null)))
      | {id:.id,name:.name,disk:(.disk_type//""|tostring),iops:((.iops.total? // .iops.read? // 0)|tonumber? // 0)}
      | select($q=="" or .name==$q or .id==$q)] | sort_by(.iops,.name) | first//empty' <<< "$response")"
  [[ -n "$selected" ]] || fail "Tipo de volume '${VOLUME_TYPE_NAME:-automático}' indisponível em $target."
  VOL_TYPE_ID_BY_TARGET[$target]="$(jq -r '.id' <<< "$selected")"
  VOL_TYPE_NAME_BY_TARGET[$target]="$(jq -r '.name' <<< "$selected")"
  VOL_TYPE_DISK_BY_TARGET[$target]="$(jq -r '.disk' <<< "$selected")"
  VOL_TYPE_IOPS_BY_TARGET[$target]="$(jq -r '.iops' <<< "$selected")"
  log "$target: tipo de volume ${VOL_TYPE_NAME_BY_TARGET[$target]}."
}

prepare_volume() { local target; for target in "${TARGETS[@]}"; do resolve_volume_type "$target"; done; }

object_bucket_names_from_list() {
  jq -r '
    [
      (.. | objects | (.name? // .bucket? // .bucket_name? // empty)),
      (.. | strings | select(test("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")))
    ] | .[]?
  ' 2>/dev/null | sort -u
}

prepare_object_storage() {
  local region
  for region in "${REGIONS[@]}"; do
    if ! mgc object-storage buckets list --region "$region" --output json --raw >/dev/null 2>"$TMP_DIR/${region}-object-auth.log"; then
      fail "Não foi possível acessar Object Storage em $region. Além do login da CLI, confirme as credenciais/API key de Object Storage. Detalhes: $(tr '\n' ' ' < "$TMP_DIR/${region}-object-auth.log")"
    fi
    log "$region: acesso ao Object Storage validado."
  done
}

fetch_k8s_versions() { mgc kubernetes version list --region "$1" --output json --raw; }

k8s_version_candidates() {
  jq -c '
    def num: if type=="number" then . elif type=="string" then (tonumber? // 0) else 0 end;
    def ramgb($o):
      if $o.minimumRequirements.ram? != null then ($o.minimumRequirements.ram|num)
      elif $o.minimum_requirements.ram? != null then ($o.minimum_requirements.ram|num)
      else 0 end;
    [.. | objects
      | select((.version?|type)=="string" and (.version|test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$")))
      | {
          version:.version,
          deprecated:(.deprecated // false),
          vcpu:((.minimumRequirements.vcpu? // .minimum_requirements.vcpu? // 0)|num),
          ram:ramgb(.),
          disk:((.minimumRequirements.disk? // .minimum_requirements.disk? // 0)|num)
        }
    ] | unique_by(.version)' 2>/dev/null
}

prompt_k8s_version() {
  local region response candidates count i answer deprecated req
  local -a versions=()
  region="${REGIONS[0]}"
  response="$(fetch_k8s_versions "$region" 2>"$TMP_DIR/prompt-k8s-versions.log")" || fail "Não foi possível listar versões K8s em $region."
  candidates="$(k8s_version_candidates <<< "$response")"
  mapfile -t versions < <(jq -r '.[].version' <<< "$candidates" | sort -V -r)
  count="${#versions[@]}"; ((count>0)) || fail "Nenhuma versão K8s encontrada."
  printf '\nVersões Kubernetes em %s (0 = mais recente):\n' "$region"
  for ((i=0;i<count;i++)); do
    deprecated="$(jq -r --arg v "${versions[$i]}" '.[]|select(.version==$v)|.deprecated' <<< "$candidates")"
    req="$(jq -r --arg v "${versions[$i]}" '.[]|select(.version==$v)|"mínimos: \(.vcpu)vCPU/\(.ram)GB/\(.disk)GB"' <<< "$candidates")"
    [[ "$deprecated" == true ]] && req="$req; obsoleta"
    printf '  %d) %s [%s]\n' "$((i+1))" "${versions[$i]}" "$req"
  done
  read -r -p 'Selecione [0]: ' answer; answer="${answer:-0}"
  if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer==0)); then K8S_VERSION=""
  elif [[ "$answer" =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=count)); then K8S_VERSION="${versions[$((answer-1))]}"
  else K8S_VERSION="$answer"; fi
}

resolve_k8s_version() {
  local region="$1" response candidates selected version req_v req_r req_d
  response="$(fetch_k8s_versions "$region" 2>"$TMP_DIR/${region}-k8s-versions.log")" || fail "Não foi possível listar versões K8s em $region."
  candidates="$(k8s_version_candidates <<< "$response")"
  if [[ -n "$K8S_VERSION" ]]; then
    selected="$(jq -c --arg q "$K8S_VERSION" '[.[]|select(.version==$q)]|first//empty' <<< "$candidates")"
    [[ -n "$selected" ]] || fail "Versão K8s '$K8S_VERSION' indisponível em $region."
  else
    version="$(jq -r '.[].version' <<< "$candidates" | sort -V | tail -n1)"
    [[ -n "$version" ]] || fail "Nenhuma versão K8s encontrada em $region."
    selected="$(jq -c --arg q "$version" '[.[]|select(.version==$q)]|first//empty' <<< "$candidates")"
  fi
  version="$(jq -r '.version' <<< "$selected")"
  req_v="$(jq -r '.vcpu' <<< "$selected")"; req_r="$(jq -r '.ram' <<< "$selected")"; req_d="$(jq -r '.disk' <<< "$selected")"
  # A API v3 usa tipos de VM e documenta BV2-4-40 como o menor tipo suportado.
  (( $(printf '%.0f' "$req_v") < 2 )) && req_v=2
  awk -v x="$req_r" 'BEGIN{exit !(x<4)}' && req_r=4 || true
  awk -v x="$req_d" 'BEGIN{exit !(x<40)}' && req_d=40 || true
  K8S_VERSION_BY_REGION[$region]="$version"
  K8S_MIN_VCPU_BY_REGION[$region]="$req_v"
  K8S_MIN_RAM_BY_REGION[$region]="$req_r"
  K8S_MIN_DISK_BY_REGION[$region]="$req_d"
}

k8s_machine_type_candidates() {
  local target="$1" region candidates
  region="$(region_from_zone "$target")"
  candidates="$(vm_type_candidates "$target")"
  jq -c --argjson v "${K8S_MIN_VCPU_BY_REGION[$region]}" --argjson r "${K8S_MIN_RAM_BY_REGION[$region]}" --argjson d "${K8S_MIN_DISK_BY_REGION[$region]}"     '[.[]|select(.gpu==0 and .vcpu>=$v and .ram>=$r and .disk>=$d)] | sort_by(.vcpu,.ram,.disk,.name)' <<< "$candidates"
}

prompt_k8s_machine_type() {
  local target response candidates compatible count i answer
  target="${TARGETS[0]}"
  response="$(fetch_vm_types "$target" 2>"$TMP_DIR/prompt-k8s-machine-types.log")" || fail "Não foi possível listar tipos de máquina em $target."
  candidates="$(vm_type_candidates "$target" <<< "$response")"
  compatible="$(k8s_machine_type_candidates "$target" <<< "$candidates")"
  count="$(jq 'length' <<< "$compatible")"; ((count>0)) || fail "Nenhum tipo de máquina compatível com Kubernetes foi encontrado em $target."
  printf '\nTipos de máquina para o Node Pool em %s (0 = menor compatível):\n' "$target"
  for ((i=0;i<count && i<50;i++)); do
    printf '  %d) %s [%s vCPU / %s GB RAM / %s GB disco]\n' "$((i+1))"       "$(jq -r ".[$i].name" <<< "$compatible")" "$(jq -r ".[$i].vcpu" <<< "$compatible")"       "$(jq -r ".[$i].ram" <<< "$compatible")" "$(jq -r ".[$i].disk" <<< "$compatible")"
  done
  read -r -p 'Selecione [0]: ' answer; answer="${answer:-0}"
  if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer==0)); then K8S_MACHINE_TYPE=""
  elif [[ "$answer" =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=count)); then K8S_MACHINE_TYPE="$(jq -r ".[$((answer-1))].name" <<< "$compatible")"
  else K8S_MACHINE_TYPE="$answer"; fi
}

resolve_k8s_machine_type() {
  local target="$1" region response candidates selected
  region="$(region_from_zone "$target")"
  response="$(fetch_vm_types "$target" 2>"$TMP_DIR/${target}-k8s-machine-types.log")" || fail "Não foi possível listar tipos de máquina em $target."
  candidates="$(vm_type_candidates "$target" <<< "$response")"
  selected="$(jq -c --arg q "$K8S_MACHINE_TYPE" --argjson v "${K8S_MIN_VCPU_BY_REGION[$region]}" --argjson r "${K8S_MIN_RAM_BY_REGION[$region]}" --argjson d "${K8S_MIN_DISK_BY_REGION[$region]}"     '[.[]|select(.gpu==0 and .vcpu>=$v and .ram>=$r and .disk>=$d)|select($q=="" or .name==$q or .id==$q)] | sort_by(.vcpu,.ram,.disk,.name) | first//empty' <<< "$candidates")"
  [[ -n "$selected" ]] || fail "O tipo Kubernetes '${K8S_MACHINE_TYPE:-automático}' não está disponível em $target ou não atende aos mínimos ${K8S_MIN_VCPU_BY_REGION[$region]} vCPU/${K8S_MIN_RAM_BY_REGION[$region]} GB/${K8S_MIN_DISK_BY_REGION[$region]} GB."
  K8S_TYPE_ID_BY_TARGET[$target]="$(jq -r '.id' <<< "$selected")"
  K8S_TYPE_NAME_BY_TARGET[$target]="$(jq -r '.name' <<< "$selected")"
  K8S_TYPE_VCPU_BY_TARGET[$target]="$(jq -r '.vcpu' <<< "$selected")"
  K8S_TYPE_RAM_BY_TARGET[$target]="$(jq -r '.ram' <<< "$selected")"
  K8S_TYPE_DISK_BY_TARGET[$target]="$(jq -r '.disk' <<< "$selected")"
}

prepare_k8s() {
  local region target interact=false
  should_interact && interact=true
  [[ -n "$K8S_VERSION" ]] || { is_true "$interact" && prompt_k8s_version; }
  for region in "${REGIONS[@]}"; do
    resolve_k8s_version "$region"
    log "$region: Kubernetes ${K8S_VERSION_BY_REGION[$region]} exige no mínimo ${K8S_MIN_VCPU_BY_REGION[$region]} vCPU, ${K8S_MIN_RAM_BY_REGION[$region]} GB RAM e ${K8S_MIN_DISK_BY_REGION[$region]} GB disco."
  done
  [[ -n "$K8S_MACHINE_TYPE" ]] || { is_true "$interact" && prompt_k8s_machine_type; }
  for target in "${TARGETS[@]}"; do
    resolve_k8s_machine_type "$target"
    log "$target: tipo do node pool ${K8S_TYPE_NAME_BY_TARGET[$target]} (${K8S_TYPE_VCPU_BY_TARGET[$target]} vCPU, ${K8S_TYPE_RAM_BY_TARGET[$target]} GB, ${K8S_TYPE_DISK_BY_TARGET[$target]} GB)."
  done
}

fetch_db_engines() { mgc dbaas engines list --region "$1" --status ACTIVE --control.limit 50 --output json --raw; }

db_engine_candidates() {
  jq -c '[..|objects|select(.id?!=null and (.name?|type)=="string")|select(((.status? // "ACTIVE")|tostring|ascii_upcase)=="ACTIVE")|{id:.id,name:.name,version:(.version//.engine_version//""|tostring)}] | unique_by(.id) | sort_by(.name,.version)'
}

prompt_db_engine() {
  local region response candidates count i answer
  region="${REGIONS[0]}"; response="$(fetch_db_engines "$region" 2>"$TMP_DIR/prompt-db-engines.log")" || fail "Não foi possível listar engines DBaaS em $region."
  candidates="$(db_engine_candidates <<< "$response")"; count="$(jq 'length' <<< "$candidates")"; ((count>0)) || fail "Nenhuma engine DBaaS ativa foi encontrada."
  printf '\nEngines DBaaS em %s:\n' "$region"
  for ((i=0;i<count;i++)); do printf '  %d) %s %s\n' "$((i+1))" "$(jq -r ".[$i].name" <<< "$candidates")" "$(jq -r ".[$i].version" <<< "$candidates")"; done
  read -r -p 'Selecione [1]: ' answer; answer="${answer:-1}"
  if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=count)); then
    DBAAS_ENGINE="$(jq -r ".[$((answer-1))] | .name + (if .version==\"\" then \"\" else \"@\"+.version end)" <<< "$candidates")"
  else DBAAS_ENGINE="$answer"; fi
}

resolve_db_engine() {
  local region="$1" response candidates selected q_name q_version
  response="$(fetch_db_engines "$region" 2>"$TMP_DIR/${region}-db-engines.log")" || fail "Não foi possível listar engines DBaaS em $region."
  candidates="$(db_engine_candidates <<< "$response")"
  if [[ -n "$DBAAS_ENGINE" ]]; then
    q_name="${DBAAS_ENGINE%@*}"; q_version=""; [[ "$DBAAS_ENGINE" == *@* ]] && q_version="${DBAAS_ENGINE#*@}"
    selected="$(jq -c --arg q "$DBAAS_ENGINE" --arg n "$q_name" --arg v "$q_version" '[.[]|select(.id==$q or ((.name|ascii_downcase)==($n|ascii_downcase) and ($v=="" or .version==$v)))]|first//empty' <<< "$candidates")"
    [[ -n "$selected" ]] || fail "Engine DBaaS '$DBAAS_ENGINE' indisponível em $region."
  else
    selected="$(jq -c '. as $all | ([ $all[] | select(.name|ascii_downcase|contains("postgres")) ] | last) // $all[0] // empty' <<< "$candidates")"
    [[ -n "$selected" ]] || fail "Nenhuma engine DBaaS ativa em $region."
  fi
  DB_ENGINE_ID_BY_REGION[$region]="$(jq -r '.id' <<< "$selected")"
  DB_ENGINE_NAME_BY_REGION[$region]="$(jq -r '.name' <<< "$selected")"
  DB_ENGINE_VERSION_BY_REGION[$region]="$(jq -r '.version' <<< "$selected")"
}

fetch_db_types() {
  mgc dbaas instance-types list --region "$1" --engine-id "$2" --compatible-product SINGLE_INSTANCE --status ACTIVE --control.limit 200 --output json --raw
}

db_type_candidates() {
  jq -c '
    def num: if type=="number" then . elif type=="string" then (tonumber? // 0) else 0 end;
    [..|objects|select(.id?!=null and (.name?|type)=="string")
      | select(((.status? // "ACTIVE")|tostring|ascii_upcase)=="ACTIVE")
      | ((.vcpus? // .vcpu? // .cpu? // 0)|num) as $v
      | ((.ram? // .memory? // .memory_mb? // 0)|num) as $r
      | {id:.id,name:.name,vcpu:$v,ram:(if $r>=128 then $r/1024 else $r end)}]
    | unique_by(.id) | sort_by(.vcpu,.ram,.name)'
}

prompt_db_type() {
  local region response candidates count i answer
  region="${REGIONS[0]}"; response="$(fetch_db_types "$region" "${DB_ENGINE_ID_BY_REGION[$region]}" 2>"$TMP_DIR/prompt-db-types.log")" || fail "Não foi possível listar tipos DBaaS em $region."
  candidates="$(db_type_candidates <<< "$response")"; count="$(jq 'length' <<< "$candidates")"; ((count>0)) || fail "Nenhum tipo DBaaS compatível foi encontrado."
  printf '\nTipos DBaaS em %s (0 = menor):\n' "$region"
  for ((i=0;i<count;i++)); do printf '  %d) %s [%s vCPU / %s GB]\n' "$((i+1))" "$(jq -r ".[$i].name" <<< "$candidates")" "$(jq -r ".[$i].vcpu" <<< "$candidates")" "$(jq -r ".[$i].ram" <<< "$candidates")"; done
  read -r -p 'Selecione [0]: ' answer; answer="${answer:-0}"
  if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer==0)); then DBAAS_INSTANCE_TYPE="";
  elif [[ "$answer" =~ ^[0-9]+$ ]] && ((answer>=1 && answer<=count)); then DBAAS_INSTANCE_TYPE="$(jq -r ".[$((answer-1))].name" <<< "$candidates")";
  else DBAAS_INSTANCE_TYPE="$answer"; fi
}

resolve_db_type() {
  local region="$1" response candidates selected
  response="$(fetch_db_types "$region" "${DB_ENGINE_ID_BY_REGION[$region]}" 2>"$TMP_DIR/${region}-db-types.log")" || fail "Não foi possível listar tipos DBaaS em $region."
  candidates="$(db_type_candidates <<< "$response")"
  selected="$(jq -c --arg q "$DBAAS_INSTANCE_TYPE" '[.[]|select($q=="" or .name==$q or .id==$q)]|sort_by(.vcpu,.ram,.name)|first//empty' <<< "$candidates")"
  [[ -n "$selected" ]] || fail "Tipo DBaaS '${DBAAS_INSTANCE_TYPE:-automático}' indisponível em $region."
  DB_TYPE_ID_BY_REGION[$region]="$(jq -r '.id' <<< "$selected")"
  DB_TYPE_NAME_BY_REGION[$region]="$(jq -r '.name' <<< "$selected")"
  DB_TYPE_VCPU_BY_REGION[$region]="$(jq -r '.vcpu' <<< "$selected")"
  DB_TYPE_RAM_BY_REGION[$region]="$(jq -r '.ram' <<< "$selected")"
}

prepare_dbaas() {
  local region interact=false
  should_interact && interact=true
  [[ -n "$DBAAS_ENGINE" ]] || { is_true "$interact" && prompt_db_engine; }
  for region in "${REGIONS[@]}"; do resolve_db_engine "$region"; done
  [[ -n "$DBAAS_INSTANCE_TYPE" ]] || { is_true "$interact" && prompt_db_type; }
  for region in "${REGIONS[@]}"; do
    resolve_db_type "$region"
    log "$region: DBaaS ${DB_ENGINE_NAME_BY_REGION[$region]} ${DB_ENGINE_VERSION_BY_REGION[$region]}, tipo ${DB_TYPE_NAME_BY_REGION[$region]}."
  done
  if [[ -z "$DBAAS_PASSWORD" ]]; then
    command -v openssl >/dev/null 2>&1 || fail "openssl é necessário para gerar a senha temporária do DBaaS. Informe DBAAS_PASSWORD para dispensá-lo."
    DBAAS_PASSWORD="$(openssl rand -hex 20)"
    log "Senha temporária de DBaaS gerada em memória; ela não será gravada nos relatórios."
  fi
  ((${#DBAAS_PASSWORD} <= 50)) || fail "A senha DBaaS deve ter no máximo 50 caracteres."
}

prepare_product() {
  case "$PRODUCT" in
    vm) prepare_vm ;;
    volume) prepare_volume ;;
    object-storage) prepare_object_storage ;;
    k8s) prepare_k8s ;;
    dbaas) prepare_dbaas ;;
  esac
}

json_number_or_null() { [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$1" || printf 'null'; }

configuration_json() {
  local target="$1" region az
  region="$(target_region "$target")"; az="$(target_az "$target")"
  case "$PRODUCT" in
    vm)
      jq -n --arg image "${VM_IMAGE_NAME_BY_TARGET[$target]}" --arg version "${VM_IMAGE_VERSION_BY_TARGET[$target]}" --arg image_id "${VM_IMAGE_ID_BY_TARGET[$target]}" --arg type "${VM_TYPE_NAME_BY_TARGET[$target]}" --arg type_id "${VM_TYPE_ID_BY_TARGET[$target]}" --arg ssh "$SSH_KEY_NAME" --argjson vcpu "$(json_number_or_null "${VM_TYPE_VCPU_BY_TARGET[$target]}")" --argjson ram "$(json_number_or_null "${VM_TYPE_RAM_BY_TARGET[$target]}")" --argjson disk "$(json_number_or_null "${VM_TYPE_DISK_BY_TARGET[$target]}")" '{image:{name:$image,version:$version,id:$image_id},machine_type:{name:$type,id:$type_id,vcpu:$vcpu,ram_gb:$ram,disk_gb:$disk},ssh_key:$ssh}' ;;
    volume)
      jq -n --arg type "${VOL_TYPE_NAME_BY_TARGET[$target]}" --arg type_id "${VOL_TYPE_ID_BY_TARGET[$target]}" --arg disk "${VOL_TYPE_DISK_BY_TARGET[$target]}" --argjson size "$VOLUME_SIZE" '{volume_type:{name:$type,id:$type_id,disk_type:$disk},size_gib:$size}' ;;
    object-storage)
      jq -n '{access:"private",scope:"regional"}' ;;
    k8s)
      jq -n --arg version "${K8S_VERSION_BY_REGION[$region]}" --arg type "${K8S_TYPE_NAME_BY_TARGET[$target]}" --arg type_id "${K8S_TYPE_ID_BY_TARGET[$target]}" --arg az "$az" --argjson vcpu "$(json_number_or_null "${K8S_TYPE_VCPU_BY_TARGET[$target]}")" --argjson ram "$(json_number_or_null "${K8S_TYPE_RAM_BY_TARGET[$target]}")" --argjson disk "$(json_number_or_null "${K8S_TYPE_DISK_BY_TARGET[$target]}")" --argjson replicas "$K8S_REPLICAS" --argjson max_pods "$K8S_MAX_PODS" '{version:$version,node_pool:{machine_type:{name:$type,id:$type_id,vcpu:$vcpu,ram_gb:$ram,disk_gb:$disk},availability_zone:$az,replicas:$replicas,max_pods_per_node:$max_pods}}' ;;
    dbaas)
      jq -n --arg engine "${DB_ENGINE_NAME_BY_REGION[$region]}" --arg version "${DB_ENGINE_VERSION_BY_REGION[$region]}" --arg engine_id "${DB_ENGINE_ID_BY_REGION[$region]}" --arg type "${DB_TYPE_NAME_BY_REGION[$region]}" --arg type_id "${DB_TYPE_ID_BY_REGION[$region]}" --arg user "$DBAAS_USER" --arg volume_type "$DBAAS_VOLUME_TYPE" --argjson volume_size "$DBAAS_VOLUME_SIZE" '{engine:{name:$engine,version:$version,id:$engine_id},instance_type:{name:$type,id:$type_id},user:$user,volume:{type:$volume_type,size_gib:$volume_size}}' ;;
  esac
}

configuration_summary() {
  local target="$1" region
  region="$(target_region "$target")"
  case "$PRODUCT" in
    vm) printf 'imagem=%s %s; tipo=%s; %svCPU/%sGB/%sGB; ssh=%s' "${VM_IMAGE_NAME_BY_TARGET[$target]}" "${VM_IMAGE_VERSION_BY_TARGET[$target]}" "${VM_TYPE_NAME_BY_TARGET[$target]}" "${VM_TYPE_VCPU_BY_TARGET[$target]}" "${VM_TYPE_RAM_BY_TARGET[$target]}" "${VM_TYPE_DISK_BY_TARGET[$target]}" "$SSH_KEY_NAME" ;;
    volume) printf 'tipo=%s; tamanho=%sGiB' "${VOL_TYPE_NAME_BY_TARGET[$target]}" "$VOLUME_SIZE" ;;
    object-storage) printf 'bucket privado; escopo regional' ;;
    k8s) printf 'versão=%s; tipo=%s; réplicas=%s; AZ=%s' "${K8S_VERSION_BY_REGION[$region]}" "${K8S_TYPE_NAME_BY_TARGET[$target]}" "$K8S_REPLICAS" "$(target_az "$target")" ;;
    dbaas) printf 'engine=%s %s; tipo=%s; volume=%s/%sGiB; AZ=%s' "${DB_ENGINE_NAME_BY_REGION[$region]}" "${DB_ENGINE_VERSION_BY_REGION[$region]}" "${DB_TYPE_NAME_BY_REGION[$region]}" "$DBAAS_VOLUME_TYPE" "$DBAAS_VOLUME_SIZE" "$(target_az "$target")" ;;
  esac
}

write_result() {
  local file="$1" target="$2" name="$3" id="$4" result="$5" state="$6" status="$7" api_ms="$8" ready_ms="$9" total_ms="${10}" public_ip="${11}" readiness="${12}" started_at="${13}" ready_at="${14}" error="${15}"
  local region az config summary
  region="$(target_region "$target")"; az="$(target_az "$target")"; config="$(configuration_json "$target")"; summary="$(configuration_summary "$target")"
  jq -n --arg product "$PRODUCT" --arg product_label "$(product_label)" --arg target "$target" --arg region "$region" --arg az "$az" --arg name "$name" --arg id "$id" --arg result "$result" --arg state "$state" --arg status "$status" --arg public_ip "$public_ip" --arg readiness "$readiness" --arg started_at "$started_at" --arg ready_at "$ready_at" --arg error "$error" --arg summary "$summary" --argjson config "$config" --argjson api_ms "$(json_number_or_null "$api_ms")" --argjson ready_ms "$(json_number_or_null "$ready_ms")" --argjson total_ms "$(json_number_or_null "$total_ms")" '{product:$product,product_label:$product_label,target:$target,region:$region,availability_zone:$az,name:$name,id:$id,configuration:$config,configuration_summary:$summary,result:$result,state:$state,status:$status,public_ip:$public_ip,readiness_result:$readiness,timings_ms:{create_api:$api_ms,ready:$ready_ms,total_test:$total_ms},timestamps:{started_at:$started_at,ready_at:$ready_at},error_message:$error}' > "$file"
}

format_cli_error() {
  local stderr_file="$1" stdout_text="$2" rc="$3" stderr_text combined
  stderr_text="$(tr '\n' ' ' < "$stderr_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  stdout_text="$(printf '%s' "$stdout_text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  combined="$stderr_text"; [[ -z "$stdout_text" ]] || combined="${combined}${combined:+ | stdout: }${stdout_text}"
  [[ -n "$combined" ]] || combined="A MGC CLI retornou código $rc sem mensagem."
  printf '%s\n' "$combined"
}

log_failed_command() {
  local product="$1" target="$2" name="$3" rc="$4" error="$5"; shift 5
  local arg
  {
    printf '[%s] PRODUCT=%s TARGET=%s RESOURCE=%s RC=%s\n' "$(iso_now)" "$product" "$target" "$name" "$rc"
    printf 'Comando: mgc'
    for arg in "$@"; do
      if [[ "$arg" == "$DBAAS_PASSWORD" && -n "$DBAAS_PASSWORD" ]]; then printf ' %q' '***REDACTED***'; else printf ' %q' "$arg"; fi
    done
    printf '\nErro: %s\n\n' "$error"
  } >> "$DIAGNOSTIC_FILE"
}

extract_public_ip() {
  jq -r '[paths(scalars) as $p | ($p|map(tostring)|join(".")|ascii_downcase) as $t | select($t|test("(public|floating).*(ip|address)|(ip|address).*(public|floating)")) | getpath($p) | select(type=="string") | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))] | first//empty' 2>/dev/null
}

tcp22_reachable() { timeout "${TCP_CONNECT_TIMEOUT_SECONDS}s" bash -c 'exec 3<>/dev/tcp/"$1"/22' _ "$1" >/dev/null 2>&1; }

provision_vm() (
  set +e
  local target="$1" region name file log_file id="" response details='{}' state=unknown status=unknown result=unknown error="" public_ip="" readiness=not_requested
  local start_ms end_ms current_ms deadline ready_deadline=0 api_ms="" ready_ms="" total_ms="" started_at ready_at=""
  region="$(region_from_zone "$target")"; name="$(build_resource_name "$target")"; file="$(target_result_file "$target")"; log_file="$TMP_DIR/${target}-provision.log"
  cleanup() { [[ -n "$id" ]] && is_true "$AUTO_DELETE" && { log "$target: removendo VM $id..."; local -a a=(virtual-machine instances delete --id "$id" --region "$region" --no-confirm); is_true "$ASSOCIATE_PUBLIC_IP" && a+=(--delete-public-ip); mgc "${a[@]}" >>"$log_file" 2>&1 || true; }; }
  trap cleanup EXIT INT TERM
  start_ms="$(now_ms)"; deadline=$((start_ms+TIMEOUT_SECONDS*1000)); started_at="$(iso_now)"; log "$target: criando $name..."
  local -a args=(virtual-machine instances create --region "$region" --availability-zone "$target" --name "$name" --ssh-key-name "$SSH_KEY_NAME" --network.associate-public-ip "$ASSOCIATE_PUBLIC_IP" --output json --raw)
  if [[ "$RESOURCE_REFERENCE_MODE" == id ]]; then args+=(--image.id "${VM_IMAGE_ID_BY_TARGET[$target]}" --machine-type.id "${VM_TYPE_ID_BY_TARGET[$target]}"); else args+=(--image.name "${VM_IMAGE_NAME_BY_TARGET[$target]}" --machine-type.name "${VM_TYPE_NAME_BY_TARGET[$target]}"); fi
  [[ -z "$VPC_ID" ]] || args+=(--network.vpc.id "$VPC_ID"); [[ -z "$VPC_NAME" ]] || args+=(--network.vpc.name "$VPC_NAME")
  response="$(mgc "${args[@]}" 2>"$log_file")"; local rc=$?; end_ms="$(now_ms)"; api_ms=$((end_ms-start_ms))
  if ((rc)); then error="Falha no comando de criação: $(format_cli_error "$log_file" "$response" "$rc")"; total_ms=$(( $(now_ms)-start_ms )); log_failed_command vm "$target" "$name" "$rc" "$error" "${args[@]}"; log "$target: $error"; write_result "$file" "$target" "$name" "" create_command_error "$state" "$status" "$api_ms" "" "$total_ms" "" "$readiness" "$started_at" "" "$error"; exit 0; fi
  id="$(jq -r '.id//empty' <<< "$response")"; [[ -n "$id" ]] || { error="A CLI não retornou ID."; total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "" invalid_create_response "$state" "$status" "$api_ms" "" "$total_ms" "" "$readiness" "$started_at" "" "$error"; exit 0; }
  while true; do
    current_ms="$(now_ms)"; if [[ -z "$ready_ms" ]] && ((current_ms>=deadline)); then result=timeout; error="VM não atingiu running em ${TIMEOUT_SECONDS}s."; break; fi
    details="$(mgc virtual-machine instances get --id "$id" --region "$region" --expand network --output json --raw 2>>"$log_file")" || { sleep "$POLL_INTERVAL_SECONDS"; continue; }
    state="$(jq -r '(.state//"unknown")|tostring|ascii_downcase' <<< "$details")"; status="$(jq -r '(.status//"unknown")|tostring|ascii_downcase' <<< "$details")"; current_ms="$(now_ms)"
    [[ -n "$public_ip" ]] || public_ip="$(extract_public_ip <<< "$details" || true)"
    if [[ "$state" == running && -z "$ready_ms" ]]; then ready_ms=$((current_ms-start_ms)); ready_at="$(iso_now)"; result=success; ready_deadline=$((current_ms+READINESS_TIMEOUT_SECONDS*1000)); log "$target: running após $((ready_ms/1000))s."; fi
    if [[ "$state" == error || "$status" == *error* || "$status" == failed ]]; then result=provisioning_error; error="$(jq -r '.error.message//.error_message//"Provisionamento em erro."' <<< "$details")"; break; fi
    if [[ -n "$ready_ms" ]]; then
      if [[ "$READINESS_CHECK" == none ]]; then readiness=not_requested; break; fi
      if [[ -n "$public_ip" ]] && tcp22_reachable "$public_ip"; then readiness=tcp22_reachable; break; fi
      ((current_ms>=ready_deadline)) && { [[ -n "$public_ip" ]] && readiness=tcp22_timeout || readiness=public_ip_not_observed; break; }
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
  total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "$id" "$result" "$state" "$status" "$api_ms" "$ready_ms" "$total_ms" "$public_ip" "$readiness" "$started_at" "$ready_at" "$error"
)

provision_volume() (
  set +e
  local target="$1" region name file log_file id="" response details='{}' state=unknown status=unknown result=unknown error="" start_ms end_ms current_ms deadline api_ms="" ready_ms="" total_ms="" started_at ready_at=""
  region="$(region_from_zone "$target")"; name="$(build_resource_name "$target")"; file="$(target_result_file "$target")"; log_file="$TMP_DIR/${target}-provision.log"
  cleanup() { [[ -n "$id" ]] && is_true "$AUTO_DELETE" && { log "$target: removendo volume $id..."; mgc block-storage volumes delete --id "$id" --region "$region" --no-confirm >>"$log_file" 2>&1 || true; }; }; trap cleanup EXIT INT TERM
  start_ms="$(now_ms)"; deadline=$((start_ms+TIMEOUT_SECONDS*1000)); started_at="$(iso_now)"; log "$target: criando $name..."
  local -a args=(block-storage volumes create --region "$region" --availability-zone "$target" --name "$name" --size "$VOLUME_SIZE" --output json --raw)
  [[ "$RESOURCE_REFERENCE_MODE" == id ]] && args+=(--type.id "${VOL_TYPE_ID_BY_TARGET[$target]}") || args+=(--type.name "${VOL_TYPE_NAME_BY_TARGET[$target]}")
  response="$(mgc "${args[@]}" 2>"$log_file")"; local rc=$?; end_ms="$(now_ms)"; api_ms=$((end_ms-start_ms))
  if ((rc)); then error="Falha no comando de criação: $(format_cli_error "$log_file" "$response" "$rc")"; total_ms=$(( $(now_ms)-start_ms )); log_failed_command volume "$target" "$name" "$rc" "$error" "${args[@]}"; write_result "$file" "$target" "$name" "" create_command_error "$state" "$status" "$api_ms" "" "$total_ms" "" not_applicable "$started_at" "" "$error"; exit 0; fi
  id="$(jq -r '.id//empty' <<< "$response")"; [[ -n "$id" ]] || { error="A CLI não retornou ID."; total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "" invalid_create_response "$state" "$status" "$api_ms" "" "$total_ms" "" not_applicable "$started_at" "" "$error"; exit 0; }
  while true; do
    current_ms="$(now_ms)"; ((current_ms>=deadline)) && { result=timeout; error="Volume não ficou disponível em ${TIMEOUT_SECONDS}s."; break; }
    details="$(mgc block-storage volumes get --id "$id" --region "$region" --output json --raw 2>>"$log_file")" || { sleep "$POLL_INTERVAL_SECONDS"; continue; }
    state="$(jq -r '(.state//"unknown")|tostring|ascii_downcase' <<< "$details")"; status="$(jq -r '(.status//"unknown")|tostring|ascii_downcase' <<< "$details")"
    if [[ "$state" == available && ( "$status" == completed || "$status" == available || "$status" == unknown ) ]]; then ready_ms=$(( $(now_ms)-start_ms )); ready_at="$(iso_now)"; result=success; break; fi
    [[ "$state" == *error* || "$status" == *error* || "$status" == failed ]] && { result=provisioning_error; error="$(jq -r '.error.message//.error_message//"Provisionamento em erro."' <<< "$details")"; break; }
    sleep "$POLL_INTERVAL_SECONDS"
  done
  total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "$id" "$result" "$state" "$status" "$api_ms" "$ready_ms" "$total_ms" "" not_applicable "$started_at" "$ready_at" "$error"
)

provision_object() (
  set +e
  local target="$1" region name file log_file id="" response list_response result=unknown state=unknown status=unknown error="" start_ms end_ms current_ms deadline api_ms="" ready_ms="" total_ms="" started_at ready_at=""
  region="$target"; name="$(build_resource_name "$target")"; file="$(target_result_file "$target")"; log_file="$TMP_DIR/${target}-provision.log"
  cleanup() { [[ -n "$id" ]] && is_true "$AUTO_DELETE" && { log "$target: removendo bucket $id..."; mgc object-storage buckets delete --bucket "$id" --recursive --region "$region" --no-confirm >>"$log_file" 2>&1 || true; }; }; trap cleanup EXIT INT TERM
  start_ms="$(now_ms)"; deadline=$((start_ms+TIMEOUT_SECONDS*1000)); started_at="$(iso_now)"; log "$target: criando bucket $name..."
  local -a args=(object-storage buckets create --bucket "$name" --private --region "$region" --output json --raw)
  response="$(mgc "${args[@]}" 2>"$log_file")"; local rc=$?; end_ms="$(now_ms)"; api_ms=$((end_ms-start_ms))
  if ((rc)); then error="Falha no comando de criação: $(format_cli_error "$log_file" "$response" "$rc")"; total_ms=$(( $(now_ms)-start_ms )); log_failed_command object-storage "$target" "$name" "$rc" "$error" "${args[@]}"; write_result "$file" "$target" "$name" "" create_command_error "$state" "$status" "$api_ms" "" "$total_ms" "" not_applicable "$started_at" "" "$error"; exit 0; fi
  id="$(jq -r '.name//.bucket//.bucket_name//empty' <<< "$response" 2>/dev/null)"; [[ -n "$id" ]] || id="$name"
  while true; do
    current_ms="$(now_ms)"; ((current_ms>=deadline)) && { result=timeout; error="Bucket não apareceu na listagem em ${TIMEOUT_SECONDS}s."; break; }
    list_response="$(mgc object-storage buckets list --region "$region" --output json --raw 2>>"$log_file")" || { sleep "$POLL_INTERVAL_SECONDS"; continue; }
    if object_bucket_names_from_list <<< "$list_response" | grep -Fxq "$id"; then state=available; status=created; ready_ms=$((current_ms-start_ms)); ready_at="$(iso_now)"; result=success; break; fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
  total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "$id" "$result" "$state" "$status" "$api_ms" "$ready_ms" "$total_ms" "" list_visibility "$started_at" "$ready_at" "$error"
)

provision_k8s() (
  set +e
  local target="$1" region az name file log_file id="" response details='{}' state=unknown status=unknown result=unknown error="" start_ms end_ms current_ms deadline api_ms="" ready_ms="" total_ms="" started_at ready_at="" node_pools
  region="$(region_from_zone "$target")"; az="$(az_from_zone "$target")"; name="$(build_resource_name "$target")"; file="$(target_result_file "$target")"; log_file="$TMP_DIR/${target}-provision.log"
  cleanup() { [[ -n "$id" ]] && is_true "$AUTO_DELETE" && { log "$target: removendo cluster K8s $id..."; mgc kubernetes cluster delete --cluster-id "$id" --region "$region" --no-confirm >>"$log_file" 2>&1 || true; }; }; trap cleanup EXIT INT TERM
  node_pools="$(jq -nc --arg az "$az" --arg flavor "${K8S_TYPE_NAME_BY_TARGET[$target]}" --arg name "np-$az" --argjson replicas "$K8S_REPLICAS" --argjson maxpods "$K8S_MAX_PODS" '[{name:$name,flavor:$flavor,replicas:$replicas,max_pods_per_node:$maxpods,availability_zones:[$az]}]')"
  start_ms="$(now_ms)"; deadline=$((start_ms+TIMEOUT_SECONDS*1000)); started_at="$(iso_now)"; log "$target: criando cluster $name..."
  local -a args=(kubernetes cluster create --region "$region" --name "$name" --version "${K8S_VERSION_BY_REGION[$region]}" --node-pools "$node_pools" --output json --raw)
  response="$(mgc "${args[@]}" 2>"$log_file")"; local rc=$?; end_ms="$(now_ms)"; api_ms=$((end_ms-start_ms))
  if ((rc)); then error="Falha no comando de criação: $(format_cli_error "$log_file" "$response" "$rc")"; total_ms=$(( $(now_ms)-start_ms )); log_failed_command k8s "$target" "$name" "$rc" "$error" "${args[@]}"; write_result "$file" "$target" "$name" "" create_command_error "$state" "$status" "$api_ms" "" "$total_ms" "" kubeconfig "$started_at" "" "$error"; exit 0; fi
  id="$(jq -r '.id//empty' <<< "$response")"; [[ -n "$id" ]] || { error="A CLI não retornou ID."; total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "" invalid_create_response "$state" "$status" "$api_ms" "" "$total_ms" "" kubeconfig "$started_at" "" "$error"; exit 0; }
  while true; do
    current_ms="$(now_ms)"; ((current_ms>=deadline)) && { result=timeout; error="Cluster K8s não disponibilizou kubeconfig em ${TIMEOUT_SECONDS}s."; break; }
    details="$(mgc kubernetes cluster get --cluster-id "$id" --region "$region" --output json --raw 2>>"$log_file")" || { sleep "$POLL_INTERVAL_SECONDS"; continue; }
    state="$(jq -r '(.status.state//.state//"unknown")|tostring|ascii_downcase' <<< "$details")"; status="$(jq -r '(.status.message//(.status.messages? // []|join(";"))//.status//"unknown")|tostring' <<< "$details")"
    [[ "$state" == *error* || "$state" == failed || "${status,,}" == *error* ]] && { result=provisioning_error; error="$status"; break; }
    if mgc kubernetes cluster kubeconfig --cluster-id "$id" --region "$region" --output yaml --raw >/dev/null 2>>"$log_file"; then ready_ms=$((current_ms-start_ms)); ready_at="$(iso_now)"; result=success; state="${state/unknown/ready}"; break; fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
  total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "$id" "$result" "$state" "$status" "$api_ms" "$ready_ms" "$total_ms" "" kubeconfig_available "$started_at" "$ready_at" "$error"
)

provision_dbaas() (
  set +e
  local target="$1" region name file log_file id="" response details='{}' state=unknown status=unknown result=unknown error="" start_ms end_ms current_ms deadline api_ms="" ready_ms="" total_ms="" started_at ready_at=""
  region="$(region_from_zone "$target")"; name="$(build_resource_name "$target")"; file="$(target_result_file "$target")"; log_file="$TMP_DIR/${target}-provision.log"
  cleanup() { [[ -n "$id" ]] && is_true "$AUTO_DELETE" && { log "$target: removendo instância DBaaS $id..."; mgc dbaas instances delete --instance-id "$id" --region "$region" --no-confirm >>"$log_file" 2>&1 || true; }; }; trap cleanup EXIT INT TERM
  start_ms="$(now_ms)"; deadline=$((start_ms+TIMEOUT_SECONDS*1000)); started_at="$(iso_now)"; log "$target: criando instância DBaaS $name..."
  local -a args=(dbaas instances create --region "$region" --availability-zone "$target" --name "$name" --engine-id "${DB_ENGINE_ID_BY_REGION[$region]}" --instance-type-id "${DB_TYPE_ID_BY_REGION[$region]}" --user "$DBAAS_USER" --password "$DBAAS_PASSWORD" --volume.size "$DBAAS_VOLUME_SIZE" --volume.type "$DBAAS_VOLUME_TYPE" --backup-retention-days "$DBAAS_BACKUP_RETENTION_DAYS" --output json --raw)
  response="$(mgc "${args[@]}" 2>"$log_file")"; local rc=$?; end_ms="$(now_ms)"; api_ms=$((end_ms-start_ms))
  if ((rc)); then error="Falha no comando de criação: $(format_cli_error "$log_file" "$response" "$rc")"; total_ms=$(( $(now_ms)-start_ms )); log_failed_command dbaas "$target" "$name" "$rc" "$error" "${args[@]}"; write_result "$file" "$target" "$name" "" create_command_error "$state" "$status" "$api_ms" "" "$total_ms" "" active_status "$started_at" "" "$error"; exit 0; fi
  id="$(jq -r '.id//empty' <<< "$response")"; [[ -n "$id" ]] || { error="A CLI não retornou ID."; total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "" invalid_create_response "$state" "$status" "$api_ms" "" "$total_ms" "" active_status "$started_at" "" "$error"; exit 0; }
  while true; do
    current_ms="$(now_ms)"; ((current_ms>=deadline)) && { result=timeout; error="Instância DBaaS não atingiu ACTIVE em ${TIMEOUT_SECONDS}s."; break; }
    details="$(mgc dbaas instances get --instance-id "$id" --region "$region" --output json --raw 2>>"$log_file")" || { sleep "$POLL_INTERVAL_SECONDS"; continue; }
    status="$(jq -r '(.status//.state//"unknown")|tostring|ascii_downcase' <<< "$details")"; state="$status"
    if [[ "$status" == active ]]; then ready_ms=$((current_ms-start_ms)); ready_at="$(iso_now)"; result=success; break; fi
    [[ "$status" == error* || "$status" == failed ]] && { result=provisioning_error; error="$(jq -r '.error.message//.error_message//.message//"Provisionamento em erro."' <<< "$details")"; break; }
    sleep "$POLL_INTERVAL_SECONDS"
  done
  total_ms=$(( $(now_ms)-start_ms )); write_result "$file" "$target" "$name" "$id" "$result" "$state" "$status" "$api_ms" "$ready_ms" "$total_ms" "" active_status "$started_at" "$ready_at" "$error"
)

provision_target() {
  # Evita que o worker herde o trap global que remove TMP_DIR ao encerrar.
  # Cada provisionador instala seu próprio trap apenas para limpar o recurso.
  trap - EXIT
  case "$PRODUCT" in
    vm) provision_vm "$1" ;; volume) provision_volume "$1" ;; object-storage) provision_object "$1" ;; k8s) provision_k8s "$1" ;; dbaas) provision_dbaas "$1" ;;
  esac
}

build_results() {
  local target file; local -a files=()
  for target in "${TARGETS[@]}"; do
    file="$(target_result_file "$target")"
    if [[ ! -s "$file" ]]; then write_result "$file" "$target" "$(build_resource_name "$target")" "" internal_script_error unknown unknown "" "" "" "" not_executed "" "" "O processo terminou sem gerar resultado."; fi
    files+=("$file")
  done
  jq -s '.' "${files[@]}"
}

generate_csv() {
  local results="$1"
  jq -r 'def sec($x):if $x==null then "" else (($x/1000)|tostring) end; (["product","target","region","availability_zone","name","id","configuration","result","state","status","create_api_seconds","ready_seconds","total_test_seconds","public_ip","readiness_result","started_at","ready_at","error_message"]|@csv),(.[]|[.product,.target,.region,.availability_zone,.name,.id,.configuration_summary,.result,.state,.status,sec(.timings_ms.create_api),sec(.timings_ms.ready),sec(.timings_ms.total_test),.public_ip,.readiness_result,.timestamps.started_at,.timestamps.ready_at,.error_message]|@csv)' <<< "$results" > "$CSV_FILE"
}

generate_report() {
  local results="$1" finished summary
  finished="$(iso_now)"
  summary="$(jq -r '[.[]|select(.timings_ms.ready!=null)|.timings_ms.ready] as $t | if ($t|length)==0 then "Sem provisionamentos concluídos." else "Concluídos: \($t|length) | mínimo: \((($t|min)/1000))s | média: \((($t|add/length)/1000))s | máximo: \((($t|max)/1000))s" end' <<< "$results")"
  {
    printf '# Relatório de provisionamento — %s\n\n' "$(product_label)"
    printf -- '- **Execução:** `%s`\n' "$RUN_ID"
    printf -- '- **Tenant:** %s\n' "$TENANT_LABEL"
    printf -- '- **Produto:** %s\n' "$(product_label)"
    printf -- '- **Alvos:** `%s`\n' "${TARGETS[*]}"
    printf -- '- **Responsável:** `%s`\n' "$OWNER_TAG"
    printf -- '- **Início:** %s\n- **Fim:** %s\n' "$RUN_STARTED_AT" "$finished"
    printf -- '- **Remoção automática:** `%s`\n\n' "$AUTO_DELETE"
    printf '## Resumo\n\n%s\n\n' "$summary"
    printf 'A métrica **Pronto** é específica do produto: VM=`running`; volume=`available`; bucket=visível na listagem; Kubernetes=kubeconfig disponível; DBaaS=`ACTIVE`.\n\n'
    printf '## Resultados\n\n| Recurso | ID do recurso | Região | AZ | Configuração | Resultado | API | Pronto | Estado/Status |\n|---|---|---|---|---|---|---:|---:|---|\n'
    jq -r 'def sec($x):if $x==null then "—" else "\(($x/1000))s" end; .[]|"| `\(.name)` | \(if .id=="" then "—" else "`"+.id+"`" end) | \(.region) | \(if .availability_zone=="" then "—" else .availability_zone end) | \(.configuration_summary) | \(.result) | \(sec(.timings_ms.create_api)) | **\(sec(.timings_ms.ready))** | \(.state)/\(.status) |"' <<< "$results"
    printf '\n## Falhas e observações\n\n'
    jq -r '.[]|select(.result!="success" or .error_message!="")|"- **\(.target):** resultado=`\(.result)`\(if .error_message=="" then "" else ", erro="+.error_message end)."' <<< "$results"
  } > "$REPORT_FILE"
}

print_terminal_report() {
  local results="$1" failures
  printf '\nResultado final — %s:\n\n' "$(product_label)"
  if command -v column >/dev/null 2>&1; then
    jq -r 'def sec($x):if $x==null then "-" else "\(($x/1000))s" end; (["ALVO","RECURSO","ID","CONFIGURACAO","RESULTADO","API","PRONTO","ESTADO"]|@tsv),(.[]|[.target,.name,(if .id=="" then "-" else .id end),.configuration_summary,.result,sec(.timings_ms.create_api),sec(.timings_ms.ready),(.state+"/"+.status)]|@tsv)' <<< "$results" | column -t -s $'\t'
  else
    jq -r '.[]|"\(.target): \(.result), pronto=\(if .timings_ms.ready==null then "-" else ((.timings_ms.ready/1000)|tostring)+"s" end), nome=\(.name), id=\(if .id=="" then "-" else .id end)"' <<< "$results"
  fi
  printf '\nCSV:         %s\nRelatório:   %s\nDiagnóstico: %s\n' "$CSV_FILE" "$REPORT_FILE" "$DIAGNOSTIC_FILE"
  failures="$(jq '[.[]|select(.result!="success")]|length' <<< "$results")"
  if ((failures)); then printf '\nFalhas detalhadas:\n'; jq -r '.[]|select(.result!="success")|"- \(.target): \(.error_message//"sem mensagem")"' <<< "$results"; fi
  is_true "$AUTO_DELETE" && printf 'Os recursos efetivamente criados foram solicitados para remoção automática.\n' || printf 'Os recursos foram mantidos e devem ser removidos manualmente.\n'
}

print_configuration() {
  printf '\nConfiguração do teste:\n'
  printf '  Produto:                  %s\n' "$(product_label)"
  printf '  Alvos:                    %s\n' "${TARGETS[*]}"
  printf '  Responsável:              %s\n' "$OWNER_TAG"
  printf '  Padrão de nome:           teste-prov-%s-%s-<alvo>-%s\n' "$OWNER_TAG" "$(product_tag)" "${RUN_TOKEN,,}"
  case "$PRODUCT" in
    vm)
      printf '  Chave SSH:                %s\n' "$SSH_KEY_NAME"
      printf '  Imagem solicitada:        %s\n' "${VM_IMAGE:-automática}"
      printf '  Tipo solicitado:          %s\n' "${VM_MACHINE_TYPE:-menor compatível}"
      printf '  IPv4 público:             %s\n  Validação:                %s\n' "$ASSOCIATE_PUBLIC_IP" "$READINESS_CHECK" ;;
    volume) printf '  Tamanho:                  %s GiB\n  Tipo:                     %s\n' "$VOLUME_SIZE" "${VOLUME_TYPE_NAME:-automático}" ;;
    object-storage) printf '  Escopo:                   um bucket privado por região\n' ;;
    k8s) printf '  Tipo de máquina solicitado: %s\n  Versão solicitada:          %s\n  Réplicas por cluster:       %s\n  Fonte dos tipos:            catálogo de Virtual Machine por região/AZ\n  Estratégia de AZ:           um cluster por AZ, node pool fixado na letra selecionada\n' "${K8S_MACHINE_TYPE:-menor compatível}" "${K8S_VERSION:-mais recente}" "$K8S_REPLICAS" ;;
    dbaas) printf '  Engine solicitada:        %s\n  Tipo solicitado:          %s\n  Volume:                   %s GiB / %s\n  Estratégia de AZ:         uma instância por AZ selecionada\n' "${DBAAS_ENGINE:-PostgreSQL ativa ou primeira ativa}" "${DBAAS_INSTANCE_TYPE:-menor compatível}" "$DBAAS_VOLUME_SIZE" "$DBAAS_VOLUME_TYPE" ;;
  esac
  printf '  Timeout:                  %ss por recurso\n  Remoção automática:       %s\n\n' "$TIMEOUT_SECONDS" "$AUTO_DELETE"
}

cleanup_tmp() {
  # O trap EXIT é herdado pelos processos em background. Somente o shell
  # principal pode remover o diretório temporário, após aguardar os workers.
  [[ "${BASHPID:-$$}" == "$MAIN_BASHPID" ]] || return 0
  rm -rf -- "$TMP_DIR"
}
trap cleanup_tmp EXIT

main() {
  local target pid results; local -a pids=()
  parse_args "$@"
  require_commands
  check_authentication
  discover_zones
  resolve_general_inputs
  build_targets
  prepare_product
  resolve_owner_tag
  validate_resource_names
  print_configuration
  : > "$DIAGNOSTIC_FILE"

  for target in "${TARGETS[@]}"; do provision_target "$target" & pids+=("$!"); done
  for pid in "${pids[@]}"; do wait "$pid" || true; done

  results="$(build_results)"
  generate_csv "$results"
  generate_report "$results"
  print_terminal_report "$results"
  jq -e 'any(.[];.result!="success")' >/dev/null <<< "$results" && return 2 || return 0
}

main "$@"
