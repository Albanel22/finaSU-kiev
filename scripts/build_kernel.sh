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

echo "=== Build FinaSU ($FINASU_REF) — noyau cible 4.19 + SuSFS ==="
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

# Patch SUSFS 4.19
SUSFS_419_PATCH_URL="${SUSFS_419_PATCH_URL:-https://raw.githubusercontent.com/Albanel22/finaSU-kiev/b592bd3b000c6538c17ea69395f342fba14b6dcc/patches/susfs_patch_to_4.19.patch}"
SUSFS_419_PATCH="$GITHUB_WORKSPACE/patches/susfs_patch_to_4.19.patch"
mkdir -p "$GITHUB_WORKSPACE/patches"
curl --proto '=https' --tlsv1.2 -fsSL "$SUSFS_419_PATCH_URL" -o "$SUSFS_419_PATCH"
echo "Patch SUSFS téléchargé : $(sha256sum "$SUSFS_419_PATCH" | cut -d' ' -f1)" | tee -a "$AUDIT"
MANUAL_SUSFS_PATCH="$GITHUB_WORKSPACE/patches/susfs_419_manual_fix.patch"
mkdir -p "$(dirname "$MANUAL_SUSFS_PATCH")"
base64 -d > "$MANUAL_SUSFS_PATCH" <<'SUSFS_MANUAL_B64_EOF'
LS0tIGEvZnMvTWFrZWZpbGUKKysrIGIvZnMvTWFrZWZpbGUKQEAgLTE0LDYgKzE0LDcgQEAKIAkJ
cG5vZGUubyBzcGxpY2UubyBzeW5jLm8gdXRpbWVzLm8gZF9wYXRoLm8gXAogCQlzdGFjay5vIGZz
X3N0cnVjdC5vIHN0YXRmcy5vIGZzX3Bpbi5vIG5zZnMubyBcCiAJCWZzX3R5cGVzLm8gZnNfY29u
dGV4dC5vIGZzX3BhcnNlci5vCitvYmotJChDT05GSUdfS1NVX1NVU0ZTKSArPSBzdXNmcy5vCiAK
IGlmZXEgKCQoQ09ORklHX0JMT0NLKSx5KQogb2JqLXkgKz0JYnVmZmVyLm8gYmxvY2tfZGV2Lm8g
ZGlyZWN0LWlvLm8gbXBhZ2UubwotLS0gYS9mcy9uYW1lc3BhY2UuYworKysgYi9mcy9uYW1lc3Bh
Y2UuYwpAQCAtMzAsNiArMzAsMTQgQEAKIAogI2luY2x1ZGUgInBub2RlLmgiCiAjaW5jbHVkZSAi
aW50ZXJuYWwuaCIKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTCisjaW5jbHVkZSA8bGludXgvc3Vz
ZnNfZGVmLmg+CisjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlMKKyNpZmRlZiBDT05G
SUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorZXh0ZXJuIGJvb2wgc3VzZnNfaXNfY3VycmVudF9rc3Vf
ZG9tYWluKHZvaWQpOworZXh0ZXJuIHN0cnVjdCBzdGF0aWNfa2V5X3RydWUgc3VzZnNfaXNfc2Rj
YXJkX2FuZHJvaWRfZGF0YV9ub3RfZGVjcnlwdGVkOworI2RlZmluZSBDTF9DT1BZX01OVF9OUyBC
SVQoMjUpIC8qIHVzZWQgYnkgY29weV9tbnRfbnMoKSAqLworI2VuZGlmIC8vICNpZmRlZiBDT05G
SUdfS1NVX1NVU0ZTX1NVU19NT1VOVAogCiAvKiBNYXhpbXVtIG51bWJlciBvZiBtb3VudHMgaW4g
YSBtb3VudCBuYW1lc3BhY2UgKi8KIHVuc2lnbmVkIGludCBzeXNjdGxfbW91bnRfbWF4IF9fcmVh
ZF9tb3N0bHkgPSAxMDAwMDA7CkBAIC0xMDkwLDggKzEwOTgsMTcgQEAKIAlpZiAoIWZjLT5yb290
KQogCQlyZXR1cm4gRVJSX1BUUigtRUlOVkFMKTsKIAlzYiA9IGZjLT5yb290LT5kX3NiOwotCisj
aWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQKKwlpZiAoc3RhdGljX2JyYW5jaF91bmxp
a2VseSgmc3VzZnNfaXNfc2RjYXJkX2FuZHJvaWRfZGF0YV9ub3RfZGVjcnlwdGVkKSAmJgorCSAgICBzdXNmc19pc19jdXJyZW50X2tzdV9kb21haW4oKSkgeworCQltbnQgPSBzdXNmc19hbGxvY19u
b25fdW5zaGFyZV9rc3VfdmZzbW50KGZjLT5zb3VyY2UgPzogIm5vbmUiKTsKKwkJZ290byBzdXNm
c192ZnNfY3JlYXRlX21vdW50X2FsbG9jYXRlZDsKKwl9CisjZW5kaWYgLy8gI2lmZGVmIENPTkZJ
R19LU1VfU1VTRlNfU1VTX01PVU5UCiAJbW50ID0gYWxsb2NfdmZzbW50KGZjLT5zb3VyY2UgPzog
Im5vbmUiKTsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorc3VzZnNfdmZzX2Ny
ZWF0ZV9tb3VudF9hbGxvY2F0ZWQ6CisjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlNf
U1VTX01PVU5UCiAJaWYgKCFtbnQpCiAJCXJldHVybiBFUlJfUFRSKC1FTk9NRU0pOwogCi0tLSBh
L2ZzL3Byb2MvdGFza19tbXUuYworKysgYi9mcy9wcm9jL3Rhc2tfbW11LmMKQEAgLTE2NzQsNyAr
MTY3NCwxNSBAQAogCQlyZXQgPSBtbWFwX3JlYWRfbG9ja19raWxsYWJsZShtbSk7CiAJCWlmIChy
ZXQpCiAJCQlnb3RvIG91dF9mcmVlOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01BUAor
CQl2bWEgPSBmaW5kX3ZtYShtbSwgc3RhcnRfdmFkZHIpOworCQlpZiAodm1hICYmIHZtYS0+dm1f
ZmlsZSAmJiBTVVNGU19JU19JTk9ERV9TVVNfTUFQKGZpbGVfaW5vZGUodm1hLT52bV9maWxlKSkp
CisJCQlnb3RvIHN1c2ZzX3BhZ2VtYXBfYnlwYXNzOworI2VuZGlmIC8vICNpZmRlZiBDT05GSUdf
S1NVX1NVU0ZTX1NVU19NQVAKIAkJcmV0ID0gd2Fsa19wYWdlX3JhbmdlKHN0YXJ0X3ZhZGRyLCBl
bmQsICZwYWdlbWFwX3dhbGspOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01BUAorc3Vz
ZnNfcGFnZW1hcF9ieXBhc3M6CisjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VT
X01BUAogCQltbWFwX3JlYWRfdW5sb2NrKG1tKTsKIAkJc3RhcnRfdmFkZHIgPSBlbmQ7CiAKLS0t
IGEvZnMvc3VwZXIuYworKysgYi9mcy9zdXBlci5jCkBAIC0zNyw2ICszNywxMyBAQAogI2luY2x1
ZGUgPGxpbnV4L2xvY2tkZXAuaD4KICNpbmNsdWRlIDxsaW51eC91c2VyX25hbWVzcGFjZS5oPgog
I2luY2x1ZGUgPGxpbnV4L2ZzX2NvbnRleHQuaD4KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTCisj
aW5jbHVkZSA8bGludXgvc3VzZnNfZGVmLmg+CisjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1Vf
U1VTRlMKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorZXh0ZXJuIGJvb2wgc3Vz
ZnNfaXNfY3VycmVudF9rc3VfZG9tYWluKHZvaWQpOworZXh0ZXJuIHN0cnVjdCBzdGF0aWNfa2V5
X3RydWUgc3VzZnNfaXNfc2RjYXJkX2FuZHJvaWRfZGF0YV9ub3RfZGVjcnlwdGVkOworI2VuZGlm
IC8vICNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAogI2luY2x1ZGUgImludGVybmFs
LmgiCiAKIHN0YXRpYyBpbnQgdGhhd19zdXBlcl9sb2NrZWQoc3RydWN0IHN1cGVyX2Jsb2NrICpz
Yik7Ci0tLSBhL21tL21lbW9yeS5jCisrKyBiL21tL21lbW9yeS5jCkBAIC03OSw2ICs3OSw5IEBA
CiAjaW5jbHVkZSA8YXNtL3RsYi5oPgogI2luY2x1ZGUgPGFzbS90bGJmbHVzaC5oPgogI2luY2x1
ZGUgPGxpbnV4L3BndGFibGUuaD4KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NQVAKKyNp
bmNsdWRlIDxsaW51eC9zdXNmc19kZWYuaD4KKyNlbmRpZiAvLyAjaWZkZWYgQ09ORklHX0tTVV9T
VVNGU19TVVNfTUFQCiAKICNpbmNsdWRlICJpbnRlcm5hbC5oIgogCkBAIC00NTAyLDcgKzQ1MDUs
OSBAQAogCiAJaWYgKG1tYXBfcmVhZF9sb2NrX2tpbGxhYmxlKG1tKSkKIAkJcmV0dXJuIDA7Ci0K
KyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NQVAKKwl2bWEgPSBmaW5kX3ZtYShtbSwgYWRk
cik7CisjZW5kaWYgLy8gI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01BUAogCS8qIGlnbm9y
ZSBlcnJvcnMsIGp1c3QgY2hlY2sgaG93IG11Y2ggd2FzIHN1Y2Nlc3NmdWxseSB0cmFuc2ZlcnJl
ZCAqLwogCXdoaWxlIChsZW4pIHsKIAkJaW50IGJ5dGVzLCByZXQsIG9mZnNldDsK
SUSFS_MANUAL_B64_EOF
set +e
 git apply --reject --whitespace=nowarn "$SUSFS_419_PATCH" 2>&1 | tee -a "$AUDIT"
