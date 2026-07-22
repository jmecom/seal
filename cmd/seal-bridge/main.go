package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"
)

const (
	connectTimeout = 5 * time.Second
	writeTimeout   = 10 * time.Second
	maxMessageSize = 64 << 20
	maxSocketPath  = 100
)

type controlMessage struct {
	Seal controlEvent `json:"seal"`
}

type controlEvent struct {
	Event   string `json:"event"`
	URL     string `json:"url,omitempty"`
	Message string `json:"message,omitempty"`
}

type output struct {
	mu      sync.Mutex
	encoder *json.Encoder
	writer  io.Writer
}

type processExit struct {
	done chan struct{}
	err  error
}

func (o *output) control(event controlEvent) {
	o.mu.Lock()
	defer o.mu.Unlock()
	_ = o.encoder.Encode(controlMessage{Seal: event})
}

func (o *output) message(message []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	var compact bytes.Buffer
	if err := json.Compact(&compact, message); err != nil {
		return fmt.Errorf("invalid app-server JSON: %w", err)
	}
	if _, err := o.writer.Write(compact.Bytes()); err != nil {
		return err
	}
	_, err := o.writer.Write([]byte{'\n'})
	return err
}

func forwardServerMessage(out *output, message []byte) error {
	if !json.Valid(message) {
		out.control(controlEvent{Event: "error", Message: "invalid JSON received from Codex app-server"})
		return nil
	}
	return out.message(message)
}

func reserveEndpoint() (string, func(), error) {
	// Unix socket paths have a small platform-dependent limit. Keep the
	// private directory under the short, conventional /tmp path even when a
	// caller has configured a deeply nested TMPDIR.
	directory, err := os.MkdirTemp("/tmp", "seal-")
	if err != nil {
		directory, err = os.MkdirTemp("", "seal-")
	}
	if err != nil {
		return "", nil, err
	}
	cleanup := func() { _ = os.RemoveAll(directory) }
	socket := filepath.Join(directory, "app.sock")
	if len(socket) >= maxSocketPath {
		cleanup()
		return "", nil, fmt.Errorf("temporary directory produces an overlong Unix socket path: %s", socket)
	}
	return "unix://" + socket, cleanup, nil
}

func connect(ctx context.Context, endpoint string, exited *processExit) (*websocket.Conn, error) {
	deadline := time.Now().Add(connectTimeout)
	var lastErr error
	dialURL := endpoint
	client := &http.Client{Timeout: time.Second}
	if strings.HasPrefix(endpoint, "unix://") {
		socket := strings.TrimPrefix(endpoint, "unix://")
		transport := &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var dialer net.Dialer
				return dialer.DialContext(ctx, "unix", socket)
			},
		}
		defer transport.CloseIdleConnections()
		client.Transport = transport
		dialURL = "ws://localhost/"
	}
	for time.Now().Before(deadline) {
		select {
		case <-exited.done:
			if exited.err == nil {
				return nil, errors.New("Codex app-server exited during startup")
			}
			return nil, fmt.Errorf("Codex app-server exited during startup: %w", exited.err)
		default:
		}
		conn, _, err := websocket.Dial(ctx, dialURL, &websocket.DialOptions{
			HTTPClient: client,
		})
		if err == nil {
			conn.SetReadLimit(maxMessageSize)
			return conn, nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-exited.done:
			if exited.err == nil {
				return nil, errors.New("Codex app-server exited during startup")
			}
			return nil, fmt.Errorf("Codex app-server exited during startup: %w", exited.err)
		case <-time.After(50 * time.Millisecond):
		}
	}
	return nil, fmt.Errorf("connect to %s: %w", endpoint, lastErr)
}

func scanInput(reader io.Reader, send func([]byte) error) error {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), maxMessageSize)
	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		if len(line) == 0 {
			continue
		}
		if !utf8.Valid(line) {
			return errors.New("app-server input contains invalid UTF-8")
		}
		if err := send(line); err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return io.EOF
}

func forwardInput(ctx context.Context, reader io.Reader, conn *websocket.Conn) error {
	return scanInput(reader, func(line []byte) error {
		writeCtx, cancel := context.WithTimeout(ctx, writeTimeout)
		err := conn.Write(writeCtx, websocket.MessageText, line)
		cancel()
		return err
	})
}

func stopProcess(command *exec.Cmd, exited *processExit) {
	if command.Process == nil {
		return
	}
	select {
	case <-exited.done:
		return
	default:
	}
	_ = command.Process.Signal(os.Interrupt)
	select {
	case <-exited.done:
	case <-time.After(time.Second):
		_ = command.Process.Kill()
		select {
		case <-exited.done:
		case <-time.After(time.Second):
		}
	}
}

func appServerCommand(codex, url string) *exec.Cmd {
	command := exec.Command(codex, "app-server", "--listen", url)
	command.Stdout = nil
	command.Stderr = os.Stderr
	command.WaitDelay = time.Second
	return command
}

func run(ctx context.Context, codex string, out *output) error {
	url, cleanup, err := reserveEndpoint()
	if err != nil {
		return fmt.Errorf("reserve app-server endpoint: %w", err)
	}
	defer cleanup()

	command := appServerCommand(codex, url)
	if err := command.Start(); err != nil {
		return fmt.Errorf("start Codex app-server: %w", err)
	}

	exited := &processExit{done: make(chan struct{})}
	go func() {
		exited.err = command.Wait()
		close(exited.done)
	}()
	defer stopProcess(command, exited)

	conn, err := connect(ctx, url, exited)
	if err != nil {
		return err
	}
	defer conn.CloseNow()
	out.control(controlEvent{Event: "ready", URL: url})

	inputErr := make(chan error, 1)
	go func() { inputErr <- forwardInput(ctx, os.Stdin, conn) }()
	messages := make(chan []byte)
	readErr := make(chan error, 1)
	go func() {
		for {
			_, message, err := conn.Read(ctx)
			if err != nil {
				readErr <- err
				return
			}
			select {
			case messages <- message:
			case <-ctx.Done():
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-inputErr:
			if errors.Is(err, io.EOF) || errors.Is(err, context.Canceled) {
				return nil
			}
			return fmt.Errorf("send app-server message: %w", err)
		case <-exited.done:
			if exited.err == nil {
				return errors.New("Codex app-server exited")
			}
			return fmt.Errorf("Codex app-server exited: %w", exited.err)
		case err := <-readErr:
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("read app-server message: %w", err)
		case message := <-messages:
			if err := forwardServerMessage(out, message); err != nil {
				return fmt.Errorf("write app-server message: %w", err)
			}
		}
	}
}

func main() {
	codex := flag.String("codex", "codex", "path to the Codex CLI")
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	out := &output{encoder: json.NewEncoder(os.Stdout), writer: os.Stdout}
	if err := run(ctx, *codex, out); err != nil {
		out.control(controlEvent{Event: "error", Message: err.Error()})
		os.Exit(1)
	}
}
