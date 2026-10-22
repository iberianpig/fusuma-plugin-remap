# Builds the standalone keyboard remapper binary.
#
#   1. cc -c src/shim/shim.c -o build/shim.o
#   2. spinel src/main.rb -o build/fusuma-remap-keyboard --link build/shim.o
#
# spinel links its runtime and the packages the program requires (strscan is
# one), so the build does not name libspinel_rt.a itself.

SPINEL_DIR ?= $(HOME)/ghq/github.com/matz/spinel
SPINEL     := $(SPINEL_DIR)/spinel

CC ?= cc

SRCS     := $(wildcard src/*.rb)
SHIM     := src/shim/shim.c
SHIM_OBJ := build/shim.o
BIN      := build/fusuma-remap-keyboard

GOLDEN_BIN := build/fusuma-remap-golden

all: $(BIN)

golden: $(GOLDEN_BIN)

$(SHIM_OBJ): $(SHIM) | build
	$(CC) -O2 -c -I$(SPINEL_DIR)/lib $(SHIM) -o $(SHIM_OBJ)

$(BIN): $(SRCS) $(SHIM_OBJ) | build
	$(SPINEL) src/main.rb -o $(BIN) --link $(SHIM_OBJ)

$(GOLDEN_BIN): $(SRCS) $(SHIM_OBJ) | build
	$(SPINEL) src/golden_runner.rb -o $(GOLDEN_BIN) --link $(SHIM_OBJ)

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all golden clean

fake-keyboard: build/fake_keyboard

build/fake_keyboard: tools/fake_keyboard.c | build
	$(CC) -O2 -Wall -Wextra $< -o $@

.PHONY: fake-keyboard
