import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ErrorBoundary } from './ErrorBoundary';
import { setCopyLocale } from '../lib/copy';

function Broken({ failure }) { throw failure; }
beforeEach(() => { setCopyLocale('en'); vi.spyOn(console, 'error').mockImplementation(() => {}); });
describe('view fallback', () => {
  it('renders healthy children', () => {
    render(<ErrorBoundary><p>healthy view</p></ErrorBoundary>);
    expect(screen.getByText('healthy view')).toBeVisible();
  });
  it.each([new Error('<svg onload=bad>'), 'plain failure', { message: 'object detail' }, null])('shows text diagnostics for %s', failure => {
    render(<ErrorBoundary><Broken failure={failure} /></ErrorBoundary>);
    expect(screen.getByRole('alert')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Reload page' })).toBeEnabled();
    expect(document.querySelector('pre svg')).toBeNull();
    const expected = failure?.message ?? failure ?? 'No diagnostic message is available.';
    expect(document.querySelector('pre')).toHaveTextContent(String(expected));
    expect(console.error).toHaveBeenCalledWith('Token Lens view failed', failure, expect.objectContaining({ componentStack: expect.any(String) }));
  });
  it('reloads through a keyboard-accessible button in the Chinese dark appearance', () => {
    setCopyLocale('zh-CN');
    document.documentElement.classList.add('dark');
    render(<ErrorBoundary><Broken failure={new Error('diagnostic')} /></ErrorBoundary>);
    const button = screen.getByRole('button', { name: '重新载入页面' });
    button.focus();
    expect(button).toHaveFocus();
    console.error.mockClear();
    fireEvent.click(button);
    expect(console.error.mock.calls.some(([message]) => String(message).includes('Not implemented: navigation'))).toBe(true);
    document.documentElement.classList.remove('dark');
  });
});
