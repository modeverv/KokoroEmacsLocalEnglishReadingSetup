"""Bounded PCM queue, independent of networking and audio hardware."""
from collections import deque
from array import array
from dataclasses import dataclass, field
import threading

RATE = 24000
MAX_BYTES = 64 * 1024 * 1024


@dataclass
class Utterance:
    id: int
    chunks: deque = field(default_factory=deque)
    index: int = 0
    buffered: int = 0
    received: int = 0
    complete: bool = False
    started: bool = False
    volume: float = 1.0
    end_time: float = 0.0


class PlaybackQueue:
    def __init__(self, prebuffer=1.0):
        self.lock = threading.RLock()
        self.entries = deque()
        self.events = deque()
        self.last_id = -1
        self.buffered = 0
        self.held = False
        self.warmup = 1
        self.prebuffer = int(prebuffer * RATE * 2)

    def reserve(self, id, volume=1.0):
        with self.lock:
            if type(id) is not int or id <= self.last_id or len(self.entries) >= 32:
                raise ValueError("IDs must increase; at most 32 pending utterances")
            if not isinstance(volume, (int, float)) or not 0 <= volume <= 1:
                raise ValueError("volume must be between 0 and 1")
            self.last_id = id
            self.entries.append(Utterance(id, volume=volume))

    def find(self, id):
        with self.lock:
            for entry in self.entries:
                if entry.id == id:
                    return entry
        raise ValueError("utterance cancelled, finished, or not reserved")

    def append(self, id, index, pcm):
        with self.lock:
            volume = self.find(id).volume
        if volume != 1.0:
            import sys
            samples = array("h", pcm)
            if sys.byteorder != "little":
                samples.byteswap()
            samples = array("h", (int(sample * volume) for sample in samples))
            if sys.byteorder != "little":
                samples.byteswap()
            pcm = samples.tobytes()
        with self.lock:
            entry = self.find(id)
            if entry.complete or type(index) is not int or index != entry.index:
                raise ValueError("duplicate or out-of-order audio")
            if not pcm or len(pcm) % 2 or self.buffered + len(pcm) > MAX_BYTES:
                raise ValueError("invalid PCM or playback buffer full")
            entry.chunks.append(memoryview(pcm))
            entry.index += 1
            entry.buffered += len(pcm)
            entry.received += len(pcm)
            self.buffered += len(pcm)

    def complete(self, id, count):
        with self.lock:
            entry = self.find(id)
            if entry.complete or type(count) is not int or count != entry.index or count < 1:
                raise ValueError("incomplete or duplicate delivery")
            entry.complete = True
            return entry.received / (RATE * 2)

    def stop(self):
        with self.lock:
            self.entries.clear()
            self.events.clear()
            self.buffered = 0
            self.held = False
            self.warmup = 1
            # Never reuse IDs: a late upload must not become new playback.

    def discard(self, id):
        with self.lock:
            entry = self.find(id)
            self.entries.remove(entry)
            self.buffered -= entry.buffered
            self.events = deque(event for event in self.events if event[2] != id)

    def play(self, warmup=1):
        with self.lock:
            self.held = False
            self.warmup = max(1, min(32, int(warmup)))

    def ready(self, entry):
        return entry.buffered > 0 and (entry.complete or entry.buffered >= self.prebuffer)

    def render(self, frames, dac_time):
        """Fill a device block, recording events at the actual DAC frame times.

        Adjacent ready utterances share the same block without a silence gap.
        Events are delivered later, when the device clock reaches their time.
        """
        output = bytearray(frames * 2)
        offset = 0
        with self.lock:
            if self.held:
                return output
            if self.warmup > 1:
                initial = list(self.entries)[:self.warmup]
                if not initial or not all(self.ready(e) for e in initial):
                    return output
                self.warmup = 1
            while self.entries and offset < len(output):
                entry = self.entries[0]
                if not entry.started:
                    if not self.ready(entry):
                        break
                    entry.started = True
                    self.events.append((dac_time + offset / (RATE * 2), "started", entry.id))
                if not entry.chunks:
                    if not entry.complete:
                        break
                    self.events.append((entry.end_time, "finished", entry.id))
                    self.entries.popleft()
                    continue
                chunk = entry.chunks[0]
                count = min(len(chunk), len(output) - offset)
                output[offset:offset + count] = chunk[:count]
                offset += count
                entry.end_time = dac_time + offset / (RATE * 2)
                entry.buffered -= count
                self.buffered -= count
                if count == len(chunk):
                    entry.chunks.popleft()
                else:
                    entry.chunks[0] = chunk[count:]
                if not entry.chunks and entry.complete:
                    self.events.append((dac_time + offset / (RATE * 2), "finished", entry.id))
                    self.entries.popleft()
        return output

    def due_events(self, now):
        with self.lock:
            result = []
            while self.events and self.events[0][0] <= now:
                result.append(self.events.popleft())
            return result
