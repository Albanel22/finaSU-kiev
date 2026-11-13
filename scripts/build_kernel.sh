#!/bin/bash
set -euo pipefail

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
export GITHUB_WORKSPACE

FINASU_URL="${FINASU_URL:-https://github.com/LyraVoid/FinaSU.git}"
FINASU_REF="${FINASU_REF:-v1.5.0}"
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"
FINASU_EXPECTED_SIZE="${FINASU_EXPECTED_SIZE:-}"
FINASU_EXPECTED_HASH="${FINASU_EXPECTED_HASH:-}"
VER="finasu-A"
KSU_REF="$FINASU_REF"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"

echo "=== Build FinaSU ($FINASU_REF) + SUSFS Inline — noyau 4.19 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"
MGR_GDRIVE_ID="1Qr07fjThXjmIz_DAmW2GZepoWrNIikXR"

mkdir -p "$GITHUB_WORKSPACE/output"
AUDIT="$GITHUB_WORKSPACE/output/audit-${VER}.txt"
: > "$AUDIT"

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
from collections import Counter
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
err = re.compile(r'^(?:\.\./)*(\S+?):(\d+):(\d+): (?:fatal )?error: (.*)$')
per_file, per_msg, first_loc = Counter(), Counter(), {}
for l in txt:
    m = err.match(l.strip())
    if m:
        f, ln, col, msg = m.groups()
        per_file[f] += 1
        key = re.sub(r"\s*\[-W[^\]]*\]", "", msg)[:110]
        per_msg[key] += 1
        first_loc.setdefault(key, f"{f}:{ln}")
