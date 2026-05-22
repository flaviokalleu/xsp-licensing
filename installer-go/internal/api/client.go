package api

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

type Client struct {
	BaseURL      string
	HMACSecret   string
	HTTP         *http.Client
	UserAgent    string
}

func New(base, hmacSecret string) *Client {
	return &Client{
		BaseURL:    base,
		HMACSecret: hmacSecret,
		UserAgent:  "xsp-installer/1.0",
		HTTP:       &http.Client{Timeout: 20 * time.Second},
	}
}

func (c *Client) sign(method, path string, body []byte) (ts, nonce, sig string) {
	ts = strconv.FormatInt(time.Now().Unix(), 10)
	nb := make([]byte, 16)
	rand.Read(nb)
	nonce = hex.EncodeToString(nb)
	mac := hmac.New(sha256.New, []byte(c.HMACSecret))
	mac.Write([]byte(method + path))
	mac.Write(body)
	mac.Write([]byte(ts + nonce))
	sig = hex.EncodeToString(mac.Sum(nil))
	return
}

func (c *Client) post(path string, in any, headers map[string]string) (map[string]any, int, error) {
	body, err := json.Marshal(in)
	if err != nil {
		return nil, 0, err
	}
	ts, nonce, sig := c.sign(http.MethodPost, path, body)
	req, _ := http.NewRequest(http.MethodPost, c.BaseURL+path, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", c.UserAgent)
	req.Header.Set("X-Timestamp", ts)
	req.Header.Set("X-Nonce", nonce)
	req.Header.Set("X-Signature", sig)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	if resp.StatusCode >= 400 {
		return m, resp.StatusCode, fmt.Errorf("http %d: %s", resp.StatusCode, string(raw))
	}
	return m, resp.StatusCode, nil
}

type ActivateReq struct {
	Key              string            `json:"key"`
	HWID             string            `json:"hwid"`
	Hostname         string            `json:"hostname"`
	PublicIP         string            `json:"public_ip"`
	Domain           string            `json:"domain"`
	Email            string            `json:"email"`
	OS               string            `json:"os"`
	OSVersion        string            `json:"os_version"`
	PanelVersion     string            `json:"panel_version"`
	InstallerVersion string            `json:"installer_version"`
	Fingerprint      map[string]string `json:"fingerprint"`
}

type ActivateResp struct {
	InstallationID    string         `json:"installation_id"`
	LicenseToken      string         `json:"license_token"`
	MasterKeySealed   string         `json:"master_key_sealed"`
	MasterKeyNonce    string         `json:"master_key_nonce"`
	ExpiresAt         time.Time      `json:"expires_at"`
	HeartbeatInterval int            `json:"heartbeat_interval_s"`
	Manifest          map[string]any `json:"manifest"`
	RegistryToken     string         `json:"registry_token"`
}

func (c *Client) Activate(in ActivateReq) (*ActivateResp, error) {
	m, _, err := c.post("/v1/activate", in, nil)
	if err != nil {
		return nil, err
	}
	b, _ := json.Marshal(m)
	var out ActivateResp
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	if out.InstallationID == "" {
		return nil, fmt.Errorf("invalid response: missing installation_id")
	}
	return &out, nil
}

func (c *Client) Deactivate(installationID string) error {
	_, _, err := c.post("/v1/deactivate", struct{}{},
		map[string]string{"X-Installation-ID": installationID})
	return err
}
