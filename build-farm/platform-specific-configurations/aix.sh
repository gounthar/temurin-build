#!/bin/bash
# shellcheck disable=SC1091

################################################################################
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# AIX default ulimit is frequently less than we need to clone the LTS JDK repositories
FILESIZELIMIT=$(ulimit)
if [ "$FILESIZELIMIT" != "unlimited" ]; then
  # Set to ~2GB as this works for the AIX hosts we have as of April 2021
  if [ "$FILESIZELIMIT" -lt 2097150 ]; then
    echo "WARNING: MAXIMUM USER FILE SIZE (ulimit -n) IS $FILESIZELIMIT (<2097150) - GIT MAY HAVE PROBLEMS CLONING"
    sleep 5
  fi
fi

# Send temporary build files to the ramdisk for performance
if [ -r /ramdisk0/build/tmp ]; then
  echo Using /ramdisk0/build/tmp for temporary files \(Clearing it out first...\)
  export TMPDIR=/ramdisk0/build/tmp
  echo Found "$(find $TMPDIR -type f -print | wc -l)" items in it - removing them
  time rm -rf /ramdisk0/build/tmp/*
else
  echo Using default /tmp for temporary files as /ramdisk0/build/tmp does not exist
fi
# shellcheck source=sbin/common/constants.sh
source "$SCRIPT_DIR/../../sbin/common/constants.sh"
export PATH="/opt/freeware/bin:/usr/local/bin:/opt/IBM/xlC/13.1.3/bin:/opt/IBM/xlc/13.1.3/bin:$PATH"
# Without this, java adds /usr/lib to the LIBPATH and it's own library
# directories of anything it forks which breaks linkage
export LIBPATH=/opt/freeware/lib/pthread/ppc64:/opt/freeware/lib:/usr/lib
export CONFIGURE_ARGS_FOR_ANY_PLATFORM="${CONFIGURE_ARGS_FOR_ANY_PLATFORM} --with-cups-include=/opt/freeware/include"

# Any version below 11
if  [ "$JAVA_FEATURE_VERSION" -lt 11 ]
then
  export CONFIGURE_ARGS_FOR_ANY_PLATFORM="${CONFIGURE_ARGS_FOR_ANY_PLATFORM} --with-extra-ldflags=-lpthread --with-extra-cflags=-lpthread --with-extra-cxxflags=-lpthread"
fi

export BUILD_ARGS="${BUILD_ARGS} --skip-freetype"

if [ "${VARIANT}" == "${BUILD_VARIANT_OPENJ9}" ]; then
  export LDR_CNTRL=MAXDATA=0x80000000
fi
echo LDR_CNTRL=$LDR_CNTRL

BOOT_JDK_VARIABLE="JDK${JDK_BOOT_VERSION}_BOOT_DIR"
if [ ! -d "$(eval echo "\$$BOOT_JDK_VARIABLE")" ]; then
  bootDir="$PWD/jdk-$JDK_BOOT_VERSION"
  # Note we export $BOOT_JDK_VARIABLE (i.e. JDKXX_BOOT_DIR) here
  # instead of BOOT_JDK_VARIABLE (no '$').
  export "${BOOT_JDK_VARIABLE}"="${bootDir}"
  if [ ! -x "$bootDir/bin/javac" ]; then
    # Set to a default location as linked in the ansible playbooks
    if [ -x "/usr/java${JDK_BOOT_VERSION}_64/bin/javac" ]; then
      echo "Could not use ${BOOT_JDK_VARIABLE} - using /usr/java${JDK_BOOT_VERSION}_64"
      # shellcheck disable=SC2140
      export "${BOOT_JDK_VARIABLE}"="/usr/java${JDK_BOOT_VERSION}_64"
    elif [ "$JDK_BOOT_VERSION" -ge 8 ]; then # Adopt has no build pre-8
      mkdir -p "${bootDir}"
      releaseType="ga"
      apiUrlTemplate="https://api.adoptium.net/v3/binary/latest/\${JDK_BOOT_VERSION}/\${releaseType}/aix/\${ARCHITECTURE}/jdk/hotspot/normal/adoptium"
      apiURL=$(eval echo ${apiUrlTemplate})
      echo "Downloading GA release of boot JDK version ${JDK_BOOT_VERSION} from ${apiURL}"
      # make-adopt-build-farm.sh has 'set -e'. We need to disable that for
      # the fallback mechanism, as downloading of the GA binary might fail.
      set +e
      wget -q -O - "${apiURL}" | tar xpzf - --strip-components=1 -C "$bootDir"
      retVal=$?
      set -e
      if [ $retVal -ne 0 ]; then
        # We must be a JDK HEAD build for which no boot JDK exists other than
        # nightlies?
        echo "Downloading GA release of boot JDK version ${JDK_BOOT_VERSION} failed."
        # shellcheck disable=SC2034
        releaseType="ea"
        apiURL=$(eval echo ${apiUrlTemplate})
        echo "Attempting to download EA release of boot JDK version ${JDK_BOOT_VERSION} from ${apiURL}"
        wget -q -O - "${apiURL}" | tar xpzf - --strip-components=1 -C "$bootDir"
      fi
    fi
  fi
fi

# shellcheck disable=SC2155
export JDK_BOOT_DIR="$(eval echo "\$$BOOT_JDK_VARIABLE")"
"$JDK_BOOT_DIR/bin/java" -version 2>&1 | sed 's/^/BOOT JDK: /'
"$JDK_BOOT_DIR/bin/java" -version > /dev/null 2>&1
executedJavaVersion=$?
if [ $executedJavaVersion -ne 0 ]; then
    echo "Failed to obtain or find a valid boot jdk"
    exit 1
fi

if [ "${VARIANT}" == "${BUILD_VARIANT_OPENJ9}" ]; then
  if [ "$JAVA_FEATURE_VERSION" -ge 11 ]; then
    export CONFIGURE_ARGS_FOR_ANY_PLATFORM="${CONFIGURE_ARGS_FOR_ANY_PLATFORM} --disable-warnings-as-errors --with-openssl=fetched"
  else
    export CONFIGURE_ARGS_FOR_ANY_PLATFORM="${CONFIGURE_ARGS_FOR_ANY_PLATFORM} --with-openssl=fetched"
  fi
else
  export CONFIGURE_ARGS_FOR_ANY_PLATFORM="${CONFIGURE_ARGS_FOR_ANY_PLATFORM} DF=/usr/sysv/bin/df"
fi

if [ "$JAVA_FEATURE_VERSION" -ge 11 ]; then
  export LANG=C
  export PATH=/opt/freeware/bin:$JAVA_HOME/bin:/usr/local/bin:/opt/IBM/xlC/16.1.0/bin:/opt/IBM/xlc/16.1.0/bin:$PATH
  export CC=xlclang
  export CXX=xlclang++
fi

# J9 JDK14 builds seem to be chewing up more RAM than the others, so restrict it
# Ref: https://github.com/AdoptOpenJDK/openjdk-infrastructure/issues/1151
if [ "$JAVA_FEATURE_VERSION" -ge 14 ]; then
  export CONFIGURE_ARGS_FOR_ANY_PLATFORM="${CONFIGURE_ARGS_FOR_ANY_PLATFORM} --with-memory-size=7000"
else
  export CONFIGURE_ARGS_FOR_ANY_PLATFORM="${CONFIGURE_ARGS_FOR_ANY_PLATFORM} --with-memory-size=10000"
fi
