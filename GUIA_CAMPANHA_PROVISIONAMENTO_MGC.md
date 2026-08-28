# Campanha periódica de provisionamento MGC

Este fluxo executa o `teste_provisionamento_mgc.sh` em horários fixos, armazena cada rodada separadamente e consolida os tempos ao final.

## Arquivos

- `teste_provisionamento_mgc.sh`: cria, mede e remove os recursos de uma rodada.
- `executar_campanha_provisionamento_mgc.sh`: agenda as rodadas localmente.
- `consolidar_campanha_mgc.py`: reúne os CSVs e calcula estatísticas.

## Antes de iniciar

```bash
chmod +x teste_provisionamento_mgc.sh
chmod +x executar_campanha_provisionamento_mgc.sh
chmod +x consolidar_campanha_mgc.py
mgc auth login
```

Mantenha o computador e o terminal ativos durante toda a campanha. A sessão da MGC CLI precisa continuar válida. Para execução remota, recomenda-se usar `tmux`, `screen` ou uma VM de operação.

## Campanha de 8 horas, a cada 20 minutos

Exemplo para VM nas cinco AZs:

```bash
./executar_campanha_provisionamento_mgc.sh \
  --interval-minutes 20 \
  --duration-hours 8 \
  -- \
  --product vm \
  --zones br-se1-a,br-se1-b,br-se1-c,br-ne1-a,br-ne1-b \
  --ssh-key mmelo-tkpd \
  --image 'cloud-ubuntu-24.04 LTS' \
  --machine-type BV1-1-10 \
  --public-ip true \
  --readiness tcp22 \
  --auto-delete true
```

A janela padrão gera 24 horários: a primeira rodada começa imediatamente e a última em `+7h40`. Para incluir também uma rodada em `+8h`, use `--runs 25`.

## Segurança operacional

A exclusão automática deve permanecer habilitada em campanhas periódicas. O wrapper bloqueia `--keep` e `--auto-delete false`, a menos que seja adicionada conscientemente a opção `--allow-keep`.

Por padrão, rodadas não se sobrepõem. Se uma execução ainda estiver ativa no horário seguinte, aquele horário é registrado como `skipped_previous_running`. Isso evita acumular recursos e distorcer o ambiente. `--allow-overlap` força a cadência exata, mas pode deixar várias rodadas simultâneas.

## Manter a campanha após fechar o terminal

Com `tmux`:

```bash
tmux new -s campanha-mgc
./executar_campanha_provisionamento_mgc.sh [opções]
```

Para sair sem encerrar: `Ctrl+B`, depois `D`.

Para retornar:

```bash
tmux attach -t campanha-mgc
```

Também é possível executar com `nohup`:

```bash
nohup ./executar_campanha_provisionamento_mgc.sh [opções] \
  > campanha-launcher.log 2>&1 &
```

## Resultados

A campanha cria um diretório semelhante a:

```text
campanha-provisionamento-20260802T090000Z/
├── campanha.conf
├── execucoes_campanha.csv
├── consolidado_recursos.csv
├── resumo_por_alvo.csv
├── analise_campanha.md
├── meta/
└── runs/
    ├── run-001-.../
    ├── run-002-.../
    └── ...
```

O relatório consolidado apresenta:

- quantidade de rodadas planejadas e executadas;
- taxa de sucesso;
- mínimo, mediana, média, p95 e máximo do tempo `Pronto`;
- desvio padrão por região/AZ;
- média do tempo de resposta da API;
- contagem dos resultados de TCP/22;
- dez provisionamentos mais lentos;
- falhas e mensagens retornadas pela plataforma.

## Consolidar novamente

```bash
python3 consolidar_campanha_mgc.py campanha-provisionamento-<ID>
```

Isso é útil caso arquivos de uma rodada sejam corrigidos ou adicionados posteriormente.
