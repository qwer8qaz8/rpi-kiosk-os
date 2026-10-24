#!/usr/bin/env bash
# ==============================================================================
# prompt-exit.sh - Triggers Exit Confirmation Dialog from compositor or taskbar
# ==============================================================================

curl -s -X POST http://127.0.0.1:8080/api/admin/prompt_exit >/dev/null 2>&1 || true
