#include "node.h"

// A real process entry point for package-manager workers and child processes.
// Keep argv, environment and standard streams intact, as with the upstream Node
// CLI. In particular, do not inherit the JNI runtime's one-shot startup guard or
// redirect its output into the Agent service's log.
int main(int argc, char* argv[]) {
  return node::Start(argc, argv);
}
