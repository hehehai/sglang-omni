// Command update-server serves a directory over HTTPS on the loopback
// interface, as the update feed of scripts/mac-update-e2e.sh: MyGo's
// updater only downloads over HTTPS, and `updates.url` must be an https
// URL. It makes a self-signed certificate for 127.0.0.1, writes it to
// -cert (the test points SSL_CERT_FILE at it: Go 1.27 then trusts it alone,
// on macOS too, without touching the keychain) and the feed's URL to -url,
// and logs each request.
//
//	go run ./scripts/update-server -dir feed -cert cert.pem -url url.txt
//
// With -github OWNER/REPO it is GitHub instead, for the beta channel's test
// (scripts/mac-beta-e2e.sh): an HTTPS proxy (its URL in -url, for
// HTTPS_PROXY) that answers for github.com and api.github.com itself, with
// the same certificate, and refuses every other host, so nothing reaches
// the real GitHub. dir/releases.json lists the releases, newest first, as
// the API does ({"tag_name", "draft", "prerelease"}); dir/<tag>/<file> are
// their files. It serves
//
//	api.github.com/repos/OWNER/REPO/releases?per_page=100&page=1   the list
//	github.com/OWNER/REPO/releases/download/<tag>/<file>         a file
//	github.com/OWNER/REPO/releases/latest/download/<file>        the latest
//	                                                              release's
//
// the latest release being the first that is neither a draft nor a
// prerelease (404 without one). While dir/rate-limited exists, the API
// answers 403 with X-RateLimit-Remaining: 0, as GitHub does past its limit.
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	dir := flag.String("dir", ".", "the directory to serve")
	addr := flag.String("addr", "127.0.0.1:0", "where to listen (loopback)")
	certOut := flag.String("cert", "cert.pem", "where to write the certificate")
	urlOut := flag.String("url", "url.txt", "where to write the URL")
	github := flag.String("github", "", "be github.com and api.github.com for this OWNER/REPO, as an HTTPS proxy")
	flag.Parse()

	cert, pemCert, err := selfSigned()
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(*certOut, pemCert, 0o644); err != nil {
		log.Fatal(err)
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	if ip := ln.Addr().(*net.TCPAddr).IP; !ip.IsLoopback() {
		log.Fatalf("%s is not a loopback address", ip)
	}
	if *github != "" {
		serveGitHub(ln, *dir, *github, cert, *urlOut)
		return
	}
	url := fmt.Sprintf("https://127.0.0.1:%d", ln.Addr().(*net.TCPAddr).Port)
	if err := os.WriteFile(*urlOut, []byte(url+"\n"), 0o644); err != nil {
		log.Fatal(err)
	}
	log.Printf("serving %s at %s", *dir, url)
	files := http.FileServer(http.Dir(*dir))
	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			log.Printf("%s %s", r.Method, r.URL.Path)
			files.ServeHTTP(w, r)
		}),
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}},
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(srv.ServeTLS(ln, "", ""))
}

// selfSigned makes a certificate for 127.0.0.1 and localhost that is its
// own authority, for a day.
func selfSigned() (tls.Certificate, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: "Auralink update test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1)},
		DNSNames:              []string{"localhost", "github.com", "api.github.com"},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), nil
}

