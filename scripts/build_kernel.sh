#!/bin/bash
set -euo pipefail

# =============================================================================
# FinaSU (LyraVoid) en dur dans le noyau 4.19 — ÉTAPE A
# rules.c dual-path + portage non-SELinux (TWA_RESUME, seccomp, headers…)
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
print("\n-- Première erreur de chaque fichier --")
for f, v in list(first_msg.items())[:40]:
    print(f"{f}:{v}"[:170])
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
echo "SHA complet de la source : $(git rev-parse HEAD)" | tee -a "$AUDIT"

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

{
    echo ""
    echo "=== DRIVER : Kconfig ==="
    grep -n "^config \|depends on" "$KSU_DIR/Kconfig" | head -80 || true
    true
} 2>&1 | tee -a "$AUDIT"

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
    if [ -n "$SIG_OUT" ]; then
        FINASU_EXPECTED_SIZE=$(echo "$SIG_OUT" | sed -n '1p')
        FINASU_EXPECTED_HASH=$(echo "$SIG_OUT" | sed -n '2p')
    fi
fi
SIG_ARGS=""
if [ -n "$FINASU_EXPECTED_SIZE" ] && [ -n "$FINASU_EXPECTED_HASH" ]; then
    SIG_ARGS="KSU_EXPECTED_SIZE=$FINASU_EXPECTED_SIZE KSU_EXPECTED_HASH=$FINASU_EXPECTED_HASH"
    echo "Signature manager : $FINASU_EXPECTED_SIZE / $FINASU_EXPECTED_HASH" | tee -a "$AUDIT"
else
    echo "⚠️ AUCUNE signature de manager fournie" | tee -a "$AUDIT"
fi

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

# ==================== 3h. FIX O_CLOEXEC ====================
echo "=== Fix O_CLOEXEC ==="
FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_GET_UNUSED" ]; then
    for f in $FILES_GET_UNUSED; do
        sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
    done
fi
FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_ANON_INODE" ]; then
    for f in $FILES_ANON_INODE; do
        sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g; s/O_RDWR|O_CLOEXEC/O_RDWR/g; s/, O_CLOEXEC)/)/g' "$f"
    done
fi

# ==================== 4b. PORTAGE 4.19 ====================
echo ""
echo "=== Portage 4.19 ==="

# --- 4b.1 rules.c dual-path (remplacement complet) ---
echo "  → rules.c dual-path..."
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
#include "linux/lsm_audit.h"
#include "xfrm.h"

#define ALL NULL

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
/* ========== Chemin 4.19 ========== */
struct selinux_policy *backup_sepolicy = NULL;

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
extern int avc_ss_reset(u32 seqno);
#else
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
#endif

static void reset_avc_cache(u32 seqno)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
	avc_ss_reset(seqno);
	selnl_notify_policyload(seqno);
#else
	struct selinux_avc *avc = selinux_state.avc;
	if (avc)
		avc_ss_reset(avc, seqno);
	selnl_notify_policyload(seqno);
#endif
	selinux_xfrm_notify_policyload();
}

static struct policydb *ksu_get_policydb(void)
{
#if defined(KSU_COMPAT_USE_SELINUX_STATE)
	return &selinux_state.ss->policydb;
#else
	extern struct policydb policydb;
	return &policydb;
#endif
}

void apply_kernelsu_rules(void)
{
	struct policydb *db = ksu_get_policydb();

	if (!getenforce())
		pr_info("SELinux permissive or disabled, apply rules! (old kernel path)\n");

	ksu_type(db, KERNEL_SU_DOMAIN, "domain");
	ksu_permissive(db, KERNEL_SU_DOMAIN);
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "mlstrustedsubject");
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "netdomain");
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "bluetoothdomain");

	ksu_type(db, KERNEL_SU_FILE, "file_type");
	ksu_typeattribute(db, KERNEL_SU_FILE, "mlstrustedobject");
	ksu_allow(db, "domain", KERNEL_SU_FILE, ALL, ALL);
	ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);

	if (db->policyvers >= POLICYDB_VERSION_XPERMS_IOCTL) {
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "blk_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "fifo_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "chr_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "file", ALL);
	}

	ksu_allow(db, "init", KERNEL_SU_DOMAIN, ALL, ALL);
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "read");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "process", "sigchld");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fd", "use");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "write");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "open");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "write");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "connectto");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getopt");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "binder", ALL);
	ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
	ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");

	reset_avc_cache(0);
	pr_info("KernelSU rules applied (4.19 compatibility path)\n");
}

