# AXI4-Stream Interconnect

A parameterised AXI4-Stream interconnect with AXI4-Lite control plane, written in SystemVerilog.

## Overview

This project implements a configurable N-master × M-slave AXI4-Stream crossbar switch with runtime-programmable routing via an AXI4-Lite register interface. Designed for FPGA deployment.

## Architecture

- **AXI4-Stream Crossbar** — round-robin arbitrated switching fabric between N masters and M slaves
- **AXI4-Lite Control Plane** — register bank for runtime route configuration, status readback, and interrupt control
- **Arbiter** — per-slave round-robin arbiter to resolve contention when multiple masters target the same slave
- **Decoder** — routes transactions based on address/ID mapping configured via the control plane

## Project Structure

```
├── rtl/                  # Synthesisable SystemVerilog modules
├── tb/                   # Testbenches
├── sim/                  # Simulation scripts and waveform outputs
│   ├── run.sh            # Simulation runner (lint → compile → simulate)
│   └── waves/            # VCD waveforms (gitignored)
├── docs/                 # Design specifications and block diagrams
└── constraints/          # FPGA timing and pin constraints
```

## Tools

- **Simulation:** Verilator (lint + simulation)
- **Waveform viewer:** GTKWave
- **Synthesis:** AMD Vivado (FPGA target)

## Building and Simulation

Lint a module:
```bash
verilator --lint-only -Wall rtl/<module>.sv
```

Run a testbench:
```bash
./sim/run.sh <module_name>
```

## Status

Under active development.
