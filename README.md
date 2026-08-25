# Mini CI/CD Pipeline

A simplified, fully local CI/CD pipeline inspired by GitHub Actions. The project detects new Git commits, validates the configured branch, allocates a unique build number, runs the committed revision inside an isolated Docker runner, executes configurable CI stages, stores timestamped build logs and coverage artifacts, and packages the sample application as a Docker image tagged with the exact commit SHA.

The implementation uses **Bash, Git, Python, YAML, Docker, pytest, pytest-cov, and Ruff**. It does not depend on GitHub Actions, Jenkins, or any cloud CI service.

---

## 1. Features

The pipeline implements the following functionality:

- **Automated prerequisite setup** through `prerequisites.sh`, which checks the required tools/Docker daemon, builds `runner:v1`, creates a Python virtual environment, installs host-side requirements, and configures the version-controlled Git hook.
- **Commit watcher** using a Git `post-commit` hook.
- **Branch-based triggering** configured in `pipeline.yml` (`main` and `dev-1` in the supplied configuration).
- **Build-number generation** using monotonically increasing IDs such as `V73` and `V74`.
- **Build-number locking** with `fcntl.flock(..., LOCK_EX)` to prevent cooperating concurrent controller processes from receiving the same build number.
- **Fresh runner environment** using a Docker image named `runner:v1`.
- **Exact-commit execution**: the runner clones the source repository and checks out the SHA supplied by the hook.
- **Declarative stage configuration** through `pipeline.yml` rather than hardcoded build/test/lint commands in the runner.
- **Sequential, fail-fast execution** of Build, UnitTest, Linter, Coverage, BuildImage, and RunAppContainer stages.
- **Unit testing** with `pytest`.
- **Static analysis** with Ruff.
- **HTML coverage reporting** with `pytest-cov`.
- **Docker image generation** tagged as `task-management-app:<COMMIT_SHA>`.
- **Runtime smoke testing** of the generated application image.
- **Persistent build history** under `build_history/V<n>/`.
- **Per-job and pipeline-level logs** containing timestamps and success/failure information.
- **Docker-daemon validation** before the runner is started.

---

## 2. Repository Layout

The supplied archive has the following important structure:

```text
CICD/
├── prerequisites.sh            # One-time prerequisite/bootstrap script
├── Dockerfile                  # Docker image for the CI runner (runner:v1)
├── requirements.txt            # Runner dependency: PyYAML
├── README.md
└── task_management_app/
    ├── .build/
    │   ├── build_counter       # Last allocated numeric build number
    │   └── build_counter.lock  # Lock file used during allocation
    ├── .githooks/
    │   └── post-commit         # Version-controlled commit watcher / pipeline launcher
    ├── build_history/
    │   ├── V69/
    │   ├── V70/
    │   ├── V73/
    │   └── V74/
    ├── app/
    │   ├── __init__.py
    │   ├── routes.py
    │   └── tasks.py
    ├── tests/
    │   └── test_tasks.py
    ├── app.py
    ├── Dockerfile              # Docker image for the Flask application
    ├── pipeline.py             # Trigger validation + build-number allocation
    ├── pipeline.yml            # Declarative CI/CD definition
    ├── runner.py               # Executes configured stages and writes logs
    ├── requirements.txt        # Application/test/lint dependencies
    └── .gitignore
```

`build_history/` contains artifacts from previous pipeline runs, including one successful run and one deliberately failed run used to demonstrate failure handling.

---

## 3. Architecture and Execution Flow

Before the first pipeline run, the evaluator/user can execute the root-level `prerequisites.sh` script. It checks Git, Python and Docker, verifies that the Docker daemon is reachable, builds the `runner:v1` image, creates a local Python virtual environment, installs the host-side requirements, and configures `.githooks` as the repository hook directory. The normal per-commit execution flow is then:

```text
Developer runs git commit
        |
        v
.githooks/post-commit
        |
        |-- obtains HEAD commit SHA
        |-- verifies Docker daemon is reachable
        |-- creates/reuses pipeline-net
        |-- invokes pipeline.py <commit-sha>
        v
pipeline.py
        |
        |-- loads pipeline.yml
        |-- checks current branch against configured branches
        |-- locks .build/build_counter.lock
        |-- increments .build/build_counter
        |-- prints build number (for example V75)
        v
post-commit hook
        |
        |-- starts runner:v1
        |-- passes COMMIT_ID and BUILD_NUMBER
        |-- mounts source repository
        |-- mounts build_history
        |-- mounts Docker socket
        v
runner:v1
        |
        |-- git clone /source task_management_app
        |-- git checkout $COMMIT_ID
        |-- python3 runner.py
        v
runner.py
        |
        |-- reads pipeline.yml
        |-- executes stages/jobs sequentially
        |-- writes per-job and pipeline logs
        |-- stops on first failed job
        v
build_history/V<n>/
```

The exact committed SHA is used rather than simply building whatever files happen to be present in the working directory at execution time.

---

## 4. Prerequisites

Install the following on the host machine:

- Git
- Docker Engine / Docker Desktop with a running Docker daemon
- Python 3 with `venv` support

PyYAML is installed by `prerequisites.sh` into the local virtual environment from the outer `requirements.txt`.

Verify the main tools:

```bash
python3 --version
git --version
docker --version
docker info
```

The implementation uses `fcntl` for file locking, so the controller is intended for **Linux/Unix-like environments**. Native Windows Python does not provide `fcntl`; WSL/Linux is recommended if running on Windows.

---

## 5. Initial Setup

From the outer `CICD/` directory, run:

```bash
chmod +x prerequisites.sh
./prerequisites.sh
cd task_management_app
```

`prerequisites.sh` checks Git, Python, and Docker, verifies the Docker daemon, builds the `runner:v1` image, creates the local Python virtual environment and installs the host requirements, and configures `.githooks/post-commit` as the Git hook.

Verify the hook configuration:

```bash
git config --get core.hooksPath
```

Expected output:

```text
.githooks
```

After setup, make a commit on a branch configured in `pipeline.yml` to trigger the pipeline:

```bash
git add .
git commit -m "Trigger pipeline"
```

---

## 6. Pipeline Configuration

The pipeline definition is stored in `task_management_app/pipeline.yml`.

The current trigger is:

```yaml
trigger:
  commit:
    branches:
      - main
      - dev-1
```

Only commits made while the checked-out branch is listed here receive a build number and proceed to the runner.

The current stage order is:

1. `Build`
2. `UnitTest`
3. `Linter`
4. `Coverage`
5. `BuildImage`
6. `RunAppContainer`

`runner.py` reads this YAML file dynamically and executes the jobs in the order in which they appear.

For multiline shell jobs, the pipeline uses strict Bash execution:

```bash
set -euo pipefail
```

This makes a multiline job stop on an unexpected command failure (`-e`), fail when an undefined variable is referenced (`-u`), and propagate failures from commands inside a shell pipeline (`pipefail`). Commands whose failure is intentionally acceptable still use explicit handling such as `|| true`.

---

## 7. Commit Watcher and Triggering

The commit watcher is implemented by the version-controlled `.githooks/post-commit` script.

On every successful local commit it:

1. Gets the exact new commit SHA using `git rev-parse HEAD`.
2. Checks the Docker daemon using `docker info`.
3. Creates `pipeline-net` if it does not already exist.
4. Calls:

   ```bash
   python3 pipeline.py "$commit_ID"
   ```

5. If `pipeline.py` accepts the trigger, captures the returned build number.
6. Starts `runner:v1` with:
   - `COMMIT_ID`
   - `BUILD_NUMBER`
   - the target source repository mounted at `/source`
   - host `build_history/` mounted at `/build_history`
   - `/var/run/docker.sock` mounted so the runner can build/start Docker images
   - membership in `pipeline-net`

This produces an event-driven local pipeline without polling.