int handle_sepolicy(void __user *user_data, u64 data_len)
{
	pr_info("handle_sepolicy not supported on kernel < 5.10\n");
	return -EOPNOTSUPP;
}

#else /* >= 5.10 */
struct selinux_policy *backup_sepolicy;
#define SELINUX_POLICY_INSTEAD_SELINUX_SS

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
extern int avc_ss_reset(u32 seqno);
#else
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
#endif

static void reset_avc_cache(u32 seqno)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
	avc_ss_reset(seqno);
	selnl_notify_policyload(seqno);
	selinux_status_update_policyload(seqno);
#else
	struct selinux_avc *avc = selinux_state.avc;
	avc_ss_reset(avc, seqno);
	selnl_notify_policyload(seqno);
	selinux_status_update_policyload(&selinux_state, seqno);
#endif
	selinux_xfrm_notify_policyload();
}

void apply_kernelsu_rules(void)
{
	struct selinux_policy *pol, *old_pol;
	struct policydb *db;

	if (!getenforce())
		pr_info("SELinux permissive or disabled, apply rules!\n");

	mutex_lock(&selinux_state.policy_mutex);
	old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
	backup_sepolicy = ksu_dup_sepolicy(old_pol);
	if (IS_ERR(backup_sepolicy)) {
		pr_err("failed to create backup sepolicy: %ld\n", PTR_ERR(backup_sepolicy));
		backup_sepolicy = NULL;
	} else {
		backup_sepolicy->sidtab = kzalloc(sizeof(*backup_sepolicy->sidtab), GFP_KERNEL);
		if (!backup_sepolicy->sidtab) {
			ksu_destroy_sepolicy(backup_sepolicy);
			backup_sepolicy = NULL;
		} else {
			int ret = policydb_load_isids(&backup_sepolicy->policydb, backup_sepolicy->sidtab);
			if (ret) {
				kfree(backup_sepolicy->sidtab);
				ksu_destroy_sepolicy(backup_sepolicy);
				backup_sepolicy = NULL;
			}
		}
	}
	pol = ksu_dup_sepolicy(old_pol);
	if (IS_ERR(pol)) {
		pr_err("failed to dup selinux_policy: %ld\n", PTR_ERR(pol));
		goto out_unlock;
	}
	db = &pol->policydb;
	pol->latest_granting = old_pol->latest_granting + 1;
	if (!ksu_set_original_types(db, &old_pol->policydb, pol->latest_granting))
		pr_warn("failed to save original type metadata\n");

	ksu_type(db, KERNEL_SU_DOMAIN, "domain");
	ksu_permissive(db, KERNEL_SU_DOMAIN);
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "mlstrustedsubject");
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "netdomain");
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "bluetoothdomain");
	ksu_type(db, KERNEL_SU_FILE, "file_type");
	ksu_typeattribute(db, KERNEL_SU_FILE, "mlstrustedobject");
	ksu_allow(db, "domain", KERNEL_SU_FILE, ALL, ALL);
	ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);
	if (db->policyvers >= POLICYDB_VERSION_XPERMS_IOCTL) {
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "blk_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "fifo_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "chr_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "file", ALL);
	}
	ksu_allow(db, "init", KERNEL_SU_DOMAIN, ALL, ALL);
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "read");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "process", "sigchld");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fd", "use");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "write");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "open");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "write");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "connectto");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getopt");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "execute");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "map");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "write");
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "binder", ALL);
	ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
	ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");