print(f"erreurs : {sum(per_file.values())}   fichiers : {len(per_file)}")
for f, n in per_file.most_common(25): print(f"{n:4d}  {f}")
print()
for k, n in per_msg.most_common(25): print(f"{n:4d}  {k}   [{first_loc[k]}]")
SUMEOF
        fi
    } > "$SUM" 2>&1
    cat "$SUM"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && { echo '```'; cat "$SUM"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
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

# ==================== 1. CLONAGE NOYAU ====================
git clone --filter=blob:none --no-checkout -b lineage-23.2 \
  https://github.com/LineageOS/android_kernel_motorola_sm8250.git kernel_sources
cd kernel_sources
if ! git checkout -q "$KERNEL_PIN" 2>/dev/null; then
    git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
    git checkout -q "$KERNEL_PIN" || { echo "❌ commit $KERNEL_PIN introuvable"; exit 1; }
fi
echo "Source figée : $KERNEL_PIN ($(git rev-parse HEAD))" | tee -a "$AUDIT"

# ==================== 1b. PATCH SET_MEMORY 4.19 (CRITIQUE) ====================
# Sans ce patch, ksu_patch_text() de FinaSU ne peut pas écrire dans sys_call_table
# sur 4.19 (échec -5 EIO observé dans le logcat). Il rétroporte set_memory_ro/rw
# et ARCH_HAS_SET_MEMORY pour les kernels 4.19.
echo "=== Application du patch set_memory 4.19 ===" | tee -a "$AUDIT"
SET_MEMORY_PATCH_URL="${SET_MEMORY_PATCH_URL:-https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/set_memory_to_49_and_low.patch}"
SET_MEMORY_PATCH="$GITHUB_WORKSPACE/patches/set_memory_to_49_and_low.patch"
mkdir -p "$GITHUB_WORKSPACE/patches"
curl --proto '=https' --tlsv1.2 -fsSL "$SET_MEMORY_PATCH_URL" -o "$SET_MEMORY_PATCH"
echo "Patch set_memory téléchargé : $(sha256sum "$SET_MEMORY_PATCH" | cut -d' ' -f1)" | tee -a "$AUDIT"

# Ce patch touche beaucoup d'architectures (arm, x86, s390, etc.). On l'applique avec
# --reject : les hunks qui concernent les autres arch que arm64 échoueront (fichiers
# absents) et c'est normal. On garde uniquement ce qui touche arm64 et le core mm.
set +e
git apply --reject --whitespace=nowarn "$SET_MEMORY_PATCH" 2>&1 | tee -a "$AUDIT"
SET_MEMORY_RC=${PIPESTATUS[0]}
set -e
echo "set_memory patch rc=$SET_MEMORY_RC (rejets autres-arch attendus)" | tee -a "$AUDIT"

# Vérification : sur arm64, set_memory.h doit exister et ARCH_HAS_SET_MEMORY doit être sélectionné
if [ ! -f arch/arm64/include/asm/set_memory.h ] && [ ! -f include/asm-generic/set_memory.h ]; then
    echo "❌ set_memory.h absent après patch — le patch n'a pas trouvé sa cible arm64" | tee -a "$AUDIT"
    find . -name 'set_memory*' -o -name '*.rej' | head -20 | tee -a "$AUDIT"
    exit 1
fi
if ! grep -q "ARCH_HAS_SET_MEMORY" arch/arm64/Kconfig; then
    echo "⚠️ ARCH_HAS_SET_MEMORY pas dans arch/arm64/Kconfig — injection manuelle" | tee -a "$AUDIT"
    sed -i '/^config ARM64$/a\	select ARCH_HAS_SET_MEMORY' arch/arm64/Kconfig
fi
if ! grep -q "ARCH_HAS_SET_MEMORY" arch/Kconfig; then
    echo "⚠️ config ARCH_HAS_SET_MEMORY pas dans arch/Kconfig — injection manuelle" | tee -a "$AUDIT"
    sed -i '/^config ARCH_HAS_FORTIFY_SOURCE$/i\config ARCH_HAS_SET_MEMORY\n\tbool\n' arch/Kconfig
fi

# Nettoyage des .rej (on ne garde pas de trace, tous les hunks autres-arch sont inutiles)
REJ_COUNT=$(find . -name '*.rej' | wc -l)
find . -name '*.rej' -delete
echo "✅ Patch set_memory appliqué (rejets nettoyés : $REJ_COUNT)" | tee -a "$AUDIT"

# ==================== 1c. PATCH SUSFS BASE 4.19 (JackA1ltman) ====================
echo "=== Application du patch SUSFS 4.19 ===" | tee -a "$AUDIT"
SUSFS_419_PATCH_URL="${SUSFS_419_PATCH_URL:-https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch}"
SUSFS_419_PATCH="$GITHUB_WORKSPACE/patches/susfs_patch_to_4.19.patch"
curl --proto '=https' --tlsv1.2 -fsSL "$SUSFS_419_PATCH_URL" -o "$SUSFS_419_PATCH"
echo "Patch SUSFS téléchargé : $(sha256sum "$SUSFS_419_PATCH" | cut -d' ' -f1)" | tee -a "$AUDIT"

# On applique avec --reject : les hunks du backend Tracepoint (fs/Makefile, fs/namespace.c,
# fs/proc/task_mmu.c, fs/super.c, mm/memory.c) échouent car ils ciblent des fichiers
# modifiés par set_memory ou n'existent pas dans notre arbre. On nettoie les .rej.
set +e
git apply --reject --whitespace=nowarn "$SUSFS_419_PATCH" 2>&1 | tee -a "$AUDIT"
SUSFS_RC=${PIPESTATUS[0]}
set -e
echo "SUSFS patch rc=$SUSFS_RC (rejets backend Tracepoint attendus)" | tee -a "$AUDIT"

# Vérification : les fichiers SUSFS core doivent exister
if [ ! -f fs/susfs.c ] || [ ! -f include/linux/susfs.h ]; then
    echo "❌ fs/susfs.c ou include/linux/susfs.h absent — patch SUSFS base KO" | tee -a "$AUDIT"
    find . -name '*.rej' | head -20 | tee -a "$AUDIT"
    exit 1
fi

# Vérifier que fs/Makefile a bien obj-$(CONFIG_KSU_SUSFS) += susfs.o (hunk critique)
if ! grep -q "susfs.o" fs/Makefile; then
    echo "⚠️ fs/Makefile ne contient pas susfs.o — injection manuelle" | tee -a "$AUDIT"
    sed -i '/^obj-y :=.*fs_pin\.o nsfs\.o/a\
obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || \
        sed -i '/^obj-y/a\
obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile
fi

REJ_COUNT=$(find . -name '*.rej' | wc -l)
find . -name '*.rej' -delete
echo "✅ Patch SUSFS base appliqué (rejets backend Tracepoint nettoyés : $REJ_COUNT)" | tee -a "$AUDIT"

# ==================== 1d. HOOKS INLINE (JackA1ltman) ====================
echo "=== Application des hooks Inline (JackA1ltman) ===" | tee -a "$AUDIT"
INLINE_HOOK_URL="${INLINE_HOOK_URL:-https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/susfs_inline_hook_patches.sh}"
INLINE_HOOK_SCRIPT="$GITHUB_WORKSPACE/patches/susfs_inline_hook_patches.sh"
curl --proto '=https' --tlsv1.2 -fsSL "$INLINE_HOOK_URL" -o "$INLINE_HOOK_SCRIPT"
chmod +x "$INLINE_HOOK_SCRIPT"
echo "Script Inline téléchargé : $(sha256sum "$INLINE_HOOK_SCRIPT" | cut -d' ' -f1)" | tee -a "$AUDIT"

# Le script doit être exécuté dans le répertoire racine du kernel (où il y a fs/, kernel/, etc.)
bash "$INLINE_HOOK_SCRIPT" 2>&1 | tee -a "$AUDIT"

# Vérification : les 8 fichiers critiques doivent contenir ksu_handle_*
INLINE_OK=1
for f in fs/exec.c fs/open.c fs/read_write.c fs/stat.c drivers/input/input.c kernel/reboot.c kernel/sys.c security/selinux/hooks.c; do
    if ! grep -q "ksu_handle" "$f" 2>/dev/null; then
        echo "❌ $f : aucun ksu_handle_* injecté par le script Inline" | tee -a "$AUDIT"
        INLINE_OK=0
    else
        echo "  ✅ $f : $(grep -c "ksu_handle" "$f") ksu_handle_* injecté(s)" | tee -a "$AUDIT"
    fi
done
if [ "$INLINE_OK" -ne 1 ]; then
    echo "❌ Hooks Inline incomplets — vérifiez les noms de fonctions dans FinaSU" | tee -a "$AUDIT"
    exit 1
fi

# Vérification de la signature des fonctions attendues par FinaSU (si un nom diffère,
# le build échouera plus tard avec 'implicit declaration').
echo "=== Vérification des signatures ksu_handle_* attendues par FinaSU ===" | tee -a "$AUDIT"
FINA_KSU_DIR="$GITHUB_WORKSPACE/kernel_sources/drivers/kernelsu"
# (drivers/kernelsu n'existe pas encore — il sera créé plus bas, donc on cherche dans le clone FinaSU)
for fn in ksu_handle_execveat ksu_handle_faccessat ksu_handle_sys_read ksu_handle_stat ksu_handle_vfs_fstat ksu_handle_sys_reboot ksu_handle_setresuid ksu_handle_input_handle_event; do
    if grep -rq "$fn" "$GITHUB_WORKSPACE/kernel_sources/FinaSU/kernel/" --include='*.c' --include='*.h' 2>/dev/null; then
        echo "  ✅ $fn trouvé dans FinaSU" | tee -a "$AUDIT"
    else
        echo "  ⚠️ $fn non trouvé dans le clone FinaSU — sera vérifié après setup.sh" | tee -a "$AUDIT"
    fi
done

# ==================== 2. INTÉGRATION FinaSU ====================
echo "=== Intégration FinaSU ($FINASU_REF) ==="
rm -rf drivers/kernelsu FinaSU 2>/dev/null || true
git clone "$FINASU_URL" FinaSU
git -C FinaSU checkout "$FINASU_REF"
if [ -f FinaSU/kernel/setup.sh ]; then
    bash FinaSU/kernel/setup.sh --dir "$PWD/FinaSU"
fi
if [ ! -e drivers/kernelsu ]; then
    ln -sfn ../FinaSU/kernel drivers/kernelsu
    grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
[ -e drivers/kernelsu ] || { echo "❌ drivers/kernelsu absent"; exit 1; }
KSU_DIR="drivers/kernelsu"
KSU_REPO_ROOT="$GITHUB_WORKSPACE/kernel_sources/FinaSU"
echo "✅ FinaSU intégré"

# ==================== 2b. SONDE ====================
{
    echo ""
    echo "=== SONDE 1 : options Kconfig de FinaSU ==="
    found_kconf=0
    while IFS= read -r kf; do
        [ -n "$kf" ] || continue
        found_kconf=1
        echo "--- $kf"
        grep -E "^config[[:space:]]+KSU" "$kf" 2>/dev/null || echo "  (aucun config KSU_*)"
    done < <(find -L drivers/kernelsu -name "Kconfig*" -type f 2>/dev/null)
    [ "$found_kconf" -eq 0 ] && echo "  Aucun Kconfig* trouvé dans drivers/kernelsu"

    echo ""
    echo "=== SONDE 2 : fonctions ksu_handle_* présentes dans le driver ==="
    for fn in ksu_handle_execveat ksu_handle_faccessat ksu_handle_sys_read ksu_handle_stat ksu_handle_vfs_fstat ksu_handle_sys_reboot ksu_handle_setresuid ksu_handle_input_handle_event; do
        if grep -rq "$fn" drivers/kernelsu/ --include='*.c' --include='*.h' 2>/dev/null; then
            echo "  ✅ $fn"
        else
            echo "  ❌ $fn ABSENT"
        fi
    done
} 2>&1 | tee -a "$AUDIT"

# ==================== 3. SIGNATURE MANAGER ====================
MGR_APK="$GITHUB_WORKSPACE/patches/manager.apk"
if [ ! -f "$MGR_APK" ]; then
    mkdir -p "$GITHUB_WORKSPACE/patches"
    gdown "https://drive.google.com/uc?id=${MGR_GDRIVE_ID}" -O "$MGR_APK" 2>&1 || echo "  ⚠️ Échec download"
fi
if [ -z "$FINASU_EXPECTED_SIZE" ] && [ -f "$MGR_APK" ]; then
    SIG_OUT=$(python3 - "$MGR_APK" <<'PYEOF' || true
import hashlib, struct, sys
data = open(sys.argv[1], 'rb').read()
e = data.rfind(b'PK\x05\x06')
if e < 0: sys.exit(2)
cd_off = struct.unpack_from('<I', data, e + 16)[0]
if data[cd_off - 16:cd_off] != b'APK Sig Block 42': sys.exit(3)
blk_size = struct.unpack_from('<Q', data, cd_off - 24)[0]
pos = cd_off - blk_size - 8 + 8
end = cd_off - 24
cert = None
while pos < end and cert is None:
    pair_len = struct.unpack_from('<Q', data, pos)[0]
    pid = struct.unpack_from('<I', data, pos + 8)[0]
    if pid in (0x7109871a, 0xf05368c0):
        p = pos + 12 + 4 + 4 + 4
        dg_len = struct.unpack_from('<I', data, p)[0]
        p += 4 + dg_len + 4
        c_len = struct.unpack_from('<I', data, p)[0]
        p += 4
        cert = data[p:p + c_len]
    pos += 8 + pair_len
if cert is None: sys.exit(4)
print("0x%x" % len(cert))
print(hashlib.sha256(cert).hexdigest())
PYEOF
)
    [ -n "$SIG_OUT" ] && FINASU_EXPECTED_SIZE=$(echo "$SIG_OUT" | sed -n '1p') && FINASU_EXPECTED_HASH=$(echo "$SIG_OUT" | sed -n '2p')
fi
SIG_ARGS=""
if [ -n "$FINASU_EXPECTED_SIZE" ] && [ -n "$FINASU_EXPECTED_HASH" ]; then
    SIG_ARGS="KSU_EXPECTED_SIZE=$FINASU_EXPECTED_SIZE KSU_EXPECTED_HASH=$FINASU_EXPECTED_HASH"
    echo "✅ Signature manager OK ($FINASU_EXPECTED_SIZE)"
else
    echo "⚠️ AUCUNE signature de manager fournie"
fi

# ==================== 3g/3h. EXPORTS + O_CLOEXEC ====================
[ -f "security/selinux/selinuxfs.c" ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f "security/selinux/ss/status.c" ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f "security/selinux/ss/services.c" ] && sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
[ -f "security/selinux/hooks.c" ] && sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c

grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null | while read -r f; do
    sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
done || true
grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null | while read -r f; do
    sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g; s/O_RDWR|O_CLOEXEC/O_RDWR/g; s/, O_CLOEXEC)/)/g' "$f"
