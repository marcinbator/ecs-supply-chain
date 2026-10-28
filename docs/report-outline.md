# Szkic dokumentu

Hasła i fakty do rozwinięcia, listingi i zrzuty do wklejenia. Diagramy Mermaid do wyrenderowania są w [architecture.md](architecture.md), przebieg demo w [presentation.md](presentation.md).

## 2. Architektura

- Diagramy z `architecture.md`: infrastruktura AWS, pipeline `app.yml`, pipeline `infra.yml`, sekwencja blue/green.
- Region `eu-central-1`, jedno środowisko `demo`, całość z jednego `terraform apply` / `destroy`.
- Ruch: internet -> ALB (HTTP 80) -> reguła produkcyjna -> target group blue/green -> zadania Fargate (port 8000).
- Bez NAT Gateway (koszt), zadania w podsieciach publicznych z publicznym IP, SG zadań przyjmuje ruch tylko z SG ALB.

![ALB, listener HTTP 80 z 3 regułami](screenshots/01-infrastructure/01-alb-http-listener.png)

## 3. Aplikacja

- Python 3.12, FastAPI, uvicorn, 3 endpointy:

| Endpoint       | Odpowiedź                  | Użycie                            |
| -------------- | -------------------------- | --------------------------------- |
| `GET /health`  | `{"status":"ok"}`          | healthcheck ALB                   |
| `GET /version` | wersja i SHA commita       | `loadgen.sh`, widać zmianę wersji |
| `GET /`        | prosta odpowiedź biznesowa | ruch testowy                      |

![Aplikacja za ALB w przeglądarce, wersja 2.0.0](screenshots/01-infrastructure/02-app-in-browser.png)

- Zmienne środowiskowe (wpisywane w obraz przez `--build-arg`, nie przez task definition):

| Zmienna                 | Wartości                                                       | Po co                                                    |
| ----------------------- | -------------------------------------------------------------- | -------------------------------------------------------- |
| `APP_VERSION`           | z `app/VERSION`, np. `2.0.0`, przy demo z dopiskiem `-delayed` | widać w `/version`, która wersja obsługuje ruch          |
| `GIT_SHA`               | SHA commita                                                    | powiązanie obrazu z kodem                                |
| `FAILURE_MODE`          | `none` / `health` / `delayed`                                  | tryby awarii do demonstracji, wybierane w Run workflow   |
| `FAILURE_DELAY_SECONDS` | domyślnie 90                                                   | po ilu sekundach od startu `delayed` zaczyna zwracać 500 |

- Tryby awarii:
  - `none`: działanie normalne,
  - `health`: `/health` zwraca 500, nowa wersja nie przechodzi healthchecków ALB, nie dostaje ruchu,
  - `delayed`: `/health` OK, ale `/` i `/version` zwracają 500 po 90 s, nowa wersja przejmuje ruch i psuje się w trakcie bake time.
- Dlaczego flaga, a nie osobny zepsuty kod: obraz przechodzi testy i skan, podpis jest ważny, awaria ujawnia się dopiero w środowisku (realistyczny scenariusz).
- Testy pytest: 4 testy, wszystkie tryby.

### List. Tryby awarii (`app/main.py`, fragment)

```python
def delayed_failure_active() -> bool:
    delay = int(os.getenv("FAILURE_DELAY_SECONDS", "90"))
    return failure_mode() == "delayed" and time.monotonic() - STARTED_AT >= delay


@app.get("/health")
def health():
    if failure_mode() == "health":
        return error()
    return {"status": "ok"}
```

- Dockerfile:
  - multi-stage (etap build z zależnościami, etap końcowy tylko runtime),
  - obraz bazowy przypięty po digeście,
  - użytkownik non-root z UID 10001,
  - w task definition `readonlyRootFilesystem = true`,
  - bez `HEALTHCHECK` (robi go ALB).

### List. `app/Dockerfile`

