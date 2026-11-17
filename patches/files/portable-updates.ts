/**
 * Portable-build update channel (GitHub Releases).
 *
 * This build has no upstream updater: app.asar is built by GitHub Actions from
 * an upstream tag and published as a release asset. The overlay falls back here
 * when the regular update bridge reports `check-failed`.
 *
 * PORTABLE_BUILD_TAG / PORTABLE_UPDATE_BASE / PORTABLE_RELEASE_URL are generated
 * at pack time into ./portable-build-tag (bin/build-hermes-desktop-asar.sh or
 * .github/workflows/build-asar.yml).
 */
import { PORTABLE_BUILD_TAG, PORTABLE_RELEASE_URL, PORTABLE_UPDATE_BASE } from './portable-build-tag'

export { PORTABLE_BUILD_TAG, PORTABLE_RELEASE_URL, PORTABLE_UPDATE_BASE }

/** `manifest.json` shipped with every release: everything the updater needs. */
export const PORTABLE_MANIFEST_URL = `${PORTABLE_RELEASE_URL}/latest/download/manifest.json`

export interface PortableManifest {
  /** Release tag, e.g. `asar-v0.23.2`. */
  tag: string
  /** Upstream version, e.g. `0.23.2`. */
  version: string
  builtAt: string
  artifactUrl: string
  /** sha256 of app.asar; empty when only the release API answered. */
  asarSha256: string
  unpackedUrl: string
  unpackedSha256: string
}

interface ReleaseManifest {
  tag?: string
  upstreamTag?: string
  version?: string
  builtAt?: string
  sha256?: string
  unpackedSha256?: string
  artifactUrl?: string
  unpackedUrl?: string
}

interface GitHubRelease {
  tag_name?: string
  published_at?: string
  assets?: { name?: string; browser_download_url?: string }[]
}

/** `asar-v0.23.2` / `v0.23.2` -> `0.23.2` */
function stripTagPrefix(tag: string): string {
  return tag.replace(/^asar-/, '').replace(/^v/, '')
}

/**
 * Reads the release manifest, which carries the checksums and asset URLs the
 * in-app updater verifies before writing anything. Falls back to the release
 * API (version only, no checksums) so a manifest hiccup degrades to the manual
 * path instead of hiding a newer version entirely.
 */
export async function fetchPortableManifest(): Promise<PortableManifest | null> {
  try {
    const res = await fetch(PORTABLE_MANIFEST_URL, { signal: AbortSignal.timeout(6000) })

    if (res.ok) {
      const manifest = (await res.json()) as ReleaseManifest

      if (manifest.tag) {
        return {
          tag: manifest.tag,
          version: manifest.version || stripTagPrefix(manifest.tag),
          builtAt: manifest.builtAt ?? '',
          artifactUrl: manifest.artifactUrl || `${PORTABLE_RELEASE_URL}/latest/download/app.asar`,
          asarSha256: manifest.sha256 ?? '',
          unpackedUrl: manifest.unpackedUrl || `${PORTABLE_RELEASE_URL}/latest/download/app.asar.unpacked.tar.gz`,
          unpackedSha256: manifest.unpackedSha256 ?? ''
        }
      }
    }
  } catch {
    // fall through to the release API probe
  }

  try {
    const res = await fetch(PORTABLE_UPDATE_BASE, {
      headers: { Accept: 'application/vnd.github+json' },
      signal: AbortSignal.timeout(6000)
    })

    if (!res.ok) {
      return null
    }

    const release = (await res.json()) as GitHubRelease
    const asset = release.assets?.find(entry => entry.name === 'app.asar')

    if (!release.tag_name || !asset?.browser_download_url) {
      return null
    }

    return {
      tag: release.tag_name,
      version: stripTagPrefix(release.tag_name),
      builtAt: release.published_at ?? '',
      artifactUrl: asset.browser_download_url,
      asarSha256: '',
      unpackedUrl: `${PORTABLE_RELEASE_URL}/latest/download/app.asar.unpacked.tar.gz`,
      unpackedSha256: ''
    }
  } catch {
    return null
  }
}

/** Compare dotted versions ('asar-'/'v' prefixes tolerated); <0 when a is older. */
export function comparePortableVersions(a: string, b: string): number {
  const pa = stripTagPrefix(a).split('.').map(Number)
  const pb = stripTagPrefix(b).split('.').map(Number)

  for (let i = 0; i < 3; i++) {
    const delta = (pa[i] || 0) - (pb[i] || 0)

    if (delta !== 0) {
      return delta
    }
  }

  return 0
}
