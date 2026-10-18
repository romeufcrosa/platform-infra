# ADR 002: Minikube Single-Cluster Development

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need a local development Kubernetes environment. Options:
1. **Minikube** - Single-node Kubernetes in VM
2. **Kind** - Kubernetes in Docker
3. **k3d** - Lightweight k3s in Docker
4. **Docker Desktop Kubernetes** - Built-in single-node cluster
5. **Remote dev cluster** - Shared cluster in cloud

## Decision

We will use **Minikube** as the primary local development environment.

### Configuration
- Driver: Docker (default on Linux/macOS), Hyperkit (macOS alternative)
- Resources: 4 CPUs, 8GB RAM, 50GB disk
- Addons: ingress, metrics-server, registry, storage-provisioner
- Kubernetes version: 1.28.x (matching production)

## Consequences

### Positive
- **Full Kubernetes compatibility** - Real kubelet, API server, controller manager
- **Multi-node simulation** - Can simulate multi-node with `minikube start --nodes=2`
- **Addon ecosystem** - Built-in ingress, registry, metrics-server
- **Cross-platform** - Works on Linux, macOS, Windows
- **Production parity** - Closest to real cluster behavior

### Negative
- **Resource heavy** - Requires 8GB+ RAM, VM overhead
- **Slower startup** - VM boot + cluster init (~2-3 minutes)
- **Single-node by default** - Limited HA testing
- **Network complexity** - VM networking requires tunnel/port-forward for access

### Mitigation
- Provide `make cluster-up` script for one-command setup
- Document resource requirements clearly
- Use `minikube tunnel` for LoadBalancer services
- CI uses GitHub Actions with Kind for faster ephemeral clusters

## Related
- ADR 003: Ministack for Local AWS Services