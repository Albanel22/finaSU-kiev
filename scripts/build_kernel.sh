#!/bin/bash
set -euo pipefail

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
export GITHUB_WORKSPACE

FINASU_URL="${FINASU_URL:-https://github.com/LyraVoid/FinaSU.git}"
FINASU_REF="${FINASU_REF:-v1.6.4}"
KERNEL_PIN="${KERNEL_PIN:-9426323c2acd0865fd565a6dd8a9f39f831cbec3}"
FINASU_EXPECTED_SIZE="${FINASU_EXPECTED_SIZE:-}"
FINASU_EXPECTED_HASH="${FINASU_EXPECTED_HASH:-}"
VER="finasu-A"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"

REPO_RAW="https://raw.githubusercontent.com/Albanel22/finaSU-kiev/finaSU-Qwen-Duck2/patches"

echo "=== Build FinaSU ($FINASU_REF) — 4.19 + SuSFS + INLINE + preinit (CORRIGÉ) ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"
MGR_GDRIVE_ID="11gKehkaCHKPAYbjOcVDx1IIvNc_2t4j9"

mkdir -p "$GITHUB_WORKSPACE/output" "$GITHUB_WORKSPACE/patches"
AUDIT="$GITHUB_WORKSPACE/output/audit-${VER}.txt"
SPEC="$GITHUB_WORKSPACE/output/hooks-spec.txt"
: > "$AUDIT"; : > "$SPEC"

