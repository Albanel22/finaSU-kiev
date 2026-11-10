#!/bin/bash
set -euo pipefail

# =============================================================================
# FinaSU (LyraVoid) — noyau 4.19 — ÉTAPE A (Tracepoint, sans SuSFS)
# Script global corrigé ($ variables intacts)
# =============================================================================

export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

FINASU_URL="${FINASU_URL:-https://github.com/LyraVoid/FinaSU.git}"
FINASU_REF="${FINASU_REF:-v1.5.0}"
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"
FINASU_EXPECTED_SIZE="${FINASU_EXPECTED_SIZE:-}"
FINASU_EXPECTED_HASH="${FINASU_EXPECTED_HASH:-}"
MGR_GDRIVE_ID="${MGR_GDRIVE_ID:-1Qr07fjThXjmIz_DAmW2GZepoWrNIikXR}"
VER="finasu-A"
KSU_REF="$FINASU_REF"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"

echo "=== Build FinaSU ($FINASU_REF) — étape A ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

mkdir -p "$GITHUB_WORKSPACE/output"
AUDIT="\( GITHUB_WORKSPACE/output/audit- \){VER}.txt"
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
    if u: undefined[u.group(1)] += 1
    t = re.search(r'\*\*\* \[[^\]]*?:(\d+): ([^\]]+)\] Error', l)
    if t and t.group(2) not in targets: targets.append(t.group(2))
print(f"erreurs : {total}   fichiers touchés : {len(per_file)}   messages distincts : {len(per_msg)}")
print("\n-- Erreurs par fichier (haut de liste) --")
for f, n in per_file.most_common(25): print(f"{n:4d}  {f}")
print("\n-- Types d'erreurs (compte, premier emplacement) --")
for k, n in per_msg.most_common(25): print(f"{n:4d}  {k}   [{first_loc[k]}]")
print("\n-- Première erreur de chaque fichier --")
for f, v in list(first_msg.items())[:40]: print(f"{f}:{v}"[:170])
if undefined:
    print("\n-- Symboles non définis --")
    for k, n in undefined.most_common(30): print(f"{n:4d}  {k}")
if targets:
    print("\n-- Cibles make en échec --")
    for t in targets[:20]: print("   " + t)
SUMEOF
        else
            echo "pas de build.log"
        fi
        echo ""
        echo "=== 20 DERNIÈRES LIGNES DE L'AUDIT ==="
        tail -n 20 "$AUDIT" 2>/dev/null
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
KERNEL_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
git clone --filter=blob:none --no-checkout -b lineage-23.2 "$KERNEL_URL" kernel_sources
cd kernel_sources
if ! git checkout -q "$KERNEL_PIN" 2>/dev/null; then
    git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
    git checkout -q "$KERNEL_PIN" || { echo "❌ commit $KERNEL_PIN introuvable"; exit 1; }
fi
echo "Source figée : \( KERNEL_PIN ( \)(git rev-parse HEAD))" | tee -a "$AUDIT"

# ==================== 2. INTÉGRATION FinaSU ====================
echo "=== Intégration FinaSU ($FINASU_REF) ==="
rm -rf drivers/kernelsu FinaSU 2>/dev/null || true
git clone "$FINASU_URL" FinaSU
git -C FinaSU checkout "$FINASU_REF"
echo "FinaSU : $(git -C FinaSU describe --tags --always)" | tee -a "$AUDIT"

if [ -f FinaSU/kernel/setup.sh ]; then
    bash FinaSU/kernel/setup.sh --dir "$PWD/FinaSU" || true
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

# ==================== 3. MANAGER APK + SIGNATURE ====================
mkdir -p "$GITHUB_WORKSPACE/patches"
if [ ! -f "$GITHUB_WORKSPACE/patches/manager.apk" ] && [ -n "$MGR_GDRIVE_ID" ]; then
    echo "=== Téléchargement manager.apk (GDrive) ==="
    gdown "https://drive.google.com/uc?id=${MGR_GDRIVE_ID}" \
        -O "$GITHUB_WORKSPACE/patches/manager.apk" 2>&1 | tee -a "$AUDIT" || true
fi

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
    [ -n "\( SIG_OUT" ] && FINASU_EXPECTED_SIZE= \)(echo "\( SIG_OUT" | sed -n '1p') && FINASU_EXPECTED_HASH= \)(echo "$SIG_OUT" | sed -n '2p')
