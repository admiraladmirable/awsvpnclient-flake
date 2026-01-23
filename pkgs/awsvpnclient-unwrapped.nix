{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  pkgs,

  # runtime deps commonly needed for GUI/electron-ish apps
  gtk3,
  glib,
  nss,
  nspr,
  atk,
  at-spi2-atk,
  pango,
  cairo,
  gdk-pixbuf,
  libdrm,
  mesa,
  xorg,
  libxkbcommon,
  dbus,
  alsa-lib,

  # .NET runtime dependencies
  icu,
  libz,
  lttng-ust_2_12,

  # system utilities required at runtime
  xdg-utils,
  lsof,

  # optional: for desktop integration
  makeDesktopItem,
}:

let
  version = "5.3.2";

  src = fetchurl {
    url = "https://d20adtppz83p9s.cloudfront.net/GTK/${version}/awsvpnclient_amd64.deb";
    # sha256 published on the release notes page https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-release-notes.html
    sha256 = "89e4b9f2c9f7def37167f5f137f4ff9c6c5246fd6e0a7244b70c196a17683569";
  };

in
stdenv.mkDerivation {
  pname = "awsvpnclient-unwrapped";
  inherit version src;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    gtk3
    glib
    nss
    nspr
    atk
    at-spi2-atk
    pango
    cairo
    gdk-pixbuf
    libdrm
    mesa
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libxcb
    xorg.libxshmfence
    libxkbcommon
    dbus
    alsa-lib
    icu
    libz
    lttng-ust_2_12
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    # Copy everything to output
    mkdir -p "$out/opt"
    cp -r opt/awsvpnclient "$out/opt/"

    # Normalize permissions to prevent nix sandbox errors
    chmod -R u+w "$out"
    find "$out" -type d -exec chmod 755 {} +
    find "$out" -type f -perm /111 -exec chmod 755 {} +
    find "$out" -type f ! -perm /111 -exec chmod 644 {} +

    # Copy D-Bus configuration
    mkdir -p "$out/share/dbus-1/system.d"
    cp -r etc/dbus-1/system.d/* "$out/share/dbus-1/system.d/" || true

    # Copy desktop file and icon
    mkdir -p "$out/share/applications"
    mkdir -p "$out/share/pixmaps"
    cp usr/share/applications/awsvpnclient.desktop "$out/share/applications/"
    cp usr/share/pixmaps/acvc-64.png "$out/share/pixmaps/"

    # Fix desktop file issues (same fixes as AUR package)
    # 1. Fix Exec line - remove \s escape sequences
    # 2. Fix Icon - remove .png extension for proper icon lookup
    substituteInPlace "$out/share/applications/awsvpnclient.desktop" \
      --replace-fail '"/opt/awsvpnclient/AWS\sVPN\sClient"' '"/opt/awsvpnclient/AWS VPN Client"' \
      --replace-fail 'Icon=acvc-64.png' 'Icon=acvc-64'

    runHook postInstall
  '';

  # Disable automatic patchelf - we'll do it manually to exclude openvpn directory
  dontAutoPatchelf = true;

  postFixup = ''
    # Workaround for SQL library compatibility issues (from AUR package)
    if [ -f "$out/opt/awsvpnclient/libe_sqlite3.so" ]; then
      mv "$out/opt/awsvpnclient/libe_sqlite3.so" "$out/opt/awsvpnclient/libe_sqlite3.so.disabled"
    fi

    # Move entire openvpn directory out of the way to preserve ALL files unmodified
    # The application validates checksums including shebangs, so we must restore originals
    OPENVPN_BACKUP=$(mktemp -d)
    mv "$out/opt/awsvpnclient/Service/Resources/openvpn" "$OPENVPN_BACKUP/"

    # Now run autoPatchelf on everything except the openvpn directory
    echo "Running autoPatchelf (excluding openvpn directory)..."
    autoPatchelf "$out"

    # Restore openvpn directory from the original source
    # This ensures files are completely unmodified (no patchelf, no patchShebangs)
    echo "Restoring openvpn directory from original source..."
    mkdir -p "$out/opt/awsvpnclient/Service/Resources/openvpn"
    cd "$OPENVPN_BACKUP"
    dpkg-deb -x ${src} extracted
    cp -r extracted/opt/awsvpnclient/Service/Resources/openvpn/* "$out/opt/awsvpnclient/Service/Resources/openvpn/"
    rm -rf "$OPENVPN_BACKUP"
  '';

  meta = {
    description = "AWS provided Client VPN for Linux (unwrapped)";
    homepage = "https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux.html";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "x86_64-linux" ];
  };
}