summarize() {
    local rc=$?
    set +e
    local BL="$GITHUB_WORKSPACE/kernel_sources/build.log"
    local SUM="$GITHUB_WORKSPACE/output/build-summary.txt"
    {
        echo "=== RÉSUMÉ DU BUILD (code de sortie $rc) ==="
        echo "########## VERDICT VALIDATEUR + DIAG ##########"
        head -n 160 "$SPEC" 2>/dev/null || echo "(spec absente)"
        echo ""
        if [ -f "$BL" ]; then
            echo "########## HOOK-SITES MANQUANTS ##########"
            grep -nE "SUSFS Inline:|hook-site check" "$BL" | head -30
            echo ""
            echo "########## ERREURS DE COMPILATION ##########"
            grep -nE "error:|undefined symbol|fatal error|\*\*\*|Stop\." "$BL" | head -50
            echo ""
            echo "########## 25 DERNIÈRES LIGNES ##########"
            tail -n 25 "$BL"
        else
            echo "pas de build.log : arrêt avant compilation"
            tail -n 40 "$AUDIT" 2>/dev/null
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
    git checkout -q "$KERNEL_PIN" || { echo "❌ commit introuvable"; exit 1; }
fi
echo "Source figée : $(git rev-parse HEAD)" | tee -a "$AUDIT"

# ==================== 1a. PATCH SUSFS ====================
SUSFS_419_PATCH="$GITHUB_WORKSPACE/patches/susfs_patch_to_4.19.patch"
curl -fL --retry 3 "$REPO_RAW/susfs_patch_to_4.19.patch" -o "$SUSFS_419_PATCH"
echo "Patch SUSFS : $(sha256sum "$SUSFS_419_PATCH" | cut -c1-16)" | tee -a "$AUDIT"

set +e
git apply --reject --whitespace=nowarn "$SUSFS_419_PATCH" 2>&1 | tee -a "$AUDIT"
set -e
EXPECTED_REJECTS=$'fs/Makefile.rej\nfs/namespace.c.rej\nfs/proc/task_mmu.c.rej\nfs/super.c.rej\nmm/memory.c.rej'
mapfile -t SUSFS_REJECTS < <(find . -name '*.rej' -printf '%P\n' | sort)
if [ "${#SUSFS_REJECTS[@]}" -ne 5 ] || [ "$(printf '%s\n' "${SUSFS_REJECTS[@]}")" != "$EXPECTED_REJECTS" ]; then
    echo "❌ Rejets SUSFS inattendus:" | tee -a "$AUDIT"
    printf '  %s\n' "${SUSFS_REJECTS[@]}" | tee -a "$AUDIT"
    exit 1
fi
for r in "${SUSFS_REJECTS[@]}"; do rm -f "$r"; done

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
git apply --whitespace=nowarn "$MANUAL_SUSFS_PATCH"
[ -z "$(find . -name '*.rej' -print)" ] || { echo "❌ rejets résiduels"; exit 1; }
echo "✅ Patch SUSFS appliqué" | tee -a "$AUDIT"

# CORRECTIF : mon patch manuel écrase la détection SUSFS_KERNEL_READ_NEW du hunk upstream
python3 - <<'MKEOF' 2>&1 | tee -a "$AUDIT"
p = "fs/Makefile"
c = open(p).read()
if 'SUSFS_KERNEL_READ_NEW' not in c and 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' in c:
    old = 'obj-$(CONFIG_KSU_SUSFS) += susfs.o\n'
    new = (old +
      'ifeq ($(shell grep -q "ssize_t kernel_read" $(srctree)/fs/read_write.c $(srctree)/fs/exec.c 2>/dev/null; echo $$?),0)\n'
      'CFLAGS_susfs.o += -DSUSFS_KERNEL_READ_NEW\n'
      'endif\n')
    open(p,'w').write(c.replace(old, new, 1))
    print("  ✅ fs/Makefile : détection SUSFS_KERNEL_READ_NEW restaurée")
else:
    print("  ℹ️ fs/Makefile : détection déjà présente ou ligne absente")
MKEOF

# ==================== 1b. STUBS path_mount/path_umount ====================
if ! grep -q "finasu_stub_path_mount_419" fs/namespace.c; then
cat >> fs/namespace.c <<'NS419'

/* === finasu_stub_path_mount_419 : API 5.9 absente de 4.19 === */
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
int path_umount(struct path *path, int flags) { return 0; }
int path_mount(const char *dev_name, struct path *path, unsigned long flags, void *data) { return 0; }
#endif
NS419
fi
echo "✅ Stubs path_mount/path_umount" | tee -a "$AUDIT"

# ==================== 2. INTÉGRATION FinaSU (AVANT les hooks !) ====================
echo "=== Intégration FinaSU ==="
rm -rf drivers/kernelsu FinaSU 2>/dev/null || true
git clone "$FINASU_URL" FinaSU
git -C FinaSU fetch --tags --force 2>/dev/null || true

if [ "$FINASU_REF" = "latest" ] || [ -z "$FINASU_REF" ]; then
    RESOLVED="$(git -C FinaSU tag -l 'v*' --sort=-v:refname | head -1 || true)"
    [ -z "$RESOLVED" ] && RESOLVED="$(git -C FinaSU describe --tags --abbrev=0 2>/dev/null || true)"
    [ -z "$RESOLVED" ] && RESOLVED="master"
    FINASU_REF="$RESOLVED"
    echo "✅ FinaSU résolu (latest) : $FINASU_REF" | tee -a "$AUDIT"
fi

set +e
git -C FinaSU checkout -q "$FINASU_REF"
CO_RC=$?
[ $CO_RC -ne 0 ] && git -C FinaSU checkout -q master && CO_RC=$?
[ $CO_RC -ne 0 ] && git -C FinaSU checkout -q main && CO_RC=$?
set -e
[ $CO_RC -eq 0 ] || { echo "❌ checkout FinaSU impossible"; exit 1; }

FINASU_COMMIT="$(git -C FinaSU rev-parse HEAD)"
FINASU_DESC="$(git -C FinaSU describe --tags --always)"
echo "FinaSU effectif : $FINASU_DESC ($FINASU_COMMIT)" | tee -a "$AUDIT"
{
  echo "FINASU_REF=$FINASU_REF"
  echo "FINASU_COMMIT=$FINASU_COMMIT"
  echo "FINASU_DESC=$FINASU_DESC"
  echo "DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$GITHUB_WORKSPACE/output/finasu.lock" | tee -a "$AUDIT"
[ -f FinaSU/kernel/setup.sh ] && bash FinaSU/kernel/setup.sh --dir "$PWD/FinaSU"
if [ ! -e drivers/kernelsu ]; then
    ln -sfn ../FinaSU/kernel drivers/kernelsu
    grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
[ -e drivers/kernelsu ] || { echo "❌ drivers/kernelsu absent"; exit 1; }
KSU_DIR="drivers/kernelsu"
KSU_REPO_ROOT="$GITHUB_WORKSPACE/kernel_sources/FinaSU"
echo "✅ FinaSU intégré (drivers/kernelsu existe → les gardes du script de hooks fonctionneront)" | tee -a "$AUDIT"

# ==================== 2g. HOOKS INLINE ====================
HOOK_SH="$GITHUB_WORKSPACE/patches/susfs_inline_hook_patches.sh"
curl -fL --retry 3 "$REPO_RAW/susfs_inline_hook_patches.sh" -o "$HOOK_SH" || \
curl -fL --retry 3 "$REPO_RAW/susfs_inline_hook_patches" -o "$HOOK_SH" || true
if [ ! -s "$HOOK_SH" ] || ! grep -q "ksu_handle_execveat" "$HOOK_SH"; then
    echo "❌ script de hooks inline absent/invalide"; exit 1
fi
sed -i '/^[[:space:]]*security\/selinux\/hooks\.c[[:space:]]*$/d' "$HOOK_SH"
echo "=== Application des hooks inline ===" | tee -a "$AUDIT"
set +e; bash "$HOOK_SH" 2>&1 | tee -a "$AUDIT"; set -e

grep -q "ksu_handle_execveat_sucompat" fs/exec.c || { echo "❌ fs/exec.c non patché"; exit 1; }
grep -q "ksu_handle_setresuid" kernel/sys.c   || { echo "❌ kernel/sys.c non patché"; exit 1; }
echo "✅ hooks exec + setresuid appliqués" | tee -a "$AUDIT"

sed -i 's/extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd);/extern __attribute__((cold)) void ksu_handle_sys_read(unsigned int fd);/' fs/read_write.c

# Contenu de syscall_hook_patches.sh : informatif, NON exécuté (risque de noms rejetés)
set +e
{
  echo "### syscall_hook_patches.sh (NON exécuté — contenu pour analyse) ###"
  curl -fL --retry 2 "$REPO_RAW/syscall_hook_patches.sh" 2>/dev/null | head -60 || echo "(absent)"
} > "$SPEC" 2>&1
set -e

# ==================== 3. SIGNATURE MANAGER ====================
MGR_APK="$GITHUB_WORKSPACE/patches/manager.apk"
[ -f "$MGR_APK" ] || gdown "https://drive.google.com/uc?id=${MGR_GDRIVE_ID}" -O "$MGR_APK" 2>&1 || true
if [ -z "$FINASU_EXPECTED_SIZE" ] && [ -f "$MGR_APK" ]; then
    SIG_OUT=$(python3 - "$MGR_APK" <<'PYEOF' || true
import hashlib, struct, sys
data = open(sys.argv[1],'rb').read()
e = data.rfind(b'PK\x05\x06')
if e < 0: sys.exit(2)
cd_off = struct.unpack_from('<I', data, e+16)[0]
if data[cd_off-16:cd_off] != b'APK Sig Block 42': sys.exit(3)
blk = struct.unpack_from('<Q', data, cd_off-24)[0]
pos = cd_off-blk; end = cd_off-24; cert=None
while pos < end and cert is None:
    plen = struct.unpack_from('<Q', data, pos)[0]
    pid  = struct.unpack_from('<I', data, pos+8)[0]
    if pid in (0x7109871a, 0xf05368c0):
        p = pos+24
        dg = struct.unpack_from('<I', data, p)[0]; p += 4+dg+4
        cl = struct.unpack_from('<I', data, p)[0]; p += 4
        cert = data[p:p+cl]
    pos += 8+plen
if cert is None: sys.exit(4)
print("0x%x" % len(cert)); print(hashlib.sha256(cert).hexdigest())
PYEOF
)
    [ -n "$SIG_OUT" ] && FINASU_EXPECTED_SIZE=$(echo "$SIG_OUT"|sed -n 1p) && FINASU_EXPECTED_HASH=$(echo "$SIG_OUT"|sed -n 2p)
fi
SIG_ARGS=""
if [ -n "$FINASU_EXPECTED_SIZE" ] && [ -n "$FINASU_EXPECTED_HASH" ]; then
    SIG_ARGS="KSU_EXPECTED_SIZE=$FINASU_EXPECTED_SIZE KSU_EXPECTED_HASH=$FINASU_EXPECTED_HASH"
    echo "✅ Signature manager OK" | tee -a "$AUDIT"
fi

{
  echo "MGR_GDRIVE_ID=$MGR_GDRIVE_ID"
  echo "MGR_SIZE=${FINASU_EXPECTED_SIZE:-}"
  echo "MGR_HASH=${FINASU_EXPECTED_HASH:-}"
} >> "$GITHUB_WORKSPACE/output/finasu.lock"
echo "Lock manager → finasu.lock" | tee -a "$AUDIT"

# ==================== 3h. RETRAIT 'static' (O_CLOEXEC PRÉSERVÉ) ====================
for f in security/selinux/ss/status.c security/selinux/selinuxfs.c security/selinux/status.c; do
    [ -f "$f" ] || continue
    sed -i -E 's/^static[[:space:]]+(struct page[[:space:]]*\*[[:space:]]*selinux_status_page)/\1/' "$f"
    sed -i -E 's/^static[[:space:]]+(DEFINE_MUTEX\(selinux_status_lock\))/\1/' "$f"
done
[ -f security/selinux/ss/services.c ] && sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c

# O_CLOEXEC est valide sur 4.19 (get_unused_fd_flags / anon_inode_getfile inchangés
# depuis 3.x). Le stripping provoquait une fuite du FD preinit vers zygote, puis
# l'abort "Not allowlisted (8)" dans nativeForkSystemServer. NE PAS Y TOUCHER.

# Filet de sécurité : si un build précédent a déjà altéré les sources, on restaure.
grep -rl "get_unused_fd_flags(0)" "$KSU_DIR/" 2>/dev/null | while read -r f; do
    sed -i 's/get_unused_fd_flags(0)/get_unused_fd_flags(O_CLOEXEC)/g' "$f"
done || true

# supercall.c alloue le FD du driver via une variable fd_flags : on force le bit.
SC="$KSU_DIR/supercall/supercall.c"
if [ -f "$SC" ]; then
    sed -i 's/get_unused_fd_flags(fd_flags)/get_unused_fd_flags(fd_flags | O_CLOEXEC)/' "$SC"
    sed -i 's/anon_inode_getfile(name, \&anon_ksu_fops, context, O_RDWR)/anon_inode_getfile(name, \&anon_ksu_fops, context, O_RDWR | O_CLOEXEC)/' "$SC"
    { echo "=== supercall.c après correctif O_CLOEXEC ==="; sed -n '55,80p' "$SC"; } | tee -a "$AUDIT"
fi

# Vérification dure : plus aucun O_CLOEXEC ne doit avoir disparu
{
  echo "=== Contrôle O_CLOEXEC dans FinaSU ==="
  grep -rn "get_unused_fd_flags" "$KSU_DIR/" 2>/dev/null | head -20
  echo "--- anon_inode_getfile ---"
  grep -rn "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null | head -20
} | tee -a "$AUDIT"

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

static size_t sepol_remaining(const struct sepol_batch_cursor *c) { return (size_t)(c->end - c->cur); }
static int sepol_read_cmd_header(struct sepol_batch_cursor *c, struct sepol_data *h) {
    if (sepol_remaining(c) < sizeof(*h)) return -EINVAL;
    memcpy(h, c->cur, sizeof(*h)); c->cur += sizeof(*h); return 0;
}
static int sepol_read_string(struct sepol_batch_cursor *c, const char **out) {
    u32 len; const char *s;
    if (sepol_remaining(c) < sizeof(len)) return -EINVAL;
    memcpy(&len, c->cur, sizeof(len)); c->cur += sizeof(len);
    if (len >= sepol_remaining(c)) return -EINVAL;
    s = (const char *)c->cur;
    if (memchr(s, '\0', len) != NULL || s[len] != '\0') return -EINVAL;
    c->cur += len + 1;
    if (len == 0) { *out = ALL; return 0; }
    *out = s; return 0;
}
static int sepol_require_not_all(const char *v, const char *n) {
    if (v != ALL) return 0; pr_err("sepol: %s cannot be ALL.\n", n); return -EINVAL;
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
static int apply_one_sepolicy_cmd(struct policydb *db, const struct sepol_data *h, const char **a) {
    bool ok = false; int ret;
    switch (h->cmd) {
    case KSU_SEPOLICY_CMD_NORMAL_PERM:
        if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW) ok = ksu_allow(db,a[0],a[1],a[2],a[3]);
        else if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DENY) ok = ksu_deny(db,a[0],a[1],a[2],a[3]);
        else if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_AUDITALLOW) ok = ksu_auditallow(db,a[0],a[1],a[2],a[3]);
        else if (h->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DONTAUDIT) ok = ksu_dontaudit(db,a[0],a[1],a[2],a[3]);
        return ok ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_XPERM:
        ret = sepol_require_not_all(a[3],"operation"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[4],"perm_set"); if (ret<0) return ret;
        if (h->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_ALLOW) ok = ksu_allowxperm(db,a[0],a[1],a[2],a[4]);
        else if (h->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_AUDITALLOW) ok = ksu_auditallowxperm(db,a[0],a[1],a[2],a[4]);
        else if (h->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_DONTAUDIT) ok = ksu_dontauditxperm(db,a[0],a[1],a[2],a[4]);
        return ok ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE_STATE:
        ret = sepol_require_not_all(a[0],"type"); if (ret<0) return ret;
        if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_PERMISSIVE) ok = ksu_permissive(db,a[0]);
        else if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_ENFORCE) ok = ksu_enforce(db,a[0]);
        return ok ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE: case KSU_SEPOLICY_CMD_TYPE_ATTR:
        ret = sepol_require_not_all(a[0],"type"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[1],"attribute"); if (ret<0) return ret;
        ok = (h->cmd == KSU_SEPOLICY_CMD_TYPE) ? ksu_type(db,a[0],a[1]) : ksu_typeattribute(db,a[0],a[1]);
        return ok ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_ATTR:
        ret = sepol_require_not_all(a[0],"attribute"); if (ret<0) return ret;
        return ksu_attribute(db,a[0]) ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE_TRANSITION:
        ret = sepol_require_not_all(a[0],"src"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[1],"tgt"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[2],"cls"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[3],"default_type"); if (ret<0) return ret;
        return ksu_type_transition(db,a[0],a[1],a[2],a[3],a[4]) ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_TYPE_CHANGE:
        ret = sepol_require_not_all(a[0],"src"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[1],"tgt"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[2],"cls"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[3],"default_type"); if (ret<0) return ret;
        if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_CHANGE) ok = ksu_type_change(db,a[0],a[1],a[2],a[3]);
        else if (h->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_MEMBER) ok = ksu_type_member(db,a[0],a[1],a[2],a[3]);
        return ok ? 0 : -EINVAL;
    case KSU_SEPOLICY_CMD_GENFSCON:
        ret = sepol_require_not_all(a[0],"name"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[1],"path"); if (ret<0) return ret;
        ret = sepol_require_not_all(a[2],"context"); if (ret<0) return ret;
        return ksu_genfscon(db,a[0],a[1],a[2]) ? 0 : -EINVAL;
    default: return -EINVAL;
    }
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
#define KSU_DB419     (&selinux_state.ss->policydb)
#define KSU_LOCK419   write_lock(&selinux_state.ss->policy_rwlock)
#define KSU_UNLOCK419 write_unlock(&selinux_state.ss->policy_rwlock)

