/**
 * Portable-build update channel.
 *
 * This build has no upstream updater: the packing server builds a release
 * tag, pushes app.asar to the Windows client over SSH and restarts it. The
 * overlay falls back here when the regular update bridge reports
 * `check-failed`.
 *
 * The server origin and this build's tag are generated at pack time into
 * ./portable-build-tag (see bin/build-hermes-desktop-asar.sh).
 */
import { PORTABLE_BUILD_TAG, PORTABLE_UPDATE_BASE } from './portable-build-tag'

export { PORTABLE_BUILD_TAG, PORTABLE_UPDATE_BASE }

export interface PortableManifest {
  tag: string
  version: string
  builtAt: string
  artifactUrl: string
}

export interface PortableStatus {
  state: 'idle' | 'building' | 'deploying' | 'done' | 'error'
  tag: string | null
  log: readonly string[]
  deployed: boolean
  error: string | null
}

export async function fetchPortableManifest(): Promise<PortableManifest | null> {
  try {
    const res = await fetch(`${PORTABLE_UPDATE_BASE}/api/desktop-update/manifest`, {
      signal: AbortSignal.timeout(4000)
    })

    return res.ok ? ((await res.json()) as PortableManifest) : null
  } catch {
    return null
  }
}

export async function startPortableBuild(): Promise<boolean> {
  try {
    const res = await fetch(`${PORTABLE_UPDATE_BASE}/api/desktop-update/build`, { method: 'POST' })

    return res.ok || res.status === 409
  } catch {
    return false
  }
}

export async function fetchPortableStatus(): Promise<PortableStatus | null> {
  try {
    const res = await fetch(`${PORTABLE_UPDATE_BASE}/api/desktop-update/status`, {
      signal: AbortSignal.timeout(4000)
    })

    return res.ok ? ((await res.json()) as PortableStatus) : null
  } catch {
    return null
  }
}

/** Compare dotted versions ('v' prefix tolerated); <0 when a is older. */
export function comparePortableVersions(a: string, b: string): number {
  const pa = a.replace(/^v/, '').split('.').map(Number)
  const pb = b.replace(/^v/, '').split('.').map(Number)

  for (let i = 0; i < 3; i++) {
    const delta = (pa[i] || 0) - (pb[i] || 0)

    if (delta !== 0) {
      return delta
    }
  }

  return 0
}
