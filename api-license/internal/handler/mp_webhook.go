package handler

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	xcrypto "github.com/xsp/api-license/internal/crypto"
	"github.com/xsp/api-license/internal/model"
	"github.com/xsp/api-license/internal/repo"
)

// Mercado Pago webhook handler.
//
// Fluxo:
//   1. MP envia POST /webhooks/mp com {type, action, data:{id}}
//   2. Verificamos assinatura HMAC (x-signature) usando MP_WEBHOOK_SECRET
//   3. Buscamos detalhes do pagamento na API do MP
//   4. Se "payment.approved" → criamos/renovamos KEY conforme metadata
//   5. Disparamos webhook próprio (opcional) para o cliente saber

type MPHandler struct {
	repo        *repo.Repo
	accessToken string // MP_ACCESS_TOKEN
	whSecret    string // MP_WEBHOOK_SECRET
	defaultPlan string // ex: "pro"
	periodDays  int    // ex: 30
}

func NewMP(r *repo.Repo, accessToken, whSecret, defaultPlan string, periodDays int) *MPHandler {
	if defaultPlan == "" {
		defaultPlan = "pro"
	}
	if periodDays == 0 {
		periodDays = 30
	}
	return &MPHandler{repo: r, accessToken: accessToken, whSecret: whSecret,
		defaultPlan: defaultPlan, periodDays: periodDays}
}

type mpNotification struct {
	Type   string `json:"type"`
	Action string `json:"action"`
	Data   struct {
		ID string `json:"id"`
	} `json:"data"`
}

type mpPayment struct {
	ID            int64  `json:"id"`
	Status        string `json:"status"`
	StatusDetail  string `json:"status_detail"`
	TransAmount   float64 `json:"transaction_amount"`
	CurrencyID    string `json:"currency_id"`
	ExternalRef   string `json:"external_reference"`
	Payer         struct {
		Email     string `json:"email"`
		FirstName string `json:"first_name"`
		LastName  string `json:"last_name"`
	} `json:"payer"`
	Metadata map[string]any `json:"metadata"`
}

// Webhook entrypoint
func (h *MPHandler) Handle(c *fiber.Ctx) error {
	body := c.Body()

	// 1) Verifica assinatura HMAC (formato MP: x-signature: ts=...,v1=...)
	if err := h.verifySignature(c, body); err != nil {
		return fiber.NewError(401, fmt.Sprintf("signature: %s", err.Error()))
	}

	var notif mpNotification
	if err := json.Unmarshal(body, &notif); err != nil {
		return fiber.NewError(400, "bad_payload")
	}

	// Aceita apenas pagamentos
	if !strings.HasPrefix(notif.Type, "payment") || notif.Data.ID == "" {
		return c.JSON(fiber.Map{"status": "ignored", "type": notif.Type})
	}

	// 2) Busca o pagamento na API MP
	payment, err := h.fetchPayment(c.Context(), notif.Data.ID)
	if err != nil {
		return fiber.NewError(500, "fetch_payment: "+err.Error())
	}

	// 3) Idempotência — se já processado, ignora
	if h.alreadyProcessed(c, payment.ID) {
		return c.JSON(fiber.Map{"status": "already_processed", "id": payment.ID})
	}

	// 4) Só age em pagamentos APROVADOS
	if payment.Status != "approved" {
		return c.JSON(fiber.Map{"status": "skipped", "payment_status": payment.Status})
	}

	// 5) Cria/renova licença
	result, err := h.provisionLicense(c, payment)
	if err != nil {
		return fiber.NewError(500, "provision: "+err.Error())
	}

	return c.JSON(fiber.Map{
		"status":  "ok",
		"payment_id": payment.ID,
		"result":  result,
	})
}

// ─── Assinatura HMAC do Mercado Pago ────────────────────────────────────────
// MP envia: x-signature: ts=1700000000,v1=abc123...
// onde v1 = HMAC-SHA256(secret, "id:<data_id>;request-id:<x-request-id>;ts:<ts>;")
func (h *MPHandler) verifySignature(c *fiber.Ctx, body []byte) error {
	if h.whSecret == "" {
		return errors.New("MP_WEBHOOK_SECRET not configured")
	}
	sigHeader := c.Get("x-signature")
	if sigHeader == "" {
		return errors.New("missing x-signature")
	}

	var ts, v1 string
	for _, part := range strings.Split(sigHeader, ",") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "ts":
			ts = kv[1]
		case "v1":
			v1 = kv[1]
		}
	}
	if ts == "" || v1 == "" {
		return errors.New("malformed signature")
	}

	// Anti-replay: rejeita ts > 5 min
	tsInt, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || time.Now().Unix()-tsInt > 300 {
		return errors.New("stale signature")
	}

	// Reconstrói o manifest e calcula HMAC esperado
	dataID := c.Query("data.id")
	if dataID == "" {
		// MP às vezes envia no body também
		var n mpNotification
		_ = json.Unmarshal(body, &n)
		dataID = n.Data.ID
	}
	reqID := c.Get("x-request-id")
	manifest := fmt.Sprintf("id:%s;request-id:%s;ts:%s;", dataID, reqID, ts)

	mac := hmac.New(sha256.New, []byte(h.whSecret))
	mac.Write([]byte(manifest))
	expected := hex.EncodeToString(mac.Sum(nil))

	if !hmac.Equal([]byte(expected), []byte(v1)) {
		return errors.New("signature mismatch")
	}
	return nil
}

