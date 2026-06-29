#!/bin/bash

set -euo pipefail

## Folder layout is discovered automatically from the built linux-firmware tree.
## No hardcoded lists are kept here: each release is analyzed on the fly so new
## folders are picked up automatically and stale ones disappear without manual edits.
##
## Discovery rules:
##  - Every top level folder in /lib/firmware becomes its own target.
##  - Loose files in the root of /lib/firmware go into the "uncategorized" target.
##  - Folders that are very large AND contain very large subfolders (today this is
##    intel and qcom) are split: each big subfolder gets its own target and the rest
##    of the folder (loose files + small subfolders) ships as <folder>-generic.
##    This is size driven, so any future huge folder is handled the same way without
##    changing the script.

FIRMWARE_VERSION="20260221"

SINGLE_TARGET=""
DOCKERFILE_ONLY=0
BUILD=0
SYSEXT=0
PUSH=0
REPOSITORY="ttl.sh"
CERTIFICATE=""
PRIVATE_KEY=""
CACHE_FROM=""
CACHE_TO=""
## A folder is only split into separate firmware layers when it is BOTH big in total
## (>= SPLIT_THRESHOLD_MB) AND has subfolders to split on. A folder with no subfolders
## is never split, so no single firmware ever needs 2 layers. A folder with many tiny
## subfolders stays bundled; one with a large total spread across subfolders gets split.
## Override with --split-threshold-mb.
SPLIT_THRESHOLD_MB=100

DESTDIR="${DESTDIR:-/usr/local/lib/firmware}"


while [[ $# -gt 0 ]]; do
  case "$1" in
    --dockerfile-only)
      DOCKERFILE_ONLY=1
      shift
      ;;
    --target)
      SINGLE_TARGET="$2"
      shift 2
      ;;
    --firmware-version)
      FIRMWARE_VERSION="$2"
      shift 2
      ;;
    --build)
      BUILD=1
      shift
      ;;
    --sysext)
      SYSEXT=1
      shift
      ;;
    --push)
      PUSH=1
      shift
      ;;
    --repository)
      REPOSITORY="$2"
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY="$2"
      shift 2
      ;;
    --certificate)
      CERTIFICATE="$2"
      shift 2
      ;;
    --cache-from)
      CACHE_FROM="$2"
      shift 2
      ;;
    --cache-to)
      CACHE_TO="$2"
      shift 2
      ;;
    --split-threshold-mb)
      SPLIT_THRESHOLD_MB="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --dockerfile-only             Generate only the Dockerfile.firmware"
      echo "  --target <target_name>        Build only the specified target"
      echo "  --firmware-version <ver>      Specify the linux-firmware version (default: $FIRMWARE_VERSION)"
      echo "  --build                       Build the firmware images"
      echo "  --sysext                      Create sysext images for the built firmware images"
      echo "  --push                        Push the built images to the repository (requires --build)"
      echo "  --repository <repo>           Specify the Docker repository (default: $REPOSITORY)"
      echo "  --split-threshold-mb <mb>     Total folder size (with subfolders) that triggers splitting (default: $SPLIT_THRESHOLD_MB)"
      echo "  --cache-from <spec>           Docker cache source spec (e.g. type=gha)"
      echo "  --cache-to <spec>             Docker cache destination spec (e.g. type=gha,mode=max)"
      echo "  --help, -h                    Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      shift
      ;;
  esac
done

if [[ $PUSH -eq 1 && $BUILD -eq 0 ]]; then
  echo "--push requires --build to be specified."
  exit 1
fi

if [[ $DOCKERFILE_ONLY -eq 0 && $BUILD -eq 0 && $SYSEXT -eq 0 ]]; then
  echo "No action specified. Use --dockerfile-only, --build, or --sysext."
  exit 1
fi

## Check if firmware version has a revision part (e.g., 20231115-1) and handle it properly as we want to drap that, the revisions are just for us
if [[ $FIRMWARE_VERSION == *"-"* ]]; then
  FIRMWARE_VERSION="${FIRMWARE_VERSION%%-*}"
fi

## Build the cache args arrays for docker buildx build
CACHE_FROM_ARGS=()
CACHE_EXPORT_ARGS=()
FULL_CACHE_ARGS=()
if [[ -n "$CACHE_FROM" ]]; then
  CACHE_FROM_ARGS+=(--cache-from "$CACHE_FROM")
fi
if [[ -n "$CACHE_TO" ]]; then
  CACHE_EXPORT_ARGS+=(--cache-to "$CACHE_TO")
fi
FULL_CACHE_ARGS=("${CACHE_FROM_ARGS[@]}" "${CACHE_EXPORT_ARGS[@]}")

