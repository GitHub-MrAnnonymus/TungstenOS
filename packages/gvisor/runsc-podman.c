/*
 * runsc as Podman's OCI runtime on TungstenOS, with the flags it needs there.
 * A binary, not a shell script: SELinux decides the domain of a script from its
 * interpreter, so conmon could not start a script wrapper in the Podman domain.
 *
 *  --directfs=false        homes are noexec: with direct file access the gofer
 *                          remounts the image read-only, dropping the locked noexec
 *                          flag (EPERM).
 *  --overlay2=root:memory  the container's own writes (packages, build output) live
 *                          in memory; in a file next to the image (the default) they
 *                          are on the noexec home, where programs built in the
 *                          container could not run.
 *  --ignore-cgroups        rootless: the user manager owns the cgroup tree.
 *  --platform=kvm          when /dev/kvm is usable. gVisor's default platform, systrap,
 *                          unmaps the vDSO from its stub processes, which the TungstenOS
 *                          kernel forbids (CONFIG_MSEAL_SYSTEM_MAPPINGS, sealed system
 *                          mappings; the kernel documentation names gVisor as broken by
 *                          it). KVM needs no stubs, no ptrace and no executable memory.
 *
 * runsc finds its sidecars next to its real path (/proc/self/exe), so exec is enough.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const char runsc[] = "/usr/lib/gvisor/runsc";
static const char *const flags[] = {
	"--directfs=false",
	"--overlay2=root:memory",
	"--ignore-cgroups",
};
#define NFLAGS (sizeof(flags) / sizeof(flags[0]))

int main(int argc, char **argv)
{
	/* One extra slot for --platform=kvm. */
	char **args = calloc((size_t)argc + NFLAGS + 2, sizeof(*args));
	if (!args) {
		perror("runsc-podman");
		return 127;
	}
	size_t n = 0;
	args[n++] = (char *)runsc;
	for (size_t i = 0; i < NFLAGS; i++)
		args[n++] = (char *)flags[i];
	if (access("/dev/kvm", R_OK | W_OK) == 0)
		args[n++] = "--platform=kvm";
	else if (argc > 1)
		fprintf(stderr, "runsc-podman: /dev/kvm is not usable (no hardware virtualization, "
			"or none passed to this VM); gVisor's systrap platform cannot run on the "
			"TungstenOS kernel, which seals system mappings\n");
	for (int i = 1; i < argc; i++)
		args[n++] = argv[i];
	execv(runsc, args);
	perror("runsc-podman: " "/usr/lib/gvisor/runsc");
	return 127;
}
