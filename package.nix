{
  stdenv,
  lib,
  fetchurl,
  autoPatchelfHook,
  pkg-config,
  patchelf,
  # Runtime dependencies
  gtk3,
  gdk-pixbuf,
  glib,
  libX11,
  libXcursor,
  libXext,
  libXi,
  libXrandr,
  libXrender,
  libXfixes,
  libGL,
  vulkan-loader,
  ocl-icd,
  openssl,
  zlib,
  krb5,
  icu,
  lttng-ust,
  libunwind,
  pciutils,
  fontconfig,
  freetype,
  at-spi2-core,
  dbus,
  libICE,
  libSM,
  mesa,
  # GPU and hardware topology
  libdrm,
  hwloc,
  libpciaccess,
  libdisplay-info,
  wayland,
  # Networking (OCCT licensing/updates)
  curl,
  # Device enumeration
  systemdLibs,
  hwdata,
  # Hardware discovery
  dmidecode,
  smartmontools,
  usbutils,
  zfs,
  # Build dependencies
  copyDesktopItems,
  makeDesktopItem,
  icoutils,
  # Additional sensors
  lm_sensors,
  nvme-cli,
  iproute2,
  libva-utils,
  vulkan-tools,
  util-linux,
  kmod,
  # Memory temperature monitoring (I2C/SMBus DIMM sensors)
  i2c-tools,
  # Upstream branch selection: "Stable" (default) or "Testing"
  branch ? "Stable",
}:

