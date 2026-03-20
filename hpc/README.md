# gromacs_status.sh

A terminal-based status explorer for GROMACS molecular dynamics simulations managed with SLURM. It scans a directory tree, identifies simulation directories by their output files, queries `squeue` for live job state, parses GROMACS and MPI error blocks, and prints a colour-coded aligned table.

---

## Features

- **Fingerprint-based discovery** — no directory name assumptions. Finds simulation dirs by presence of `.tpr`, `.cpt`, `.edr`, `.xtc`, `.log` files at any depth.
- **SLURM-authoritative status** — calls `squeue` once at startup. Two matching strategies:
  - *Exact*: job ID from `.err` file found in squeue (running/just-started jobs).
  - *Name-based*: replica + system numbers extracted from the directory path and matched against squeue job names — catches **pending (PD) jobs** that have no `.err` file yet.
- **FINALIZED vs FAILED** — if `"Finished mdrun"` is present in the log but only post-processing script errors occurred (`sed`, `sbatch`), the status is `FINALIZED` instead of `FAILED`. The post-processing notes appear as dim sub-rows.
- **Three-layer inline error display** — GROMACS fatal block (`.out`), MPI/prterun messages (`.err`), and generic SLURM errors shown directly under each failed row.
- **Timestep-aware time** — step counts × `dt` auto-scaled to ps / ns / µs.
- **ANSI-aware column alignment** — all columns stay aligned even when coloured status strings contain invisible escape bytes.
- **Log rotation** — saves a timestamped log every run; keeps the 10 most recent automatically. FAILED detail (full `.err` content) is written to the log only, not the terminal.

---

## Requirements

| Tool | Notes |
|---|---|
| `bash` ≥ 4.2 | Associative arrays required |
| `awk` | Standard on all HPC systems |
| `grep` with `-P` | Perl-compatible regex (GNU grep) |
| `squeue` | Optional — needed for live SLURM state |
| `du` | Optional — needed for disk usage column |
| `timeout` | Optional — protects `du` on slow network filesystems |

---

## Installation

```bash
cp gromacs_status.sh ~/bin/
chmod +x ~/bin/gromacs_status.sh
```

---

## Quick Start

```bash
# Run from the directory containing your simulation folders
./gromacs_status.sh .

# Or point to a root directory
./gromacs_status.sh /scratch/user/project
```

On the first run (without `-p`) two interactive questions are asked:

```
Step 1 — Output file pattern
  Detected candidates:
    [1] 9.production
    [2] 7.equilibration

  Pattern [e.g. 9.production]: 1

Step 2 — SLURM log prefix
  Default: MD_SIMULATION  →  MD_SIMULATION.err.<jobid>
  SLURM prefix [Enter = keep 'MD_SIMULATION']:
```

The pattern (e.g. `9.production`) tells the script which files to read in each replica directory: `9.production.log`, `9.production.xtc`, `9.production.cpt`, etc.

---

## Usage

```
./gromacs_status.sh [ROOT_DIR] [OPTIONS]
```

### All options

| Flag | Default | Description |
|---|---|---|
| `-p, --pattern NAME` | *(interactive)* | Base name of GROMACS output files, e.g. `9.production` |
| `--slurm-prefix PFX` | `MD_SIMULATION` | Prefix of SLURM log files → `PFX.err.<jobid>` |
| `-d, --depth N` | unlimited | Maximum directory search depth |
| `-e, --errors-only` | off | Show only FAILED / FINALIZED / INCOMPLETE / QUEUED rows |
| `-v, --verbose` | off | Show file inventory below each row |
| `-x, --exclude PATTERN` | *(none)* | Skip dirs whose path contains `PATTERN`. Repeatable. |
| `--no-color` | off | Disable ANSI colours (clean for piping / `grep`) |
| `--no-gromacs-err` | on | Do not parse the GROMACS fatal error block |
| `--no-mpi-err` | on | Do not parse MPI/prterun error lines |
| `--no-slurm-out` | on | Do not read `.out` file for progress/error info |
| `--no-disk` | on | Skip `du -sh` (faster on slow filesystems) |
| `--time-unit UNIT` | auto | Force time unit: `ps`, `ns`, or `us` |
| `--dt VAL` | `0.02` | Integration timestep in ps. Default = 20 fs (MARTINI CG). Use `0.002` for atomistic 2 fs runs. |
| `--err-lines N` | `3` | Inline error context lines per error type. `0` = label only. |
| `-l, --log [DIR]` | `./md_status_logs` | Log directory. 10 most recent logs are kept. |
| `-h, --help` | — | Print help and exit |