done || true

# ==================== 4a. rules.c dual-path ====================
echo "=== Réécriture rules.c dual-path ==="
cat > "$KSU_DIR/selinux/rules.c" << 'RULESEOF'
#include "linux/rcupdate.h"
#include "security.h"
#include <linux/uaccess.h>
#include <linux/types.h>
#include <linux/version.h>
#include <linux/lockdep.h>
#include <linux/slab.h>
#include <linux/string.h>

#include "uapi/selinux.h"
#include "klog.h"
#include "selinux.h"
#include "sepolicy.h"
#include "ss/services.h"
#include "ss/policydb.h"
#include "linux/lsm_audit.h"
#include "xfrm.h"

#define ALL NULL
#define KSU_SEPOLICY_MAX_BATCH_SIZE (8U * 1024U * 1024U)
#define KSU_SEPOLICY_MAX_ARGS 5

struct sepol_data { u32 cmd; u32 subcmd; };
struct sepol_batch_cursor { const u8 *cur; const u8 *end; };

static size_t sepol_remaining(const struct sepol_batch_cursor *cursor)
{ return (size_t)(cursor->end - cursor->cur); }

static int sepol_read_cmd_header(struct sepol_batch_cursor *cursor, struct sepol_data *header)
{
    if (sepol_remaining(cursor) < sizeof(*header)) return -EINVAL;
    memcpy(header, cursor->cur, sizeof(*header));
    cursor->cur += sizeof(*header);
    return 0;
}

static int sepol_read_string(struct sepol_batch_cursor *cursor, const char **out)
{
    u32 len; const char *str;
    if (sepol_remaining(cursor) < sizeof(len)) return -EINVAL;
    memcpy(&len, cursor->cur, sizeof(len));
    cursor->cur += sizeof(len);
    if (len >= sepol_remaining(cursor)) return -EINVAL;
    str = (const char *)cursor->cur;
    if (memchr(str, '\0', len) != NULL || str[len] != '\0') return -EINVAL;
    cursor->cur += len + 1;
    if (len == 0) { *out = ALL; return 0; }
    *out = str;
    return 0;
}

static int sepol_require_not_all(const char *value, const char *name)
{
    if (value != ALL) return 0;
    pr_err("sepol: %s cannot be ALL.\n", name);
    return -EINVAL;
}

static int sepol_expected_argc(u32 cmd)
{
    switch (cmd) {
    case KSU_SEPOLICY_CMD_NORMAL_PERM: return 4;
    case KSU_SEPOLICY_CMD_XPERM: return 5;
    case KSU_SEPOLICY_CMD_TYPE_STATE: return 1;
    case KSU_SEPOLICY_CMD_TYPE:
    case KSU_SEPOLICY_CMD_TYPE_ATTR: return 2;
    case KSU_SEPOLICY_CMD_ATTR: return 1;
    case KSU_SEPOLICY_CMD_TYPE_TRANSITION: return 5;
    case KSU_SEPOLICY_CMD_TYPE_CHANGE: return 4;
    case KSU_SEPOLICY_CMD_GENFSCON: return 3;
    default: return -EINVAL;
    }
}

