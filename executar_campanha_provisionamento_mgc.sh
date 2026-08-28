#!/usr/bin/env bash
# Executa o teste de provisionamento da MGC em uma campanha periódica e,
# ao final, consolida os CSVs produzidos.

set -Eeuo pipefail
umask 077

INTERVAL_MINUTES=20
DURATION_HOURS=8
RUNS=""
BASE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/teste_provisionamento_mgc.sh"
CONSOLIDATOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/consolidar_campanha_mgc.py"
CAMPAIGN_DIR=""
ALLOW_OVERLAP=false
ALLOW_KEEP=false
STOP_ON_AUTH_ERROR=true
STOP_REQUESTED=false
ACTIVE_PID=""
declare -a ALL_PIDS=()
declare -a BASE_ARGS=()

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Uso:
  ./executar_campanha_provisionamento_mgc.sh [opções da campanha] -- [opções do teste]

Opções da campanha:
  --interval-minutes N      Intervalo entre inícios. Padrão: 20
  --duration-hours N        Duração da janela. Padrão: 8
  --runs N                  Quantidade exata de execuções. Substitui a duração.
  --script CAMINHO          Caminho do teste_provisionamento_mgc.sh
  --consolidator CAMINHO    Caminho do consolidar_campanha_mgc.py
  --campaign-dir DIRETORIO  Diretório de saída da campanha
  --allow-overlap           Inicia uma nova rodada mesmo se a anterior ainda estiver ativa
  --allow-keep              Permite usar --keep ou --auto-delete false no teste
  --continue-on-auth-error  Não encerra a campanha se a sessão MGC estiver inválida
  -h, --help                Mostra esta ajuda

Tudo após -- é repassado ao teste de provisionamento.
O wrapper adiciona --non-interactive automaticamente.

Exemplo:
  ./executar_campanha_provisionamento_mgc.sh \
    --interval-minutes 20 \
    --duration-hours 8 \
    -- \
    --product vm \
    --zones br-se1-a,br-se1-b,br-se1-c,br-ne1-a,br-ne1-b \
    --ssh-key minha-chave \
    --image 'cloud-ubuntu-24.04 LTS' \
    --machine-type BV1-1-10 \
    --auto-delete true

Sem --runs, uma janela de 8 horas com intervalo de 20 minutos gera 24 horários:
agora, +20 min, ..., +7h40. Para incluir também o ponto exato de +8h, use --runs 25.
USAGE
}

is_true_value() {
  case "${1,,}" in true|1|yes|sim) return 0 ;; *) return 1 ;; esac
}

parse_args() {
  while (($#)); do
    case "$1" in
      --interval-minutes) [[ -n "${2:-}" ]] || fail "$1 exige valor"; INTERVAL_MINUTES="$2"; shift 2 ;;
      --duration-hours) [[ -n "${2:-}" ]] || fail "$1 exige valor"; DURATION_HOURS="$2"; shift 2 ;;
      --runs) [[ -n "${2:-}" ]] || fail "$1 exige valor"; RUNS="$2"; shift 2 ;;
      --script) [[ -n "${2:-}" ]] || fail "$1 exige valor"; BASE_SCRIPT="$2"; shift 2 ;;
      --consolidator) [[ -n "${2:-}" ]] || fail "$1 exige valor"; CONSOLIDATOR="$2"; shift 2 ;;
      --campaign-dir) [[ -n "${2:-}" ]] || fail "$1 exige valor"; CAMPAIGN_DIR="$2"; shift 2 ;;
      --allow-overlap) ALLOW_OVERLAP=true; shift ;;
      --allow-keep) ALLOW_KEEP=true; shift ;;
      --continue-on-auth-error) STOP_ON_AUTH_ERROR=false; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; BASE_ARGS=("$@"); break ;;
      *) fail "Opção de campanha desconhecida: $1. Separe as opções do teste com --." ;;
    esac
  done
}

contains_arg() {
  local wanted="$1" arg
  for arg in "${BASE_ARGS[@]}"; do [[ "$arg" == "$wanted" ]] && return 0; done
  return 1
}

