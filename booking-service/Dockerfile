FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o booking-service ./cmd

FROM alpine:3.19
COPY --from=builder /app/booking-service /booking-service
EXPOSE 8080
ENTRYPOINT ["/booking-service"]
