#!/usr/bin/env python3
"""Portage SELinux-hide de FinaSU v1.6.4 vers LineageOS 4.19 (sm8250).
Fonde sur la lecture de selinux_hide.c, ss/services.h et ss/policydb.h.

CORRECTIONS :
  - Noyau 4.19 : struct symtab { struct hashtab *table; } -> table est un
    POINTEUR. La macro symtab_search doit utiliser (s)->table SANS '&'.
    (Aligne sur FinaSU amont, sepolicy.c, guard < 5.9.0.)
  - Alias selinux_policy -> selinux_ss force en tete de selinux_hide.c ET
    sepolicy.c (sepolicy.c n'inclut pas selinux.h).
"""
import os, re, sys

GW = sys.argv[1]
KR = os.path.join(GW, "kernel_sources")
KS = os.path.join(KR, "FinaSU", "kernel")
n = 0

def rd(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()

def wr(p, c):
    with open(p, "w", encoding="utf-8") as f:
        f.write(c)

ALIAS_GUARD = ("/* KSU_SELINUX_POLICY_ALIAS_FORCE */\n"
               "#include <linux/version.h>\n"
               "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n"
               "#ifndef selinux_policy\n"
               "#define selinux_policy selinux_ss\n"
               "#endif\n"
               "#endif\n")

def prepend_guard(c):
    if "KSU_SELINUX_POLICY_ALIAS_FORCE" in c:
        return c
    m = re.search(r"// SPDX-License-Identifier:[^\n]*\n", c)
    pos = m.end() if m else 0
    return c[:pos] + ALIAS_GUARD + c[pos:]

# ---- A : alias de type. 4.19 n'a pas struct selinux_policy ; selinux_ss
#         possede les trois champs utilises (sidtab, policydb, latest_granting).
p = os.path.join(KS, "selinux/selinux.h")
if os.path.isfile(p):
    c = rd(p)
    if "KSU_SELINUX_POLICY_ALIAS" not in c:
        wr(p, "/* KSU_SELINUX_POLICY_ALIAS */\n"
              "#include <linux/version.h>\n"
              "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n"
              "#ifndef selinux_policy\n"
              "#define selinux_policy selinux_ss\n"
              "#endif\n"
              "#endif\n\n" + c)
        n += 1
        print("  OK    selinux.h : alias selinux_policy -> selinux_ss")

# ---- B : selinux_hide.c. Les implementations ne sont PAS gardees par version
#         dans le source : on les laisse actives et on ponte les 6 differences.
p = os.path.join(KS, "feature/selinux_hide.c")
if os.path.isfile(p):
    c = rd(p); o = c
    if "KSU_SELINUX_419" not in c:
        c = c.replace("mutex_lock(&selinux_state.status_lock);", "ksu_status_lock();")
        c = c.replace("mutex_unlock(&selinux_state.status_lock);", "ksu_status_unlock();")
        c = c.replace("selinux_state.status_page", "ksu_status_page")
        c = c.replace("rcu_dereference(selinux_state.policy)", "KSU_LIVE_POLICY()")
        for t in ("scontext", "tcontext"):
            c = c.replace("&policydb->type_attr_map_array[%s->type - 1]" % t,
                          "ksu_type_attr_map(policydb, %s->type - 1)" % t)
            c = c.replace("policydb->type_val_to_struct[%s->type - 1]" % t,
                          "ksu_type_val_to_struct(policydb, %s->type - 1)" % t)

        c = re.sub(r"^([ \t]*)static int sidtab_entry_to_string\(",
                   r"#if !KSU_SELINUX_419\n\1static int sidtab_entry_to_string(",
                   c, count=1, flags=re.M)
        c = re.sub(r"(sidtab_sid2str_put\(sidtab, entry, \*scontext, \*scontext_len\);"
                   r"\s*\n\s*return rc;\s*\n\})",
                   r"\1\n#endif /* !KSU_SELINUX_419 */", c, count=1)
        c = c.replace("struct sidtab_entry *entry;",
                      "#if !KSU_SELINUX_419\n    struct sidtab_entry *entry;\n#endif")
        c = c.replace("entry = sidtab_search_entry(sidtab, sid);",
                      "#if KSU_SELINUX_419\n"
                      "    {\n"
                      "        struct context *c419 = sidtab_search(sidtab, sid);\n"
                      "        if (!c419) { rc = -EINVAL; goto out_unlock; }\n"
                      "        rc = context_struct_to_string(policydb, c419, scontext, scontext_len);\n"
                      "    }\n"
                      "#else\n"
                      "    entry = sidtab_search_entry(sidtab, sid);")
        c = c.replace("rc = sidtab_entry_to_string(policydb, sidtab, entry, scontext, scontext_len);",
                      "rc = sidtab_entry_to_string(policydb, sidtab, entry, scontext, scontext_len);\n#endif")

        # Le chemin SUSFS de enable() retourne 0 sans poser keep_backup :
        # drop_backup_if_unused() libererait notre backup.
        c = re.sub(r"(#ifdef CONFIG_KSU_SUSFS\s*\n)([ \t]*)return 0;",
                   r"\1\2ksu_selinux_hide_keep_backup = true;\n\2return 0;", c, count=1)

        compat = """/* ==== KSU_SELINUX_419 ==== */
#include <linux/version.h>
#include <linux/flex_array.h>
#ifndef SIMPLE_TRANSACTION_LIMIT
#define SIMPLE_TRANSACTION_LIMIT (PAGE_SIZE - sizeof(void *) - 1)
#endif
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#define KSU_SELINUX_419 1
extern struct selinux_policy *backup_sepolicy;
/* 4.19 : struct symtab { struct hashtab *table; } -> table est un POINTEUR.
 * Surtout PAS de '&' : &(s)->table produirait un hashtab** (les 9 erreurs).
 * Aligne sur FinaSU amont (sepolicy.c, guard < 5.9.0). */
#define symtab_search(s, name) hashtab_search((s)->table, name)
#define ksu_status_lock()   mutex_lock(&selinux_state.ss->status_lock)
#define ksu_status_unlock() mutex_unlock(&selinux_state.ss->status_lock)
#define ksu_status_page     (selinux_state.ss->status_page)
#define KSU_LIVE_POLICY()   (selinux_state.ss)
#define ksu_type_attr_map(p, i) \\
    ((struct ebitmap *)flex_array_get((p)->type_attr_map_array, (i)))
#define ksu_type_val_to_struct(p, i) \\
    ((struct type_datum *)flex_array_get_ptr((p)->type_val_to_struct_array, (i)))
#else
#define KSU_SELINUX_419 0
#define ksu_status_lock()   mutex_lock(&selinux_state.status_lock)
#define ksu_status_unlock() mutex_unlock(&selinux_state.status_lock)
#define ksu_status_page     (selinux_state.status_page)
#define KSU_LIVE_POLICY()   rcu_dereference(selinux_state.policy)
#define ksu_type_attr_map(p, i) (&(p)->type_attr_map_array[(i)])
#define ksu_type_val_to_struct(p, i) ((p)->type_val_to_struct[(i)])
#endif

"""
        c = c.replace("static DEFINE_MUTEX(selinux_hide_mutex);",
                      compat + "static DEFINE_MUTEX(selinux_hide_mutex);", 1)

        helper = """/* KSU_HIDE_READY_419 : garde-fou pour les hooks noyau */
bool ksu_selinux_hide_ready(void)
{
    return ksu_selinux_hide_enabled && backup_sepolicy;
}

"""
        c = c.replace("ssize_t my_write_context(struct file *file, char *buf, size_t size)",
                      helper + "ssize_t my_write_context(struct file *file, char *buf, size_t size)", 1)

    # Reparation inconditionnelle : si un ancien portage a laisse le '&', on le retire.
    c = c.replace("hashtab_search(&(s)->table, name)", "hashtab_search((s)->table, name)")
    # Alias force en tete, avant tout prototype (idempotent).
    c = prepend_guard(c)

    if c != o:
        wr(p, c); n += 1
        print("  OK    selinux_hide.c : ponts 4.19 + macro symtab_search corrigee + alias")

# ---- C : ksu_destroy_sepolicy doit vraiment detruire en 4.19
p = os.path.join(KS, "selinux/sepolicy.c")
if os.path.isfile(p):
    c = rd(p); o = c
    c = c.replace("void ksu_destroy_sepolicy(struct selinux_policy *pol) { (void)pol; }",
                  "void ksu_destroy_sepolicy(struct selinux_policy *pol) {\n"
                  "    if (!pol) return;\n"
                  "    policydb_destroy(&pol->policydb);\n"
                  "    kfree(pol);\n}")
    # sepolicy.c n'inclut PAS selinux.h : sans alias force ici,
    # 'struct selinux_policy' reste incomplet au dereferencement (pol->policydb).
    c = prepend_guard(c)
    if c != o:
        wr(p, c); n += 1
        print("  OK    sepolicy.c : ksu_destroy_sepolicy reel + alias force")

# ---- D : moteur de backup dans rules.c
p = os.path.join(KS, "selinux/rules.c")
if os.path.isfile(p):
    c = rd(p); o = c
    if "KSU_BACKUP_419" not in c:
        c = c.replace("#include <linux/slab.h>",
                      "#include <linux/slab.h>\n#include <linux/vmalloc.h>", 1)
        engine = r'''
/* ==== KSU_BACKUP_419 ==== */
extern bool ksu_set_original_types(struct policydb *db, struct policydb *orig_db, u32 gen);
struct selinux_policy *backup_sepolicy;
static u32 ksu_policy_generation_419;

static struct policydb *ksu_dup_policydb_419(struct policydb *src)
{
    struct policy_file fp;
    struct policydb *dst = NULL;
    void *data = NULL;
    size_t len, used;
    int ret;

    if (!src || !src->len)
        return ERR_PTR(-EINVAL);

    /* policydb_read() re-ajoute chaque type a sa propre carte d'attributs :
     * la sortie peut depasser src->len. Marge identique a ksu_dup_sepolicy(). */
    len = src->len + (size_t)src->p_types.nprim * (sizeof(u32) + sizeof(u64));
    data = vmalloc(len);
    if (!data)
        return ERR_PTR(-ENOMEM);

    fp.data = data;
    fp.len = len;
    ret = policydb_write(src, &fp);
    if (ret) {
        pr_err("ksu: backup policydb_write: %d\n", ret);
        goto out;
    }
    used = len - fp.len;

    /* policydb_write() n'emet pas les bits de config Android. Sans ce fixup,
     * policydb_read() perd android_netlink_route/getneigh et la frontiere
     * netlink SELinux cesse d'etre appliquee. Offset = 4*2 + 8 + 4 = 20. */
    if (used >= 20 + sizeof(u32)) {
        u32 *cfg = (u32 *)((unsigned long)data + 20);
        if (src->android_netlink_route)
            *cfg |= POLICYDB_CONFIG_ANDROID_NETLINK_ROUTE;
        if (src->android_netlink_getneigh)
            *cfg |= POLICYDB_CONFIG_ANDROID_NETLINK_GETNEIGH;
    }

    dst = kzalloc(sizeof(*dst), GFP_KERNEL);
    if (!dst) { ret = -ENOMEM; goto out; }
    fp.data = data;
    fp.len = used;
    ret = policydb_read(dst, &fp);
    if (ret) {
        pr_err("ksu: backup policydb_read: %d\n", ret);
        kfree(dst);
        dst = NULL;
        goto out;
    }
    dst->len = used;
out:
    vfree(data);
    return dst ? dst : ERR_PTR(ret ? ret : -EINVAL);
}

static struct selinux_policy *ksu_make_backup_419(struct policydb *src)
{
    struct policydb *dup;
    struct sidtab *st;
    struct selinux_policy *bk;
    int ret;

    dup = ksu_dup_policydb_419(src);
    if (IS_ERR(dup))
        return ERR_PTR(PTR_ERR(dup));

    st = kzalloc(sizeof(*st), GFP_KERNEL);
    if (!st) { ret = -ENOMEM; goto err_dup; }
    ret = sidtab_init(st);
    if (ret) goto err_st;
    ret = policydb_load_isids(dup, st);
    if (ret) goto err_sidtab;

    bk = kzalloc(sizeof(*bk), GFP_KERNEL);
    if (!bk) { ret = -ENOMEM; goto err_sidtab; }
    bk->sidtab = st;
    bk->policydb = *dup;
    kfree(dup);
    bk->latest_granting = 1;
    return bk;

err_sidtab:
    sidtab_destroy(st);
err_st:
    kfree(st);
err_dup:
    policydb_destroy(dup);
    kfree(dup);
    return ERR_PTR(ret);
}
'''
        c = c.replace("void apply_kernelsu_rules(void) {",
                      engine + "\nvoid apply_kernelsu_rules(void) {", 1)
        c = c.replace("    KSU_LOCK419; db = KSU_DB419;",
                      "    /* Backup pris HORS du rwlock : vmalloc/policydb_read dorment. */\n"
                      "    if (!backup_sepolicy) {\n"
                      "        backup_sepolicy = ksu_make_backup_419(&selinux_state.ss->policydb);\n"
                      "        if (IS_ERR(backup_sepolicy)) {\n"
                      "            pr_err(\"ksu: backup sepolicy indisponible (%ld)\\n\",\n"
                      "                   PTR_ERR(backup_sepolicy));\n"
                      "            backup_sepolicy = NULL;\n"
                      "        } else {\n"
                      "            pr_info(\"ksu: backup sepolicy 4.19 pret (%u types)\\n\",\n"
                      "                    backup_sepolicy->policydb.p_types.nprim);\n"
                      "        }\n"
                      "    }\n"
                      "    KSU_LOCK419; db = KSU_DB419;\n"
                      "    ksu_set_original_types(db, db, ++ksu_policy_generation_419);", 1)
    if c != o:
        wr(p, c); n += 1
        print("  OK    rules.c : moteur de backup 4.19")

# ---- E : hooks. Le script inline cherche ksu_hide_setprocattr (ancien nom) ;
#         FinaSU exporte my_setprocattr. Et il n'a aucune section selinuxfs.c.
p = os.path.join(KR, "security/selinux/hooks.c")
if os.path.isfile(p):
    c = rd(p); o = c
    if "KSU_HOOK_SETPROCATTR_419" not in c:
        m = re.search(r"^static int selinux_setprocattr\(struct task_struct \*p,", c, re.M)
        if m:
            d = ("#ifdef CONFIG_KSU_SUSFS\n/* KSU_HOOK_SETPROCATTR_419 */\n"
                 "extern bool ksu_selinux_hide_ready(void);\n"
                 "extern int my_setprocattr(const char *name, void *value, size_t size);\n"
                 "#endif\n")
            c = c[:m.start()] + d + c[m.start():]
            c = c.replace("char *str = value;",
                          "char *str = value;\n"
                          "#ifdef CONFIG_KSU_SUSFS\n"
                          "\tif (p == current && current_uid().val >= 10000 &&\n"
                          "\t    !strcmp(name, \"current\") && ksu_selinux_hide_ready())\n"
                          "\t\treturn my_setprocattr(name, value, size);\n"
                          "#endif\n", 1)
            wr(p, c); n += 1
            print("  OK    hooks.c : my_setprocattr branche")
        else:
            print("  ECHEC hooks.c : signature selinux_setprocattr introuvable")

p = os.path.join(KR, "security/selinux/selinuxfs.c")
if os.path.isfile(p):
    c = rd(p); o = c
    if "KSU_HOOK_SELINUXFS_419" not in c:
        d = ("\n#ifdef CONFIG_KSU_SUSFS\n/* KSU_HOOK_SELINUXFS_419 */\n"
             "extern bool ksu_selinux_hide_ready(void);\n"
             "extern ssize_t my_write_context(struct file *file, char *buf, size_t size);\n"
             "extern ssize_t my_write_access(struct file *file, char *buf, size_t size);\n"
             "#endif\n")
        last = 0
        for mm in re.finditer(r"^#include[^\n]*\n", c, re.M):
            last = mm.end()
        c = c[:last] + d + c[last:]
        got = 0
        for fn, mine in (("sel_write_context", "my_write_context"),
                         ("sel_write_access", "my_write_access")):
            pat = r"(static ssize_t " + fn + r"\(struct file \*file, char \*buf, size_t size\)\s*\n\{)"
            rep = (r"\1" + "\n#ifdef CONFIG_KSU_SUSFS\n"
                   "\tif (current_uid().val >= 10000 && ksu_selinux_hide_ready())\n"
                   "\t\treturn " + mine + "(file, buf, size);\n#endif\n")
            c2 = re.sub(pat, rep, c, count=1)
            if c2 != c:
                c = c2; got += 1
            else:
                print("  ECHEC selinuxfs.c : " + fn + " introuvable")
        wr(p, c); n += 1
        print("  OK    selinuxfs.c : %d/2 hooks branches" % got)

# ---- Verification finale : la macro ne doit plus contenir de '&'
p = os.path.join(KS, "feature/selinux_hide.c")
if os.path.isfile(p):
    c = rd(p)
    if re.search(r"hashtab_search\(\s*&\s*\(s\)\s*->\s*table", c):
        print("  ERREUR : macro symtab_search contient encore '&' !")
        sys.exit(1)
    n_calls = len(re.findall(r"\bsymtab_search\s*\(", c)) - 1
    print("  OK    verification : macro sans '&', %d appels symtab_search (attendu 9)" % n_calls)

print("  === fix_selinux : %d fichier(s) modifies ===" % n)
