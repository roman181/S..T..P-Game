#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Jimmy – Vollständige Installation für Termux
#  Enthält: Go, Ollama, llama3.2:3b, Plan-Loop, Web-UI,
#           Multi-Plan, WebSocket, Pause/Resume, Session
# ============================================================

set -e

echo "=== [1/9] Termux-Grundsetup ==="
pkg update -y && pkg upgrade -y
pkg install -y git curl wget build-essential binutils
termux-setup-storage || true

echo "=== [2/9] Go installieren ==="
pkg install -y golang
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"
grep -qxF 'export GOPATH="$HOME/go"' ~/.bashrc || echo 'export GOPATH="$HOME/go"' >> ~/.bashrc
grep -qxF 'export PATH="$PATH:$GOPATH/bin"' ~/.bashrc || echo 'export PATH="$PATH:$GOPATH/bin"' >> ~/.bashrc
go version

echo "=== [3/9] Ollama installieren ==="
if command -v ollama &> /dev/null; then
    echo "Ollama bereits vorhanden: $(ollama --version)"
else
    if pkg install -y ollama 2>/dev/null; then
        echo "✓ Ollama aus Repository installiert."
    else
        echo "⚠ Repository-Installation fehlgeschlagen. Nutze Source-Installer..."
        curl -sL https://github.com/Anon4You/ollama-in-termux/raw/main/ollama.sh | bash
    fi
fi

echo "=== [4/9] Ollama-Server starten & Modell laden ==="
nohup ollama serve > /dev/null 2>&1 &
sleep 3
echo "Lade llama3.2:3b (~2 GB, kann einige Minuten dauern)..."
ollama pull llama3.2:3b || echo "⚠ Modell-Download fehlgeschlagen – bitte später manuell: ollama pull llama3.2:3b"

echo "=== [5/9] Projektverzeichnis anlegen ==="
mkdir -p "$HOME/jimmy/templates" "$HOME/jimmy/plans"
cd "$HOME/jimmy"
if [ ! -f go.mod ]; then
    go mod init jimmy
fi

echo "=== [6/9] Go-Quelldateien schreiben ==="

cat > plan.go <<'GOEOF'
package main

type TaskState int

const (
	Pending TaskState = iota
	InProgress
	Completed
	Failed
)

func (s TaskState) String() string {
	switch s {
	case Pending:
		return "Pending"
	case InProgress:
		return "InProgress"
	case Completed:
		return "Completed"
	case Failed:
		return "Failed"
	}
	return "Unknown"
}

type Task struct {
	ID          string    `json:"id"`
	Description string    `json:"description"`
	State       TaskState `json:"state"`
	Result      string    `json:"result,omitempty"`
	Error       string    `json:"error,omitempty"`
	Attempts    int       `json:"attempts"`
	MaxAttempts int       `json:"max_attempts"`
}

type Plan struct {
	Goal      string  `json:"goal"`
	Tasks     []*Task `json:"tasks"`
	MaxRounds int     `json:"max_rounds"`
	Round     int     `json:"round"`
}

func (p *Plan) IsAllDone() bool {
	for _, t := range p.Tasks {
		if t.State != Completed && t.State != Failed {
			return false
		}
	}
	return true
}

func (p *Plan) GetNextPendingTask() *Task {
	for _, t := range p.Tasks {
		if t.State == Pending {
			return t
		}
	}
	return nil
}

func (p *Plan) AddTask(t *Task) {
	if t.MaxAttempts == 0 {
		t.MaxAttempts = 3
	}
	p.Tasks = append(p.Tasks, t)
}
GOEOF

cat > loop.go <<'GOEOF'
package main

import (
	"context"
	"errors"
	"fmt"
)

type Executor func(task *Task) (result string, newTasks []*Task, err error)

func RunPlanLoop(plan *Plan, execute Executor, replanner Replanner, ctrl *LoopController) (*Plan, error) {
	if plan.MaxRounds <= 0 {
		plan.MaxRounds = 15
	}

	for plan.Round < plan.MaxRounds {
		if err := ctrl.Wait(context.Background()); err != nil {
			return plan, err
		}
		if plan.IsAllDone() {
			return plan, nil
		}

		task := plan.GetNextPendingTask()
		if task == nil {
			return plan, errors.New("keine ausführbaren Tasks mehr")
		}

		plan.Round++
		fmt.Printf("\n=== Runde %d | Task %q (%s) ===\n",
			plan.Round, task.ID, task.Description)

		task.State = InProgress
		result, newTasks, err := execute(task)

		if err != nil {
			task.State = Failed
			task.Error = err.Error()
		} else {
			task.State = Completed
			task.Result = result
		}
		task.Attempts++

		for _, nt := range newTasks {
			plan.AddTask(nt)
		}

		if err := replanner.Update(plan, task); err != nil {
			return plan, err
		}
	}

	return plan, errors.New("MaxRounds erreicht, Plan nicht vollständig abgeschlossen")
}
GOEOF