SUSFS_APPLY_RC=${PIPESTATUS[0]}
set -e
EXPECTED_REJECTS=$'fs/Makefile.rej\nfs/namespace.c.rej\nfs/proc/task_mmu.c.rej\nfs/super.c.rej\nmm/memory.c.rej'
mapfile -t SUSFS_REJECTS < <(find . -name '*.rej' -printf '%P\n' | sort)
if [ "${#SUSFS_REJECTS[@]}" -ne 5 ] || [ "$(printf '%s\n' "${SUSFS_REJECTS[@]}")" != "$EXPECTED_REJECTS" ]; then
    echo "❌ Rejets SUSFS inattendus (code=$SUSFS_APPLY_RC):" | tee -a "$AUDIT"
    printf '  %s\n' "${SUSFS_REJECTS[@]}" | tee -a "$AUDIT"
    exit 1
fi
for reject in "${SUSFS_REJECTS[@]}"; do rm -f "$reject"; done
if ! git apply --check "$MANUAL_SUSFS_PATCH"; then
    echo "❌ Le correctif manuel SUSFS ne s'applique pas" | tee -a "$AUDIT"
    git apply --check --verbose "$MANUAL_SUSFS_PATCH" 2>&1 | tee -a "$AUDIT" || true
    exit 1
fi
git apply --whitespace=nowarn "$MANUAL_SUSFS_PATCH"
REMAINING_REJECTS=$(find . -name '*.rej' -print)
if [ -n "$REMAINING_REJECTS" ]; then
    echo "❌ Rejets SUSFS résiduels:" | tee -a "$AUDIT"
    printf '%s\n' "$REMAINING_REJECTS" | tee -a "$AUDIT"
    exit 1
