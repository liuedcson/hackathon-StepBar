#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/checks
sources=()
for name in Core Demo Settings Usage AI Search Assistant Semantic Clean Background BrowserBridge Layers WebSearch Study Voice RuntimeChecks Updater; do sources+=(Sources/StepBar/$name.swift); done
swiftc $sources Tests/StepBarTests/InferenceTests.swift Tests/StepBarTests/AdvancedTests.swift -o .build/checks/core-tests
.build/checks/core-tests
swiftc $sources Tests/StepBarTests/BridgeTests.swift -o .build/checks/bridge-tests
.build/checks/bridge-tests
swiftc $sources Sources/StepBar/Store.swift Sources/StepBar/Launcher.swift Tests/StepBarTests/StoreSafetyTests.swift -o .build/checks/store-safety-tests
python3 - <<'PY'
import os, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix="stepbar-store-tests-", dir=os.environ.get("TMPDIR")) as folder:
    subprocess.run([".build/checks/store-safety-tests"], env=dict(os.environ, STEPBAR_DEMO=folder), check=True, timeout=20)
PY
python3 Tests/StepBarTests/update-helper-test.py
if [[ "${STEPBAR_TEST_UI:-0}" == "1" ]]; then
  swiftc Sources/StepBar/Usage.swift Sources/StepBar/AI.swift Sources/StepBar/Updater.swift Tests/StepBarTests/UpdateUITests.swift -o .build/checks/update-ui-tests
  .build/checks/update-ui-tests
fi
