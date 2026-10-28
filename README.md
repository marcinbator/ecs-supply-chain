# ecs-supply-chain

Projekt BRCh: bezpieczny supply chain dla aplikacji kontenerowej na AWS. Aplikacja FastAPI jest budowana, skanowana (Trivy), opisywana SBOM-em, podpisywana (Cosign keyless) i wdrażana po digeście na ECS Fargate w strategii blue/green z bake time 5 minut i rollbackiem na alarmach CloudWatch. Zmiany infrastruktury przechodzą przez PR ze skanem Trivy i wyceną kosztu planu z progiem wymagającym ręcznej akceptacji.

Opis architektury i diagramy: [docs/architecture.md](docs/architecture.md).

## Struktura

```text
app/                  aplikacja, testy, Dockerfile, VERSION
terraform/            cała infrastruktura (jeden root module, backend S3)
.github/workflows/    app.yml (aplikacja), infra.yml (infrastruktura)
.github/dependabot.yml
.trivyignore.yaml     uzasadnione wyjątki skanu konfiguracji
scripts/              deploy.sh (weryfikacja podpisu + wdrożenie), skrypty demo
docs/                 architektura, opis projektu
```

## Wymagania

- konto AWS z użytkownikiem/rolą z uprawnieniami administratora (tylko do pierwszego `terraform apply`),
- AWS CLI v2, Terraform >= 1.10, Docker, `jq`, `curl`,
- `gh` (GitHub CLI) i `cosign` do skryptów demo,
- repozytorium na GitHubie (publiczne albo z planem, który obsługuje wymaganych reviewerów w środowiskach),

## Uruchomienie

### 1. AWS: bucket S3 na stan Terraform (konsola)

1. S3, **Create bucket**.
2. Region `eu-central-1`, Bucket type: General purpose, namespace: account regional, nazwa `ecs-supply-chain-state` (pełna nazwa: `ecs-supply-chain-state-<account-id>-eu-central-1-an`, taka jak w `terraform/backend.tf`).
3. Object Ownership: ACLs disabled (domyślne).
4. **Block all public access**: zaznaczone (domyślne).
5. Bucket Versioning: **Enable**.
6. Default encryption: SSE-S3 (domyślne), Bucket Key: Enable.
7. **Create bucket**.

Blokada stanu używa natywnego mechanizmu S3 (`use_lockfile = true`), tabela DynamoDB nie jest potrzebna.

### 2. AWS: provider OIDC dla GitHub Actions (konsola)

Provider jest jeden na całe konto, więc jeśli już istnieje (IAM, Identity providers, `token.actions.githubusercontent.com`), pomiń ten krok.

1. IAM, **Identity providers**, **Add provider**.
2. Provider type: **OpenID Connect**.
3. Provider URL: `https://token.actions.githubusercontent.com`.
4. Audience: `sts.amazonaws.com`.
5. **Add provider**.

Role `gh-plan`, `gh-infra-apply` i `gh-app-deploy` tworzy Terraform.

