#!/bin/sh
# Runs every logic check (no app launch, no mic, no network). Each check compiles only the files it tests.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
run() { name=$1; shift; printf '== %s\n' "$name"; swiftc "$@" -o "$out/$name" 2>&1 | grep -E "error" && exit 1; "$out/$name"; }
run vocabulary Capipaste/Vocabulary.swift Capipaste/CaptureContext.swift checks/main.swift
run recordings Capipaste/Recordings.swift checks/recordings/main.swift
run updater Capipaste/Updater.swift checks/updater/main.swift
run cloud Capipaste/Cloud.swift checks/cloud/main.swift
run logic Capipaste/TidyRules.swift Capipaste/Recorder.swift Capipaste/Output.swift Capipaste/History.swift Capipaste/Recordings.swift Capipaste/Clip.swift Capipaste/Updater.swift checks/logic/main.swift
echo "all checks passed"
