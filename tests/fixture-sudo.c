#include <stdio.h>
#include <unistd.h>

/* A deliberately tiny setuid test double.  The fixture runs target scripts as
 * an unprivileged SSH user while allowing only their explicit `sudo command`
 * boundaries to regain root, which makes shell-redirection bugs observable. */
int main(int argc, char **argv)
{
	if (argc < 2)
		return 64;
	if (setgid(0) != 0 || setuid(0) != 0) {
		perror("fixture sudo");
		return 77;
	}
	execvp(argv[1], &argv[1]);
	perror("fixture sudo exec");
	return 127;
}
