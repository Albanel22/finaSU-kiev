# finaSU-kiev

**FinaSU** (KernelSU) sur **Motorola One 5G Ace (`kiev`)** — noyau **non-GKI 4.19**, avec **SuSFS Inline**, preinit et build reproductible.

[![Kernel](https://img.shields.io/badge/kernel-4.19.325-blue)]()
[![Device](https://img.shields.io/badge/device-kiev-green)]()
[![FinaSU](https://img.shields.io/badge/FinaSU-v1.6.4+-orange)]()
[![Hook](https://img.shields.io/badge/hook-SUSFS%20Inline-purple)]()

---

Quick Start
https://fina.mysqil.com/en/guide/get-started/

## Résultat (baseline Golden)

| Élément | État |
|--------|------|
| Manager FinaSU | **Working** · Built-In |
| Kernel build | **v1.6.4** (tag résolu au build) |
| Hook | **SUSFS Inline Syscall Redirect** |
| SUSFS | **v2.4.0 · Built-In** |
| SELinux | Enforcing |
| Play Integrity | Basic · Device · **Strong** |

Root fonctionnel (`u:r:ksu:s0`), modules actifs, masquage validé (RootBeer / Native Detector / Ruru sur les checks courants).

---

## Matériel & sources

| | |
|--|--|
| **Appareil** | Motorola One 5G Ace (`kiev`) |
| **Noyau** | [LineageOS `android_kernel_motorola_sm8250`](https://github.com/LineageOS/android_kernel_motorola_sm8250) · branche `lineage-23.2` |
| **Commit figé** | `9426323c2acd0865fd565a6dd8a9f39f831cbec3` |
| **FinaSU** | [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) — `FINASU_REF=latest` → tag résolu + **lock** |
| **Backend** | `CONFIG_KSU_HOOK_SUSFS_INLINE` (pas Tracepoint seul) |

---

## Stratégie du script

1. **Noyau épinglé** (`KERNEL_PIN`) — base stable Motorola / Lineage
2. **Patch SuSFS 4.19** + correctifs manuels (rejets contrôlés)
3. **FinaSU** cloné **avant** les hooks ; `latest` résolu en tag/commit, écrit dans `output/finasu.lock`
4. **Hooks INLINE** (script dédié) + injection **preinit** dans `fs/exec.c`
5. **Signature manager** depuis APK (Google Drive) → `KSU_EXPECTED_SIZE` / `KSU_EXPECTED_HASH`
6. **Portage 4.19** (SELinux, file_wrapper, O_CLOEXEC **préservé**, etc.)
7. **Compilation** LLVM/clang · `Image` · repack Magiskboot + `ksud`

### Reproductibilité

    FINASU_REF=latest     → résout le dernier tag v*
                          → enregistre FINASU_COMMIT dans output/finasu.lock

    # Rebuild strictement identique :
    FINASU_REF=<commit du lock>

Le lock contient aussi la signature manager (SIZE / HASH) du run.

---

## Prérequis CI / local

- Ubuntu runner (ou équivalent) avec accès réseau
- Outils : `clang`, `lld`, `gcc-aarch64-linux-gnu`, `python3`, `gdown`, Rust (ksud), NDK
- Secrets / fichiers : boot stock (Drive), optionnel `patches/manager.apk`

Variables utiles :

| Variable | Défaut | Rôle |
|----------|--------|------|
| `FINASU_REF` | `latest` | Tag / branche / commit FinaSU |
| `KERNEL_PIN` | `9426323c…` | Commit noyau |
| `MGR_GDRIVE_ID` | (APK manager) | Signature compilée dans le noyau |

---

## Sorties

    output/
    ├── FinaSU-A-finasu-A-boot.img   # boot flashable
    ├── Image-finasu-A
    ├── ksud
    ├── finasu.lock                  # commit FinaSU + signature manager
    ├── audit-finasu-A.txt
    └── build-summary.txt

---

## Flash (rappel)

> Sauvegarde toujours un **boot stock / baseline** avant d’essayer un nouveau build.

    # fastboot (déverrouillé)
    fastboot flash boot FinaSU-A-finasu-A-boot.img
    fastboot reboot

Puis ouvrir le **manager FinaSU** (même famille de version que le kernel build).

---

## Vérifications rapides (Termux)

    su -c id
    su -c 'uname -r; cat /proc/version'
    su -c 'dmesg | grep -iE "kernelsu|ksu|finasu" | tail -30'
    su -c getenforce

Attendu : `uid=0` · `context=u:r:ksu:s0` · logs `KernelSU:` · `Enforcing`.

---

## Avertissements

- Projet **expérimental** pour `kiev` / 4.19 non-GKI.
- Un boot incorrect peut nécessiter un retour fastboot / boot de secours.
- Le root et le masquage n’offrent **aucune garantie** face à toutes les apps ou détections futures.
- Respectez les lois et conditions d’utilisation des services que vous utilisez.

---

## Crédits

- [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU)
- [KernelSU](https://github.com/tiann/KernelSU) / écosystème SuSFS
- [LineageOS](https://github.com/LineageOS/android_kernel_motorola_sm8250)
- Communauté patches INLINE / 4.19

---

## Licence

Le script de build de ce dépôt : selon la licence du dépôt.  
Noyau Linux : GPL-2.0.  
FinaSU / composants tiers : licences de leurs projets respectifs.
