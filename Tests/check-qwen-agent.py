#!/usr/bin/env python3
"""Offline native adapter checks. No actual model, GPU, app or media."""
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Tools'))
qwen = importlib.import_module('DirectorAgents.qwen')

FAKE = r'''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
args=sys.argv[1:]
native=args[args.index('--resume' if '--resume' in args else '--session-id')+1]
Path('captured.json').write_text(json.dumps({'args':args,'env':dict(os.environ),'prompt':sys.stdin.read()}))
assert Path('bound').read_text()==native
mode=Path('mode').read_text() if Path('mode').exists() else 'ok'
tools=json.loads(args[args.index('--mcp-config')+1])['mcpServers']['framethrower']['includeTools']
print(json.dumps({'type':'system','subtype':'init','session_id':native,'qwen_code_version':'0.0.0' if mode=='version' else '0.27.0','tools':['mcp__framethrower__'+tool for tool in tools]}),flush=True)
if mode=='hang': time.sleep(20)
if mode=='wrong_id': native='00000000-0000-0000-0000-000000000000'
if mode=='tool':
 print(json.dumps({'type':'assistant','session_id':native,'message':{'content':[{'type':'tool_use','name':'run_shell_command'}]}}),flush=True)
elif mode=='partial': sys.exit(2)
elif mode=='malformed': print('invalid json',flush=True)
else:
 print(json.dumps({'type':'assistant','session_id':native,'message':{'content':[{'type':'tool_use','name':'mcp__framethrower__inspect_editor','id':'call-1','input':{}}]}}),flush=True)
 print(json.dumps({'type':'user','session_id':native,'message':{'content':[{'type':'tool_result','tool_use_id':'call-1','content':'actual result'}]}}),flush=True)
 print(json.dumps({'type':'result','subtype':'success','is_error':False,'session_id':native,'result':'Completed.','usage':{'input_tokens':42,'cache_read_input_tokens':20}}),flush=True)
 if mode=='result_hang': time.sleep(20)
'''