### 3. Pierwszy `terraform apply` (lokalnie)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# uzupełnij github_oidc_repo (opis niżej)
terraform init
terraform plan
terraform apply
```

`github_oidc_repo` to repozytorium w formacie z claimu `sub` tokenu OIDC: `owner@<owner-id>/repo@<repo-id>`. Repozytoria utworzone po 15.07.2026 mają w tym claimie niezmienne ID właściciela i repo zamiast samych nazw, więc rola z warunkiem `repo:owner/repo:...` nie zadziała. ID można odczytać tak:

```bash
curl -s https://api.github.com/repos/<owner>/<repo> | jq '.owner.id, .id'
```

W CI ta sama wartość jest składana z kontekstu `github` w `infra.yml`.

Apply tworzy całą infrastrukturę. Usługa ECS startuje z `desired_count = 0` i obrazem zastępczym, bo w ECR nie ma jeszcze żadnego podpisanego obrazu. Pierwsze wdrożenie z pipeline'u ustawia obraz po digeście i skaluje usługę do 1 zadania.

Zapisz output `alb_url` (`terraform output`).

### 4. GitHub: zmienne i sekrety

Settings, Secrets and variables, Actions.

Zakładka **Variables**:

| Nazwa | Wartość |
|---|---|
| `AWS_ACCOUNT_ID` | ID konta AWS (12 cyfr) |
| `AWS_REGION` | `eu-central-1` |
| `COST_THRESHOLD_USD` | `10` |

Sekrety nie są potrzebne.

ARN-y ról są składane w workflow z `AWS_ACCOUNT_ID` i stałych nazw ról. Jedynym miejscem z ID konta w repozytorium jest nazwa bucketu w `terraform/backend.tf`.

### 5. GitHub: środowiska

Settings, Environments, **New environment**:

1. `infra`: Deployment branches and tags, **Selected branches and tags**, dodaj `main`. Bez reviewerów. Z tego środowiska korzysta tylko `terraform apply`, a rola `gh-infra-apply` ufa wyłącznie tokenom z tego środowiska.
2. `infra-cost-approval`: zaznacz **Required reviewers** i dodaj siebie (albo osobę z zespołu). Odznacz "Prevent self-review", jeśli zatwierdzasz sam. Bez ograniczenia gałęzi, bo job `cost-gate` działa na PR.

Środowisko `infra-cost-ok` (PR poniżej progu) GitHub utworzy sam przy pierwszym użyciu.

### 6. GitHub: branch protection dla `main`

Settings, Branches, **Add branch ruleset** (albo classic rule):

1. Target: `main` (Include default branch).
2. **Require a pull request before merging**.
3. **Require status checks to pass**, dodaj `trivy` i `cost-gate` (opcjonalnie też `plan` i `test`). Checki pojawiają się na liście po pierwszym uruchomieniu workflow na PR.
4. **Block force pushes**.

### 7. Pierwsze wdrożenie aplikacji

Push na `main` ze zmianą w `app/` albo Actions, **app**, **Run workflow** (`failure_mode = none`). Pipeline: testy, build, Trivy, SBOM, push do ECR, podpis Cosign, atestacja SBOM, weryfikacja podpisu, nowa rewizja task definition z `repo@sha256:...`, `update-service`, czekanie na koniec wdrożenia z bake time.

Pierwsze wdrożenie trwa około 7-10 minut (bake time 5 minut). Potem aplikacja jest pod `alb_url`.

## Dobór alarmów a bake time

Oba alarmy (`HTTPCode_Target_5XX_Count` i `TargetResponseTime` na poziomie ALB) mają okres 60 s i próg "2 z 3 punktów danych". ALB publikuje metryki co minutę z opóźnieniem około 1 minuty, więc alarm przechodzi w stan ALARM po około 3 minutach od pojawienia się błędów.

Scenariusz `delayed`: zadania nowej wersji zaczynają zwracać 500 po 90 s od startu (`FAILURE_DELAY_SECONDS`). Od startu kontenera do przełączenia ruchu mija około 1 minuty (healthchecki i etapy wdrożenia), więc błędy pojawiają się około pół minuty po przełączeniu, a alarm około 3-3,5 minuty po przełączeniu. To mieści się w bake time 5 minut z zapasem około 1,5-2 minut, więc rollback następuje, gdy stara wersja nadal działa.

Uwaga: po rollbacku alarm wraca do stanu OK dopiero po kilku minutach bez błędów. Kolejne wdrożenie warto uruchamiać, gdy alarmy są w stanie OK.

## Scenariusze demo

Generator ruchu (w osobnym terminalu, przez cały czas demonstracji):

```bash
scripts/loadgen.sh "$(terraform -chdir=terraform output -raw alb_url)"
# Ctrl+C kończy i wypisuje podsumowanie: żądania, błędy, przedziały błędów, zmiany wersji
```

| Scenariusz | Jak uruchomić | Oczekiwany wynik |
|---|---|---|
| Poprawne wdrożenie | zmień `app/VERSION` z `1.0.0` na `1.1.0`, PR, merge | zero błędów w `loadgen.sh`, `/version` zmienia się z 1.0.0 na 1.1.0 |
| Obraz nie przechodzi `/health` | Actions, **app**, **Run workflow**, `failure_mode = health` | nowa wersja nie dostaje ruchu, wdrożenie zatrzymane przez circuit breaker, raport "STOPPED" |
| Błędy po wdrożeniu | Actions, **app**, **Run workflow**, `failure_mode = delayed` | nowa wersja przejmuje ruch, po kilku minutach alarm, ECS przełącza ruch na poprzednią wersję, raport "ROLLBACK" |
| Podatność CRITICAL | PR, w którym `app/requirements.txt` dostaje pakiet ze znaną krytyczną podatnością, albo `FROM` ze starym obrazem bazowym | job `build` kończy się na kroku Trivy, nic nie trafia do ECR |
| Niepodpisany obraz i nadpisanie tagu | `scripts/demo-unsigned.sh` (lokalne poświadczenia AWS) | `cosign verify` odrzuca obraz, usługa nie jest aktualizowana, push na istniejący tag odrzucony przez ECR |
| PR z publicznym bucketem lub SG otwartą na 0.0.0.0/0 na porcie innym niż 80/443 | PR z takim zasobem w `terraform/` | check `trivy` czerwony, merge zablokowany |
| PR z NAT Gateway | gałąź `demo/nat-gateway`, opis niżej | komentarz z wyceną na PR, `cost-gate` czeka na zatwierdzenie w `infra-cost-approval` |

### Gałąź `demo/nat-gateway`

Utwórz gałąź z `main` i dodaj plik `terraform/nat.tf`:

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "demo" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}
```