static void reset_avc_cache_419(void) {
    if (selinux_state.avc) avc_ss_reset(selinux_state.avc, 0);
    selnl_notify_policyload(0);
    selinux_xfrm_notify_policyload();
}

void apply_kernelsu_rules(void) {
    struct policydb *db;
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
    pr_info("KernelSU rules applied (4.19 path)\n");
}

int handle_sepolicy(void __user *user_data, u64 data_len) {
    struct sepol_batch_cursor cur; u8 *payload; int ret, n_ok; u32 idx;
    if (!user_data || !data_len) return -EINVAL;
    if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) return -E2BIG;
    payload = kvmalloc((size_t)data_len, GFP_KERNEL);
    if (!payload) return -ENOMEM;
    if (copy_from_user(payload, user_data, (size_t)data_len)) { ret = -EFAULT; goto out_free; }
    KSU_LOCK419;
    cur.cur = payload; cur.end = payload + (size_t)data_len;
    ret = 0; n_ok = 0; idx = 0;
    while (cur.cur < cur.end) {
        struct sepol_data h; const char *a[KSU_SEPOLICY_MAX_ARGS] = {0};
        int argc; u32 i;
        ret = sepol_read_cmd_header(&cur, &h); if (ret < 0) break;
        argc = sepol_expected_argc(h.cmd);
        if (argc < 0 || argc > KSU_SEPOLICY_MAX_ARGS) { ret = -EINVAL; break; }
        for (i = 0; i < (u32)argc; i++) { ret = sepol_read_string(&cur, &a[i]); if (ret < 0) break; }
        if (ret < 0) break;
        ret = apply_one_sepolicy_cmd(KSU_DB419, &h, a);
        if (ret == 0) n_ok++;
        idx++;
    }
    KSU_UNLOCK419; reset_avc_cache_419();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
    ret = n_ok;
