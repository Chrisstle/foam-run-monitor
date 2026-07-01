# runCase

`runCase` is a robust bash script designed to streamline the execution and monitoring of OpenFOAM simulations. It automatically handles environment detection, parallel decomposition, dynamic mesh tracking, and data reconstruction, wrapping it all in a clean, live-updating progress interface.

---

## Features

- **Smart Initialization**: Automatically reads `controlDict`, `decomposeParDict`, and `dynamicMeshDict` to determine the solver, execution mode (serial/parallel), target end time, and mesh type.
- **Mesh Validation**: Runs a pre-flight `checkMesh` to ensure mesh validity before starting the solver.
- **Live Monitoring Dashboard**: Replaces standard terminal spam with a clean, in-place updating dashboard showing:
  - Progress bar and Estimated Time of Arrival (ETA)
  - Current timestep and latest saved data
  - Mean and Max Courant / Interface Courant numbers
  - **Dynamic Cell Tracking**: Automatically monitors and updates cell counts (and cells per processor) in real-time if a dynamic mesh is detected.
- **Automated Reconstruction**: Automatically handles `reconstructParMesh` (if a dynamic mesh is used) followed by `reconstructPar` at the end of a parallel run, cleaning up processor directories upon success.
- **Failsafe Mechanisms**: Gracefully intercepts `Ctrl+C` to cleanly kill background solvers. Skips cleanup if reconstruction encounters errors, preserving your `processor*` directories.

---

## Usage

```bash
runCase [MODE] [OPTIONS]
```

### Modes (Required)

You must specify exactly one of the following modes to run the script:

| Flag | Description |
| :--- | :--- |
| `-n, --new` | Starts a **new** simulation. Cleans the case directory, removing old logs, `processor*` folders, and time directories. (Will prompt for confirmation if existing data is found). |
| `-c, --continue` | **Continues** an existing simulation from the `latestTime` available. |
| `-r, --reconstruct`| Only performs **manual reconstruction** (`reconstructParMesh` & `reconstructPar`) on a stopped/completed parallel run without starting the solver. |
| `-clean` | **Cleans** the case directory immediately. Deletes logs, `processor*` directories, time folders, resets the `0` directory from `0.orig` (if it exists), and runs `setFields`. |

### Options (Optional)

| Flag | Description |
| :--- | :--- |
| `-np <number>` | Overrides the `numberOfSubdomains` parameter in `system/decomposeParDict` to use the specified `<number>` of processors. |

---

## Examples

**1. Start a fresh parallel simulation on 16 cores:**
```bash
runCase --new -np 16
```
*(This will clean the directory, modify decomposeParDict to 16, decompose the domain, run the solver, and reconstruct the results at the end).*

**2. Resume an interrupted simulation:**
```bash
runCase --continue
```
*(This will pick up the simulation from the latest saved time step).*

**3. Manually reconstruct results after stopping a simulation early:**
```bash
runCase --reconstruct
```

**4. Reset the case completely (clean up everything):**
```bash
runCase -clean
```

---

## Under the Hood

### Logs
All standard OpenFOAM outputs are quietly redirected into a generated `log/` directory. You can inspect these if something goes wrong:
- `log/log.checkMesh`
- `log/log.decomposePar`
- `log/log.run` (The main solver output)
- `log/log.reconstructParMesh`
- `log/log.reconstructPar`

### Dynamic Mesh Handling
If `dynamicFvMesh` (e.g., Adaptive Mesh Refinement) is detected in `constant/dynamicMeshDict`:
1. The live dashboard will dynamically display current cell counts by parsing the solver output.
2. During reconstruction, `reconstructParMesh` is automatically executed before `reconstructPar`.
