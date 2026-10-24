# recipes/

Reserved for a future debos/vmdb2 recipe. The current PineTab2 builder is the
self-contained bash script:

```bash
sudo ~/Documents/Arrow-Silver/live-pinetab/scripts/build-pinetab2-image.sh
```

That path reuses `live-arm64/chroot` via rsync and is faster to iterate on
than introducing debos.
