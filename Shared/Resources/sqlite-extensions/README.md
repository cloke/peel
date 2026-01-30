# sqlite-vec Extension

This folder is for documentation only. **DO NOT put vec0.dylib here** - Xcode will auto-link it and crash the app on launch.

## Setup

1. **Download**: Get `vec0.dylib` for macOS ARM64 from [sqlite-vec releases](https://github.com/asg017/sqlite-vec/releases)

2. **Sign** (required for macOS to load it):
```bash
# List your signing identities
security find-identity -v -p codesigning

# Sign with your Apple Development certificate
codesign -f -s "Apple Development: Your Name (XXXXXXXXXX)" vec0.dylib
```

3. **Install** to Application Support (NOT the project folder!):
```bash
mkdir -p "$HOME/Library/Application Support/Peel/Extensions"
cp vec0.dylib "$HOME/Library/Application Support/Peel/Extensions/"
```

4. Restart Peel. Check `rag.status` - it should report `extensionLoaded: True`.

## Why Not In The Project?

Xcode automatically links any `.dylib` files it finds in the project folder, which causes the app to crash on launch because the dylib isn't in the expected load path. By keeping it in Application Support, we load it at runtime via `sqlite3_load_extension()` instead.

## Troubleshooting

- **"code signature not valid"**: Re-sign with your developer certificate
- **App crashes on launch**: The dylib is in the project folder - remove it!
- **extensionLoaded: False**: Check the Xcode console for `[RAG]` log messages showing which paths were checked