Otwórz PR i nie scalaj go. NAT Gateway w `eu-central-1` to około 42 USD miesięcznie (godziny NAT i adres IPv4), więc przekracza próg 10 USD.

## Wycena kosztu w PR

Job `plan` zapisuje plan jako JSON, a [scripts/cost.py](scripts/cost.py) liczy z niego miesięczny koszt przed zmianą i po niej oraz różnicę. Wynik trafia jako komentarz na PR i do podsumowania joba, a `cost-gate` porównuje różnicę z `COST_THRESHOLD_USD`. Plan jest liczony względem aktualnego stanu, czyli tego, co jest wdrożone z `main`.

Skrypt nie potrzebuje konta ani klucza zewnętrznej usługi. Ceny on-demand dla `eu-central-1` są stałymi w skrypcie, pobranymi z publicznego AWS Price List API (październik 2026). Wyceniane są koszty stałe: ALB, NAT Gateway, publiczne IPv4, interface VPC endpointy, zadania Fargate (1 zadanie na task definition) i alarmy CloudWatch. Koszty zależne od ruchu (LCU, transfer, logi) są pominięte.

Lokalnie:

```bash
cd terraform
terraform plan -out=tfplan && terraform show -json tfplan > plan.json
python3 ../scripts/cost.py plan.json
```

## Koszt środowiska

Szacunek dla `eu-central-1` przy 1 zadaniu, bez ruchu (ceny z AWS Price List API, te same co w `scripts/cost.py`):

| Zasób | USD/h | USD/miesiąc (730 h) |
|---|---|---|
| ALB (godziny + minimum LCU) | ~0.035 | ~25 |
| Fargate 0.25 vCPU / 0.5 GB | ~0.014 | ~10 |
| Publiczne IPv4 (2 ALB + 1 zadanie) | 0.015 | ~11 |
| CloudWatch (Container Insights, alarmy, logi) | grosze | ~1-3 |
| ECR, S3 | grosze | <1 |
| **Razem** | **~0.065** | **~47** |

Podczas wdrożenia blue/green przez około 7-10 minut działają dwa zadania. Środowisko warto usuwać po demonstracji.

## Sprzątanie

```bash
cd terraform
terraform destroy
```

ECR ma `force_delete = true`, więc obrazy znikają razem z repozytorium. Ręcznie (konsola) zostaje:

1. bucket stanu: S3, bucket, **Empty** (usuwa też wersje), potem **Delete**,
2. provider OIDC: IAM, Identity providers, `token.actions.githubusercontent.com`, **Delete** (tylko jeśli nie używa go nic innego).
