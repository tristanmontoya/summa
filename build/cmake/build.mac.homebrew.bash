#!/bin/bash

# build SUMMA on a Mac using Bash, from cmake directory run this as 
# ./build.mac.homebrew.bash

# Fortran compiler
export FC=/opt/homebrew/bin/gfortran

# Get Homebrew LAPACK location
LAPACK_PREFIX=$(brew --prefix lapack)

# Library search path + link flags
export FLAGS_LINK="-L${LAPACK_PREFIX}/lib"
export LIBRARY_LINKS='-llapack'
export SUNDIALS_DIR=../../../sundials/install/

cmake -B ../cmake_build -S ../. \
  -DUSE_SUNDIALS=ON \
  -DSPECIFY_LAPACK_LINKS=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build ../cmake_build --target all -j