fi
SIG_ARGS=""
if [ -n "$FINASU_EXPECTED_SIZE" ] && [ -n "$FINASU_EXPECTED_HASH" ]; then
    SIG_ARGS="KSU_EXPECTED_SIZE=$FINASU_EXPECTED_SIZE KSU_EXPECTED_HASH=$FINASU_EXPECTED_HASH"
    echo "Signature manager : $FINASU_EXPECTED_SIZE / $FINASU_EXPECTED_HASH" | tee -a "$AUDIT"
else
    echo "⚠️ AUCUNE signature de manager fournie" | tee -a "$AUDIT"
fi

# ==================== 3g/3h EXPORTS + O_CLOEXEC ====================
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

# ==================== 4b. PORTAGE 4.19 ====================
echo "=== Portage 4.19 ==="

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
struct selinux_policy *backup_sepolicy = NULL;
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
extern int avc_ss_reset(u32 seqno);
#else
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
#endif
static void reset_avc_cache(u32 seqno)
{
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
	avc_ss_reset(seqno); selnl_notify_policyload(seqno);
#else
	struct selinux_avc *avc = selinux_state.avc;
	if (avc) avc_ss_reset(avc, seqno);
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
#else
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
	avc_ss_reset(seqno); selnl_notify_policyload(seqno); selinux_status_update_policyload(seqno);
#else
	struct selinux_avc *avc = selinux_state.avc;
	avc_ss_reset(avc, seqno); selnl_notify_policyload(seqno);
	selinux_status_update_policyload(&selinux_state, seqno);
#endif
	selinux_xfrm_notify_policyload();
}
void apply_kernelsu_rules(void)
{
	struct selinux_policy *pol, *old_pol;
	struct policydb *db;
	if (!getenforce()) pr_info("SELinux permissive or disabled, apply rules!\n");
	mutex_lock(&selinux_state.policy_mutex);
	old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
	backup_sepolicy = ksu_dup_sepolicy(old_pol);
	if (IS_ERR(backup_sepolicy)) backup_sepolicy = NULL;
	else {
		backup_sepolicy->sidtab = kzalloc(sizeof(*backup_sepolicy->sidtab), GFP_KERNEL);
		if (!backup_sepolicy->sidtab) { ksu_destroy_sepolicy(backup_sepolicy); backup_sepolicy = NULL; }
		else if (policydb_load_isids(&backup_sepolicy->policydb, backup_sepolicy->sidtab)) {
			kfree(backup_sepolicy->sidtab); ksu_destroy_sepolicy(backup_sepolicy); backup_sepolicy = NULL;
		}
	}
	pol = ksu_dup_sepolicy(old_pol);
	if (IS_ERR(pol)) goto out_unlock;
	db = &pol->policydb;
	pol->latest_granting = old_pol->latest_granting + 1;
	ksu_set_original_types(db, &old_pol->policydb, pol->latest_granting);
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
static size_t sepol_remaining(const struct sepol_batch_cursor *c) { return (size_t)(c->end - c->cur); }
static int sepol_read_cmd_header(struct sepol_batch_cursor *c, struct sepol_data *h)
{
	if (sepol_remaining(c) < sizeof(*h)) return -EINVAL;
	memcpy(h, c->cur, sizeof(*h)); c->cur += sizeof(*h); return 0;
}
static int sepol_read_string(struct sepol_batch_cursor *c, const char **out)
{
	u32 len; const char *str;
	if (sepol_remaining(c) < sizeof(len)) return -EINVAL;
	memcpy(&len, c->cur, sizeof(len)); c->cur += sizeof(len);
	if (len >= sepol_remaining(c)) return -EINVAL;
	str = (const char *)c->cur;
	if (memchr(str, '\0', len) || str[len] != '\0') return -EINVAL;
	c->cur += len + 1;
	*out = (len == 0) ? ALL : str;
	return 0;
}
static int sepol_require_not_all(const char *v, const char *n)
{ if (v != ALL) return 0; pr_err("sepol: %s cannot be ALL.\n", n); return -EINVAL; }
static int sepol_expected_argc(u32 cmd)
{
	switch (cmd) {
	case KSU_SEPOLICY_CMD_NORMAL_PERM: return 4;
	case KSU_SEPOLICY_CMD_XPERM: return 5;
	case KSU_SEPOLICY_CMD_TYPE_STATE: return 1;
	case KSU_SEPOLICY_CMD_TYPE: case KSU_SEPOLICY_CMD_TYPE_ATTR: return 2;
	case KSU_SEPOLICY_CMD_ATTR: return 1;
	case KSU_SEPOLICY_CMD_TYPE_TRANSITION: return 5;
	case KSU_SEPOLICY_CMD_TYPE_CHANGE: return 4;
	case KSU_SEPOLICY_CMD_GENFSCON: return 3;
	default: return -EINVAL;
	}
}
static int apply_one_sepolicy_cmd(struct policydb *db, const struct sepol_data *h, const char **a)
{
	bool ok = false; int r;
	switch (h->cmd) {
	case KSU_SEPOLICY_CMD_NORMAL_PERM:
		if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW) ok = ksu_allow(db, a[0], a[1], a[2], a[3]);
		else if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DENY) ok = ksu_deny(db, a[0], a[1], a[2], a[3]);
		else if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_AUDITALLOW) ok = ksu_auditallow(db, a[0], a[1], a[2], a[3]);
		else if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DONTAUDIT) ok = ksu_dontaudit(db, a[0], a[1], a[2], a[3]);
		return ok ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_XPERM:
		if ((r = sepol_require_not_all(a[3], "op")) < 0 || (r = sepol_require_not_all(a[4], "perm")) < 0) return r;
		if (h->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_ALLOW) ok = ksu_allowxperm(db, a[0], a[1], a[2], a[4]);
		else if (h->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_AUDITALLOW) ok = ksu_auditallowxperm(db, a[0], a[1], a[2], a[4]);
		else if (h->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_DONTAUDIT) ok = ksu_dontauditxperm(db, a[0], a[1], a[2], a[4]);
		return ok ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_TYPE_STATE:
		if ((r = sepol_require_not_all(a[0], "type")) < 0) return r;
		if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_PERMISSIVE) ok = ksu_permissive(db, a[0]);
		else if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_ENFORCE) ok = ksu_enforce(db, a[0]);
		return ok ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_TYPE: case KSU_SEPOLICY_CMD_TYPE_ATTR:
		if ((r = sepol_require_not_all(a[0], "type")) < 0 || (r = sepol_require_not_all(a[1], "attr")) < 0) return r;
		ok = (h->cmd == KSU_SEPOLICY_CMD_TYPE) ? ksu_type(db, a[0], a[1]) : ksu_typeattribute(db, a[0], a[1]);
		return ok ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_ATTR:
		if ((r = sepol_require_not_all(a[0], "attr")) < 0) return r;
		return ksu_attribute(db, a[0]) ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_TYPE_TRANSITION:
		if ((r = sepol_require_not_all(a[0], "src")) < 0 || (r = sepol_require_not_all(a[1], "tgt")) < 0 ||
		    (r = sepol_require_not_all(a[2], "cls")) < 0 || (r = sepol_require_not_all(a[3], "def")) < 0) return r;
		return ksu_type_transition(db, a[0], a[1], a[2], a[3], a[4]) ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_TYPE_CHANGE:
		if ((r = sepol_require_not_all(a[0], "src")) < 0 || (r = sepol_require_not_all(a[1], "tgt")) < 0 ||
		    (r = sepol_require_not_all(a[2], "cls")) < 0 || (r = sepol_require_not_all(a[3], "def")) < 0) return r;
		if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_CHANGE) ok = ksu_type_change(db, a[0], a[1], a[2], a[3]);
		else if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_MEMBER) ok = ksu_type_member(db, a[0], a[1], a[2], a[3]);
		return ok ? 0 : -EINVAL;
	case KSU_SEPOLICY_CMD_GENFSCON:
		if ((r = sepol_require_not_all(a[0], "name")) < 0 || (r = sepol_require_not_all(a[1], "path")) < 0 ||
		    (r = sepol_require_not_all(a[2], "ctx")) < 0) return r;
		return ksu_genfscon(db, a[0], a[1], a[2]) ? 0 : -EINVAL;
	default: return -EINVAL;
	}
}
int handle_sepolicy(void __user *user_data, u64 data_len)
{
	struct selinux_policy *pol, *old_pol; struct policydb *db;
	struct sepol_batch_cursor cur; u8 *payload; int ret, okc;
	if (!user_data || !data_len) return -EINVAL;
	if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) return -E2BIG;
	payload = kvmalloc((size_t)data_len, GFP_KERNEL);
	if (!payload) return -ENOMEM;
	if (copy_from_user(payload, user_data, (size_t)data_len)) { ret = -EFAULT; goto out_free; }
	mutex_lock(&selinux_state.policy_mutex);
	old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
	pol = ksu_dup_sepolicy(old_pol);
	if (IS_ERR(pol)) { ret = PTR_ERR(pol); goto out_unlock; }
	db = &pol->policydb;
	cur.cur = payload; cur.end = payload + (size_t)data_len;
	ret = 0; okc = 0;
	while (cur.cur < cur.end) {
		struct sepol_data h; const char *args[KSU_SEPOLICY_MAX_ARGS] = {0};
		int argc; u32 i;
		if ((ret = sepol_read_cmd_header(&cur, &h)) < 0) goto drop;
		argc = sepol_expected_argc(h.cmd);
		if (argc < 0 || argc > KSU_SEPOLICY_MAX_ARGS) { ret = -EINVAL; goto drop; }
		for (i = 0; i < (u32)argc; i++)
			if ((ret = sepol_read_string(&cur, &args[i])) < 0) goto drop;
		if (apply_one_sepolicy_cmd(db, &h, args) >= 0) okc++;
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
	ret = okc; goto out_unlock;
drop:	ksu_destroy_sepolicy(pol);
out_unlock: mutex_unlock(&selinux_state.policy_mutex);
out_free: kvfree(payload); return ret;
}
#endif
RULESEOF
echo "  ✅ rules.c dual-path"