fi
echo "✅ Patch SUSFS 4.19 appliqué" | tee -a "$AUDIT"

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
# Export souple de selinux_status_page et selinux_status_lock quel que soit le fichier SELinux
grep -rl "selinux_status_page" security/selinux/ 2>/dev/null | while read -r f; do
    sed -i -E 's/^static[[:space:]]+(struct page[[:space:]]*\*[[:space:]]*selinux_status_page)/\1/' "$f"
done || true
grep -rl "selinux_status_lock" security/selinux/ 2>/dev/null | while read -r f; do
    sed -i -E 's/^static[[:space:]]+(DEFINE_MUTEX\(selinux_status_lock\))/\1/' "$f"
done || true

[ -f "security/selinux/ss/services.c" ] && sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
[ -f "security/selinux/hooks.c" ] && sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c

grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null | while read -r f; do
    sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
done || true
grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null | while read -r f; do
    sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g; s/O_RDWR|O_CLOEXEC/O_RDWR/g; s/, O_CLOEXEC)/)/g' "$f"
done || true

# ==================== 4a. rules.c dual-path ====================
echo "=== Réécriture rules.c dual-path (4.19: selinux_state.ss->policydb) ==="
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
{
    return (size_t)(cursor->end - cursor->cur);
}

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
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW)
            success = ksu_allow(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DENY)
            success = ksu_deny(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_AUDITALLOW)
            success = ksu_auditallow(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DONTAUDIT)
            success = ksu_dontaudit(db, args[0], args[1], args[2], args[3]);
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
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
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        return success ? 0 : -EINVAL;

    case KSU_SEPOLICY_CMD_TYPE_STATE:
        ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_PERMISSIVE)
            success = ksu_permissive(db, args[0]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_ENFORCE)
            success = ksu_enforce(db, args[0]);
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        return success ? 0 : -EINVAL;

    case KSU_SEPOLICY_CMD_TYPE:
    case KSU_SEPOLICY_CMD_TYPE_ATTR:
        ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "attribute"); if (ret < 0) return ret;
        if (header->cmd == KSU_SEPOLICY_CMD_TYPE)
            success = ksu_type(db, args[0], args[1]);
        else
            success = ksu_typeattribute(db, args[0], args[1]);
        if (!success) { pr_err("sepol: %d failed.\n", header->cmd); return -EINVAL; }
        return 0;

    case KSU_SEPOLICY_CMD_ATTR:
        ret = sepol_require_not_all(args[0], "attribute"); if (ret < 0) return ret;
        if (!ksu_attribute(db, args[0])) { pr_err("sepol: %d failed.\n", header->cmd); return -EINVAL; }
        return 0;

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
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_CHANGE)
            success = ksu_type_change(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_MEMBER)
            success = ksu_type_member(db, args[0], args[1], args[2], args[3]);
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        return success ? 0 : -EINVAL;

    case KSU_SEPOLICY_CMD_GENFSCON:
        ret = sepol_require_not_all(args[0], "name"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "path"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[2], "context"); if (ret < 0) return ret;
        if (!ksu_genfscon(db, args[0], args[1], args[2])) { pr_err("sepol: %d failed.\n", header->cmd); return -EINVAL; }
        return 0;

    default:
        pr_err("sepol: unknown cmd: %d\n", header->cmd);
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
    if (!getenforce())
        pr_info("SELinux permissive or disabled, apply rules! (old kernel path)\n");

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

    if (!getenforce())
        pr_info("SELinux permissive or disabled when handle policy!\n");

    write_lock(&selinux_state.ss->policy_rwlock);
    cursor.cur = payload;
    cursor.end = payload + (size_t)data_len;
    ret = 0;
    success_cmd_count = 0;
    cmd_index = 0;
    while (cursor.cur < cursor.end) {
        struct sepol_data header;
        const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
        int expected_argc;
        u32 arg_index;
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

struct selinux_policy *backup_sepolicy;
#define SELINUX_POLICY_INSTEAD_SELINUX_SS

#ifdef KSU_SUSFS_HAS_TYPE_REGISTRATION
extern int susfs_add_sus_avd_allowed_by_type(u32 s_type, u32 t_type, u32 type, u32 orig_avd_allowed);
extern int susfs_add_sus_type(const char *secctx, u32 type_value);
#endif

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

    if (!getenforce()) pr_info("SELinux permissive or disabled, apply rules!\n");

    mutex_lock(&selinux_state.policy_mutex);

    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    backup_sepolicy = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(backup_sepolicy)) {
        pr_err("failed to create backup sepolicy: %ld\n", PTR_ERR(backup_sepolicy));
        backup_sepolicy = NULL;
    } else {
        backup_sepolicy->sidtab = kzalloc(sizeof(*backup_sepolicy->sidtab), GFP_KERNEL);
        if (!backup_sepolicy->sidtab) {
            pr_err("failed to alloc backup sidtab\n");
            ksu_destroy_sepolicy(backup_sepolicy);
            backup_sepolicy = NULL;
        } else {
            int ret = policydb_load_isids(&backup_sepolicy->policydb, backup_sepolicy->sidtab);
            if (ret) {
                pr_err("failed to load isids for backup sepolicy: %d!\n", ret);
                kfree(backup_sepolicy->sidtab);
                ksu_destroy_sepolicy(backup_sepolicy);
                backup_sepolicy = NULL;
            } else {
                pr_info("backup sepolicy success! latest_granting=%d\n", backup_sepolicy->latest_granting);
            }
        }
    }

    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) {
        pr_err("failed to dup selinux_policy: %ld\n", PTR_ERR(pol));
        goto out_unlock;
    }

    db = &pol->policydb;

