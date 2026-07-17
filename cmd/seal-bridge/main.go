package main

import (
	"bufio"
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
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

const (
	connectTimeout = 5 * time.Second
	writeTimeout   = 10 * time.Second
	maxMessageSize = 64 << 20
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
	if _, err := os.Stdout.Write(message); err != nil {
		return err
	}
	_, err := os.Stdout.Write([]byte{'\n'})
	return err
}

func reserveAddress() (string, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		return "", err
	}
	return "ws://" + address, nil
}

func connect(ctx context.Context, url string) (*websocket.Conn, error) {
	deadline := time.Now().Add(connectTimeout)
	var lastErr error
	for time.Now().Before(deadline) {
		conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
			HTTPClient: &http.Client{Timeout: time.Second},
		})
		if err == nil {
			conn.SetReadLimit(maxMessageSize)
			return conn, nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
	return nil, fmt.Errorf("connect to %s: %w", url, lastErr)
}

func forwardInput(ctx context.Context, conn *websocket.Conn) error {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64<<10), maxMessageSize)
	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		if len(line) == 0 {
			continue
		}
		writeCtx, cancel := context.WithTimeout(ctx, writeTimeout)
		err := conn.Write(writeCtx, websocket.MessageText, line)
		cancel()
		if err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return io.EOF
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
		<-exited.done
	}
}

func run(ctx context.Context, codex string, out *output) error {
	url, err := reserveAddress()
	if err != nil {
		return fmt.Errorf("reserve app-server address: %w", err)
	}

	command := exec.Command(codex, "app-server", "--listen", url)
	command.Stdout = io.Discard
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		return fmt.Errorf("start Codex app-server: %w", err)
	}

	exited := &processExit{done: make(chan struct{})}
	go func() {
		exited.err = command.Wait()
		close(exited.done)
	}()
	defer stopProcess(command, exited)

	conn, err := connect(ctx, url)
	if err != nil {
		return err
	}
	defer conn.CloseNow()
	out.control(controlEvent{Event: "ready", URL: url})

	inputErr := make(chan error, 1)
	go func() { inputErr <- forwardInput(ctx, conn) }()
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
			if err := out.message(message); err != nil {
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
	out := &output{encoder: json.NewEncoder(os.Stdout)}
	if err := run(ctx, *codex, out); err != nil {
		out.control(controlEvent{Event: "error", Message: err.Error()})
		os.Exit(1)
	}
}