static int apply_one_sepolicy_cmd(struct policydb *db, const struct sepol_data *header, const char **args)
{
    bool success = false;
    int ret;
    switch (header->cmd) {
    case KSU_SEPOLICY_CMD_NORMAL_PERM:
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW) success = ksu_allow(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DENY) success = ksu_deny(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_AUDITALLOW) success = ksu_auditallow(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DONTAUDIT) success = ksu_dontaudit(db, args[0], args[1], args[2], args[3]);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_XPERM:
        ret = sepol_require_not_all(args[3], "operation"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[4], "perm_set"); if (ret < 0) return ret;
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_ALLOW) success = ksu_allowxperm(db, args[0], args[1], args[2], args[4]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_AUDITALLOW) success = ksu_auditallowxperm(db, args[0], args[1], args[2], args[4]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_DONTAUDIT) success = ksu_dontauditxperm(db, args[0], args[1], args[2], args[4]);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE_STATE:
        ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_PERMISSIVE) success = ksu_permissive(db, args[0]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_ENFORCE) success = ksu_enforce(db, args[0]);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE:
    case KSU_SEPOLICY_CMD_TYPE_ATTR:
        ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "attribute"); if (ret < 0) return ret;
        success = (header->cmd == KSU_SEPOLICY_CMD_TYPE) ? ksu_type(db, args[0], args[1]) : ksu_typeattribute(db, args[0], args[1]);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_ATTR:
        ret = sepol_require_not_all(args[0], "attribute"); if (ret < 0) return ret;
        return ksu_attribute(db, args[0]) ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE_TRANSITION: {
        const char *object = ALL;
        ret = sepol_require_not_all(args[0], "src"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "tgt"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[2], "cls"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[3], "default_type"); if (ret < 0) return ret;
        object = args[4];
        success = ksu_type_transition(db, args[0], args[1], args[2], args[3], object);
        return success ? 0 : -EINVAL;
    }
    case KSU_SEPOLICY_CMD_TYPE_CHANGE:
        ret = sepol_require_not_all(args[0], "src"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "tgt"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[2], "cls"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[3], "default_type"); if (ret < 0) return ret;
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_CHANGE) success = ksu_type_change(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_MEMBER) success = ksu_type_member(db, args[0], args[1], args[2], args[3]);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_GENFSCON:
        ret = sepol_require_not_all(args[0], "name"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "path"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[2], "context"); if (ret < 0) return ret;
        return ksu_genfscon(db, args[0], args[1], args[2]) ? 0 : -EINVAL;
    default:
        return -EINVAL;
    }
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
struct selinux_avc;
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
static void reset_avc_cache_419(void)
{
    struct selinux_avc *avc = selinux_state.avc;
    if (avc) avc_ss_reset(avc, 0);
    selnl_notify_policyload(0);
    selinux_xfrm_notify_policyload();
}
void apply_kernelsu_rules(void)
{
    if (!getenforce()) pr_info("SELinux permissive or disabled, apply rules! (old kernel path)\n");
    write_lock(&selinux_state.ss->policy_rwlock);
    ksu_type(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, "domain");
    ksu_permissive(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN);
    ksu_typeattribute(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, "mlstrustedsubject");
    ksu_typeattribute(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, "netdomain");
    ksu_typeattribute(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, "bluetoothdomain");
    ksu_type(&selinux_state.ss->policydb, KERNEL_SU_FILE, "file_type");
    ksu_typeattribute(&selinux_state.ss->policydb, KERNEL_SU_FILE, "mlstrustedobject");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_FILE, ALL, ALL);
    ksu_allow(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, ALL, ALL, ALL);
    if (selinux_state.ss->policydb.policyvers >= POLICYDB_VERSION_XPERMS_IOCTL) {
        ksu_allowxperm(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, ALL, "blk_file", ALL);
        ksu_allowxperm(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, ALL, "fifo_file", ALL);
        ksu_allowxperm(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, ALL, "chr_file", ALL);
        ksu_allowxperm(&selinux_state.ss->policydb, KERNEL_SU_DOMAIN, ALL, "file", ALL);
    }
    ksu_allow(&selinux_state.ss->policydb, "init", KERNEL_SU_DOMAIN, ALL, ALL);
    ksu_allow(&selinux_state.ss->policydb, "servicemanager", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(&selinux_state.ss->policydb, "servicemanager", KERNEL_SU_DOMAIN, "dir", "read");
    ksu_allow(&selinux_state.ss->policydb, "servicemanager", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(&selinux_state.ss->policydb, "servicemanager", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(&selinux_state.ss->policydb, "servicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "process", "sigchld");
    ksu_allow(&selinux_state.ss->policydb, "logd", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(&selinux_state.ss->policydb, "logd", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(&selinux_state.ss->policydb, "logd", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(&selinux_state.ss->policydb, "logd", KERNEL_SU_DOMAIN, "file", "getattr");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "fd", "use");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "fifo_file", "write");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "fifo_file", "read");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "fifo_file", "open");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "fifo_file", "getattr");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "read");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "write");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "connectto");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getopt");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getattr");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "memfd_file", "execute");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "memfd_file", "getattr");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "memfd_file", "map");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "memfd_file", "read");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "memfd_file", "write");
    ksu_allow(&selinux_state.ss->policydb, "hwservicemanager", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(&selinux_state.ss->policydb, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(&selinux_state.ss->policydb, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(&selinux_state.ss->policydb, "hwservicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
    ksu_allow(&selinux_state.ss->policydb, "domain", KERNEL_SU_DOMAIN, "binder", ALL);
    ksu_allow(&selinux_state.ss->policydb, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
    ksu_allow(&selinux_state.ss->policydb, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");
#ifdef CONFIG_KSU_SUSFS
    ksu_allow(&selinux_state.ss->policydb, "zygote", "labeledfs", "filesystem", "unmount");
#endif
    write_unlock(&selinux_state.ss->policy_rwlock);
    reset_avc_cache_419();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    pr_info("KernelSU rules applied (4.19 compatibility path)\n");
}
int handle_sepolicy(void __user *user_data, u64 data_len)
{
    struct sepol_batch_cursor cursor;
    u8 *payload;
    int ret, success_cmd_count;
    u32 cmd_index;
    if (!user_data || !data_len) return -EINVAL;
    if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) return -E2BIG;
    payload = kvmalloc((size_t)data_len, GFP_KERNEL);
    if (!payload) return -ENOMEM;
    if (copy_from_user(payload, user_data, (size_t)data_len)) { ret = -EFAULT; goto out_free; }
    if (!getenforce()) pr_info("SELinux permissive or disabled when handle policy!\n");
    write_lock(&selinux_state.ss->policy_rwlock);
    cursor.cur = payload; cursor.end = payload + (size_t)data_len;
    ret = 0; success_cmd_count = 0; cmd_index = 0;
    while (cursor.cur < cursor.end) {
        struct sepol_data header;
        const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
        int expected_argc; u32 arg_index;
        ret = sepol_read_cmd_header(&cursor, &header);
        if (ret < 0) { pr_err("sepol: failed header #%u\n", cmd_index); break; }
        expected_argc = sepol_expected_argc(header.cmd);
        if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) { ret = -EINVAL; break; }
        for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
            ret = sepol_read_string(&cursor, &args[arg_index]);
            if (ret < 0) break;
        }
        if (ret < 0) break;
        ret = apply_one_sepolicy_cmd(&selinux_state.ss->policydb, &header, args);
        if (ret < 0) pr_err("sepol: cmd #%u failed cmd=%u subcmd=%u\n", cmd_index, header.cmd, header.subcmd);
        else success_cmd_count++;
        cmd_index++;
    }
    write_unlock(&selinux_state.ss->policy_rwlock);
    reset_avc_cache_419();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    ret = success_cmd_count;
out_free:
    kvfree(payload);
    return ret;
}
#else
/* Version >= 5.10 : on garde le code original de FinaSU */
#error "Ce script cible uniquement 4.19. Le code 5.10+ de rules.c doit être restauré depuis FinaSU."
#endif
RULESEOF
echo "  ✅ rules.c 4.19 uniquement (5.10+ désactivé)"

# ==================== 4b. COMPATIBILITÉ 4.19 (sans FIX 14 et 15) ====================
echo "=== Correctifs ciblés 4.19 (sans FIX 14/15 doublons Inline) ==="
python3 - "$GITHUB_WORKSPACE" <<'FIXEOF' 2>&1 | tee -a "$AUDIT"
import os, sys, re

GW = sys.argv[1]
kernel_root = os.path.join(GW, "kernel_sources")
ksu_root = os.path.join(kernel_root, "FinaSU", "kernel")
total = 0

def read(p):
    with open(p, encoding='utf-8', errors='replace') as f: return f.read()
def write(p, c):
    with open(p, 'w', encoding='utf-8') as f: f.write(c)
def ensure_inc_after_last(c, inc):
    if inc in c: return c
    lines = c.split('\n'); last = -1
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith('#include'): last = i
    if last >= 0:
        lines.insert(last + 1, f'#include {inc}')
        return '\n'.join(lines)
    return f'#include {inc}\n' + c

# FIX 1-13 : identiques à l'original (fs/stat.c, MODULE_IMPORT_NS, file_wrapper, seccomp_cache,
# su_mount_ns, pkg_observer, TWA_RESUME, app_profile, sepolicy, minmax, tasklist_lock, dispatch,
# selinux_hide)
#
# FIX 14 (fs/namespace.c path_mount/path_umount) : SUPPRIMÉ — le script Inline JackA1ltman
# n'injecte rien dans fs/namespace.c, mais ce backport était lié au backend Tracepoint
# (mount ns hooks). En Inline, il est inutile et peut créer des conflits.
#
# FIX 15 (kernel/reboot.c ksu_handle_sys_reboot) : SUPPRIMÉ — le script Inline JackA1ltman
# injecte DÉJÀ ksu_handle_sys_reboot dans kernel/reboot.c. Doublon = erreur de compilation.

p = os.path.join(kernel_root, "fs/stat.c")
if os.path.isfile(p):
    c = read(p)
    if '#include <linux/susfs_def.h>' not in c:
        marker = '#include <asm/unistd.h>'
        if marker in c:
            idx = c.index(marker) + len(marker)
            eol = c.find('\n', idx)
            if eol == -1: eol = len(c)
            insert = '\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif'
            c = c[:eol] + insert + c[eol:]
            write(p, c); total += 1
            print(f"  ✅ fs/stat.c: include susfs_def.h")

if os.path.isdir(ksu_root):
    for dp, dn, fn in os.walk(ksu_root):
        for f in fn:
            if not f.endswith(('.c', '.h')): continue
            p = os.path.join(dp, f)
            try: c = read(p)
            except Exception: continue
            if 'MODULE_IMPORT_NS' not in c: continue
            lines = c.split('\n'); out = []; changed = False
            for ln in lines:
                s = ln.strip()
                if s.startswith('MODULE_IMPORT_NS(') and s.endswith(');'):
                    prev = out[-1].strip() if out else ''
                    if prev != '#ifdef MODULE_IMPORT_NS':
                        out.append('#ifdef MODULE_IMPORT_NS'); out.append(ln); out.append('#endif')
                        changed = True; continue
                out.append(ln)
            if changed:
                write(p, '\n'.join(out)); total += 1
                print(f"  ✅ {os.path.relpath(p, GW)}: MODULE_IMPORT_NS")

p = os.path.join(ksu_root, "infra/file_wrapper.c")
if os.path.isfile(p):
    c = read(p); original = c
    pairs = [
        ('    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;',
         '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif'),
        ('    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;',
         '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n#endif'),
    ]
    for old, new in pairs:
        if old in c and new not in c: c = c.replace(old, new, 1)
    if c != original:
        write(p, c); total += 1
        print(f"  ✅ infra/file_wrapper.c: guards 4.19")

p = os.path.join(ksu_root, "infra/seccomp_cache.c")
if os.path.isfile(p):
    c = read(p)
    if 'SECCOMP_ARCH_NATIVE_NR' in c and 'KSU_SECCOMP_COMPAT' not in c:
        compat = ('\n#ifndef KSU_SECCOMP_COMPAT\n#define KSU_SECCOMP_COMPAT 1\n'
                  '#ifndef SECCOMP_ARCH_NATIVE_NR\n#ifdef CONFIG_COMPAT\n'
                  '#define SECCOMP_ARCH_NATIVE_NR 2\n#else\n#define SECCOMP_ARCH_NATIVE_NR 1\n'
                  '#endif\n#endif\n#endif\n')
        lines = c.split('\n'); last_inc = -1
        for i, ln in enumerate(lines):
            if ln.lstrip().startswith('#include'): last_inc = i
        if last_inc >= 0:
            lines.insert(last_inc + 1, compat)
            write(p, '\n'.join(lines)); total += 1
            print(f"  ✅ infra/seccomp_cache.c: SECCOMP_ARCH_NATIVE_NR")

p = os.path.join(ksu_root, "infra/su_mount_ns.c")
if os.path.isfile(p):
    c = read(p)
    if '#include <uapi/linux/mount.h>' in c and 'KSU_MOUNT_HDR_COMPAT' not in c:
        c = c.replace('#include <uapi/linux/mount.h>',
            '#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)\n'
            '#include <uapi/linux/mount.h>\n#else\n#include <linux/mount.h>\n#endif\n'
            '#define KSU_MOUNT_HDR_COMPAT 1')
        write(p, c); total += 1
        print(f"  ✅ infra/su_mount_ns.c: uapi/linux/mount.h")

# pkg_observer.c : réécriture complète 4.19
p = os.path.join(ksu_root, "manager/pkg_observer.c")
if os.path.isfile(p):
    c = read(p)
    if 'KSU_PKG_OBSERVER_419' not in c:
        new_c = r'''// SPDX-License-Identifier: GPL-2.0
// KSU_PKG_OBSERVER_419
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/fsnotify_backend.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/rculist.h>
#include <linux/task_work.h>
#include <linux/version.h>
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#include <linux/susfs_def.h>
#endif
#include "klog.h"
#include "manager/throne_tracker.h"

#define MASK_SYSTEM (FS_CREATE | FS_MOVE | FS_EVENT_ON_CHILD)
#ifndef TWA_RESUME
#define TWA_RESUME 0
#endif

struct watch_dir {
    const char *path;
    u32 mask;
    struct path kpath;
    struct inode *inode;
    struct fsnotify_mark *mark;
};

static struct fsnotify_group *g;

static void ksu_track_throne_tw_func(struct callback_head *cb)
{
    kfree(cb);
    if (current->flags & PF_EXITING) return;
    track_throne(false);
}

static void ksu_defer_track_throne(void)
{
    struct callback_head *cb;
    if (!(current->flags & PF_KTHREAD)) {
        cb = kzalloc(sizeof(*cb), GFP_KERNEL);
        if (cb) {
            cb->func = ksu_track_throne_tw_func;
            if (!task_work_add(current, cb, TWA_RESUME)) return;
            kfree(cb);
        }
    }
    track_throne(false);
}

static void ksu_maybe_track_packages_list(void)
{
    ksu_defer_track_throne();
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir,
                                  const struct qstr *file_name, u32 cookie)
{
    if (!file_name) return 0;
    if (mask & FS_ISDIR) return 0;
    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13))
        ksu_maybe_track_packages_list();
    return 0;
}
#else
static int ksu_handle_event_compat(struct fsnotify_group *group, struct inode *inode, u32 mask,
                                    const void *data, int data_type, const unsigned char *file_name,
                                    u32 cookie, struct fsnotify_iter_info *iter_info)
{
    (void)group; (void)inode; (void)data; (void)data_type; (void)cookie; (void)iter_info;
    if (!file_name) return 0;
    if (mask & FS_ISDIR) return 0;
    if (strlen((const char *)file_name) == 13 && !memcmp(file_name, "packages.list", 13))
        ksu_maybe_track_packages_list();
    return 0;
}
#endif

static const struct fsnotify_ops ksu_ops = {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    .handle_inode_event = ksu_handle_inode_event,
#else
    .handle_event = ksu_handle_event_compat,
#endif
};

static int add_mark_on_inode(struct inode *inode, u32 mask, struct fsnotify_mark **out)
{
    struct fsnotify_mark *m;
    m = kzalloc(sizeof(*m), GFP_KERNEL);
    if (!m) return -ENOMEM;
    fsnotify_init_mark(m, g);
    m->mask = mask;
    if (fsnotify_add_inode_mark(m, inode, 0)) {
        fsnotify_put_mark(m);
        return -EINVAL;
    }
    *out = m;
    return 0;
}

static int watch_one_dir(struct watch_dir *wd)
{
    int ret = kern_path(wd->path, LOOKUP_FOLLOW, &wd->kpath);
    if (ret) return ret;
    wd->inode = d_inode(wd->kpath.dentry);
    ihold(wd->inode);
    ret = add_mark_on_inode(wd->inode, wd->mask, &wd->mark);
    if (ret) {
        path_put(&wd->kpath);
        iput(wd->inode);
        wd->inode = NULL;
        return ret;
    }
    return 0;
}

static void unwatch_one_dir(struct watch_dir *wd)
{
    if (wd->mark) { fsnotify_destroy_mark(wd->mark, g); fsnotify_put_mark(wd->mark); wd->mark = NULL; }
    if (wd->inode) { iput(wd->inode); wd->inode = NULL; }
    if (wd->kpath.dentry) { path_put(&wd->kpath); memset(&wd->kpath, 0, sizeof(wd->kpath)); }
}

static struct watch_dir g_watch = { .path = "/data/system", .mask = MASK_SYSTEM };

int ksu_observer_init(void)
{
    int ret = 0;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 0, 0)
    g = fsnotify_alloc_group(&ksu_ops, 0);
#else
    g = fsnotify_alloc_group(&ksu_ops);
#endif
    if (IS_ERR(g)) return PTR_ERR(g);
    watch_one_dir(&g_watch);
    return 0;
}

void __exit ksu_observer_exit(void)
{
    unwatch_one_dir(&g_watch);
    fsnotify_put_group(g);
}
'''
        write(p, new_c); total += 1
        print(f"  ✅ manager/pkg_observer.c: réécrit 4.19")

# TWA_RESUME + put_task_struct
if os.path.isdir(ksu_root):
    for dp, dn, fn in os.walk(ksu_root):
        for f in fn:
            if not f.endswith(('.c', '.h')): continue
            p = os.path.join(dp, f)
            try: c = read(p)
            except Exception: continue
            if not any(s in c for s in ('TWA_RESUME', 'put_task_struct')): continue
            original = c
            if 'TWA_RESUME' in c and '#ifndef TWA_RESUME' not in c:
                twa = '\n#ifndef TWA_RESUME\n#define TWA_RESUME 0\n#endif\n'
                c = ensure_inc_after_last(c, '<linux/version.h>')
                lines = c.split('\n'); last_inc = -1
                for i, ln in enumerate(lines):
                    if ln.lstrip().startswith('#include'): last_inc = i
                if last_inc >= 0:
                    lines.insert(last_inc + 1, twa); c = '\n'.join(lines)
                else: c = twa + c
            if 'put_task_struct' in c:
                c = ensure_inc_after_last(c, '<linux/sched.h>')
                c = ensure_inc_after_last(c, '<linux/sched/task.h>')
            if c != original:
                write(p, c); total += 1
                print(f"  ✅ {os.path.relpath(p, GW)}: TWA_RESUME")

# app_profile
p = os.path.join(ksu_root, "policy/app_profile.c")
if os.path.isfile(p):
    c = read(p); original = c
    old = 'void seccomp_filter_release(struct task_struct *tsk);\n'
    if old in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\nvoid seccomp_filter_release' not in c:
        c = c.replace(old, '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\nvoid seccomp_filter_release(struct task_struct *tsk);\n#endif\n', 1)
    old = '    atomic_set(&current->seccomp.filter_count, 0);\n'
    if old in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n    atomic_set(&current->seccomp.filter_count' not in c:
        c = c.replace(old, '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n    atomic_set(&current->seccomp.filter_count, 0);\n#endif\n', 1)
    old = '    seccomp_filter_release(fake);\n'
    if old in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n    seccomp_filter_release(fake)' not in c:
        new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'
               '    seccomp_filter_release(fake);\n#else\n    put_seccomp_filter(fake);\n#endif\n')
        c = c.replace(old, new, 1)
    if c != original:
        write(p, c); total += 1
        print(f"  ✅ policy/app_profile.c")

# sepolicy.c
p = os.path.join(ksu_root, "selinux/sepolicy.c")
if os.path.isfile(p):
    c = read(p); original = c
    c = ensure_inc_after_last(c, '<linux/flex_array.h>')
    if 'ksu_avtab_htable_get' not in c and '#define KSU_SUPPORT_ADD_TYPE' in c:
        c = c.replace('#define KSU_SUPPORT_ADD_TYPE\n',
            '#define KSU_SUPPORT_ADD_TYPE\n\n'
            '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n'
            '#define ksu_avtab_htable_get(htab, i) ((struct avtab_node *)flex_array_get_ptr((htab).htable, (i)))\n'
            '#define ksu_avtab_htable_set(htab, i, v) flex_array_put_ptr((htab).htable, (i), (v), GFP_ATOMIC)\n'
            '#else\n'
            '#define ksu_avtab_htable_get(htab, i) ((htab).htable[(i)])\n'
            '#define ksu_avtab_htable_set(htab, i, v) ((htab).htable[(i)] = (v))\n'
            '#endif\n', 1)
    c = c.replace('for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {',
                  'for (n = ksu_avtab_htable_get(db->te_avtab, i); n; prev = n, n = n->next) {', 1)
    c = c.replace('db->te_avtab.htable[i] = n->next;', 'ksu_avtab_htable_set(db->te_avtab, i, n->next);', 1)
    c = c.replace('removed.htable[0] = n;', 'ksu_avtab_htable_set(removed, 0, n);', 1)
    if c != original:
        write(p, c); total += 1
        print(f"  ✅ selinux/sepolicy.c")

# minmax.h -> kernel.h
if os.path.isdir(ksu_root):
    for dp, dn, fn in os.walk(ksu_root):
        for f in fn:
            if not f.endswith(('.c', '.h')): continue
            p = os.path.join(dp, f)
            try: c = read(p)
            except Exception: continue
            if '#include <linux/minmax.h>' not in c: continue
            if 'KSU_MINMAX_COMPAT' in c: continue
            c = c.replace('#include <linux/minmax.h>',
                '/* KSU_MINMAX_COMPAT */\n#include <linux/kernel.h>', 1)
            write(p, c); total += 1
            print(f"  ✅ {os.path.relpath(p, GW)}: minmax")

# dispatch.c compat
p = os.path.join(ksu_root, "supercall/dispatch.c")
if os.path.isfile(p):
    c = read(p)
    if 'KSU_DISPATCH_419_COMPAT' not in c:
        for inc in ['<linux/sched.h>', '<linux/sched/task.h>', '<linux/pid.h>', '<linux/spinlock.h>']:
            c = ensure_inc_after_last(c, inc)
        compat_block = '''
#ifndef KSU_DISPATCH_419_COMPAT
#define KSU_DISPATCH_419_COMPAT 1
extern struct task_struct init_task;
extern rwlock_t tasklist_lock;
#ifdef task_pgrp
#undef task_pgrp
#endif
#ifdef task_session
#undef task_session
#endif
static inline struct pid *ksu_task_pgrp_419(struct task_struct *task) { return task->signal->pids[PIDTYPE_PGID]; }
static inline struct pid *ksu_task_session_419(struct task_struct *task) { return task->signal->pids[PIDTYPE_SID]; }
#define task_pgrp(task)    ksu_task_pgrp_419(task)
#define task_session(task) ksu_task_session_419(task)
#endif
'''
        lines = c.split('\n'); last_inc = -1
        for i, ln in enumerate(lines):
            if ln.lstrip().startswith('#include'): last_inc = i
        lines.insert(last_inc + 1, compat_block)
        write(p, '\n'.join(lines)); total += 1
        print(f"  ✅ supercall/dispatch.c: compat 4.19")

# selinux_hide.c
p = os.path.join(ksu_root, "feature/selinux_hide.c")
if os.path.isfile(p):
    c = read(p)
    if 'ksu_fake_status_mutex' not in c:
        new_sh = r'''// SPDX-License-Identifier: GPL-2.0
#include "selinux_hide.h"
#include "infra/symbol_resolver.h"
#include "hook/patch_memory.h"
#include <linux/jump_label.h>
#include <linux/version.h>
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include <linux/page-flags.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <security.h>
#include "avc.h"
#include "objsec.h"
#include "klog.h"
#include "ksu.h"
#include "policy/feature.h"

static DEFINE_MUTEX(selinux_hide_mutex);
static DEFINE_MUTEX(ksu_fake_status_mutex);
bool ksu_selinux_hide_enabled __read_mostly;
bool ksu_selinux_hide_running __read_mostly;
static struct page *fake_status;
typedef int (*sel_open_handle_status_fn)(struct inode *inode, struct file *filp);
static sel_open_handle_status_fn orig_sel_open_handle_status;
static sel_open_handle_status_fn *sel_open_handle_status_slot;
static struct page *ksu_selinux_status_page(void) { return selinux_kernel_status_page(&selinux_state); }

ssize_t my_write_context(struct file *file, char *buf, size_t size)
{
    char *canon = NULL; u32 sid, len; int ret;
    (void)file;
    ret = security_context_to_sid(&selinux_state, buf, size, &sid, GFP_KERNEL);
    if (ret) return ret;
    ret = security_sid_to_context(&selinux_state, sid, &canon, &len);
    if (ret) return ret;
    if (len > SIMPLE_TRANSACTION_LIMIT) { kfree(canon); return -ERANGE; }
    memcpy(buf, canon, len); kfree(canon);
    return len;
}

ssize_t my_write_access(struct file *file, char *buf, size_t size)
{
    char *scon, *tcon; u32 ssid, tsid, sconlen, tconlen; u16 tclass;
    struct av_decision avd; int ret;
    (void)file;
    scon = kzalloc(size + 1, GFP_KERNEL); tcon = kzalloc(size + 1, GFP_KERNEL);
    if (!scon || !tcon) { kfree(tcon); kfree(scon); return -ENOMEM; }
    if (sscanf(buf, "%s %s %hu", scon, tcon, &tclass) != 3) { kfree(tcon); kfree(scon); return -EINVAL; }
    sconlen = strlen(scon); tconlen = strlen(tcon);
    ret = security_context_to_sid(&selinux_state, scon, sconlen, &ssid, GFP_KERNEL);
    if (!ret) ret = security_context_to_sid(&selinux_state, tcon, tconlen, &tsid, GFP_KERNEL);
    if (ret) { kfree(tcon); kfree(scon); return ret; }
    security_compute_av_user(&selinux_state, ssid, tsid, tclass, &avd);
    ret = scnprintf(buf, SIMPLE_TRANSACTION_LIMIT, "%x %x %x %x %u %x",
                    avd.allowed, 0xffffffff, avd.auditallow, avd.auditdeny, avd.seqno, avd.flags);
    kfree(tcon); kfree(scon);
    return ret;
}

static int ksu_selinux_status_open(struct inode *inode, struct file *filp)
{
    struct page *status; (void)inode;
    if (ksu_selinux_hide_enabled && current_uid().val >= 10000) {
        mutex_lock(&ksu_fake_status_mutex);
        status = fake_status;
        mutex_unlock(&ksu_fake_status_mutex);
        if (status) { filp->private_data = status; return 0; }
    }
    return orig_sel_open_handle_status(inode, filp);
}

static int ksu_hook_selinux_status_open(void)
{
    struct file_operations *ops; sel_open_handle_status_fn new_fn; int ret;
    if (orig_sel_open_handle_status) return 0;
    ops = find_kernel_symbol_exact("sel_handle_status_ops");
    if (!ops || !ops->open) return -ENOENT;
    sel_open_handle_status_slot = (sel_open_handle_status_fn *)&ops->open;
    orig_sel_open_handle_status = *sel_open_handle_status_slot;
    new_fn = ksu_selinux_status_open;
    ret = ksu_patch_text(sel_open_handle_status_slot, &new_fn, sizeof(new_fn), KSU_PATCH_TEXT_FLUSH_DCACHE);
    if (ret) { orig_sel_open_handle_status = NULL; sel_open_handle_status_slot = NULL; }
    return ret;
}

static void ksu_unhook_selinux_status_open(void)
{
    if (sel_open_handle_status_slot && orig_sel_open_handle_status) {
        ksu_patch_text(sel_open_handle_status_slot, &orig_sel_open_handle_status,
                       sizeof(orig_sel_open_handle_status), KSU_PATCH_TEXT_FLUSH_DCACHE);
        orig_sel_open_handle_status = NULL;
        sel_open_handle_status_slot = NULL;
    }
}

static int ksu_initialize_fake_status(void)
{
    struct page *status_page, *new_page; struct selinux_kernel_status *status, *new_status;
    mutex_lock(&ksu_fake_status_mutex);
    if (fake_status) { mutex_unlock(&ksu_fake_status_mutex); return 0; }
    status_page = ksu_selinux_status_page();
    if (!status_page) { mutex_unlock(&ksu_fake_status_mutex); return -ENODEV; }
    status = page_address(status_page);
    if (!status) { mutex_unlock(&ksu_fake_status_mutex); return -EFAULT; }
    new_page = alloc_page(GFP_KERNEL | __GFP_ZERO);
    if (!new_page) { mutex_unlock(&ksu_fake_status_mutex); return -ENOMEM; }
    new_status = page_address(new_page);
    memcpy(new_status, status, sizeof(*status));
    new_status->enforcing = 1; new_status->policyload = 0; new_status->sequence = 0;
    fake_status = new_page; mutex_unlock(&ksu_fake_status_mutex);
    return 0;
}

static int selinux_hide_feature_get(u64 *value) { *value = ksu_selinux_hide_enabled ? 1 : 0; return 0; }

static int selinux_hide_feature_set(u64 value)
{
    int ret = 0; bool enable = value != 0;
    mutex_lock(&selinux_hide_mutex);
    if (enable == ksu_selinux_hide_enabled) { mutex_unlock(&selinux_hide_mutex); return 0; }
    if (enable) {
        ret = ksu_initialize_fake_status();
        if (!ret) ret = ksu_hook_selinux_status_open();
        if (!ret) { ksu_selinux_hide_enabled = true; ksu_selinux_hide_running = true; }
    } else {
        ksu_selinux_hide_enabled = false; ksu_selinux_hide_running = false;
        ksu_unhook_selinux_status_open();
    }
    mutex_unlock(&selinux_hide_mutex);
    return ret;
}

static const struct ksu_feature_handler selinux_hide_handler = {
    .feature_id = KSU_FEATURE_SELINUX_HIDE, .name = "selinux_hide",
    .get_handler = selinux_hide_feature_get, .set_handler = selinux_hide_feature_set,
};

void ksu_selinux_hide_handle_second_stage(void) { if (ksu_selinux_hide_enabled) ksu_initialize_fake_status(); }
void ksu_selinux_hide_handle_post_fs_data(void) { if (ksu_selinux_hide_enabled) ksu_initialize_fake_status(); }

void __init ksu_selinux_hide_init(void)
{
    if (ksu_register_feature_handler(&selinux_hide_handler))
        pr_err("Failed to register selinux_hide feature handler\n");
}

void __exit ksu_selinux_hide_exit(void)
{
    mutex_lock(&selinux_hide_mutex);
    ksu_selinux_hide_enabled = false; ksu_selinux_hide_running = false;
    ksu_unhook_selinux_status_open();
    mutex_unlock(&selinux_hide_mutex);
    ksu_unregister_feature_handler(KSU_FEATURE_SELINUX_HIDE);
    mutex_lock(&ksu_fake_status_mutex);
    if (fake_status) __free_page(fake_status);
    fake_status = NULL;
    mutex_unlock(&ksu_fake_status_mutex);
}

void ksu_selinux_hide_drop_backup_if_unused(void) { }
'''
        write(p, new_sh); total += 1
        print(f"  ✅ feature/selinux_hide.c")

print(f"  ✅ portage 4.19 : {total} fichier(s) (FIX 14/15 retirés, Inline gère reboot.c)")
FIXEOF

# ==================== 5. CONFIG (INLINE au lieu de TRACEPOINT) ====================
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
CLANG_MAJOR=$(clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)
CC_ARGS=""
if [ "${FORCE_CLANG_WRAP:-1}" = "1" ] || [ "${CLANG_MAJOR:-99}" -lt 16 ]; then
    cat > "$GITHUB_WORKSPACE/clang-wrap" <<'W'
#!/bin/bash
args=()
for a in "$@"; do case "$a" in -Wno-cast-function-type-strict|-Wcast-function-type-strict) ;; *) args+=("$a") ;; esac; done
exec clang -Wno-unknown-warning-option "${args[@]}" -Wno-unknown-warning-option
W
    chmod +x "$GITHUB_WORKSPACE/clang-wrap"
    CC_ARGS="CC=$GITHUB_WORKSPACE/clang-wrap"
