# overlay/desktop (2026-10-17)

Desktop look ported from Arrow-Silver-Daily-ARM64 so the PineTab2 image matches it.
build-pinetab2-image.sh copies this tree onto the image root *after* it re-applies
live-arm64/config/includes.chroot (which would otherwise put compositing back off),
then copies the skel files into /home/ArrowSilver (that home is made earlier in the build).

- etc/xdg/xfce4/panel/default.xml        top bar + centered bottom Docklike dock (48 px, 65% opacity)
- etc/xdg + etc/skel docklike-11.rc       dock pins; pins whose .desktop file is not in the
                                          image are dropped at build time
- etc/xdg/.../xfwm4.xml                   compositing on (needed for the see-through dock)
- etc/X11/Xsession.d/90arrow-webkit-vm    WEBKIT_DISABLE_DMABUF_RENDERER=1 only inside a VM
- usr/share/backgrounds/*.png             optional wallpapers; default stays arrow-silver.png

Packages added by the builder for this: xfce4-docklike-plugin, mousepad.