---

## Examples

```bash
# Minimal — interactive prompts
./gromacs_status.sh .

# Fully non-interactive
./gromacs_status.sh /scratch/proj \
    -p 9.production \
    --slurm-prefix MD_SIMULATION \
    --dt 0.02 \
    --time-unit us

# Show only problems
./gromacs_status.sh . -p 9.production -e

# Atomistic 2 fs timestep, time in ns
./gromacs_status.sh /scratch/atomistic -p md_production --dt 0.002 --time-unit ns

# More error context
./gromacs_status.sh . -p 9.production --err-lines 5

# Skip disk usage (faster on Panasas / Lustre / GPFS)
./gromacs_status.sh . -p 9.production --no-disk

# Exclude specific directories
./gromacs_status.sh . -p 9.production -x backup -x test -x old_runs

# Custom SLURM log prefix
./gromacs_status.sh . -p 9.production --slurm-prefix run

# Save log to a custom path, no colours
./gromacs_status.sh . -p 9.production --no-color -l /home/user/logs
```

---

## Output

### Table columns

| Column | Description |
|---|---|
| `PATH (relative)` | Directory path relative to the root |
| `STATUS` | Simulation state — see table below |
| `JOB ID` | SLURM job ID (with `(PD)` suffix for pending jobs) |
| `SIM TIME` | Simulated time (steps × dt), auto-scaled |
| `STEPS` | Last MD step number reached |
| `DISK` | Directory size (`du -sh`) |
| `ATOMS` | Atom count from the GROMACS log |
| `FILES` | Key output files — `●` present, `○` absent |

### Status values

| Status | Colour | Condition |
|---|---|---|
| `FINISHED ✔` | Green | `"Finished mdrun"` in GROMACS log |
| `FINALIZED ✔` | Green | `"Finished mdrun"` in log, but post-run script had errors (`sed`/`sbatch`) — MD itself completed |
| `RUNNING ▶` | Cyan | Job is `R` in squeue, or `.cpt` modified within the last 60 min |
| `QUEUED ⏳` | Blue | Job is `PD` (pending) in squeue |
| `INCOMPLETE ⚠` | Yellow | `.cpt` or `.edr` found, no clean finish, no error |
| `FAILED ✖` | Red | GROMACS fatal block or MPI abort found in SLURM logs |
| `NOT_STARTED ○` | Dim | `.tpr` found but no output files yet |
| `NO_TPR ✗` | Magenta | No `.tpr` found |

> **FINALIZED vs FAILED**: if the simulation ran to completion (`"Finished mdrun"` in the log) but the post-processing step failed (missing script, empty `sbatch` job), the status is `FINALIZED` — not `FAILED`. Post-processing notes still appear as dim `NOTE` sub-rows for visibility.

### Inline sub-rows

**Under FAILED rows:**
```
  14.2/.../replica2  FAILED ✖   1624873   ...
    ├ GROMACS  File input/output error:
    ├ GROMACS  Cannot rename checkpoint file; maybe you are out of disk space?
    ├ MPI/PAR  MPI_ABORT was invoked on rank 0 in communicator MPI_COMM_WORLD
    ├ MPI/PAR  prterun has exited due to process rank 0 with PID 0 on node ...
    └ OTHER    sbatch: error: Batch script is empty!
```