```dockerfile
FROM python:3.12-slim@sha256:12316debbfb86890f6b2d825820612741ba527ad5a44e3902759141d572bfe8f AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim@sha256:12316debbfb86890f6b2d825820612741ba527ad5a44e3902759141d572bfe8f
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
ARG FAILURE_MODE=none
ENV APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    FAILURE_MODE=${FAILURE_MODE} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /install /usr/local
WORKDIR /app
COPY main.py .
USER 10001
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

## 4. Infrastruktura (Terraform)

- Jeden root module w `terraform/`, pliki według obszaru:

| Plik            | Zawartość                                                                            |
| --------------- | ------------------------------------------------------------------------------------ |
| `backend.tf`    | stan w S3, natywna blokada `use_lockfile`                                            |
| `versions.tf`   | Terraform >= 1.10, provider AWS `~> 6.6` (natywny blue/green od 6.4), `default_tags` |
| `network.tf`    | VPC, 2 podsieci publiczne w 2 AZ, IGW, bez NAT                                       |
| `ecr.tf`        | repozytorium obrazów                                                                 |
| `alb.tf`        | ALB, listener HTTP 80, target groupy blue i green, reguła produkcyjna i testowa      |
| `ecs.tf`        | klaster (Container Insights), task definition, usługa blue/green, SG zadań           |
| `monitoring.tf` | 2 alarmy CloudWatch na poziomie ALB                                                  |
| `iam.tf`        | role OIDC dla GitHub Actions, rola zadań, rola ECS do blue/green                     |

- Ręcznie (raz, w konsoli): bucket na stan i provider OIDC GitHuba.

### List. Usługa ECS z natywnym blue/green (`terraform/ecs.tf`, fragment)

```hcl
  deployment_configuration {
    strategy             = "BLUE_GREEN"
    bake_time_in_minutes = 5
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  alarms {
    enable   = true
    rollback = true
    alarm_names = [
      aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.response_time.alarm_name,
    ]
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count, load_balancer]
  }
```

- `ignore_changes`: obrazem zarządza pipeline aplikacji, nie Terraform; ECS zamienia blue i green po każdym wdrożeniu.
- `load_balancer.advanced_configuration`: alternatywny target group, reguła produkcyjna i testowa, rola ECS do przełączania wag.

### List. Alarm 5xx (`terraform/monitoring.tf`, fragment)

```hcl
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.alarm_5xx_threshold
```

- Wymiar `LoadBalancer`: alarm obejmuje oba target groupy.
- Czas reakcji około 3 min (2 z 3 punktów po 60 s + opóźnienie metryk ALB), bake time 5 min, więc alarm zdąży przed końcem bake time.

### Środki bezpieczeństwa

- **ECR**: tagi `IMMUTABLE` (nie da się nadpisać obrazu pod tym samym tagiem), `scan_on_push`, szyfrowanie KMS, lifecycle 20 obrazów.

### List. `terraform/ecr.tf` (fragment)

```hcl
resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}
```

- **OIDC zamiast kluczy**: GitHub Actions dostaje krótkotrwałe poświadczenia, w repo i w GitHubie brak kluczy AWS.
- **3 role z warunkiem na `sub`**:

| Rola             | Kto może przyjąć                        | Uprawnienia                                                          |
| ---------------- | --------------------------------------- | -------------------------------------------------------------------- |
| `gh-plan`        | PR                                      | ReadOnlyAccess + zapis tylko pliku blokady stanu                     |
| `gh-infra-apply` | job w środowisku `infra` (tylko `main`) | zasoby projektu, IAM tylko na role `ecs-supply-chain-*`              |
| `gh-app-deploy`  | gałąź `main`                            | push do 1 repo ECR, 1 usługa ECS, `iam:PassRole` tylko na rolę zadań |

- Nowy format `sub` (repozytoria od 15.07.2026): niezmienne ID właściciela i repo, ochrona przed przejęciem nazwy repo.

### List. Warunek zaufania ról (`terraform/iam.tf`, fragment)

```hcl
  for_each = {
    plan        = "repo:${var.github_oidc_repo}:pull_request"
    infra-apply = "repo:${var.github_oidc_repo}:environment:infra"
    app-deploy  = "repo:${var.github_oidc_repo}:ref:refs/heads/main"
  }
```

- **Sieć**: SG ALB: wejście tylko 80; SG zadań: wejście tylko z SG ALB na 8000, wyjście tylko 443.
- **Skan konfiguracji Trivy**: blokuje HIGH/CRITICAL, wyjątki tylko w `.trivyignore.yaml` z uzasadnieniem i ograniczone do pliku.

### List. `.trivyignore.yaml` (fragment)

```yaml
- id: AWS-0104
  paths:
    - "ecs.tf"
  statement: Tasks run in public subnets without NAT Gateway or VPC endpoints (cost), so they need HTTPS egress to ECR and CloudWatch Logs public endpoints. Only port 443 is open.
