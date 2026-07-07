# Builds the standalone keyboard remapper binary.
#
# The shape mirrors fusuma-plugin-libinput/native:
#   1. spinel src/main.rb -c -o build/main.c
#   2. cc build/main.c src/shim/shim.c ... libspinel_rt.a ... -o build/fusuma-remap-keyboard

SPINEL_DIR ?= $(HOME)/ghq/github.com/matz/spinel
SPINEL     := $(SPINEL_DIR)/spinel
SP_RT_LIB  := $(wildcard $(SPINEL_DIR)/lib/libspinel_rt.a)

CC ?= cc

SRCS  := $(wildcard src/*.rb)
SHIM  := src/shim/shim.c
GEN_C := build/main.c
BIN   := build/fusuma-remap-keyboard

GOLDEN_GEN_C := build/golden_runner.c
GOLDEN_BIN   := build/fusuma-remap-golden

all: $(BIN)

golden: $(GOLDEN_BIN)

$(GEN_C): $(SRCS) | build
	$(SPINEL) src/main.rb -c -o $(GEN_C)

$(BIN): $(GEN_C) $(SHIM) | build
	$(CC) -O2 -Wno-all -ffunction-sections -fdata-sections \
	  -I$(SPINEL_DIR)/lib -I$(SPINEL_DIR)/lib/regexp \
	  $(GEN_C) $(SHIM) $(SP_RT_LIB) -lm \
	  -Wl,--gc-sections -o $(BIN)

$(GOLDEN_GEN_C): $(SRCS) | build
	$(SPINEL) src/golden_runner.rb -c -o $(GOLDEN_GEN_C)

$(GOLDEN_BIN): $(GOLDEN_GEN_C) $(SHIM) | build
	$(CC) -O2 -Wno-all -ffunction-sections -fdata-sections \
	  -I$(SPINEL_DIR)/lib -I$(SPINEL_DIR)/lib/regexp \
	  $(GOLDEN_GEN_C) $(SHIM) $(SP_RT_LIB) -lm \
	  -Wl,--gc-sections -o $(GOLDEN_BIN)

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all golden clean

fake-keyboard: build/fake_keyboard

build/fake_keyboard: tools/fake_keyboard.c | build
	$(CC) -O2 -Wall -Wextra $< -o $@

.PHONY: fake-keyboard
