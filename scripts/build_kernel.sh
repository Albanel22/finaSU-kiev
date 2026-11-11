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

echo "=== Build FinaSU ($FINASU_REF) — noyau cible 4.19 ==="
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

# Patch SUSFS adapté au noyau 4.19.325, provenant d'un commit immuable
# de la branche finaSU-kiev-Manus.
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
a2VseSgmc3VzZnNfaXNfc2RjYXJkX2FuZHJvaWRfZGF0YV9ub3RfZGVjcnlwdGVkKSAmJgorCSAg
ICBzdXNmc19pc19jdXJyZW50X2tzdV9kb21haW4oKSkgeworCQltbnQgPSBzdXNmc19hbGxvY19u
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
# Le patch amont est historiquement proche de 4.19, mais cinq contextes
# diffèrent dans ce commit précis. On accepte uniquement ces cinq rejets.
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
echo "✅ Patch SUSFS 4.19 appliqué avec adaptation contrôlée des cinq contextes" | tee -a "$AUDIT"

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

# ==================== 4b. COMPATIBILITÉ ====================
# Les sources FinaSU v1.5.0 restent intactes : aucun rules.c réécrit,
# aucun stub SELinux et aucun shim path_mount/path_umount.
echo "  ✅ sources FinaSU v1.5.0 conservées sans neutralisation"

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

# ==================== 6. MOTOROLA ====================
# Le noyau Motorola attend ces symboles exportés pour conserver la liaison
# avec le pilote tactile. Ce shim est conservé volontairement.
cat >> techpack/display/msm/msm_drv.c <<'EOF'

#include <linux/notifier.h>
#include <linux/module.h>

static BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);

int panel_register_notifier(struct notifier_block *nb)
{
	return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_register_notifier);

int panel_unregister_notifier(struct notifier_block *nb)
{
	return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_unregister_notifier);

void touch_set_state(int state)
{
	(void)state;
}
EXPORT_SYMBOL(touch_set_state);
EOF

# ==================== 7. COMPILATION ====================
echo "=== Compilation ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" $SIG_ARGS \
  -j$(nproc) Image 2>&1 | tee build.log
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
