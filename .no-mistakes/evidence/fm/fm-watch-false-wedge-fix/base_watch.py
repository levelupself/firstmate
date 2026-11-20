import os, pathlib, subprocess as sp, time, json, signal
root=pathlib.Path.cwd(); scratch=root/'.phase-test'; ev=pathlib.Path('/home/fungiman/.no-mistakes/evidence/01M7TXNZGNH1HJG06BF82ZYK9Y'); sock=str(root/'s')
env=os.environ.copy(); env.update(HOME=str(scratch/'home'),TMPDIR=str(scratch/'tmp'),TMUX=sock+',0,0',FM_GATE_REFUSE_BYPASS='1')
def run(args, **kw): return sp.run(list(map(str,args)),env=env,text=True,capture_output=True,check=True,**kw).stdout.strip()
def tm(*args): return run(['tmux','-S',sock,*args])
results=[]
def put(p, s='', age=0):
 p.write_text(s)
 if age: os.utime(p,(time.time()-age,)*2)
def check(name,status='working: waiting on process',te='old',prog='fresh',pauseage=600,afk=False,ticking=False,expect='quiet',resume=False):
 home=scratch/('base-'+name); state=home/'state'; state.mkdir(parents=True); (home/'data').mkdir(); (home/'config').mkdir(); (home/'projects').mkdir()
 id='sample'; win='isolated:fm-sample'; key='isolated_fm-sample'
 tm('send-keys','-t',win,'C-c'); tm('send-keys','-t',win,"while :; do "+("printf 'foreground wait %s\\n' \"$(date +%s)\"; " if ticking else '')+"sleep 1; done",'Enter')
 put(state/(id+'.meta'),f'window={win}\nkind=ship\nharness=claude\nbackend=tmux\n',7200)
 gen=run([root/'bin/fm-busy-event.sh','arm',state,id]); run([root/'bin/fm-busy-event.sh','apply',state,id,'busy','--gen',gen,'--source','claude-hook','--event','user-prompt-submit'])
 put(state/(id+'.status'),status+'\n',pauseage)
 if te!='none': put(state/(id+'.turn-ended'),age=7200 if te=='old' else 0)
 if prog!='none': put(state/(id+'.turn-progress'),age=7200 if prog=='old' else 0)
 for p in [state/(id+'.status'),state/(id+'.turn-ended')]:
  if p.exists(): put(state/('.seen-'+p.name.replace('.','_')),f'{p.stat().st_size}:{int(p.stat().st_mtime)}')
 put(state/('.stale-since-'+key),str(int(time.time())-500)); put(state/('.wedge-escalations-'+key),'2\n')
 for n in ['.last-heartbeat','.last-check']: put(state/n)
 if afk: put(state/'.afk')
 local=env.copy(); local.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home),FM_STATE_OVERRIDE=str(state),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_HEARTBEAT_MAX='999999',FM_BUSY_TURN_MAX_SECS='3600',FM_STALE_ESCALATE_SECS='240',FM_PAUSE_RESURFACE_SECS='3600')
 def start():
  f=open(home/'watch.out','a'); p=sp.Popen([str(root/'.phase-test/base-bin/fm-watch.sh')],env=local,stdout=f,stderr=sp.STDOUT,start_new_session=True); f.close(); return p
 def stop(p):
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=10)
 def output(): return (home/'watch.out').read_text()
 p=start()
 try:
  if expect=='quiet':
   time.sleep(5); assert p.poll() is None,output(); assert not output(),output(); assert (state/('.hash-'+key)).exists(),'pane never scanned'
   assert not (state/('.stale-since-'+key)).exists(),'wedge timer retained'
  else:
   p.wait(timeout=15)
   assert ('possible wedge, escalation 3' in output()) if expect=='wedge' else (output().strip()==f'stale: {win}' if afk else 'declared pause' in output()),output()
  if expect=='pause':
   assert (state/('.paused-'+key)).exists()!=afk,'incorrect normal pause tracking'
   # Acknowledge through the real drain protocol before the next watcher cycle.
   d=sp.run([str(root/'bin/fm-wake-drain.sh')],env=local,text=True,capture_output=True)
   import re
   m=re.search(r'--ack-through (\d+) --recovery-generation ([\w.-]+)',d.stderr); assert m,d.stderr
   sp.run([str(root/'bin/fm-wake-drain.sh'),'--ack-through',m[1],'--recovery-generation',m[2]],env=local,check=True,capture_output=True)
   prior=output(); p=start(); time.sleep(5); assert p.poll() is None,output(); assert output()==prior,'repeated pause wake'
   assert not (state/('.stale-since-'+key)).exists(),'park started wedge'
  if resume:
   put(state/(id+'.status'),'working: wait ended\n'); pth=state/(id+'.status'); put(state/('.seen-'+id+'_status'),f'{pth.stat().st_size}:{int(pth.stat().st_mtime)}')
   time.sleep(3); assert (state/('.stale-since-'+key)).exists(),'working did not restore timer'; assert not (state/('.paused-'+key)).exists(),'park not cleared'
  rec={'scenario':name,'result':'pass','wake':output().strip(),'triage':(state/'.watch-triage.log').read_text() if (state/'.watch-triage.log').exists() else '', 'pane':tm('capture-pane','-p','-t',win,'-S','-5'), 'queue':(state/'.wake-queue').read_text() if (state/'.wake-queue').exists() else '', 'pause_tracking':(state/('.paused-'+key)).exists(),'resurface_tracking':(state/('.paused-resurfaced-'+key)).exists()}
  results.append(rec); print(json.dumps(rec),flush=True)
 finally: stop(p)
try:
 tm('-f','/dev/null','new-session','-d','-s','isolated','-n','fm-sample','-x','100','-y','30','bash --noprofile --norc')
 tm('set-window-option','-t','isolated:fm-sample','automatic-rename','off')
 check('fresh-working')
 raise RuntimeError('baseline unexpectedly passed')
 check('fresh-no-turn',te='none')
 check('fresh-done',status='done: final processing')
 check('newest-turn',te='fresh',prog='old')
 check('hung-call',prog='old',expect='wedge')
 check('missing-progress',prog='none',expect='wedge')
 check('done-without-progress',status='done: final processing',prog='none',expect='wedge')
 check('paused-stable',status='paused: external wait',prog='none',pauseage=4000,expect='pause',resume=True)
 check('held-ticking',status='captain-held: external wait',prog='none',pauseage=4000,expect='pause',ticking=True)
 check('afk-ticking',status='paused: external wait',prog='none',pauseage=4000,expect='pause',ticking=True,afk=True)
 check('recent-pause',status='paused: external wait',prog='none')
finally:
 try: tm('kill-server')
 except Exception: pass
 (ev/'baseline-watch-results.json').write_text(json.dumps(results,indent=2)+'\n')