#if !defined(CONFIG_KSU_SUSFS) || !defined(KSU_SUSFS_HAS_TYPE_REGISTRATION)
    pol->latest_granting = old_pol->latest_granting + 1;
    if (!ksu_set_original_types(db, &old_pol->policydb, pol->latest_granting))
        pr_warn("failed to save original type metadata, use backup lookups\n");
#endif

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

#ifdef KSU_SUSFS_HAS_TYPE_REGISTRATION
    reset_avc_cache(0);
#else
    reset_avc_cache(pol->latest_granting);
#endif
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
out_unlock:
    mutex_unlock(&selinux_state.policy_mutex);
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
    if (copy_from_user(payload, user_data, (size_t)data_len)) { ret = -EFAULT; goto out_free; }
    if (!getenforce()) pr_info("SELinux permissive or disabled when handle policy!\n");
    mutex_lock(&selinux_state.policy_mutex);
    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) {
        ret = PTR_ERR(pol);
        pr_err("ksu_dup_sepolicy err: %d\n", ret);
        goto out_unlock;
    }
    db = &pol->policydb;
    cursor.cur = payload;
    cursor.end = payload + (size_t)data_len;
    ret = 0;
    success_cmd_count = 0;
    cmd_index = 0;
    while (cursor.cur < cursor.end) {
        struct sepol_data header;
        const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
        int expected_argc;
        u32 arg_index;
        ret = sepol_read_cmd_header(&cursor, &header);
        if (ret < 0) { pr_err("sepol: failed header #%u\n", cmd_index); goto out_drop_new_policy; }
        expected_argc = sepol_expected_argc(header.cmd);
        if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) { ret = -EINVAL; goto out_drop_new_policy; }
        for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
            ret = sepol_read_string(&cursor, &args[arg_index]);
            if (ret < 0) goto out_drop_new_policy;
        }
        ret = apply_one_sepolicy_cmd(db, &header, args);
        if (ret < 0) pr_err("sepol: cmd #%u failed cmd=%u subcmd=%u\n", cmd_index, header.cmd, header.subcmd);
        else success_cmd_count++;
        cmd_index++;
    }
#if !defined(CONFIG_KSU_SUSFS) || !defined(KSU_SUSFS_HAS_TYPE_REGISTRATION)
    pol->latest_granting = old_pol->latest_granting + 1;
    if (!ksu_advance_original_types(db, &old_pol->policydb, old_pol->latest_granting, pol->latest_granting))
        pr_warn("failed to carry original type metadata, use backup lookups\n");
#endif
    rcu_assign_pointer(selinux_state.policy, pol);
    synchronize_rcu();
    ksu_destroy_sepolicy(old_pol);
#ifdef KSU_SUSFS_HAS_TYPE_REGISTRATION
    reset_avc_cache(0);
#else
    reset_avc_cache(pol->latest_granting);
#endif
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

#endif /* LINUX_VERSION_CODE >= 5.10.0 */
RULESEOF
echo "  ✅ rules.c dual-path réinstallé"

# ==================== 4b. COMPATIBILITÉ 4.19 (13 fixes) ====================
echo "=== Correctifs ciblés 4.19 (13 fixes) ==="
python3 - "$GITHUB_WORKSPACE" <<'FIXEOF' 2>&1 | tee -a "$AUDIT"
import os, sys, re

GW = sys.argv[1]
kernel_root = os.path.join(GW, "kernel_sources")
ksu_root = os.path.join(kernel_root, "FinaSU", "kernel")
total = 0

def read(p):
    with open(p, encoding='utf-8', errors='replace') as f:
        return f.read()

def write(p, c):
    with open(p, 'w', encoding='utf-8') as f:
        f.write(c)

def ensure_inc_after_last(c, inc):
    if inc in c: return c
    lines = c.split('\n'); last = -1
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith('#include'): last = i
    if last >= 0:
        lines.insert(last + 1, f'#include {inc}')
        return '\n'.join(lines)
    return f'#include {inc}\n' + c

# --- FIX 1 : fs/stat.c ---
p = os.path.join(kernel_root, "fs/stat.c")
if os.path.isfile(p):
    c = read(p)
    if '#include <linux/susfs_def.h>' not in c:
        marker = '#include <asm/unistd.h>'
        if marker in c:
            idx = c.index(marker) + len(marker)
            eol = c.find('\n', idx)
            if eol == -1: eol = len(c)
            insert = '\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif // CONFIG_KSU_SUSFS_SUS_KSTAT'
            c = c[:eol] + insert + c[eol:]
            write(p, c); total += 1
            print(f"  ✅ fs/stat.c: include susfs_def.h")

# --- FIX 2 : MODULE_IMPORT_NS ---
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
                        out.append('#ifdef MODULE_IMPORT_NS')
                        out.append(ln)
                        out.append('#endif')
                        changed = True; continue
                out.append(ln)
            if changed:
                write(p, '\n'.join(out)); total += 1
                print(f"  ✅ {os.path.relpath(p, GW)}: MODULE_IMPORT_NS")