---

## 8. Build Number Generation and Locking

`pipeline.py` maintains build state in:

```text
.build/build_counter
.build/build_counter.lock
```

When a configured branch triggers the pipeline, the controller:

1. Acquires an exclusive lock on `build_counter.lock` using `fcntl.flock`.
2. Initializes the counter to `0` if necessary.
3. Reads the current value.
4. Increments it by one.
5. Writes the new value back.
6. Releases the lock.
7. Returns the identifier as `V<number>`.

For example, a counter value of `74` corresponds to build `V74`.

The lock prevents two cooperating controller processes from reading the same old value and allocating the same next build number concurrently.

A build number is allocated before the runner creates its build-history directory. Therefore, if the runner cannot start after allocation, gaps in build numbers are possible; this does not cause build-number reuse.

---

## 9. Isolated Runner and Exact Commit Checkout

The `runner:v1` image is created from the outer `CICD/Dockerfile`.

When started by the Git hook, its command performs a fresh clone:

```bash
git clone /source task_management_app
cd /task_management_app
git checkout "$COMMIT_ID"
python3 runner.py
```

This gives each pipeline invocation a fresh source checkout inside a new runner container and ensures the pipeline evaluates the commit that triggered it.

The runner also receives the host Docker socket. This is necessary for the `BuildImage` and `RunAppContainer` stages, although mounting the Docker socket gives the runner powerful access to the host Docker daemon and should therefore only be used with trusted pipeline definitions.

---

## 10. Pipeline Stages

### 10.1 Build

The Build stage contains two jobs.

**Install Dependencies**

```bash
python3 -m pip install -r requirements.txt
```

**Compile Check**

```bash
python3 -m compileall app app.py
```

A non-zero exit code causes the runner to stop and downstream stages are not executed.

### 10.2 Unit Tests

```bash
python3 -m pytest tests/
```

The sample test suite exercises the Flask application's main functionality, including:

- root endpoint
- health endpoint
- task creation
- task listing
- retrieving one task
- missing-task behavior
- completing a task
- deleting a task
- validation when a title is missing

A successful recorded run (`V73`) executed **11 tests successfully**.

### 10.3 Linter

```bash
ruff check app app.py
```

Ruff performs static analysis of the application code. Lint failures produce a non-zero return code and stop the pipeline.

### 10.4 Coverage

```bash
python3 -m pytest --cov=app --cov-report=html tests/
cp -r htmlcov /build_history/${BUILD_NUMBER}/htmlcov
```

The generated HTML report is persisted under the corresponding build-history directory, for example:

```text
build_history/V73/htmlcov/
```

### 10.5 Docker Image Build

```bash
docker build -t task-management-app:${COMMIT_ID} .
```

The application image is tagged with the full commit SHA, which directly associates the image with the source revision that produced it.

Example from successful build `V73`:

```text
task-management-app:47da36925c64a912d66f4690edfcabb0849b774c
```

### 10.6 Application Container and Smoke Test

Before starting the new image, the stage removes any previous container named `task-management-app`:

```bash
docker stop task-management-app 2>/dev/null || true
docker rm task-management-app 2>/dev/null || true
```

It then starts the newly built image on `pipeline-net`:

```bash
docker run -d \
  --name task-management-app \
  --network pipeline-net \
  -p 5000:5000 \
  task-management-app:${COMMIT_ID}
```

After a short startup delay, the stage performs API smoke tests that:

1. Check `/health`.
2. List `/tasks`.
3. Create a task titled `Learn CI/CD`.
4. Extract the returned task ID.
5. Retrieve that task.
6. Mark it complete.
7. Delete it.

This verifies not only that the image builds, but also that the packaged application starts and its main CRUD flow works.

---

## 11. Sample Task Management Application

The sample application is a small Flask service.

### Endpoints

| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/` | Confirms the application is running |
| `GET` | `/health` | Health check; returns `{"status":"ok"}` |
| `GET` | `/tasks` | Lists all tasks |
| `POST` | `/tasks` | Creates a task; requires `title` |
| `GET` | `/tasks/<id>` | Returns one task or 404 |
| `PUT` | `/tasks/<id>/complete` | Marks a task complete or returns 404 |
| `DELETE` | `/tasks/<id>` | Deletes a task or returns 404 |

Task state is kept in an in-memory Python dictionary, so it is intentionally temporary and resets when the application process/container is restarted.

---

## 12. Logging and Build History

Each pipeline run creates a directory:

```text
build_history/<BUILD_NUMBER>/
```

For a successful run, files may include:

```text
build_history/V73/
├── pipeline_log.log
├── Install Dependencies.log
├── Compile Check.log
├── Run Unit Tests.log
├── Perform static analysis.log
├── Generate Coverage report.log
├── Build App Image.log
├── Run Application.log
└── htmlcov/
```

### Pipeline log

`pipeline_log.log` records stage start/completion information, timestamps, total pipeline duration, the final build status, and commit ID.

### Per-job logs

Each configured job receives its own log file. The runner captures combined standard output/error, appends timestamps, and records whether the job succeeded or failed.

This makes individual failures inspectable without losing the output of earlier completed stages.

---

## 13. Failure Handling

Jobs are executed sequentially. If a command returns a non-zero status, `runner.py`:

1. Records the command output in that job's log.
2. Marks the job as failed.
3. Records the failure in `pipeline_log.log`.
4. Raises an exception.
5. Terminates the runner process.

As a result, downstream stages do not execute after the first failed job.

Example:

```text
Build       -> SUCCESS
UnitTest    -> FAILED
Linter      -> NOT RUN
Coverage    -> NOT RUN
BuildImage  -> NOT RUN
RunApp      -> NOT RUN
```

---

## 14. Demonstrated Successful and Failed Builds

The supplied `build_history/` contains evidence for both required cases.

### Successful execution: V73

Build `V73` completed every configured stage successfully for commit:

```text
47da36925c64a912d66f4690edfcabb0849b774c
```

Its unit-test log reports:

```text
11 passed
```

The Docker log shows the generated image being tagged with the same full commit SHA, and the application log shows successful health and task CRUD requests.

### Failed execution: V74

Build `V74` failed during the `UnitTest` stage for commit:

```text
f47322a9a21534110e5fb6d755e2c653e23eddb4
```

The recorded demonstration intentionally expects the health status to be `"not ok"` even though the application correctly returns `"ok"`. The resulting test run reports:

```text
1 failed, 10 passed
```

The pipeline stops at this point, so Linter, Coverage, BuildImage, and RunAppContainer are not executed for `V74`. This demonstrates the required fail-fast behavior and failure logging.

> For a final "green" application branch, change the health assertion in `tests/test_tasks.py` back to `"ok"` after retaining the `V74` logs as evidence of the failed-run demonstration.

---

## 15. Running the Pipeline

After setup, make a commit on one of the configured branches:

```bash
git checkout dev-1
git add .
git commit -m "Trigger local CI pipeline"
```

The `post-commit` hook executes automatically.

Typical hook output begins with information such as:

```text
Detected new commit
Commit ID: <sha>
Pipeline triggered
Starting container
```

Inspect the newest build afterward:

```bash
ls build_history
cat build_history/V*/pipeline_log.log
```

For a specific build:

```bash
cat build_history/V73/pipeline_log.log
```

Open its coverage report from:

```text
build_history/V73/htmlcov/index.html
```


## 19. Technology Summary

| Technology | Role |
|---|---|
| Bash | Git hook and local orchestration |
| Git | Commit detection, branch state, exact revision checkout |
| Python | Trigger/controller and pipeline runner |
| YAML / PyYAML | Declarative pipeline configuration |
| Docker | Runner isolation and application packaging |
| pytest | Unit testing |
| pytest-cov | Coverage generation |
| Ruff | Static analysis/linting |
| Flask | Sample task-management web application |

