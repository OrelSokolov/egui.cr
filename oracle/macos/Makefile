# Build + run the macOS widget oracle renderer (see render.swift).
# Output: png/<sheet>.png — 480x160 flat sheets, light aqua.

SWIFTC ?= swiftc

all: run

render: render.swift
	$(SWIFTC) -O -parse-as-library -o render render.swift

run: render
	./render

clean:
	rm -f render
	rm -rf png

.PHONY: all run clean
