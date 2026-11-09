# Build + run the KDE widget oracle renderer (see render.cpp).
# Output: png/<sheet>.png — 480x160 flat sheets, light Breeze.

CXX ?= g++
PKGS := Qt6Widgets

all: run

render: render.cpp
	$(CXX) -O2 -std=c++17 -fPIC -o render render.cpp $$(pkg-config --cflags --libs $(PKGS))

run: render
	./render

clean:
	rm -f render
	rm -rf png

.PHONY: all run clean