// ─── Busca detalhes do pagamento na API MP ─────────────────────────────────
func (h *MPHandler) fetchPayment(ctx interface{}, id string) (*mpPayment, error) {
	if h.accessToken == "" {
		return nil, errors.New("MP_ACCESS_TOKEN not configured")
	}
	req, _ := http.NewRequest("GET",
		"https://api.mercadopago.com/v1/payments/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+h.accessToken)

	cli := &http.Client{Timeout: 8 * time.Second}
	resp, err := cli.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		raw, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("mp api http %d: %s", resp.StatusCode, raw)
	}
	var p mpPayment
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		return nil, err
	}
	return &p, nil
}

// ─── Idempotência ───────────────────────────────────────────────────────────
// Marca payment_id no banco para não processar 2x.
func (h *MPHandler) alreadyProcessed(c *fiber.Ctx, paymentID int64) bool {
	// Usamos a tabela subscriptions com provider='mp' e provider_ref=id
	// Se já existe registro com esse ID, foi processado.
	// (Repositório poderia ter um SELECT específico; aqui consulta direta seria mais limpo,
	// mas para manter modular usamos validation_logs como cache rápido.)
	return false // placeholder — implementar com query dedicada
}

// ─── Provisiona/renova licença ─────────────────────────────────────────────
func (h *MPHandler) provisionLicense(c *fiber.Ctx, p *mpPayment) (map[string]any, error) {
	// Determina plano e período via metadata do pagamento (configure no MP Checkout)
	planCode, _ := p.Metadata["plan_code"].(string)
	if planCode == "" {
		planCode = h.defaultPlan
	}
	periodDays := h.periodDays
	if v, ok := p.Metadata["period_days"].(float64); ok && v > 0 {
		periodDays = int(v)
	}

	email := p.Payer.Email
	if email == "" {
		return nil, errors.New("payer email missing")
	}
	name := strings.TrimSpace(p.Payer.FirstName + " " + p.Payer.LastName)

	plan, err := h.repo.GetPlanByCode(c.Context(), planCode)
	if err != nil {
		return nil, fmt.Errorf("plan %s not found", planCode)
	}

	cust, err := h.repo.UpsertCustomer(c.Context(), email, name, "")
	if err != nil {
		return nil, err
	}

	// Se cliente já tem licença ativa do mesmo plano → estende. Senão cria nova.
	existing := h.findActiveLicense(c, cust.ID, plan.ID)
	if existing != nil {
		newExp := existing.ExpiresAt.Add(time.Duration(periodDays) * 24 * time.Hour)
		if time.Now().After(existing.ExpiresAt) {
			// estava expirada — renova a partir de agora
			newExp = time.Now().Add(time.Duration(periodDays) * 24 * time.Hour)
		}
		if err := h.repo.ExtendLicense(c.Context(), existing.ID, newExp); err != nil {
			return nil, err
		}
		return map[string]any{
			"action":     "extended",
			"license_id": existing.ID,
			"key":        existing.Key,
			"expires_at": newExp,
		}, nil
	}

	// Nova KEY
	key, err := xcrypto.GenerateLicenseKey()
	if err != nil {
		return nil, err
	}
	lic := &model.License{
		CustomerID:   cust.ID,
		PlanID:       plan.ID,
		Key:          key,
		KeyHash:      xcrypto.HashKey(key),
		Status:       "active",
		ExpiresAt:    time.Now().Add(time.Duration(periodDays) * 24 * time.Hour),
		MaxInstances: plan.MaxInstances,
		GracePeriodH: 24,
		Notes:        fmt.Sprintf("mp:%d", p.ID),
	}
	if err := h.repo.CreateLicense(c.Context(), lic); err != nil {
		return nil, err
	}

	// TODO: enviar e-mail/webhook ao cliente com a KEY + link
	// emailService.SendNewKey(email, key, lic.ExpiresAt)

	return map[string]any{
		"action":     "created",
		"license_id": lic.ID,
		"key":        key,
		"expires_at": lic.ExpiresAt,
		"customer":   email,
	}, nil
}

// findActiveLicense é um helper — em produção, mover para repo.
func (h *MPHandler) findActiveLicense(c *fiber.Ctx, custID uuid.UUID, planID int) *model.License {
	licList, err := h.repo.ListLicenses(c.Context(), 200, 0)
	if err != nil {
		return nil
	}
	for i := range licList {
		l := &licList[i]
		if l.CustomerID == custID && l.PlanID == planID &&
			(l.Status == "active" || l.Status == "expired") {
			return l
		}
	}
	return nil
}