out_free: kvfree(payload); return ret;
}
#else
struct selinux_policy *backup_sepolicy;
#define SELINUX_POLICY_INSTEAD_SELINUX_SS
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
extern int avc_ss_reset(u32 seqno);
#else
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
#endif
static void reset_avc_cache(u32 seqno) {
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
    avc_ss_reset(seqno); selnl_notify_policyload(seqno); selinux_status_update_policyload(seqno);
#else
    avc_ss_reset(selinux_state.avc, seqno); selnl_notify_policyload(seqno);
    selinux_status_update_policyload(&selinux_state, seqno);
#endif
    selinux_xfrm_notify_policyload();
}
void apply_kernelsu_rules(void) {
    struct selinux_policy *pol, *old_pol; struct policydb *db;
    mutex_lock(&selinux_state.policy_mutex);
    old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));
    pol = ksu_dup_sepolicy(old_pol);
    if (IS_ERR(pol)) goto out_unlock;
    db = &pol->policydb;
    pol->latest_granting = old_pol->latest_granting + 1;
    ksu_type(db, KERNEL_SU_DOMAIN, "domain"); ksu_permissive(db, KERNEL_SU_DOMAIN);
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "mlstrustedsubject");
    ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);
    rcu_assign_pointer(selinux_state.policy, pol); synchronize_rcu(); ksu_destroy_sepolicy(old_pol);
    reset_avc_cache(pol->latest_granting);
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
out_unlock: mutex_unlock(&selinux_state.policy_mutex);
}
int handle_sepolicy(void __user *user_data, u64 data_len) { (void)user_data; (void)data_len; return -EOPNOTSUPP; }
#endif
RULESEOF
echo "✅ rules.c dual-path" | tee -a "$AUDIT"

# ==================== 4b. FIX 4.19 + INJECTION PREINIT ====================
cat > "$GITHUB_WORKSPACE/patches/fix419.py" <<'FIXEOF'
import os, sys, re
GW = sys.argv[1]
KR = os.path.join(GW, "kernel_sources")
KS = os.path.join(KR, "FinaSU", "kernel")
total = 0
def read(p):
    with open(p, encoding='utf-8', errors='replace') as f: return f.read()
def write(p, c):
    with open(p, 'w', encoding='utf-8') as f: f.write(c)
def inc(c, i):
    if i in c: return c
    L = c.split('\n'); last = -1
    for n, l in enumerate(L):
        if l.lstrip().startswith('#include'): last = n
    if last >= 0:
        L.insert(last+1, '#include '+i); return '\n'.join(L)
    return '#include '+i+'\n'+c

# FIX 2 : MODULE_IMPORT_NS
for dp, dn, fn in os.walk(KS):
    for f in fn:
        if not f.endswith(('.c','.h')): continue
        p = os.path.join(dp,f); c = read(p)
        if 'MODULE_IMPORT_NS' not in c: continue
        out=[]; ch=False
        for l in c.split('\n'):
            s=l.strip()
            if s.startswith('MODULE_IMPORT_NS(') and s.endswith(');'):
                if not out or out[-1].strip() != '#ifdef MODULE_IMPORT_NS':
                    out += ['#ifdef MODULE_IMPORT_NS', l, '#endif']; ch=True; continue
            out.append(l)
        if ch: write(p,'\n'.join(out)); total+=1; print("  ✅ MODULE_IMPORT_NS:", os.path.basename(p))

# FIX 3 : file_wrapper.c
p = os.path.join(KS,"infra/file_wrapper.c")
if os.path.isfile(p):
    c = read(p); o = c
    for old,new in [
      ('    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;',
       '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif'),
      ('    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;',
       '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n#endif')]:
        if old in c and new not in c: c = c.replace(old,new,1)
    old='#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll(struct kiocb *kiocb, struct io_comp_batch *icb, unsigned int v)'
    new='#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'+old
    if old in c and new not in c: c=c.replace(old,new,1)
    old='    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif'
    new='    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif\n#endif /* 5.0.0 */'
    if old in c and '#endif\n#endif /* 5.0.0 */' not in c: c=c.replace(old,new,1)
    old='static loff_t ksu_wrapper_remap_file_range(struct file *file_in, loff_t pos_in, struct file *file_out, loff_t pos_out,\n                                           loff_t len, unsigned int remap_flags)\n{'
    if old in c: c=c.replace(old,'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n'+old,1)
    old='        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n    }\n}\n'
    if old in c and '#endif /* 5.0.0 */\n\nstatic int ksu_wrapper_fadvise' not in c:
        c=c.replace(old, old+'#endif /* 5.0.0 */\n',1)
    if c!=o: write(p,c); total+=1; print("  ✅ file_wrapper.c guards")

# FIX 4 : seccomp_cache.c
p = os.path.join(KS,"infra/seccomp_cache.c")
if os.path.isfile(p):
    c = read(p)
    if 'SECCOMP_ARCH_NATIVE_NR' in c and 'KSU_SECCOMP_COMPAT' not in c:
        blk='\n#ifndef KSU_SECCOMP_COMPAT\n#define KSU_SECCOMP_COMPAT 1\n#ifndef SECCOMP_ARCH_NATIVE_NR\n#ifdef CONFIG_COMPAT\n#define SECCOMP_ARCH_NATIVE_NR 2\n#else\n#define SECCOMP_ARCH_NATIVE_NR 1\n#endif\n#endif\n#endif\n'
        L=c.split('\n'); last=-1
        for n,l in enumerate(L):
            if l.lstrip().startswith('#include'): last=n
        if last>=0:
            L.insert(last+1, blk); write(p,'\n'.join(L)); total+=1; print("  ✅ seccomp_cache.c")

