# Prezentacja

## Włączenie

1. `cd terraform && terraform apply`
2. Actions, **app**, **Run workflow**, `failure_mode = none` (około 7-10 min).
3. Sprawdzić: `curl "$(terraform -chdir=terraform output -raw alb_url)/version"`

## Wyłączenie

1. Poczekać na koniec trwających wdrożeń.
2. `cd terraform && terraform destroy`
3. Nie scalać zmian w `terraform/`, dopóki środowisko jest wyłączone.

## Przygotowanie (dzień wcześniej)

Dla każdej gałęzi poniżej: utworzyć gałąź od aktualnego `main`, wprowadzić zmianę, zrobić commit i push.

**`demo/v1.1`:** w pliku `app/VERSION` zmienić `1.0.0` na `1.1.0`.

**`demo/critical-cve`:** w pliku `app/requirements.txt` dopisać na końcu linię `django==2.2` (6 podatności CRITICAL, job `build` zatrzyma się na Trivy).

**`demo/open-sg`:** w pliku `terraform/network.tf` dopisać na końcu (check `trivy` będzie czerwony):

```hcl
resource "aws_security_group" "ssh" {
  name        = "ecs-supply-chain-ssh"
  description = "SSH access"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.ssh.id
  description       = "SSH from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}
```

**`demo/nat-gateway`:** utworzyć plik `terraform/nat.tf` (koszt +41,61 USD/mies., `cost-gate` będzie czekał):

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "demo" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}
```

## Przebieg

Przez cały czas w osobnym terminalu:

```bash
scripts/loadgen.sh "$(terraform -chdir=terraform output -raw alb_url)"
```

1. **Poprawne wdrożenie:** otworzyć PR z `demo/v1.1` do `main`. Po zielonych checkach (około 3-4 min) scalić. W `loadgen.sh` wersja zmienia się z 1.0.0 na 1.1.0 bez błędów. W trakcie checków i wdrożenia pokazać punkty 2-4.
2. **Podatność CRITICAL:** otworzyć PR z `demo/critical-cve`. Po około 2 min job `build` zatrzymany na kroku Trivy, nic nie trafia do ECR. Zamknąć PR.
3. **Infrastruktura:**
   - otworzyć PR z `demo/open-sg`. Po około minucie czerwony check `trivy`, merge zablokowany. Zamknąć PR.
   - otworzyć PR z `demo/nat-gateway`. Po około 2 min komentarz z kosztem, `cost-gate` czeka. Zatwierdzić (Review deployments, Approve), nie scalać, zamknąć PR.
4. **Niepodpisany obraz:** `scripts/demo-unsigned.sh`. `cosign verify` odrzuca obraz, ECR odrzuca nadpisanie tagu.
5. **Healthcheck:** po zakończeniu wdrożenia 1.1.0 Run workflow, `failure_mode = health`. Nowa wersja nie dostaje ruchu, `loadgen.sh` bez błędów, raport: STOPPED.
6. **Rollback po alarmie:** Run workflow, `failure_mode = delayed`. Wersja `1.1.0-delayed` przejmuje ruch, po około 1,5 min błędy 500, alarm, powrót do 1.1.0. Raport: ROLLBACK. Pokazać alarm w CloudWatch i zakładkę Deployments w ECS.
7. Zatrzymać `loadgen.sh` (Ctrl+C) i pokazać podsumowanie.

Po prezentacji wyłączyć środowisko.
