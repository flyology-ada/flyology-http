package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
)

const maximumUpload = 1024 * 1024

func patterned(size int) []byte {
	result := make([]byte, size)
	for index := range result {
		result[index] = byte('a' + index%26)
	}
	return result
}

func main() {
	certificate := flag.String("certificate", "", "TLS certificate")
	privateKey := flag.String("private-key", "", "TLS private key")
	portFile := flag.String("port-file", "", "ready port file")
	flag.Parse()
	if *certificate == "" || *privateKey == "" || *portFile == "" {
		log.Fatal("certificate, private-key, and port-file are required")
	}

	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.ProtoMajor != 2 {
			http.Error(writer, "HTTP/2 required", http.StatusHTTPVersionNotSupported)
			return
		}
		writer.Header().Set("x-peer", "go")
		var body []byte
		switch request.URL.Path {
		case "/small":
			body = []byte("flyology-http2-interop")
		case "/first":
			body = []byte("first")
		case "/second":
			body = []byte("second")
		case "/large":
			body = patterned(256 * 1024)
		case "/echo":
			var err error
			body, err = io.ReadAll(io.LimitReader(request.Body, maximumUpload+1))
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
			if len(body) > maximumUpload {
				http.Error(writer, "upload too large", http.StatusRequestEntityTooLarge)
				return
			}
		default:
			http.NotFound(writer, request)
			return
		}
		writer.Header().Set("content-length", fmt.Sprint(len(body)))
		writer.WriteHeader(http.StatusOK)
		if request.Method != http.MethodHead {
			if _, err := writer.Write(body); err != nil {
				log.Printf("write response: %v", err)
			}
		}
	})

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(
		*portFile,
		[]byte(fmt.Sprint(listener.Addr().(*net.TCPAddr).Port)),
		0o600,
	); err != nil {
		log.Fatal(err)
	}
	server := &http.Server{
		Handler: handler,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			NextProtos: []string{"h2"},
		},
	}
	log.Fatal(server.ServeTLS(listener, *certificate, *privateKey))
}