# --- FIX 3 : file_wrapper.c ---
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
    old = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n'
           'static int ksu_wrapper_iopoll(struct kiocb *kiocb, struct io_comp_batch *icb, unsigned int v)')
    new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'
           '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n'
           'static int ksu_wrapper_iopoll(struct kiocb *kiocb, struct io_comp_batch *icb, unsigned int v)')
    if old in c and new not in c: c = c.replace(old, new, 1)
    old = '    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif'
    new = '    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif\n#endif /* 5.0.0 */'
    if old in c and '#endif\n#endif /* 5.0.0 */' not in c: c = c.replace(old, new, 1)
    old = ('static loff_t ksu_wrapper_remap_file_range(struct file *file_in, loff_t pos_in, struct file *file_out, loff_t pos_out,\n'
           '                                           loff_t len, unsigned int remap_flags)\n{')
    new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'
           'static loff_t ksu_wrapper_remap_file_range(struct file *file_in, loff_t pos_in, struct file *file_out, loff_t pos_out,\n'
           '                                           loff_t len, unsigned int remap_flags)\n{')
    if old in c and new not in c: c = c.replace(old, new, 1)
    old = ('        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n'
           '    }\n}\n')
    new = ('        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n'
           '    }\n}\n#endif /* 5.0.0 */\n')
    if old in c and '#endif /* 5.0.0 */\n\nstatic int ksu_wrapper_fadvise' not in c:
        c = c.replace(old, new, 1)
    if c != original:
        write(p, c); total += 1
        print(f"  ✅ infra/file_wrapper.c: guards 4.19")

# --- FIX 4 : seccomp_cache.c ---
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

# --- FIX 5 : su_mount_ns.c ---
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

# --- FIX 6 : pkg_observer.c ---
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
#if defined(CONFIG_KSU_SUSFS) && defined(CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER) && defined(CMD_SUSFS_SET_PRIORITY_UID_FILTER)
    susfs_parse_priority_app_strings();
#endif
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
    pr_warn("defer track_throne failed, run it inline\n");
    track_throne(false);
}

static void ksu_maybe_track_packages_list(void)
{
    pr_info("packages.list detected\n");
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
    if (ret) {
        pr_info("path not ready: %s (%d)\n", wd->path, ret);
        return ret;
    }
    wd->inode = d_inode(wd->kpath.dentry);
    ihold(wd->inode);
    ret = add_mark_on_inode(wd->inode, wd->mask, &wd->mark);
    if (ret) {
        pr_err("Add mark failed for %s (%d)\n", wd->path, ret);
        path_put(&wd->kpath);
        iput(wd->inode);
        wd->inode = NULL;
        return ret;
    }
    pr_info("watching %s\n", wd->path);
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
    ret = watch_one_dir(&g_watch);
    pr_info("observer init done\n");
    return 0;
}

