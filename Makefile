.DEFAULT_GOAL := check
.PHONY: check lint test fmt e2e dry-run clean

SHELLS := deploy/*.sh deploy/remote/*.sh tests/*.sh

## check: everything CI runs that does not need Docker or a host
check: lint test

## lint: workflows, shell and Dockerfile
lint:
	actionlint
	shellcheck -x $(SHELLS)
	shfmt -i 4 -ci -d $(SHELLS)
	hadolint Dockerfile

## fmt: rewrite shell to canonical formatting
fmt:
	shfmt -i 4 -ci -w $(SHELLS)

## test: unit tests for the deployment logic — no SSH, no Docker, no AWS
test:
	bash tests/test_deploy_lib.sh

## dry-run: print a deployment plan without contacting anything
dry-run:
	./deploy/deploy.sh --host example.internal --tag sha-demo --repo owner/app --dry-run

## e2e: full deployment against a real host (CI runs this against the runner)
e2e:
	bash tests/e2e.sh

clean:
	rm -f ./actionlint
