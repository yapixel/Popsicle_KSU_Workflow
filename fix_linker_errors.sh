#!/bin/bash
set -e

# Fix 1: remove 'static' from ksu_handle_sys_reboot in supercalls.c
# Only under the #ifndef CONFIG_KSU_SUSFS block (the non-SUSFS version stays static)
# The SUSFS version at line ~804 needs to be non-static so reboot.c can link it.

python3 << 'PYEOF'
import sys

with open("kernel/supercalls.c", "r") as f:
    src = f.read()

original = src

OLD = ('#ifndef CONFIG_KSU_SUSFS\n'
       'static int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)\n')
NEW = ('#ifndef CONFIG_KSU_SUSFS\n'
       'int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)\n')

if OLD not in src:
    # Try the #else version (SUSFS path)
    OLD2 = ('#else\n'
            'int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)\n')
    if OLD2 in src:
        print("SKIP: SUSFS ksu_handle_sys_reboot already non-static")
    else:
        # It might just be static with no guard prefix visible here, find it directly
        OLD3 = 'static int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)\n'
        NEW3 = 'int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)\n'
        if OLD3 in src:
            src = src.replace(OLD3, NEW3, 1)
            print("OK fix1: removed static from ksu_handle_sys_reboot")
        else:
            print("ERROR: ksu_handle_sys_reboot not found", file=sys.stderr)
            sys.exit(1)
else:
    src = src.replace(OLD, NEW, 1)
    print("OK fix1: removed static from non-SUSFS ksu_handle_sys_reboot")

if src != original:
    with open("kernel/supercalls.c", "w") as f:
        f.write(src)
    print("supercalls.c updated.")
PYEOF

# Fix 2: create susfs_hooks_compat.c providing stubs for all symbols
# that syscall_hook_manager.c normally provides, used when CONFIG_KSU_SUSFS=y

cat > kernel/susfs_hooks_compat.c << 'CEOF'
// SPDX-License-Identifier: GPL-2.0-or-later
// Compatibility stubs for symbols normally provided by syscall_hook_manager.c
// Used when CONFIG_KSU_SUSFS=y (syscall_hook_manager is excluded in that path)

#ifdef CONFIG_KSU_SUSFS

#include <linux/types.h>
#include <linux/fs.h>
#include <linux/uaccess.h>

// Called from fs/stat.c
void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
    // handled by susfs directly via sus_kstat
}

// Called from fs/read_write.c
void ksu_init_rc_hook(void)
{
    // no-op: rc injection handled differently under susfs
}

// Called from fs/exec.c
void ksu_execveat_hook(void)
{
    // no-op: execveat handled via ksu_handle_execveat_ksud
}

// Called from drivers/input/input.c
void ksu_input_hook(void *data)
{
    // no-op: input handled separately
}

// Called from fs/read_write.c
void ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr)
{
    // no-op: read hook handled by ksud directly
}

#endif // CONFIG_KSU_SUSFS
CEOF

echo "OK fix2: created kernel/susfs_hooks_compat.c"

# Fix 3: add susfs_hooks_compat.c to the kernelsu Makefile
python3 << 'PYEOF'
import sys

makefile = "kernel/Makefile"
with open(makefile, "r") as f:
    src = f.read()

stub_line = "obj-$(CONFIG_KSU_SUSFS) += susfs_hooks_compat.o\n"

if stub_line in src:
    print("SKIP fix3: susfs_hooks_compat.o already in Makefile")
else:
    # Add after the first obj-y or obj-$(CONFIG_KSU) line
    import re
    # Find first obj- line and insert after it
    m = re.search(r'^obj-[^\n]+\n', src, re.MULTILINE)
    if m:
        insert_pos = m.end()
        src = src[:insert_pos] + stub_line + src[insert_pos:]
        with open(makefile, "w") as f:
            f.write(src)
        print("OK fix3: added susfs_hooks_compat.o to Makefile")
    else:
        # Just append
        with open(makefile, "a") as f:
            f.write(stub_line)
        print("OK fix3: appended susfs_hooks_compat.o to Makefile")
PYEOF
 
