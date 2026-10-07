# OpenTelemetry Collector Reset Runbook

## Purpose

This runbook provides steps to reset the OpenTelemetry collector in case of issues with trace data not being exported correctly.

## Steps

1. **Check the collector pods**
   ```bash
   kubectl get pods -n monitoring -l app=otel-collector
   ```

2. **View the logs**
   ```bash
   kubectl logs -n monitoring -l app=otel-collector --tail=100
   ```

3. **Restart the collector**
   If the collector is not exporting traces, restart the deployment:
   ```bash
   kubectl rollout restart deployment/otel-collector -n monitoring
   ```

4. **Verify the restart**
   ```bash
   kubectl get pods -n monitoring -l app=otel-collector
   ```

5. **Check the Go service traces**
   Ensure that the Go service is configured to point to the collector endpoint:
   ```bash
   kubectl get deployment go-service -n dev -o yaml | grep OTEL_EXPORTER_OTLP_ENDPOINT
   ```

## Troubleshooting

- If the collector is not receiving traces, verify network policies and service connectivity.
- Ensure that the Go service's environment variable `OTEL_EXPORTER_OTLP_ENDPOINT` is set correctly.
- Check the collector's configuration for any errors in the receivers or exporters.

## References

- OpenTelemetry Collector documentation: https://opentelemetry.io/docs/collector/
- Helm chart for OpenTelemetry Collector: https://github.com/open-telemetry/opentelemetry-helm-charts