python3 - "$KSU_DIR" <<'PORTEOF' 2>&1 | tee -a "$AUDIT"
import os, re, sys

root = sys.argv[1]
total = 0

def read(p):
    with open(p, encoding='utf-8', errors='replace') as f:
        return f.read()

def write(p, c, o):
    global total
    if c != o:
        open(p, 'w', encoding='utf-8').write(c)
        total += 1
        print(f"  ✅ {os.path.relpath(p, root)}")

def ensure_inc(c, inc):
    if inc in c:
        return c
    last = 0
    for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
        last = m.end()
    return (c[:last] + f'#include {inc}\n' + c[last:]) if last else f'#include {inc}\n' + c

def ensure_ver(c):
    return c if 'linux/version.h' in c else ensure_inc(c, '<linux/version.h>')

p = os.path.join(root, "feature/selinux_hide.c")
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    if "KSU_SELINUX_HIDE_DISABLED_ON_OLD_KERNEL" not in c:
        h = (
            "#include <linux/version.h>\n#include <linux/types.h>\n#include <linux/errno.h>\n"
            "#define KSU_SELINUX_HIDE_DISABLED_ON_OLD_KERNEL 1\n"
            "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n"
            "bool ksu_selinux_hide_enabled = false;\nbool ksu_selinux_hide_running = false;\n"
            "int ksu_selinux_hide_enable(void) { return -EOPNOTSUPP; }\n"
            "void ksu_selinux_hide_unhook(void) {}\nvoid initialize_fake_status(void) {}\n#else\n"
        )
        c = re.sub(r'#include\s*[<"]linux/version\.h[>"]\s*\n', '', c)
        c = h + c + "\n#endif\n"
        write(p, c, o)

