#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
context_helper="$http_root/scripts/alire-test-context.sh"
test_path=${PATH:-/usr/bin:/bin}

env -i \
  PATH="$test_path" \
  ALIRE=True \
  FLYOLOGY_ROOT=/outer/flyology \
  GPR_CONFIG=/outer/flyology/build/flyology.cgpr \
  GPR_PROJECT_PATH=/outer/projects \
  FLYOLOGY_ALIRE_PREFIX=/outer/flyology \
  GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX=/outer/gnat \
  GNAT_NATIVE_ALIRE_PREFIX=/outer/gnat-native \
  GPRBUILD_ALIRE_PREFIX=/outer/gprbuild \
  sh -c '
    set -eu
    . "$1"
    test "${FLYOLOGY_HTTP_TEST_IN_ALIRE:-}" = 1
    sh -c '\''test "${FLYOLOGY_HTTP_TEST_IN_ALIRE:-}" = 1'\''
    flyology_http_run_nested_alire_test sh -c '\''
      test -z "${FLYOLOGY_ROOT:-}"
      test -z "${GPR_CONFIG:-}"
      test -z "${GPR_PROJECT_PATH:-}"
      test -z "${FLYOLOGY_ALIRE_PREFIX:-}"
      test -z "${GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX:-}"
      test -z "${GNAT_NATIVE_ALIRE_PREFIX:-}"
      test -z "${GPRBUILD_ALIRE_PREFIX:-}"
      test "${ALIRE:-}" = True
    '\''
  ' sh "$context_helper"

env -i \
  PATH="$test_path" \
  FLYOLOGY_ROOT=/direct/flyology \
  GPR_CONFIG=/direct/flyology/build/flyology.cgpr \
  sh -c '
    set -eu
    . "$1"
    test -z "${FLYOLOGY_HTTP_TEST_IN_ALIRE:-}"
    flyology_http_run_nested_alire_test sh -c '\''
      test "${FLYOLOGY_ROOT:-}" = /direct/flyology
      test "${GPR_CONFIG:-}" = /direct/flyology/build/flyology.cgpr
    '\''
  ' sh "$context_helper"
