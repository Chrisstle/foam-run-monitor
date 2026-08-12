# foam-run-monitor

A collection of robust utility scripts designed to streamline the execution and active monitoring of OpenFOAM® simulations.

---

## 1. runCase

`runCase` is a robust bash script designed to streamline the execution and monitoring of OpenFOAM® simulations. It automatically handles solver detection, parallel decomposition, dynamic mesh tracking, and data reconstruction, wrapping it all in a clean, live-updating progress interface.

### Features
- **Smart Initialization**: Automatically reads `controlDict`, `decomposeParDict`, and `dynamicMeshDict` to determine the solver, execution mode (serial/parallel), target end time, and mesh type.
- **Mesh Validation**: Runs a pre-flight `checkMesh` to ensure mesh validity before starting the solver.
- **Active Monitoring**: Active monitoring of the case, similar in style as `foamProgress` (see examples below).
- **Automated Reconstruction**: Automatically handles `reconstructParMesh` (if a dynamic mesh is used) followed by `reconstructPar` at the end of a parallel run, cleaning up processor directories upon success.
- **Failsafe Mechanisms**: Gracefully intercepts `Ctrl+C` to cleanly kill background solvers. Skips cleanup if reconstruction encounters errors, preserving your `processor*` directories.
- **Batch Processing & Job Pool**: Run multiple case directories sequentially or in parallel (`-P`). Features a native, live-updating TUI dashboard that tracks the status of all queued and active jobs.

### Usage
```bash
runCase [MODE] [OPTIONS]
```
Run it from your case directory (the directory where you find system, constant, 0 etc.)

#### Modes (Required)
You must specify exactly one of the following modes to run the script:

| Flag | Description |
| :--- | :--- |
| `-n, --new` | Starts a **new** simulation. Cleans the case directory, removing old logs, `processor*` folders, and time directories. (Will prompt for confirmation if existing data is found). |
| `-c, --continue` | **Continues** an existing simulation from the `latestTime` available. |
| `-r, --reconstruct`| Only performs **manual reconstruction** (`reconstructParMesh` & `reconstructPar`) on a stopped/completed parallel run without starting the solver. |
| `-clean` | **Cleans** the case directory immediately. Deletes logs, `processor*` directories, time folders, resets the `0` directory from `0.orig` (if it exists), and runs `setFields`. |

#### Options (Optional)
| Flag | Description |
| :--- | :--- |
| `-np <number>` | Overrides the `numberOfSubdomains` parameter in `system/decomposeParDict` to use the specified `<number>` of processors. If used with `--batch`, it updates the dictionary for *all* target cases before starting. |
| `-b, --batch` | Batch execution mode. Treats all trailing positional arguments (e.g. `case*`) as directories to execute. If a directory is a parametric study root (not a case itself), it will recursively scan and find all valid nested case directories. If no arguments are provided, it defaults to scanning the current directory. |
| `-P, --jobs <num>`| Number of concurrent jobs to run in batch mode (default: 1). |
| `-q, --quiet` | Suppresses the interactive terminal UI (TUI) and animations. Useful for `nohup`, `tmux`, or redirecting output to files. |
| `-a, --animate` | Triggers `animateCase` automatically when the simulation completes (or collectively at the end of a batch). |
| `-s, --fps, --res, --field` | Optional flags to pass directly to `animateCase` when using `-a`. (e.g. `--fps 5 -s custom.pvsm`) |
| `-h, --help` | Show the help message and exit. |

### Examples

**Single Case:**
```bash
runCase -n -np 4
```

**Batch Processing:**
Run a new simulation for all cases matching `case*`, running 2 cases concurrently:
```bash
runCase -n -P 2 -b case*
```
You can also explicitly list out the cases you want to run:
```bash
runCase -n -P 2 -b case1 case3 case4
```
*Note: In batch mode, a live dashboard will appear to track the status (Queued, Running, Done, Crashed) of each case.*

**Comprehensive Pipeline:**
Clean the directory, decompose for 3 cores, run 2 jobs in parallel over all cases, and render customized animations at the end:
```bash
runCase --new -np 3 --jobs 2 --batch case* --animate --fps 5 --state set_up.pvsm
```

