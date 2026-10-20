// hsburst: start N TLS handshakes against a server at the same instant and
// report how long they take. Models a reconnection burst against etcd.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"math/rand"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	addr := flag.String("addr", "", "host:port")
	name := flag.String("name", "etcd-test", "server name to verify")
	levels := flag.String("levels", "1,10,100,500,1000,2000", "burst sizes")
	rounds := flag.Int("rounds", 3, "bursts per size")
	timeout := flag.Duration("timeout", 30*time.Second, "per-handshake timeout")
	pause := flag.Duration("pause", 5*time.Second, "pause between bursts")
	dir := flag.String("certs", "/certs", "ca.crt, client.crt, client.key")
	storms := flag.Int("storm", 0, "storm mode: this many connections, reconnecting together each cycle")
	cycles := flag.Int("cycles", 5, "storm cycles")
	hold := flag.Duration("hold", 15*time.Second, "storm cycle length; connections close at its end")
	flag.Parse()

	cert, err := tls.LoadX509KeyPair(*dir+"/client.crt", *dir+"/client.key")
	check(err)
	caPEM, err := os.ReadFile(*dir + "/ca.crt")
	check(err)
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)
	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      pool,
		ServerName:   *name,
		// What a FIPS client offers: no X25519 or hybrid key shares.
		CurvePreferences: []tls.CurveID{tls.CurveP256, tls.CurveP384},
	}

	if *storms > 0 {
		fmt.Println("cycle\tconnected\tattempts\tfailures\tall_connected_ms\tfirst_error")
		for c := 1; c <= *cycles; c++ {
			storm(*addr, cfg, *storms, c, *hold, *timeout)
		}
		return
	}

	fmt.Println("burst\tround\tok\terr\twall_ms\tp50_ms\tp90_ms\tp99_ms\tmax_ms\tfirst_error")
	for _, l := range strings.Split(*levels, ",") {
		n, err := strconv.Atoi(l)
		check(err)
		for r := 1; r <= *rounds; r++ {
			burst(*addr, cfg, n, r, *timeout)
			time.Sleep(*pause)
		}
	}
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	fmt.Printf("client cpu: user %.1fs sys %.1fs\n", float64(ru.Utime.Sec)+float64(ru.Utime.Usec)/1e6, float64(ru.Stime.Sec)+float64(ru.Stime.Usec)/1e6)
}

func burst(addr string, cfg *tls.Config, n, round int, timeout time.Duration) {
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		lat     []float64
		errs    int
		firstEr string
	)
	start := make(chan struct{})
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			t := time.Now()
			d := net.Dialer{Timeout: timeout}
			c, err := tls.DialWithDialer(&d, "tcp", addr, cfg)
			ms := float64(time.Since(t).Microseconds()) / 1000
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errs++
				if firstEr == "" {
					firstEr = err.Error()
				}
				return
			}
			c.Close()
			lat = append(lat, ms)
		}()
	}
	t0 := time.Now()
	close(start)
	wg.Wait()
	wall := float64(time.Since(t0).Milliseconds())
	sort.Float64s(lat)
	fmt.Printf("%d\t%d\t%d\t%d\t%.0f\t%s\t%s\t%s\t%s\t%s\n", n, round, len(lat), errs, wall,
		pct(lat, 50), pct(lat, 90), pct(lat, 99), pct(lat, 100), firstEr)
}

// storm models API servers reconnecting to an etcd member that came back:
// n connections dial at once; a handshake that takes longer than timeout is
// abandoned and retried after a short random wait, as a client would. Each
// connection stays open until the cycle ends, then all close together.
func storm(addr string, cfg *tls.Config, n, cycle int, hold, timeout time.Duration) {
	var (
		wg                 sync.WaitGroup
		attempts, failures atomic.Int64
		connected          atomic.Int64
		lastOK             atomic.Int64
		firstErr           atomic.Value
	)
	start := time.Now()
	end := start.Add(hold)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(end) {
				attempts.Add(1)
				d := net.Dialer{Timeout: timeout}
				c, err := tls.DialWithDialer(&d, "tcp", addr, cfg)
				if err != nil {
					failures.Add(1)
					firstErr.CompareAndSwap(nil, err.Error())
					time.Sleep(time.Duration(rand.Int63n(int64(500 * time.Millisecond))))
					continue
				}
				connected.Add(1)
				lastOK.Store(int64(time.Since(start)))
				time.Sleep(time.Until(end))
				c.Close()
				return
			}
		}()
	}
	wg.Wait()
	all := "-"
	if connected.Load() == int64(n) {
		all = fmt.Sprintf("%d", time.Duration(lastOK.Load()).Milliseconds())
	}
	e, _ := firstErr.Load().(string)
	fmt.Printf("%d\t%d\t%d\t%d\t%s\t%s\n", cycle, connected.Load(), attempts.Load(), failures.Load(), all, e)
}

func pct(s []float64, p float64) string {
	if len(s) == 0 {
		return "-"
	}
	i := int(float64(len(s)-1) * p / 100)
	return fmt.Sprintf("%.1f", s[i])
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