#ifdef CONFIG_KSU_SUSFS
	ksu_allow(db, "zygote", "labeledfs", "filesystem", "unmount");
#endif
	rcu_assign_pointer(selinux_state.policy, pol);
	synchronize_rcu();
	ksu_destroy_sepolicy(old_pol);
	reset_avc_cache(pol->latest_granting);
#ifdef CONFIG_KSU_SUSFS
	susfs_set_batch_sid();
#endif
out_unlock:
	mutex_unlock(&selinux_state.policy_mutex);
}

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
	bool success = false; int ret;
	switch (header->cmd) {
	case KSU_SEPOLICY_CMD_NORMAL_PERM:
		if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW)
			success = ksu_allow(db, args[0], args[1], args[2], args[3]);
		else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DENY)
			success = ksu_deny(db, args[0], args[1], args[2], args[3]);
		else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_AUDITALLOW)
			success = ksu_auditallow(db, args[0], args[1], args[2], args[3]);
		else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DONTAUDIT)
			success = ksu_dontaudit(db, args[0], args[1], args[2], args[3]);
		return success ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_XPERM:
		ret = sepol_require_not_all(args[3], "operation"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[4], "perm_set"); if (ret < 0) return ret;
		if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_ALLOW)
			success = ksu_allowxperm(db, args[0], args[1], args[2], args[4]);
		else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_AUDITALLOW)
			success = ksu_auditallowxperm(db, args[0], args[1], args[2], args[4]);
		else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_DONTAUDIT)
			success = ksu_dontauditxperm(db, args[0], args[1], args[2], args[4]);
		return success ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_TYPE_STATE:
		ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
		if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_PERMISSIVE)
			success = ksu_permissive(db, args[0]);
		else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_ENFORCE)
			success = ksu_enforce(db, args[0]);
		return success ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_TYPE:
	case KSU_SEPOLICY_CMD_TYPE_ATTR:
		ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[1], "attribute"); if (ret < 0) return ret;
		if (header->cmd == KSU_SEPOLICY_CMD_TYPE)
			success = ksu_type(db, args[0], args[1]);
		else
			success = ksu_typeattribute(db, args[0], args[1]);
		return success ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_ATTR:
		ret = sepol_require_not_all(args[0], "attribute"); if (ret < 0) return ret;
		return ksu_attribute(db, args[0]) ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_TYPE_TRANSITION: {
		ret = sepol_require_not_all(args[0], "src"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[1], "tgt"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[2], "cls"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[3], "default_type"); if (ret < 0) return ret;
		success = ksu_type_transition(db, args[0], args[1], args[2], args[3], args[4]);
		return success ? 0 : -EINVAL;
	}
	case KSU_SEPOLICY_CMD_TYPE_CHANGE:
		ret = sepol_require_not_all(args[0], "src"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[1], "tgt"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[2], "cls"); if (ret < 0) return ret;
		ret = sepol_require_not_all(args[3], "default_type"); if (ret < 0) return ret;
		if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_CHANGE)
			success = ksu_type_change(db, args[0], args[1], args[2], args[3]);
		else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_MEMBER)
			success = ksu_type_member(db, args[0], args[1], args[2], args[3]);
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

