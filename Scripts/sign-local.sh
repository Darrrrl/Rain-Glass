#!/bin/sh
set -eu

# Give the unsigned Debug bundles valid ad hoc signatures for local installation.
if [ "${CONFIGURATION:-}" != "Debug" ] || [ "${CODE_SIGNING_ALLOWED:-}" != "NO" ]; then
    exit 0
fi

app="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
saver="${app}/Contents/Resources/RainGlass.saver"
/usr/bin/codesign --force --sign - --entitlements "${PROJECT_DIR}/RainGlass/ScreenSaver/RainGlassSaver.entitlements" "${saver}"
for library in "${app}"/Contents/MacOS/*.dylib; do
    [ -f "${library}" ] || continue
    /usr/bin/codesign --force --sign - "${library}"
done
/usr/bin/codesign --force --sign - --entitlements "${PROJECT_DIR}/RainGlass/App/RainGlass.entitlements" "${app}"