cat > replanner.go <<'GOEOF'
package main

import "fmt"

type Replanner interface {
	Update(plan *Plan, last *Task) error
}

type DefaultReplanner struct {
	OnSuccess func(plan *Plan, t *Task) []*Task
}

func (r *DefaultReplanner) Update(plan *Plan, last *Task) error {
	switch last.State {
	case Failed:
		if last.Attempts < last.MaxAttempts {
			last.Attempts++
			last.State = Pending
			last.Error = ""
			fmt.Printf("↻ Replan: Task %q wird erneut versucht (%d/%d)\n",
				last.ID, last.Attempts, last.MaxAttempts)
		} else {
			fmt.Printf("✗ Replan: Task %q endgültig fehlgeschlagen\n", last.ID)
		}
	case Completed:
		if r.OnSuccess != nil {
			for _, nt := range r.OnSuccess(plan, last) {
				plan.AddTask(nt)
				fmt.Printf("+ Replan: Neue Task %q hinzugefügt\n", nt.ID)
			}
		}
	}
	return nil
}
GOEOF

cat > store.go <<'GOEOF'
package main

import (
	"encoding/json"
	"os"
)

func LoadPlan(path string) (*Plan, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p Plan
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	for _, t := range p.Tasks {
		if t.MaxAttempts == 0 {
			t.MaxAttempts = 3
		}
	}
	return &p, nil
}

func SavePlan(path string, p *Plan) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
GOEOF

cat > control.go <<'GOEOF'
package main

import (
	"context"
	"sync"
)

type LoopController struct {
	mu       sync.Mutex
	paused   bool
	resumeCh chan struct{}
	stopCh   chan struct{}
	stopped  bool
}

func NewLoopController() *LoopController {
	return &LoopController{stopCh: make(chan struct{})}
}

func (c *LoopController) Pause() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.paused || c.stopped {
		return
	}
	c.paused = true
	c.resumeCh = make(chan struct{})
}

func (c *LoopController) Resume() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.paused {
		return
	}
	c.paused = false
	close(c.resumeCh)
}

func (c *LoopController) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped {
		return
	}
	c.stopped = true
	if c.paused {
		c.paused = false
		close(c.resumeCh)
	}
	close(c.stopCh)
}

func (c *LoopController) IsPaused() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.paused
}

func (c *LoopController) Wait(ctx context.Context) error {
	c.mu.Lock()
	paused, ch, stopped, stopCh := c.paused, c.resumeCh, c.stopped, c.stopCh
	c.mu.Unlock()

	if stopped {
		return context.Canceled
	}
	if !paused {
		select {
		case <-stopCh:
			return context.Canceled
		case <-ctx.Done():
			return ctx.Err()
		default:
			return nil
		}
	}
	select {
	case <-ch:
		return nil
	case <-stopCh:
		return context.Canceled
	case <-ctx.Done():
		return ctx.Err()
	}
}
GOEOF

cat > plans.go <<'GOEOF'
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const plansDir = "plans"

type PlanMeta struct {
	ID        string    `json:"id"`
	Goal      string    `json:"goal"`
	TaskCount int       `json:"task_count"`
	DoneCount int       `json:"done_count"`
	UpdatedAt time.Time `json:"updated_at"`
}

func ensurePlansDir() error {
	return os.MkdirAll(plansDir, 0o755)
}

func newPlanID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func ListPlans() ([]PlanMeta, error) {
	if err := ensurePlansDir(); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(plansDir)
	if err != nil {
		return nil, err
	}
	var metas []PlanMeta
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		id := e.Name()[:len(e.Name())-5]
		p, err := LoadPlan(filepath.Join(plansDir, e.Name()))
		if err != nil {
			continue
		}
		info, _ := e.Info()
		var done int
		for _, t := range p.Tasks {
			if t.State == Completed {
				done++
			}
		}
		metas = append(metas, PlanMeta{
			ID: id, Goal: p.Goal, TaskCount: len(p.Tasks),
			DoneCount: done, UpdatedAt: info.ModTime(),
		})
	}
	sort.Slice(metas, func(i, j int) bool {
		return metas[i].UpdatedAt.After(metas[j].UpdatedAt)
	})
	return metas, nil
}

func SavePlanAs(id string, p *Plan) error {
	if err := ensurePlansDir(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(plansDir, id+".json"), data, 0o644)
}

func LoadPlanByID(id string) (*Plan, error) {
	return LoadPlan(filepath.Join(plansDir, id+".json"))
}

func DeletePlan(id string) error {
	return os.Remove(filepath.Join(plansDir, id+".json"))
}
GOEOF

cat > session.go <<'GOEOF'
package main

