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
	char **args = calloc((size_t)argc + NFLAGS + 1, sizeof(*args));
	if (!args) {
		perror("runsc-podman");
		return 127;
	}
	args[0] = (char *)runsc;
	for (size_t i = 0; i < NFLAGS; i++)
		args[1 + i] = (char *)flags[i];
	for (int i = 1; i < argc; i++)
		args[NFLAGS + (size_t)i] = argv[i];
	execv(runsc, args);
	perror("runsc-podman: " "/usr/lib/gvisor/runsc");
	return 127;
}
