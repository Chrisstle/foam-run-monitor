# foamTools-OpenFOAM

A collection of robust utility scripts designed to streamline the execution and monitoring of OpenFOAM simulations.

---

## 1. runCase

`runCase` is a robust bash script designed to streamline the execution and monitoring of OpenFOAM simulations. It automatically handles solver detection, parallel decomposition, dynamic mesh tracking, and data reconstruction, wrapping it all in a clean, live-updating progress interface.

### Features
- **Smart Initialization**: Automatically reads `controlDict`, `decomposeParDict`, and `dynamicMeshDict` to determine the solver, execution mode (serial/parallel), target end time, and mesh type.
- **Mesh Validation**: Runs a pre-flight `checkMesh` to ensure mesh validity before starting the solver.
- **Automated Reconstruction**: Automatically handles `reconstructParMesh` (if a dynamic mesh is used) followed by `reconstructPar` at the end of a parallel run, cleaning up processor directories upon success.
- **Failsafe Mechanisms**: Gracefully intercepts `Ctrl+C` to cleanly kill background solvers. Skips cleanup if reconstruction encounters errors, preserving your `processor*` directories.

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
| `-np <number>` | Overrides the `numberOfSubdomains` parameter in `system/decomposeParDict` to use the specified `<number>` of processors. |

---

## 2. foamProgress

`foamProgress` is a Python-based utility that monitors one or multiple active OpenFOAM simulations simultaneously from anywhere in your filesystem. 

### Features
- **Global Monitoring**: Automatically detects all running OpenFOAM processes on your machine.
- **TUI Dashboard**: Features a native Terminal User Interface (TUI) allowing you to seamlessly scroll through multiple active cases.
- **Agnostic Log Parsing**: Traces OS-level file descriptors to find log files, making it completely immune to varying log names, locations, or standard output redirections (e.g. `tee` or `mpirun` wrappers).
- **Dynamic Caching**: Actively caches metrics like iteration speed and Courant numbers, keeping them visible even if the solver gets stuck in heavy, thousands-of-lines-long timesteps.

### Usage
```bash
foamProgress [OPTIONS]
```

| Flag | Description |
| :--- | :--- |
| *(None)* | Prints a static, minimalistic one-time summary of all running simulations. |
| `-m, --monitor` | Launches an interactive, live-updating TUI dashboard (similar to `htop`). Supports scrolling. Press `q` to exit. |
| `-f, --full` | Expands the output to display comprehensive details mimicking `runCase`, including Courant numbers, mesh types, and ETA. |

---

## Under the Hood

### Logs
`runCase` quietly redirects all standard OpenFOAM outputs into a generated `log/` directory. You can inspect these if something goes wrong:
- `log/log.checkMesh`
- `log/log.decomposePar`
- `log/log.run` (The main solver output)
- `log/log.reconstructParMesh`
- `log/log.reconstructPar`

### Dynamic Mesh Handling
If `dynamicFvMesh` (e.g., Adaptive Mesh Refinement) is detected in `constant/dynamicMeshDict`:
1. `foamProgress` and `runCase` will dynamically display current cell counts by parsing the solver output.
2. During reconstruction, `runCase` automatically executes `reconstructParMesh` before `reconstructPar`.
