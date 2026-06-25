# FIFO queue ensures exactly-once delivery — critical for booking idempotency
resource "aws_sqs_queue" "booking" {
  name                        = "booking-queue.fifo"
  fifo_queue                  = true
  content_based_deduplication = true

  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400   # 1 day
  receive_wait_time_seconds  = 20      # long-polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.booking_dlq.arn
    maxReceiveCount     = 3            # after 3 failures → DLQ
  })
}

# Dead Letter Queue — inspect failed messages without losing them
resource "aws_sqs_queue" "booking_dlq" {
  name                      = "booking-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = 604800  # 7 days
}

resource "aws_sqs_queue_policy" "booking" {
  queue_url = aws_sqs_queue.booking.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
      Resource  = aws_sqs_queue.booking.arn
    }]
  })
}

output "sqs_queue_url" {
  value = aws_sqs_queue.booking.url
}
