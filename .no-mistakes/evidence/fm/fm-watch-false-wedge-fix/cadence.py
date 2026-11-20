import pathlib,subprocess as s,os,time,re,json
root=pathlib.Path.cwd();base=root/'.test-phase/live'; evidence=pathlib.Path('/home/fungiman/.no-mistakes/evidence/01M7TXNZGNH1HJG06BF82ZYK9Y/cadence.json'); results=[]
env=os.environ.copy();env.update(PATH=str(root/'.test-phase/bin')+':'+env['PATH'],FM_TEST_SOCKET=str(base/'tmux.sock'),TMPDIR=str(root/'.test-phase/tmp'))
s.run(['tmux','-f','/dev/null','new-session','-d','-s','live','-n','worker','-x','100','-y','30','sleep 600'],env=env,check=True)
def efor(name):
 e=env.copy();e.update(FM_HOME=str(base/name),FM_STATE_OVERRIDE=str(base/name/'state'),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_BUSY_TURN_MAX_SECS='3600',FM_STALE_ESCALATE_SECS='2',FM_PAUSE_RESURFACE_SECS='3600');return e
def ack(e):
 p=s.run([str(root/'bin/fm-wake-drain.sh')],env=e,capture_output=True,text=True);m=re.search(r'--ack-through (\d+) --recovery-generation ([\w.-]+)',p.stderr)
 assert m,p.stderr
 s.run([str(root/'bin/fm-wake-drain.sh'),'--ack-through',m[1],'--recovery-generation',m[2]],env=e,check=True,capture_output=True)
def watch(name,expect):
 e=efor(name);cf=base/name/'state/.count-live_worker'; start=int(cf.read_text());p=s.Popen([str(root/'bin/fm-watch.sh')],env=e,stdout=s.PIPE,stderr=s.PIPE,text=True);deadline=time.time()+45
 while p.poll() is None and time.time()<deadline:
  if not expect and cf.exists() and int(cf.read_text().strip() or '0')>=start+4:break
  time.sleep(.2)
 exited=p.poll() is not None
 if not exited:p.terminate()
 out,err=p.communicate(timeout=10);r=dict(case=name,expect_wake=expect,exited=exited,stdout=out,stderr=err);results.append(r);evidence.write_text(json.dumps(results,indent=2));assert exited==expect,r;return out
try:
 ack(efor('afk'));assert watch('afk',False)==''
 ack(efor('paused'))
 st=base/'paused/state';p=st/'task.status';t=time.time()-7200;os.utime(p,(t,t));(st/'.seen-task_status').write_text(f'{p.stat().st_size}:{int(p.stat().st_mtime)}')
 out=watch('paused',True);assert 'possible wedge' not in out and 'stale: live:worker' in out
 ack(efor('paused'));assert watch('paused',False)==''
 ack(efor('paused'))
 p.write_text('working: resumed\n');(st/'.seen-task_status').write_text(f'{p.stat().st_size}:{int(p.stat().st_mtime)}')
 out=watch('paused',True);assert 'possible wedge' in out
 print(json.dumps(results,indent=2))
finally:s.run(['tmux','kill-server'],env=env)
