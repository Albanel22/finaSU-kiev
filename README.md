<div align="center">

# 🛡️ FinaSU + SuSFS — Motorola One 5G Ace (`kiev`)

**Kernel 4.19 non-GKI · Root intégré · SUSFS Inline · Preinit fonctionnel**

![Kernel](https://img.shields.io/badge/kernel-4.19.325-blue?style=flat-square)
![Android](https://img.shields.io/badge/Android-16%20(LineageOS%2023.2)-3DDC84?style=flat-square&logo=android&logoColor=white)
![FinaSU](https://img.shields.io/badge/FinaSU-v1.5.0-orange?style=flat-square)
![SuSFS](https://img.shields.io/badge/SuSFS-v2.4.0%20NON--GKI-purple?style=flat-square)
![Hook](https://img.shields.io/badge/hook-SUSFS%20Inline-success?style=flat-square)
![Integrity](https://img.shields.io/badge/Play%20Integrity-STRONG-brightgreen?style=flat-square)

</div>

---

## 📖 À propos

Portage de **FinaSU** (fork de KernelSU par LyraVoid) et **SuSFS v2.4.0** sur le noyau **4.19 non-GKI** du Motorola One 5G Ace, avec le backend **SUSFS Inline** — c'est-à-dire des appels directs `ksu_handle_*` insérés dans les sources du noyau, sans tracepoint ni kprobe.

FinaSU ne supporte officiellement que les noyaux GKI. Ce dépôt documente le portage complet vers un 4.19 legacy, **y compris les sept blocages non triviaux** qui empêchent un build standard de fonctionner.

> [!IMPORTANT]
> Un noyau qui compile ne veut pas dire un noyau qui boote. Toute la difficulté de ce portage se situait **entre les deux**. Voir la section [Pièges résolus](#-pièges-résolus).

---

## ✅ Résultats vérifiés

| Test | Résultat |
|---|---|
| **Play Integrity API** | `MEETS_BASIC_INTEGRITY` ✅ `MEETS_DEVICE_INTEGRITY` ✅ `MEETS_STRONG_INTEGRITY` ✅ |
| **RootBeer Sample** | `NOT ROOTED` — 13/13 checks verts |
| **Ruru v1.1.1** | Tous les vecteurs verts (PM Intent, Libc, Syscall, Xposed, LSPatch, Magisk…) |
| **Native Detector** | *The Environment is normal* |
| **Manager FinaSU** | `Working` · badge `Built-In` |
| **Root shell** | `uid=0(root) gid=0(root) context=u:r:ksu:s0` |
| **Modules** | 9 modules montés via MetaModule · OverlayFS |
| **Zygisk** | Zygisk Next actif |
| **SELinux** | `Enforcing` (jamais permissif) |

---

## 📱 Compatibilité

| Élément | Valeur |
|---|---|
| Appareil | Motorola One 5G Ace (`kiev`) — SM8250 |
| ROM | LineageOS 23.2 (Android 16) |
| Noyau | `4.19.325` — `android_kernel_motorola_sm8250` |
| Commit épinglé | `9426323c2acd0865fd565a6dd8a9f39f831cbec3` |
| Architecture | `arm64` · defconfig `vendor/lito-perf_defconfig` |
| Toolchain | Clang / LLVM (`LLVM=1`) |
| Bootloader | Déverrouillé, `vbmeta` désactivé |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────┐
│  Manager FinaSU (v1.6.4)                    │
│         ↕ ioctl GET_INFO / SET_SEPOLICY     │
├─────────────────────────────────────────────┤
│  Driver FinaSU intégré (CONFIG_KSU=y)       │
│         ↕ appels directs ksu_handle_*       │
├─────────────────────────────────────────────┤
│  Noyau 4.19 patché                          │
│  • 12 points d'accroche SUSFS Inline        │
│  • fs/susfs.c (SuSFS v2.4.0)                │
│  • preinit runner (nolibc, ELF embarqué)    │
└─────────────────────────────────────────────┘
```

### Backend de hook

FinaSU propose deux backends, sélectionnés **à la compilation** :

| Backend | Config | Mécanisme |
|---|---|---|
| Tracepoint | `CONFIG_KSU_HOOK_TRACEPOINT=y` | `sys_enter` + dispatcher partagé |
| **SUSFS Inline** ← utilisé ici | `CONFIG_KSU_HOOK_SUSFS_INLINE=y` | Appels `ksu_handle_*` directs dans `fs/`, `kernel/`, `drivers/input/` |

Le validateur `kernel/tools/check_susfs_inline.sh` **refuse de compiler** si les 12 points d'accroche ne sont pas présents dans les vraies sources.

---

## 🔗 Les 12 points d'accroche requis

| Fichier noyau | Fonction |
|---|---|
| `drivers/input/input.c` | `ksu_handle_input_handle_event` |
| `fs/exec.c` | `ksu_handle_execveat` |
| `fs/exec.c` | `ksu_handle_execveat_sucompat` |
| `fs/exec.c` | `ksu_handle_post_execveat_sucompat` |
| `fs/exec.c` | `ksu_setup_preinit_file` ⚠️ *spécifique FinaSU* |
| `fs/exec.c` | `ksu_preinit_handle_post_execveat` ⚠️ *spécifique FinaSU* |
| `fs/open.c` | `ksu_handle_faccessat` |
| `fs/read_write.c` | `ksu_handle_sys_read` |
| `fs/stat.c` | `ksu_handle_stat` |
| `fs/stat.c` | `ksu_handle_vfs_fstat` |
| `kernel/reboot.c` | `ksu_handle_sys_reboot` |
| `kernel/sys.c` | `ksu_handle_setresuid` |

> [!WARNING]
> Le validateur **rejette** également ces anciens noms s'ils sont présents :
> `CONFIG_KSU_MANUAL_HOOK`, `ksu_vfs_read_hook`, `ksu_input_hook`, `ksu_execveat_hook`, `ksu_init_rc_hook`.
> Un patch « KernelSU Manual Hook » générique fera donc échouer le build.

**Origine des accroches :** le script [`susfs_inline_hook_patches.sh`](https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd) de JackA1ltman fournit les **10** accroches standard. Les **2 hooks preinit** sont propres à FinaSU et doivent être injectés manuellement dans `__do_execve_file()` / `do_execveat_common()`.

---

## 🚧 Pièges résolus

C'est le cœur de ce portage. Chacun de ces points provoque soit un échec de build, soit un bootloop silencieux.

### 1. `O_CLOEXEC` ne doit **jamais** être retiré

**Symptôme :** bootloop, logo LineageOS qui tourne indéfiniment.

```
Abort message: 'JNI FatalError called: (system_server) Not allowlisted (8): /null'
  #06 FileDescriptorInfo::CreateFromFd(...)
  #09 nativeForkSystemServer(...)
```

**Cause :** retirer `O_CLOEXEC` de `get_unused_fd_flags()` / `anon_inode_getfile()` fait survivre le FD du runner preinit à l'`execve`. Il se propage `init → zygote → system_server`, où la liste blanche Android le rejette → `abort()` toutes les 5 s.

**Correctif :** ne pas toucher à `O_CLOEXEC`. Il est valide sur 4.19 (`get_unused_fd_flags` inchangé depuis 3.x). Le FD 8 mentionné dans l'abort correspond exactement au `preinit: direct exec via /proc/self/fd/8`.

### 2. `linux/mount.h` absent des UAPI 4.19

**Symptôme :**
```
nolibc/sys/mount.h:15: fatal error: 'linux/mount.h' file not found
blob.S:10: Could not find incbin file '.../runner.elf'
```

**Cause :** `include/uapi/linux/mount.h` n'existe qu'à partir de **5.2**. Le runner nolibc de preinit l'inclut sans condition.

**Correctif :** shim minimal après `headers_install` — le runner n'utilise que `__NR_mount`, aucun symbole de `mount.h` :

```c
/* out/usr/include/linux/mount.h */
#ifndef _LINUX_MOUNT_H
#define _LINUX_MOUNT_H
#include <linux/fs.h>   /* MS_* vivent ici avant 5.2 */
#endif
```

### 3. `SUSFS_KERNEL_READ_NEW` écrasé

**Symptôme :**
```
fs/susfs.c:45: error: incompatible integer to pointer conversion
             passing 'loff_t' to parameter of type 'void *'
```

**Cause :** `kernel_read()` a changé de signature en 4.14. Le patch upstream détecte la bonne variante via `fs/Makefile`. Un correctif manuel qui réécrit ce hunk **supprime la détection**.

**Correctif :** restaurer le bloc de détection :

```makefile
obj-$(CONFIG_KSU_SUSFS) += susfs.o
ifeq ($(shell grep -q "ssize_t kernel_read" $(srctree)/fs/read_write.c $(srctree)/fs/exec.c 2>/dev/null; echo $$?),0)
CFLAGS_susfs.o += -DSUSFS_KERNEL_READ_NEW
endif
```

### 4. SELinux 4.19 : `struct selinux_state *` en premier argument

**Symptôme :**
```
selinux_hide.c: error: too few arguments to function call, expected 5, have 4
```

**Cause :** le backport Android `selinux_state` présent dans ce 4.19 impose `state` en premier paramètre. FinaSU récent appelle l'API sans ce paramètre.

```c
/* Prototypes réels de ce noyau */
int security_context_to_sid(struct selinux_state *state, ...);      /* 5 args */
int security_sid_to_context(struct selinux_state *state, u32 sid, ...); /* 4 args */
```

**Correctif :** macros d'adaptation conditionnelles, placées **après tous les `#include`**, activées seulement si `security.h` confirme le prototype :

```c
#define security_context_to_sid(c, l, s, g) \
        security_context_to_sid(&selinux_state, (c), (l), (s), (g))
```

> Le préprocesseur C ne ré-expand pas un macro de même nom : l'appel interne atteint bien la fonction du noyau.

### 5. `sepolicy.c` : `flex_array` vs tableaux

| Structure | 4.19 | 5.10+ |
|---|---|---|
| `type_attr_map_array` | `struct flex_array *` | tableau `ebitmap[]` |
| `type_val_to_struct_array` | `struct flex_array *` | `type_val_to_struct[]` |
| `te_avtab.htable` | `flex_array` | tableau direct |
| `filename_trans` | `hashtab` + `struct filename_trans` | `filename_trans_key` + `policydb_filenametr_search` |
| `filename_trans_datum` | `{ otype }` | `{ stypes, next, … }` |

**Correctif :** dual-path complet via `#if LINUX_VERSION_CODE`, avec wrappers `ksu_avtab_htable_get/set`, `add_type_flex_419()` et `add_filename_trans()` variante hashtab.

### 6. `rules.c` : layout `selinux_state.ss->`

En 4.19 il n'y a pas de `struct selinux_policy`. Le `policydb` est modifié **en place** :

```c
#define KSU_DB419     (&selinux_state.ss->policydb)
#define KSU_LOCK419   write_lock(&selinux_state.ss->policy_rwlock)
#define KSU_UNLOCK419 write_unlock(&selinux_state.ss->policy_rwlock)
```

Idem pour `selinux_hide.c` : `status_lock` et `status_page` sont dans `selinux_state.ss->`, pas à la racine.

### 7. Preinit : `CONFIG_HEADERS_INSTALL` + ordre d'intégration

- `CONFIG_HEADERS_INSTALL=y` et `KSU_REQUIRE_PREINIT=1` sont **obligatoires** : sans les UAPI installés dans `$(objtree)/usr/include`, le runner est silencieusement désactivé.
- Le script de hooks doit s'exécuter **après** l'intégration de FinaSU : il contient un garde `grep -rq "ksu_handle_setresuid" drivers/kernelsu/` qui saute `kernel/sys.c` si le répertoire n'existe pas encore.

---

## 🔨 Build

Le build tourne sur GitHub Actions (Ubuntu, Clang/LLVM, NDK r26d pour ksud).

```bash
# Variables surchargeables
FINASU_REF=v1.5.0                 # driver épinglé (recommandé)
KERNEL_PIN=9426323c2acd...        # commit noyau épinglé
FINASU_EXPECTED_SIZE=0x...        # taille du certificat DER du manager
FINASU_EXPECTED_HASH=...          # SHA-256 du certificat
```

**Artefacts produits :**

| Fichier | Contenu |
|---|---|
| `FinaSU-A-finasu-A-boot.img` | boot.img flashable (kernel + ksud + su) |
| `Image-finasu-A` | noyau brut |
| `ksud` | binaire userspace aarch64 |
| `finasu.lock` | versions exactes (driver, commit, signature manager) |
| `audit-finasu-A.txt` | verdict du validateur, config, symboles |
| `build-summary.txt` | résumé lisible + erreurs brutes |

> [!TIP]
> Le script affiche le verdict de `check_susfs_inline.sh` **avant** la compilation. Un hook manquant est détecté en quelques secondes au lieu d'un build de 20 minutes.

---

## 📲 Installation

> [!CAUTION]
> Bootloader déverrouillé requis. **Gardez `boot-stock.img` accessible.** Sur `kiev`, le recovery est dans `boot.img` (recovery-as-boot) : un boot cassé casse aussi le recovery. Seul **fastboot** reste fiable.

```bash
adb reboot bootloader
fastboot getvar current-slot

# vbmeta désactivé — obligatoire
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

# adapter le slot (boot_a ou boot_b)
fastboot flash boot_a FinaSU-A-finasu-A-boot.img
fastboot reboot
```

### Vérification

```bash
adb wait-for-device shell getprop sys.boot_completed   # → 1
adb shell su -c id                                     # → uid=0(root) … u:r:ksu:s0
```

Installez **l'APK dont la signature a été calculée au build**. Le noyau vérifie le certificat DER, pas le nom de paquet.

---

## 📌 Versions recommandées

| Composant | Version | Note |
|---|---|---|
| Driver FinaSU | **v1.5.0** (`fbf8e003`) | configuration vérifiée bout en bout |
| Manager FinaSU | **v1.6.4** (33211-6) | reconnaît SUSFS `Built-In` |
| SuSFS | v2.4.0 NON-GKI | patch 4.19 de JackA1ltman |
| MetaModule | 1.3.1 | montage OverlayFS |
| Zygisk | Zygisk Next | — |

> [!NOTE]
> Le manager **v1.5.0** affiche `Unknown protocol · read-only` avec toutes les capacités SUSFS `Unavailable`. Le **v1.6.4** reconnaît correctement le provider `Built-In` et débloque le bouton `Manage`. Driver et manager sont indépendants : garder le driver v1.5.0 avec le manager v1.6.4 est la combinaison validée.

---

## 🙏 Crédits

| Projet | Auteur | Rôle |
|---|---|---|
| [FinaSU](https://github.com/LyraVoid/FinaSU) | **LyraVoid** | driver root, preinit, couche SUSFS |
| [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) | **simonpunk** | SUSFS — création et version v2.4.0 |
| [NonGKI_Kernel_Build_2nd](https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd) | **JackA1ltman** | patch SUSFS 4.19 + script des hooks inline |
| — | **backslashxx** | co-auteur du script de hooks |
| [KernelSU](https://github.com/tiann/KernelSU) | **tiann** | projet amont |
| Zygisk Next · MetaModule | auteurs respectifs | injection Zygisk & montage modules |

Le code SUSFS et le driver FinaSU appartiennent à leurs auteurs. Ce dépôt ne contient que le **portage 4.19** : scripts de build, dual-paths de compatibilité et injection des hooks preinit.

---

## ⚠️ Avertissement

Ce noyau modifie le noyau d'un appareil réel. Un bootloop est possible.

CE LOGICIEL EST FOURNI « EN L'ÉTAT », SANS GARANTIE D'AUCUNE SORTE**, expresse ou implicite, y compris mais sans s'y limiter les garanties de qualité marchande, d'adéquation à un usage particulier et de non-contrefaçon.Tu l'utilises **à tes risques et périls**. Dans toute la mesure permise par la loi applicable, les auteurs et contributeurs ne peuvent être tenus responsables d'un appareil hors service (*brick*), d'une perte de données, d'une perte de garantie constructeur, d'un compte suspendu, d'un dommage matériel ou de tout préjudice direct ou indirect résultant de l'utilisation de ce dépôt.Cette clause reprend l'esprit des sections 11 et 12 de la GPL-2.0 (et 15–16 de la GPL-3.0), qui s'appliquent de toute façon aux composants distribués sous ces licences.### Risques concrets| Risque | Détail ||---|---|| **Bootloop / brick** | Un noyau ou un ramdisk invalide peut empêcher le démarrage. Sur `kiev`, le recovery est **dans** `boot.img` : un boot cassé casse aussi le recovery. Seul **fastboot** reste fiable. || **Perte de données** | Un échec de montage `/data` ou un reflash peut imposer un *factory reset*. Sauvegarde avant. || **Sécurité affaiblie** | `--disable-verity --disable-verification` désactive la chaîne de démarrage vérifiée. C'est un choix assumé, pas une recommandation. || **CGU d'applications** | Banques, paiement, jeux avec anti-triche : le root et le masquage peuvent violer leurs conditions d'utilisation. Suspensions de compte possibles. || **Cadre légal** | Le contournement de mesures techniques de protection est encadré différemment selon les juridictions. Renseigne-toi sur la tienne. || **Mauvais appareil** | Ne flashe **jamais** une image destinée à un autre modèle ou un autre KMI. |### Non-affiliation

- Sauvegardez vos données et votre `boot.img` d'origine
- Ne flashez pas une image d'un autre KMI ou d'un autre appareil
- `vbmeta` désactivé réduit la chaîne de confiance vérifiée — c'est un choix assumé
- Le masquage SUSFS doit être **configuré** : sans règles, `Nothing to apply` signifie qu'aucune dissimulation n'est active

---

<div align="center">

**Portage 4.19 non-GKI · FinaSU + SuSFS v2.4.0 · SUSFS Inline**

*Si ce travail vous a été utile, une ⭐ est appréciée.*

</div>
