#!/bin/bash
# Publish PetStore WASM release with minisig signatures
# Usage: ./scripts/publish.sh <version> [--draft]

set -e

VERSION="${1:-}"
DRAFT_FLAG="${2:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/publish.sh <version> [--draft]"
    echo "Example: ./scripts/publish.sh 0.1.0"
    echo "         ./scripts/publish.sh 0.1.0 --draft"
    exit 1
fi

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
    echo "Error: Invalid version format. Use semver (e.g., 0.1.0, 0.1.0-beta)"
    exit 1
fi

TAG="petstore-${VERSION}"

echo "🔨 Building PetStore WASM components..."
zig build

echo "📦 Preparing release artifacts..."
mkdir -p dist
cp zig-out/petstore.wasm dist/
cp zig-out/petstore-test.wasm dist/

echo "📝 Generating checksums..."
cd dist
sha256sum *.wasm > SHA256SUMS
echo "Checksums generated:"
cat SHA256SUMS
cd ..

echo "🔑 Looking for minisign keys..."
if [ ! -f ~/.minisign/minisign.key ]; then
    echo "❌ Error: minisign secret key not found at ~/.minisign/minisign.key"
    echo "To generate keys, run: minisign -G"
    exit 1
fi

echo "✍️  Signing WASM files..."
cd dist
for wasm in *.wasm; do
    echo "  Signing $wasm..."
    minisign -Sm "$wasm" -s ~/.minisign/minisign.key -t "PetStore release ${VERSION}"
done
cd ..

echo "📋 Verifying signatures..."
cd dist
PUBKEY_FILE=~/.minisign/minisign.pub
if [ -f "$PUBKEY_FILE" ]; then
    for wasm in *.wasm; do
        echo "  Verifying $wasm..."
        minisign -Vm "$wasm" -p "$PUBKEY_FILE" || true
    done
fi
cd ..

echo "🏷️  Creating git tag..."
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "⚠️  Tag $TAG already exists. Removing..."
    git tag -d "$TAG"
    git push origin --delete "$TAG" || true
fi

# Create annotated tag
git tag -a "$TAG" -m "Release PetStore v${VERSION}"

echo "📤 Pushing tag to GitHub..."
git push origin "$TAG"

echo ""
echo "✅ Release ${VERSION} published!"
echo ""
echo "📌 Release artifacts in ./dist/:"
ls -lh dist/
echo ""
echo "Next steps:"
echo "1. Visit: https://github.com/cataggar/wabt/releases/tag/${TAG}"
echo "2. Edit the release and add release notes"
echo "3. Upload the signed artifacts from ./dist/"
echo ""
echo "To verify signatures later:"
echo "  minisign -Vm petstore.wasm -p ~/.minisign/minisign.pub"
