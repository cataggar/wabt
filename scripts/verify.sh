#!/bin/bash
# Verify PetStore WASM signatures
# Usage: ./scripts/verify.sh <path-to-pubkey> [wasm-files...]

set -e

PUBKEY="${1:-}"
SHIFT_COUNT=1

if [ -z "$PUBKEY" ]; then
    echo "Usage: ./scripts/verify.sh <path-to-pubkey> [wasm-files...]"
    echo "Example: ./scripts/verify.sh ~/.minisign/minisign.pub dist/*.wasm"
    exit 1
fi

if [ ! -f "$PUBKEY" ]; then
    echo "❌ Error: Public key not found at $PUBKEY"
    exit 1
fi

# Get files to verify
shift $SHIFT_COUNT
if [ $# -eq 0 ]; then
    # Find wasm files in dist or current directory
    if [ -d dist ]; then
        WASM_FILES=$(find dist -name "*.wasm" -type f)
    else
        WASM_FILES=$(find . -maxdepth 1 -name "*.wasm" -type f)
    fi
else
    WASM_FILES="$@"
fi

if [ -z "$WASM_FILES" ]; then
    echo "❌ Error: No WASM files found"
    exit 1
fi

echo "🔑 Using public key: $PUBKEY"
echo "📝 Verifying signatures..."
echo ""

ALL_VALID=true
for wasm in $WASM_FILES; do
    if [ ! -f "$wasm" ]; then
        continue
    fi
    
    SIG_FILE="${wasm}.minisig"
    
    if [ ! -f "$SIG_FILE" ]; then
        echo "⚠️  $wasm - Signature file not found (${SIG_FILE})"
        ALL_VALID=false
        continue
    fi
    
    echo -n "Verifying $wasm... "
    if minisign -Vm "$wasm" -p "$PUBKEY" >/dev/null 2>&1; then
        echo "✅"
    else
        echo "❌ FAILED"
        ALL_VALID=false
    fi
done

echo ""

# Also verify checksums if available
if [ -f dist/SHA256SUMS ] || [ -f SHA256SUMS ]; then
    SUMS_FILE="dist/SHA256SUMS"
    [ ! -f "$SUMS_FILE" ] && SUMS_FILE="SHA256SUMS"
    
    echo "🔐 Verifying checksums from $SUMS_FILE..."
    
    if sha256sum -c "$SUMS_FILE"; then
        echo "✅ All checksums valid"
    else
        echo "❌ Checksum verification failed"
        ALL_VALID=false
    fi
fi

echo ""
if [ "$ALL_VALID" = true ]; then
    echo "✅ All verifications passed!"
    exit 0
else
    echo "❌ Some verifications failed"
    exit 1
fi
