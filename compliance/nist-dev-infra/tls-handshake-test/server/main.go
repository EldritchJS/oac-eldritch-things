// hsserve: a TLS server with etcd's handshake settings, but Go's own
// crypto instead of OpenSSL. Built with CGO_ENABLED=0, it is the control
// for the etcd runs: the same handshakes, with no cgo calls.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"flag"
	"io"
	"log"
	"os"
)

func main() {
	addr := flag.String("addr", ":2379", "listen address")
	dir := flag.String("certs", "/certs", "ca.crt, server.crt, server.key")
	flag.Parse()

	cert, err := tls.LoadX509KeyPair(*dir+"/server.crt", *dir+"/server.key")
	if err != nil {
		log.Fatal(err)
	}
	caPEM, err := os.ReadFile(*dir + "/ca.crt")
	if err != nil {
		log.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)
	cfg := &tls.Config{
		Certificates:     []tls.Certificate{cert},
		ClientCAs:        pool,
		ClientAuth:       tls.RequireAndVerifyClientCert,
		MinVersion:       tls.VersionTLS12,
		CurvePreferences: []tls.CurveID{tls.CurveP256, tls.CurveP384},
	}
	ln, err := tls.Listen("tcp", *addr, cfg)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("serving %s", *addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func() {
			defer c.Close()
			if c.(*tls.Conn).Handshake() == nil {
				io.Copy(io.Discard, c)
			}
		}()
	}
}
