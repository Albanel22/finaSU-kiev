#!/bin/bash
set -euo pipefail

# =============================================================================
# FinaSU (LyraVoid) en dur dans le noyau 4.19 — ÉTAPE A : FinaSU seul, hooks Tracepoint, SANS SuSFS
# Motorola One 5G Ace (kiev) — LineageOS 23.2
#
# Objectif : voir si le driver FinaSU compile et démarre sur ce noyau 4.19 (compatibilité NON démontrée).
# Réutilise : source du noyau épinglée, garde-fou clang, make -k + build-errors.txt, audits, ksud, repack.
#
# SIGNATURE DU MANAGER : le noyau vérifie l'APK du manager (taille + SHA-256 du certificat compilés).
#   1) Place l'APK du manager FinaSU dans patches/manager.apk -> le script calcule les valeurs, OU
#   2) FINASU_EXPECTED_SIZE=0x... FINASU_EXPECTED_HASH=<sha256> en variables d'environnement.
#   Sans l'un ni l'autre, le noyau garde les valeurs « placeholder » : le manager ne sera pas reconnu.
# =============================================================================

FINASU_URL="${FINASU_URL:-https://github.com/LyraVoid/FinaSU.git}"
FINASU_REF="${FINASU_REF:-v1.5.0}"
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"
FINASU_EXPECTED_SIZE="${FINASU_EXPECTED_SIZE:-}"
FINASU_EXPECTED_HASH="${FINASU_EXPECTED_HASH:-}"
VER="finasu-A"
KSU_REF="$FINASU_REF"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"

echo "=== Build FinaSU ($FINASU_REF) — étape A (Tracepoint, sans SuSFS) ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

mkdir -p "$GITHUB_WORKSPACE/output"
AUDIT="$GITHUB_WORKSPACE/output/audit-${VER}.txt"
: > "$AUDIT"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio libclang-dev patch wget openssl

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU (source épinglée) ====================
KERNEL_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
git clone --filter=blob:none --no-checkout -b lineage-23.2 "$KERNEL_URL" kernel_sources
cd kernel_sources
echo "Tête actuelle de lineage-23.2 : $(git log --oneline -1 origin/lineage-23.2)" | tee -a "$AUDIT"
if ! git checkout -q "$KERNEL_PIN" 2>/dev/null; then
    git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
    git checkout -q "$KERNEL_PIN" || { echo "❌ commit $KERNEL_PIN introuvable"; exit 1; }
fi
echo "Source figée sur : $KERNEL_PIN" | tee -a "$AUDIT"
echo "SHA complet de la source : $(git rev-parse HEAD)" | tee -a "$AUDIT"

# ==================== 2. INTÉGRATION FinaSU (setup officiel, checkout existant) ====================
echo ""
echo "=== Intégration FinaSU ($FINASU_REF) ==="
rm -rf drivers/kernelsu FinaSU 2>/dev/null || true
git clone "$FINASU_URL" FinaSU
git -C FinaSU checkout "$FINASU_REF"
{
    echo "FinaSU : $(git -C FinaSU describe --tags --always) / $(git -C FinaSU rev-parse HEAD)"
} 2>&1 | tee -a "$AUDIT"

if [ -f FinaSU/kernel/setup.sh ]; then
    bash FinaSU/kernel/setup.sh --dir "$PWD/FinaSU" || echo "⚠️ setup.sh a échoué, liaison manuelle ci-dessous"
fi
if [ ! -e drivers/kernelsu ]; then
    ln -sfn ../FinaSU/kernel drivers/kernelsu
    grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
[ -e drivers/kernelsu ] || { echo "❌ drivers/kernelsu absent"; exit 1; }
KSU_DIR="drivers/kernelsu"
KSU_REPO_ROOT="$GITHUB_WORKSPACE/kernel_sources/FinaSU"
echo "✅ FinaSU intégré ($KSU_DIR -> $(readlink drivers/kernelsu || echo '?'))"

