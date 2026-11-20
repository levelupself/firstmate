import os, pathlib, subprocess as s, time, json
root=pathlib.Path.cwd(); base=root/'.test-phase/live'; base.mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('/home/fungiman/.no-mistakes/evidence/01M7TXNZGNH1HJG06BF82ZYK9Y')
env=os.environ.copy(); env.update(PATH=str(root/'.test-phase/bin')+':'+env['PATH'],FM_TEST_SOCKET=str(base/'tmux.sock'),TMPDIR=str(root/'.test-phase/tmp'))
def run(*args,**kw): return s.run(args,env=env,text=True,check=True,**kw)
run('tmux','-f','/dev/null','new-session','-d','-s','live','-n','worker','-x','100','-y','30','sleep 600')
results=[]
try:
 for name,status,turn,progress,afk,expect in [('working','working: running','old','fresh',False,False),('no-turn','working: running','none','fresh',False,False),('done','done: complete','old','fresh',False,False),('newest-turn','working: running','fresh','old',False,False),('hung','working: running','old','old',False,True),('missing-marker','done: complete','old','none',False,True),('paused','paused: external wait','old','old',False,False),('held','captain-held: approval','old','old',False,False),('afk','paused: external wait','old','old',True,True)]:
  home=base/name; state=home/'state'; state.mkdir(parents=True); (home/'data').mkdir(); (home/'config').mkdir()
  e=env.copy();e.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(state),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_BUSY_TURN_MAX_SECS='3600',FM_STALE_ESCALATE_SECS='2',FM_PAUSE_RESURFACE_SECS='3600')
  def file(n,content='',age=0,seen=False):
   p=state/n;p.write_text(content); t=time.time()-age;os.utime(p,(t,t))
   if seen: (state/('.seen-'+n.replace('.','_'))).write_text(f'{p.stat().st_size}:{int(p.stat().st_mtime)}')
  file('task.meta','window=live:worker\nkind=ship\nharness=claude\nbackend=tmux\n',7200)
  file('task.status',status+'\n',7200 if afk else 0,True)
  if turn!='none':file('task.turn-ended',age=7200 if turn=='old' else 0,seen=True)
  if progress!='none':file('task.turn-progress',age=7200 if progress=='old' else 0)
  if afk:file('.afk')
  gen=s.check_output([str(root/'bin/fm-busy-event.sh'),'arm',str(state),'task'],env=e,text=True).strip()
  s.run([str(root/'bin/fm-busy-event.sh'),'apply',str(state),'task','busy','--gen',gen,'--source','claude-hook','--event','user-prompt-submit'],env=e,check=True)
  p=s.Popen([str(root/'bin/fm-watch.sh')],env=e,stdout=s.PIPE,stderr=s.PIPE,text=True)
  try:
   deadline=time.time()+45
   while p.poll() is None and time.time()<deadline:
    cf=state/'.count-live_worker'
    if not expect and cf.exists() and int(cf.read_text().strip() or '0')>=4: break
    time.sleep(.2)
   out,err=p.communicate(timeout=1); exited=True
  except s.TimeoutExpired:p.terminate();out,err=p.communicate(timeout=5);exited=False
  triage=(state/'.watch-triage.log').read_text() if (state/'.watch-triage.log').exists() else ''
  polls=(state/'.count-live_worker').read_text().strip() if (state/'.count-live_worker').exists() else '0'
  ok=(exited==expect and (('stale: live:worker' in out and ('possible wedge' not in out if afk else 'possible wedge' in out)) if expect else int(polls)>=2))
  results.append(dict(name=name,pass_=ok,exited=exited,polls=polls,stdout=out,stderr=err,triage=triage))
  (evidence/'live-watcher.json').write_text(json.dumps(results,indent=2));print(name,ok,out.strip(),flush=True)
finally: run('tmux','kill-server')
assert all(r['pass_'] for r in results)
