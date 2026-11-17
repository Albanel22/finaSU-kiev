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

# URLs de TON dépôt pour garantir la cohérence des patches
REPO_BRANCH="finaSU-kiev-Qwen2"
REPO_RAW="https://raw.githubusercontent.com/Albanel22/finaSU-kiev/${REPO_BRANCH}/patches"

echo "=== Build FinaSU ($FINASU_REF) — 4.19 + SuSFS + INLINE (via ton dépôt) ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"
MGR_GDRIVE_ID="1Qr07fjThXjmIz_DAmW2GZepoWrNIikXR"

mkdir -p "$GITHUB_WORKSPACE/output"
mkdir -p "$GITHUB_WORKSPACE/patches"
AUDIT="$GITHUB_WORKSPACE/output/audit-${VER}.txt"
SPEC="$GITHUB_WORKSPACE/output/hooks-spec.txt"
: > "$AUDIT"
: > "$SPEC"

summarize() {
    local rc=$?
    set +e
    local BL="$GITHUB_WORKSPACE/kernel_sources/build.log"
    local SUM="$GITHUB_WORKSPACE/output/build-summary.txt"
    {
        echo "=== RÉSUMÉ DU BUILD (code de sortie $rc) ==="
        echo "########## SPEC / SYMBOLES / SOURCES ##########"
        head -n 300 "$SPEC" 2>/dev/null || echo "(spec absente)"
        echo ""
        if [ -f "$BL" ]; then
            echo "########## HOOK-SITES MANQUANTS ##########"
            grep -nE "SUSFS Inline:|hook-site check" "$BL" | head -30
            echo ""
            echo "########## AUTRES ANOMALIES ##########"
            grep -nE "error:|undefined symbol|fatal error|Error [0-9]+|No rule to make target|\*\*\*|Stop\.|unknown type name|UAPI headers|conflicting" "$BL" | tail -45
            echo ""
            echo "########## 30 DERNIÈRES LIGNES DE build.log ##########"
            tail -n 30 "$BL"
        else
            echo "pas de build.log : arrêt avant compilation"
            tail -n 25 "$AUDIT" 2>/dev/null
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

# ==================== 1a. APPLICATION DES PATCHS DE TON DÉPÔT ====================
echo "=== Application des patches depuis ton dépôt ===" | tee -a "$AUDIT"

# 1. Patch SUSFS de base
SUSFS_419_PATCH="$GITHUB_WORKSPACE/patches/susfs_patch_to_4.19.patch"
curl -fL --retry 3 "$REPO_RAW/susfs_patch_to_4.19.patch" -o "$SUSFS_419_PATCH"
echo "Patch SUSFS téléchargé : $(sha256sum "$SUSFS_419_PATCH" | cut -d' ' -f1)" | tee -a "$AUDIT"

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

MANUAL_SUSFS_PATCH="$GITHUB_WORKSPACE/patches/susfs_419_manual_fix.patch"
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

# 2. Script d'hooks inline (JackA1ltman / ton dépôt)
INLINE_HOOK_SH="$GITHUB_WORKSPACE/patches/susfs_inline_hook_patches.sh"
curl -fL --retry 3 "$REPO_RAW/susfs_inline_hook_patches.sh" -o "$INLINE_HOOK_SH" || \
curl -fL --retry 3 "$REPO_RAW/susfs_inline_hook_patches" -o "$INLINE_HOOK_SH" # Fallback sans .sh

if [ ! -s "$INLINE_HOOK_SH" ] || ! grep -q "ksu_handle_execveat" "$INLINE_HOOK_SH"; then
    echo "❌ Script de hooks inline absent ou invalide" | tee -a "$AUDIT"
    exit 1
fi
echo "✅ Script hooks inline téléchargé" | tee -a "$AUDIT"

# On retire security/selinux/hooks.c pour éviter le conflit u:r:su:s0
sed -i '/^    security\/selinux\/hooks\.c$/d' "$INLINE_HOOK_SH"

set +e
bash "$INLINE_HOOK_SH" 2>&1 | tee -a "$AUDIT"
set -e

if ! grep -q "ksu_handle_execveat_sucompat" fs/exec.c; then
    echo "❌ Le script n'a pas patché fs/exec.c" | tee -a "$AUDIT"
    exit 1
fi
echo "✅ Hooks inline de base appliqués" | tee -a "$AUDIT"

# 3. Script syscall_hook_patches.sh (LA CLÉ POUR PREINIT)
SYSCALL_HOOK_SH="$GITHUB_WORKSPACE/patches/syscall_hook_patches.sh"
curl -fL --retry 3 "$REPO_RAW/syscall_hook_patches.sh" -o "$SYSCALL_HOOK_SH"

if [ -s "$SYSCALL_HOOK_SH" ]; then
    echo "✅ syscall_hook_patches.sh téléchargé, application..." | tee -a "$AUDIT"
    set +e
    bash "$SYSCALL_HOOK_SH" 2>&1 | tee -a "$AUDIT"
    set -e
    echo "✅ Hooks syscall (preinit) appliqués" | tee -a "$AUDIT"
else
    echo "⚠️ syscall_hook_patches.sh non trouvé, on continue avec les hooks de base" | tee -a "$AUDIT"
fi

# Correctif signature ksu_handle_sys_read (void vs int)
sed -i 's/extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd);/extern __attribute__((cold)) void ksu_handle_sys_read(unsigned int fd);/' fs/read_write.c 2>/dev/null || true

# ==================== 1b. STUBS path_mount/path_umount ====================
if grep -q "finasu_backport_path_mount_419" fs/namespace.c 2>/dev/null; then
    sed -i '/\/\* === finasu_backport_path_mount_419/,/\/\* < 5.9 \*\//d' fs/namespace.c
fi
if ! grep -q "finasu_stub_path_mount_419" fs/namespace.c; then
cat >> fs/namespace.c <<'NS419'
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
int path_umount(struct path *path, int flags) { pr_info("path_umount: no-op\n"); return 0; }
int path_mount(const char *dev_name, struct path *path, unsigned long flags, void *data) { pr_info("path_mount: no-op\n"); return 0; }
#endif
NS419
fi

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
    echo "✅ Signature manager OK" | tee -a "$AUDIT"
fi

# ==================== 3g/3h. RETRAIT DES 'static' + O_CLOEXEC ====================
for f in security/selinux/ss/status.c security/selinux/selinuxfs.c security/selinux/status.c; do
    [ -f "$f" ] || continue
    sed -i -E 's/^static[[:space:]]+(struct page[[:space:]]*\*[[:space:]]*selinux_status_page)/\1/' "$f"
    sed -i -E 's/^static[[:space:]]+(DEFINE_MUTEX\(selinux_status_lock\))/\1/' "$f"
done
[ -f "security/selinux/ss/services.c" ] && sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
[ -f "security/selinux/hooks.c" ] && sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c

grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null | xargs -r sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fdod_flags(0)/g' || true
grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null | xargs -r sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g; s/O_RDWR|O_CLOEXEC/O_RDWR/g; s/, O_CLOEXEC)/)/g' || true

