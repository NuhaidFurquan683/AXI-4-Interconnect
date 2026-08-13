#!/bin/bash
# Usage: ./sim/run.sh <module_name>
# Example: ./sim/run.sh axi_arbiter

MODULE=$1

if [ -z "$MODULE" ]; then
    echo "Usage: ./sim/run.sh <module_name>"
    echo "Expects rtl/${MODULE}.sv and tb/tb_${MODULE}.sv to exist"
    exit 1
fi

RTL="rtl/${MODULE}.sv"
TB="tb/tb_${MODULE}.sv"

# Check files exist
if [ ! -f "$RTL" ]; then echo "Missing: $RTL"; exit 1; fi
if [ ! -f "$TB" ]; then echo "Missing: $TB"; exit 1; fi

echo "=== Linting ${MODULE} ==="
verilator --lint-only -Wall $RTL
if [ $? -ne 0 ]; then
    echo "LINT FAILED"
    exit 1
fi

echo "=== Compiling ==="
verilator --binary --trace -j 0 -Wall \
    --top-module tb_${MODULE} \
    $TB $RTL \
    -o sim_${MODULE}

if [ $? -ne 0 ]; then
    echo "COMPILATION FAILED"
    exit 1
fi

echo "=== Running simulation ==="
./obj_dir/sim_${MODULE}

# Move waveform if generated
if [ -f "dump.vcd" ]; then
    mv dump.vcd sim/waves/${MODULE}.vcd
    echo "Waveform: sim/waves/${MODULE}.vcd"
fi

echo "=== Done ==="
