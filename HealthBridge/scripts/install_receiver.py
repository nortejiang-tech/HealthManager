#!/usr/bin/env python3
"""Install a reviewed local binary and user LaunchAgent; preserve any existing install."""
import json, os, pathlib, plistlib, shutil, subprocess, sys
binary=pathlib.Path(sys.argv[1]).resolve()
root=pathlib.Path(sys.argv[2]).resolve()
home=pathlib.Path.home();support=home/'Library/Application Support/HealthManagerBridge'
exe=support/'bin/healthbridge';plist=home/'Library/LaunchAgents/com.norte.healthbridge.receiver.plist'
if exe.exists() or plist.exists():raise SystemExit('Existing installation found; review before replacement')
(support/'bin').mkdir(parents=True,exist_ok=True);support.chmod(0o700)
root.mkdir(parents=True,exist_ok=True)
(root/'batches').mkdir(exist_ok=True)
shutil.copy2(binary,exe);exe.chmod(0o700)
plist.parent.mkdir(parents=True,exist_ok=True)
job={'Label':'com.norte.healthbridge.receiver','ProgramArguments':[str(exe),'receive','--root',str(root)],'RunAtLoad':True,'StartInterval':60,'WatchPaths':[str(root/'batches')],'ProcessType':'Background','StandardOutPath':str(support/'receiver.log'),'StandardErrorPath':str(support/'receiver-error.log'),'Umask':0o077}
plist.write_bytes(plistlib.dumps(job));plist.chmod(0o600)
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True)
print(json.dumps({'installed':str(exe),'launchAgent':str(plist),'transportRoot':str(root)}))
