# Architektura

## Infrastruktura AWS

```mermaid
flowchart LR
  user([Użytkownik / loadgen]) -->|HTTP 80| alb[ALB]
  subgraph vpc[VPC, 2 podsieci publiczne w 2 AZ]
    alb -->|reguła produkcyjna| tgb[Target group blue]
    alb -->|reguła testowa X-Deployment-Test| tgg[Target group green]
    tgb --> t1[Zadania Fargate, wersja bieżąca]
    tgg --> t2[Zadania Fargate, nowa wersja]
  end
  t1 & t2 -->|HTTPS 443, publiczne IP| ecr[(ECR, IMMUTABLE, scan on push)]
  t1 & t2 --> logs[(CloudWatch Logs)]
  alb -. metryki .-> cw[Alarmy CloudWatch: 5xx, czas odpowiedzi]
  cw -. rollback .-> ecs[Usługa ECS, BLUE_GREEN, bake 5 min]
  ecs --> t1 & t2
  gh[GitHub Actions] -->|OIDC| iam[Role gh-plan, gh-infra-apply, gh-app-deploy]
  iam --> ecr & ecs
  tf[(S3: stan Terraform)] --- gh
```

Zasoby:

- `network.tf`: VPC, 2 podsieci publiczne, Internet Gateway, bez NAT Gateway,
- `ecr.tf`: repozytorium z niezmiennymi tagami, skanem przy push, szyfrowaniem KMS, lifecycle (20 obrazów),
- `alb.tf`: ALB, listener HTTP 80, target groupy blue i green z healthcheckiem `/health`, reguła produkcyjna i testowa,
- `ecs.tf`: klaster z Container Insights, task definition (read-only root filesystem), usługa w strategii `BLUE_GREEN`,
- `monitoring.tf`: alarmy na poziomie ALB (wymiar `LoadBalancer`, obejmuje oba target groupy),
- `iam.tf`: role dla GitHub Actions, rola wykonawcza zadań, rola infrastrukturalna ECS dla blue/green.

## Pipeline aplikacji (`app.yml`)

```mermaid
flowchart TB
  subgraph ci [Każde uruchomienie: push, PR, ręczne]
    direction LR
    B[pytest] --> C[docker build] --> D{Trivy: CRITICAL?}
    D -->|tak| X[stop, nic nie trafia do ECR]
    D -->|nie| E[SBOM CycloneDX] --> F{PR?}
    F -->|tak| Y[stop bez wdrożenia]
  end
  subgraph cd [Tylko main]
    direction LR
    G[OIDC, push do ECR, digest] --> H[cosign sign, attest SBOM] --> I{cosign verify}
    I -->|brak podpisu| Z[stop, usługa bez zmian]
    I -->|OK| J[task definition z repo@sha256] --> K[update-service] --> L[raport]
  end
  ci -->|nie| cd
```

Weryfikacja podpisu i wdrożenie są w `scripts/deploy.sh`. Ten sam skrypt jest wywoływany przez `scripts/demo-unsigned.sh`, więc demonstracja odrzucenia niepodpisanego obrazu używa dokładnie tej samej ścieżki co pipeline.

## Pipeline infrastruktury (`infra.yml`)

```mermaid
flowchart LR
  P[PR] --> plan[terraform plan<br>rola gh-plan] --> cost[cost.py<br>komentarz na PR] --> gate{wzrost kosztu<br>> próg?}
  gate -->|tak| ap[cost-gate<br>infra-cost-approval<br>czeka na reviewera]
  gate -->|nie| ok[cost-gate<br>infra-cost-ok]
  P --> trivy[trivy config]
  ap & ok & trivy --> merge[merge do main] --> apply[terraform apply<br>środowisko infra<br>rola gh-infra-apply]
```

## Wdrożenie blue/green z bake time

```mermaid
sequenceDiagram
  participant P as Pipeline
  participant E as ECS
  participant A as ALB
  participant C as CloudWatch
  P->>E: update-service (nowa rewizja, digest)
  E->>E: start zadań green
  E->>A: rejestracja w target group green, healthcheck /health
  alt healthcheck nie przechodzi
    E->>E: circuit breaker, wdrożenie zatrzymane
    Note over A: ruch produkcyjny cały czas na blue
  else healthcheck OK
    E->>A: ruch testowy na green, potem produkcyjny na green
    Note over E: bake time 5 min, blue dalej działa
    alt alarm 5xx lub czasu odpowiedzi
      C-->>E: ALARM
      E->>A: ruch z powrotem na blue
      E->>E: zatrzymanie green (rollback)
    else brak alarmu przez 5 min
      E->>E: zatrzymanie blue, green staje się produkcją
    end
  end
  P->>E: describe-service-deployments, raport
```