{
    echo ""
    echo "=== DRIVER : Kconfig (symboles) ==="
    grep -n "^config \|depends on" "$KSU_DIR/Kconfig" | head -80 || true
    echo ""
    echo "=== DRIVER : tests de version du noyau ==="
    echo "KERNEL_VERSION(4 : $(grep -rn 'KERNEL_VERSION(4' "$KSU_DIR" | wc -l)   KERNEL_VERSION(5 : $(grep -rn 'KERNEL_VERSION(5' "$KSU_DIR" | wc -l)"
    grep -rn "LINUX_VERSION_CODE" "$KSU_DIR" | head -40 || true
    true
} 2>&1 | tee -a "$AUDIT"

# ==================== 3. SIGNATURE DU MANAGER (taille + SHA-256 du certificat) ====================
MGR_APK="$GITHUB_WORKSPACE/patches/manager.apk"
if [ -z "$FINASU_EXPECTED_SIZE" ] && [ -f "$MGR_APK" ]; then
    SIG_OUT=$(python3 - "$MGR_APK" <<'PYEOF' || true
import hashlib, struct, sys
data = open(sys.argv[1], 'rb').read()
e = data.rfind(b'PK\x05\x06')
if e < 0:
    sys.exit(2)
cd_off = struct.unpack_from('<I', data, e + 16)[0]
if data[cd_off - 16:cd_off] != b'APK Sig Block 42':
    sys.exit(3)
blk_size = struct.unpack_from('<Q', data, cd_off - 24)[0]
pos = cd_off - blk_size - 8 + 8
end = cd_off - 24
cert = None
while pos < end and cert is None:
    pair_len = struct.unpack_from('<Q', data, pos)[0]
    pid = struct.unpack_from('<I', data, pos + 8)[0]
    if pid in (0x7109871a, 0xf05368c0):          # schéma de signature v2 ou v3
        p = pos + 12
        p += 4                                   # longueur de la séquence des signataires
        p += 4                                   # longueur du premier signataire
        p += 4                                   # longueur des données signées
        dg_len = struct.unpack_from('<I', data, p)[0]
        p += 4 + dg_len                          # on saute les digests
        p += 4                                   # longueur de la séquence de certificats
        c_len = struct.unpack_from('<I', data, p)[0]
        p += 4
        cert = data[p:p + c_len]
    pos += 8 + pair_len
if cert is None:
    sys.exit(4)
print("0x%x" % len(cert))
print(hashlib.sha256(cert).hexdigest())
PYEOF
)
    if [ -n "$SIG_OUT" ]; then
        FINASU_EXPECTED_SIZE=$(echo "$SIG_OUT" | sed -n '1p')
        FINASU_EXPECTED_HASH=$(echo "$SIG_OUT" | sed -n '2p')
    else
        echo "⚠️ signature de patches/manager.apk illisible (schéma v2/v3 absent ?)" | tee -a "$AUDIT"
    fi
fi
SIG_ARGS=""
if [ -n "$FINASU_EXPECTED_SIZE" ] && [ -n "$FINASU_EXPECTED_HASH" ]; then
    SIG_ARGS="KSU_EXPECTED_SIZE=$FINASU_EXPECTED_SIZE KSU_EXPECTED_HASH=$FINASU_EXPECTED_HASH"
    echo "Signature du manager : taille $FINASU_EXPECTED_SIZE, sha256 $FINASU_EXPECTED_HASH" | tee -a "$AUDIT"
else
    echo "⚠️ AUCUNE signature de manager fournie : valeurs par défaut du noyau (manager non reconnu)" | tee -a "$AUDIT"
fi

# ==================== 4. COMPATIBILITÉ NOYAU (comme pour KernelSU-Next) ====================
# ==================== 3g. STATIC EXPORTS SELINUX ====================
echo "=== Static exports SELinux ==="
[ -f "security/selinux/selinuxfs.c" ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f "security/selinux/ss/status.c" ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f "security/selinux/ss/services.c" ] && {
    sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
}
[ -f "security/selinux/hooks.c" ] && {
    sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
}

# ==================== 4b. FIX MODULE_IMPORT_NS POUR 4.19 ====================
echo ""
echo "=== Fix MODULE_IMPORT_NS (noyaux < 5.0) ==="
python3 - <<'PYEOF'
import re, os

