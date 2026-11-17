package main

// Junção de conversas que mudaram em dois PCs.
//
// Uma conversa do Claude Code (.jsonl) é uma lista de linhas, uma por evento,
// cada mensagem com seu uuid e o da anterior. O Claude Code só acrescenta
// linhas; ao retomar, monta a árvore pelas ligações e segue a mensagem mais
// recente. Então, quando dois PCs acrescentaram coisas diferentes, nenhuma
// precisa ser descartada: a união das linhas guarda as duas.
//
// A junção é determinística (as mesmas duas versões dão o mesmo resultado em
// qualquer PC), para os PCs convergirem em vez de trocarem versões entre si:
// o começo comum fica como está, e o resto das duas vai em ordem de horário.

import (
	"bytes"
	"encoding/json"
	"sort"
	"strings"
)

type mergeOutcome int

const (
	takeTheirs mergeOutcome = iota // a de lá já tem tudo da daqui
	keepMine                       // a daqui já tem tudo da de lá
	merged                         // cada uma tinha algo que a outra não tinha
)

// completeLines devolve as linhas terminadas em \n. Uma última linha sem \n
// (escrita em andamento ou envio cortado) fica de fora.
func completeLines(data []byte) []string {
	text := string(data)
	if i := strings.LastIndexByte(text, '\n'); i >= 0 {
		text = text[:i]
	} else {
		return nil
	}
	return strings.Split(text, "\n")
}

// endsComplete: o arquivo está vazio ou termina numa linha inteira.
func endsComplete(data []byte) bool {
	return len(data) == 0 || data[len(data)-1] == '\n'
}

func containsAll(set map[string]struct{}, lines []string) bool {
	for _, l := range lines {
		if _, ok := set[l]; !ok {
			return false
		}
	}
	return true
}

func lineSet(lines []string) map[string]struct{} {
	set := make(map[string]struct{}, len(lines))
	for _, l := range lines {
		set[l] = struct{}{}
	}
	return set
}

func lineTimestamp(line string) string {
	var head struct {
		Timestamp string `json:"timestamp"`
	}
	if json.Unmarshal([]byte(line), &head) != nil {
		return ""
	}
	return head.Timestamp
}

// mergeConversation junta duas versões da mesma conversa sem perder linha.
func mergeConversation(mine, theirs []byte) ([]byte, mergeOutcome) {
	ml, tl := completeLines(mine), completeLines(theirs)
	if containsAll(lineSet(tl), ml) {
		return theirs, takeTheirs
	}
	if containsAll(lineSet(ml), tl) {
		return mine, keepMine
	}
	n := 0
	for n < len(ml) && n < len(tl) && ml[n] == tl[n] {
		n++
	}
	prefix := ml[:n]
	seen := lineSet(prefix)
	start := ""
	for i := len(prefix) - 1; i >= 0 && start == ""; i-- {
		start = lineTimestamp(prefix[i])
	}
	// Linha sem horário (metadados) herda o da linha anterior da mesma versão,
	// para ficar perto de onde foi escrita.
	keys := map[string]string{}
	collect := func(lines []string) {
		last := start
		for _, l := range lines {
			if ts := lineTimestamp(l); ts != "" {
				last = ts
			}
			if _, dup := seen[l]; dup {
				continue
			}
			if k, ok := keys[l]; !ok || last < k {
				keys[l] = last
			}
		}
	}
	collect(ml[n:])
	collect(tl[n:])
	rest := make([]string, 0, len(keys))
	for l := range keys {
		rest = append(rest, l)
	}
	sort.Slice(rest, func(i, j int) bool {
		if keys[rest[i]] != keys[rest[j]] {
			return keys[rest[i]] < keys[rest[j]]
		}
		return rest[i] < rest[j]
	})
	var out bytes.Buffer
	for _, l := range prefix {
		out.WriteString(l)
		out.WriteByte('\n')
	}
	for _, l := range rest {
		out.WriteString(l)
		out.WriteByte('\n')
	}
	return out.Bytes(), merged
}