uses_keep_mode() {
  local i
  for ((i=0; i<${#BASE_ARGS[@]}; i++)); do
    case "${BASE_ARGS[$i]}" in
      --keep) return 0 ;;
      --auto-delete)
        if ((i+1 < ${#BASE_ARGS[@]})) && ! is_true_value "${BASE_ARGS[$((i+1))]}"; then return 0; fi
        ;;
    esac
  done
  return 1
}

redacted_command() {
  local -a out=() args=("${BASE_ARGS[@]}")
  local i=0
  while ((i < ${#args[@]})); do
    if [[ "${args[$i]}" == "--dbaas-password" ]] && ((i+1 < ${#args[@]})); then
      out+=("--dbaas-password" "***REDACTED***")
      ((i+=2))
    else
      out+=("${args[$i]}")
      ((i+=1))
    fi
  done
  printf '%q ' "$BASE_SCRIPT" --non-interactive "${out[@]}"
}

iso_from_epoch() { date -u -d "@$1" +'%Y-%m-%dT%H:%M:%SZ'; }

write_meta() {
  local file="$1" slot="$2" status="$3" scheduled="$4" started="$5" ended="$6" rc="$7" run_dir="$8" prefix="$9"
  cat > "$file" <<META
slot=$slot
status=$status
scheduled_at=$scheduled
actual_start=$started
actual_end=$ended
exit_code=$rc
run_dir=$run_dir
output_prefix=$prefix
META
}

run_one() {
  local slot="$1" scheduled_iso="$2" run_dir="$3" prefix="$4" meta_file="$5"
  local started ended rc
  started="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$run_dir"
  log "Rodada $(printf '%03d' "$slot"): início em $started (agendada para $scheduled_iso)."
  set +e
  OUTPUT_PREFIX="$prefix" "$BASE_SCRIPT" --non-interactive "${BASE_ARGS[@]}" >"$run_dir/execucao.log" 2>&1
  rc=$?
  set -e
  ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  write_meta "$meta_file" "$slot" completed "$scheduled_iso" "$started" "$ended" "$rc" "$run_dir" "$prefix"
  log "Rodada $(printf '%03d' "$slot"): encerrada em $ended, exit_code=$rc."
  return "$rc"
}

on_signal() {
  STOP_REQUESTED=true
  warn "Interrupção solicitada. Nenhuma nova rodada será iniciada; as rodadas já ativas serão aguardadas."
}
trap on_signal INT TERM

parse_args "$@"

[[ "$INTERVAL_MINUTES" =~ ^[1-9][0-9]*$ ]] || fail "--interval-minutes deve ser inteiro positivo."
[[ "$DURATION_HOURS" =~ ^[1-9][0-9]*([.][0-9]+)?$ ]] || fail "--duration-hours deve ser positivo."
[[ -z "$RUNS" || "$RUNS" =~ ^[1-9][0-9]*$ ]] || fail "--runs deve ser inteiro positivo."
[[ -x "$BASE_SCRIPT" ]] || fail "Script base não encontrado ou sem permissão de execução: $BASE_SCRIPT"
[[ -f "$CONSOLIDATOR" ]] || fail "Consolidador não encontrado: $CONSOLIDATOR"
command -v python3 >/dev/null 2>&1 || fail "python3 não encontrado."
command -v mgc >/dev/null 2>&1 || fail "mgc CLI não encontrada."
((${#BASE_ARGS[@]} > 0)) || fail "Informe as opções do teste após --. A campanha não pode depender de menus interativos."
contains_arg --interactive && fail "Não use --interactive em uma campanha."
contains_arg --non-interactive && warn "--non-interactive já é adicionado automaticamente."
if uses_keep_mode && [[ "$ALLOW_KEEP" != true ]]; then
  fail "A campanha manteria recursos de várias rodadas. Use exclusão automática ou confirme conscientemente com --allow-keep."
fi

if [[ -z "$RUNS" ]]; then
  RUNS="$(python3 - "$DURATION_HOURS" "$INTERVAL_MINUTES" <<'PY'
import math, sys
hours=float(sys.argv[1]); interval=int(sys.argv[2])
print(max(1, math.ceil(hours*60/interval)))
PY
)"
fi

CAMPAIGN_ID="$(date -u +'%Y%m%dT%H%M%SZ')"
if [[ -z "$CAMPAIGN_DIR" ]]; then CAMPAIGN_DIR="$(pwd)/campanha-provisionamento-${CAMPAIGN_ID}"; fi
mkdir -p "$CAMPAIGN_DIR/runs" "$CAMPAIGN_DIR/meta"
CAMPAIGN_DIR="$(cd "$CAMPAIGN_DIR" && pwd)"

LOCK_FILE="$CAMPAIGN_DIR/.campaign.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "Já existe outra execução usando $CAMPAIGN_DIR"

START_EPOCH="$(date +%s)"
INTERVAL_SECONDS=$((INTERVAL_MINUTES*60))

cat > "$CAMPAIGN_DIR/campanha.conf" <<CONF
campaign_id=$CAMPAIGN_ID
started_at=$(iso_from_epoch "$START_EPOCH")
interval_minutes=$INTERVAL_MINUTES
duration_hours=$DURATION_HOURS
planned_runs=$RUNS
allow_overlap=$ALLOW_OVERLAP
auto_delete_guard=$([[ "$ALLOW_KEEP" == true ]] && echo bypassed || echo enabled)
base_script=$BASE_SCRIPT
command=$(redacted_command)
CONF

log "Campanha: $CAMPAIGN_ID"
log "Diretório: $CAMPAIGN_DIR"
log "Planejamento: $RUNS rodadas, intervalo de ${INTERVAL_MINUTES} min."
[[ "$ALLOW_OVERLAP" == true ]] && warn "Sobreposição habilitada: várias rodadas podem provisionar recursos simultaneamente."

for ((slot=1; slot<=RUNS; slot++)); do
  [[ "$STOP_REQUESTED" == true ]] && break
  scheduled_epoch=$((START_EPOCH + (slot-1)*INTERVAL_SECONDS))
  now_epoch="$(date +%s)"
  if ((now_epoch < scheduled_epoch)); then
    sleep $((scheduled_epoch-now_epoch)) || true
  fi
  [[ "$STOP_REQUESTED" == true ]] && break

  scheduled_iso="$(iso_from_epoch "$scheduled_epoch")"
  slot_id="$(printf '%03d' "$slot")"
  run_stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  run_dir="$CAMPAIGN_DIR/runs/run-${slot_id}-${run_stamp}"
  prefix="$run_dir/provisionamento-mgc-${run_stamp}"
  meta_file="$CAMPAIGN_DIR/meta/slot-${slot_id}.meta"

  if [[ "$ALLOW_OVERLAP" != true && -n "$ACTIVE_PID" ]]; then
    if kill -0 "$ACTIVE_PID" 2>/dev/null; then
      warn "Rodada $slot_id ignorada: a rodada anterior ainda está em execução."
      write_meta "$meta_file" "$slot" skipped_previous_running "$scheduled_iso" "" "" "" "$run_dir" "$prefix"
      continue
    fi
    wait "$ACTIVE_PID" || true
    ACTIVE_PID=""
  fi

  if ! mgc auth tenant current --output json --raw >/dev/null 2>&1; then
    warn "Rodada $slot_id não iniciada: sessão da MGC CLI inválida ou expirada."
    write_meta "$meta_file" "$slot" auth_error "$scheduled_iso" "" "" "" "$run_dir" "$prefix"
    if [[ "$STOP_ON_AUTH_ERROR" == true ]]; then
      warn "Campanha encerrada. Execute 'mgc auth login' antes de uma nova campanha."
      break
    fi
    continue
  fi

  run_one "$slot" "$scheduled_iso" "$run_dir" "$prefix" "$meta_file" &
  pid=$!
  ALL_PIDS+=("$pid")
  ACTIVE_PID="$pid"
done

log "Aguardando rodadas ainda ativas..."
for pid in "${ALL_PIDS[@]}"; do wait "$pid" || true; done

log "Consolidando resultados..."
python3 "$CONSOLIDATOR" "$CAMPAIGN_DIR"
log "Campanha concluída. Consulte: $CAMPAIGN_DIR/analise_campanha.md"
