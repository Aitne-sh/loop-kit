# loop.config.sh — demo2: contract-driven feature work
# Note: the existing test file is denied (the loop must not weaken it),
# but new test files are allowed — REQ-004 requires the loop to add them.

VERIFY_COMMANDS=(
  "uv run pytest -q"
)

DENIED_PATHS="tests/test_stats.py .env* secrets/**"
ESCALATE_PATHS="pyproject.toml"

MAX_ITERATIONS=6
MAX_COST_USD=3.00
MAX_ITER_SECONDS=600

STAGNATION_N=2
REPEAT_FAIL_N=3
FUTILE_N=2

REVIEW_MODE="always"
MAX_REVISIONS=3
STOP_EVAL="true"

PERMISSION_MODE="acceptEdits"
