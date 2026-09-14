# flacz -- byte-exact lossless recompression of FLAC files.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11 -pedantic
LDFLAGS ?=
LDLIBS  ?= -lm

SRC := $(wildcard src/*.c)
OBJ := $(SRC:.c=.o)
BIN := flacz

.PHONY: all clean verify verify-stress speed
all: $(BIN)

$(BIN): $(OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJ) $(LDLIBS)

src/%.o: src/%.c $(wildcard src/*.h)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJ) $(BIN)

verify: $(BIN)
	@bench/run-natural.sh

verify-stress: $(BIN)
	@bench/run-stress.sh

speed: $(BIN)
	@bench/speed.sh
