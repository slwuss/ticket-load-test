#!/bin/sh
set -e

awslocal sqs create-queue \
  --queue-name booking-queue.fifo \
  --attributes FifoQueue=true,ContentBasedDeduplication=true \
  --region ap-southeast-2

echo "SQS queue booking-queue.fifo created"