int handle_sepolicy(void __user *user_data, u64 data_len)
{
	struct selinux_policy *pol, *old_pol;
	struct policydb *db;
	struct sepol_batch_cursor cursor;
	u8 *payload;
	int ret, success_cmd_count;
	u32 cmd_index;

	if (!user_data || !data_len) return -EINVAL;
	if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) return -E2BIG;
	payload = kvmalloc((size_t)data_len, GFP_KERNEL);
	if (!payload) return -ENOMEM;
	if (copy_from_user(payload, user_data, (size_t)data_len)) {
		ret = -EFAULT; goto out_free;
	}
	mutex_lock(&selinux_state.policy_mutex);
	old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
	pol = ksu_dup_sepolicy(old_pol);
	if (IS_ERR(pol)) { ret = PTR_ERR(pol); goto out_unlock; }
	db = &pol->policydb;
	cursor.cur = payload;
	cursor.end = payload + (size_t)data_len;
	ret = 0; success_cmd_count = 0; cmd_index = 0;
	while (cursor.cur < cursor.end) {
		struct sepol_data header;
		const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
		int expected_argc; u32 arg_index;
		ret = sepol_read_cmd_header(&cursor, &header);
		if (ret < 0) goto out_drop_new_policy;
		expected_argc = sepol_expected_argc(header.cmd);
		if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) {
			ret = -EINVAL; goto out_drop_new_policy;
		}
		for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
			ret = sepol_read_string(&cursor, &args[arg_index]);
			if (ret < 0) goto out_drop_new_policy;
		}
		ret = apply_one_sepolicy_cmd(db, &header, args);
		if (ret >= 0) success_cmd_count++;
		cmd_index++;
	}
	pol->latest_granting = old_pol->latest_granting + 1;
	ksu_advance_original_types(db, &old_pol->policydb, old_pol->latest_granting, pol->latest_granting);
	rcu_assign_pointer(selinux_state.policy, pol);
	synchronize_rcu();
	ksu_destroy_sepolicy(old_pol);
	reset_avc_cache(pol->latest_granting);
#ifdef CONFIG_KSU_SUSFS
	susfs_set_batch_sid();
#endif
	ret = success_cmd_count;
	goto out_unlock;
out_drop_new_policy:
	ksu_destroy_sepolicy(pol);
out_unlock:
	mutex_unlock(&selinux_state.policy_mutex);
out_free:
	kvfree(payload);
	return ret;
}
#endif /* < 5.10 */
RULESEOF
echo "  ✅ rules.c dual-path installé"

# --- 4b.2 + 4b.3 : selinux_hide, sepolicy, file_wrapper, non-SELinux ---
python3 - "$KSU_DIR" <<'PORTEOF' 2>&1 | tee -a "$AUDIT"
import os, re, sys

root = sys.argv[1]
total = 0

