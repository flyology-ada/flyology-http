#!/bin/sh

if [ "${ALIRE:-}" = True ] \
  && [ -n "${FLYOLOGY_ROOT:-}" ] \
  && [ -z "${FLYOLOGY_HTTP_TEST_IN_ALIRE:-}" ]
then
  FLYOLOGY_HTTP_TEST_IN_ALIRE=1
  export FLYOLOGY_HTTP_TEST_IN_ALIRE
fi

flyology_http_run_nested_alire_test () {
  if [ -n "${FLYOLOGY_HTTP_TEST_IN_ALIRE:-}" ]; then
    env \
      -u FLYOLOGY_ALIRE_PREFIX \
      -u FLYOLOGY_ALLOCATORS_ALIRE_PREFIX \
      -u FLYOLOGY_CACHELINES_ALIRE_PREFIX \
      -u FLYOLOGY_HTTP_ALIRE_PREFIX \
      -u FLYOLOGY_QUIC_ALIRE_PREFIX \
      -u FLYOLOGY_ROOT \
      -u GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX \
      -u GNAT_NATIVE_ALIRE_PREFIX \
      -u GPR_CONFIG \
      -u GPRBUILD_ALIRE_PREFIX \
      -u GPR_PROJECT_PATH \
      "$@"
  else
    "$@"
  fi
}