import (
	"encoding/json"
	"os"
	"time"
)

const sessionPath = "session.json"

type Session struct {
	ActiveID    string    `json:"active_id"`
	RunningID   string    `json:"running_id,omitempty"`
	Paused      bool      `json:"paused"`
	RunningGoal string    `json:"running_goal,omitempty"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func LoadSession() (*Session, error) {
	data, err := os.ReadFile(sessionPath)
	if err != nil {
		return nil, err
	}
	var s Session
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

func SaveSession(s *Session) error {
	s.UpdatedAt = time.Now()
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(sessionPath, data, 0o644)
}
GOEOF

cat > web.go <<'GOEOF'
package main

import (
	"context"
	"embed"
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

//go:embed templates/index.html
var templateFS embed.FS

type WSMessage struct {
	Type   string `json:"type"`
	Task   *Task  `json:"task,omitempty"`
	Msg    string `json:"msg,omitempty"`
	Goal   string `json:"goal,omitempty"`
	PlanID string `json:"plan_id,omitempty"`
}

type WebServer struct {
	jimmy *Jimmy
	tmpl  *template.Template

	mu          sync.Mutex
	activePlan  *Plan
	activeID    string
	running     bool
	runningGoal string
	runningID   string
	loopStarted bool
	ctrl        *LoopController

	clientsMu sync.Mutex
	clients   map[*websocket.Conn]context.CancelFunc
}

func NewWebServer(jimmy *Jimmy) *WebServer {
	tmpl := template.Must(template.ParseFS(templateFS, "templates/*.html"))
	s := &WebServer{
		jimmy:   jimmy,
		tmpl:    tmpl,
		clients: make(map[*websocket.Conn]context.CancelFunc),
	}
	if sess, err := LoadSession(); err == nil && sess.ActiveID != "" {
		if p, err := LoadPlanByID(sess.ActiveID); err == nil {
			s.activePlan = p
			s.activeID = sess.ActiveID
			s.runningID = sess.RunningID
			s.runningGoal = sess.RunningGoal
			if sess.Paused {
				s.ctrl = NewLoopController()
				s.ctrl.Pause()
				s.running = true
			}
		}
	}
	return s
}

func (s *WebServer) saveSessionLocked() {
	_ = SaveSession(&Session{
		ActiveID:    s.activeID,
		RunningID:   s.runningID,
		RunningGoal: s.runningGoal,
		Paused:      s.running && s.ctrl != nil && s.ctrl.IsPaused(),
	})
}

func (s *WebServer) pauseIfRunning() bool {
	s.mu.Lock()
	if !s.running || s.ctrl == nil {
		s.mu.Unlock()
		return false
	}
	s.ctrl.Pause()
	goal := s.runningGoal
	s.saveSessionLocked()
	s.mu.Unlock()
	s.broadcast(WSMessage{Type: "state", Msg: "paused", Goal: goal})
	return true
}

func (s *WebServer) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/api/plans", s.handlePlans)
	mux.HandleFunc("/api/plan", s.handlePlan)
	mux.HandleFunc("/api/plan/", s.handlePlanID)
	mux.HandleFunc("/api/action", s.handleAction)
	return mux
}

func (s *WebServer) handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = s.tmpl.ExecuteTemplate(w, "index.html", nil)
}

func (s *WebServer) handlePlans(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", 405)
		return
	}
	metas, err := ListPlans()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.mu.Lock()
	active := s.activeID
	s.mu.Unlock()
	writeJSON(w, map[string]any{"plans": metas, "active": active})
}

func (s *WebServer) handlePlan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	var req struct{ Goal string `json:"goal"` }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Goal == "" {
		http.Error(w, "goal required", 400)
		return
	}
	plan, err := s.jimmy.planPhase(r.Context(), req.Goal)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	paused := s.pauseIfRunning()
	id := newPlanID()
	if err := SavePlanAs(id, plan); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.mu.Lock()
	s.activePlan = plan
	s.activeID = id
	s.saveSessionLocked()
	s.mu.Unlock()
	s.broadcast(WSMessage{Type: "plan_loaded", PlanID: id})
	writeJSON(w, map[string]any{"id": id, "plan": plan, "paused": paused})
}

func (s *WebServer) handlePlanID(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Path[len("/api/plan/"):]
	switch r.Method {
	case http.MethodGet:
		p, err := LoadPlanByID(id)
		if err != nil {
			http.Error(w, "not found", 404)
			return
		}
		paused := s.pauseIfRunning()
		s.mu.Lock()
		s.activePlan = p
		s.activeID = id
		s.saveSessionLocked()
		s.mu.Unlock()
		s.broadcast(WSMessage{Type: "plan_loaded", PlanID: id})
		writeJSON(w, map[string]any{"plan": p, "paused": paused})
	case http.MethodDelete:
		if err := DeletePlan(id); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		s.mu.Lock()
		if s.activeID == id {
			s.activePlan = nil
			s.activeID = ""
			s.saveSessionLocked()
		}
		s.mu.Unlock()
		w.WriteHeader(204)
	default:
		http.Error(w, "method not allowed", 405)
	}
}

func (s *WebServer) handleAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	var req struct{ Action string `json:"action"` }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad json", 400)
		return
	}

	switch req.Action {
	case "run":
		s.mu.Lock()
		if s.running || s.activePlan == nil {
			s.mu.Unlock()
			http.Error(w, "cannot run", 409)
			return
		}
		s.running = true
		s.ctrl = NewLoopController()
		s.runningGoal = s.activePlan.Goal
		s.runningID = s.activeID
		s.loopStarted = true
		plan := s.activePlan
		id := s.activeID
		ctrl := s.ctrl
		s.saveSessionLocked()
		s.mu.Unlock()
		go s.runLoop(plan, id, ctrl)

	case "pause":
		s.mu.Lock()
		if s.ctrl != nil {
			s.ctrl.Pause()
			s.saveSessionLocked()
		}
		goal := s.runningGoal
		s.mu.Unlock()
		s.broadcast(WSMessage{Type: "state", Msg: "paused", Goal: goal})

	case "resume":
		s.mu.Lock()
		if s.ctrl == nil {
			s.mu.Unlock()
			http.Error(w, "nothing to resume", 409)
			return
		}
		if s.runningID != "" && s.runningID != s.activeID {
			if p, err := LoadPlanByID(s.runningID); err == nil {
				s.activePlan = p
				s.activeID = s.runningID
				s.broadcast(WSMessage{Type: "plan_loaded", PlanID: s.runningID})
			}
		}
		s.ctrl.Resume()
		if s.running && !s.ctrl.IsPaused() && !s.loopStarted {
			plan := s.activePlan
			id := s.runningID
			ctrl := s.ctrl
			s.loopStarted = true
			s.saveSessionLocked()
			s.mu.Unlock()
			go s.runLoop(plan, id, ctrl)
			s.broadcast(WSMessage{Type: "state", Msg: "running"})
			return
		}
		s.saveSessionLocked()
		s.mu.Unlock()
		s.broadcast(WSMessage{Type: "state", Msg: "running"})

	case "stop":
		s.mu.Lock()
		if s.ctrl != nil {
			s.ctrl.Stop()
			s.runningID = ""
			s.runningGoal = ""
			s.saveSessionLocked()
		}
		s.mu.Unlock()

	default:
		http.Error(w, "unknown action", 400)
		return
	}
	w.WriteHeader(202)
}

func (s *WebServer) runLoop(plan *Plan, id string, ctrl *LoopController) {
	defer func() {
		s.mu.Lock()
		s.running = false
		s.ctrl = nil
		s.runningID = ""
		s.runningGoal = ""
		s.loopStarted = false
		s.saveSessionLocked()
		s.mu.Unlock()
		_ = SavePlanAs(id, plan)
	}()

	exec := func(t *Task) (string, []*Task, error) {
		s.broadcast(WSMessage{Type: "task_start", Task: t})
		res, nts, err := s.jimmy.execute(t)
		s.broadcast(WSMessage{Type: "task_done", Task: t, Msg: res})
		return res, nts, err
	}

	if _, err := RunPlanLoop(plan, exec, &DefaultReplanner{}, ctrl); err != nil {
		s.broadcast(WSMessage{Type: "loop_error", Msg: err.Error()})
	} else {
		s.broadcast(WSMessage{Type: "loop_done"})
	}
}

func (s *WebServer) handleWS(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	s.clientsMu.Lock()
	s.clients[c] = cancel
	s.clientsMu.Unlock()
	defer func() {
		s.clientsMu.Lock()
		delete(s.clients, c)
		s.clientsMu.Unlock()
		cancel()
		c.Close(websocket.StatusNormalClosure, "")
	}()

	s.mu.Lock()
	init, _ := json.Marshal(map[string]any{
		"type":    "init",
		"plan":    s.activePlan,
		"plan_id": s.activeID,
		"running": s.running,
		"paused":  s.running && s.ctrl != nil && s.ctrl.IsPaused(),
	})
	s.mu.Unlock()
	_ = c.Write(ctx, websocket.MessageText, init)

	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return
		}
		var cmd struct{ Cmd string `json:"cmd"` }
		if json.Unmarshal(data, &cmd) == nil && cmd.Cmd != "" {
			go s.handleWSCmd(cmd.Cmd)
		}
	}
}

func (s *WebServer) handleWSCmd(cmd string) {
	switch cmd {
	case "pause":
		s.mu.Lock()
		if s.ctrl != nil {
			s.ctrl.Pause()
			s.saveSessionLocked()
		}
		goal := s.runningGoal
		s.mu.Unlock()
		s.broadcast(WSMessage{Type: "state", Msg: "paused", Goal: goal})
	case "resume":
		s.mu.Lock()
		if s.ctrl != nil {
			s.ctrl.Resume()
			if s.running && !s.ctrl.IsPaused() && !s.loopStarted {
				plan := s.activePlan
				id := s.runningID
				ctrl := s.ctrl
				s.loopStarted = true
				s.saveSessionLocked()
				s.mu.Unlock()
				go s.runLoop(plan, id, ctrl)
				s.broadcast(WSMessage{Type: "state", Msg: "running"})
				return
			}
			s.saveSessionLocked()
		}
		s.mu.Unlock()
		s.broadcast(WSMessage{Type: "state", Msg: "running"})
	case "stop":
		s.mu.Lock()
		if s.ctrl != nil {
			s.ctrl.Stop()
			s.runningID = ""
			s.runningGoal = ""
			s.saveSessionLocked()
		}
		s.mu.Unlock()
	case "ping":
		s.broadcast(WSMessage{Type: "pong"})
	}
}

func (s *WebServer) broadcast(msg WSMessage) {
	data, _ := json.Marshal(msg)
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	for conn := range s.clients {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = conn.Write(ctx, websocket.MessageText, data)
		cancel()
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func StartWebServer(jimmy *Jimmy, addr string) error {
	log.Printf("Jimmy Web-UI → http://localhost%s", addr)
	return http.ListenAndServe(addr, NewWebServer(jimmy).Routes())
}
GOEOF

cat > main.go <<'GOEOF'
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/ollama/ollama/api"
)

type Jimmy struct {
	Client *api.Client
	Model  string
}

func buildPlanSchema() json.RawMessage {
	schema := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"tasks": map[string]any{
				"type": "array",
				"items": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"description":  map[string]any{"type": "string"},
						"max_attempts": map[string]any{"type": "integer"},
					},
					"required": []string{"description"},
				},
			},
		},
		"required": []string{"tasks"},
	}
	raw, _ := json.Marshal(schema)
	return raw
}

func (j *Jimmy) planPhase(ctx context.Context, goal string) (*Plan, error) {
	req := &api.ChatRequest{
		Model: j.Model,
		Messages: []api.Message{
			{Role: "system", Content: "Du bist Jimmy, ein präziser Planer. Zerlege das Ziel in 3–6 atomare Aufgaben. Antworte ausschließlich im JSON-Schema."},
			{Role: "user", Content: "Ziel: " + goal},
		},
		Format:  buildPlanSchema(),
		Options: map[string]any{"temperature": 0.0},
	}
	var out strings.Builder
	if err := j.Client.Chat(ctx, req, func(resp api.ChatResponse) error {
		out.WriteString(resp.Message.Content)
		return nil
	}); err != nil {
		return nil, err
	}
	var pr struct {
		Tasks []struct {
			Description string `json:"description"`
			MaxAttempts int    `json:"max_attempts"`
		} `json:"tasks"`
	}
	if err := json.Unmarshal([]byte(out.String()), &pr); err != nil {
		return nil, fmt.Errorf("Planner-JSON ungültig: %w", err)
	}
	if len(pr.Tasks) == 0 {
		return nil, errors.New("Planner lieferte keine Tasks")
	}
	plan := &Plan{Goal: goal, MaxRounds: 15}
	for i, t := range pr.Tasks {
		maxAtt := t.MaxAttempts
		if maxAtt <= 0 {
			maxAtt = 2
		}
		plan.Tasks = append(plan.Tasks, &Task{
			ID:          fmt.Sprintf("%d", i+1),
			Description: t.Description,
			State:       Pending,
			MaxAttempts: maxAtt,
		})
	}
	return plan, nil
}

func (j *Jimmy) execute(t *Task) (string, []*Task, error) {
	req := &api.ChatRequest{
		Model: j.Model,
		Messages: []api.Message{
			{Role: "system", Content: "Du bist Jimmy, ein präziser Aufgaben-Ausführer. Antworte kurz und sachlich."},
			{Role: "user", Content: "Führe folgende Aufgabe aus und beschreibe das Ergebnis in einem Satz: " + t.Description},
		},
		Options: map[string]any{"temperature": 0.2},
	}
	var out strings.Builder
	if err := j.Client.Chat(context.Background(), req, func(resp api.ChatResponse) error {
		out.WriteString(resp.Message.Content)
		return nil
	}); err != nil {
		return "", nil, err
	}
	return strings.TrimSpace(out.String()), nil, nil
}

func main() {
	client, err := api.ClientFromEnvironment()
	if err != nil {
		log.Fatal(err)
	}
	jimmy := &Jimmy{Client: client, Model: "llama3.2:3b"}

	if len(os.Args) > 1 && os.Args[1] == "web" {
		addr := ":8080"
		if len(os.Args) > 2 {
			addr = os.Args[2]
		}
		log.Fatal(StartWebServer(jimmy, addr))
	}

	goal := strings.Join(os.Args[1:], " ")
	var plan *Plan
	if goal == "" {
		plan, err = LoadPlan("plan.json")
		if err != nil {
			log.Fatal("plan.json nicht ladbar:", err)
		}
	} else {
		fmt.Printf("Plane Ziel: %q\n", goal)
		plan, err = jimmy.planPhase(context.Background(), goal)
		if err != nil {
			log.Fatal("Planner fehlgeschlagen:", err)
		}
	}

	final, err := RunPlanLoop(plan, jimmy.execute, &DefaultReplanner{}, NewLoopController())
	if err != nil {
		fmt.Println("\n⚠ Loop beendet:", err)
	} else {
		fmt.Println("\n✓ Plan vollständig abgeschlossen")
	}
	_ = SavePlan("plan.json", final)
}
GOEOF

echo "=== [7/9] Web-UI (index.html) schreiben ==="
cat > templates/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Jimmy · AI Agent</title>
<style>
  :root{--bg:#0f1115;--panel:#171a21;--border:#2a2f3a;--text:#e6e9ef;--muted:#8b93a7;--accent:#7c5cff;--ok:#3fbf7f;--warn:#f5a623;--err:#ef4444}
  *{box-sizing:border-box}
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
  header{padding:16px 24px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:12px;background:var(--panel);flex-wrap:wrap}
  header h1{margin:0;font-size:18px;font-weight:600}
  header .sub{color:var(--muted);font-size:13px}
  header .dot{width:10px;height:10px;border-radius:50%;background:var(--muted)}
  header .dot.online{background:var(--ok);box-shadow:0 0 8px var(--ok)}
  header .dot.running{background:var(--warn);animation:pulse 1s infinite}
  @keyframes pulse{50%{opacity:.3}}
  main{max-width:1200px;margin:0 auto;padding:20px;display:grid;gap:16px;grid-template-columns:1fr 1fr}
  @media (max-width:900px){main{grid-template-columns:1fr}}
  .panel{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:16px}
  .panel.full{grid-column:1/-1}
  .panel h2{margin:0 0 12px;font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
  .goal-form{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap}
  input[type=text]{flex:1;min-width:160px;background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 12px;color:var(--text);font-size:14px;outline:none}
  input[type=text]:focus{border-color:var(--accent)}
  button{background:var(--accent);color:#fff;border:none;border-radius:8px;padding:8px 14px;font-size:13px;font-weight:500;cursor:pointer;transition:opacity .15s}
  button:hover:not(:disabled){opacity:.85}
  button:disabled{opacity:.4;cursor:not-allowed}
  button.secondary{background:transparent;border:1px solid var(--border);color:var(--text)}
  .controls{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
  .task-list{display:flex;flex-direction:column;gap:6px;max-height:320px;overflow-y:auto}
  .task{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 12px;display:flex;gap:10px;align-items:flex-start}
  .task .badge{font-size:10px;font-weight:600;padding:2px 7px;border-radius:4px;text-transform:uppercase;letter-spacing:.03em;white-space:nowrap}
  .task.Pending .badge{background:var(--muted);color:var(--bg)}
  .task.InProgress .badge{background:var(--warn);color:var(--bg)}
  .task.Completed .badge{background:var(--ok);color:var(--bg)}
  .task.Failed .badge{background:var(--err);color:#fff}
  .task .desc{flex:1;font-size:13px}
  .task .result{font-size:11px;color:var(--muted);margin-top:3px}
  .plan-list{display:flex;flex-direction:column;gap:6px;max-height:280px;overflow-y:auto}
  .plan-item{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 12px;display:flex;gap:8px;align-items:center}
  .plan-item.active{border-color:var(--accent)}
  .log{background:var(--bg);border-radius:8px;padding:10px;font-family:"SF Mono",Menlo,monospace;font-size:11px;line-height:1.55;max-height:380px;overflow-y:auto;color:var(--muted)}
  .log .line{white-space:pre-wrap;word-break:break-word}
  .log .line .time{color:#4a5062;margin-right:6px}
  .log .line.event-start{color:var(--warn)}
  .log .line.event-done{color:var(--ok)}
  .log .line.event-error{color:var(--err)}
  .log .line.event-replan{color:var(--accent)}
  .empty{color:var(--muted);font-size:12px;text-align:center;padding:16px}
</style>
</head>
<body>
<header>
  <h1>Jimmy</h1>
  <span class="sub">AI Agent · Plan-Loop · llama3.2:3b</span>
  <div style="flex:1"></div>
  <div style="display:flex;align-items:center;gap:8px;font-size:13px;color:var(--muted)">
    <span id="status-dot" class="dot"></span>
    <span id="status-text">Verbinde…</span>
  </div>
</header>

<main>
  <section class="panel">
    <h2>Neues Ziel</h2>
    <div class="goal-form">
      <input type="text" id="goal-input" placeholder="z.B. Baue eine Todo-API mit Tests" />
      <button id="plan-btn">Plan erstellen</button>
    </div>
    <h2>Aktiver Plan</h2>
    <div class="task-list" id="task-list"><div class="empty">Noch kein Plan.</div></div>
    <div class="controls">
      <button id="run-btn" disabled>▶ Start</button>
      <button id="pause-btn" class="secondary" disabled>⏸ Pause</button>
      <button id="resume-btn" class="secondary" disabled>▶ Resume</button>
      <button id="stop-btn" class="secondary" disabled>⏹ Stop</button>
    </div>
  </section>

  <section class="panel">
    <h2>Live-Log</h2>
    <div class="log" id="log"><div class="line">Verbinde…</div></div>
  </section>

  <section class="panel full">
    <h2>Meine Pläne</h2>
    <div class="plan-list" id="plan-list"><div class="empty">Lade…</div></div>
  </section>
</main>

<script>
const $=id=>document.getElementById(id);
const taskList=$('task-list'),logEl=$('log'),planList=$('plan-list');
const planBtn=$('plan-btn'),runBtn=$('run-btn'),pauseBtn=$('pause-btn'),resumeBtn=$('resume-btn'),stopBtn=$('stop-btn');
const statusDot=$('status-dot'),statusText=$('status-text');
let currentPlan=null,running=false,ws=null;

function setStatus(text,mode){statusText.textContent=text;statusDot.className='dot '+(mode||'')}
function escapeHtml(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function appendLog(text,cls){
  const time=new Date().toLocaleTimeString('de-DE');
  const line=document.createElement('div');
  line.className='line '+(cls||'');
  line.innerHTML=`<span class="time">${time}</span>${escapeHtml(text)}`;
  logEl.appendChild(line);logEl.scrollTop=logEl.scrollHeight;
}
function stateName(n){return ['Pending','InProgress','Completed','Failed'][n]||'Unknown'}
function updateButtons({running,paused}){
  runBtn.disabled=!!running;
  pauseBtn.disabled=!running||!!paused;
  resumeBtn.disabled=!paused;
  stopBtn.disabled=!running;
}

function renderPlan(plan){
  currentPlan=plan;taskList.innerHTML='';
  if(!plan||!plan.tasks||plan.tasks.length===0){
    taskList.innerHTML='<div class="empty">Noch kein Plan.</div>';return;
  }
  for(const t of plan.tasks){
    const state=stateName(t.state);
    const div=document.createElement('div');
    div.className='task '+state;
    div.innerHTML=`
      <span class="badge">${state}</span>
      <div class="desc">
        <div><strong>${escapeHtml(t.id)}</strong> · ${escapeHtml(t.description)}</div>
        ${t.result?`<div class="result">→ ${escapeHtml(t.result)}</div>`:''}
        ${t.error?`<div class="result" style="color:var(--err)">⚠ ${escapeHtml(t.error)}</div>`:''}
      </div>`;
    taskList.appendChild(div);
  }
}

async function refreshPlan(){
  try{
    const res=await fetch('/api/plans');
    const data=await res.json();
    if(data.active){
      const r2=await fetch('/api/plan/'+data.active);
      const p=await r2.json();
      if(p.plan)renderPlan(p.plan);
    }
  }catch{}
}

async function loadPlans(){
  try{
    const res=await fetch('/api/plans');
    const data=await res.json();
    planList.innerHTML='';
    if(!data.plans||!data.plans.length){planList.innerHTML='<div class="empty">Noch keine Pläne.</div>';return}
    for(const p of data.plans){
      const active=p.id===data.active;
      const div=document.createElement('div');
      div.className='plan-item'+(active?' active':'');
      div.innerHTML=`
        <div style="flex:1;min-width:0">
          <div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><strong>${escapeHtml(p.goal)}</strong></div>
          <div style="font-size:11px;color:var(--muted)">${p.done_count}/${p.task_count} Tasks · ${new Date(p.updated_at).toLocaleString('de-DE')}</div>
        </div>
        <button class="secondary" data-act="load">Laden</button>
        <button class="secondary" data-act="del">✕</button>`;
      div.querySelector('[data-act=load]').onclick=async()=>{
        const r=await fetch('/api/plan/'+p.id);
        const d=await r.json();
        if(d.plan)renderPlan(d.plan);
        if(d.paused){appendLog('⏸ Laufender Loop pausiert.', 'event-replan');setStatus('Pausiert','');updateButtons({running:true,paused:true})}
        loadPlans();
      };
      div.querySelector('[data-act=del]').onclick=async()=>{
        if(!confirm('Plan löschen?'))return;
        await fetch('/api/plan/'+p.id,{method:'DELETE'});
        loadPlans();
      };
      planList.appendChild(div);
    }
  }catch{}
}

async function createPlan(){
  const goal=$('goal-input').value.trim();
  if(!goal)return alert('Bitte ein Ziel eingeben.');
  planBtn.disabled=true;setStatus('Plane…','running');
  appendLog(`Plane Ziel: ${goal}`,'event-replan');
  try{
    const res=await fetch('/api/plan',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({goal})});
    if(!res.ok)throw new Error(await res.text());
    const data=await res.json();
    renderPlan(data.plan);
    runBtn.disabled=false;
    appendLog(`✓ Plan mit ${data.plan.tasks.length} Tasks erstellt.`,'event-done');
    setStatus('Bereit','online');
    if(data.paused){appendLog('⏸ Laufender Loop wurde pausiert.','event-replan');updateButtons({running:true,paused:true})}
    loadPlans();
  }catch(e){
    appendLog('Fehler beim Planen: '+e.message,'event-error');
    setStatus('Fehler','');
  }finally{planBtn.disabled=false}
}

async function doAction(action){
  try{
    const res=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action})});
    if(!res.ok&&res.status!==202)throw new Error(await res.text());
  }catch(e){appendLog('Fehler: '+e.message,'event-error')}
}

function connectWS(){
  const proto=location.protocol==='https:'?'wss':'ws';
  ws=new WebSocket(`${proto}://${location.host}/ws`);
  ws.onmessage=ev=>{try{handleEvent(JSON.parse(ev.data))}catch{}};
  ws.onclose=()=>{setStatus('Getrennt','');setTimeout(connectWS,1500)};
  ws.onopen=()=>setStatus('Verbunden','online');
}

