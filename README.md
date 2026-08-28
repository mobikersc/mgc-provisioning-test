# MGC Provisioning Test

Suite de automação para **provisionar, validar, medir e remover recursos na Magalu Cloud (MGC)** utilizando a `mgc` CLI.

O projeto permite executar testes reproduzíveis em diferentes regiões e Availability Zones para múltiplos produtos:

- Virtual Machines
- Block Storage
- Object Storage
- Kubernetes
- DBaaS

Além da criação dos recursos, a ferramenta automatiza a descoberta de configurações compatíveis, acompanha o provisionamento, mede tempos, registra erros e evidências e, por padrão, remove os recursos criados ao final do teste.

> Projeto experimental de automação e diagnóstico. Não é uma ferramenta oficial da Magalu Cloud.

## Fluxo

    Autenticação MGC
          ↓
    Seleção do produto
          ↓
    Descoberta de região / AZ
          ↓
    Descoberta de parâmetros compatíveis
          ↓
    Criação do recurso
          ↓
    Acompanhamento do provisionamento
          ↓
    Readiness / validação
          ↓
    Medição e diagnóstico
          ↓
    Relatório
          ↓
    Cleanup automático

## Produtos suportados

Selecione o produto utilizando:

    --product vm|volume|object-storage|k8s|dbaas

### Virtual Machines

O teste de VM pode:

- selecionar automaticamente uma imagem Ubuntu ativa;
- selecionar o menor machine type compatível;
- utilizar VPC por nome ou ID;
- associar IPv4 público;
- acompanhar a VM até `running`;
- validar conectividade TCP/22;
- medir diferentes etapas do provisionamento.

Exemplo:

    ./teste_provisionamento_mgc_por_az.sh \
      --product vm \
      --zones br-se1-a,br-ne1-b \
      --ssh-key minha-chave \
      --image 'cloud-ubuntu-24.04 LTS' \
      --machine-type BV1-1-10

Se `--image` não for informado, o script procura automaticamente uma imagem Ubuntu ativa de menor requisito.

Se `--machine-type` não for informado, procura o menor tipo compatível disponível na zona.

Opções:

    --ssh-key NOME
    --image NOME_OU_ID
    --machine-type NOME_OU_ID
    --public-ip true|false
    --readiness none|tcp22
    --vpc-name NOME
    --vpc-id UUID

Defaults:

    public-ip: true
    readiness: tcp22

### Block Storage

Provisiona volumes para testar disponibilidade e tempo de criação.

Exemplo:

    ./teste_provisionamento_mgc_por_az.sh \
      --product volume \
      --zones br-se1-a,br-se1-b \
      --volume-size 10

Opções:

    --volume-size GIB
    --volume-type NOME

O tamanho mínimo e padrão é 10 GiB.

Quando o tipo não é informado, o script tenta selecioná-lo automaticamente.

### Object Storage

Object Storage é testado por região, e não por Availability Zone.

Exemplo:

    ./teste_provisionamento_mgc_por_az.sh \
      --product object-storage \
      --regions br-se1,br-ne1

### Kubernetes

Permite criar clusters Kubernetes e acompanhar o fluxo de provisionamento.

Exemplo:

    ./teste_provisionamento_mgc_por_az.sh \
      --product k8s \
      --regions br-se1 \
      --azs a,b \
      --k8s-machine-type BV2-4-40 \
      --k8s-replicas 1

Opções:

    --k8s-machine-type NOME
    --k8s-flavor NOME
    --k8s-version VERSAO
    --k8s-replicas NUMERO
    --k8s-max-pods NUMERO

`--k8s-flavor` é mantido como alias legado de `--k8s-machine-type`.

Se a versão não for informada, a ferramenta seleciona a versão Kubernetes mais recente disponível.

Se o machine type não for informado, tenta selecionar o menor compatível com a versão.

Defaults:

    replicas: 1
    max-pods: 32

### DBaaS

Provisiona instâncias de banco de dados gerenciado.

Exemplo:

    ./teste_provisionamento_mgc_por_az.sh \
      --product dbaas \
      --zones br-se1-a \
      --dbaas-engine PostgreSQL

Opções:

    --dbaas-engine NOME|ID|NOME@VERSAO
    --dbaas-instance-type NOME|ID
    --dbaas-user USUARIO
    --dbaas-password SENHA
    --dbaas-volume-size GIB
    --dbaas-volume-type TIPO

Defaults:

    user:        mgctest
    volume:      10 GiB
    volume-type: CLOUD_NVME15K

Quando `--dbaas-password` não é informado, uma senha temporária é gerada e não é registrada.

## Regiões e Availability Zones

Somente regiões:

    --regions br-se1,br-ne1

Regiões com AZs:

    --regions br-se1 \
    --azs a,b,c

Zonas completas:

    --zones br-se1-a,br-se1-c,br-ne1-b

Quando `--zones` é utilizado, ele substitui `--regions` e `--azs`.

Object Storage é testado por região. Os demais produtos utilizam Availability Zones quando aplicável.

## Modos de execução

