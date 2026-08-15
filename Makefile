.PHONY: rtl-test software-cifar sim-rgb332

rtl-test:
	tools/run_rtl_tests.sh

software-cifar:
	$(MAKE) -C sdk/software/examples/cifar_tinyvit_demo \
		LA32RSOC_WINDOWS_HOME=$(CURDIR)

sim-rgb332: software-cifar
	$(MAKE) -C fpga sim-rgb332-baseline-dvi
