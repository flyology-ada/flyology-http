#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
benchmark_root=${FLYOLOGY_IRI_BENCHMARK_ROOT:-$repository_root/build/flyology-iri-benchmark}
ada_root=$benchmark_root/ada-url
dataset_root=$ada_root/url-dataset

ada_url=https://github.com/ada-url/ada.git
ada_revision=32dabc8d39a919633f31f692c358012b2105fd61
dataset_url=https://github.com/ada-url/url-dataset.git
dataset_revision=ef7065196980ab7956bacc60b4bda663939f659c

prepare_checkout () {
  name=$1
  url=$2
  revision=$3
  directory=$4

  if [ ! -e "$directory" ]; then
    mkdir -p "$directory"
    git -C "$directory" init --quiet
  elif ! git -C "$directory" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' \
      "flyology_iri: $directory exists but is not a Git checkout" >&2
    exit 2
  fi

  if git -C "$directory" remote get-url origin >/dev/null 2>&1; then
    actual_url=$(git -C "$directory" remote get-url origin)
    if [ "$actual_url" != "$url" ]; then
      printf '%s\n' \
        "flyology_iri: $name origin is $actual_url; expected $url" >&2
      exit 2
    fi
  else
    git -C "$directory" remote add origin "$url"
  fi

  if ! git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$directory" fetch --depth 1 origin "$revision"
  fi
  git -C "$directory" checkout --quiet --detach "$revision"

  actual_revision=$(git -C "$directory" rev-parse HEAD)
  if [ "$actual_revision" != "$revision" ]; then
    printf '%s\n' \
      "flyology_iri: $name is at $actual_revision; expected $revision" >&2
    exit 2
  fi
}

prepare_checkout "Ada URL" "$ada_url" "$ada_revision" "$ada_root"
prepare_checkout \
  "URL dataset" "$dataset_url" "$dataset_revision" "$dataset_root"

if [ ! -f "$dataset_root/out.txt" ]; then
  printf '%s\n' \
    "flyology_iri: pinned URL dataset has no out.txt at $dataset_root" >&2
  exit 2
fi

printf '%s\n' \
  "Ada URL:    $ada_root ($ada_revision)" \
  "URL dataset: $dataset_root/out.txt ($dataset_revision)" \
  "Run: $crate_root/scripts/benchmark.sh"
