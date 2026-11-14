import { useStore } from '@nanostores/react'
import { useEffect, useState } from 'react'

import { BrandMark } from '@/components/brand-mark'
import { Button } from '@/components/ui/button'
import { DialogDescription, DialogTitle } from '@/components/ui/dialog'
import { Loader } from '@/components/ui/loader'
import { Progress } from '@/components/ui/progress'
import {
  PORTABLE_BUILD_TAG,
  comparePortableVersions,
  fetchPortableStatus,
  startPortableBuild,
  type PortableManifest,
  type PortableStatus
} from '@/lib/portable-updates'
import { setUpdateOverlayOpen } from '@/store/updates'

const RUNNING_STATES = new Set(['building', 'deploying'])
const TERMINAL_STATES = new Set(['done', 'error'])

function formatLogTail(log: readonly string[]): string[] {
  return log.slice(-4).filter(Boolean)
}

/**
 * Replacement for the "cannot reach the update server" dead end on the
 * portable (packing-server) build: compares the packing server's manifest
 * with the running version and drives the build+deploy+restart pipeline.
 */
export function PortableUpdatePanel({
  manifest,
  onRetryCheck
}: {
  manifest: PortableManifest
  onRetryCheck: () => void
}) {
  const [status, setStatus] = useState<PortableStatus | null>(null)
  const [starting, setStarting] = useState(false)

  // package.json version is meaningless (0.0.0); the build tag baked in at
  // pack time is the real identity of this portable build.
  const current = PORTABLE_BUILD_TAG
  const newer = comparePortableVersions(manifest.tag, current) > 0

  useEffect(() => {
    if (!status || TERMINAL_STATES.has(status.state)) {
      return
    }

    const timer = window.setInterval(() => {
      void fetchPortableStatus().then(next => next && setStatus(next))
    }, 2000)

    return () => window.clearInterval(timer)
  }, [status])

  const running = status !== null && RUNNING_STATES.has(status.state)
  const logTail = status ? formatLogTail(status.log) : []

  const handleStart = () => {
    setStarting(true)
    void startPortableBuild().then(ok => {
      setStarting(false)

      if (ok) {
        void fetchPortableStatus().then(s => s && setStatus(s))
      }
    })
  }

  return (
    <div className="grid gap-5 px-6 pb-6 pt-7 pr-8">
      <div className="flex flex-col items-center gap-3 text-center">
        <BrandMark className="size-16" />

        <DialogTitle className="text-center text-xl">客户端更新（打包服务器）</DialogTitle>
        <DialogDescription className="max-w-prose text-center text-sm leading-5 text-muted-foreground">
          此绿色版客户端由本机打包服务器构建与部署，不走官方更新通道。
        </DialogDescription>
      </div>

      <div className="grid gap-1.5 text-center text-sm">
        <p className="text-muted-foreground">
          当前版本 <span className="font-medium text-foreground">{current ?? '未知'}</span>
          <span className="mx-1">·</span>
          服务器版本 <span className="font-medium text-foreground">{manifest.tag}</span>
        </p>

        {!running && newer && <p className="text-primary font-medium">发现新版本，可一键构建并部署。</p>}
        {!running && !newer && current !== null && (
          <p className="text-muted-foreground">当前已是最新打包版本。</p>
        )}
      </div>

      {running && (
        <>
          <div className="flex flex-col items-center gap-2 text-center">
            <Loader className="size-10" label={status?.state === 'deploying' ? '部署中…' : '构建中…'} type="lemniscate-bloom" />
            <p className="text-sm text-muted-foreground">
              正在服务器上构建并部署到本机，完成后客户端将自动重启。
            </p>
          </div>
          <Progress aria-label="更新进度" indeterminate size="lg" value={0} />
        </>
      )}

      {logTail.length > 0 && (
        <div className="max-h-24 overflow-hidden rounded-md border border-border/70 bg-muted/35 px-3 py-2 text-left font-mono text-[11px] leading-4 text-muted-foreground">
          {logTail.map((line, index) => (
            <div className="truncate" key={`${index}-${line}`}>
              {line}
            </div>
          ))}
        </div>
      )}

      {status?.state === 'error' && (
        <p className="max-w-prose text-center text-xs leading-5 text-red-500">
          更新失败：{status.error ?? '未知错误'}
        </p>
      )}

      {status?.state === 'done' && (
        <p className="text-center text-sm text-primary font-medium">已部署 {status.tag ?? manifest.tag}，客户端正在重启…</p>
      )}

      <div className="grid gap-2">
        {!running && status?.state !== 'done' && newer && (
          <Button className="font-semibold" disabled={starting} onClick={handleStart} size="lg">
            {starting ? '启动中…' : '一键更新'}
          </Button>
        )}

        {!running && (
          <Button className="font-medium" onClick={onRetryCheck} type="button" variant="text">
            重新检查
          </Button>
        )}

        {status?.state === 'done' && (
          <Button className="font-semibold" onClick={() => setUpdateOverlayOpen(false)} size="lg" variant="secondary">
            完成
          </Button>
        )}
      </div>
    </div>
  )
}
