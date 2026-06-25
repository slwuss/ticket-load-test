package db

import (
	"context"
	"database/sql"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

var tracer = otel.Tracer("worker-service/db")

const schema = `
CREATE TABLE IF NOT EXISTS bookings (
	id          TEXT PRIMARY KEY,
	event_id    TEXT        NOT NULL,
	seat_id     TEXT        NOT NULL,
	user_id     TEXT        NOT NULL,
	status      TEXT        NOT NULL DEFAULT 'reserved',
	created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	UNIQUE (event_id, seat_id)
);

CREATE INDEX IF NOT EXISTS idx_bookings_user   ON bookings(user_id);
CREATE INDEX IF NOT EXISTS idx_bookings_event  ON bookings(event_id);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings(status);
`

func Migrate(db *sql.DB) error {
	_, err := db.Exec(schema)
	return err
}

type Store struct{ db *sql.DB }

func NewStore(db *sql.DB) *Store { return &Store{db: db} }

// UpsertReserved inserts a new reservation. Idempotent — safe to retry.
func (s *Store) UpsertReserved(ctx context.Context, bookingID, eventID, seatID, userID string) error {
	_, span := tracer.Start(ctx, "db.upsert_reserved")
	defer span.End()
	span.SetAttributes(
		attribute.String("db.operation", "upsert"),
		attribute.String("db.sql.table", "bookings"),
		attribute.String("booking.id", bookingID),
		attribute.String("booking.event_id", eventID),
		attribute.String("booking.seat_id", seatID),
	)

	_, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings (id, event_id, seat_id, user_id, status)
		VALUES ($1, $2, $3, $4, 'reserved')
		ON CONFLICT (event_id, seat_id) DO UPDATE
			SET id = EXCLUDED.id, user_id = EXCLUDED.user_id,
			    status = 'reserved', updated_at = NOW()
	`, bookingID, eventID, seatID, userID)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return fmt.Errorf("upsert reserved: %w", err)
	}
	span.SetStatus(codes.Ok, "")
	return nil
}

// Confirm moves a booking from reserved → confirmed.
func (s *Store) Confirm(ctx context.Context, bookingID string) error {
	_, span := tracer.Start(ctx, "db.confirm")
	defer span.End()
	span.SetAttributes(
		attribute.String("db.operation", "update"),
		attribute.String("db.sql.table", "bookings"),
		attribute.String("booking.id", bookingID),
	)

	res, err := s.db.ExecContext(ctx, `
		UPDATE bookings SET status = 'confirmed', updated_at = NOW()
		WHERE id = $1 AND status = 'reserved'
	`, bookingID)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return fmt.Errorf("confirm booking: %w", err)
	}
	rows, _ := res.RowsAffected()
	if rows == 0 {
		err = fmt.Errorf("booking %s not found or already confirmed", bookingID)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return err
	}
	span.SetStatus(codes.Ok, "")
	return nil
}

// Cancel marks a booking as cancelled (soft delete).
func (s *Store) Cancel(ctx context.Context, bookingID string) error {
	_, span := tracer.Start(ctx, "db.cancel")
	defer span.End()
	span.SetAttributes(
		attribute.String("db.operation", "update"),
		attribute.String("db.sql.table", "bookings"),
		attribute.String("booking.id", bookingID),
	)

	_, err := s.db.ExecContext(ctx, `
		UPDATE bookings SET status = 'cancelled', updated_at = NOW()
		WHERE id = $1
	`, bookingID)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
	} else {
		span.SetStatus(codes.Ok, "")
	}
	return err
}
