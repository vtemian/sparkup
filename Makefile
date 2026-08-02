.DEFAULT_GOAL := help

# Sudo on the box. Default prompts once per run; override with `BECOME=` if you
# have passwordless sudo. No password ever belongs in this repo.
BECOME ?= -K
PLAYBOOK ?= site.yml
EXTRA ?=

.PHONY: help deps lint syntax ping check apply idempotence

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Install pinned collections
	ansible-galaxy collection install -r requirements.yml

lint: ## ansible-lint, production profile
	ansible-lint

syntax: ## Parse the playbook without contacting the host
	ansible-playbook $(PLAYBOOK) --syntax-check

ping: ## Confirm the host answers
	ansible spark -m ansible.builtin.ping

check: ## Dry run, showing the diff it would make
	ansible-playbook $(PLAYBOOK) $(BECOME) --check --diff $(EXTRA)

apply: ## Converge the box
	ansible-playbook $(PLAYBOOK) $(BECOME) $(EXTRA)

idempotence: ## Converge, then prove a second run changes nothing
	ansible-playbook $(PLAYBOOK) $(BECOME) $(EXTRA)
	ansible-playbook $(PLAYBOOK) $(BECOME) $(EXTRA) | tee /tmp/sparkup-second-run.log
	@grep -qE 'changed=0 ' /tmp/sparkup-second-run.log \
		&& echo "IDEMPOTENT: second run reported changed=0" \
		|| { echo "NOT IDEMPOTENT: second run changed something"; exit 1; }

# Everything below runs without a Spark. Docker is the only requirement.
.PHONY: offline dashboard roles-test harness-up harness-down

offline: lint syntax dashboard roles-test ## Every check that needs no Spark

dashboard: ## Parse every panel query and check it names a metric we emit
	python3 tests/check_dashboard.py

roles-test: ## Converge base and users in containers twice, expect changed=0
	./tests/role-idempotence.sh

harness-up: ## Grafana + Prometheus locally on :13000, fed synthetic metrics
	./tests/harness-up.sh

harness-down: ## Remove the local harness, containers and volumes
	./tests/harness-down.sh