# ==================== 4a. rules.c dual-path ====================
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

static size_t sepol_remaining(const struct sepol_batch_cursor *cursor) { return (size_t)(cursor->end - cursor->cur); }
static int sepol_read_cmd_header(struct sepol_batch_cursor *cursor, struct sepol_data *header) {
    if (sepol_remaining(cursor) < sizeof(*header)) return -EINVAL;
    memcpy(header, cursor->cur, sizeof(*header)); cursor->cur += sizeof(*header); return 0;
}
static int sepol_read_string(struct sepol_batch_cursor *cursor, const char **out) {
    u32 len; const char *str;
    if (sepol_remaining(cursor) < sizeof(len)) return -EINVAL;
    memcpy(&len, cursor->cur, sizeof(len)); cursor->cur += sizeof(len);
    if (len >= sepol_remaining(cursor)) return -EINVAL;
    str = (const char *)cursor->cur;
    if (memchr(str, '\0', len) != NULL || str[len] != '\0') return -EINVAL;
    cursor->cur += len + 1;
    if (len == 0) { *out = ALL; return 0; }
    *out = str; return 0;
}
static int sepol_require_not_all(const char *value, const char *name) {
    if (value != ALL) return 0; pr_err("sepol: %s cannot be ALL.\n", name); return -EINVAL;
}
static int sepol_expected_argc(u32 cmd) {
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
static int apply_one_sepolicy_cmd(struct policydb *db, const struct sepol_data *header, const char **args) {
    bool success = false; int ret;
    switch (header->cmd) {
    case KSU_SEPOLICY_CMD_NORMAL_PERM:
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW) success = ksu_allow(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DENY) success = ksu_deny(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_AUDITALLOW) success = ksu_auditallow(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DONTAUDIT) success = ksu_dontaudit(db, args[0], args[1], args[2], args[3]);
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_XPERM:
        ret = sepol_require_not_all(args[3], "operation"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[4], "perm_set"); if (ret < 0) return ret;
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_ALLOW) success = ksu_allowxperm(db, args[0], args[1], args[2], args[4]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_AUDITALLOW) success = ksu_auditallowxperm(db, args[0], args[1], args[2], args[4]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_DONTAUDIT) success = ksu_dontauditxperm(db, args[0], args[1], args[2], args[4]);
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE_STATE:
        ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_PERMISSIVE) success = ksu_permissive(db, args[0]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_ENFORCE) success = ksu_enforce(db, args[0]);
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE: case KSU_SEPOLICY_CMD_TYPE_ATTR:
        ret = sepol_require_not_all(args[0], "type"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "attribute"); if (ret < 0) return ret;
        if (header->cmd == KSU_SEPOLICY_CMD_TYPE) success = ksu_type(db, args[0], args[1]);
        else success = ksu_typeattribute(db, args[0], args[1]);
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
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_CHANGE) success = ksu_type_change(db, args[0], args[1], args[2], args[3]);
        else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_MEMBER) success = ksu_type_member(db, args[0], args[1], args[2], args[3]);
        else pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        return success ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_GENFSCON:
        ret = sepol_require_not_all(args[0], "name"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[1], "path"); if (ret < 0) return ret;
        ret = sepol_require_not_all(args[2], "context"); if (ret < 0) return ret;
        if (!ksu_genfscon(db, args[0], args[1], args[2])) { pr_err("sepol: %d failed.\n", header->cmd); return -EINVAL; }
        return 0;
    default: pr_err("sepol: unknown cmd: %d\n", header->cmd); return -EINVAL;
    }
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
#define KSU_DB419   (&selinux_state.ss->policydb)
#define KSU_LOCK419 write_lock(&selinux_state.ss->policy_rwlock)
#define KSU_UNLOCK419 write_unlock(&selinux_state.ss->policy_rwlock)