def read(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read()

def write(path, content, old):
    global total
    if content != old:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        total += 1
        print(f"  ✅ {os.path.relpath(path, root)}")
        return True
    return False

def ensure_include(c, inc):
    if inc in c:
        return c
    last = 0
    for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
        last = m.end()
    if last:
        return c[:last] + f'#include {inc}\n' + c[last:]
    return f'#include {inc}\n' + c

def ensure_version_h(c):
    if 'linux/version.h' in c:
        return c
    return ensure_include(c, '<linux/version.h>')

# ----- selinux_hide -----
hide_path = os.path.join(root, "feature", "selinux_hide.c")
if os.path.isfile(hide_path):
    c = read(hide_path)
    o = c
    if "KSU_SELINUX_HIDE_DISABLED_ON_OLD_KERNEL" not in c:
        header = (
            "/* Auto-portage 4.19 */\n"
            "#include <linux/version.h>\n"
            "#include <linux/types.h>\n"
            "#include <linux/errno.h>\n"
            "#define KSU_SELINUX_HIDE_DISABLED_ON_OLD_KERNEL 1\n"
            "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n"
            "bool ksu_selinux_hide_enabled = false;\n"
            "bool ksu_selinux_hide_running = false;\n"
            "int ksu_selinux_hide_enable(void) { return -EOPNOTSUPP; }\n"
            "void ksu_selinux_hide_unhook(void) {}\n"
            "void initialize_fake_status(void) {}\n"
            "#else\n"
        )
        c = re.sub(r'#include\s*[<"]linux/version\.h[>"]\s*\n', '', c)
        c = header + c + "\n#endif\n"
        write(hide_path, c, o)

# ----- sepolicy add_filename_trans guard -----
sepolicy_path = os.path.join(root, "selinux", "sepolicy.c")
if os.path.isfile(sepolicy_path):
    c = read(sepolicy_path)
    o = c
    if "KSU_FILENAME_TRANS_GUARD" not in c:
        c = ensure_version_h(c)
        pattern = r'(static\s+bool\s+add_filename_trans\s*\([^)]*\)\s*\{)'
        if re.search(pattern, c):
            c = re.sub(pattern,
                r'#define KSU_FILENAME_TRANS_GUARD 1\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)\n\1',
                c, count=1)
            c = re.sub(
                r'(#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5, 8, 0\)\nstatic bool add_filename_trans[\s\S]*?\n\})',
                r'\1\n#else\nstatic bool add_filename_trans(struct policydb *db, const char *s, const char *t,\n'
                r'                               const char *cls, const char *d, const char *o)\n{ return true; }\n#endif',
                c, count=1)
        write(sepolicy_path, c, o)

# ----- file_wrapper -----
def find_matching(c, i, open_ch, close_ch):
    depth = 0
    for k in range(i, len(c)):
        if c[k] == open_ch: depth += 1
        elif c[k] == close_ch:
            depth -= 1
            if depth == 0: return k
    return -1

def wrap_function(c, name, cond):
    for m in re.finditer(r'\b' + re.escape(name) + r'\s*\(', c):
        po = m.end() - 1
        pc = find_matching(c, po, '(', ')')
        if pc < 0: continue
        j = pc + 1
        while j < len(c) and c[j] in ' \t\r\n': j += 1
        if j >= len(c) or c[j] != '{': continue
        end = find_matching(c, j, '{', '}')
        if end < 0: continue
        start = c.rfind('\n', 0, m.start()) + 1
        while start > 0:
            prev = c.rfind('\n', 0, start - 1) + 1
            line = c[prev:start - 1].strip()
            if line == '' or line.endswith(';') or line.endswith('}') or line.startswith('#'):
                break
            start = prev
        return c[:start] + f"#if {cond}\n" + c[start:end+1] + "\n#endif\n" + c[end+1:], True
    return c, False

path = os.path.join(root, 'infra/file_wrapper.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    c = ensure_version_h(c)
    V51 = 'LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)'
    V420 = 'LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)'
    c, _ = wrap_function(c, 'ksu_wrapper_iopoll', V51)
    c, _ = wrap_function(c, 'ksu_wrapper_remap_file_range', V420)
    lines = c.split('\n')
    out = []
    for line in lines:
        if re.search(r'\.iopoll\s*=', line) and '#if' not in (out[-1] if out else ''):
            out.append(f'#if {V51}')
            out.append(line)
            out.append('#endif')
        elif re.search(r'\.remap_file_range\s*=', line) and '#if' not in (out[-1] if out else ''):
            out.append(f'#if {V420}')
            out.append(line)
            out.append('#endif')
        else:
            out.append(line)
    c = '\n'.join(out)
    write(path, c, o)

# ----- TWA_RESUME -----
TWA = '''
#ifndef TWA_RESUME
#define TWA_RESUME 0
#endif
'''
for rel in ['manager/pkg_observer.c', 'manager/dynamic_manager.c', 'policy/allowlist.c', 'supercall/supercall.c']:
    path = os.path.join(root, rel)
    if not os.path.isfile(path): continue
    c = read(path)
    o = c
    if 'TWA_RESUME' in c and 'TWA_RESUME 0' not in c:
        c = ensure_version_h(c)
        last = 0
        for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
            last = m.end()
        c = c[:last] + TWA + c[last:]
        write(path, c, o)

# ----- SECCOMP_ARCH_NATIVE_NR -----
path = os.path.join(root, 'infra/seccomp_cache.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    if 'SECCOMP_ARCH_NATIVE_NR' in c and 'KSU_SECCOMP_COMPAT' not in c:
        c = ensure_version_h(c)
        stub = '''
#ifndef KSU_SECCOMP_COMPAT
#define KSU_SECCOMP_COMPAT 1
#ifndef SECCOMP_ARCH_NATIVE_NR
#ifdef CONFIG_COMPAT
#define SECCOMP_ARCH_NATIVE_NR 2
#else
#define SECCOMP_ARCH_NATIVE_NR 1
#endif
#endif
#endif
'''
        last = 0
        for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
            last = m.end()
        c = c[:last] + stub + c[last:]
        write(path, c, o)

# ----- filter_count -----
path = os.path.join(root, 'policy/app_profile.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    if 'filter_count' in c and 'KSU_FILTER_COUNT_COMPAT' not in c:
        c = ensure_version_h(c)
        lines = c.split('\n')
        out = []
        for line in lines:
            if 'filter_count' in line and not line.strip().startswith(('/', '#')):
                out.append('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)')
                out.append(line)
                out.append('#else')
                if 'return' in line:
                    out.append('\treturn 0;')
                else:
                    out.append('\t/* filter_count unavailable */')
                out.append('#endif')
            else:
                out.append(line)
        c = '\n'.join(out)
        c = c.replace('#include <linux/version.h>', '#include <linux/version.h>\n#define KSU_FILTER_COUNT_COMPAT 1', 1)
        write(path, c, o)

# ----- put_task_struct -----
path = os.path.join(root, 'manager/dynamic_manager.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    if 'put_task_struct' in c:
        c = ensure_include(c, '<linux/sched.h>')
        c = ensure_include(c, '<linux/sched/task.h>')
        write(path, c, o)

# ----- tasklist_lock / init_task -----
path = os.path.join(root, 'supercall/dispatch.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    c = ensure_version_h(c)
    c = ensure_include(c, '<linux/sched.h>')
    c = ensure_include(c, '<linux/sched/signal.h>')
    c = ensure_include(c, '<linux/sched/task.h>')
    if 'tasklist_lock' in c and 'KSU_TASKLIST_COMPAT' not in c:
        compat = '''
#ifndef KSU_TASKLIST_COMPAT
#define KSU_TASKLIST_COMPAT 1
extern rwlock_t tasklist_lock;
extern struct task_struct init_task;
#endif
'''
        last = 0
        for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
            last = m.end()
        c = c[:last] + compat + c[last:]
        write(path, c, o)

# ----- minmax.h -----
path = os.path.join(root, 'sulog/event.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    if 'linux/minmax.h' in c:
        c = c.replace('#include <linux/minmax.h>',
            '''#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#include <linux/minmax.h>
#else
#include <linux/kernel.h>
#endif''')
        write(path, c, o)

# ----- uapi/linux/mount.h -----
path = os.path.join(root, 'infra/su_mount_ns.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    if 'uapi/linux/mount.h' in c:
        c = c.replace('#include <uapi/linux/mount.h>',
            '''#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
#include <uapi/linux/mount.h>
#else
#include <linux/mount.h>
#endif''')
        write(path, c, o)

# ----- fsnotify handle_inode_event -----
path = os.path.join(root, 'manager/pkg_observer.c')
if os.path.isfile(path):
    c = read(path)
    o = c
    c = ensure_version_h(c)
    if 'handle_inode_event' in c and 'KSU_FSNOTIFY_COMPAT' not in c:
        lines = c.split('\n')
        out = []
        for line in lines:
            if 'handle_inode_event' in line and not line.strip().startswith(('/', '#')):
                out.append('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)')
                out.append(line)
                out.append('#else')
                out.append(line.replace('handle_inode_event', 'handle_event'))
                out.append('#endif')
            else:
                out.append(line)
        c = '\n'.join(out)
        c = c.replace('#include <linux/version.h>', '#include <linux/version.h>\n#define KSU_FSNOTIFY_COMPAT 1', 1)
        write(path, c, o)

# MODULE_IMPORT_NS
for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith(('.c', '.h')): continue
        p = os.path.join(dp, f)
        try:
            c = read(p)
        except:
            continue
        o = c
        c2 = re.sub(r'^([ \t]*MODULE_IMPORT_NS\([^\n]*\);[ \t]*)$',
                    r'#ifdef MODULE_IMPORT_NS\n\1\n#endif', c, flags=re.M)
        if c2 != o:
            write(p, c2, o)

print(f"  ✅ portage complémentaire + non-SELinux : {total} fichier(s)")
PORTEOF

# ==================== 5. CONFIGURATION ====================
echo ""
echo "=== Configuration ==="
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

CLANG_MAJOR=$(clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)
echo "clang version majeure : ${CLANG_MAJOR:-inconnue}" | tee -a "$AUDIT"
CC_ARGS=""
if [ "\( {FORCE_CLANG_WRAP:-1}" = "1" ] || [ " \){CLANG_MAJOR:-99}" -lt 16 ]; then
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
    echo "⚠️ clang < 16 : wrapper actif" | tee -a "$AUDIT"
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
    for o in KSU KSU_HOOK_TRACEPOINT KPROBES KALLSYMS_ALL EXT4_FS THREAD_INFO_IN_TASK FTRACE_SYSCALLS HAVE_SYSCALL_TRACEPOINTS; do
        if grep -q "^CONFIG_\( {o}=y" out/.config; then echo "  ✅ CONFIG_ \){o}"; else echo "  ℹ️ CONFIG_${o} absent"; fi
    done
} 2>&1 | tee -a "$AUDIT"

grep -q "^CONFIG_KSU=y" out/.config || { echo "❌ CONFIG_KSU non activé"; exit 1; }

# ==================== 6. PATCHS MOTOROLA ====================
echo "=== Patch Motorola ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION ====================
echo "=== Compilation du kernel ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" $SIG_ARGS \
  -k -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    {
        echo "=== ERREURS ==="
        grep -nE "error:|undefined symbol|undefined reference|fatal error:|\*\*\*" build.log | head -150 || true
        echo ""
        echo "=== 150 DERNIÈRES LIGNES ==="
        tail -n 150 build.log
    } > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅ Compilation réussie"
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
cp out/arch/arm64/boot/Image "\( GITHUB_WORKSPACE/output/Image- \){VER}"
cp out/System.map "\( GITHUB_WORKSPACE/output/System.map- \){VER}"

# ==================== 8. KSUD ====================
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"
if [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"
    KSUD_ROOT="$KSU_REPO_ROOT"
else
    git clone --depth=1 --branch "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksud-src"
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
    KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
fi
[ -f "$KSUD_DIR/Cargo.toml" ] || { echo "❌ ksud Cargo.toml introuvable"; exit 1; }

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
KSUD_BINARY=$(find "$KSUD_ROOT" -type f -path "*aarch64-linux-android/release/ksud" 2>/dev/null | head -1 || true)
[ -n "$KSUD_BINARY" ] || { echo "❌ ksud introuvable"; exit 1; }
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK ====================
echo "=== Repack ==="
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 || true
[ -f boot-stock.img ] && [ "$(stat -c%s boot-stock.img)" -gt 50000000 ] || { echo "❌ boot-stock.img invalide"; exit 1; }
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib

cd repack
set +e; ./magiskboot unpack boot.img; set -e
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary; chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10. DIAGNOSTIC ====================
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
[ -f kernel ] && [ "\( (sha256sum kernel | cut -d' ' -f1)" = " \)(cat /tmp/kernel_compiled_hash.txt)" ] && echo "✅ Noyau IDENTIQUE"
../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null && echo "  ✅ ksud présent" || echo "  ❌ ksud absent"
cd ..

# ==================== 11. SORTIE ====================
cp final_boot.img "output/FinaSU-A-${VER}-boot.img"
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ ${VER} ==="
ls -lh output/
