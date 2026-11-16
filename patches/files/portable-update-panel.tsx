import { useState } from 'react'

import { BrandMark } from '@/components/brand-mark'
import { Button } from '@/components/ui/button'
import { DialogDescription, DialogTitle } from '@/components/ui/dialog'
import {
  PORTABLE_BUILD_TAG,
  PORTABLE_RELEASE_URL,
  comparePortableVersions,
  type PortableManifest
} from '@/lib/portable-updates'
import { setUpdateOverlayOpen } from '@/store/updates'

const INSTALL_COMMAND = `curl -fsSL ${PORTABLE_RELEASE_URL}/latest/download/install-hermes-desktop-linux.sh | bash`

/**
 * Replacement for the "cannot reach the update server" dead end on the
 * portable build: the app.asar is built by GitHub Actions and published as a
 * release asset, so this panel only compares versions and hands out the
 * artifact — the client cannot rebuild itself.
 */
export function PortableUpdatePanel({
  manifest,
  onRetryCheck
}: {
  manifest: PortableManifest
  onRetryCheck: () => void
}) {
  const [copied, setCopied] = useState(false)

  // package.json version is meaningless (0.0.0); the build tag baked in at
  // pack time is the real identity of this portable build.
  const current = PORTABLE_BUILD_TAG
  const newer = comparePortableVersions(manifest.tag, current) > 0

  const openRelease = () => {
    void window.hermesDesktop?.openExternal?.(manifest.artifactUrl)
  }

  const copyCommand = () => {
    void navigator.clipboard?.writeText(INSTALL_COMMAND).then(() => {
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    })
  }

  return (
    <div className="grid gap-5 px-6 pb-6 pt-7 pr-8">
      <div className="flex flex-col items-center gap-3 text-center">
        <BrandMark className="size-16" />

        <DialogTitle className="text-center text-xl">客户端更新（GitHub）</DialogTitle>
        <DialogDescription className="max-w-prose text-center text-sm leading-5 text-muted-foreground">
          此绿色版客户端由 GitHub Actions 构建并发布，不走官方更新通道。
        </DialogDescription>
      </div>

      <div className="grid gap-1.5 text-center text-sm">
        <p className="text-muted-foreground">
          当前版本 <span className="font-medium text-foreground">{current ?? '未知'}</span>
          <span className="mx-1">·</span>
          最新版本 <span className="font-medium text-foreground">{manifest.version || manifest.tag}</span>
        </p>

        {newer && <p className="text-primary font-medium">发现新版本，可下载后替换。</p>}
        {!newer && current !== null && (
          <p className="text-muted-foreground">当前已是最新打包版本。</p>
        )}
      </div>

      <div className="grid gap-2 rounded-md border border-border/70 bg-muted/35 px-3 py-2 text-left font-mono text-[11px] leading-4 text-muted-foreground">
        <span className="text-foreground/70"># Linux（Arch/Fedora/Debian，重跑即更新）</span>
        <span className="break-all">{INSTALL_COMMAND}</span>
      </div>

      <div className="grid gap-2">
        {newer && (
          <Button className="font-semibold" onClick={openRelease} size="lg">
            打开下载页
          </Button>
        )}

        <Button className="font-medium" onClick={copyCommand} type="button" variant="secondary">
          {copied ? '已复制' : '复制更新命令'}
        </Button>

        <Button className="font-medium" onClick={onRetryCheck} type="button" variant="text">
          重新检查
        </Button>

        <Button
          className="font-medium"
          onClick={() => setUpdateOverlayOpen(false)}
          type="button"
          variant="text"
        >
          关闭
        </Button>
      </div>
    </div>
  )
}
