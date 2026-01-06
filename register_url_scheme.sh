#!/bin/bash
# Register the app with Launch Services for URL scheme handling during development
# This allows URL callbacks to work even when running from DerivedData

APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

if [ -d "$APP_PATH" ]; then
    echo "Registering app for URL scheme handling: $APP_PATH"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH"
else
    echo "Warning: App not found at $APP_PATH"
fi
