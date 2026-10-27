/** Official development inputs. Guest-image redistribution still needs its source bundle. */
export const tinyEmuSourceLock = Object.freeze({
  version: '2019-12-21',
  url: 'https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz',
  sha256: 'be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555',
  license: 'MIT',
  licenseFile: 'MIT-LICENSE.txt',
  root: 'tinyemu-2019-12-21',
})

export const tinyEmuGuestFixtureLock = Object.freeze({
  url: 'https://bellard.org/tinyemu/diskimage-linux-riscv-2018-09-23.tar.gz',
  sha256: '808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14',
  root: 'diskimage-linux-riscv-2018-09-23',
  distribution: 'development-fixture-only-until-corresponding-source-and-licenses-are-bundled',
  memoryMiB: 128,
  commandLine: 'console=hvc0 root=/dev/vda rw',
  upstreamPatches: 'patches/',
  biosSourceRevision: 'ac2c910b18c3e36cfd85080472e78ad2fe484325',
  kernelSourceRevision: 'a3b1e7acc6a181e04e9a943942084395df4498dd',
  files: {
    bios: { name: 'bbl64.bin', bytes: 53786, sha256: '293610cea7af6c75e4a8337e16c0d62834becbf31ffd9cca35e0c211602349db' },
    kernel: { name: 'kernel-riscv64.bin', bytes: 3946740, sha256: '293aef345c8e996320de4ca7fc87ff48155a183b3dde00d2f269c8e461b067c5' },
    disk: { name: 'root-riscv64.bin', bytes: 4194304, sha256: '04c4e67351934c3b81602698adf56f39961f53fe630f2920ad15bc9c12da971b' },
  },
})

/** No SDL, curl/OpenSSL, SLIRP, KVM, host-directory or HTTP filesystem adapter. */
export const tinyEmuHeadlessSources = Object.freeze([
  'virtio.c', 'pci.c', 'fs.c', 'cutils.c', 'iomem.c', 'simplefb.c', 'riscv_machine.c', 'softfp.c',
])

/** Official rootfs and signed package index used by the offline guest builders. */
export const alpineGuestSourceLock = Object.freeze({
  version: '3.22.7',
  architecture: 'riscv64',
  url: 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/riscv64/alpine-minirootfs-3.22.7-riscv64.tar.gz',
  sha256: '50043f35362c3b7507a94814f2373948485e6d577a39f61833f2c37c0760458a',
  packageIndexUrl: 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main/riscv64/APKINDEX.tar.gz',
  packageIndexSha256: '64e046acf0a38d027c351301bfd1670fda7b951f5c234a3739018d3d7780eed9',
  packageLock: 'alpine-packages.lock.json',
})

/** Corresponding boot-component source; excludes the opaque old demo rootfs. */
export const tinyEmuBootSourceLock = Object.freeze({
  bios: {
    url: 'https://codeload.github.com/riscv-software-src/riscv-pk/tar.gz/ac2c910b18c3e36cfd85080472e78ad2fe484325',
    sha256: 'f24a34defd6e04ff9ef1d1b9d2a86b4b8bf5f97283f646c15d6a6c8a5039f126',
    license: 'BSD-3-Clause',
    licenseSha256: '7a2a8577b920db0ed2442b323963061c07536f1e382f4bd052bd2d7ea0e495fe',
    patch: 'riscv-pk.diff',
    patchSha256: 'ee5c9335ff9f7501d04b1f50dbf95c66ce7d22aaaf5bcc102eeae51f2b825fcf',
  },
  kernel: {
    url: 'https://codeload.github.com/riscv/riscv-linux/tar.gz/a3b1e7acc6a181e04e9a943942084395df4498dd',
    sha256: 'cd7d190fcd20ee3a326329374a67c9e2839393669aa283def2a2ee0daeee9020',
    license: 'GPL-2.0-only WITH Linux-syscall-note',
    licenseSha256: 'af8067302947c01fd9eee72befa54c7e3ef8a48fecde7fd71277f2290b2bf0f7',
    patch: 'riscv-linux.diff',
    patchSha256: '48999c3aca770205b6cd01546e429f431a4d01f3d28c5317568a06849804409d',
    config: 'config_linux_riscv64',
    configSha256: '442e3380b626a19eeed01f2142284fc7ba58e2829f5f7162e9e3f44bce65d2af',
  },
})