static void reset_avc_cache_419(void) {
    if (selinux_state.avc) avc_ss_reset(selinux_state.avc, 0);
    selnl_notify_policyload(0);
    selinux_xfrm_notify_policyload();
}

void apply_kernelsu_rules(void) {
    struct policydb *db;
    if (!getenforce()) pr_info("SELinux permissive or disabled, apply rules! (4.19 path)\n");
    KSU_LOCK419; db = KSU_DB419;
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
    KSU_UNLOCK419;
    reset_avc_cache_419();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    pr_info("KernelSU rules applied (4.19 compatibility path)\n");
}

int handle_sepolicy(void __user *user_data, u64 data_len) {
    struct sepol_batch_cursor cursor; u8 *payload; int ret, success_cmd_count; u32 cmd_index;
    if (!user_data || !data_len) return -EINVAL;
    if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) return -E2BIG;
    payload = kvmalloc((size_t)data_len, GFP_KERNEL);
    if (!payload) return -ENOMEM;
    if (copy_from_user(payload, user_data, (size_t)data_len)) { ret = -EFAULT; goto out_free; }
    if (!getenforce()) pr_info("SELinux permissive or disabled when handle policy!\n");
    KSU_LOCK419;
    cursor.cur = payload; cursor.end = payload + (size_t)data_len;
    ret = 0; success_cmd_count = 0; cmd_index = 0;
    while (cursor.cur < cursor.end) {
        struct sepol_data header; const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
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
        ret = apply_one_sepolicy_cmd(KSU_DB419, &header, args);
        if (ret < 0) pr_err("sepol: cmd #%u failed cmd=%u subcmd=%u\n", cmd_index, header.cmd, header.subcmd);
        else success_cmd_count++;
        cmd_index++;
    }
    KSU_UNLOCK419; reset_avc_cache_419();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    ret = success_cmd_count;