# FIX 5 : su_mount_ns.c
p = os.path.join(KS,"infra/su_mount_ns.c")
if os.path.isfile(p):
    c = read(p)
    if '#include <uapi/linux/mount.h>' in c and 'KSU_MOUNT_HDR_COMPAT' not in c:
        c = c.replace('#include <uapi/linux/mount.h>',
          '#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)\n#include <uapi/linux/mount.h>\n#else\n#include <linux/mount.h>\n#endif\n#define KSU_MOUNT_HDR_COMPAT 1')
        write(p,c); total+=1; print("  ✅ su_mount_ns.c header")

# FIX 6 : pkg_observer.c
p = os.path.join(KS,"manager/pkg_observer.c")
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
struct watch_dir { const char *path; u32 mask; struct path kpath; struct inode *inode; struct fsnotify_mark *mark; };
static struct fsnotify_group *g;
static void ksu_track_throne_tw_func(struct callback_head *cb) {
    kfree(cb); if (current->flags & PF_EXITING) return; track_throne(false);
#if defined(CONFIG_KSU_SUSFS) && defined(CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER) && defined(CMD_SUSFS_SET_PRIORITY_UID_FILTER)
    susfs_parse_priority_app_strings();
#endif
}
static void ksu_defer_track_throne(void) {
    struct callback_head *cb;
    if (!(current->flags & PF_KTHREAD)) {
        cb = kzalloc(sizeof(*cb), GFP_KERNEL);
        if (cb) { cb->func = ksu_track_throne_tw_func; if (!task_work_add(current, cb, TWA_RESUME)) return; kfree(cb); }
    }
    track_throne(false);
}
static void ksu_maybe_track(void) { pr_info("packages.list detected\n"); ksu_defer_track_throne(); }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir, const struct qstr *fn, u32 cookie) {
    if (!fn || (mask & FS_ISDIR)) return 0;
    if (fn->len == 13 && !memcmp(fn->name, "packages.list", 13)) ksu_maybe_track();
    return 0;
}
#else
static int ksu_handle_event_compat(struct fsnotify_group *grp, struct inode *inode, u32 mask, const void *data, int dt, const unsigned char *fn, u32 cookie, struct fsnotify_iter_info *it) {
    (void)grp;(void)inode;(void)data;(void)dt;(void)cookie;(void)it;
    if (!fn || (mask & FS_ISDIR)) return 0;
    if (strlen((const char *)fn) == 13 && !memcmp(fn, "packages.list", 13)) ksu_maybe_track();
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
static int add_mark_on_inode(struct inode *inode, u32 mask, struct fsnotify_mark **out) {
    struct fsnotify_mark *m = kzalloc(sizeof(*m), GFP_KERNEL);
    if (!m) return -ENOMEM;
    fsnotify_init_mark(m, g); m->mask = mask;
    if (fsnotify_add_inode_mark(m, inode, 0)) { fsnotify_put_mark(m); return -EINVAL; }
    *out = m; return 0;
}
static int watch_one_dir(struct watch_dir *wd) {
    int ret = kern_path(wd->path, LOOKUP_FOLLOW, &wd->kpath);
    if (ret) return ret;
    wd->inode = d_inode(wd->kpath.dentry); ihold(wd->inode);
    ret = add_mark_on_inode(wd->inode, wd->mask, &wd->mark);
    if (ret) { path_put(&wd->kpath); iput(wd->inode); wd->inode = NULL; return ret; }
    pr_info("watching %s\n", wd->path); return 0;
}
static void unwatch_one_dir(struct watch_dir *wd) {
    if (wd->mark) { fsnotify_destroy_mark(wd->mark, g); fsnotify_put_mark(wd->mark); wd->mark = NULL; }
    if (wd->inode) { iput(wd->inode); wd->inode = NULL; }
    if (wd->kpath.dentry) { path_put(&wd->kpath); memset(&wd->kpath, 0, sizeof(wd->kpath)); }
}
static struct watch_dir g_watch = { .path = "/data/system", .mask = MASK_SYSTEM };
int ksu_observer_init(void) {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 0, 0)
    g = fsnotify_alloc_group(&ksu_ops, 0);
#else
    g = fsnotify_alloc_group(&ksu_ops);
#endif
    if (IS_ERR(g)) return PTR_ERR(g);
    watch_one_dir(&g_watch); pr_info("observer init done\n"); return 0;
}
void __exit ksu_observer_exit(void) { unwatch_one_dir(&g_watch); fsnotify_put_group(g); }
'''
        write(p,new_c); total+=1; print("  ✅ pkg_observer.c 4.19")

# FIX 7/11 : TWA_RESUME + headers sched
for dp, dn, fn in os.walk(KS):
    for f in fn:
        if not f.endswith(('.c','.h')): continue
        p=os.path.join(dp,f); c=read(p); o=c
        if 'TWA_RESUME' in c and '#ifndef TWA_RESUME' not in c:
            c = inc(c, '<linux/version.h>')
            L=c.split('\n'); last=-1
            for n,l in enumerate(L):
                if l.lstrip().startswith('#include'): last=n
            blk='\n#ifndef TWA_RESUME\n#define TWA_RESUME 0\n#endif\n'
            if last>=0: L.insert(last+1, blk); c='\n'.join(L)
            else: c=blk+c
        if 'put_task_struct' in c:
            c = inc(c,'<linux/sched.h>'); c = inc(c,'<linux/sched/task.h>')
        if any(s in c for s in ('tasklist_lock','init_task','task_pgrp','task_session')) and f.endswith('.c'):
            c = inc(c,'<linux/sched/signal.h>'); c = inc(c,'<linux/sched/task.h>')
        if c!=o: write(p,c); total+=1

# FIX 8 : app_profile.c
p = os.path.join(KS,"policy/app_profile.c")
if os.path.isfile(p):
    c=read(p); o=c
    old='void seccomp_filter_release(struct task_struct *tsk);\n'
    if old in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\nvoid seccomp_filter_release' not in c:
        c=c.replace(old,'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'+old+'#endif\n',1)
    old='    atomic_set(&current->seccomp.filter_count, 0);\n'
    if old in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n    atomic_set' not in c:
        c=c.replace(old,'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'+old+'#endif\n',1)
    old='    seccomp_filter_release(fake);\n'
    if old in c and '#else\n    put_seccomp_filter(fake);' not in c:
        c=c.replace(old,'#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'+old+'#else\n    put_seccomp_filter(fake);\n#endif\n',1)
    if c!=o: write(p,c); total+=1; print("  ✅ app_profile.c seccomp")

# FIX 9 : sepolicy.c — dual-path COMPLET 4.19
p = os.path.join(KS,"selinux/sepolicy.c")
if os.path.isfile(p):
    c = read(p); o = c
    c = inc(c,'<linux/flex_array.h>')

    # 9a. macros avtab (flex_array en 4.19)
    if 'ksu_avtab_htable_get' not in c and '#define KSU_SUPPORT_ADD_TYPE' in c:
        c = c.replace('#define KSU_SUPPORT_ADD_TYPE\n',
          '#define KSU_SUPPORT_ADD_TYPE\n\n'
          '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n'
          '#define ksu_avtab_htable_get(h,i) ((struct avtab_node *)flex_array_get_ptr((h).htable,(i)))\n'
          '#define ksu_avtab_htable_set(h,i,v) flex_array_put_ptr((h).htable,(i),(v),GFP_ATOMIC)\n'
          '#else\n'
          '#define ksu_avtab_htable_get(h,i) ((h).htable[(i)])\n'
          '#define ksu_avtab_htable_set(h,i,v) ((h).htable[(i)] = (v))\n'
          '#endif\n', 1)
    c = c.replace('for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {',
                  'for (n = ksu_avtab_htable_get(db->te_avtab, i); n; prev = n, n = n->next) {', 1)
    c = c.replace('db->te_avtab.htable[i] = n->next;',
                  'ksu_avtab_htable_set(db->te_avtab, i, n->next);', 1)
    c = c.replace('removed.htable[0] = n;',
                  'ksu_avtab_htable_set(removed, 0, n);', 1)

    # 9b. add_filename_trans : API 5.9+ vs hashtab 4.19
    old_open = ('static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,\n'
                '                               const char *o)\n{\n    struct type_datum *src, *tgt, *def;')
    new_open = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n' + old_open
    if old_open in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\nstatic bool add_filename_trans' not in c:
        c = c.replace(old_open, new_open, 1)

    old_close = 'free_trans:\n    kfree(trans);\nout:\n    return false;\n}'
    new_close = r'''free_trans:
    kfree(trans);
