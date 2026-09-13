# AudioRingBufferChecks

This harness exercises the C11 implementation through its public C ABI with
real producer, consumer, and manager threads. It checks:

- ordered stereo frames while management requests consumer-owned discard;
- post-discard progress and a non-secret canary frame;
- coherent `{target gain, ramp duration}` commands under concurrent updates;
- FIFO payload/revision integrity, explicit overflow, and retry of a final event;
- monotonic acknowledgment observed from a third thread;
- rejection of overflowing allocation capacities.
- callback disable while an accepted call holds userdata, rejection of later
  calls, and payload retirement while a disabled registration is still invoked.

The implementation is compiled as C, while the harness uses C++17 threads.
Normal Core testing includes the harness:

```sh
cmake -S Source/Core -B /tmp/lowend-core-checks -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build /tmp/lowend-core-checks
ctest --test-dir /tmp/lowend-core-checks --output-on-failure
```

To run ThreadSanitizer on a compiler/runtime that supports it:

```sh
mkdir -p /tmp/lowend-ring-tsan
clang -std=c11 -O1 -g -fsanitize=thread \
  -I SystemAudioProcessor/Sources/AudioRingBufferC/include \
  -c SystemAudioProcessor/Sources/AudioRingBufferC/AudioRingBufferC.c \
  -o /tmp/lowend-ring-tsan/ring.o
clang++ -std=c++17 -O1 -g -fsanitize=thread \
  -I SystemAudioProcessor/Sources/AudioRingBufferC/include \
  SystemAudioProcessor/Tests/AudioRingBufferChecks/main.cpp \
  /tmp/lowend-ring-tsan/ring.o -o /tmp/lowend-ring-tsan/checks
TSAN_OPTIONS=halt_on_error=1 /tmp/lowend-ring-tsan/checks
```

An empty sanitizer report is bounded evidence for these exercised schedules,
not proof that arbitrary caller ownership or lifecycle patterns are safe.
`clear`/destroy are only called after both endpoints have stopped. The manager
never consumes or clears the ring concurrently.

The callback gate is different from its userdata: after disable and zero
in-flight calls, userdata can be retired, but the gate itself remains allocated
until successful callback-source removal prevents all future entry attempts.
The stress fixture keeps calling the disabled gate after deleting its payload,
then joins every callback thread before destroying the gate.