class Checks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.directory=Path(self.temp.name)
        self.cli=self.directory/'cli'; self.cli.write_text(FAKE); self.cli.chmod(0o700)
        self.proxy=self.directory/'proxy.py'; self.proxy.write_text('# fake MCP path')
        self.configuration={'cli':str(self.cli),'mcp_proxy':str(self.proxy),'cwd':str(self.directory),
            'mcp_socket':'/tmp/fake.sock','document_id':'document-A','model':'framethrower-local',
            'base_url':'http://127.0.0.1:12345/v1','local_token':'private-token','context_window_size':32768,
            'on_session_id':lambda identity:(self.directory/'bound').write_text(identity)}
    def tearDown(self): self.temp.cleanup()
    def run_turn(self, text='Inspect the current editor.', **extra):
        return qwen.run_turn({'text':text, **extra},self.configuration)
    def test_isolation_and_native_events(self):
        result=self.run_turn(editor_events=[{'actor':'manual','action':'Undo'}],bootstrap_context={'title':'synthetic'})
        self.assertNotIn('error',result); self.assertEqual(result['text'],'Completed.')
        self.assertEqual(result['usage']['cache_read_input_tokens'],20)
        self.assertEqual(result['events'][2]['message']['content'][0]['content'],'actual result')
        captured=json.loads((self.directory/'captured.json').read_text()); args=captured['args']
        self.assertIn('--safe-mode',args); self.assertIn('--chat-recording=true',args)
        self.assertEqual(args[args.index('--system-prompt')+1],qwen.INSTRUCTIONS)
        self.assertNotIn('private-token',json.dumps(args)); self.assertIn('run_shell_command',args)
        self.assertTrue(set(qwen.EXCLUDED_TOOLS).issubset(args))
        mcp=json.loads(args[args.index('--mcp-config')+1])['mcpServers']['framethrower']
        self.assertEqual(mcp['includeTools'],list(qwen.TOOLS)); self.assertEqual(mcp['args'][-2:],['--document-id','document-A'])
        settings=json.loads((self.directory/'qwen-home/settings.json').read_text())
        self.assertIs(settings['general']['enableAutoUpdate'],False)
        generation=settings['modelProviders']['openai'][0]['generationConfig']
        self.assertEqual(generation['contextWindowSize'],32768)
        self.assertIs(generation['extra_body']['chat_template_kwargs']['enable_thinking'],False)
        self.assertIn('bootstrap_context',captured['prompt'])
    def test_reasoning_on_is_explicit_native_toggle(self):
        self.configuration['effort']='on'
        result=self.run_turn(); self.assertNotIn('error',result)
        settings=json.loads((self.directory/'qwen-home/settings.json').read_text())
        self.assertNotIn('reasoningEffort',settings['model'])
        self.assertIs(settings['modelProviders']['openai'][0]['generationConfig']['extra_body']['chat_template_kwargs']['enable_thinking'],True)
        self.assertNotIn('--reasoning-effort',json.loads((self.directory/'captured.json').read_text())['args'])
    def test_reasoning_tiers_refused_before_cli(self):
        self.configuration['effort']='medium'
        self.assertIn('error',self.run_turn())
        self.assertFalse((self.directory/'captured.json').exists())
    def test_resume_only_new_turn(self):
        first=self.run_turn('FIRST-SECRET',bootstrap_context={'old':'BOOTSTRAP'})
        self.configuration['native_session_id']=first['native_session_id']
        second=self.run_turn('NEW-TURN',editor_events=[{'actual':2}],bootstrap_context={'old':'BOOTSTRAP'})
        self.assertNotIn('error',second); self.assertEqual(first['native_session_id'],second['native_session_id'])
        captured=json.loads((self.directory/'captured.json').read_text())
        self.assertIn('--resume',captured['args']); self.assertNotIn('FIRST-SECRET',captured['prompt'])
        self.assertNotIn('BOOTSTRAP',captured['prompt']); self.assertIn('NEW-TURN',captured['prompt'])
    def test_failure_retains_identity_events(self):
        for mode in ('partial','wrong_id','malformed','tool','version'):
            (self.directory/'mode').write_text(mode)
            result=self.run_turn(); self.assertIn('error',result,mode)
            self.assertEqual(result['native_session_id'],(self.directory/'bound').read_text())
            self.assertGreaterEqual(len(result['events']),1)
    def test_deadline(self):
        (self.directory/'mode').write_text('hang'); self.configuration['timeout_seconds']=.6
        start=time.monotonic(); result=self.run_turn()
        self.assertIn('error',result); self.assertLess(time.monotonic()-start,2)
        self.assertEqual(len(result['events']),1)
    def test_result_does_not_bypass_exit_deadline(self):
        (self.directory/"mode").write_text("result_hang"); self.configuration["timeout_seconds"]=.6
        start=time.monotonic(); result=self.run_turn()
        self.assertIn("error",result); self.assertLess(time.monotonic()-start,2)
        self.assertEqual(result["text"],"Completed.")
        self.assertEqual(result["events"][-1]["type"],"result")
    def test_config_refusals_before_child(self):
        for value in ('https://example.com/v1','http://localhost:123/v1','http://127.0.0.1:123/v1?x=y'):
            self.configuration['base_url']=value
            result=self.run_turn(); self.assertIn('error',result)
            self.assertIsNone(result['native_session_id'])
            self.assertFalse((self.directory/'captured.json').exists())
    def test_callback_failure_prevents_child(self):
        def fail(_): raise RuntimeError('binding failed')
        self.configuration['on_session_id']=fail
        self.assertIn('error',self.run_turn()); self.assertFalse((self.directory/'captured.json').exists())
    def test_callback_error_redacts_endpoint_token(self):
        def fail(_): raise RuntimeError("private-token")
        self.configuration["on_session_id"]=fail
        result=self.run_turn(); self.assertIn("error",result)
        self.assertNotIn("private-token",json.dumps(result))
    def test_configuration_symlink_refusal(self):
        external=self.directory/"external"; external.mkdir()
        (self.directory/"qwen-home").symlink_to(external, target_is_directory=True)
        result=self.run_turn(); self.assertIn("error",result)
        self.assertEqual(list(external.iterdir()),[])
        self.assertFalse((self.directory/"captured.json").exists())
    def test_reject_history_reconstruction(self):
        self.assertIn('error',self.run_turn(messages=[{'role':'user','content':'old'}]))
        self.assertFalse((self.directory/'captured.json').exists())

if __name__=='__main__': unittest.main()
