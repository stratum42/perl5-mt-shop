PERL5_MT_ROOT       ?= $(abspath $(CURDIR)/../perl5-mt)
MOJOLICIOUS_MT_ROOT ?= $(abspath $(CURDIR)/../mojolicious-mt)
PERL                ?= $(shell command -v perl5-mt 2>/dev/null || echo $(PERL5_MT_ROOT)/perl)
PERL_LIB            ?= $(PERL5_MT_ROOT)/lib
SHOP_LIB            := $(CURDIR)/lib
XS_DIR              := $(CURDIR)/xs/Shop-SSH-Crypto
XS_BLIB             := $(XS_DIR)/blib/lib:$(XS_DIR)/blib/arch
HOSTKEY             := $(CURDIR)/config/host_ed25519_key

MOJO_FLAGS := $(if $(wildcard $(MOJOLICIOUS_MT_ROOT)/lib),-I$(MOJOLICIOUS_MT_ROOT)/lib -I$(MOJOLICIOUS_MT_ROOT)/xs/blib/lib -I$(MOJOLICIOUS_MT_ROOT)/xs/blib/arch,)
MOJO_KEYDB_FLAGS := $(if $(wildcard $(MOJOLICIOUS_MT_ROOT)/xs-keydb/blib/lib),-I$(MOJOLICIOUS_MT_ROOT)/xs-keydb/blib/lib -I$(MOJOLICIOUS_MT_ROOT)/xs-keydb/blib/arch,)

PERL_FLAGS := -I$(PERL_LIB) -I$(XS_DIR)/blib/arch -I$(XS_DIR)/blib/lib -I$(SHOP_LIB) $(MOJO_FLAGS) $(MOJO_KEYDB_FLAGS)

.PHONY: all crypto hostkey docker-up docker-down init-db2 init-informix test fuzz bench run clean

all: crypto hostkey

crypto:
	@echo "==> Building Tier-1 thread-safe XS crypto + zlib extension..."
	cd $(XS_DIR) && PERL5LIB=$(PERL_LIB) $(PERL) -I$(PERL_LIB) Makefile.PL && PERL5LIB=$(PERL_LIB) $(MAKE)

hostkey:
	@mkdir -p $(CURDIR)/config $(CURDIR)/var
	@if [ ! -f "$(HOSTKEY)" ]; then \
		echo "==> Generating Ed25519 SSH host key at $(HOSTKEY)..."; \
		ssh-keygen -t ed25519 -N "" -f "$(HOSTKEY)" -C "perl5-mt-shop"; \
	else \
		echo "==> Host key already exists at $(HOSTKEY)"; \
	fi

docker-up:
	@echo "==> Starting IBM Db2 Community Edition + db2-gateway + KeyDB..."
	docker compose -f docker/docker-compose.yml up -d

docker-down:
	@echo "==> Stopping Docker services..."
	docker compose -f docker/docker-compose.yml down

init-db2:
	@echo "==> Waiting for db2-gateway and initializing IBM Db2 schema + seed data..."
	./docker/init-db2.sh

init-informix:
	@echo "==> Waiting for informix-gateway and initializing IBM Informix schema, SPL procedures & seed data..."
	./docker/init-informix.sh

test: crypto hostkey
	@echo "==> Running perl5-mt-shop test suite..."
	@for t in t/*.t; do \
		echo "--- $$t ---"; \
		$(PERL) $(PERL_FLAGS) "$$t" || exit 1; \
	done
	@echo "==> All tests passed!"

fuzz: crypto hostkey
	@echo "==> Running extended SSH/Crypto/Wire/TUI/JSON fuzz suite (FUZZ_ITERS=$${FUZZ_ITERS:-100000})..."
	FUZZ_ITERS=$${FUZZ_ITERS:-100000} $(PERL) $(PERL_FLAGS) t/15_ssh_fuzz.t

bench: crypto hostkey
	@echo "==> Running perl5-mt-shop performance & egress benchmark..."
	$(PERL) $(PERL_FLAGS) bin/bench-egress-and-perf

run: crypto hostkey
	@mkdir -p $(CURDIR)/var
	$(PERL) $(PERL_FLAGS) bin/shop-server --config config/shop.json

clean:
	@if [ -f $(XS_DIR)/Makefile ]; then cd $(XS_DIR) && $(MAKE) realclean; fi
	@rm -rf $(CURDIR)/var/*.mtck $(CURDIR)/var/*.db