out:
    return false;
}
#else
/* 4.19 : filename_trans = {stype,ttype,tclass,name}, datum = {otype},
 *        db->filename_trans est un hashtab, ttypes est un ebitmap */
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
    if (!src) { pr_warn("source type %s does not exist\n", s); return false; }
    tgt = symtab_search(&db->p_types, t);
    if (!tgt) { pr_warn("target type %s does not exist\n", t); return false; }
    cls = symtab_search(&db->p_classes, c);
    if (!cls) { pr_warn("class %s does not exist\n", c); return false; }
    def = symtab_search(&db->p_types, d);
    if (!def) { pr_warn("default type %s does not exist\n", d); return false; }

    key.stype = src->value;
    key.ttype = tgt->value;
    key.tclass = cls->value;
    key.name = o;

    datum = hashtab_search(db->filename_trans, &key);
    if (datum) { datum->otype = def->value; return true; }

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
    if (rc) { kfree(new_datum); kfree(new_key->name); kfree(new_key); return false; }

    ebitmap_set_bit(&db->filename_trans_ttypes, tgt->value, 1);
    return true;
}
#endif'''
    if old_close in c and '#else\n/* 4.19 : filename_trans' not in c:
        c = c.replace(old_close, new_close, 1)

    # 9c. add_type : tableaux 5.10+ vs flex_array 4.19
    m = re.search(r'^static bool add_type\(struct policydb \*db, const char \*type_name, bool attr\)\n\{', c, re.MULTILINE)
    if m and 'KSU_ADD_TYPE_FLEX_ARRAY' not in c:
        start = m.start(); depth = 0; end = -1; i = m.end() - 1
        while i < len(c):
            if c[i] == '{':
                depth += 1
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
    
            wrapped = orig_func.replace(
                'static bool add_type(struct policydb *db, const char *type_name, bool attr)\n{',
                'static bool add_type_5_10(struct policydb *db, const char *type_name, bool attr)\n{', 1)
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

    # 9d. sattr
    old = '    struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];'
    new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n' + old +
           '\n#else\n    struct ebitmap *sattr = (struct ebitmap *)flex_array_get(db->type_attr_map_array, type->value - 1);\n#endif')
    if old in c and new not in c:
        c = c.replace(old, new, 1)

        # 9e. ksu_destroy_sepolicy / ksu_dup_sepolicy
    old = ('void ksu_destroy_sepolicy(struct selinux_policy *pol)\n{\n    policydb_destroy(&pol->policydb);\n'
           '    kfree(pol);\n}\n\nstruct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)\n{')
    if old in c and '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\nvoid ksu_destroy_sepolicy' not in c:
        c = c.replace(old, '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n' + old, 1)
    oc = 'out_free_data:\n    kvfree(data);\n\n    return ERR_PTR(ret);\n}\n'
    nc = (oc + '#else\n'
          '/* 4.19 : pas de struct selinux_policy ; policydb modifie en place dans rules.c */\n'
          'void ksu_destroy_sepolicy(struct selinux_policy *pol) { (void)pol; }\n'
          'struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)\n'
          '{\n    (void)old_pol;\n    return ERR_PTR(-EOPNOTSUPP);\n}\n#endif\n')
    if oc in c and '#else\n/* 4.19 : pas de struct selinux_policy' not in c:
        c = c.replace(oc, nc, 1)

    if c != o:
        write(p,c); total+=1; print("  ✅ sepolicy.c : dual-path COMPLET (avtab + filename_trans + add_type)")

# FIX 10 : minmax.h
for dp,dn,fn in os.walk(KS):
    for f in fn:
        if not f.endswith(('.c','.h')): continue
        p=os.path.join(dp,f); c=read(p)
        if '#include <linux/minmax.h>' in c and 'KSU_MINMAX_COMPAT' not in c:
            c=c.replace('#include <linux/minmax.h>','/* KSU_MINMAX_COMPAT */\n#include <linux/kernel.h>',1)
            write(p,c); total+=1
        
