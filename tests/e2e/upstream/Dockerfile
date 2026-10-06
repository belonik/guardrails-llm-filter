# Mock LLM upstream for the verification stand (deploy/compose).
#
# Two jobs, both needed by test-fixes.sh:
#   1. CAPTURE — append every request body the gateway forwarded (i.e. what the
#      model actually receives, post-masking) to $CAPTURE_FILE as JSONL, keyed
#      by the X-Test-Id header. This is the oracle for "did the PII leak".
#   2. ECHO — reflect the received text back verbatim in the right wire format,
#      so the client must get the ORIGINAL back through the demask path.
#
#   docker build -t guardrails-mock-llm tests/e2e/upstream
FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/e2e-upstream .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/e2e-upstream /e2e-upstream
ENV LISTEN_ADDR=:8890 \
    CAPTURE_FILE=/capture/requests.jsonl
EXPOSE 8890
ENTRYPOINT ["/e2e-upstream"]
