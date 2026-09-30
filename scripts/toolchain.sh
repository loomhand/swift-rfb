#!/bin/bash
# Sourced by the other scripts. Some Command Line Tools installs keep files
# from an older release (a second SwiftBridging module map and stale
# PackageDescription private interfaces) that break every Foundation import
# and every manifest. This masks them without touching /Library; no-op when
# the toolchain is clean.

CLT=/Library/Developer/CommandLineTools
FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/toolchain-fix"

stale_modulemap="$CLT/usr/include/swift/module.modulemap"
if [ -f "$stale_modulemap" ] && [ -f "$CLT/usr/include/swift/bridging.modulemap" ]; then
  mkdir -p "$FIX_DIR/usr/bin"
  ln -sfn "$CLT/usr/lib" "$FIX_DIR/usr/lib"
  : >"$FIX_DIR/empty.modulemap"
  printf '{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file", "name": "%s", "external-contents": "%s" } ] }\n' \
    "$stale_modulemap" "$FIX_DIR/empty.modulemap" >"$FIX_DIR/vfs.yaml"
  cat >"$FIX_DIR/usr/bin/swift-frontend" <<SH
#!/bin/bash
if [ "\$1" = "-frontend" ]; then
  exec "$CLT/usr/bin/swift-frontend" "\$1" -vfsoverlay "$FIX_DIR/vfs.yaml" "\${@:2}"
fi
exec "$CLT/usr/bin/swift-frontend" "\$@"
SH
  chmod +x "$FIX_DIR/usr/bin/swift-frontend"
  export SWIFT_DRIVER_SWIFT_FRONTEND_EXEC="$FIX_DIR/usr/bin/swift-frontend"
fi

if compgen -G "$CLT/usr/lib/swift/pm/ManifestAPI/*.swiftmodule/*.private.swiftinterface" >/dev/null; then
  mkdir -p "$FIX_DIR/pm"
  for api in ManifestAPI PluginAPI; do
    if [ ! -d "$FIX_DIR/pm/$api" ]; then
      cp -R "$CLT/usr/lib/swift/pm/$api" "$FIX_DIR/pm/$api"
      rm -f "$FIX_DIR/pm/$api"/*.swiftmodule/*.private.swiftinterface
    fi
  done
  export SWIFTPM_CUSTOM_LIBS_DIR="$FIX_DIR/pm"
fi
