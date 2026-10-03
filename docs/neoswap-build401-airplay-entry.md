# Build401: main-menu AirPlay entry and boot contract repair

This private candidate includes the reviewed Build400 host runtime repair.
Build400 commit `f3919617dec99a1379ac53bdf45a63a439eefff2` did not package an
IPA: the donor contract still searched for the direct Core boot call replaced
by the common host wrapper. The updated contracts check the real wrapper
callsite ordering and its sole unchanged Core delegation, including failure
and epoch invalidation. No donation, JIT, startup or test guarantees are removed.
The prerequisite remains the last successfully packaged Build399.

AirPlay is accessible from an icon on the application main menu. It opens the
existing NeoPlay panel for AirPlay, Chromecast and Windows destinations.
The former NeoPlay activation entry in Settings > Tools is removed. Opening
the panel does not automatically start discovery or screen capture. Independent
Apple TV guidance and the existing translated destination controls remain.

The transport latency investigation is separate from this UI move. The existing
Cast path emits one-second complete HLS fragments and waits for at least three
seconds in the live playlist before loading the default Cast receiver. This is
startup accumulation, not a measured steady end-to-end delay. Merely shortening
fragments without changing the six-segment duration window would make playback
unavailable. No physical Chromecast latency improvement is claimed here.

All exact-SHA Apple, simulator, byte identity, error and lifecycle gates are
still required before private IPA401 delivery. The Core7bcc artifact and all
57 defining inputs remain pinned, with physical iPhone gameplay pending.
