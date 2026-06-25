package handler

import (
	"context"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/worldpaint/booking-service/internal/lock"
	"github.com/worldpaint/booking-service/internal/queue"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

var tracer = otel.Tracer("booking-service/handler")

type Locker interface {
	AcquireSeat(ctx context.Context, eventID, seatID, bookingID string) error
	ReleaseSeat(ctx context.Context, eventID, seatID, bookingID string) error
}

type Publisher interface {
	Publish(ctx context.Context, msg queue.BookingMessage) error
}

type Handler struct {
	locker    Locker
	publisher Publisher
}

func New(locker Locker, publisher Publisher) *Handler {
	return &Handler{locker: locker, publisher: publisher}
}

type reserveRequest struct {
	SeatID string `json:"seat_id" binding:"required"`
	UserID string `json:"user_id" binding:"required"`
}

// ListEvents returns a mocked list of concerts.
func (h *Handler) ListEvents(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"events": []gin.H{
			{"id": "evt-001", "name": "Rock the Arena", "venue": "Bangkok Arena", "date": "2026-08-01", "total_seats": 5000},
			{"id": "evt-002", "name": "Jazz Night", "venue": "IMPACT", "date": "2026-09-15", "total_seats": 2000},
		},
	})
}

// Reserve acquires a distributed lock on a seat and publishes a pending booking.
func (h *Handler) Reserve(c *gin.Context) {
	ctx, span := tracer.Start(c.Request.Context(), "reserve")
	defer span.End()

	eventID := c.Param("event_id")
	var req reserveRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "invalid request body")
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	bookingID := uuid.New().String()
	span.SetAttributes(
		attribute.String("booking.id", bookingID),
		attribute.String("booking.event_id", eventID),
		attribute.String("booking.seat_id", req.SeatID),
		attribute.String("booking.user_id", req.UserID),
	)

	err := h.locker.AcquireSeat(ctx, eventID, req.SeatID, bookingID)
	if err != nil {
		if err == lock.ErrAlreadyLocked {
			span.SetStatus(codes.Error, "seat already locked")
			c.JSON(http.StatusConflict, gin.H{"error": "seat already taken"})
			return
		}
		span.RecordError(err)
		span.SetStatus(codes.Error, "failed to acquire seat lock")
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to reserve seat"})
		return
	}

	msg := queue.BookingMessage{
		BookingID: bookingID,
		EventID:   eventID,
		SeatID:    req.SeatID,
		UserID:    req.UserID,
		Action:    "reserve",
	}

	pubErr := h.publisher.Publish(ctx, msg)
	if pubErr != nil {
		span.RecordError(pubErr)
		span.SetStatus(codes.Error, "failed to publish to SQS")
		_ = h.locker.ReleaseSeat(context.Background(), eventID, req.SeatID, bookingID)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to queue booking"})
		return
	}

	span.SetStatus(codes.Ok, "")
	c.JSON(http.StatusAccepted, gin.H{
		"booking_id": bookingID,
		"status":     "reserved",
		"message":    "seat held for 10 minutes — call /confirm to complete purchase",
	})
}

type confirmRequest struct {
	UserID  string `json:"user_id"  binding:"required"`
	EventID string `json:"event_id" binding:"required"`
	SeatID  string `json:"seat_id"  binding:"required"`
}

// Confirm publishes a confirm action. The worker marks the booking as confirmed in Postgres.
func (h *Handler) Confirm(c *gin.Context) {
	ctx, span := tracer.Start(c.Request.Context(), "confirm")
	defer span.End()

	bookingID := c.Param("booking_id")
	var req confirmRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "invalid request body")
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	span.SetAttributes(
		attribute.String("booking.id", bookingID),
		attribute.String("booking.event_id", req.EventID),
		attribute.String("booking.seat_id", req.SeatID),
		attribute.String("booking.user_id", req.UserID),
	)

	msg := queue.BookingMessage{
		BookingID: bookingID,
		EventID:   req.EventID,
		SeatID:    req.SeatID,
		UserID:    req.UserID,
		Action:    "confirm",
	}

	err := h.publisher.Publish(ctx, msg)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "failed to publish to SQS")
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to confirm booking"})
		return
	}

	span.SetStatus(codes.Ok, "")
	c.JSON(http.StatusAccepted, gin.H{"booking_id": bookingID, "status": "confirming"})
}

// Cancel releases the seat lock and publishes a cancel action.
func (h *Handler) Cancel(c *gin.Context) {
	ctx, span := tracer.Start(c.Request.Context(), "cancel")
	defer span.End()

	bookingID := c.Param("booking_id")
	eventID := c.Query("event_id")
	seatID := c.Query("seat_id")

	if eventID == "" || seatID == "" {
		span.SetStatus(codes.Error, "missing event_id or seat_id")
		c.JSON(http.StatusBadRequest, gin.H{"error": "event_id and seat_id required"})
		return
	}

	span.SetAttributes(
		attribute.String("booking.id", bookingID),
		attribute.String("booking.event_id", eventID),
		attribute.String("booking.seat_id", seatID),
	)

	_ = h.locker.ReleaseSeat(ctx, eventID, seatID, bookingID)

	msg := queue.BookingMessage{
		BookingID: bookingID,
		EventID:   eventID,
		SeatID:    seatID,
		Action:    "cancel",
	}

	err := h.publisher.Publish(ctx, msg)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "failed to publish to SQS")
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to cancel booking"})
		return
	}

	span.SetStatus(codes.Ok, "")
	c.JSON(http.StatusOK, gin.H{"booking_id": bookingID, "status": "cancelled"})
}
