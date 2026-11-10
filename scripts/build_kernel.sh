#!/bin/bash
set -euo pipefail

FINASU_URL="${FINASU_URL:-https://github.com/LyraVoid/FinaSU.git}"
FINASU_REF="${FINASU_REF:-v1.5.0}"
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"
FINASU_EXPECTED_SIZE="${FINASU_EXPECTED_SIZE:-}"
FINASU_EXPECTED_HASH="${FINASU_EXPECTED_HASH:-}"
VER="finasu-A"
KSU_REF="$FINASU_REF"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"

echo "=== Build FinaSU ($FINASU_REF) — 4.19 ==="
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

# ==================== 2. INTÉGRATION FinaSU ====================
echo "=== Intégration FinaSU ($FINASU_REF) ==="
rm -rf drivers/kernelsu FinaSU 2>/dev/null || true
git clone "$FINASU_URL" FinaSU
git -C FinaSU checkout "$FINASU_REF"
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

# ==================== 4b.1 rules.c dual-path ====================
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
	return selinux_state.ss->policydb;
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
int handle_sepolicy(void __user *user_data, u64 data_len) { return -EOPNOTSUPP; }
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
	if (IS_ERR(backup_sepolicy)) { backup_sepolicy = NULL; }
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
int handle_sepolicy(void __user *user_data, u64 data_len) { return -EOPNOTSUPP; }
#endif
RULESEOF
echo "  ✅ rules.c dual-path"

# ==================== 4b.2 Correctifs 4.19 ====================
python3 - "$KSU_DIR" <<'PORTEOF' 2>&1 | tee -a "$AUDIT"
import os, sys

root = sys.argv[1]
total = 0

def read(p):
    with open(p, encoding='utf-8', errors='replace') as f:
        return f.read()

def write(p, c, o):
    global total
    if c != o:
        with open(p, 'w', encoding='utf-8') as f:
            f.write(c)
        total += 1
        print(f"  ✅ {os.path.relpath(p, root)}")

def rep(c, old, new, where):
    if old not in c:
        raise SystemExit(f"❌ ancre introuvable dans {where}:\n{old[:200]}")
    return c.replace(old, new, 1)

def ensure_inc(c, inc):
    if inc in c:
        return c
    lines = c.split('\n')
    for i, line in enumerate(lines):
        if line.lstrip().startswith('#include'):
            before = '\n'.join(lines[:i + 1])
            after = '\n'.join(lines[i + 1:])
            return before + f'\n#include {inc}' + ('\n' + after if after else '')
    return f'#include {inc}\n' + c

# ==========================================================
# 1. infra/file_wrapper.c
# ==========================================================
p = os.path.join(root, "infra/file_wrapper.c")
if os.path.isfile(p):
    c = read(p); o = c
    c = ensure_inc(c, "<linux/version.h>")
    c = rep(c,
        '    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'
        '    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n'
        '#endif', "fw/iopoll-assign")
    c = rep(c,
        '    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'
        '    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n'
        '#endif', "fw/remap-assign")
    c = rep(c,
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n'
        'static int ksu_wrapper_iopoll(struct kiocb *kiocb, struct io_comp_batch *icb, unsigned int v)',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n'
        'static int ksu_wrapper_iopoll(struct kiocb *kiocb, struct io_comp_batch *icb, unsigned int v)',
        "fw/iopoll-open")
    c = rep(c,
        '    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif',
        '    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif\n'
        '#endif /* LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0) */',
        "fw/iopoll-close")
    c = rep(c,
        'static loff_t ksu_wrapper_remap_file_range(struct file *file_in, loff_t pos_in, struct file *file_out, loff_t pos_out,\n'
        '                                           loff_t len, unsigned int remap_flags)\n{',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'
        'static loff_t ksu_wrapper_remap_file_range(struct file *file_in, loff_t pos_in, struct file *file_out, loff_t pos_out,\n'
        '                                           loff_t len, unsigned int remap_flags)\n{',
        "fw/remap-open")
    c = rep(c,
        '        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n'
        '    }\n}\n',
        '        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n'
        '    }\n}\n'
        '#endif /* LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0) */\n',
        "fw/remap-close")
    write(p, c, o)

