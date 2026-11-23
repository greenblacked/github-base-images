import { attest, buildSLSAProvenancePredicate } from '@actions/attest'
import { attachArtifactToImage, getRegistryCredentials } from '@sigstore/oci'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const provenanceType = 'https://slsa.dev/provenance/v1'

async function readBundle(directory, subject, digest) {
  const bytes = await readFile(join(directory, 'attestation.json'))
  const bundle = JSON.parse(bytes)
  const statement = JSON.parse(Buffer.from(bundle.dsseEnvelope.payload, 'base64'))
  const [entry] = statement.subject
  if (statement.predicateType !== provenanceType || statement.subject.length !== 1 ||
      entry.name !== subject || `sha256:${entry.digest.sha256}` !== digest) {
    throw new Error('Saved attestation does not match the requested image and digest')
  }
  return { bytes, bundle }
}

export async function sign({ directory, subject, digest, visibility }, makePredicate = buildSLSAProvenancePredicate, signBundle = attest) {
  if (!/^ghcr\.io\/[a-z0-9-]+\/[a-z0-9-]+$/.test(subject) || !/^sha256:[a-f0-9]{64}$/.test(digest)) {
    throw new Error('Expected a GHCR image name and an immutable sha256 digest')
  }
  await mkdir(directory)
  await writeFile(join(directory, 'subject.txt'), `${subject}@${digest}\n`)

  const { type, params } = await makePredicate()
  const { bundle } = await signBundle({
    subjects: [{ name: subject, digest: { sha256: digest.slice(7) } }],
    predicateType: type,
    predicate: params,
    sigstore: visibility === 'public' ? 'public-good' : 'github',
    token: '',
    skipWrite: true,
  })
  await writeFile(join(directory, 'attestation.json'), JSON.stringify(bundle) + '\n')
}

export async function register({ directory, subject, digest, repository, apiUrl, token },
  { request = fetch, attach = attachArtifactToImage, credentials = getRegistryCredentials } = {}) {
  const { bytes, bundle } = await readBundle(directory, subject, digest)
  const response = await request(`${apiUrl}/repos/${repository}/attestations`, {
    method: 'POST',
    redirect: 'error',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ bundle }),
    signal: AbortSignal.timeout(30_000),
  })
  if (!response.ok) {
    throw new Error(`GitHub attestation registration failed (HTTP ${response.status})`)
  }
  await attach({
    credentials: credentials(subject),
    imageName: subject,
    imageDigest: digest,
    artifact: bytes,
    mediaType: bundle.mediaType,
    annotations: {
      'dev.sigstore.bundle.content': 'dsse-envelope',
      'dev.sigstore.bundle.predicateType': provenanceType,
    },
    fetchOpts: { timeout: 30_000, retry: 3 },
  })
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { ATTESTATION_DIR: directory, REPO: subject, DIGEST: digest,
    GITHUB_REPOSITORY: repository, GITHUB_API_URL: apiUrl, GH_TOKEN: token, REPOSITORY_VISIBILITY: visibility } = process.env
  const command = process.argv[2]
  try {
    if (command === 'sign') {
      await sign({ directory, subject, digest, visibility })
    } else if (command === 'register') {
      await register({ directory, subject, digest, repository, apiUrl, token })
    } else {
      throw new Error('Expected sign or register')
    }
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
