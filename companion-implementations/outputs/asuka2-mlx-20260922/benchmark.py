"""Sequential local MLX comparison. Downloads must be completed before measured runs."""
from pathlib import Path
import argparse, json, time, hashlib, platform, importlib.metadata
import numpy as np
import soundfile as sf
import mlx.core as mx
from mlx_audio.tts.utils import load_model

OUT=Path(__file__).resolve().parent
MODELS={'irodori':'mlx-community/Irodori-TTS-500M-v3-8bit','qwen':'mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit'}
TEXTS=[('short','こんにちは。今日は、音声合成の聞き比べをします。窓の外には青い空が広がっています。'),('reading','午後三時、駅前の小さな喫茶店で友人を待っていました。温かいコーヒーを一口飲むと、雨に濡れた街の景色が、少しだけ明るく見えました。「お待たせ。久しぶりだね」と、懐かしい声が聞こえます。')]
p=argparse.ArgumentParser();p.add_argument('engine',choices=MODELS);p.add_argument('--prepare',action='store_true');args=p.parse_args()
t=time.perf_counter();model=load_model(MODELS[args.engine]);mx.eval(model.parameters());mx.synchronize();load_s=time.perf_counter()-t
print('LOAD',args.engine,load_s,flush=True)
if args.prepare: raise SystemExit
ref=OUT/'reference.wav';ref_text=(OUT/'reference.txt').read_text().strip()
settings={'num_steps':24,'t_schedule_mode':'sway','sway_coeff':-1.0,'duration_scale':1.0,'rng_seed':42} if args.engine=='irodori' else {'lang_code':'Japanese','ref_text':ref_text,'temperature':0.9,'top_k':50,'top_p':1.0,'repetition_penalty':1.5,'max_tokens':2048}
report={'engine':args.engine,'model':MODELS[args.engine],'load_seconds':load_s,'reference_sha256':hashlib.sha256(ref.read_bytes()).hexdigest(),'settings':settings,'platform':platform.platform(),'versions':{x:importlib.metadata.version(x) for x in ['mlx','mlx-audio','numpy']},'runs':[]}
# First short run measures cold generation. Three repeated short and reading runs measure warm generation.
for name,text in [TEXTS[0]]+[TEXTS[0]]*3+[TEXTS[1]]*3:
    idx=len(report['runs']);mx.random.seed(42);mx.synchronize();start=time.perf_counter();chunks=[];sr=None
    for result in model.generate(text=text,ref_audio=str(ref),**settings):
        mx.eval(result.audio);chunks.append(np.asarray(result.audio,dtype=np.float32).reshape(-1));sr=int(result.sample_rate)
    mx.synchronize();gen_s=time.perf_counter()-start
    a=np.concatenate(chunks);assert a.size and np.isfinite(a).all()
    filename=f'{args.engine}-{idx:02d}-{name}.wav';start=time.perf_counter();sf.write(OUT/filename,a,sr,subtype='PCM_16');write_s=time.perf_counter()-start
    row={'file':filename,'text':text,'phase':'cold' if idx==0 else 'warm','generation_seconds':gen_s,'write_seconds':write_s,'audio_seconds':len(a)/sr,'sample_rate':sr,'rtf':gen_s/(len(a)/sr),'peak':float(abs(a).max()),'rms':float(np.sqrt(np.mean(a*a))),'clipped_fraction':float(np.mean(abs(a)>=1))}
    report['runs'].append(row);(OUT/f'{args.engine}-metrics.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(row,ensure_ascii=False),flush=True)