## Sanitize a folder name into a valid, lowercase docker target name.
## - folders starting with a number get reversed so the name does not start with a digit
## - dots are turned into dashes
## - uppercase names are lowercased
sanitize_target() {
  local folder="$1" target
  if [[ $folder =~ ^[0-9] ]]; then
    target=$(echo "$folder" | rev | tr '.' '-')
  else
    target=${folder//./-}
  fi
  if [[ $folder =~ ^[A-Z0-9_-]+$ ]]; then
    target=${target,,}
  fi
  echo "$target"
}

BASE_IMAGE_TAG="hadron-firmware-base:${FIRMWARE_VERSION}"

echo "Generating Dockerfile.base for linux-firmware version: $FIRMWARE_VERSION"
cat <<EOF > Dockerfile.base
ARG FIRMWARE_VERSION=$FIRMWARE_VERSION
ARG ALPINE_VERSION=3.22.2

FROM alpine:\$ALPINE_VERSION AS base
ENV ZSTD_NBTHREADS=4
ENV ZSTD_CLEVEL=19
# rdfind is used to deduplicate files
# parallel is used to speed up compression
# coreutils is used for ln in dedup which uses force option
# findutils is needed for dedup to use xtype option
RUN apk add --no-cache git zstd rdfind parallel coreutils findutils
WORKDIR /src
RUN git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
WORKDIR /src/linux-firmware
RUN git fetch --tags
RUN git checkout $FIRMWARE_VERSION
## This avoids a WHENCE check which we should nto care about and avoids installing python3
RUN rm .git/config
RUN mkdir /out
RUN ./copy-firmware.sh -j\$(nproc) -v --zstd /out/lib/firmware
RUN ./dedup-firmware.sh /out/lib/firmware
EOF

## The base image is required to inspect the firmware tree and decide which folders
## need splitting, so we always build it first.
echo "Building base image to discover firmware folders..."
set +e
output=$(docker buildx build -f Dockerfile.base -t "${BASE_IMAGE_TAG}" --target base --load "${FULL_CACHE_ARGS[@]}" . 2>&1)
status=$?
set -e
if [ $status -ne 0 ]; then
  echo "Base image build failed:"
  echo "$output"
  exit 1
fi

## Discover the firmware layout on the fly from the built base image.
## The container prints one record per top level folder:
##   DIR|<folder>                ship the whole folder as one target
##   GENERIC|<folder>|<subfolders>   split: each subfolder ships separately, loose
##                                   files (and anything left) ship as <folder>-generic
echo "Analyzing firmware folders (split when total>=${SPLIT_THRESHOLD_MB}MB and has subfolders)..."
MANIFEST=$(docker run --rm "${BASE_IMAGE_TAG}" sh -c "
  set -e
  cd /out/lib/firmware
  SPLIT=${SPLIT_THRESHOLD_MB}
  for d in \$(ls -d */ 2>/dev/null | tr -d '/'); do
    total=\$(du -sm \"\$d\" | cut -f1)
    subs=''
    for s in \$(ls -d \"\$d\"/*/ 2>/dev/null | sed 's#/\$##'); do
      subs=\"\$subs \${s#\$d/}\"
    done
    # Only split big folders that actually have subfolders to split on. A folder with
    # no subfolders is shipped whole no matter how big, so no firmware needs 2 layers.
    if [ \"\$total\" -ge \"\$SPLIT\" ] && [ -n \"\$subs\" ]; then
      echo \"GENERIC|\$d|\${subs# }\"
    else
      echo \"DIR|\$d\"
    fi
  done
")

TARGETS=()  # name|src|dest|mode
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  kind=${line%%|*}
  rest=${line#*|}
  if [[ $kind == "DIR" ]]; then
    folder=$rest
    target=$(sanitize_target "$folder")
    TARGETS+=("${target}|/out/lib/firmware/${folder}|${DESTDIR}/${folder}/|dir")
  else
    folder=${rest%%|*}
    bigsubs=${rest#*|}
    base=$(sanitize_target "$folder")
    TARGETS+=("${base}-generic|/out/lib/firmware/${folder}|${DESTDIR}/${folder}/|split;${bigsubs}")
    for sub in $bigsubs; do
      st=$(sanitize_target "$sub")
      TARGETS+=("${base}-${st}|/out/lib/firmware/${folder}/${sub}|${DESTDIR}/${folder}/${sub}/|dir")
    done
  fi
done <<< "$MANIFEST"
# Loose files in the root of /lib/firmware
TARGETS+=("uncategorized|/out/lib/firmware|${DESTDIR}/|rootfiles")

echo "Discovered ${#TARGETS[@]} firmware targets"

echo "Generating Dockerfile.firmware"
cp Dockerfile.base Dockerfile.firmware
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r name src dest mode <<< "$entry"
  case "$mode" in
    dir)
      cat <<EOF >> Dockerfile.firmware

FROM scratch AS ${name}
COPY --from=base ${src}/. ${dest}
EOF
      ;;
    rootfiles)
      cat <<EOF >> Dockerfile.firmware

FROM base AS ${name}-stage
RUN mkdir /output && find ${src} -maxdepth 1 -type f -exec cp {} /output/ \;

FROM scratch AS ${name}
COPY --from=${name}-stage /output/. ${dest}
EOF
      ;;
    split\;*)
      bigsubs=${mode#split;}
      rm_cmd=""
      for sub in $bigsubs; do
        rm_cmd="${rm_cmd} && rm -rf /output/${sub}"
      done
      cat <<EOF >> Dockerfile.firmware

FROM base AS ${name}-stage
RUN cp -a ${src} /output${rm_cmd}

FROM scratch AS ${name}
COPY --from=${name}-stage /output/. ${dest}
EOF
      ;;
  esac
done

echo "Generated Dockerfile.firmware"
# If only generating Dockerfile, exit here so we dont remove the dockerfile
if [[ $DOCKERFILE_ONLY -eq 1 ]]; then
  rm -f Dockerfile.base
  exit 0
fi

build_target() {
  local target="$1" tag="$2"
  echo "Building: $target"
  set +e
  output=$(docker buildx build -f Dockerfile.firmware -t "$tag" --target "$target" --load "${CACHE_FROM_ARGS[@]}" . 2>&1)
  status=$?
  set -e
  if [ $status -ne 0 ]; then
    echo "Docker build failed:"
    echo "$output"
    exit 1
  fi
  if [[ $PUSH -eq 1 ]]; then
    echo "Pushing image $tag to repository..."
    docker push "$tag"
    echo "$tag" >> published-images.txt
    echo "Push completed successfully."
  fi
}

if [[ $BUILD -eq 1 ]]; then
  if [[ -n "$SINGLE_TARGET" ]]; then
    build_target "$SINGLE_TARGET" "${REPOSITORY}/linux-firmware-${SINGLE_TARGET}:${FIRMWARE_VERSION}"
    echo "Build for $SINGLE_TARGET completed successfully."
    rm Dockerfile.firmware Dockerfile.base
    exit 0
  fi

  echo "Building all firmware targets..."
  for entry in "${TARGETS[@]}"; do
    name=${entry%%|*}
    build_target "$name" "${REPOSITORY}/linux-firmware-${name}:${FIRMWARE_VERSION}"
  done
  echo "All builds completed successfully."
fi


## Allow passing --private-key and --certificate to sysext in order to sign the sysext images
if [[ $SYSEXT -eq 1 ]]; then
  echo "Building sysext firmware images..."
  images=$(docker images --filter=reference="${REPOSITORY}/linux-firmware-*" --format '{{.Repository}}:{{.Tag}}')
  for image in $images; do
    # target name is the image name without the repository part. Lets keep the linux-firmware on it
    target_name=$(echo "$image" | sed -e "s|${REPOSITORY}/||" -e 's|:|_|g')
    echo "Building sysext for $target_name with image $image"
    mounts="-v /var/run/docker.sock:/var/run/docker.sock"
    args="--output /build"
    if [[ -n "$PRIVATE_KEY" && -n "$CERTIFICATE" ]]; then
      # get the base path of the private key and certificate to mount into the docker container
      # For example if the private key is /path/to/key.pem we need to mount /path/to
      key_dir=$(dirname "$PRIVATE_KEY")
      cert_dir=$(dirname "$CERTIFICATE")
      ## If they are relative paths make them absolute
      if [[ "$key_dir" != /* ]]; then
        key_dir="${PWD}/$key_dir"
      fi
      if [[ "$cert_dir" != /* ]]; then
        cert_dir="${PWD}/$cert_dir"
      fi
      ## chmod the key to be read only by the user
      chmod 400 "$PRIVATE_KEY"
      chmod 400 "$CERTIFICATE"
      ## Now add the mounts for the key and cert
      mounts="$mounts -v $key_dir:/key -v $cert_dir:/cert"
      ## Now set the full destination args to the proper paths inside the container
      args="$args --private-key /key/$(basename "$PRIVATE_KEY") --certificate /cert/$(basename "$CERTIFICATE")"
    fi
    docker run -i --rm ${mounts} \
      -v "${PWD}"/build:/build \
      quay.io/kairos/auroraboot:v0.15.0-beta1 \
      sysext ${args} "$target_name" "$image"
    echo "Sysext for $target_name built successfully."
  done
  echo "All sysext firmware images built"
fi


# Cleanup
echo "Removing temporary Dockerfiles"
rm -f Dockerfile.firmware Dockerfile.base