Modo interativo:

    ./teste_provisionamento_mgc_por_az.sh --interactive

Modo não interativo:

    ./teste_provisionamento_mgc_por_az.sh \
      --non-interactive \
      --product vm \
      --zones br-se1-a

O modo não interativo é indicado para automações, campanhas e execuções recorrentes.

## Timeout

O timeout pode ser configurado com:

    --timeout 1800

O padrão é 1800 segundos por recurso.

## Cleanup

Por padrão:

    auto-delete: true

Para manter os recursos depois do teste:

    --keep

ou:

    --auto-delete false

Mesmo com cleanup automático, recomenda-se verificar os recursos após execuções interrompidas.

## Identificação dos recursos

É possível fornecer um identificador para os recursos criados:

    --owner IDENTIFICADOR

Para Virtual Machines, o identificador padrão pode ser derivado da chave SSH escolhida.

## Exemplos

### VM com seleção automática

    ./teste_provisionamento_mgc_por_az.sh \
      --product vm \
      --zones br-se1-a,br-se1-b,br-se1-c \
      --ssh-key minha-chave \
      --vpc-name vpc_default

### Object Storage

    ./teste_provisionamento_mgc_por_az.sh \
      --product object-storage \
      --regions br-se1,br-ne1

### Kubernetes

    ./teste_provisionamento_mgc_por_az.sh \
      --product k8s \
      --regions br-se1 \
      --azs a,b \
      --k8s-machine-type BV2-4-40

### DBaaS

    ./teste_provisionamento_mgc_por_az.sh \
      --product dbaas \
      --zones br-se1-a \
      --dbaas-engine PostgreSQL

### Manter recursos

    ./teste_provisionamento_mgc_por_az.sh \
      --product vm \
      --zones br-se1-a \
      --keep

## Diagnóstico

A ferramenta busca diferenciar falhas por etapa, em vez de registrar apenas sucesso ou erro.

Dependendo do produto, podem ser registrados dados como:

    tempo da API
    tempo de provisionamento
    estado final
    readiness
    IPv4 público
    resultado TCP/22
    HTTP status
    mensagem da API
    slug
    Request ID
    MGC Trace ID

Isso permite utilizar o projeto tanto como smoke test quanto como ferramenta de coleta de evidências para troubleshooting.

## Campanhas de provisionamento

O repositório também contém ferramentas para execuções repetidas:

    executar_campanha_provisionamento_mgc.sh
    consolidar_campanha_mgc.py
    GUIA_CAMPANHA_PROVISIONAMENTO_MGC.md

Fluxo:

    executar_campanha_provisionamento_mgc.sh
                    ↓
             múltiplos testes
                    ↓
            resultados individuais
                    ↓
            consolidar_campanha_mgc.py
                    ↓
             resultado consolidado

As campanhas permitem analisar:

- taxa de sucesso;
- diferenças entre regiões;
- diferenças entre AZs;
- variações de tempo;
- falhas intermitentes;
- comportamento antes e depois de mudanças.

Consulte `GUIA_CAMPANHA_PROVISIONAMENTO_MGC.md` para detalhes adicionais.

## Estrutura do repositório

    .
    ├── teste_provisionamento_mgc_por_az.sh
    ├── teste_provisionamento_mgc.sh
    ├── executar_campanha_provisionamento_mgc.sh
    ├── consolidar_campanha_mgc.py
    ├── GUIA_CAMPANHA_PROVISIONAMENTO_MGC.md
    ├── README.md
    └── .gitignore

### teste_provisionamento_mgc_por_az.sh

Ferramenta principal multi-produto para provisionamento, medição e validação.

### teste_provisionamento_mgc.sh

Versão/base anterior da ferramenta mantida no projeto.

### executar_campanha_provisionamento_mgc.sh

Orquestra múltiplas execuções.

### consolidar_campanha_mgc.py

Consolida os resultados obtidos em campanhas.

### GUIA_CAMPANHA_PROVISIONAMENTO_MGC.md

Documentação específica das campanhas de provisionamento.

## Pré-requisitos

A MGC CLI deve estar instalada e autenticada:

    mgc auth login

Antes de executar os testes, confirme o tenant ativo.

O usuário autenticado deve possuir permissões suficientes para criar, consultar e remover os recursos correspondentes aos produtos testados.

## Segurança

Os testes criam recursos reais na conta MGC selecionada.

Antes de executar, confirme:

- tenant;
- regiões;
- Availability Zones;
- produto;
- comportamento de cleanup.

Nunca versione:

- API keys;
- access tokens;
- refresh tokens;
- senhas;
- chaves SSH privadas;
- arquivos `.env`.

## Ajuda

A lista atualizada de parâmetros suportados pode ser consultada diretamente:

    ./teste_provisionamento_mgc_por_az.sh --help

## Status

Projeto experimental para testes, medições e troubleshooting de provisionamento de recursos na Magalu Cloud.

A compatibilidade pode mudar conforme novas versões da MGC CLI e das APIs utilizadas.

---

**Disclaimer:** este projeto é uma automação independente e experimental e não representa uma ferramenta oficial da Magalu Cloud.