function handleEvent(ev){
  switch(ev.type){
    case 'init':
      if(ev.plan)renderPlan(ev.plan);
      running=ev.running;
      if(ev.paused){
        appendLog('⏸ Pausierter Loop wiederhergestellt. Resume zum Fortsetzen.','event-replan');
        setStatus('Pausiert','');updateButtons({running:true,paused:true});
      }else if(ev.running){
        setStatus('Läuft…','running');updateButtons({running:true,paused:false});
      }else{
        setStatus('Bereit','online');updateButtons({running:false});
      }
      break;
    case 'task_start':
      appendLog(`▶ Task ${ev.task.id}: ${ev.task.description}`,'event-start');
      refreshPlan();break;
    case 'task_done':
      appendLog(`✓ Task ${ev.task.id} abgeschlossen.`,'event-done');
      refreshPlan();break;
    case 'loop_done':
      appendLog('✓ Loop abgeschlossen.','event-done');
      setStatus('Fertig','online');running=false;updateButtons({running:false});
      refreshPlan();loadPlans();break;
    case 'loop_error':
      appendLog('⚠ '+ev.msg,'event-error');
      setStatus('Fehler','');running=false;updateButtons({running:false});break;
    case 'state':
      if(ev.msg==='paused'){appendLog(`⏸ Pausiert${ev.goal?': '+ev.goal:''}`,'event-replan');setStatus('Pausiert','');updateButtons({running:true,paused:true})}
      else if(ev.msg==='running'){appendLog('▶ Fortgesetzt','event-replan');setStatus('Läuft…','running');updateButtons({running:true,paused:false})}
      break;
    case 'plan_loaded':
      refreshPlan();loadPlans();break;
  }
}

planBtn.onclick=createPlan;
runBtn.onclick=()=>doAction('run');
pauseBtn.onclick=()=>doAction('pause');
resumeBtn.onclick=()=>doAction('resume');
stopBtn.onclick=()=>doAction('stop');
$('goal-input').addEventListener('keydown',e=>{if(e.key==='Enter')createPlan()});

connectWS();
refreshPlan();
loadPlans();
</script>
</body>
</html>
HTMLEOF

echo "=== [8/9] Abhängigkeiten & Build ==="
cd "$HOME/jimmy"
go get github.com/ollama/ollama/api
go get github.com/coder/websocket
go mod tidy
go build -o jimmy .

echo "=== [9/9] Fertig ==="
echo ""
echo "================================================================"
echo "✓ Jimmy vollständig installiert."
echo ""
echo "  Starten (Web-UI):     cd ~/jimmy && ./jimmy web"
echo "  Anderer Port:         ./jimmy web :3000"
echo "  CLI-Modus:            ./jimmy \"Baue eine Todo-API\""
echo ""
echo "  Browser öffnen:       http://localhost:8080"
echo ""
echo "  Ollama läuft im Hintergrund."
echo "  Falls nicht erreichbar: nohup ollama serve &"
echo "================================================================"