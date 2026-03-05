#!/bin/bash
rm -rf xsim.dir
xvlog --sv rtl/*.sv tb/tb_counters.sv
xelab -debug typical -top tb_counters -snapshot tb_counters_opt
xsim tb_counters_opt -R | tee xsim_counters.log