// serveGitHub is the proxy of -github: CONNECTs to github.com and
// api.github.com end here, in TLS with cert, and reach gitHub.
func serveGitHub(ln net.Listener, dir, repo string, cert tls.Certificate, urlOut string) {
	url := fmt.Sprintf("http://127.0.0.1:%d", ln.Addr().(*net.TCPAddr).Port)
	if err := os.WriteFile(urlOut, []byte(url+"\n"), 0o644); err != nil {
		log.Fatal(err)
	}
	log.Printf("github.com and api.github.com of %s from %s, proxy %s", repo, dir, url)
	gh := gitHub(dir, repo)
	tlsConf := &tls.Config{Certificates: []tls.Certificate{cert}}
	proxy := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, port, _ := net.SplitHostPort(r.Host)
		if r.Method != http.MethodConnect || port != "443" || host != "github.com" && host != "api.github.com" {
			log.Printf("REFUSED %s %s", r.Method, r.Host)
			http.Error(w, "the test proxy only answers for github.com and api.github.com", http.StatusForbidden)
			return
		}
		conn, buf, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			if _, err := conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
				return
			}
			tc := tls.Server(&bufConn{Conn: conn, r: buf.Reader}, tlsConf)
			if err := tc.Handshake(); err != nil {
				log.Printf("TLS with %s: %v", host, err)
				return
			}
			br := bufio.NewReader(tc)
			for {
				req, err := http.ReadRequest(br)
				if err != nil {
					return
				}
				req.Host = host
				rw := newResponse()
				gh.ServeHTTP(rw, req)
				if err := rw.write(tc, req); err != nil || req.Close {
					return
				}
			}
		}()
	})
	srv := &http.Server{Handler: proxy, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.Serve(ln))
}

// gitHub serves the releases of repo in dir.
func gitHub(dir, repo string) http.Handler {
	type release struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
	}
	list := func() []release {
		var rs []release
		if b, err := os.ReadFile(filepath.Join(dir, "releases.json")); err == nil {
			_ = json.Unmarshal(b, &rs)
		}
		return rs
	}
	file := func(w http.ResponseWriter, r *http.Request, tag, name string) {
		if tag == "" || strings.Contains(tag, "/") || strings.Contains(name, "/") || strings.HasPrefix(tag, ".") || strings.HasPrefix(name, ".") {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, filepath.Join(dir, tag, name))
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s%s", r.Method, r.Host, r.URL.RequestURI())
		switch {
		case r.Host == "api.github.com" && r.URL.Path == "/repos/"+repo+"/releases":
			if _, err := os.Stat(filepath.Join(dir, "rate-limited")); err == nil {
				w.Header().Set("X-RateLimit-Remaining", "0")
				w.Header().Set("X-RateLimit-Reset", fmt.Sprint(time.Now().Add(40*time.Minute).Unix()))
				http.Error(w, `{"message": "API rate limit exceeded"}`, http.StatusForbidden)
				return
			}
			rs := list()
			if r.URL.Query().Get("page") != "1" {
				rs = nil
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(append([]release{}, rs...))
		case r.Host == "github.com":
			rest, ok := strings.CutPrefix(r.URL.Path, "/"+repo+"/releases/")
			if !ok {
				http.NotFound(w, r)
				return
			}
			if name, ok := strings.CutPrefix(rest, "latest/download/"); ok {
				for _, rel := range list() {
					if !rel.Draft && !rel.Prerelease {
						file(w, r, rel.Tag, name)
						return
					}
				}
				http.NotFound(w, r)
				return
			}
			if p, ok := strings.CutPrefix(rest, "download/"); ok {
				tag, name, _ := strings.Cut(p, "/")
				file(w, r, tag, name)
				return
			}
			http.NotFound(w, r)
		default:
			http.NotFound(w, r)
		}
	})
}

// bufConn reads what the proxy's reader already holds first.
type bufConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufConn) Read(b []byte) (int, error) { return c.r.Read(b) }

// response is a response written to memory, then to the connection.
type response struct {
	header http.Header
	code   int
	body   strings.Builder
}

func newResponse() *response { return &response{header: http.Header{}, code: http.StatusOK} }

func (r *response) Header() http.Header         { return r.header }
func (r *response) WriteHeader(code int)        { r.code = code }
func (r *response) Write(b []byte) (int, error) { return r.body.Write(b) }

func (r *response) write(c net.Conn, req *http.Request) error {
	resp := &http.Response{
		StatusCode: r.code, ProtoMajor: 1, ProtoMinor: 1, Header: r.header, Request: req,
		ContentLength: int64(r.body.Len()), Body: io.NopCloser(strings.NewReader(r.body.String())),
	}
	return resp.Write(c)
}
