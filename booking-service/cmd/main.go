package main

import (
	"context"
	"crypto/tls"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	"github.com/worldpaint/booking-service/internal/handler"
	"github.com/worldpaint/booking-service/internal/lock"
	"github.com/worldpaint/booking-service/internal/queue"
	"github.com/worldpaint/booking-service/internal/telemetry"
	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
)

func main() {
	ctx := context.Background()

	shutdown, err := telemetry.Init(ctx, "booking-service")
	if err != nil {
		log.Fatalf("init telemetry: %v", err)
	}
	defer func() {
		if err := shutdown(context.Background()); err != nil {
			log.Printf("telemetry shutdown: %v", err)
		}
	}()

	rdb := redis.NewUniversalClient(&redis.UniversalOptions{
		Addrs:     []string{os.Getenv("REDIS_ADDR")},
		TLSConfig: &tls.Config{},
	})

	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}
	sqsClient := sqs.NewFromConfig(cfg)

	locker := lock.NewRedisLocker(rdb)
	publisher := queue.NewSQSPublisher(sqsClient, os.Getenv("SQS_QUEUE_URL"))
	h := handler.New(locker, publisher)

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(otelgin.Middleware("booking-service"))

	r.GET("/healthz", func(c *gin.Context) { c.Status(http.StatusOK) })
	r.GET("/readyz", func(c *gin.Context) {
		pingCtx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		defer cancel()
		if err := rdb.Ping(pingCtx).Err(); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "redis unreachable"})
			return
		}
		c.Status(http.StatusOK)
	})

	api := r.Group("/api/v1")
	{
		api.GET("/events", h.ListEvents)
		api.POST("/events/:event_id/reserve", h.Reserve)
		api.POST("/bookings/:booking_id/confirm", h.Confirm)
		api.DELETE("/bookings/:booking_id", h.Cancel)
	}

	srv := &http.Server{Addr: ":8080", Handler: r}

	go func() {
		log.Printf("booking-service listening on :8080")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
	<-quit

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("graceful shutdown failed: %v", err)
	}
	log.Println("booking-service stopped")
}
