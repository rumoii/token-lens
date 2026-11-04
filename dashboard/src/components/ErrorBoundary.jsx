import { Component } from 'react';
import { TriangleAlert } from 'lucide-react';
import { copy } from '../lib/copy';

export class ErrorBoundary extends Component {
  state = { failed: false, error: null };
  static getDerivedStateFromError(error) {
    return { failed: true, error };
  }
  componentDidCatch(error, diagnostic) {
    console.error('Token Lens view failed', error, diagnostic);
  }
  render() {
    if (!this.state.failed) return this.props.children;
    const failure = this.state.error;
    const detail = failure?.message != null ? String(failure.message) : failure == null ? '' : String(failure);
    return <section className="flex min-h-screen items-center justify-center bg-surface-1 p-6 text-ink" role="alert">
      <div className="w-full max-w-md rounded-2xl border border-[var(--lens-line)] bg-surface-2 p-6">
        <TriangleAlert aria-hidden className="mb-4 h-6 w-6 text-signal-warn" />
        <p className="text-caption text-ink-secondary">{copy('error.boundary.title')}</p>
        <h1 className="mt-2 text-xl font-semibold">{copy('error.boundary.subtitle')}</h1>
        <p className="mt-3 whitespace-pre-line text-sm text-ink-secondary">{copy('error.boundary.hint')}</p>
        <pre className="my-4 max-h-32 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-surface-1 p-3 text-xs">{detail.trim() ? copy('shared.error.prefix', { error: detail }) : copy('error.boundary.no_details')}</pre>
        <button type="button" className="rounded-lg bg-clay px-4 py-2 text-white" onClick={() => {
          if (typeof window !== 'undefined') window.location.reload();
        }}>{copy('error.boundary.action.reload')}</button>
      </div>
    </section>;
  }
}
