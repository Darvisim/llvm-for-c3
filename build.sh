#!/bin/bash

# Display all commands before executing them.
set -o errexit
set -o errtrace

LLVM_VERSION=$1
LLVM_REPO_URL=${2:-https://github.com/llvm/llvm-project.git}
LLVM_CROSS="$3"

if [[ -z "$LLVM_REPO_URL" || -z "$LLVM_VERSION" ]]
then
  echo "Usage: $0 <llvm-version> <llvm-repository-url> [aarch64/riscv64]"
  echo
  echo "# Arguments"
  echo "  llvm-version         The name of a LLVM release branch without the 'release/' prefix"
  echo "  llvm-repository-url  The URL used to clone LLVM sources (default: https://github.com/llvm/llvm-project.git)"
  echo "  aarch64 / riscv64    To cross-compile an aarch64/riscv64 version of LLVM"

  exit 1
fi

# Clone the LLVM project.
if [ ! -d llvm-project ]
then
	if git clone -b "release/$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
		LLVM_REF="release/$LLVM_VERSION"
	elif git clone -b "llvmorg-$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
		LLVM_REF="llvmorg-$LLVM_VERSION"
	else
		echo "Error: Could not find branch 'release/$LLVM_VERSION' or tag 'llvmorg-$LLVM_VERSION'"
		exit 1
	fi
fi

cd llvm-project
git fetch origin
git checkout "$LLVM_REF"
git reset --hard "$LLVM_REF"

# Create directories
mkdir -p build
mkdir -p build_rt

# Adjust compilation based on build type
BUILD_TYPE=$4
if [[ -z "$BUILD_TYPE" ]]; then
  BUILD_TYPE="Release"
fi

# Adjust cross-compilation (Only RISC-V requires cross-compiling on current CI runners)
CROSS_COMPILE=""
TARGET_TRIPLE=""
if [[ "$3" == *riscv64* ]]; then
    TARGET_TRIPLE="riscv64-linux-gnu"
    CROSS_COMPILE="-DLLVM_HOST_TRIPLE=$TARGET_TRIPLE -DCMAKE_C_COMPILER=riscv64-linux-gnu-gcc-13 -DCMAKE_CXX_COMPILER=riscv64-linux-gnu-g++-13 -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=riscv64"
fi

# Set defaults
ENABLE_ASSERTIONS="OFF"
OPTIMIZED_TABLEGEN="ON"
PARALLEL_LINK_FLAGS=""
BUILD_PARALLEL_FLAGS=""
CMAKE_ARGUMENTS=""

if [[ "$BUILD_TYPE" == "Debug" ]]; then
  BUILD_TYPE="Release"
  ENABLE_ASSERTIONS="ON"

  # if [[ "${OSTYPE}" == linux* ]]; then
  #   # Grouped Linux-specific Debug optimizations to save memory on CI
  #   CMAKE_ARGUMENTS="-DLLVM_USE_SPLIT_DWARF=ON"
  #   #OPTIMIZED_TABLEGEN="OFF"
  #   PARALLEL_LINK_FLAGS="-DLLVM_PARALLEL_LINK_JOBS=2"
  #   BUILD_PARALLEL_FLAGS="--parallel 2"
  # fi
fi

df -h

# -- PHASE 1: Build LLVM + LLD --
cd build
cmake \
  -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=TRUE \
  -DCMAKE_INSTALL_PREFIX="/" \
  -DLLVM_ENABLE_PROJECTS="lld" \
  -DLLVM_ENABLE_RUNTIMES="" \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV;WebAssembly;LoongArch;ARM" \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DLLVM_ENABLE_ASSERTIONS="${ENABLE_ASSERTIONS}" \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_LIBXML2=0 \
  -DLLVM_ENABLE_DOXYGEN=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_TOOLS=ON \
  -DLLVM_INCLUDE_RUNTIMES=OFF \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_OPTIMIZED_TABLEGEN="${OPTIMIZED_TABLEGEN}" \
  ${CROSS_COMPILE} \
  ${PARALLEL_LINK_FLAGS} \
  ${CMAKE_ARGUMENTS} \
  ../llvm

cmake --build . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}

# Save some disk space
echo "Initial disk usage:"
df -h
find . -name "*.o" -type f -delete || true
find . -name "*.dwo" -type f -delete || true
echo "Before install disk usage:"
df -h

DESTDIR=destdir cmake --install . --config "${BUILD_TYPE}"

echo "After install disk usage:"
df -h
echo "Cleaning up Phase 1 to make room for Phase 2..."
find . -maxdepth 1 ! -name 'destdir' ! -name 'bin' ! -name 'lib' ! -name '.' -exec rm -rf {} + || true
echo "Disk usage before Phase 2:"
df -h

# -- PHASE 2: Build compiler-rt (Builtins & Sanitizers) --

# --- AUTO-DISCOVERY ---
# Locate llvm-config inside the destdir (it might be in /bin or /usr/bin)
LLVM_CONFIG_PATH=$(find "$(pwd)/destdir" -name llvm-config -type f | head -n 1)
if [[ -z "$LLVM_CONFIG_PATH" ]]; then
  echo "Error: Could not find llvm-config in destdir"
  exit 1