void __exit ksu_observer_exit(void)
{
    unwatch_one_dir(&g_watch);
    fsnotify_put_group(g);
    pr_info("observer exit done\n");
}
'''
        write(p, new_c); total += 1
        print(f"  ✅ manager/pkg_observer.c: réécrit 4.19")

# --- FIX 7 : TWA_RESUME + put_task_struct ---
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
                    lines.insert(last_inc + 1, twa)
                    c = '\n'.join(lines)
                else:
                    c = twa + c
            if 'put_task_struct' in c:
                c = ensure_inc_after_last(c, '<linux/sched.h>')
                c = ensure_inc_after_last(c, '<linux/sched/task.h>')
            if c != original:
                write(p, c); total += 1
                print(f"  ✅ {os.path.relpath(p, GW)}: TWA_RESUME + sched/task.h")

# --- FIX 8 : app_profile.c ---
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
               '    seccomp_filter_release(fake);\n'
               '#else\n'
               '    put_seccomp_filter(fake);\n'
               '#endif\n')
        c = c.replace(old, new, 1)
    if c != original:
        write(p, c); total += 1
        print(f"  ✅ policy/app_profile.c: seccomp_filter_release backporté")

# --- FIX 9 : sepolicy.c ---
p = os.path.join(ksu_root, "selinux/sepolicy.c")
if os.path.isfile(p):
    c = read(p); original = c

    c = ensure_inc_after_last(c, '<linux/flex_array.h>')

    if 'ksu_avtab_htable_get' not in c and '#define KSU_SUPPORT_ADD_TYPE' in c:
        c = c.replace(
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
            1
        )

    c = c.replace(
        'for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {',
        'for (n = ksu_avtab_htable_get(db->te_avtab, i); n; prev = n, n = n->next) {',
        1
    )
    c = c.replace(
        'db->te_avtab.htable[i] = n->next;',
        'ksu_avtab_htable_set(db->te_avtab, i, n->next);',
        1
    )
    c = c.replace(
        'removed.htable[0] = n;',
        'ksu_avtab_htable_set(removed, 0, n);',
        1
    )

    old_open = '''static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,
                               const char *o)
{
    struct type_datum *src, *tgt, *def;'''
    new_open = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,
                               const char *o)
{
    struct type_datum *src, *tgt, *def;'''
    if old_open in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\nstatic bool add_filename_trans' not in c:
        c = c.replace(old_open, new_open, 1)

    old_close = '''free_trans:
    kfree(trans);
out:
    return false;
}'''
    new_close = '''free_trans:
    kfree(trans);
out:
    return false;
}
#else
static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,
                               const char *o)
{
    struct type_datum *src, *tgt, *def;
    struct class_datum *cls;
    struct filename_trans key;
    struct filename_trans_datum *datum;
    struct filename_trans *new_key;
    struct filename_trans_datum *new_datum;
    int rc;

    src = symtab_search(&db->p_types, s);
    if (!src) { pr_warn("source type %s does not exist\\n", s); return false; }
    tgt = symtab_search(&db->p_types, t);
    if (!tgt) { pr_warn("target type %s does not exist\\n", t); return false; }
    cls = symtab_search(&db->p_classes, c);
    if (!cls) { pr_warn("class %s does not exist\\n", c); return false; }
    def = symtab_search(&db->p_types, d);
    if (!def) { pr_warn("default type %s does not exist\\n", d); return false; }

    key.stype = src->value;
    key.ttype = tgt->value;
    key.tclass = cls->value;
    key.name = o;

    datum = hashtab_search(db->filename_trans, &key);
    if (datum) {
        datum->otype = def->value;
        return true;
    }

    new_key = kzalloc(sizeof(*new_key), GFP_KERNEL);
    if (!new_key) return false;
    new_key->stype = src->value;
    new_key->ttype = tgt->value;
    new_key->tclass = cls->value;
    new_key->name = kstrdup(o, GFP_KERNEL);
    if (!new_key->name) { kfree(new_key); return false; }

    new_datum = kzalloc(sizeof(*new_datum), GFP_KERNEL);
    if (!new_datum) { kfree(new_key->name); kfree(new_key); return false; }
    new_datum->otype = def->value;

    rc = hashtab_insert(db->filename_trans, new_key, new_datum);
    if (rc) {
        kfree(new_datum);
        kfree(new_key->name);
        kfree(new_key);
        return false;
    }

    ebitmap_set_bit(&db->filename_trans_ttypes, tgt->value, 1);
    return true;
}
#endif'''
    if old_close in c and '#else\nstatic bool add_filename_trans' not in c:
        c = c.replace(old_close, new_close, 1)

    m = re.search(r'^static bool add_type\(struct policydb \*db, const char \*type_name, bool attr\)\n\{', c, re.MULTILINE)
    if m and 'KSU_ADD_TYPE_FLEX_ARRAY' not in c:
        start = m.start()
        depth = 0; end = -1; i = m.end() - 1
        while i < len(c):
            if c[i] == '{': depth += 1
            elif c[i] == '}':
                depth -= 1
                if depth == 0:
                    end = i; break
            i += 1
        if end > 0:
            orig_func = c[start:end+1]
            flex_version = r'''static bool add_type_flex_419(struct policydb *db, const char *type_name, bool attr) {
    /* KSU_ADD_TYPE_FLEX_ARRAY */
    struct type_datum *type = symtab_search(&db->p_types, type_name);
    if (type) { pr_warn("Type %s already exists\n", type_name); return true; }

    u32 value = ++db->p_types.nprim;
    int k;
    void *zero = NULL;
    struct ebitmap empty_bm;

    type = (struct type_datum *)kzalloc(sizeof(struct type_datum), GFP_KERNEL);
    if (!type) { pr_err("add_type: alloc type_datum failed.\n"); return false; }
    type->primary = 1;
    type->value = value;
    type->attribute = attr;
    char *key = kstrdup(type_name, GFP_KERNEL);
    if (!key) { pr_err("add_type: alloc key failed.\n"); return false; }
    if (symtab_insert(&db->p_types, key, type)) { pr_err("add_type: insert symtab failed.\n"); return false; }

    struct flex_array *new_tama = flex_array_alloc(sizeof(struct ebitmap), value, GFP_KERNEL);
    if (!new_tama) { pr_err("add_type: flex_array_alloc type_attr_map_array failed\n"); return false; }
    memset(&empty_bm, 0, sizeof(empty_bm));
    for (k = 0; k < value; k++)
        flex_array_put(new_tama, k, &empty_bm, GFP_KERNEL);
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

    struct flex_array *new_tvts = flex_array_alloc(sizeof(void *), value, GFP_KERNEL);
    if (!new_tvts) { pr_err("add_type: flex_array_alloc type_val_to_struct_array failed\n"); return false; }
    for (k = 0; k < value; k++)
        flex_array_put_ptr(new_tvts, k, zero, GFP_KERNEL);
    for (k = 0; k < value - 1; k++) {
        void *pv = flex_array_get_ptr(db->type_val_to_struct_array, k);
        if (pv) flex_array_put_ptr(new_tvts, k, pv, GFP_KERNEL);
    }
    flex_array_free(db->type_val_to_struct_array);
    db->type_val_to_struct_array = new_tvts;
    flex_array_put_ptr(new_tvts, value - 1, type, GFP_KERNEL);

    struct flex_array *new_names = flex_array_alloc(sizeof(char *), value, GFP_KERNEL);
    if (!new_names) { pr_err("add_type: flex_array_alloc sym_val_to_name failed\n"); return false; }
    for (k = 0; k < value; k++)
        flex_array_put_ptr(new_names, k, zero, GFP_KERNEL);
    for (k = 0; k < value - 1; k++) {
        void *pv = flex_array_get_ptr(db->sym_val_to_name[SYM_TYPES], k);
        if (pv) flex_array_put_ptr(new_names, k, pv, GFP_KERNEL);
    }
    flex_array_free(db->sym_val_to_name[SYM_TYPES]);
    db->sym_val_to_name[SYM_TYPES] = new_names;
    flex_array_put_ptr(new_names, value - 1, key, GFP_KERNEL);

    int i;
    for (i = 0; i < db->p_roles.nprim; ++i) {
        ebitmap_set_bit(&db->role_val_to_struct[i]->types, value - 1, 1);
    }
    return true;
}
'''
            wrapped = (orig_func
                       .replace('static bool add_type(struct policydb *db, const char *type_name, bool attr)\n{',
                                'static bool add_type_5_10(struct policydb *db, const char *type_name, bool attr)\n{', 1))
            new_func = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n' + wrapped + '\n#else\n'
                        + flex_version + '\n#endif\n\n'
                        'static bool add_type(struct policydb *db, const char *type_name, bool attr) {\n'
                        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
                        '    return add_type_5_10(db, type_name, attr);\n'
                        '#else\n'
                        '    return add_type_flex_419(db, type_name, attr);\n'
                        '#endif\n'
                        '}')
            c = c[:start] + new_func + c[end+1:]

    old = '    struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];'
    new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
           '    struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];\n'
           '#else\n'
           '    struct ebitmap *sattr = (struct ebitmap *)flex_array_get(db->type_attr_map_array, type->value - 1);\n'
           '#endif')
    if old in c and new not in c:
        c = c.replace(old, new, 1)

    old = ('void ksu_destroy_sepolicy(struct selinux_policy *pol)\n'
           '{\n'
           '    policydb_destroy(&pol->policydb);\n'
           '    kfree(pol);\n'
           '}\n'
           '\n'
           'struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)\n'
           '{')
    new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
           'void ksu_destroy_sepolicy(struct selinux_policy *pol)\n'
           '{\n'
           '    policydb_destroy(&pol->policydb);\n'
           '    kfree(pol);\n'
           '}\n'
           '\n'
           'struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)\n'
           '{')
    if old in c and new not in c:
        c = c.replace(old, new, 1)

    old_close = ('out_free_data:\n'
                 '    kvfree(data);\n'
                 '\n'
                 '    return ERR_PTR(ret);\n'
                 '}\n')
    new_close = ("out_free_data:\n"
                 "    kvfree(data);\n"
                 "\n"
                 "    return ERR_PTR(ret);\n"
                 "}\n"
                 "#else\n"
                 "void ksu_destroy_sepolicy(struct selinux_policy *pol) { (void)pol; }\n"
                 "struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)\n"
                 "{\n"
                 "    (void)old_pol;\n"
                 "    return ERR_PTR(-EOPNOTSUPP);\n"
                 "}\n"
                 "#endif\n")
    if old_close in c and '#else\nvoid ksu_destroy_sepolicy' not in c:
        c = c.replace(old_close, new_close, 1)

    if c != original:
        write(p, c); total += 1
        print(f"  ✅ selinux/sepolicy.c: FIX 9 complet")

