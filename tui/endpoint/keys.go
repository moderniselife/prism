package endpoint

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/zalando/go-keyring"
)

// Keyring service shared with the macOS app's Keychain items.
const keyringService = "com.mojolayers.prism.endpoint"

// Keys stores API keys in the system's credential store (Windows
// Credential Manager, the Secret Service on Linux, the macOS Keychain).
// Where no store is available (a Linux box without a keyring daemon) it
// falls back to a 0600 file next to the config and says so.
type Keys struct {
	mu       sync.Mutex
	cache    map[string]string
	fallback string
	// UsingFile reports that keys went to the fallback file.
	UsingFile bool
	// Memory keeps keys in memory only (tests).
	Memory bool
}

func NewKeys(dir string) *Keys {
	return &Keys{cache: map[string]string{}, fallback: filepath.Join(dir, "endpoint-keys.json")}
}

func (k *Keys) Get(id string) string {
	k.mu.Lock()
	if v, ok := k.cache[id]; ok {
		k.mu.Unlock()
		return v
	}
	k.mu.Unlock()
	if k.Memory {
		return ""
	}
	v, err := keyring.Get(keyringService, id)
	if err != nil {
		v = k.fileGet(id)
	}
	if v != "" {
		k.mu.Lock()
		k.cache[id] = v
		k.mu.Unlock()
	}
	return v
}

func (k *Keys) Has(id string) bool { return k.Get(id) != "" }

// Set stores the key; an empty key deletes it.
func (k *Keys) Set(id, key string) error {
	k.mu.Lock()
	if key == "" {
		delete(k.cache, id)
	} else {
		k.cache[id] = key
	}
	k.mu.Unlock()
	if k.Memory {
		return nil
	}
	if key == "" {
		_ = keyring.Delete(keyringService, id)
		return k.fileSet(id, "")
	}
	if err := keyring.Set(keyringService, id, key); err != nil {
		k.UsingFile = true
		return k.fileSet(id, key)
	}
	return nil
}

func (k *Keys) fileGet(id string) string {
	data, err := os.ReadFile(k.fallback)
	if err != nil {
		return ""
	}
	m := map[string]string{}
	_ = json.Unmarshal(data, &m)
	if m[id] != "" {
		k.UsingFile = true
	}
	return m[id]
}

func (k *Keys) fileSet(id, key string) error {
	m := map[string]string{}
	if data, err := os.ReadFile(k.fallback); err == nil {
		_ = json.Unmarshal(data, &m)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if key == "" {
		if _, ok := m[id]; !ok {
			return nil
		}
		delete(m, id)
	} else {
		m[id] = key
	}
	if err := os.MkdirAll(filepath.Dir(k.fallback), 0o700); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(m, "", "  ")
	return os.WriteFile(k.fallback, data, 0o600)
}
