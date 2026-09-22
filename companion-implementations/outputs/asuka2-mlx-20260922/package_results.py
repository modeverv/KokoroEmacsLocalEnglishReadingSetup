from pathlib import Path
import json,statistics,math,html
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
out=Path(__file__).resolve().parent
reports={k:json.loads((out/f'{k}-metrics.json').read_text()) for k in ['qwen','irodori']}
rows=[]
for engine,r in reports.items():
 for kind in ['short','reading']:
  runs=[x for x in r['runs'] if x['phase']=='warm' and kind in x['file']]
  rows.append({'engine':engine,'text':kind,'load_seconds':r['load_seconds'],'generation_median_seconds':statistics.median(x['generation_seconds'] for x in runs),'generation_min_seconds':min(x['generation_seconds'] for x in runs),'generation_max_seconds':max(x['generation_seconds'] for x in runs),'audio_median_seconds':statistics.median(x['audio_seconds'] for x in runs),'rtf_median':statistics.median(x['rtf'] for x in runs)})
(out/'summary.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
comparisons={}
for kind,index in [('short',1),('reading',4)]:
 arrays=[]
 for engine in reports:
  a,sr=sf.read(out/f'{engine}-{index:02d}-{kind}.wav');g=math.gcd(sr,48000);a=resample_poly(a,48000//g,sr//g)
  arrays.append(a)
 target=min([10**(-23/20)]+[10**(-1/20)*np.sqrt(np.mean(a*a))/max(abs(a)) for a in arrays])
 normalized=[a*(target/np.sqrt(np.mean(a*a))) for a in arrays]
 sf.write(out/f'compare-{kind}-qwen-then-irodori.wav',np.concatenate([normalized[0],np.zeros(48000),normalized[1]]),48000,subtype='PCM_16')
 comparisons[kind]={'order':['qwen','1 second silence','irodori'],'rms_dbfs':20*np.log10(target),'second_start_seconds':len(normalized[0])/48000+1}
(out/'comparison-metadata.json').write_text(json.dumps(comparisons,indent=2))
lines=['# asuka2 MLX TTS比較','', '実行日: 2026-09-22 / Apple M4 Max・128GB / Python 3.11.9 / mlx-audio 0.4.7 / MLX 0.32.2','', '## 条件','', '- 参照: assets/asuka2.wav の先頭0〜4.8秒。70.5秒の原本から最初の自己紹介を抽出し、左右平均でモノラル化。両モデルで同一WAVを使用。','- Qwen3-TTS-12Hz-1.7B-Base-8bit: 参照音声とASR由来の文字起こし（固有名詞を補正）を使うICL方式。Japanese、temperature=0.9、repetition_penalty=1.5。','- Irodori-TTS-500M-v3-8bit: 参照音声、24 steps、sway=-1、duration_scale=1。','- seed=42。モデルを順番に実行。短文初回の後、短文3回・長文3回。各回の参照処理を含む生成時間を測定し、MLX同期・配列取得完了まで計時。WAV書込は別計時。','- ダウンロード完了後、HF_HUB_OFFLINE=1で測定。モデル読込時間は別計測。プロセス起動・Python import時間は含まない。通常の常駐アプリが動作中で、専有ベンチマークではない。','- 両モデルは規模・方式・出力サンプルレートが異なる。今回の設定の比較であり、系列全体の順位を示すものではない。','', '## 処理時間（warm 3回の中央値）','', '|モデル|文章|生成秒（最小〜最大）|音声秒|RTF|','|---|---|---:|---:|---:|']
for row in rows:
 lines.append(f"|{row['engine']}|{row['text']}|{row['generation_median_seconds']:.2f} ({row['generation_min_seconds']:.2f}–{row['generation_max_seconds']:.2f})|{row['audio_median_seconds']:.2f}|{row['rtf_median']:.2f}|")
lines+=['','RTF = 生成秒 / 音声秒。1未満なら実時間より速い。','']
for engine,r in reports.items():
 lines.append(f"- {engine}: モデル読込 {r['load_seconds']:.2f}秒、短文初回生成 {r['runs'][0]['generation_seconds']:.2f}秒。")
lines+=['','## 試聴','','比較WAVは **Qwen → 1秒無音 → Irodori**。48kHz・16bit・mono。全体RMSを揃え、ピークが−1dBFSを超えない共通音量に調整（LUFS合わせではない）。元の生成WAVも保存。時間伸縮・無音除去は行っていない。','']
for kind,idx in [('short',1),('reading',4)]:
 lines +=[f'### {kind}',reports['qwen']['runs'][idx]['text'],'',f'- [連続比較](compare-{kind}-qwen-then-irodori.wav)',f'- [Qwen原音](qwen-{idx:02d}-{kind}.wav)',f'- [Irodori原音](irodori-{idx:02d}-{kind}.wav)','']
lines+=['声の似方、抑揚、読み間違い、文末や息継ぎを試聴で比較してください。数値検査とASRは主観的な声質評価を代替しません。','','## 再実行','','```sh','HF_HUB_OFFLINE=1 /Users/seijiro/.cache/asuka2-mlx-benchmark-venv/bin/python benchmark.py irodori','HF_HUB_OFFLINE=1 /Users/seijiro/.cache/asuka2-mlx-benchmark-venv/bin/python benchmark.py qwen','/Users/seijiro/.cache/asuka2-mlx-benchmark-venv/bin/python package_results.py','```','','環境: environment.txt、設定・全計測値: *-metrics.json、原本ハッシュ・切出条件: reference-metadata.json。']
(out/'README.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(rows,ensure_ascii=False,indent=2))