files = [
    'drivers/kernelsu/core/init.c',
    'drivers/kernelsu/ksu.c',
    'drivers/kernelsu/ksu_main.c',
]
for path in files:
    if not os.path.exists(path):
        continue
    with open(path) as f:
        c = f.read()
    if 'MODULE_IMPORT_NS' not in c:
        continue
    if 'LINUX_VERSION_CODE >= KERNEL_VERSION(5,0,0)' in c and 'MODULE_IMPORT_NS' in c:
        # déjà patché
        continue
    # Enveloppe chaque MODULE_IMPORT_NS dans #if LINUX_VERSION_CODE
    c = re.sub(
        r'^(\s*)(MODULE_IMPORT_NS\([^)]*\);)',
        r'\1#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,0,0)\n\1\2\n\1#endif',
        c, flags=re.M
    )
    with open(path, 'w') as f:
        f.write(c)
    print(f"  ✅ {path} : MODULE_IMPORT_NS protégé")
PYEOF

# ==================== 3h. FIX O_CLOEXEC ====================
echo ""
echo "=== Fix O_CLOEXEC dans TOUS les fichiers (détection Manager) ==="

FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_GET_UNUSED" ]; then
    for f in $FILES_GET_UNUSED; do
        sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
        echo "  ✅ get_unused_fd_flags fixé dans $f"
    done
fi

FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_ANON_INODE" ]; then
    for f in $FILES_ANON_INODE; do
        sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/O_RDWR|O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/, O_CLOEXEC)/)/g' "$f"
        echo "  ✅ anon_inode_getfile nettoyé dans $f"
    done
fi


# ==================== 5. CONFIGURATION ====================
echo ""
echo "=== Configuration (FinaSU, hooks Tracepoint, sans SuSFS) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# --- Compatibilité clang : le noyau peut passer des -Wno-... inconnus d'un clang ancien
CLANG_MAJOR=$(clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)
echo "clang : $(command -v clang) -> $(readlink -f "$(command -v clang)")" | tee -a "$AUDIT"
clang --version | head -2 | tee -a "$AUDIT"
echo "clang version majeure : ${CLANG_MAJOR:-inconnue}" | tee -a "$AUDIT"
CC_ARGS=""
if [ "${FORCE_CLANG_WRAP:-1}" = "1" ] || [ "${CLANG_MAJOR:-99}" -lt 16 ]; then
    cat > "$GITHUB_WORKSPACE/clang-wrap" <<'WRAPEOF'
#!/bin/bash
args=()
for a in "$@"; do
    case "$a" in
        -Wno-cast-function-type-strict|-Wcast-function-type-strict) ;;
        *) args+=("$a") ;;
    esac
done
exec clang -Wno-unknown-warning-option "${args[@]}" -Wno-unknown-warning-option
WRAPEOF
    chmod +x "$GITHUB_WORKSPACE/clang-wrap"
    CC_ARGS="CC=$GITHUB_WORKSPACE/clang-wrap"
    echo "⚠️ clang < 16 : wrapper actif (flags inconnus ignorés)" | tee -a "$AUDIT"
fi


mkdir -p out
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_HOOK_TRACEPOINT=y"
  echo "# CONFIG_KSU_HOOK_SUSFS_INLINE is not set"
  echo "# CONFIG_KSU_SUSFS is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_KALLSYMS=y"
  echo "CONFIG_KALLSYMS_ALL=y"
  echo "CONFIG_EXT4_FS=y"
  echo "CONFIG_HEADERS_INSTALL=y"
  echo "CONFIG_THREAD_INFO_IN_TASK=y"
  echo "CONFIG_FTRACE=y"
  echo "CONFIG_FTRACE_SYSCALLS=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

echo "=== État final .config ==="
{
    for o in KSU KSU_HOOK_TRACEPOINT KSU_HOOK_SUSFS_INLINE KPROBES KALLSYMS_ALL EXT4_FS HEADERS_INSTALL THREAD_INFO_IN_TASK FTRACE_SYSCALLS HAVE_SYSCALL_TRACEPOINTS; do
        if grep -q "^CONFIG_${o}=y" out/.config; then echo "  ✅ CONFIG_${o}"; else echo "  ℹ️ CONFIG_${o} absent ou inactif"; fi
    done
    true
} 2>&1 | tee -a "$AUDIT"

