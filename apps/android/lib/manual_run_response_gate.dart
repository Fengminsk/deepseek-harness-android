/// Orders asynchronous status reads against user submissions and newer reads.
class ManualRunResponseGate {
  int _generation = 0;
  int _statusTicket = 0;

  int get generation => _generation;

  int begin() {
    _statusTicket++;
    return ++_generation;
  }

  int nextStatusTicket() => ++_statusTicket;

  bool accepts(int generation) => generation == _generation;

  bool acceptsStatus(
    int generation,
    int ticket,
    String requestedRunId,
    String? currentRunId,
  ) =>
      accepts(generation) &&
      ticket == _statusTicket &&
      requestedRunId == currentRunId;
}
