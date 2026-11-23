# Phase 7 documentation

You can find the documentation and problem descriptions for phase seven in `phase_7/documentation/phase_7.pdf`. Be sure to **read all pages** of the PDF. There are two parts to this phase:

1. An out-of-order (Tomasulo-style) backend in `hart.v`, with the register alias table in `rat.v` and the common data bus (CDB) arbiter in `cdb_arb.v` as separate modules
2. A formal verification harness (`riscv_fv.v`) that checks your `cdb_arb` and `rat` with SymbiYosys

Your submission is one zip file with these files:

- `hart.v`, `alu.v`, `imm.v`, `rf.v` and `decoder.v`
- `fpu.v` from phase 6
- `cdb_arb.v` and `rat.v`
- `riscv_fv.v`, in the root of the zip next to `hart.v`
- Your phase 5 cache, under `cache/`
- Any other files your `hart.v` needs

Put one module in each file, and name the module the same as the file (except cache modules under `cache/`).

The skeletons in `phase_7/skeletons/` show the new `hart.v` ports and parameters, and the `riscv_fv.v` stub to start your formal verification harness from. `alu.v`, `imm.v`, `rf.v` and `decoder.v` keep their phase 6 ports.

> **You will need to re-install the conda environment for this phase.**

# Rubric
| Category | Points |
| -------- | -------- |
| Basic correctness    | 2    |
| Hazards / integration    | 1    |
| Out-of-order completion (witness)    | 3    |
| Out-of-order throughput (CPI)    | 2    |
| Total | 8 |

Formal verification is worth 2 points, scored separately from the categories in the table (Section 6 of the PDF).

# Install

I recommend using conda, as this will allow you to install everything needed.

https://docs.conda.io/projects/conda/en/latest/user-guide/install/index.html

Once you have conda, follow the instructions below.

### Linux/MacOS

```
git clone https://github.com/UnaryLab/EEL4768_RISC-V_Project
cd EEL4768_RISC-V_Project/phase_7/
conda env create -f environment.yaml
```
Then, you can activate the conda environment
```
conda activate eel4768_phase_7
```
You need to reactivate or make sure you are in this conda env before running your testbench every time.

### Windows

Icarus and GTK cannot be directly installed through conda. If you have a windows system, I recommend either using [wsl](https://learn.microsoft.com/en-us/windows/wsl/install) (Windows subsystem for linux), or you can use the [eustis server](https://www.youtube.com/watch?v=KGm5RdI_gNA).

Both of these solutions will run a linux operating system. If you have issues, please come to my office hours.

# Testing your work

**There is no autograder in this repository.** Verifying that your `hart.v`,
`cdb_arb.v`, `rat.v`, `fpu.v`, your cache, `alu.v`, `imm.v`, `rf.v` and `decoder.v` behave correctly is part of the assignment.
Your testbench drives the combinational instruction memory port and also needs a main memory for your data cache to talk to.
Follow the example testbench outlined in `phase_2/example/` to understand how to write a testbench.

The PDF names some paths as they appear in the course source tree. In this repository, `source/fv/` is `phase_7/fv/`, `source/python-ece552/` is `phase_7/lint/`, and the `riscv_fv.v` stub is `phase_7/skeletons/riscv_fv.v`.

## Linting

`lint/` holds a Verilog rule checker that the autograder runs.
**It only does design checking to see if your design breaks any rules. It does not validate the output or functionality of your design.**

To install it, run the following command from `phase_7/` with the conda environment active.

```
pip install ./lint
```

To check your design, run the checker on your files. The `-w` flag treats warnings as errors, as the autograder does.

```
ece552 validate -w hart.v alu.v imm.v rf.v decoder.v fpu.v cdb_arb.v rat.v riscv_fv.v cache/*.v
```

The autograder checks every `.v` file in the root of your zip, `riscv_fv.v` included, so add any other top-level files your `hart.v` needs. List your `cache/` files too, so that the checker can find the cache modules your hart instantiates. The autograder applies the rules only to the files in the root of your zip.

If the command prints nothing and exits with code 0, your files pass. Otherwise, each error names the file, the line, and the rule you broke.

## Formal verification

The formal verification tools (SymbiYosys, Yosys and Z3) are not in the conda environment. Install the OSS CAD Suite as Section 6.3 of the PDF describes.

The formal verification files are in `phase_7/fv/`. Section 6 of the PDF explains the credit rules and walks through both steps below. Put the OSS CAD Suite first on your `PATH` before you run them.

First, check your toolchain with the mutex example. It isn't graded. From `phase_7/`:

```
fv/example/mutex/run.sh
```

The run ends with `DONE (PASS, rc=0)`.

Then, copy the stub into your submission folder, fill it in, and check it. `run.sh` takes the folder that holds your `riscv_fv.v`, `cdb_arb.v` and `rat.v`. SymbiYosys compiles only these three files.

```
cp skeletons/riscv_fv.v /path/to/your/submission/riscv_fv.v
fv/riscv/run.sh /path/to/your/submission
```

`run.sh` uses `phase_7/fv/riscv/riscv_fv.sby`, the same job file used for grading. Don't change it.

## Example

`phase_2/example/` holds two files:

- **`opmux.v`** -- a small combinational module: four inputs (`i_a`, `i_b`,
  `i_sel`, `i_en`), two outputs (`o_result`, `o_zero`), and a two-bit select
  choosing between `+`, `-`, `<<` and `>>`.
- **`opmux_tb.v`** -- a self-checking testbench for it. **This is the file to
  read.** It is commented as a walkthrough, and its structure is the one every
  testbench you write this semester will have.

## Run iverilog

To run the example testbench, follow the script below. To run your own verilog file and testbench, just replace the paths for the testbench and target file.

```
cd EEL4768_RISC-V_Project/phase_2/
iverilog -s opmux_tb -o sim example/opmux_tb.v example/opmux.v
./sim
```

For phase 7, list your testbench and every file your hart needs:

```
iverilog -g2005 -s hart_tb -o sim hart_tb.v hart.v alu.v imm.v rf.v decoder.v fpu.v cdb_arb.v rat.v riscv_fv.v cache/*.v
./sim
```

`-s` names the top module to elaborate, `-o` names the simulator to write, and
every source file the design needs is listed after them. `-g2005` compiles
the files as Verilog-2005, iverilog's default standard, which grading uses. Grading compiles every `.v` file in your zip with its own testbench, so `riscv_fv.v` must compile with iverilog too. Leave your testbench out of the zip.

Running the example prints:

```
========== opmux testbench ==========
--- add ---
[PASS] add: 7 + 9
[PASS] add: 0 + 0 sets zero
...
212 passed, 0 failed
ALL TESTS PASSED
```

## Waveforms

The example also writes `opmux.vcd`:

```
gtkwave opmux.vcd
```

Add `$dumpfile`/`$dumpvars` to your own testbench the same way to get a waveform of your hart.

This outputs a waveform, similar to the ones from digital systems, to view. This is helpful for debugging.
