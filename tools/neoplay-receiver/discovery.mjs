import { networkInterfaces } from 'node:os';
import { isIPv4 } from 'node:net';

export function discoveryAddress(interfaces = networkInterfaces()) {
  const addresses = Object.values(interfaces).flat().filter(value => value &&
    !value.internal && isIPv4(value.address) &&
    !value.address.startsWith('169.254.') && !value.address.startsWith('127.') &&
    value.address !== '0.0.0.0' && value.mac !== '00:00:00:00:00:00');
  const privateLAN = value => /^10\.|^192\.168\.|^172\.(1[6-9]|2\d|3[01])\./.test(value.address);
  return (addresses.find(privateLAN) ?? addresses[0])?.address ?? null;
}

export function discoveryHost(computerName) {
  const label = computerName.replace(/\.+$/, '').replace(/\.local$/i, '')
    .replace(/[^a-zA-Z0-9-]/g, '-').replace(/^-+|-+$/g, '').slice(0, 63).replace(/-+$/g, '') || 'neoplay';
  return `${label.toLowerCase()}.local`;
}
