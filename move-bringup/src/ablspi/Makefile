# Out-of-tree build for the ablspi kernel module.
#
# Typical invocation when cross-compiling for the Move's aarch64 CM5 target:
#
#   make KDIR=/path/to/linux-rpi-6.6.y \
#        ARCH=arm64 \
#        CROSS_COMPILE=aarch64-linux-gnu- \
#        -j$(nproc)
#
# On the device itself (native build with kernel headers installed):
#
#   make
#
# Targets: ablspi.ko (default), clean, install (writes into
# $(DESTDIR)/lib/modules/$(KVER)/extra/), modules_install (uses the kernel's
# own install path under $(KDIR)).

KDIR     ?= /lib/modules/$(shell uname -r)/build
PWD      := $(CURDIR)
KVER     ?= $(shell uname -r)
DESTDIR  ?=

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: modules
	install -d $(DESTDIR)/lib/modules/$(KVER)/extra
	install -m 0644 ablspi.ko $(DESTDIR)/lib/modules/$(KVER)/extra/
	@if [ -z "$(DESTDIR)" ]; then depmod -a $(KVER); fi

modules_install: modules
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

.PHONY: all modules clean install modules_install
