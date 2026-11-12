# keel-nextcloud: Nextcloud on nginx, PHP-FPM, MariaDB and Redis, built as a
# layer on the lnmp layer (handbook decisions 0059 and 0087, proposed):
#
#     bt-layer nextcloud --parent lnmp
#
# lnmp brings Keel Web's nginx, PHP-FPM 8.4 and MariaDB 11.8 with the first
# boot hooks of the database. The delta of this recipe: the PHP modules of
# Nextcloud, Redis, the Nextcloud code tree (pinned by sha256 and checked
# against the signature of Nextcloud), its route in keel-default.d, the
# gate, the cron timer, the first boot hook and the manifest. conf.d/main
# removes the check page of lnmp.
#
# PHP_* are read by common's conf/php. The route of the overlay sets the
# same body limit (512 MiB).
# The fab part runs only under bt-layer, which sets FAB_PATH; the local
# targets at the end (test, lint, coverage) need no fab.
ifdef FAB_PATH
PHP_MEMORY_LIMIT = 512M
PHP_UPLOAD_MAX_FILESIZE = 512M
PHP_POST_MAX_SIZE = 512M
PHP_MAX_EXECUTION_TIME = 3600

include $(FAB_PATH)/common/mk/turnkey/php-fpm.mk

# After the mk files, so a file of this overlay wins over a shared one.
COMMON_OVERLAYS += $(CURDIR)/overlay

# 80 and 443 are Web's, 12321 the panel, as in lnmp. 3306 and 6379 are
# not opened: MariaDB is on the loopback (on a pair on the mesh, lnmp's
# manifest), Redis is on its socket.
WEBMIN_FW_TCP_INCOMING = 22 80 443 12321

include $(FAB_PATH)/common/mk/turnkey.mk

# The checks conf.d/main runs on the tree, copied in before the conf scripts
# run and removed again by conf.d/main.
KEEL_BUILD_TOOLS ?= /usr/local/lib/keel-build
define _keel_root.patched/pre

	install -D -m 755 $(CURDIR)/bin/keel-nextcloud-image-check $O/root.patched$(KEEL_BUILD_TOOLS)/keel-nextcloud-image-check;
	install -D -m 644 $(CURDIR)/keys/nextcloud-security.gpg $O/root.patched$(KEEL_BUILD_TOOLS)/nextcloud-security.gpg;
endef
root.patched/pre += $(_keel_root.patched/pre)
endif

# Local targets of the repository (not used by bt-layer)
.PHONY: test lint coverage
test:
	bats tests
lint:
	shellcheck -x overlay/usr/lib/inithooks/lib/nextcloud.sh \
	    overlay/usr/lib/inithooks/firstboot.d/40nextcloud \
	    overlay/usr/lib/keel-nextcloud/keel-nextcloud-gate \
	    overlay/usr/local/bin/keel-occ bin/keel-nextcloud-image-check \
	    conf.d/main tests/coverage.sh
coverage:
	tests/coverage.sh