let
  # OCCT's bundled .NET native code calls legacy OpenSSL 1.1 symbols
  # (ERR_put_error, SSL_state) that were removed in OpenSSL 3.1+.
  # This shim provides those symbols by wrapping the modern 3.x API.
  openssl-compat = stdenv.mkDerivation {
    pname = "openssl-compat-shim";
    version = "1.0";

    dontUnpack = true;

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      openssl
      icu
    ];

    buildPhase = ''
            cat > compat_shim.c << 'EOF'
      #include <openssl/err.h>
      #include <openssl/ssl.h>
      #include <openssl/hmac.h>
      #include <openssl/rand.h>
      #include <stddef.h>

      /* Undefine macros so we can provide real function symbols */
      #undef ERR_put_error
      #undef SSL_load_error_strings
      #undef SSL_library_init
      #undef OpenSSL_add_all_algorithms
      #undef CRYPTO_num_locks
      #undef CRYPTO_set_locking_callback
      #undef CRYPTO_get_locking_callback
      #undef ERR_load_crypto_strings
      #undef OPENSSL_add_all_algorithms_noconf
      #undef OPENSSL_add_all_algorithms_conf
      #undef EVP_CIPHER_CTX_cleanup
      #undef EVP_CIPHER_CTX_init
      #undef EVP_MD_CTX_cleanup
      #undef EVP_MD_CTX_init
      #undef HMAC_CTX_cleanup
      #undef HMAC_CTX_init
      #undef RAND_pseudo_bytes
      #undef SSLeay
      #undef SSLeay_version

      void ERR_put_error(int lib, int func, int reason, const char *file, int line) {
          ERR_new();
          ERR_set_debug(file, line, NULL);
          ERR_set_error(lib, reason, NULL);
      }

      int SSL_state(const SSL *ssl) {
          return (int)SSL_get_state(ssl);
      }

      unsigned long SSLeay(void) { return OpenSSL_version_num(); }
      const char *SSLeay_version(int t) { return OpenSSL_version(t); }

      /* OpenSSL 1.1 legacy symbols removed in 3.0 */
      void SSL_load_error_strings(void) {}
      int SSL_library_init(void) { return 1; }
      void OpenSSL_add_all_algorithms(void) {}
      void ERR_load_crypto_strings(void) {}
      void OPENSSL_add_all_algorithms_noconf(void) {}
      void OPENSSL_add_all_algorithms_conf(void) {}

      /* EVP/Digest legacy symbols */
      void EVP_CIPHER_CTX_init(EVP_CIPHER_CTX *ctx) { EVP_CIPHER_CTX_reset(ctx); }
      void EVP_CIPHER_CTX_cleanup(EVP_CIPHER_CTX *ctx) { EVP_CIPHER_CTX_reset(ctx); }
      void EVP_MD_CTX_init(EVP_MD_CTX *ctx) { EVP_MD_CTX_reset(ctx); }
      void EVP_MD_CTX_cleanup(EVP_MD_CTX *ctx) { EVP_MD_CTX_reset(ctx); }

      /* HMAC legacy symbols */
      void HMAC_CTX_init(HMAC_CTX *ctx) { HMAC_CTX_reset(ctx); }
      void HMAC_CTX_cleanup(HMAC_CTX *ctx) { HMAC_CTX_reset(ctx); }

      /* RAND legacy symbols */
      int RAND_pseudo_bytes(unsigned char *buf, int num) { return RAND_bytes(buf, num); }

      /* Threading symbols from OpenSSL 1.1 */
      int CRYPTO_num_locks(void) { return 1; }
      void CRYPTO_set_locking_callback(void (*func)(int mode, int type, const char *file, int line)) {}
      void* CRYPTO_get_locking_callback(void) { return NULL; }

      /* CRYPTO_add_lock was for refcounting in 1.1; 3.x uses different mechanisms */
      /* This is a simplified dummy that might be enough if it's just for init */
      int CRYPTO_add_lock(int *pointer, int amount, int type, const char *file, int line) {
          *pointer += amount;
          return *pointer;
      }

      /* ICU shim: resolve versioned u_strlen at runtime (survives ICU bumps) */
      #include <dlfcn.h>
      #include <stdio.h>
      #include <stdlib.h>
      size_t u_strlen(const void *s) {
          static size_t (*real_fn)(const void *) = NULL;
          if (!real_fn) {
              char sym[32];
              for (int v = 76; v <= 90; v++) {
                  snprintf(sym, sizeof(sym), "u_strlen_%d", v);
                  real_fn = dlsym(RTLD_DEFAULT, sym);
                  if (real_fn) break;
              }
              if (!real_fn) {
                  fprintf(stderr, "OCCT: no u_strlen_XX found in ICU — update the compat shim\n");
                  abort();
              }
          }
          return real_fn(s);
      }

      /* Dummy DllMain for lazy Windows-to-Linux ports */
      int DllMain(void* hinstDLL, unsigned int fdwReason, void* lpvReserved) {
          return 1;
      }
      EOF

            $CC -shared -fPIC -o libocct_compat.so compat_shim.c \
              $(pkg-config --cflags openssl icu-uc) \
              $(pkg-config --libs openssl icu-uc) -ldl
    '';

    installPhase = ''
      mkdir -p $out/lib
      cp libocct_compat.so $out/lib/
    '';
  };

  # Per-branch source metadata (version, URL, hash)
  sources = {
    Stable = {
      version = "16.1.11";
      url = "https://www.ocbase.com/download-bin/edition:Personal/os:Linux/branch:Stable";
      hash = "sha256-yvKg/ariuICx5obWzWynbKSl47AL0A/gXsmoPYaaiek=";
    };
    Testing = {
      version = "16.1.11";
      url = "https://www.ocbase.com/download-bin/edition:Personal/os:Linux/branch:Testing";
      hash = "sha256-yvKg/ariuICx5obWzWynbKSl47AL0A/gXsmoPYaaiek=";
    };
  };

  source = sources.${branch} or (throw "Unknown branch '${branch}': must be 'Stable' or 'Testing'");

  # All libraries needed at runtime via LD_LIBRARY_PATH
  runtimeLibs = [
    gtk3
    gdk-pixbuf
    glib
    libX11
    libXcursor
    libXext
    libXi
    libXrandr
    libXrender
    libXfixes
    libICE
    libSM
    libGL
    mesa
    vulkan-loader
    ocl-icd
    openssl
    openssl-compat
    zlib
    krb5
    icu
    lttng-ust
    libunwind
    pciutils
    fontconfig
    freetype
    at-spi2-core
    dbus
    stdenv.cc.cc.lib
    # GPU and hardware topology
    libdrm
    hwloc
    libpciaccess
    libdisplay-info
    wayland
    curl
    systemdLibs
    # Monitoring tools
    lm_sensors
    nvme-cli
    iproute2
    libva-utils
    vulkan-tools
    # Memory temperature (I2C/SMBus DIMM sensors)
    i2c-tools
  ];
