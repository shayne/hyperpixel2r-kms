#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* A deliberately tiny setuid test double. The fixture uses it for explicit
 * privilege boundaries and for direct lifecycle unit scenarios, which keeps
 * shell-redirection and run-as bugs observable. */
int main(int argc, char **argv)
{
	if (argc < 2)
		return 64;
	if (getenv("HP2R_FIXTURE_REJECT_SUDO_RUNAS") != NULL &&
	    (strcmp(argv[1], "-u") == 0 || strcmp(argv[1], "-g") == 0)) {
		fputs("sudo: a password is required\n", stderr);
		return 1;
	}
	if (setgid(0) != 0 || setuid(0) != 0) {
		perror("fixture sudo");
		return 77;
	}
	execvp(argv[1], &argv[1]);
	perror("fixture sudo exec");
	return 127;
}