**Under FINALIZED rows:**
```
  14.2/.../replica3  FINALIZED ✔   1625377   ...
    └ NOTE   sed: can't read 1.post-process.sh: No such file or directory
```

**Under FINISHED rows (performance):**
```
  14.1/.../replica1  FINISHED ✔   ...
    └ PERF   ns/day: 2.345   hours/ns: 10.234   wall time: 34h12m07s
```

**Under RUNNING / INCOMPLETE rows (last progress line):**
```
  14.1/.../replica2  RUNNING ▶   ...
    └ PROGRS  imb F 18% step 137931100, will finish Wed Mar 18 14:26:06 2026
```

| Sub-row | Colour | Source |
|---|---|---|
| `GROMACS` | Red | `-------` fatal block in GROMACS `.out` |
| `MPI/PAR` | Orange | `MPI_ABORT`, `prterun`, segfault from `.err` |
| `OTHER` | Yellow | `sbatch` errors, missing files, I/O |
| `NOTE` | Dim | Post-processing errors on a completed simulation |
| `PERF` | Green | Performance stats from GROMACS log (FINISHED only) |
| `PROGRS` | Cyan | Last progress line from SLURM `.out` (RUNNING/INCOMPLETE) |

---

## Log Files

Every run writes to `./md_status_logs/` (or the path set with `-l`):

```
md_status_logs/
  md_status_20260320_143201.log   ← most recent
  md_status_20260320_091045.log
  ...                             (10 most recent kept automatically)
```

The log contains the full terminal output **plus** a `FAILED SIMULATIONS — FULL DETAIL` section not shown on screen, which includes the complete content of every SLURM `.err` file for failed simulations.

---

## How SLURM State Works

`squeue -u $USER` is called once at startup. For each simulation directory, two matching strategies are tried in order:

1. **Exact** — `.err` files in the directory are scanned; if any job ID appears in the squeue table, that job's state is used directly. Works for running and recently started jobs.

2. **Name-based** — for pending jobs (PD) that have no `.err` file yet, the replica number and system-specific number are extracted from the directory path and matched against squeue job names:
   - Replica from `replicaN` in the path → job name must start with `r{N}_`
   - System number from the protein name pattern (e.g. `CCPG1-2SIGMAR` → `2`) → job name must contain `-2`

   Example: `14.2.oligomerization_CG_8CCPG1-2SIGMAR1/replica3` → matches `r3_ccpg1-idr-8_sigmar1-2_memb`.

If `squeue` is unavailable, the script falls back entirely to file-based heuristics (checkpoint modification time, presence of output files).

---

## Notes

### MARTINI Coarse-Grained (default)
`--dt 0.02` (20 fs) is the default, matching standard MARTINI CG timesteps.

### Atomistic simulations
```bash
./gromacs_status.sh . -p md_production --dt 0.002 --time-unit ns
```

### Slow network filesystems (Panasas, Lustre, GPFS)
`du -sh` uses `timeout 15` internally. If disk reporting is too slow (shows `?`), disable it:
```bash
./gromacs_status.sh . -p 9.production --no-disk
```

### Custom SLURM log naming
If your cluster names logs differently (e.g. `run.err.1234567`):
```bash
./gromacs_status.sh . -p 9.production --slurm-prefix run
```

### Final structure file detection
The script searches for the output `.gro` file in this order:
1. `confout.gro` (GROMACS default)
2. `${PATTERN}.gro` (e.g. `9.production.gro`)
3. `${PATTERN}*.gro` (any suffix variant)
4. Any `*.gro` newer than the `.tpr` (timestamp-based fallback)
5. If `"Finished mdrun"` is in the log, `gro:●` is shown regardless — GROMACS always writes a final structure when it finishes cleanly.