# ===== FIX 13 : INJECTION DES 2 HOOKS PREINIT =====
p = os.path.join(KR,"fs/exec.c")
if os.path.isfile(p):
    c = read(p); o = c
    if 'ksu_setup_preinit_file' not in c:
        sig = None
        for s in ['static int __do_execve_file(int fd, struct filename *filename,',
                  'static int do_execveat_common(int fd, struct filename *filename,']:
            if s in c: sig = s; break
        if sig:
            ext=('#ifdef CONFIG_KSU_SUSFS\n'
                 'extern int ksu_setup_preinit_file(struct filename **filename_ptr, struct user_arg_ptr *argv_user);\n'
                 'extern int ksu_preinit_handle_post_execveat(int *fd, struct filename **filename_ptr, void *argv_user,\n'
                 '\t\t\t\t\t  void *envp_user, int *flags, int *retval, int *preinit_fd);\n'
                 '#endif\n')
            start = c.index(sig)
            c = c[:start] + ext + c[start:]
            bstart = c.index(sig)
            i = c.index('{', bstart); depth = 0; bend = -1
            while i < len(c):
                if c[i]=='{': depth+=1
                elif c[i]=='}':
                    depth-=1
                    if depth==0: bend=i; break
                i+=1
            if bend > 0:
                body = c[bstart:bend+1]
                if 'bool is_su_session = false;' in body:
                    body = body.replace('bool is_su_session = false;',
                                        'bool is_su_session = false;\n\tint preinit_fd = 0;',1)
                else:
                    body = body.replace('\tint retval;', '\tint retval;\n#ifdef CONFIG_KSU_SUSFS\n\tint preinit_fd = 0;\n#endif',1)
                if 'orig_flow:\n#endif' in body:
                    body = body.replace('orig_flow:\n#endif',
                        'orig_flow:\n#endif\n#ifdef CONFIG_KSU_SUSFS\n'
                        '\tpreinit_fd = ksu_setup_preinit_file(&filename, &argv);\n#endif',1)
                put = '\tif (filename)\n\t\tputname(filename);'
                post=('#ifdef CONFIG_KSU_SUSFS\n'
                      '\tif (unlikely(preinit_fd > 0))\n'
                      '\t\t(void)ksu_preinit_handle_post_execveat(&fd, &filename, (void *)&argv,\n'
                      '\t\t\t\t(void *)&envp, &flags, &retval, &preinit_fd);\n#endif\n')
                n = body.count(put)
                body = body.replace(put, post + put)
                c = c[:bstart] + body + c[bend+1:]
                write(p,c); total+=1
                print(f"  ✅ fs/exec.c : preinit injecté (setup + {n} sites post-exec)")
            else:
                print("  ❌ fs/exec.c : corps de fonction non délimité")
        else:
            print("  ❌ fs/exec.c : signature execve introuvable")
    else:
        print("  ℹ️ fs/exec.c : preinit déjà présent")

print(f"  ✅ portage 4.19 : {total} fichier(s)")
FIXEOF

python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" \
    "$GITHUB_WORKSPACE/patches/fix419.py"
python3 "$GITHUB_WORKSPACE/patches/fix419.py" "$GITHUB_WORKSPACE" 2>&1 | tee -a "$AUDIT"

# ==================== 4c. PORTAGE SELINUX (fichier externe) ====================
FIXSEL="$GITHUB_WORKSPACE/patches/fix_selinux.py"
curl -fL --retry 3 "https://raw.githubusercontent.com/Albanel22/finaSU-kiev/finaSU-Qwen-Duck2/patches/fix_selinux.py" -o "$FIXSEL"
if grep -q 'hashtab_search(&(s)->table' "$FIXSEL"; then
    echo "❌ fix_selinux.py OBSOLÈTE sur GitHub (macro avec '&'). Poussez la version corrigée." | tee -a "$AUDIT"
    exit 1
fi
echo "✅ fix_selinux.py à jour (macro sans '&')" | tee -a "$AUDIT"
python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$FIXSEL"
python3 "$FIXSEL" "$GITHUB_WORKSPACE" 2>&1 | tee -a "$AFIXSEL"

# ==================== FIX 14 : HOOKS SELINUX MANQUANTS ====================
python3 - "$GITHUB_WORKSPACE" <<'HK' 2>&1 | tee -a "$AUDIT"
import os, re, sys
KR = os.path.join(sys.argv[1], "kernel_sources")
def rd(p):
    with open(p, encoding='utf-8', errors='replace') as f: return f.read()
def wr(p,c):
    with open(p,'w',encoding='utf-8') as f: f.write(c)

# hooks.c : selinux_setprocattr -> my_setprocattr
p = os.path.join(KR,"security/selinux/hooks.c")
if os.path.isfile(p):
    c = rd(p); o = c
    if 'KSU_HOOK_SETPROCATTR_419' not in c:
        m = re.search(r'^static int selinux_setprocattr\(struct task_struct \*p,', c, re.M)
        if m:
            d = ('#ifdef CONFIG_KSU_SUSFS\n/* KSU_HOOK_SETPROCATTR_419 */\n'
                 'extern bool ksu_selinux_hide_ready(void);\n'
                 'extern int my_setprocattr(const char *name, void *value, size_t size);\n#endif\n')
            c = c[:m.start()] + d + c[m.start():]
            c = c.replace('char *str = value;',
                'char *str = value;\n#ifdef CONFIG_KSU_SUSFS\n'
                '\tif (p == current && current_uid().val >= 10000 &&\n'
                '\t    !strcmp(name, "current") && ksu_selinux_hide_ready())\n'
                '\t\treturn my_setprocattr(name, value, size);\n#endif\n', 1)
            wr(p,c); print("  ✅ hooks.c : my_setprocattr branché")
        else:
            print("  ❌ hooks.c : signature selinux_setprocattr introuvable")

# selinuxfs.c : sel_write_context / sel_write_access -> my_write_*
p = os.path.join(KR,"security/selinux/selinuxfs.c")
if os.path.isfile(p):
    c = rd(p); o = c
    if 'KSU_HOOK_SELINUXFS_419' not in c:
        d = ('\n#ifdef CONFIG_KSU_SUSFS\n/* KSU_HOOK_SELINUXFS_419 */\n'
             'extern bool ksu_selinux_hide_ready(void);\n'
             'extern ssize_t my_write_context(struct file *file, char *buf, size_t size);\n'
             'extern ssize_t my_write_access(struct file *file, char *buf, size_t size);\n#endif\n')
        last = 0
        for mm in re.finditer(r'^#include[^\n]*\n', c, re.M): last = mm.end()
        c = c[:last] + d + c[last:]
        n = 0
        for fn, mine in (('sel_write_context','my_write_context'),
                         ('sel_write_access','my_write_access')):
            pat = r'(static ssize_t ' + fn + r'\(struct file \*file, char \*buf, size_t size\)\s*\n\{)'
            rep = (r'\1' + '\n#ifdef CONFIG_KSU_SUSFS\n'
                   '\tif (current_uid().val >= 10000 && ksu_selinux_hide_ready())\n'
                   '\t\treturn ' + mine + '(file, buf, size);\n#endif\n')
            c2 = re.sub(pat, rep, c, count=1)
            if c2 != c: c = c2; n += 1
            else: print("  ❌ selinuxfs.c : " + fn + " introuvable")
        wr(p,c); print(f"  ✅ selinuxfs.c : {n}/2 hooks branchés")
