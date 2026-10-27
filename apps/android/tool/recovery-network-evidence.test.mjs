import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'

test('the actual native classifier distinguishes IMS, VPN, internet and unavailable capability evidence on a host JVM', () => {
  const root = resolve(import.meta.dirname, '../../..')
  const cache = realpathSync(join(root, '.cache/android'))
  const directory = mkdtempSync(join(cache, 'recovery-network-test-'))
  try {
    const source = join(directory, 'RecoveryNetworkEvidenceHostTest.java')
    writeFileSync(source, `
package com.minnnng.dsh_android;
import java.util.Arrays;
public final class RecoveryNetworkEvidenceHostTest {
  static RecoveryNetworkEvidence.Fact fact(boolean known, boolean internet, boolean validated, boolean vpn) {
    return new RecoveryNetworkEvidence.Fact(known, internet, validated, vpn);
  }
  static void expect(RecoveryNetworkEvidence.Fact[] facts, int... expected) {
    var counts = RecoveryNetworkEvidence.classify(facts);
    int[] actual = { counts.validatedNetworks, counts.validatedInternetNetworks, counts.validatedVpnInternetNetworks,
      counts.usableUnderlyingInternetNetworks, counts.unvalidatedUnderlyingInternetNetworks, counts.unknownCapabilityNetworks };
    if (!Arrays.equals(actual, expected)) throw new AssertionError(Arrays.toString(actual));
  }
  public static void main(String[] args) {
    var ims = fact(true, false, true, false);
    var vpn = fact(true, true, true, true);
    var internet = fact(true, true, true, false);
    var unvalidated = fact(true, true, false, false);
    var unknown = fact(false, false, false, false);
    expect(new RecoveryNetworkEvidence.Fact[] {}, 0, 0, 0, 0, 0, 0);
    expect(new RecoveryNetworkEvidence.Fact[] { ims }, 1, 0, 0, 0, 0, 0);
    expect(new RecoveryNetworkEvidence.Fact[] { vpn }, 1, 1, 1, 0, 0, 0);
    expect(new RecoveryNetworkEvidence.Fact[] { internet }, 1, 1, 0, 1, 0, 0);
    expect(new RecoveryNetworkEvidence.Fact[] { internet, vpn, ims }, 3, 2, 1, 1, 0, 0);
    expect(new RecoveryNetworkEvidence.Fact[] { vpn, ims }, 2, 1, 1, 0, 0, 0);
    expect(new RecoveryNetworkEvidence.Fact[] { unvalidated, vpn, ims }, 2, 1, 1, 0, 1, 0);
    expect(new RecoveryNetworkEvidence.Fact[] { unknown, vpn, ims }, 2, 1, 1, 0, 0, 1);
    expect(new RecoveryNetworkEvidence.Fact[] { internet, internet }, 2, 2, 0, 2, 0, 0);
    try { RecoveryNetworkEvidence.classify(null); throw new AssertionError("null accepted"); }
    catch (IllegalArgumentException expected) {}
    try { RecoveryNetworkEvidence.classify(new RecoveryNetworkEvidence.Fact[65]); throw new AssertionError("oversized inventory accepted"); }
    catch (IllegalArgumentException expected) {}
    System.out.println("9 classification cases and 2 bounds passed");
  }
}
`, 'utf8')
    const implementation = join(root, 'apps/android/android/app/src/androidTest/java/com/minnnng/dsh_android/RecoveryNetworkEvidence.java')
    execFileSync('javac', ['--release', '17', '-encoding', 'UTF-8', '-d', directory, implementation, source],
      { windowsHide: true, timeout: 30000 })
    const result = execFileSync('java', ['-cp', directory, 'com.minnnng.dsh_android.RecoveryNetworkEvidenceHostTest'],
      { windowsHide: true, encoding: 'utf8', timeout: 15000 })
    assert.match(result, /9 classification cases and 2 bounds passed/)
  } finally {
    const target = realpathSync(directory)
    assert.equal(dirname(target), cache)
    assert.ok(basename(target).startsWith('recovery-network-test-'))
    rmSync(target, { recursive: true })
  }
})
