#!/bin/bash
rm -rf xsim.dir
xvlog --sv rtl/*.sv tb/tb_luma_vpass.sv
xelab -debug typical -top tb_luma_vpass -snapshot tb_luma_opt
xsim tb_luma_opt -R | tee xsim_luma.log
