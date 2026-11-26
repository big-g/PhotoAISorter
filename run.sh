#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

VENV_DIR=".venv"
LAUNCH_MODE="console"
VENV_RECREATE_DONE=0
IMPORT_REPAIR_DONE=0

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

if [ -d ".venv-linux" ] && [ ! -d ".venv" ]; then
    echo "[migrate] .venv-linux → .venv"
    mv ".venv-linux" ".venv"
fi

if [ -d "ffmpeg-runtime/bin" ] && [ -x "ffmpeg-runtime/bin/ffmpeg" ]; then
    export PATH="$(pwd)/ffmpeg-runtime/bin:$PATH"
fi

show_help() {
    echo "Usage:"
    echo "  ./run.sh           — create/update .venv, dependencies, checks, and launch GUI"
    echo "  ./run.sh gui       — same (GUI)"
    echo "  ./run.sh test      — same, then pytest -q"
    echo "  ./run.sh help      — this help"
    echo
    exit 0
}

fail() {
    echo
    echo "Press Enter to exit..."
    read -r
    exit 1
}

remove_venv() {
    local tries=0
    while [ -d "$VENV_DIR" ] && [ $tries -lt 5 ]; do
        rm -rf "$VENV_DIR" 2>/dev/null || true
        if [ -d "$VENV_DIR" ]; then
            tries=$((tries + 1))
            sleep 2
        fi
    done
    [ ! -d "$VENV_DIR" ]
}

case "${1:-}" in
    help|-h|--help) show_help ;;
    gui) LAUNCH_MODE="gui" ;;
    test) LAUNCH_MODE="test" ;;
esac

echo
echo " ========================================"
echo "  Photo AI Sorter — launch"
echo " ========================================"
echo

if [ ! -f "requirements.txt" ]; then
    echo "[ERROR] requirements.txt not found in project folder."
    echo "Expected: $(pwd)/requirements.txt"
    fail
fi

if ! command -v python3 &>/dev/null; then
    echo "[ERROR] python3 not found. Python 3.10+ is required."
    echo "Install: sudo apt install python3 python3-venv python3-pip"
    fail
fi

create_venv() {
    if [ ! -f "$VENV_DIR/bin/python" ]; then
        echo "[1/3] Creating virtual environment $VENV_DIR ..."
        python3 -m venv "$VENV_DIR"
        if [ $? -ne 0 ]; then
            echo "[ERROR] Failed to create venv."
            fail
        fi
        echo "      Done."
    else
        echo "[1/3] Virtual environment $VENV_DIR already exists."
    fi
}

create_venv

PY="$(pwd)/$VENV_DIR/bin/python"
DEPS_MARKER="$(pwd)/$VENV_DIR/.photo_ai_sorter_deps_ok"

if ! "$PY" -c "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)" 2>/dev/null; then
    if [ "$VENV_RECREATE_DONE" -eq 1 ]; then
        echo "[ERROR] Python 3.10+ is required. Check the system Python and run again."
        fail
    fi
    echo "[1/3] $VENV_DIR is damaged or was created with an older Python — recreating ..."
    if ! remove_venv; then
        echo "[ERROR] Could not remove the old .venv."
        fail
    fi
    VENV_RECREATE_DONE=1
    create_venv
    PY="$(pwd)/$VENV_DIR/bin/python"
fi

echo "[2/3] Checking dependencies ..."
NEED_INSTALL=0
if [ ! -f "$DEPS_MARKER" ]; then
    NEED_INSTALL=1
else
    if ! "$PY" -c "
from pathlib import Path; import sys
req = Path('requirements.txt')
marker = Path('$VENV_DIR/.photo_ai_sorter_deps_ok')
sys.exit(0 if marker.exists() and marker.stat().st_mtime >= req.stat().st_mtime else 1)
" 2>/dev/null; then
        NEED_INSTALL=1
    fi
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
    echo "      Installing/updating pip and packages ..."
    "$PY" -m pip install --upgrade pip setuptools wheel -q --disable-pip-version-check || {
        echo "[ERROR] pip install failed."
        "$PY" -m pip install -r requirements.txt --upgrade --disable-pip-version-check
        fail
    }
    "$PY" -m pip install -r requirements.txt --upgrade -q --disable-pip-version-check || {
        echo "[ERROR] pip install failed."
        "$PY" -m pip install -r requirements.txt --upgrade --disable-pip-version-check
        fail
    }
    "$PY" -c "from pathlib import Path; Path('$VENV_DIR/.photo_ai_sorter_deps_ok').write_text('ok', encoding='utf-8')"
    echo "      Done."