fi
echo "Found llvm-config at: $LLVM_CONFIG_PATH"

# Locate the LLVM CMake directory inside destdir
LLVM_CMAKE_DIR_PATH=$(find "$(pwd)/destdir" -name LLVMConfig.cmake -type f -exec dirname {} + | head -n 1)
if [[ -z "$LLVM_CMAKE_DIR_PATH" ]]; then
  echo "Error: Could not find LLVMConfig.cmake in destdir"
  exit 1
fi
echo "Found LLVM CMake dir at: $LLVM_CMAKE_DIR_PATH"

# We need the host triple for standalone compiler-rt build. 
# Skip running llvm-config if cross-compiling to avoid Exec format errors.
LLVM_LIB_DIR=$(find "$(pwd)/destdir" -name "lib" -type d | head -n 1)

# Tell the OS where to find libLLVM.so so llvm-config can f... run
if [[ "${OSTYPE}" == linux* ]]; then
  export LD_LIBRARY_PATH="$LLVM_LIB_DIR:$LD_LIBRARY_PATH"
elif [[ "${OSTYPE}" == darwin* ]]; then
  export DYLD_LIBRARY_PATH="$LLVM_LIB_DIR:$DYLD_LIBRARY_PATH"
fi
#HOST_TRIPLE=${TARGET_TRIPLE:-$(./bin/llvm-config --host-target)}
#HOST_TRIPLE=${TARGET_TRIPLE:-$(../build/destdir/bin/llvm-config --host-target)}
HOST_TRIPLE=${TARGET_TRIPLE:-$($LLVM_CONFIG_PATH --host-target)}
echo "Host Triple: $HOST_TRIPLE"

cd ..

if [[ "$3" == *ios* ]]; then
  IOS_DEVICE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
  IOS_SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
  DEVICE_TRIPLE="arm64-apple-ios"
  SIM_TRIPLE="arm64-apple-ios-simulator"

  echo "Building compiler-rt for iOS device..."
  mkdir -p ios_device
  cd ios_device

  cmake -G Ninja \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${IOS_DEVICE_SDK}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DCMAKE_C_COMPILER=$(xcrun --sdk iphoneos -f clang) \
    -DCMAKE_C_COMPILER_TARGET="${DEVICE_TRIPLE}" \
    -DLLVM_CMAKE_DIR="$LLVM_CMAKE_DIR_PATH" \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    ../compiler-rt
  ninja
  DESTDIR=../build/destdir_ios_device ninja install
  cd ..

  echo "Building compiler-rt for iOS simulator..."
  mkdir -p ios_sim
  cd ios_sim

  cmake -G Ninja \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${IOS_SIM_SDK}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DCMAKE_C_COMPILER=$(xcrun --sdk iphonesimulator -f clang) \
    -DCMAKE_C_COMPILER_TARGET="${SIM_TRIPLE}" \
    -DLLVM_CMAKE_DIR="$LLVM_CMAKE_DIR_PATH" \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    ../compiler-rt

  ninja
  DESTDIR=../build/destdir_ios_sim ninja install
  cd ..

  echo "Creating Universal builtins..."

  DEVICE_LIB=$(find build/destdir_ios_device -name "libclang_rt.builtins_ios.a" | head -n 1)
  SIM_LIB=$(find build/destdir_ios_sim -name "libclang_rt.builtins_ios*.a" | head -n 1)

  if [[ -z "$DEVICE_LIB" || -z "$SIM_LIB" ]]; then
    echo "Error: Could not locate builtins libraries"
    exit 1
  fi

  UNIVERSAL_DIR="build/destdir/lib/clang/${LLVM_VERSION}/lib/darwin"
  mkdir -p "$UNIVERSAL_DIR"

  UNIVERSAL_LIB="$UNIVERSAL_DIR/libclang_rt.builtins_ios.a"

  lipo -create "$DEVICE_LIB" "$SIM_LIB" -output "$UNIVERSAL_LIB"
  lipo -info "$UNIVERSAL_LIB"
  
  echo "Universal builtins created at:"
  echo "$UNIVERSAL_LIB"

else
  cd build_rt
  cmake \
    -G Ninja \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_INSTALL_PREFIX="/" \
    -DLLVM_CMAKE_DIR="$LLVM_CMAKE_DIR_PATH" \
    -DCMAKE_C_COMPILER_TARGET="${HOST_TRIPLE}" \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=ON \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    ${CROSS_COMPILE} \
    ${CMAKE_ARGUMENTS} \
    ../compiler-rt

  echo "Building compiler-rt..."
  df -h

  cmake --build . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}

  echo "Installing compiler-rt..."
  df -h

  # Install to the same destdir as LLVM
  DESTDIR=../build/destdir cmake --install . --config "${BUILD_TYPE}"
fi
echo "Final Disk Usage:"
df -h
