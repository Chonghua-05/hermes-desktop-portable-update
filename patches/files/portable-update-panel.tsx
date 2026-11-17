import { useEffect, useRef, useState } from 'react'

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

/** idle -> applying (main downloads+verifies) -> handoff (helper spawned, app quits). */
type ApplyPhase = 'idle' | 'applying' | 'handoff' | 'error'

/**
 * Replacement for the "cannot reach the update server" dead end on the
 * portable build: the app.asar is built by GitHub Actions and published as a
 * release asset. Main downloads and verifies it, then hands the swap to a
 * detached helper that runs after this app exits — the same shape Squirrel /
 * NSIS installers use, since nothing can overwrite a running bundle.
 */
export function PortableUpdatePanel({
  manifest,
  onRetryCheck
}: {
  manifest: PortableManifest
  onRetryCheck: () => void
}) {
  const [copied, setCopied] = useState(false)
  const [phase, setPhase] = useState<ApplyPhase>('idle')
  const [message, setMessage] = useState('')
  const mounted = useRef(true)

  useEffect(
    () => () => {
      mounted.current = false
    },
    []
  )

  // package.json version is meaningless (0.0.0); the build tag baked in at
  // pack time is the real identity of this portable build.
  const current = PORTABLE_BUILD_TAG
  const newer = comparePortableVersions(manifest.tag, current) > 0
  const bridge = window.hermesDesktop?.portableUpdate
  const canApply = newer && Boolean(bridge) && Boolean(manifest.asarSha256) && Boolean(manifest.unpackedSha256)

  const openRelease = () => {
    void window.hermesDesktop?.openExternal?.(manifest.artifactUrl)
  }

  const copyCommand = () => {
    void navigator.clipboard?.writeText(INSTALL_COMMAND).then(() => {
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    })
  }

  const applyUpdate = async () => {
    if (!bridge) {
      setPhase('error')
      setMessage('当前客户端没有一键更新桥接，请用下面的命令。')

      return
    }

    setPhase('applying')
    setMessage('正在下载并校验新版本…')

    try {
      const result = await bridge.apply({
        asarUrl: manifest.artifactUrl,
        unpackedUrl: manifest.unpackedUrl,
        sha256: manifest.asarSha256,
        unpackedSha256: manifest.unpackedSha256,
        version: manifest.version
      })

      if (!mounted.current) {
        return
      }

      if (!result?.ok) {
        setPhase('error')
        setMessage(result?.message || '更新失败，可改用下面的命令。')

        return
      }

      setPhase('handoff')
      setMessage('已完成下载校验，应用即将重启完成替换。')
    } catch (error) {
      if (mounted.current) {
        setPhase('error')
        setMessage((error as Error)?.message || '更新失败，可改用下面的命令。')
      }
    }
  }

  const busy = phase === 'applying' || phase === 'handoff'

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

        {newer && phase === 'idle' && <p className="text-primary font-medium">发现新版本，可一键更新。</p>}
        {!newer && current !== null && <p className="text-muted-foreground">当前已是最新打包版本。</p>}
        {message && <p className={phase === 'error' ? 'text-destructive' : 'text-muted-foreground'}>{message}</p>}
      </div>

      <div className="grid gap-2">
        {newer && (
          <Button className="font-semibold" disabled={busy || !canApply} onClick={applyUpdate} size="lg">
            {phase === 'applying' ? '正在下载…' : phase === 'handoff' ? '等待重启…' : `一键更新到 ${manifest.version}`}
          </Button>
        )}

        {newer && !canApply && phase === 'idle' && (
          <p className="text-center text-xs text-muted-foreground">该 release 缺少校验信息，请用下面的命令更新。</p>
        )}

        {newer && (
          <Button className="font-medium" disabled={busy} onClick={openRelease} type="button" variant="secondary">
            打开下载页
          </Button>
        )}

        <Button className="font-medium" disabled={busy} onClick={copyCommand} type="button" variant="secondary">
          {copied ? '已复制' : '复制更新命令'}
        </Button>

        <Button className="font-medium" disabled={busy} onClick={onRetryCheck} type="button" variant="text">
          重新检查
        </Button>

        <Button
          className="font-medium"
          disabled={busy}
          onClick={() => setUpdateOverlayOpen(false)}
          type="button"
          variant="text"
        >
          关闭
        </Button>
      </div>

      <div className="grid gap-2 rounded-md border border-border/70 bg-muted/35 px-3 py-2 text-left font-mono text-[11px] leading-4 text-muted-foreground">
        <span className="text-foreground/70"># 手动更新（Linux，重跑即更新）</span>
        <span className="break-all">{INSTALL_COMMAND}</span>
      </div>
    </div>
  )
}