else
    echo "      Dependencies are up to date."
fi

if command -v nvidia-smi &>/dev/null; then
    if ! "$PY" -c "import torch; import sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
        echo "[2/3] NVIDIA GPU detected — installing CUDA (cu126) PyTorch ..."
        # --force-reinstall --no-deps: a CPU torch of the same version already
        # satisfies torch>=..., so --upgrade is a no-op; force the CUDA wheel and
        # keep numpy/pillow (absent from the pytorch index) intact.
        if ! "$PY" -m pip install -r requirements-gpu.txt --force-reinstall --no-deps -q --disable-pip-version-check; then
            echo "[WARNING] Could not install torch+cuda. CLIP will use CPU."
        else
            echo "      PyTorch CUDA installed."
        fi
    fi
fi

if [ "$LAUNCH_MODE" = "test" ]; then
    "$PY" -m pip install -r requirements-dev.txt --upgrade -q --disable-pip-version-check || {
        echo "[ERROR] Installing development dependencies failed."
        "$PY" -m pip install -r requirements-dev.txt --upgrade --disable-pip-version-check
        fail
    }
fi

echo "[3/3] Checking environment ..."
if ! "$PY" -c "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)"; then
    echo "[ERROR] Python 3.10+ is required. Remove $VENV_DIR and run the script again."
    fail
fi

"$PY" -m compileall -q app main.py || {
    echo "[ERROR] Python compilation failed (syntax error)."
    fail
}

if ! "$PY" -c "import app.gui; import app.gui_duplicates; import app.duplicate_finder; import app.duplicate_worker; import app.signature_db; import app.worker; import app.lm_studio; import app.settings_store; import app.video_frames; print('Import check: OK')"; then
    if [ "$IMPORT_REPAIR_DONE" -eq 0 ]; then
        echo "[3/3] Imports failed — recreating $VENV_DIR from scratch ..."
        if ! remove_venv; then
            echo "[ERROR] Could not remove old $VENV_DIR."
            fail
        fi
        IMPORT_REPAIR_DONE=1
        VENV_RECREATE_DONE=1
        create_venv
        PY="$(pwd)/$VENV_DIR/bin/python"
        echo "      Installing dependencies ..."
        "$PY" -m pip install --upgrade pip setuptools wheel -q --disable-pip-version-check
        "$PY" -m pip install -r requirements.txt --upgrade -q --disable-pip-version-check
        if [ "$LAUNCH_MODE" = "test" ]; then
            "$PY" -m pip install -r requirements-dev.txt --upgrade -q --disable-pip-version-check
        fi
        "$PY" -c "from pathlib import Path; Path('$VENV_DIR/.photo_ai_sorter_deps_ok').write_text('ok', encoding='utf-8')"
        if ! "$PY" -c "import app.gui; import app.gui_duplicates; import app.duplicate_finder; import app.duplicate_worker; import app.signature_db; import app.worker; import app.lm_studio; import app.settings_store; import app.video_frames; print('Проверка импорта: OK')"; then
            echo "[ERROR] Could not import the application."
            echo "Try manually: $PY -m pip install -r requirements.txt -v"
            fail
        fi
    else
        echo "[ERROR] Could not import the application."
        echo "Try manually: $PY -m pip install -r requirements.txt -v"
        fail
    fi
fi

if [ "$LAUNCH_MODE" = "test" ]; then
    echo
    echo "      Running tests (pytest) ..."
    echo
    "$PY" -m pytest -q
    EXITCODE=$?
    if [ $EXITCODE -ne 0 ]; then
        echo
        echo "[TESTS] Exit code: $EXITCODE"
        fail
    fi
    echo
    echo "Tests passed."
    exit 0
fi

echo
echo "      Launching GUI ..."
echo
"$PY" main.py
EXITCODE=$?

if [ $EXITCODE -ne 0 ]; then
    echo
    echo "[EXIT] Error code: $EXITCODE"
    fail
fi
echo
echo "Application exited normally."
exit 0