in
stdenv.mkDerivation rec {
  pname = "occt${lib.optionalString (branch == "Testing") "-testing"}";
  inherit (source) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  icon = fetchurl {
    url = "https://www.ocbase.com/favicon.ico";
    hash = "sha256-wkrRT+JtznpBoBMC68jncf8l9ad6ZWBPJtxi+oPJaaE=";
  };

  dontUnpack = true;

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    patchelf
    icoutils
  ];

  # Only the binary's direct NEEDED libs (from readelf -d)
  buildInputs = [
    zlib
    stdenv.cc.cc.lib
  ];

  installPhase = ''
        runHook preInstall

        # Install the shim first so we can reference it
        mkdir -p $out/lib/occt-compat
        cp ${openssl-compat}/lib/libocct_compat.so $out/lib/occt-compat/

        # Install the binary
        mkdir -p $out/opt/occt $out/bin
        cp --no-preserve=mode $src $out/opt/occt/occt-bin
        chmod +x $out/opt/occt/occt-bin

        # Wrapper script — handles $HOME expansion at runtime
        cat > $out/bin/occt << 'WRAPPER'
    #!/usr/bin/env bash
    # OCCT wrapper for NixOS

    OCCT_HOME="''${HOME}/.local/share/occt"
    OCCT_BIN="@out@/opt/occt/occt-bin"

    mkdir -p "''$OCCT_HOME"
    touch "''$OCCT_HOME/app_folder_in_home"
    touch "''$OCCT_HOME/disable_update"

    # Load kernel modules for hardware sensors (silent fail for non-root;
    # succeeds when run as root or if modules already loaded via NixOS config)
    modprobe msr 2>/dev/null || true
    modprobe i2c-dev 2>/dev/null || true
    modprobe jc42 2>/dev/null || true

    # OCCT extracts native monitoring libs at runtime (OcctMonitoringLib).
    # /tmp is noexec on NixOS → dlopen fails → SIGABRT.
    # Redirect to /var/tmp (exec-allowed) or OCCT_HOME.
    export TMPDIR="''$OCCT_HOME/tmp"
    mkdir -p "''$TMPDIR"

    # Clean stale .NET bundle extractions (one per binary hash, never auto-cleaned)
    find "''$OCCT_HOME/runtime/occt-bin/" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

    # Set up the environment
    # Priority: wrapped-openssl > runtimeLibs > existing LD_LIBRARY_PATH
    export LD_LIBRARY_PATH="@out@/lib/openssl-wrapped:@ldpath@''${LD_LIBRARY_PATH:+:''$LD_LIBRARY_PATH}"
    export LD_PRELOAD="@out@/lib/occt-compat/libocct_compat.so''${LD_PRELOAD:+:''$LD_PRELOAD}"
    export PATH="@binpath@''${PATH:+:''$PATH}"
    export GDK_BACKEND="wayland,x11"
    export OCL_ICD_VENDORS="/run/opengl-driver/etc/OpenCL/vendors/"
    export HWDATA_PATH="@hwdata@/share/hwdata"
    export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0
    export DOTNET_BUNDLE_EXTRACT_BASE_DIR="''$OCCT_HOME/runtime"

    cd "''$OCCT_HOME"
    exec "''$OCCT_BIN" "''$@"
    WRAPPER

        chmod +x $out/bin/occt
        substituteInPlace $out/bin/occt \
          --replace "@out@" "$out" \
          --replace "@ldpath@" "${lib.makeLibraryPath runtimeLibs}" \
          --replace "@binpath@" "${
            lib.makeBinPath [
              pciutils
              dmidecode
              smartmontools
              usbutils
              zfs
              lm_sensors
              nvme-cli
              iproute2
              libva-utils
              vulkan-tools
              util-linux
              kmod
              i2c-tools
            ]
          }" \
          --replace "@hwdata@" "${hwdata}"

        # Install the icons from the ICO file
        cp $icon occt.ico
        icotool -x occt.ico
        for size in 16 24 32 48 64 128 256; do
          # icotool -x produces files like occt_1_128x128x32.png
          if ls occt_*''${size}x''${size}x*.png >/dev/null 2>&1; then
            mkdir -p $out/share/icons/hicolor/''${size}x''${size}/apps
            cp occt_*''${size}x''${size}x*.png $out/share/icons/hicolor/''${size}x''${size}/apps/occt.png || true
          fi
        done
        # Fallback to a generic location if needed
        mkdir -p $out/share/pixmaps
        cp occt_*256x256x*.png $out/share/pixmaps/occt.png || cp occt_*.png $out/share/pixmaps/occt.png || true

        runHook postInstall
  '';

  postFixup = ''
    # Create a wrapped OpenSSL layer
    mkdir -p $out/lib/openssl-wrapped

    # Locate and copy OpenSSL libs explicitly
    LIBSSL=$(find ${lib.getLib openssl}/lib -name "libssl.so.3" | head -n 1)
    LIBCRYPTO=$(find ${lib.getLib openssl}/lib -name "libcrypto.so.3" | head -n 1)

    if [ -z "$LIBSSL" ] || [ -z "$LIBCRYPTO" ]; then
      echo "ERROR: Could not find OpenSSL libraries!"
      ls -R ${lib.getLib openssl}/lib
      exit 1
    fi

    cp -vL "$LIBSSL" $out/lib/openssl-wrapped/libssl.so.3
    cp -vL "$LIBCRYPTO" $out/lib/openssl-wrapped/libcrypto.so.3
    chmod +w $out/lib/openssl-wrapped/libssl.so.3 $out/lib/openssl-wrapped/libcrypto.so.3

    # Force both libssl and libcrypto to load our shim
    patchelf --add-needed libocct_compat.so $out/lib/openssl-wrapped/libssl.so.3
    patchelf --add-needed libocct_compat.so $out/lib/openssl-wrapped/libcrypto.so.3
    patchelf --set-rpath "$out/lib/occt-compat" $out/lib/openssl-wrapped/libssl.so.3
    patchelf --set-rpath "$out/lib/occt-compat" $out/lib/openssl-wrapped/libcrypto.so.3

    # Force the binary to use our wrapped OpenSSL and shim
    patchelf --add-needed libocct_compat.so $out/opt/occt/occt-bin
    patchelf --add-rpath "$out/lib/occt-compat:$out/lib/openssl-wrapped" $out/opt/occt/occt-bin
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "occt";
      exec = "occt";
      icon = "occt";
      desktopName = "OCCT";
      genericName = "Stability Test & Benchmark";
      categories = [
        "System"
        "Utility"
        "HardwareSettings"
      ];
    })
  ];

  meta = with lib; {
    description = "OCCT - OverClock Checking Tool (stability & benchmark)";
    longDescription = ''
      OCCT is the most popular all-in-one stability check and stress test tool available. 
      It generates heavy loads on your components while checking for errors, and 
      detects hardware issues before they become critical.

      This NixOS package uses a custom compatibility shim to support the internal 
      .NET runtime's dependency on legacy OpenSSL 1.1 symbols.
    '';
    homepage = "https://www.ocbase.com/";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "occt";
    maintainers = [ "Daaboulex" ];
  };
}
