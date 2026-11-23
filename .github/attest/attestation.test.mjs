import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { register, sign } from './attestation.mjs'

const subject = 'ghcr.io/greenblacked/ci-python313'
const hex = 'a'.repeat(64)
const digest = `sha256:${hex}`
const repository = 'greenblacked/github-base-images'
const apiUrl = 'https://api.github.com'
const predicate = { type: 'https://slsa.dev/provenance/v1', params: { runDetails: { metadata: { invocationId: 'run/598/attempts/1' } } } }
const bundle = {
  mediaType: 'application/vnd.dev.sigstore.bundle.v0.3+json',
  dsseEnvelope: { payload: Buffer.from(JSON.stringify({
    predicateType: predicate.type, predicate: predicate.params, subject: [{ name: subject, digest: { sha256: hex } }],
  })).toString('base64') },
}

async function fixture(t) {
  const parent = await mkdtemp(join(tmpdir(), 'attestation-test-'))
  t.after(() => rm(parent, { recursive: true, force: true }))
  return { directory: join(parent, 'evidence'), subject, digest, repository, apiUrl, token: 'mock-token', visibility: 'public' }
}

test('signs once and registers the archived bundle in GitHub and GHCR', async t => {
  const context = await fixture(t)
  const create = t.mock.fn(async options => {
    assert.equal(options.skipWrite, true)
    assert.equal(options.sigstore, 'public-good')
    assert.deepEqual(options.predicate, predicate.params)
    return { bundle }
  })
  await sign(context, async () => predicate, create)
  const path = join(context.directory, 'attestation.json')
  const bytes = await readFile(path)
  const request = t.mock.fn(async (url, options) => {
    assert.equal(url, `${apiUrl}/repos/${repository}/attestations`)
    assert.equal(options.method, 'POST')
    assert.deepEqual(JSON.parse(options.body), { bundle })
    return { ok: true }
  })
  const attach = t.mock.fn(async options => {
    assert.equal(options.imageName, subject)
    assert.equal(options.imageDigest, digest)
    assert.deepEqual(options.artifact, bytes)
    assert.equal(options.annotations['dev.sigstore.bundle.predicateType'], predicate.type)
  })
  await register(context, { request, attach, credentials: () => undefined })
  assert.equal(create.mock.callCount(), 1)
  assert.equal(request.mock.callCount(), 1)
  assert.equal(attach.mock.callCount(), 1)
})

test('a GitHub 409 stops registration and retains the original bundle and digest', async t => {
  const context = await fixture(t)
  await sign(context, async () => predicate, async () => ({ bundle }))
  const request = t.mock.fn(async () => ({ ok: false, status: 409 }))
  const attach = t.mock.fn()
  await assert.rejects(register(context, { request, attach }), /HTTP 409/)
  assert.equal(request.mock.callCount(), 1)
  assert.equal(attach.mock.callCount(), 0)
  assert.deepEqual(JSON.parse(await readFile(join(context.directory, 'attestation.json'))), bundle)
  assert.equal(await readFile(join(context.directory, 'subject.txt'), 'utf8'), `${subject}@${digest}\n`)
})

test('an ambiguous transport failure makes one request and leaves the bundle intact', async t => {
  const context = await fixture(t)
  await sign(context, async () => predicate, async () => ({ bundle }))
  const request = t.mock.fn(async () => { throw new Error('request timed out') })
  const attach = t.mock.fn()
  await assert.rejects(register(context, { request, attach }), /timed out/)
  assert.equal(request.mock.callCount(), 1)
  assert.equal(attach.mock.callCount(), 0)
  assert.deepEqual(JSON.parse(await readFile(join(context.directory, 'attestation.json'))), bundle)
})

test('a registry failure after successful GitHub registration leaves the bundle intact', async t => {
  const context = await fixture(t)
  await sign(context, async () => predicate, async () => ({ bundle }))
  const request = t.mock.fn(async () => ({ ok: true }))
  const attach = t.mock.fn(async () => { throw new Error('registry unavailable') })
  await assert.rejects(register(context, { request, attach, credentials: () => undefined }), /registry unavailable/)
  assert.equal(request.mock.callCount(), 1)
  assert.equal(attach.mock.callCount(), 1)
  assert.deepEqual(JSON.parse(await readFile(join(context.directory, 'attestation.json'))), bundle)
})

test('a signer failure leaves only the digest and a different digest cannot register', async t => {
  const context = await fixture(t)
  await assert.rejects(sign(context, async () => predicate, async () => { throw new Error('Rekor 404') }), /Rekor 404/)
  assert.equal(await readFile(join(context.directory, 'subject.txt'), 'utf8'), `${subject}@${digest}\n`)
  const request = t.mock.fn()
  await assert.rejects(register(context, { request }), /ENOENT/)
  const next = { ...context, directory: join(context.directory, 'next') }
  await sign(next, async () => predicate, async () => ({ bundle }))
  await assert.rejects(register({ ...next, digest: `sha256:${'b'.repeat(64)}` }, { request }), /does not match/)
  assert.equal(request.mock.callCount(), 0)
})

test('a repository without confirmed public visibility signs with GitHub Sigstore', async t => {
  const context = await fixture(t)
  const create = t.mock.fn(async options => {
    assert.equal(options.sigstore, 'github')
    return { bundle }
  })
  await sign({ ...context, visibility: undefined }, async () => predicate, create)
  assert.equal(create.mock.callCount(), 1)
})
