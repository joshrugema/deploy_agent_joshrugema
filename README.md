# deploy_agent — Student Attendance Tracker bootstrapper

`deploy_agent.sh` is a Bash script that **deploys**, **runs**, and **archives the logs of** the
Student Attendance Tracker (`attendance_checker.py`), and cleans up safely if you press
Ctrl+C / Ctrl+Z partway through a deployment. The Python application is never modified.

**Video walkthrough:** https://youtu.be/M5eLllnivn0

## Repository layout

```
deploy_agent_<GithubUsername>/
├── deploy_agent.sh          # the master script
├── templates/               # unmodified source files
│   ├── attendance_checker.py
│   ├── assets.csv
│   └── config.json
├── .gitignore               # keeps deployed projects / zips out of git
└── README.md
```

## Requirements

- Bash 3.2+ (works with the macOS system bash and Linux)
- `python3` and `zip`. The script checks for both and stops early with a clear message if either is missing.

## How to run it and pick a feature

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh            # interactive menu
```

The menu:

```
1) Deploy a new project
2) Run a deployed project
3) Archive a project's logs
4) Exit
```

You can also skip the menu with an argument, which is handy for scripting and testing:

| Command | Feature |
|---|---|
| `./deploy_agent.sh deploy` | 1 – Deploy (then runs the app to verify) |
| `./deploy_agent.sh run [name]` | 2 – Run an existing project |
| `./deploy_agent.sh archive [name]` | 3 – Archive its logs |
| `./deploy_agent.sh help` | Show usage |

`name` is the suffix you chose at deploy time, so `v1` means `attendance_tracker_v1/`. The full
directory name also works. If you leave it out, the script lists the deployed projects and asks.

## Feature 1 – Deploy

1. **Pre-flight checks:** confirms `python3` (printing `python3 --version`) and `zip` are installed,
   that all three files exist in `templates/`, and that the folder is writable.
2. **Name the project:** reads a name (letters, digits, `_`, `-` only) and creates:
   ```
   attendance_tracker_{name}/
   ├── attendance_checker.py
   ├── Helpers/
   │   ├── assets.csv
   │   └── config.json
   └── reports/
   ```
   If the directory already exists, the script asks before overwriting. Answering **no** aborts with
   an error and leaves the existing project untouched. If any `mkdir`, `cp` or write fails (for
   example, permission denied), the script prints the error and removes the half-made directory.
3. **Populate the files:** `attendance_checker.py` and `config.json` are copied unmodified from
   `templates/`. For `Helpers/assets.csv` you choose:
   - **A – copy from template:** how many students (1 to the number in the template); copies the header plus that many rows.
   - **B – generate fresh:** how many students (1–100); builds rows from first/last name arrays in
     the script, e.g. `alice.mugisha@example.com,Alice Mugisha,0,0`.
4. **Permissions:** `chmod +x attendance_checker.py` and `chmod 600 Helpers/config.json`
   (owner read/write only, since it holds grading thresholds). The resulting modes are printed.
5. **Threshold update:** see below.
6. **Verification:** the deploy finishes by running the app (Feature 2). A successful start
   proves the structure, roster and config work together.

### `total_sessions` and the roster

`total_sessions` counts *all* sessions including today's, so it must equal
**prior sessions recorded in the roster + 1**:

| Roster | Prior sessions per student | `total_sessions` |
|---|---|---|
| Option A (template rows) | 4 (`Attendance + Absence = 4`) | **5**, the template default, left as is |
| Option B (fresh, counts 0) | 0 | **1**, set by the script with `sed` |

There's no prompt for this. The script always ships the consistent value.

## How the threshold update works

After permissions are set, the script shows the current `warning` / `failure` values and asks
whether to change them. If you say yes:

- `read` captures each value, with defaults `75` and `50` (press Enter to accept a default).
- **Validation:** input must be a whole number from 0 to 100. Empty input with no default,
  letters, decimals or negative numbers are rejected and you're asked again. `failure` must also be
  lower than `warning`.
- The file is edited in place with `sed`, matching only the number after the key:
  ```bash
  sed -E -i.bak 's/("warning"[[:space:]]*:[[:space:]]*)[0-9]+/\1<new>/' Helpers/config.json
  ```
  Indentation, key order and everything else stay as they were. (`-i.bak` followed by deleting
  the `.bak` keeps it portable between GNU and BSD/macOS sed.) The file is set back to `chmod 600`
  after the edit, and the new lines are printed as confirmation.

## Feature 2 – Run

Checks that the project's files and `reports/` exist, then runs

```bash
cd attendance_tracker_{name} && python3 attendance_checker.py
```

and hands the terminal to the instructor for the interactive marking session. When the app exits,
the script reports its exit status and offers to archive the new logs. Pressing Ctrl+C during
marking ends the Python session, but the script survives and still offers archiving. The deploy
trap described below is **not** active here.

## How log archiving works (Feature 3)

The app writes `reports/attendance.log` and `reports/absent.log`. Archiving:

1. Takes one timestamp per run: `date +%Y%m%d_%H%M%S`.
2. For each log that **exists**, creates its own directory and moves the file there with the
   timestamp in its name:
   ```
   attendance_tracker_{name}/archives/
   ├── attendance/attendance_20261014_211356.log
   └── absent/absent_20261014_211356.log
   ```
   Every archived copy is unique and traceable, and `reports/` is left clean for the next session.
3. Prints each source → destination path.
4. If a log is missing (for example, nobody was absent so there's no `absent.log`), it prints `[SKIP] …
   not found` and carries on. If neither exists, it says so and exits normally.

## Signal handling: Ctrl+C / Ctrl+Z during deployment

**Archive trigger:** while Feature 1 is running, the script traps
`SIGINT` (Ctrl+C) and `SIGTSTP` (Ctrl+Z):

```bash
trap 'on_interrupt SIGINT 130'  INT
trap 'on_interrupt SIGTSTP 148' TSTP
```

When either arrives, `on_interrupt`:

1. Ignores further Ctrl+C/Ctrl+Z so the cleanup can't itself be interrupted.
2. Prints that the deployment was interrupted, and by which signal.
3. Zips whatever exists of `attendance_tracker_{name}/` into
   **`attendance_tracker_{name}_archive.zip`** using `zip -r`.
4. **Deletes the incomplete directory**, but only if the zip succeeded, so nothing is lost.
5. Exits cleanly (status 130 for Ctrl+C, 148 for Ctrl+Z).

Safety details:
- If you interrupt *before* the directory is created (for example, at the name prompt), there's
  nothing to archive and the script just says so.
- If you interrupt at the "overwrite existing project?" prompt, the existing project is **not**
  touched. The trap only archives and removes a directory this run created.
- The traps are removed (`trap - INT TSTP`) once deployment finishes, before the app is launched.

### How to test the trap

1. Run `./deploy_agent.sh deploy` and enter a name, e.g. `demo`.
2. At the **"Choose A or B"** prompt (the directory and some files exist by then), press **Ctrl+C**.
3. Check:
   ```bash
   ls -d attendance_tracker_demo        # -> No such file or directory (cleaned up)
   unzip -l attendance_tracker_demo_archive.zip
   ```
   The zip holds the partial project at that moment:
   ```
   attendance_tracker_demo/
   attendance_tracker_demo/attendance_checker.py
   attendance_tracker_demo/Helpers/
   attendance_tracker_demo/Helpers/config.json
   attendance_tracker_demo/reports/
   ```
   (No `assets.csv` yet, because the roster hadn't been built.)
4. Repeat with **Ctrl+Z**. The result is the same, with the message naming SIGTSTP.

Interrupting at a later prompt (student count, thresholds) produces a zip with more of the project in it.

## How the deployed structure was tested

| Scenario | Expected / observed |
|---|---|
| Option A, 3 students | `assets.csv` = header + 3 template rows; `total_sessions` 5 |
| Option B, 12 students | 12 unique generated names, counts `0,0`; `total_sessions` 1 |
| Threshold input `abc`, then failure ≥ warning | Rejected with a message, asked again |
| Thresholds 90 / 80 | Only those two numbers changed in `config.json`; formatting kept |
| Permissions | `attendance_checker.py` `-rwxr-xr-x`, `config.json` `-rw-------` |
| Existing name, answer "n" | Aborts with an error; existing project untouched |
| App run, someone absent | Both logs created → both archived with timestamps |
| App run, nobody absent | `attendance.log` archived; `absent.log` reported as skipped |
| Ctrl+C / Ctrl+Z at roster prompt | Zip created with partial project; directory removed |
| `find attendance_tracker_v1 \| sort` | Matches the required structure exactly |

To check a deployment by hand:

```bash
find attendance_tracker_v1 | sort
ls -l attendance_tracker_v1/attendance_checker.py attendance_tracker_v1/Helpers/config.json
cat attendance_tracker_v1/Helpers/config.json
```
