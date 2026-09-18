"""Entry point inside a relocatable app; ignore user Python installations."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
if len(sys.argv) > 1 and sys.argv[1] == "service":
    del sys.argv[1]
    from speech_http.playback_service import main
else:
    from speech_http.playback import main

if __name__ == "__main__":
    main()
