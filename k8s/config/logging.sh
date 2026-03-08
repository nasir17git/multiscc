log_info()    { echo "ℹ️ [INFO] $*"; }
log_success() { echo "✅ [OK]   $*"; }
log_error()   { echo "❌ [ERR]  $*" >&2; }