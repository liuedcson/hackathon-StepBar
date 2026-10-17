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
python3 Tests/StepBarTests/update-helper-test.py
if [[ "${STEPBAR_TEST_UI:-0}" == "1" ]]; then
  swiftc Sources/StepBar/Usage.swift Sources/StepBar/AI.swift Sources/StepBar/Updater.swift Tests/StepBarTests/UpdateUITests.swift -o .build/checks/update-ui-tests
  .build/checks/update-ui-tests
fi
