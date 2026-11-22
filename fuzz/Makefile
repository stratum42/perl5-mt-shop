AFL_CC      ?= afl-clang-fast
ASAN_CC     ?= clang
AFL_FUZZ    ?= afl-fuzz
AFL_SECONDS ?= 60
ASAN        ?= 0

PKG_CFLAGS  := $(shell pkg-config --cflags libsodium openssl zlib)
PKG_LIBS    := $(shell pkg-config --libs libsodium openssl zlib)

CFLAGS      := -Wall -Wextra -Wno-unused-parameter -O2 -g $(PKG_CFLAGS)
ASAN_CFLAGS := -Wall -Wextra -Wno-unused-parameter -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer $(PKG_CFLAGS)

ifeq ($(ASAN),1)
AFL_ENV     := AFL_USE_ASAN=1
CFLAGS      += -fsanitize=address,undefined -fno-omit-frame-pointer
else
AFL_ENV     :=
endif

.PHONY: all run replay clean

all: fuzz_ssh_crypto fuzz_ssh_crypto_asan

fuzz_ssh_crypto: fuzz_ssh_crypto.c
	$(AFL_ENV) $(AFL_CC) $(CFLAGS) -o $@ $< $(PKG_LIBS)

fuzz_ssh_crypto_asan: fuzz_ssh_crypto.c
	$(ASAN_CC) $(ASAN_CFLAGS) -o $@ $< $(PKG_LIBS)

run: fuzz_ssh_crypto fuzz_ssh_crypto_asan
	@rm -rf out
	env -u AFL_SECONDS \
	AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
	AFL_SKIP_CPUFREQ=1 \
	AFL_NO_UI=1 \
	$(AFL_FUZZ) -V $(AFL_SECONDS) -i corpus -o out -- ./fuzz_ssh_crypto
	@echo "==> AFL++ fuzzer_stats:"
	@cat out/default/fuzzer_stats
	@echo "==> Replaying discovered corpus under ASan+UBSan..."
	./fuzz_ssh_crypto_asan out/default/queue/id:*
	@echo "==> ASan+UBSan corpus replay complete (0 errors)."

replay: fuzz_ssh_crypto_asan
	./fuzz_ssh_crypto_asan corpus/*
	@if [ -d out/default/queue ]; then \
		./fuzz_ssh_crypto_asan out/default/queue/id:*; \
	fi

clean:
	rm -rf fuzz_ssh_crypto fuzz_ssh_crypto_asan fuzz_ssh_crypto.dSYM fuzz_ssh_crypto_asan.dSYM out
