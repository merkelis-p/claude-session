# tui/Makefile — the Go half of claude-session.
#
# One authoritative version: it is read out of ../bin/claude-session, never
# duplicated here. Same for the JSON schema version — the bash side owns both,
# and a Go binary that disagreed with the bash it talks to is exactly the skew
# this avoids.
#
# `build` and `release` target ./cmd/claude-session-tui, which does not exist
# yet (it arrives with the app shell). Until then `make test`, `make vet` and
# `make fmt` are the useful targets; the build targets are already correct and
# start working the moment that package lands.
V := $(shell grep -E '^VERSION=' ../bin/claude-session | head -1 | cut -d'"' -f2)
SCHEMA := $(shell grep -E '^JSON_SCHEMA_VERSION=' ../bin/claude-session | head -1 | cut -d= -f2)
LDFLAGS := -s -w -X main.version=$(V) -X main.schemaMin=$(SCHEMA) -X main.schemaMax=$(SCHEMA)
GOFLAGS := -trimpath

# CGO_ENABLED=0 and -trimpath are what make the binary genuinely static and the
# build reproducible; both are load-bearing for the release workflow's
# native-runner smoke test. Do not drop either.
#
# Scoped to the build targets ON PURPOSE, not exported Makefile-wide: the race
# detector is implemented in C, so `go test -race` fails outright under
# CGO_ENABLED=0 ("-race requires cgo"). A file-level export here made `make
# test` impossible to run.
build release: export CGO_ENABLED = 0

.PHONY: build release test vet fmt clean
build:   ; go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o dist/$(shell go env GOOS)-$(shell go env GOARCH)/claude-session-tui ./cmd/claude-session-tui
release: ; @for t in linux/amd64 darwin/arm64 linux/arm64; do \
	   os=$${t%/*}; arch=$${t#*/}; \
	   GOOS=$$os GOARCH=$$arch go build $(GOFLAGS) -ldflags "$(LDFLAGS)" \
	     -o dist/$$os-$$arch/claude-session-tui ./cmd/claude-session-tui || exit 1; done; \
	 cd dist && find . -name claude-session-tui -type f | sort | xargs shasum -a 256 > SHA256SUMS
test:    ; go vet ./... && go test -race ./...
vet:     ; go vet ./...
fmt:     ; gofmt -l -w .
clean:   ; rm -rf dist
