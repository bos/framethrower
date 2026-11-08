#!/bin/sh
# Compile the shared Director module once; reuse it across the integration suites.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec taskpolicy -b python3 - "$repo_dir" "$@" <<'PY'
import hashlib, pathlib, platform, subprocess, sys
root=pathlib.Path(sys.argv[1]); source=root/'FrameThrower/Sources/FrameThrower'
production=['MediaProcessing','EditorConflictGeometry','EditorConflictReview','EditorActionDescription','DirectorTranscript',
 'EditorRegion','RecordingProject','EditorCommand','EditorMutation','EditorPreviewCommand','EditorAutomationAPI','EditorAgentControls','RecordedScene','DirectorInspection','LocalEditPlanner',
 'LocalModelRuntime','LocalSpeechInput','WhisperSpeechRuntime','WhisperSpeechSession','DirectorDiagnostics','DirectorConversation',
 'DirectorModelTransport','EditorAssistantPanel']
suites=['DirectorInspectionSessionChecks','EditorAssistantSessionChecks','DirectorConversationChecks','HistoryLookupChecks','FramingConflictChecks','AssistantPanelLayoutChecks','EditorAutomationPlannerChecks']
paths=[source/(name+'.swift') for name in production]+[root/'Tests'/(name+'.swift') for name in suites]
flags=['-whole-module-optimization','-Onone','-num-threads','1','-parse-as-library','-warnings-as-errors','-strict-concurrency=complete','-enable-upcoming-feature','ExistentialAny','-target',platform.machine()+'-apple-macos15.0']
fingerprint=hashlib.sha256((root/'Tests/check-director-integrations.sh').read_bytes())
for path in paths: fingerprint.update(path.read_bytes())
folder=root/'build/DirectorIntegrationChecks'/fingerprint.hexdigest();folder.mkdir(parents=True,exist_ok=True)
binary=folder/'check-director-integrations'
if not binary.exists():
 tests=[]
 for name in suites:
  text=(root/'Tests'/(name+'.swift')).read_text()
  assert text.count('@main')==1,name
  path=folder/(name+'.swift');path.write_text(text.replace('@main','',1));tests.append(path)
 calls='\n'.join('if selected.isEmpty || selected.contains("'+name+'") { try '+('' if name=='EditorAutomationPlannerChecks' else 'await ')+name+('.run()' if name=='DirectorInspectionSessionChecks' else '.main()')+' }' for name in suites)
 entry=folder/'IntegrationMain.swift'
 entry.write_text('import Foundation\nimport Darwin\n@main @MainActor struct DirectorIntegrationMain { static func main() async { let selected=Set(CommandLine.arguments.dropFirst()); do {\n'+calls+'\n} catch { FileHandle.standardError.write(Data("Director integration failed: \\(error)\\n".utf8)); exit(1) } } }\n')
 subprocess.run(['swiftc']+flags+[str(path) for path in paths[:len(production)]]+[str(path) for path in tests]+[str(entry),'-o',str(binary)],check=True)
subprocess.run([str(binary)]+sys.argv[2:],check=True)
PY
