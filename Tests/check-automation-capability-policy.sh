#!/bin/sh
# Compile Host metadata checks once; exercise vector edits and independent policy facts.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec taskpolicy -b python3 - "$repo_dir" <<'PY'
import hashlib, os, pathlib, platform, subprocess, sys
root=pathlib.Path(sys.argv[1]); source=root/'FrameThrower/Sources/FrameThrower'
production=['MediaProcessing','EditorRegion','RecordingProject','EditorConflictGeometry','EditorConflictReview',
 'EditorActionDescription','EditorCommand','EditorMutation','EditorAgentControls','LocalEditPlanner',
 'TimelineAnimation','EditorAnimationEditing','EditorSimulationClock','EditorPreviewCommand',
 'CursorRecording','ProjectRenderer','PIPVideoCompositor','EditorPlayback','RecordedScene','DirectorInspection',
 'FrameThrowerMCPServer','EditorAutomationAPI','EditorAutomationHost']
suites=['MultiVideoDirectorChecks','AutomationCapabilityPolicyChecks']
paths=[source/(name+'.swift') for name in production]+[root/'Tests'/(name+'.swift') for name in suites]
fingerprint=hashlib.sha256((root/'Tests/check-automation-capability-policy.sh').read_bytes())
for path in paths: fingerprint.update(path.read_bytes())
folder=root/'build/AutomationCapabilityPolicyChecks'/fingerprint.hexdigest();folder.mkdir(parents=True,exist_ok=True)
binary=folder/'check-automation-capability-policy'
if not binary.exists():
 tests=[]
 for name in suites:
  value=(root/'Tests'/(name+'.swift')).read_text()
  assert value.count('@main')==1,name
  path=folder/(name+'.swift');path.write_text(value.replace('@main','',1));tests.append(path)
 entry=folder/'PolicyMain.swift'
 entry.write_text('import Foundation\nimport Darwin\n@main @MainActor struct PolicyMain { static func main() async { do { if CommandLine.arguments.contains("--selection") { try await MultiVideoDirectorChecks.main() } else { try await AutomationCapabilityPolicyChecks.main() } } catch { FileHandle.standardError.write(Data("Automation policy failed: \\(error)\\n".utf8)); exit(1) } } }\n')
 flags=['-whole-module-optimization','-Onone','-num-threads','1','-parse-as-library','-warnings-as-errors',
  '-strict-concurrency=complete','-enable-upcoming-feature','ExistentialAny','-target',platform.machine()+'-apple-macos15.0']
 subprocess.run(['swiftc']+flags+[str(path) for path in paths[:len(production)]]+[str(path) for path in tests]+[str(entry),'-o',str(binary)],check=True)
normal=os.environ.copy();normal.pop('FRAMETHROWER_VECTOR_PREVIEW',None)
vector=normal|{'FRAMETHROWER_VECTOR_PREVIEW':'1'}
subprocess.run([str(binary),'--selection'],env=vector,check=True)
subprocess.run([str(binary),'--expect-recorded-enabled'],env=normal,check=True)
subprocess.run([str(binary),'--expect-vector-preview'],env=vector,check=True)
PY
