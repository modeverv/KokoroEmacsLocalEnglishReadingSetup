from pathlib import Path
import json
import soundfile as sf
import numpy as np
import mlx_whisper
out=Path(__file__).resolve().parent
checks=[]
for engine in ['qwen','irodori']:
 for index,kind in [(1,'short'),(4,'reading')]:
  file=out/f'{engine}-{index:02d}-{kind}.wav';a,sr=sf.read(file)
  r=mlx_whisper.transcribe(str(file),path_or_hf_repo='mlx-community/whisper-small-mlx',language='ja',condition_on_previous_text=False)
  item={'file':file.name,'asr_text':r['text'],'seconds':len(a)/sr,'finite':bool(np.isfinite(a).all()),'peak':float(abs(a).max()),'rms':float(np.sqrt(np.mean(a*a)))}
  checks.append(item);print(json.dumps(item,ensure_ascii=False),flush=True)
  (out/'audio-check.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
