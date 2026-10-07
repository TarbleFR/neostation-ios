import test from 'node:test';
import assert from 'node:assert/strict';
import { Service } from 'bonjour-service';
import { discoveryAddress, discoveryHost } from '../discovery.mjs';

const adapter = (address, mac = 'bc:fc:e7:b6:d3:b1', internal = false) => ({address, mac, internal});
test('discovery uses the real LAN when a disconnected tunnel comes first', () => {
  assert.equal(discoveryAddress({Tailscale:[adapter('169.254.83.107', '00:00:00:00:00:00')],
    Ethernet:[adapter('fe80::8546:2f1c:cda8:e66c'), adapter('192.168.1.24')],
    Loopback:[adapter('127.0.0.1', '00:00:00:00:00:00', true)]}), '192.168.1.24');
  assert.equal(discoveryAddress({Ethernet:[adapter('10.0.0.3')]}), '10.0.0.3');
  assert.equal(discoveryAddress({WiFi:[adapter('172.16.0.3')]}), '172.16.0.3');
  assert.equal(discoveryAddress({Loopback:[adapter('127.0.0.1')], Tunnel:[adapter('169.254.1.2')]}), null);
});
test('published SRV host belongs to the local DNS namespace', () => {
  for (const name of ['Corentin', 'Corentin.local', 'Corentin.local.', 'a'.repeat(80), '...']) {
    const host = discoveryHost(name);
    assert.match(host, /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.local$/);
    const service = new Service({name:'NeoPlay', type:'neoplay', protocol:'tcp', port:17642, host,
      disableIPv6:true, txt:{v:'1', kind:'windows'}}, () => {}, () => {});
    assert.equal(service.RecordSRV(service).data.target, host);
    assert.equal(service.disableIPv6, true);
  }
  assert.equal(discoveryHost('Corentin'), 'corentin.local');
});
