# ADR 002: SQS Event Publishing

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to implement event-driven communication between services. The Go Orders service needs to publish events when orders are created/updated. Options:
1. **Direct HTTP calls** - Synchronous, tight coupling
2. **Message queue (SQS)** - Asynchronous, decoupled
3. **Event streaming (Kafka/Redpanda)** - High throughput, complex
4. **gRPC streaming** - Bidirectional, but synchronous
5. **Database polling** - Simple, but latency and coupling

## Decision

We will use **AWS SQS (via Ministack locally)** for event publishing from the Go Orders service.

### Event Flow
```
Order Created → Publish to SQS (order-events) → 
  Node Service consumes → Creates notification → 
  Frontend receives via WebSocket
```

### Event Structure
```json
{
  "event_id": "uuid",
  "event_type": "order.created",
  "timestamp": "2026-01-15T10:30:00Z",
  "service": "go-service",
  "payload": {
    "order_id": "ord_123",
    "customer_email": "user@example.com",
    "total": 99.99,
    "items": [...]
  }
}
```

### SQS Configuration
| Setting | Value | Rationale |
|---------|-------|-----------|
| Queue Type | Standard | At-least-once, best throughput |
| Visibility Timeout | 60s | Enough for processing + retries |
| Message Retention | 14 days | Debug/replay window |
| Dead Letter Queue | Yes | Failed messages after 3 retries |
| Batch Size | 10 | Balance latency vs throughput |

## Consequences

### Positive
- **Decoupling** - Services don't need to know each other's endpoints
- **Resilience** - Messages persisted, survive consumer downtime
- **Scalability** - Multiple consumers can process in parallel
- **Retry/Dead Letter** - Built-in retry with DLQ for failed messages
- **Local parity** - Ministack provides SQS API locally

### Negative
- **Eventual consistency** - Consumers process async, slight delay
- **Duplicate messages** - Standard queue = at-least-once, need idempotency
- **Ordering** - Standard queue = best-effort ordering
- **Monitoring complexity** - Need to track queue depth, processing lag
- **Schema evolution** - Event schema changes require coordination

### Mitigation
- **Idempotency keys** - Use `event_id` for deduplication
- **Outbox pattern** - Write events to DB + SQS in same transaction
- **Schema versioning** - Include `event_version` in payload
- **Monitoring** - CloudWatch/Ministack metrics for queue depth, age
- **DLQ alerting** - Alert on messages in dead letter queue

## Implementation

### Publisher (Go Service)
```go
type EventPublisher struct {
    client   *sqs.Client
    queueURL string
}

func (p *EventPublisher) Publish(ctx context.Context, event Event) error {
    body, _ := json.Marshal(event)
    _, err := p.client.SendMessage(ctx, &sqs.SendMessageInput{
        QueueUrl:    &p.queueURL,
        MessageBody: aws.String(string(body)),
        MessageAttributes: map[string]types.MessageAttributeValue{
            "event_type": {DataType: aws.String("String"), StringValue: aws.String(event.Type)},
        },
    })
    return err
}
```

### Consumer (Node Service)
```javascript
const consumer = sqs.receiveMessage({ QueueUrl, MaxNumberOfMessages: 10, WaitTimeSeconds: 20 });
for (const msg of consumer.Messages || []) {
    await processMessage(JSON.parse(msg.Body));
    await sqs.deleteMessage({ QueueUrl, ReceiptHandle: msg.ReceiptHandle });
}
```

## Related
- ADR 001: Gin Framework
- ADR 002 (Node): Redis PubSub WebSockets