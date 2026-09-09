import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const source = readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('async function acknowledgeDelivery(');
const end = source.indexOf('\n__name(acknowledgeDelivery,', start);
assert(start >= 0 && end > start);
const handler = new Function('receiverAuthorized', 'json', 'constantTimeEqual',
  source.slice(start, end) + '\nreturn acknowledgeDelivery;')(
    async request => request.headers.get('Authorization') === 'Bearer test-only',
    (body, status) => Response.json(body, {status}), (a, b) => a === b);
for (const state of ['canceled', 'expired', 'delivered', 'uploading', 'available', 'leased', 'ackDeleting']) {
  let writes = 0;
  const env = {
    STATE_DB: {prepare: () => ({bind: () => ({
      first: async () => ({state, sha256: 'a'.repeat(64), r2_key: 'test-only-payload'}),
      run: async () => { writes++; }
    })})},
    PHOTO_BUCKET: {delete: async key => { assert.equal(key, 'test-only-payload'); writes++; }}
  };
  const request = (hash, auth = 'Bearer test-only') => new Request('https://test.invalid/ack', {
    method:'POST', headers:{Authorization:auth}, body:JSON.stringify({sha256:hash})
  });
  assert.equal((await handler(request('wrong'),env,'receiver','delivery')).status,422);
  assert.equal((await handler(request('a'.repeat(64),'wrong'),env,'receiver','delivery')).status,403);
  assert.equal(writes, 0, 'Invalid SHA/auth must never delete payloads');
  const response = await handler(request('a'.repeat(64)),env,'receiver','delivery');
  const terminal = ['canceled','expired'].includes(state);
  const receivable = ['available', 'leased', 'ackDeleting'].includes(state);
  assert.equal(response.status, terminal ? 410 : (state === 'delivered' || receivable) ? 204 : 409, state);
  if (terminal) assert.equal((await response.json()).error, 'delivery ' + state);
  assert.equal(writes,receivable ? 3 : 0,'Only verified receivable deliveries may be acknowledged and cleaned');
}
console.log('PASS: exact deployed ACK handler terminal states, SHA and authorization guards');