fi

mkdir -p out
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

cat >> out/.config <<'EOF'
CONFIG_KSU=y
# CONFIG_KSU_HOOK_TRACEPOINT is not set
CONFIG_KSU_HOOK_SUSFS_INLINE=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KRETPROBES=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_EXT4_FS=y
CONFIG_HEADERS_INSTALL=y
CONFIG_THREAD_INFO_IN_TASK=y
CONFIG_FTRACE=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
EOF
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

# Force INLINE post-olddefconfig + désactive Tracepoint
if grep -q '^CONFIG_KSU_HOOK_TRACEPOINT=y' out/.config; then
    sed -i 's/^CONFIG_KSU_HOOK_TRACEPOINT=y/# CONFIG_KSU_HOOK_TRACEPOINT is not set/' out/.config
    echo "  ✅ CONFIG_KSU_HOOK_TRACEPOINT forcé OFF" | tee -a "$AUDIT"
fi
if ! grep -q '^CONFIG_KSU_HOOK_SUSFS_INLINE=y' out/.config; then
    echo 'CONFIG_KSU_HOOK_SUSFS_INLINE=y' >> out/.config
    echo "  ✅ CONFIG_KSU_HOOK_SUSFS_INLINE forcé ON" | tee -a "$AUDIT"
fi
if grep -q '^CONFIG_KSU_DYNAMIC_MANAGER=y' out/.config; then
    sed -i 's/^CONFIG_KSU_DYNAMIC_MANAGER=y/# CONFIG_KSU_DYNAMIC_MANAGER is not set/' out/.config
    echo "  ✅ CONFIG_KSU_DYNAMIC_MANAGER forcé OFF" | tee -a "$AUDIT"
