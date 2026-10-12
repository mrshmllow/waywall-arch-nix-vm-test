let
  npins = import ./npins { };
  pkgs = import npins.nixpkgs { };

  src = pkgs.fetchFromGitHub {
    owner = "tesselslate";
    repo = "waywall";
    rev = "300868207819618025d71ce98b03972868adafd5";
    hash = "sha256-mBm4C0t809NWI0/HR53eQGuGSGj7Jrgv9sDh36kxvqM=";
  };

  pacmanConf =
    let
      date = "2026/10/11";
    in
    pkgs.writeText "pacman.conf" ''
      [options]
      Architecture = x86_64
      SigLevel = Never
      DisableSandbox

      [core]
      Server = https://archive.archlinux.org/repos/${date}/$repo/os/$arch

      [extra]
      Server = https://archive.archlinux.org/repos/${date}/$repo/os/$arch
    '';

  mkPackages =
    { names, hash }:
    pkgs.runCommand "arch-packages"
      {
        nativeBuildInputs = [
          pkgs.pacman
          pkgs.fakeroot
        ];
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = hash;
      }
      ''
        set -x -e

        mkdir -p db root gpg $out

        fakeroot pacman --config ${pacmanConf} \
          --dbpath $PWD/db --root $PWD/root --gpgdir $PWD/gpg \
          --cachedir $out --logfile /dev/null \
          -Syw --noconfirm ${pkgs.lib.escapeShellArgs names}

        rm -f $out/*.part
      '';

  archImage =
    let
      archPackages = mkPackages {
        names = [
          "base-devel"
          "meson"
          "libegl"
          "libgles"
          "luajit"
          "libspng"
          "wayland"
          "libxcb"
          "libxkbcommon"
          "xorg-xwayland"
          "wayland-protocols"
          "meson"
          "git"
        ];
        hash = "";
      };
    in
    pkgs.vmTools.runInLinuxVM (
      pkgs.stdenv.mkDerivation rec {
        name = "arch-image";

        nativeBuildInputs = [
          pkgs.pacman
          pkgs.e2fsprogs
          pkgs.util-linux
        ];

        preVM = pkgs.vmTools.createEmptyImage {
          size = 4096;
          fullName = name;
        };

        buildCommand = ''
          mkfs.ext4 /dev/vda
          mkdir -p /mnt
          mount /dev/vda /mnt
          mkdir -p /mnt/{dev,proc,sys,etc,var/lib/pacman}
          mount --bind /dev  /mnt/dev
          mount --bind /proc /mnt/proc
          mount --bind /sys  /mnt/sys

          cat > pacman.conf <<EOF
          [options]
          Architecture = x86_64
          SigLevel = Never
          LocalFileSigLevel = Never
          EOF

          pacman --config pacman.conf --root /mnt --dbpath /mnt/var/lib/pacman \
            --noconfirm --noscriptlet -U ${archPackages}/*.pkg.tar.zst

          umount /mnt/dev /mnt/proc /mnt/sys
          umount /mnt
        '';
      }
    );

in
pkgs.vmTools.runInLinuxImage (
  pkgs.stdenv.mkDerivation {
    name = "waywall";

    diskImage = archImage;
    diskImageFormat = "qcow2";
    memSize = 2048;

    inherit src;

    buildPhase = ''
      set -x -e

      cp -r $src .
      useradd -m builduser
      chown -R builduser:builduser .

      pushd contrib
      runuser -l builduser -c "cd $PWD && makepkg --nodeps --noconfirm"
    '';
  }
)