# ==========================================================
# 2. selinux/sepolicy.c
# ==========================================================
p = os.path.join(root, "selinux/sepolicy.c")
if os.path.isfile(p):
    c = read(p); o = c
    c = ensure_inc(c, "<linux/version.h>")
    c = ensure_inc(c, "<linux/flex_array.h>")

    c = rep(c,
        '#define KSU_SUPPORT_ADD_TYPE\n',
        '#define KSU_SUPPORT_ADD_TYPE\n'
        '\n'
        '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n'
        '#define ksu_avtab_htable_get(htab, i) ((struct avtab_node *)flex_array_get_ptr((htab).htable, (i)))\n'
        '#define ksu_avtab_htable_set(htab, i, v) flex_array_put_ptr((htab).htable, (i), (v), GFP_ATOMIC)\n'
        '#else\n'
        '#define ksu_avtab_htable_get(htab, i) ((htab).htable[(i)])\n'
        '#define ksu_avtab_htable_set(htab, i, v) ((htab).htable[(i)] = (v))\n'
        '#endif\n',
        "sepolicy/helpers")

    c = rep(c,
        '        for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {',
        '        for (n = ksu_avtab_htable_get(db->te_avtab, i); n; prev = n, n = n->next) {',
        "sepolicy/remove-read")
    c = rep(c,
        '                db->te_avtab.htable[i] = n->next;',
        '                ksu_avtab_htable_set(db->te_avtab, i, n->next);',
        "sepolicy/remove-write")
    c = rep(c,
        '            removed.htable[0] = n;',
        '            ksu_avtab_htable_set(removed, 0, n);',
        "sepolicy/remove-temp")

    old_body = '''    u32 value = ++db->p_types.nprim;
    type = (struct type_datum *)kzalloc(sizeof(struct type_datum), GFP_KERNEL);
    if (!type) {
        pr_err("add_type: alloc type_datum failed.\\n");
        return false;
    }

    type->primary = 1;
    type->value = value;
    type->attribute = attr;

    char *key = kstrdup(type_name, GFP_KERNEL);
    if (!key) {
        pr_err("add_type: alloc key failed.\\n");
        return false;
    }

    if (symtab_insert(&db->p_types, key, type)) {
        pr_err("add_type: insert symtab failed.\\n");
        return false;
    }

    struct ebitmap *new_type_attr_map_array =
        ksu_kvrealloc(db->type_attr_map_array, value * sizeof(struct ebitmap), (value - 1) * sizeof(struct ebitmap));

    if (!new_type_attr_map_array) {
        pr_err("add_type: alloc type_attr_map_array failed\\n");
        return false;
    }

    struct type_datum **new_type_val_to_struct = ksu_kvrealloc(
        db->type_val_to_struct, sizeof(*db->type_val_to_struct) * value, sizeof(*db->type_val_to_struct) * (value - 1));

    if (!new_type_val_to_struct) {
        pr_err("add_type: alloc type_val_to_struct failed\\n");
        return false;
    }

    char **new_val_to_name_types =
        ksu_kvrealloc(db->sym_val_to_name[SYM_TYPES], sizeof(char *) * value, sizeof(char *) * (value - 1));
    if (!new_val_to_name_types) {
        pr_err("add_type: alloc val_to_name failed\\n");
        return false;
    }

    db->type_attr_map_array = new_type_attr_map_array;
    ebitmap_init(&db->type_attr_map_array[value - 1]);
    ebitmap_set_bit(&db->type_attr_map_array[value - 1], value - 1, 1);

    db->type_val_to_struct = new_type_val_to_struct;
    db->type_val_to_struct[value - 1] = type;

    db->sym_val_to_name[SYM_TYPES] = new_val_to_name_types;
    db->sym_val_to_name[SYM_TYPES][value - 1] = key;

    int i;
    for (i = 0; i < db->p_roles.nprim; ++i) {
        ebitmap_set_bit(&db->role_val_to_struct[i]->types, value - 1, 1);
    }

    return true;
'''

    new_body = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    u32 value = ++db->p_types.nprim;
    type = (struct type_datum *)kzalloc(sizeof(struct type_datum), GFP_KERNEL);
    if (!type) {
        pr_err("add_type: alloc type_datum failed.\\n");
        return false;
    }
    type->primary = 1;
    type->value = value;
    type->attribute = attr;
    char *key = kstrdup(type_name, GFP_KERNEL);
    if (!key) { pr_err("add_type: alloc key failed.\\n"); return false; }
    if (symtab_insert(&db->p_types, key, type)) { pr_err("add_type: insert symtab failed.\\n"); return false; }
    struct ebitmap *new_type_attr_map_array =
        ksu_kvrealloc(db->type_attr_map_array, value * sizeof(struct ebitmap), (value - 1) * sizeof(struct ebitmap));
    if (!new_type_attr_map_array) { pr_err("add_type: alloc type_attr_map_array failed\\n"); return false; }
    struct type_datum **new_type_val_to_struct = ksu_kvrealloc(
        db->type_val_to_struct, sizeof(*db->type_val_to_struct) * value, sizeof(*db->type_val_to_struct) * (value - 1));
    if (!new_type_val_to_struct) { pr_err("add_type: alloc type_val_to_struct failed\\n"); return false; }
    char **new_val_to_name_types =
        ksu_kvrealloc(db->sym_val_to_name[SYM_TYPES], sizeof(char *) * value, sizeof(char *) * (value - 1));
    if (!new_val_to_name_types) { pr_err("add_type: alloc val_to_name failed\\n"); return false; }
    db->type_attr_map_array = new_type_attr_map_array;
    ebitmap_init(&db->type_attr_map_array[value - 1]);
    ebitmap_set_bit(&db->type_attr_map_array[value - 1], value - 1, 1);
    db->type_val_to_struct = new_type_val_to_struct;
    db->type_val_to_struct[value - 1] = type;
    db->sym_val_to_name[SYM_TYPES] = new_val_to_name_types;
    db->sym_val_to_name[SYM_TYPES][value - 1] = key;
    int i;
    for (i = 0; i < db->p_roles.nprim; ++i) {
        ebitmap_set_bit(&db->role_val_to_struct[i]->types, value - 1, 1);
    }
    return true;
