package main

// O Claude Code grava as conversas em <pasta do Claude>/projects/<nome>/, e o
// nome sai do caminho absoluto do projeto (tudo que não é letra ou número
// vira "-"). Em outro PC o caminho muda, então no Nextcloud as conversas
// ficam pelo nome do projeto: projects/<projeto>/.
//
// Para saber de que projeto é uma pasta local, o app olha:
//   1. os vínculos feitos na interface (projeto → caminho neste PC);
//   2. os projetos que o Claude Code já abriu neste PC (.claude.json);
//   3. o campo "cwd" dentro das próprias conversas.

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
)

var notAlnum = regexp.MustCompile(`[^A-Za-z0-9]`)
var notKeySafe = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func encodeProjectDir(path string) string {
	return notAlnum.ReplaceAllString(path, "-")
}

// foldName compara nomes de pasta como o sistema de arquivos: sem caixa no Windows e no macOS.
func foldName(name string) string {
	if runtime.GOOS == "linux" {
		return name
	}
	return strings.ToLower(name)
}

func samePath(a, b string) bool {
	clean := func(p string) string { return foldName(filepath.Clean(strings.ReplaceAll(p, "\\", "/"))) }
	return clean(a) == clean(b)
}

func baseName(path string) string {
	path = strings.TrimRight(strings.ReplaceAll(path, "\\", "/"), "/")
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[i+1:]
	}
	return path
}

func projectKey(cfg *Config, path string) string {
	for alias, key := range cfg.Aliases {
		if samePath(alias, path) {
			return key
		}
	}
	name := baseName(path)
	if key, ok := cfg.Aliases[name]; ok {
		return key
	}
	key := notKeySafe.ReplaceAllString(name, "-")
	if key == "" {
		return "raiz"
	}
	return key
}

// projectCwd lê o caminho do projeto de dentro das conversas da pasta.
func projectCwd(folder string) string {
	files, _ := filepath.Glob(filepath.Join(folder, "*.jsonl"))
	sort.Slice(files, func(i, j int) bool { return modTime(files[i]) > modTime(files[j]) })
	for _, file := range files {
		f, err := os.Open(file)
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
		for i := 0; i < 50 && scanner.Scan(); i++ {
			var line struct {
				Cwd string `json:"cwd"`
			}
			if json.Unmarshal(scanner.Bytes(), &line) == nil && line.Cwd != "" {
				f.Close()
				return line.Cwd
			}
		}
		f.Close()
	}
	return ""
}

func modTime(path string) int64 {
	if info, err := os.Stat(path); err == nil {
		return info.ModTime().UnixNano()
	}
	return 0
}

// knownProjects são os caminhos que o Claude Code já abriu (chaves de "projects" no .claude.json).
func knownProjects(syncDir string) []string {
	data, err := os.ReadFile(filepath.Join(syncDir, ".claude.json"))
	if err != nil {
		return nil
	}
	var cfg struct {
		Projects map[string]json.RawMessage `json:"projects"`
	}
	if json.Unmarshal(data, &cfg) != nil {
		return nil
	}
	paths := make([]string, 0, len(cfg.Projects))
	for path := range cfg.Projects {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths
}

type LocalProject struct {
	Key    string // nome no Nextcloud
	Folder string // nome da pasta em projects/
	Path   string // caminho do projeto neste PC
}

// projectMap liga cada pasta local (existente ou a criar) a um projeto.
type projectMap struct {
	cwdCache map[string]string
}

func (m *projectMap) resolve(cfg *Config) []LocalProject {
	if m.cwdCache == nil {
		m.cwdCache = map[string]string{}
	}
	byFolder := map[string]LocalProject{}
	add := func(p LocalProject) {
		if _, ok := byFolder[foldName(p.Folder)]; !ok {
			byFolder[foldName(p.Folder)] = p
		}
	}
	for key, path := range cfg.Links {
		add(LocalProject{Key: key, Folder: encodeProjectDir(path), Path: path})
	}
	for _, path := range knownProjects(cfg.SyncDir) {
		add(LocalProject{Key: projectKey(cfg, path), Folder: encodeProjectDir(path), Path: path})
	}
	entries, _ := os.ReadDir(filepath.Join(cfg.SyncDir, "projects"))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if _, ok := byFolder[foldName(entry.Name())]; ok {
			// Mesmo nome de pasta, outra caixa (C: e c:): usa a que existe no disco.
			p := byFolder[foldName(entry.Name())]
			p.Folder = entry.Name()
			byFolder[foldName(entry.Name())] = p
			continue
		}
		cwd, ok := m.cwdCache[entry.Name()]
		if !ok {
			cwd = projectCwd(filepath.Join(cfg.SyncDir, "projects", entry.Name()))
			if cwd != "" {
				m.cwdCache[entry.Name()] = cwd
			}
		}
		if cwd != "" {
			add(LocalProject{Key: projectKey(cfg, cwd), Folder: entry.Name(), Path: cwd})
		}
	}
	out := make([]LocalProject, 0, len(byFolder))
	for _, p := range byFolder {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key+out[i].Folder < out[j].Key+out[j].Folder })
	return out
}
