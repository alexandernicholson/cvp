CVP_SCRIPT := cvp.sh
PLUGIN     := plugin.sh
TEST_DIR   := test/bats
BATS       := bats

.PHONY: test test-verbose lint help install-bats

help:
	@echo "Targets:"
	@echo "  test          Run the bats test suite"
	@echo "  test-verbose  Run tests with verbose (tap) output"
	@echo "  lint          Syntax-check cvp.sh and plugin.sh"
	@echo "  install-bats  Install bats-core (via Homebrew or npm)"

test: _check-bats lint
	@echo ""
	@echo "Running cvp test suite..."
	@echo ""
	@$(BATS) $(TEST_DIR)/*.bats

test-verbose: _check-bats lint
	@$(BATS) --tap $(TEST_DIR)/*.bats

lint:
	@bash -n $(CVP_SCRIPT) && echo "✓ cvp.sh syntax OK"
	@bash -n $(PLUGIN)     && echo "✓ plugin.sh syntax OK"
	@bash -n install.sh    && echo "✓ install.sh syntax OK"

install-bats:
	@if command -v brew >/dev/null 2>&1; then \
		brew install bats-core; \
	elif command -v npm >/dev/null 2>&1; then \
		npm install -g bats; \
	else \
		echo "Install bats manually: https://github.com/bats-core/bats-core"; \
		exit 1; \
	fi

_check-bats:
	@command -v $(BATS) >/dev/null 2>&1 || { \
		echo "Error: bats not found. Install it with:"; \
		echo "  make install-bats"; \
		echo "  https://github.com/bats-core/bats-core"; \
		exit 1; \
	}
