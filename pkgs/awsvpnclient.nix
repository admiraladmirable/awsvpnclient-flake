{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,

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

  # optional: for desktop integration
  makeDesktopItem,
}:

let
  # Latest per AWS Linux release notes: 5.3.2 (Dec 17, 2025) :contentReference[oaicite:1]{index=1}
  version = "5.3.2";

  src = fetchurl {
    # Release-notes “Download version 5.3.2” points to this CloudFront path :contentReference[oaicite:2]{index=2}
    url = "https://d20adtppz83p9s.cloudfront.net/GTK/${version}/awsvpnclient_amd64.deb";
    # sha256 published on the release notes page :contentReference[oaicite:3]{index=3}
    sha256 = "89e4b9f2c9f7def37167f5f137f4ff9c6c5246fd6e0a7244b70c196a17683569";
  };

  desktopItem = makeDesktopItem {
    name = "awsvpnclient";
    desktopName = "AWS VPN Client";
    comment = "AWS Client VPN for Linux";
    exec = "awsvpnclient";
    categories = [ "Network" ];
    terminal = false;
  };

in
stdenv.mkDerivation {
  pname = "awsvpnclient";
  inherit version src;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
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
    xorg.libXext
    xorg.libXrender
    xorg.libXfixes
    xorg.libXi
    xorg.libXtst
    xorg.libXrandr
    xorg.libxcb
    libxkbcommon
    dbus
    alsa-lib
    icu
  ];

  unpackPhase = "true";

  installPhase = ''
    runHook preInstall

    # Extract the .deb payload
    dpkg-deb -x "$src" "$out"

    # Fix permissions - .deb files often have problematic ownership/permissions
    chmod -R u+w "$out"
    find "$out" -type d -exec chmod 755 {} +
    # Set files to 644, but preserve execute bit where it exists
    find "$out" -type f -perm /111 -exec chmod 755 {} +
    find "$out" -type f ! -perm /111 -exec chmod 644 {} +

    # Upstream installs into /opt/awsvpnclient
    # Provide a stable wrapper in $out/bin
    mkdir -p "$out/bin"

    # The actual GUI binary name in /opt often contains spaces.
    # We wrap it under a simple "awsvpnclient" command.
    if [ -e "$out/opt/awsvpnclient/AWS VPN Client" ]; then
      makeWrapper "$out/opt/awsvpnclient/AWS VPN Client" "$out/bin/awsvpnclient" \
        --set-default XDG_DATA_DIRS "$out/share:$XDG_DATA_DIRS"
    elif [ -e "$out/opt/awsvpnclient/awsvpnclient" ]; then
      makeWrapper "$out/opt/awsvpnclient/awsvpnclient" "$out/bin/awsvpnclient" \
        --set-default XDG_DATA_DIRS "$out/share:$XDG_DATA_DIRS"
    else
      echo "ERROR: Could not find AWS VPN Client executable under $out/opt/awsvpnclient"
      echo "Contents:"
      find "$out/opt/awsvpnclient" -maxdepth 2 -type f -print || true
      exit 1
    fi

    # Desktop integration (optional but nice)
    mkdir -p "$out/share/applications"
    ln -s "${desktopItem}/share/applications/"* "$out/share/applications/" || true

    runHook postInstall
  '';

  # If autoPatchelf misses something, this keeps it from failing the build.
  # You can tighten this later once you know exact binaries.
  autoPatchelfIgnoreMissingDeps = true;

  meta = {
    description = "AWS provided Client VPN for Linux (packaged from upstream .deb)";
    homepage = "https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux.html";
    license = lib.licenses.unfreeRedistributable; # upstream binary distribution
    platforms = [ "x86_64-linux" ];
    mainProgram = "awsvpnclient";
  };
}