p = os.path.join(root, "selinux/sepolicy.c")
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    if "KSU_FILENAME_TRANS_GUARD" not in c:
        c = ensure_ver(c)
        pat = r'(static\s+bool\s+add_filename_trans\s*\([^)]*\)\s*\{)'
        if re.search(pat, c):
            c = re.sub(pat, r'#define KSU_FILENAME_TRANS_GUARD 1\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)\n\1', c, count=1)
            c = re.sub(
                r'(#if LINUX_VERSION_CODE >= KERNEL_VERSION\(5, 8, 0\)\nstatic bool add_filename_trans[\s\S]*?\n\})',
                r'\1\n#else\nstatic bool add_filename_trans(struct policydb *db, const char *s, const char *t,\n'
                r' const char *cls, const char *d, const char *o) { return true; }\n#endif',
                c, count=1,
            )
        write(p, c, o)

p = os.path.join(root, "infra/file_wrapper.c")
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    c = re.sub(
        r'#if\s+LINUX_VERSION_CODE\s*>=\s*KERNEL_VERSION\(\s*5\s*,\s*1\s*,\s*0\s*\)\s*\n(.*?\n)#endif\s*\n',
        r'\1', c,
    )
    c = re.sub(
        r'#if\s+LINUX_VERSION_CODE\s*>=\s*KERNEL_VERSION\(\s*4\s*,\s*20\s*,\s*0\s*\)\s*\n(.*?\n)#endif\s*\n',
        r'\1', c,
    )
    c = ensure_ver(c)
    if 'REMAP_FILE_DEDUP' in c and 'KSU_REMAP_FILE_DEDUP_COMPAT' not in c:
        last = 0
        for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
            last = m.end()
        c = c[:last] + (
            '\n#ifndef KSU_REMAP_FILE_DEDUP_COMPAT\n#define KSU_REMAP_FILE_DEDUP_COMPAT 1\n'
            '#ifndef REMAP_FILE_DEDUP\n#define REMAP_FILE_DEDUP 0\n#endif\n#endif\n'
        ) + c[last:]

    def guard_lines_containing(text, pattern, cond):
        out = []
        for line in text.split('\n'):
            prev = out[-1] if out else ''
            if re.search(pattern, line) and not line.lstrip().startswith(('#', '//')):
                if '#if' not in prev:
                    out.append(f'#if {cond}')
                    out.append(line)
                    out.append('#endif')
                else:
                    out.append(line)
            else:
                out.append(line)
        return '\n'.join(out)

    c = guard_lines_containing(c, r'(\.iopoll\b|->iopoll\b)', 'LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)')
    c = guard_lines_containing(c, r'(\.remap_file_range\b|->remap_file_range\b)', 'LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)')
    write(p, c, o)

