package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	MessagesProcessed = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_messages_processed_total",
		Help: "Messages processed, labelled by action and status (ok|error)",
	}, []string{"action", "status"})

	MessageDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "worker_message_duration_seconds",
		Help:    "Time to process one SQS message",
		Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5},
	}, []string{"action"})
)
