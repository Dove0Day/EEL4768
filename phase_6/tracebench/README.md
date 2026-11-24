hart_random_tb.v was the bench used to validate the (submitted) design according to the given trace
trace_output.png is evidence that this particular bench seems to fully accept that design

To compile everything, use:
iverilog -g2012 -Wall -Wno-timescale -s hart_random_tb -o hart_random_sim hart_random_tb.v hart.v cache.v decoder.v imm.v rf.v alu.v fpu.v
To run it:
vvp hart_random_sim +PROGRAM=random_program.hex +COUNT=36088 +MAX_CYCLES=2000000 | tee random_trace.txt
