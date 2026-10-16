#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/checks
sources=()
for name in Core Demo Settings AI Search Assistant Semantic Clean Background BrowserBridge Layers WebSearch Study Voice RuntimeChecks; do sources+=(Sources/StepBar/$name.swift); done
swiftc $sources Tests/StepBarTests/InferenceTests.swift Tests/StepBarTests/AdvancedTests.swift -o .build/checks/core-tests
.build/checks/core-tests
swiftc $sources Tests/StepBarTests/BridgeTests.swift -o .build/checks/bridge-tests
.build/checks/bridge-tests