```

- **GitHub**:
  - ruleset na `main`: tylko przez PR, wymagane checki `trivy` i `cost-gate`, blokada force push i usuwania,
  - środowisko `infra`: tylko gałąź `main`, jedyne źródło roli `gh-infra-apply`,
  - środowisko `infra-cost-approval`: wymagany reviewer,
  - akcje przypięte do pełnego SHA commita,
  - Dependabot (pip, docker, github-actions, terraform), co tydzień,
  - repo bez sekretów, zmienne tylko `AWS_ACCOUNT_ID`, `AWS_REGION`, `COST_THRESHOLD_USD`.

## 5. Wdrożenie aplikacji (pipeline)

### `app.yml`

- Wyzwalacze: push na `main` (zmiany w `app/`), PR (bez wdrożenia), ręcznie z wyborem `failure_mode`.
- Kroki: pytest -> build -> Trivy (CRITICAL kończy pipeline) -> SBOM CycloneDX (artefakt) -> [tylko main] OIDC -> push do ECR -> digest -> cosign sign (keyless) -> cosign attest SBOM -> `deploy.sh`.
- Tag obrazu: `<wersja>-<krótki sha>`, przy ręcznym uruchomieniu z dopiskiem `-<tryb>-<nr runu>` (tagi niezmienne, więc każdy build ma unikalny tag).
- Wdrożenie zawsze po digeście (`repo@sha256:...`), nie po tagu.

### List. Podpis i atestacja SBOM (`.github/workflows/app.yml`, fragment)

```yaml
- name: Sign image and attest SBOM (keyless)
  if: github.event_name != 'pull_request'
  env:
    IMAGE: ${{ steps.push.outputs.image }}
  run: |
    cosign sign --yes "$IMAGE"
    cosign attest --yes --type cyclonedx --predicate sbom.cdx.json "$IMAGE"
```

### List. Weryfikacja podpisu przed wdrożeniem (`.github/scripts/deploy.sh`, fragment)

```bash
if ! cosign verify "$IMAGE" \
  --certificate-identity "$CERT_IDENTITY" \
  --certificate-oidc-issuer "$OIDC_ISSUER" > /dev/null; then
  summary "REJECTED: no valid signature from $CERT_IDENTITY, service not updated"
  exit 1
fi
```

- `CERT_IDENTITY` = workflow `app.yml` na `main`: obraz podpisany z innej gałęzi lub innego workflow jest odrzucany.
- Brak natywnej weryfikacji podpisów w ECS, dlatego weryfikacja w pipeline tuż przed `update-service`.
- Dalej `deploy.sh`: nowa rewizja task definition z digestem, `update-service`, śledzenie `describe-service-deployments`, raport SUCCESS / STOPPED / ROLLBACK.
- Etapy blue/green w ECS: SCALE_UP -> TEST_TRAFFIC_SHIFT -> PRODUCTION_TRAFFIC_SHIFT -> BAKE_TIME (5 min, stara wersja dalej działa) -> CLEAN_UP.

### `infra.yml`

- PR: `plan` (fmt, validate, plan, plan.json, wycena kosztu, komentarz na PR), `trivy` (skan konfiguracji), `cost-gate`.
- Push na `main`: `apply` w środowisku `infra`.
- Wycena: własny skrypt `.github/scripts/cost.py`, ceny on-demand z AWS Price List API, tylko koszty stałe (Infracost odrzucony: darmowy klucz wygasa po 14 dniach).

### List. Wybór środowiska w `cost-gate` (`.github/workflows/infra.yml`)

```yaml
cost-gate:
  needs: plan
  runs-on: ubuntu-24.04
  environment: ${{ needs.plan.outputs.over_threshold == 'true' && 'infra-cost-approval' || 'infra-cost-ok' }}
