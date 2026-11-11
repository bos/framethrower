#!/usr/bin/env python3
"""Generated prerecorded graphic -> real Host -> MCP image -> optional Sonnet.

Never queries the desktop, camera or microphone. The Sonnet mode uses only this
isolated fixture/socket/conversation, never an existing user recording/session.
"""
import hashlib, importlib.util, json, os, pathlib, platform, shutil, socket, subprocess, sys, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=ROOT/'FrameThrower/Sources/FrameThrower'
NAMES=['MediaProcessing','EditorRegion','RecordingProject','EditorConflictGeometry','EditorConflictReview','EditorActionDescription','EditorCommand','EditorMutation','EditorAgentControls','LocalEditPlanner','TimelineAnimation','EditorAnimationEditing','EditorSimulationClock','EditorPreviewCommand','CursorRecording','ProjectRenderer','PIPVideoCompositor','EditorPlayback','RecordedScene','DirectorInspection','FrameThrowerMCPServer','EditorAutomationAPI','EditorAutomationHost','DirectorDiagnostics']
PATHS=[SOURCE/(name+'.swift') for name in NAMES]+[ROOT/'Tests/RecordedFrameInspectionChecks.swift']
FLAGS=['-whole-module-optimization', '-Onone', '-num-threads', '1', '-parse-as-library', '-warnings-as-errors', '-strict-concurrency=complete', '-enable-upcoming-feature', 'ExistentialAny', '-target', platform.machine()+'-apple-macos15.0']
# Workflow-only changes do not invalidate compiled production/fixture code.
DIGEST=hashlib.sha256(json.dumps(FLAGS,separators=(',',':')).encode())
for path in PATHS: DIGEST.update(path.read_bytes())
BUILD=ROOT/'build/RecordedFrameInspectionChecks'/DIGEST.hexdigest();BUILD.mkdir(parents=True,exist_ok=True)
BINARY=BUILD/'recorded-frame-check'
if not BINARY.exists():
 subprocess.run(['taskpolicy','-b','swiftc']+FLAGS+[str(p) for p in PATHS]+['-o',str(BINARY)],check=True)
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
  # Model-visible legacy schemas baked a transient endpoint into an enum.
  # Load that exact historical behavior from an isolated copy, never alter the
  # installed/current proxy, then migrate this same native session on reopen.
  legacy_proxy=folder/'legacy-proxy.py'
  current_proxy=ROOT/'Tools/framethrower-mcp.py'
  legacy_source=current_proxy.read_text()
  assert 'field.pop("enum", None)' in legacy_source,'Expected current migration fix'
  legacy_proxy.write_text(legacy_source.replace('field.pop("enum", None)', 'field["enum"] = [self.document_id]',1))
  spec=importlib.util.spec_from_file_location('legacy_frame_proxy_fixture',legacy_proxy)
  legacy=importlib.util.module_from_spec(spec);spec.loader.exec_module(legacy)
  old_scope=legacy.DocumentScope(ready['document_id'])
  old_scope.client(b'{"jsonrpc":"2.0","id":9,"method":"tools/list"}\n')
  old_catalog=json.loads(old_scope.server(b'{"jsonrpc":"2.0","id":9,"result":{"tools":[{"name":"inspect_recording","inputSchema":{"properties":{"document_id":{"type":"string"}}}}]}}\n'))
  cached_field=old_catalog['result']['tools'][0]['inputSchema']['properties']['document_id']
  assert cached_field['enum']==[ready['document_id']]
  configuration={'provider':'claude','model':'claude-sonnet-5-5','effort':'low','cwd':str(cwd),'cli':shutil.which('claude'),'mcp_proxy':str(legacy_proxy),'mcp_socket':ready['socket'],'document_id':ready['document_id'],'recording_id':ready['recording_id'],'timeout':120}
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
  # Close/reopen the actual saved editor endpoint while preserving the file,
  # persistent recording ID and Claude's own native conversation/transcript.
  previous=ready.copy();(folder/'reopen').touch();deadline=time.monotonic()+20
  while not (folder/'reopened.json').exists():
   if time.monotonic()>deadline:raise TimeoutError('Reopen generated editor endpoint')
   time.sleep(.05)
  ready=json.loads((folder/'reopened.json').read_text())
  assert ready['document_id']!=previous['document_id'] and ready['recording_id']==previous['recording_id']
  # Deterministically reproduce why the previous cached enum was unusable:
  # its sole legal value is now rejected by the exact per-recording boundary.
  stale_args={'document_id':cached_field['enum'][0],'detail':'frame'}
  stale_scope=legacy.DocumentScope(ready['document_id'])
  forwarded,rejected=stale_scope.client((json.dumps({'jsonrpc':'2.0','id':10,'method':'tools/call','params':{'name':'inspect_recording','arguments':stale_args}})+'\n').encode())
  assert not forwarded and json.loads(rejected)['error']['code']==-32602
  print('Legacy cached document enum regression reproduced: sole schema value is stale after actual reopen.')
  legacy_proxy.write_text(current_proxy.read_text())
  configuration['document_id']=ready['document_id']
  assert configuration['mcp_proxy']==str(legacy_proxy),'The native MCP argv/path must stay unchanged across upgrade'
  fresh_context={'kind':'current_editor','context':{'documentID':ready['document_id'],'recordingID':ready['recording_id'],'recorded_frame_inspection_available':True,'live_capture_suspended':True,'media_processing_suspended':False,'preview':{'outputTime':0,'inspectionTimeBase':'output'}}}
  third=turn('What can you see on the screen here now? Please inspect it again.',[fresh_context])
  calls=[part for event in third.get('events',[]) for part in event.get('message',{}).get('content',[]) if isinstance(part,dict) and part.get('type')=='tool_use']
  frame_calls=[part for part in calls if part.get('name')=='mcp__framethrower__inspect_recording' and part.get('input',{}).get('detail')=='frame' and part.get('input',{}).get('document_id')==ready['document_id']]
  assert frame_calls,'Resumed Sonnet must target the current editor handle after reopen: '+str(calls)
  call_ids={part['id'] for part in frame_calls}
  results=[part for event in third.get('events',[]) for part in event.get('message',{}).get('content',[]) if isinstance(part,dict) and part.get('type')=='tool_result' and part.get('tool_use_id') in call_ids]
  assert any(not part.get('is_error') and ready['document_id'] in json.dumps(part.get('content')) for part in results),'The new endpoint must actually return a successful recorded frame'
  text=third.get('text','').lower()
  assert 'orbit' in text and '42' in text and 'yellow' in text,third.get('text')
  assert first['native_session_id']==third['native_session_id'],'Reopening must never reset the provider conversation'
  assert not any(word in text for word in ['new session','new conversation','restart the conversation']),third.get('text')
  (folder/'reopen-summary.json').write_text(json.dumps({'old_document_id':previous['document_id'],'new_document_id':ready['document_id'],'recording_id':ready['recording_id'],'native_session_id':third['native_session_id'],'frame_call_ids':sorted(call_ids),'text':third['text']},indent=2))
  print('Real Sonnet old-schema -> new-proxy reopen migration PASSED with same conversation:',third['text'])
 (folder/'stop').touch();process.wait(timeout=10);assert process.returncode==0,(folder/'harness.log').read_text()
 print((folder/'harness.log').read_text().strip())
finally:
 if process is not None and process.poll() is None:process.terminate();process.wait(timeout=10)
 if '--keep' in sys.argv:print('Fixture evidence:',folder)
 else:shutil.rmtree(folder)
