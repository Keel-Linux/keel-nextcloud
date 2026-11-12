keel-nextcloud (prototype)
==========================

Nextcloud 35 on the LNMP stack (nginx, PHP-FPM 8.4, MariaDB 11.8) with
Redis, as a Keel layer on ``lnmp``::

    bt-layer nextcloud --parent lnmp

The design is handbook decision note 0087 (proposed), which amends 0062.
This is a local prototype: no remote, no image, nothing released. The
first boot hook, its library, the gate and the front files ran by hand on
a real LNMP pair in cloud advanced (BR1 and BR2, evidence
``2026-11-12-nextcloud-35-cloud-advanced-pair.md`` of the handbook).
``conf.d/main`` has not run on a build host.

What is in it
-------------

==============================================================  ==============================================
``Makefile``, ``plan/main``                                     the layer: PHP modules, Redis, bzip2, gpgv
``conf.d/main``                                                 the tarball 35.0.2 (sha256 pin and signature), ownership, Redis include, checks
``keys/nextcloud-security.gpg``                                 the release key 28806A878AE423A28372792ED75899B9A724937A
``overlay/usr/lib/inithooks/firstboot.d/40nextcloud``           the first boot: pair file, Redis ACL, session pool, install or replica config
``overlay/usr/lib/inithooks/lib/nextcloud.sh``                  the logic, as functions with no side effects
``overlay/usr/lib/keel-nextcloud/keel-nextcloud-gate``          opens the site only on the writer, empties Redis first, follows an upgrade on a replica
``overlay/etc/systemd/system/keel-nextcloud-*``                 the gate watcher (each address event), the gate timer (5 s), the cron timer (5 min, only while the gate is open)
``overlay/etc/nginx/keel-default.d/60-keel-nextcloud.conf``     the route in the default site of keel-web
``overlay/etc/nginx/keel-front.d/60-keel-nextcloud.conf``       the sync clients past Anubis, the body limit
``overlay/etc/coreruleset/plugins/keel-nextcloud-before.conf``  WebDAV behind Coraza
``overlay/usr/share/keel/appliances/nextcloud.yaml``            the manifest: replicated paths, shared secrets
``overlay/usr/local/bin/keel-occ``                              occ as the web user
``bin/keel-nextcloud-image-check``                              the image as a first boot starts from
``tests/``                                                      bats, ``coverage.sh`` (kcov), ``commission.yaml`` (draft)
==============================================================  ==============================================

Tests
-----

::

    make lint        # shellcheck, clean
    make test        # 87 bats tests
    make coverage    # kcov; 95 to 100 percent per file, threshold 90

``tests/commission.yaml`` is a draft: ``keel-commission --check`` accepts
it, and no pass has run. The manifest validates with keel 0.23.96 along
core, web, lnmp and nextcloud.

What the build host must do
---------------------------

1. A Forgejo repository ``Keel-Linux/keel-nextcloud`` (the maintainer's
   yes first), with the CI of keel-wordpress (``tests``, ``commission``,
   ``package``) and a ``changelog``.
2. ``bt-layer nextcloud --parent lnmp`` on the stable track, under
   ``flock /root/bt.lock``. ``conf.d/main`` needs the network to fetch the
   tarball and its signature.
3. The template and the ISO, then the passes of 0075 on BR1 and BR2.

Known gaps
----------

- No dialog for keel-init: an interactive first boot cannot ask the
  password of the administrator (``lxc-interactive`` would fail).
- The scheme behind Anubis: Nextcloud makes ``http://`` links on a
  request to port 443 in the cloud modes (0087, open point).
- Redis is installed from Debian with an include file, not through the
  ``unit-redis`` component of keel-redis.
- No ``changelog`` and no CI workflow yet.
- The files of the overlay get their modes from the checkout; check
  them in the image.
- The memory of nginx under Coraza with large DAV bodies: a release
  blocker candidate of note 0087, section 7; not a defect of this layer.
