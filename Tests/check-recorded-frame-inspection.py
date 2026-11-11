#!/usr/bin/env python3
"""Generated prerecorded graphic -> real Host -> MCP image -> optional Sonnet.

Never queries the desktop, camera or microphone. The Sonnet mode uses only this
isolated fixture/socket/conversation, never an existing user recording/session.
"""
import hashlib, json, os, pathlib, platform, shutil, socket, subprocess, sys, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=ROOT/'FrameThrower/Sources/FrameThrower'
NAMES=['MediaProcessing','EditorRegion','RecordingProject','EditorConflictGeometry','EditorConflictReview','EditorActionDescription','EditorCommand','EditorMutation','EditorAgentControls','LocalEditPlanner','TimelineAnimation','EditorAnimationEditing','EditorSimulationClock','EditorPreviewCommand','CursorRecording','ProjectRenderer','PIPVideoCompositor','EditorPlayback','RecordedScene','DirectorInspection','FrameThrowerMCPServer','EditorAutomationAPI','EditorAutomationHost','DirectorDiagnostics']
PATHS=[SOURCE/(name+'.swift') for name in NAMES]+[ROOT/'Tests/RecordedFrameInspectionChecks.swift']
DIGEST=hashlib.sha256(pathlib.Path(__file__).read_bytes())
for path in PATHS: DIGEST.update(path.read_bytes())
BUILD=ROOT/'build/RecordedFrameInspectionChecks'/DIGEST.hexdigest();BUILD.mkdir(parents=True,exist_ok=True)
BINARY=BUILD/'recorded-frame-check'
if not BINARY.exists():
 subprocess.run(['taskpolicy','-b','swiftc','-whole-module-optimization','-Onone','-num-threads','1','-parse-as-library','-warnings-as-errors','-strict-concurrency=complete','-enable-upcoming-feature','ExistentialAny','-target',platform.machine()+'-apple-macos15.0']+[str(p) for p in PATHS]+['-o',str(BINARY)],check=True)
folder=pathlib.Path(tempfile.mkdtemp(prefix='ft-frame-',dir='/tmp'))
process=None
try:
 env=os.environ.copy();env.pop('FRAMETHROWER_VECTOR_PREVIEW',None)
 subprocess.run(['taskpolicy','-b',shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg','-v','error','-f','lavfi','-i','color=c=navy:s=640x360:d=3:r=10','-c:v','libx264','-threads','1','-pix_fmt','yuv420p',str(folder/'fixture.mov')],env=env,check=True)
 output=open(folder/'harness.log','w')
 process=subprocess.Popen(['taskpolicy','-b',str(BINARY),str(folder),'--serve'],env=env,stdout=output,stderr=subprocess.STDOUT)
 ready_file=folder/'ready.json';deadline=time.monotonic()+60
 while not ready_file.exists():
  if process.poll() is not None:raise RuntimeError((folder/'harness.log').read_text())
  if time.monotonic()>deadline:raise TimeoutError('Recorded fixture startup')
  time.sleep(.05)
 ready=json.loads(ready_file.read_text())
 connection=socket.socket(socket.AF_UNIX);connection.settimeout(30);connection.connect(ready['socket']);stream=connection.makefile('rwb')
 def rpc(ident,method,params):
  stream.write((json.dumps({'jsonrpc':'2.0','id':ident,'method':method,'params':params})+'\n').encode());stream.flush()
  value=json.loads(stream.readline());assert value.get('id')==ident,value;return value['result']
 rpc(1,'initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'fixture','version':'1'}})
 stream.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n');stream.flush()
 response=rpc(2,'tools/call',{'name':'inspect_recording','arguments':{'document_id':ready['document_id'],'detail':'frame'}})
 assert [part['type'] for part in response['content']]==['text','image'],response
 assert response['content'][1]['mimeType']=='image/jpeg'
 assert '_mcp_image' not in response['structuredContent']
 assert 'ORBIT' not in response['content'][0]['text'],'Visible fixture text must not leak through image metadata'
 assert response['structuredContent']['result']['live_desktop'] is False
 assert len(json.dumps(response).encode())<1_048_576
 print('Native MCP image result passed: image content, no duplicated pixels/text or live desktop.')
 stream.close();connection.close()
 if '--sonnet' in sys.argv:
  cwd=folder/'conversation';cwd.mkdir(mode=0o700)
  configuration={'provider':'claude','model':'claude-sonnet-5-5','effort':'low','cwd':str(cwd),'cli':shutil.which('claude'),'mcp_proxy':str(ROOT/'Tools/framethrower-mcp.py'),'mcp_socket':ready['socket'],'document_id':ready['document_id'],'recording_id':ready['recording_id'],'timeout':120}
  def turn(text,events):
   payload={'configuration':configuration,'request':{'text':text,'editor_events':events,'bootstrap_context':{'document_id':ready['document_id'],'recording_name':'Generated prerecorded fixture'}}}
   value=subprocess.run([sys.executable,str(ROOT/'Tools/director-agent-client.py')],input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=150,check=True)
   reply=json.loads(value.stdout);assert reply.get('ok') is True,reply;return reply
  first=turn('For this synthetic test, recorded frame inspection used to be unavailable. Reply READY only; do not call tools yet.',[])
  second=turn('What can you see on the screen here? Inspect the current recorded preview image, then name the large central text and the colored shape. Do not infer them from metadata.',[{'kind':'current_editor','context':{'documentID':ready['document_id'],'recorded_frame_inspection_available':True,'live_capture_suspended':True,'media_processing_suspended':False,'preview':{'outputTime':0,'inspectionTimeBase':'output'}}}])
  calls=[part for event in second.get('events',[]) for part in event.get('message',{}).get('content',[]) if isinstance(part,dict) and part.get('type')=='tool_use']
  assert any(part.get('name')=='mcp__framethrower__inspect_recording' and part.get('input',{}).get('detail')=='frame' for part in calls),calls
  text=second.get('text','').lower()
  assert 'orbit' in text and '42' in text and 'yellow' in text and any(word in text for word in ['circle','oval','ellipse','round']),second.get('text')
  assert first['native_session_id']==second['native_session_id'],'The resumed native conversation must retain its identity'
  print('Real resumed Sonnet native-image test passed:',second['text'])
 (folder/'stop').touch();process.wait(timeout=10);assert process.returncode==0,(folder/'harness.log').read_text()
 print((folder/'harness.log').read_text().strip())
finally:
 if process is not None and process.poll() is None:process.terminate();process.wait(timeout=10)
 if '--keep' in sys.argv:print('Fixture evidence:',folder)
 else:shutil.rmtree(folder)
