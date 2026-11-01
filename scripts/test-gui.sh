#!/bin/sh
set -eu
export NANOPORE_GUI_TESTS=1
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = Linux ]; then
  GDK_BACKEND=x11 xvfb-run -a crystal spec spec/gui/native_spec.cr
else
  crystal spec spec/gui/native_spec.cr
fi
