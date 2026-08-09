// quic-go-h3-benchmark is a compiled HTTP/3 load generator for the unified
// Flyology HTTP benchmark route. It is intentionally separate from the
// interoperability oracle so qualification remains a small fixed exchange.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

type clientConnection struct {
	client    *http.Client
	transport *http3.Transport
}

type latencySummary struct {
	Mean float64 `json:"mean"`
	P50  float64 `json:"p50"`
	P95  float64 `json:"p95"`
	P99  float64 `json:"p99"`
	Max  float64 `json:"max"`
}

type summary struct {
	Protocol        string         `json:"protocol"`
	Requests        uint64         `json:"requests"`
	Connections     int            `json:"connections"`
	Streams         int            `json:"streams"`
	Concurrency     int            `json:"concurrency"`
	ConnectionReuse float64        `json:"connection_reuse"`
	WallSeconds     float64        `json:"wall_s"`
	RequestsPerSec  float64        `json:"requests_per_s"`
	ResponseBytes   int            `json:"response_bytes"`
	LatencyMS       latencySummary `json:"latency_ms"`
	HandshakeMS     latencySummary `json:"handshake_ms"`
}

func newConnection(timeout time.Duration) clientConnection {
	transport := &http3.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, // The benchmark server uses a test identity.
			NextProtos:         []string{http3.NextProtoH3},
			MinVersion:         tls.VersionTLS13,
		},
		QUICConfig: &quic.Config{
			MaxIdleTimeout:          timeout,
			InitialPacketSize:       1200,
			DisablePathMTUDiscovery: true,
		},
	}
	return clientConnection{
		client:    &http.Client{Transport: transport, Timeout: timeout},
		transport: transport,
	}
}

func request(
	ctx context.Context,
	client *http.Client,
	url string,
	expectedBody []byte,
) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	body, readErr := io.ReadAll(response.Body)
	closeErr := response.Body.Close()
	if readErr != nil {
		return readErr
	}
	if closeErr != nil {
		return closeErr
	}
	if response.StatusCode != http.StatusOK || !bytes.Equal(body, expectedBody) {
		return fmt.Errorf(
			"unexpected response: status=%d body=%q",
			response.StatusCode,
			body,
		)
	}
	return nil
}

func summarize(values []time.Duration) latencySummary {
	if len(values) == 0 {
		return latencySummary{}
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	var total time.Duration
	for _, value := range values {
		total += value
	}
	percentile := func(numerator int) float64 {
		index := (len(values)*numerator + 99) / 100
		if index < 1 {
			index = 1
		}
		return float64(values[index-1]) / float64(time.Millisecond)
	}
	return latencySummary{
		Mean: float64(total) / float64(len(values)) / float64(time.Millisecond),
		P50:  percentile(50),
		P95:  percentile(95),
		P99:  percentile(99),
		Max:  float64(values[len(values)-1]) / float64(time.Millisecond),
	}
}

func benchmark(
	port int,
	path string,
	expectedBody []byte,
	requests uint64,
	connectionCount int,
	streams int,
	timeout time.Duration,
) (summary, error) {
	url := fmt.Sprintf("https://localhost:%d%s", port, path)
	connections := make([]clientConnection, connectionCount)
	handshakes := make([]time.Duration, connectionCount)
	for index := range connections {
		connections[index] = newConnection(timeout)
		started := time.Now()
		if err := request(
			context.Background(), connections[index].client, url, expectedBody,
		); err != nil {
			return summary{}, fmt.Errorf("warmup connection %d: %w", index, err)
		}
		handshakes[index] = time.Since(started)
	}
	defer func() {
		for _, connection := range connections {
			_ = connection.transport.Close()
		}
	}()

	latencies := make([]time.Duration, requests)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var next atomic.Uint64
	var wait sync.WaitGroup
	errCh := make(chan error, 1)
	workerCount := connectionCount * streams
	ready := make(chan struct{})
	for worker := 0; worker < workerCount; worker++ {
		wait.Add(1)
		go func(client *http.Client) {
			defer wait.Done()
			<-ready
			for {
				index := next.Add(1) - 1
				if index >= requests {
					return
				}
				started := time.Now()
				if err := request(ctx, client, url, expectedBody); err != nil {
					select {
					case errCh <- err:
						cancel()
					default:
					}
					return
				}
				latencies[index] = time.Since(started)
			}
		}(connections[worker/streams].client)
	}
	started := time.Now()
	close(ready)
	wait.Wait()
	wall := time.Since(started)
	select {
	case err := <-errCh:
		return summary{}, err
	default:
	}

	return summary{
		Protocol:        "h3",
		Requests:        requests,
		Connections:     connectionCount,
		Streams:         streams,
		Concurrency:     workerCount,
		ConnectionReuse: float64(requests) / float64(connectionCount),
		WallSeconds:     wall.Seconds(),
		RequestsPerSec:  float64(requests) / wall.Seconds(),
		ResponseBytes:   len(expectedBody),
		LatencyMS:       summarize(latencies),
		HandshakeMS:     summarize(handshakes),
	}, nil
}

func main() {
	log.SetFlags(0)
	port := flag.Int("port", 18443, "UDP port")
	path := flag.String("path", "/hello/test", "request path")
	responseBytes := flag.Int("response-bytes", 0, "expected response size (zero uses the path)")
	requests := flag.Uint64("requests", 10000, "measured requests")
	connections := flag.Int("connections", 8, "persistent QUIC connections")
	streams := flag.Int("streams", 8, "concurrent request streams per connection")
	timeout := flag.Duration("timeout", 10*time.Second, "request and idle timeout")
	flag.Parse()
	if *requests == 0 || *connections < 1 || *streams < 1 || *timeout <= 0 {
		log.Fatal("requests, connections, streams, and timeout must be positive")
	}

	expectedBody := []byte("hello " + strings.TrimPrefix(*path, "/hello/"))
	if *responseBytes != 0 {
		if *responseBytes < len("hello ") {
			log.Fatal("response-bytes cannot be smaller than 6")
		}
		name := strings.Repeat("x", *responseBytes-len("hello "))
		*path = "/hello/" + name
		expectedBody = []byte("hello " + name)
	}

	result, err := benchmark(
		*port,
		*path,
		expectedBody,
		*requests,
		*connections,
		*streams,
		*timeout,
	)
	if err != nil {
		if !errors.Is(err, context.Canceled) {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(result); err != nil {
		log.Fatal(err)
	}
}
