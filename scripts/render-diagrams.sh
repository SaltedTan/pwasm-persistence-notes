#!/usr/bin/env bash
set -euo pipefail

mkdir -p rendered

plantuml --svg diagrams/*.puml

# PlantUML writes output beside the source by default.
# Move generated SVGs into rendered/.
find diagrams -maxdepth 1 -name '*.svg' -exec mv {} rendered/ \;
