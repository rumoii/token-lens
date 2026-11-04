import { createElement, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { ChartNoAxesCombined, FileSearch, History, Menu, Moon, RefreshCw, Settings, Sun, Wrench, X } from 'lucide-react';
import { api } from '../../lib/v1';
import { currentPeriod, periodQuery, periodRange } from '../../lib/period';
import { detailSearch, readDetail } from '../../lib/detail-query';
import { isSuccessfulRun, syncState } from '../../lib/sync-state';
import { markShapes, isStroked } from '../../lib/brand-mark';
import { toolOf } from '../../lib/tools';
import { useResource, useSyncState } from '../../pages/v1/shared';
import { useTheme } from '../../hooks/useTheme';
import { ToolTile } from '../lens/ToolTile';
import './sidebar.css';

export function getNavGroups() {
  return [
    { id: 'home', to: '/dashboard', icon: ChartNoAxesCombined, label: '用量总览' },
    { id: 'detail', to: '/dashboard?view=detail', icon: FileSearch, label: '用量明细' },
    { id: 'sessions', to: '/sessions', icon: History, label: '会话记录' },
    { id: 'sources', to: '/sources', icon: Wrench, label: '工具来源' },
    { id: 'settings', to: '/settings', icon: Settings, label: '价格与设置' }
  ];
}

function Mark() {
  return <svg width="28" height="28" viewBox="0 0 32 32" aria-hidden>
    {markShapes({ small: true }).map(({ type, role, attrs }, index) => createElement(type, {
      ...attrs, key: index,
      [isStroked(role) ? 'stroke' : 'fill']: `var(${role === 'accent' ? '--lens-clay' : '--lens-mark-bar'})`
    }))}
  </svg>;
}

function completedLabel(run) {
  const finished = Date.parse(run?.finished_at);
  if (!Number.isFinite(finished)) return '已完成同步';
  const minutes = Math.max(0, Math.round((Date.now() - finished) / 60000));
  if (minutes < 1) return '刚刚完成同步';
  if (minutes < 60) return `${minutes} 分钟前完成`;
  if (minutes < 1440) return `${Math.round(minutes / 60)} 小时前完成`;
  return `${Math.round(minutes / 1440)} 天前完成`;
}

export function AppLayout({ children }) {
  const location = useLocation();
  const period = currentPeriod(location.search);
  const periodText = periodQuery(period);
  const range = useMemo(() => periodRange(period), [periodText]);
  const usage = useResource(() => api.breakdown('source', range), [periodText]);
  const sources = useResource(() => api.sources(), []);
  const sync = useSyncState();
  const { resolvedTheme, setTheme } = useTheme();
  const [open, toggleDrawer] = useState(false);
  const [present, keepDrawer] = useState(false);
  const trigger = useRef(null);
  const drawer = useRef(null);
  const previousVersion = useRef(sync.version);
  const [pulse, animatePulse] = useState(false);
  useEffect(() => {
    if (sync.version === previousVersion.current) return;
    previousVersion.current = sync.version;
    animatePulse(true);
    const timer = setTimeout(() => animatePulse(false), 600);
    return () => clearTimeout(timer);
  }, [sync.version]);
  useEffect(() => {
    if (open) {
      keepDrawer(true);
      return;
    }
    const timer = setTimeout(() => keepDrawer(false), 180);
    return () => clearTimeout(timer);
  }, [open]);
  useEffect(() => {
    if (!open || !present) return;
    const panel = drawer.current;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const controls = () => [...panel.querySelectorAll('a[href], button:not(:disabled)')];
    controls()[0]?.focus();
    const keyboard = event => {
      if (event.key === 'Escape') { event.preventDefault(); toggleDrawer(false); }
      if (event.key !== 'Tab') return;
      const items = controls();
      const first = items[0];
      const last = items.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    panel.addEventListener('keydown', keyboard);
    return () => {
      panel.removeEventListener('keydown', keyboard);
      document.body.style.overflow = previousOverflow;
      trigger.current?.focus();
    };
  }, [open, present]);
  useEffect(() => { toggleDrawer(false); }, [location.pathname, location.search]);
  const closeNavigation = () => toggleDrawer(false);

  const details = readDetail(location.search);
  const home = location.pathname === '/' || location.pathname === '/dashboard';
  const rows = new Map();
  for (const source of sources.data?.sources ?? []) if (source.source) rows.set(source.source, 0);
  for (const group of usage.data?.groups ?? []) if (group.key) rows.set(group.key, Number(group.gross_tokens) || 0);
  const tools = [...rows].sort((left, right) => right[1] - left[1]);
  const total = Number(usage.data?.totals?.gross_tokens) || 0;
  const run = sync.lastRun ?? sources.data?.last_run;
  const busy = sync.phase === 'running' || sync.phase === 'conflict' || (sync.phase === 'idle' && run?.status === 'running');
  const warning = sync.warning || (isSuccessfulRun(run) ? run.anomalies?.join('；') : null);
  let status = '还没有同步记录';
  let dot = 'bg-ink-muted';
  if (isSuccessfulRun(run) || sync.phase === 'success') {
    status = warning ? `同步完成，有异常警告：${warning}` : completedLabel(run);
    dot = 'bg-signal-ok';
  }
  if (['failed', 'abandoned'].includes(run?.status) || ['error', 'timed_out'].includes(sync.phase)) {
    status = sync.error?.message || '最近的同步未完成';
    dot = 'bg-signal-danger';
  }
  if (busy || (!sync.error && run?.status === 'running')) {
    status = sync.phase === 'conflict' ? '已有同步在执行，正在等待完成' : '正在同步';
    dot = 'bg-ink-muted';
  }
  const refresh = () => {
    if (busy) return;
    const action = sync.errorKind === 'status' ? syncState.retryStatus : syncState.startSync;
    Promise.resolve(action()).catch(() => {});
  };
  const pending = usage.refreshing || sources.refreshing;
  const readError = usage.error || sources.error;
  const stateDot = <span aria-label={status} className={`relative inline-block h-2 w-2 shrink-0 rounded-full ${dot}`}>
    {pulse && <span className={`absolute inset-0 rounded-full ${dot} animate-ping motion-reduce:animate-none`} />}
  </span>;

  const navigation = <>
    <Link to="/dashboard" onClick={closeNavigation} className="mb-6 flex items-center gap-2 text-lg font-semibold text-ink"><Mark />Token Lens</Link>
    <nav aria-label="页面导航" className="flex flex-col gap-1">
      {getNavGroups().map(({ id, to, icon: Icon, label }) => {
        const active = id === 'home' ? home && details.view === 'overview' : id === 'detail' ? home && details.view === 'detail' : location.pathname === to;
        return <Link key={id} onClick={closeNavigation} to={id === 'detail' ? `/dashboard?${detailSearch(periodText)}` : to} aria-current={active ? 'page' : undefined}
          className={`flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm ${active ? 'bg-[var(--lens-fill-hover)] font-medium text-ink' : 'text-ink-secondary hover:bg-[var(--lens-fill-hover)]'}`}>
          <Icon aria-hidden size={17} />{label}
        </Link>;
      })}
    </nav>
    <section className="mt-6 min-h-0 flex-1 overflow-y-auto" aria-busy={pending} aria-label="本期工具">
      {pending && <p role="status" className="px-3 text-xs text-ink-muted">正在读取本期用量…</p>}
      {readError && <div role="alert" className="px-3 text-xs text-signal-danger">{readError.message}
        <button type="button" className="ml-2 underline" onClick={() => { usage.reload(); sources.reload(); }}>重试读取</button>
      </div>}
      {tools.length > 0 && <><h2 className="mb-2 px-3 text-xs font-medium text-ink-muted">本期工具</h2>
        {tools.map(([id, tokens]) => <Link key={id} onClick={closeNavigation} to={`/dashboard?${detailSearch(periodText, { tool: id, dim: 'model' })}`}
          title={`查看 ${toolOf(id).name} 的用量明细`} aria-current={home && details.view === 'detail' && details.tool === id ? 'page' : undefined}
          className="flex items-center gap-2 rounded-lg px-3 py-2 text-sm text-ink-secondary hover:bg-[var(--lens-fill-hover)]">
          <ToolTile id={id} size={20} /><span className="min-w-0 flex-1 truncate">{toolOf(id).name}</span>
          <span className="tabular-nums text-xs text-ink-muted">{total > 0 ? Math.round(tokens / total * 100) : 0}%</span>
        </Link>)}
      </>}
    </section>
    <footer className="mt-4 border-t border-[var(--lens-line)] pt-4">
      <p role="status" className="mb-3 flex items-start gap-2 text-xs text-ink-secondary"><span className="mt-1">{stateDot}</span><span>{status}</span></p>
      <div className="flex items-center justify-between">
        <button type="button" aria-label="立即同步" disabled={busy} onClick={refresh} className="flex items-center gap-1.5 rounded-md px-2 py-1.5 text-xs text-ink-secondary hover:bg-[var(--lens-fill-hover)] disabled:opacity-50">
          <RefreshCw aria-hidden size={14} className={busy ? 'animate-spin motion-reduce:animate-none' : ''} />同步用量
        </button>
        <div role="group" aria-label="侧栏外观" className="flex gap-1">
          {[['light', Sun, '浅色'], ['dark', Moon, '深色']].map(([theme, Icon, label]) => <button key={theme} type="button" aria-label={label} aria-pressed={resolvedTheme === theme} onClick={() => setTheme(theme)} className="rounded-md p-1.5 text-ink-secondary hover:bg-[var(--lens-fill-hover)]"><Icon aria-hidden size={15} /></button>)}
        </div>
      </div>
    </footer>
  </>;
  return <div className="h-dvh overflow-hidden bg-surface-1 text-ink">
    <aside className="fixed inset-y-0 left-0 hidden w-[244px] flex-col border-r border-[var(--lens-line)] bg-surface-0 px-4 py-6 md:flex">{navigation}</aside>
    <header className="flex h-[52px] items-center gap-3 border-b border-[var(--lens-line)] px-[14px] md:hidden">
      <button ref={trigger} type="button" aria-label="打开导航菜单" aria-expanded={open} onClick={() => toggleDrawer(value => !value)}><Menu aria-hidden size={22} /></button>
      <Link to="/dashboard" className="flex flex-1 items-center gap-1.5 font-semibold"><Mark />Token Lens</Link>{stateDot}
    </header>
    {present && <div className={`lens-navigation-layer fixed inset-0 z-40 md:hidden ${open ? '' : 'lens-navigation-closing'}`} aria-hidden={!open} inert={open ? undefined : ''}>
      <button type="button" tabIndex={-1} aria-label="关闭导航遮罩" onClick={() => toggleDrawer(false)} className="lens-navigation-scrim absolute inset-0 bg-black/40" />
      <div ref={drawer} role="dialog" aria-modal="true" aria-label="导航菜单" className="lens-navigation-drawer absolute inset-y-0 left-0 z-50 flex w-[272px] flex-col bg-surface-0 px-4 py-6">
        <button type="button" aria-label="关闭导航菜单" className="absolute right-3 top-3 rounded-md p-1 text-ink-secondary" onClick={() => toggleDrawer(false)}><X aria-hidden size={18} /></button>
        {navigation}
      </div>
    </div>}
    <main className="h-[calc(100dvh-52px)] overflow-y-auto md:ml-[244px] md:h-dvh"><div className="mx-auto h-full max-w-[1120px] px-[14px] pt-[18px] md:px-9 md:pt-7">{children}</div></main>
  </div>;
}