TWA = '\n#ifndef TWA_RESUME\n#define TWA_RESUME 0\n#endif\n'
for rel in ['manager/pkg_observer.c', 'manager/dynamic_manager.c', 'policy/allowlist.c', 'supercall/supercall.c']:
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        continue
    c, o = read(p), None
    o = c
    if 'TWA_RESUME' in c and 'TWA_RESUME 0' not in c:
        c = ensure_ver(c)
        last = 0
        for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
            last = m.end()
        c = c[:last] + TWA + c[last:]
        write(p, c, o)

p = os.path.join(root, 'infra/seccomp_cache.c')
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    if 'SECCOMP_ARCH_NATIVE_NR' in c and 'KSU_SECCOMP_COMPAT' not in c:
        c = ensure_ver(c)
        last = 0
        for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
            last = m.end()
        c = c[:last] + (
            '\n#ifndef KSU_SECCOMP_COMPAT\n#define KSU_SECCOMP_COMPAT 1\n#ifndef SECCOMP_ARCH_NATIVE_NR\n'
            '#ifdef CONFIG_COMPAT\n#define SECCOMP_ARCH_NATIVE_NR 2\n#else\n#define SECCOMP_ARCH_NATIVE_NR 1\n'
            '#endif\n#endif\n#endif\n'
        ) + c[last:]
        write(p, c, o)

p = os.path.join(root, 'policy/app_profile.c')
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    if 'filter_count' in c and 'KSU_FILTER_COUNT_COMPAT' not in c:
        c = ensure_ver(c)
        out = []
        for line in c.split('\n'):
            if 'filter_count' in line and not line.strip().startswith(('/', '#')):
                out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)', line, '#else',
                        '\treturn 0;' if 'return' in line else '\t/* no filter_count */', '#endif']
            else:
                out.append(line)
        c = '\n'.join(out).replace('#include <linux/version.h>', '#include <linux/version.h>\n#define KSU_FILTER_COUNT_COMPAT 1', 1)
        write(p, c, o)

for rel in ['manager/dynamic_manager.c', 'policy/allowlist.c']:
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        continue
    c, o = read(p), None
    o = c
    if 'put_task_struct' in c:
        c = ensure_inc(c, '<linux/sched.h>')
        c = ensure_inc(c, '<linux/sched/task.h>')
        write(p, c, o)

