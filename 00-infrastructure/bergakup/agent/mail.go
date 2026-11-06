package main

// E-mail de falha, enviado pelo próprio agente: funciona com a web desligada.

import (
	"crypto/tls"
	"fmt"
	"log"
	"mime"
	"net"
	"net/smtp"
	"strconv"
	"strings"
	"time"
)

func (a *Agent) sendMail(subject, body string) {
	plan := a.currentPlan()
	if plan == nil || plan.SMTP == nil || plan.SMTP.Host == "" || len(plan.SMTP.To) == 0 {
		return
	}
	if err := sendSMTP(plan.SMTP, a.opener, subject, body); err != nil {
		log.Printf("e-mail não enviado: %v", err)
	}
}

func sendSMTP(cfg *SMTPCfg, opener *Opener, subject, body string) error {
	password := ""
	if cfg.Username != "" {
		var err error
		if password, err = opener.Open(cfg.Password, "senha do SMTP"); err != nil {
			return err
		}
	}
	port := cfg.Port
	if port == 0 {
		port = 587
	}
	addr := net.JoinHostPort(cfg.Host, strconv.Itoa(port))
	tlsConfig := &tls.Config{ServerName: cfg.Host, MinVersion: tls.VersionTLS12}

	var conn net.Conn
	var err error
	dialer := &net.Dialer{Timeout: 20 * time.Second}
	if cfg.Security == "tls" {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, tlsConfig)
	} else {
		conn, err = dialer.Dial("tcp", addr)
	}
	if err != nil {
		return err
	}
	_ = conn.SetDeadline(time.Now().Add(60 * time.Second))
	client, err := smtp.NewClient(conn, cfg.Host)
	if err != nil {
		conn.Close()
		return err
	}
	defer client.Close()
	if cfg.Security == "starttls" {
		if err := client.StartTLS(tlsConfig); err != nil {
			return fmt.Errorf("STARTTLS: %w", err)
		}
	}
	if cfg.Username != "" {
		if err := client.Auth(smtp.PlainAuth("", cfg.Username, password, cfg.Host)); err != nil {
			return fmt.Errorf("autenticação: %w", err)
		}
	}
	sender := cfg.Sender
	if sender == "" {
		sender = cfg.Username
	}
	if err := client.Mail(sender); err != nil {
		return err
	}
	for _, to := range cfg.To {
		if err := client.Rcpt(strings.TrimSpace(to)); err != nil {
			return err
		}
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	headers := []string{
		"From: " + sender,
		"To: " + strings.Join(cfg.To, ", "),
		"Subject: " + mime.QEncoding.Encode("utf-8", subject),
		"Date: " + time.Now().Format(time.RFC1123Z),
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=utf-8",
		"Content-Transfer-Encoding: 8bit",
	}
	msg := strings.Join(headers, "\r\n") + "\r\n\r\n" + strings.ReplaceAll(body, "\n", "\r\n")
	if _, err := w.Write([]byte(msg)); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return client.Quit()
}