HK

# --- DIAG : prototypes SELinux réels + appels de selinux_hide.c ---
set +e
{
  echo "### Prototypes SELinux du noyau (security.h) ###"
  grep -nE "int security_context_to_sid|int security_sid_to_context|void security_compute_av" \
      security/selinux/include/security.h 2>/dev/null | head -25
  echo
  echo "### selinux_hide.c : appels SELinux après patch ###"
  grep -nE "security_context_to_sid|security_sid_to_context|security_compute_av|_live" \
      drivers/kernelsu/feature/selinux_hide.c 2>/dev/null | head -40
} >> "$SPEC" 2>&1
set -e

# Verdict immédiat du validateur
echo "=== VERDICT check_susfs_inline.sh ===" | tee -a "$AUDIT"
set +e
sh FinaSU/kernel/tools/check_susfs_inline.sh "$PWD" 2>&1 | tee -a "$AUDIT"
set -e

# ==================== 5. CONFIG ====================
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-
cat > "$GITHUB_WORKSPACE/clang-wrap" <<'W'
#!/bin/bash
args=()
for a in "$@"; do case "$a" in -Wno-cast-function-type-strict|-Wcast-function-type-strict) ;; *) args+=("$a") ;; esac; done
exec clang -Wno-unknown-warning-option "${args[@]}" -Wno-unknown-warning-option
W
chmod +x "$GITHUB_WORKSPACE/clang-wrap"
CC_ARGS="CC=$GITHUB_WORKSPACE/clang-wrap"

mkdir -p out
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig
cd out
for o in KSU KSU_HOOK_SUSFS_INLINE KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT \
         KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
         KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP \
         KSU_SUSFS_PRIORITY_UID_FILTER KPROBES HAVE_KPROBES KRETPROBES KALLSYMS KALLSYMS_ALL \
         EXT4_FS HEADERS_INSTALL THREAD_INFO_IN_TASK FTRACE FTRACE_SYSCALLS SECCOMP SECCOMP_FILTER \
         COMPAT COMPAT_32BIT_TIME ; do
    ../scripts/config --set-val CONFIG_$o y
done
# Désactiver KSU_DEBUG : retire la règle shell->su et la bannière DEBUG
../scripts/config --set-val CONFIG_KSU_DEBUG n
../scripts/config --set-val CONFIG_KSU_HOOK_TRACEPOINT n
cd ..
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3
grep -E "^CONFIG_KSU" out/.config | tee -a "$AUDIT"
grep -q "^CONFIG_KSU=y" out/.config || { echo "❌ KSU off"; exit 1; }
grep -q "^CONFIG_KSU_HOOK_SUSFS_INLINE=y" out/.config || { echo "❌ INLINE off"; exit 1; }
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 headers_install 2>&1 | tail -2
[ -f out/usr/include/linux/unistd.h ] && echo "✅ UAPI headers OK (preinit actif)" | tee -a "$AUDIT"

# 4.19 n'a pas include/uapi/linux/mount.h (ajouté en 5.2).
if [ ! -f out/usr/include/linux/mount.h ]; then
cat > out/usr/include/linux/mount.h <<'MNTSHIM'
#ifndef _LINUX_MOUNT_H
#define _LINUX_MOUNT_H
/* Shim 4.19 : les drapeaux MS_* vivent dans linux/fs.h avant 5.2 */
#include <linux/fs.h>
#endif
MNTSHIM
echo "✅ shim out/usr/include/linux/mount.h créé" | tee -a "$AUDIT"
fi

set +e
{
  echo "### nolibc/sys/mount.h ###"
  cat FinaSU/kernel/preinit/runner/nolibc/sys/mount.h 2>/dev/null | head -40
  echo "### headers UAPI linux/ disponibles (mount / fs) ###"
  ls -la out/usr/include/linux/mount.h out/usr/include/linux/fs.h 2>/dev/null
} >> "$SPEC" 2>&1
set -e

# ==================== 6. MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb){return blocking_notifier_chain_register(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb){return blocking_notifier_chain_unregister(&motorola_panel_notifier_list,nb);}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int s){return;}\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 7. COMPILATION ====================
set +eo pipefail
make O=out LLVM=1 $CC_ARGS CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  KCFLAGS="-Wno-unused-variable -Wno-declaration-after-statement" KSU_REQUIRE_PREINIT=1 $SIG_ARGS \
  -k -j$(nproc) Image 2>&1 | tee build.log
RC=${PIPESTATUS[0]}
set -eo pipefail
[ "$RC" -eq 0 ] && [ -f out/arch/arm64/boot/Image ] || { echo "❌ BUILD FAILED"; exit 1; }
echo "✅ Compilation réussie"
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/khash.txt
cp out/arch/arm64/boot/Image "$GITHUB_WORKSPACE/output/Image-${VER}"
grep -E " (ksu_handle_|ksu_preinit|ksu_sucompat)" out/System.map | head -20 | tee -a "$AUDIT"

# ==================== 8. KSUD ====================
cd "$GITHUB_WORKSPACE"
if [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"; KSUD_ROOT="$KSU_REPO_ROOT"
else
    git clone --depth=1 -b "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git ksud-src
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"; KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
fi
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
NDK="$GITHUB_WORKSPACE/android-ndk-r26d/toolchains/llvm/prebuilt/linux-x86_64"
cd "$KSUD_DIR"; mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$NDK/bin/aarch64-linux-android26-clang"
[env]
CC_aarch64_linux_android = "$NDK/bin/aarch64-linux-android26-clang"
CXX_aarch64_linux_android = "$NDK/bin/aarch64-linux-android26-clang++"
AR_aarch64_linux_android = "$NDK/bin/llvm-ar"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "--sysroot=$NDK/sysroot -I$NDK/sysroot/usr/include/aarch64-linux-android"
EOF
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android
cp "$(find "$KSUD_ROOT" -type f -path '*aarch64-linux-android/release/ksud' | head -1)" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK ====================
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 || true
[ -f boot-stock.img ] && [ "$(stat -c%s boot-stock.img)" -gt 50000000 ] || { echo "❌ boot invalide"; exit 1; }
mkdir -p repack; cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk.apk
unzip -q Magisk.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot; chmod +x repack/magiskboot; rm -rf Magisk.apk lib
cd repack
set +e; ./magiskboot unpack boot.img; set -e
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" ./local_su; chmod 755 ./local_su
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su"
rm -f ./local_su
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img; cd ..
cp final_boot.img "output/FinaSU-A-${VER}-boot.img"
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ ${VER} ==="
ls -lh output/
