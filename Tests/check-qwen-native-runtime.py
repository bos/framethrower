#!/usr/bin/env python3
"""Official installed Qwen CLI against fake HTTP+MCP peers; never a real model.

Usage: python3 Tests/check-qwen-native-runtime.py --cli /absolute/path/to/qwen
Checks real registration, native tool execution, transcript persistence/resume
and provider configuration without an app, GPU, media, or private project.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib
import json
from pathlib import Path
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Tools'))
qwen = importlib.import_module('DirectorAgents.qwen')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True)
    args = parser.parse_args()
    requests = []
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            assert self.path == '/v1/chat/completions'
            assert self.headers['Authorization'] == 'Bearer synthetic-local-token'
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            if len(requests) == 1:
                delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'native-call-1', 'type': 'function',
                    'function': {'name': 'mcp__framethrower__inspect_editor', 'arguments': '{}'}}]}
                reason = 'tool_calls'
            else:
                delta = {'role': 'assistant', 'content': 'Native answer cobalt.'}
                reason = 'stop'
            for value in [
                {'id': 'synthetic', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                {'id': 'synthetic', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': reason}],
                 'usage': {'prompt_tokens': 100, 'completion_tokens': 5, 'total_tokens': 105}}]:
                self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode()); self.wfile.flush()
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory() as directory:
            cwd = Path(directory)
            proxy = cwd / 'synthetic-mcp.py'
            proxy.write_text('''import json,sys
from pathlib import Path
for line in sys.stdin:
 request=json.loads(line); method=request.get('method'); identity=request.get('id')
 if identity is None:continue
 if method=='initialize':result={'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'synthetic','version':'1'}}
 elif method=='tools/list':result={'tools':[{'name':name,'description':'Synthetic tool','inputSchema':{'type':'object','properties':{}}} for name in ''' + repr(qwen.TOOLS) + ''']}
 elif method=='tools/call':
  assert Path('bound').is_file()
  Path('actual-call.json').write_text(json.dumps(request))
  result={'content':[{'type':'text','text':'ACTUAL-SYNTHETIC-EDITOR-RESULT'}]}
 else:result={}
 print(json.dumps({'jsonrpc':'2.0','id':identity,'result':result}),flush=True)
''')
            config = {'cli': args.cli, 'cwd': directory, 'mcp_proxy': str(proxy), 'mcp_socket': '/tmp/synthetic-unused.sock',
                'document_id': 'synthetic-only', 'model': 'framethrower-local', 'base_url': f'http://127.0.0.1:{server.server_port}/v1',
                'local_token': 'synthetic-local-token', 'context_window_size': 32768, 'timeout_seconds': 45,
                'on_session_id': lambda native: (cwd / 'bound').write_text(native)}
            first = qwen.run_turn({'text': 'FIRST-TURN-COBALT. Inspect the editor.', 'bootstrap_context': {'title': 'BOOTSTRAP-ONCE'}}, config)
            assert 'error' not in first, first
            assert first['text'] == 'Native answer cobalt.', first
            native = first['native_session_id']
            assert (cwd / 'bound').read_text() == native
            call = json.loads((cwd / 'actual-call.json').read_text())
            assert call['params']['name'] == 'inspect_editor'
            init = next(event for event in first['events'] if event.get('subtype') == 'init')
            allowed = {'mcp__framethrower__' + name for name in qwen.TOOLS}
            assert set(init['tools']) == allowed, init['tools']
            assert init['qwen_code_version'] == qwen.CLI_VERSION
            assert any('ACTUAL-SYNTHETIC-EDITOR-RESULT' in json.dumps(event) for event in first['events'])
            assert len(requests) == 2, len(requests)
            for request in requests:
                assert {tool['function']['name'] for tool in request['tools']} == allowed
                assert request['chat_template_kwargs']['enable_thinking'] is False
                assert 1 < request['max_tokens'] <= 4096, (request['max_tokens'], len(json.dumps(request)), [(m['role'],len(str(m.get('content')))) for m in request['messages']])
            config['native_session_id'] = native
            second = qwen.run_turn({'text': 'SECOND-TURN. What synthetic word did I give you?',
                                   'bootstrap_context': {'title': 'MUST-NOT-REPLAY'}}, config)
            assert 'error' not in second, second
            assert second['native_session_id'] == native
            assert len(requests) == 3, len(requests)
            resumed = json.dumps(requests[-1]['messages'])
            assert 'FIRST-TURN-COBALT' in resumed and 'Native answer cobalt.' in resumed
            assert 'ACTUAL-SYNTHETIC-EDITOR-RESULT' in resumed
            assert 'SECOND-TURN' in resumed and 'MUST-NOT-REPLAY' not in resumed
            print('Qwen native offline runtime passed: official0.27.0, exact8 MCPtools, actual tool result, early binding, native transcript resume, thinkingoff and useful output budget; no real inference/media.')
    finally:
        server.shutdown(); server.server_close()

if __name__ == '__main__': main()