fi

echo "=== VÉRIFICATION CONFIG KSU (INLINE) ===" | tee -a "$AUDIT"
grep -E "^CONFIG_KSU|^# CONFIG_KSU" out/.config | tee -a "$AUDIT"

grep -q "^CONFIG_KSU=y" out/.config || { echo "❌ CONFIG_KSU off"; exit 1; }
grep -q "^CONFIG_KSU_HOOK_SUSFS_INLINE=y" out/.config || { echo "❌ INLINE off"; exit 1; }
grep -q "^# CONFIG_KSU_HOOK_TRACEPOINT is not set" out/.config || { echo "❌ TRACEPOINT pas désactivé"; exit 1; }
grep -q "^CONFIG_KSU_SUSFS=y" out/.config || { echo "❌ SUSFS off"; exit 1; }

echo "=== PROBE : prérequis Inline ===" | tee -a "$AUDIT"
grep -E "^CONFIG_(ARM64|KSU|KSU_SUSFS|KSU_HOOK_SUSFS_INLINE|KPROBES|KALLSYMS|HEADERS_INSTALL)=" out/.config | tee -a "$AUDIT"

# ==================== 6. MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb){return blocking_notifier_chain_register(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb){return blocking_notifier_chain_unregister(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int s){return;}\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION ====================
echo "=== Compilation (avec KSU_REQUIRE_PREINIT=1) ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" $SIG_ARGS \
  KSU_REQUIRE_PREINIT=1 \
  -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    { grep -nE "error:|undefined symbol|fatal error:|\*\*\*|check_susfs_inline" build.log | head -150; echo ""; tail -n 100 build.log; } \
      > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅ Compilation réussie"
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-${VER}"
cp out/System.map "$GITHUB_WORKSPACE/output/System.map-${VER}"

