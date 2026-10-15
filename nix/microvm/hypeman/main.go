// This command connects microvm.nix's running-VM registry to Hypeman's memory
// controller. Pressure sampling, allocation and balloon control stay upstream.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"math"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kernel/hypeman/lib/guestmemory"
	"github.com/kernel/hypeman/lib/hypervisor"
	_ "github.com/kernel/hypeman/lib/hypervisor/cloudhypervisor"
	"github.com/kernel/hypeman/lib/vmm"
)

const mib = 1024 * 1024

type vmEntry struct {
	APISocket   string `json:"apiSocket"`
	MemoryState string `json:"memoryState"`
}

type config struct {
	VMs              map[string]vmEntry                 `json:"vms"`
	ActiveBallooning guestmemory.ActiveBallooningConfig `json:"activeBallooning"`
	APITimeout       time.Duration                      `json:"apiTimeout"`
}

type memoryState struct {
	Enable     bool   `json:"enable"`
	MaximumMiB int64  `json:"maximumMiB"`
	MinimumMiB int64  `json:"minimumMiB"`
	APISocket  string `json:"apiSocket"`
}

type source struct {
	config config
	log    *slog.Logger
}

func readJSON(path string, value any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, value); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

func (s source) runningVM(ctx context.Context, name string, entry vmEntry) (*guestmemory.BalloonVM, error) {
	var state memoryState
	if err := readJSON(entry.MemoryState, &state); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	if !state.Enable {
		return nil, nil
	}
	if state.APISocket != entry.APISocket || state.MinimumMiB <= 0 || state.MinimumMiB > state.MaximumMiB || state.MaximumMiB > math.MaxInt64/mib {
		return nil, fmt.Errorf("invalid running memory limits")
	}
	maximum := state.MaximumMiB * mib
	percent := int64(s.config.ActiveBallooning.ProtectedFloorPercent)
	floor := max(s.config.ActiveBallooning.ProtectedFloorMinBytes, maximum/100*percent+maximum%100*percent/100)
	if floor < state.MinimumMiB*mib {
		return nil, fmt.Errorf("Hypeman protected floor %d MiB is below this VM's minimum %d MiB", floor/mib, state.MinimumMiB)
	}
	if _, err := os.Stat(entry.APISocket); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	client, err := vmm.NewVMM(entry.APISocket)
	if err != nil {
		return nil, err
	}
	response, err := client.GetVmInfoWithResponse(ctx)
	if err != nil {
		return nil, err
	}
	if response.StatusCode() != 200 || response.JSON200 == nil {
		return nil, fmt.Errorf("vm.info returned HTTP %d", response.StatusCode())
	}
	info := response.JSON200
	if info.State != vmm.Running || info.Config.Balloon == nil {
		return nil, nil
	}
	if info.Config.Memory == nil || info.Config.Memory.Size != maximum {
		return nil, fmt.Errorf("running VM and memory registry disagree on assigned memory")
	}
	return &guestmemory.BalloonVM{
		ID:                  hypervisor.SocketCacheKey(entry.APISocket),
		Name:                name,
		HypervisorType:      hypervisor.TypeCloudHypervisor,
		SocketPath:          entry.APISocket,
		AssignedMemoryBytes: maximum,
	}, nil
}

func (s source) ListBalloonVMs(ctx context.Context) ([]guestmemory.BalloonVM, error) {
	var vms []guestmemory.BalloonVM
	for name, entry := range s.config.VMs {
		vm, err := s.runningVM(ctx, name, entry)
		if err != nil {
			s.log.WarnContext(ctx, "excluding VM from memory management", "vm", name, "error", err)
		} else if vm != nil {
			vms = append(vms, *vm)
		}
	}
	return vms, ctx.Err()
}

func run() error {
	path := flag.String("config", "", "Nix-generated memory controller configuration")
	flag.Parse()
	var cfg config
	if err := readJSON(*path, &cfg); err != nil {
		return err
	}
	cfg.ActiveBallooning.Enabled = true
	cfg.ActiveBallooning = cfg.ActiveBallooning.Normalize()
	if cfg.APITimeout <= 0 {
		return fmt.Errorf("apiTimeout must be positive")
	}
	vmm.DefaultHTTPTimeout = cfg.APITimeout
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	policy := guestmemory.Policy{Enabled: true, ReclaimEnabled: true}
	return guestmemory.NewController(policy, cfg.ActiveBallooning, source{cfg, log}, log).Start(ctx)
}

func main() {
	if err := run(); err != nil {
		slog.Error("memory controller failed", "error", err)
		os.Exit(1)
	}
}