out_free: kvfree(payload); return ret;
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
static void reset_avc_cache(u32 seqno) {
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
    avc_ss_reset(seqno); selnl_notify_policyload(seqno); selinux_status_update_policyload(seqno);
#else
    struct selinux_avc *avc = selinux_state.avc;
    avc_ss_reset(avc, seqno); selnl_notify_policyload(seqno); selinux_status_update_policyload(&selinux_state, seqno);
#endif
    selinux_xfrm_notify_policyload();
}
void apply_kernelsu_rules(void) {
    struct selinux_policy *pol, *old_pol; struct policydb *db;
    if (!getenforce()) pr_info("SELinux permissive or disabled, apply rules!\n");
    mutex_lock(&selinux_state.policy_mutex);
    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    backup_sepolicy = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(backup_sepolicy)) { pr_err("failed to create backup sepolicy: %ld\n", PTR_ERR(backup_sepolicy)); backup_sepolicy = NULL; }
    else {
        backup_sepolicy->sidtab = kzalloc(sizeof(*backup_sepolicy->sidtab), GFP_KERNEL);
        if (!backup_sepolicy->sidtab) { pr_err("failed to alloc backup sidtab\n"); ksu_destroy_sepolicy(backup_sepolicy); backup_sepolicy = NULL; }
        else {
            int ret = policydb_load_isids(&backup_sepolicy->policydb, backup_sepolicy->sidtab);
            if (ret) { pr_err("failed to load isids for backup sepolicy: %d!\n", ret); kfree(backup_sepolicy->sidtab); ksu_destroy_sepolicy(backup_sepolicy); backup_sepolicy = NULL; }
            else { pr_info("backup sepolicy success! latest_granting=%d\n", backup_sepolicy->latest_granting); }
        }
    }
    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) { pr_err("failed to dup selinux_policy: %ld\n", PTR_ERR(pol)); goto out_unlock; }
    db = &pol->policydb;
#if !defined(CONFIG_KSU_SUSFS) || !defined(KSU_SUSFS_HAS_TYPE_REGISTRATION)
    pol->latest_granting = old_pol->latest_granting + 1;
    if (!ksu_set_original_types(db, &old_pol->policydb, pol->latest_granting)) pr_warn("failed to save original type metadata, use backup lookups\n");
#endif
    ksu_type(db, KERNEL_SU_DOMAIN, "domain"); ksu_permissive(db, KERNEL_SU_DOMAIN);
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "mlstrustedsubject"); ksu_typeattribute(db, KERNEL_SU_DOMAIN, "netdomain");
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "bluetoothdomain"); ksu_type(db, KERNEL_SU_FILE, "file_type");
    ksu_typeattribute(db, KERNEL_SU_FILE, "mlstrustedobject"); ksu_allow(db, "domain", KERNEL_SU_FILE, ALL, ALL);
    ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);
    if (db->policyvers >= POLICYDB_VERSION_XPERMS_IOCTL) {
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "blk_file", ALL); ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "fifo_file", ALL);
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "chr_file", ALL); ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "file", ALL);
    }
    ksu_allow(db, "init", KERNEL_SU_DOMAIN, ALL, ALL); ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "read"); ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "read"); ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "process", "sigchld"); ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "read"); ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "getattr"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fd", "use");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "write"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "read");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "open"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "read"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "write");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "connectto"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getopt");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getattr"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "execute");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "getattr"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "map");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "read"); ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "write");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "dir", "search"); ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "open"); ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "binder", ALL); ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
    ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");
