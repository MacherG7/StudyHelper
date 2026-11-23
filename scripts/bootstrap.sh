#!/usr/bin/env bash
# Generates StudyHelper.xcodeproj from project.yml.
source "$(dirname "$0")/common.sh"
generate_project
echo "Fertig: $PROJECT"