if ! grep -q "^CONFIG_KSU=y" out/.config; then
    echo "❌ CONFIG_KSU non activé (dépendances du Kconfig non satisfaites ?), abandon" | tee -a "$AUDIT"
    grep -n "KSU" out/.config | head -20 || true
    exit 1
fi

# ==================== 6. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 7. COMPILATION KERNEL (make -k : toutes les erreurs d'un coup) ====================
echo "=== Compilation du kernel ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" $SIG_ARGS \
  -k -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    grep -iE "error:|undefined symbol|undefined reference|fatal error:" build.log | head -30 || true
    {
        echo "=== ERREURS (rc=$MAKE_RC) ==="
        grep -nE "error:|undefined symbol|undefined reference|fatal error:|\*\*\*" build.log | head -150 || true
        echo ""
        echo "=== SYMBOLES NON DÉFINIS (édition de liens) ==="
        grep -oE "undefined (symbol|reference to)[: ]+[^ ]+" build.log | sort | uniq -c | sort -rn | head -60 || true
        echo ""
        echo "=== 150 DERNIÈRES LIGNES ==="
        tail -n 150 build.log
    } > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅ Compilation réussie"
ls -lh out/arch/arm64/boot/
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-${VER}"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-${VER}"
{
    echo ""
    echo "=== AUDIT SYMBOLES ==="
    grep -E " (ksu_handle_|ksu_init|ksu_exit|kernelsu_init)" out/System.map | head -20 || echo "⚠️ aucun symbole ksu_* dans System.map"
    true
} 2>&1 | tee -a "$AUDIT"

# ==================== 8. COMPILATION KSUD (même checkout que le driver) ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"

# Source de ksud : on privilégie le checkout déjà utilisé pour le driver
KSUD_DIR=""
KSUD_ROOT=""
if [ -n "$KSU_REPO_ROOT" ] && [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"
    KSUD_ROOT="$KSU_REPO_ROOT"
    echo "✅ ksud pris dans le MÊME checkout que le driver ($KSU_REF) : $KSUD_DIR"
else
    echo "⚠️  userspace/ksud absent du checkout $KSU_REF"
    echo "⚠️  Fallback : ksud depuis la branche '$KSUD_FALLBACK_REF' (risque de protocole différent du driver)"
    rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
    git clone --depth=1 --branch "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksud-src"
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
    KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
    echo -n "  ksud fallback commit : "; git -C "$GITHUB_WORKSPACE/ksud-src" rev-parse HEAD
    echo -n "  ksud fallback describe : "; git -C "$GITHUB_WORKSPACE/ksud-src" describe --tags --always 2>/dev/null || echo "?"
    echo "  UAPI vue par ksud :"; grep -rn "KERNEL_SU_UAPI_VERSION" "$GITHUB_WORKSPACE/ksud-src" --include=*.h --include=*.rs 2>/dev/null | head -5 || true
fi

if [ ! -f "$KSUD_DIR/Cargo.toml" ]; then
    echo "❌ Cargo.toml de ksud introuvable dans $KSUD_DIR"; exit 1
fi

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"; export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

cd "$KSUD_DIR"
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android

KSUD_BINARY=$(find "$KSUD_ROOT" -type f -path "*aarch64-linux-android/release/ksud" 2>/dev/null | head -1 || true)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé ($KSUD_BINARY)"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK (MÉTHODE BACKSLASHXX) ====================
echo ""
echo "=== Repack (méthode backslashxx : magiskboot cpio add) ==="

rm -f ./boot-stock.img 2>/dev/null || true
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then
    echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"
fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi
rm -f ./dtbo-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf ./Magisk-v27.0.apk ./lib 2>/dev/null || true

cd repack
set +e
./magiskboot unpack boot.img
set -e

cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary
chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary 2>/dev/null || true

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10. DIAGNOSTIC ====================
echo ""
echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE"
fi

if [ -f "ramdisk.cpio" ]; then
    if ../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null; then
        echo "  ✅ ksud présent dans /data/adb/ksud/"
    else
        echo "  ❌ ksud absent"
    fi
fi
cd ..

# ==================== 11. SORTIE ====================
cp final_boot.img "output/FinaSU-A-${VER}-boot.img"
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ ${VER} (FinaSU $KSU_REF, Tracepoint, sans SuSFS) ==="
ls -lh output/

