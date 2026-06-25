package main

import (
	"context"
	"database/sql"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
	"github.com/worldpaint/worker-service/internal/consumer"
	"github.com/worldpaint/worker-service/internal/db"
	"github.com/worldpaint/worker-service/internal/telemetry"
)

func main() {
	ctx := context.Background()

	shutdown, err := telemetry.Init(ctx, "worker-service")
	if err != nil {
		log.Fatalf("init telemetry: %v", err)
	}
	defer func() {
		if err := shutdown(context.Background()); err != nil {
			log.Printf("telemetry shutdown: %v", err)
		}
	}()

	pgDB, err := sql.Open("postgres", os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("open postgres: %v", err)
	}
	defer pgDB.Close()

	pgDB.SetMaxOpenConns(25)
	pgDB.SetMaxIdleConns(10)

	if err := db.Migrate(pgDB); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	rdb := redis.NewUniversalClient(&redis.UniversalOptions{
		Addrs: []string{os.Getenv("REDIS_ADDR")},
	})

	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		log.Fatalf("aws config: %v", err)
	}
	sqsClient := sqs.NewFromConfig(cfg)

	store := db.NewStore(pgDB)
	c := consumer.New(sqsClient, rdb, store, os.Getenv("SQS_QUEUE_URL"))

	runCtx, cancel := context.WithCancel(ctx)

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-quit
		log.Println("shutting down worker...")
		cancel()
	}()

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		if err := http.ListenAndServe(":9090", nil); err != nil {
			log.Printf("metrics server error: %v", err)
		}
	}()

	log.Println("worker-service started")
	c.Run(runCtx)
	log.Println("worker-service stopped")
}
