#!/usr/bin/env python3
import logging
import os
import requests

logging.basicConfig(level=logging.DEBUG)
log = logging.getLogger(__name__)

"""
our inputs:
 BRANCH=master or openwrt-23.05 or openwrt-24.10 etc.
   for 23.05, we want something from https://downloads.openwrt.org/releases/23.05-SNAPSHOT/targets/
   for master, https://downloads.openwrt.org/snapshots/targets/
 TARGET=x86_64 or similar
   which means x86/64 (so _ becomes /) inside our targets/ dir
"""

# TODO: once this goes at the end of the yml, exit 1 on failure

def main():
    branch = os.environ["BRANCH"]
    target = os.environ["TARGET"]

    target = target.replace('-', '/')

    log.debug(f"got branch {branch}, path for target {target}")

    if branch == 'master':
        baseurl = 'https://downloads.openwrt.org/snapshots/targets/'
    elif branch.startswith('openwrt-'):
        rel = branch[8:]
        baseurl = 'https://downloads.openwrt.org/releases/' + rel + '-SNAPSHOT/targets/'
    else:
        raise Exception("don't know downloads URL for branch " + branch)

    targeturl = baseurl + target

    # log.debug(f"getting ")
    sha256sumsreq = requests.get(targeturl + '/sha256sums')

    if sha256sumsreq.status_code != 200:
        log.error("got non-200 code, stopping")
        return

    sha256sums = sha256sumsreq.text

    # print(sha256sums)
    for line in sha256sums.splitlines():
        hash, fname = line.split()
        if fname.endswith('rootfs.tar.gz'):
            if fname.startswith('*'):
                fname = fname[1:]
            print(targeturl + '/' + fname)
            return

    log.error("did not find a rootfs.tar.gz in sha256sums, stopping")

if __name__ == '__main__':
    main()
