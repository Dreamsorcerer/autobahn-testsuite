# Experiment only: force a full collection every second, to check whether the
# memory growth is garbage the GC has not collected yet.
import gc
import threading
import time


def _collect():
    while True:
        time.sleep(1)
        gc.collect()


_thread = threading.Thread(target=_collect)
_thread.daemon = True
_thread.start()