#ifdef CONFIG_KSU_SUSFS
    ksu_allow(db, "zygote", "labeledfs", "filesystem", "unmount");
#endif
    rcu_assign_pointer(selinux_state.policy, pol); synchronize_rcu(); ksu_destroy_sepolicy(old_pol);
#ifdef KSU_SUSFS_HAS_TYPE_REGISTRATION
    reset_avc_cache(0);
#else
    reset_avc_cache(pol->latest_granting);
#endif
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
out_unlock: mutex_unlock(&selinux_state.policy_mutex);
}
int handle_sepolicy(void __user *user_data, u64 data_len) {
    struct selinux_policy *pol, *old_pol; struct policydb *db; struct sepol_batch_cursor cursor; u8 *payload;
    int ret, success_cmd_count; u32 cmd_index;
    if (!user_data || !data_len) return -EINVAL;
    if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) return -E2BIG;
    payload = kvmalloc((size_t)data_len, GFP_KERNEL); if (!payload) return -ENOMEM;
    if (copy_from_user(payload, user_data, (size_t)data_len)) { ret = -EFAULT; goto out_free; }
    if (!getenforce()) pr_info("SELinux permissive or disabled when handle policy!\n");
    mutex_lock(&selinux_state.policy_mutex);
    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) { ret = PTR_ERR(pol); pr_err("ksu_dup_sepolicy err: %d\n", ret); goto out_unlock; }
    db = &pol->policydb; cursor.cur = payload; cursor.end = payload + (size_t)data_len;
    ret = 0; success_cmd_count = 0; cmd_index = 0;
    while (cursor.cur < cursor.end) {
        struct sepol_data header; const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 }; int expected_argc; u32 arg_index;
        ret = sepol_read_cmd_header(&cursor, &header);
        if (ret < 0) { pr_err("sepol: failed header #%u\n", cmd_index); goto out_drop_new_policy; }
        expected_argc = sepol_expected_argc(header.cmd);
        if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) { ret = -EINVAL; goto out_drop_new_policy; }
        for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) { ret = sepol_read_string(&cursor, &args[arg_index]); if (ret < 0) goto out_drop_new_policy; }
        ret = apply_one_sepolicy_cmd(db, &header, args);
        if (ret < 0) pr_err("sepol: cmd #%u failed cmd=%u subcmd=%u\n", cmd_index, header.cmd, header.subcmd);
        else success_cmd_count++; cmd_index++;
    }
#if !defined(CONFIG_KSU_SUSFS) || !defined(KSU_SUSFS_HAS_TYPE_REGISTRATION)
    pol->latest_granting = old_pol->latest_granting + 1;
    if (!ksu_advance_original_types(db, &old_pol->policydb, old_pol->latest_granting, pol->latest_granting)) pr_warn("failed to carry original type metadata, use backup lookups\n");
#endif
    rcu_assign_pointer(selinux_state.policy, pol); synchronize_rcu(); ksu_destroy_sepolicy(old_pol);
#ifdef KSU_SUSFS_HAS_TYPE_REGISTRATION
    reset_avc_cache(0);
#else
    reset_avc_cache(pol->latest_granting);
#endif
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    ret = success_cmd_count; goto out_unlock;
out_drop_new_policy: ksu_destroy_sepolicy(pol);
out_unlock: mutex_unlock(&selinux_state.policy_mutex);
out_free: kvfree(payload); return ret;
}
#endif
RULESEOF

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

