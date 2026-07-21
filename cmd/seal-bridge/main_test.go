package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestReserveEndpointUsesAPrivateUnixSocketPath(t *testing.T) {
	endpoint, cleanup, err := reserveEndpoint()
	if err != nil {
		t.Fatal(err)
	}
	directory := strings.TrimSuffix(strings.TrimPrefix(endpoint, "unix://"), "/app.sock")
	info, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(endpoint, "unix://") || info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("endpoint is not private: %q mode=%o", endpoint, info.Mode().Perm())
	}
	cleanup()
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatalf("cleanup did not remove %q", directory)
	}
}

func TestOutputCompactsMultilineMessagesIntoOneRecord(t *testing.T) {
	var buffer bytes.Buffer
	out := &output{encoder: json.NewEncoder(&buffer), writer: &buffer}
	if err := out.message([]byte("{\n  \"method\": \"turn/started\",\n  \"params\": {}\n}")); err != nil {
		t.Fatal(err)
	}
	if got, want := buffer.String(), "{\"method\":\"turn/started\",\"params\":{}}\n"; got != want {
		t.Fatalf("unexpected framed message\nwant: %q\n got: %q", want, got)
	}
}

func TestForwardInputRejectsInvalidUTF8BeforeWriting(t *testing.T) {
	input := strings.NewReader("{\"prompt\":\"\xff\"}\n")
	err := forwardInput(context.Background(), input, nil)
	if err == nil || !strings.Contains(err.Error(), "invalid UTF-8") {
		t.Fatalf("expected invalid UTF-8 error, got %v", err)
	}
}

func TestConnectReportsChildExitImmediately(t *testing.T) {
	exited := &processExit{done: make(chan struct{}), err: errors.New("startup failed")}
	close(exited.done)
	started := time.Now()
	_, err := connect(context.Background(), "ws://127.0.0.1:1", exited)
	if err == nil || !strings.Contains(err.Error(), "startup failed") {
		t.Fatalf("expected child exit error, got %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("connect masked an exited child behind the dial timeout")
	}
}

func TestStopProcessReturnsAfterWaitWasConsumed(t *testing.T) {
	command := exec.Command("sh", "-c", "kill -TERM $$")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	exited := &processExit{done: make(chan struct{})}
	go func() {
		exited.err = command.Wait()
		close(exited.done)
	}()
	<-exited.done

	done := make(chan struct{})
	go func() {
		stopProcess(command, exited)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stopProcess blocked after the process had already been reaped")
	}
}

func TestStopProcessInterruptsRunningProcess(t *testing.T) {
	command := exec.Command("sh", "-c", "sleep 10")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	exited := &processExit{done: make(chan struct{})}
	go func() {
		exited.err = command.Wait()
		close(exited.done)
	}()

	done := make(chan struct{})
	go func() {
		stopProcess(command, exited)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("stopProcess did not stop a running process")
	}
}
