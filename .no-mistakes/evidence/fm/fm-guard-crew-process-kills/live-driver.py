import os,sys,subprocess,json,pathlib,time
root=pathlib.Path.cwd(); check=str(root/'bin/fm-signal-pretool-check.sh')
def guard(command, expected):
 r=subprocess.run([check,'--claude','--scope','isolated-live-signal','--command',command],text=True,capture_output=True)
 print(json.dumps({'command':command,'exit':r.returncode,'response':r.stderr.strip()}),flush=True)
 assert r.returncode==expected
 return r.returncode
if len(sys.argv)==1:
 decoy=subprocess.Popen(['sleep','120'])
 try:
  env=dict(os.environ,FM_PROC_SCOPE='isolated-live-signal')
  subprocess.run([sys.executable,__file__,str(decoy.pid)],env=env,check=True)
  assert decoy.poll() is None
  print('OUTSIDE_PROCESS_SURVIVED',flush=True)
 finally:
  decoy.terminate();decoy.wait()
else:
 own=subprocess.Popen(['sleep','120'])
 try:
  guard(f'kill {own.pid}',0)
  subprocess.run(['bash','-c',f'kill {own.pid}'],check=True)
  assert own.wait(timeout=3)==-15
  print('OWN_PROCESS_STOPPED',flush=True)
 finally:
  if own.poll() is None: own.terminate();own.wait()
 guard('ps -eo pid,ppid,cmd | grep "isolated-live-pattern" | grep -v grep | grep python3 | awk \'{print $1, $2}\' | while read p pp; do kill $pp $p; done',2)
 guard('kill '+sys.argv[1],2)
 guard('kill '+str(os.getpid()),2)
 guard('kill $PPID',2)
 guard('pkill -f isolated-live-pattern',2)
 pidfile=root/'.test-signal-tmp/orphan.pid'
 subprocess.run(['bash','-c',f'sleep 120 >/dev/null 2>&1 & echo $! > {pidfile}'],check=True)
 pid=int(pidfile.read_text())
 try:
  guard(f'kill "$(cat {pidfile})"',0)
  subprocess.run(['bash','-c',f'kill "$(cat {pidfile})"'],check=True)
  for _ in range(30):
   status=pathlib.Path(f'/proc/{pid}/status')
   if not status.exists() or 'State:\tZ' in status.read_text(): break
   time.sleep(.1)
  else: raise AssertionError('orphan still running')
  print('MARKED_ORPHAN_STOPPED',flush=True)
 finally:
  try: os.kill(pid,15)
  except ProcessLookupError: pass
 for command in ['sleep 30 & REPLY=$!; read <<< "$PPID"; kill "$REPLY"','sleep 30 & MAPFILE=$!; mapfile <<< "$PPID"; kill "$MAPFILE"','sleep 30 & MAPFILE=$!; readarray <<< "$PPID"; kill "$MAPFILE"','sleep 12345 & kill $(jobs -l)','sleep 12345 & kill $(jobs)']:
  guard(command,2)
 for command in ['sleep 30 & kill $(jobs -p)','sleep 30 & kill $(jobs -pr)','sleep 30 & kill $(jobs -p -s)','echo ORDINARY_RAN','kill -0 '+sys.argv[1]]:
  guard(command,0)
 guard('malformed " kill',2)
 r=subprocess.run([check,'--claude'],input='malformed kill 123',text=True,capture_output=True)
 print(json.dumps({'payload':'malformed kill 123','exit':r.returncode,'response':r.stderr.strip()}),flush=True)
 assert r.returncode==2 and 'signal-unverifiable' in r.stderr
