import pathlib,os,subprocess as sp,json
r=pathlib.Path.cwd(); h=r/'.phase-test/teardown-live'; s=h/'state'; s.mkdir(parents=True)
for n in ['data','config','projects']: (h/n).mkdir()
e=os.environ.copy(); e.update(HOME=str(r/'.phase-test/home'),FM_HOME=str(h),FM_ROOT_OVERRIDE=str(r),FM_STATE_OVERRIDE=str(s),FM_DATA_OVERRIDE=str(h/'data'),FM_CONFIG_OVERRIDE=str(h/'config'),TMPDIR=str(r/'.phase-test/tmp'),FM_GATE_REFUSE_BYPASS='1',TMUX=str(r/'s')+',0,0')
def tm(*a): return sp.run(['tmux','-S',str(r/'s'),*a],env=e,text=True,capture_output=True,check=True)
tm('-f','/dev/null','new-session','-d','-s','isolated','-n','fm-cleanup','-x','100','-y','30','sleep 100')
try:
 (s/'cleanup.meta').write_text(f'window=isolated:fm-cleanup\nkind=ship\nharness=claude\nbackend=tmux\nproject={h}/projects/disposable\nworktree={h}/already-returned\ndelivery_mode=local-only\nlocal_landed_at=2026-11-19T00:00:00Z\n')
 for n in ['turn-ended','turn-progress']: (s/('cleanup.'+n)).touch()
 p=sp.run([str(r/'bin/fm-teardown.sh'),'cleanup'],env=e,text=True,capture_output=True,timeout=60)
 print(p.stdout+p.stderr,flush=True); print(json.dumps({'exit':p.returncode,'turn_ended_exists':(s/'cleanup.turn-ended').exists(),'turn_progress_exists':(s/'cleanup.turn-progress').exists(),'meta_exists':(s/'cleanup.meta').exists()}),flush=True)
 assert p.returncode==0
 assert not (s/'cleanup.turn-progress').exists()
finally:
 sp.run(['tmux','-S',str(r/'s'),'kill-server'],env=e,capture_output=True)