# --- FIX 10 v2 : minmax.h → kernel.h ---
if os.path.isdir(ksu_root):
    for dp, dn, fn in os.walk(ksu_root):
        for f in fn:
            if not f.endswith(('.c', '.h')): continue
            p = os.path.join(dp, f)
            try: c = read(p)
            except Exception: continue
            if '#include <linux/minmax.h>' not in c: continue
            if 'KSU_MINMAX_COMPAT' in c: continue
            c = c.replace(
                '#include <linux/minmax.h>',
                '/* KSU_MINMAX_COMPAT: kernel.h fournit min_t/max_t sur tous les kernels */\n'
                '#include <linux/kernel.h>',
                1)
            write(p, c); total += 1
            print(f"  ✅ {os.path.relpath(p, GW)}: minmax.h → kernel.h")

# --- FIX 11 : sched/signal.h et sched/task.h ---
if os.path.isdir(ksu_root):
    for dp, dn, fn in os.walk(ksu_root):
        for f in fn:
            if not f.endswith('.c'): continue
            p = os.path.join(dp, f)
            try: c = read(p)
            except Exception: continue
            if not any(s in c for s in ('tasklist_lock', 'init_task', 'task_pgrp', 'task_session')): continue
            original = c
            c = ensure_inc_after_last(c, '<linux/sched/signal.h>')
            c = ensure_inc_after_last(c, '<linux/sched/task.h>')
            if c != original:
                write(p, c); total += 1
                print(f"  ✅ {os.path.relpath(p, GW)}: sched/signal.h + sched/task.h")

