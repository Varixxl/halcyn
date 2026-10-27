#!/usr/bin/env bash
# For a tag build, prints the flutter build flags that stamp the tag's version (v1.2.3 →
# 1.2.3) and an always-increasing build number, which Android needs to install updates.
if [[ ${GITHUB_REF:-} == refs/tags/v* ]]; then
  echo "--build-name=${GITHUB_REF_NAME#v} --build-number=${GITHUB_RUN_NUMBER}"
fi
