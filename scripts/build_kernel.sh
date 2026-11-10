#!/bin/bash
set -euo pipefail

# =============================================================================
# FinaSU (LyraVoid) en dur dans le noyau 4.19 — ÉTAPE A : FinaSU seul, hooks Manual
# Motorola One 5G Ace (kiev) — LineageOS 23.2
#
# Stratégie : Modification du Makefile pour exclure les modules intrinsèquement 
# incompatibles 4.19 (SELinux Hide, Seccomp Cache, Supercall) + Patchs API ciblés.
# =============================================================================

FINASU_URL="${FINASU_URL:-https://github.com/LyraVoid/FinaSU.git}"
FINASU_REF="${FINASU_REF:-v1.5.0}"
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"
FINASU_EXPECTED_SIZE="${FINASU_EXPECTED_SIZE:-}"
FINASU_EXPECTED_HASH="${FINASU_EXPECTED_HASH:-}"
VER="finasu-A"
KSU_REF="$FINASU_REF"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"

echo "=== Build FinaSU ($FINASU_REF) — Compatibilité 4.19 officielle ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

mkdir -p "$GITHUB_WORKSPACE/output"
AUDIT="$GITHUB_WORKSPACE/output/audit-${VER}.txt"
: > "$AUDIT"

# ---------- Résumé du build ----------
summarize() {
    local rc=$?
    set +e
    local BL="$GITHUB_WORKSPACE/kernel_sources/build.log"
    local SUM="$GITHUB_WORKSPACE/output/build-summary.txt"
    {
        echo "=== RÉSUMÉ DU BUILD (code de sortie $rc) ==="
        if [ -f "$BL" ]; then
            python3 - "$BL" <<'SUMEOF'
import re, sys
from collections import Counter, OrderedDict
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
err = re.compile(r'^(?:\.\./)*(\S+?):(\d+):(\d+): (?:fatal )?error: (.*)$')
per_file, per_msg, first_msg, first_loc = Counter(), Counter(), OrderedDict(), {}
undefined, targets, total = Counter(), [], 0
for l in txt:
    m = err.match(l.strip())
    if m:
        f, ln, col, msg = m.groups()
        total += 1
        per_file[f] += 1
        key = re.sub(r"\s*\[-W[^\]]*\]", "", msg)[:110]
        per_msg[key] += 1
        first_loc.setdefault(key, f"{f}:{ln}")
        first_msg.setdefault(f, f"{ln}: {key}")
        continue
    u = re.search(r'undefined (?:symbol|reference to)[: ]+[`]?([^\s\'`]+)', l)
    if u:
        undefined[u.group(1)] += 1
    t = re.search(r'\*\*\* \[[^\]]*?:(\d+): ([^\]]+)\] Error', l)
    if t and t.group(2) not in targets:
        targets.append(t.group(2))
print(f"erreurs : {total}   fichiers touchés : {len(per_file)}   messages distincts : {len(per_msg)}")
print("\n-- Erreurs par fichier (haut de liste) --")
for f, n in per_file.most_common(25):
    print(f"{n:4d}  {f}")
print("\n-- Types d'erreurs (compte, premier emplacement) --")
for k, n in per_msg.most_common(25):
    print(f"{n:4d}  {k}   [{first_loc[k]}]")
if undefined:
    print("\n-- Symboles non définis (édition de liens) --")
    for k, n in undefined.most_common(30):
        print(f"{n:4d}  {k}")
if targets:
    print("\n-- Cibles make en échec --")
    for t in targets[:20]:
        print("   " + t)
SUMEOF
        else
            echo "pas de build.log : le script s'est arrêté AVANT la compilation du noyau"
        fi
        echo ""
        echo "=== 20 DERNIÈRES LIGNES DE L'AUDIT ==="
        tail -n 20 "$AUDIT" 2>/dev/null
    } > "$SUM" 2>&1
    cat "$SUM"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        { echo '```'; cat "$SUM"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
    fi
    [ -f "$BL" ] && gzip -c "$BL" > "$GITHUB_WORKSPACE/output/build.log.gz"
    return $rc
}
trap summarize EXIT

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio libclang-dev patch wget openssl

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
KERNEL_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
git clone --filter=blob:none --no-checkout -b lineage-23.2 "$KERNEL_URL" kernel_sources
cd kernel_sources
echo "Tête actuelle de lineage-23.2 : $(git log --oneline -1 origin/lineage-23.2)" | tee -a "$AUDIT"
if ! git checkout -q "$KERNEL_PIN" 2>/dev/null; then
    git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
    git checkout -q "$KERNEL_PIN" || { echo "❌ commit $KERNEL_PIN introuvable"; exit 1; }
fi
echo "Source figée sur : $KERNEL_PIN" | tee -a "$AUDIT"

# ==================== 2. INTÉGRATION FinaSU ====================
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

# ==================== 3. SIGNATURE DU MANAGER ====================
MGR_APK="$GITHUB_WORKSPACE/patches/manager.apk"
if [ -z "$FINASU_EXPECTED_SIZE" ] && [ -f "$MGR_APK" ]; then
    SIG_OUT=$(python3 - "$MGR_APK" <<'PYEOF' || true
import hashlib, struct, sys
data = open(sys.argv[1], 'rb').read()
e = data.rfind(b'PK\x05\x06')
if e < 0: sys.exit(2)
cd_off = struct.unpack_from('<I', data, e + 16)[0]
if data[cd_off - 16:cd_off] != b'APK Sig Block 42': sys.exit(3)
blk_size = struct.unpack_from('<Q', data, cd_off - 24)[0]
pos = cd_off - blk_size
end = cd_off - 24
cert = None
while pos < end and cert is None:
    pair_len = struct.unpack_from('<Q', data, pos)[0]
    pid = struct.unpack_from('<I', data, pos + 8)[0]
    if pid in (0x7109871a, 0xf05368c0):
        p = pos + 12
        p += 4; p += 4; p += 4
        dg_len = struct.unpack_from('<I', data, p)[0]
        p += 4 + dg_len; p += 4
        c_len = struct.unpack_from('<I', data, p)[0]
        p += 4
        cert = data[p:p + c_len]
    pos += 8 + pair_len
if cert is None: sys.exit(4)
print("0x%x" % len(cert))
print(hashlib.sha256(cert).hexdigest())
PYEOF
)
    if [ -n "$SIG_OUT" ]; then
        FINASU_EXPECTED_SIZE=$(echo "$SIG_OUT" | sed -n '1p')
        FINASU_EXPECTED_HASH=$(echo "$SIG_OUT" | sed -n '2p')
    fi
fi
SIG_ARGS=""
if [ -n "$FINASU_EXPECTED_SIZE" ] && [ -n "$FINASU_EXPECTED_HASH" ]; then
    SIG_ARGS="KSU_EXPECTED_SIZE=$FINASU_EXPECTED_SIZE KSU_EXPECTED_HASH=$FINASU_EXPECTED_HASH"
    echo "Signature du manager : taille $FINASU_EXPECTED_SIZE, sha256 $FINASU_EXPECTED_HASH" | tee -a "$AUDIT"
else
    echo "⚠️ AUCUNE signature de manager fournie" | tee -a "$AUDIT"
fi

# ==================== 4. PATCHS DE COMPATIBILITÉ 4.19 CIBLÉS ====================
echo ""
echo "=== Patchs de compatibilité 4.19 ciblés ==="

# 1. Patch Makefile pour désactiver les modules intrinsèquement incompatibles 4.19
MAKEFILE="$KSU_DIR/Makefile"
if [ -f "$MAKEFILE" ]; then
    sed -i 's/obj-y += feature\/selinux_hide.o/obj-n += feature\/selinux_hide.o/' "$MAKEFILE"
    sed -i 's/obj-\$(CONFIG_KSU) += feature\/selinux_hide.o/obj-n += feature\/selinux_hide.o/' "$MAKEFILE"
    sed -i 's/obj-y += infra\/seccomp_cache.o/obj-n += infra\/seccomp_cache.o/' "$MAKEFILE"
    sed -i 's/obj-\$(CONFIG_KSU) += infra\/seccomp_cache.o/obj-n += infra\/seccomp_cache.o/' "$MAKEFILE"
    sed -i 's/obj-y += supercall\//obj-n += supercall\//' "$MAKEFILE"
    sed -i 's/obj-\$(CONFIG_KSU) += supercall\//obj-n += supercall\//' "$MAKEFILE"
    echo "✅ Makefile patché pour désactiver selinux_hide, seccomp_cache, supercall"
fi

python3 - "$KSU_DIR" <<'PORTEOF' 2>&1 | tee -a "$AUDIT"
import os, re, sys

root = sys.argv[1]
total_files = 0

def patch_file(filepath):
    global total_files
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    original = content

    # 1. TWA_RESUME et TWA_NONE -> 0 (Sûr et universel pour 4.19)
    if 'TWA_RESUME' in content or 'TWA_NONE' in content:
        content = content.replace('TWA_RESUME', '0')
        content = content.replace('TWA_NONE', '0')

    # 2. fsnotify_ops : handle_inode_event (5.9+) -> handle_event (4.19)
    if 'ksu_handle_inode_event' in content and 'handle_inode_event = ksu_handle_inode_event' in content:
        func_old = '''static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir,
                                  const struct qstr *file_name, u32 cookie)
{
    if (!file_name)
        return 0;
    if (mask & FS_ISDIR)
        return 0;
    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        ksu_defer_track_throne();
    }
    return 0;
}'''
        func_new = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir,
                                  const struct qstr *file_name, u32 cookie)
{
    if (!file_name) return 0;
    if (mask & FS_ISDIR) return 0;
    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        ksu_defer_track_throne();
    }
    return 0;
}
#else
static int ksu_handle_event(struct fsnotify_group *group, struct inode *inode,
                            struct fsnotify_mark *inode_mark, struct fsnotify_mark *vfsmount_mark,
                            u32 mask, void *data, int data_type, const unsigned char *file_name, u32 cookie)
{
    if (!file_name) return 0;
    if (mask & FS_ISDIR) return 0;
    size_t len = strlen((const char *)file_name);
    if (len == 13 && !memcmp(file_name, "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        ksu_defer_track_throne();
    }
    return 0;
}
#endif'''
        content = content.replace(func_old, func_new)
        
        struct_old = '''static const struct fsnotify_ops ksu_ops = {
    .handle_inode_event = ksu_handle_inode_event,
};'''
        struct_new = '''static const struct fsnotify_ops ksu_ops = {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    .handle_inode_event = ksu_handle_inode_event,
#else
    .handle_event = ksu_handle_event,
#endif
};'''
        content = content.replace(struct_old, struct_new)

    # 3. file_wrapper.c : iopoll et remap_file_range
    if 'file_wrapper.c' in filepath:
        content = re.sub(
            r'(\s+)p->ops\.iopoll = fp->f_op->iopoll \? ksu_wrapper_iopoll : NULL;',
            r'\1#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n\1p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n\1#endif',
            content
        )
        content = re.sub(
            r'(\s+)p->ops\.remap_file_range = fp->f_op->remap_file_range \? ksu_wrapper_remap_file_range : NULL;',
            r'\1#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n\1p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n\1#endif',
            content
        )
        content = content.replace('REMAP_FILE_DEDUP', '0 /* REMAP_FILE_DEDUP not in 4.19 */')

    # 4. sepolicy.c : Stubber filename_trans pour < 5.8
    if 'sepolicy.c' in filepath and 'add_filename_trans' in content and 'KSU_FILENAME_TRANS_STUB' not in content:
        content = re.sub(
            r'(static bool add_filename_trans\(struct policydb \*db, const char \*s, const char \*t, const char \*c, const char \*d,\s*const char \*o\)\s*\{.*?^\})',
            r'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)\n\1\n#else\nstatic bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d, const char *o) {\n    pr_info("add_filename_trans ignored on kernel < 5.8\\n");\n    return true;\n}\n#endif',
            content,
            flags=re.DOTALL | re.MULTILINE
        )

    # 5. Headers manquants pour task_struct, etc.
    if 'put_task_struct' in content or 'tasklist_lock' in content or 'init_task' in content:
        if '#include <linux/sched/task.h>' not in content:
            content = '#include <linux/sched/task.h>\n' + content
        if '#include <linux/sched/signal.h>' not in content:
            content = '#include <linux/sched/signal.h>\n' + content

    # 6. uapi/linux/mount.h -> linux/mount.h
    content = content.replace('#include <uapi/linux/mount.h>', '#include <linux/mount.h>')

    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        total_files += 1
        return True
    return False

for dp, dn, fn in os.walk(root):
    for f in fn:
        if f.endswith('.c'):
            filepath = os.path.join(dp, f)
            if patch_file(filepath):
                print(f"  ✅ Patché compatibilité dans {f}")

print(f"✅ Portage 4.19 terminé : {total_files} fichier(s) corrigé(s) proprement.")
PORTEOF

# ==================== 5. FIX O_CLOEXEC ====================
echo ""
echo "=== Fix O_CLOEXEC ==="
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

# ==================== 6. CONFIGURATION ====================
echo ""
echo "=== Configuration (FinaSU, compatible 4.19) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "# CONFIG_KSU_HOOK_TRACEPOINT is not set"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  
  echo "# CONFIG_KSU_SELINUX_HIDE is not set"
  echo "# CONFIG_KSU_SECCOMP_CACHE is not set"
  echo "# CONFIG_KSU_SUPERCALL is not set"
  
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_KALLSYMS=y"
  echo "CONFIG_KALLSYMS_ALL=y"
  echo "CONFIG_EXT4_FS=y"
  echo "CONFIG_THREAD_INFO_IN_TASK=y"
  echo "CONFIG_FTRACE=y"
  echo "CONFIG_FTRACE_SYSCALLS=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

# Forçage agressif des options après olddefconfig
sed -i 's/^# CONFIG_KSU_MANUAL_HOOK is not set$/CONFIG_KSU_MANUAL_HOOK=y/' out/.config

echo "=== État final .config ==="
{
    for o in KSU KSU_MANUAL_HOOK KPROBES KALLSYMS_ALL EXT4_FS THREAD_INFO_IN_TASK FTRACE_SYSCALLS; do
        if grep -q "^CONFIG_${o}=y" out/.config; then echo "  ✅ CONFIG_${o}"; else echo "  ℹ️ CONFIG_${o} absent ou inactif"; fi
    done
    true
} 2>&1 | tee -a "$AUDIT"

if ! grep -q "^CONFIG_KSU=y" out/.config; then
    echo "❌ CONFIG_KSU non activé" | tee -a "$AUDIT"
    exit 1
fi

# ==================== 7. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 8. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
set +eo pipefail
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
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
        echo "=== SYMBOLES NON DÉFINIS ==="
        grep -oE "undefined (symbol|reference to)[: ]+[^ ]+" build.log | sort | uniq -c | sort -rn | head -60 || true
    } > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅ Compilation réussie"
