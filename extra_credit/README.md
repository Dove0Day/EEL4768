# Extra credit documentation

You can find the documentation and problem descriptions for the extra credit phase in `extra_credit/documentation/extra_credit.pdf`. Be sure to **read all pages** of the PDF. This phase is worth 5 points of extra credit. There are two parts to this phase:

1. Raise the IPC of your own phase 7 out-of-order processor by at least 25%, using any method. Your design must still retire exactly the same instructions as your phase 7 design.
2. An 8 - 10 minute presentation on your whole project

Your submission is one zip file with the same files as phase 7:

- `hart.v`, `alu.v`, `imm.v`, `rf.v` and `decoder.v`
- `fpu.v` from phase 6
- `cdb_arb.v` and `rat.v`
- `riscv_fv.v`, in the root of the zip next to `hart.v`
- Your phase 5 cache, under `cache/`
- Any other files your `hart.v` needs

Put one module in each file, and name the module the same as the file (except cache modules under `cache/`).
