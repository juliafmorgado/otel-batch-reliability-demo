# OpenTelemetry Batch Reliability Demo

This repository demonstrates the critical reliability differences between the OpenTelemetry Collector's batch processor and exporter helper batching approaches. Through controlled crash scenarios, we prove why the OpenTelemetry community is [moving away from the batch processor](https://github.com/open-telemetry/opentelemetry-demo/pull/2734).

## Background

This demo validates the reliability improvements described in [OpenTelemetry Collector Issue #8122](https://github.com/open-telemetry/opentelemetry-collector/issues/8122) -> the official tracking issue for introducing exporter helper batching and deprecating the batch processor.

From the OpenTelemetry maintainers: *"The primary reason for introducing the new exporter helper is to move the batching to the exporter side and deprecate the batch processor as part of making the delivery pipeline reliable."*

### Current Status (January 2025)
- **Batch processor**: Still available but **not recommended** for production
- **Exporter helper**: **Stable and production-ready** with persistent storage
- **Community direction**: Active migration toward exporter-level batching

## What This Demo Proves
Our crash tests provide empirical evidence for the reliability claims in the official issue, demonstrating the exact architectural shift the OpenTelemetry community is implementing.

**Key Finding**: When an OpenTelemetry Collector crashes ungracefully (SIGKILL):
- **Batch Processor**: 100% data loss (0 traces recovered)
- **Exporter Helper**: 0% data loss (100% traces recovered)

**Important Scope Notes:**
- This demo focuses on **traces** for simplicity (same behavior applies to metrics and logs)
- Crash scenario uses **SIGKILL** (ungraceful termination) which mimics:
  - Kubernetes pod eviction without grace period
  - OOM killer termination
  - Hardware failure / power loss
  - Force kill operations

The demo consists of:
- **Two Collector configurations**: One using batch processor, one using exporter helper with persistent storage
- **Jaeger backend**: For visualizing recovered traces
- **Automated test script**: Simulates crash scenarios and measures data recovery
- **telemetrygen**: Generates test telemetry data

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────┐
│   telemetrygen  │───▶│  OTel Collector  │───▶│   Jaeger    │
│  (100 traces)   │    │  (crash test)    │    │ (recovery)  │
└─────────────────┘    └──────────────────┘    └─────────────┘
```

## Quick Start

### Prerequisites
- Docker and Docker Compose
- `telemetrygen` (install via `go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest`)

### Running the Batch Processor Test (Data Loss)

```bash
./run_test.sh batch-processor
```

**What happens:**
1. Sends 100 traces to Collector
2. Waits for spans to be accepted (2s)
3. Crashes Collector with SIGKILL (ungraceful)
4. Verifies 0 traces in Jaeger
5. Restarts Collector
6. Still 0 traces → **100% data loss confirmed**

### Running the Exporter Helper Test (Data Recovery)

```bash
./run_test.sh exporter-helper
```

**What happens:**
1. Sends 100 traces to Collector
2. Waits for spans to be accepted (2s)
3. Crashes Collector with SIGKILL (ungraceful)
4. Verifies 0 traces in Jaeger (not yet exported)
5. Restarts Collector
6. All 100 traces appear → **0% data loss confirmed**

### Running Reproducibility Test

Prove the results are consistent:

```bash
ITERATIONS=5 ./run_test.sh reproducibility
```

**Expected:** 100% success rate for both tests across all iterations

## Test Results Summary

| Approach | Data Sent | Collector Crashed | Data Recovered | Data Loss |
|----------|-----------|-------------------|----------------|-----------|
| Batch Processor | 100 traces | After 5s | 0 traces | **100%** |
| Exporter Helper | 100 traces | After 5s | 100 traces | **0%** |

## 🔧 Configuration Comparison

### Batch Processor (Vulnerable to Data Loss)
```yaml
# batch-processor/otelcol-config.yaml
processors:
  batch:
    timeout: 60s          # Data vulnerable in memory longer
    send_batch_size: 1000 # Larger batch size

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]  # In-memory only - data lost on crash
      exporters: [otlp]
```

### Exporter Helper (Crash-Proof)
```yaml
# exporter-helper/otelcol-config.yaml
extensions:
  file_storage:
    directory: /tmp/otel-storage

exporters:
  otlp:
    endpoint: http://jaeger:4317
    sending_queue:
      enabled: true
      storage: file_storage    # Persistent storage - survives crashes
      queue_size: 1000
      num_consumers: 5

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: []           # No batch processor needed
      exporters: [otlp]
```

## How the Test Works

The automated test script (`run_test.sh`) performs these steps:

1. **Clean Environment**: Removes any existing storage and containers
2. **Start Services**: Launches Collector and Jaeger
3. **Send Data**: Uses `telemetrygen` to send 100 traces
4. **Wait for Acceptance**: 2 seconds to ensure spans are received by Collector
5. **Verify Acceptance**: Check logs and storage files
6. **Simulate Crash**: Forcefully kills Collector with SIGKILL (ungraceful)
7. **Verify Loss**: Confirms no traces visible in Jaeger
8. **Test Recovery**: Restarts Collector and measures data recovery

**Critical timing:**
- Crash happens at ~3 seconds after sending
- Batch timeout is 300 seconds (5 minutes)
- Batch size is 10,000 spans (100 traces won't trigger)
- This ensures data is accepted but NOT yet exported when crash occurs


## Understanding the Results

### Why Batch Processor Loses Data

1. **In-Memory Queues**: Uses Go channels with no persistence
2. **Early Success Response**: Client gets success before data is exported
3. **Crash Vulnerability**: Process termination = immediate data loss
4. **No Recovery Mechanism**: Cannot restore data after restart

### Why Exporter Helper Preserves Data

1. **Persistent Storage**: Write-ahead log survives crashes
2. **Unified Queue**: Single queue handles batching and persistence
3. **Automatic Recovery**: Restores queued data on startup
4. **Guaranteed Delivery**: Data persisted before success response

## Production Implications

**Critical Takeaway**: In production environments, using batch processor without understanding its limitations can result in:
- Silent data loss during deployments
- Missing traces during incident response  
- Incomplete observability during critical moments
- Compliance issues in regulated industries


The demo validates the technical benefits outlined in the official design document:
- Ability to place failed requests back into the queue without OTLP format conversion
- Enhanced control in counting queue and batch sizes using exporter-specific data models  
- Optional counting of queue and batch sizes in bytes of serialized data

## External Resources
- [OpenTelemetry Collector Documentation](https://opentelemetry.io/docs/collector/)
- [Exporter Helper Documentation](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md)
- [Batch Processor Documentation](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md)
- [Issue #8122: Deprecate Batch Processor](https://github.com/open-telemetry/opentelemetry-collector/issues/8122)

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