ls -lh out/arch/arm64/boot/
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt

# ==================== 9. COMPILATION KSUD ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"

KSUD_DIR=""
KSUD_ROOT=""
if [ -n "$KSU_REPO_ROOT" ] && [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"
    KSUD_ROOT="$KSU_REPO_ROOT"
    echo "✅ ksud pris dans le MÊME checkout que le driver ($KSU_REF)"
else
    echo "⚠️ Fallback ksud depuis $KSUD_FALLBACK_REF"
    rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
    git clone --depth=1 --branch "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksud-src"
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
    KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
fi

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang++"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

cd "$KSUD_DIR"
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$NDK_BIN/aarch64-linux-android26-clang"
[env]
CC_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang"
CXX_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang++"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android

KSUD_BINARY=$(find "$KSUD_ROOT" -type f -path "*aarch64-linux-android/release/ksud" 2>/dev/null | head -1 || true)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"
cd "$GITHUB_WORKSPACE"

# ==================== 10. REPACK ====================
echo ""
echo "=== Repack ==="
rm -f ./boot-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi

mkdir -p repack && cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot && chmod +x repack/magiskboot
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
mv new-boot.img ../final_boot.img && cd ..

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img "output/FinaSU-A-${VER}-boot.img"
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ ${VER} (FinaSU $KSU_REF, Compatibilité 4.19 officielle) ==="
ls -lh output/
