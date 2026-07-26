# Pipelines

> **Este repo é um mirror público (não-fork) de
> [`clefern/fiap-tc-mecanica-pipelines`](https://github.com/clefern/fiap-tc-mecanica-pipelines).**
> `clefern` teve o billing do GitHub Actions bloqueado, então a execução real passou a
> ser via forks pessoais em `Overz`. O fork `Overz/fiap-tc-mecanica-pipelines` é privado,
> e `Overz` é conta pessoal (sem organização) — reusable workflows privados não são
> chamáveis cross-repo mesmo dentro da mesma conta (`workflow was not found`). Como não
> somos donos de `clefern`, não dá pra mudar a visibilidade do original. Este mirror
> existe só para os `cd.yml` dos serviços em `Overz` conseguirem chamar `build.yml`/
> `deploy.yml`/`test.yml` via `uses:`.
>
> **Divergência intencional vs. o original:** o self-checkout dentro de `deploy.yml`
> aponta para `Overz/fiap-tc-mecanica-pipelines-public@main` em vez de
> `clefern/fiap-tc-mecanica-pipelines@develop`. É a única diferença — todo o resto deve
> ficar idêntico. Sempre que o original receber mudanças em `build.yml`/`deploy.yml`/
> `test.yml`, replicar aqui manualmente e dar push na `main`.

Workflows reutilizáveis de CI/CD compartilhados pelos microsserviços da Fase 4
(`mecanica-os-service`, `mecanica-billing-service`, `mecanica-inventory-service`,
`mecanica-workshop-service`). Não contém código de aplicação — só `.github/workflows/`
e o script de deploy que eles usam.

Réplica adaptada do padrão já usado em `fiap-tc-mecanica-app` (Fase 3): lá, `ci.yml`/
`cd.yml` chamam workflows reutilizáveis locais (`uses: ./.github/workflows/X.yml`).
Aqui, cada serviço tem seu próprio `ci.yml`/`cd.yml` fino, chamando os arquivos deste
repo cross-repo (`uses: clefern/fiap-tc-mecanica-pipelines/.github/workflows/X.yml@develop`).

Execução sempre manual pra tudo que toca AWS/cluster (`workflow_dispatch`), pois o
ambiente é AWS Academy (credenciais de sessão, expiram, renovadas manualmente). CI de
teste roda automático em push/PR, como qualquer projeto.

## Workflows

### `test.yml`
Build + testes Maven + análise SonarCloud + upload do relatório JaCoCo.

**Inputs:** `java-version` (opcional, default `21`), `service-name` (obrigatório —
usado no nome do artefato de cobertura).
**Secrets:** `SONAR_TOKEN` (obrigatório).

### `build.yml`
Build da imagem Docker + push no ECR, tag = SHA curto do commit + `latest`.

**Inputs:** `ecr_repository` (obrigatório), `aws_region` (opcional, default `us-east-1`).
**Secrets:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`.
**Outputs:** `image-uri` — URI completa da imagem publicada (`registry/repo:sha`).

### `deploy.yml`
Aplica o overlay Kustomize do repo chamador (`k8s/overlays/$ENVIRONMENT`) com a
imagem publicada por `build.yml`, via `kustomize edit set image` + `kubectl apply`.
**Não** busca credencial de banco nem faz `envsubst` — o repo `infra` já mantém um
`ExternalSecret`/`ClusterSecretStore` sincronizando os Secrets que cada Deployment
referencia via `secretKeyRef`.

**Inputs:** `environment` (obrigatório — `lab`/`develop`), `aws_region` (opcional),
`eks_cluster_name` (opcional, default `<environment>-fiap-cluster`), `k8s_deployment`
(obrigatório — nome do Deployment), `image_uri` (obrigatório — saída do `build.yml`),
`rollout_timeout` (opcional, default `180s`), `skip_rollout_check` (opcional, default
`false`).
**Secrets:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`.

`scripts/k8s-deploy.sh` (script compartilhado que este workflow chama) copia
`k8s/base`+overlay pra um diretório temporário antes de aplicar a imagem via
`kustomize edit set image` — preserva o checkout original, mesmo padrão de
isolamento de `phase-3/app/scripts/k8s-deploy.sh`.

Faz 2 checkouts: o repo chamador (pega o `k8s/` daquele serviço) e este repo
(`clefern/fiap-tc-mecanica-pipelines`, pasta `.pipelines/`, pega
`scripts/k8s-deploy.sh`). O namespace (`mecanica`/`mecanica-lab`) e o nome do cluster
são resolvidos automaticamente a partir de `environment` — o serviço chamador não
precisa saber esse mapeamento.

## Como um novo serviço usa isso

`ci.yml` do serviço:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  test:
    uses: clefern/fiap-tc-mecanica-pipelines/.github/workflows/test.yml@develop
    with:
      service-name: meu-servico
    secrets:
      SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
```

`cd.yml` do serviço:

```yaml
name: CD
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [lab, develop]
        default: lab

jobs:
  build:
    uses: clefern/fiap-tc-mecanica-pipelines/.github/workflows/build.yml@develop
    with:
      ecr_repository: fiap-mecanica-meu-servico
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_SESSION_TOKEN: ${{ secrets.AWS_SESSION_TOKEN }}

  deploy:
    needs: [build]
    uses: clefern/fiap-tc-mecanica-pipelines/.github/workflows/deploy.yml@develop
    with:
      environment: ${{ inputs.environment }}
      k8s_deployment: meu-servico
      image_uri: ${{ needs.build.outputs.image-uri }}
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_SESSION_TOKEN: ${{ secrets.AWS_SESSION_TOKEN }}
```

O serviço precisa ter `k8s/base/{deployment,service,ingressroute,kustomization}.yaml`
+ `k8s/overlays/{lab,develop}/` (Kustomize), com a imagem do Deployment referenciada
como `placeholder:latest` (o `deploy.yml` substitui via `kustomize edit set image`).

## Fora de escopo deste repo

- Orquestração cross-repo automática (disparar `infra`→`db`→serviços em sequência) —
  decisão consciente, execução sempre manual, ambiente AWS Academy.
- Provisionamento de infraestrutura (Terraform) — fica nos repos `infra`/`db`.
