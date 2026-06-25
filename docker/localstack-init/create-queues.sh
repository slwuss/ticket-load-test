#!/bin/bash
# Runs automatically when LocalStack is ready
awslocal sqs create-queue \
  --queue-name booking-dlq.fifo \
  --attributes FifoQueue=true,ContentBasedDeduplication=true

awslocal sqs create-queue \
  --queue-name booking-queue.fifo \
  --attributes FifoQueue=true,ContentBasedDeduplication=true,RedrivePolicy='{"deadLetterTargetArn":"arn:aws:sqs:ap-southeast-2:000000000000:booking-dlq.fifo","maxReceiveCount":"3"}'

echo "SQS queues created"