#else /* 4.19 flex_array path */
    u32 value = ++db->p_types.nprim;
    int k;
    void *zero = NULL;

    type = (struct type_datum *)kzalloc(sizeof(struct type_datum), GFP_KERNEL);
    if (!type) { pr_err("add_type: alloc type_datum failed.\\n"); return false; }
    type->primary = 1;
    type->value = value;
    type->attribute = attr;
    char *key = kstrdup(type_name, GFP_KERNEL);
    if (!key) { pr_err("add_type: alloc key failed.\\n"); return false; }
    if (symtab_insert(&db->p_types, key, type)) { pr_err("add_type: insert symtab failed.\\n"); return false; }

    /* type_attr_map_array: flex_array of struct ebitmap */
    struct flex_array *new_tama = flex_array_alloc(sizeof(struct ebitmap), value, GFP_KERNEL);
    if (!new_tama) { pr_err("add_type: flex_array_alloc type_attr_map_array failed\\n"); return false; }
    {
        struct ebitmap empty;
        memset(&empty, 0, sizeof(empty));
        for (k = 0; k < value; k++)
            flex_array_put(new_tama, k, &empty, GFP_KERNEL);
    }
    for (k = 0; k < value - 1; k++) {
        struct ebitmap *old_bm = (struct ebitmap *)flex_array_get(db->type_attr_map_array, k);
        struct ebitmap *new_bm = (struct ebitmap *)flex_array_get(new_tama, k);
        if (old_bm && new_bm)
            ebitmap_cpy(new_bm, old_bm);
    }
    flex_array_free(db->type_attr_map_array);
    db->type_attr_map_array = new_tama;
    {
        struct ebitmap *new_slot = (struct ebitmap *)flex_array_get(new_tama, value - 1);
        if (new_slot) {
            ebitmap_init(new_slot);
            ebitmap_set_bit(new_slot, value - 1, 1);
        }
    }

    /* type_val_to_struct_array: flex_array of void* */
    struct flex_array *new_tvts = flex_array_alloc(sizeof(void *), value, GFP_KERNEL);
    if (!new_tvts) { pr_err("add_type: flex_array_alloc type_val_to_struct_array failed\\n"); return false; }
    for (k = 0; k < value; k++)
        flex_array_put_ptr(new_tvts, k, zero, GFP_KERNEL);
    for (k = 0; k < value - 1; k++) {
        void *pv = flex_array_get_ptr(db->type_val_to_struct_array, k);
        if (pv)
            flex_array_put_ptr(new_tvts, k, pv, GFP_KERNEL);
    }
    flex_array_free(db->type_val_to_struct_array);
    db->type_val_to_struct_array = new_tvts;
    flex_array_put_ptr(new_tvts, value - 1, type, GFP_KERNEL);

    /* sym_val_to_name[SYM_TYPES]: flex_array of char* */
    struct flex_array *new_names = flex_array_alloc(sizeof(char *), value, GFP_KERNEL);
    if (!new_names) { pr_err("add_type: flex_array_alloc sym_val_to_name failed\\n"); return false; }
    for (k = 0; k < value; k++)
        flex_array_put_ptr(new_names, k, zero, GFP_KERNEL);
    for (k = 0; k < value - 1; k++) {
        void *pv = flex_array_get_ptr(db->sym_val_to_name[SYM_TYPES], k);
        if (pv)
            flex_array_put_ptr(new_names, k, pv, GFP_KERNEL);
    }
    flex_array_free(db->sym_val_to_name[SYM_TYPES]);
    db->sym_val_to_name[SYM_TYPES] = new_names;
    flex_array_put_ptr(new_names, value - 1, key, GFP_KERNEL);

    int i;
    for (i = 0; i < db->p_roles.nprim; ++i) {
        ebitmap_set_bit(&db->role_val_to_struct[i]->types, value - 1, 1);
    }
    return true;
