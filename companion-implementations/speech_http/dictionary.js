const $ = id => document.getElementById(id);
let entries = [], audioURL;
function status(text) { $('status').textContent = text; }
async function request(path, method='GET', body) {
  const response = await fetch(path, {method, headers: {'Content-Type':'application/json','X-Reader-Dictionary':'1'}, body:body ? JSON.stringify(body) : undefined});
  if (!response.ok) {
    let detail; try { detail=(await response.json()).detail; } catch {}
    throw new Error(typeof detail === 'string' ? detail : '操作に失敗しました。入力とサーバーの状態を確認してください。');
  }
  return response;
}
function input() { return {word:$('word').value.trim(), reading:$('reading').value.trim()}; }
function busy(value) { for (const button of document.querySelectorAll('button')) button.disabled=value; }
async function load() { entries=(await (await request('/api/entries')).json()).entries; render(); }
function render() {
  const query=$('search').value;
  const shown=entries.filter(e=>e.word.includes(query)||e.reading.includes(query));
  $('entries').replaceChildren(); $('count').textContent=`${entries.length}語`;
  $('empty').hidden=shown.length>0;
  $('empty').textContent=entries.length ? '一致する単語がありません。' : 'まだ単語が登録されていません。';
  for (const entry of shown) {
    const row=document.createElement('li'), names=document.createElement('div'), word=document.createElement('strong'), reading=document.createElement('span'), actions=document.createElement('div');
    word.textContent=entry.word; reading.textContent=entry.reading; names.append(word,reading); actions.className='row-actions';
    const edit=document.createElement('button'); edit.textContent='編集'; edit.className='secondary'; edit.onclick=()=>{$('word').value=entry.word;$('reading').value=entry.reading;$('reading').focus();status('読みを変更して「登録する」を押してください。');};
    const remove=document.createElement('button'); remove.textContent='削除'; remove.className='text-button'; remove.onclick=async()=>{
      busy(true); try {await request('/api/entries?word='+encodeURIComponent(entry.word),'DELETE');await load();status(`「${entry.word}」を削除しました。`);} catch(e){status(e.message);} finally{busy(false);}
    };
    actions.append(edit,remove);row.append(names,actions);$('entries').append(row);
  }
}
$('entry-form').onsubmit=async event=>{
  event.preventDefault();busy(true);status('読みを自動確認しています…');
  try {await request('/api/entries','POST',input());await load();status('登録しました。次に生成する音声から反映されます。');}
  catch(e){status(e.message);}finally{busy(false);}
};
$('preview').onclick=async()=>{
  if (!$('entry-form').reportValidity()) return;
  busy(true);status('試聴音声を用意しています…');
  try {const blob=await (await request('/api/preview','POST',input())).blob();if(audioURL) URL.revokeObjectURL(audioURL);audioURL=URL.createObjectURL(blob);$('audio').src=audioURL;$('audio').hidden=false;await $('audio').play();status('入力したよみを試聴しています。');}
  catch(e){status(e.message);}finally{busy(false);}
};
$('search').oninput=render;
load().catch(e=>status(e.message));
