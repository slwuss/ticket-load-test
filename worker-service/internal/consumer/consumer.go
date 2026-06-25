package consumer

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
	"github.com/worldpaint/worker-service/internal/metrics"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
)

var tracer = otel.Tracer("worker-service/consumer")

type BookingMessage struct {
	BookingID string `json:"booking_id"`
	EventID   string `json:"event_id"`
	SeatID    string `json:"seat_id"`
	UserID    string `json:"user_id"`
	Action    string `json:"action"`
}

type Store interface {
	UpsertReserved(ctx context.Context, bookingID, eventID, seatID, userID string) error
	Confirm(ctx context.Context, bookingID string) error
	Cancel(ctx context.Context, bookingID string) error
}

type Consumer struct {
	sqs      *sqs.Client
	rdb      redis.UniversalClient
	store    Store
	queueURL string
}

func New(sqsClient *sqs.Client, rdb redis.UniversalClient, store Store, queueURL string) *Consumer {
	return &Consumer{sqs: sqsClient, rdb: rdb, store: store, queueURL: queueURL}
}

// Run polls SQS in a long-poll loop until ctx is cancelled.
func (c *Consumer) Run(ctx context.Context) {
	const concurrency = 10
	for i := 0; i < concurrency; i++ {
		go c.poll(ctx)
	}
	<-ctx.Done()
	time.Sleep(5 * time.Second)
}

func (c *Consumer) poll(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		out, err := c.sqs.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:              aws.String(c.queueURL),
			MaxNumberOfMessages:   10,
			WaitTimeSeconds:       20,
			VisibilityTimeout:     30,
			MessageAttributeNames: []string{"All"}, // receive W3C traceparent injected by booking-service
		})
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("sqs receive error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}

		for _, msg := range out.Messages {
			if err := c.handle(ctx, msg); err != nil {
				log.Printf("handle message error: %v", err)
				continue
			}
			c.delete(ctx, msg)
		}
	}
}

func (c *Consumer) handle(ctx context.Context, msg sqstypes.Message) error {
	var bm BookingMessage
	if err := json.Unmarshal([]byte(*msg.Body), &bm); err != nil {
		return fmt.Errorf("unmarshal: %w", err)
	}

	// Extract W3C trace context propagated from booking-service via SQS message attributes.
	carrier := make(propagation.MapCarrier, len(msg.MessageAttributes))
	for k, v := range msg.MessageAttributes {
		if v.StringValue != nil {
			carrier[k] = *v.StringValue
		}
	}
	ctx = otel.GetTextMapPropagator().Extract(ctx, carrier)

	timer := prometheus.NewTimer(metrics.MessageDuration.WithLabelValues(bm.Action))
	defer timer.ObserveDuration()

	ctx, span := tracer.Start(ctx, "worker."+bm.Action)
	defer span.End()

	span.SetAttributes(
		attribute.String("booking.id", bm.BookingID),
		attribute.String("booking.event_id", bm.EventID),
		attribute.String("booking.seat_id", bm.SeatID),
		attribute.String("booking.action", bm.Action),
	)

	var err error
	switch bm.Action {
	case "reserve":
		err = c.store.UpsertReserved(ctx, bm.BookingID, bm.EventID, bm.SeatID, bm.UserID)
	case "confirm":
		err = c.store.Confirm(ctx, bm.BookingID)
	case "cancel":
		if err = c.store.Cancel(ctx, bm.BookingID); err != nil {
			break
		}
		err = c.releaseLock(ctx, bm.EventID, bm.SeatID, bm.BookingID)
	default:
		err = fmt.Errorf("unknown action: %s", bm.Action)
	}

	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		metrics.MessagesProcessed.WithLabelValues(bm.Action, "error").Inc()
		return err
	}

	span.SetStatus(codes.Ok, "")
	metrics.MessagesProcessed.WithLabelValues(bm.Action, "ok").Inc()
	return nil
}

func (c *Consumer) releaseLock(ctx context.Context, eventID, seatID, bookingID string) error {
	key := fmt.Sprintf("seat:lock:%s:%s", eventID, seatID)
	script := redis.NewScript(`
		if redis.call("GET", KEYS[1]) == ARGV[1] then
			return redis.call("DEL", KEYS[1])
		end
		return 0
	`)
	return script.Run(ctx, c.rdb, []string{key}, bookingID).Err()
}

func (c *Consumer) delete(ctx context.Context, msg sqstypes.Message) {
	_, err := c.sqs.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(c.queueURL),
		ReceiptHandle: msg.ReceiptHandle,
	})
	if err != nil {
		log.Printf("failed to delete message %s: %v", *msg.MessageId, err)
	}
}
