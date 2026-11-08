#!/usr/bin/env python3
"""Offline adapter contract tests. No real CLI, credentials, models or desktop."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("director_claude_agent", ROOT / "Tools/DirectorAgents/claude.py")
claude = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claude)

FAKE = r'''
import json, os, pathlib, sys
args = sys.argv[1:]
def value(flag): return args[args.index(flag)+1]
cwd = pathlib.Path.cwd()
text = sys.stdin.read()
row = {"args":args,"text":text,"cwd":str(cwd),
       "api_key_present":"ANTHROPIC_API_KEY" in os.environ,
       "auth_token_present":"ANTHROPIC_AUTH_TOKEN" in os.environ}
row['bound_before_start']=(cwd/'bound-session').read_text() if (cwd/'bound-session').exists() else None
with (cwd/'invocations.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')
sid = value('--resume') if '--resume' in args else value('--session-id')
mode = (cwd/'mode').read_text() if (cwd/'mode').exists() else 'success'
def emit(value):
 if mode == 'missing_id': value.pop('session_id',None)
 print(json.dumps(value), flush=True)
if mode == 'nonzero':
 emit({"type":"system","subtype":"init","session_id":sid,"mcp_servers":[{"name":"framethrower","status":"connected"}]})
 print('Fixture failed before result',file=sys.stderr)
 sys.exit(4)
servers = [{"name":"framethrower","status":"failed" if mode == 'mcp_failed' else "connected"}]
if mode == 'extra_mcp': servers.append({"name":"unrelated","status":"connected"})
emit({"type":"system","subtype":"init","session_id":sid,"mcp_servers":servers,"tools":["mcp__framethrower__inspect_editor"]})
emit({"type":"assistant","session_id":sid,"message":{"role":"assistant","content":[{"type":"tool_use","id":"native-call-1","name":"Bash" if mode == 'wrong_tool' else "mcp__framethrower__inspect_editor","input":{"section":"preview"}}]}})
emit({"type":"user","session_id":sid,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"native-call-1","content":"Actual fixture state: playhead9"}]}})
if mode == 'malformed': print('{BROKEN',flush=True)
if mode == 'truncated': sys.exit(0)
if mode == 'bad_shape': emit({"type":"assistant","session_id":sid,"message":None})
if mode == 'wrong_id': sid='11111111-1111-4111-8111-111111111111'
emit({"type":"result","subtype":"error_during_execution" if mode=='turn_failed' else "success","is_error":mode=='turn_failed',"session_id":sid,
      "result":"Applied the camera adjustment." if mode!='turn_failed' else "Could not complete the next action.",
      "usage":{"input_tokens":300,"cache_read_input_tokens":220},"total_cost_usd":0.012,"num_turns":2})
'''


class ClaudeAgentChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.cli = self.directory/'fake-claude'
        self.cli.write_text('#!'+sys.executable+'\n'+FAKE)
        self.cli.chmod(0o700)
        self.proxy = self.directory/'proxy.py'
        self.proxy.write_text('# unused fake MCP proxy\n')
        self.cwd = self.directory/'private-document'
        self.cwd.mkdir(mode=0o700)
        self.configuration = {"cli":str(self.cli),"model":"claude-sonnet-5-5","effort":"medium",
            "cwd":str(self.cwd),"native_session_id":None,"mcp_proxy":str(self.proxy),
            "mcp_socket":str(self.directory/'mcp.sock'),"document_id":"document-opaque-1"}

    def rows(self):
        return [json.loads(line) for line in (self.cwd/'invocations.jsonl').read_text().splitlines()]

    def mode(self, mode): (self.cwd/'mode').write_text(mode)

    def test_native_resume_and_actual_events(self):
        first = claude.run_turn({"text":"Zoom the camera to full screen over two seconds.","bootstrap_context":{"playhead":9}},self.configuration)
        self.assertNotIn('error',first)
        self.assertEqual(first['text'],'Applied the camera adjustment.')
        self.assertEqual(len(first['events']),4)
        self.assertEqual(first['events'][2]['message']['content'][0]['tool_use_id'],'native-call-1')
        self.assertEqual(first['usage']['usage']['cache_read_input_tokens'],220)
        self.configuration['native_session_id']=first['native_session_id']
        second = claude.run_turn({"text":"Yes, the picture in picture.","bootstrap_context":{"must_not_replay":"old state"},
            "editor_events":[{"operation":"manual_seek","time":9}]},self.configuration)
        self.assertNotIn('error',second)
        self.assertEqual(first['native_session_id'],second['native_session_id'])
        rows=self.rows()
        self.assertIn('--session-id',rows[0]['args'])
        self.assertNotIn('--resume',rows[0]['args'])
        self.assertIn('--resume',rows[1]['args'])
        self.assertNotIn('--session-id',rows[1]['args'])
        self.assertEqual(rows[1]['args'][rows[1]['args'].index('--resume')+1],first['native_session_id'])
        self.assertNotIn('Zoom the camera',rows[1]['text'])
        self.assertNotIn('must_not_replay',rows[1]['text'])
        self.assertIn('manual_seek',rows[1]['text'])
        self.assertEqual(rows[0]['cwd'],rows[1]['cwd'])

    def test_session_binding_precedes_process_and_failure_never_executes(self):
        received=[]
        def bind(native_id):
            received.append(native_id)
            (self.cwd/'bound-session').write_text(native_id)
        self.configuration['on_session_id']=bind
        result=claude.run_turn({'text':'Inspect.'},self.configuration)
        self.assertNotIn('error',result)
        self.assertEqual(received,[result['native_session_id']])
        self.assertEqual(self.rows()[0]['bound_before_start'],result['native_session_id'])
        def fail(_): raise OSError('Fixture durable binding failed')
        self.configuration['on_session_id']=fail
        failed=claude.run_turn({'text':'Do not execute without a durable binding.'},self.configuration)
        self.assertEqual(failed['error']['code'],'session_binding')
        self.assertIsNotNone(failed['native_session_id'])
        self.assertEqual(len(self.rows()),1)

    def test_builtin_tools_disabled_native_mcp_and_context_management_retained(self):
        with patch.dict(os.environ,{'ANTHROPIC_API_KEY':'not-a-real-key','ANTHROPIC_AUTH_TOKEN':'not-a-real-token'}):
            result=claude.run_turn({'text':'Inspect the current editor.'},self.configuration)
        self.assertNotIn('error',result)
        row=self.rows()[0]; args=row['args']
        for absent in ('--bare','--safe-mode','--disable-slash-commands','--no-session-persistence','--json-schema','--autocompact','--system-prompt','--fork-session'):
            self.assertNotIn(absent,args)
        self.assertEqual(args[args.index('--tools')+1],'')
        self.assertIn('--strict-mcp-config',args)
        self.assertEqual(args[args.index('--permission-mode')+1],'dontAsk')
        mcp=json.loads(args[args.index('--mcp-config')+1])['mcpServers']
        self.assertEqual(list(mcp),['framethrower'])
        self.assertEqual(mcp['framethrower']['args'],[str(self.proxy),'--socket',self.configuration['mcp_socket'],'--document-id','document-opaque-1'])
        settings=json.loads(args[args.index('--settings')+1])
        self.assertTrue(settings['disableAllHooks'])
        self.assertNotIn('autoCompactEnabled',settings)
        self.assertFalse(row['api_key_present'])
        self.assertFalse(row['auth_token_present'])

    def test_no_application_context_cap_or_history_selection(self):
        text='Original user detail '+('abcdefg '*10_000)
        events=[{'operation':'manual_edit','actual':('123456789 '*10_000)}]
        result=claude.run_turn({'text':text,'editor_events':events},self.configuration)
        self.assertNotIn('error',result)
        sent=self.rows()[0]['text']
        self.assertTrue(sent.startswith(text))
        self.assertIn(events[0]['actual'],sent)
        self.assertGreater(len(sent),180_000)
        self.assertNotIn('omitted',sent)

    def test_native_slash_command_not_rewritten_without_updates(self):
        self.assertNotIn('error',claude.run_turn({'text':'/compact'},self.configuration))
        self.assertEqual(self.rows()[0]['text'],'/compact')

    def test_failure_preserves_native_identity_actual_tool_result_and_text(self):
        self.mode('turn_failed')
        result=claude.run_turn({'text':'Make the adjustment.'},self.configuration)
        self.assertEqual(result['error']['code'],'native_turn_failed')
        self.assertIsNotNone(result['native_session_id'])
        self.assertEqual(len(result['events']),4)
        self.assertEqual(result['events'][2]['message']['content'][0]['content'],'Actual fixture state: playhead9')
        self.assertEqual(result['text'],'Could not complete the next action.')
        self.assertEqual(len(self.rows()),1)

    def test_truncated_or_invalid_stream_never_restarts_conversation(self):
        for mode in ('truncated','malformed','bad_shape','wrong_id','missing_id','wrong_tool','mcp_failed','extra_mcp','nonzero'):
            with self.subTest(mode=mode):
                self.mode(mode)
                before=len(self.rows()) if (self.cwd/'invocations.jsonl').exists() else 0
                result=claude.run_turn({'text':'Inspect the editor.'},self.configuration)
                self.assertIn('error',result)
                self.assertIsNotNone(result['native_session_id'])
                self.assertGreaterEqual(len(result['events']),1)
                self.assertEqual(len(self.rows()),before+1)

    def test_missing_resumable_session_does_not_fall_back(self):
        self.configuration['native_session_id']='not-a-session'
        result=claude.run_turn({'text':'Continue.'},self.configuration)
        self.assertEqual(result['error']['code'],'configuration')
        self.assertEqual(result['native_session_id'],'not-a-session')
        self.assertFalse((self.cwd/'invocations.jsonl').exists())

    def test_invalid_configuration_or_data_no_child(self):
        bindings=[]
        configuration={**self.configuration,'on_session_id':bindings.append}
        for config,request in [({**configuration,'cli':'relative/path'},{'text':'Hello'}),
            ({**configuration,'model':None},{'text':'Hello'}),
            ({**configuration,'model':'invalid\0model'},{'text':'Hello'}),
            ({**configuration,'mcp_proxy':str(self.directory/'missing.py')},{'text':'Hello'}),
            ({**configuration,'on_session_id':42},{'text':'Hello'}),
            (configuration,{'text':'Hello','editor_events':[None]}),
            (configuration,{'text':'Hello','bootstrap_context':{'bad':float('nan')}}),
            (configuration,{'text':'Hello','messages':[{'role':'user','content':'old history'}]}),
            (configuration,{'text':'Hello','document_id':'broker-must-strip-this'})]:
            with self.subTest(request=request):
                result=claude.run_turn(request,config)
                self.assertIn('error',result)
                self.assertIsNone(result['native_session_id'])
                self.assertEqual(bindings,[])
                self.assertFalse((self.cwd/'invocations.jsonl').exists())


if __name__=='__main__': unittest.main()
