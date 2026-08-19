include config.mk

FLAVORS := vanilla mingui cgui

.PHONY: all $(FLAVORS) clean

all: $(FLAVORS)

$(FLAVORS):
	@echo "Building Enderarch profile: $@"
	@bash build.sh $@

clean:
	rm -rf $(ISO_DIR) $(OUT_DIR)
	rm -rf workdir-*

.PHONY: help
help:
	@echo "Enderarch Build System"
	@echo "Usage: make <flavor>"
	@echo "Flavors: $(FLAVORS)"
	@echo ""
	@echo "make vanilla     - Build vanilla (CLI) ISO"
	@echo "make mingui      - Build MinGUI (Openbox) ISO"
	@echo "make cgui        - Build CGUI (Cinnamon) ISO"
	@echo "make all         - Build all flavors"
	@echo "make clean       - Clean build artifacts"