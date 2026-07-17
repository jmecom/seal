package main

import (
	"net/url"
	"os/exec"
	"testing"
	"time"
)

func TestReserveAddressReturnsLoopbackWebSocket(t *testing.T) {
	address, err := reserveAddress()
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(address)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != "ws" || parsed.Hostname() != "127.0.0.1" || parsed.Port() == "" {
		t.Fatalf("unexpected address %q", address)
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
