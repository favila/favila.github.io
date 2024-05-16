define ASSETS
assets/img/posts/datomic-entity-id-structure/entity-id-structure.svg
endef

# Suppress implicit rules
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
.SUFFIXES:

# default target
.PHONY: assets
assets: $(ASSETS)

#define asset_dir_prereq
#$(1) : $(patsubst assets/%,assets-source/%,$(1)) | $(dir $(1))
#endef
#$(foreach a,$(ASSETS),$(eval $(call asset_dir_prereq,$(a))))

# Make any directory path
define asset_dir_rule
$(1) :
	@mkdir -p $$@
endef
$(foreach d,$(sort $(dir $(ASSETS))),$(eval $(call asset_dir_rule, $(d))))

assets/img/posts/datomic-entity-id-structure/entity-id-structure.svg : assets-source/img/posts/datomic-entity-id-structure/entity-id-structure.json | assets/img/posts/datomic-entity-id-structure
	npx bit-field --input $< --lanes 4 --bits 64 --hspace 770 --vspace 60 > $@

.PHONY: clean
clean:
	rm $(ASSETS)
