package lock

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

const (
	// SeatLockTTL is how long a seat is held during checkout.
	// After this, the reservation expires and the seat is released automatically.
	SeatLockTTL = 10 * time.Minute
)

var ErrAlreadyLocked = errors.New("seat already reserved by another user")

var tracer = otel.Tracer("booking-service/lock")

type RedisLocker struct {
	rdb redis.UniversalClient
}

func NewRedisLocker(rdb redis.UniversalClient) *RedisLocker {
	return &RedisLocker{rdb: rdb}
}

// AcquireSeat attempts a SET NX (set-if-not-exists) on the seat key.
// Returns ErrAlreadyLocked if another booking holds the seat.
func (l *RedisLocker) AcquireSeat(ctx context.Context, eventID, seatID, bookingID string) error {
	ctx, span := tracer.Start(ctx, "lock.acquire_seat")
	defer span.End()
	span.SetAttributes(
		attribute.String("lock.event_id", eventID),
		attribute.String("lock.seat_id", seatID),
		attribute.String("lock.booking_id", bookingID),
	)

	key := seatKey(eventID, seatID)
	ok, err := l.rdb.SetNX(ctx, key, bookingID, SeatLockTTL).Result()
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "redis setnx failed")
		return fmt.Errorf("redis setnx: %w", err)
	}
	if !ok {
		span.SetStatus(codes.Error, "seat already locked")
		return ErrAlreadyLocked
	}
	span.SetStatus(codes.Ok, "")
	return nil
}

// ReleaseSeat deletes the seat lock only if it belongs to this booking.
// Uses a Lua script to make read-then-delete atomic.
func (l *RedisLocker) ReleaseSeat(ctx context.Context, eventID, seatID, bookingID string) error {
	ctx, span := tracer.Start(ctx, "lock.release_seat")
	defer span.End()
	span.SetAttributes(
		attribute.String("lock.event_id", eventID),
		attribute.String("lock.seat_id", seatID),
		attribute.String("lock.booking_id", bookingID),
	)

	key := seatKey(eventID, seatID)
	script := redis.NewScript(`
		if redis.call("GET", KEYS[1]) == ARGV[1] then
			return redis.call("DEL", KEYS[1])
		end
		return 0
	`)
	if err := script.Run(ctx, l.rdb, []string{key}, bookingID).Err(); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "redis release failed")
		return err
	}
	span.SetStatus(codes.Ok, "")
	return nil
}

// ExtendSeat resets the TTL on an existing seat lock (for keep-alive pings).
func (l *RedisLocker) ExtendSeat(ctx context.Context, eventID, seatID, bookingID string) error {
	ctx, span := tracer.Start(ctx, "lock.extend_seat")
	defer span.End()
	span.SetAttributes(
		attribute.String("lock.event_id", eventID),
		attribute.String("lock.seat_id", seatID),
		attribute.String("lock.booking_id", bookingID),
	)

	key := seatKey(eventID, seatID)
	script := redis.NewScript(`
		if redis.call("GET", KEYS[1]) == ARGV[1] then
			return redis.call("EXPIRE", KEYS[1], ARGV[2])
		end
		return 0
	`)
	ttlSecs := int(SeatLockTTL.Seconds())
	if err := script.Run(ctx, l.rdb, []string{key}, bookingID, ttlSecs).Err(); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "redis extend failed")
		return err
	}
	span.SetStatus(codes.Ok, "")
	return nil
}

func seatKey(eventID, seatID string) string {
	return fmt.Sprintf("seat:lock:%s:%s", eventID, seatID)
}