# ==================== 8. KSUD ====================
echo "=== ksud ==="
cd "$GITHUB_WORKSPACE"
if [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"; KSUD_ROOT="$KSU_REPO_ROOT"
else
    git clone --depth=1 --branch "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git ksud-src
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"; KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
fi
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
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
KSUD_BINARY=$(find "$KSUD_ROOT" -type f -path "*aarch64-linux-android/release/ksud" | head -1)
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK ====================
echo "=== Repack ==="
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 || true
[ -f boot-stock.img ] && [ "$(stat -c%s boot-stock.img)" -gt 50000000 ] || { echo "❌ boot invalide"; exit 1; }
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true
mkdir -p repack; cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk.apk
unzip -q Magisk.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot; chmod +x repack/magiskboot
rm -rf Magisk.apk lib
cd repack
set +e; ./magiskboot unpack boot.img; set -e
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" ./local_su; chmod 755 ./local_su
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su"
rm -f ./local_su
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10-11. DIAG + SORTIE ====================
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
[ -f kernel ] && [ "$(sha256sum kernel | cut -d' ' -f1)" = "$(cat /tmp/kernel_compiled_hash.txt)" ] && echo "✅ Noyau IDENTIQUE"
../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null && echo "✅ ksud OK" || echo "❌ ksud absent"
cd ..
cp final_boot.img "output/FinaSU-A-${VER}-boot.img"
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ ${VER} (backend INLINE) ==="
ls -lh output/
