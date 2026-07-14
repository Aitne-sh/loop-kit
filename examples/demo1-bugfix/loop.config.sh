# loop.config.sh — demo1: fix the failing tests (cheap + fast)

VERIFY_COMMANDS=(
  "uv run pytest -q"
)

DENIED_PATHS="tests/** .env* secrets/**"
ESCALATE_PATHS="pyproject.toml"

MAX_ITERATIONS=5
MAX_COST_USD=2.00
MAX_ITER_SECONDS=600

STAGNATION_N=2
REPEAT_FAIL_N=3
FUTILE_N=2

REVIEW_MODE="always"
MAX_REVISIONS=3
STOP_EVAL="true"

PERMISSION_MODE="acceptEdits"
