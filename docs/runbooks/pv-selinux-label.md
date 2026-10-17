# Label an existing iSCSI volume for SELinux

New iSCSI volumes get the mount option `context=system_u:object_r:ephemeral_t:s0`
from their StorageClass. Volumes created before that need it once, one at a time
([decisions.md](../decisions.md#selinux-labels-on-csi-volumes)). Never for
`immich/immich-data`: it stays unlabelled by decision, and the script refuses it.

## Which tool

| Volume | How |
| --- | --- |
| Manifest in `infrastructure/iscsi-volumes/` | add `mountOptions: [context=system_u:object_r:ephemeral_t:s0]` to the PV there, one application per pull request |
| Any other iSCSI PV | `scripts/pv-selinux-label.sh` (below) |
| `immich-data` (`pvc-b9d3e7d8-0d3e-43d4-b8d3-8f212ede0ea6`) | nothing |

## Steps

1. Database volume (CloudNativePG): check that the last backup is younger than
   24 hours before anything else. If not, take one first.
2. Dry run. It prints the options before and after and the patch it would send:

   ```sh
   scripts/pv-selinux-label.sh <pv>
   ```

3. Apply. It prints the result and the pod that uses the claim:

   ```sh
   scripts/pv-selinux-label.sh <pv> --apply
   ```

4. Restart that pod (delete it; its controller recreates it), or wait for its next
   normal restart. The option only applies at the next mount.
5. Check, from inside the pod, that the mount carries the label:

   ```sh
   kubectl -n <ns> exec <pod> -- grep ' <mount path> ' /proc/mounts
   ```

   The line shows `context=system_u:object_r:ephemeral_t:s0`. The AVC records
   from that node (`vector_audit_records_total{type="AVC"}`) drop.
6. Database: the cluster reports healthy before the next volume.

## If the mount fails

The pod stays in `ContainerCreating` with a mount error in its events. Revert the
option at once and restart the pod, then stop:

```sh
scripts/pv-selinux-label.sh <pv> --revert
kubectl -n <ns> delete pod <pod>
```

The script is idempotent: running `--apply` or `--revert` twice changes nothing
the second time.