cd out
../scripts/config --set-val CONFIG_KSU y
../scripts/config --set-val CONFIG_KSU_HOOK_TRACEPOINT n
../scripts/config --set-val CONFIG_KSU_HOOK_SUSFS_INLINE y
../scripts/config --set-val CONFIG_KSU_DEBUG y
../scripts/config --set-val CONFIG_KSU_SUSFS y
../scripts/config --set-val CONFIG_KSU_SUSFS_SUS_PATH y
../scripts/config --set-val CONFIG_KSU_SUSFS_SUS_MOUNT y
../scripts/config --set-val CONFIG_KSU_SUSFS_SUS_KSTAT y
../scripts/config --set-val CONFIG_KSU_SUSFS_SPOOF_UNAME y
../scripts/config --set-val CONFIG_KSU_SUSFS_ENABLE_LOG y
../scripts/config --set-val CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS y
../scripts/config --set-val CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG y
../scripts/config --set-val CONFIG_KSU_SUSFS_OPEN_REDIRECT y
../scripts/config --set-val CONFIG_KSU_SUSFS_SUS_MAP y
../scripts/config --set-val CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER y
../scripts/config --set-val CONFIG_KPROBES y
../scripts/config --set-val CONFIG_HAVE_KPROBES y
../scripts/config --set-val CONFIG_KRETPROBES y
../scripts/config --set-val CONFIG_KALLSYMS y
../scripts/config --set-val CONFIG_KALLSYMS_ALL y
../scripts/config --set-val CONFIG_EXT4_FS y
../scripts/config --set-val CONFIG_HEADERS_INSTALL y
../scripts/config --set-val CONFIG_THREAD_INFO_IN_TASK y
../scripts/config --set-val CONFIG_FTRACE y
../scripts/config --set-val CONFIG_FTRACE_SYSCALLS y
../scripts/config --set-val CONFIG_SECCOMP y
../scripts/config --set-val CONFIG_SECCOMP_FILTER y
../scripts/config --set-val CONFIG_COMPAT y
../scripts/config --set-val CONFIG_COMPAT_32BIT_TIME y
cd ..

make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

grep -q "^CONFIG_KSU=y" out/.config || { echo "❌ CONFIG_KSU off"; exit 1; }
grep -q "^CONFIG_KSU_SUSFS=y" out/.config || { echo "❌ CONFIG_KSU_SUSFS off"; exit 1; }
if ! grep -q "^CONFIG_KSU_HOOK_SUSFS_INLINE=y" out/.config; then
    echo "❌ SUSFS_INLINE refusé"
    exit 1
fi
echo "✅ Backend actif : KSU_HOOK_SUSFS_INLINE" | tee -a "$AUDIT"

echo "=== Installation des UAPI headers ==="
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 headers_install 2>&1 | tail -3

# ==================== 6. MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb){return blocking_notifier_chain_register(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb){return blocking_notifier_chain_unregister(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int s){return;}\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION ====================
echo "=== Compilation ==="
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" KSU_REQUIRE_PREINIT=1 $SIG_ARGS \
    -k -j$(nproc) Image 2>&1 | tee build.log
MAKE_RC=${PIPESTATUS[0]}
set -eo pipefail

if [ "$MAKE_RC" -ne 0 ] || [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED (rc=$MAKE_RC)"
    exit 1
fi
echo "✅ Compilation réussie"
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-${VER}"

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
mkdir -p repack; cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk.apk
unzip -q Magisk.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot && chmod +x repack/magiskboot
rm -rf Magisk.apk lib
cd repack
set +e; ./magiskboot unpack boot.img; set -e
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" ./local_su && chmod 755 ./local_su
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su"
rm -f ./local_su
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img && cd ..

mkdir -p output
cp final_boot.img "output/FinaSU-A-${VER}-boot.img"
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ ${VER} ==="
ls -lh output/