p = os.path.join(root, 'supercall/dispatch.c')
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    c = ensure_ver(c)
    c = ensure_inc(c, '<linux/sched.h>')
    c = ensure_inc(c, '<linux/sched/signal.h>')
    c = ensure_inc(c, '<linux/sched/task.h>')
    if 'tasklist_lock' in c and 'KSU_TASKLIST_COMPAT' not in c:
        last = 0
        for m in re.finditer(r'#include\s+[<"].*?[>"]\s*\n', c):
            last = m.end()
        c = c[:last] + (
            '\n#ifndef KSU_TASKLIST_COMPAT\n#define KSU_TASKLIST_COMPAT 1\n'
            'extern rwlock_t tasklist_lock;\nextern struct task_struct init_task;\n#endif\n'
        ) + c[last:]
        write(p, c, o)

p = os.path.join(root, 'sulog/event.c')
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    if 'linux/minmax.h' in c:
        c = c.replace('#include <linux/minmax.h>',
            '#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
            '#include <linux/minmax.h>\n#else\n#include <linux/kernel.h>\n#endif')
        write(p, c, o)

p = os.path.join(root, 'infra/su_mount_ns.c')
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    if 'uapi/linux/mount.h' in c:
        c = c.replace('#include <uapi/linux/mount.h>',
            '#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)\n'
            '#include <uapi/linux/mount.h>\n#else\n#include <linux/mount.h>\n#endif')
        write(p, c, o)

p = os.path.join(root, 'manager/pkg_observer.c')
if os.path.isfile(p):
    c, o = read(p), None
    o = c
    c = ensure_ver(c)
    if 'handle_inode_event' in c or 'handle_event' in c:
        out = []
        for line in c.split('\n'):
            if re.search(r'\.(handle_inode_event|handle_event)\s*=', line) and not line.strip().startswith('#'):
                out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)', line, '#endif']
            else:
                out.append(line)
        c = '\n'.join(out)
        if 'KSU_FSNOTIFY_COMPAT' not in c:
            c = c.replace('#include <linux/version.h>', '#include <linux/version.h>\n#define KSU_FSNOTIFY_COMPAT 1', 1)
        write(p, c, o)

for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith(('.c', '.h')):
            continue
        p = os.path.join(dp, f)
        try:
            c = read(p)
        except Exception:
            continue
        o = c
        c2 = re.sub(r'^([ \t]*MODULE_IMPORT_NS\([^\n]*\);[ \t]*)$', r'#ifdef MODULE_IMPORT_NS\n\1\n#endif', c, flags=re.M)
        if c2 != o:
            write(p, c2, o)

print(f"  ✅ portage unifié : {total} fichier(s)")
PORTEOF

# ==================== 5. CONFIG ====================
echo "=== Configuration ==="
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
CLANG_MAJOR=$(clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)
CC_ARGS=""
if [ "\( {FORCE_CLANG_WRAP:-1}" = "1" ] || [ " \){CLANG_MAJOR:-99}" -lt 16 ]; then
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
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3
grep -q "^CONFIG_KSU=y" out/.config || { echo "❌ CONFIG_KSU off"; exit 1; }

# ==================== 6. MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb){return blocking_notifier_chain_register(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb){return blocking_notifier_chain_unregister(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int s){return;}\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION ====================
echo "=== Compilation ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" $SIG_ARGS \
  -k -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    { grep -nE "error:|undefined symbol|fatal error:|\*\*\*" build.log | head -150; echo ""; tail -n 100 build.log; } \
      > "$GITHUB_WORKSPACE/output/build-errors.txt" 2>&1 || true
    exit 1
fi
echo "✅ Compilation réussie"
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
cp out/arch/arm64/boot/Image "\( GITHUB_WORKSPACE/output/Image- \){VER}"
cp out/System.map "\( GITHUB_WORKSPACE/output/System.map- \){VER}"

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

# ==================== 10-11 ====================
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
[ -f kernel ] && [ "\( (sha256sum kernel | cut -d' ' -f1)" = " \)(cat /tmp/kernel_compiled_hash.txt)" ] && echo "✅ Noyau IDENTIQUE"
../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null && echo "✅ ksud OK" || echo "❌ ksud absent"
cd ..
cp final_boot.img "output/FinaSU-A-${VER}-boot.img"
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ ${VER} ==="
ls -lh output/
