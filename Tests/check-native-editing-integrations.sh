#!/bin/sh
# One cached compile for the Director, domain/MCP, and optional live fixture.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec taskpolicy -b python3 - "$repo_dir" "$@" <<'PY'
import ast, hashlib, pathlib, platform, subprocess, sys
root = pathlib.Path(sys.argv[1]); source = root/'FrameThrower/Sources/FrameThrower'
base = root/'Tests/check-director-integrations.sh'
tree = ast.parse(base.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0])
values = {node.targets[0].id: ast.literal_eval(node.value) for node in tree.body
          if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
          and node.targets[0].id in ('production', 'suites')}
production = list(dict.fromkeys(values['production'] + [
    'TimelineAnimation','EditorAnimationEditing','EditorSimulationClock','CursorRecording',
    'ProjectRenderer','PIPVideoCompositor','EditorPlayback','FrameThrowerMCPServer','EditorAutomationHost']))
suites = values['suites'] + ['EditorAutomationChecks','NativeAutomationConflictChecks','EditorComponentInspectionChecks']
live = 'NativeDirectorLiveChecks'
paths = [source/(name+'.swift') for name in production] + [root/'Tests'/(name+'.swift') for name in suites+[live]]
fingerprint = hashlib.sha256(pathlib.Path(__file__).read_bytes()) if '__file__' in globals() and pathlib.Path(__file__).is_file() else hashlib.sha256((root/'Tests/check-native-editing-integrations.sh').read_bytes())
fingerprint.update(base.read_bytes())
for path in paths: fingerprint.update(path.read_bytes())
folder = root/'build/NativeEditingIntegrationChecks'/fingerprint.hexdigest(); folder.mkdir(parents=True,exist_ok=True)
binary = folder/'check-native-editing-integrations'
if not binary.exists():
    tests=[]
    for name in suites+[live]:
        text=(root/'Tests'/(name+'.swift')).read_text(); assert text.count('@main')==1,name
        path=folder/(name+'.swift'); path.write_text(text.replace('@main','',1)); tests.append(path)
    calls='\n'.join('if selected.isEmpty || selected.contains("'+name+'") { try '+
        ('' if name=='EditorAutomationPlannerChecks' else 'await ')+name+
        ('.run()' if name=='DirectorInspectionSessionChecks' else '.main()')+' }' for name in suites)
    entry=folder/'IntegrationMain.swift'
    entry.write_text('import Foundation\nimport Darwin\n@main @MainActor struct NativeEditingMain { static func main() async { let selected=Set(CommandLine.arguments.dropFirst()); do {\n'+
        'if selected.contains("'+live+'") { await '+live+'.main(); return }\n'+calls+
        '\n} catch { FileHandle.standardError.write(Data("Native editing integration failed: \\(error)\\n".utf8)); exit(1) } } }\n')
    flags=['-whole-module-optimization','-Onone','-num-threads','1','-parse-as-library','-warnings-as-errors',
        '-strict-concurrency=complete','-enable-upcoming-feature','ExistentialAny','-target',platform.machine()+'-apple-macos15.0']
    subprocess.run(['swiftc']+flags+[str(p) for p in paths[:len(production)]]+[str(p) for p in tests]+[str(entry),'-o',str(binary)],check=True)
subprocess.run([str(binary)]+sys.argv[2:],check=True)
PY