# --- FIX 12 : selinux_hide.c dual-path 4.19 ---
p = os.path.join(ksu_root, "feature", "selinux_hide.c")
if os.path.isfile(p):
    c = read(p); original = c

    compat = (
        "/* ============ Compat 4.19 (dual-path) ============ */\n"
        "#include <linux/version.h>\n"
        "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n"
        "#define KSU_SELINUX_HIDE_BACKUP 0\n"
        "struct selinux_policy *backup_sepolicy;\n"
        "#define symtab_search(s, name) hashtab_search(&(s)->table, name)\n"
        "extern struct mutex selinux_status_lock;\n"
        "extern struct page *selinux_status_page;\n"
        "#define ksu_status_lock()   mutex_lock(&selinux_status_lock)\n"
        "#define ksu_status_unlock() mutex_unlock(&selinux_status_lock)\n"
        "#define ksu_status_page     (selinux_status_page)\n"
        "#else\n"
        "#define KSU_SELINUX_HIDE_BACKUP 1\n"
        "#define ksu_status_lock()   mutex_lock(&selinux_state.status_lock)\n"
        "#define ksu_status_unlock() mutex_unlock(&selinux_state.status_lock)\n"
        "#define ksu_status_page     (selinux_state.status_page)\n"
        "#endif\n\n"
    )
    if 'KSU_SELINUX_HIDE_BACKUP' not in c:
        c = c.replace('static DEFINE_MUTEX(selinux_hide_mutex);',
                      compat + 'static DEFINE_MUTEX(selinux_hide_mutex);', 1)

    c = c.replace('mutex_lock(&selinux_state.status_lock);', 'ksu_status_lock();')
    c = c.replace('mutex_unlock(&selinux_state.status_lock);', 'ksu_status_unlock();')
    c = c.replace('selinux_state.status_page', 'ksu_status_page')

    old_drop = ("void ksu_selinux_hide_drop_backup_if_unused()\n"
                "{\n"
                "    mutex_lock(&selinux_hide_mutex);")
    new_drop = ("void ksu_selinux_hide_drop_backup_if_unused()\n"
                "{\n"
                "#if KSU_SELINUX_HIDE_BACKUP\n"
                "    mutex_lock(&selinux_hide_mutex);")
    if old_drop in c and new_drop not in c:
        c = c.replace(old_drop, new_drop, 1)
    old_tail = ("    mutex_unlock(&selinux_hide_mutex);\n"
                "}\n"
                "\n"
                "/*\n"
                " * Caveat:  Mutates scontext.")
    new_tail = ("    mutex_unlock(&selinux_hide_mutex);\n"
                "#endif // KSU_SELINUX_HIDE_BACKUP\n"
                "}\n"
                "\n"
                "#if KSU_SELINUX_HIDE_BACKUP\n"
                "/*\n"
                " * Caveat:  Mutates scontext.")
    if old_tail in c and new_tail not in c:
        c = c.replace(old_tail, new_tail, 1)

    stubs = (
        "\n"
        "#else /* LINUX_VERSION_CODE < 5.10 : pas de backup sepolicy sur 4.19 */\n"
        "\n"
        "static int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len,\n"
        "                                               u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p)\n"
        "{\n"
        "    if (orig_sid_p)\n"
        "        *orig_sid_p = SECSID_NULL;\n"
        "    if (orig_rc_p)\n"
        "        *orig_rc_p = -EOPNOTSUPP;\n"
        "    return -EOPNOTSUPP;\n"
        "}\n"
        "\n"
        "static int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext,\n"
        "                                               u32 *scontext_len)\n"
        "{\n"
        "    if (scontext)\n"
        "        *scontext = NULL;\n"
        "    *scontext_len = 0;\n"
        "    return -EOPNOTSUPP;\n"
        "}\n"
        "\n"
        "static void security_compute_av_user_with_policy(struct selinux_policy *policy, u32 ssid, u32 tsid, u16 tclass,\n"
        "                                                 struct av_decision *avd)\n"
        "{\n"
        "    avd->allowed = 0;\n"
        "    avd->auditallow = 0;\n"
        "    avd->auditdeny = 0xffffffff;\n"
        "    avd->seqno = 0;\n"
        "    avd->flags = 0;\n"
        "}\n"
        "\n"
        "#endif /* KSU_SELINUX_HIDE_BACKUP */\n"
    )
    if 'KSU_SELINUX_HIDE_BACKUP' in c and 'ksu_status_lock();' in c and \
       not c.rstrip().endswith('#endif /* KSU_SELINUX_HIDE_BACKUP */'):
        c = c.rstrip('\n') + '\n' + stubs

    if c != original:
        write(p, c); total += 1
        print(f"  ✅ feature/selinux_hide.c: dual-path 4.19")

# --- FIX 13 : Backport VFS (can_umount, path_umount, path_mount) pour 4.19 ---
p = os.path.join(kernel_root, "fs/namespace.c")
if os.path.isfile(p):
    c = read(p)
    if 'int path_umount(' not in c:
        backport_vfs = '''
/* --- Rétroportage KernelSU / FinaSU (fs/namespace.c pour noyau 4.19) --- */
int path_mount(const char *dev_name, struct path *path,
               const char *type_page, unsigned long flags, void *data_page)
{
    int ret;
    char *buf = kmalloc(PATH_MAX, GFP_KERNEL);
    char *dir_name;

    if (!buf)
        return -ENOMEM;

    dir_name = d_path(path, buf, PATH_MAX);
    if (IS_ERR(dir_name)) {
        kfree(buf);
        return PTR_ERR(dir_name);
    }

    ret = do_mount(dev_name, dir_name, type_page, flags, data_page);
    kfree(buf);
    return ret;
}

static int can_umount(const struct path *path, int flags)
{
    struct mount *mnt = real_mount(path->mnt);

    if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
        return -EINVAL;
    if (!may_mount())
        return -EPERM;
    if (path->dentry != path->mnt->mnt_root)
        return -EINVAL;
    if (!check_mnt(mnt))
        return -EINVAL;
    if (mnt->mnt.mnt_flags & MNT_LOCKED)
        return -EINVAL;
    return 0;
}

int path_umount(struct path *path, int flags)
{
    struct mount *mnt = real_mount(path->mnt);
    int ret;

    ret = can_umount(path, flags);
    if (!ret)
        ret = do_umount(mnt, flags);

    dput(path->dentry);
    mntput_no_expire(mnt);
    return ret;
}
'''
        c = c.rstrip() + '\n' + backport_vfs
        write(p, c)
        total += 1
        print("  ✅ fs/namespace.c: backport can_umount + path_umount + path_mount réussi")

p_fsh = os.path.join(kernel_root, "include/linux/fs.h")
if os.path.isfile(p_fsh):
    c_fsh = read(p_fsh)
    if 'int path_umount(' not in c_fsh:
        c_fsh = c_fsh.replace(
            '#endif /* _LINUX_FS_H */',
            'extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags, void *data_page);\n'
            'extern int path_umount(struct path *path, int flags);\n'
            '#endif /* _LINUX_FS_H */',
            1
        )
        write(p_fsh, c_fsh)
        total += 1
        print("  ✅ include/linux/fs.h: déclarations path_mount + path_umount ajoutées")

print(f"  ✅ portage 4.19 : {total} fichier(s)")
FIXEOF

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
grep -q "^CONFIG_KSU=y" out/.config || { echo "❌ CONFIG_KSU off"; exit 1; }
grep -q "^CONFIG_KSU_SUSFS=y" out/.config || { echo "❌ CONFIG_KSU_SUSFS off"; exit 1; }
grep -q "^CONFIG_KSU_SUSFS_SUS_KSTAT=y" out/.config || { echo "❌ CONFIG_KSU_SUSFS_SUS_KSTAT off"; exit 1; }

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
