#!/bin/bash
# Copyright (c) 2018-2020, NVIDIA CORPORATION.
#########################################
# cuML GPU build and test script for CI #
#########################################
set -e
NUMARGS=$#
ARGS=$*

# Logger function for build status output
function logger() {
  echo -e "\n>>>> $@\n"
}

# Arg parsing function
function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

# Set path and build parallel level
export PATH=/conda/bin:/usr/local/cuda/bin:$PATH
export PARALLEL_LEVEL=4
export CUDA_REL=${CUDA_VERSION%.*}

# Set home to the job's workspace
export HOME=$WORKSPACE

# Parse git describei
cd $WORKSPACE
export GIT_DESCRIBE_TAG=`git describe --tags`
export MINOR_VERSION=`echo $GIT_DESCRIBE_TAG | grep -o -E '([0-9]+\.[0-9]+)'`

################################################################################
# SETUP - Check environment
################################################################################

logger "Check environment..."
env

logger "Check GPU usage..."
nvidia-smi

logger "Activate conda env..."
source activate gdf
conda install -c conda-forge -c rapidsai -c rapidsai-nightly -c nvidia \
      "cudatoolkit=${CUDA_REL}" \
      "cudf=${MINOR_VERSION}" \
      "rmm=${MINOR_VERSION}" \
      "libcumlprims=0.15.0a200720" \
      "dask-cudf=${MINOR_VERSION}" \
      "dask-cuda=${MINOR_VERSION}" \
      "ucx-py=${MINOR_VERSION}" \
      "xgboost==1.1.0dev.rapidsai0.15" \
      "rapids-build-env=$MINOR_VERSION.*" \
      "rapids-notebook-env=$MINOR_VERSION.*" \
      "rapids-doc-env=$MINOR_VERSION.*"

# https://docs.rapids.ai/maintainers/depmgmt/
# conda remove -f rapids-build-env rapids-notebook-env
# conda install "your-pkg=1.0.0"


# Install contextvars on Python 3.6
py_ver=$(python -c "import sys; print('.'.join(map(str, sys.version_info[:2])))")
if [ "$py_ver" == "3.6" ];then
    conda install contextvars
fi

# Install the master version of dask, distributed, and dask-ml
logger "pip install git+https://github.com/dask/distributed.git --upgrade --no-deps"
pip install "git+https://github.com/dask/distributed.git" --upgrade --no-deps
logger "pip install git+https://github.com/dask/dask.git --upgrade --no-deps"
pip install "git+https://github.com/dask/dask.git" --upgrade --no-deps


logger "Check versions..."
python --version
$CC --version
$CXX --version
conda list

################################################################################
# BUILD - Build libcuml, cuML, and prims from source
################################################################################

logger "Adding ${CONDA_PREFIX}/lib to LD_LIBRARY_PATH"

export LD_LIBRARY_PATH_CACHED=$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$LD_LIBRARY_PATH

logger "Building doxygen C++ docs"
$WORKSPACE/build.sh cppdocs -v

logger "Build libcuml, cuml, prims and bench targets..."
$WORKSPACE/build.sh clean libcuml cuml prims bench -v

logger "Resetting LD_LIBRARY_PATH..."

export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_CACHED
export LD_LIBRARY_PATH_CACHED=""

cd $WORKSPACE

################################################################################
# TEST - Run GoogleTest and py.tests for libcuml and cuML
################################################################################

if hasArg --skip-tests; then
    logger "Skipping Tests..."
    exit 0
fi

logger "Check GPU usage..."
nvidia-smi

logger "GoogleTest for libcuml..."
cd $WORKSPACE/cpp/build
GTEST_OUTPUT="xml:${WORKSPACE}/test-results/libcuml_cpp/" ./test/ml

logger "Python pytest for cuml..."
cd $WORKSPACE/python

pytest --cache-clear --junitxml=${WORKSPACE}/junit-cuml.xml -v -s -m "not memleak" --durations=50 --timeout=300 --ignore=cuml/test/dask --ignore=cuml/raft

timeout 7200 sh -c "pytest cuml/test/dask --cache-clear --junitxml=${WORKSPACE}/junit-cuml-mg.xml -v -s -m 'not memleak' --durations=50 --timeout=300"


################################################################################
# TEST - Run notebook tests
################################################################################

${WORKSPACE}/ci/gpu/test-notebooks.sh 2>&1 | tee nbtest.log
python ${WORKSPACE}/ci/utils/nbtestlog2junitxml.py nbtest.log

################################################################################
# TEST - Run GoogleTest for ml-prims
################################################################################

logger "Run ml-prims test..."
cd $WORKSPACE/cpp/build
GTEST_OUTPUT="xml:${WORKSPACE}/test-results/prims/" ./test/prims

################################################################################
# TEST - Run GoogleTest for ml-prims, but with cuda-memcheck enabled
################################################################################

if [ "$BUILD_MODE" = "branch" ] && [ "$BUILD_TYPE" = "gpu" ]; then
    logger "GoogleTest for ml-prims with cuda-memcheck enabled..."
    cd $WORKSPACE/cpp/build
    python ../scripts/cuda-memcheck.py -tool memcheck -exe ./test/prims
fi
