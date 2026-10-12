let
  npins = import ./npins { };
  pkgs = import npins.nixpkgs { };

  waywallRev = "0.2026.10.12b";
  waywallSrc = pkgs.fetchFromGitHub {
    owner = "tesselslate";
    repo = "waywall";
    rev = waywallRev;
    hash = "sha256-mBm4C0t809NWI0/HR53eQGuGSGj7Jrgv9sDh36kxvqM=";
  };

  glfwRev = "3.4";
  glfwSrc = pkgs.applyPatches {
    src = pkgs.fetchFromGitHub {
      owner = "glfw";
      repo = "glfw";
      rev = glfwRev;
      hash = "sha256-FcnQPDeNHgov1Z07gjFze0VMz2diOrpbKZCsI96ngz0=";
    };
    patches = [ "${waywallSrc}/contrib/glfw.patch" ];
  };

  maintainers-md = pkgs.writeText "MAINTAINERS.md" ''
    GLFW Maintainers and Contributors:
    - See https://github.com/glfw/glfw/blob/${glfwRev}/CONTRIBUTORS.md for the list of contributors (or the bundled Contributors.md file).

    Note:
    This version of GLFW (${glfwRev}) includes a patch from the waywall project (https://github.com/tesselslate/waywall)
    to enable compatibility with Minecraft when used with waywall. The patch is applied from:
    https://raw.githubusercontent.com/tesselslate/waywall/${waywallRev}/contrib/glfw.patch
  '';

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
      # Server = https://mirror.aarnet.edu.au/pub/archlinux/$repo/os/$arch

      [extra]
      Server = https://archive.archlinux.org/repos/${date}/$repo/os/$arch
      # Server = https://mirror.aarnet.edu.au/pub/archlinux/$repo/os/$arch
    '';

  # Produces a directory of tarballs that pacman can use `-U` on to install
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
        set -e

        mkdir -p db root gpg $out

        fakeroot pacman --config ${pacmanConf} \
          --dbpath $PWD/db --root $PWD/root --gpgdir $PWD/gpg \
          --cachedir $out --logfile /dev/null \
          -Syw --noconfirm ${pkgs.lib.escapeShellArgs names}

        rm -f $out/*.part
      '';

  waywallDepends = mkPackages {
    names = [
      "base-devel"

      # waywall
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
      "git"

      # for glfw
      "cmake"
      "ninja"
      "libxrandr"
      "libxinerama"
      "libxcursor"
      "libxi"
    ];
    hash = "sha256-FYkJoWQfkZQ9cGTlHDJ3gl/0bXSBMAQQxWZDrUHUWrc=";
  };

  archImage = pkgs.vmTools.runInLinuxVM (
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

        pacman --config ${pacmanConf} --root /mnt --dbpath /mnt/var/lib/pacman \
          --noconfirm --noscriptlet -U ${waywallDepends}/*.pkg.tar.zst

        umount /mnt/dev /mnt/proc /mnt/sys
        umount /mnt
      '';
    }
  );
in
pkgs.vmTools.runInLinuxImage (
  pkgs.stdenv.mkDerivation {
    name = "waywall-glfw";

    diskImage = archImage;
    diskImageFormat = "qcow2";
    memSize = 2048;

    dontUnpack = true;

    src = pkgs.linkFarm "src" [
      {
        name = "waywall";
        path = waywallSrc;
      }
      {
        name = "glfw";
        path = glfwSrc;
      }
    ];

    buildPhase = ''
      set -e

      # dir setup
      cp -rL $src ./src
      cd ./src
      mkdir glfw/build

      # fix permissions
      useradd -m builduser
      chmod -R u+w .
      chown -R builduser:builduser .

      # build glfw
      pushd glfw
      runuser -u builduser -- cmake -S . -B build -DBUILD_SHARED_LIBS=ON -DGLFW_BUILD_WAYLAND=ON
      runuser -u builduser -- make -C build
      popd

      mkdir -p ./waywall/waywall-build/glfw
      cp ./glfw/build/src/libglfw.so* ./waywall/waywall-build/glfw/
      cp ./glfw/LICENSE.md ./glfw/CONTRIBUTORS.md ./waywall/waywall-build/glfw/
      cp ${maintainers-md} ./waywall/waywall-build/glfw/MAINTAINERS.md

      # build waywall
      pushd waywall
      runuser -u builduser -- make
      pushd contrib
      runuser -u builduser -- makepkg --nodeps --noconfirm

      # cpy to out
      mkdir -p $out
      cp ./waywall*.zst $out
    '';
  }
)
