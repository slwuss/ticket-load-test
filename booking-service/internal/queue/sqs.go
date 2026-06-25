package queue

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
)

var tracer = otel.Tracer("booking-service/queue")

type BookingMessage struct {
	BookingID string `json:"booking_id"`
	EventID   string `json:"event_id"`
	SeatID    string `json:"seat_id"`
	UserID    string `json:"user_id"`
	Action    string `json:"action"` // "confirm" | "cancel"
}

type SQSPublisher struct {
	client   *sqs.Client
	queueURL string
}

func NewSQSPublisher(client *sqs.Client, queueURL string) *SQSPublisher {
	return &SQSPublisher{client: client, queueURL: queueURL}
}

func (p *SQSPublisher) Publish(ctx context.Context, msg BookingMessage) error {
	ctx, span := tracer.Start(ctx, "queue.publish")
	defer span.End()
	span.SetAttributes(
		attribute.String("messaging.system", "sqs"),
		attribute.String("booking.id", msg.BookingID),
		attribute.String("booking.event_id", msg.EventID),
		attribute.String("booking.action", msg.Action),
	)

	body, err := json.Marshal(msg)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "marshal failed")
		return fmt.Errorf("marshal message: %w", err)
	}

	// Inject W3C trace context so the worker can continue the distributed trace.
	carrier := make(propagation.MapCarrier)
	otel.GetTextMapPropagator().Inject(ctx, carrier)

	msgAttrs := make(map[string]sqstypes.MessageAttributeValue, len(carrier))
	for k, v := range carrier {
		val := v
		msgAttrs[k] = sqstypes.MessageAttributeValue{
			DataType:    aws.String("String"),
			StringValue: &val,
		}
	}

	_, err = p.client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:               aws.String(p.queueURL),
		MessageBody:            aws.String(string(body)),
		MessageGroupId:         aws.String(msg.EventID),
		MessageDeduplicationId: aws.String(uuid.New().String()),
		MessageAttributes:      msgAttrs,
	})
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "sqs send failed")
		return err
	}
	span.SetStatus(codes.Ok, "")
	return nil
}