#endif
'''

    c = rep(c, old_body, new_body, "sepolicy/add_type-body")

    c = rep(c,
        '    struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
        '    struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];\n'
        '#else\n'
        '    struct ebitmap *sattr = (struct ebitmap *)flex_array_get(db->type_attr_map_array, type->value - 1);\n'
        '#endif',
        "sepolicy/add_typeattr-sattr")

    c = rep(c,
        'static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,\n'
        '                               const char *o)\n'
        '{\n'
        '    struct type_datum *src, *tgt, *def;',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
        'static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,\n'
        '                               const char *o)\n'
        '{\n'
        '    struct type_datum *src, *tgt, *def;',
        "sepolicy/fnametr-open")
    c = rep(c,
        'free_trans:\n    kfree(trans);\nout:\n    return false;\n}\n',
        'free_trans:\n    kfree(trans);\nout:\n    return false;\n}\n'
        '#else /* LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0) */\n'
        'static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,\n'
        '                               const char *o)\n'
        '{\n'
        '    pr_warn("add_filename_trans non supporté avant 5.10\\n");\n'
        '    return false;\n'
        '}\n'
        '#endif /* LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0) */\n',
        "sepolicy/fnametr-close")

    c = rep(c,
        'void ksu_destroy_sepolicy(struct selinux_policy *pol)\n'
        '{\n'
        '    policydb_destroy(&pol->policydb);\n'
        '    kfree(pol);\n'
        '}\n'
        '\n'
        'struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)\n'
        '{',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
        'void ksu_destroy_sepolicy(struct selinux_policy *pol)\n'
        '{\n'
        '    policydb_destroy(&pol->policydb);\n'
        '    kfree(pol);\n'
        '}\n'
        '\n'
        'struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)\n'
        '{',
        "sepolicy/dup-open")
    c = rep(c,
        'out_free_data:\n    kvfree(data);\n\n    return ERR_PTR(ret);\n}\n',
        'out_free_data:\n    kvfree(data);\n\n    return ERR_PTR(ret);\n}\n'
        '#endif /* LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0) */\n',
        "sepolicy/dup-close")

    write(p, c, o)

# ==========================================================
# 3. Correctifs complémentaires
# ==========================================================
for rel in ['manager/dynamic_manager.c', 'policy/allowlist.c']:
    p = os.path.join(root, rel)
    if not os.path.isfile(p): continue
    c = read(p); o = c
    if 'put_task_struct' in c:
        c = ensure_inc(c, '<linux/sched.h>')
        c = ensure_inc(c, '<linux/sched/task.h>')
        write(p, c, o)

TWA = '\n#ifndef TWA_RESUME\n#define TWA_RESUME 0\n#endif\n'
for rel in ['manager/pkg_observer.c','manager/dynamic_manager.c','policy/allowlist.c','supercall/supercall.c']:
    p = os.path.join(root, rel)
    if not os.path.isfile(p): continue
    c = read(p); o = c
    if 'TWA_RESUME' in c and 'TWA_RESUME 0' not in c:
        c = ensure_inc(c, '<linux/version.h>')
        lines = c.split('\n')
        for i, line in enumerate(lines):
            if line.lstrip().startswith('#include'):
                before = '\n'.join(lines[:i + 1])
                after = '\n'.join(lines[i + 1:])
                c = before + TWA + ('\n' + after if after else '')
                break
        write(p, c, o)

p = os.path.join(root, 'manager/pkg_observer.c')
if os.path.isfile(p):
    c = read(p); o = c
    c = ensure_inc(c, '<linux/version.h>')
    if 'KSU_FSNOTIFY_COMPAT' not in c:
        out = []
        for line in c.split('\n'):
            if '.handle_inode_event' in line and not line.strip().startswith('#'):
                out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)', line, '#endif']
            else:
                out.append(line)
        c = '\n'.join(out).replace('#include <linux/version.h>',
                                   '#include <linux/version.h>\n#define KSU_FSNOTIFY_COMPAT 1', 1)
        write(p, c, o)

p = os.path.join(root, 'infra/seccomp_cache.c')
if os.path.isfile(p):
    c = read(p); o = c
    if 'SECCOMP_ARCH_NATIVE_NR' in c and 'KSU_SECCOMP_COMPAT' not in c:
        c = ensure_inc(c, '<linux/version.h>')
        stub = ('\n#ifndef KSU_SECCOMP_COMPAT\n#define KSU_SECCOMP_COMPAT 1\n'
                '#ifndef SECCOMP_ARCH_NATIVE_NR\n#ifdef CONFIG_COMPAT\n'
                '#define SECCOMP_ARCH_NATIVE_NR 2\n#else\n#define SECCOMP_ARCH_NATIVE_NR 1\n'
                '#endif\n#endif\n#endif\n')
        lines = c.split('\n')
        for i, line in enumerate(lines):
            if line.lstrip().startswith('#include'):
                before = '\n'.join(lines[:i + 1])
                after = '\n'.join(lines[i + 1:])
                c = before + stub + ('\n' + after if after else '')
                break
        write(p, c, o)

p = os.path.join(root, 'policy/app_profile.c')
if os.path.isfile(p):
    c = read(p); o = c
    if 'filter_count' in c and 'KSU_FILTER_COUNT_COMPAT' not in c:
        c = ensure_inc(c, '<linux/version.h>')
        out = []
        for line in c.split('\n'):
            if 'filter_count' in line and not line.strip().startswith(('/', '#')):
                out += ['#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)', line, '#else',
                        '\treturn 0;' if 'return' in line else '\t/* no filter_count */', '#endif']
            else:
                out.append(line)
        c = '\n'.join(out).replace('#include <linux/version.h>',
                                   '#include <linux/version.h>\n#define KSU_FILTER_COUNT_COMPAT 1', 1)
        write(p, c, o)
    # Alias seccomp_filter_release -> put_seccomp_filter pour 4.19
    if 'seccomp_filter_release' in c and 'KSU_SECCOMP_RELEASE_COMPAT' not in c:
        c = ensure_inc(c, '<linux/version.h>')
        alias = ('\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n'
                 '#define seccomp_filter_release put_seccomp_filter\n'
                 '#endif\n#define KSU_SECCOMP_RELEASE_COMPAT 1\n')
        lines = c.split('\n')
        for i, line in enumerate(lines):
            if line.lstrip().startswith('#include'):
                before = '\n'.join(lines[:i + 1])
                after = '\n'.join(lines[i + 1:])
                c = before + alias + ('\n' + after if after else '')
                break
        write(p, c, o)

p = os.path.join(root, 'supercall/dispatch.c')
if os.path.isfile(p):
    c = read(p); o = c
    c = c.replace(
        '\n#ifndef KSU_TASKLIST_COMPAT\n#define KSU_TASKLIST_COMPAT 1\n'
        'extern rwlock_t tasklist_lock;\nextern struct task_struct init_task;\n#endif\n', '')
    c = c.replace(
        '#ifndef KSU_TASKLIST_COMPAT\n#define KSU_TASKLIST_COMPAT 1\n'
        'extern rwlock_t tasklist_lock;\nextern struct task_struct init_task;\n#endif\n', '')
    c = c.replace('extern rwlock_t tasklist_lock;\n', '')
    c = c.replace('extern struct task_struct init_task;\n', '')
    c = ensure_inc(c, '<linux/version.h>')
    c = ensure_inc(c, '<linux/spinlock.h>')
    c = ensure_inc(c, '<linux/sched.h>')
    c = ensure_inc(c, '<linux/sched/signal.h>')
    c = ensure_inc(c, '<linux/sched/task.h>')
    write(p, c, o)

p = os.path.join(root, 'sulog/event.c')
if os.path.isfile(p):
    c = read(p); o = c
    if 'linux/minmax.h' in c and 'KSU_MINMAX_COMPAT' not in c:
        c = c.replace('#include <linux/minmax.h>',
            '#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
            '#include <linux/minmax.h>\n#else\n#include <linux/kernel.h>\n#endif\n'
            '#define KSU_MINMAX_COMPAT 1')
        write(p, c, o)

p = os.path.join(root, 'infra/su_mount_ns.c')
if os.path.isfile(p):
    c = read(p); o = c
    if 'uapi/linux/mount.h' in c and 'KSU_MOUNT_HDR_COMPAT' not in c:
        c = c.replace('#include <uapi/linux/mount.h>',
            '#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)\n'
            '#include <uapi/linux/mount.h>\n#else\n#include <linux/mount.h>\n#endif\n'
            '#define KSU_MOUNT_HDR_COMPAT 1')
        write(p, c, o)

# selinux_hide stub — AJOUT de init/exit
p = os.path.join(root, 'feature/selinux_hide.c')
if os.path.isfile(p):
    c = read(p); o = c
    if 'KSU_SELINUX_HIDE_4_19_STUB' not in c:
        stub = (
            '#include <linux/version.h>\n#include <linux/types.h>\n#include <linux/errno.h>\n'
            '#define KSU_SELINUX_HIDE_4_19_STUB 1\n'
            '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n'
            'bool ksu_selinux_hide_enabled = false;\n'
            'bool ksu_selinux_hide_running = false;\n'
            'int ksu_selinux_hide_enable(void) { return -EOPNOTSUPP; }\n'
            'int ksu_selinux_hide_disable(void) { return 0; }\n'
            'void ksu_selinux_hide_unhook(void) { }\n'
            'void initialize_fake_status(void) { }\n'
            'void ksu_selinux_hide_handle_post_fs_data(void) { }\n'
            'void ksu_selinux_hide_handle_second_stage(void) { }\n'
            'void ksu_selinux_hide_drop_backup_if_unused(void) { }\n'
            'void ksu_selinux_hide_handle_umount(void) { }\n'
            'int ksu_selinux_hide_init(void) { return 0; }\n'
            'void ksu_selinux_hide_exit(void) { }\n'
            '#else\n')
        lines = c.split('\n'); removed = False; out = []
        for ln in lines:
            if not removed and ln.strip() == '#include <linux/version.h>':
                removed = True; continue
            out.append(ln)
        c = stub + '\n'.join(out) + '\n#endif /* KSU_SELINUX_HIDE_4_19_STUB */\n'
        write(p, c, o)
    elif 'ksu_selinux_hide_init' not in c:
        # Patch déjà appliqué mais sans init/exit : les ajouter
        c = c.replace(
            'void ksu_selinux_hide_handle_umount(void) { }\n#else',
            'void ksu_selinux_hide_handle_umount(void) { }\n'
            'int ksu_selinux_hide_init(void) { return 0; }\n'
            'void ksu_selinux_hide_exit(void) { }\n#else')
        write(p, c, o)

# path_mount / path_umount : stub sur 4.19
for rel in ['feature/kernel_umount.c', 'infra/su_mount_ns.c']:
    p = os.path.join(root, rel)
    if not os.path.isfile(p): continue
    c = read(p); o = c
    if 'KSU_PATH_MOUNT_COMPAT' not in c:
        # Envelopper les appels à path_umount/path_mount pour 4.19
        # On retire les déclarations extern et on remplace l'appel par un stub
        if 'path_umount' in c:
            c = c.replace('extern int path_umount(struct path *path, int flags);\n', '')
            c = c.replace('extern int path_umount(struct path *path, int flags);', '')
            # Remplacer l'appel réel par un retour neutre sur 4.19
            import re
            c = re.sub(r'(path_umount\s*\([^;]*\);)',
                       r'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n        \1\n#else\n        (void)path; (void)flags; /* stub 4.19 */\n#endif',
                       c, count=1)
        if 'path_mount' in c:
            c = c.replace('extern int path_mount(const char *dev_name, struct path *path,\n'
                          '                      const char *type_page, unsigned long flags,\n'
                          '                      void *data_page);\n', '')
            c = c.replace('extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags, void *data_page);', '')
            c = re.sub(r'(path_mount\s*\([^;]*\);)',
                       r'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n        \1\n#else\n        (void)dev_name; (void)path; (void)type_page; (void)flags; (void)data_page; /* stub 4.19 */\n#endif',
                       c, count=1)
        if 'KSU_PATH_MOUNT_COMPAT' not in c:
            c = ensure_inc(c, '<linux/version.h>')
            c = '#define KSU_PATH_MOUNT_COMPAT 1\n' + c
        write(p, c, o)

for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith(('.c', '.h')): continue
        p = os.path.join(dp, f)
        try: c = read(p)
        except Exception: continue
        o = c
        out = []
        for ln in c.split('\n'):
            s = ln.strip()
            if s.startswith('MODULE_IMPORT_NS(') and s.endswith(');'):
                out += ['#ifdef MODULE_IMPORT_NS', ln, '#endif']
            else:
                out.append(ln)
        new = '\n'.join(out)
        if new != o: write(p, new, o)

print(f"  ✅ portage : {total} fichier(s)")
PORTEOF

# ==================== 5. CONFIG ====================
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
CONFIG_KSU_HOOK_TRACEPOINT=y
# CONFIG_KSU_HOOK_SUSFS_INLINE is not set
# CONFIG_KSU_SUSFS is not set
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
echo "=== BUILD TERMINÉ ${VER} ==="
ls -lh output/
