CXX = clang++
DEPS_INSTALL_PATH = $(shell realpath ../boki_deps/release/)
BUILD_BASE_PATH = $(shell realpath ../boki_build)

DISABLE_STAT ?= 1
DEBUG_BUILD ?= 0
BUILD_BENCH ?= 0
FORCE_DCHECK ?= 0