## Under the Hood

### Logs
`runCase` quietly redirects all standard OpenFOAM® outputs into a generated `log/` directory. You can inspect these if something goes wrong:
- `log/log.checkMesh`
- `log/log.decomposePar`
- `log/log.run` (The main solver output)
- `log/log.reconstructParMesh`
- `log/log.reconstructPar`

### Dynamic Mesh Handling
If `dynamicFvMesh` (e.g., Adaptive Mesh Refinement) is detected in `constant/dynamicMeshDict`:
1. `foamProgress` and `runCase` will dynamically display current cell counts by parsing the solver output.
2. During reconstruction, `runCase` automatically executes `reconstructParMesh`
before `reconstructPar`.

---

## 2. foamProgress

`foamProgress` is a Python-based utility that monitors one or multiple active OpenFOAM® simulations simultaneously from anywhere in your filesystem. 

### Features
- **Global Monitoring**: Automatically detects all running OpenFOAM® processes on your machine.
- **TUI Dashboard**: Features a native Terminal User Interface (TUI) allowing you to seamlessly scroll through multiple active cases.
- **Agnostic Log Parsing**: Traces OS-level file descriptors to find log files, making it completely immune to varying log names, locations, or standard output redirections (e.g. `tee` or `mpirun` wrappers).
- **Dynamic Caching**: Actively caches metrics like iteration speed and Courant numbers to ensure the UI stays solid when polling between sequential solver output updates.

### Usage
```bash
foamProgress [OPTIONS]
```

| Flag | Description |
| :--- | :--- |
| *(None)* | Prints a static, minimalistic one-time summary of all running simulations. |
| `-m, --monitor` | Launches an interactive, live-updating TUI dashboard (similar to `htop`). Supports scrolling. Press `q` to exit. |
| `-f, --full` | Expands the output to display comprehensive details mimicking `runCase`, including Courant numbers, mesh types, and ETA. |
| `-h, --help` | Show the help message and exit. |

### Examples

**Standard Monitoring Dashboard:**
![foamProgress](Images/foamProgress.png)

**Full Monitoring Dashboard (`-f`):**
![foamProgress full](Images/foamProgress%20full.png)

---

## 3. animateCase

`animateCase` is a Python-based utility wrapping ParaView's `pvpython` API that automates rendering OpenFOAM cases into animations locally.

### Features
- **Intelligent State File Parsing:** Supports ParaView state files (`.pvsm`). It automatically reads the XML to find the registered name of the OpenFOAM reader proxy and swaps the file paths for each new case seamlessly.
- **Automated Directory Handling:** Creates `.foam` dummy files automatically.
- **Batch Processing with Wildcards:** Takes a list of OpenFOAM case directories using shell expansion (e.g. `animateCase case*`). It also supports recursive case discovery if you provide a root directory or no arguments at all!
- **Parallel Processing:** Use the `-P` flag to spawn multiple `pvpython` subprocesses and render multiple videos concurrently.
- **Smart Output Targeting:** Renders directly into the case directory for single cases, and generates an `Animations` folder to group the outputs for batch rendering.

### Usage
```bash
animateCase [options] [cases...]
```

#### Options
| Flag | Description |
| :--- | :--- |
| `-s, --state <file.pvsm>` | Use a state file instead of the default `alpha.water` visualization. |
| `-f, --fps <int>` | Framerate (default 15). |
| `--res <w> <h>` | Resolution width and height (default 1280 720). |
| `--field <name>` | Field to focus on (default `alpha.water`). |
| `-P, --jobs <int>` | Number of parallel jobs (default 1). |
| `-h, --help` | Show the help message and exit. |

*Note: The default settings for `animateCase` (like framerate, resolution, format) can be easily changed by editing the global variables at the very top of the `animateCase` python script file.*


<sub>*OPENFOAM® is a registered trade mark of OpenCFD Limited, producer and distributor of the OpenFOAM software via www.openfoam.com. This offering is not approved or endorsed by OpenCFD Limited.*</sub>
