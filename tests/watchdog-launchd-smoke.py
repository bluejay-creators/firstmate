"""Real launchd and loopback notification proof; all identity/secret input is synthetic."""
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

script = Path(sys.argv[1]).resolve()
bridge = Path(sys.argv[2]).resolve()
requests = []

def interrupted(signum, _frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, interrupted)

class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path == '/notify'
        assert payload == {'template': 'watcher-down'}
        assert self.headers['Authorization'] == 'Bearer synthetic-notify-only'
        requests.append(payload)
        self.send_response(204)
        self.end_headers()
    def log_message(self, *_):
        pass

with tempfile.TemporaryDirectory(prefix='fm-watchdog-native-') as raw:
    root = Path(raw).resolve()
    home = root / 'primary & fixture'
    state = home / 'state'
    state.mkdir(parents=True, mode=0o700)
    (state / '.firstmate-pane').write_text('w99:p1\n')
    beat = state / '.last-watcher-beat'
    beat.touch()
    os.utime(beat, (time.time()-600, time.time()-600))
    bins = root / 'bin'
    bins.mkdir()
    (bins / 'herdr').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ['FM_HOME'])
if sys.argv[1:3] == ['agent', 'get']:
 print(json.dumps({'result':{'agent':{'agent':'omp','foreground_cwd':str(home),'pane_id':sys.argv[3]}}}))
elif sys.argv[1:3] == ['pane', 'process-info']:
 print(json.dumps({'result':{'type':'pane_process_info','process_info':{'pane_id':sys.argv[4],'foreground_processes':[{'name':'omp','argv0':'omp'}]}}}))
elif sys.argv[1:3] == ['agent', 'prompt']:
 with (home/'prompts').open('a') as f: f.write('attempt\\n')
else: raise SystemExit(2)
''')
    (bins / 'secret').write_text('#!/bin/sh\nprintf synthetic-notify-only\n')
    (bins / 'herdr').chmod(0o700)
    (bins / 'secret').chmod(0o700)
    (bins / 'fm-notify-phone').symlink_to(bridge)
    env = dict(os.environ, HOME=str(home), FM_HOME=str(home), HERDR_SESSION='watchdog-native-fixture',
               PATH=str(bins)+os.pathsep+os.environ['PATH'])
    for key in ['XDG_CONFIG_HOME','XDG_STATE_HOME','FM_STATE_OVERRIDE','FM_ROOT_OVERRIDE','FM_HOME_OVERRIDE']:
        env.pop(key, None)
    assert shutil.which('secret', path=env['PATH']) == str(bins/'secret')
    assert shutil.which('herdr', path=env['PATH']) == str(bins/'herdr')
    config = home / '.config/firstmate/notify-phone.json'
    config.parent.mkdir(parents=True, mode=0o700)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config.write_text(json.dumps({'endpoint':f'http://127.0.0.1:{server.server_port}/notify',
                                 'secret_store':'keychain','secret_name':'synthetic-watchdog'}))
    config.chmod(0o600)
    plist_bytes = subprocess.run(['bash',str(script),'plist'],env=env,check=True,capture_output=True).stdout
    job = plistlib.loads(plist_bytes)
    assert job['StartInterval'] == 60 and job['RunAtLoad'] is True
    assert job['WorkingDirectory'] == str(home)
    assert job['EnvironmentVariables']['PATH'] == env['PATH']
    assert job['EnvironmentVariables']['FM_HOME'] == str(home)
    assert job['ProgramArguments'] == ['/bin/bash',str(script),'check']
    plist = root / 'watchdog.plist'
    plist.write_bytes(plist_bytes)
    subprocess.run(['plutil','-lint',str(plist)],check=True,capture_output=True)
    domain = f'gui/{os.getuid()}'
    target = domain+'/'+job['Label']
    loaded = False
    try:
        subprocess.run(['launchctl','bootstrap',domain,str(plist)],env=env,check=True,capture_output=True)
        loaded = True
        # Observe the real RunAtLoad job, not a model turn or a fake launchctl.
        deadline = time.monotonic()+20
        episode = state / '.watchdog-episode'
        while time.monotonic() < deadline:
            if (home/'prompts').exists() and not (state/'.watchdog.lock').exists():
                break
            time.sleep(.2)
        else:
            raise AssertionError('native RunAtLoad did not request fixture recovery')
        assert episode.exists() and (home/'prompts').read_text() == 'attempt\n'
        print('PASS: real launchd RunAtLoad requested recovery in an isolated home; no omp/model turn.', flush=True)
        # Move only the fixture episode clock to its five-minute boundary.
        # No live home, watcher, Keychain or device is involved.
        time.sleep(.5)
        fields = episode.read_text().split()
        assert fields[0] == '1' and fields[3] == '0'
        fields[1] = str(int(time.time())-300)
        episode.write_text('\t'.join(fields)+'\n')
        subprocess.run(['bash',str(script),'check'],env=env,check=True,capture_output=True)
        assert requests == [{'template':'watcher-down'}]
        subprocess.run(['bash',str(script),'check'],env=env,check=True,capture_output=True)
        assert len(requests) == 1 and (home/'prompts').read_text() == 'attempt\n'
        print('PASS: actual fm-notify-phone sent exactly one watcher-down-only payload to loopback with a synthetic secret adapter; restart dedup held.', flush=True)
        beat.touch()
        # Leave the real 60-second LaunchAgent scheduled. A new launchd process
        # must observe the heartbeat without any prompt, kickstart or model turn.
        time.sleep(67)
        assert not episode.exists()
        assert (home/'prompts').read_text() == 'attempt\n' and len(requests) == 1
        loaded_info = subprocess.run(['launchctl','print',target],check=True,capture_output=True,text=True).stdout
        assert 'last exit code = 0' in loaded_info
        print('PASS: native scheduled tick observed fresh recovery and cleared the episode after 60 seconds; no duplicate prompt/phone.', flush=True)
    finally:
        if loaded:
            subprocess.run(['launchctl','bootout',target],check=True,capture_output=True)
            absent = subprocess.run(['launchctl','print',target],capture_output=True)
            assert absent.returncode != 0
            print('PASS: only the unique fixture LaunchAgent was unloaded.', flush=True)
        server.shutdown()
        server.server_close()