```

## 6. Scenariusze

### 6.1 Poprawne wdrożenie (happy path)

- PR ze zmianą wersji, wycena kosztu +0.00, wszystkie checki zielone, merge.
- Pipeline: test, build, SBOM jako artefakt, push, podpis, wdrożenie.
- ECS: start green, przełączenie ruchu, bake time 5 min z alarmami OK, wyłączenie blue. Całość 7 min 41 s.
- ECR: obraz z niezmiennym tagiem + artefakty podpisu i atestacji (typ "Other"), skan przy push: 0 CRITICAL.
- Wynik: raport SUCCESS, zero błędów w `loadgen.sh`.

![PR scalony, komentarz z wyceną kosztu](screenshots/02-happy-path/01-pr-merged-cost-comment.png)
![Wszystkie checki zielone](screenshots/02-happy-path/02-pr-checks-passed.png)
![Pipeline app.yml i artefakt SBOM](screenshots/02-happy-path/03-app-pipeline-sbom-artifact.png)
![ECS: start zadań green](screenshots/02-happy-path/04-ecs-scale-up-green.png)
![ECS: przełączanie ruchu produkcyjnego](screenshots/02-happy-path/05-ecs-production-traffic-shift.png)
![ECS: bake time, alarmy OK](screenshots/02-happy-path/06-ecs-bake-time-alarms-ok.png)
![Target groupy blue i green w trakcie wdrożenia](screenshots/02-happy-path/07-ecs-blue-green-target-groups.png)
![ECR: obrazy, podpisy i atestacje](screenshots/02-happy-path/08-ecr-images-and-signatures.png)
![ECR: skan przy push](screenshots/02-happy-path/09-ecr-scan-on-push.png)
![ECS: wdrożenie zakończone](screenshots/02-happy-path/10-ecs-deployment-complete.png)
![Log deploy.sh: weryfikacja podpisu i SUCCESS](screenshots/02-happy-path/11-deploy-log-success.png)

### 6.2 Podatność CRITICAL

- PR dodaje `django==2.2` do `app/requirements.txt`.
- Trivy: 6 podatności CRITICAL (m.in. SQL injection), job `build` kończy się na kroku Trivy, obraz nie trafia do ECR.

![PR: build czerwony](screenshots/03-critical-cve/01-pr-build-failed.png)
![Trivy: 6 x CRITICAL w Django 2.2](screenshots/03-critical-cve/02-trivy-critical-django.png)

### 6.3 Security group otwarta na świat

- PR dodaje SG z portem 22 otwartym na `0.0.0.0/0`.
- `trivy config`: AWS-0107 (HIGH), check `trivy` wymagany, merge zablokowany.

![PR: trivy czerwony, merge zablokowany](screenshots/04-open-security-group/01-pr-trivy-failed-merge-blocked.png)
![Trivy: AWS-0107](screenshots/04-open-security-group/02-trivy-aws-0107.png)

### 6.4 Kosztowna zmiana (NAT Gateway)

- PR dodaje NAT Gateway + EIP.
- Wycena: 41.22 -> 82.83 USD/mies., +41.61 > próg 10, `cost-gate` czeka w `infra-cost-approval` na zatwierdzenie.

![Komentarz z wyceną kosztu](screenshots/05-cost-gate/01-pr-cost-comment.png)
![Zatwierdzenie w środowisku infra-cost-approval](screenshots/05-cost-gate/02-cost-approval.png)

### 6.5 Niepodpisany obraz i nadpisanie tagu

- `scripts/demo-unsigned.sh`: lokalny build, push do ECR z innym tagiem, próba wdrożenia tą samą ścieżką co pipeline (`deploy.sh`).
- `cosign verify` odrzuca obraz, usługa nie jest aktualizowana.
- Ponowny push pod ten sam tag: ECR odrzuca (`tag is immutable`).

![Wynik demo-unsigned.sh](screenshots/06-unsigned-image/01-demo-unsigned-output.png)

### 6.6 Nowa wersja nie przechodzi healthchecku

- Run workflow z `failure_mode = health`.
- Zadanie green nie przechodzi healthchecku ALB, ruch produkcyjny cały czas na blue.
- Circuit breaker: 3/3 nieudane zadania, wdrożenie wycofane, raport STOPPED.
- To nie jest rollback w sensie celu 3: nowa wersja nigdy nie dostała ruchu.

![ECS: zadanie green nie przechodzi healthchecku](screenshots/07-health-check/01-ecs-health-check-failed.png)
![ECS: circuit breaker, wycofanie](screenshots/07-health-check/02-ecs-circuit-breaker-rollback.png)
![Log deploy.sh: STOPPED](screenshots/07-health-check/03-deploy-log-stopped.png)

### 6.7 Rollback po alarmie w bake time

- Run workflow z `failure_mode = delayed`, w tle `loadgen.sh` (około 5 żądań/s).
- Nowa wersja `2.0.0-delayed` przejmuje ruch, alarm `target-5xx` przechodzi w ALARM, ECS przełącza ruch z powrotem, raport ROLLBACK.
- Wniosek: bez ruchu nie ma błędów, więc alarm nic nie wykryje (pierwsza próba bez `loadgen.sh` zakończyła się "udanym" wdrożeniem zepsutej wersji).

![loadgen.sh: błędy 500](screenshots/08-alarm-rollback/01-loadgen-errors.png)
![ECS: rollback z powodu alarmu](screenshots/08-alarm-rollback/02-ecs-rollback-alarm.png)
![CloudWatch: alarm 5xx w stanie ALARM](screenshots/08-alarm-rollback/03-cloudwatch-alarm-5xx.png)
![Log deploy.sh: ROLLBACK](screenshots/08-alarm-rollback/04-deploy-log-rollback.png)
![Podsumowanie loadgen.sh](screenshots/08-alarm-rollback/05-loadgen-summary.png)
![CSV z loadgen.sh: zmiana wersji i błędy](screenshots/08-alarm-rollback/06-loadgen-csv-version-change.png)
![CloudWatch: historia stanu alarmu 5xx (OK, ALARM, powrót do OK)](screenshots/08-alarm-rollback/07-cloudwatch-alarm-history.png)
