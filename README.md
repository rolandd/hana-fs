# hana-fs

Script to guide creating and mounting filesystems on Bare Metal Solution

## Using

1. Gather required information from the system:
   ```
   sudo sanlun lun show > sanlun.out
   sudo multipath -l > multipath.out
   ```
1. Run the script:
   ```
   ./hana-fs.sh sanlun.out multipath.out
   ```
1. Review the list of commands produced by the script and run them to
   create and mount required filesystems.

## The fine print

This product is [licensed](LICENSE) under the Apache 2 license.  This
is not an officially supported Google project.
