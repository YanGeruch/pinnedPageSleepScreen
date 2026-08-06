# Cross-compiled from macOS with zig cc (device: aarch64, glibc 2.39)
XOVI_REPO ?= ../../research/xovi
name = fastshot
VERSION ?= 0.1.0

CC = zig cc -target aarch64-linux-gnu.2.36
CFLAGS = -D_GNU_SOURCE -fPIC -O2 -fno-sanitize=undefined -DVERSION=\"$(VERSION)\"

BUILD = build

all: $(name).so

$(BUILD)/xovi.c: $(name).xovi
	@mkdir -p $(BUILD)
	python3 $(XOVI_REPO)/util/xovigen.py -a aarch64 -o $(BUILD)/xovi.c -H $(BUILD)/xovi.h $(name).xovi

$(name).so: src/$(name).c $(BUILD)/xovi.c
	$(CC) $(CFLAGS) -I$(BUILD) -shared -o $@ src/$(name).c $(BUILD)/xovi.c

clean:
	rm -rf $(BUILD) $(name).so

.PHONY: all clean
