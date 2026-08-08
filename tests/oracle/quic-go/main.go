// quic-go-oracle is an independent HTTP/3 peer for Flyology qualification.
// It is a test process only and is never linked into the Ada libraries.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

const certificateDERHex = "3082013c3081efa0030201020214434e3e3873a520217edf913fba03f4" +
	"ea17411e64300506032b657030143112301006035504030c096c6f6361" +
	"6c686f7374301e170d3236303830373230323830385a170d3336303830" +
	"343230323830385a30143112301006035504030c096c6f63616c686f73" +
	"74302a300506032b65700321006380a1de85cdd187a3134d096ff12e8b" +
	"1e47aa4c94cff3c4144bad3ee5f81eaea3533051301d0603551d0e0416" +
	"0414d3dd952a2ff44a35af38d9249d71a454ced348ce301f0603551d23" +
	"041830168014d3dd952a2ff44a35af38d9249d71a454ced348ce300f060" +
	"3551d130101ff040530030101ff300506032b657003410024075a33b818" +
	"be62a4f328b79bd8f79febe7d3710fb44ba7a7b2d8e12bc3d1e4056d5" +
	"c20fba04e183430175b62ed1a107eb518dfaacf11045fa0e5a6feba2c0f"

const privateSeedHex = "f491306c81165ffd97822f3ef58de8918779314457f5501e42d3f68504cd3aa8"

func decodeHex(value string) []byte {
	result, err := hex.DecodeString(value)
	if err != nil {
		panic(err)
	}
	return result
}

func serverTLSConfig() *tls.Config {
	certificateDER := decodeHex(certificateDERHex)
	certificate, err := x509.ParseCertificate(certificateDER)
	if err != nil {
		panic(err)
	}
	privateKey := ed25519.NewKeyFromSeed(decodeHex(privateSeedHex))
	return &tls.Config{
		Certificates: []tls.Certificate{{
			Certificate: [][]byte{certificateDER},
			PrivateKey:  privateKey,
			Leaf:        certificate,
		}},
		NextProtos: []string{http3.NextProtoH3},
		MinVersion: tls.VersionTLS13,
	}
}

func runServer(port int) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/hello", func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet || request.ProtoMajor != 3 {
			http.Error(writer, "unexpected request", http.StatusBadRequest)
			return
		}
		writer.Header().Set("Content-Type", "text/plain")
		writer.Header().Set("X-Oracle", "quic-go")
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("hello"))
	})

	server := http3.Server{
		Addr:      fmt.Sprintf("127.0.0.1:%d", port),
		TLSConfig: serverTLSConfig(),
		QUICConfig: &quic.Config{
			MaxIdleTimeout:          10 * time.Second,
			InitialPacketSize:       1200,
			DisablePathMTUDiscovery: true,
		},
		Handler: mux,
	}
	fmt.Printf("quic-go HTTP/3 oracle listening on 127.0.0.1:%d\n", port)
	return server.ListenAndServe()
}

func runClient(port int) error {
	transport := &http3.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, // The Ada server uses a fixed test identity.
			NextProtos:         []string{http3.NextProtoH3},
			MinVersion:         tls.VersionTLS13,
		},
		QUICConfig: &quic.Config{
			MaxIdleTimeout:          10 * time.Second,
			InitialPacketSize:       1200,
			DisablePathMTUDiscovery: true,
		},
	}
	defer transport.Close()
	client := http.Client{Transport: transport, Timeout: 10 * time.Second}

	checks := []struct {
		method       string
		path         string
		requestBody  string
		status       int
		responseBody string
	}{
		{http.MethodGet, "/hello", "", http.StatusOK, "hello"},
		{http.MethodPost, "/echo", "payload", http.StatusCreated, "echo:payload"},
	}
	for _, check := range checks {
		request, err := http.NewRequest(
			check.method,
			fmt.Sprintf("https://localhost:%d%s", port, check.path),
			bytes.NewBufferString(check.requestBody),
		)
		if err != nil {
			return err
		}
		request.Header.Set("X-Oracle", "quic-go")
		response, err := client.Do(request)
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
		if response.StatusCode != check.status ||
			!bytes.Equal(body, []byte(check.responseBody)) {
			return fmt.Errorf(
				"unexpected Ada HTTP/3 response: path=%s status=%d body=%q",
				check.path,
				response.StatusCode,
				body,
			)
		}
		if check.path == "/echo" && response.Header.Get("X-Echo") != "accepted" {
			return errors.New("Ada HTTP/3 response omitted the X-Echo header")
		}
	}
	fmt.Println("quic-go client interoperated with the Ada HTTP/3 server")
	return nil
}

func main() {
	log.SetFlags(0)
	port := flag.Int("port", 4435, "UDP port")
	flag.Parse()
	if flag.NArg() != 1 {
		log.Fatal("usage: quic-go-oracle [--port PORT] {client|server}")
	}
	var err error
	switch flag.Arg(0) {
	case "client":
		err = runClient(*port)
	case "server":
		err = runServer(*port)
	default:
		err = errors.New("mode must be client or server")
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
